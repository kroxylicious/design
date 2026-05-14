# 110 - Versioned Plugin Configuration

This proposal introduces explicit API versioning for plugins through a new `@Version` annotation and changes to the plugin type resolution mechanism.
The changes enable plugin implementations to declare their API stability level independently of the project's semantic version and allow users to explicitly reference plugin versions in configuration.
Version information also serves as a disambiguation mechanism when multiple plugin implementations share the same simple class name.

## Current situation

Plugins are referenced in configuration using either their simple class name or fully qualified name.
The proxy resolves these references at startup through ServiceLoader discovery, registering each plugin under both its fully qualified name and simple name.
When multiple plugins share the same simple name, the proxy logs an ambiguity warning and requires users to reference the plugin by its fully qualified name.
Plugin API stability is coupled to the project's semantic version, making it difficult to ship experimental or unstable plugin APIs alongside stable ones as the project approaches 1.0.0.

## Motivation

Kroxylicious is approaching its 1.0.0 release, which will establish backward compatibility guarantees for public APIs.
However, different plugins may have different maturity levels and API stability guarantees.
Coupling all plugin APIs to a single project version creates tension between shipping experimental features and maintaining stability.
The Record Encryption filter, for example, may need multiple major revisions before its API stabilizes, but tying those revisions to the project version would either delay 1.0.0 or force premature API commitments.

Kubernetes-style API versioning (v1alpha1, v1beta1, v1) provides a well-understood model for expressing API maturity.
Adopting this model for individual plugins allows the project to reach 1.0.0 while clearly communicating that specific plugins remain experimental.
The versioning scheme also enables controlled migration paths where plugin authors can ship both alpha and beta implementations in the same JAR, allowing users to migrate gradually.

Version-based disambiguation additionally solves a practical problem for plugin authors who wish to maintain multiple implementations during API transitions.
Currently, two classes named RecordEncryption in different packages create an ambiguity that can only be resolved through fully qualified names.
Adding version as part of the plugin identity allows RecordEncryption/v1alpha1 and RecordEncryption/v1beta1 to coexist without requiring users to remember package structures.

## Proposal

### Functional changes

Plugin authors will annotate their implementations with `@Version("v1alpha1")` or similar version identifiers following Kubernetes conventions.
Users will reference these versioned plugins in configuration using the format `PluginName/version`.
The proxy will validate at configuration parse time that the referenced version matches the plugin's declared version, failing fast with a clear error message if they diverge.
Unversioned plugins and unversioned references will continue to work to maintain backward compatibility with existing deployments.

For proxy users, configuration syntax extends from `type: RecordEncryption` to support `type: RecordEncryption/v1alpha1`.
When a version is present in the type string, the proxy uses it both for validation and for name resolution.
A plugin named RecordEncryption annotated with `@Version("v1alpha1")` can be referenced as either `RecordEncryption/v1alpha1` (explicit version) or `RecordEncryption` (implicit, triggers warning).
If multiple RecordEncryption implementations exist with different versions (v1alpha1 and v1beta1), users disambiguate by including the version rather than switching to fully qualified class names.

Version validation ensures that configuration matches plugin implementation.
If a user references `RecordEncryption/v1alpha1` but the plugin declares `@Version("v1beta1")`, the proxy rejects the configuration during parsing with an error message identifying the mismatch.
If a user references `RecordEncryption/v1alpha1` but the plugin has no `@Version` annotation, the proxy similarly rejects the configuration.
This fail-fast behavior prevents runtime surprises from version mismatches.

The enforcement policy evolves across Kroxylicious releases.
In versions before 1.0.0, version annotations are optional and version references in configuration are optional.
When a plugin declares a version but the configuration omits it, the proxy logs a warning but continues.
This allows plugin authors to begin adopting version annotations while maintaining compatibility with existing configurations.
In 1.0.0 and later, when a plugin declares a version, configurations must include that version.
The proxy rejects configurations that omit required versions.
An environment variable `KROXYLICIOUS_REQUIRE_PLUGIN_VERSIONS` allows operators to opt into strict enforcement before 1.0.0 for testing purposes.

For filter authors and plugin developers, the `@Version` annotation becomes part of the public API contract.
Placing `@Version("v1alpha1")` on a filter implementation signals to users that the API is experimental and subject to breaking changes.
Transitioning from v1alpha1 to v1beta1 may involve incompatible configuration changes, but users explicitly opt into the new version by updating their configuration.
Plugin authors can ship both versions in the same JAR during migration periods, allowing gradual rollout.
When a plugin reaches stability, annotating it with `@Version("v1")` communicates that the API will remain backward compatible within the v1 series.

