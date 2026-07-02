# 118 - Default forwarding to the assigned upstream broker

Revise the `Router` plugin API (proposal [070](./070-routing-api.md)) so that a request on a
broker-bound connection is, by default, forwarded to the broker that endpoint already represents,
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

1. **The useful default was lost.** Before routing, every broker was a virtual endpoint and traffic
   to that endpoint _always_ flowed to the upstream broker it represents (`b0.proxy -> b0.cluster0`,
   `b10000.proxy -> b0.cluster1`). `staticRoutes()` makes a router opt _into_ forwarding by listing
   API keys, instead of inheriting that default.

2. **Scope mismatch.** `staticRoutes()` is a fixed `ApiKeys -> route name` map, but `Router`
   instances are per-connection. A route name cannot express "forward to the broker _this connection_
   represents" — that target (`virtualNode()`) is only known per connection.

3. **No router can populate the map usefully.** For a pass-through router it means enumerating ~80
   keys; for client-id, subject, or topic routers it is empty or near-empty, because nothing can be
   pinned to a route purely by API key. The map either lists everything (bad DX) or returns `{}`.

## Proposal

Invert the model: the runtime forwards a bound connection's traffic to its assigned broker by
default; a router declares only what it must **intercept**.

### Route binding is established when the connection is created

A connection reaches the proxy on a specific endpoint — a bootstrap endpoint, or a broker endpoint
for one `(route, broker)`. The runtime binds the connection to that route and builds its upstream
filter chain at connection-creation time, exactly as the non-router proxy already builds a
per-connection pipeline. Two consequences:

* A bound (broker-endpoint) connection's forward target is unambiguous: it already knows its
  `(route, broker)` and filter chain, so `intercepts == false` simply forwards there — no per-request
  route recovery.
