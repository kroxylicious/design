# Config2: Multi-file plugin configuration

We propose replacing the current monolithic proxy configuration with a multi-file, Kubernetes-inspired
configuration system. Plugin instances are defined in individual YAML files with explicit versioning,
cross-file dependency references, and optional JSON Schema validation.

## Current situation

Today, configuration lives in a single YAML file with a few ancillary files used for TLS certificates, keys and ACL rules.

At places where plugins can be configured, `@PluginImplName` / `@PluginImplConfig` annotation pairs are used on the relevant Java class
so that a plugin's configuration can be included in the YAML tree.
Plugins are allowed to have plugins of their own.

For example, the proxy runtime uses those annotations for the `type` and `config` properties (<1> & <2>), and 
the `RecordEncryption` filter uses them for `kms` + `kmsConfig` (<3> & <4>) 
and for `selector` and `selectorConfig` (<5> & <6>):

```yaml
filterDefinitions:
  - name: encrypt
    type: RecordEncryption  # <1>
    config:  # <2>
      kms: VaultKmsService  # <3>
      kmsConfig:  # <4>
        vaultTransitEngineUrl: http://vault:8200/v1/transit
        vaultToken:
          password: my-token
      selector: TemplateKekSelector  # <5>
      selectorConfig:  # <6>
        template: "KEK_${topicName}"
```

The proxy runtime resolves these during startup by discovering `@PluginImplName`-annotated fields, looking up
the named plugin implementation via `ServiceLoader`, and deserialising the corresponding
`@PluginImplConfig` field into the plugin's config type. 

The existing APIs work, and the ability for plugins to depend on other plugins has proven useful.

## Motivation

Although it works, the current configuration model has several drawbacks that motivate a redesign.

### 1. No reuse of plugin configurations

The configuration model is tree-like. If two filters need the same KMS
then each must embed a copy of the KMS configuration. There is no way to define a plugin
instance once and reference it from multiple consumers.

### 2. Per-plugin JSON schemas are impossible today