Version-based disambiguation enables new packaging strategies.
A plugin author maintaining both alpha and beta implementations can ship `io.kroxylicious.filter.encryption.alpha.RecordEncryption` annotated with `@Version("v1alpha1")` and `io.kroxylicious.filter.encryption.beta.RecordEncryption` annotated with `@Version("v1beta1")` in the same JAR.
Users running configurations with `type: RecordEncryption/v1alpha1` receive the alpha implementation while users with `type: RecordEncryption/v1beta1` receive the beta implementation.
This eliminates the need for separate JARs or complex classloader isolation to support parallel versions.

Nested plugin references inherit the same versioning behavior.
When a RecordEncryption filter configuration references a KmsService, that reference can include a version: `kms: VaultKmsService/v1alpha1`.
The same parsing and validation logic applies recursively to all plugin references in the configuration tree, ensuring consistency throughout.

### Public API changes

A new `@Version` annotation will be added to `io.kroxylicious.proxy.plugin` in the kroxylicious-api module:

```java
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
public @interface Version {
    /**
     * The API version identifier for this plugin implementation.
     * Should follow Kubernetes-style versioning: v1alpha1, v1beta1, v1, etc.
     */
    String value();
}
```

A new `VersionMismatchException` will be added to `io.kroxylicious.proxy.plugin` in the kroxylicious-api module:

```java
public class VersionMismatchException extends RuntimeException {
    public VersionMismatchException(String message) {
        super(message);
    }
}
```

This exception is thrown when configuration version references do not match plugin version declarations.

The `PluginFactory` interface in kroxylicious-runtime will gain a new method:

```java
@Nullable
String pluginVersion(String instanceName);
```

This method returns the version from a plugin's `@Version` annotation or null if the plugin is not annotated.
It follows the same signature pattern as the existing `configType(String instanceName)` method and throws `UnknownPluginInstanceException` if the instance name cannot be resolved.

No changes are required to existing filter APIs or configuration classes.
The `@PluginImplName` and `@PluginImplConfig` annotations already support arbitrary string values for the type field, so the slash-separated version syntax works without modification to the annotation processing infrastructure.

### Migration plan

The migration proceeds in two phases aligned with Kroxylicious release versions.

#### Phase 1: Infrastructure and adoption (pre-1.0.0)

Phase 1 ships in version 0.22.0 or similar pre-1.0 releases and continues until 1.0.0.

- All version-related infrastructure is implemented: the `@Version` annotation, the parsing logic, the validation logic, and the enforcement policy.
- Enforcement defaults to warning mode.
- Built-in plugins receive `@Version` annotations indicating their stability level (e.g., `@Version("v1alpha1")` for experimental plugins like Record Encryption, `@Version("v1beta1")` or `@Version("v1")` for more mature filters).
- Documentation and examples are updated to show versioned plugin references.
- When users reference a plugin without including the version, and the plugin has a `@Version` annotation, the proxy logs a warning indicating that explicit versions will be required in 1.0.0.
- Example warning: "Plugin 'RecordEncryption' declares version 'v1alpha1' but config does not specify it. Update config to: type: RecordEncryption/v1alpha1 (required in 1.0.0+)".
- Plugin authors can ship multiple API versions in the same JAR for migration purposes.
- Users are encouraged to update configurations to include explicit versions to prepare for 1.0.0.
- All existing configurations continue to work without modification.
- The `KROXYLICIOUS_REQUIRE_PLUGIN_VERSIONS` environment variable allows operators to opt into strict enforcement before 1.0.0 by setting it to `true`, treating missing versions as errors rather than warnings for testing purposes (particularly useful in CI pipelines and staging environments).

#### Phase 2: Enforcement (1.0.0+)

Phase 2 begins with the 1.0.0 release.

- The enforcement policy changes from warning to error when a plugin declares a version but the configuration omits it.
- Configurations without explicit versions fail during parsing with `VersionMismatchException`.
- This breaking change is acceptable at a major version boundary and has been signaled through warnings in all prior releases.
- Users who updated their configurations in response to warnings experience no disruption.
- Users who ignored warnings must add version suffixes to plugin type references before upgrading to 1.0.0.
- The migration path is clear and mechanical: each warning message indicates exactly which version string to add.

## Affected/not affected projects

### Affected

