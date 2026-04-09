# Config2: Multi-file plugin configuration

We propose replacing the current monolithic proxy configuration with a multi-file, Kubernetes-inspired
configuration system. Plugin instances are defined in individual YAML files with explicit versioning,
cross-file dependency references, and optional JSON Schema validation.

## Current situation

Today, all configuration lives in a single YAML file. Filter definitions embed their nested plugin
configurations inline using `@PluginImplName` / `@PluginImplConfig` annotation pairs on the config
record's constructor parameters:

```yaml
filterDefinitions:
  - name: encrypt
    type: RecordEncryption
    config:
      kms: VaultKmsService
      kmsConfig:
        vaultTransitEngineUrl: http://vault:8200/v1/transit
        vaultToken:
          password: my-token
      selector: TemplateKekSelector
      selectorConfig:
        template: "KEK_${topicName}"
```

The proxy resolves these at runtime by discovering `@PluginImplName`-annotated fields, looking up
the named plugin implementation via `ServiceLoader`, and deserialising the corresponding
`@PluginImplConfig` field into the plugin's config type. This has several consequences:

- **No reuse**: two filters that need the same KMS must each embed a copy of the KMS configuration.
- **No independent versioning**: a filter's config schema is monolithic. Changing the KMS config
  format requires the filter to understand and migrate its nested portion.
- **No schema validation**: there is no declarative way to validate plugin configurations before
  the proxy starts.
- **No dependency ordering**: the proxy discovers plugin dependencies implicitly at initialisation
  time, with no upfront visibility into the dependency graph.
- **Opaque to tooling**: since plugin configurations are embedded inside filter configs, external
  tools (Kubernetes operators, CI validators, config linters) cannot inspect or validate them
  independently.

## Motivation

There are five specific drawbacks of the current configuration system that motivate this change.

### 1. Per-plugin JSON schemas are impossible today

It is impossible to write a single JSON schema for the configuration file, because what is allowed
depends on which plugins are present at runtime. But having schemas is desirable for documentation,
editor assistance, and automated validation. By giving each plugin instance its own file, each
plugin version can ship its own JSON schema. These per-plugin schemas can be published to schema
catalogues (e.g. schemastore.org) and consumed by IDEs and CI tools independently of the proxy.

### 2. Lack of uniformity in how plugins are configured

Each plugin point embeds its plugins differently. Filter factories are explicitly named (via
`NamedFilterDefinition`), but other plugins like `KmsService` are anonymous because they are
referenced once by their parent. This inconsistency extends across the codebase: filters,
authorisers, KMS services, subject builders, and key selectors all follow slightly different
patterns. A uniform model where every plugin instance is a named, versioned resource eliminates
this inconsistency.

### 3. The runtime cannot understand inter-plugin dependencies

The lack of uniformity means the runtime has no meaningful understanding of the dependency
relationships between plugins. This matters for dynamic reloading: when a plugin configuration
changes, the runtime needs to know which virtual clusters are affected. Today, dependencies are
discovered implicitly at initialisation time, with no upfront visibility into the graph. Explicit
dependency declarations enable the runtime to reason about the impact of configuration changes.

Note that the runtime does not (and should not) know about all plugin types. Plugins are allowed
to have plugins of their own (e.g. `RecordEncryption` depends on `KmsService` and
`KekSelectorService`, which are not known to the runtime). This rules out approaches that add
top-level definitions for each plugin type (e.g. `kmsDefinitions`), because the runtime cannot
enumerate plugin types it does not know about.

### 4. Plugin instances are not individually identifiable

Eventually we may need to build a control plane for clusters of proxies. Plugin instances would be
important entities in the API of that control plane. For this to work, each plugin instance must
have a unique identity. The current system gives names to filter definitions but not to the plugins
they embed. A model where every plugin instance has a name, a type, and a version makes each one
individually addressable.

### 5. No principled way to evolve plugin configuration

