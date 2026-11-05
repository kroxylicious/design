# 110 - Plugin Configuration Versioning

This proposal introduces explicit configuration schema versioning for plugins by extending the existing `@Plugin` annotation with a `configVersion` attribute.
Plugin implementations can declare support for multiple configuration schema versions simultaneously, enabling controlled API evolution and migration periods.
Users explicitly specify which configuration schema version they are using via a `version` field in their YAML configuration.
This establishes a foundation for Kubernetes-style API versioning (v1alpha1, v1beta1, v1) that will be fully realized in PR #96's multi-file configuration system.

## Current situation

Plugins are referenced in configuration using either their simple class name or fully qualified name.
The proxy resolves these references at startup through ServiceLoader discovery.
Each plugin has a single configuration schema tied to its `@Plugin(configType = ...)` annotation.
When a plugin's configuration needs to evolve, the plugin author must choose between breaking existing users or maintaining backward compatibility through complex conditional logic in a single configuration class.
Plugin API stability is implicitly coupled to the project's semantic version, making it difficult to ship experimental or unstable plugin configuration schemas alongside stable ones as the project approaches 1.0.0.

## Motivation

Kroxylicious is approaching its 1.0.0 release, which will establish backward compatibility guarantees for public APIs.
However, different plugins may have different maturity levels and configuration schema stability guarantees.
Coupling all plugin configuration schemas to a single project version creates tension between shipping experimental features and maintaining stability.
The Record Encryption filter, for example, may need multiple configuration schema revisions before it stabilizes, but tying those revisions to the project version would either delay 1.0.0 or force premature API commitments.

Kubernetes-style API versioning (v1alpha1, v1beta1, v1) provides a well-understood model for expressing configuration schema maturity.
Adopting this model for individual plugin configurations allows the project to reach 1.0.0 while clearly communicating that specific plugin configurations remain experimental.
The versioning scheme also enables controlled migration paths where plugin authors can support multiple configuration schema versions in the same plugin implementation, allowing users to migrate gradually.

This proposal establishes the versioning mechanism that PR #96 will build upon.
By making configuration version an explicit concept in 1.0.0, we ensure users understand that plugin configurations can evolve independently of the project version.
PR #96 will then add the multi-file layout, dependency graphs, and JSON Schema validation that make versioned configurations more powerful.

## Proposal

### Functional changes

Plugin authors will annotate their implementations with multiple `@Plugin` annotations, each specifying a different `configVersion` and corresponding `configType`.
The existing `@Plugin` annotation becomes `@Repeatable`, allowing a single implementation class to support multiple configuration schema versions simultaneously.
Users will specify which configuration schema version they are using via a separate `version` field in their YAML configuration.
The proxy will validate at configuration parse time that the referenced version matches one of the plugin's declared configuration versions, failing fast with a clear error message if no match is found.

For proxy users, configuration syntax extends from:
```yaml
type: RecordEncryption
config:
  # legacy config fields
```

to support an explicit `version` field:
```yaml
type: RecordEncryption
version: v1alpha1
config:
  # v1alpha1 config fields
```

When a version is present, the proxy uses it to select which `@Plugin(configVersion = "...", configType = ...)` annotation to use for deserialization.
When no version is specified, the proxy uses the legacy configuration (the `@Plugin` annotation with an empty `configVersion`).

Version validation ensures that configuration matches plugin implementation.
If a user specifies `version: v1alpha1` but the plugin has no `@Plugin(configVersion = "v1alpha1", ...)` annotation, the proxy rejects the configuration during parsing with an error message identifying the mismatch.
This fail-fast behavior prevents runtime surprises from version mismatches.

