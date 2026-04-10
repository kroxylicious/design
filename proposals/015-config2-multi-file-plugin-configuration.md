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
  kms: vault-kms
  selector: my-selector
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

A `Snapshot` interface abstracts the configuration source, allowing the same resolution logic
to work whether configuration comes from a filesystem directory, a Kubernetes ConfigMap, or
an in-memory representation in tests.

```java
public interface Snapshot {
    /** Returns the proxy configuration YAML content. */
    String proxyConfig();

    /** Returns the plugin interface names for which plugin instances are configured. */
    List<String> pluginInterfaces();

    /** Returns the names of all plugin instances configured for a given plugin interface. */
    List<String> pluginInstances(String pluginInterfaceName);

    /** Metadata for a plugin instance (name, type, version, shared, generation). */
    PluginInstanceMetadata pluginInstanceMetadata(
            String pluginInterfaceName, String pluginInstanceName);

    /** Raw data bytes for a plugin instance (UTF-8 YAML or binary resource). */
    byte[] pluginInstanceData(
            String pluginInterfaceName, String pluginInstanceName);

    /** Password for a named resource, or null if no password is configured. */
    @Nullable char[] resourcePassword(String resourceName);
}
```

Each plugin instance has **metadata** and **data**:

- **Metadata** (`PluginInstanceMetadata`): name, type (FQCN), version, shared flag, and a
  generation number. The generation is a monotonically increasing value that changes when the
  resource content changes, enabling efficient change detection without comparing data bytes
  (which is problematic for keystores due to non-deterministic salting and security concerns
  around comparing key material). For the Kubernetes operator, generation maps to
  `metadata.generation` / `resourceVersion`. For filesystem deployments, it is derived from
  file modification time.

- **Data** (`pluginInstanceData()`): raw bytes. For most plugins, these bytes are UTF-8 YAML —
  the proxy parses them with Jackson into the `configType` from the `@Plugin` annotation. For
  binary resource plugins (those annotated with `@ResourceType` — see **Non-YAML resources**
  below), the bytes are the raw resource content (e.g. a PKCS12 keystore). The runtime checks
  `@ResourceType` on the plugin class to determine which deserialisation path to use.

**Passwords** are provided out-of-band from the resource data via `resourcePassword()`. This
decouples passwords from the data they protect, allowing different access controls (e.g.
Kubernetes Secret vs ConfigMap, or a separate `passwords.yaml` with restricted permissions
for filesystem deployments).

### Plugin references

When a plugin's configuration needs to refer to another plugin instance (e.g. a filter that
uses a KMS service), the versioned config type declares its dependencies by implementing
`HasPluginReferences`. The YAML representation of the reference is entirely up to the plugin
author — typically a bare instance name string, since the plugin interface type is statically
known:

```java
public record RecordEncryptionConfigV1(
        String kms,
        String selector,
        Map<String, Object> experimental,
        UnresolvedKeyPolicy unresolvedKeyPolicy)
    implements HasPluginReferences {

    @Override
    public Stream<PluginReference<?>> pluginReferences() {
        return Stream.of(
                new PluginReference<>(KmsService.class.getName(), kms),
                new PluginReference<>(KekSelectorService.class.getName(), selector));
    }
}
```

`PluginReference<T>` is a runtime type — a record of `(String type, String name)` where `type`
is the fully qualified plugin interface name and `name` is the instance name. It is not a
serialisation type: it does not appear in the YAML. Plugin authors construct `PluginReference`
values in their `pluginReferences()` implementation, combining the statically-known interface
type with the instance name read from YAML.

This separation is deliberate. A plugin like `RecordEncryption` knows statically that its `kms`
field always refers to a `KmsService`. Forcing the user to write
`kms: {type: io.kroxylicious.kms.service.KmsService, name: vault-kms}` in the YAML would be
redundant — the `type` can only ever be one thing. By keeping `PluginReference` out of the
YAML, each plugin is free to choose the most natural representation for its references.

The `HasPluginReferences` interface is the contract that makes this work. The runtime calls
`pluginReferences()` to discover cross-file dependencies, build the dependency graph, and
validate that all referenced plugin instances exist. The alternative — scanning config objects
for fields that look like references, or using reflection to discover dependencies — would be
fragile, plugin-specific, and invisible to tooling.