The kroxylicious repository is affected.
Changes span the kroxylicious-api module (new annotation and exception types), the kroxylicious-runtime module (parsing, validation, and registration logic), and potentially filter implementation modules (adding `@Version` annotations).
The kroxylicious-kms module is affected as KMS provider plugins will need version annotations.
The kroxylicious-authorizer-api module is affected as authorizer plugins will need version annotations.

### Not affected

The kroxylicious-operator repository is not directly affected.
The operator passes user-provided configuration to the proxy without interpreting plugin type strings, so versioned syntax passes through transparently.
The Kubernetes CRD schema already permits arbitrary strings in plugin type fields.

## Compatibility

Before 1.0.0, all changes are backward compatible.
Existing configurations with unversioned plugin references continue to work.
Existing plugins without `@Version` annotations continue to work.
The only behavioral change is the addition of warning messages when versioned plugins are referenced without versions, and these warnings do not prevent startup or operation.

At 1.0.0, the change becomes intentionally breaking for configurations that reference versioned plugins without including the version.
This is acceptable at a major version boundary and follows semantic versioning principles.
The breakage is limited to configurations that ignored warnings in prior releases.
Configurations that never referenced versioned plugins (because all their plugins remained unversioned) continue to work without modification even at 1.0.0.

For plugin developers, adding a `@Version` annotation is a one-way commitment.
Once a plugin is annotated with a version, removing the annotation in a future release would break any configurations that include the version string.
Plugin authors should carefully consider API stability before adding version annotations.
The conventional approach is to start with v1alpha1 for experimental APIs and progress through v1beta1 to v1 as the API stabilizes.

The Kubernetes CRD versioning approach provides precedent for version transitions.
Moving from v1alpha1 to v1beta1 may involve breaking changes to configuration structure.
Moving from v1beta1 to v1 should avoid breaking changes where possible but may make incompatible changes if necessary.
Moving from v1 to v2 is a major version transition requiring careful migration planning.
Kroxylicious adopts these same conventions, relying on users to understand the stability implications of each version level.

## Rejected alternatives

### Semver version strings

Using semantic version strings (1.0.0, 1.1.0, 2.0.0) instead of Kubernetes-style versions was considered.
Semantic versioning provides more granular version information and is familiar to Java developers.
However, Kubernetes-style versioning has significant advantages.
The alpha/beta/stable progression clearly communicates API maturity in a way that semantic versions do not.
A plugin at version 0.5.0 might be quite stable or highly experimental; the version number alone does not convey this.
A plugin at version v1alpha1 unambiguously signals experimental status.
Kubernetes-style versioning is already used in the kroxylicious-kubernetes-api module for CRDs, so adopting it for plugin configuration maintains consistency across the project.

### Version as separate configuration field

Representing version as a separate field in configuration rather than as part of the type string was considered.
The configuration might look like `type: RecordEncryption` and `version: v1alpha1` as sibling fields.
This approach provides clearer separation between plugin identity and version, potentially simplifying parsing.
However, it increases configuration verbosity, requiring two fields instead of one.
It also diverges from patterns like Kubernetes resource definitions where apiVersion is a single field combining API group and version (e.g., apps/v1).
The composite type string approach is more concise and aligns with Kubernetes conventions.

### Plugin version compatibility checking

Implementing version compatibility checking rather than exact version matching was considered.
The proxy might accept a configuration referencing v1alpha1 when the plugin implements v1alpha2 if the versions are compatible according to some policy.
This would provide more flexibility during upgrades.
However, defining compatibility rules for alpha and beta versions is difficult because those version levels explicitly allow breaking changes.
For stable v1 versions, semantic versioning compatibility rules could apply, but mixing compatibility rules across version levels creates complexity.
The exact-match approach is simpler, more predictable, and encourages users to make deliberate version upgrade decisions.
When a plugin author releases v1alpha2, configurations must explicitly opt into the new version, ensuring users are aware of potential breaking changes.

### Automatic version migration

Providing automatic migration from v1alpha1 to v1beta1 through configuration transformations was considered.
The proxy might detect a v1alpha1 configuration and automatically transform it to v1beta1 format according to plugin-provided migration rules.
This would ease version transitions but adds significant complexity to the configuration system.
Migration rules would need to be discoverable, machine-readable, and composable across multiple plugin upgrades.
The approach also obscures what version is actually in use, potentially causing confusion.
Explicit version references in configuration make the actual plugin version transparent and keep migration responsibility with the configuration owner rather than embedding it in proxy logic.
