# 000 - Router API: `ClientAddressing` sealed interface

This proposal refines the Router API introduced in [Proposal 070](070-routing-api.md)
by introducing a `ClientAddressing` sealed interface that replaces the opaque
`VirtualNode` marker with domain-typed alternatives: `Bootstrap` for connections to the
virtual cluster's bootstrap address and `Broker` for broker-specific connections.

## Current situation

Since 0.22.0 the Router API exposes two query methods on `RouterContext` that describe
how the current client connection is positioned in the cluster topology:

```java
// "Is the client connected to a specific broker?"
Optional<VirtualNode> virtualNode();

// "Give me a dispatch token so I can send to any broker on a route."
VirtualNode anyNode(String route);
```

`VirtualNode` itself is an opaque marker interface with no accessible state:

```java
public interface VirtualNode {}
```

Together these methods work like this in practice:

```java
// Bootstrap / initial connection — forward to any broker on the default route
if (ctx.virtualNode().isEmpty()) {
    var node = ctx.anyNode("default");
    return ctx.sendRequest(node, header, request)
               .thenCompose(body -> ctx.respondWith(body).completed());
}

// Broker-specific connection — forward to that exact broker
return ctx.sendRequest(ctx.virtualNode().get(), header, request)
           .thenCompose(body -> ctx.respondWith(body).completed());
```

## Motivation

### 1. `Optional` as a type-level distinction is weak

`Optional<VirtualNode>` signals "might be empty", not "is a bootstrap connection".
A router author who sees `Optional` thinks _nullable value_, not _connection phase_.
The semantic — "empty means you connected to a bootstrap address" — is only discoverable
from documentation, not from the type.

### 2. `anyNode()` conflates two distinct operations

`anyNode()` returns a `VirtualNode`, but a bootstrap entry point is not a node.
The caller only uses the return value by passing it directly to `sendRequest()`.
The two-step pattern (`anyNode()` + `sendRequest()`) is really a single route-dispatch
operation that should be expressed atomically:

```java
ctx.sendToRoute("default", header, request);
```

The indirection through `VirtualNode` is a historical artefact: the 0.22.0 design
envisaged `anyNode()` as a node-selection step separate from request dispatch, but no
use case has emerged where a router selects a node and then decides later whether to
actually send to it.

### 3. `VirtualNode` carries no identity

Because `VirtualNode` is an opaque marker, routers cannot reason about which broker
they are targeting at the API level. This is intentional for some cases (the runtime
selects the broker for bootstrap requests) but not for broker-specific connections,
where the broker identity is meaningful and should be surfaced.

### 4. The type system does not reflect the domain

Kafka's domain has clear concepts for the nodes a client connects to — brokers are
first-class entities with integer node IDs. Bootstrap, by contrast, is not a Kafka
domain concept but a proxy-level addressing mechanism — the proxy exposes a discovery
address that does not correspond to a specific cluster node.

The current API collapses both into a single opaque `VirtualNode` type, erasing the
domain distinction between "a specific Kafka broker" and "a proxy discovery address."

## Proposal

### `ClientAddressing` sealed interface

```java
public sealed interface ClientAddressing permits Bootstrap, Broker {}
```

`ClientAddressing` represents how the client addressed the proxy — either via a
bootstrap discovery address or via a specific broker. The name reflects that this is
determined by the client's choice of address, not by the router's decision.

**`Bootstrap`** — the client connected to a bootstrap address. This is a proxy concept,
not a Kafka domain concept. There is no specific node and no node ID:

```java
public record Bootstrap() implements ClientAddressing {}
```

`Bootstrap` is intentionally empty. Adding fields later (e.g. for observability) is
source-compatible for routers that pattern-match on `Bootstrap`.

**`Broker`** — the client connected to a broker-specific address. `Broker` replaces the
opaque `VirtualNode` marker with a domain-typed record carrying the virtual node ID:

```java
public record Broker(int id) implements ClientAddressing {}
```

The `id` is the virtual (client-facing) node ID assigned by the proxy — it is not the
upstream (target-cluster) node ID. The Kafka wire protocol serializes node identity as
integers, so `nodeForId(int)` bridges from protocol messages into the typed handle and
`id` provides the reverse when routers need the integer form. The Router API still
prefers working in terms of `Broker` instances rather than raw integers.

### Replace `virtualNode()` with `clientAddressed()`

```java
// Replaces Optional<VirtualNode> virtualNode()
ClientAddressing clientAddressed();
```

Router authors use pattern matching:

```java
switch (ctx.clientAddressed()) {
    case Bootstrap b   -> /* discovery path — forward to any broker on a route */
    case Broker broker -> /* broker-specific path — forward to that broker */
}
```

This makes the distinction exhaustive, compiler-checkable, and self-documenting.

### Replace `nodeForId(int)` with `brokerFor(int)`

```java
// Replaces VirtualNode nodeForId(int virtualNodeId)
Broker brokerFor(int virtualNodeId);
```

