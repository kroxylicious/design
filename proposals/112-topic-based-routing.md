# 112 - Add `TopicPartitionRouter`

This proposal describes a `Router` implementation that presents multiple upstream Kafka clusters to clients as a single virtual cluster, routing requests based on topic ownership.

## Current situation

[Proposal 070](070-routing-api.md) introduced the `Router` plugin API, which enables the proxy to route requests to multiple upstream clusters.
No concrete `Router` implementation exists yet.

## Motivation

Organisations often operate multiple Kafka clusters — for scaling, isolation, geography, or organisational reasons.
A client is locked in to accessing only the topics available on the single cluster it connects to.
This creates operational headaches when an application needs to process data that lives across multiple clusters.

The options available today have stark compromises:

* **Multiple clients.** The application code can be changed to use multiple producer and/or consumer instances, one for each cluster. But this is not viable for all applications — transactions and consumer groups are scoped to a single cluster, so workflows that need cross-cluster transactions or coordinated consumption cannot use this approach.
* **Topic replication.** Tools like MirrorMaker 2 can replicate topics between clusters so that all the data an application needs lives in a single cluster. But this introduces operational burden (managing replication topologies), asynchrony (replicated data lags behind the source), and offset divergence (the same record has different offsets on source and replica, complicating failover and exactly-once semantics).

Data virtualization can address this by presenting a virtual cluster that is composed of multiple real clusters.
Clients connect to the virtual cluster and interact with it as if it were a single Kafka cluster.
The proxy transparently routes each request to the correct upstream cluster based on which cluster owns the topics involved.

The Kafka protocol makes this non-trivial.
Many request types batch operations across multiple topics in a single request (e.g. a `PRODUCE` request may contain records for topics owned by different clusters).
The router must decompose such requests, fan out the sub-requests in parallel, and recompose a single response.
Beyond basic produce and consume, stateful protocol features — idempotent producers, transactions, consumer groups, fetch sessions — each add further complexity.
This proposal addresses these features incrementally, with the simplest cases (produce, metadata) first and the more complex cases (transactions, consumer groups) building on that foundation.


## Proposal

### Overview

The data virtualization router partitions Kafka traffic across multiple upstream clusters using two complementary strategies:

**Topic-based partitioning.** 
Each topic is owned by exactly one upstream cluster.
The router determines the owning cluster from the topic name (via an unambiguous mapping) and routes data-plane operations accordingly.
When a single client request references topics on different clusters, the router decomposes the request, fans out the sub-requests, fans-in the sub-responses and recomposes a single response to be returned to the client.

Whether this decomposition is needed for a given API depends on the `NodeIdMapping` strategy in use (see proposal 070).
With a _dedicated_ (one-to-one) mapping, each virtual node belongs to exactly one route, so a well-behaved Kafka client's leader-directed requests (e.g. `PRODUCE`, `FETCH`) will naturally contain only topics from one route — no decomposition is needed for these APIs.
With a _shared_ (many-to-one) mapping — for example, if proxy instances are presented to clients as broker nodes — a single virtual node may serve brokers from multiple routes, and leader-directed requests _can_ contain topics from different routes.
The router does not know which mapping is in use, so it must handle the general case.
Decomposition is always required for non-leader-directed APIs such as `METADATA` and admin operations (`CREATE_TOPICS`, `DELETE_TOPICS`, etc.), regardless of the mapping strategy.

**Subject-based partitioning.**
Some Kafka protocol operations cannot be partitioned by topic because the topic is not known at the point where the routing decision must be made.

The clearest example is transactions.
The transactional protocol begins with `INIT_PRODUCER_ID` (which names only a `transactional.id`, not a topic) and proceeds through `ADD_PARTITIONS_TO_TXN` and `END_TXN`.
The router does not learn which topics are involved until `ADD_PARTITIONS_TO_TXN`, but by that point the transaction coordinator has already been chosen and the producer ID has been allocated on a specific cluster.
In principle the router could cache the mapping between the client's producer ID and each cluster's producer ID, but this mapping is not crash-safe: if the proxy restarts, the mapping is lost, and the client's in-flight transaction cannot be recovered.
Building a crash-safe mapping would require the proxy to maintain its own replicated state — effectively implementing a distributed transaction coordinator.

