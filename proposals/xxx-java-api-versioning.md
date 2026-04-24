# Java API Versioning

We propose a mechanism for declaring the stability level of Kroxylicious's Java plugin APIs (SPIs), and for detecting at runtime when a plugin was compiled against an incompatible version of an API. This gives plugin developers clear signals about API maturity, and gives operators clear error messages when a plugin is not compatible with the proxy version they are running.

## Current situation

Kroxylicious exposes several Java interfaces that plugin developers implement: `FilterFactory`, `KmsService`, `Authorizer`, and so on. These interfaces are discovered at runtime via `ServiceLoader`.

Currently there is no way to communicate the stability of these interfaces. A plugin developer implementing `FilterFactory` has no indication whether the interface might change incompatibly in the next release. Similarly, if a plugin was compiled against one version of an interface but is loaded into a proxy providing a different, incompatible version, the failure manifests as an opaque `NoSuchMethodError` or `AbstractMethodError` with no guidance to the end user about what went wrong or how to fix it.

## Motivation

1. **Signalling API stability.** Kroxylicious follows Kubernetes-style API maturity conventions (`v1alpha1`, `v1beta1`, `v1`) for its Kubernetes CRDs. The Java plugin APIs should use the same scheme, making it clear to plugin developers which APIs are stable and which may change.

2. **Explicit opt-in for unstable APIs.** Plugin developers knowingly using unstable APIs should acknowledge this explicitly, rather than discovering instability only when an upgrade breaks them.

3. **Better error messages on version mismatch.** When a plugin compiled against `FilterFactory` `v1beta1` is loaded into a proxy providing `v1beta2`, the operator should see a message explaining the incompatibility and suggesting remediation, not a raw JVM linkage error.

4. **Foundation for future evolution.** Once APIs are versioned, we can evolve them with confidence: bumping an unstable version signals to plugin developers that recompilation (and possibly code changes) are needed.

## Proposal

### `@ApiVersion` annotation

A new annotation, `@ApiVersion`, is placed on plugin interfaces to declare their API version:

```java
@ApiVersion("v1beta1")
public interface FilterFactory<C, F extends Filter> {
    // ...
}
```

The version string follows the regex `v\d+((alpha|beta)\d+)?`, giving versions like `v1alpha1`, `v1beta2`, or `v1`. Version ordering follows API maturity: `v1alpha1 < v1alpha2 < v1beta1 < v1beta2 < v1 < v2alpha1 < v2`. These versions form a total order, defined as part of the version semantics so that future work can depend on it if needed.

The annotation is `@Retention(RUNTIME)` so it can be read at runtime for logging and opt-in enforcement. It is placed on the plugin interface (SPI), not on the implementation, because the version describes the contract, not any particular implementation of it.

### Stability semantics

Versions are classified into two categories:

- **Unstable** (`alpha` or `beta`): may change incompatibly between any Kroxylicious releases. Using an unstable API at runtime requires explicit opt-in by the end user via the `KROXYLICIOUS_ALLOWED_UNSTABLE_APIS` environment variable.
- **Stable** (no qualifier, e.g. `v1`): will not change incompatibly, and can only be removed in a new major version of the Maven module which defines it. A version bump (e.g. `v1` to `v2`) signals a breaking change; plugins compiled against the old version are not assumed to be compatible.

#### Relationship to semantic versioning

API versioning and Maven module semantic versioning are complementary but distinct. A minor or patch release of a Maven module may change unstable APIs incompatibly, whereas stable APIs are subject to semver's major-version contract: they can only be changed incompatibly or removed when the Maven module's major version is bumped. The API version scheme signals the maturity and compatibility promises of individual interfaces; semantic versioning governs the release lifecycle of the module as a whole. This applies equally to Kroxylicious's own modules and to third-party modules that define `@ApiVersion`-annotated interfaces.

### Initial version assignments

The following table shows the initial API version assignments for existing plugin interfaces:

| Interface | Module | Version |
|---|---|---|
| `AuthorizerService` | `kroxylicious-authorizer-api` | `v1` |
| `ByteBufferTransformationFactory` | `kroxylicious-simple-transform` | `v1` |
| `EntityNameMapperService` | `kroxylicious-entity-isolation` | `v1` |
| `FilterFactory` | `kroxylicious-api` | `v1beta1` |
| `KekSelectorService` | `kroxylicious-record-encryption` | `v1` |
| `KmsService` | `kroxylicious-kms` | `v1` |
| `MicrometerConfigurationHookService` | `kroxylicious-runtime` | `v1` |
| `PrincipalFactory` | `kroxylicious-api` | `v1beta1` |
| `SaslObserverFactory` | `kroxylicious-sasl-inspection` | `v1` |
| `SaslSubjectBuilderService` | `kroxylicious-api` | `v1` |
| `TransportSubjectBuilderService` | `kroxylicious-api` | `v1` |

### Opt-in for unstable APIs

When a plugin interface has an unstable version, loading any plugin that implements it will fail unless the operator has explicitly opted in. 
The failure will usually be at proxy startup, but this cannot be 100% guaranteed by the framework.
Failing prevents operators from unknowingly depending on an API that may change incompatibly.

Opt-in is controlled via the `KROXYLICIOUS_ALLOWED_UNSTABLE_APIS` environment variable, which takes a comma-separated list of fully-qualified plugin interface names:

```
KROXYLICIOUS_ALLOWED_UNSTABLE_APIS=com.example.MySpi,com.example.MyOtherSpi
```

An environment variable is used rather than a system property because it is more naturally configured in Kubernetes Pod specs and propagates across wrapper scripts.

If an unstable API is not listed, the proxy throws `DisallowedUnstableApiException` at startup with a message identifying the API, its version, and the environment variable needed to opt in.

As a pragmatic exception, `FilterFactory` (currently at `v1beta1`) is always allowed without opt-in. `FilterFactory` is binary-compatibility-coupled to `kafka-clients`, which is outside the project's control. Graduating it to `v1` would require decoupling that dependency — a very large effort. The `v1beta1` label primarily informs plugin developers of this reality. Since `FilterFactory` cannot realistically reach stability in the near term, requiring opt-in for the central API of the entire proxy would impose permanent friction with no corresponding safety benefit.

This mechanism is intentionally coarse-grained: it operates at the level of the API interface, not individual plugins. If an end user opts into `FilterFactory` `v1beta1`, all filter plugins are permitted. This keeps configuration simple and avoids the need to enumerate every plugin individually. In any case, end users are already in control of the plugins they use via the proxy configuration file.

The opt-in is not version-specific: if an operator accepts that an API is unstable, a subsequent version bump within the unstable range (e.g. `v1beta1` to `v1beta2`) does not require re-acknowledgement. The operator has already accepted the risk of instability.

### Compatibility rules

The compatibility semantics of APIs follow Kubernetes conventions:

* An API can change in a backwards compatible way while sticking with the same version. 
  For example adding a new method to the `FilterContext` is backwards compatible: 
  Code compiled against the old version that lacked the new method still compiles and links.
  This choice does not prevent breakage in a downgrade scenario: 
  A plugin implementation that calls the new method will not work in an older version of 
  the proxy where that method is missing.
  The compromise is deliberate. The strictness necessary to prevent breakage in a downgrade scenario
  would require almost every change to a plugin API to have a new version, and thus require all plugin implementations to be rebuilt. 
  We think that's too costly for a small ecosystem to sustain, given that downgrading the runtime but not the plugins would be an uncommon thing to do.
* An API that changes in a backwards incompatible way must have a new version.
* APIs which have an `alpha` version could disappear entirely in any future release.
* APIs which have a `beta` version are expected to eventually become stable, but may still change incompatibly in any future release.
* Stable APIs (those without an `alpha` or `beta` modifier) will not change incompatibly, and can only be removed in a new major version of the Maven module which defines them.
  In other words, semver's major-version contract applies only to APIs which are explicitly stable. 

A plugin compiled against version C is compatible with running version R if and only if:

| Running (R) | Compiled against (C) | Compatible?                       | Rationale |
|---|---|---|---|
| `v1beta1`   | `v1beta1`            | Yes, binary compatibility assumed | Exact match |
| `v1beta2`   | `v1beta1`            | No                                | Unstable versions require exact match |
| `v1`        | `v1`                 | Yes, binary compatibility assumed | Exact match |
| `v2`        | `v1`                 | No                                | Require exact match |
| `v1`        | `v2`                 | No                                | Require exact match |


### Compile-time version capture via annotation processor

To detect version mismatches at runtime, we need to know which API version a plugin was compiled against. We cannot simply read the `@ApiVersion` annotation from the implementation class at runtime, because loading the class triggers JVM linking -- which is precisely the thing that could fail when there is a version mismatch. We need the version information before the class is loaded.

The solution is a Java annotation processor, `ApiVersionProcessor`, which runs at compile time and writes version metadata to a resource file.

The processor:

1. Processes each class annotated with `@Plugin`.
2. Walks the type hierarchy (via `Types.directSupertypes()`, recursively) to find interfaces annotated with `@ApiVersion`.
3. Records each `interface:version` pair.
4. On the final annotation processing round, writes one resource file per implementation class.

The resource file path is `META-INF/kroxylicious/api-version/<impl-fqcn>`. The content is one line per versioned interface, in the format `<interface-fqcn>:<version>`:

```
io.kroxylicious.proxy.filter.FilterFactory:v1beta1
```

If a plugin class implements multiple versioned interfaces, all are recorded and checked independently at runtime.

If no `@ApiVersion`-annotated interface is found in the type hierarchy, the processor emits a compiler warning. This encourages interface authors to adopt `@ApiVersion`.

#### Module structure

The processor lives in a new module, `kroxylicious-api-version-processor`. It cannot live in `kroxylicious-annotations` (which has no dependencies) because it needs `kroxylicious-api` types on its compilation classpath, which would create a cycle. The build order is:

```
kroxylicious-annotations -> kroxylicious-api -> kroxylicious-api-version-processor -> (everything else)
```

The processor has no runtime dependencies beyond the JDK. It depends on `kroxylicious-api` at test scope only, since it uses string-based annotation lookups (`"io.kroxylicious.proxy.plugin.ApiVersion"`) rather than class references. The processor is tested using `javax.tools.JavaCompiler` directly, avoiding a dependency on Google's `compile-testing` library.

#### Incremental compilation

IDE incremental compilers (IntelliJ, Eclipse) may not re-run the processor for an implementation class when only the interface's `@ApiVersion` annotation changes. In practice this is a minor risk: end users consume plugins that were clean-built by Maven or Gradle. The risk falls on developers, who are accustomed to needing clean builds in such cases.

#### Integrity-by-default (JEP 472)

From JDK 23+, annotation processors are no longer discovered automatically from the classpath. The processor must be declared explicitly via `annotationProcessorPaths` in the Maven compiler plugin configuration. This is a build concern, not an architectural one. Internal modules declare the processor in their POM; the filter archetype includes it for third-party developers.

### Runtime version checking

`ServiceBasedPluginFactoryRegistry` performs the version check during plugin discovery, before the implementation class is loaded. For each provider found via `ServiceLoader`:

1. Look up the resource at `META-INF/kroxylicious/api-version/<provider-fqcn>` using `ClassLoader.getResource()`.
2. Parse each line as `<interface-fqcn>:<version>`.
3. If the interface matches the plugin interface being loaded, compare the compiled-against version with the current `@ApiVersion` using `Version.isCompatibleWith()`.
4. If incompatible, throw `IncompatibleApiVersionException` with a message advising the operator to update the plugin or the proxy.

If the resource file is absent (because the plugin was built without the annotation processor), a warning is logged and the check is skipped. This provides graceful degradation for third-party plugins that have not yet adopted the processor.

### Build integration

**Internal modules**: Each module that contains plugin implementations (e.g. `kroxylicious-filters`, `kroxylicious-kms-providers`, `kroxylicious-authorizer-providers`, `kroxylicious-runtime`) declares the processor in its `maven-compiler-plugin` `annotationProcessorPaths`.