Proposal 070 described `nodeForId(int)` as "permanent, not transitional" because routers
will always need to interpret integer node IDs from Kafka protocol messages (METADATA
responses, FIND_COORDINATOR responses, partition-leader references). That remains true —
`brokerFor(int)` serves the same wire-protocol bridge function. The change is the return
type (`Broker` instead of `VirtualNode`) and the name (reflecting the domain type), not
the role.

### Add `sendRequest(Broker, ...)` overload

```java
CompletionStage<ApiMessage> sendRequest(Broker node,
                                         RequestHeaderData header,
                                         ApiMessage request);
```

This overload accepts the new `Broker` type directly. The existing
`sendRequest(VirtualNode, ...)` is deprecated but retained during the migration period.

### Replace `anyNode()` + `sendRequest()` with `sendToRoute()`

```java
// Replaces: var node = ctx.anyNode(route); ctx.sendRequest(node, header, request)
CompletionStage<ApiMessage> sendToRoute(String route, RequestHeaderData header, ApiMessage request);
```

`sendRequest(Broker, ...)` is retained for the broker-specific case, where the caller
already holds a `Broker` from `clientAddressed()` or `brokerFor(int)`.

### Migration

| 0.22 pattern | 0.23 equivalent |
|---|---|
| `ctx.virtualNode().isEmpty()` | `ctx.clientAddressed() instanceof Bootstrap` |
| `ctx.virtualNode().get()` | `ctx.clientAddressed()` as `Broker` via pattern match |
| `VirtualNode` (type references) | `Broker` |
| `ctx.anyNode(route)` + `ctx.sendRequest(node, ...)` | `ctx.sendToRoute(route, ...)` |
| `ctx.nodeForId(id)` | `ctx.brokerFor(id)` |

### Future extensibility

When KRaft controller-specific connections are needed, `Controller` can be added as a
peer alongside `Broker`:

```java
public sealed interface ClientAddressing permits Bootstrap, Broker, Controller {}

public record Controller(int id) implements ClientAddressing {}
```

If router code needs to handle `Broker` and `Controller` uniformly (e.g. for
`sendRequest()`), a shared interface can be introduced at that point:

```java
public interface VirtualNode { int id(); }

public record Broker(int id) implements ClientAddressing, VirtualNode {}
public record Controller(int id) implements ClientAddressing, VirtualNode {}
```

This reserves `VirtualNode` for its natural role — "a node in the virtual cluster" — as
the unifying interface for all node types with IDs, introduced only when a second node
type demands it.

## Affected/not affected projects

* `kroxylicious-api` — new `ClientAddressing` sealed interface, `Bootstrap` and `Broker`
  records added to `io.kroxylicious.proxy.router`; `VirtualNode` deprecated; `RouterContext`
  gains `clientAddressed()`, `sendToRoute()`, `brokerFor(int)`, and a
  `sendRequest(Broker, ...)` overload.
* `kroxylicious-runtime` — internal implementations updated to provide `ClientAddressing`
  instances through `RouterContext`.
* Not affected: filters, KMS, authoriser API, operator CRDs.

## Compatibility

### Deprecated API

`virtualNode()`, `anyNode()`, `nodeForId(int)`, `sendRequest(VirtualNode, ...)`, and
the `VirtualNode` type are deprecated in 0.23 and scheduled for removal in a future
minor release.

| Deprecated | Replacement | Mechanism |
|---|---|---|
| `VirtualNode` type | `Broker` | `Broker` extends `VirtualNode` during deprecation |
| `virtualNode()` | `clientAddressed()` | Default implementation delegates to `clientAddressed()` |
| `anyNode(route)` | `sendToRoute(route, ...)` | Default implementation delegates to runtime |
| `nodeForId(int)` | `brokerFor(int)` | Default implementation delegates to `brokerFor(int)` |
| `sendRequest(VirtualNode, ...)` | `sendRequest(Broker, ...)` | Deprecated overload retained |

**`VirtualNode`** is deprecated. `Broker` extends `VirtualNode` during the deprecation
period so that existing code consuming `VirtualNode` instances continues to compile.
Router authors migrate type references from `VirtualNode` to `Broker` at their own
pace. `VirtualNode` is removed when the deprecation cycle completes.

**`virtualNode()`** is given a default implementation that delegates to `clientAddressed()` —
returns `Optional.of(broker)` when `clientAddressed()` is a `Broker`, `Optional.empty()` for
`Bootstrap`. Source- and behaviour-compatible.

**`anyNode()`** is given a default implementation that delegates to the runtime's
existing route-dispatch mechanism, returning a `VirtualNode`. The result can be passed
to the deprecated `sendRequest(VirtualNode, ...)` overload. Source-, binary-, and
behaviour-compatible.

**`nodeForId(int)`** is given a default implementation that delegates to `brokerFor(int)`.
Source- and behaviour-compatible.

**`sendRequest(VirtualNode, ...)`** is retained as a deprecated overload alongside the
new `sendRequest(Broker, ...)`. This allows the existing `anyNode()` + `sendRequest()`
pattern to continue working during the migration period. New code uses
`sendToRoute()` for the bootstrap path and `sendRequest(Broker, ...)` for the
broker-specific path.

### Migration path