None of the configurations (the proxy's or any of the plugins') are explicitly versioned. A plugin
developer can deprecate properties, but cannot remove them in a controlled manner where the API
evolution is obvious to the user. Explicit version strings (following Kubernetes conventions:
v1alpha1, v1beta1, v1) give plugin developers a principled mechanism for config schema evolution,
including support for multiple concurrent versions during migration periods.

## Proposal

### Configuration layout

The new configuration comprises a `proxy.yaml` and a `plugins.d/` directory:

```
config-dir/
  proxy.yaml
  plugins.d/
    io.kroxylicious.proxy.filter.FilterFactory/
      encrypt.yaml
    io.kroxylicious.kms.service.KmsService/
      vault-kms.yaml
    io.kroxylicious.filter.encryption.config.KekSelectorService/
      my-selector.yaml
```

`proxy.yaml` contains the global proxy settings (virtual clusters, gateways, management endpoints,
default filter chain, micrometer instance names) plus a `version` field:

```yaml
version: v1alpha1
management:
  endpoints:
    prometheus: {}
virtualClusters:
  - name: demo
    targetCluster:
      bootstrapServers: kafka.example:9092
    gateways:
      - name: default
        portIdentifiesNode:
          bootstrapAddress: localhost:9192
defaultFilters:
  - encrypt
micrometer:
  - common-tags
```

Each plugin instance file specifies `name`, `type`, `version`, and optionally `config`:

```yaml
name: encrypt
type: io.kroxylicious.filter.encryption.RecordEncryption
version: v1
config:
  kms:
    type: io.kroxylicious.kms.service.KmsService
    name: vault-kms
  selector:
    type: io.kroxylicious.filter.encryption.config.KekSelectorService
    name: my-selector
```

The `name` field must match the filename (without the `.yaml` extension). This is validated during
loading. Including `name` in the file content ensures that plugin instance files are
self-describing: a file can be understood without knowing its path, which matters for debugging,
code review, and non-filesystem configuration sources like ConfigMaps.

The `type` field must be a fully qualified class name. The legacy single-file format allows
short names (e.g. `RecordEncryption`), but the config2 format requires the FQCN
(e.g. `io.kroxylicious.filter.encryption.RecordEncryption`). This makes each plugin file
completely self-describing: its interpretation does not depend on which plugins happen to be
loadable by a particular proxy binary. Short names are ambiguous when two plugins share a
simple class name; FQCNs eliminate that problem entirely.

The loss of brevity is mitigated by JSON Schema: each plugin version's schema can constrain
`type` using `const` or `enum`, giving editors code completion and validation without requiring
the user to type the full name.

### Snapshot abstraction

A `Snapshot` interface abstracts the configuration source. It provides access to `proxy.yaml`
content and the set of plugin instances grouped by interface. This allows the same resolution
logic to work whether configuration comes from a filesystem directory, a Kubernetes ConfigMap,
or an in-memory representation in tests.

### Plugin references

When a plugin's configuration needs to refer to another plugin instance (e.g. a filter that
uses a KMS service), the versioned config type uses `PluginReference<T>`:

```java
public record RecordEncryptionConfigV1(
        PluginReference<KmsService> kms,
        PluginReference<KekSelectorService> selector,
        Map<String, Object> experimental,
        UnresolvedKeyPolicy unresolvedKeyPolicy)
    implements HasPluginReferences {

    @Override
    public Stream<PluginReference<?>> pluginReferences() {
        return Stream.of(kms, selector);
    }
}
```

`PluginReference<T>` is a record of `(String type, String name)` where `type` is the fully
qualified plugin interface name and `name` is the instance name. In the YAML, this serialises
as a `{type, name}` map — a uniform, explicit pattern for all cross-file references.

By introducing `PluginReference` we impose a consistent reference syntax on all plugin
developers. This is a deliberate trade-off: it constrains the shape of versioned config types,
but in return every dependency is visible to the framework without requiring type-specific
introspection. The alternative — scanning config objects for fields that look like references,
or using reflection to discover dependencies at runtime — would be fragile, plugin-specific,
and invisible to tooling.

