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
hand — but it is *inconsistent*. Everywhere else the API conveys an error as an error code (a `short`
or the `Errors` enum). These two entry points are the odd ones out, forcing the caller to materialise
a `kafka-clients` exception instance to say something the API otherwise expresses as a code and
optional message.

[Proposal 116](https://github.com/kroxylicious/design/blob/main/proposals/116-kafka-api-migration.md) had agreed to
vendor the `ApiException` class into the `kroxylicious-api` source tree. The full weight of that
decision only became apparent later:
* it would also entail vendoring the ~150 `ApiException` subclasses; and
* Kroxylicious would inherit Kafka's large exception model into its public API.

## Motivation

- **Inconsistent with the rest of the API.** Errors are conveyed as `Errors` codes (or shorts) everywhere else
  in the API. These two methods are the exception — literally — forcing the caller to route through
  Kafka's `ApiException` hierarchy to express what the API elsewhere expresses as a code. That
  inconsistency is a papercut for filter authors and an obstacle to a coherent 1.0 API.
- **Forces Kafka's exception hierarchy into the owned API.** Proposal 116 makes the API surface
  Kroxylicious-owned, vendoring the Kafka protocol types it keeps. If these two methods continue to
  take `ApiException`, that type has to be vendored too — dragging in its ~150 subclasses — so the
  owned API inherits Kafka's entire exception model just to let a filter name an error, at odds with
  the goal of a small, self-contained API surface for 1.0.
- **Enables the owned-`Errors` payoff.** Removing `ApiException` from these two signatures takes the
  exception hierarchy off the public API *shape*, but it does not by itself drop the ~150 subclasses
  from the owned surface: the API now speaks in Kafka's `Errors` enum, and that enum still references
  the exception subclasses (each constant can instantiate its exception via `Errors.exception()`), so
  they are pulled in transitively. Dropping them entirely needs the further step of swapping `Errors`
  for a Kroxylicious-owned enum that does not reference the Kafka exceptions (the follow-on to
  #4752/#4755) — the real payoff described in #4756. That swap only becomes *reachable* once the shape
  of the API no longer demands an exception, which is what this proposal delivers.

## Proposal

Add `Errors`-based overloads and **remove** the exception-based overloads outright. There is no
deprecation window and no transitional `Throwable` signature: the `org.apache.kafka.common.errors.ApiException`
reference leaves the public API in one step.

The clean break is chosen deliberately. Filter authors already have to make source changes for
proposal 116 — moving off Kafka's `*Data` classes onto Kroxylicious's own, in the same 0.24.0 release
— so this edit rides along with a migration they are already performing; it costs them no *additional*
migration event, and the alternative deprecate-and-widen machinery buys little in return (see
[Rejected alternatives](#deprecate-and-widen-the-exception-overloads-to-throwable)).

### New API

On both `RequestFilterResultBuilder.errorResponse` and `RouterContext.respondWithError`:

```java
// code only — uses the Errors default message
errorResponse(RequestHeaderData header, ApiMessage requestMessage, Errors errorCode);

// code plus an explicit message
errorResponse(RequestHeaderData header, ApiMessage requestMessage, Errors errorCode, @Nullable String message);
```

`RouterContext.respondWithError` gains the same two overloads.

`Errors` is `org.apache.kafka.common.protocol.Errors` — the same enum the runtime already uses
internally, and consistent with the rest of the API surface on `main` today. When the owned `Errors`
enum lands, this single type is swapped for the owned one; call sites are otherwise unchanged.

### Validation

The `errorCode` must denote an actual error. It carries the package's default `@NonNull` annotation
(inherited from `package-info.java`), so a `null` code is already a documented contract violation.
Beyond that, `Errors.NONE` — the sentinel for the *absence* of an error — is rejected at call time
with `IllegalArgumentException`: asking for an error response that carries no error is a programming
error. This is a genuinely new constraint. The removed exception-based overloads could not express
"no error" (there is no `ApiException` for `NONE`), so nothing that compiled before is affected, and
the check fails fast rather than letting a filter emit a response that claims success on an error
path.

### Removed API

```java
// removed — no deprecated replacement
errorResponse(RequestHeaderData header, ApiMessage requestMessage, ApiException apiException);
respondWithError(RequestHeaderData header, ApiMessage requestMessage, ApiException apiException);
```

With these gone, no `kafka-clients` exception type appears anywhere in the public API signature — no
deprecated overload, no `Throwable` widening, no runtime type-check to maintain.

## Non-goals

- **Removing `kafka-clients` from the runtime.** The `kroxylicious-runtime` continues to depend on
  `kafka-clients` for now; that dependency's eventual removal is part of the wider own-the-protocol work
  (proposal 116, #4752/#4755), not this proposal. This change adjusts the *public API* shape only.
- **Vendoring the `Errors` class.** The new API delivered by this proposal is expressed in terms of
  Kafka's `org.apache.kafka.common.protocol.Errors` — the enum the runtime and the rest of the API
  surface already use today. Vendoring an owned `Errors` class into `kroxylicious-api` is delivered
  separately (the follow-on to #4752/#4755, proposal 116); at that point this single type is swapped
  for the Kroxylicious-owned one, and call sites are otherwise unchanged.
- **Redefining how error responses are created.** Today the `KafkaProxyExceptionMapper` uses the
  `ApiException` to generate an error response. The public API is expressed in terms of the
  `*RequestData`/`*ResponseData` message classes, but internally the mapper reconstructs the
  corresponding `*Request` object from the `*RequestData` and calls
  `AbstractRequest#getErrorResponse(java.lang.Throwable)` on it to produce a correctly shaped error
  response. For the scope of this proposal, this behaviour is unchanged. Separate work (being
  delivered by [kroxylicious#4748](https://github.com/kroxylicious/kroxylicious/issues/4748)) will
  eliminate the dependency on the `*Request` object.

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
  (`NoSuchMethodError`) until recompiled. This is an accepted.
- **Behavioural parity:** for an equivalent input the new `Errors` overload produces the identical
  response (same error code, same message) the exception overload produced before; unit tests assert
  this parity.
- **Runtime contract:** the new overloads reject `Errors.NONE` with `IllegalArgumentException`, and
  the `errorCode` parameter is `@NonNull` (the package default), so a `null` code is a contract
  violation too. The removed exception overloads had no equivalent input, so no existing caller is
  affected.

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

### Introduce the Kroxylicious-owned `Errors` enum now

Vendor the Kroxylicious-owned `Errors` enum as part of this change, rather than reusing Kafka's
`org.apache.kafka.common.protocol.Errors` for now. This couples this focused API-shape change to the
larger owned-protocol effort (#4752/#4755, proposal 116) and would land the owned enum on `main` ahead
of that work. Reusing Kafka's `Errors` enum keeps this change small and consistent with the current
surface; vendoring the owned `Errors` enum is a clean, mechanical follow-up once the owned protocol
lands.
