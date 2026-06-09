# 000 - A Scatter-Gather Routing API

This proposal presents an alternative to [PR #70](https://github.com/kroxylicious/design/pull/70)
for adding routing to Kroxylicious.
It proposes a narrower Router plugin API focused exclusively on scatter-gather coordination,
with per-route namespace translation, node ID mapping, and protocol-level transformations
handled by per-route filter chains and the runtime — not the Router.

## Current situation

Kroxylicious's `Filter` plugin API binds each filter chain to a single upstream Kafka cluster.
A filter can manipulate requests and responses and originate its own requests,
but it cannot influence _which_ cluster receives the requests it handles.
This 1:1 constraint is the only thing preventing use cases like union clusters,
principal-aware routing, and topic splicing.

The existing non-routed pipeline already has the shape of a degenerate single-route router:

```
Client → [VC filters] → [BrokerAddressFilter] → [ApiVersionsIntersectFilter] → Cluster
```

`BrokerAddressFilter` rewrites broker addresses in METADATA responses so clients connect
back through the proxy. `ApiVersionsIntersectFilter` intersects the broker's API version
ranges with the proxy's own capabilities. Both are runtime-managed _implicit filters_ —
invisible to the user, inserted by the runtime to handle protocol-level concerns.

This pipeline is a 1:1 router that has been optimised by removing the indirection.
The question is: what is the _minimum_ addition needed to generalise it to 1:N?

## Motivation

The use cases motivating routing (union clusters, principal-aware routing, topic splicing)
are described in [070-routing-api.md](070-routing-api.md) and not repeated here.

What _is_ worth examining is what routing actually adds over the existing model.
PR #70's `Router.onRequest()` receives the full deserialised request for every dynamically-routed
API key, is responsible for sending requests to routes via the `RouterContext`, composing
responses from multiple routes, and returning the final response to the client.
This makes the Router responsible for three distinct concerns that differ in a critical way:

1. **Per-route namespace translation** — rewriting content within a single route's response
   (virtual node IDs, broker addresses, topic names, partition IDs).
   This requires no cross-route knowledge.

2. **Scatter-gather composition** — deciding which routes receive the request and composing their
   responses into a single client response. This _requires_ cross-route knowledge:
   only the Router knows which routes it scattered to, and therefore what it needs to gather.

3. **Per-route predicates** — selection logic determining which routes participate in the scatter
   (e.g. "route to the cluster that owns this topic"). This is per-route state,
   not cross-route coordination.

Concern 1 is already handled by the existing implicit filter machinery — `BrokerAddressFilter`
and `ApiVersionsIntersectFilter` are per-route namespace translators.
Concern 3 is a per-route extension point, analogous to adding a filter on a route.
Only concern 2 — scatter-gather — is irreducibly the Router's job.

A thinner Router that owns only scatter-gather coordination lets the existing filter chain
machinery handle everything else. This preserves consistency with the existing model,
reduces the plugin author surface, and avoids duplicating protocol-handling logic that
the runtime already knows how to do.

## Proposal

### The model

#### Today's pipeline is a 1:1 router

The current pipeline for a non-routed virtual cluster:

```
Client → [VC filters] → [BrokerAddressFilter] → [ApiVersionsIntersectFilter] → Cluster
```

This is already a degenerate single-route router:
- The "scatter" is trivial: one route, one cluster.
- The "gather" is trivial: one response, returned as-is.
- Namespace translation (addresses, API versions) is handled by implicit filters.
- The identity node ID mapping (`V = t`) is a special case of the general formula.

There is no Router plugin because there is no decision to make.

#### Routing extends this to 1:N

The routed pipeline forks at the Router:

```
Client → [VC filters] → Router → Route A: [user filters] → [implicit filters] → Cluster A
                                → Route B: [user filters] → [implicit filters] → Cluster B
```

Each route gets its own filter chain: user-configured filters (e.g. topic name rewriting,
SASL initiator for upstream authentication) followed by Router-declared filters. The
Router declares its per-route filter chain via `RouterFactory.filtersRequiredForRoute()` — the
default provides the baseline (node ID mapping, broker address rewriting, API version
intersection); a Router that needs more (partition filtering, identifier mapping)
overrides the method and declares the full chain.

Each route has two distinct ID spaces: **downstream** and **upstream**. The downstream
space is what the layer above (client or parent router) sees. The upstream space is what
the next layer down sees — which may be a backing cluster's real IDs or another router's
virtual IDs. In a nested topology (`Client → Router A → route ra1 → Router B → route rb2
→ Cluster X`), ra1's upstream IDs are Router B's downstream IDs, not Cluster X's real
broker IDs. The mapping is always between adjacent layers. Each route maintains its own
bidirectional downstream ↔ upstream mapping; there is no global ID space across routes.
Per-route filters operate in the downstream space; implicit filters at the end of the
chain translate to upstream before the request reaches the next layer.

The Router sits at the fork point. Its job is exclusively:
- **Scatter**: which routes receive this request?
- **Gather**: how to compose the responses from those routes into a single client response?

Everything else stays where it already is.

#### Routers compose into a DAG

A route's target is either a cluster or another router. Routers and routes together
form a directed acyclic graph (DAG). Clusters are the leaf nodes; routers are the
interior nodes. Startup validation rejects cycles and dangling references. This is
the same structural model as PR #70.

```
                                              route "a"
                                      .---[filters...]--→ AzFetchRouter --→ Cluster A
                                     /                     (single route)
Client → [VC filters] → UnionRouter
                                     \
                                      '---[filters...]--→ AzFetchRouter --→ Cluster B
                                              route "b"    (single route)
```

When a route targets another router rather than a cluster, the request passes through
the route's filter chain before reaching the nested router. Each layer in the DAG gets
its own filter chain handling its own namespace translation. The downstream/upstream
ID space model makes this precise: the outer route's upstream IDs are the inner
router's downstream IDs. Neither layer needs to know about the other's ID space —
they share a boundary, and per-route filters at that boundary handle the translation.

The nested dispatch composition formula (`V_outer = k + S_outer × V_inner`) is a
property of the runtime's node ID management and applies unchanged at each layer.

**AZ-aware fetch as a composition example.** The simplest composable router is a
single-route dispatch router that does nothing but connection hopping. An AZ-aware
fetch router receives a FETCH targeting virtual node 1 (the partition leader in a
remote AZ) and redirects it to virtual node 2 (an in-sync replica in the local AZ)
via `sendToNode`. The message content is unchanged — the IDs are consistent, the
partition references are correct. The router is purely changing which upstream
connection carries the request.

The router doesn't need to cache METADATA itself. The runtime caches the current
METADATA response per route and exposes it via `ScatterContext.currentMetadata()`.
The router consults this on FETCH to find a local replica:

```java
class AzAwareFetchRouter implements Router {
    private final String localAz;

    CompletionStage<ScatterGatherResult> scatter(short apiVersion,
                                                  ApiKeys apiKey,
                                                  RequestHeaderData header,
                                                  ApiMessage request,
                                                  ScatterContext ctx) {
        if (apiKey == ApiKeys.FETCH) {
            MetadataResponseData metadata = ctx.currentMetadata("main");
            int clientTarget = nodeIdFrom(header);
            int destination = findLocalReplica(metadata, clientTarget, localAz);
            return ctx.sendToNode("main", destination, header, request)
                .thenApply(resp -> new Completed(resp.body()));
        }

        // Everything else including METADATA: forward to the client's target
        int target = nodeIdFrom(header);
        return ctx.sendToNode("main", target, header, request)
            .thenApply(resp -> new Completed(resp.body()));
    }
}
```

This router needs no custom per-route filters — the runtime's default implicit filters
handle namespace translation. No special METADATA handling — the runtime caches it, the
router queries it. The only interesting decision is _which node_ receives the FETCH.
In the simplest case, `scatter()` reduces to connection selection.

Composed with a union router, the AZ-aware fetch router sits between the union router
and each cluster. The union router handles scatter-gather (METADATA merging, partition
routing). The AZ router handles per-cluster connection hopping. Each is a single
concern, tested and configured independently. Adding AZ-aware fetch to an existing
union cluster deployment is a configuration change — insert the AZ router between
the union router's routes and the backing clusters — not a code change to the union
router.

#### Three layers, three owners

| Layer | Owner | Cross-route knowledge? |
|-------|-------|----------------------|
| Per-route namespace translation | Per-route implicit filters (runtime) | No |
| Scatter-gather composition | Router plugin | Yes |
| Per-route predicates / transformation | Per-route user filters or Router config | No |

The key constraint: scatter and gather are inseparable.
The scatter decision determines the gather shape.
If the Router scatters a METADATA request to routes A and B, only the Router knows it needs
to merge two METADATA responses into one.
A filter — which sees only its own route's traffic — cannot perform this merge because it
doesn't know whether other routes were also queried.

### What the Router owns

#### Scatter-gather coordination

The Router's irreducible contribution is coordinating requests across multiple routes
and composing their responses. In the general case this is scatter-gather: fan out to
multiple routes and merge results. In the simple case — single-route topologies,
AZ-aware redirection, coordinator targeting — scatter reduces to **connection selection**:
choosing which upstream node receives the request. The gather is trivial (pass through
the single response).

For **METADATA**, the Router scatters the request to some or all routes, receives per-route
responses (each already rewritten into the route's namespace by implicit filters), and
merges them: combining broker lists, merging topic metadata, deduplicating.
This establishes the _topology_ — the multi-cluster namespace as seen by the client.

For **leader-directed API keys** in simple topologies (principal-aware routing, single-route
per connection), the Router's `scatter()` is trivial: the request targets a downstream node ID
that belongs to a single route, so the Router calls `sendToNode` with that route and node.
For AZ-aware routing, the Router can redirect to a different node — an in-sync replica in
the client's availability zone — by calling `sendToNode` with the local replica's node ID
instead of the leader's. This connection hopping is purely a dispatch decision; the message
content is unchanged.

For **union topics**, a single PRODUCE or FETCH can contain partitions that span routes.
This happens because the Router's METADATA scatter-gather merged partition leaders from
multiple upstream clusters onto shared virtual nodes — partitions from cluster A and
cluster B may both report the same virtual node as their leader. The client, following
standard Kafka behaviour, groups all partitions by leader and sends a single request
to that virtual node. The request body therefore references partitions from multiple
backing clusters, even though the client believes it is talking to one broker.
The Router's scatter sends the request to the relevant routes — but per-route filters
do the hard protocol work.

Consider a PRODUCE request containing partitions 1, 3, 7, 8, 9 (cluster A) and
2, 4, 10, 11 (cluster B). The Router scatters the _entire_ PRODUCE to both routes:

```
                                     ┌─ Route A filter ──→ Cluster A
                                     │  (strips partitions     (receives PRODUCE
Client ── PRODUCE ──→ Router ────────┤   2,4,10,11;            for 1,3,7,8,9)
           (all          (scatter    │   keeps 1,3,7,8,9)
          partitions)   to A and B)  │
                                     └─ Route B filter ──→ Cluster B
                                        (strips partitions     (receives PRODUCE
                                         1,3,7,8,9;            for 2,4,10,11)
                                         keeps 2,4,10,11)
```

Each route's per-route filter operates wholly in the **downstream** ID space. It consults the runtime's per-route topology cache (exposed via FilterContext) to
determine which downstream partition IDs belong to its route, strips the rest, and
forwards a trimmed request to the next filter in the chain — where downstream-to-upstream
ID mapping happens. The filter never mixes ID spaces: downstream partition IDs are
compared against downstream topology, keeping the decision consistent.
The filter has no cross-route knowledge — it only knows what its own route owns.
The two PRODUCE responses come back, and the Router's gather merges the partition
results — generic response composition with no protocol-level partition knowledge.

The Router never inspects the PRODUCE structure. Its scatter decision is "which routes,"
not "which partitions go where." The protocol-aware decomposition happens in a
per-route filter shipped as a reference implementation by the runtime.

This addresses a concern raised in
[PR #70's review](https://github.com/kroxylicious/design/pull/70#discussion_r3370514842):
that the Router must traverse the request structure to decompose it, so identifier
rewriting is trivial additional work. In this model the Router doesn't traverse the
structure at all. The per-route filter does the traversal — and since it's already
inside the request structure to strip partitions, identifier rewriting (PIDs, etc.)
IS trivial at that point, exactly as observed. But the filter is written once by the
runtime, not by every Router author.

The cost is CPU: the full PRODUCE is deserialised on each route, and each route
discards the partitions that don't belong. This is more total deserialisation work
than a single decomposition would be. But it happens inside the proxy (no wasted
network bandwidth), and it's an optimisation concern, not an architectural one —
a future runtime optimisation could pre-split the request before dispatch without
changing the model.

The Router's `scatter()` is called for every request, but the Router's job is always
the same: decide which routes receive the request and compose the responses. The
complexity of that decision varies by API key:
- **METADATA**: genuine multi-route scatter and response merge.
- **API keys with cross-cluster semantics** (e.g. `LIST_GROUPS`): scatter to multiple
  routes and merge results.
- **Leader-directed API keys** (PRODUCE, FETCH): send to one or more routes based on
  the request's target. Per-route filters handle decomposition and identifier translation.
- **Simple forwarding** (e.g. single-route topologies): send to the one route.

The Router's surface is narrower than PR #70's `onRequest()` not because it is called
less often, but because it does less per call — scatter-gather coordination only, with
protocol-level concerns handled by per-route filters.

#### Topology declaration

The Router declares which routes it manages and their scatter-gather behaviour:
which routes participate in metadata discovery and how responses are composed.

### What per-route filters handle

#### Topic name rewriting

For a union cluster, each route maps broker-side topic names into the virtual namespace
(e.g. prefixing with `cluster-a.` or `cluster-b.`). This is a per-route transformation
with no cross-route knowledge — it doesn't need to know what other routes are doing.

A per-route filter rewrites topic names in requests (stripping the prefix before forwarding
upstream) and responses (adding the prefix before returning downstream). The Router's
METADATA gather then merges these already-rewritten responses.

This separation means the topic naming strategy is configured on the route, not baked into
the Router. Different routes can use different naming strategies.

#### Partition filtering

In multi-route topologies (union topics), a single client request may contain partitions
spanning multiple routes. The runtime ships a reference `PartitionRoutingFilter` that
handles this. A Router author who needs different decomposition logic can supply their
own filter instead.

The filter operates wholly in the **downstream** ID space. It receives
requests in downstream IDs (via the route's filter chain) and consults the runtime's per-route topology
cache — exposed through a richer `FilterContext` — to determine which downstream
topic-partitions belong to its route. On a PRODUCE or FETCH request, it strips partitions
that don't belong to its route and forwards a trimmed request to the next filter in the
chain, where downstream-to-upstream ID mapping happens. On the response path, it passes
through only the partition results that correspond to what it forwarded.

The filter does not maintain its own METADATA cache. The runtime maintains the per-route
topology — built from METADATA responses that flow through each route's filter chain
during the Router's scatter-gather — and exposes it to implicit filters via FilterContext.
This avoids duplicating state the runtime already owns and ensures the filter's view is
consistent with the topology the Router established.

**Correctness.** The filter's partition-stripping is the **only** line of defence against
data misrouting. Unlike a non-routed topology where the broker can reject a request for
a partition it doesn't own, downstream-to-upstream ID mapping means a misrouted partition
may map to a valid upstream partition on the wrong cluster — the broker cannot tell.
This makes the runtime's topology cache load-bearing: it must be correct, not merely
eventually-consistent. The gather side provides a second check: the Router composes
per-route PRODUCE responses and can verify that every partition in the original request
received exactly one acknowledgment. A partition appearing in zero or two responses
indicates a topology inconsistency. This is a higher correctness bar than a monolithic
Router, where each author builds their own partition mapping — but it is paid once
in the runtime rather than reimplemented (and potentially misimplemented) in every
Router.

Since this filter is already traversing the request structure to strip partitions,
identifier rewriting (PIDs, fetch session IDs) at the same point is trivial additional
work. This is where the identifier mapping filters
(see _Protocol identifier mapping_ below) naturally integrate.

For single-route topologies (principal-aware routing, simple proxy), the filter is a
no-op — all partitions belong to the one route.

#### Predicate evaluation

Route selection predicates (e.g. "this route handles topics matching `orders.*`") are
per-route concerns. They can be implemented as per-route filters that the Router consults
during scatter, or as configuration on the route that the Router reads.

#### SASL initiator / upstream authentication

Per-route concern, implemented as a per-route filter — same as PR #70.

### Per-route filter chain composition

The existing model establishes a pattern of _implicit filters_: `BrokerAddressFilter` and
`ApiVersionsIntersectFilter` are inserted by the runtime on every route, invisible to the
user. They handle protocol-level concerns that every proxy path needs.

Multi-cluster routing introduces additional per-route protocol concerns (node ID mapping,
partition filtering, identifier mapping). Rather than hiding these behind runtime magic,
the Router explicitly declares the per-route filter chain via `RouterFactory.filtersRequiredForRoute()`.
The default method returns the baseline filters (broker address rewriting, API version
intersection, node ID mapping). A Router that needs additional protocol filters overrides
the method and declares the full chain.

The runtime ships reference implementations of common protocol filters that the Router
can include in its declared chain. A Router author who needs different behaviour writes
their own filter using the same `Filter` API. This keeps one processing model (filters
on a chain) for all per-route protocol concerns, with the Router in explicit control of
what's on the chain.

#### Virtual node ID mapping (baseline default)

Same formula as PR #70: `V = id + S × t`, where `V` is the virtual node ID, `t` is the
target-cluster node ID, `S` is the number of routes, and `id` is the route's identifier.

The runtime's default implementation is a per-route filter that rewrites node IDs in
responses (METADATA, PRODUCE, FIND_COORDINATOR, DESCRIBE_CLUSTER) from upstream to
downstream, and in requests from downstream to upstream. The Router works entirely in
downstream node IDs — it never translates.

For single-route (1:1) configurations, the identity mapping `V = t` applies with zero overhead.
This is the existing model, confirming that 1:1 is a degenerate case of the general formula.

The nested dispatch composition (`V_outer = k + S_outer × V_inner`) described in
_Routers compose into a DAG_ above applies at each layer of the graph — it is a
property of the runtime's node ID management, not of the Router.

#### Broker address rewriting

`BrokerAddressFilter`, already implicit, already per-route. No change needed.

#### API version intersection

`ApiVersionsIntersectFilter`, already implicit, already per-route. No change needed.

#### Protocol identifier mapping (PIDs, fetch session IDs, topic UUIDs)

The Kafka protocol uses several broker-assigned identifiers beyond node IDs:
Producer IDs (PIDs), fetch session IDs, topic UUIDs, delegation token IDs,
client instance IDs. In a multi-cluster topology, each route's upstream cluster
assigns its own values for these identifiers, creating the same collision problem
that the node ID mapping solves for broker addressing.

These are handled as per-route filters — the same pattern as `BrokerAddressFilter`.
Each filter operates on a single route's traffic with no cross-route knowledge — it maps
between the downstream identifier and the upstream identifier for its route. Each route
has its own bidirectional mapping (downstream ↔ upstream); there is no global identifier
space across routes.

The runtime ships **reference implementations** of these filters that cover the common
cases. A Router author who needs a different mapping strategy can supply their own via
the `RouterFactory`.

Like the `PartitionRoutingFilter`, these filters operate wholly in the downstream ID
space and consult per-route mapping state maintained by the runtime (exposed through
`FilterContext`). The runtime builds and updates these mappings as identifier-carrying
responses flow through each route's filter chain.

For **establishment RPCs** (`INIT_PRODUCER_ID`, initial FETCH, etc.), the identifier
appears as a top-level response field. The filter records the per-route upstream value
and establishes the downstream ↔ upstream mapping. The Router's scatter-gather selects
which route's establishment response becomes the downstream value.

For **data-path RPCs** (PRODUCE, FETCH), identifier rewriting integrates naturally
with the `PartitionRoutingFilter` described above. That filter is already traversing
the request structure to strip partitions that don't belong to its route. Rewriting
PIDs, fetch session IDs, and other identifiers at the same point is trivial
additional work — the hard part (the protocol traversal) is already done. This
directly addresses the
[concern raised in PR #70's review](https://github.com/kroxylicious/design/pull/70#discussion_r3370514842)
that identifier rewriting is trivial once you're inside the request structure.
The difference is that the traversal and the rewriting both live in a filter
shipped once, not reimplemented in every Router.

This is distinct from the `associate()` API explored in
[Sam's identifier mapping gist](https://gist.github.com/SamBarker/156030ef86911f82a2fdd3d2ebc4676b).
That approach had the Router explicitly establishing mappings via an API call.
Here, the filters manage the per-route mapping state — the Router never calls an
association method and never knows about identifier translation.

#### Chain assembly

The per-route filter chain is composed from two sources, in order:

1. **User-configured filters** — declared in the route's `filters` configuration
   (e.g. `TopicPrefixFilter`).
2. **Router-declared filters** — returned by `RouterFactory.filtersRequiredForRoute()`.
   The default returns the baseline (broker address rewriting, API version
   intersection, node ID mapping). A Router that needs protocol-level filters
   (partition routing, PID mapping) overrides the method and declares the full
   chain including the baseline.

The runtime ships reference implementations of common protocol filters
(`PartitionRoutingFilter`, PID mapping, fetch session mapping) that a Router
author can include in their `filtersRequiredForRoute()` return value. A Router author who
needs different behaviour writes their own filter — using the same `Filter` API,
the same processing model, the same chain position.

Per-route filters access runtime-maintained state — per-route topology, identifier
mappings — through a richer `FilterContext`. The runtime owns this state and updates
it as traffic flows through each route's chain. Filters consume it but do not build
or cache it independently. This keeps the source of truth in one place and avoids
filters diverging from the topology the Router's scatter-gather established.

### Plugin API

#### `Router`

```java
interface Router {

    CompletionStage<ScatterGatherResult> scatter(short apiVersion,
                                                  ApiKeys apiKey,
                                                  RequestHeaderData header,
                                                  ApiMessage request,
                                                  ScatterContext context);

    default void close() {}
}
```

`Router` is narrower than PR #70's version. The key difference is in _what_ it is
responsible for: only the scatter-gather decision, not protocol-level decomposition
or identifier translation.

**`scatter()`** is invoked for every request. The Router inspects the request, sends
sub-requests to routes via the `ScatterContext` (using `sendToRoute` for discovery
requests or `sendToNode` for broker-targeted requests), and returns a
`ScatterGatherResult` that describes how to compose the responses. For METADATA, this is
a genuine multi-route scatter. For a leader-directed PRODUCE, the Router sends to the
appropriate node. For union-topic scatters, the Router sends to multiple routes and
per-route filters handle decomposition and identifier translation.

**`close()`** releases per-connection resources, same as PR #70.

#### `ScatterContext`

```java
interface ScatterContext {

    Set<String> routes();

    CompletionStage<ResponseFrame> sendToRoute(String route,
                                                RequestHeaderData header,
                                                ApiMessage request);

    CompletionStage<ResponseFrame> sendToNode(String route,
                                               int nodeId,
                                               RequestHeaderData header,
                                               ApiMessage request);

    MetadataResponseData currentMetadata(String route);

    String sessionId();

    Subject authenticatedSubject();
}
```

`ScatterContext` provides two methods for sending requests to routes, depending on
whether the Router needs to target a specific broker.

**`routes()`** returns the set of route names available to this Router.

**`sendToRoute(route, header, request)`** sends a request to a route without targeting
a specific broker. The runtime selects an appropriate broker (bootstrap for initial
requests, round-robin or random thereafter). Use this for requests that can go to any
broker on the route — METADATA discovery, scatter-to-all-routes operations.

**`sendToNode(route, nodeId, header, request)`** sends a request to a specific downstream
node on a route. The `nodeId` is a downstream node ID that the Router obtained from a
previous response (e.g. a METADATA or FIND_COORDINATOR response). The runtime resolves it
to the target broker via the route's downstream ↔ upstream mapping. Use this for requests
that must target a specific broker.

The clearest motivation for `sendToNode` is **connection hopping** — delivering a request
to a different upstream node than the one the client's connection targets. Consider an
AZ-aware proxy: a client in AZ-A connects to the proxy and sends a FETCH to virtual
node 1 (the partition leader in AZ-B). Without `sendToNode`, the proxy must forward
the FETCH to virtual node 1's upstream broker — a cross-AZ call. With `sendToNode`,
the Router can redirect the FETCH to virtual node 2 (an in-sync replica in AZ-A)
by calling `sendToNode(route, node2, header, request)`. The message content is
unchanged — the IDs are consistent, the partition references are correct. The proxy
is purely changing _which connection carries the request_, not rewriting the request.

This is the irreducible thing routing adds over the existing filter model. A filter can
rewrite message content, but it cannot change which upstream connection the request
travels on — the connection is determined by which virtual node address the client
connected to. `sendToNode` decouples the dispatch decision from the connection.

The same mechanism serves transaction and group coordinators (where the Router must
target a specific broker discovered via FIND_COORDINATOR), but AZ-aware fetch is the
most concrete example: no protocol decomposition, no scatter-gather, just "send this
request to a different node than the one the client connected to."

> **Open question:** For leader-directed requests, the destination node ID is already
> present in the request header. It's unclear whether `sendToNode` adds value over
> `sendToRoute` with the runtime extracting the target from the request — doing so
> would avoid two competing sources of truth for the target node. `sendToNode` is
> clearly needed when the Router overrides the client's target (AZ-aware fetch) or
> when the request doesn't carry a destination node. This needs further investigation.

This is the same capability as PR #70's `sendRequestToNode(route, virtualNodeId, ...)`.
The difference is that `sendToRoute` exists alongside it for the common case where the
Router doesn't need to pick a broker, avoiding the need for `bootstrapNodeId()` as a
separate method.

When the Router scatters a METADATA request, it uses `sendToRoute` — any broker on each
route will do. The responses come back with downstream node IDs (rewritten by per-route
filters). For subsequent requests, the Router uses `sendToNode` — whether redirecting
to a local replica (AZ-aware fetch), targeting a coordinator (transactions), or forwarding
to the leader the client intended.

**`currentMetadata(route)`** returns the runtime's cached METADATA response for a route,
in downstream IDs. The runtime caches the most recent METADATA response that flowed
through each route's filter chain — the same data the runtime uses for its own node ID
mapping and broker address resolution. The Router can inspect it for topology decisions
(rack-aware replica selection, leader lookup, partition layout) without maintaining its
own METADATA cache. This avoids duplicating state the runtime already owns while keeping
the API surface thin — one method returning a protocol message type, with no
runtime-defined semantic wrapper around METADATA fields.

**`sessionId()`** and **`authenticatedSubject()`** — same as PR #70.

#### `ScatterGatherResult`

```java
sealed interface ScatterGatherResult {
    record Completed(ApiMessage response) implements ScatterGatherResult {}
    record CompletedNoResponse() implements ScatterGatherResult {}
    record Disconnect() implements ScatterGatherResult {}
}
```

Same semantics as PR #70's `RouterResult` — the Router returns a composed response,
signals fire-and-forget, or requests disconnection.

#### `RouterFactory`

```java
interface RouterFactory<C, I> {
    I initialize(RouterFactoryContext context, C config);

    Router createRouter(RouterFactoryContext context, I initializationData);

    default List<FilterDefinition> filtersRequiredForRoute(String route, I initializationData) {
        return List.of(BrokerAddressFilter.definition(),
                       ApiVersionsIntersectFilter.definition(),
                       NodeIdMappingFilter.definition());
    }

    void close(I initializationData);
}
```

> **Sketch — exact API shape TBD.** The `filtersRequiredForRoute` method and `FilterDefinition`
> type are illustrative. The important design point is the default method providing
> the baseline chain.

The factory lifecycle is the same as PR #70. The addition is `filtersRequiredForRoute()`: the
Router declares which per-route filters each route needs. The default implementation
returns the baseline filters that every route requires (broker address rewriting,
API version intersection, node ID mapping). A Router author who needs additional
protocol filters — partition routing, PID mapping — overrides the method and
declares the full chain:

```java
List<FilterDefinition> filtersRequiredForRoute(String route, I initData) {
    return List.of(PartitionRoutingFilter.definition(),
                   PidMappingFilter.definition(),
                   BrokerAddressFilter.definition(),
                   ApiVersionsIntersectFilter.definition(),
                   NodeIdMappingFilter.definition());
}
```

There is no "override" or "extend" mechanism — the Router either accepts the default
or replaces it entirely. The default is visible in the interface; no hidden behaviour.
If a Router author forgets a baseline filter like `BrokerAddressFilter`, the proxy
fails obviously.

The per-route filter chain is composed from two sources, in order:

1. **User-configured filters** — declared in the route's `filters` configuration
   (e.g. `TopicPrefixFilter`).
2. **Router-declared filters** — returned by `filtersRequiredForRoute()`. Defaults to the
   baseline; overridden when the Router needs protocol-level filters beyond the
   baseline.

### Configuration

The configuration structure matches PR #70:

```yaml
clusterDefinitions:
  - name: cluster-a
    bootstrapServers: kafka-a:9092
  - name: cluster-b
    bootstrapServers: kafka-b:9092

routerDefinitions:
  - name: my-router
    type: UnionClusterRouter
    config:
      # Router-level config: scatter-gather strategy
      ...
    routes:
      - name: a
        id: 0
        filters:
          # Per-route user filters (e.g. topic prefix rewriting)
          - type: TopicPrefixFilter
            config:
              prefix: "a."
        target:
          cluster: cluster-a
      - name: b
        id: 1
        filters:
          - type: TopicPrefixFilter
            config:
              prefix: "b."
        target:
          cluster: cluster-b

virtualClusters:
  - name: my-vc
    target:
      router: my-router
    gateways: [...]
    filters:
      - type: AuditFilter
```

The difference from PR #70 is not in the configuration shape but in where the
responsibilities lie. Topic rewriting is configured as a per-route filter, not as
logic within the Router's `scatter()`. The Router's `config` property contains
only scatter-gather strategy (e.g. "scatter METADATA to all routes and merge").

Because a route's target can be a router, not just a cluster, routers compose into
a DAG. Adding AZ-aware fetch to the union cluster above is a configuration change:

```yaml
clusterDefinitions:
  - name: cluster-a
    bootstrapServers: kafka-a:9092
  - name: cluster-b
    bootstrapServers: kafka-b:9092

routerDefinitions:
  - name: az-fetch-a
    type: AzAwareFetchRouter
    config:
      localAz: "az-a"
    routes:
      - name: main
        id: 0
        target:
          cluster: cluster-a

  - name: az-fetch-b
    type: AzAwareFetchRouter
    config:
      localAz: "az-a"
    routes:
      - name: main
        id: 0
        target:
          cluster: cluster-b

  - name: union-router
    type: UnionClusterRouter
    config: { ... }
    routes:
      - name: a
        id: 0
        filters:
          - type: TopicPrefixFilter
            config:
              prefix: "a."
        target:
          router: az-fetch-a      # route targets a router, not a cluster
      - name: b
        id: 1
        filters:
          - type: TopicPrefixFilter
            config:
              prefix: "b."
        target:
          router: az-fetch-b

virtualClusters:
  - name: my-vc
    target:
      router: union-router
    gateways: [...]
    filters:
      - type: AuditFilter
```

The union router's scatter-gather logic is unchanged — it doesn't know or care that
its routes target AZ-aware routers rather than clusters. The AZ routers don't know
they sit behind a union router. Each router is a self-contained concern.

#### Two extension points

Routing introduces two plugin extension points, compared to filtering's one:

1. **Router-level** (`routerDefinitions[].type` + `config`): the scatter-gather strategy.
   Which routes get which requests, how to compose responses.

2. **Per-route** (`routes[].filters`): transformation and predicates within a single route.
   Topic name rewriting, upstream authentication, request filtering.

This has CRD implications: a routing CRD needs two `configTemplate` slots
(one for the router plugin, one for per-route filters), unlike filtering which has one.

#### Virtual cluster changes

Same as PR #70: the existing inline `targetCluster` is deprecated in favour of a
`target` property referencing a named cluster or router.

### Runtime

#### Request dispatch

The runtime deserialises every incoming request and invokes `Router.scatter()`.
There is one dispatch path, not multiple modes. The Router decides which routes
receive the request and returns a `ScatterGatherResult` describing how to compose
the responses.

For METADATA, the Router typically scatters to all routes and merges the responses.
For a leader-directed PRODUCE or FETCH, the Router sends to one or more routes based
on the request's target node or its own scatter-gather strategy. In all cases,
per-route filter chains handle protocol-level concerns — partition stripping,
identifier translation, topic rewriting — not the Router.

This uniform path means the Router is always in the loop. The degenerate case —
a single-route topology where every `scatter()` sends to the one route — is one
method call on the event loop thread per request, not a performance concern.
If profiling later reveals that always invoking the Router is too costly for
specific API keys or topologies, optimisations (topology-directed forwarding,
opaque frame bypass) can be introduced as a runtime concern without changing the
Router API. See _Rejected alternatives_ below.

#### Threading model

Same as PR #70: one `Router` instance per client connection, single Netty event loop thread,
no synchronisation needed within an instance.

#### Node ID mapping, correlation ID management, response ordering

Same as PR #70 — these are runtime concerns independent of the Router's API surface.

#### Flow control

Same as PR #70 — Netty auto-read backpressure. The Router's `scatter()` determines
latency. For simple single-route forwarding, the Router's `scatter()` is trivial and
adds negligible latency over the existing non-routed pipeline.

### Metrics

Same metric dimensions as PR #70 (route name, API key, error type) with the same
cardinality analysis. Since all requests flow through `scatter()`, there is no
routing-mode tag — the Router is always in the path.

## Contrast with PR #70

The central difference: what lives in the Router's hot path.

| Concern | PR #70 (`onRequest()`) | This alternative |
|---------|----------------------|-----------------|
| METADATA composition | Router | Router (`scatter()`) |
| Topic name rewriting | Router | Per-route user filter |
| Node ID mapping | Runtime | Per-route filter (Router-declared, baseline default) |
| Broker address rewriting | Runtime | Per-route filter (Router-declared, baseline default) |
| API version intersection | Runtime | Per-route filter (Router-declared, baseline default) |
| PID / fetch session mapping | Router | Per-route filter (Router-declared, reference impl) |
| PRODUCE/FETCH decomposition | Router | Per-route filter (Router-declared, reference impl) |
| PRODUCE/FETCH routing | Router | Router (`scatter()`) + per-route filter |
| LIST_GROUPS, etc. merging | Router | Router (`scatter()`) |
| Predicate evaluation | Router | Per-route filter / Router config |

PR #70's `onRequest()` is called for every dynamically-routed API key and is responsible
for both the routing decision and the protocol-level decomposition of requests. This
alternative's `scatter()` is also called for every request, but its job is limited to the
scatter decision ("which routes"). Per-route filters — declared by the Router via
`filtersRequiredForRoute()` — handle request decomposition (stripping non-matching partitions)
and identifier translation.

### What this buys

**Smaller default plugin surface.** The Router's `scatter()` is called for every request,
but the Router's job is the thin scatter-gather concern: which routes, and how to merge.
The baseline `filtersRequiredForRoute()` default handles the common case — a Router author who
doesn't override it gets broker address rewriting, API version intersection, and node ID
mapping for free. The runtime ships reference implementations of protocol filters
(partition routing, PID mapping) that the Router can add to its declared chain. When
the references don't fit, the Router author writes their own filter using the same
`Filter` API.

**Consistency with the filter model.** Per-route transformations are filters, same as
VC-level transformations. The mental model is the same: filters transform traffic within
a single path; the Router coordinates across paths.

**Composability.** Topic rewriting is a filter — it can be developed, tested, and configured
independently of the Router. Different routes can use different rewriting strategies.
The same filter can be used in non-routed configurations for simple topic renaming.

**The 1:1 case is the existing model.** A virtual cluster with one route, no Router plugin,
and identity node mapping is exactly today's pipeline. No new code path is introduced for
the common case.

### What this costs

**Protocol evolution affects the reference filters.** The runtime's reference
implementations of protocol filters (PID mapping, partition filtering, etc.) must
understand the protocol fields they operate on. When a new Kafka RPC introduces a new
identifier type or changes how it carries identifiers, the reference filters need updating.

This coupling is mitigated in two ways. First, a Router author who needs to handle a
new protocol concern before the runtime catches up can supply their own filter — they
are not blocked on a runtime release. Second, the existing implicit filters
(`BrokerAddressFilter`, `ApiVersionsIntersectFilter`) already accept this trade-off —
they are protocol-aware runtime code that every path through the proxy needs.
The reference protocol filters are the same class of concern.

**Every request deserialises and invokes `scatter()`.** Since the Router is always in
the path, every request pays the cost of deserialisation and a `scatter()` call.
For single-route topologies this is overhead that the runtime could theoretically
short-circuit. We choose the simpler uniform path and defer optimisation to when
profiling provides evidence. See _Rejected alternatives_ below.

## Affected/not affected projects

Same as PR #70, with the `Router` interface in `kroxylicious-api` being smaller:
- `kroxylicious-api` — `Router`, `RouterFactory`, `RouterFactoryContext`, `ScatterContext`, `ScatterGatherResult`.
- `kroxylicious-runtime` — routing engine, configuration model, graph validation, node ID mapping, response sequencing, implicit filters, metrics.
- `kroxylicious-bom` — version management.
- Not affected: existing filters, KMS, authoriser API.
- The Kubernetes operator will need a separate update to support router configuration in CRDs (with two extension points rather than one).

## Compatibility

Same as PR #70:
- No impact on the `Filter` API. All existing filters continue to work.
- The inline `targetCluster` property is deprecated but still supported.
- New properties (`clusterDefinitions`, `routerDefinitions`, `target`) are purely additive.
- The 1:1 case (no Router, single cluster target) degenerates to today's pipeline with no behavioural change.

## Rejected alternatives

**Broader `onRequest()` (PR #70's approach).** PR #70 invokes the Router for every
dynamically-routed API key, making the Router responsible for forwarding PRODUCE, FETCH,
and other leader-directed requests. This works, but it pushes protocol-level concerns
(node ID translation, topic rewriting, API version negotiation) into the Router that the
runtime already handles via implicit filters. The result is a larger plugin surface and
duplicated protocol knowledge. See the contrast table above.

**Router as a filter.** The existing `Filter` API could theoretically be extended to support
multi-cluster routing — a filter could send out-of-band requests to additional clusters.
But this would overload the filter abstraction: a filter that creates and manages
connections to multiple upstream clusters, maintains a merged topology, and composes
responses is no longer meaningfully a filter. The scatter-gather coordination — knowing
which routes it scattered to, and how to compose their responses — is a fundamentally
different concern that deserves its own abstraction. A Router is the name for that
abstraction.

**Runtime-managed implicit filter chain.** We considered a model where the runtime
decides which protocol filters to insert on each route — the Router declares what
capabilities it needs (e.g. "partition routing," "PID mapping") and the runtime inserts
the appropriate filters automatically. The Router could override this by supplying its
own filters. We rejected this because it introduces hidden behaviour: the Router author
doesn't see what's on the chain unless they look, and the "override" mechanism (extend?
replace? merge?) adds API complexity. The `filtersRequiredForRoute()` default method is
simpler — the baseline is visible in the interface, and replacing it is a straightforward
method override.

**Typed topology API on `ScatterContext`.** We considered exposing per-route topology
as a structured API (`RouteTopology` with methods like `leader()`, `rack()`,
`inSyncReplicas()`). This would simplify Router implementations that need topology
information but couples the `ScatterContext` to specific METADATA response fields. Each
new field the Router might need requires an API change. `currentMetadata()` — returning
the raw `MetadataResponseData` — is thinner: one method, no semantic wrapper, and the
Router extracts what it needs from the protocol message type directly. If Kafka adds new
METADATA fields, the Router gets them for free without an API change.

**Multi-mode request dispatch.** We considered a model where the Router declares which
API keys it wants `scatter()` called for, with the runtime forwarding everything else
using topology-directed or opaque-frame paths. This avoids deserialising and invoking the
Router for leader-directed requests in single-route topologies. We rejected this as
premature optimisation: it introduces three forked dispatch paths and a declaration
mechanism before profiling has shown that always calling `scatter()` is a bottleneck.
The uniform single-path model is simpler to reason about and to implement. If profiling
later reveals that the Router invocation is too costly for specific API keys or topologies,
topology-directed forwarding and opaque-frame bypass can be introduced as runtime-internal
optimisations without changing the Router plugin API.
