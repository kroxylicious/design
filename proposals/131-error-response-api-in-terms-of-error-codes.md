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
`INVALID_REQUEST`" must round-trip through the exception hierarchy:

```java
context.requestFilterResultBuilder()
        .errorResponse(header, request, new InvalidRequestException("no topic id tag"))
        .completed();
```

This is not especially *hard* — `Errors` even offers a shortcut,
`Errors.INVALID_REQUEST.exception("no topic id tag")`, so the caller need not pick the subclass by
hand — but it is *inconsistent*. Everywhere else the API conveys an error as an `Errors` code,
including the error codes a filter reads off a response. These two entry points are the odd ones out,
forcing the caller to materialise a `kafka-clients` exception instance to say something the API
otherwise expresses as a code, only for the runtime to unwrap that exception straight back to the code
it started from.

They are also the last of the concerns identified in proposal 116: the `*Data` message classes,
protocol infrastructure, record classes and scattered `common.*` types are all addressed there, but
the `ApiException` hierarchy on these two entry points is a distinct API-shape problem — it is not a
namespace move, it is the wrong abstraction — and is called out separately in #4756.

## Motivation

- **Inconsistent with the rest of the API.** Errors are conveyed as `Errors` codes everywhere else
  in the API. These two methods are the exception — literally — forcing the caller to route through
  Kafka's `ApiException` hierarchy to express what the API elsewhere expresses as a code. That
  inconsistency is a papercut for filter authors and an obstacle to a coherent 1.0 API.
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

Add `Errors`-based overloads and **remove** the exception-based overloads outright. There is no
deprecation window and no transitional `Throwable` signature: the `org.apache.kafka.common.errors.ApiException`
reference leaves the public API in one step.

