# Request/Response Contextual Data API

Provide a mechanism within the Kroxylicious Filter API to allow filters to stash state during the Request phase and retrieve it during the corresponding Response phase without manual state management.

## Current situation

Currently, filters that need to associate data from a request with its future response (e.g., `AuthorizationFilter` or `EntityIsolationFilter`) must manually manage an internal `Map`. Typically, the filter stashes data using the Kafka `correlationId` as a key during the request path and removes ("pops") it during the response path.

## Motivation

Manual state management for correlated data is error-prone and introduces several risks:
* **Memory Leaks:** If a response never returns or a filter fails to "pop" the data, the internal map grows indefinitely.
* **Edge Case Complexity:** Authors must manually account for "zero-ack" Produce requests (which have no response) and scenarios where requests are dropped or short-circuited via the Filter API.
* **Boilerplate:** Every filter author must reimplement the same "store-and-retrieve" logic, leading to inconsistent implementations.

## Proposal

The proposal introduces a framework-managed "Contextual Data" store scoped to a single filter instance and a single Request/Response lifecycle.

### API Changes
To ensure type safety and prevent invalid states, the API will be updated to allow attaching data only when a request is being forwarded. This is best achieved by introducing a more fluent builder pattern.

**Request Path:**
Currently `FilterContext#forward` returns a terminal stage.

Instead of a simple terminal stage, we introduce a `forwardRequest` to handle the transition:
```java
return context.requestFilterResultBuilder()
              .forwardRequest(header, request)
              .withContextualData(myStateObject)
              .completed();
```

By including it in the command object from the Filter to the Framework we make it sympathetic
to asynchronously populated contextual data.

**Response Path:**
The context made available to the response filter will provide access to the stashed object:
```java
Optional<MyStateObject> data = context.contextualData();
```

### Implementation Considerations
* **Scoping:** The data is strictly scoped to the filter instance that created it. It is not shared with other filters in the chain to avoid implicit coupling.
* **Lifecycle Management:** The framework becomes responsible for "popping" the data. If a request is a zero-ack Produce request, the framework will proactively prevent or discard the stashed data to prevent leaks. If the Response Filter does not access the data, the framework will handle discarding the stashed data.
* **Data Structure:** Initially, the API will support a single state object. Since filter authors can define a custom `Record` or `POJO` to hold multiple values, a complex Key-Value map is deemed unnecessary at this stage.

## Affected/not affected projects

* **Affected:** `kroxylicious-api` (interface changes), `kroxylicious-runtime` (implementation of state management).
* **Not Affected:** `kroxylicious-filters` (until they are refactored to use the new API), external integration tests.

## Compatibility

* **Backward Compatibility:** The `forward` methods are retained as a naive forward is a common action when a Filter does not want to take any action. The convenience is worth carrying the two mechanisms for forwarding.
* **Forward Compatibility:** By using a builder pattern (`forwardRequest`), we create a path for future extensions.

## Rejected alternatives

* **Downstream Shared State:** Attaching data that is visible to other filters. This was rejected as it introduces "spooky action at a distance" and makes filter ordering too brittle. We prefer explicit message manipulation or tags for inter-filter communication.
* **API decoupled from the Filter Command:** You could alternatively offer methods on the FilterContext like `context.pushContextualData(x)`, but then you have to consider more edge-cases like Filters invoking it
at unpredictable times from uncontrolled threads.
* **Simple Method Overloading:** Adding `forward(header, request, data)` was rejected as it does not scale well if we need to add more parameters in the future and makes the `FilterContext` API cluttered.
