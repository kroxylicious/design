# 000 - Expose the route of a VirtualNode to Routers

Add `Optional<String> routeOf(VirtualNode)` to `RouterContext` so a `Router` can learn which of its routes a `VirtualNode` belongs to, while keeping `VirtualNode` opaque.

## Current situation

[Proposal 070](./070-routing-api.md) makes `VirtualNode` an opaque handle.
The runtime knows the route behind each `VirtualNode` (it derives it in `sendRequest()` via `NodeIdMapping.fromVirtual()`), but routers cannot read it.
`RouterContext.virtualNode()` returns the node the client connected to, or empty for a bootstrap connection.

## Motivation

A router may want to confine a connection to one route.
Because the client chooses the broker-specific address it connects to, `virtualNode()` can return a node belonging to any route in the topology, including a route the client should not reach.
A malicious client can connect to a node ID that maps to a different route and rely on the router forwarding to it.
The router has no way to detect this today.

The same information supports other checks, for example verifying that a produce request arrived on the node that leads the topic partition (see [#4606](https://github.com/kroxylicious/kroxylicious/issues/4606)).

## Proposal

Add one method to `RouterContext`:

```java
interface RouterContext {
    /**
     * @return the name of the route that the given node belongs to, or empty if the node is not
     * associated with exactly one of this router's routes.
     */
    Optional<String> routeOf(VirtualNode node);
}
```

Usage:

```java
Optional<VirtualNode> connected = context.virtualNode();
if (connected.isPresent() && !context.routeOf(connected.get()).equals(Optional.of(allowedRoute))) {
    return context.respondWithError(header, request, new InvalidRequestException()).close();
}
```

Semantics:

* The runtime resolves the route from the `NodeIdMapping`. `VirtualNodeImpl` already carries the data.
* With the current dedicated (one-to-one) mapping the result is always present for nodes obtained from `virtualNode()`, `nodeForId(int)` and `anyNode(route)`. `routeOf(anyNode(r))` returns `r`.
* A future shared (many-to-one) mapping, or any topology where a node is not tied to one route, returns empty. Routers that need confinement must treat empty as "not permitted", not as "permitted".
* The returned name is one of the router's own route names, as configured in its `RouterDefinition`.

### Why `RouterContext` and not `VirtualNode.route()`

* `VirtualNode` is opaque by design (070). A `route()` accessor makes "one node, one route" part of the type's contract and breaks the shared-mapping case that 070 explicitly preserves.
* `Optional<String> route()` on `VirtualNode` would work, but it commits every `VirtualNode` implementation to answer the question without runtime context. A method on `RouterContext` lets the runtime answer from its mapping and scope the answer to the calling router's routes (relevant for nested routers).
* It follows the existing pattern: `nodeForId(int)` also lives on `RouterContext` because the runtime owns the mapping.

## Affected/not affected projects

* `kroxylicious` `kroxylicious-api`: new method on `RouterContext`.
* `kroxylicious` `kroxylicious-runtime`: implement it in `RouterContextImpl`.
* Operator, filters and other projects: not affected.

## Compatibility

* Purely additive. Only the runtime implements `RouterContext`; routers call it. Test doubles of `RouterContext` need the new method.
* The `Optional` return leaves room for networking models where a node has no single route, without changing the signature.

## Rejected alternatives

* **`String route()` on `VirtualNode`**: non-optional, so it rules out shared mappings.
* **`Optional<String> route()` on `VirtualNode`**: handles shared mappings but weakens the opacity of `VirtualNode` and removes the runtime's ability to scope the answer to the calling router.
* **Router performs the check from node ID arithmetic**: contradicts 070, which forbids routers from inspecting node IDs, and breaks under alternative networking models.