The clean break is chosen deliberately. Filter authors already have to make source changes for
proposal 116 — moving off Kafka's `*Data` classes onto Kroxylicious's own, in the same 0.24.0 release
— so this edit rides along with a migration they are already performing; it costs them no *additional*
migration event, and the alternative deprecate-and-widen machinery buys little in return (see
[Rejected alternatives](#deprecate-and-widen-the-exception-overloads-to-throwable)).

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

### Removed overloads

```java
// removed — no deprecated replacement
errorResponse(RequestHeaderData header, ApiMessage requestMessage, ApiException apiException);
respondWithError(RequestHeaderData header, ApiMessage requestMessage, ApiException apiException);
```

With these gone, no `kafka-clients` exception type appears anywhere in the public API signature — no
deprecated overload, no `Throwable` widening, no runtime type-check to maintain.

### No runtime churn

How the runtime turns the request into an error response is an implementation detail and is
unchanged: the new `Errors` overloads feed the existing response-shaping engine exactly what it
consumes today, so no downstream signatures or behaviour change. Internally the code the caller now
passes is the code the engine already worked with; the exception was only ever an envelope for it.

## Non-goals

- **Removing `kafka-clients` from the runtime.** The `kroxylicious-runtime` continues to depend on
  `kafka-clients`; that dependency's eventual removal is part of the wider own-the-protocol work
  (proposal 116, #4752/#4755), not this proposal. This change adjusts the *public API* shape only and
  leaves the runtime free to keep using `Errors`/`ApiException` internally.
- **Redefining how thrown exceptions are mapped to responses.** Today a filter that *throws* an
  `ApiException` from a filter method has it mapped back to an error response by
  `KafkaProxyExceptionMapper`; that behaviour is untouched here. It is worth being explicit about the
  contract, though: the supported way to short-circuit with a protocol error is the `Errors`-based
  `errorResponse`/`respondWithError`. Relying on throwing a `kafka-clients` exception and having the
  runtime recover the code is not a guarantee this proposal strengthens — and it cannot survive
  `kafka-clients` eventually leaving the runtime (a reflective code-recovery shim could bridge that
  transition, but that is future work under 116). Firming up the `Filter` error contract in full is
  out of scope here and tracked with the own-the-protocol effort.

## Migration

- Existing call sites must be updated — mechanically — from an exception to the equivalent code, e.g.
  `errorResponse(header, request, Errors.GROUP_AUTHORIZATION_FAILED.exception())` becomes
  `errorResponse(header, request, Errors.GROUP_AUTHORIZATION_FAILED)`, and
  `Errors.UNSUPPORTED_VERSION.exception(reason)` becomes
  `errorResponse(header, request, Errors.UNSUPPORTED_VERSION, reason)`.
- Because 0.24.0 already forces filter authors to make source changes (proposal 116's move off the
  `*Data` classes), this edit rides along with changes the author is making regardless; there is no
  separate migration release to track.
- Internal filters, the runtime and the test plugins are migrated to the `Errors` overloads as the
  reference examples, and the `Errors` overloads are the only form shown in documentation.

## Affected/not affected projects

**Affected:**

- `kroxylicious-api` — the two entry points gain `Errors` overloads and their exception overloads are
  removed. This is the public-API change this proposal exists to cover.
- `kroxylicious-runtime` — `RequestFilterResultBuilderImpl` and `RouterContextImpl` gain the new
  overrides and drop the removed ones. `KafkaProxyExceptionMapper` and the routing engine are **not**
  changed.
- `kroxylicious-filter-test-support` and the per-filter mock `MockFilterContext` implementations —
  must implement the new abstract methods and drop the removed ones.
- `kroxylicious-filters` and test plugins — migrated to the new overloads as demonstration.

**Not affected:**

- The wire protocol and interoperability — the generated response bytes are identical; the change is
  purely how the caller expresses the intended error.
- `kroxylicious-operator`, KMS, authorizer APIs, CRDs, and YAML configuration.

## Compatibility

- **Source compatibility:** deliberately broken. Every existing caller passes an `ApiException`,
  which no longer resolves to any overload, so filter source that short-circuits must be edited (the
  mechanical change in [Migration](#migration)). This break is scheduled for the same 0.24.0 release
  as proposal 116, where filter authors are already editing source to move off Kafka's `*Data`
  classes onto Kroxylicious's own — so the change is folded into a migration they must perform anyway,
  minimising the inconvenience.
- **Binary compatibility:** the exception-typed overloads are removed at the bytecode level. A
  pre-compiled plugin linked against `errorResponse(..., ApiException)` would fail at link time
  (`NoSuchMethodError`) until recompiled. This is an accepted, deliberate break and is recorded as an
  explicit `japicmp` exclusion. Recompilation against the new API is transparent. (A future runtime
  enhancement could catch `LinkageError`/`NoSuchMethodError` in the safe invoker and emit a targeted
  "compiled against a different API version" diagnostic; that is out of scope here and belongs with
  the API-versioning work.)
- **Behavioural parity:** for an equivalent input the new `Errors` overload produces the identical
  response (same error code, same message) the exception overload produced before; unit tests assert
  this parity.
- **Forward compatibility:** the `Errors` type in the new signatures is the single point that will be
  swapped for the Kroxylicious-owned `Errors` enum in a later change, at which point the vendored
  `ApiException` subclasses can be dropped from the owned surface.

## Rejected alternatives

### Deprecate and widen the exception overloads to `Throwable`

Rather than removing the exception overloads, keep them but deprecate them and widen their parameter
from `ApiException` to `java.lang.Throwable`, adding the `Errors` overloads alongside. The
`kafka-clients` type would leave the *signature* immediately (`Throwable` is a JDK type), the former
compile-time `ApiException` constraint would become a runtime check throwing `IllegalArgumentException`,
and existing source would keep compiling through a deprecation window.

Rejected. The machinery buys source compatibility that is largely moot. Filter authors are already
making source changes in 0.24.0 to migrate off Kafka's `*Data` classes onto Kroxylicious's own
(proposal 116), so preserving compilation of *unchanged* source protects a case that does not really
occur: a filter that short-circuits will be edited in this release regardless. The runtime check is
also more awkward than it first appears — since the direction of travel is to remove `kafka-clients`
from the runtime entirely, the guard could not be a plain `instanceof ApiException`; it would
ultimately have to be a *reflective* class-name check, keeping a `kafka-clients` coupling alive by the
back door. Add the deprecation window, the `japicmp` bookkeeping, and the risk of a caller passing a
non-`ApiException` `Throwable` and only finding out at runtime, and reviewers rightly questioned
whether the transitional signature was worth its complexity. The clean break carries the same one-time
source edit while leaving nothing behind to remove later.

### Keep `ApiException`, add `Errors` overloads alongside (no removal)

Leave the exception overloads exactly as they are and just add the `Errors` overloads. This achieves
the ergonomic win but leaves `org.apache.kafka.common.errors.ApiException` on the public API
signature indefinitely, so `kafka-clients` never fully leaves the API surface — defeating the primary
motivation and the 1.0 goal from proposal 116.

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
