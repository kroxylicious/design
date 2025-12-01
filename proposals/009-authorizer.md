<!-- This template is provided as an example with sections you may wish to comment on with respect to your proposal. Add or remove sections as required to best articulate the proposal. -->

# Authorization Filter

The Authorization filter gives the ability to add authorisation checks into a Kafka system which will be enforced by the proxy. 

## Current situation

Kafka itself already supports authorization over entities including topics, consumer groups and so on.
This is fine when the broker has the complete context for making an authorization decision.
But that's not necessarily the case when a proxy is part of the picture.

It is possible for a filter to implement its own business rules, enforcing authorization in some custom manner.  However,
that approach does not have good separation of concerns.  Authorization checks are an orthogonal concern, and security
best practice is to separate their enforcement from business logic.

## Motivation

We are identifying use-cases where making authorization decisions over Kafka entities like topics at the proxy is desirable.
Examples include where one wishes to restrict a virtual cluster to a sub-set of the resources (say topics) of the cluster.

There are also use cases where filters might want to make authorization decisions over different entities than traditional Kafka supports.
Examples include things like record-level authorization, or authorization of entities like encryption keys.

## Proposal

We propose to add authorization-related APIs to Kroxylicious, as follows:

1. Model client identity using new types in `kroxylicious-api`, namely JAAS-like `Subject` and `Principal`, with an accessor on the `FilterContext`.
2. Provide support in `kroxylicious-runtime` for basic subjects constructed from TLS or SASL information.
3. Add a new `kroxylicious-authorizer` module defining an `Authorizer` plugin interface.
4. Add a new `kroxylicious-authorizer-acl` module implementing the `Authorizer` plugin interface using Access Control Lists (ACLs).
5. Add a new `kroxylicious-authorization` module implementing an `Authorization` protocol filter plugin which uses an `Authorizer` instance to provide Kafka-equivalent authorization.

The following subsections will explain these pieces in detail.

Ultimately, the `Authorization` filter gives the ability to layer authorization checks into a Kafka system with those authorization checks being enforced by the filter. These authorization checks are in addition to any that may be imposed by the Kafka Cluster itself. This means that for an action to be allowed both the proxy’s authorizer and the Kafka broker’s authorizer will need to reach an ALLOW decision.

### Changes in `kroxylicious-api` -- `Subject` and `Principal`

Proposals [005][prop-5] and [006][prop-6] added the functionality for filters to find out authentication information about connected clients in the form of a TLS client certificate and/or a SASL authorized id. 
Authorization decisions may need to depend on more than just the single string identifier either of these can yield. 
We want an API capable of supporting:

* Mapping from a TLS client certificate subject and/or subject alternative names (SAN) to a different string identifier.
* Making authorization decisions based on information about the client learned from a trusted source (e.g. Active Directory, or OAuth token introspection)
* Making some authorization decisions based on identity and others based on this additional information.
* Providing information for other uses in the future. Examples include grouping clients together to report an aggregated metric, or grouping clients together for quotaing purposes. 

For example, in a future verion of the proxy that supported multitenancy we might have `Subjects` composed of `User`, `Role` and `Tenant` principals. `User` and `Role` might be used for authorization, while `Tenant` might be used for enforcement of a bandwidth quota covering all the clients with the same `Tenant`.

To do this we will use a similar model to JAAS, but using our own types:

```java
package io.kroxylicious.proxy.authentication;

/**
 * <p>Represents an actor in the system.
 * Subjects are composed of a possibly-empty set of identifiers represented as {@link Principal} instances.
 * An anonymous actor is represented by a Subject with an empty set of principals.
 * As a convenience, {@link Subject#anonymous()} returns such a subject.
 * </p>
 *
 * <p>The principals included in a subject might comprise the following:</p>
 * <ul>
 * <li>information proven by a client, such as a SASL authorized id,</li>
 * <li>information known about the client, such as the remote peer's IP address,</li>
 * <li>information obtained about the client from a trusted source, such as lookup up role or group information from a directory.</li>
 * </ul>
 *
 * @param principals
 */
public record Subject(Set<Principal> principals) { ... }


/**
 * <p>An identifier held by a {@link Subject}.</p>
 *
 * <p>Implementations <strong>must</strong> override {@code hashCode()} and {@code equals(Object)} such
 * instances are equal if, and only if, they have the same implementation class and their names that are the same
 * (according to {@code equals()}). One easy way to achieve this is to use a {@code record} class with a single {@code name} component.</p>
 */
public interface Principal {
    /** 
     * The name of the principal.
     */
    String name();
}
```

