# 119 - Making the Authorizer API standalone

The Kroxylicious authorizer API provides a general-purpose abstraction for access control decisions, deliberately designed to be agnostic of specific `Principal` and `ResourceType` implementations.
However, the API currently depends on `kroxylicious-api`, which transitively pulls in Kafka client libraries, Jackson and compression codecs. 
This makes it less appealing for non-Kroxylicious projects to reuse.
This proposal introduces new identity types in a lightweight module, `kroxylicious-identity-api`, containing a `Principal` interface, a `Subject` record, a deprecated-at-birth `Identity` interface (to bridge the migration) and a `@SingularPrincipal` annotation.
The existing types in `kroxylicious-api` will be deprecated and gain super-types from the new module, enabling a phased migration where only the `Authorizer` API breaks immediately while `FilterContext` and other consuming APIs remain unchanged until version 1.0.

## Current situation

The `Authorizer` interface and `AuthorizeResult` record in `kroxylicious-authorizer-api` reference `io.kroxylicious.proxy.authentication.Subject`, which is defined in `kroxylicious-api`.
This means any project that wants to implement the `Authorizer` plugin interface must depend on `kroxylicious-api`, which transitively pulls in `kafka-clients`, `jackson-annotations` and compression codec libraries (`zstd-jni`, `lz4-java`, `snappy-java`).

The authorizer API's actual usage of `Subject` is narrow.
`Authorizer.authorize()` receives a `Subject` and passes it through to `AuthorizeResult`.
Implementations like `AclAuthorizer` call only `subject.principals()` and then `principal.name()` and `principal.getClass()` on each element.
None of the richer methods on the concrete `Subject` record (`uniquePrincipalOfType`, `allPrincipalsOfType`, `isAnonymous`) or the `User`-specific validation are used by the authorizer API itself.

Despite this narrow usage, the module dependency graph forces consumers to accept a large transitive dependency tree:

```
kroxylicious-authorizer-api
├── kroxylicious-api                  (compile)
│   ├── jackson-annotations           (compile)
│   └── kafka-clients                 (compile)
│       ├── zstd-jni                  (runtime)
│       ├── lz4-java                  (runtime)
│       ├── snappy-java               (runtime)
│       └── slf4j-api                 (runtime)
└── ...
```

## Motivation

### External reuse is blocked

The authorizer API's general-purpose design, as described in [proposal 009][prop-9], was built for reuse: the `Authorizer` interface is agnostic of specific `Principal` and `ResourceType` implementations, and its asynchronous return type supports both in-process and networked policy decision points such as [OPA](https://www.openpolicyagent.org/) and [OpenFGA](https://openfga.dev/).