* This does **not** require one route per cluster. Two routes fronting the same cluster are two
  distinct endpoints; a connection's route is fixed by the endpoint it arrived on, not by decoding
  the request. The only thing out of scope is a single endpoint representing *several* routes at once
  (070's shared node-id mapping, opt-in via `RouterFactoryContext.allowSharedClusterTargets()`),
  which would require per-request decomposition.

### Control plane vs data plane

Kafka makes no protocol distinction between a bootstrap broker and a data broker. The router world
must, because the connection's endpoint is the only signal for whether a default broker exists:

* **bootstrap endpoint** → connection is _unbound_ (`RouterContext.virtualNode()` is empty) → the
  **control plane**: discovery, `METADATA`, coordinator lookup, the routing decisions.
* **broker endpoint** → connection is _bound_ to one `(route, broker)` → the **data plane**:
  data-plane traffic to a known broker.

### The SPI

```java
interface Router {

    /**
     * Whether the router must be invoked for this request. When false the runtime forwards the
     * frame to the connection's assigned broker (virtualNode()) without calling onRequest().
     * Default: intercept only when there is no assigned broker (bootstrap connections).
     */
    default boolean intercepts(ApiKeys apiKey, RouterContext ctx) {
        return ctx.virtualNode().isEmpty();
    }

    /** Called only when intercepts() is true. The router chooses the destination(s). */
    CompletionStage<RouterResponse> onRequest(short apiVersion, ApiKeys apiKey,
            RequestHeaderData header, ApiMessage request, RouterContext ctx);

    default void close() {}
}
```

`onRequest` keeps 070's signature unchanged: an intercepted request is decoded and handed to the
router, and responses fetched via `sendRequest` return decoded (`CompletionStage<ApiMessage>`), as
070 specifies. This proposal changes only the gate.

**Deferred: decode depth on the interception path.** A router that intercepts but only needs the
header (client-id, subject) shouldn't force a full body decode, and a relay shouldn't pay to decode
a response it never reads. Those optimisations (a `shouldDecodeRequest` declaration, lazy
request/response frames) are real but separable: they optimise what happens *after* interception and
have no bearing on the default destination. They are left to a follow-on proposal so this one stays
focused on the gate. The gate already delivers the big win by itself — non-intercepted keys are
never decoded at all (see the `DecodePredicate` wiring below).

### Three request shapes (one `onRequest`)

Requests fall into three shapes; the two intercepted ones are both expressed through `onRequest` —
no extra methods:

| shape | gate | onRequest does | example |
|---|---|---|---|
| **pass-through** | `intercepts == false` | _(not called; forward to bound broker)_ | — |
| **pinned** | `intercepts == true` | send the whole request to one fixed route | `GetTelemetrySubscriptions` |
| **fan-out** | `intercepts == true` | decompose, send to each route, recompose | `Metadata` |

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
      if (router.intercepts(apiKey, routerCtx)) {
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
    return filters.shouldDecodeRequest(k, v) || router.intercepts(k, routerCtx);
  }

  @Override
  public boolean shouldDecodeResponse(ApiKeys k, short v) {
    return filters.shouldDecodeResponse(k, v) || router.intercepts(k, routerCtx);
  }
}
```

On a bound (data-plane) connection a router that does not override `intercepts` contributes **zero**
decode interest, so those connections get the leanest possible decode profile. Reducing what an
*intercepted* request/response must decode is the follow-on decode-depth work noted above.

### Examples

The four canonical routers form a ramp, and every one relies on the same default gate.

**Static** — front a single cluster. Never intercepts; bootstrap and broker traffic both forward.

```java
class StaticRouter implements Router {
    public boolean intercepts(ApiKeys k, RouterContext ctx) { return false; } // single route, never
    public CompletionStage<RouterResponse> onRequest(...) { throw new AssertionError("unused"); }
}
```

**ClientId-based** — key is in the header; route chosen on the bootstrap connection.

```java
class ClientIdRouter implements Router {
    // on a bound connection, the client-id is already known and the route is fixed; no need to intercept.
    // dev can additional add `ApiVersionsRequestFilter` or decode ApiVersionRequest to validate clientId once in connection lifetime.
    public boolean intercepts(ApiKeys k, RouterContext ctx) { return ctx.virtualNode().isEmpty(); }
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
// data-plane pass-through.
```

**Subject-based** — key comes from context; auth is already terminated on the VC chain.

```java
class SubjectRouter implements Router {
    public boolean intercepts(ApiKeys k, RouterContext ctx) { return ctx.virtualNode().isEmpty(); }
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
    public boolean intercepts(ApiKeys k, RouterContext ctx) {
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
// Data-plane traffic on a broker connection passes through; only cluster-spanning / coordinator
// APIs reach onRequest, where the router fans out with ctx.sendRequest (070 contract).
```

Subject-routing connection walk-through (`cluster0`: `c0b0`,`c0b1`; `cluster1`: `c1b0`,`c1b1`):

```
 Client                 Proxy / Router                   cluster0       cluster1
   |                         | virtualNode() empty (bootstrap)        c1b0 c1b1
   |  ApiVersions/SASL       |  handled by VC filters (not the router)
   |                         |==== subject "alice" -> cluster1 ====
   |--- Metadata ----------->|  intercepts (bootstrap): expose ONLY cluster1 brokers
   |<-- Metadata ------------|  (vID c1b0=1, c1b1=3 ; mapping V = id + S*t, S=2)
   |--- Produce (vID 1) ---->|  bound: intercepts==false -> forward to virtualNode()==c1b0
   |--- Fetch  (vID 3) ----->|  bound: intercepts==false -> forward to virtualNode()==c1b1
```

## Affected/not affected projects

- **kroxylicious (runtime):** affected. `staticRoutes()` removed; `Router` gains `intercepts`; the
  dispatch path gains the bound/unbound gate; the `DecodePredicate` is built per connection and
  consults `intercepts`. `onRequest` and `sendRequest` keep their 070 signatures.
- **Router plugin authors:** affected. The no-op default is "forward to the assigned broker," a safe
  and usually-correct starting point.
- **Filter API and existing filter configurations:** not affected.
- **Operator / CRDs:** not affected — SPI/runtime only.

## Compatibility

Proposal [070](./070-routing-api.md) is not yet released, so `staticRoutes()` has no users to break;
this revises an in-flight API. The `routingMode` metric (`static`/`dynamic`) is preserved:
`intercepts == false` is reported as `static`, `intercepts == true` as `dynamic`.

## Rejected alternatives

- **Keep `staticRoutes()`** — no router can populate it usefully and a route name can't name the
  represented broker (route ≠ node).
- **`RoutingMode` enum `{PASS_THROUGH, HEADER_ONLY, FULL_MESSAGE}`** — conflates destination with
  decode depth; `PASS_THROUGH` has no destination on bootstrap (so it needs the bound gate anyway).
  Decode depth is deferred to a follow-on proposal in any case.
- **`staticRoute(apiKey, ctx)` / `staticRouteForApiKey(apiKey)` returning a route** — a route is
  cluster-granular, so it can't name the specific represented broker that `sendRequest` (070) targets
  by node; loses leader affinity.

## Open questions

- **`intercepts` vs `requiresDynamicRouting` naming.** `intercepts` better describes the gate's real
  job (the router may intercept to reroute, to fan out, _or_ to rewrite a response without
  rerouting). `requiresDynamicRouting` aligns with the `routingMode` metric vocabulary. The metric
  name and method name need not match.

## Follow-on work (out of scope here)

- **Decode depth on the interception path** — a `shouldDecodeRequest`-style declaration so a router
  that routes on the header (client-id, subject) doesn't force a body decode, and lazy
  request/response frames so a relay doesn't pay to decode a response it never reads. Separable from
  the gate; deserves its own proposal.
