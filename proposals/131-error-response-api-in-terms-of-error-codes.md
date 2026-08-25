# 131 - Express the error-response API in terms of error codes, not client exceptions

> [!NOTE]
> This proposal is based on [kroxylicious#4756](https://github.com/kroxylicious/kroxylicious/issues/4756) and complements
> [proposal 116 - Own the Kafka Protocol API Surface](./116-kafka-api-migration.md).

The short-circuit error-response entry points on the public Filter and Router APIs take a Kafka
*client exception* (`org.apache.kafka.common.errors.ApiException`). This proposal re-expresses them
in terms of an error *code* (`Errors`) plus an optional message, removing the last places where the
`kafka-clients` exception hierarchy leaks into the Kroxylicious public API.

## Current situation

Two methods on the public API let a filter or router short-circuit a request with an error response:

```java
// io.kroxylicious.proxy.filter.RequestFilterResultBuilder
CloseOrTerminalStage<RequestFilterResult> errorResponse(
        RequestHeaderData header, ApiMessage requestMessage, ApiException apiException);

// io.kroxylicious.proxy.router.RouterContext
RouterResult respondWithError(
        RequestHeaderData header, ApiMessage requestMessage, ApiException apiException);
```

Both take `org.apache.kafka.common.errors.ApiException`. A caller who simply wants to reply "this is
`INVALID_REQUEST`" must first find, then instantiate, a matching exception subclass:

```java
context.requestFilterResultBuilder()
        .errorResponse(header, request, new InvalidRequestException("no topic id tag"))
        .completed();
```

Internally the runtime immediately reverses that: `KafkaProxyExceptionMapper` derives an error
**code** (`Errors.forException`) and a **message** (`Throwable.getMessage()`) from the exception, and
feeds them to Kafka's `AbstractRequest.getErrorResponse(Throwable)`. So the caller constructs an
exception purely so the runtime can map it back to the code the caller already had in mind.

This is the last of the concerns identified in proposal 116: the `*Data` message classes, protocol
infrastructure, record classes and scattered `common.*` types are all addressed there, but the
`ApiException` hierarchy on these two entry points is a distinct API-shape problem — it is not a
namespace move, it is the wrong abstraction — and is called out separately in #4756.

## Motivation

- **Wrong abstraction.** The concept a caller wants to express is an error *code* (optionally with a
  human-readable message). Requiring an exception forces the caller to pick a subclass from Kafka's
  ~150-strong `ApiException` hierarchy and trust that `Errors.forException` maps it back to the code
  they intended. The round-trip is lossy and non-obvious: two different exception subclasses can map
  to the same code, and constructing the "wrong" exception silently yields a different code.
- **Keeps `kafka-clients` on the API surface.** Proposal 116 removes the generated `*Data` classes
  and protocol infrastructure from the API. If these two methods keep taking `ApiException`, the
  `kafka-clients` exception classes remain a compile-time dependency of every filter that
  short-circuits, undermining the goal of a self-contained, Kroxylicious-owned API surface for 1.0.
- **Enables the owned-`Errors` payoff.** Once the API speaks in `Errors` codes rather than exception
  instances, the `Errors` type itself can later be swapped for a Kroxylicious-owned enum (the follow
  on to #4752/#4755). That swap is what ultimately allows the ~150 vendored `ApiException` subclasses
  to be dropped from the owned surface entirely — the real payoff described in #4756. It is only
  reachable once the *shape* of the API no longer demands an exception.

## Proposal

Introduce `Errors`-based overloads, deprecate the exception-based overloads, and widen the deprecated
overloads' parameter from `ApiException` to `java.lang.Throwable` so the `kafka-clients` reference
leaves the API *signature* immediately.

### New overloads

On both `RequestFilterResultBuilder.errorResponse` and `RouterContext.respondWithError`:

```java
// code only — uses the Errors default message
errorResponse(RequestHeaderData header, ApiMessage requestMessage, Errors error);

// code plus an explicit message
errorResponse(RequestHeaderData header, ApiMessage requestMessage, Errors error, @Nullable String message);
```

`Errors` is `org.apache.kafka.common.protocol.Errors` — the same enum the runtime already uses
internally, and consistent with the rest of the API surface on `main` today. When the owned `Errors`
enum lands, this single type is swapped for the owned one; call sites are otherwise unchanged.

### Deprecate and widen the exception-based overloads

```java
@Deprecated(since = "0.24.0", forRemoval = true)
errorResponse(RequestHeaderData header, ApiMessage requestMessage, Throwable apiException);
```

The parameter is widened from `ApiException` to `java.lang.Throwable` (a JDK type), so no
`kafka-clients` exception type appears in the public API signature. The former **compile-time**
constraint becomes a **runtime** one: the deprecated overload throws `IllegalArgumentException` if the
throwable is not an `org.apache.kafka.common.errors.ApiException` (referenced via FQN in the Javadoc
only, so the source imports no `kafka-clients` exception type).

Existing callers keep compiling unchanged — every `ApiException` *is* a `Throwable`, so a call passing
an exception now binds to the deprecated `Throwable` overload. Overload resolution is unambiguous:
`Errors` is not a `Throwable`, so a call passing an `Errors` binds to the new overloads and a call
passing an exception binds to the deprecated one.

### The runtime is unchanged

Because both new paths ultimately construct `error.exception(message)` — a `kafka-clients`
`ApiException`; `Errors.exception(String)` returns the default-message instance when `message` is
`null` — they hand `KafkaProxyExceptionMapper` exactly what it consumes today. That the proxy still
materialises an `ApiException` internally to shape the response is an implementation detail:
`KafkaProxyExceptionMapper`, the `RouterResponseImpl.RespondWithError` record, `RouterDispatchHandler`,
and all the existing special-casing (`LIST_OFFSETS`, `END_TXN`, `LEAVE_GROUP`, the api-key-match
invariant, etc.) are preserved untouched.

- The deprecated `Throwable` overload validates `throwable instanceof ApiException` (throwing
  `IllegalArgumentException` otherwise), casts, and calls the existing mapper.
- The `Errors` overloads construct `error.exception(message)` and call the same mapper.

### Migration

- Existing call sites keep compiling; they simply bind to the (now deprecated) `Throwable` overload
  and surface a deprecation warning, making the migration path visible to filter authors.
- Internal filters and the runtime are migrated to the `Errors` overloads as the reference example,
  e.g. `errorResponse(header, request, Errors.SASL_AUTHENTICATION_FAILED)` and
  `errorResponse(header, request, Errors.UNSUPPORTED_VERSION, reason)`.
- The `Errors` overloads should be preferred in documentation and examples.
- Removal of the deprecated `Throwable` overloads follows the project deprecation policy (no earlier
  than the third minor release after the announcement, and at least three months later).

## Affected/not affected projects

**Affected:**

- `kroxylicious-api` — the two entry points gain `Errors` overloads and their exception overloads are
  deprecated and widened to `Throwable`. This is the public-API change this proposal exists to cover.
- `kroxylicious-runtime` — `RequestFilterResultBuilderImpl` and `RouterContextImpl` gain the new
  overrides; the deprecated override adds the `instanceof` guard. `KafkaProxyExceptionMapper` and the
  routing engine are **not** changed.
- `kroxylicious-filter-test-support` and the per-filter mock `MockFilterContext` implementations —
  must implement the new abstract methods.
- `kroxylicious-filters` and test plugins — migrated to the new overloads as demonstration.

**Not affected:**

- The wire protocol and interoperability — the generated response bytes are identical; the change is
  purely how the caller expresses the intended error.
- `kroxylicious-operator`, KMS, authorizer APIs, CRDs, and YAML configuration.

## Compatibility

- **Source compatibility:** preserved. Every existing caller passes an `ApiException`, which is a
  `Throwable`, so existing filter source keeps compiling (against the deprecated overload).
- **Binary compatibility:** the exception-typed overloads are *removed* at the bytecode level (the
  parameter type changes from `ApiException` to `Throwable`, which is a different method descriptor).
  A pre-compiled plugin that was linked against `errorResponse(..., ApiException)` would fail at link
  time (`NoSuchMethodError`) until recompiled. This is an accepted, deliberate break and is recorded
  as an explicit `japicmp` exclusion. Recompilation against the new API is transparent.
- **Behavioural parity:** for an equivalent exception the deprecated overload produces the identical
  response (same error code, same message) as before; unit tests assert this parity, and assert the
  new `IllegalArgumentException` runtime contract for non-`ApiException` throwables.
- **Runtime contract change:** the deprecated overload now throws `IllegalArgumentException` at call
  time if handed a non-`ApiException` throwable. Previously this was impossible to express (the
  compiler rejected it), so no existing correct caller is affected.
- **Forward compatibility:** the `Errors` type in the new signatures is the single point that will be
  swapped for the Kroxylicious-owned `Errors` enum in a later change, at which point the vendored
  `ApiException` subclasses can be dropped from the owned surface.

## Rejected alternatives

### Replace the exception overloads outright (no deprecation window)

Deleting `errorResponse(..., ApiException)` and shipping only the `Errors` overloads. This is a hard
source break for every filter that short-circuits, with no migration window. Rejected in favour of
the deprecate-and-widen path, which keeps existing source compiling and gives filter authors a
release cycle to migrate.

### Keep `ApiException`, add `Errors` overloads alongside (no widening)

Leave the exception overloads exactly as they are and just add the `Errors` overloads. This achieves
the ergonomic win but leaves `org.apache.kafka.common.errors.ApiException` on the public API
signature indefinitely, so `kafka-clients` never fully leaves the API surface — defeating the primary
motivation and the 1.0 goal from proposal 116. Widening to `Throwable` removes the type from the
signature now while preserving source compatibility.

### Accept `String` code names or `int` codes instead of the `Errors` enum

Expressing the error as a raw error-code `int`, or the `Errors` name as a `String`. Both discard type
safety and discoverability: an `int` or `String` invites invalid values and gives no IDE completion,
whereas the `Errors` enum is exhaustive, self-documenting, and already the runtime's own vocabulary.
Rejected.

### Introduce a Kroxylicious-owned error-code type now

Define a new Kroxylicious error-code abstraction as part of this change rather than reusing
`org.apache.kafka.common.protocol.Errors`. This couples this focused API-shape change to the larger
owned-protocol effort (#4752/#4755, proposal 116) and would land an owned type on `main` ahead of
that work. Reusing the existing `Errors` enum keeps this change small and consistent with the current
surface; the swap to an owned enum is a clean, mechanical follow-up once the owned protocol lands.