This is not a breaking change. Plugin developers adopt `PluginReference` fields only when they
introduce a new versioned config type (e.g. `RecordEncryptionConfigV1`). The legacy config type
(`RecordEncryptionConfig`) continues to use `@PluginImplName` / `@PluginImplConfig` as before.
Because the config versioning mechanism (`@Plugin(configVersion = "v1", configType = ...)`)
allows both old and new config types to coexist, the `PluginReference` pattern is adopted
incrementally, version by version.

### Dependency graph and referential integrity

The runtime builds a dependency graph from `HasPluginReferences` declarations. Versioned config
types implement this interface to enumerate their `PluginReference` values. The runtime then
validates the graph using DFS-based topological sort, detecting:

- **Dangling references**: a plugin references an instance that does not exist.
- **Cycles**: A depends on B depends on A.

The topological order determines initialisation sequence: dependencies are initialised before
their dependents.

This is a deliberate deviation from Kubernetes. The Kubernetes API server does not enforce
referential integrity between resources — a Pod can reference a ConfigMap that does not yet
exist, and eventual consistency resolves the situation over time. We make a different choice
because our needs are different: the proxy cannot start with a dangling KMS reference or a
cyclic dependency. Fail-fast validation at configuration load time is preferable to discovering
broken references at runtime when the first message arrives. The cost is that the runtime must
understand the dependency structure, which is why `HasPluginReferences` exists as an explicit
contract rather than relying on introspection or convention.

The runtime does not (and should not) know about all plugin types. Plugins can depend on other
plugins that the runtime has never heard of (e.g. `RecordEncryption` depends on `KmsService`
and `KekSelectorService`). The `HasPluginReferences` interface lets each config type declare
its own dependencies without requiring the runtime to enumerate every possible plugin interface.

### Resolved plugin registry

A `ResolvedPluginRegistry` is built during config2 resolution. It pre-creates non-filter plugin
instances (KMS services, authorisers, etc.) in dependency order. Filter instances are created
later by the proxy runtime because they need per-connection context.

Versioned filter configs obtain their dependencies from the registry:

```java
ResolvedPluginRegistry registry = context.resolvedPluginRegistry()
        .orElseThrow(() -> new PluginConfigurationException(
                "v1 config requires a ResolvedPluginRegistry"));
KmsService kmsPlugin = registry.pluginInstance(KmsService.class, kmsRef.name());
Object kmsConfig = registry.pluginConfig(kmsRef.type(), kmsRef.name());
```

### Dual `@Plugin` annotations and version dispatch

Filter implementations carry two `@Plugin` annotations: one for the legacy (unversioned) config
and one for the versioned config:

```java
@Plugin(configType = RecordEncryptionConfig.class)
@Plugin(configVersion = "v1", configType = RecordEncryptionConfigV1.class)
public class RecordEncryption<K, E>
    implements FilterFactory<Object, SharedEncryptionContext<K, E>> {
```

The `FilterFactory` type parameter becomes `Object`, and `initialize()` dispatches via
`instanceof`:

```java
public SharedEncryptionContext<K, E> initialize(
        FilterFactoryContext context, Object config) {
    var configuration = Plugins.requireConfig(this, config);
    if (configuration instanceof RecordEncryptionConfigV1 v1) {
        return initializeV1(context, v1);
    }
    else if (configuration instanceof RecordEncryptionConfig legacy) {
        return initializeLegacy(context, legacy);
    }
    throw new PluginConfigurationException("Unsupported config type");
}
```

This maintains full backwards compatibility: existing single-file configurations continue to work
via the legacy path.

### JSON Schema validation

Plugin authors can ship a JSON Schema for each config version at:

```
META-INF/kroxylicious/schemas/{PluginSimpleName}/{version}.schema.yaml
```

When a schema is present, config2 validates the raw configuration against it before
deserialisation. This is opt-in: if no schema exists, the config is accepted without validation.
A test utility `SchemaValidationAssert` is provided so plugin authors can verify their schemas
accept valid configs.

### `@Stateless` annotation

Plugins annotated `@Stateless` can be shared across multiple consumers. The plugin instance YAML
can set `shared: true` to enable this. The framework rejects `shared: true` on plugins not
annotated `@Stateless`.

