# 017 - AWS KMS: credentials configuration restructure

<!-- TOC -->
* [017 - AWS KMS: credentials configuration restructure](#017---aws-kms-credentials-configuration-restructure)
  * [Current situation](#current-situation)
  * [Motivation](#motivation)
  * [Proposal](#proposal)
    * [New `credentials` configuration node](#new-credentials-configuration-node)
    * [Backward compatibility for existing providers](#backward-compatibility-for-existing-providers)
    * [Implementation](#implementation)
  * [Affected/not affected projects](#affectednot-affected-projects)
  * [Compatibility](#compatibility)
  * [Rejected alternatives](#rejected-alternatives)
<!-- TOC -->

## Current situation

The AWS KMS provider for the Record Encryption filter authenticates to AWS using one of two mechanisms, each configured as a separate top-level field on the `Config` record:

```yaml
kmsConfig:
  endpointUrl: https://kms.us-east-1.amazonaws.com
  longTermCredentials:          # option A
    accessKeyId:
      password: AKIA...
    secretAccessKey:
      password: wJalr...
  region: us-east-1
```

```yaml
kmsConfig:
  endpointUrl: https://kms.us-east-1.amazonaws.com
  ec2MetadataCredentials:       # option B
    iamRole: KroxyliciousInstance
  region: us-east-1
```

Both fields are nullable on the `Config` record.  `CredentialsProviderFactory` enforces at runtime that exactly one is non-null, rejecting configurations that specify zero or both.

This structure works for two providers, but additional provider types are planned (see proposal 018).  Each new type would add another nullable top-level field and another branch in the mutual-exclusivity check.

## Motivation

1. **Scalability** — with four or more providers the flat-field approach results in a growing number of nullable fields on `Config` and an increasingly complex exclusivity check in the factory.
2. **Clarity** — a single `credentials` key in the YAML makes it self-evident that exactly one authentication mechanism is configured, rather than requiring the user to know that `longTermCredentials` and `ec2MetadataCredentials` are mutually exclusive siblings.
3. **Extensibility** — future credential providers (IRSA, Pod Identity, SSO, STS AssumeRole) can be added by inserting one field into a dedicated record, with no changes to the top-level `Config` shape.

## Proposal

### New `credentials` configuration node

All credential providers are grouped under a single `credentials` key:

```yaml
kmsConfig:
  endpointUrl: https://kms.us-east-1.amazonaws.com
  credentials:
    longTerm:
      accessKeyId:
        password: AKIA...
      secretAccessKey:
        password: wJalr...
  region: us-east-1
```

```yaml
kmsConfig:
  endpointUrl: https://kms.us-east-1.amazonaws.com
  credentials:
    ec2Metadata:
      iamRole: KroxyliciousInstance
  region: us-east-1
```

The `credentials` object is a new record with one nullable field per provider.  The `CredentialsProviderFactory` enforces that exactly one field is non-null:

```java
public record CredentialsConfig(
    @JsonProperty("longTerm")    @Nullable LongTermCredentialsProviderConfig longTerm,
    @JsonProperty("ec2Metadata") @Nullable Ec2MetadataCredentialsProviderConfig ec2Metadata) {}
```

Future providers (proposal 018) will add fields to this record.

### Backward compatibility for existing providers

The existing flat-field configuration keys (`longTermCredentials`, `ec2MetadataCredentials`) are preserved as deprecated fields on `Config`.  The record's compact constructor transparently migrates them into the `credentials` node:

```yaml
# Old style — still works, deprecated
kmsConfig:
  endpointUrl: https://kms.us-east-1.amazonaws.com
  longTermCredentials:
    accessKeyId:
      password: AKIA...
    secretAccessKey:
      password: wJalr...
  region: us-east-1
```

Specifying both a deprecated flat field **and** the `credentials` node simultaneously is a configuration error.

### Implementation

The `Config` record gains a `credentials` field and retains the two existing flat fields for backward compatibility:

```java
public record Config(
    @JsonProperty(value = "endpointUrl", required = true) URI endpointUrl,
    @JsonProperty(value = "longTermCredentials") @Nullable LongTermCredentialsProviderConfig longTermCredentialsProviderConfig,
    @JsonProperty(value = "ec2MetadataCredentials") @Nullable Ec2MetadataCredentialsProviderConfig ec2MetadataCredentialsProviderConfig,
    @JsonProperty(value = "credentials") @Nullable CredentialsConfig credentials,
    @JsonProperty(value = "region", required = true) String region,
    @JsonProperty(value = "tls") @Nullable Tls tls) {

    public Config {
        Objects.requireNonNull(endpointUrl);
        Objects.requireNonNull(region);
        // Migrate deprecated flat fields into credentials node
        var migrated = credentials;
        if (longTermCredentialsProviderConfig != null) {
            if (migrated != null) throw ...;
            migrated = new CredentialsConfig(longTermCredentialsProviderConfig, null);
        }
        if (ec2MetadataCredentialsProviderConfig != null) {
            if (migrated != null) throw ...;
            migrated = new CredentialsConfig(null, ec2MetadataCredentialsProviderConfig);
        }
        credentials = migrated;
    }
}
```

The `CredentialsProviderFactory` is simplified to dispatch solely from `config.credentials()`.

## Affected/not affected projects

**Affected:**
- `kroxylicious-kms-provider-aws-kms` — new `CredentialsConfig` record, modified `Config`, modified `CredentialsProviderFactory`
- `kroxylicious-kms-provider-aws-kms-test-support` — `Config` constructor update
- `kroxylicious-systemtests` — `Config` constructor update
- `kroxylicious-docs` — updated configuration snippets, deprecation notes

**Not affected:**
- Other KMS providers (HashiCorp Vault, Azure Key Vault, Fortanix DSM, in-memory)
- The Kroxylicious operator
- Proxy runtime core

## Compatibility

- **Backward compatible:** existing YAML with `longTermCredentials` or `ec2MetadataCredentials` at the top level continues to work unchanged.
- **Deprecation:** the flat-field style will emit a log warning encouraging migration to the `credentials` node.  Removal of the deprecated fields is deferred to a future major version.
- **Forward compatible:** adding a new credential provider requires only a new field on `CredentialsConfig` — no changes to the top-level `Config` shape.

## Rejected alternatives

1. **Jackson polymorphic deserialization (`@JsonTypeInfo`)** — using a type discriminator inside `credentials` (e.g. `type: webIdentity`) would enforce single-provider semantics at the deserialization layer.  Rejected because it requires a discriminator property that differs from the key-per-provider style used elsewhere in Kroxylicious (Azure KMS `entraIdentity`, Fortanix `apiKeySession`) and makes the YAML less intuitive.

2. **Break existing config without backward compat** — since the project is pre-1.0, breaking changes are nominally acceptable.  Rejected because existing users have working configurations and migration should be painless.  The cost of the backward-compat shim (a few lines in the compact constructor) is negligible compared to the user friction of a forced migration.

3. **Keep flat fields, just add more** — rejected because it scales poorly.  With four providers, the `Config` record would have four nullable credential fields interspersed with `endpointUrl`, `region`, and `tls`, making the YAML hard to read and the factory logic fragile.
