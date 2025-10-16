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

To do this we will use a similar model to JAAS, but using our own types:

```java
package io.kroxylicious.proxy.authentication;

/**
 * <p>Represents an actor in the system.
 * Subjects are composed of a set of identifiers represented as {@link Principal} instances.</p>
 *
 * <p>The principals chosen depend on the calling code, but in general might comprise the following:</p>
 * <ul>
 * <li>information proven by a client, such as a SASL authorized id,</li>
 * <li>information known about the client, such as the remote peer's IP address, 
       or obtained from some trusted source of information about users,</li>
 * <li>information provided by the client, such as its Kafka client id</li>
 * </ul>
 * <p>
 *     <strong>Security best practice says you should only trust information that's proven about the client.</strong>
 *     However, it is sometimes useful to have access to the other information for making policy decisions.
 *     An example would be to deny a misbehaving client application identified by a
 *     (authorized id, client id)-pair from connecting to a cluster while the underlying problem is fixed.
 *     Such a decision narrows access to a client based on untrusted information (the client id)
 *     to a client which would otherwise be allowed access (based on the SASL authorized id) on
 *     the premise that such a client is not malicious, merely misbehaving.
 *     Crucially, this kind of usage does not <em>expand access</em> to clients based on that <em>untrusted information</em>.
 * </p>
 *
 * @param principals
 */
public record Subject(Set<Principal> principals) { ... }


/**
 * A typed identifier held by a {@link Subject}.
 * The fully qualified java class name of concrete implementation classes are used to externally identify the type of principal.
 * For example a plugin might supply implementation classes {@code com.example.kafka.proxy.auth.User} and 
 {@code com.example.kafka.proxy.auth.Role} which are treated as distinct namespaces for the 
 names of their instances: {@code User("foo")} and {@code Role("foo")} are two different things.
 */
public interface Principal {
    /** 
     * The name of the principal.
     * The empty string should be used for types of principal which are global therefore lack a natural identifier.
     * An empty Optional indicates an anonymous instance of this kind of principal.
     */
    Optional<String> name();
}

public class User implements Principal {
    public static final User ANONYMOUS = new User(null);
    
    Optional<String> name;
    
    public User(@Nullable String name) {
        this.name = Optional.ofNullable(name);
    }
    
    Optional<String> name() {
        return this.name;
    }
    
}
```

A filter will be able to obtain the `Subject` from the `FilterContext`:

```java
package io.kroxylicious.proxy.filter;

public interface FilterContext {
    // ... existing methods ...
    
    // new method:
    CompletionStage<Subject> authenticatedSubject();
}
```

The asynchronous result type allows a subject to be built using information obtained over the network, for example role/group information obtained from Active Directory/LDAP.

### Support for TLS and SASL subjects in `kroxylicious-runtime`

Eventually we expect to make the creation of the `Subject` instances exposed through `FilterContext.authenticatedSubject()` to be pluggable.
But initially the `SubjectBuilder` interface will be internal to the `kroxylicious-runtime` module.
It looks like this:

```java
package io.kroxylicious.proxy.internal.subject;
/**
 * Builds a {@link Subject} based on information
 * proven by, known about, or provided by it.
 */
public interface SubjectBuilder {

    CompletionStage<Subject> buildSubject(Context context);

    interface Context {
        Optional<ClientTlsContext> clientTlsContext();

        Optional<ClientSaslContext> clientSaslContext();
        
        String sessionId();
    }
}
```

The default `SubjectBuilder` will return `Subjects` with a singleton `principals` set whose element is an anonymous `User`.
In addition to the default subject builder we will support two other `SubjectBuilders` within the `kroxylicious-runtime`:
1. A builder called `Tls`, which will return `Subjects` with a `User` based entirely on TLS client certificate information 
2. A builder called `Sasl`, which will return `Subjects` with a `User` based entirely on the SASL authorized id.

The user will be able to configure a virtual cluster with one of these subject builders:

```yaml
virtualClusters:
  - name: whatever
    subjectBuilder:
      type: Tls
      config:
        subjectMappingRules:
          - RULE:^CN=(.*?),OU=ServiceUsers.*$/$1/
          - RULE:^CN=(.*?),OU=(.*?),O=(.*?),L=(.*?),ST=(.*?),C=(.*?)$/$1@$2/L
          - RULE:^.*[Cc][Nn]=([a-zA-Z0-9.]*).*$/$1/L
          - DEFAULT
    filters:
      - authn
      - authz
    # ...
```
In other words, all the filters in a virtual cluster will share a common "shape" of `Subjects` based on the `subjectBuilder`.
Filter implementations which consume the `FilterContext.authenticatedSubject()` will be able to query the `principals` is contains 
and make policy decisions based on the presence or absence of particular principal types or (principal type, name) pairs.

The `Tls` builder will support the same [mapping rules as Apache Kafka][TLS_MAPPING], and also the ability to create principals 
from the subject alternative names (with the same regex-based mapping supported).

The `Sasl` builder will support the same [mapping rules as Apache Kafka][SASL_MAPPING].


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
     * @return The outcome.
     */
    CompletionStage<AuthorizeResult> authorize(Subject subject, List<Action> actions);
    
    /**
     * All the resource types supported by this authorizer.
     */
    Set<Class<?>> resourceTypes();
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
 * Interface to be implemented by {@code enum} types which represent a type of resource, such as a 
 * Kafka topic or consumer group. The enum elements represent the operations that instances of that resource type support.
 * For example a Kafka topic supports a CREATE, DESCRIBE, READ and WRITE operations (among others).
 */
public interface ResourceType<V extends Enum<V> & ResourceType<V>> { ... }
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

    public Decision decision(Operation<?> operation, String resourceName) { ... }
    
    // ...
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
They do this using an `import` statement:

```
import User from org.example.principals;
import Topic from org.example.resources;
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

# Fail-safe behaviours

Extending the API coverage of the filter over multiple releases brings a compatibility wrinkle.
Consider an ACL rules file for version X which contains rules for `Topic` resources.
When upgrading to version Y > X where the filter has gained support for rules on `ConsumerGroup` resources an unmodified rules file would deny-by-default any APIs which refer to groups. 

While inconvenient (the user will need to add additional rules to their file), this behaviour is consistent with avoiding inadvertant information disclosure.

However, there's a further wrinkle: What about ACL rules files which contain rules about resource types which are not-yet supported, such as `TransactionalId`? From an end user's point of view they have an access control for transactional ids. But the filter is not actually enforing this access control. To avoid this the `Authorzation` filter will check that its configured rules file only refers to the resource types it is actually providing enforcement over. It will use the `Authorizer.resourceTypes()` method to enforce this check.

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
