# 119 - Making the Authorizer API standalone

The Kroxylicious authorizer API provides a general-purpose abstraction for access control decisions, deliberately designed to be agnostic of specific `Principal` and `ResourceType` implementations.
However, the API currently depends on `kroxylicious-api`, which transitively pulls in Kafka client libraries, Jackson, and compression codecs. 
This makes it less appealing for non-Kroxylicious projects to reuse.
This proposal extracts identity concepts into a new lightweight module, `kroxylicious-identity-api`, containing a `Principal` interface, a `Subject` record, a deprecated-at-birth `Identity` interface (to aid in the migration to the new module) and a `@SingularPrincipal` annotation.
The existing types in `kroxylicious-api` will be deprecated and gain super-types from the new module, enabling a phased migration where only the `Authorizer` API breaks immediately while `FilterContext` and other consuming APIs remain unchanged until version 1.0.

## Current situation

The `Authorizer` interface and `AuthorizeResult` record in `kroxylicious-authorizer-api` reference `io.kroxylicious.proxy.authentication.Subject`, which is defined in `kroxylicious-api`.
This means any project that wants to implement the `Authorizer` plugin interface must depend on `kroxylicious-api`, which transitively pulls in `kafka-clients`, `jackson-annotations`, and compression codec libraries (`zstd-jni`, `lz4-java`, `snappy-java`).

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

