# Proposal xxx -Migrate Kroxylicious Operator to Strimzi v1 API

Migrate the Kroxylicious Operator to use the Strimzi Kafka CR `v1` API, dropping support for `v1beta2`.

## Current situation

The Kroxylicious Operator's `KafkaService` CR supports a `strimziKafkaRef` field that allows the proxy to reference an upstream Kafka cluster provided by Strimzi. The operator currently reads the Strimzi `Kafka` CR at version `v1beta2`.

Specifically, the operator reads a small subset of the `Kafka` object:
- The `listeners` array from both `spec` and `status`

This allows the operator to discover connection details (bootstrap addresses, TLS configuration) for Strimzi-managed Kafka clusters.

## Motivation

Strimzi is evolving its Kubernetes API to `v1`. The timeline is as follows:

- **Strimzi 0.49.0** (September 2025) – introduced the `v1` API alongside `v1beta2`
- **Strimzi 0.52.0** – will remove support for `v1beta2` entirely

Currently, the Kroxylicious Operator will break when Strimzi 0.52.0 is released, as it will no longer be able to read `Kafka` resources at the `v1beta2` API version.

The Kroxylicious Operator must be updated to support Strimzi 0.52.0 and beyond. If this is not done, the Kroxylicious
integration will cease to work.  TODO: will the operator actually break completely? 

## Proposal

Migrate the Kroxylicious Operator to read the Strimzi `Kafka` CR at version `v1` only, dropping support for `v1beta2`.
This will be done for the next Kroxylicious release (currently planned as v0.21.0).

### Approach

1. Update the operator's Kubernetes client configuration to request `Kafka` resources at API version `v1` instead of `v1beta2`
2. Update any type references or model classes to use the `v1` schema
3. Verify that the fields used by the operator (`spec.listeners`, `status.listeners`) remain compatible

The [Strimzi v1 API proposal](https://github.com/strimzi/proposals/blob/main/113-Strimzi-v1-CRD-API-and-1.0.0-release.md#kafka) confirms that the listener-related fields used by the Kroxylicious Operator are not impacted by the migration from `v1beta2` to `v1`.

## Affected/not affected projects

### Affected

- `kroxylicious-operator` – must update Strimzi API version dependency

### Not affected

- `kroxylicious` – the proxy runtime is unaware of how the operator discovers Kafka clusters

## Compatibility

### Breaking change

**This proposal introduces a breaking change:** the updated operator will not support Strimzi versions prior to 0.49.0.

Specifically:
- **Strimzi 0.48.0 and earlier** (released September 2025 and before) will no longer be compatible
- Users running these versions must upgrade Strimzi to 0.49.0 or later before upgrading the Kroxylicious Operator

### Justification for breaking compatibility

1. **Strimzi 0.48.0 is already 6+ months old** (as of April 2026). The hope is most users will have upgraded. 

2. **Availability of easy workaround**.  Any user unable to upgrade to a newer version of Strimzi, can simply configure the `KafkaService` to point at the Kafka cluster directly (avoiding reliance on the Strimzi integration feature).

3. **Simpler implementation and maintenance.** Supporting a single API version keeps the codebase clean and avoids the complexity of runtime version detection, fallback logic, and testing multiple code paths. Using strongly-typed `Kafka` CR objects (rather than `GenericKubernetesResource`) reduces the risk of runtime errors and improves developer experience.

### Migration path for users

Users running Strimzi 0.48.0 or earlier must:
1. Upgrade Strimzi to 0.49.0 or later
2. Upgrade the Kroxylicious Operator to the version containing this change

The upgrade must be performed in this order. No other changes are required.

### Deprecation policy consideration

The project's [deprecation policy](https://github.com/kroxylicious/kroxylicious/blob/main/DEV_GUIDE.md#deprecation-policy)
does not currently state compatibility with other systems (such as Strimzi).

However, this change **must be clearly documented** in:
- The `CHANGELOG.md` as a breaking change
- The operator's release notes
- The operator's installation documentation, specifying the minimum supported Strimzi version

## Rejected alternatives

### Support both v1 and v1beta2

An alternative approach would be to update the operator to support **both** `v1` and `v1beta2` simultaneously, providing a backward-compatible migration path.

#### How it would work

1. At startup, the operator would probe the Kubernetes API to determine which versions of the `Kafka` CRD are available
2. If `v1` is available, use it; otherwise, fall back to `v1beta2`
3. Use Fabric8's `GenericKubernetesResource` to handle both versions dynamically, as strongly-typed models cannot easily support multiple API versions simultaneously

#### Why this was rejected

**1. Implementation complexity**

- Requires runtime API version detection and fallback logic
- Forces the operator to use `GenericKubernetesResource` instead of strongly-typed `Kafka` CR models
- Two code paths to implement, test, debug, and maintain

**2. Loss of type safety**

- `GenericKubernetesResource` is untyped, relying on raw JSON/map access patterns
- Higher risk of runtime errors from incorrect field access
- Worse developer experience and IDE support

**3. Temporary solution**

- Eventually, the `v1beta2` code path must be removed anyway (once Strimzi 0.52.0 is widely adopted)
- Supporting both versions defers the migration but does not avoid it
- Creates technical debt that must be paid later

**4. Minimal user benefit**

- Users on Strimzi < 0.49.0 (released September 2025) are already at least 6 months behind
- The forcing function to upgrade Strimzi will come from Strimzi 0.52.0 anyway, when `v1beta2` is removed entirely

**5. Increased maintenance burden**

- Doubles the testing matrix (must validate against multiple Strimzi versions and API versions)
- Increases the surface area for bugs and edge cases
- Complicates troubleshooting and support

### Conclusion

While supporting both `v1` and `v1beta2` provides a smoother upgrade path for users on very old Strimzi versions, the cost in implementation complexity, maintenance burden, and loss of type safety outweighs the benefit. The simpler approach—migrating directly to `v1` and requiring users to upgrade Strimzi first—is cleaner, easier to maintain, and aligns with Strimzi's own direction.
