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
SASL initiator for upstream authentication) followed by runtime-managed implicit filters
(node ID mapping, broker address rewriting, API version intersection).

The Router sits at the fork point. Its job is exclusively:
- **Scatter**: which routes receive this request?
- **Gather**: how to compose the responses from those routes into a single client response?

Everything else stays where it already is.

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
and composing their responses.

For **METADATA**, the Router scatters the request to some or all routes, receives per-route
responses (each already rewritten into the route's namespace by implicit filters), and
merges them: combining broker lists, merging topic metadata, deduplicating.
This establishes the _topology_ — the multi-cluster namespace as seen by the client.

For **leader-directed API keys** (PRODUCE, FETCH, LIST_OFFSETS, etc.), the topology
established by METADATA already determines routing. A PRODUCE request targets a specific
virtual node ID that belongs to a specific route — the runtime can forward it to the correct
route without involving the Router. The node ID namespace, established through the Router's
METADATA scatter-gather, implicitly encodes the routing decision for subsequent requests.

The Router is actively involved only for API keys where the scatter decision cannot be
derived from cached topology:
- **METADATA** itself (the topology-establishing operation).
- **API keys with cross-cluster semantics** that the Router's implementation needs to handle
  specially (e.g. a union-cluster Router might need to scatter `LIST_GROUPS` across all routes
  and merge the results).

This is a significantly narrower surface than PR #70's `onRequest()`, which is invoked
for every dynamically-routed API key.

#### Topology declaration

The Router declares which routes it manages and their scatter-gather behaviour:
which routes participate in metadata discovery, how responses are composed, and which
additional API keys (beyond METADATA) require Router-level scatter-gather.

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

#### Predicate evaluation

Route selection predicates (e.g. "this route handles topics matching `orders.*`") are
per-route concerns. They can be implemented as per-route filters that the Router consults
during scatter, or as configuration on the route that the Router reads.

#### SASL initiator / upstream authentication

Per-route concern, implemented as a per-route filter — same as PR #70.

### What the runtime handles (implicit filters)

These are invisible to both the Router plugin author and the user.
They are inserted by the runtime on each route's filter chain, downstream of user filters.

#### Virtual node ID mapping

Same formula as PR #70: `V = id + S × t`, where `V` is the virtual node ID, `t` is the
target-cluster node ID, `S` is the number of routes, and `id` is the route's identifier.

Implemented as a per-route implicit filter that rewrites node IDs in responses
(METADATA, PRODUCE, FIND_COORDINATOR, DESCRIBE_CLUSTER) from real to virtual,
and in requests from virtual to real. The Router works entirely in virtual node IDs —
it never translates.

For single-route (1:1) configurations, the identity mapping `V = t` applies with zero overhead.
This is the existing model, confirming that 1:1 is a degenerate case of the general formula.

The nested dispatch composition (`V_outer = k + S_outer × V_inner`) described in PR #70
applies unchanged — it is a property of the runtime's node ID management, not of the Router.

#### Broker address rewriting

`BrokerAddressFilter`, already implicit, already per-route. No change needed.

#### API version intersection

`ApiVersionsIntersectFilter`, already implicit, already per-route. No change needed.

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

`Router` is narrower than PR #70's version. The key difference is in _when_ it is invoked:
the Router's `scatter()` is only called for API keys that require cross-route coordination.
Leader-directed requests (PRODUCE, FETCH, etc.) are forwarded by the runtime using the
cached topology without invoking the Router.

**`scatter()`** is invoked for requests that require the Router's scatter-gather logic.
The Router inspects the request, sends sub-requests to routes via the `ScatterContext`,
and returns a `ScatterGatherResult` that describes how to compose the responses.

**`close()`** releases per-connection resources, same as PR #70.

#### `ScatterContext`

```java
interface ScatterContext {

    Set<String> routes();

    CompletionStage<ResponseFrame> sendToRoute(String route,
                                                RequestHeaderData header,
                                                ApiMessage request);

    String sessionId();

    Subject authenticatedSubject();
}
```

`ScatterContext` is simpler than PR #70's `RouterContext`:

**`routes()`** returns the set of route names available to this Router.

**`sendToRoute(route, header, request)`** sends a request to a route. Unlike PR #70's
`sendRequestToNode()`, this does not require a virtual node ID — the runtime selects
an appropriate broker on the route (bootstrap for initial requests, or the appropriate
node once topology is established). The route's filter chain handles all per-route
transformations before the request reaches the upstream cluster.

The Router does not need to address specific brokers because it is not doing the
protocol-level work that requires broker targeting. When the Router scatters a METADATA
request, it sends to any broker on each route — the standard Kafka client bootstrap
behaviour. The responses come back with virtual node IDs (rewritten by implicit filters),
and the Router merges them.

For leader-directed requests that the runtime forwards without involving the Router,
the runtime uses the virtual node ID from the request to determine both the route and
the target broker.

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

    void close(I initializationData);
}
```

Same as PR #70 — the factory lifecycle is independent of the Router's API surface.

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
logic within the Router's `onRequest()`. The Router's `config` property contains
only scatter-gather strategy (e.g. "scatter METADATA to all routes and merge").

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

The runtime dispatches incoming requests in three modes:

1. **Router scatter-gather**: For API keys the Router has declared interest in
   (at minimum METADATA), the runtime deserialises the request and invokes `Router.scatter()`.

2. **Topology-directed forwarding**: For leader-directed API keys (PRODUCE, FETCH,
   LIST_OFFSETS, OFFSET_FETCH, etc.), the runtime uses the virtual node ID in the request
   to determine the route and target broker. No Router involvement needed — the topology
   established by the Router's METADATA scatter-gather implicitly encodes the routing
   decision. The request is forwarded through the route's filter chain.

3. **Static forwarding**: For API keys that can be forwarded as opaque frames
   (as declared by the Router or determined by the runtime), bypass deserialisation
   entirely.

This means the Router's `scatter()` method is invoked for a small subset of API keys.
Most traffic (PRODUCE, FETCH — the data path) flows through the route filter chains
without Router involvement, using the topology the Router established.

#### Threading model

Same as PR #70: one `Router` instance per client connection, single Netty event loop thread,
no synchronisation needed within an instance.

#### Node ID mapping, correlation ID management, response ordering

Same as PR #70 — these are runtime concerns independent of the Router's API surface.

#### Flow control

Same as PR #70 — Netty auto-read backpressure. The Router's `scatter()` determines
latency for scatter-gather operations. Topology-directed forwarding has the same latency
characteristics as the existing non-routed pipeline.

### Metrics

Same metric dimensions as PR #70 (route name, API key, error type) with the same
cardinality analysis. The routing mode tag now has three values
(scatter-gather, topology-directed, static) rather than two (static, dynamic),
but cardinality remains bounded.

## Contrast with PR #70

The central difference: what lives in the Router's hot path.

| Concern | PR #70 (`onRequest()`) | This alternative |
|---------|----------------------|-----------------|
| METADATA composition | Router | Router (`scatter()`) |
| Topic name rewriting | Router | Per-route user filter |
| Node ID mapping | Runtime | Runtime implicit filter |
| Broker address rewriting | Runtime | Runtime implicit filter |
| API version intersection | Runtime | Runtime implicit filter |
| PRODUCE/FETCH routing | Router | Runtime (topology-directed) |
| LIST_GROUPS, etc. merging | Router | Router (`scatter()`) |
| Predicate evaluation | Router | Per-route filter / Router config |

PR #70's `onRequest()` is called for every dynamically-routed API key. This alternative's
`scatter()` is called only for API keys requiring cross-route coordination. The data path
(PRODUCE, FETCH) bypasses the Router entirely.

### What this buys

**Smaller plugin surface.** A Router author writes scatter-gather logic for METADATA and
whatever additional API keys their use case requires. They don't write PRODUCE/FETCH
forwarding, topic rewriting, or node ID management.

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

**The runtime is more involved in request dispatch.** Topology-directed forwarding requires
the runtime to inspect the virtual node ID, determine the route, and forward through the
correct filter chain. PR #70's approach is arguably simpler from the runtime's perspective:
the Router handles everything, and the runtime just executes what the Router tells it.

**Some Router implementations may want the full request.** A Router that needs to inspect
PRODUCE requests (e.g. for record-batch-level routing) would need to declare interest in
PRODUCE as a scatter-gather API key, pulling it back into the Router's hot path. The API
must support this — the set of scatter-gather API keys should be Router-declared,
not hardcoded.

## Affected/not affected projects

Same as PR #70, with the `Router` interface in `kroxylicious-api` being smaller:
- `kroxylicious-api` — `Router`, `RouterFactory`, `RouterFactoryContext`, `ScatterContext`, `ScatterGatherResult`.
- `kroxylicious-runtime` — routing engine, topology-directed forwarding, configuration model, graph validation, node ID mapping, response sequencing, metrics.
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

**No distinction between scatter-gather and topology-directed requests.** We considered
a model where the Router handles every request (as in PR #70) but delegates most to a
default forwarding strategy. This adds indirection without benefit — the runtime already
knows how to forward a request to a virtual node ID. Adding a Router method that says
"forward this the normal way" is strictly worse than not calling the Router at all.
