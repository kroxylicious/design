# 119 - Making the Authorizer API standalone

The Kroxylicious authorizer API provides a general-purpose abstraction for access control decisions, deliberately designed to be agnostic of specific `Principal` and `ResourceType` implementations.
However, the API currently depends on `kroxylicious-api`, which transitively pulls in Kafka client libraries, Jackson, and compression codecs. 
This makes it less appealing for non-Kroxylicious projects to reuse.
This proposal extracts the `Subject` and `Principal` concepts into a new lightweight module, `kroxylicious-identity-api`, so that `kroxylicious-authorizer-api` can be consumed independently of `kroxylicious-api` module.

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
The relative cost of importing the dependency does not match the value consumed.

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
Given the demonstrated external demand and the narrow usage pattern, the migration cost is justified now in a way that would be harder to justify later.

## Proposal

Introduce a new module, `kroxylicious-identity-api`, containing minimal interfaces for `Subject` and `Principal`, plus the `@Unique` annotation (which is used for marking `Principals` which should have only one instance per subject).
The existing concrete `Subject` record in `kroxylicious-api` is renamed to `ProxySubject` and implements the new `Subject` interface, and `kroxylicious-authorizer-api` switches its dependency from `kroxylicious-api` to the new module.

### New module: `kroxylicious-identity-api`

A new module in the `io.kroxylicious.identity` package containing three types:

`Principal` interface: a single method, `String name()`.
The Javadoc contract (implementations must override `hashCode`/`equals` based on class and name) is carried forward from the existing `Principal`.

`Subject` interface: a single method, `Set<Principal> principals()`.
This matches the original design from [proposal 009][prop-9], where the diversity of `Principal` implementations is handled by `Principal` being an interface.

`@Unique` annotation: `@Retention(RUNTIME)`, `@Target(TYPE)`.
Marks `Principal` implementations that should have at most one instance in a `Subject`. 
This annotation is moved from the main `kroxylicious-api`, as external users of this API may also want to enforce this invariant.

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

- `io.kroxylicious.proxy.authentication.Principal` is **deleted**.
  This is a binary-incompatible change.

- `io.kroxylicious.proxy.authentication.Subject` is **renamed** to `io.kroxylicious.proxy.authentication.ProxySubject` and adds `implements io.kroxylicious.identity.Subject`.
  The rename avoids ambiguity between the interface (`io.kroxylicious.identity.Subject`) and the concrete record when both are in scope.
  Its `Set<Principal> principals` component and method type bounds change from the deleted proxy `Principal` to `io.kroxylicious.identity.Principal`.
  The file is renamed from `Subject.java` to `ProxySubject.java`, the test from `SubjectTest.java` to `ProxySubjectTest.java`, and all references are updated: `Subject.anonymous()` becomes `ProxySubject.anonymous()`, `new Subject(...)` becomes `new ProxySubject(...)`, etc.
  This is a binary and source incompatible change for all code referencing the concrete type by name.

- Because `ProxySubject` is used by several interfaces in `kroxylicious-api`, the following method signatures also change:
  - `FilterContext.clientSaslAuthenticationSuccess(String, Subject)` to `FilterContext.clientSaslAuthenticationSuccess(String, ProxySubject)`
  - `FilterContext.authenticatedSubject()` return type changes from `Subject` to `ProxySubject`
  - `RouterContext.authenticatedSubject()` return type changes from `Subject` to `ProxySubject`
  - `TransportSubjectBuilder.buildTransportSubject(Context)` return type changes from `CompletionStage<Subject>` to `CompletionStage<ProxySubject>`
  - `SaslSubjectBuilder.buildSaslSubject(Context)` return type changes from `CompletionStage<Subject>` to `CompletionStage<ProxySubject>`

  These are all binary-incompatible changes.

- The `@Unique` annotation is moved from `io.kroxylicious.proxy.authentication` to `io.kroxylicious.identity`.
  The old annotation is deleted.
  This is a binary-incompatible change: code compiled against the old annotation will not see it on types annotated with the new one.
  This is mitigated by:
  - The project being at version 0.x (pre-1.0 API stability).
  - A `japicmp` exclusion documenting the intentional removal.
  - The `@Unique` annotation having no known external consumers.

- `User` and other types annotated with `@Unique` update their import to the new annotation.
  `User`, `PrincipalFactory`, and test types (`FakeUniquePrincipal`, `FakeMultiplePrincipal`) add an explicit `import io.kroxylicious.identity.Principal` since the same-package type no longer exists.

