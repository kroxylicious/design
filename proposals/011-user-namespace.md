<!-- This template is provided as an example with sections you may wish to comment on with respect to your proposal. Add or remove sections as required to best articulate the proposal. -->

# Resource Isolation Filter


Proposes the introduction of a "Resource Isolation Filter" to Kroxylicious's core filters.

The role of the Resource Isolation Filter is to give the client a private space within the kafka cluster space that is isolated from other users sharing the cluster.  Isolation can be applied selectively to different resource types.  This allows 
the possibility for some resource types (probably topics) to be shared between users whereas only resource instances exist in the private space.

## Current situation

The project has a preview multi-tenancy filter, which is a similar idea to this one except that it applies unconditionally to all resource types.

## Motivation

We encountered a use-case where the desire was to share topics but maintain isolated spaces for groups and transactional-ids.

## Proposal

The role of the Resource Isolation filter is to give the client the impression of a private kafka cluster space that is isolated from other clients sharing the cluster.  Namespacing can be applied selectively to different resource types.

The filter will use a pluggable API to determine how to map the name of each resource.  Operations that retrieve lists of resources will see only those that fall within the namespace. 

For the initial release, the filter will need to support only namespacing for consumer group names and transactional ids.  There will be scope for the filter to support prefixing of topic resources, but this won’t be supported in the initial release.

This proposal will deliver a simple implementation of the API that simply uses the principal as the prefix.
The principal will be added to the resource as it is sent to the server, and removed as it is returned in the response.

### APIs

#### Filter Configuration

```yaml
type: ResourceIsolation
config:
resourceNameMappers:
- resourceTypes: [TRANSACTIONAL_ID, GROUP_ID]
  resourceNameMapper: SimplePrincipalPrefixingNameMapper
```

#### Resource Name Mapper API

Asynchronous interface that lets the filter map from downstream names to upstream names and vice-versa.  It also
has the responsibility to filter the upstream view, removing resources that don't belong in the view.

```java
interface ResourceNameMapper {
     /** Return a mapping of downstream names to upstream names. */
	CompletionStage<Map<String, String>> mapDownstreamResourceNames(String authorizationId, ResourceType resourceType, List<String> downstreamResourceNames);
     /** Return a filtered map of upstream resource names to downstream names.  Any resources that do not form part of the view will be omitted from the map. */
	CompletionStage<Map<String, String>> mapUpstreamFilteredResourceNames(String authorizationId, ResourceType resourceType, List<String> upstreamResourceNames);
}
```

## Affected/not affected projects

Call out the projects in the Kroxylicious organisation that are/are not affected by this proposal. 

## Compatibility

Call out any future or backwards compatibility considerations this proposal has accounted for.

## Rejected alternatives

Call out options that were considered while creating this proposal, but then later rejected, along with reasons why.

## Limitations

The name prefixing approach reduces the length of the name that the client may use for resource names.  If the prefixed name exceeds the length permitted by Kafka the request must fail in an understandable way.