The deprecation of `VirtualNode` as a type is a rename, not a semantic change. Routers
consumed `VirtualNode` instances (they did not implement or extend the type), so
migration is mechanical: replace `VirtualNode` type references with `Broker`.

Taking this rename now — while the API is already breaking for `anyNode()` removal and
sealed interface introduction — avoids a harder break later. If `VirtualNode` were
retained as a record and later needed to be promoted to a sealed interface (to
accommodate `Controller`), that change would break code that has had time to settle
against the record type.

## Rejected alternatives

### Keep `Optional<VirtualNode>`

The `Optional` approach is technically workable but obscures the semantic distinction.
Router authors must learn from documentation that "empty means bootstrap", rather than
seeing it in the type. A sealed interface makes the two connection phases self-documenting
and compiler-checkable.

### Retain `anyNode()` as a separate step

The two-step `anyNode()` + `sendRequest()` pattern was designed for a use case (select
a node, then decide later whether to send) that has not materialised. The indirection
adds API surface without value. Collapsing it into `sendToRoute()` makes the operation
atomic and reduces the conceptual load on router authors.

### Make `Bootstrap` carry a route name

An earlier draft had `Bootstrap(String defaultRoute)` so that routers could inspect which
route was pre-selected. This was rejected because the bootstrap connection does not have
a pre-selected route — the router chooses the route at request time. Embedding a route name
in `Bootstrap` would suggest the runtime has already made a routing decision, which is
misleading.

### Two-level hierarchy with `VirtualNode` as sealed parent of `Broker` and `Controller`

An earlier draft used a two-level hierarchy where `VirtualNode` was a sealed interface
extending `ClientAddressing`, with `Broker` and `Controller` as its subtypes. This made
the `id()` contract explicit on `VirtualNode` and allowed pattern matching at two levels
of granularity.

This was rejected for two reasons. First, `Controller` is hypothetical — no current use
case requires controller-specific connections, so the second level exists only to
accommodate a speculative future type. Second, the flat hierarchy is strictly simpler and
does not foreclose the two-level design: if `Controller` is needed later, a unifying
`VirtualNode` interface can be introduced alongside it without breaking existing code
that uses `Broker`.

### Give `Bootstrap` a sentinel node ID

The Kafka client internally assigns negative IDs (-1, -2, -3) to bootstrap servers. This
is a client-side bookkeeping mechanism, not a protocol concept — negative IDs never appear
on the wire. Replicating this sentinel in the proxy API would undermine the purpose of
the sealed hierarchy, which exists precisely to eliminate sentinel-based reasoning.

### Keep `VirtualNode` as the type name (no deprecation)

Retaining `VirtualNode` and adding an `id()` accessor would minimise immediate migration
effort. However, `VirtualNode` is generic — it does not communicate that the connection
targets a _broker_ specifically. Renaming to `Broker` uses the Kafka domain term, making
the API self-documenting. It also avoids a harder future break: if `Controller` support
is needed, promoting a `VirtualNode` record to a sealed interface changes it from `final`
to non-final, potentially breaking exhaustiveness in downstream pattern matches. Using
`Broker` from the start leaves `VirtualNode` available as the natural name for the
unifying interface when it is needed.

## Design choices

### Domain-driven naming

`Broker` is the Kafka domain term for the node type that broker-specific connections
target. Using it directly makes the API self-documenting for router authors familiar
with Kafka. `Bootstrap` is a proxy concept — not a Kafka domain term — reflecting that
the proxy exposes a discovery address with no corresponding cluster node.

### Addressing as a framing

The connection's `ClientAddressing` can be understood through a networking lens: bootstrap
connections are _anycast_ (the runtime selects a node), while broker connections are
_directed_ (the client chose a specific node). This framing influenced the type name —
`ClientAddressing` communicates that the distinction is determined by how the client
addressed the proxy, not by a routing decision the router makes.

### Independent convergence

This proposal arrived at the bootstrap/broker distinction top-down from API ergonomics.
Separately, runtime work on port-binding separation (#4147) arrived at the same distinction
bottom-up from the networking layer — for different reasons.

At the networking layer, the proxy binds one bootstrap port and N broker-specific ports
per gateway. When a connection arrives, the registry resolves which virtual cluster and
which node it targets by examining the port it arrived on. That resolution has two
structurally different outcomes: a bootstrap connection has no specific broker assigned
yet (routing deferred to the upstream cluster), while a broker-specific connection must
reach a particular virtual node. The port-resolution index is therefore keyed by a sealed
type with the same two cases — `Bootstrap` and `Broker(nodeId)` — not because the API
design suggested it, but because those two connection kinds require different treatment
at the socket layer.

The fact that an API-layer analysis and an independent networking-layer analysis converged
on the same sealed two-case type gives confidence that the distinction reflects a genuine
domain boundary rather than a design preference of either layer.

### Rationale for a sealed type hierarchy

A sealed interface makes the set of valid addressing kinds closed and compiler-checkable.
Adding a new kind in the future (e.g. `Controller`) is a deliberate, documented API change
rather than a silent runtime surprise. `Optional<VirtualNode>` does not have this property:
it can only ever represent present-or-absent, not a richer taxonomy.