- The `japicmp` configuration is updated with:
  - `<exclude>` entries for: the removed `Principal` class, the removed `Unique` annotation, the removed `Subject` class (renamed to `ProxySubject`), the changed `PrincipalFactory#newPrincipal` return type, and the changed method signatures in `TransportSubjectBuilder#buildTransportSubject`, `SaslSubjectBuilder#buildSaslSubject`, `FilterContext#clientSaslAuthenticationSuccess`, `FilterContext#authenticatedSubject`, and `RouterContext#authenticatedSubject`.
  - An `<ignoreMissingClassesByRegularExpressions>` entry for `io.kroxylicious.proxy.authentication.Principal`, because `japicmp` cannot resolve old bytecode signatures that reference the deleted class without this.

- The concrete `ProxySubject` record retains all its existing behaviour, including the `User`-principal validation in its constructor, and its `uniquePrincipalOfType`, `allPrincipalsOfType`, and `isAnonymous` methods.

### Changes to `kroxylicious-authorizer-api`

- `Authorizer.authorize()` and `AuthorizeResult`'s `subject` component change their type from `io.kroxylicious.proxy.authentication.Subject` (the old concrete record, now renamed to `ProxySubject`) to `io.kroxylicious.identity.Subject` (the new interface).

- The module's dependency on `kroxylicious-api` is replaced with a dependency on `kroxylicious-identity-api`.
  A test-scope dependency on `kroxylicious-api` is retained for tests that construct concrete `ProxySubject` instances.

- This is a source-breaking change for `Authorizer` implementations: they must update the parameter type in their `authorize()` method from `io.kroxylicious.proxy.authentication.Subject` to `io.kroxylicious.identity.Subject`.
  The fix is mechanical (change one import).
  Callers of `authorize()` (such as `AuthorizationFilter`) are unaffected because the concrete `ProxySubject` implements the interface.

### Changes to downstream modules

Downstream changes follow two patterns:

- **Rename**: all code referencing the concrete `Subject` type updates to `ProxySubject` — variable declarations, constructor calls, method signatures, test assertions (including `toString()` output and `Mockito.any()` matchers).
- **Re-import**: code referencing `Principal` or `@Unique` updates imports from `io.kroxylicious.proxy.authentication` to `io.kroxylicious.identity`.

These changes are mechanical and affect most modules that interact with authentication types, including filters, runtime, integration tests, and microbenchmarks.

#### Notable implications

- **`kroxylicious-runtime` gains a direct dependency on `kroxylicious-identity-api`**: its source directly references the identity-api `Principal` type, so this must be an explicit compile-scope dependency.

- **Maven dependency analyzer false positive**: the compiler needs `kroxylicious-identity-api` on the classpath to resolve `ProxySubject`'s super-interface, but the bytecode doesn't directly reference identity-api types.
  This triggers Maven's analyzer.
  Three modules (`kroxylicious-filter-test-support`, `kroxylicious-oauthbearer-validation`, `kroxylicious-sasl-inspection`) add `kroxylicious-identity-api` as a compile-scope dependency with an `ignoredNonTestScopedDependencies` override to suppress the warning.

- **Dependency enforcer allowlists**: `kroxylicious-identity-api` must be added to `bannedDependencies` allowlists in the `kroxylicious-filters`, `kroxylicious-kms-providers`, and `kroxylicious-kubernetes` parent POMs.

- **`@Unique` FQN in error message assertions**: tests that assert on the fully-qualified annotation name in error messages (e.g. in `ProxySubjectTest`, `AclAuthorizerServiceTest`) must update from `io.kroxylicious.proxy.authentication.Unique` to `io.kroxylicious.identity.Unique`.

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
| `io.kroxylicious.proxy.authentication.Principal` deleted | Binary-incompatible | Code compiled against the old interface must be recompiled. All implementations change to `io.kroxylicious.identity.Principal`. |
| `@Unique` moved from `io.kroxylicious.proxy.authentication` to `io.kroxylicious.identity` | Binary-incompatible | Code compiled against the old annotation must be recompiled. No known external consumers. |
| `Subject` renamed to `ProxySubject` | Binary- and source-incompatible | All code referencing the concrete `Subject` type by name must be updated. |
| `ProxySubject` constructor and `PrincipalFactory` return type change from proxy `Principal` to identity-api `Principal` | Binary-incompatible | Callers must be recompiled. The type bound is strictly widened so no source changes are needed at call sites. |
| `FilterContext.authenticatedSubject()` return type changes from `Subject` to `ProxySubject` | Binary-incompatible | Filter implementations and callers must be recompiled. Source-incompatible for implementations that declare the return type explicitly. |
| `RouterContext.authenticatedSubject()` return type changes from `Subject` to `ProxySubject` | Binary-incompatible | Router implementations and callers must be recompiled. Source-incompatible for implementations that declare the return type explicitly. |
| `FilterContext.clientSaslAuthenticationSuccess()` parameter changes from `Subject` to `ProxySubject` | Binary-incompatible | Filter implementations calling or implementing this method must be recompiled. |
| `TransportSubjectBuilder.buildTransportSubject()` return type changes from `CompletionStage<Subject>` to `CompletionStage<ProxySubject>` | Binary-incompatible | Transport subject builder implementations must be recompiled. |
| `SaslSubjectBuilder.buildSaslSubject()` return type changes from `CompletionStage<Subject>` to `CompletionStage<ProxySubject>` | Binary-incompatible | SASL subject builder implementations must be recompiled. |
| `Authorizer.authorize()` parameter type changes from `io.kroxylicious.proxy.authentication.Subject` (now renamed to `ProxySubject`) to `io.kroxylicious.identity.Subject` (the new interface) | Binary- and source-incompatible | `Authorizer` implementations must be recompiled and must update one import. Two implementations exist in the codebase; the fix is mechanical. |
| `AuthorizeResult`'s `subject` component type changes from `io.kroxylicious.proxy.authentication.Subject` (now renamed to `ProxySubject`) to `io.kroxylicious.identity.Subject` (the new interface) | Binary- and source-incompatible | Code creating or deconstructing `AuthorizeResult` instances must be recompiled. The record's canonical constructor and `subject()` accessor change type. Source fix is mechanical (change one import). |

