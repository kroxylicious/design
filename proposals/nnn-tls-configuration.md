# Cleaning up TLS configurations

We propose to deprecate `git io.kroxylicious.proxy.config.tls` in the `kroxylicious-api` module. 
Existing uses of it within the project will be replaced with per-site structures that use the same YAML field names but include only the subset of properties supported at each use site. 

## Current situation

When we originally added `io.kroxylicious.proxy.config.tls.Tls` to the API module our intent was to have a consistent way of configuring TLS settings in all the places where TLS was going to be used. 
TLS is now used in many places within the project.

## Motivation

Each different use site of `Tls` within configuration tends to come with its own idiosyncrasies. 
For example, at some use sites we support JKS and PKCS#11 keystores, but not PEM-encoded keys/certificates.
In other places we might not yet support restricting TLS protocol versions or cipher suites. 
At such use sites we invariably need to write validation code to prevent the user attempting to configure something that's not supported.
Failure to do this can mean:
* the proxy will suffer an exception during startup (probably with a not-easily understood exception message). This would be the case if the user supplied a PEM TLS key in a place where only JKS and PKCS#11 are supported, for example
* the proxy will appear to start up, but the user's intention is silently not honoured. This would be the case for TLS protocol versions and cipher suites, for example.

As `Tls` gets used in more places, some use sites require the addition of new properties to the common `Tls` structure. 
That is the case in [#3218](https://github.com/kroxylicious/kroxylicious/pull/3218), for example.
Adding new properties then creates a problem at all the existing use sites, which don't support those new properties. 
For each use site we need to:
* either add support for the new property, or
* detect and generate an error if the new property is given in the configuration.

This problem gets worse the more `Tls` is used, because there are more use sites to fix.

Overall, the end user experience is degraded because `Tls` is becoming a confusing dumping ground for TLS-related configurations, the union of all the things that can be configured at any of the use sites.

## Proposal

Deprecate the `io.kroxylicious.proxy.config.tls` package in the `kroxylicious-api` module, including all the clases in it.
All existing uses of classes in that package within the project will be replaced with structures declared in each module where it's used.
Those structures will use the same field names and nesting as the current `Tls` type, but will include only the subset of fields actually supported at that use site.
This will remove the need for so much hand-written validation code at those use sites.
Instead those errors will be detected by Jackson when parsing the configuration YAML.

### Example: Schema registry client TLS

`SchemaValidationConfig` currently accepts the full `Tls` type, but `ProduceRequestValidatorBuilder` rejects `key`, `cipherSuites`, and `protocols` at runtime with hand-written validation. 
With this proposal, the schema registry's TLS configuration would instead be:

```java
sealed interface TrustProvider permits TrustStore, InsecureTls {}

record TrustStore(
        String storeFile,
        PasswordProvider storePasswordProvider,
        String storeType) implements TrustProvider {}

record InsecureTls(boolean insecure) implements TrustProvider {}

record Tls(@Nullable TrustProvider trust) {}
```

The unsupported fields (`key`, `cipherSuites`, `protocols`) simply do not exist in the type.
If a user supplies them in the YAML, Jackson rejects the configuration at parse time, and the hand-written validation code in `ProduceRequestValidatorBuilder` is no longer needed.

### Example: KMS HTTP client TLS

`TlsHttpClientConfigurator` currently accepts the full `Tls` type, but rejects `KeyPair` and PEM-format keystores/truststores at runtime.
With this proposal, the per-site types would be:

```java
record KeyStore(
        String storeFile,
        PasswordProvider storePasswordProvider,
        PasswordProvider keyPasswordProvider,
        String storeType) {}

sealed interface TrustProvider permits TrustStore, InsecureTls {}

record TrustStore(
        String storeFile,
        PasswordProvider storePasswordProvider,
        String storeType) implements TrustProvider {}

record InsecureTls(boolean insecure) implements TrustProvider {}

record Tls(
        @Nullable KeyStore key,
        @Nullable TrustProvider trust) {}
```

`key` is typed as `KeyStore` directly rather than a `KeyProvider` interface, so `KeyPair` (PEM key/certificate pairs) cannot be expressed and is rejected at parse time.
PEM-format keystores (where `storeType` is `PEM`) remain a value constraint that requires runtime validation, since `storeType` is a string field.
This could be further tightened by using an enum for `storeType`, but that is an independent decision.

The work to fix each use site can be done incrementally and delivered over a number of releases. 

## Affected/not affected projects

This affects the kroxylicious repository only.

## Compatibility

These changes should be compatible for end users of the proxy. 
Any YAML configuration which works today will continue to work. 
YAML configurations which do not work today would be rejected with a different error, as described above.
It is possible that we have missed implementing validations in the past and there are some configuration which currently appear to work, but silently do not (e.g. the TLS protocol version case). 
Such bugs will be exposed by these changes. 
But the point is that such cases (if they exist) are existing bugs in the existing proxy, so making them fail explicitly is not considered an incompatibility.
There is no regression because they never actually worked.

3rd party plugin developers who are using `Tls` in their own plugin configuration classes would need to define their own per-site TLS types, following the same approach as the internal modules.
They would have the deprecation period to make these changes.
Once the package is actually removed from the API module, plugins still depending on it would no longer work with the proxy. 

## Rejected alternatives

* Do nothing. But this situation will only get worse.
* Compose per-site config from shared leaf types. Keep types like `KeyStore` and `TrustStore` in the API module; define only the top-level TLS record per use site. This avoids duplicating leaf type definitions, but constraining which leaf types are valid at each site cannot be done with Java's sealed types across module boundaries (JEP 409 requires permitted subtypes to be in the same module as the sealed interface). The remaining options (unsealed marker interfaces, Jackson-only validation) add complexity without providing compile-time safety. The duplication of a few small, stable records is an acceptable cost for a simpler design.