This generality has attracted interest from other projects.
For example, [Apicurio Registry](https://www.apicur.io/registry/) would like to use the authorizer API as the basis for its [fine-grained authorization](https://github.com/Apicurio/apicurio-registry/issues/7724) implementation.
However, the dependency on `kroxylicious-api` makes this impractical.
To work on their [prototype implementation](https://github.com/Apicurio/apicurio-registry/pull/7829), Apicurio Registry have copied the Kroxylicious Authorizer API code into their own module and removed the dependent code.
Any non-Kroxylicious project that wants to implement or consume the `Authorizer` interface faces the same barrier.

### The dependency cost is disproportionate to what is actually used

As detailed in [Current situation](#current-situation) section, the authorizer API's usage of `Subject` is narrow: implementations only call `principals()`, `name()` and `getClass()`.
Yet this narrow usage forces consumers to accept `kafka-clients`, `jackson-annotations` and compression codec libraries as transitive dependencies.

### Authentication concepts are misplaced in the module hierarchy

`Subject` and `Principal` are general authentication concepts. 
They represent identity, not proxy behaviour.
Their current placement in `kroxylicious-api` mixes identity types with proxy infrastructure.

### The 0.x window reduces migration cost

The preceding sections establish the substantive case for this change: external reuse is blocked, the dependency cost is disproportionate and authentication concepts are misplaced.
The project's pre-1.0 status does not justify the change on its own.
It should be noted that this would be the project's first breaking change and that track record of compatibility has value.
However, the 0.x window does significantly reduce the cost of making a change that is justified on its own merits.
The authorizer API was introduced relatively recently, so external adoption is likely to be minimal.
Post-1.0, this same change would require deprecation cycles, compatibility shims and migration documentation.
Given the demonstrated external demand and the narrow usage pattern, the migration cost seems justified now in a way that would be harder to justify later.

## Proposal

To decouple the authorizer API from `kroxylicious-api`, we introduce new `Principal`, `Subject` and related types in a new zero-dependency module (`kroxylicious-identity-api`), in a new package (`io.kroxylicious.identity`).
The existing types in `kroxylicious-api` are retained and deprecated. 
They are part of public APIs (`FilterContext`, `RouterContext`, `TransportSubjectBuilder`, etc.), so removing them outright would break multiple plugin surfaces simultaneously.
Instead, we introduce a deprecated-at-birth bridge interface, `Identity`, that both the existing and new `Subject` types implement.
This allows the authorizer API to switch to `Identity` immediately, breaking only `Authorizer` implementations (of which there are two in the codebase), while other public APIs continue returning the existing `Subject` unchanged.  
This gives consumers of the API time to migrate.
When Kroxylicious 1.0 is released, the bridge types will be removed and all APIs migrated to the new types.

### Use of a new package

The new types live in a new `io.kroxylicious.identity` package, not the existing `io.kroxylicious.proxy.authentication`.

If the new module used the existing package, both `kroxylicious-api` and `kroxylicious-identity-api` would contribute types to `io.kroxylicious.proxy.authentication`:
This would be a split package.
Split packages are incompatible with the [Java Platform Module System (JPMS)][jpms], Java's built-in module system which requires each package to belong to exactly one module.
They can also confuse IDEs and build tools even on the classpath.

Using a distinct package avoids this problem entirely.
The name `io.kroxylicious.identity` also signals that these types are not proxy-specific.
They represent general identity concepts that any project can use.

### Phase 1: Initial changes

#### What changes

New `kroxylicious-identity-api` module with package `io.kroxylicious.identity`:

```java
package io.kroxylicious.identity;

// Carried forward from io.kroxylicious.proxy.authentication.Principal
interface Principal {
    String name();
    // Implementations must override hashCode/equals based on class and name
}

// Replaces @Unique with a clearer name
@Retention(RUNTIME) @Target(TYPE)
@interface SingularPrincipal { }

// Bridge interface: both the existing and new Subject implement this,
// allowing either to be passed to Authorizer.authorize().
/** @deprecated Use {@link Subject} directly. Will be removed at 1.0. */
@Deprecated(since = "0.x.0", forRemoval = true)
interface Identity {
    Set<? extends Principal> principals();
    default <P extends Principal> Optional<P> uniquePrincipalOfType(Class<P> type) { /* checks @SingularPrincipal */ }
    default <P extends Principal> Set<P> allPrincipalsOfType(Class<P> type) { ... }
    default boolean isAnonymous() { ... }
    static Identity anonymous() { ... }
}

// Intended final type for all consumers.
// Has its own anonymous() factory because static methods on interfaces
// are not inherited. Subject.anonymous() must exist before Identity is removed in 1.0.
record Subject(Set<? extends Principal> principals) implements Identity {
    Subject { /* validates @SingularPrincipal uniqueness */ }
    static Subject anonymous() { ... }
}
```

In `kroxylicious-api` the existing types are deprecated in place and the existing `Subject` now implements the new `Identity` interface:

```java
package io.kroxylicious.proxy.authentication;

/** @deprecated Use {@link io.kroxylicious.identity.Principal} instead. */
@Deprecated(since = "0.x.0", forRemoval = true)
interface Principal extends io.kroxylicious.identity.Principal {
    // Adding extends is source- and binary-compatible (name() already declared)
}

/** @deprecated Use {@link io.kroxylicious.identity.Subject} instead. */
@Deprecated(since = "0.x.0", forRemoval = true)
record Subject(Set<Principal> principals) implements Identity {
    // These methods originally had bounds <P extends old.Principal>.
    // Identity's defaults have bounds <P extends new.Principal>.
    // Both erase to the same JVM signature, but Java requires identical
    // bounds for a valid override (JLS §8.4.8.1), not just a subtype
    // relationship. Without changing the bounds, compilation fails with
    // a name clash. The change is safe: since old.Principal extends
    // new.Principal, any type that satisfied the old bound also satisfies
    // the new one, so callers are unaffected.
    @Override <P extends io.kroxylicious.identity.Principal> Optional<P> uniquePrincipalOfType(Class<P> type) { ... }
    @Override <P extends io.kroxylicious.identity.Principal> Set<P> allPrincipalsOfType(Class<P> type) { ... }
}

/** @deprecated Use {@link io.kroxylicious.identity.SingularPrincipal} instead. */
@Deprecated(since = "0.x.0", forRemoval = true)
@interface Unique { }
```

In `kroxylicious-authorizer-api` the dependency switches from `kroxylicious-api` to `kroxylicious-identity-api`:

```java
package io.kroxylicious.authorizer.service;

interface Authorizer {
    CompletionStage<AuthorizeResult> authorize(Identity subject, List<Action> actions);
    //                                         ^^^^^^^^ was: Subject
}

record AuthorizeResult(
    Identity subject, // was: Subject
    List<Action> allowed,
    List<Action> denied) { ... }
```

In `kroxylicious-authorizer-acl` and other `Authorizer` implementations:

```java
// Mechanical signature change: Subject to Identity
CompletionStage<AuthorizeResult> authorize(Identity subject, List<Action> actions) { ... }
```

#### Impact

Breaking changes:

| Change                                                       | Kind                | Who must act |
|--------------------------------------------------------------|---------------------|--------------|
| `Authorizer.authorize()` parameter: `Subject` to `Identity`  | Binary-incompatible | `Authorizer` implementations must update method signature. Two exist in the codebase (`AclAuthorizer` in `kroxylicious-authorizer-acl`, `SimpleAuthorizer` test in `kroxylicious-authorization`), and no usages outside the project are known. Callers are unaffected as the existing `Subject` will now implement `Identity`. |
| `AuthorizeResult.subject` component: `Subject` to `Identity` | Binary-incompatible | Code creating or deconstructing `AuthorizeResult` must be recompiled. The source code fix is mechanical. |

Compatible changes (no action required):

- Adding `extends io.kroxylicious.identity.Principal` to the existing `Principal` interface
- Adding `implements Identity` to the existing `Subject` record and widening type parameter bounds
- Introducing `kroxylicious-identity-api` as a new module
- `kroxylicious-identity-api` must be added to `bannedDependencies` allowlists in relevant parent POMs

All other modules (including those that use `FilterContext.authenticatedSubject()` or `RouterContext.authenticatedSubject()`) require no source changes.
These modules will see compile-time deprecation warnings for usages of the existing `Subject`, `Principal` and `@Unique`, visible to developers during builds but not to end users.

### Phase 2: 1.0 cleanup

#### What changes

In `kroxylicious-identity-api`:

```java
package io.kroxylicious.identity;

// Identity interface: removed (bridge no longer needed)
```

In `kroxylicious-api`:

```java
package io.kroxylicious.proxy.authentication;

// Subject record, Principal interface, @Unique annotation: removed

@SingularPrincipal // was: @Unique
record User(String name) implements io.kroxylicious.identity.Principal { } // was: Principal

interface PrincipalFactory<P extends io.kroxylicious.identity.Principal> { // was: Principal
    P newPrincipal(String name);
}
```

In `kroxylicious-authorizer-api`:

```java
interface Authorizer {
    CompletionStage<AuthorizeResult> authorize(Subject subject, List<Action> actions);
    //                                         ^^^^^^^ Identity changed to the new Subject
}

record AuthorizeResult(
    Subject subject, // Identity changed to the new Subject
    ...) { ... }
```

In `kroxylicious-api` (consuming APIs migrate to new types):

```java
FilterContext.authenticatedSubject()            // returns io.kroxylicious.identity.Subject
RouterContext.authenticatedSubject()            // returns io.kroxylicious.identity.Subject
FilterContext.clientSaslAuthenticationSuccess() // accepts io.kroxylicious.identity.Subject
TransportSubjectBuilder.buildTransportSubject() // returns CompletionStage<io.kroxylicious.identity.Subject>
SaslSubjectBuilder.buildSaslSubject()           // returns CompletionStage<io.kroxylicious.identity.Subject>
```

#### Impact

All types migrate to `io.kroxylicious.identity`.
Filter, router and authorizer plugin authors update imports.
By this point, the deprecated types will have been available for at least one release cycle, giving consumers time to migrate.
An [OpenRewrite](https://docs.openrewrite.org/) recipe should be shipped alongside the 1.0 release to automate the mechanical import changes for external plugin authors.

## Testing

At Phase 1, the `kroxylicious-authorizer-api` test suite should verify that `AuthorizeResult` can be constructed with both the existing `io.kroxylicious.proxy.authentication.Subject` (via its `Identity` implementation) and the new `io.kroxylicious.identity.Subject`.
This confirms that the bridge interface allows both subject types to flow through the authorizer API.

## Rejected alternatives

### Extract concrete types into the new module

Moving the concrete `Subject` record, `Principal` interface, `User`, `@Unique`, `PrincipalFactory`, `UserFactory` and `SubjectBuildingException` into a new module while keeping the existing package name `io.kroxylicious.proxy.authentication` would create a split package: two Maven artifacts contributing types to the same Java package.
Split packages block (JPMS)[jpms] adoption, confuse build tooling and are considered bad practice.
The current approach avoids this entirely by using a new package (`io.kroxylicious.identity`) for the new types while keeping the existing types in their original package until they are removed at 1.0.

### Generalise the existing `Subject` record and ship it in `identity-api`

Rather than introducing a new `Subject` record in `kroxylicious-identity-api` and keeping the existing record in `kroxylicious-api` (deprecated), an alternative would be to remove the `User`-principal validation from the existing `Subject` record and move it directly into `kroxylicious-identity-api` as a general-purpose concrete type.

This was rejected for several reasons:

1. If the record kept its `io.kroxylicious.proxy.authentication` package, two Maven artifacts would contribute types to the same package.
   This is a split package that blocks JPMS and confuses tooling.
   If it moved to `io.kroxylicious.identity`, every downstream reference would need updating immediately with no deprecation path.

2. The proxy's authentication pipeline relies on non-anonymous subjects containing exactly one `User` principal.
   Removing this validation from the existing record would push enforcement responsibility to every call site that constructs a subject within the proxy, creating a class of bugs where subjects without a `User` principal silently propagate through the pipeline.
   The existing `Subject` retains this invariant while the new `Subject` record in `kroxylicious-identity-api` uses the more general `@SingularPrincipal` validation, which is appropriate for external consumers with different principal types.

### Subject-as-interface with `ProxySubject` rename

The original version of this proposal used a `Subject` interface (rather than a record) as the primary type in `kroxylicious-identity-api`, renamed the existing `Subject` record to `ProxySubject`, and changed the return types of `FilterContext.authenticatedSubject()`, `RouterContext.authenticatedSubject()` and other API surfaces to use the new interface.
All breaking changes were applied in a single release with no deprecation period.

This was rejected for several reasons:

1. Changing `FilterContext.authenticatedSubject()` and `RouterContext.authenticatedSubject()` to return a new interface type would break every filter and router plugin that references the return type.
   These are public APIs with a wider surface area than the authorizer API, so breaking them without a deprecation path is a higher bar.

2. Every module that constructs a `Subject` would need to change to `new ProxySubject(...)` and `ProxySubject.anonymous()`, increasing the migration cost and the size of the diff.

3. Making `Subject` an interface requires every consumer to provide their own implementation, making it harder to enforce `equals`/`hashCode`/`toString` contracts and `@SingularPrincipal` uniqueness invariants.
   A concrete record with constructor validation ensures that all `Authorizer` implementations receive subjects with consistent, tested behaviour.
   This is particularly important given that [broken access control is #1 on the OWASP top ten](https://owasp.org/Top10/2025/A01_2025-Broken_Access_Control/).

4. The phased deprecation approach achieves the same end state with lower immediate migration cost.
   The `Identity` bridge interface is deprecated at birth and carries the compatibility cost for one release cycle.
   The end state (a concrete `Subject` record as the primary type, no bridge interface) is the same, but the migration path avoids breaking public API surfaces until 1.0.

[prop-9]: https://github.com/kroxylicious/design/blob/main/proposals/009-authorizer.md
[apicurio-pr]: https://github.com/Apicurio/apicurio-registry/pull/7829
[jpms]: https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/lang/module/package-summary.html