This is not a breaking change. Plugin developers implement `HasPluginReferences` only when they
introduce a new versioned config type (e.g. `RecordEncryptionConfigV1`). The legacy config type
(`RecordEncryptionConfig`) continues to use `@PluginImplName` / `@PluginImplConfig` as before.
Because the config versioning mechanism (`@Plugin(configVersion = "v1", configType = ...)`)
allows both old and new config types to coexist, the `HasPluginReferences` pattern is adopted
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
KmsService kmsPlugin = registry.pluginInstance(KmsService.class, v1.kms());
Object kmsConfig = registry.pluginConfig(KmsService.class.getName(), v1.kms());
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
| `kroxylicious-api` | Yes | New **public API** types: `PluginReference`, `HasPluginReferences`, `ResolvedPluginRegistry`, `@Stateless`, `@ResourceType`, `ResourceSerializer`, `ResourceDeserializer`, `KeyMaterialProvider`, `TrustMaterialProvider`. `@Plugin` made `@Repeatable` with `configVersion` attribute. These are the types that plugin developers depend on and that we commit to supporting long-term. |
| `kroxylicious-runtime` | Yes | New **internal** `config2` package: `Snapshot`, `FilesystemSnapshot`, `PluginInstanceMetadata`, `ProxyConfig`, `PluginConfig`, `DependencyGraph`, `ConfigSchemaValidator`, `ProxyConfigParser`, `ResolvedPluginRegistryImpl`. These are implementation details not visible to plugin developers. |
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

## Non-YAML resources

Not all plugin instance data is YAML. Some plugins manage binary resources — most notably TLS
key material stored as Java KeyStores (JKS, PKCS12) or PEM files. For the `Snapshot` to fully
encapsulate a proxy's configuration state, it must include these resources alongside YAML-based
plugin configs.

### `@ResourceType` annotation

As described in the Snapshot abstraction, plugin instance data is raw bytes — UTF-8 YAML by
default. For binary resource types (e.g. keystores), the plugin implementation declares its
binary format via a `@ResourceType` annotation:

```java
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
public @interface ResourceType {
    Class<? extends ResourceSerializer<?>> serializer();
    Class<? extends ResourceDeserializer<?>> deserializer();
}
```

The runtime discovers the serde from the annotation via reflection — the same pattern used
for `@Plugin(configType = ...)`. The `ResourceSerializer` converts a typed resource to bytes
(for snapshot generation), and `ResourceDeserializer` converts bytes back to a typed resource
(for loading).

### Store type auto-detection

Keystore format need not be user-specified. Common formats have distinctive magic bytes
(JKS: `0xFEEDFEED`, PKCS12: ASN.1 `0x30`, PEM: `-----BEGIN`). The deserialiser probes the
bytes and selects the appropriate format. PKCS12 is the default keystore type since Java 9;
JKS is legacy.

### Passwords

Passwords are provided **out-of-band** from the resource data, not co-located with it. The
`Snapshot` interface includes a `resourcePassword(String resourceName)` method that returns the
password for a named resource. This decouples passwords from the data they protect, allowing
different access controls (e.g. Kubernetes Secret vs ConfigMap for filesystem deployments, a
separate `passwords.yaml` with restricted permissions).

### Alias selection

When a keystore contains multiple entries, the consuming plugin's config specifies the alias
via a sibling property — this is a concern of the consumer, not the resource:

```java
public record VaultKmsConfigV1(
        String vaultUrl,
        @Nullable String keyMaterial,
        @Nullable String keyAlias,
        @Nullable String trustMaterial
) implements HasPluginReferences { ... }
```

### Change detection: generation numbers

Each resource in the `Snapshot` carries a **generation number** — a monotonically increasing
value that changes when the resource content changes. Comparing generation numbers rather than
data bytes avoids:

- Non-determinism from keystore salting (two logically equivalent stores can have different bytes).
- Security concerns around comparing key material.
- Expensive byte-level comparison of large blobs.

For the operator, generation maps to Kubernetes `metadata.generation` / `resourceVersion`.
For filesystem deployments, it is derived from file modification time.

### Plugin interfaces for TLS material

Two marker interfaces in `kroxylicious-api` model TLS resources:

```java
/** Provides TLS key material (private key + certificate chain). */
public interface KeyMaterialProvider {
    java.security.KeyStore keyStore();
}

/** Provides TLS trust material (trusted CA certificates). */
public interface TrustMaterialProvider {
    java.security.KeyStore trustStore();
}
```

Consumers reference these by name in their versioned config, constructing `PluginReference`
values in `pluginReferences()` — the same pattern used for all other cross-file references.

### Filesystem layout

Binary resources use a sidecar `.data` file alongside the YAML metadata file:

```
config-dir/
  proxy.yaml
  passwords.yaml
  plugins.d/
    io.kroxylicious.proxy.tls.KeyMaterialProvider/
      my-keystore.yaml      # metadata: name, type, version
      my-keystore.data      # binary keystore bytes
    io.kroxylicious.proxy.filter.FilterFactory/
      encrypt.yaml           # metadata + YAML config
```

### Text-based resources: inline YAML

For text-based resources like ACL rules, YAML multi-line syntax (`|`) is simpler than the
resource abstraction. The versioned config type uses a `String` field instead of a file path:

```yaml
name: my-acl-authorizer
type: io.kroxylicious.authorizer.provider.acl.AclAuthorizerService
version: v1
config:
  rules: |
    allow User with name = "alice" to READ Topic with name = "foo";
    otherwise deny;
```

PEM certificates and private keys are also text and can use the same inline approach.
Binary formats (JKS, PKCS12) require the `@ResourceType` mechanism.

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
