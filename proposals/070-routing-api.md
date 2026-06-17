# 70 - A Routing API

This proposal discusses an API for routing requests to Kafka clusters.

## Current situation

Kroxylicious currently supports `Filter` plugins as the top-level mechanism for adding behaviour to a proxy instance.
`Filters` can manipulate Kafka protocol requests and responses being sent by/to the Kafka client. 
They can also originate requests of their own (for example to obtain metadata that's necessary for them to function).

However, a `Filter` cannot influence which Kafka cluster will receive the requests it handles.

## Motivation

There are use cases for a Kafka proxy which cannot be served with the `Filter` API alone.

Here are some examples:

* **Union clusters**. 
Multiple backing Kafka clusters can be presented to clients as a single cluster. 
Broker-side entities, such as topics, get bijectively mapped (for example using a per-backing cluster prefix) to the
virtual entities presented to clients. 
For databases, this is known as Data Virtualization.
`Filters` cannot easily do this because they're always hooked up to a single backing Kafka cluster.

* **Principal-aware routing**.
A natural variation on basic [SASL termination](004-terminology-for-authentication.md) is to use the identity of the authenticated client to drive the decision about which backing cluster to route requests to.
For example, this could be used with some metadata about principals to ensure that a client is routed to a cluster that is local to it.

* **Topic splicing**.
Multiple separate topics in distinct backing clusters are presented to clients as a single topic.
Only one backing topic is writable at any given logical time.
 
Kroxylicious is currently unable to address use cases like these.

**Caveat:** It's worth noting that some aspects of the Kafka protocol prevent routing use cases which might, at first glance, appear possible. 
An example is _Record-based routing_.
While it's possible to use some attribute of an individual record (for example a header) to determine the destination for a `PRODUCE` request,
problems arise when you consider how a router should handle the offsets in the `PRODUCE` response returned to the client. 
While some client applications might not make use of record offsets, a proxy cannot make that assumption.
It would be possible to route record _batches_ without complication, but a record batch is not a first class concept in the Kafka Producer API, and lacks relevant (e.g. user-supplied) metadata for making routing decisions.

Not all use cases are equal in complexity.
Producer-side routing (deciding which cluster handles a `PRODUCE` request based on its topic) delivers the most immediate value, 
and has the simplest protocol interactions.
Consumer-side operations, admin operations, and stateful protocol features (transactions, consumer groups, fetch sessions) each add successive layers of complexity.
The API proposed here is general-purpose and does not prescribe which protocol features a `Router` must support; 
individual `Router` implementations are free to support as much or as little of the protocol as their use case requires.

## Proposal

### Concepts

To enable the use cases above we need a few concepts:

* A _cluster_ is an upstream Kafka cluster that can handle requests.
* A _router_ is a thing which decides which _route(s)_ should be used for a given request and formulates the response to return to the client.
* A _route_ is a named pathway from a router towards a _target_. 
* A route's _target_ is either a cluster or another router. Routes may also have filters attached.

Because a route's target can be another router, routers and routes together form a directed graph.
Furtermore, we will disallow loops in the graph, so we have a directed acyclic graph (DAG).

```
                                            route "foo"
                                    .------[filters...]------> cluster-a
                                   /
  client --> virtual cluster --> router
                 (my-vc)           \
                                    '------[filters...]------> cluster-b
                                            route "bar"
```

The _virtual cluster_ is the entry point: it binds a client-facing network address to a target (here, a router).
The _router_ decides which _route_ each request should traverse.
Each _route_ may carry its own filter chain, and terminates at a _cluster_ (or another router).
Clusters are the leaf nodes of the graph.

#### VirtualNode

Kafka's protocol identifies brokers by integer _node IDs_.
These node IDs are scoped to a single cluster — broker 0 in cluster-a is a completely different machine from broker 0 in cluster-b.
When a router presents multiple clusters to the client as a single virtual cluster, there is a collision problem: the client might receive node ID 0 in a `METADATA` response from one route and node ID 0 from another, with no way to distinguish them.

The solution is `VirtualNode` — an opaque reference type for node identity in the routing API.
The runtime assigns each `(route, target-cluster node ID)` pair a unique `VirtualNode`.
Routers obtain `VirtualNode` instances from `RouterContext` methods and pass them back to `sendRequest()`.
The type is intentionally opaque — routers must not inspect or construct instances; the runtime provides the implementation, which includes correct `equals()` and `hashCode()` so that `VirtualNode` instances can be used as map keys.

All responses delivered to the router (and onward to the client) use integer node IDs on the Kafka wire protocol.
The router converts these to `VirtualNode` via `nodeForId(int)` when it needs to use them as routing handles.
All requests from the router use `VirtualNode` via `sendRequest()`.
The runtime transparently translates between `VirtualNode` and real node IDs at the boundary.

**Why opaque, not `int`?**
The integer-based port-per-broker networking model encodes both route and target broker into a single `int` via a bijective formula.
An alternative networking model — where proxy instances act as brokers with their own identities and shard-based ownership — needs richer routing information that cannot be encoded in a single integer.
`VirtualNode` hides this difference: the same router code works with either networking model.
The runtime's internal class `VirtualNodeImpl` wraps the encoded integer for the current model; a future implementation could carry proxy instance identity, shard keys, or other routing metadata.

**`nodeForId(int)` — the wire-protocol bridge.**
Kafka protocol messages (METADATA responses, FIND_COORDINATOR responses, etc.) carry node IDs as integers.
When a router reads these integers — for example, broker node IDs in a METADATA response during fan-out merge, or a coordinator node ID from FIND_COORDINATOR — it converts them to `VirtualNode` via `nodeForId(int)`.
This method is permanent, not transitional: routers will always need to interpret integers from protocol messages.

The details of how the internal mapping works (the formula, the implementation) are described in the _Runtime_ section below.
The key point here is that `VirtualNode` is the universal addressing scheme within the routing API, and `nodeForId(int)` is the bridge from the Kafka wire protocol to that scheme.


### Plugin API

#### `Router`

`Router` is a top-level plugin analogous to the `Filter` plugin interface, using the same `ServiceLoader`-based mechanism for runtime discovery.

Each `Router` implementation will support 0 or more named routes.
The available and required route names will depend on the implementation, which might ascribe different behaviour to different named routes.
For example, a `Router` implementing the 'union cluster' use case might simply use the route names as prefixes for names of the broker-side entities 
it will expose (such as topics or consumer groups), and as such impose no restriction on the supported route names. 
In contrast, a `Router` implementing the 'topic splicing' use case might require configuration about each of the clusters being used in the splice, which would require the route names to be referenced in the `Router`'s configuration.

```java
interface Router {
    CompletionStage<RouterResponse> onRequest(short apiVersion,
                                              ApiKeys apiKey,
                                              RequestHeaderData header,
                                              ApiMessage request,
                                              RouterContext context);

    default Map<ApiKeys, String> staticRoutes() {
        return Map.of();
    }

    default void close() {}
}
```

A `Router` instance (and thus a graph instance) is created **per client connection**, not per virtual cluster.
This means per-connection state (caches, session state) can live directly in the `Router` instance without synchronisation, since all calls to a given instance happen on a single Netty event loop thread.
State shared across connections belongs in the `RouterFactory`'s initialisation data (see below).

**`onRequest()`** is invoked for each incoming client request that is _dynamically routed_.
The router inspects the request, decides which route(s) to use, sends one or more requests via the `RouterContext`, and eventually delivers a response to the client using the builder pattern.
The returned `CompletionStage<RouterResponse>` completes when the router has finished processing the request.

**`staticRoutes()`** returns a map of `ApiKeys` to route names for requests that should always be forwarded to a fixed route without `onRequest()` being called.
This allows a potential performance optimisation: if no filters express an interest either the runtime can forward these requests as opaque frames, bypassing the cost of deserialisation.
API keys not present in the map are dynamically routed via `onRequest()`.
The default implementation returns an empty map (all requests dynamically routed).

**`close()`** is called when the client connection is torn down.
Implementations should release any per-connection resources (session caches, etc.).

#### `RouterFactory`

`RouterFactory` manages the lifecycle of `Router` instances, analogous to `FilterFactory` for filters.
Like `FilterFactory`, each instance is scoped to a single virtual cluster.

```java
interface RouterFactory<C, I> {
    I initialize(RouterFactoryContext context, C config);

    Router createRouter(RouterFactoryContext context, I initializationData);

    void close(I initializationData);
}
```

**`initialize()`** is called once per virtual cluster that uses this router.
The configuration type `C` is deserialized from the router's `config` property in the proxy configuration.
The returned initialisation data `I` is shared across all `Router` instances created for that virtual cluster.
Because `Router` instances may be created on different event loop threads, the initialisation data must be thread-safe.

**`createRouter()`** is called once per client connection. It may run on a different thread than `initialize()`.

**`close(I)`** is called when the virtual cluster shuts down, to release shared resources. It may run on a different thread than `initialize()`.

**`RouterFactoryContext`** provides context to the factory:
* `virtualClusterName()` — the name of the virtual cluster.
* `routerName()` — the name of this router within the configuration.
* `routeNames()` — the set of route names declared in the router definition. This allows router factories to validate that route names referenced in their plugin configuration actually exist.
* `pluginInstance()` / `pluginImplementationNames()` — access to the plugin registry.
* `topologyService()` — returns a `TopologyService` for opt-in topology caching (see _TopologyService_ below). The runtime creates the underlying cache lazily on first call. Routers that never call this method pay no cost. The returned service should be stored in the factory's initialisation data so it survives connection reconnects.
* `allowSharedClusterTargets()` — declares that this router supports multiple routes resolving to the same cluster. By default the runtime rejects such configurations at startup because most routers assume each route is a distinct destination. Routers that handle this (e.g. aliasing the same cluster under different prefixes for migration) call this during `initialize()` to suppress the check. The check is transitive: if route A targets cluster X directly and route B targets a nested router that eventually reaches cluster X, the outer router's routes are considered overlapping.

#### `RouterContext`

`RouterContext` is passed to `Router.onRequest()` and provides methods for issuing requests to routes and delivering responses to the client.

```java
interface RouterContext {

    Optional<VirtualNode> virtualNode();

    VirtualNode anyNode(String route);

    VirtualNode nodeForId(int virtualNodeId);

    CompletionStage<ApiMessage> sendRequest(VirtualNode node,
                                             RequestHeaderData header,
                                             ApiMessage request);

    String sessionId();

    Subject authenticatedSubject();

    CloseOrTerminalStage respondWith(ApiMessage body);

    CloseOrTerminalStage respondWith(ResponseHeaderData header, ApiMessage body);

    CloseOrTerminalStage respondWithError(RequestHeaderData header,
                                          ApiMessage request,
                                          ApiException exception);

    CloseOrTerminalStage respondWithoutReply();
}
```

We want to allow (but not require) a router to potentially make multiple requests (e.g. to multiple clusters) and to have control over their processing (e.g. sequential or concurrent).
For this reason `RouterContext` does not follow the builder pattern used in the `FilterContext`, but simply exposes methods to asynchronously send requests.
This allows the `Router` author to make use of the `CompletionStage` API when issuing multiple requests.

**`virtualNode()`** returns the `VirtualNode` of the broker that the client connected to, or empty if the client connected to a bootstrap address.
When the client connects to a broker-specific endpoint (i.e. an address that corresponds to a particular broker in the cluster topology), this returns that broker's `VirtualNode`.
The router can use this to send requests — such as `API_VERSIONS` — to the specific broker the client believes it is talking to, rather than an arbitrary broker.
This is important during rolling upgrades where different brokers may run different Kafka versions.

When the client connected to a bootstrap address, this returns empty, because the proxy does not know which broker the client intended.
In that case the router should use `anyNode(String)` to obtain a node for sending requests.

**`anyNode(route)`** returns a `VirtualNode` that, when passed to `sendRequest()`, causes the runtime to send the request to an arbitrary broker on the named route's cluster.
This is used for initial discovery requests (e.g. `METADATA`, `FIND_COORDINATOR`) before the router has learned the cluster topology, and for requests that are not broker-specific.
The runtime is responsible for selecting which broker to use.
A route's cluster may be configured with multiple bootstrap servers, and the runtime should randomise selection and round-robin on subsequent calls, mirroring how Kafka clients handle bootstrap addresses.
This keeps the selection policy in the runtime, where it can be applied consistently, rather than requiring each router to implement its own strategy.

**`nodeForId(int)`** converts an integer node ID from a Kafka protocol response body into a `VirtualNode`.
This is the bridge between the Kafka wire protocol (which uses integer node IDs) and the opaque `VirtualNode` API.
Routers need this when interpreting node IDs in protocol messages — for example, broker node IDs when merging `METADATA` responses from multiple routes, coordinator node IDs from `FIND_COORDINATOR` responses, or leader IDs in partition metadata.

**`sendRequest(node, ...)`** sends a request to a specific broker, identified by a `VirtualNode`.
The runtime derives the route from the `VirtualNode` (via the internal `NodeIdMapping`) and resolves it to a specific upstream broker address, opening a new connection if necessary.

The `VirtualNode` can be:
* A value obtained from `virtualNode()` — sends to the broker the client connected to
* A value obtained from `anyNode(String)` — sends to an arbitrary broker on a route
* A value obtained from `nodeForId(int)` — sends to a broker whose ID was learned from a protocol response

Once `METADATA` responses arrive, the router converts the integer node IDs from those responses to `VirtualNode` via `nodeForId(int)`, then uses those nodes to address specific brokers via `sendRequest()`.

The absence of a route parameter on `sendRequest()` is deliberate: the runtime can derive the route from the `VirtualNode` via the internal `NodeIdMapping.fromVirtual()`.
This works for dedicated (one-to-one) mappings where each virtual node belongs to exactly one route.
For shared (many-to-one) mappings — where a single virtual node may serve brokers from multiple routes — the `VirtualNode` implementation can encode the necessary routing metadata (proxy instance identity, shard assignments, etc.) without changing the `sendRequest()` API.

**`sessionId()`** and **`authenticatedSubject()`** provide observability and identity context.
`sessionId()` returns a string that uniquely identifies the connection with the Kafka client. It will have the same value for all invocations of `onRequest()` which happen for that client connection, both for the same router over time, and different routers in a topology.
`authenticatedSubject()` returns the client's `Subject` established by mTLS or SASL processing on the VC filter chain (e.g. a `SaslTerminator` or `SaslInspector` filter).
If no authentication has occurred, the subject will be anonymous.
Note that `SaslInitiator` filters on per-route filter chains authenticate the _proxy_ to the _upstream cluster_ — they do not affect the value returned by `authenticatedSubject()`.

To ensure composability and avoid pathological configurations, SASL plugins should follow these placement rules:

* `SaslTerminator` and `SaslInspector` should only appear on the VC filter chain (not on per-route filter chains).
* There should be at most one `SaslTerminator` or `SaslInspector` per VC.
* `SaslInitiator` should only appear on routes whose target is a cluster (not a router).
* There should be at most one `SaslInitiator` per such route.

Enforcement of these rules is currently the administrator's responsibility; a future proposal may add runtime validation (see the _plugin constraint_ concept sketched in [this gist](https://gist.github.com/tombentley/31971d5fba024cc32a6769bd0d799b52)).

**Response builder methods** — `respondWith()`, `respondWithError()`, and `respondWithoutReply()` — follow a fluent builder pattern consistent with the `Filter` API.
Rather than constructing `RouterResult` subtypes directly, routers use the builder to construct responses:
* `context.respondWith(body).build()` — delivers a response to the client
* `context.respondWith(header, body).build()` — delivers a synthesised response with a custom header
* `context.respondWithError(header, request, exception).build()` — generates an API-specific error response
* `context.respondWithoutReply().build()` — completes with no response (fire-and-forget)

Each builder method returns a `CloseOrTerminalStage`, which supports optional connection closure via `.andCloseConnection()` before calling `.build()`:
* `context.respondWith(body).andCloseConnection().build()` — delivers a response then closes the connection

All `RouterContext` methods are called on the same Netty event loop thread as `onRequest()`.
No synchronisation is needed within a single `Router` instance.

#### `RouterResponse` and builder pattern

`RouterResponse` is the return type from `onRequest()`.
It is an opaque interface constructed via the builder pattern on `RouterContext`:

```java
interface RouterResponse {}

interface CloseOrTerminalStage {
    TerminalStage andCloseConnection();
    RouterResponse build();
}

interface TerminalStage {
    RouterResponse build();
}
```

Routers construct responses using the builder methods on `RouterContext`:

```java
// Deliver a response to the client
return context.respondWith(responseBody).build();

// Deliver a response with a custom header
return context.respondWith(responseHeader, responseBody).build();

// Generate an error response
return context.respondWithError(requestHeader, request, exception).build();

// Complete without sending a response (fire-and-forget)
return context.respondWithoutReply().build();

// Deliver a response and close the connection
return context.respondWith(responseBody).andCloseConnection().build();
```

The builder pattern is consistent with the `Filter` API, where outcomes are constructed via a fluent interface rather than by directly instantiating result types.
This allows the API to evolve (e.g. adding new builder stages for metrics or tracing) without breaking existing router implementations.

**Response delivery.** When a router returns a response via `respondWith()`, the runtime automatically rewrites the correlation ID to match the client's original request.
Routers never need to manage correlation IDs themselves.

**Fire-and-forget.** For requests that expect no response (e.g. `PRODUCE` with `acks=0`), routers use `respondWithoutReply()`.
Having a dedicated builder method rather than a nullable response makes the fire-and-forget case explicit.
The runtime can log a warning if a router uses `respondWith()` for a request that has no response, or `respondWithoutReply()` for a request that expects one.

**Error handling.** If the `CompletionStage<RouterResponse>` completes exceptionally, or if the implementation throws an unchecked exception, the runtime treats this as an unrecoverable error and closes the client connection.
Routers should generally handle errors within the terms of the Kafka protocol, using `respondWithError()` to generate error responses with appropriate Kafka error codes.
Throwing an exception or returning an exceptionally-completed stage should be avoided where possible.

#### `TopologyService`

`TopologyService` is an opt-in topology cache for routers that need leader, coordinator, broker, or topic ID information.
Routers obtain it from `RouterFactoryContext.topologyService()` during `RouterFactory.initialize()`.
Routers that never call `topologyService()` pay no cost — no cache is created, and the runtime skips topology-related work for that router level.

```java
interface TopologyService {
    // Discovery (async, may send requests, return self-contained results)
    CompletionStage<PartitionLeaders> leaders(Map<String, Set<String>> topicsByRoute);
    CompletionStage<Coordinators> coordinators(String route, byte keyType, Set<String> keys);
    CompletionStage<Map<Uuid, String>> topicNames(String route, Set<Uuid> topicIds);

    // Supplementary lookups (sync, best-effort from cache)
    Optional<PartitionInfo> partitionInfo(String topicName, int partitionIndex);
    Optional<BrokerInfo> brokerInfo(VirtualNode node);

    // Invalidation
    void invalidateRoute(String route);
}

interface PartitionLeaders {
    Optional<VirtualNode> leaderOf(String topicName, int partitionIndex);
}

interface Coordinators {
    Optional<VirtualNode> coordinatorFor(String key);
}
```

The service provides three categories of methods:

**Discovery** — `leaders()`, `coordinators()`, `topicNames()` — are async and return self-contained result objects.
They may send requests internally (METADATA for leaders and topic names, FIND_COORDINATOR for coordinators).
The results are valid immediately upon completion and do not require further cache queries.
`leaders()` batches all uncached topics into one METADATA request per route and returns a `PartitionLeaders` snapshot.
`coordinators()` sends METADATA (if needed) then FIND_COORDINATOR and returns a `Coordinators` snapshot; it supports batched lookup matching the FIND_COORDINATOR v4+ protocol.
`topicNames()` resolves topic IDs to names for a given route, batching cache misses.
The route parameter is required because per-route filter chains can transform topic names differently — the same cluster-level topic ID can map to different router-visible names on different routes.
These methods use a `RequestSender` bound per-connection by the runtime (see _Runtime_ below).

**Supplementary lookups** — `partitionInfo()`, `brokerInfo()` — query the cache synchronously and return immediately.
These are for use cases like follower-fetch / AZ-aware routing where the router needs replica or rack information beyond what `PartitionLeaders` provides.
If they return empty, the router can fall back to the leader from `PartitionLeaders`.

**Invalidation** — `invalidateRoute(route)` performs coarse invalidation: clears all partition info (leaders, replicas, ISR), coordinators, broker info, and topic ID→name mappings for a route.
Topic ID→name mappings are route-scoped because per-route filter chains can present different names for the same underlying cluster topic.
Over-invalidation is acceptable because the cache is repopulated cheaply from the client's next METADATA request.

**Why discovery methods return result objects, not void.**
An earlier design had `ensureLeadersCached()` returning `CompletionStage<Void>` (warming the cache as a side effect) and separate synchronous `leaderOf()`/`coordinatorOf()` methods for querying the cache.
This was rejected because the synchronous methods are unsafe: the cache is shared across connections and can be invalidated at any time by another connection calling `invalidateRoute()`.
The only moment a leader is guaranteed to be in the cache is immediately after the discovery future completes — and even then, another thread could invalidate between completion and the synchronous call.
Returning a self-contained `PartitionLeaders` snapshot eliminates this race: the router uses the snapshot directly, not the cache.

**Cache population model.**
The cache is populated as a _side effect_ of METADATA responses flowing through the routing pipeline.
When any request sent via `RouterContext.sendRequest()` produces a METADATA response, the runtime intercepts the response in `RoutingDecisionHandler.write()` (an internal class; after node ID translation) and updates the topology cache _before_ completing the router's `CompletionStage`.
This means: after a METADATA request's future completes, the cache is guaranteed to reflect that response.
Routers that need to warm the cache for uncached topics send METADATA requests themselves (or via `ensureLeadersCached()`), and the cache is populated as a side effect of the response flow.

Coordinator caching uses the same side-effect model, with one twist: the FIND_COORDINATOR response lacks `keyType`, and pre-v4 responses lack the `key` field entirely.
To solve this, `PendingResponse` (an internal class) carries a `CoordinatorRequestContext(keyType, key)` (also internal) extracted from the FIND_COORDINATOR request.
When the response arrives in `RoutingDecisionHandler.write()`, the runtime uses this request-side context alongside the response to populate the cache — the internal `TopologyCache.updateFromFindCoordinator()` method matches coordinator keys from the request with node IDs from the response.
Coordinators are keyed by `(route, keyType, key)` — not by route alone, fixing a limitation where different consumer groups on the same route could collide.

Only METADATA responses populate partition and broker data.
DESCRIBE_CLUSTER is intentionally excluded: it contains brokers and racks but no topic/partition/leader information, and mixing data from different response types risks inconsistency.

**Cache scope.**
The `TopologyCache` is shared per router level (not per connection), backed by `ConcurrentHashMap`.
All connections through the same router level share the same topology view.
This is efficient (no per-connection duplication) and necessary for correctness: a leader discovered by connection A must be usable by connection B (see _Shared node address map_ in the Runtime section).
Each connection gets its own `TopologyServiceImpl` wrapping the shared cache; this per-connection instance holds the `RequestSender` used for discovery requests (see _TopologyService request sending_ in the Runtime section).

**Authorization and cache scope.**
The cache is not scoped by authenticated subject.
When Kafka brokers filter METADATA responses based on ACLs, different connections may receive different subsets of topics.
Because the cache is shared, it converges toward the _union_ of all connections' views: each METADATA response adds or updates entries for topics present in the response, but does not remove entries for topics absent from the response.

This is safe because the cache is a _routing optimization_, not an access-control mechanism:
* The cache stores _where_ to send requests (partition leaders, coordinator nodes, broker addresses), not _whether_ a client is authorized.
* Backend brokers enforce ACLs on every request. A client that resolves a leader from the cache but lacks permission to produce or fetch will receive an authorization error from the broker, exactly as it would without the proxy.
* Cache misses trigger discovery requests on the current connection's `RequestSender`, which carries that connection's authentication context. A low-privilege connection's filtered METADATA response adds a subset of entries without corrupting entries populated by other connections.

Router authors must not use the topology cache for authorization decisions.
Routers should use the cache only for routing (leader selection, coordinator discovery, broker address resolution) and rely on backend broker ACL enforcement for access control.

**Invalidation responsibility.**
Staleness invalidation is the _router's_ responsibility, not the runtime's.
The router calls `invalidateRoute(route)` when it observes staleness indicators (e.g. `NOT_LEADER_OR_FOLLOWER`, `NOT_COORDINATOR`) in responses.
No background METADATA refresh is fired — the stale error is returned to the client unchanged, and the client sends its own METADATA request (standard Kafka behaviour), which repopulates the cache via the side-effect path.

The alternative — having the runtime scan responses for staleness errors automatically — was rejected because it would require the runtime to deserialise an open-ended and growing set of response types.
Different error codes have different semantics (`NOT_LEADER_OR_FOLLOWER` vs `NOT_COORDINATOR` vs `FENCED_LEADER_EPOCH`).
Routers that don't use the topology cache shouldn't pay the deserialization cost.

**Supporting types:**
* `PartitionLeaders` — snapshot of partition leader assignments, returned by `leaders()`. Has `leaderOf(topicName, partitionIndex)`.
* `Coordinators` — snapshot of coordinator assignments, returned by `coordinators()`. Has `coordinatorFor(key)`. The key type is implicit (specified in the `coordinators()` call).
* `PartitionInfo(VirtualNode leader, List<VirtualNode> replicas, List<VirtualNode> isr)` — full partition topology for follower-fetch / AZ-aware routing.
* `BrokerInfo(String host, int port, @Nullable String rack)` — broker metadata including rack assignment.


### Configuration

Routers are configured at the top level of the proxy configuration, alongside cluster definitions and virtual clusters.

```yaml
clusterDefinitions:
  - name: cluster-a
    bootstrapServers: kafka-a:9092
    tls: ...
  - name: cluster-b
    bootstrapServers: kafka-b:9092

routerDefinitions:
  - name: my-router
    type: MyRouter
    config: ...
    routes:
      - name: foo
        id: 0
        filters: 
          - my-first-filter
          - my-second-filter
        target:
          cluster: cluster-a
      - name: bar
        id: 1
        filters: 
          - my-third-filter
        target:
          router: my-other-router
  - name: my-other-router
    type: AnotherRouter
    config: ...
    routes:
      - name: baz
        id: 0
        target:
          cluster: cluster-b

virtualClusters:
  - name: my-vc
    target:
      router: my-router
    gateways: [...]
    filters:
      - my-audit-filter
```

The proxy configuration has three top-level definition lists:

* **`clusterDefinitions`** — the catalogue of upstream Kafka clusters the proxy can connect to. Each has a `name`, `bootstrapServers`, and optional `tls` configuration.

* **`routerDefinitions`** — router plugin instances. Each has a `name`, `type` (the plugin implementation name), optional `config`, and `routes`. In addition to the `name`, `type` and `config` (which serve the same purpose for routers as they do for filters), a router definition also supports a `routes` property. The `routes` property is optional, though any given implementation may have its own particular requirements for its routes.

* **`virtualClusters`** — the entry points presented to clients. Each has a `name`, `gateways`, and a `target`.

#### Routes

A route has a `name`, an `id`, an optional list of `filters` (the names of filters applied to requests/responses traversing this route), and a `target`.

The `id` is an integer that identifies the route within the virtual node ID mapping formula (see _Node ID mapping implementation_ below).
Route IDs must be unique within their parent router and in the range `[0, S)` where `S` is the number of routes in the router.
The `id` is separate from the `name` to allow route names to be reordered in the configuration without changing the virtual node ID mapping.
The proxy rejects configurations where the route count `S` is large enough that overflow is inevitable for plausible broker node IDs.

The `target` property is a discriminated union containing exactly one of:
* `cluster` — the name of a cluster defined in `clusterDefinitions`.
* `router` — the name of another router defined in `routerDefinitions`.

This `target` structure is used uniformly on both routes and virtual clusters, providing a consistent way to express "what does this connect to" throughout the configuration.

#### Virtual cluster changes

The existing virtual cluster schema is modified:
* The existing inline `targetCluster` property is deprecated but still supported for backwards compatibility. It will be removed in a future release.
* A new `target` property supports referencing a cluster or router by name (as described above).
* Exactly one of `target` or `targetCluster` must be specified.
* Virtual clusters may have both `filters` and a `target` referencing a router. The virtual cluster's filters run before router dispatch, handling cross-cutting concerns such as audit logging or authorisation that apply regardless of the routing decision.

For example, the old-style configuration:

```yaml
virtualClusters:
  - name: my-vc
    gateways: [...]
    filters: [...]
    targetCluster: 
      bootstrapServers: kafka:9092
``` 

can be rewritten as:

```yaml
clusterDefinitions:
  - name: my-cluster
    bootstrapServers: kafka:9092

virtualClusters:
  - name: my-vc
    gateways: [...]
    filters: [...]
    target:
      cluster: my-cluster
```

#### Router graph

As mentioned earlier, because routers can refer to other routers via their routes, they form a directed graph.
All possible routes through the graph can be determined statically from the proxy configuration, but the routing of any individual incoming request is determined at runtime.
It may involve multiple outgoing requests to one or more clusters or routers.

Validation performed at proxy startup will reject:
* Cyclic graphs (preventing request loops).
* Dangling references (routes or virtual clusters referencing undefined clusters or routers).

In order for non-trivial router graphs to be useful, `Router` authors will need to follow the same _principle of composition_ as `Filter` authors.
That is, a `Router` implementation should only talk to its targets using the `RouterContext` API, and not, for example, make their own direct TCP connections to a backing cluster. 
Doing so would short-circuit any logic in downstream routers and filters, which could be manipulating broker-side entities like topic names.

### Runtime

#### Threading model

One `Router` instance exists per client connection, running on a single Netty event loop thread.
All `onRequest()` invocations and `RouterContext` method calls for that instance happen on this thread.
No synchronisation is needed within a `Router` instance.

`RouterFactory.initialize()` may run on a different thread than `createRouter()`. 
Any initialisation data shared across connections must be thread-safe.

#### Request dispatch

The runtime dispatches incoming requests in one of two modes:

* **Static routes**: For API keys declared via `Router.staticRoutes()`, the runtime forwards the request as an opaque frame directly to the named route's backend, bypassing deserialisation and `Router.onRequest()`. This is a performance optimisation for APIs that the router does not need to inspect.

* **Dynamic routes**: For all other API keys, the runtime deserialises the request, creates a `RouterContext`, and invokes `Router.onRequest()`. The router uses the context to send requests to routes and deliver a response to the client.

#### Nested router dispatch

When a router calls `sendRequest()` on a route whose target is another router, the runtime dispatches to the nested router rather than forwarding directly to a backend.
The dispatch works as follows:

1. The runtime creates (or retrieves from a per-connection cache) a `Router` instance for the nested router.
2. A new `RouterContextImpl` (the internal implementation of `RouterContext`) is constructed for the nested router, with its own `NodeIdMapping`, routes, and bootstrap virtual node IDs.
   The nested context shares the same Netty client channel, response sequencer, correlation ID allocator, and metrics as the outer context.
   Its forwarder callbacks wrap the outer forwarders to translate virtual node IDs from the nested space to the outermost space (see _Per-router scoping and nested dispatch_ above).
3. The runtime invokes `nestedRouter.onRequest()` with the nested context.
4. The `RouterResponse` is unwrapped to a `CompletionStage<ApiMessage>`:
   * Response built via `respondWith()` → the response body is returned to the outer router.
   * Response built via `respondWithoutReply()` → null is returned (fire-and-forget).
   * Response built via `andCloseConnection()` → the future completes exceptionally (a nested router should not disconnect the client).

Nested `Router` instances are cached per connection, keyed by the `(outerRoute, routerName)` pair.
They are closed when the client connection closes, in `RouterDispatchHandler.handlerRemoved()`, before the outer router is closed.

#### Correlation ID management

When a router sends requests via `RouterContext`, the runtime allocates _routing correlation IDs_ that are distinct from the client's original correlation IDs.
Routing correlation IDs are negative integers (allocated from `Integer.MIN_VALUE / 2` upward), which distinguishes them from client-originated correlation IDs (which are non-negative).

When the router returns a `Completed(response)` result, the runtime automatically rewrites the response header's correlation ID to match the client's original request.
Routers never need to manage correlation IDs themselves.

#### Response ordering

A router may send multiple requests (fan-out) and compose their responses before delivering a single response to the client.
Different routes may respond at different times.
The runtime uses a _response sequencer_ to ensure that responses are delivered to the client in the same order as the original client requests, regardless of the order in which fan-out responses arrive.

#### Topology cache population

When a `TopologyService` has been created for a router level (via `RouterFactoryContext.topologyService()`), the runtime populates it from METADATA responses.
In `RoutingDecisionHandler.write()`, the processing order for each backend response is:

1. `MetadataAddressCacher` (an internal class) extracts broker addresses (before node ID translation, using the route's `NodeIdMapping` to store addresses keyed by the outermost virtual ID).
2. `NodeIdResponseTranslator` (an internal class) translates all node IDs in-place from target-cluster IDs to virtual IDs.
3. Topology cache update (if the cache exists for this router level):
   - For METADATA responses: `TopologyCache.updateFromMetadata()` updates partition leaders, replicas, ISR, broker info, and topicId→name mappings.
   - For FIND_COORDINATOR responses: `TopologyCache.updateFromFindCoordinator()` uses the `CoordinatorRequestContext` (keyType, key) carried by `PendingResponse` from the original request.
4. The router's `CompletionStage` future is completed.

This ordering guarantees that the topology cache reflects the response by the time the router's callback fires.

#### Shared node address map

Broker address resolution (`sharedNodeAddresses`) is shared per router level, backed by `ConcurrentHashMap` stored in `RouterChainFactory`.
This is necessary because the `TopologyCache` is shared: a leader virtual node ID cached from connection A's METADATA must be resolvable to a broker address on connection B.
If addresses were per-connection, connection B would find the leader in the topology cache (skipping METADATA), but then fail to resolve the leader's address — "Upstream address not yet known."

The shared address map is populated from two sources:
* `RouterContextImpl.registerBootstrapAddresses()` — at handler installation time, adds bootstrap addresses for cluster-targeting routes.
* `MetadataAddressCacher.cacheIfMetadata()` — from METADATA responses, adds broker addresses learned from the broker list.

#### TopologyService request sending

The `TopologyCache` is shared per router level (created in the internal `RouterChainFactory`), but each connection gets its own `TopologyServiceImpl` instance wrapping the shared cache.
`TopologyServiceImpl` is created in `RouterChainFactory.createRouter()` alongside the `Router` instance and passed to both the `Router` (via `RouterFactoryContext.topologyService()`) and the `RoutingDecisionHandler`.

Methods that may send requests (`leaders`, `coordinators`) use a `RequestSender` functional interface, bound per-connection via `TopologyServiceImpl.bindRequestSender()`.
The binding happens in `RoutingDecisionHandler.dispatchDynamically()` before each `Router.onRequest()` call — the sender lambda captures the per-request `RouterContextImpl`.

Because each `TopologyServiceImpl` is per-connection, the `RequestSender` field is a plain (non-volatile) field — all access happens on the single event loop thread assigned to the connection's channel.
No synchronisation is needed.

#### Node ID mapping implementation

As described in _VirtualNode_ above, the runtime translates between real target-cluster node IDs and virtual node IDs.
This is implemented by a `NodeIdMapping` abstraction (internal to the runtime) with two operations:

* `toVirtual(route, targetNodeId)` — used when rewriting responses received from a target cluster (the runtime rewrites broker node IDs in `METADATA`, `PRODUCE`, `FIND_COORDINATOR`, and `DESCRIBE_CLUSTER` responses before they reach the router).
* `fromVirtual(virtualNodeId)` — used internally by the runtime when the router calls `sendRequest(VirtualNode, ...)`. The runtime unwraps the `VirtualNode` to its encoded integer, calls `fromVirtual()`, and gets both the route and the target-cluster node ID. Routers never call `fromVirtual()` directly.

The mapping must satisfy: for any route `r` and target node ID `t`, if `v = toVirtual(r, t)` then `fromVirtual(v)` returns `(r, t)`.
The mapping must be able to recover the route from the virtual node ID alone.
This is straightforward for _dedicated_ (one-to-one) mappings where each virtual node belongs to exactly one route.
For _shared_ (many-to-one) mappings, the mapping implementation would need to maintain additional state to recover the route from the virtual node ID.

##### Mapping strategies

The design supports several mapping strategies, each suited to different deployment topologies.

**Dedicated mapping (one-to-one).**
Each virtual node maps to exactly one `(route, target-broker)` pair.
The current implementation uses a formula: `V = id + S × t`, where `V` is the virtual node ID, `t` is the target-cluster node ID, `S` is the number of routes in the router, and `id` is the route's configured identifier.
This mapping is deterministic, stateless, and O(1) in both directions.
No coordination between proxy instances is required.

The client sees all brokers from all clusters (each with a unique virtual ID).
Because each virtual node belongs to exactly one route, leader-directed requests (e.g. `PRODUCE`, `FETCH`) from a well-behaved client will only contain topics from one route — no decomposition is needed for these APIs.
The runtime can derive the route from the virtual node ID via `fromVirtual()`.

The dedicated mapping is _stable_: adding or removing brokers from a target cluster does not change the virtual node IDs of existing brokers.
Likewise, adding or removing proxy instances has no effect on the mapping.
Because the route's `id` is explicit rather than derived from position, reordering routes in the configuration does not change the mapping.
This stability is important because Kafka clients cache broker metadata and will use previously-seen node IDs in subsequent requests.

However, _adding or removing_ a route changes `S`, which shifts every virtual node ID for every existing route (for any `t > 0`).
This is an accepted consequence of the formula: virtual cluster configuration changes already drain all client connections before applying the new configuration, so clients reconnect and receive fresh metadata.
All proxy instances presenting the same virtual cluster must be reconfigured together (i.e. the configuration change must be applied to all instances before any drained clients reconnect), so that clients see a consistent set of virtual node IDs.
A future formula that avoids the `S`-dependency (e.g. a fixed block size per route) could enable more surgical configuration changes, but is not required for the current dedicated mapping.

For single-route configurations, an identity mapping (a special case of dedicated mapping) is used: the virtual ID equals the target ID, with zero overhead.

##### Per-router scoping and nested dispatch

Each router level has its own `NodeIdMapping`, scoped to its routes.
In a nested topology where an outer router has a route targeting an inner router, the inner router works entirely within its own virtual node ID space — its mapping uses `S_inner` (the inner router's route count) and its routes' own `id` values.

However, the runtime's address resolver maps a single integer virtual node ID to an upstream address.
Nested virtual IDs must therefore be translated to the outermost level before reaching the address resolver.
The translation exploits the outer mapping's unused route slot: for an outer route `r` with `id = k` that targets a nested router, the translation is `V_outer = k + S_outer × V_inner`.
This is simply the outer mapping applied to the nested virtual ID _as if it were a target node ID_.

Because the outer mapping guarantees uniqueness across its route slots, and the inner mapping guarantees uniqueness within its own space, the composed translation produces globally unique virtual node IDs.
The composition generalises to arbitrary nesting depth: each level translates through its parent route's slot.

Concretely, this translation is applied by the nested level's forwarder callbacks — the inner `RouterContextImpl` wraps the outer `nodeForwarder` to translate IDs before forwarding to the CCSM.
Address caching from `METADATA` responses also uses the translated IDs, ensuring the CCSM's address resolver can find them.
The `NodeIdResponseTranslator` uses the inner mapping (so the inner router sees its own virtual IDs in responses), while address caching uses the composed translation (so the CCSM sees outer virtual IDs).

**Shared mapping (many-to-one).**
Multiple `(route, target-broker)` pairs map to the same virtual node.
For example, if proxy instances are presented to clients as broker nodes, each proxy instance handles brokers from multiple routes.
The client sees fewer nodes (one per proxy instance rather than one per target broker).

Because a single virtual node may serve brokers from multiple routes, a leader-directed request to one virtual node _can_ contain topics from different routes — decomposition is needed even for `PRODUCE` and `FETCH`.
For the runtime to support this, `fromVirtual()` would need to maintain additional state to recover which route was used when the virtual node ID was created, or the mapping would need to be restricted such that each virtual node still maps to exactly one route (making it effectively a dedicated mapping).

A shared mapping requires the proxy instances to agree on their assignments.
If assignments change dynamically (e.g. a proxy instance leaves or joins), a router may hold stale metadata — its cached leader for a topic might reference a virtual node that no longer serves that route.
This is not a programming error; it is a natural consequence of eventual consistency, analogous to Kafka's `NOT_LEADER_OR_FOLLOWER`.
The runtime should respond with an appropriate Kafka error code, triggering the router to refresh its metadata.

A shared mapping would require strong consistency across proxy instances to ensure they agree on the virtual node ID assignments.

Note: The current implementation uses a dedicated mapping and does not support shared mappings. The `VirtualNode` abstraction is designed to enable shared mappings in the future: a shared-mapping `VirtualNode` implementation could carry proxy instance identity, shard assignments, or other routing metadata internally, without changing the `sendRequest()` API that routers use.

**Role-based mapping.**
Virtual nodes correspond to per-route functional roles (e.g. "partition leader", "group coordinator").
If roles are scoped per route, this behaves like a dedicated mapping.
If roles span routes, it behaves like a shared mapping.

##### Operational considerations

All proxy instances presenting the same virtual cluster to clients must use the same `NodeIdMapping`.
Changing the mapping strategy (e.g. from dedicated to shared) is expected to be a disruptive operation — not a zero-downtime change — because connected clients will hold stale virtual node IDs from the previous mapping.
Similarly, adding or removing routes changes `S` in the dedicated mapping formula, which invalidates existing virtual node IDs.
This requires draining all client connections and reconfiguring all proxy instances together before clients reconnect.

`NodeIdMapping` is a `sealed` interface — the runtime controls which implementations exist.
`Router` authors never implement or interact with this interface directly.

#### API version negotiation

The Kafka protocol scopes `API_VERSIONS` to a single broker connection — a client sends `API_VERSIONS` each time it connects to a new broker.
This means the proxy must forward `API_VERSIONS` to the specific broker the client believes it is talking to, not to an arbitrary broker.

When the client connects to a broker-specific endpoint, `virtualNode()` returns that broker's `VirtualNode`, allowing the router to forward `API_VERSIONS` to the correct broker via `sendRequest()`.
When the client connects to a bootstrap address, `virtualNode()` returns empty, and the router should use `anyNode(route)` to send `API_VERSIONS` to an arbitrary broker on the route.

With a shared mapping, the runtime would need to fan out `API_VERSIONS` to all brokers behind that virtual node and return the intersection of their version ranges.

The runtime's existing `ApiVersionsIntersectFilter` intersects each backend broker's version ranges with the proxy's own maximums.

Routers may choose to _further constrain_ advertised API versions.
For example, a router that fans out requests by topic name might cap `PRODUCE` to v12 to avoid handling topic IDs (which are cluster-specific in v13+), though this is an implementation simplification rather than a fundamental necessity.
Version capping is the router's responsibility, not the runtime's.

#### Flow control

The runtime uses Netty's auto-read mechanism to apply TCP-level backpressure to the client connection.
Auto-read is disabled while the router is processing a request and re-enabled when the `CompletionStage<RouterResponse>` completes.
This means the router's processing strategy directly determines the proxy's response latency and backpressure behaviour:

* A router that forwards a request to a single backend and returns the response has latency equal to the backend's latency.
* A router that fans out to multiple backends and waits for all responses (e.g. `CompletableFuture.allOf(...)`) has latency equal to the _maximum_ of the backends' latencies. A slow backend will hold up the client.
* A router that fans out but completes as soon as one backend responds (e.g. for speculative execution) has latency equal to the _minimum_.

The runtime does not impose its own timeout on router processing.
If a router blocks indefinitely (e.g. a backend never responds), the client connection will stall.
Routers are responsible for implementing their own timeouts if needed.

Requests arriving before backend connections are ready are buffered and flushed when the connection becomes active.
Backpressure from any upstream connection propagates to the Netty client channel.


### Metrics

The runtime provides the following per-route metrics:

* Request counters (total, errors) tagged by route name, API key, and routing mode (static/dynamic).
* Request latency histograms tagged by route name and API key.
* Error counters tagged by error type (unknown route, node forward failure, router failure).

These are broadly similar to the existing per-filter metrics.

#### Cardinality analysis

The metric tag dimensions determine the number of distinct time series. Operators and monitoring systems need to be able to handle the resulting cardinality.

| Tag | Typical values | Bound |
|-----|---------------|-------|
| route name | 2–5 per router | Bounded by configuration (number of routes). |
| API key | ~80 defined in the Kafka protocol, but only ~20 are common in practice | Bounded by the protocol. Grows slowly (a few new keys per Kafka release). |
| routing mode | `static`, `dynamic` | Fixed at 2. |
| error type | `unknown_route`, `node_forward_failed`, `router_failed` | Fixed at 3. |

The routing mode is determined per API key (an API key is either statically or dynamically routed, never both), so it does not multiply the cardinality — it is a property of the key, not an independent dimension.

For the request counter, the worst-case cardinality per virtual cluster is `routes × API keys`. With 3 routes and 80 API keys, that is 240 series. In practice it will be much lower because most API keys are statically routed (producing one series per key, not per route) and many API keys are never used by a given client.

For the latency histogram, the cardinality is `routes × API keys`. With 3 routes and 80 API keys, that is 240 series. Again, in practice most of these will never be populated.

For the error counter, the cardinality is bounded by the 3 error types — negligible.

This cardinality is comparable to the existing per-filter metrics and should not pose problems for standard monitoring deployments. We deliberately avoid high-cardinality tags such as client ID, topic name, or session ID.


## Affected/not affected projects

* `kroxylicious-api` — new `io.kroxylicious.proxy.router` package containing `Router`, `RouterFactory`, `RouterFactoryContext`, `RouterContext`, `RouterResponse`, `CloseOrTerminalStage`, `TerminalStage`, `CloseStage`; new `io.kroxylicious.proxy.topology` package containing `VirtualNode`, `TopologyService`, `PartitionLeaders`, `Coordinators`, `PartitionInfo`, `BrokerInfo`.
* `kroxylicious-runtime` — routing engine, configuration model (`RouterDefinition`, `RouteDefinition`, `TargetClusterDefinition`), graph validation, node ID mapping (internal classes: `NodeIdMapping`, `BijectiveNodeIdMapping`, `IdentityNodeIdMapping`, `VirtualNodeImpl`), topology caching (internal classes: `TopologyCache`, `TopologyServiceImpl`), response sequencing, metrics.
* `kroxylicious-bom` — version management for any new modules.
* Not affected: existing filters, KMS, authoriser API. The Kubernetes operator will need a separate update to support router configuration in CRDs.


## Compatibility

These changes are fully backwards compatible:
* There is no impact on the `Filter` API. All existing filters continue to work.
* The inline `targetCluster` property on virtual clusters is deprecated but still supported. Existing configurations continue to work without changes.
* The new `clusterDefinitions`, `routerDefinitions`, and `target` properties are purely additive.

The deprecation of inline `targetCluster`, replacing it with a named cluster reference via `target: { cluster: <name> }`, is made to reduce different ways of expressing the same configuration.
Having a single `clusterDefinitions` list as the authoritative catalogue of upstream clusters makes the proxy's connectivity easy to audit.


## Rejected alternatives

* **Do nothing.** One alternative is simply not to add routing (or not right now). However, the use cases described in the motivation are real and cannot be addressed with the `Filter` API alone.

* **`NetFilter`.** `NetFilter` is an existing attempt at an abstraction for SASL auth and cluster selection. It was never completed, and the interface never made it into the `kroxylicious-api` module. This proposal is more flexible since it allows routing decisions to happen after authentication.

* **Top-level route definitions.** We considered making routes first-class top-level objects with their own definition list. This was rejected because a route's identity is inherently scoped to its parent router — the same route name in different routers means different things. Making routes top-level would require a fourth definition list and introduce potential for confusion.

* **Uniform `nodes` list with `kind` discriminator.** We considered a single polymorphic list for all graph nodes (virtual clusters, routers, clusters) with a `kind` field to distinguish them. This was rejected because typed lists are more readable, and virtual clusters, routers, and clusters serve fundamentally different roles (ingress, logic, egress). Having separate lists makes it immediately obvious where to look for each type.

* **`connectsTo` / `receiver` property name.** We considered a verb-based property name (`connectsTo`) for the target reference, as well as the abstract noun `receiver` to unify routers and clusters. We settled on `target` as a simpler noun, with explicit type discrimination (`cluster` or `router`) inside the object. This is more concrete than `receiver` and more conventional than a verb.

* **Mutual exclusivity of filters and router on a virtual cluster.** The original draft of this proposal required that a virtual cluster specify either `filters` or a `router`, but not both. In practice, virtual-cluster-level filters handle cross-cutting concerns (audit logging, authorisation) that apply regardless of the routing decision. The implementation allows both, with filters running before router dispatch.


## Design choices

This section summarises the key design choices made in this proposal, for ease of reference.

* **`VirtualNode` as opaque type** provides a uniform addressing scheme that insulates router authors from the node ID collision problem inherent in multi-cluster topologies, and enables alternative networking models (proxy-as-broker) without changing the Router API. The runtime owns the mapping; routers work exclusively with `VirtualNode` instances and never need to know the underlying encoding. Routers never perform arithmetic on node IDs — they use them as opaque handles for map keys and `sendRequest()` arguments.
* **`nodeForId(int)` as wire-protocol bridge** converts integer node IDs from Kafka protocol response bodies into `VirtualNode` instances. This is retained permanently (not transitional) because routers will always need to interpret integers from protocol messages — for METADATA response merging, FIND_COORDINATOR responses, and future protocol extensions. Removing it would mean every such use case needs a dedicated method on `RouterContext` or `TopologyService`, which does not scale.
* **Separate `virtualNode()` and `anyNode(route)` methods** distinguish between broker-specific connections (where the client connected to a specific broker endpoint) and bootstrap connections (where the client connected to a generic bootstrap address). This allows routers to correctly handle `API_VERSIONS` requests by forwarding them to the specific broker the client connected to, which is important during rolling upgrades where different brokers may run different Kafka versions.
* **Route derived from `VirtualNode`** — `sendRequest()` takes only a `VirtualNode`, and the runtime derives the route by unwrapping to the internal integer and calling `NodeIdMapping.fromVirtual()`. This works for dedicated (one-to-one) mappings where each virtual node belongs to exactly one route. Shared (many-to-one) mappings encode the routing metadata within the `VirtualNode` implementation, without changing the `sendRequest()` API.
* **Per-connection `Router` instances** allow per-connection state (caches, sessions) without synchronisation. Shared state lives in the `RouterFactory`'s initialisation data, which must be thread-safe.
* **Builder pattern for response construction** follows the same fluent interface pattern as `FilterResult`, where outcomes are constructed via `RouterContext` builder methods rather than by directly instantiating result types. This allows the API to evolve (e.g. adding new builder stages) without breaking existing implementations.
* **All requests addressed by `VirtualNode`.** Routers must explicitly obtain a `VirtualNode` (via `virtualNode()`, `anyNode(route)`, `nodeForId(int)`, or from `TopologyService`) before sending a request. This forces router authors to think about broker targeting, avoiding a class of bugs where a broker-specific API is mistakenly sent to an arbitrary broker.
* **`TopologyService` is opt-in** via `RouterFactoryContext.topologyService()`. The runtime creates the underlying cache lazily on first call. Simple routers (subject-based, client-ID-based) that never call it pay no cost — no cache, no topology-related processing. This avoids a one-size-fits-all design where all routers pay for topology caching.
* **Side-effect cache population** — the topology cache is populated from METADATA and FIND_COORDINATOR responses in `RoutingDecisionHandler.write()`, after node ID translation, before the router's `CompletionStage` completes. Discovery methods (`leaders()`, `coordinators()`) return self-contained snapshot objects (`PartitionLeaders`, `Coordinators`) that read from the now-warm cache. The snapshots are safe to use across async callback boundaries.
* **Discovery methods return snapshots, not void** — an earlier design had `ensureLeadersCached()` returning `CompletionStage<Void>` with separate synchronous `leaderOf()`/`coordinatorOf()` methods. This was rejected because the synchronous methods are unsafe: the shared cache can be invalidated between the discovery future completing and the synchronous query. Returning a self-contained snapshot eliminates this race. It also makes the three discovery methods symmetric: `leaders()`, `coordinators()`, `topicNames()` all return self-contained results.
* **Coarse invalidation** via `invalidateRoute(route)` rather than fine-grained `invalidateLeader()`, `invalidateCoordinator()`, `invalidateNode()`. A single method clears partition info, coordinators, broker info, and topic ID→name mappings for a route. Over-invalidation is acceptable because the cache is repopulated cheaply from the client's next METADATA request. This avoids an ever-growing set of invalidation methods as more cached entity types are added.
* **Router-driven invalidation** rather than runtime-driven. The runtime would need to deserialise an open-ended and growing set of response types to scan for staleness error codes. Different error codes have different semantics. Routers that don't use the topology cache shouldn't pay the deserialisation cost.
* **Shared node address map** — broker address resolution is per-router-level (`ConcurrentHashMap`), not per-connection. Required because the shared topology cache means a leader virtual node ID cached from one connection's METADATA must be resolvable to a broker address on another connection.
* **Topic ID resolution via `TopologyService.topicNames(String route, Set<Uuid>)`** is async, batched, and route-scoped, consistent with `leaders()` and `coordinators()`. An earlier design had a synchronous `topicName(Uuid)` on `RouterContext`, preloaded by an internal filter before `onRequest()`. This was removed because it silently swallowed resolution errors (returning null for both "not yet resolved" and "topic deleted") and was inconsistent with the async discovery pattern. Routers that need topic names collect IDs from the request, call `topicNames()`, and pass the resolved map to decomposers. The route parameter is required because per-route filter chains can transform topic names differently: the same cluster-level topic ID can map to different router-visible names on different routes. When `allowSharedClusterTargets()` is in effect, omitting the route would cause the cache to return whichever name was written last, silently corrupting routing decisions.
* **Routes must target distinct clusters by default.** The runtime rejects configurations where two routes in the same router resolve (directly or transitively) to the same cluster, because most routers assume each route is a distinct destination. Router factories that handle shared cluster targets (e.g. aliasing the same cluster under different prefixes) call `allowSharedClusterTargets()` during `initialize()` to suppress the check. The check runs in the internal `RouterChainFactory` after factory initialization, not in the internal `RouterGraphValidator`, because it depends on the factory's runtime declaration.
* **`routeNames()` in `RouterFactoryContext`** allows router factories to validate at initialization time that route names referenced in their plugin configuration actually exist, providing early feedback on configuration errors.
* **`target` as a discriminated union** provides a uniform way to express "what does this connect to" across both virtual clusters and routes, with the type (`cluster` or `router`) made explicit inside the object.
* **Routes are scoped to their parent router**, not top-level entities. Route names must be unique within the containing router. This avoids a fourth top-level definition list and reflects the fact that a route's meaning depends on its router.
* **Explicit route `id`** decouples the virtual node ID mapping from route ordering. The `id` is an integer in `[0, S)` used in the formula `V = id + S × t`. Making it explicit means reordering routes in the YAML does not change the mapping, avoiding accidental virtual node ID shifts that would invalidate connected clients' cached metadata.
* **Routes generalise filter chains.** A route may carry its own filter list in addition to a target, allowing different filter chains for different paths through the graph.
* **Route-level SASL** (e.g. SASL initiator for upstream authentication) is achieved via per-route filters rather than a dedicated route-level property. `SaslInitiator` filters on per-route chains authenticate the proxy to the upstream cluster; they do not affect `authenticatedSubject()`. Placement rules for SASL plugins are described in the `RouterContext` section above.
* **Definition names** are global within their type (filters, routers, clusters each have their own namespace) but not across types.
* **Version capping is the router's responsibility**, not the runtime's. The runtime provides the baseline intersection of proxy and backend version ranges; routers may further constrain as needed.