Subject-based partitioning avoids this problem entirely.
An authenticated user (a _subject_) is pinned to a specific route for all coordinator-bound operations (transactions, consumer groups).
Because the subject is determined at connection time (via SASL authentication), the router always knows which cluster should handle coordinator operations, without needing to inspect the request body.
Topic-addressed operations (`PRODUCE`, `FETCH`, etc.) continue to be decomposed by topic ownership as normal.

Consumer groups face a similar challenge: the group coordinator manages offsets and membership for the group as a whole, and these operations cannot be split across clusters.
Subject-based partitioning ensures that a given user's group operations always go to the same cluster.

Another way to think about this: The end user is forced to declare ahead-of-time which cluster each given subject's topics will all be in, at least for subjects corresponding to applications that use transactions or groups.

The following sections describe the detailed design of both strategies.

### Routing table

Topics are assigned to routes using a _routing table_ with three tiers:

1. **Explicit topic names** — a topic name listed directly in a route's configuration.
2. **Topic name prefixes** — a topic whose name starts with a prefix defined on a route. This is a convenience to save enumerating large numbers of topic names when all the topics with a prefix live in the same cluster.
3. **Default route** — a fallback route for topics that match no explicit name or prefix.

Precedence follows the order above: explicit name takes priority over prefix, prefix over default.

Prefixes must be _disjoint_ across routes: no route's prefix may be a prefix of another route's prefix.
This is validated at startup.
Without this constraint, a topic name could match multiple prefixes, making the routing decision ambiguous.

### Request decomposition

Each Kafka API has its own request and response schema, and many APIs batch operations across multiple topics in a single request.
A `PRODUCE` request, for example, may contain records for several topics, each potentially owned by a different cluster.
The router must split such requests by topic ownership, dispatch the sub-requests to the correct routes, and merge the responses.

This is handled by per-API _decomposers_ implementing a `RequestDecomposer<Req, Resp>` interface with two operations:

* **Decompose**: given a request, produce a map from route name to the sub-request for that route.
* **Recompose**: given the per-route responses, produce the merged response for the client.

Bespoke per-API handling is unavoidable because each API has a different request/response shape and different merging semantics.
For example, merging `METADATA` responses requires unioning broker lists by virtual node ID and taking the maximum of the response throttle times, 
whereas merging `PRODUCE` responses is a straightforward concatenation of per-topic-partition results.

Not every Kafka API key needs decomposition.
The Kafka protocol defines ~80 API keys, but only a subset reference topics or coordinators.
The router classifies each API key into one of two categories:

* **Dynamically routed** — the router deserialises the request, inspects it, and makes a per-request routing decision (potentially decomposing it across multiple routes). These are the API keys listed in the table below.
* **Statically routed** — the request is forwarded as an opaque frame to the default route without deserialisation. This applies to all API keys not in the table. The `Router.staticRoutes()` method (see proposal 070) declares these.

The following API keys are dynamically routed:

| Category | API keys | Decomposition strategy |
|----------|----------|----------------------|
| **Data** | `PRODUCE` | Split by topic ownership. Records for each topic sent to the owning route. |
| **Data** | `FETCH` | Split by partition leader (see _Leader caching_ below). |
| **Data** | `LIST_OFFSETS` | Split by partition leader. |
| **Metadata** | `METADATA` | Three variants: all-topics (fan out to all routes, filter responses to owned topics), empty-topics/broker-info-only (fan out to all routes for broker discovery), specific topics (split by ownership). Broker lists unioned by node ID. |
| **Metadata** | `API_VERSIONS` | Forwarded to the specific broker via `context.sendRequest(VirtualNode, ...)`; response capped (see _Version capping_). |
| **Metadata** | `FIND_COORDINATOR` | Subject-routed: forwarded to assigned route. Non-subject-routed: forwarded to the default route (both group and transaction coordinators). |
| **Metadata** | `DESCRIBE_CLUSTER` | Fan out to all routes; concatenate broker lists (no deduplication needed — the bijective node ID mapping guarantees distinct IDs per route). |
| **Offsets** | `OFFSET_COMMIT`, `OFFSET_FETCH` | Split by topic ownership (non-subject-routed) or forwarded to assigned route (subject-routed). |
| **Offsets** | `OFFSET_FOR_LEADER_EPOCH` | Split by partition leader. |
| **Admin** | `CREATE_TOPICS` | Split by topic ownership; reject explicit broker assignments (see _Assignment rejection_). |
| **Admin** | `DELETE_TOPICS` | Split by topic ownership. |
| **Admin** | `CREATE_PARTITIONS` | Split by topic ownership; reject explicit broker assignments. |
| **Admin** | `DELETE_RECORDS` | Split by partition leader. |
| **Idempotent** | `INIT_PRODUCER_ID` | Subject-routed: forwarded to assigned route. Transactional: sent to transaction coordinator on default route. Idempotent-only: fan out to all routes (see _Producer ID management_). |
| **Transactions** | `ADD_PARTITIONS_TO_TXN`, `END_TXN`, `ADD_OFFSETS_TO_TXN`, `TXN_OFFSET_COMMIT` | Subject-routed: forwarded to assigned route. |
| **Consumer groups** | `CONSUMER_GROUP_HEARTBEAT`, `CONSUMER_GROUP_DESCRIBE` | Subject-routed: forwarded to assigned route. |

#### Request flow

For dynamically routed requests, the typical flow is:

1. Decompose the request by topic ownership or partition leader.
2. Send sub-requests to the appropriate brokers via `context.sendRequest(VirtualNode, ...)`.
3. Collect responses and recompose them into a merged response.
4. Return `context.respondWith(mergedResponse).build()`.

For fire-and-forget requests (`PRODUCE` with `acks=0`), the router returns `context.respondWithoutReply().build()` instead.
To close the client connection (e.g. on an unrecoverable error), the router uses `context.respondWith(...).withCloseConnection().build()`.


### Version capping

`API_VERSIONS` is scoped to a single broker connection — the client sends it each time it connects to a new broker.
The router forwards `API_VERSIONS` to the specific broker and may cap the response.

The router caps the following versions:

| API key | Capped to version | Reason |
|---------|-------------------|--------|
| `ADD_PARTITIONS_TO_TXN` | v3 | v4+ uses broker-only batch format |
| `FIND_COORDINATOR` | v3 | v4+ adds batched coordinator keys (KIP-699) |


### Producer ID management

Kafka's idempotent producer protocol assigns each producer a unique _producer ID_ (PID) via `INIT_PRODUCER_ID`.
When producing to multiple clusters, each cluster must allocate its own PID.
The client, however, expects a single PID.

The router handles `INIT_PRODUCER_ID` differently depending on whether the producer is subject-routed, transactional, or idempotent-only:

* **Subject-routed users.** `INIT_PRODUCER_ID` is forwarded directly to the user's assigned route. No fan-out or coordinator discovery is needed because the user's topics all reside on that route.
* **Transactional producers (non-subject-routed).** The router discovers the transaction coordinator on the default route and sends `INIT_PRODUCER_ID` to that coordinator.
* **Idempotent-only producers (non-subject-routed).** The router fans out `INIT_PRODUCER_ID` to all routes. The PID from the default route is returned to the client as _its_ PID. The per-route PID mappings are stored in a shared in-memory `ProducerIdManager` (shared across all connections to the same virtual cluster, thread-safe). On `PRODUCE`, the router rewrites the record batch headers (producer ID and epoch) for non-default routes before forwarding.