The enforcement policy evolves across Kroxylicious releases.
In versions before 1.0.0, version annotations are optional and the `version` field in configuration is optional.
When a plugin declares versioned configurations but the user's configuration omits the `version` field, the proxy logs a warning but continues using the legacy configuration.
This allows plugin authors to begin adopting versioned configurations while maintaining compatibility with existing deployments.
In 1.0.0 and later, when a plugin declares versioned configurations, user configurations must include an explicit `version` field.
The proxy rejects configurations that omit required versions.
An environment variable `KROXYLICIOUS_REQUIRE_PLUGIN_VERSIONS` allows operators to opt into strict enforcement before 1.0.0 for testing purposes.

For filter authors and plugin developers, adding a versioned `@Plugin` annotation signals the configuration schema's maturity.
Annotating with `@Plugin(configVersion = "v1alpha1", configType = RecordEncryptionConfigV1Alpha1.class)` communicates that the configuration is experimental and subject to breaking changes.
Transitioning from v1alpha1 to v1beta1 involves adding another `@Plugin` annotation with a new config type, but users explicitly opt into the new version by updating their `version` field.
Plugin authors can support multiple versions in the same implementation during migration periods, allowing gradual rollout.
When a plugin's configuration reaches stability, annotating it with `@Plugin(configVersion = "v1", ...)` communicates that the configuration schema will remain backward compatible within the v1 series.

The instanceof dispatch pattern enables a single implementation class to handle multiple configuration versions.
A plugin's `initialize()` method receives the configuration object and uses `instanceof` pattern matching to determine which version was provided:

```java
public SharedEncryptionContext<K, E> initialize(
        FilterFactoryContext context, Object config) {
    var configuration = Plugins.requireConfig(this, config);
    if (configuration instanceof RecordEncryptionConfigV1Alpha1 v1a1) {
        return initializeV1Alpha1(context, v1a1);
    }
    else if (configuration instanceof RecordEncryptionConfig legacy) {
        return initializeLegacy(context, legacy);
    }
    throw new PluginConfigurationException("Unsupported config version");
}
```

This maintains full backward compatibility while allowing controlled evolution.

Nested plugin references in the legacy format continue to work as they do today.
Versioned configuration schemas that need to reference other plugins will use the patterns introduced in PR #96 (`HasPluginReferences` interface).
This proposal does not change how nested plugins are referenced in the legacy single-file format.

### Public API changes

The existing `@Plugin` annotation in `io.kroxylicious.proxy.plugin` will be extended with a `configVersion` attribute and made `@Repeatable`:

```java
@Repeatable(Plugins.class)
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
public @interface Plugin {
    /**
     * The configuration type for this plugin.
     */
    Class<?> configType();
    
    /**
     * The configuration schema version identifier.
     * Empty string (default) indicates the legacy unversioned configuration.
     * Non-empty values should follow Kubernetes-style versioning: v1alpha1, v1beta1, v1, etc.
     */
    String configVersion() default "";
}
```

A container annotation is required for `@Repeatable`:

```java
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
public @interface Plugins {
    Plugin[] value();
}
```

Example usage for a plugin supporting multiple configuration versions:

```java
@Plugin(configType = RecordEncryptionConfig.class) // legacy, configVersion = ""
@Plugin(configVersion = "v1alpha1", configType = RecordEncryptionConfigV1Alpha1.class)
public class RecordEncryption<K, E> implements FilterFactory<Object, SharedEncryptionContext<K, E>> {
```

**Design compromise: loss of compile-time type safety.** When a plugin supports multiple configuration versions, the type parameter for the plugin interface (e.g., `FilterFactory<C, ...>`) must be `Object` instead of a specific configuration type. This is unavoidable because multiple config versions form a union type which Java's generics cannot express directly. The cost is mitigated by the `Plugins.requireConfig()` helper (which validates the config type at runtime) and by `instanceof` pattern matching in `initialize()`.

A new helper method will be added to the `Plugins` utility class in `io.kroxylicious.proxy.plugin`:

```java
public final class Plugins {
    /**
     * Type-checks and casts a configuration object for a plugin that supports multiple
     * configuration versions. Returns the configuration if it matches one of the plugin's
     * declared config types, otherwise throws PluginConfigurationException.
     * 
     * @param plugin the plugin instance
     * @param config the configuration object to validate
     * @return the configuration object, validated
     * @throws PluginConfigurationException if config type doesn't match any declared config type
     */
    public static Object requireConfig(Object plugin, Object config) {
        // implementation validates against all @Plugin annotations on plugin.getClass()
    }
}
```

A new `VersionMismatchException` will be added to `io.kroxylicious.proxy.plugin`:

```java
public class VersionMismatchException extends RuntimeException {
    public VersionMismatchException(String message) {
        super(message);
    }
}
```

This exception is thrown when a configuration specifies a `version` that does not match any `@Plugin(configVersion = "...")` annotation on the plugin implementation.

No changes are required to existing configuration classes that use `@PluginImplName` and `@PluginImplConfig`.
Those annotations continue to work as they do today for legacy configurations.

### Migration plan

The migration proceeds in two phases aligned with Kroxylicious release versions.

#### Phase 1: Infrastructure and adoption (pre-1.0.0)

Phase 1 ships in version 0.22.0 or similar pre-1.0 releases and continues until 1.0.0.

- All version-related infrastructure is implemented: the `@Plugin(configVersion = "...")` attribute, `@Repeatable` support, the parsing logic for the `version` field, validation logic, and the enforcement policy.
- Enforcement defaults to warning mode.
- Built-in plugins receive versioned `@Plugin` annotations indicating their configuration schema stability level (e.g., `@Plugin(configVersion = "v1alpha1", configType = RecordEncryptionConfigV1Alpha1.class)` for experimental configurations).
- Documentation and examples are updated to show the `version` field in configuration.
- When users reference a plugin that declares versioned configurations but the configuration omits the `version` field, the proxy logs a warning indicating that explicit versions will be required in 1.0.0.
- Example warning: "Plugin 'RecordEncryption' declares versioned configurations but config does not specify version. Add 'version: v1alpha1' field (required in 1.0.0+)".
- Plugin authors can support multiple configuration versions via multiple `@Plugin` annotations with different `configVersion` values, allowing migration periods.
- Users are encouraged to add explicit `version` fields to prepare for 1.0.0.
- All existing configurations continue to work without modification (they use the legacy `@Plugin` annotation with `configVersion = ""`).
- The `KROXYLICIOUS_REQUIRE_PLUGIN_VERSIONS` environment variable allows operators to opt into strict enforcement before 1.0.0 by setting it to `true`, treating missing versions as errors rather than warnings for testing purposes (particularly useful in CI pipelines and staging environments).

#### Phase 2: Enforcement (1.0.0+)

Phase 2 begins with the 1.0.0 release.

- The enforcement policy changes from warning to error when a plugin declares versioned configurations but the configuration omits the `version` field.
- Configurations without explicit versions fail during parsing with `VersionMismatchException`.
- This breaking change is acceptable at a major version boundary and has been signaled through warnings in all prior releases.
- Users who updated their configurations in response to warnings experience no disruption.
- Users who ignored warnings must add `version` fields to their plugin configurations before upgrading to 1.0.0.
- The migration path is clear and mechanical: each warning message indicates exactly which version to specify.

### Scope: What this proposal includes

This proposal is tightly focused on establishing the versioning mechanism:

1. **`@Plugin(configVersion = "...")` attribute**: Extending the existing annotation to support multiple configuration versions via `@Repeatable`.
2. **`version` field in YAML**: A separate field alongside `type` and `config` in the existing single-file format.
3. **instanceof dispatch pattern**: Plugin implementations use `instanceof` to determine which configuration version they received.
4. **Version validation**: Runtime checks that the `version` field matches a declared `@Plugin(configVersion = "...")`.
5. **Phased enforcement**: Warnings pre-1.0.0, errors in 1.0.0+, with `KROXYLICIOUS_REQUIRE_PLUGIN_VERSIONS` for early opt-in.
6. **Migration periods**: Supporting multiple configuration versions in one plugin implementation class.