The parent POM's error-prone profile uses `combine.children="append"` on its `annotationProcessorPaths` to add error-prone alongside the version processor rather than replacing it.

**Filter archetype**: The `kroxylicious-filter-archetype` includes the processor in its generated POM template, so third-party plugin developers get version checking by default.

**Third-party plugins not using the archetype**: If they don't add the processor, the version metadata is simply absent and the runtime check degrades gracefully (a warning is logged, but the plugin loads normally).

## Affected/not affected projects

**Affected:**

- `kroxylicious-api` -- `@ApiVersion` annotation and `@Plugin` annotation (already exist in this module)
- `kroxylicious-api-version-processor` -- new module containing the annotation processor
- `kroxylicious-runtime` -- runtime version checking in `ServiceBasedPluginFactoryRegistry`, `Version.isCompatibleWith()` method
- `kroxylicious-filters`, `kroxylicious-kms-providers`, `kroxylicious-authorizer-providers` -- build configuration to enable the processor
- `kroxylicious-filter-archetype` -- build configuration template for third-party developers
- Parent POM -- new module declaration and error-prone profile adjustment

**Not affected:**

- `kroxylicious-operator`, `kroxylicious-kubernetes-api` -- Kubernetes APIs have their own versioning scheme
- `kroxylicious-docs` -- documentation updates will follow separately
- Plugin runtime behaviour -- the version check happens at discovery time, before any plugin code runs

## Compatibility

**Backwards compatibility:** Existing plugins built without the annotation processor continue to work. The runtime check is skipped when version metadata is absent, with a warning logged. This means adoption is incremental -- there is no flag day.

**Forwards compatibility:** The resource file format (`interface:version`, one per line) is extensible. Additional metadata could be added on new lines without breaking existing parsers, which skip lines they don't recognise.

**Future classloader isolation:** This proposal does not preclude future work to load plugins in isolated classloaders or module layers. Version metadata captured at compile time would remain useful in such a scheme -- it could inform decisions about which API version's classes to make visible to a given plugin.

## Rejected alternatives

### `targetApiVersion` element on `@Plugin`

Adding a `targetApiVersion` to the `@Plugin` annotation on implementation classes was considered. However, reading this annotation at runtime requires loading the implementation class, which triggers JVM linking. If the API has changed incompatibly, linking could fail with a raw `NoSuchMethodError` before we can read the annotation -- the very problem we are trying to solve. The annotation processor approach avoids this by writing version information to a resource file that can be read without loading any plugin classes.

### Version in the package name

Encoding the API version in the Java package name (e.g. `io.kroxylicious.proxy.filter.v1beta1.FilterFactory`) would allow multiple API versions to coexist in the same JVM. However existing API classes are not in versioned packages currently, so this would be a backwards incompatible change. It would also mean every future version bump changes the package, breaking all existing plugins. It also requires the proxy to know at compile time which versions it supports, and complicates the interface hierarchy. The overhead is disproportionate to the current need, which is better diagnostics, not version coexistence.

### JPMS module layers

Java Platform Module System (JPMS) module layers could provide true classloader isolation, allowing different plugins to use different API versions simultaneously. This is architecturally appealing but represents a much larger effort: Kroxylicious and its dependencies do not currently use the module system, and retrofitting it would affect every module. The annotation-based approach is complementary -- the version metadata it captures would be useful inputs to a future module layer scheme -- so it does not foreclose this option.

### Per-method `@Since` / `@Until` annotations

Fine-grained annotations on individual methods would track which methods were added or removed in which version. This was rejected as over-engineering for the current need: Kroxylicious APIs are small interfaces, and version-level compatibility is sufficient granularity. Per-method tracking would also create a significant annotation maintenance burden.

### Centralised version registry file

A single properties file listing all plugins and their compiled-against versions was considered instead of one resource file per implementation. The per-implementation approach was chosen because it avoids resource merging concerns (multiple JARs contributing to the same file) and aligns naturally with the `ServiceLoader` discovery model, where each JAR provides its own implementation metadata.