Fanning out `INIT_PRODUCER_ID` to all routes for idempotent-only producers means that PIDs are allocated on clusters that may never receive any records from that producer.
This is a deliberate trade-off: it wastes PIDs on those clusters, but it allows the router to support idempotent producers (which are enabled by default since Kafka 3.0) using topic-based partitioning alone, without requiring subject-based routing.

PID mappings are evicted after a configurable TTL (default: 7 days).
If a mapping is evicted and a subsequent `PRODUCE` arrives, the router returns `UNKNOWN_PRODUCER_ID`, which causes the Kafka producer to re-initialise.


### KIP-227 fetch session management

KIP-227 introduced _incremental fetch sessions_: a stateful per-connection agreement between client and broker to reduce the amount of data on the wire by only transmitting changes to the consumer's topic partitions of interests since the last fetch.
With multiple backend clusters, the router must mediate between the client's session and per-route backend sessions.

The router implements _bidirectional session management_:

* **Server-side** (facing the client): the router acts as a session server, tracking which topic-partitions the client has registered.
* **Client-side** (facing the broker): the router acts as a session client for each backend route, independently managing sessions with each upstream cluster.

These two sides are independent: a pre-v7 client (no session support) can still benefit from server-side sessions with backends, and vice versa.

When a backend sends an _incremental_ response (containing only changed partitions), the router reconstructs a _full_ response using its cached session state before merging across routes.
This ensures the client always receives a complete picture.

Session state is bounded by a configurable cache:
* `maxFetchSessionCacheSlots` — maximum concurrent sessions across all connections (default: 1000).
* `minFetchSessionEviction` — minimum idle time before a session is eligible for eviction (default: 120 seconds).

Setting either to 0 will disable the fetch session support entirely.

