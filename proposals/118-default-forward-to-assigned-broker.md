# 118 - Default forwarding to the assigned virtual node

Revise the `Router` plugin API (proposal [070](./070-routing-api.md)) so that a request on a
node-bound connection is, by default, forwarded to the virtual node that endpoint already represents,
and a router declares only the API keys it needs to **intercept**. Replaces `staticRoutes()`.

Addresses the gaps raised in
[kroxylicious#4177](https://github.com/kroxylicious/kroxylicious/issues/4177).

## Current situation

Proposal [070](./070-routing-api.md) introduced the `Router` plugin with `staticRoutes()`:

```java
interface Router {
    CompletionStage<RouterResponse> onRequest(short apiVersion, ApiKeys apiKey,
            RequestHeaderData header, ApiMessage request, RouterContext context);

    default Map<ApiKeys, String> staticRoutes() { return Map.of(); }
}
```

`staticRoutes()` maps `ApiKeys -> route name`; those keys are forwarded as opaque frames to the
named route, bypassing `onRequest()`. Every other key is dynamically routed. In the current
implementation `onRequest()` is not yet wired, so an API key absent from `staticRoutes()` throws.

## Motivation

Three problems with `staticRoutes()`, drawn from
[kroxylicious#4177](https://github.com/kroxylicious/kroxylicious/issues/4177):

1. **The useful default was lost.** Before routing, every upstream broker was represented by its own
   virtual endpoint and traffic to that endpoint _always_ flowed to the broker it represents
   (`b0.proxy -> b0.cluster0`, `b10000.proxy -> b0.cluster1`). `staticRoutes()` makes a router opt
   _into_ forwarding by listing API keys, instead of inheriting that default.

2. **Scope mismatch.** `staticRoutes()` is a fixed `ApiKeys -> route name` map, but `Router`
   instances are per-connection. A route name cannot express "forward to the implied target virtual
   node" — that target (`virtualNode()`) is derived initially from the connection.

3. **No router can populate the map usefully.** For a pass-through router it means enumerating ~80
   keys; for client-id, subject, or topic routers it is empty or near-empty, because nothing can be
   pinned to a route purely by API key. The map either lists everything (bad DX) or returns `{}`.

## Proposal

Invert the model: the runtime forwards a bound connection's traffic to its assigned virtual node by
default; a router declares only what it must **intercept**.

### Route binding is established when the connection is created

A connection reaches the proxy on a specific endpoint — a bootstrap endpoint, or a node endpoint for
one `(route, virtual node)`. The runtime binds the connection to that route and builds its upstream
filter chain at connection-creation time, exactly as the non-router proxy already builds a
per-connection pipeline. Three consequences:

* A bound (node-endpoint) connection's forward target is unambiguous: it already knows its
  `(route, virtual node)` and filter chain, so `shouldIntercept == false` simply forwards there — no
  per-request route recovery.
* "Derived initially from the connection" is deliberate: routers compose as a DAG, and each router in
  the DAG sees its own virtual node id mapping. Router A may see a request destined for
  virtualNodeId 2 while Router B sees the same request destined for virtualNodeId 0. A router reads
  `ctx.virtualNode()` to learn which virtual node the request is associated with *at its own position
  in the DAG*; it is not a single global identity. Nor is a virtual node a physical broker: the 1:1
  mapping the runtime happens to use today is not something the SPI promises, and future topologies
  need not preserve it.
* This does **not** require one route per cluster. Two routes fronting the same cluster are two
  distinct endpoints; a connection's route is fixed by the endpoint it arrived on, not by decoding
  the request. The only thing out of scope is a single endpoint representing *several* routes at once
  (070's shared node-id mapping, opt-in via `RouterFactoryContext.allowSharedClusterTargets()`),
  which would require per-request decomposition.

### Bootstrap and node endpoints are a structural distinction

Kafka makes no protocol distinction between a bootstrap broker and a data broker, but the proxy must,
because the endpoint a connection arrived on is the only signal for whether a default destination
exists. That makes the distinction a structural property the SPI depends on, not an implementation
convenience, and it should be visible in the API:

* **bootstrap endpoint** → connection is _unbound_: `RouterContext.virtualNode()` is empty, there is
  no default destination, so the router must participate.
* **node endpoint** → connection is _bound_ to one `(route, virtual node)`: the default destination
  is that virtual node, so the router need not be consulted at all.

### The SPI

```java
interface Router {

    /**
     * Whether the router must be invoked for this request. When false the runtime forwards the
     * frame to the connection's assigned virtual node (virtualNode()) without calling onRequest().
     * Default: intercept only when there is no assigned virtual node (bootstrap connections).
     */
    default boolean shouldIntercept(ApiKeys apiKey, short apiVersion, RouterContext ctx) {
        return ctx.virtualNode().isEmpty();
    }

    /** Called only when shouldIntercept() is true. The router chooses the destination(s). */
    CompletionStage<RouterResponse> onRequest(short apiVersion, ApiKeys apiKey,
            RequestHeaderData header, ApiMessage request, RouterContext ctx);

    default void close() {}
}
```

`apiVersion` is part of the gate so a router can intercept only the version ranges it cares about,
and so the gate composes directly with `DecodePredicate.shouldDecodeRequest(apiKey, apiVersion)`.

The gate is a `boolean` rather than a richer action type. A `sealed RouteAction` (forward-to-implicit-node,
intercept, forward-to-named-node, multicast) was considered and rejected as YAGNI: the boolean is
sufficient for every router shape below, and it keeps symmetry with the filter API's `shouldHandle*`
predicates. Richer actions can be introduced when a use case demands them.

`onRequest` keeps 070's signature unchanged: an intercepted request is decoded and handed to the
router, and responses fetched via `sendRequest` return decoded (`CompletionStage<ApiMessage>`), as
070 specifies. This proposal changes only the gate.

**Deferred: request decode depth on the interception path.** A router that intercepts but only needs
the header (client-id, subject) shouldn't force a full body decode. That optimisation is real but
separable: it optimises what happens *after* interception and has no bearing on the default
destination, so it is left to a follow-on proposal. The gate already delivers the big win by
itself — non-intercepted keys are never decoded at all (see the `DecodePredicate` wiring below).

### Three request shapes (one `onRequest`)

Requests fall into three shapes; the two intercepted ones are both expressed through `onRequest` —
no extra methods:

| shape | gate | onRequest does | example |
|---|---|---|---|
| **pass-through** | `shouldIntercept == false` | _(not called; forward to bound virtual node)_ | — |
| **pinned** | `shouldIntercept == true` | send the whole request to one fixed route | `GetTelemetrySubscriptions` |
| **fan-out** | `shouldIntercept == true` | decompose, send to each route, recompose | `Metadata` |

Pinned is the degenerate case of fan-out where the decomposition yields a single `(route, request)`
entry; it needs no separate code path.

### What the runtime does

Per request:

```java
class RouteDispatchHandler extends ChannelDuplexHandler {

  @Override
  public void channelRead(ChannelHandlerContext ctx, Object msg) {
    RequestFrame frame = (RequestFrame) msg;
    ApiKeys apiKey = frame.apiKey();
    {
      if (router.shouldIntercept(apiKey, frame.apiVersion(), routerCtx)) {
        dispatchToRouter(apiKey, frame, routerCtx);   // decoded per 070; router picks destination via sendRequest
      } else {
        routerCtx.sendRequest(routerCtx.virtualNode(), frame.header(), frame.rawBody())
              .thenAccept(r -> routerCtx.respondWith(r).build());
      }
    }
  }
}
```

Because bound-ness is per connection and known at connection setup, the runtime builds a
per-connection `DecodePredicate` (070 already permits this — the predicate "can depend on which
back-end cluster they're connected to"):

```java
// Existing DelegatingDecodePredicate or new RouteAwareDelegatingDecodePredicate
class RouteAwareDelegatingDecodePredicate implements DecodePredicate {

  private final DecodePredicate filters;   // DecodePredicate.forFilters(...)
  private final Router router;
  private final RouterContext routerCtx;

  @Override
  public boolean shouldDecodeRequest(ApiKeys k, short v) {
    return filters.shouldDecodeRequest(k, v) || router.shouldIntercept(k, v, routerCtx);
  }

  // shouldDecodeResponse is unchanged: response decoding is governed by filters and the runtime's
  // node-id translation (kroxylicious#4257), neither of which this proposal touches.
}
```

The two predicates are deliberately distinct names for distinct questions: `shouldDecodeRequest` asks
whether the runtime must materialise the body, `shouldIntercept` asks whether the router must be
invoked. Interception implies decoding today, which is why the gate is OR'd in here, but the
follow-on decode-depth work will let an intercepting router opt out of the body decode — at which
point conflating the two names would be actively wrong.

On a bound connection a router that does not override `shouldIntercept` contributes **zero**
request-decode interest. Reducing what an *intercepted* request must decode is the follow-on
decode-depth work noted above.

### Examples

The four canonical routers form a ramp, and every one relies on the same default gate.

**Static** — front a single cluster. Never intercepts; bootstrap and node traffic both forward.

```java
class StaticRouter implements Router {
    public boolean shouldIntercept(ApiKeys k, short v, RouterContext ctx) { return false; } // single route, never
    public CompletionStage<RouterResponse> onRequest(...) { throw new AssertionError("unused"); }
}
```

**ClientId-based** — key is in the header; route chosen on the bootstrap connection.

```java
class ClientIdRouter implements Router {
    // Routing happens on the bootstrap connection (virtualNode() is empty): the client is routed to a
    // cluster and gets back a Metadata response describing that cluster's nodes. It then connects to
    // the nodes it needs, and those connections are already bound — virtualNode() is present, so they
    // need no routing at all and the client-id is never re-examined.
    public boolean shouldIntercept(ApiKeys k, short v, RouterContext ctx) { return ctx.virtualNode().isEmpty(); }
    public CompletionStage<RouterResponse> onRequest(short v, ApiKeys k, RequestHeaderData header,
                                                     ApiMessage request, RouterContext ctx) {
        // ctx.clientId() — or some other way: the router is connection-local, so it can capture the
        // client-id when it intercepts the ApiVersions request and carry it on the router object.
        String route = routeFor(ctx.clientId());
        return ctx.sendRequest(ctx.anyNode(route), header, request)
                  .thenApply(r -> ctx.respondWith(r).build());
    }
}
// Endpoint/identity consistency (client-id route == bound endpoint route) is a connection-scoped
// check; it belongs on the bound filter chain, NOT in onRequest — keeping it out preserves
// pass-through on bound connections.
```

**Subject-based** — key comes from context; auth is already terminated on the VC chain.

```java
class SubjectRouter implements Router {
    public boolean shouldIntercept(ApiKeys k, short v, RouterContext ctx) { return ctx.virtualNode().isEmpty(); }
    public CompletionStage<RouterResponse> onRequest(short v, ApiKeys k, RequestHeaderData header,
                                                     ApiMessage request, RouterContext ctx) {
        String route = routeForSubject(ctx.authenticatedSubject());  // set by SaslTerminator earlier
        return ctx.sendRequest(ctx.anyNode(route), header, request)
                  .thenApply(r -> ctx.respondWith(r).build());
    }
}
// API_VERSIONS + SASL are handled by VC filters before the router, so onRequest never sees anonymous.
```

**Topic-based** — key is in the body; fan-out for cluster-spanning APIs, pin for coordinator APIs.

```java
class TopicRouter implements Router {
    public boolean shouldIntercept(ApiKeys k, short v, RouterContext ctx) {
        return ctx.virtualNode().isEmpty() || spansClusters(k) || pinned(k); // METADATA…, FIND_COORDINATOR…
    }
    public CompletionStage<RouterResponse> onRequest(short v, ApiKeys k, RequestHeaderData header,
                                                     ApiMessage request, RouterContext ctx) {
        Map<String, ApiMessage> sub = decomposer(k).decompose(request, table, v); // 1 entry (pinned) or N
        var calls = sub.entrySet().stream()
            .map(e -> ctx.sendRequest(ctx.anyNode(e.getKey()), header, e.getValue())
                         .thenApply(r -> Map.entry(e.getKey(), r)))
            .toList();
        return allOf(calls).thenApply(responses ->
            ctx.respondWith(decomposer(k).recompose(responses, request, v)).build());
    }
}
// Traffic on a bound connection passes through; only cluster-spanning / coordinator APIs reach
// onRequest, where the router fans out with ctx.sendRequest (070 contract).
```

Subject-routing connection walk-through (`cluster0`: `c0b0`,`c0b1`; `cluster1`: `c1b0`,`c1b1`):

```
 Client                 Proxy / Router                   cluster0       cluster1
   |                         | virtualNode() empty (bootstrap)        c1b0 c1b1
   |  ApiVersions/SASL       |  handled by VC filters (not the router)
   |                         |==== subject "alice" -> cluster1 ====
   |--- Metadata ----------->|  intercepts (bootstrap): expose ONLY cluster1 nodes
   |<-- Metadata ------------|  (vID c1b0=1, c1b1=3 ; mapping V = id + S*t, S=2)
   |--- Produce (vID 1) ---->|  bound: shouldIntercept==false -> forward to virtualNode()==c1b0
   |--- Fetch  (vID 3) ----->|  bound: shouldIntercept==false -> forward to virtualNode()==c1b1
```

## Affected/not affected projects

- **kroxylicious (runtime):** affected. `staticRoutes()` removed; `Router` gains `shouldIntercept`;
  the dispatch path gains the bound/unbound gate; the `DecodePredicate` is built per connection and
  consults `shouldIntercept`. `onRequest` and `sendRequest` keep their 070 signatures.
- **Router plugin authors:** affected. The no-op default is "forward to the assigned virtual node," a
  safe and usually-correct starting point.
- **Filter API and existing filter configurations:** not affected.
- **Operator / CRDs:** not affected — SPI/runtime only.

A proof-of-concept of this design exists at
[kroxylicious#4510](https://github.com/kroxylicious/kroxylicious/pull/4510). It surfaced a
pre-existing defect on `main` — out-of-band requests issued by virtual-cluster filters or router
filters misbehave in combination with dynamic routing. That defect is independent of this proposal
and should be tracked and fixed separately, but it will be encountered by whoever implements this.

## Compatibility

Proposal [070](./070-routing-api.md) is not yet released, so `staticRoutes()` has no users to break;
this revises an in-flight API.

## Rejected alternatives

- **Keep `staticRoutes()`** — no router can populate it usefully and a route name can't name the
  represented virtual node (route ≠ node).
- **A `sealed RouteAction` return type instead of a `boolean`** — richer actions
  (forward-to-implicit-node, forward-to-named-node, multicast) would leave room for extension, but no
  current router shape needs them, and the boolean keeps the gate symmetric with the filter API's
  `shouldHandle*` predicates. Revisit when a use case arrives.
- **`RoutingMode` enum `{PASS_THROUGH, HEADER_ONLY, FULL_MESSAGE}`** — conflates destination with
  decode depth; `PASS_THROUGH` has no destination on bootstrap (so it needs the bound gate anyway).
  Decode depth is deferred to a follow-on proposal in any case.
- **`staticRoute(apiKey, ctx)` / `staticRouteForApiKey(apiKey)` returning a route** — a route is
  cluster-granular, so it can't name the specific represented virtual node that `sendRequest` (070)
  targets by node; loses leader affinity.

## Follow-on work (out of scope here)

- **Request decode depth on the interception path** — a declaration so a router that routes on the
  header (client-id, subject) doesn't force a body decode. Separable from the gate; deserves its own
  proposal, and is worth registering as an issue now even though it should wait for a concrete use
  case. Two caveats for whoever picks it up:
  - Progressive decoding is not obviously feasible against today's `RequestData`/`ResponseData`
    APIs. It would need the root object to retain a reference to the `ByteBuf` and decode
    sub-structs lazily on first access, which is a change to generated Kafka message classes rather
    than to the routing SPI.
  - Response-side laziness was considered and dropped: virtual node-id translation already decodes
    the node-reference-bearing responses, `Fetch` included, leaving too narrow a case to justify
    widening `sendRequest`.