A Filter will be able public a Subject as a result of SASL authentication and to obtain the `Subject` from the `FilterContext`:

```java
package io.kroxylicious.proxy.filter;

public interface FilterContext {
    // ... existing methods ...

    // new methods:
    /**
     * Allows a filter (typically one which implements {@link SaslAuthenticateRequestFilter})
     * to announce a successful authentication outcome with the Kafka client to other plugins.
     * After calling this method the results of {@link #clientSaslContext()}
     * and {@link #authenticatedSubject()} will both be non-empty for this and other filters.
     *
     * In order to support reauthentication, calls to this method and
     * {@link #clientSaslAuthenticationFailure(String, String, Exception)}
     * may be arbitrarily interleaved during the lifetime of a given filter instance.
     * @param mechanism The SASL mechanism used
     * @param subject The subject
     */
    void clientSaslAuthenticationSuccess(String mechanism,
                                         Subject subject);
    
    /**
     * <p>Returns the client subject.</p>
     *
     * <p>Depending on configuration, the subject can be based on network-level or Kafka protocol-level information (or both):</p>
     * <ul>
     *   <li>This will return an
     *   anonymous {@code Subject} (one with an empty {@code principals} set) when
     *   no authentication is configured, or the transport layer cannot provide authentication (e.g. TCP or non-mutual TLS transports).</li>
     *   <li>When client mutual TLS authentication is configured this will
     *   initially return a non-anonymous {@code Subject} based on the TLS certificate presented by the client.</li>
     *   <li>At any point, if a filter invokes {@link #clientSaslAuthenticationSuccess(String, Subject)} then that subject
     *   will override the existing subject.</li>
     *   <li>Because of the possibility of <em>reauthentication</em> it is also possible for the
     *   subject to change even after then initial SASL reauthentication.</li>
     * </ul>
     *
     * <p>Because the subject can change, callers are advised to be careful to avoid
     * caching subjects, or decisions derived from them.</p>
     *
     * <p>Which principals are present in the returned subject, and what their {@code name}s look like,
     * depends on the configuration of network
     * and/or {@link #clientSaslAuthenticationSuccess(String, Subject)}-calling filters.
     * In general, filters should be configurable with respect to the principal type when interrogating the returned
     * subject.</p>
     *
     * @return The client subject
     * @see #clientSaslAuthenticationSuccess(String, Subject)
     */
    Subject authenticatedSubject();
}
```

There's strong no need, at the API level, to be prescriptive about the implementations of `Principal` that are allowed.
In particular, we don't want to limit `Principal` implementations to being provided by the API module.
However, in order to guaranteeing that `authenticatedSubject()` cannot return `null` and also support backwards compatibility for the existing API (e.g. `FilterContext.clientSaslAuthenticationSuccess(String mechanism, String authorizedId)` and `ClientSaslContext.authorizationId()`), we need the runtime to have a way of making a `Subject` out of an `authorizedId`, and providing an `authorizedId` from a `Subject`
For this reason we will provide a `User` class in the runtime, and initially require that the `Subjects` with non-empty `principals` published via `clientSaslAuthenticationSuccess(String mechanism, Subject subject)` always have a single `User` principal. This allows `ClientSaslContext.authorizationId()` to work even when the new API is used.

```
/**
 * A principal identifying an authenticated client.
 * It is currently required to use this principal to represent clients that have authenticated via
 * TLS or SASL.
 * @param name The name of the user.
 */
public record User(String name) implements Principal {}
```



### Support for TLS and SASL subjects in `kroxylicious-runtime`

Kroxylicious supports APIs that allow authentication information to be obtained from TLS or SASL. 
SASL itself supports a variety of mechanisms, and although successful SASL authentication in the abstract yields an `authorizedId`, specific mechanism might have more information about the subject available. For example:

* Some configurations of OAUTH can provide information about claims about the Subject perhaps via an introspection endpoint.
* TLS client certificates might include useful information in the Subject Alternative Names.
* There might be information about users roles and groups stored in a directory service.

To provide flexibility for making use of such richer context about the subject, we will introduce plugin APIs for how `Subjects` get built.

To provide better type safety we will have two distinct types, one for Subjects built from transport-level context (usually TLS, though it's not required to configure this API), and one for Subjects built from a SASL authentication exchange.
The `TransportSubjectBuilder` will be cofigurable at the virtual cluster level. 
The `SaslSubjectBuilder` is an opt-in API which may be supported by SASL authentication plugins, but does not have to be.

/**
 * <p>Builds a {@link Subject} based on information available at the transport layer,
 * before any requests have been received from the client.</p>
 *
 * <p>A {@code TransportSubjectBuilder} instance is constructed by a {@link TransportSubjectBuilderService},
 * which in turn is specified on a virtual cluster.</p>
 *
 * <p>See {@link SaslSubjectBuilder} for a similar interface use for building a {@code Subject} based on SASL authentication.</p>
 */
public interface TransportSubjectBuilder {

    /**
     * Returns an asynchronous result which completes with the {@code Subject} built
     * from the given {@code context}.
     * @param context The context of the connection.
     * @return The Subject. The returned stage should fail with an {@link SubjectBuildingException} if the builder was not able to
     * build a subject.
     */
    CompletionStage<Subject> buildTransportSubject(Context context);

    interface Context {
        /**
         * @return The TLS context for the client connection, or empty if the client connection is not TLS.
         */
        Optional<ClientTlsContext> clientTlsContext();
    }
}


```java
package io.kroxylicious.proxy.internal.subject;
/**
 * <p>Builds a {@link Subject} based on information available from a successful SASL authentication.</p>
 *
 * <p>A {@code SaslSubjectBuilder} instance is constructed by a {@link SaslSubjectBuilderService}.</p>
 *
 * <p>A SASL-authenticating {@link io.kroxylicious.proxy.filter.Filter Filter}
 * <em>may</em> use a {@code SaslSubjectBuilder} in order to construct the
 * {@link Subject} with which it calls
 * {@link io.kroxylicious.proxy.filter.FilterContext#clientSaslAuthenticationSuccess(String, Subject)
 * FilterContext.clientSaslAuthenticationSuccess(String, Subject)}.
 * As such, {@code SaslSubjectBuilder} is an opt-in way of decoupling the building of Subjects
 * from the mechanism of SASL authentication.
 * SASL-authenticating filters are not obliged to use this abstraction.</p>
 *
 * <p>{@link TransportSubjectBuilder} is a similar interface use for building a
 * {@code Subject} based on transport-layer information.
 * However, note that a {@code SaslSubjectBuilder} is not specified directly
 * on a virtual cluster as a {@code TransportSubjectBuilder} is.</p>
 */
public interface SaslSubjectBuilder {

    /**
     * Returns an asynchronous result which completes with the {@code Subject} built
     * from the given {@code context}.
     * @param context The context of a successful SASL authentication.
     * @return The Subject. The returned stage should fail with an {@link SubjectBuildingException} if the builder was not able to
     * build a subject.
     */
    CompletionStage<Subject> buildSaslSubject(SaslSubjectBuilder.Context context);

    /**
     * The context that's passed to {@link #buildSaslSubject(Context)}.
     */
    interface Context {
        /**
         * @return The TLS context for the client connection, or empty if the client connection is not TLS.
         */
        Optional<ClientTlsContext> clientTlsContext();

        /**
         * @return The SASL context for the client connection.
         */
        ClientSaslContext clientSaslContext();
    }
}
```

A default implmentation of each of these interfaces will be provided.
This will support some simple string operations on the TLS subject DN, the TLS SANs or the SASL `authorizedId`.
Alternative implementation can be provided at runtime.


### `kroxylicious-authorizer` -- the `Authorizer` interface

The `Authorizer` interface is quite general and is modelled on Apache Kafka's authorizer, but with some differences:

```java
package io.kroxylicious.authorizer.service;

public interface Authorizer {

    /**
     * Determines whether the given {@code subject} is allowed to perform the given {@code actions}.
     * The implementation must ensure that the returned authorization partitions all the given {@code actions}
     * between {@link AuthorizeResult#allowed()} and {@link AuthorizeResult#denied()}.
     * @param subject The subject.
     * @param actions The actions.
     * @return The outcome. The returned stage should fail with an {@link AuthorizerException} if the authorizer was not able to
     * make a decision.
     */
    CompletionStage<AuthorizeResult> authorize(Subject subject, List<Action> actions);
    
    /**
     * <p>Returns the types of resource that this authorizer is able to make decisions about.
     * If this is not known to the implementation it should return empty.</p>
     *
     * <p>This is provided so that an access control policy enforcement point can confirm that it
     * is capable of providing access control to all the resource types in the access control policy
     * backing this authorizer.</p>
     *
     * @return the types of resource that this authorizer is able to make decisions about.
     */
    Optional<Set<Class<? extends ResourceType<?>>>> supportedResourceTypes();
}
```

Note:
* The asynchronous return type is intended to permit implementations using technologies such as [OPA][OPA] or [OpenFGA][OpenFGA], which would otherwise need to block the thread making the decision over the network.
* Because of the possibility of higher latency authorizer implementations, call sites should try to pass as many `actions` as possible so as to benefit from batching requests.
* Unlike Apache Kafka we don't currently include in the Authorizer the responsibility to audit log authorization attempts.

An `Action` describes something the subject may be attempting to do:

```java
public record Action(
                     ResourceType<?> resourceType,
                     String resourceName) { ... }
```

Where `ResourceType` has this declaration:

```java
/**
 * A {@code ResourceType} is an {@code enum} of the possible operations on a resource of a particular type.
 * We use a one-enum-per-resource-type pattern so that the {@link Class} an implementation also
 * serves to identify the resource type.
 * For this reason, implementations of this interface should be named for the type of resource
 * (for example {@code Topic}, or {@code ConsumerGroup}) rather than the operations
 * enumerated (so not {@code TopicOperations} or {@code ConsumerGroupOperations}).
 * @param <S> The self type.
 */
public interface ResourceType<S extends Enum<S> & ResourceType<S>> {
    /**
     * Returns a set of operations that are implied by this operation.
     * This must return the complete transitive closure of all such implied operations.
     * In other words, if logically speaking {@code A} implies {@code B}, and {@code B} implies {@code C} then
     * programmatically speaking {@code A.implies()} must contain both {@code B} <em>and {@code C}</em>.
     * @return The operations that are implied by this operation.
     */
    default Set<S> implies() {
        return Set.of();
    }
}
```

The scary-looking type parameter bound means a `ResourceType` implementation must be an `enum` rather than `class`, `interface`, etc.
The `enum`'s elements are the operations that a particular resource type supports. 
We would model a Kafka topic like this:

```java
enum Topic implements ResourceType<Topic> {
    READ,
    WRITE,
    CREATE,
    // ...
}

The `java.lang.Class` of a particular `ResourceType` then serves to identify the type of a resource in the API.
In this way, the `Action` instance for describing a topic called "foo" would be created like so:

```java
new Action(Topic.DESCRIBE, "foo")
```

The `AuthorizeResult` type provides access to the decisions about each of the actions in the query to `Authorizer.authorize()`.
That is, `Authorizer.authorize()` partitions its `actions` argument into the `allowed` and `denied` lists of the returned `AuthorizeResult`.

```java
public enum Decision {
    ALLOW,
    DENY;
}

public class AuthorizeResult {
                            
	AuthorizeResult(
		Subject subject,
		List<Action> allowed,
		List<Action> denied) {
        // ...
    }

    public Decision decision(ResourceType<?> operation, String resourceName) { ... }
    
    /**
     * Partitions the given {@code items}, whose names can be obtained via the given {@code toName} function, into two lists
     * based on whether the {@link #subject()} is allowed to perform the given {@code operation} on them.
     * @param items The items to partition
     * @param operation The operation
     * @param toName A function that returns the name of each item.
     * @return A pair of lists of the items which the subject is allowed to, or denied from, performing the operation on.
     * It is guaranteed that there is always an entry for both {@code ALLOW} and {@code DENY} in the returned map.
     * @param <T> The type of item.
     */
    public <T> Map<Decision, List<T>> partition(Collection<T> items, ResourceType<?> operation, Function<T, String> toName) { ... }
}
```

### The `kroxylicious-authorizer-acl` module

The new `kroxylicious-authorizer-acl` module will provide a implementation of `Authorizer` using an Access Control List (ACL), called `AclAuthorizer`.
The ACLs will be defined in a file (external to the proxy configuration file) which enumerates _who_ is allowed to do _what_.
The formal syntax of the file will be defined by an [ANTLR][ANTLR] grammar, 
but for the purposes of this proposal it is easier describe the structure using examples.

The AclAuthorizer will be:
* deny-by-default. 
* agnostic of any particular `Principal` implementations
* agnostic of any particular `ResourceType` implementations

Being agnostic about `Principal` and `ResourceType` implementations means the `AclAuthorizer` can more easily be reused in other filters in the future, but it means the user needs to define their types when they write the file. 
They do this using a `from ... import ...` statement:

```
from org.example.principals import User;
from org.example.resources import Topic ;
// ...
```

A simple `allow` rule looks like this:

```
// ...
allow User with name = "Alice" to READ Topic with name = "foo";
otherwise deny;
```

The file must end with `otherwise deny;`. 
This makes the deny-by-default nature of the rules explicit and allows easy detection of truncated files.

To avoid having to enumerate every combination of allowed subject, resource and operation, the syntax supports rules which select multiple resources at once:

* All resources of a given type can be selected:
    ```
    allow User with name = "Alice" to READ Topic with name *;
    ```

* Resources of a given type can be selected if their name is `in` a set literal:
    ```
    allow User with name = "Alice" to READ Topic with name in {"foo", "bar"};
    ```

* Resources of a given type can be selected if their name starts with a given prefix:
    ```
    allow User with name = "Alice" to READ Topic with name like "foo*";
    ```
    Note that the wildcard `*` is only permitted at the end of the prefix.

* Resources of a given type can be selected if their name matches a given regular expression literal:
    ```
    allow User with name = "Alice" to READ Topic with name matching /(foo+|bar)/;
    ```
    Note that regex based matching will generally scale less well (in terms of number of rules) than the other selection methods, 
    so the other methods should be used where possible.

Similarly, we can select multiple operations at once:

* All operations of a given resource type can be selected:
    ```
    allow User with name = "Alice" to * Topic with name = "foo";
    ```
* Operations of a given resource type can be selected by name with a set literal:
    ```
    allow User with name = "Alice" to {READ, WRITE} Topic with name = "foo";
    ```

Finally, it's also possible to select multiple principals at once:

* All subjects with a given principal type can be selected:
    ```
    allow User with name * to READ Topic with name = "foo";
    ```
    Note that the principal must have a `name` to match this rule; it does **not** match anonymous `Users`.
    
* Subjects which are anonymous in some given principal type can be selected:
    ```
    allow anonymous User to READ Topic with name = "foo";
    ```
    This means that none of the subject's principals are of type `User`.

* All subjects with a given principal type and a name starting with a given prefix can be selected:
    ```
    allow User with name like "Alice*" to READ Topic with name = "foo";
    ```
    (Note that the wildcard `*` is only permitted at the end of the prefix).
    
All these multiple selection features can be used simultaneously in a single rule, for example:

```
allow User with name * to * Topic with name *;
```

Sometimes it is useful to grant access widely, but with some narrower exceptions.
To avoid having to enumerate _exactly_ the access which should be allowed, `deny` rules are also supported.
For example, the following rules grant everyone _except_ that troublemaker Eve access to do anything with any topic:

```
deny User with name = "Eve" to * Topic with name *;
allow User with name * to * Topic with name *;
otherwise deny;
```

The syntax requires that `deny` rules must come before `allow` rules. 
This is to facilitate reading the rules: The first matching rule is the one which applies.

Validation checks on the rule file will be performed at start up. These include things like:
* checking that the imported principal and resource classes exist and extend the expected Java types
* checking that regular expressions are syntactically correct

### Request authorization

The `Authorization` filter will intercept all request messages that perform an action on a resource, and all response messages that refer to resources.

On receipt of a request message from the downstream, the filter will use the configured authorizer to make an access decision.
As a general rule, a Kafka broker does not fail requests atomically.
For example if a request refers to two topics and the subject is allowed access to one but not the other, then the request for the allowed topic will ba processed. The denied topic will be included in the response with a topic-level error code.
The filter will replicate this behaviour.
It will partition resources in a request by `Decision`, forwarding only those where the decision was `ALLOW`. When handling the response, it will add the resources where the decision was `DENY`, using an appropriate error code.

### Authorized operations

Some Kafka responses contain authorized operations values (originally introduced by [KIP-430][KIP-430]).
These give the client a way to know which operations are supported for a resource without having to try the operation.
Authorized operation values are bit fields where each position in the bitfield corresponds to a different operation.
The broker computes authorized operations values only when requested.  The client sets an include authorized operations flag in the request
and the broker then computes the result which is returned in the response.

If authorized operation values present in the response (`>0`), the filter must compute the effective authorized operations values
given both the value returned from the upstream and authorized operation value computed for the ACLs imposed by itself.
The response must be updated with the effective value before it is returned to the client.
This equates to a bitwise-AND operation on the two values.


### Operation/Resource Matrix

For the initial version, the system will be capable of making authorization decisions for topic operations and cluster connections only.
Future versions may support authorization decisions for other Kafka resources types (e.g. consumer group and transactional id).
The Authorizer will be designed to be open for extension so that it may be used to make authorization decisions about other entities (beyond those defined by Apache Kafka).

The table below sets out the authorization checks and filters will be implemented initially.

| Operation | Resource Type | Kafka Message                                                                                                                                                                                                          |
|-----------|---------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| READ      | Topic         | Fetch, ShareFetch, ShareGroupFetch, ShareAcknowledge, AlterShareGroupOffsets, DeleteShareGroupOffsets, OffsetCommit, TxnOffsetCommit, OffsetDelete                                                                     |
| WRITE     | Topic         | Produce, InitProducerId, AddPartitionsToTxn                                                                                                                                                                            |
| CREATE    | Topic         | CreateTopics                                                                                                                                                                                                           |
| DELETE    | Topic         | DeleteTopics                                                                                                                                                                                                           |
| ALTER     | Topic         | AlterConfigs, IncrementalAlterConfigs, CreatePartitions                                                                                                                                                                |
| DESCRIBE  | Topic         | ListOffset, OffsetFetch, OffsetFetchForLeaderEpoch DescribeProducers, ConsumerGroupHeartbeat, ConsumerGroupDescribe, ShareGroupHeartbeat, ShareGroupDescribe, MetaData, DescribeTopicPartitions, ConsumerGroupDescribe |
| CONNECT   | Cluster       | SaslAuthenticate                                                                                                                                                                                                       |

# Fail-closed behaviours

Extending the API coverage of the filter over multiple releases brings a compatibility wrinkle.
Consider an ACL rules file for version X which contains rules for `Topic` resources.
When upgrading to version Y > X where the filter has gained support for rules on `ConsumerGroup` resources an unmodified rules file would deny-by-default any APIs which refer to groups. 

While inconvenient (the user will need to add additional rules to their file), this behaviour is consistent with avoiding inadvertant information disclosure.

However, there's a further wrinkle: What about ACL rules files which contain rules about resource types which are not-yet supported, such as `TransactionalId`? From an end user's point of view they have an access control for transactional ids. But the filter is not actually enforing this access control. To avoid this the `Authorzation` filter will check that its configured rules file only refers to the resource types it is actually providing enforcement over. It will use the `Authorizer.supportedResourceTypes()` method to enforce this check.

Finally we need to consider evolution of the Kafka protocol itself. Even a complete and bug-free `Authorization` filter implementation could cease to provide complete control if:

* A new version of a Kafka API starts to refer to a resource (such as a `Topic`) which the filter was not coded to handle.
* A new API is added which refers to a resource (such as a `Topic`) which the filter was not coded to handle (consider as an example the addition of the Share Groups RPCs).

For this reason the `Authorization` filter will use strict controls over what APIs and API versions it supports, and will reject requests which don't meet these criteria.

The combination of these behaviours should provide good guarantees that the rules configured by the end user are actually being understood and honoured by the filter, even as both it and the Kafka protocol itself evolves.

# Kafka equivalence

In general, the `Authorization` filter will make access decisions in the same manner as Kafka itself.  This means it will apply the same authorizer checks that Kafka enforces itself and generate error responses in the same way.  It will
From the client's perspective, it will be impossible for it to distinguish between the proxy and kafka cluster itself.
It will also use the same implied operation semantics as implemented by Kafka itself, such as where `ALTER` implies `DESCRIBE`, as described by 
`org.apache.kafka.common.acl.AclOperation`.

There is one deviation.  The filter will implement a `CONNECT` authorization check on the `CLUSTER` early, as the connection is made, once the principal is known.  This allows the Authorizer filter to be used to gate access to virtual clusters.
* In the case of SASL, this will be performed on receipt of the Sasl Authentication Response.  If the authorization check fails, the authentication will fail with an authorization failure and the connection closed.
* In case of TLS client-auth, this will be performed on receipt of the first request message.   If the authorization check fails, a short circuit response will be sent containing an authorization failure and the connection closed.  This feature won’t be part of the initial scope.

The filter will support messages that express topic identity using topic ids (i.e. those building on [KIP-516][KIP-516]).  It will resolve the topic id into a topic name before making the authorization check.


### Configuration

```yaml
filterDefinitions:
   # ...
  - name: authz
    type: Authorization
    config:
      authorizer: AclAuthorizer
      authorizerConfig:
        rulesFile: /path/to/file.rules
```

Because the `SubjectBuilder` is configured at the virtual cluster level, it is possible for a filter to be referenced in a virtual cluster which uses a subject builder which yields Subjects that are incompatible with the `Authorization` filter. 
Due to the deny-by-default nature of the AclAuthoriser this configuration problem is not a security problem (access cannot be allowed by accident).
It would be nice if this situation could be detected and warned about during proxy start up. 
However, there is no obvious way to do this.
The AclAuthorizer could emit a warning log message if a Subject lacked _any_ of the principal types imported in the rule file.
However, it's not clear at this time that this is worth checking on _every request_.
So in this proposal we leave this problem unaddressed.


## Affected/not affected projects

The kroxylicious repo.

## Compatibility

The changes described in this proposal are backwards compatible.

## Rejected alternatives

### Reuse of the Kafka ACL interfaces/enumerations

The Kafka Client library includes interfaces and enumeration such as `org.apache.kafka.server.authorizer.Action`
and `org.apache.kafka.common.acl.AclOperation`.  It would be technically possible to base the Authorizer's interfaces
on these types.  This would have the advantage that it would help ensure that the ACL model of the Proxy followed
that of Kafka, but it would have also meant restricting the Authorizer to making access control decisions for the same
entities as Kafka does.  We want to leave open the possibility to make access decisions about other resource types, beyond
those considered by Kafka today (such as record-level ACLs).


[prop-5]: https://github.com/kroxylicious/design/blob/main/proposals/005-filter-api-to-expose-client-and-server-tls-info.md
[prop-6]: https://github.com/kroxylicious/design/blob/main/proposals/006-filter-api-to-expose-client-sasl-info.md
[KIP-430]: https://cwiki.apache.org/confluence/display/KAFKA/KIP-430+-+Return+Authorized+Operations+in+Describe+Responses
[KIP-516]: https://cwiki.apache.org/confluence/display/KAFKA/KIP-516%3A+Topic+Identifiers
[ANTLR]: https://www.antlr.org/
[OPA]: https://www.openpolicyagent.org/
[OpenFGA]: https://openfga.dev/
[TLS_MAPPING]: https://kafka.apache.org/documentation.html#security_authz_ssl
[SASL_MAPPING]: https://kafka.apache.org/documentation.html#security_authz_sasl