When the client disconnects, the router releases server-side session state but does _not_ send session-close requests (`sessionId=N, epoch=-1`) to the backend brokers.
Backend sessions remain open until they expire naturally (controlled by the broker's `fetch.session.timeout.ms`).
This "impolite" closure wastes broker resources proportional to connection churn, but avoids the complexity of asynchronous backend cleanup on client disconnect.
A future improvement could send close requests on connection teardown.

Metrics are tagged with the virtual cluster and router name.


### Subject routing

As described in the _Overview_, subject-based partitioning pins an authenticated user to a specific route for coordinator-bound operations.
The configuration declares which subjects belong to which route (see _Configuration_ below).

The following operations are forwarded to the subject's assigned route without decomposition:
* `FIND_COORDINATOR` (group and transaction coordinators)
* `INIT_PRODUCER_ID`
* `ADD_PARTITIONS_TO_TXN`, `END_TXN`, `ADD_OFFSETS_TO_TXN`, `TXN_OFFSET_COMMIT`
* `CONSUMER_GROUP_HEARTBEAT`, `CONSUMER_GROUP_DESCRIBE`
* `OFFSET_COMMIT`, `OFFSET_FETCH` (when the subject is assigned to a route)

**Prerequisite**: subject routing requires that the client's identity is known, which in practice means SASL termination must occur before the router in the topology.
Note that, in general, "SASL inspection" does not work because SASL mechanisms often have protection against credential material reuse (e.g. SCRAM). It would work for PLAIN assuming the subject had the same password on each cluster.
Runtime validation of correct SASL plugin placement is out of scope for this proposal.


### Coordinator and leader caching

The router delegates all topology queries — partition leaders, transaction coordinators, and consumer group coordinators — to a `TopologyService` obtained from `RouterFactoryContext` during initialisation.
The router does not maintain its own caches for these lookups.

The `TopologyService` provides the following operations:

* **`leaders(topicsByRoute)`** — returns a `PartitionLeaders` view mapping `(topic, partition)` to the virtual node of the partition leader. On cache miss the service sends internal `METADATA` requests to the relevant routes. The cache is also populated as a side effect of `METADATA` responses flowing through the routing pipeline.

* **`coordinators(route, keyType, keys)`** — returns coordinator nodes for the given keys (transaction IDs or group IDs) on the specified route. On cache miss the service sends internal `FIND_COORDINATOR` requests.

* **`invalidateRoute(route)`** — invalidates cached leaders for a route. Called when the router observes `NOT_LEADER_OR_FOLLOWER` in a response. No background refresh is fired — the client's own `METADATA` request (triggered by the error) repopulates the cache.

* **`topicNames(route, topicIds)`** — resolves topic UUIDs to names for topic-ID-bearing protocol versions.

* **`canServeRoute(virtualNodeId, route)`** — **new method added to `TopologyService` by this proposal.** Returns whether a virtual node ID can serve as a broker for the given route. In a dedicated node mapping where each virtual node corresponds to exactly one backend broker, this returns `true` only when the node maps to the given route. In configurations where a single node can serve multiple routes, it may return `true` for more than one route. Used by the router to validate explicit broker assignments in `CREATE_TOPICS` and `CREATE_PARTITIONS` (see _Assignment rejection_).

The `TopologyService` instance is shared across all connections to the same virtual cluster, so leader and coordinator state discovered by one connection is immediately available to others.
Caching strategy, thread safety, and eviction are internal to the `TopologyService` implementation and not the router's concern.

Fetch session state, by contrast, is genuinely per-connection and lives in the `Router` instance (see _KIP-227 fetch session management_).


### Assignment rejection

`CREATE_TOPICS` and `CREATE_PARTITIONS` accept optional explicit broker assignments (replica placement lists that name specific broker node IDs).
The virtual cluster presents a union of all broker nodes across routes, so an assignment could reference virtual node IDs from different clusters, which would be meaningless on any single backend.

The router validates each broker ID in the assignment using `TopologyService.canServeRoute(virtualNodeId, owningRoute)`.
If all referenced nodes can serve the topic's owning route, the assignment is valid and is forwarded to the target cluster.
If any broker ID cannot serve the owning route (i.e. it belongs to a different route), the router returns `INVALID_REPLICA_ASSIGNMENT` (error code 39, non-retriable) early, rather than forwarding a request that would produce confusing errors from the backend.

Automatic broker placement (the default, when no assignments are specified) works correctly: each backend cluster assigns replicas among its own brokers.


### Configuration

Here's an example:

```yaml
router:
  type: TopicPartitionRouterFactory
  config:
    defaultRoute: route-a
    producerIdTtl: PT168H                # optional; default 7 days (ISO-8601)
    maxFetchSessionCacheSlots: 1000      # optional
    minFetchSessionEviction: PT2M        # optional; default 120 seconds (ISO-8601)
    routes:
      - name: route-a
        topics: ["important-topic"]
        topicPrefixes: ["orders.", "payments."]
        subjects: [alice, bob]
      - name: route-b
        topicPrefixes: ["analytics.", "logs."]
        subjects: [charlie]
  routes:
    - name: route-a
      id: 0
      target:
        cluster: cluster-a
    - name: route-b
      id: 1
      target:
        cluster: cluster-b
```

**Route configuration properties:**

| Property | Description |
|----------|-------------|
| `topics` | Explicit topic names owned by this route. Takes precedence over prefixes. |
| `topicPrefixes` | Topic name prefixes owned by this route. Must be disjoint across routes. |
| `subjects` | Authenticated usernames pinned to this route for coordinator-bound operations. |

**Router configuration properties:**

| Property | Default | Description |
|----------|---------|-------------|
| `defaultRoute` | (none) | The route used for topics that match no prefix or explicit name, and for statically-routed APIs. If not set, unmatched topics receive `UNKNOWN_TOPIC_OR_PARTITION` errors. |
| `producerIdTtl` | `PT168H` (7 days) | TTL for producer ID mappings before eviction. ISO-8601 duration. |
| `maxFetchSessionCacheSlots` | `1000` | Maximum concurrent fetch sessions across all connections. |
| `minFetchSessionEviction` | `PT2M` (120 seconds) | Minimum idle time before a fetch session is eligible for eviction. ISO-8601 duration. |


## Metrics

The topic router emits the following metrics in addition to the per-route metrics provided by the runtime (see proposal 070):

* **Fetch session metrics** — tagged by virtual cluster and router name:
  * `kroxylicious_fetch_session_active_sessions` (Gauge) — currently active client-side fetch sessions.
  * `kroxylicious_fetch_session_partitions_cached` (Gauge) — total cached partition count across sessions.
  * `kroxylicious_fetch_session_evictions_total` (Counter) — cumulative fetch session evictions.
* **Assignment rejection counter** — incremented when a `CREATE_TOPICS` or `CREATE_PARTITIONS` request is rejected due to explicit broker assignments.

#### Cardinality analysis

| Tag | Typical values | Bound |
|-----|---------------|-------|
| virtual cluster | 1–3 | Bounded by configuration. |
| router name | 1 per virtual cluster | Bounded by configuration. |

The fetch session metrics produce 3 series per virtual cluster (two gauges, one counter). With 3 virtual clusters, this is 9 series.

The assignment rejection counter is a single series per router. Negligible cardinality.

These are well within the bounds of standard monitoring deployments.

## Design choices

* **"TopicPartitionRouter" naming.** The router was originally proposed as "DataVirtualization" (named for what it _does_), but was implemented as `TopicPartitionRouter` (named for its primary routing dimension). "Federation" was rejected because it implies mutual awareness between the federated systems, whereas this is unilateral.
* **Two complementary partitioning strategies.** Topic-based partitioning handles data-plane operations; subject-based partitioning handles coordinator-bound operations. This split is driven by the protocol: transaction and group coordinator state cannot be decomposed by topic because the topic is not known at coordinator-selection time, and the proxy cannot maintain crash-safe coordinator state without replicated storage.
* **Per-API decomposers** rather than a single dispatch method. Each Kafka API has different request/response shapes and merging semantics. Decomposers are independently testable and new APIs can be added incrementally without modifying existing code.
* **Disjoint prefix enforcement** at startup. Overlapping prefixes would make routing ambiguous. Validating disjointness early (at configuration time) avoids subtle runtime bugs.
* **SASL termination prerequisite.** Subject routing requires the client's identity to be known, which means SASL termination must be configured upstream. This is documented as a deployment requirement; runtime validation of correct SASL plugin placement is deferred to a future proposal.
* **Topic ID resolution via `TopologyService.topicNames()`.** The router resolves topic IDs to names using a cache built from `METADATA` responses, allowing it to handle topic-ID-based protocol versions (e.g. `PRODUCE` v13+) without version capping.
* **PID fan-out to all routes for idempotent-only producers.** For non-subject-routed idempotent-only producers, `INIT_PRODUCER_ID` is fanned out to all routes, wasting PIDs on clusters that may never receive records from that producer. This is a deliberate trade-off: it allows idempotent producers (the default since Kafka 3.0) to work with topic-based partitioning alone, without requiring subject-based routing. Subject-routed users and transactional producers avoid the fan-out — the former are forwarded to their assigned route, the latter are sent to the transaction coordinator on the default route.
* **Assignment validation, not blanket rejection.** `CREATE_TOPICS` and `CREATE_PARTITIONS` with explicit broker assignments are validated per-broker using `TopologyService.canServeRoute(virtualNodeId, owningRoute)`. Assignments that reference only nodes that can serve the topic's owning route are permitted and forwarded to the backend; cross-route assignments are rejected early with `INVALID_REPLICA_ASSIGNMENT`. The `canServeRoute` contract is designed to accommodate future networking models where a single virtual node may serve multiple routes.
* **Topology queries delegated to `TopologyService`.** The router does not maintain its own leader or coordinator caches. Instead it delegates all topology lookups to a `TopologyService` obtained from `RouterFactoryContext`. The service is shared across all connections to the same virtual cluster, so discoveries are amortised. Caching strategy and thread safety are internal to the service, keeping the router focused on request decomposition. Fetch session state remains per-connection because it tracks per-connection session agreements.
* **Bounded fetch session cache.** Unbounded caches risk memory exhaustion under high connection counts. The configurable bound with LRU eviction provides a predictable memory footprint.
* **Producer ID TTL eviction.** PID mappings cannot be kept indefinitely. The 7-day default TTL balances mapping longevity against memory growth. Eviction triggers a client-side re-initialisation, which is safe.


## Affected/not affected projects

* **New module**: `kroxylicious-router-topic` — the `TopicPartitionRouter` implementation, decomposers, fetch session management, producer ID management, routing table.
* **`kroxylicious-api`** — adds `canServeRoute(int, String)` to `TopologyService` (see _Coordinator and leader caching_ and _Assignment rejection_).
* **`kroxylicious-runtime`** — minor additions: node address caching for `sendRequest()` resolution.
* **Not affected**: existing filters, KMS, authoriser API, Kubernetes operator.


## Compatibility

* This is a new module with no existing users, so there are no backwards-compatibility concerns.
* The module depends on the `Router` API from proposal 070 and will be released alongside (or after) the runtime changes from that proposal.


## Rejected alternatives

* **Single monolithic request handler.** We considered handling all API keys in a single method rather than per-API decomposers. This was rejected because each Kafka API has a different request/response schema and different merging semantics. Per-API decomposers are more testable, more maintainable, and make it easier to add support for new APIs incrementally.

* **Proxy-level transaction coordinator.** We considered implementing a full transaction coordinator within the proxy, allowing transactions to span multiple clusters. This was rejected because it would require replicated state across proxy instances (essentially building a distributed coordinator) — a large undertaking with significant operational complexity. Subject routing provides a simpler and more predictable solution for the common case where each user's transactions are scoped to a single cluster.

* **Automatic prefix inference.** We considered inferring topic-to-route mappings automatically from cluster metadata rather than explicit configuration. This was rejected because explicit configuration is safer, more predictable, and auditable. Automatic inference could lead to surprising behaviour if topics are created on unexpected clusters.

* **Cross-cluster consumer group coordination.** We considered coordinating consumer groups across clusters, allowing a single consumer group to consume from topics on multiple backends. This was rejected as infeasible without proxy-level state (the proxy would need its own group coordinator). Subject routing avoids the problem by pinning each user's group operations to a single cluster.


## Limitations and future work

* **Classic consumer groups are not supported.**
  Only the KIP-848 consumer group protocol (`CONSUMER_GROUP_HEARTBEAT`, `CONSUMER_GROUP_DESCRIBE`) is dynamically routed.
  The classic group protocol APIs (`JOIN_GROUP`, `SYNC_GROUP`, `LEAVE_GROUP`, `HEARTBEAT`, `LIST_GROUPS`, `DESCRIBE_GROUPS`, `DELETE_GROUPS`) are statically routed to the default route.
  This means classic consumer groups function only on the default route's cluster; group operations are not decomposed across routes.
  Supporting the classic protocol would require decomposers for these APIs and proxying group coordinator state, which is comparable in complexity to the cross-cluster consumer group coordination rejected above.

* **No topic migration.**
  Once a topic is assigned to a route — via explicit name, prefix match, or default route — it cannot be moved to a different route without changing the routing configuration and migrating the topic's data out-of-band.
  The router has no mechanism for live topic migration between backend clusters.

* **Share Groups, Streams Groups, and KIP-939 two-phase commit are not supported.**
  These newer Kafka features introduce additional protocol APIs and coordinator types that the router does not handle.
  Their API keys are statically routed to the default route.
  Adding support would require new decomposers and potentially new routing strategies (e.g. share group coordinators).

* **Impolite fetch session closure.**
  When a client disconnects, the router releases its own server-side session state but does not send session-close requests to backend brokers (see _KIP-227 fetch session management_).
  Backend sessions remain open until they expire via the broker's `fetch.session.timeout.ms`.