The `version` field works within the existing single-file configuration format. Name resolution for plugins remains unchanged (simple names when unambiguous, FQCNs when ambiguous).

### Scope: What is deferred to PR #96

PR #96 (Config2: Multi-file plugin configuration) will build on this versioning foundation with:

- Multi-file `plugins.d/` layout with one file per plugin instance
- `PluginReference<T>` and `HasPluginReferences` for explicit dependency graphs
- Dependency graph validation (cycle detection, referential integrity)
- JSON Schema validation for versioned configurations
- `@Stateless` annotation and shared plugin instances
- `ResolvedPluginRegistry` for dependency injection
- `Snapshot` abstraction and change detection (generation numbers)
- Binary resource support (`@ResourceType`) and out-of-band passwords
- FQCN requirement for `type` field in multi-file format
- Migration tool from single-file to multi-file format

All mechanisms in this proposal carry forward to PR #96 without changes:
- Same `@Plugin(configVersion = "...")` semantics
- Same `version` field name and position
- Same `instanceof` dispatch pattern
- Same validation logic
- Same enforcement timeline

Users will transition from single-file configs with `version` fields (this proposal) to multi-file configs (PR #96) at their own pace. Both formats will coexist.

## Affected/not affected projects

### Affected

The kroxylicious repository is affected.
Changes span:
- **kroxylicious-api**: Extending `@Plugin` with `configVersion` attribute, making it `@Repeatable`, adding `Plugins` container annotation, adding `VersionMismatchException`, extending `Plugins` utility class with `requireConfig()`.
- **kroxylicious-runtime**: Parsing logic for `version` field in YAML, version validation logic, enforcement policy implementation.
- **Filter modules**: Optionally adding versioned `@Plugin` annotations to introduce versioned configuration schemas. Existing filters continue to work with only the legacy `@Plugin` annotation.
- **kroxylicious-kms**: KMS providers can optionally add versioned configurations.
- **kroxylicious-authorizer-api**: Authorizers can optionally add versioned configurations.

### Not affected

The kroxylicious-operator repository is not directly affected.
The operator passes user-provided configuration to the proxy without interpreting plugin type strings, so versioned syntax passes through transparently.
The Kubernetes CRD schema already permits arbitrary strings in plugin type fields.

## Compatibility

Before 1.0.0, all changes are backward compatible.
Existing configurations without `version` fields continue to work, using the legacy configuration schema (the `@Plugin` annotation with `configVersion = ""`).
Existing plugins with only a single `@Plugin` annotation continue to work unchanged.
The only behavioral change is the addition of warning messages when a plugin declares versioned configurations but the user's configuration omits the `version` field. These warnings do not prevent startup or operation.

At 1.0.0, the change becomes intentionally breaking for configurations that reference plugins with versioned configurations but omit the `version` field.
This is acceptable at a major version boundary and follows semantic versioning principles.
The breakage is limited to configurations that ignored warnings in prior releases.
Configurations for plugins that never added versioned `@Plugin` annotations (remaining with only the legacy annotation) continue to work without modification even at 1.0.0.

For plugin developers, adding a versioned `@Plugin` annotation is a commitment to support that configuration schema version.
Once a plugin declares `@Plugin(configVersion = "v1alpha1", ...)`, removing support for that version in a future release would break any configurations specifying `version: v1alpha1`.
The conventional approach is to:
1. Start with v1alpha1 for experimental configuration schemas
2. Progress through v1beta1 as the schema stabilizes
3. Reach v1 for stable schemas with backward compatibility guarantees
4. Support multiple versions during migration periods via multiple `@Plugin` annotations

The Kubernetes CRD versioning approach provides precedent for version transitions:
- Moving from v1alpha1 to v1beta1 may involve breaking changes to configuration structure
- Moving from v1beta1 to v1 should avoid breaking changes where possible but may make incompatible changes if necessary
- Moving from v1 to v2 is a major version transition requiring careful migration planning

During migration periods, plugin authors can support both old and new versions:
```java
@Plugin(configType = RecordEncryptionConfig.class) // legacy
@Plugin(configVersion = "v1alpha1", configType = RecordEncryptionConfigV1Alpha1.class)
@Plugin(configVersion = "v1beta1", configType = RecordEncryptionConfigV1Beta1.class)
public class RecordEncryption<K, E> implements FilterFactory<Object, SharedEncryptionContext<K, E>>
```

Users migrate by adding the `version` field and updating their config structure to match the new schema.

## Rejected alternatives

### Semver version strings

Using semantic version strings (1.0.0, 1.1.0, 2.0.0) instead of Kubernetes-style versions was considered.
Semantic versioning provides more granular version information and is familiar to Java developers.
However, Kubernetes-style versioning has significant advantages.
The alpha/beta/stable progression clearly communicates configuration schema maturity in a way that semantic versions do not.
A configuration schema at version 0.5.0 might be quite stable or highly experimental; the version number alone does not convey this.
A configuration schema at version v1alpha1 unambiguously signals experimental status.
Kubernetes-style versioning is already used in the kroxylicious-kubernetes-api module for CRDs, so adopting it for plugin configuration maintains consistency across the project.

### Composite version string (original proposal approach)

The original version of this proposal used a composite type string like `type: RecordEncryption/v1alpha1` instead of separate `type` and `version` fields.
This was rejected to align with PR #96's approach, which uses separate fields to match Kubernetes resource conventions where `kind` and `apiVersion` are distinct.
The separate field approach also:
- Provides clearer separation between plugin identity and configuration version
- Simplifies parsing (no need to split on `/` and handle escaping)
- Enables better validation (version is always in a known location)
- Aligns with the multi-file format in PR #96 where metadata (name, type, version) is cleanly separated from config content

### Separate @Version annotation (original proposal approach)

The original version of this proposal introduced a new `@Version` annotation separate from `@Plugin`.
This was rejected in favor of extending the existing `@Plugin` annotation with a `configVersion` attribute because:
- It reduces API surface area (one annotation instead of two)
- It keeps version information co-located with the config type it describes
- It makes the relationship between version and config type explicit and type-safe
- It aligns with PR #96's multi-version design, where each version maps to a specific config type
- The `@Repeatable` mechanism naturally supports multiple versions

### Version for disambiguation instead of configuration schema versioning

The original proposal treated version as a disambiguation mechanism when multiple plugin implementations share the same simple name.
This was rejected because:
- Version should identify the configuration schema, not the implementation
- Name disambiguation is already solved by FQCNs (and will be required in PR #96's multi-file format)
- Conflating version with implementation identity creates confusion about what version means
- Configuration schema version is the more important concept for users

### Plugin version compatibility checking

Implementing version compatibility checking rather than exact version matching was considered.
The proxy might accept a configuration with `version: v1alpha1` when the plugin only declares `v1alpha2` if the versions are compatible according to some policy.
This would provide more flexibility during upgrades.
However, defining compatibility rules for alpha and beta versions is difficult because those version levels explicitly allow breaking changes.
For stable v1 versions, semantic versioning compatibility rules could apply, but mixing compatibility rules across version levels creates complexity.
The exact-match approach is simpler, more predictable, and encourages users to make deliberate version upgrade decisions.
When a plugin author releases v1alpha2, configurations must explicitly update to `version: v1alpha2`, ensuring users are aware of potential breaking changes.

### Automatic version migration

Providing automatic migration from v1alpha1 to v1beta1 through configuration transformations was considered.
The proxy might detect `version: v1alpha1` and automatically transform it to v1beta1 format according to plugin-provided migration rules.
This would ease version transitions but adds significant complexity to the configuration system.
Migration rules would need to be discoverable, machine-readable, and composable across multiple plugin upgrades.
The approach also obscures what version is actually in use, potentially causing confusion.
Explicit version references in configuration make the actual configuration schema version transparent and keep migration responsibility with the configuration owner rather than embedding it in proxy logic.
