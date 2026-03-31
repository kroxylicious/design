<!-- This template is provided as an example with sections you may wish to comment on with respect to your proposal. Add or remove sections as required to best articulate the proposal. -->

# Entity Isolation Filter


Proposes the introduction of a "Entity Isolation Filter" to Kroxylicious's core filters.

This filter gives a connected client an isolated view of some or all of its entities (e.g. topics), segregating them entities of other clients that happen to use the same name.
Isolation can be applied selectively to some entity types and not others.  For example, it's possible to have isolation for consumer groups, but not for topics.

## Current situation

The project has a preview multi-tenancy filter, which is a similar idea to this one except that it applies unconditionally to all resource types.

## Motivation

We encountered a use-case where the desire was to share topics but maintain isolated spaces for groups and transactional-ids.

## Proposal

It is proposed to add a new filter, the Entity Isolation filter, to set of core filters shipped as part of Kroxylicious.

The filter will be capable of isolating the kafka entities of from one client from those of another client, even if they have to choose the same name.

The filter will achieve isolation using name transformation and result filtering

- Entity names known to the client will be transformed in some way to avoid collision with entities belonging to other clients.
- The client will have no knowledge of the entity's transformed name.
- When the client uses Kafka APIs that list entities, the result set will be filtered so that the client receives only entities that belong to them.

## Configurable isolation

The filter will expose configuration that allows the administrator to decide which entity types are isolated and which are not.
For instance, it will be possible to configure the filter so that Kafka group-ids and transactional-ids are isolated, but
topic are not.

## Pluggable Mapper

The filter will be delegate the job of transforming and filtering entity names to a `EntityNameMapper`.  The mapper will be pluggable API
allowing alternative mapping strategies to be employed.

For the first release there will be a single implementation of the mapper, PrincipalEntityNameMapper, that works by prefixing the entity name with the name of a unique principal from the authenticated subject and a configurable separator
To use this mapper, the proxy must be configured with a `SubjectBuilder` so that the filter is aware of the channel's authenticated subject (from TLS or SASL).

On the request path, the isolated entity name will be prefixed with the principal name like so.

```
orders -> alice_orders
```

On the response path, for Kafka messages that list entities, the entities will be first filtered:

```
alice_orders -> alice_orders
bob_orders // filtered out
charlie_orders // filtered out
```

then the prefixing removed:

```
alice_orders -> orders
```

## Security

The role of the filter is to prevent the entities of one client being visible to another.  In other words, prevent an information leak between clients.

There's the possibility that a new version of the Kafka protocol could expose an entity in a new way.
There could be a new API key or API version of an existing API key that exposes an entity that ought to be isolated.

If an old version of this filter (one that doesn't know about the new API key/versions) is used with Kafka a client/broker that supports it, an information leak is a possibility.

In order to prevent this, the filter will employ a `fail-closed` methodology.

This means it will:
- influence the `ApiVersions` negotiations so that client/broker selects only API key and API versions that are known to the filter.
- if the filter encounters a API key or API version that is unknown to it, it will close the connection with an error.

## Restrictions in scope for the first version

In order to narrow the scope of the problem, the first version of the Entity Isolation Filter will be restricted
to the groupId and transactionId entity types.

Topic isolation has some additional challenges which we want to defer to a future release.  These are described in the
following issue https://github.com/kroxylicious/kroxylicious/issues/3504.

### APIs

#### Filter Configuration

```yaml

type: io.kroxylicious.filter.entityisolation.EntityIsolation
config:
  entityTypes:
    - GROUP_ID
    - TRANSACTIONAL_ID
  mapper: PrincipalEntityNameMapperService
  mapperConfig:
    separator: "-"
    principalType: io.kroxylicious.proxy.authentication.User
```

## EntityNameMapper API

Synchronous API that lets the filter map from downstream names to upstream names and vice versa.
It also has the responsibility to filter the upstream view, removing resources that don't belong in the view.

Asynchronous interface that lets the filter map from downstream names to upstream names and vice-versa.  It also
has the responsibility to filter the upstream view, removing resources that don't belong in the view.

```java
interface EntityNameMapper {
    String map(MapperContext mapperContext,
               EntityType entityType,
               String downstreamEntityName)
            throws EntityMapperException;

    /**
     *  Maps an upstream kafka entity name to a downstream name.
     *
     * @param mapperContext mapper context.
     * @param entityType entity type.
     * @param upstreamEntityName upstream entity name.
     * @return downstream entity name
     * @throws EntityMapperException the mapped entity name violates one or more system constraints.
     */
    String unmap(MapperContext mapperContext,
                 EntityType entityType,
                 String upstreamEntityName)
            throws EntityMapperException;

    /**
     * Tests whether the given upstreams entity name belongs to this context.
     *
     * @param mapperContext mapper context.
     * @param entityType entity type.
     * @param upstreamEntityName upstream entity name.
     * @return true if the mapped entity name belongs to this context, false otherwise.
     */
    boolean isOwnedByContext(MapperContext mapperContext,
                             EntityType entityType,
                             String upstreamEntityName);
}
```

```java
record MapperContext(Subject authenticatedSubject, @Nullable ClientTlsContext clientTlsContext, @Nullable ClientSaslContext clientSaslContext) {
    public MapperContext {
        Objects.requireNonNull(authenticatedSubject);
    }
}
```


## Affected/not affected projects

This proposal introduces a new filter.  It does not affect any existing projects with the Kroxylicious organisation.

## Compatibility

This proposal introduces a new filter. There are no changes to existing APIs.

## Rejected alternatives

### Build on the Multi Tenancy Filter

The project has an existing 'proof-of-concept' Multi Tenancy Filter that dates back to the project's inception.
It isolates topic names, group ids and transactional ids by prefixing with entities with the virtual cluster name.
Its implementation is sufficient to cover basic produce/consume use-cases only but nothing more.
There are several areas where the filter will fail.

Whilst it would have been possible to base the entity isolation work on the multi tenancy filter,
it was felt by the developers that a fresh start would give stronger foundations.
