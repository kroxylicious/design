<!-- This template is provided as an example with sections you may wish to comment on with respect to your proposal. Add or remove sections as required to best articulate the proposal. -->

# Authorizer Filter

The Authorizer filter gives the ability to add authorisation checks into a Kafka system which will be enforced by the proxy. 

## Current situation

It is possible for a filter to implement its own business rules, enforcing authorization in some custom manner.  However,
that approach does not have good separation of concerns.  Authorization checks are an orthogonal concern, and security
best practice is to separate their enforcement from business logic.

## Motivation

We are identifying use-cases where making authorization decisions at the proxy is desirable.   Examples include where one wishes to restrict a virtual cluster to a sub-set of the resources (say topics) of the cluster.

## Proposal

The Authorizer filter gives the ability to layer authorization checks into a Kafka system which with those authorization checks being enforced by the filter.  These authorization checks are in addition to anythat may be imposed by the Kafka Cluster itself. This means that for an action to be allowed both the proxy’s authorizer and the Kafka broker’s authorizer will need to reach an ALLOW decision.

The Authorizer filter allows for authorization checks to be made in the following form:

`Principal P is [Allowed/Denied] Operation O On Resource R`.

where:

* Principal is the authenticated user.
* Operation is an action such as, but not limited to, Read, Write, Create, Delete.
* Resource identifies one or more resources, such as, but not limited to Topic, Group, Cluster, TransactionalId.

Unlike Apache Kafka authorizer system, the `from host` predicate is omitted.  This is done to adhere to the modern security principle that there are no privileged network locations.

### Request authorization

The Authorizer filter will intercept all request messages that perform an action on a resource, and all response messages that list resources.  

On receipt of a request message from the downstream, the filter will make an asynchronous call to the authorizer for the resource(s) involved in the request.  If the authorization result for all resources is `ALLOWED`, the filter will forward the request to the broker.
If the authorization result is `DENIED` for any resource in the request, the filter will produce a short circuit error response denying the request using the appropriate authorization failed error code.  The authorizer filter must not forward requests that fail authorization. 

### Response resource filtering

On receipt of a response message from the upstream, the Authorizing filter will filter the resources so that the downstream receives only resources that they are authorized to `DESCRIBE`.