All other changes (adding a new module, adding dependency allowlist entries) are source- and binary-compatible.

## Rejected alternatives

### Extract concrete types into the new module

Moving the concrete `Subject` record, `Principal` interface, `User`, `Unique`, `PrincipalFactory`, `UserFactory`, and `SubjectBuildingException` into a new module while keeping the existing package name `io.kroxylicious.proxy.authentication` would create a split package: two Maven artifacts contributing types to the same Java package.
Split packages block JPMS adoption, confuse build tooling, and are considered bad practice.
The interface extraction approach avoids this entirely by using a new package.

### Include a concrete `Subject` implementation in the new module

Providing a ready-made `Subject` implementation (e.g. `DefaultSubject`) in `kroxylicious-identity-api` was considered so that external consumers wouldn't need to write their own.
This was deferred because:

- The interface is a functional interface (`Subject` has one abstract method), so anonymous implementations are trivial: `() -> myPrincipalSet`.
- External consumers building production systems will likely want their own implementation with domain-specific validation or immutability guarantees.
- Adding a concrete implementation can be done later without breaking changes if there is demand.

### Generalise the existing `Subject` record and ship it in `identity-api`

Rather than introducing a minimal `Subject` interface and renaming the existing concrete record to `ProxySubject`, an alternative would be to remove the `User`-principal validation from the existing `Subject` record and move it directly into `kroxylicious-identity-api` as a general-purpose concrete type.
This would avoid the rename (no `ProxySubject`, no source-incompatible change for downstream code referencing `Subject` by name) and give external consumers a ready-made implementation.

This was rejected for several reasons:

1. **Split package or forced package rename for all consumers.**
   If the record kept its `io.kroxylicious.proxy.authentication` package, two Maven artifacts would contribute types to the same package — a split package that blocks JPMS and confuses tooling.
   If it moved to `io.kroxylicious.identity`, every downstream reference would still need updating (the same source-incompatible cost as the rename to `ProxySubject`), but with the additional confusion of a type called `Subject` silently losing its proxy-specific validation.

2. **The `User` validation is load-bearing within the proxy.**
   The proxy's authentication pipeline relies on non-anonymous subjects containing exactly one `User` principal.
   Removing this validation from the concrete type would push enforcement responsibility to every call site that constructs a subject within the proxy, creating a class of bugs where subjects without a `User` principal silently propagate through the pipeline.
   The `ProxySubject` approach keeps this invariant co-located with the type, where it is easiest to maintain and hardest to forget.

3. **It conflates two concerns with different stability requirements.**
   The identity-api module is intended to be a stable, minimal dependency for external consumers.
   The concrete `Subject` record in `kroxylicious-api` carries proxy-specific behaviour (`uniquePrincipalOfType`, `allPrincipalsOfType`, `isAnonymous`, `User` validation) that may evolve with the proxy.
   Shipping a concrete implementation in the stable module locks in that behaviour and constrains future changes.
   The interface approach decouples the contract (what external consumers depend on) from the implementation (what the proxy needs).

4. **External consumers gain little.**
   The `Subject` interface is a functional interface with a single `principals()` method, so external consumers can implement it trivially (`() -> myPrincipalSet`).
   A generalized concrete record adds convenience, but at the cost of the issues above.
   If demand for a concrete implementation materialises, it can be added later without breaking changes — the interface approach keeps this option open.

[prop-9]: https://github.com/kroxylicious/design/blob/main/proposals/009-authorizer.md
