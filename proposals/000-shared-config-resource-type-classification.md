# 000 - Shared ConfigResource type-classification utility

Multiple Kroxylicious filters need to determine whether a `ConfigResource` in a
`DescribeConfigs` request or response represents a topic name, a group id, or something else.
This logic has been independently implemented three times, each slightly differently. This
proposal introduces a small shared utility to consolidate the classification and eliminate the
duplication.

## Current situation

Three filter modules contain their own ConfigResource type-classification logic:

1. **kroxylicious-authorization** — `ConfigResources.filter(stream, idFn, type)` filters a
   stream of config-resource entries by comparing the raw `resourceType()` byte against
   `ConfigResource.Type.TOPIC.id()` or `ConfigResource.Type.GROUP.id()`. Used by
   `DescribeConfigsEnforcement`.

2. **kroxylicious-entity-isolation** — `EntityIsolation.fromConfigResourceType` decodes the raw
   byte via `ConfigResource.Type.forId`, then switches on the resulting enum to produce a
   semantic `EntityType.TOPIC_NAME` or `EntityType.GROUP_ID`. This is the most structured of the
   three: it decodes once and works with a typed enum rather than raw id comparisons.

3. **kroxylicious-multitenant** (PR #5296, not yet merged) — `MultiTenantFilter`'s
   `onDescribeConfigsRequest` / `onDescribeConfigsResponse` methods compare
   `resourceType() == ConfigResource.Type.TOPIC.id() || resourceType() == ConfigResource.Type.GROUP.id()`
   inline. This is the crudest variant: raw byte comparisons duplicated across both request and
   response handlers.

Each of these filter modules is independently pluggable and has no dependency on the others,
which is why the logic was reinvented rather than reused.

## Motivation

The duplication is small but carries real cost:

- **Inconsistency.** The three implementations differ in structure: one decodes via `Type.forId`
  and switches on the enum; two compare raw `id()` bytes. A future protocol change that adds a
  new config-resource type relevant to rewriting (unlikely but not impossible) would need to be
  found and fixed in three places.
- **Fragility.** The inline raw-byte comparisons in particular are easy to get wrong and hard to
  spot in review — there is no type safety guiding the comparison, and the intent (classify this
  resource type) is obscured by the mechanism (comparing bytes).
- **Boilerplate.** Every new filter that touches `DescribeConfigs` will face the same question
  and likely copy one of the existing approaches, perpetuating the divergence.

A single shared classification utility — small enough to be a single enum with a static factory
method — eliminates all three issues.

## Proposal

### Target module

This proposal recommends **`kroxylicious-api`**. The utility depends on `ConfigResource.Type`,
which — per [proposal 116](./116-kafka-api-migration.md) — is being forked into a
Kroxylicious-owned type in `kroxylicious-api`. The utility must be expressed in terms of the
owned type, so it must live in a module that has visibility of it. Since `kroxylicious-api` is
where the owned type lives and every filter already depends on it, it is the natural and only
zero-new-dependency home.

The API stability cost is low: the enum's shape is dictated by the Kafka protocol, not by
Kroxylicious design choices, so it is unlikely to need breaking changes.

### API shape

The utility is a single enum with a static factory method, modelled on the
`EntityIsolation.fromConfigResourceType` approach (decode once, switch on the typed enum):

```java
// Uses the Kroxylicious-owned ConfigResource.Type (proposal 116),
// not org.apache.kafka.common.config.ConfigResource.

/**
 * Classifies a {@link ConfigResource.Type} into the semantic entity it
 * names — a topic name, a group id, or something this classification
 * does not cover.
 */
public enum ConfigResourceEntityType {

    /** The resource names a topic. */
    TOPIC_NAME,

    /** The resource names a consumer group. */
    GROUP_ID;

    /**
     * Classifies a raw {@code resourceType} byte from a {@code DescribeConfigs}
     * request or response entry.
     *
     * @param resourceType the {@link ConfigResource.Type#id()} byte
     * @return the classified entity type, or empty if the resource type
     *         is not one that names a topic or group (e.g. {@code BROKER},
     *         {@code BROKER_LOGGER}, or an unknown type)
     */
    public static Optional<ConfigResourceEntityType> fromResourceType(byte resourceType) {
        ConfigResource.Type type = ConfigResource.Type.forId(resourceType);
        return switch (type) {
            case TOPIC -> Optional.of(TOPIC_NAME);
            case GROUP -> Optional.of(GROUP_ID);
            default -> Optional.empty();
        };
    }
}
```

Design choices:

- **`Optional` return rather than a third enum constant.** A `fromResourceType` call site
  typically needs to branch on "is this a type I need to rewrite?" vs "skip it". Returning
  `Optional.empty()` for unrecognised or irrelevant types (broker, broker-logger, unknown) lets
  the caller use `ifPresent`, `map`, or `filter` directly. A third `OTHER` / `UNSUPPORTED`
  constant would force every caller to handle a value it has no use for.

- **Decode via `Type.forId` once.** The raw byte is decoded to the `ConfigResource.Type` enum
  immediately, and all subsequent logic uses the typed enum. This avoids the raw byte
  comparisons that made the multitenant copy fragile.

- **Enum, not an interface.** The set of relevant config-resource entity types is fixed by the
  Kafka protocol and small. An interface or sealed hierarchy would add abstraction without
  adding extensibility that is actually needed.

### Migration

The migration is mechanical and can be delivered incrementally:

1. **kroxylicious-entity-isolation** — replace the private
   `EntityIsolation.fromConfigResourceType` method with a call to
   `ConfigResourceEntityType.fromResourceType`, mapping the result to the filter's own
   `EntityType` if it retains one, or switching to `ConfigResourceEntityType` directly.

2. **kroxylicious-authorization** — replace the inline `ConfigResource.Type.TOPIC.id()` /
   `ConfigResource.Type.GROUP.id()` comparisons in `ConfigResources.filter` with a
   `ConfigResourceEntityType.fromResourceType` call and a match on the result.

3. **kroxylicious-multitenant** — once PR #5296 lands, replace the raw byte comparisons in
   `MultiTenantFilter`'s `onDescribeConfigsRequest` / `onDescribeConfigsResponse` with the
   shared utility. This is a follow-up, not a prerequisite: the utility can land and the
   first two migrations can merge before #5296 does.

Each migration is a small, independently reviewable change. No filter's external behaviour
changes — the classification logic is identical, just shared.

## Affected/not affected projects

**Affected:**

- `kroxylicious/kroxylicious` — `kroxylicious-api` gains the `ConfigResourceEntityType` enum.
  The three filter modules listed above adopt it.

**Not affected:**

- `kroxylicious-operator` — no CRD or operator changes.
- KMS modules, authorizer APIs, proxy runtime — none touch `DescribeConfigs` classification.
- External filter authors — the utility is opt-in; existing filters continue to work unchanged.

## Compatibility

The change is purely additive. A new enum is introduced in `kroxylicious-api` expressed in
terms of the owned `ConfigResource.Type` from proposal 116; nothing existing is removed or has
its signature changed. Filter modules that adopt the shared utility replace private internal
logic with an equivalent shared call — no externally visible behaviour changes.

## Rejected alternatives

### Place the utility in `kroxylicious-kafka-message-tools`

At first glance a natural fit — the module is described as "tools for manipulating kafka
messages" and has no dependency on the rest of Kroxylicious. However, it depends on
`kafka-clients`, and the utility must be expressed in terms of the Kroxylicious-owned
`ConfigResource.Type` from proposal 116, which lives in `kroxylicious-api`.
`kroxylicious-kafka-message-tools` does not depend on `kroxylicious-api`, and adding that
dependency would change the module's stated contract. Rejected.

### Place the utility in a new `kroxylicious-protocol-support` module

A dedicated module for protocol-level helpers would keep it off the public API surface, but
introducing a new module is unnecessary when `kroxylicious-api` already contains the owned
type the utility depends on and every filter already depends on it.

### Return a third `OTHER` enum constant instead of `Optional`

Rejected. Every call site that would receive `OTHER` would immediately discard or skip it. An
`Optional.empty()` expresses "not relevant" more naturally and lets callers use `ifPresent` /
`map` / `filter` without a dead branch.

### A richer abstraction (interface, sealed hierarchy, or visitor)

Rejected. The domain is two constants and a "none of the above" case. An interface or visitor
pattern would add ceremony without adding value — the set of config-resource types relevant to
entity rewriting is fixed by the Kafka protocol and unlikely to grow.

### Reuse `EntityIsolation.EntityType` directly

Rejected. `EntityType` is an internal type of the entity-isolation filter. Depending on it
would couple every consumer to that filter module, which is exactly the dependency this proposal
exists to avoid.

### Keep the duplication

Rejected. Three copies is past the threshold where the maintenance cost of divergence exceeds
the cost of a small shared utility. A fourth copy is already in progress (PR #5296).