Some Kafka responses contain authorized operations values (originally introduced by [KIP-430](https://cwiki.apache.org/confluence/display/KAFKA/KIP-430+-+Return+Authorized+Operations+in+Describe+Responses)).
These give the client a way to know which operations are supported for a resource without having to try the operation.
Authorized operation values are bit fields where each position in the bitfield corresponds to a different operation.
The broker computes authorized operations values only when requested.  The client sets an include authorized operations flag in the request
and the broker then computes the result which is returned in the response.

If authorized operation values present in the response (`>0`), the filter must compute the effective authorized operations values
given both the value returned from the upstream and authorized operation value computed for the ACLs imposed by itself.
The response must be updated with the effective value before it is returned to the client.
This equates to a bitwise-AND operation on the two values.

### Pluggable API

The Authorizer filter will have a pluggable API that allows different Authorizer implementations to be plugged in.  This proposal will deliver a simple implementation of the API that allows  authorization rules to be expressed in a separate file.  Future work may
deliver alternative implementations that, say, delegate authorization decisions to externals systems (such as OPA), or implement other
authorizations schemes (such as RBAC).

### Operation/Resource Matrix

For the initial version, the system will be capable of making authorization decisions for topic operations and cluster connections only.
Future versions may support authorization decisions for other Kafka resources types (e.g. consumer group and transactional id).
The Authorizer will be designed to be open for extension so that it may be used to make authorization decisions about other entities (beyond those defined by Apache Kafka).

The table below sets out the authorization checks and filters will be implemented.

| Operation | Resource Type | Kafka Message                                                                                                                                                                                                          |
|-----------|---------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| READ      | Topic         | Fetch, ShareFetch, ShareGroupFetch, ShareAcknowledge, AlterShareGroupOffsets, DeleteShareGroupOffsets, OffsetCommit, TxnOffsetCommit, OffsetDelete                                                                     |
| WRITE     | Topic         | Produce, InitProducerId, AddPartitionsToTxn                                                                                                                                                                            |
| CREATE    | Topic         | CreateTopics                                                                                                                                                                                                           |
| DELETE    | Topic         | DeleteTopics                                                                                                                                                                                                           |
| ALTER     | Topic         | AlterConfigs, IncrementalAlterConfigs, CreatePartitions                                                                                                                                                                |
| DESCRIBE  | Topic         | ListOffset, OffsetFetch, OffsetFetchForLeaderEpoch DescribeProducers, ConsumerGroupHeartbeat, ConsumerGroupDescribe, ShareGroupHeartbeat, ShareGroupDescribe, MetaData, DescribeTopicPartitions, ConsumerGroupDescribe |
| CONNECT   | Cluster       | SaslAuthenticate                                                                                                                                                                                                       |

In general, the filter will make access decisions in the same manner as Kafka itself.  This means it will apply the same authorizer checks that Kafka enforces itself and generate error responses in the same way.  It will
From the client's perspective, it will be impossible for it to distinguish between the proxy and kafka cluster itself.
It will also use the same implied operation semantics as implemented by Kafka itself, such as where `ALTER` implies `DESCRIBE`, as described by 
`org.apache.kafka.common.acl.AclOperation`.

There is one deviation.  The filter will implement a `CONNECT` authorization check on the `CLUSTER` early, as the connection is made, once the principal is known.  This allows the Authorizer filter to be used to gate access to virtual clusters.
* In the case of SASL, this will be performed on receipt of the Sasl Authentication Response.  If the authorization check fails, the authentication will fail with an authorization failure and the connection closed.
* In case of TLS client-auth, this will be performed on receipt of the first request message.   If the authorization check fails, a short circuit response will be sent containing an authorization failure and the connection closed.  This feature won’t be part of the initial scope.

The filter will support messages that express topic identity using topic ids (i.e. those building on [KIP-516](https://cwiki.apache.org/confluence/display/KAFKA/KIP-516%3A+Topic+Identifiers)).  It will resolve the topic id into a topic name before making the authorization check.

### File based Authorizer implementation

The initial scope will include an Authorizer implementation that is backed by authorization rules expressed in a separate file.  This file will associate principals with ACL rules capable of expressing an allow-list of resources.
The initial version will be restricted to expressing allow lists of topics, but future version will extend this to allow for rules to be express about other resource types.

### APIs

#### Authorizer Filter

Filter Configuration:

```yaml
type: AuthorizerFilter
config:
  authorizer: FileBasedAllowListAuthorizer
  authorizerConfig:
    rulesFile: /path/to/allow-list.yaml
```

Java APIs:

```java
// Inspired by org.apache.kafka.server.authorizer.Authorizer, except is asynchronous in nature.
interface Authorizer {
    CompletionStage<List<AuthenticationResult>> authorize(AuthorizableRequestContext context, List<Action> actions);
}
```

```java
// Inspired by org.apache.kafka.server.authorizer.AuthorizableRequestContext
interface AuthorizableRequestContext {
    String principal();
    // scope for methods such as requestType(), requestVersion()  etc to be added in future.
}
```

```java
// Inspired by org.apache.kafka.server.authorizer.Action
record Action(
    AclOperation aclOperation,
    ResourcePattern resourcePattern) {
}
```

```java
// The following types are inspire by the Kafka classes of the same name and have the same role.  However, interfaces are used
// rather than enums to allow for extensibility (using pattern suggested by https://www.baeldung.com/java-extending-enums)
interface AclOperation {
    String operationName();
}

enum CoreAclOperation implements AclOperation {
  CREATE("Create"),
  DELETE("Delete"),
  READ("Read")/* ,... */
}

interface ResourceType {
    String resourceType();
}


enum CoreResourceType implements ResourceType {
  TOPIC("Topic"),
  CLUSTER("Cluster")
}

interface PatternType {
   boolean matches(String resourceName);
}


enum CorePatternType {
   LITERAL() {
      @Override
      boolean matches(String pattern, String resourceName) {
         return pattern.equals(resourceName);
      }
   },
   MATCH() { /* ... */ },
   PREFIXED { /* ... */ }
}

record ResourceNamePattern(PatternType patternType, String pattern) {
    boolean matches(String resourceName) {
       return patternType.matches(pattern, resourceName);  
    }
}
```

#### Rules File

The rules file expresses a mapping between principals (user type only with exact match) and an allow-list of resources.

For the initial scope, only resource rules of type TOPIC are supported.  In order to allow for future extension, the user’s configuration set the version property to 1.  This will allow future versions of the filter to introduce support for other resource types without changing the meaning of existing configurations.

For the `CLUSTER` `CONNECT` authorization check, this will be implemented implicitly.  The check will return `ALLOW` if there is at least one resource rule for the principal.  If there are no resource rules for the principal, the authorizer will return `DENY`.

```yaml
version: 1  # Mandatory must be 1.  Version 1 is defined as supporting resourceType TOPIC only.
definitions:
- principals: [User:bob, User:grace]  # Only User: prefixed principals will be supported.
  resourceRules:
  - resourceType: TOPIC   #  Only the topic resourceType is permitted
    operations: [READ]
    patternType: LITERAL
    resourceName: foo
  - type: TOPIC
    operations: [ALL]
    patternType: PREFIXED
    resourceName: bar
  - type: TOPIC
    operations: [ALL]
    patternType: MATCH
    resourceName: baz*
```

## Affected/not affected projects

The kroxylicious repo.

## Compatibility

No issues - this proposal introduces a new filter./

## Rejected alternatives

### Reuse of the Kafka ACL interfaces/enumerations

The Kafka Client library includes interfaces and enumeration such as `org.apache.kafka.server.authorizer.Action`
and `org.apache.kafka.common.acl.AclOperation`.  It would be technically possible to base the Authorizer's interfaces
on these types.  This would have the advantage that it would help ensure that the ACL model of the Proxy followed
that of Kafka, but it would have also meant restricting the Authorizer to making access control decisions for the same
entities as Kafka does.  We want to leave open the possibility to make access decisions about other resource types, beyond
those considered by Kafka today (such as record-level ACLs).

