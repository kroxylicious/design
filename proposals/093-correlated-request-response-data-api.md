# 93 - Request/Response Correlated Data API

Provide a mechanism within the Kroxylicious Filter API to allow filters to stash state during the Request phase and retrieve it during the corresponding Response phase without manual state management.

## Current situation

Currently, filters that need to associate data from a request with its future response (e.g., `AuthorizationFilter` or `EntityIsolationFilter`) must manually manage an internal `Map`. Typically, the filter stashes data using the Kafka `correlationId` as a key during the request path and removes ("pops") it during the response path.

Each Filter has so far had to hand-roll this code.

Keying by `correlationId` is also unsafe against the runtime as it stands today. The proxy no longer correlates requests to responses by `correlationId`; it carries a routing value (`PathElement`) on the frame and restores it onto the response (`CorrelationManager`, `KafkaResponseDecoder`). Out-of-band requests a filter issues via `FilterContext#sendRequest` draw their id from a dedicated allocator over `[Integer.MIN_VALUE, 0)`, distinct per request, precisely so filters that key their own bookkeeping off `correlationId` do not collide. A filter keying its own map off `correlationId` is duplicating, by hand, a correlation the framework already performs on the frame.

## Motivation

Manual state management for correlated data is error-prone and introduces several risks:
* **Memory Leaks:** If a response never returns or a filter fails to "pop" the data, the internal map grows indefinitely.
* **Edge Case Complexity:** Authors must be aware of and manually account for "zero-ack" Produce requests (which have no response) and scenarios where requests are dropped or short-circuited via the Filter API.
* **Boilerplate:** Every filter author must reimplement the same "store-and-retrieve" logic, leading to inconsistent implementations.

## Proposal

The proposal introduces a framework-managed "Correlated Data" store scoped to a single filter instance and a single Request/Response lifecycle.

### API Changes
To ensure type safety and prevent invalid states, the API will be updated to allow attaching data only when a request is being forwarded. This is best achieved by introducing a more fluent builder pattern.

**Request Path:**
Currently `FilterContext#forwardRequest` returns a terminal stage.

Instead of a simple terminal stage, we introduce a `forwardRequestBuilder` to handle the transition:
```java
return context.requestFilterResultBuilder()
              .forwardRequestBuilder(header, request)
              .withCorrelatedData(myStateObject)
              .completed();
```

By including it in the command object from the Filter to the Framework we make it sympathetic
to asynchronously populated correlated data.

**Response Path:**
The context made available to the response filter will provide access to the stashed object:
```java
Optional<MyStateObject> data = context.correlatedData();
```

### Implementation

The correlated data rides the frame, on the same rails the runtime already uses to carry a frame's routing value across its lifecycle. The filter never sees this; it only calls `withCorrelatedData` and later `correlatedData()`.

* **Storage:** A new field on the frame holds a map from filter identity to that filter's stashed object. Filter identity is the filter's name plus its ordinal within the chain, the same pair `PathElement.FilterOriginator` already uses to disambiguate two filters sharing a name. A map is required because a request passes through many filters, each of which may stash. Each filter reads back only its own entry.
* **Separate from routing:** The map is its own frame field, not folded into the `PathElement`. The routing value is replaced wholesale at route resolution (`graft`/`reposition`); a separate field is left untouched by that.
* **Carrying across the response boundary:** Three paths already reconstruct a response frame from its request. The correlated-data map follows each:
  * Broker round trip. The map cannot go on the wire, so it is held in `CorrelationManager.Correlation` alongside the routing value and restored onto the response frame in `KafkaResponseDecoder`.
  * Short-circuit. `handleShortCircuitResponse` builds the response via `DecodedRequestFrame#responseFrame`, which copies the map across.
  * Out-of-band. `InternalRequestFrame#createResponseFrame` copies the map across.

  The only new work is widening `Correlation` and the `createResponseFrame` copy. No new delivery mechanism.

### Lifecycle and leak safety

Binding the data to the frame removes the leak class the manual map suffers. The map's lifetime is the frame's lifetime, so:

* **Zero-ack Produce:** no response frame is built, the request frame is collected, the map dies with it.
* **Short-circuit above a filter:** a filter nearer the broker that stashed on the request path never runs its response phase when a filter above it short-circuits. Its entry is simply never read and is collected with the frame.

So the framework does not "pop to prevent leaks". It hands a filter its entry on the response path and discards the rest when the frame is collected. Correcting the earlier framing: popping exists to deliver, not to prevent leaks.

### Scoping and open questions

* **Scoping:** The data is strictly scoped to the filter instance that created it. It is not shared with other filters in the chain to avoid implicit coupling.
* **Observed out-of-band responses:** an OOB response is restored with routing so the issuing route's filters can observe it. A route-scoped filter could therefore stash on an OOB request it merely observed and then observe the OOB response. `correlatedData()` is scoped to the pair (filter instance, this frame), not (filter instance, client request). This must be stated in the API contract so a filter does not assume its entry refers only to client traffic it forwarded.
* **Threading:** the stash is written on the request path and read on the response path. Both run on the connection's event loop, so no cross-thread publication is involved. Asynchronously populated data is handled by populating the command object before `completed()`, not by writing the frame from an uncontrolled thread.
* **Data Structure:** Initially, the API will support a single state object per filter. Since filter authors can define a custom `Record` or `POJO` to hold multiple values, a complex Key-Value map within a filter's own entry is deemed unnecessary at this stage.

## Affected/not affected projects

* **Affected:** `kroxylicious-api` (interface changes), `kroxylicious-runtime` (implementation of state management).
* **Not Affected:** `kroxylicious-filters` (until they are refactored to use the new API), external integration tests.

## Compatibility

* **Backward Compatibility:** The `forward` methods are retained as a naive forward is a common action when a Filter does not want to take any action. The convenience is worth carrying the two mechanisms for forwarding.
* **Forward Compatibility:** By using a builder pattern (`forwardRequestBuilder`), we create a path for future extensions.

## Rejected alternatives

* **Downstream Shared State:** Attaching data that is visible to other filters. This was rejected as it introduces "spooky action at a distance" and makes filter ordering too brittle. We prefer explicit message manipulation or tags for inter-filter communication.
* **API decoupled from the Filter Command:** You could alternatively offer methods on the FilterContext like `context.pushCorrelatedData(x)`, but then you have to consider more edge-cases like Filters invoking it
at unpredictable times from uncontrolled threads.
* **Simple Method Overloading:** Adding `forward(header, request, data)` was rejected as it does not scale well if we need to add more parameters in the future and makes the `FilterContext` API cluttered.