### Migration tool

A `migrate-config` CLI subcommand converts legacy single-file configurations into the multi-file
format:

```
kroxylicious migrate-config -i legacy-config.yaml -o output-dir/
```

The tool:

1. Parses the legacy configuration via `ConfigParser`.
2. Reflects on each filter's legacy config type to discover `@PluginImplName` / `@PluginImplConfig`
   pairs on the canonical constructor parameters.
3. Extracts each nested plugin into its own file under `plugins.d/{interface}/{name}.yaml`.
4. Rewrites the filter config to use `PluginReference`-style maps, selecting the best available
   config version.
5. Writes `proxy.yaml` by passing through the raw YAML (stripping `filterDefinitions`, replacing
   `micrometer` with instance name references).

## Affected/not affected projects

| Project | Affected | Nature of change |
|---|---|---|
| `kroxylicious-api` | Yes | New **public API** types: `PluginReference`, `HasPluginReferences`, `ResolvedPluginRegistry`, `@Stateless`. `@Plugin` made `@Repeatable` with `configVersion` attribute. These are the types that plugin developers depend on and that we commit to supporting long-term. |
| `kroxylicious-runtime` | Yes | New **internal** `config2` package: `Snapshot`, `FilesystemSnapshot`, `ProxyConfig`, `PluginConfig`, `DependencyGraph`, `ConfigSchemaValidator`, `ProxyConfigParser`, `ResolvedPluginRegistryImpl`. These are implementation details not visible to plugin developers. |
| `kroxylicious-filter-test-support` | Yes | New `SchemaValidationAssert` utility. |
| `kroxylicious-app` | Yes | New `ConfigMigrate` picocli subcommand. Dependency scope changes for Jackson. |
| All filter modules | Yes | Dual `@Plugin` annotations, versioned config records, JSON schemas, updated tests. |
| `kroxylicious-operator` | Not yet | Future work: operator generates `Snapshot` from CRDs. |
| `kroxylicious-docs` | Not yet | Future work: document new configuration format. |

The distinction matters: types in `kroxylicious-api` form the contract with plugin developers.
Changes to `PluginReference`, `HasPluginReferences`, or `ResolvedPluginRegistry` require the
same care as any other public API change. Types in `kroxylicious-runtime` are internal and can
be refactored freely.

## Compatibility

### Backwards compatibility

The legacy single-file configuration format continues to work unchanged. The dual `@Plugin`
annotation approach means the existing `ConfigParser` deserialises legacy configs exactly as
before. The config2 path is only activated when a multi-file configuration source is used.

### Forward compatibility

Config version strings follow Kubernetes conventions (v1alpha1, v1beta1, v1). The version
field in plugin YAML files enables the framework to select the correct deserialisation target
as schemas evolve. The `@Repeatable` `@Plugin` annotation allows plugins to support an arbitrary
number of config versions simultaneously.

### Migration path

Users migrate at their own pace. The `migrate-config` tool provides a one-shot conversion.
The legacy format is not deprecated by this proposal.

## Rejected alternatives

### Embedding version in the config parser rather than plugin annotations

We considered adding version dispatch logic to the `ConfigParser` itself. This was rejected
because plugin authors know their own config evolution best. The `@Plugin` annotation approach
keeps version knowledge co-located with the plugin implementation.

### Single versioned config type per plugin

We considered requiring each plugin to have exactly one config type for the new format, removing
the legacy type entirely. This was rejected because it would break existing configurations and
force a flag-day migration.

### Generating plugin files from annotations at build time

We considered generating the `plugins.d/` layout from annotations during the Maven build. This
was rejected because the multi-file layout is a deployment-time concern, not a build-time one.
The configuration source is an operational choice (filesystem, ConfigMap, etc.).

### Configuration without explicit dependency declarations

We considered inferring dependencies from the config structure (e.g. scanning for nested objects
that look like plugin references). This was rejected in favour of explicit `HasPluginReferences`
because implicit inference is fragile, hard to validate, and invisible to tooling.