A plugin developer ought to be able to document the YAML accepted by their plugin,
but this is difficult because the source of truth is Java code: end users cannot be assumed to know Java.
Similarly, external tools (editors, config linters, CI validators, Kubernetes operators)
cannot inspect or validate plugin configurations (see [2436](https://github.com/kroxylicious/kroxylicious/issues/2436)),
and there is no declarative way to validate plugin configurations before
the proxy starts (somewhat related: [3267](https://github.com/kroxylicious/kroxylicious/issues/3267#issuecomment-4042031788)).

These three problems — poor documentation, opaque tooling, and absent validation — share a root cause:
it is currently impossible to write a single JSON schema for the configuration file, because what is allowed
depends on which plugins are present at runtime.
If we give each plugin instance its own file, each
plugin version can ship its own JSON schema to be used to validate that file.
These per-plugin schemas can be published to schema
catalogues (e.g. schemastore.org) and consumed by IDEs and CI tools independently of the proxy.

### 3. Lack of uniformity in how plugins are configured

Each plugin point embeds its plugins differently. Filter factories are explicitly named (via
`NamedFilterDefinition`), but other plugins like `KmsService` are anonymous because they are
referenced once by their parent. This inconsistency extends across the codebase: filters,
authorisers, KMS services, subject builders, and key selectors all follow slightly different
patterns. A uniform model where every plugin instance is a named, versioned resource would eliminate
this inconsistency.

### 4. The runtime cannot understand inter-plugin dependencies

The lack of uniformity means the runtime has no meaningful understanding of the dependency
relationships between plugins. This matters for dynamic reloading: when a plugin configuration
changes, the runtime needs to know which virtual clusters are affected. Today, dependencies are
discovered implicitly at initialisation time, with no upfront visibility into the graph. Explicit
dependency declarations would enable the runtime to reason about the impact of configuration changes.

Note that the runtime does not (and should not) know about all plugin types. Plugins are allowed
to have plugins of their own (e.g. `RecordEncryption` depends on `KmsService` and
`KekSelectorService`, which are not known to the runtime). This rules out approaches that add
top-level definitions for each plugin type (e.g. `kmsDefinitions`), because the runtime cannot
enumerate plugin types it does not know about.

### 5. Plugin instances are not individually identifiable

Eventually we may want to build a control plane for clusters of proxies. 
Plugin instances would be important entities in the API of that control plane. 
For this to work, each plugin instance must have a unique identity. 
The current system gives names to filter definitions but typically not to the plugins they embed. 
A model where every plugin instance has a name, a type, and a version would make each one individually addressable.

### 6. No principled way to evolve plugin configuration

None of the configurations (the proxy's or any of the plugins') are explicitly versioned. 
A plugin developer can deprecate properties, but cannot remove them in a controlled manner where the API evolution is obvious to the user. 
As a plugin evolves, the plugin implementation either accepts the YAML or it does not. 
If a newer version of a plugin removes support for a configuration property the user will likely be confused, because the configuration used to work — but the plugin has no effective way to communicate that the user is speaking the old language. 
Explicit version strings (following Kubernetes conventions: v1alpha1, v1beta1, v1) would give plugin developers a principled mechanism for config schema evolution, including support for multiple concurrent versions during migration periods.

## Proposal

### Supporting multiple plugin configuration versions

The existing `@Plugin` annotation type will be annotated `@Repeatable`, and given a new `configVersion` method.

This will allow plugin implementations carry multiple `@Plugin` annotations: 
* The default value for `Plugin.configVersion` will be the empty string.
* the legacy (unversioned) config will be the one with an empty string as its `configVersion`
* hence forth, each version of a plugin's config will be identified by a non-empty `configVersion`

The runtime will validate that `configVersion` is unique across all the `@Plugin` annotations on a plugin implementation class.

```java
@Plugin(configType = RecordEncryptionConfig.class) // The legacy config schema
@Plugin(configVersion = "v1", configType = RecordEncryptionConfigV1.class) // The new config schema, called v1
public class RecordEncryption<K, E>
    implements FilterFactory<Object, SharedEncryptionContext<K, E>> {
```

When implementing a plugin like `FilterFactory` which accepts a type parameter representing the configuration type, `Object` will be used as the type argument.

**Design compromise: loss of compile-time type safety.** The plugin loses compile-time type checking on its configuration — the compiler can no longer verify that the config argument matches a specific type. This is unavoidable because multiple config versions form a union type, which Java's generics cannot express directly. The cost is mitigated by the `Plugins.requireConfig()` helper (which validates the config type at runtime) and by `instanceof` pattern matching in `initialize()`, which provides exhaustiveness checking within the method body. If desired, a plugin developer can declare a common `sealed interface` for all their config types, recovering some type safety while avoiding the raw `Object` type argument.

In either case `initialize()`-like methods will dispatch via `instanceof`:

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

This maintains full backwards compatibility: existing single-file configurations continue to work via the legacy path.

### One file per plugin instance

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
default filter chain, micrometer instance names) plus a new `version` field:

```yaml
# proxy.yaml
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
```

The presence of the `version` field signals to the runtime that the new configuration system is in use.
When it's absent the old configuration system is used.

Each plugin instance file specifies `name`, `type`, `version`, and optionally `config`:

```yaml
# plugins.d/io.kroxylicious.proxy.filter.FilterFactory/encrypt.yaml
name: encrypt
type: io.kroxylicious.filter.encryption.RecordEncryption
version: v1
config:
  kms: vault-kms
  selector: my-selector
```

The `name` field must match the filename (without the `.yaml` extension). This is a deliberate
redundancy: storing the name in two places means they can diverge, requiring a validation rule
at load time. We accept this cost because it makes plugin instance files self-describing — a file
can be understood without knowing its path, which matters for debugging, code review, and
(in the future) non-filesystem configuration sources.

The `type` field must be a fully qualified class name. The legacy single-file format allows
short names (e.g. `RecordEncryption`), but the config2 format requires the FQCN
(e.g. `io.kroxylicious.filter.encryption.RecordEncryption`). This makes each plugin file
completely self-describing: its interpretation does not depend on which plugins happen to be
loadable by a particular proxy binary. Short names are ambiguous when two plugins share a
simple class name; FQCNs eliminate that problem entirely.

The fully qualified names also apply to directory paths under `plugins.d/`
(e.g. `plugins.d/io.kroxylicious.proxy.filter.FilterFactory/`), which creates long paths —
a usability cost for operators working directly on the filesystem. We accept this cost for the
same reason: unambiguity and self-description. The directory structure mirrors the `ServiceLoader`
contract, where the interface FQCN is the natural key.

The loss of brevity is mitigated by JSON Schema: each plugin version's schema can constrain
`type` using `const` or `enum`, giving editors code completion and validation without requiring
the user to type the full name.
This mitigation relies on plugin developers adding such constraints.

### JSON Schema validation

Plugin developers can ship a JSON Schema for each config version at:

```
META-INF/kroxylicious/schemas/{PluginSimpleName}/{version}.schema.yaml
```

When a schema is present, the runtime will validate the raw configuration against it before deserialisation. 
This is opt-in: if no schema exists, the config is accepted without validation.

A test utility `SchemaValidationAssert` is provided in `kroxylicious-filter-test-support` so plugin authors can verify their schemas accept valid configs.

Discovery of schemas by external tooling depends on plugin developers publishing the schema so that it can be discovered by tools.
One way to do that is to publish the schema on a public webserver, allowing end users to make use of JSON Schema's `$schema` keyword.
Editors will often allow to download such schemas. 
Alternatively schemastore.org provides on mechanism with good editor support. 

### Plugin references

`PluginReference<T>` is a new API class in `kroxylicious-api` used by plugin developers to describe their plugin's configuration dependency on some other plugin instance.

```java
package io.kroxylicious.proxy.plugin;

/**
 * A typed reference to a named plugin instance. Used by the framework to
 * build the dependency graph and determine initialisation order.
 * <p>
 * This is a runtime type, not a serialisation type. Plugin authors choose their
 * own YAML representation for references (e.g. a bare instance name string when
 * the plugin interface type is statically known) and construct {@code PluginReference}
 * instances in their {@link HasPluginReferences#pluginReferences()} implementation.
 *
 * @param type the fully qualified name of the plugin interface (e.g. {@code io.kroxylicious.kms.service.KmsService})
 * @param name the name of the plugin instance (e.g. {@code aws-kms})
 * @param <T> the plugin interface type
 */
public record PluginReference<T>(
                                 String type,
                                 String name) {}
```

In general, a plugin's configuration might have many such individual dependencies.
The runtime needs a way to know about all of a plugin's dependencies so we define `HasPluginReferences`
in `kroxylicious-api`:

```java
package io.kroxylicious.proxy.plugin;
/**
 * Implemented by new-style (versioned) plugin configuration types to declare their
 * dependencies on other plugin instances. The framework calls {@link #pluginReferences()}
 * to discover cross-file dependencies, build a dependency graph, and validate that
 * all referenced plugin instances exist.
 */
public interface HasPluginReferences {

    /**
     * Returns all plugin references in this configuration, including references
     * from nested structures. Implementations must include all references to
     * ensure correct dependency tracking and initialisation ordering.
     *
     * @return a stream of all plugin references declared by this configuration
     */
    Stream<PluginReference<?>> pluginReferences();
}
```

When a plugin's configuration can refer to another plugin instance (e.g. a filter that
uses a KMS service), the plugin's configuration type declares its dependencies by implementing
`HasPluginReferences`. 


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

The YAML representation of the reference is entirely up to the plugin author.
When the plugin interface type is statically known, the reference can simply be the name of the depended-upon plugin instance (i.e. a JSON string). 
For example, a plugin like `RecordEncryption` knows statically that its `kms`
field always refers to the `KmsService` plugin interface. 
Forcing the user to write `kms: {type: io.kroxylicious.kms.service.KmsService, name: vault-kms}` in the YAML would be
redundant — the `type` can only ever be one thing. 
By keeping `PluginReference` out of the YAML, each plugin is free to choose the most natural representation for its references.
A `type` property can be included where the plugin interface type is _not_ known statically.

The `HasPluginReferences` interface is the contract that allows the runtime to resolve the plugin instance graph. 
The runtime calls
`pluginReferences()` to discover cross-file dependencies, build the dependency graph, and
validate that all referenced plugin instances exist. 

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

Although much of the design described in this proposal is inspired the the Kubernetes model this is a deliberate deviation. 
The Kubernetes API server does not enforce referential integrity between resources — a Pod can reference a ConfigMap that does not yet
exist, and eventual consistency resolves the situation over time. 
We make a different choice because our needs are different: the proxy cannot start with a dangling KMS reference or a cyclic dependency. 
Fail-fast validation at configuration load time is preferable to discovering broken references at runtime when the first message arrives. 
The cost is that the runtime must understand ­— and validate ­— the dependency structure, which is why `HasPluginReferences` exists as an explicit contract rather than relying on introspection or convention.

The runtime does not (and should not) statically know about all plugin types. 
Plugins can depend on other plugins that the runtime has never heard of (e.g. `RecordEncryption` depends on `KmsService` and `KekSelectorService`). The `HasPluginReferences` interface lets each config type declare its own dependencies without requiring the runtime to enumerate every possible plugin interface.

### `@Stateless` annotation

Plugin developers can apply a new `@Stateless` annotation to their plugin implementation.
This signals to the runtime that an instance may be shared across multiple consumers. 

The decision about whether to actually do that belongs to the end user who controls the configuration used to refer to a plugin instance.
The plugin instance YAML can set `shared: true` to enable this. 

The framework will reject `shared: true` on plugins not annotated `@Stateless`.

### Resolved plugin registry

A `ResolvedPluginRegistry` is built during plugin resolution.
It instantiates non-filter plugin instances (KMS services, authorisers, etc.) eagerly, in
dependency order, at startup. These are shared services whose lifecycle is tied to the proxy
process.

Filter instances are different: the proxy creates a new filter chain for each client connection,
so filter instances cannot be pre-created at startup. Instead, filter factories obtain their
dependencies from the registry when the runtime invokes them:

```java
ResolvedPluginRegistry registry = context.resolvedPluginRegistry()
        .orElseThrow(() -> new PluginConfigurationException(
                "v1 config requires a ResolvedPluginRegistry"));
KmsService kmsPlugin = registry.pluginInstance(KmsService.class, v1.kms());
Object kmsConfig = registry.pluginConfig(KmsService.class.getName(), v1.kms());
```

### Snapshot abstraction

**This subsection concerns non-public APIs within the runtime. It is included in this proposal to help explain the concepts.**

A `Snapshot` interface in `kroxylicious-runtime` abstracts the configuration source, allowing the same resolution logic
to work whether configuration comes from a filesystem directory, an in-memory representation in tests, or (in the future) some other source.

```java
interface Snapshot {
    /**
     * Returns the proxy configuration YAML content.
     *
     * @return the proxy configuration as a YAML string
     */
    String proxyConfig();

    /**
     * Returns the plugin interface names for which plugin instances are configured.
     *
     * @return list of plugin interface names (fully qualified class names)
     */
    // For the filesystem implementation this is the child directories of plugins.d/
    List<String> pluginInterfaces();

    /**
     * Returns the names of all plugin instances configured for a given plugin interface.
     *
     * @param pluginInterfaceName the fully qualified name of the plugin interface
     * @return list of plugin instance names
     */
    // For the filesystem implementation this is the .yaml files in the given subdirectory of plugins.d/
    List<String> pluginInstances(String pluginInterfaceName);


    /**
     * Returns the metadata and data bytes for a specific plugin instance as an atomic unit.
     * For YAML-based plugins, the data is the UTF-8 encoded YAML content (including the
     * metadata envelope). For binary resource plugins (annotated with {@code @ResourceType}),
     * the data is the raw resource bytes.
     *
     * <p>Callers must not modify the returned data array.</p>
     *
     * @param pluginInterfaceName the fully qualified name of the plugin interface
     * @param pluginInstanceName the name of the plugin instance
     * @return the plugin instance content (metadata and data)
     * @throws IllegalArgumentException if the plugin instance is not found
     */
    PluginInstanceContent pluginInstance(
                                         String pluginInterfaceName,
                                         String pluginInstanceName);
                                         
    
    // ...
}
```



#### `PluginInstanceContent`

A `PluginInstanceContent` has **metadata** and **data**:

```java
public record PluginInstanceContent(
                                    PluginInstanceMetadata metadata,
                                    byte[] data) {}
```

- **Metadata** (`PluginInstanceMetadata`): name, type (FQCN), version, shared flag, and a
  generation number. 

- **Data**: raw bytes. For most plugins, these bytes are UTF-8 YAML —
  the proxy parses them with Jackson into the `configType` from the `@Plugin` annotation. For
  binary resource plugins (those annotated with `@ResourceType` — see **Non-YAML resources**
  below), the bytes are the raw resource content (e.g. a PKCS12 keystore). The runtime checks
  `@ResourceType` on the plugin class to determine which deserialisation path to use.

#### `PluginInstanceMetadata`

```java
public record PluginInstanceMetadata(
                             String name,
                             String type,
                             String version,
                             boolean shared,
                             long generation) {}
```

#### Change detection: generation numbers

Each resource in the `Snapshot` carries a **generation number** — a monotonically increasing
value that changes when the resource content changes. Comparing generation numbers rather than
data bytes avoids:

- Non-determinism from keystore salting (two logically equivalent stores can have different bytes).
- Security concerns around comparing key material.
- Expensive byte-level comparison of large blobs.

For the operator, generation maps to Kubernetes `metadata.generation` / `resourceVersion`.
For filesystem deployments, it is derived from file modification time.


### Non-YAML resources

For the `Snapshot` to fully encapsulate a proxy's configuration state, it must include these resources alongside YAML-based plugin configs.

Not all plugin instance data is YAML. 
* The existing AclAuthorizer uses a non-YAML text format for its ACL rules.
* Plugins commonly accept `Tls` objects for specifying secret data via Java KeyStores. 

It is possible to provide plugin data in any format.
However, this is mainly provides to allow KeyStores to have first class support within the configuration system.
For the filesystem Snapshot non-YAML data is provided in a separate file in the same directory as the YAML metadata file.
 
#### Text-based resources: inline YAML

For text-based resources like ACL rules, YAML multi-line syntax (`|`) is simplest. 
The versioned config type can use a `String` field instead of a file path:

```yaml
name: my-acl-authorizer
type: io.kroxylicious.authorizer.provider.acl.AclAuthorizerService
version: v1
config:
  rules: |
    allow User with name = "alice" to READ Topic with name = "foo";
    otherwise deny;
```
 
#### Filesystem layout

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

#### `@ResourceType` annotation

For binary resource types, the plugin implementation declares its binary format via a `@ResourceType` annotation:

```java
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
public @interface ResourceType {
    Class<? extends ResourceSerializer<?>> serializer();
    Class<? extends ResourceDeserializer<?>> deserializer();
}
```

The runtime discovers the serde from the annotation via reflection — the same pattern used for `@Plugin(configType = ...)`. 
The `ResourceSerializer` converts a typed resource to bytes (for snapshot generation), and `ResourceDeserializer` converts bytes back to a typed resource (for loading).

#### Passwords

Using `@ResourceType` we can write plugins configuration which depend on binary files, including KeyStores. 
But some `KeyStore` types like PKCS#12 can be (or are required to be) password-protected.
If the password was managed as just another piece of metadata, and kept alongside the keystore, then most of its security value is lost.
To provide a security benefit the keystore must be handled separately from the password needed to access it until 
the moment that access is needed.
For this reason passwords are provided **out-of-band** from the resource data, not co-located with it. 
The `Snapshot` interface includes a `resourcePassword(String resourceName)` method that returns the password for a named resource. 
This decouples passwords from the data they protect.

```java
interface Snapshot {
    // ...
    
    /**
     * Returns the password for a named resource, if one is configured. Passwords are
     * provided out-of-band from the resource data for security.
     *
     * @param resourceName the name of the resource
     * @return the password as a char array, or {@code null} if no password is configured
     */
    @Nullable
    char[] resourcePassword(String resourceName);
}
```

For the filesystem-based snapshot, passwords are stored in a `passwords.yaml` file in the
configuration directory. This file maps resource names to their passwords:

```yaml
# passwords.yaml
my-keystore: changeit
```

Other `Snapshot` implementations may source passwords differently — for example, the operator
could read them from Kubernetes Secrets, or from Vault. 


#### Store type auto-detection

The keystore format need not be user-specified. 
Common formats have distinctive magic bytes (JKS: `0xFEEDFEED`, PKCS12: ASN.1 `0x30`, PEM: `-----BEGIN`). 
The deserialiser probes the bytes and selects the appropriate format. 
PKCS12 is the default keystore type since Java 9; JKS is legacy.

#### Alias selection

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

#### Plugin interfaces for TLS material

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

The changes described in this proposal concern the kroxylicious project only.
In particular it only covers the kroxylicious proxy.
Follow-on changes to `kroxylicious-kubernetes-api` and `kroxylicious-operator` will be developed in a future proposal.

| Project | Affected | Nature of change |
|---|---|---|
| `kroxylicious-api` | Yes | New **public API** types: `PluginReference`, `HasPluginReferences`, `ResolvedPluginRegistry`, `@Stateless`, `@ResourceType`, `ResourceSerializer`, `ResourceDeserializer`, `KeyMaterialProvider`, `TrustMaterialProvider`. `@Plugin` made `@Repeatable` with `configVersion` attribute. These are the types that plugin developers depend on and that we commit to supporting long-term. |
| `kroxylicious-runtime` | Yes | New **internal** `config2` package: `Snapshot`, `FilesystemSnapshot`, `PluginInstanceMetadata`, `ProxyConfig`, `PluginConfig`, `DependencyGraph`, `ConfigSchemaValidator`, `ProxyConfigParser`, `ResolvedPluginRegistryImpl`. These are implementation details not visible to plugin developers. |
| `kroxylicious-filter-test-support` | Yes | New `SchemaValidationAssert` utility. |
| `kroxylicious-app` | Yes | New `ConfigMigrate` picocli subcommand. Dependency scope changes for Jackson. |
| All filter modules | Yes | Dual `@Plugin` annotations, versioned config records, JSON schemas, updated tests. |
| `kroxylicious-operator` | Not yet | Future work: operator generates `Snapshot` from CRDs. |
| `kroxylicious-docs` | Not yet | Future work: document new configuration format. |


## Compatibility


### Backwards compatibility

The legacy single-file configuration format continues to work unchanged. 
The dual `@Plugin` annotation approach means the existing `ConfigParser` deserialises legacy configs exactly as before. 
The new configuration handling is only activated when proxy configuration file has a `version` property.
Because current configurations never have this property they will continue to be handled by the current mechanisms.

### Forward compatibility

Config version strings follow Kubernetes conventions (v1alpha1, v1beta1, v1). 
The `version` field in plugin YAML files enables the framework to select the correct deserialisation target as schemas evolve. 
The `@Repeatable` `@Plugin` annotation allows plugins to support an arbitrary number of config versions simultaneously.

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