As detailed in [Current situation](#current-situation) section, the authorizer API's usage of `Subject` is narrow: implementations only call `principals()`, `name()`, and `getClass()`.
Yet this narrow usage forces consumers to accept `kafka-clients`, `jackson-annotations`, and compression codec libraries as transitive dependencies.

### Authentication concepts are misplaced in the module hierarchy

`Subject` and `Principal` are general authentication concepts. 
They represent identity, not proxy behaviour.
Their current placement in `kroxylicious-api` mixes identity types with proxy infrastructure.

### The 0.x window reduces migration cost

The preceding sections establish the substantive case for this change: external reuse is blocked, the dependency cost is disproportionate, and authentication concepts are misplaced.
The project's pre-1.0 status does not justify the change on its own. It should be noted that this would be the project's first breaking change and that track record of compatibility has value.
However, the 0.x window does significantly reduce the cost of making a change that is justified on its own merits.
The authorizer API was introduced relatively recently, so external adoption is likely to be minimal.
Post-1.0, this same change would require deprecation cycles, compatibility shims, and migration documentation.
Given the demonstrated external demand and the narrow usage pattern, the migration cost seems justified now in a way that would be harder to justify later.

## Proposal

Introduce a new module, `kroxylicious-identity-api`, containing four types: a `Principal` interface, a `@SingularPrincipal` annotation, a deprecated-at-birth `Identity` bridge interface, and a `Subject` record.

The existing `Subject` record and `Principal` interface in `kroxylicious-api` will remain.
However, the existing `Principal` gains `extends io.kroxylicious.identity.Principal`, the existing `Subject` gains `implements io.kroxylicious.identity.Identity`, and both will be deprecated along with the existing `@Unique` annotation.

`kroxylicious-authorizer-api` switches its dependency from `kroxylicious-api` to the new module and its method parameters change to use the `Identity` bridge interface.
This is the only immediately breaking change.

API surfaces in `kroxylicious-api` that consume subjects (`FilterContext.authenticatedSubject()`, `RouterContext.authenticatedSubject()`, `FilterContext.clientSaslAuthenticationSuccess()`) are unchanged because the existing `Subject` record now implements `Identity` and flows into `Authorizer.authorize(Identity)` without conversion.
Subject-constructing APIs (`TransportSubjectBuilder`, `SaslSubjectBuilder`) are also unchanged.

At 1.0, the deprecated bridge types are removed and all APIs migrate to using the new `Subject` record directly.

### New module: `kroxylicious-identity-api`

We will create a new module in the `io.kroxylicious.identity` package containing four types:

`Principal` interface: a single method, `String name()`.
The Javadoc contract (implementations must override `hashCode`/`equals` based on class and name) is carried forward from the existing `Principal`.

`@SingularPrincipal` annotation: `@Retention(RUNTIME)`, `@Target(TYPE)`.
This is a renamed version of the existing `@Unique` annotation, with a name that more clearly describes its purpose: marking `Principal` implementations that should have at most one instance in a subject.
This annotation is co-located in the identity module because the `uniquePrincipalOfType` default method on `Identity` will directly depend on it: the method will check `@SingularPrincipal` at runtime to validate that the requested principal type supports the "at most one" invariant.

`Identity` interface: a deprecated-at-birth bridge interface with one abstract method, `Set<? extends Principal> principals()`, plus default convenience methods and a static factory:

- `<P extends Principal> Optional<P> uniquePrincipalOfType(Class<P> uniquePrincipalType)`: default method that returns the unique principal of a given `@SingularPrincipal`-annotated type, or empty. Throws `IllegalArgumentException` if the type is not annotated with `@SingularPrincipal`.
- `<P extends Principal> Set<P> allPrincipalsOfType(Class<P> principalType)`: default method that returns all principals matching a given type.
- `boolean isAnonymous()`: default method that returns `true` when the principals set is empty.
- `static Identity anonymous()`: static factory method that returns an `Identity` with no principals, backed by a lightweight private implementation.

The `Identity` interface is annotated `@Deprecated` from its introduction.
It exists solely as a bridge type so that both the existing `Subject` record (in `kroxylicious-api`) and the new `Subject` record (in this module) can be passed to `Authorizer.authorize()`.
The wildcard return type on `principals()` (`Set<? extends Principal>`) is necessary so the existing `Subject` record's `Set<io.kroxylicious.proxy.authentication.Principal>` accessor satisfies the interface through covariant return types, given that the existing `Principal` gains `extends io.kroxylicious.identity.Principal`.
The `Identity` interface will be removed at 1.0.

Placing the convenience methods on `Identity` is motivated by evidence from [Apicurio Registry's prototype][apicurio-pr], which copied the Kroxylicious `Subject` and re-implemented equivalent convenience methods (`principalOfType`, `isAnonymous`, `anonymous()`) for their `GrantsAuthorizer`.
This demonstrates that these methods are useful for working with subjects, not proxy-specific behaviour.
Providing them as defaults means all implementations of `Identity`, including both the existing and new `Subject` types, get full subject-querying capability without writing boilerplate or duplicating logic.

`Subject` record: a concrete record implementing the `Identity` interface.
Its constructor validates `@SingularPrincipal` uniqueness: if a `Principal` implementation is annotated with `@SingularPrincipal`, the constructor rejects any principal set containing more than one instance of that type.
This is the intended final type for all consumers of the identity API.
External consumers such as Apicurio should target this type directly.

The `Subject` record has its own `static Subject anonymous()` factory method that returns a `Subject` with no principals.
This is separate from `Identity.anonymous()` because static methods on interfaces are not inherited in Java — when `Identity` is removed at 1.0, `Subject.anonymous()` must already exist for code that has migrated to the new type.

The module has no compile-scope dependencies beyond `spotbugs-annotations` (provided scope, for package-level null-safety annotations).
This means the transitive dependency tree for consumers of the authorizer API, which imports from this new module, becomes:

```
kroxylicious-authorizer-api
├── kroxylicious-identity-api   (compile)
│   └── spotbugs-annotations          (provided)
└── ...
```

### Use of a new package

The new types live in `io.kroxylicious.identity`, not `io.kroxylicious.proxy.authentication`.
This avoids a split package, a situation where two Maven artifacts contribute types to the same Java package.
Split packages block JPMS adoption and can confuse IDEs and build tools even on the classpath.

The package name also signals that these types are not proxy-specific.
They represent general identity concepts that any project can use.

### Changes to existing types in `kroxylicious-api`

- `io.kroxylicious.proxy.authentication.Principal` gains `extends io.kroxylicious.identity.Principal`.
  This is both source- and binary-compatible: the existing `Principal` already declares `String name()`, matching the new super-interface's single method.
  The existing `Principal` is deprecated.

- `io.kroxylicious.proxy.authentication.Subject` gains `implements io.kroxylicious.identity.Identity`.
  Adding the super-interface is binary-compatible, and the existing `principals()` accessor satisfies `Identity`'s `Set<? extends Principal> principals()` through covariant return types.
  However, the existing `Subject`'s convenience methods (`uniquePrincipalOfType`, `allPrincipalsOfType`) must have their type parameter bounds widened from `<P extends io.kroxylicious.proxy.authentication.Principal>` to `<P extends io.kroxylicious.identity.Principal>`.
  Without this change, the existing methods and the `Identity` default methods would have the same erasure but different type parameter bounds, producing a name clash compilation error (JLS §8.4.8.1 requires identical bounds for a valid override; a subtype relationship between bounds is not sufficient).
  Widening the bounds is both source- and binary-compatible for callers: the erased method signature is unchanged, and any type argument that satisfied the narrower bound also satisfies the wider one.
  `isAnonymous()` has no type parameters and overrides the `Identity` default cleanly.
  The existing `Subject` is deprecated.
  Its constructor will check both `@SingularPrincipal` and `@Unique` for the cardinality invariant, so that principals annotated with either annotation are validated during the transition period.
  This avoids silently dropping enforcement for any external `Principal` implementations still annotated with `@Unique`.
  The dual check is removed at 1.0 along with the rest of the deprecated `Subject` record; the new `Subject` in `kroxylicious-identity-api` only checks `@SingularPrincipal`.
  The existing `Subject` also retains its `User`-principal validation.

- `io.kroxylicious.proxy.authentication.Unique` is deprecated.

- `User` and other types annotated with `@Unique` switch to the new `@SingularPrincipal` annotation from `io.kroxylicious.identity`.

- API surfaces in `kroxylicious-api` that consume or produce the existing `Subject` (`FilterContext.authenticatedSubject()`, `RouterContext.authenticatedSubject()`, `FilterContext.clientSaslAuthenticationSuccess()`, `TransportSubjectBuilder.buildTransportSubject()`, and `SaslSubjectBuilder.buildSaslSubject()`) will remain unchanged.
  Their signatures continue to use the existing `io.kroxylicious.proxy.authentication.Subject` record.
  Since that record now implements `Identity`, returned subjects flow into `Authorizer.authorize(Identity)` without conversion, preserving existing contracts for filter and router plugin authors.

### Changes to `kroxylicious-authorizer-api`

- `Authorizer.authorize()` and `AuthorizeResult`'s `subject` component change their type from `io.kroxylicious.proxy.authentication.Subject` (the existing concrete record) to `io.kroxylicious.identity.Identity` (the new bridge interface).

- The module's dependency on `kroxylicious-api` is replaced with a dependency on `kroxylicious-identity-api`.
  A test-scope dependency on `kroxylicious-identity-api` is sufficient for tests that construct `io.kroxylicious.identity.Subject` record instances.

- This is a binary-incompatible change.
  However, it is source-compatible for callers: since the existing `Subject` record now implements `Identity`, code that passes an existing `Subject` to `authorize()` compiles without changes.
  `Authorizer` implementations must update the parameter type in their `authorize()` method from `io.kroxylicious.proxy.authentication.Subject` to `io.kroxylicious.identity.Identity`.
  The fix is mechanical (change one import and the parameter type).

### Changes to downstream modules

The only downstream modules that need source changes are those containing `Authorizer` implementations, which must update their `authorize()` method signature from the existing `Subject` to `Identity`.
Two such implementations exist in the codebase.

Additionally, the existing `Subject`'s `uniquePrincipalOfType()` method checks `isAnnotationPresent(Unique.class)` at runtime.
Since `User` switches from `@Unique` to `@SingularPrincipal`, this method must be updated to accept both annotations during the transition period, mirroring the dual check described for the constructor.

`PrincipalEntityNameMapper` in `kroxylicious-entity-isolation` also checks `isAnnotationPresent(Unique.class)` in its constructor to validate that a principal type supports the "at most one" invariant.
This check must be updated to accept both `@Unique` and `@SingularPrincipal`, otherwise passing `User` (which now carries `@SingularPrincipal`) as the principal type would be rejected.

All other modules (including those that use `FilterContext.authenticatedSubject()`, `RouterContext.authenticatedSubject()`, or any other API surface in `kroxylicious-api`) require no immediate source changes.
These modules will see deprecation warnings for usages of the existing `Subject`, `Principal`, and `@Unique`, encouraging migration to the new types, but compilation is unaffected.

#### Notable implications

- **Dependency enforcer allowlists**: `kroxylicious-identity-api` must be added to `bannedDependencies` allowlists in the `kroxylicious-filters`, `kroxylicious-kms-providers`, and `kroxylicious-kubernetes` parent POMs.

- **`PrincipalEntityNameMapper` dual annotation check**: `PrincipalEntityNameMapper` in `kroxylicious-entity-isolation` validates principal types at construction time using `isAnnotationPresent(Unique.class)`.
  Since `User` now carries `@SingularPrincipal` instead of `@Unique`, this check must accept both annotations during the transition period.
  The dual check is removed at 1.0 when `@Unique` is deleted.

### Modules not affected

The following modules require no source or dependency changes:

- `kroxylicious-annotations`
- `kroxylicious-app`
- `kroxylicious-certificate-test-support`
- `kroxylicious-docs`
- `kroxylicious-docs-tests`
- `kroxylicious-filter-archetype`
- `kroxylicious-integration-test-support`
- `kroxylicious-kafka-message-tools`
- `kroxylicious-kms`
- `kroxylicious-kms-test-support`
- `kroxylicious-kms-tls-support`
- `kroxylicious-krpc-plugin`
- `kroxylicious-openmessaging-benchmarks`
- `kroxylicious-systemtests`

Additionally, all filter and router modules that only consume `Subject` through `FilterContext.authenticatedSubject()` or `RouterContext.authenticatedSubject()` are unaffected.
The exact set of affected modules beyond the `Authorizer` implementations will be confirmed during implementation.

## Affected/not affected projects

### Affected

- `kroxylicious`: the main repository; all changes are within this repo.

### Not affected

- `kroxylicious-junit5-extension`
- `kroxylicious-operator`

## Compatibility

This proposal includes the following breaking changes:

| Change | Kind | Impact |
|--------|------|--------|
| `Authorizer.authorize()` parameter type changes from `io.kroxylicious.proxy.authentication.Subject` to `io.kroxylicious.identity.Identity` | Binary- and source-incompatible | `Authorizer` implementations must update their method signature. Two implementations exist in the codebase. Callers are unaffected because the existing `Subject` record implements `Identity`. |
| `AuthorizeResult`'s `subject` component type changes from `io.kroxylicious.proxy.authentication.Subject` to `io.kroxylicious.identity.Identity` | Binary- and source-incompatible | Code creating or deconstructing `AuthorizeResult` instances must be recompiled. Source fix is mechanical (change one import). |
| `User` annotation changes from `@Unique` to `@SingularPrincipal` | Binary-incompatible | Code compiled against `@Unique` on `User` must be recompiled. No source changes required at call sites since the annotation is not referenced directly by consumers. |

The following changes are source- and binary-compatible:

- Adding `extends io.kroxylicious.identity.Principal` to the existing `Principal` interface.
- Adding `implements io.kroxylicious.identity.Identity` to the existing `Subject` record, together with widening the type parameter bounds on its `uniquePrincipalOfType` and `allPrincipalsOfType` methods from `<P extends io.kroxylicious.proxy.authentication.Principal>` to `<P extends io.kroxylicious.identity.Principal>` (required to avoid a name clash with the `Identity` default methods; see [Changes to existing types](#changes-to-existing-types-in-kroxylicious-api)).
- Introducing the new `kroxylicious-identity-api` module.

The existing `Subject`, `Principal`, and `@Unique` are deprecated.
This generates compiler warnings but requires no immediate source changes.

## 1.0 cleanup

At 1.0, the deprecated bridge types are removed and all APIs migrate to the types in `kroxylicious-identity-api`:

- The deprecated `Identity` interface is removed from `kroxylicious-identity-api`.
- The deprecated `Subject` record, `Principal` interface, and `@Unique` annotation are removed from `kroxylicious-api`.
- `Authorizer.authorize()` parameter type changes from `io.kroxylicious.identity.Identity` to `io.kroxylicious.identity.Subject` (the record).
- `AuthorizeResult`'s `subject` component type changes from `io.kroxylicious.identity.Identity` to `io.kroxylicious.identity.Subject`.
- `FilterContext.authenticatedSubject()` return type changes from `io.kroxylicious.proxy.authentication.Subject` to `io.kroxylicious.identity.Subject`.
- `RouterContext.authenticatedSubject()` return type changes from `io.kroxylicious.proxy.authentication.Subject` to `io.kroxylicious.identity.Subject`.
- `FilterContext.clientSaslAuthenticationSuccess()` parameter type changes from `io.kroxylicious.proxy.authentication.Subject` to `io.kroxylicious.identity.Subject`.
- `TransportSubjectBuilder.buildTransportSubject()` return type changes from `CompletionStage<io.kroxylicious.proxy.authentication.Subject>` to `CompletionStage<io.kroxylicious.identity.Subject>`.
- `SaslSubjectBuilder.buildSaslSubject()` return type changes from `CompletionStage<io.kroxylicious.proxy.authentication.Subject>` to `CompletionStage<io.kroxylicious.identity.Subject>`.

By this point, the deprecated types will have been available for at least one release cycle, giving consumers time to migrate.
The deprecation warnings serve as documentation of the migration path.

## Rejected alternatives

### Extract concrete types into the new module

Moving the concrete `Subject` record, `Principal` interface, `User`, `@Unique`, `PrincipalFactory`, `UserFactory`, and `SubjectBuildingException` into a new module while keeping the existing package name `io.kroxylicious.proxy.authentication` would create a split package: two Maven artifacts contributing types to the same Java package.
Split packages block JPMS adoption, confuse build tooling, and are considered bad practice.
The current approach avoids this entirely by using a new package (`io.kroxylicious.identity`) for the new types while keeping the existing types in their original package until they are removed at 1.0.

### Generalise the existing `Subject` record and ship it in `identity-api`

Rather than introducing a new `Subject` record in `kroxylicious-identity-api` and keeping the existing record in `kroxylicious-api` (deprecated), an alternative would be to remove the `User`-principal validation from the existing `Subject` record and move it directly into `kroxylicious-identity-api` as a general-purpose concrete type.

This was rejected for several reasons:

1. **Split package or forced package rename for all consumers.**
   If the record kept its `io.kroxylicious.proxy.authentication` package, two Maven artifacts would contribute types to the same package — a split package that blocks JPMS and confuses tooling.
   If it moved to `io.kroxylicious.identity`, every downstream reference would need updating immediately, with no deprecation path.

2. **The `User` validation is load-bearing within the proxy.**
   The proxy's authentication pipeline relies on non-anonymous subjects containing exactly one `User` principal.
   Removing this validation from the existing record would push enforcement responsibility to every call site that constructs a subject within the proxy, creating a class of bugs where subjects without a `User` principal silently propagate through the pipeline.
   The existing `Subject` retains this invariant while the new `Subject` record in `kroxylicious-identity-api` uses the more general `@SingularPrincipal` validation, which is appropriate for external consumers with different principal types.

### Subject-as-interface with `ProxySubject` rename

The original version of this proposal used a `Subject` interface (rather than a record) as the primary type in `kroxylicious-identity-api`, renamed the existing `Subject` record to `ProxySubject`, and changed the return types of `FilterContext.authenticatedSubject()`, `RouterContext.authenticatedSubject()`, and other API surfaces to use the new interface.
All breaking changes were applied in a single release with no deprecation period.

This was rejected for several reasons:

1. **Larger blast radius.**
   Changing `FilterContext.authenticatedSubject()` and `RouterContext.authenticatedSubject()` to return a new interface type would break every filter and router plugin that references the return type.
   `FilterContext` has real external adoption, and this is a higher bar than the authorizer API.

2. **`ProxySubject` rename forces source-incompatible changes across all downstream modules.**
   Every module that constructs a `Subject` would need to change to `new ProxySubject(...)` and `ProxySubject.anonymous()`, increasing the migration cost and the size of the diff.

3. **An interface is harder to make safe for authorizer implementations.**
   Making `Subject` an interface requires every consumer to provide their own implementation, making it harder to enforce `equals`/`hashCode`/`toString` contracts and `@SingularPrincipal` uniqueness invariants.
   A concrete record with constructor validation ensures that all `Authorizer` implementations receive subjects with consistent, tested behaviour — particularly important given that [broken access control is #1 on the OWASP top ten](https://owasp.org/Top10/2025/A01_2025-Broken_Access_Control/).

4. **The phased deprecation approach achieves the same end state with lower immediate migration cost.**
   The `Identity` bridge interface is deprecated at birth and carries the compatibility cost for one release cycle.
   The end state (a concrete `Subject` record as the primary type, no bridge interface) is the same, but the migration path avoids breaking widely-adopted API surfaces until 1.0.

[prop-9]: https://github.com/kroxylicious/design/blob/main/proposals/009-authorizer.md
[apicurio-pr]: https://github.com/Apicurio/apicurio-registry/pull/7829
