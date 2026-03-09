# Audit logging

The proposal is for centralized audit logging within the proxy.

## Current situation

Currently, the proxy has no organized audit logging. 
Security-related events are logged though the same SLF4J API used for general application logging.
Someone deploying the proxy would need to:

* know which logger names contained security-related events (these are not documented).
* handle the fact that non-security relevant messages may be emitted through those loggers.
* handle the fact that the security relevant messages emitted through those loggers are not structured.
* accept the maintenance burden implied by the fact that the log messages are not considered part of the proxy API
  — for example, it's possible that the same logical event type emitted via logger A gets emitted via logger B in a later version, due to internal refactoring. 
* use custom plugins to generate logging messages for which there is no existing logging in place. 
  This might not even be possible if the events are only really visible within the runtime.

Overall this results in:
* a poor user experience in getting anything set up in the first place 
* ongoing fragility once set up (due to the API aspect) 

## Motivation

We want to make security audit logging a first-class responsibility of the proxy.

### Goals

* Emit an audit trail of security-relevant events from the runtime for security and compliance purposes.
* Plugins can contribute events to the audit stream.
* The events represent **actions that the proxy has taken** along with their outcome.
* The events are structured and amenable to automated post-processing
* The events are an API of the project, with the same compatibility guarantees as other APIs
* Provide an API for emitting actions which can be extended in the future.
* Provide a built-in implementation which emits JSON-encoded actions as application logging messages at info level to the `audit` logger. Disabled by default.
* Define an initial set of actions to be emitted .

### Non-goals

* Replace application logging or reinvent a logging facade (e.g. SLF4J). 
* Reinvent tracing (e.g. OTel). 
* Replace Kafka's own logging and auditing functionality. The audit trails from both systems should be used in conjunction.
* Making the emitted audit log tamper-resistent or verifiable. This depends on action serialization and as such is an implementation detail of an emitter.
* Deeper integrations with specific SIEM systems or audit log standard: This proposal is primarily about APIs which enable such integations, not providing such integrations themselves.

## Proposal

We can break down the proposal into the following parts:

1. The API of the actions that the proxy can emit. For example the proxy making a connection to a broker in a target cluster.
2. The API used by plugins which are reporting auditable actions. This is necessary because some actions of interest are taken by plugins rather than the proxy runtime. For example, a plugin making an authorization decision about access to a Kafka topic.
3. The `Emitter` API, through which the auditable actions are make visible outside a proxy process. 
4. The configuration API of an `Emitter` implementation which renders the auditable actions as JSON and logs them using the application logging stack.

We describe these parts in the following sections.

#### The API of the actions

Let's start with some key ideas:

* At a high level, each action is a fact descibing **who** has attempted to do **what** on **which** object, **when** they did this, and **what** was the outcome.
  The reason for this is it makes it easy to perform common queries against actions without having to know the schema or semantics for each type of action. 
* Each audit action represents _one_ action on _one_ resource. 
  Again, this is to simplfy querying for actions which match common criteria.
* When a single event (such as the arrival of a batched client request) relates to several objects we will emit multiple _correlated_ actions.

##### `BaseAction`

We will now elaborate on these ideas while progressively building out the API of the `BaseAction` type.

```java
/** 
 * Describes an auditable action taken by the proxy or one of its plugins.
 * Action implementations must extend {@link java.lang.Record}. 
 * Implementations records should avoid declaring components beyond those required by the methods in this interface. 
 * They should instead make use of the {@link context()} method.
 */
interface BaseAction {
    // ...
}
```

Constaining BaseAction implementations to be `record` classes ensures that there is a uniform way to generically operate on actions (in terms of their components). 
This enabled desirable functionality such as a guarantee that actions are JSON-serializable.

##### When

**When** is simply _when the action happened_. It is modelled trivially:

```java
interface BaseAction {
    /** When the event happened. */
    Instant time();
    
    // ...
}
```

##### What
 
**What** encompasses _what action was attempted_, and whether it was _performed successfully_.

```java
interface BaseAction {

    // ...

    /** The type of the event. */
    default String action() { 
        return getClass().getName();
    }
    
    String status(); // null means "ok", otherwise a machine-readable status, This might be an exception class name or a Kafka error code
    String reason(); // optional human-readable reason for the status
        
    // ...
}
```

##### Who

**Who** covers the _actor that initiated the action_. 
Modelling this accurately is a little complex.
The first complication is that Kafka client applications, Kafka brokers and the proxy itself can all initiate actions. 
The second complication is that prior to authentication the proxy knows has a network-level understanding of actors;
later on, the proxy might become aware of application-level actors (principals).

```java
interface BaseAction {

    // ...

    /** 
     * Return the actor that initiated the action.
     */
    Actor actor();
        
    // ...
}

/** 
 * An actor that has performed an auditable action.
 * Implementation are required to extend `java.lang.Record`. 
 */
interface Actor {}

```

* `Actor` is a `non-sealed` `interface` so that it's possible to for set set of actors to be extened either by plugins or by the runtime at a later time.
* We constain implementations to be `record` classes. 
  This is to make it easier to write emitters which handle actions generically without having to be aware of the complete set of Actor types in use.
  For example, this simplfies serializing actors to JSON without needing to use serialization-specific mechansims like annotations. 

Let's enumerate the actors used by the runtime:

```java

/** 
 * An actor representing the proxy itself, or a plugin.
 * @param pluginType The type of plugin when the actor is a proxy plugin, otherwise null.
 * @param pluginName The name of plugin when the actor is a proxy plugin, otherwise null.
 */
record SelfActor(@Nullable String pluginType, @Nullable pluginName) implements Actor {}

/** 
 * An actor representing a Kafka client application.
 */
record ClientActor(NetworkAddress addr, String session, @Nullable Subject subject) implements Actor {}

/** 
 * An actor representing a Kafka server/broker.
 */
record ServerActor(NetworkAddress addr, String hostname, @Nullable Integer nodeId) implements Actor {}
``` 

The `SelfActor` can be useful for actions which happen outside of the context of a Kafka request or response. 
This could be used as the actor for applications startup and shutdown events.

The `ClientActor` can minimally represent a TCP client connected to the proxy by using the `attr` and `session` components.
This is the case for clients of the HTTP management server and for Kafka clients at the start of their session.
Once a Kafka client has authenticated we may become aware of the client's subject. 

Similarly the `ServerActor` can be used to represent the proxy's side of a connection to a server, 
including but not limited to a Kafka broker. 

##### Which
 
**Which** is about describing which object or resource is the _target of the action_.
As such we need a uniform coordinate system for such objects and resources.

In full generality, a pluggable proxy such as Kroxylicious can talk to systems other than a Kafka broker.
For example existing 1st party plugins make use of schema registries, and key management systems.
This means we need a coordinate system that is open: It should be able to describe objects that the runtime doesn't know about.
However, we don't want an API that is as heavyweight and difficult to use as X500-style Object Names.

Instead we propose a hierarchical naming schema which should about collisions in practice:
Which is about describing which object or resource is the target of the action.
As such we need a uniform coordinate system for such objects and resources.

In full generality, a pluggable proxy such as Kroxylicious can talk to systems other than a Kafka broker.
For example existing 1st party plugins make use of schema registries, and key management systems.
This means we need a coordinate system that is open: It should be able to describe objects that the runtime doesn't know about.
However, we don't want an API that is as heavyweight and difficult to use as X500-style Object Names.

Instead we propose a flattened map structure which avoids collisions in practice while keeping JSON payload size minimal and SIEM queries intuitive:
Java

```java
interface BaseAction {

    // ...
    
    /**
     * The coordinates of the target object. 
     * The keys represent the scope (e.g., "vc", "topicId"), and the values are the unique identifiers within that scope.
     * Multiple scopes should usually represent a hierarchy from largest to smallest.
     * For example the "vc" scope logically contains a sub-scopes for topic names, group ids, transactional ids, and so on.
     * Plugins providing their own coordinates should package-prefix their scope names.
     */
    Map<String, String> objectRef();
    
    // ...
}
```

Both scopes and ids are open for extension, subject to the following:

* `scope` can be nested. In order words the `topicName` scope makes no sense on its own, a `vc` coordinate must be included to make it unambiguous.
* An unique identifier must be unique within a `scope` at any given time. 
* A unique identifier may have stronger uniqueness properties (e.g. unique over time, rather than just instantaneously), but may not have weaker properties.

In this proposal we define the following scopes:

* `addr`: A network address.
* `vc`: A virtual cluster, as defined in the proxy's configuration.
* `tc`: A target cluster, as defined in the proxy's configuration.
* `nodeId`: A Kafka server with a cluster.
* `topicName` and `topicId`: A topic within a cluster. Either can be used. Both should be included if known.
* `groupId`: A group within a cluster.
* `transactionalId`: A transactional within a cluster.

##### Correlation

_Correlation_ is used when multiple actions result from a single initating event.

```java
interface BaseAction {

    // ...
    
    /** 
     * Contextual identifiers for correlating this action with external systems, 
     * client requests, or distributed traces.
     */
    Record correlation();
}

/**
 * Identifiers for correlating actions.
 * @param clientRequest The Kafka client's correlation ID (usually an Int32).
 * @param serverRequest The broker's correlation ID.
 */
record BaseCorrelation(
    @Nullable Integer clientRequest,
    @Nullable Integer serverRequest) {}
```

Because the notion of correlation is based on the initiator of the action we don't need different fields to represent the client's `correlationId` and the broker's `correlationId`. 
However, this means care should be taken that an action is an broker-initiated action before attempting to correlate it with an event in the the broker logs.

##### Context

_Context_ provides a single place for action-specific information which is under control of the people defining that kind of action.
This avoids the possibility of a conflict should a future proposal add to the core components/JSON properties described here.

```java
interface BaseAction {

    // ...
    
    /** 
     * Type-specific additional data about this action.
     * @returns additional data about this action, or null if there is no additional information.
     */
    @Nullable Record context();

```

This could be used to:
* Provide more detail about the _what_, such as providing the topic id as well as the name.
* Correlate to other systems than the Kafka broker. For example a plugin might add a `traceId` to link to an OTel trace.


#### Examples

Here are some examples of how certain actions would be rendered as JSON, based on the above Java schema.

##### `ClientConnect`

A client application connecting successfully to a proxy socket associated with a virtual cluster

```json
{
  "time": "20260313T12:30:00.000000",
  "action": "ClientConnect",
  "actor": {
    "addr": "123.123.123.123:32456", # the TCP client address
    "session": "1bd07921-c2b6-43a3-95f0-1c2244933aee"
  }
  "objectRef": {
    "vc": "my-cluster",
    "nodeId": "1"
  }
  # "status": "null" => success
}
```

It's worth noting that `ClientConnect` need not be associated with a particular virtual cluster. 
For example we could reuse the same action for HTTP connections to the management server: 
The `objectRef` might be:

```json
[
  { "scope": "addr"
    "id": "127.0.0.1:8080"
  }
]
```

##### `ClientAuthenticate`

Here's the same client application authenticating successfully:

```json
{
  "time": "20260313T12:30:00.001378",
  "action": "ClientAuthenticate",
  "actor": {
    "addr": "123.123.123.123:32456",
    "session": "1bd07921-c2b6-43a3-95f0-1c2244933aee" # same session => same client
    "principals": [ # The principals resulting from the successful authentication
      { "User": "alice" }
    ]
  }
  "objectRef": {
    "vc": "my-cluster",
    "nodeId": "1"
  }
  # "status": "null" => success
}
```

##### `Write`

And same client application being allowed access to topic 'foo' and denied access to topic 'bar' in a single produce request:

```json
# 1st action
{
  "time": "20260313T12:30:00.002840",
  "action": "Write",
  "actor": {
    "addr": "123.123.123.123:32456",
    "session": "1bd07921-c2b6-43a3-95f0-1c2244933aee"
    "principals": [
      { "User": "alice" }
    ]
  }
  "objectRef": {
    "vc": "my-cluster",
    "topicName": "foo"
  },
  "correlation": {
    "clientRequest": 4
  }
  # "status": "null" => success
}
# 2nd action
{
  "time": "20260313T12:30:00.002840",
  "action": "Write",
  "actor": {
    "addr": "123.123.123.123:32456",
    "session": "1bd07921-c2b6-43a3-95f0-1c2244933aee"
    "principals": [
      { "User": "alice" }
    ]
  }
  "objectRef": {
    "vc": "my-cluster",
    "topicName": "bar"
  },
  "correlation": {
    "clientRequest": 4, # the same correlation => same request
  },
  "status": "29"
  "reason": "Topic authorization failed."
}
```

Because a topic is not broker-local it is not necessary to include a "nodeId" in the "objectRef" in this case.

### The API used by plugins to report auditable actions

Kroxylicious allows plugins to determine behaviour. 
That means sometimes an auditable action is known only to a plugin.
The `Authorization` filter is a concrete example: It allows or denies client interactions with Kafka entities on the target broker, and the runtime doesn't have any visiblity into the decision or the outcome.
Another example would be the `RecordEncryption` filter recording the connections it makes to a KMS.

To enable uses like this we need an API through which such plugins can contribute their actions to the audit log.
Other filters may make use of this functionality where they need to record their auditable actions.

Plugins **should not** use this facility to record observations, for example, about what the broker or client is observed to have done.
* The broker is best placed to record its own actions.
* A proxy is poorly placed to provide an authoratative record of what the broker has actually done. 
  The 'two generals problem' means the proxy log cannot always be both complete and correct



```java
/**
 * A way to record an auditable action
 */
interface AuditLogger {
  /**
   * Record an auditable action that's be performed by the proxy.
   * Actions must not contain sensitive data such as passwords, PII or (generally speaking) data obtained from a Kafka Record.
   * @param action The action to be logged.
   */
  <A extends Record & BaseAction> void logAction(A action);
}
```

Using a dedicated type means that different plugin context interfaces (such as `FilterContext`) can expose an `AuditLogger`, and pass that logger on to any subplugins. 

The `FilterContext` will gain the following method:

```java

interface FilterContext {

    /** 
     * Get an audit logger for recording auditable actions.
     */
    AuditLogger auditLogger();
    
}
```

### Actions

Having seen some examples of how actions are modelled, let's enumerate the full set of actions the proxy runtime will support as a result of this proposal:

* `ProxyStartup` -- the proxy application starting
* `ProxyShutdown` -- the proxy application shutting down
* `VirtualClusterStart` -- a virtual cluster starting
* `VirtualClusterStop` -- a virtual cluster stopping
* `ClientConnect` -- a client connecting to the proxy
* `ClientClose` -- a client connection being closed
* `ServerConnect` -- the proxy connecting to a server
* `ServerClose` -- a server connection being closed
* `ClientAuthenticate` -- a client's subjects changing (e.g. via `FilterContext.clientSaslAuthenticationSuccess()` or successful TLS handshake) or an authentication failure (e.g. via `FilterContext.clientSaslAuthenticationFailure()` or a failed TLS handshake). Note that SASL Inspectors and SASL Terminators do not need to use `FilterContext.auditLogger()`, instead audit logging happens as a side-effect of calling `FilterContext.clientSaslAuthenticationSuccess()` and `FilterContext.clientSaslAuthenticationSuccess()`.

Additionally, the `Authorization` filter will add support an action for each of the operations it enforces:

* `Read`
* `Write`
* `Create`
* `Delete`
* `Alter`
* `Describe`
* `ClusterAction`
* `DescribeConfigs`
* `AlterConfigs`
* `IdempotentWrtie`
* `CreateTokens`
* `DescribeTokens`
* `TwoPhaseCommit`

### The `Emitter` Java API

```java
/**
 * Exposes auditable actions, or data derived from them, outside of this proxy process. 
 */
interface AuditEmitter extends AutoClosable {

  /** 
   * Emits the auditable action 
   * Implementations are expected not to block. 
   * If necessary they should handle their own asynchronous buffering.
   * @param action The action to be emitted.
   */
  <A extends Record & BaseAction> void emitAction(A action);
  
  public abstract void close();
}
```

The awkward-looking type parameter `<A extends Record & BaseAction>` provides type safety that actions really are `record` classes that implement  `BaseAction`.

Similarly to existing plugins we'll use the `ServiceLoader` mechanism is discover a factory class, instantiate it and use that to instantiate the emitter. 

```java
interface AuditEmitterFactory<C> {
    initialize(C configuration);
    AuditEmitter createEmitter();
}
```

A point of difference from other plugins is that the `AuditEmitter` has the `close()` method, and the factory does not. 
This is because the emitters are intentionally instantiated once on application startup and will not be dynamically reconfigurable.
This absence of reconfigurability makes it harder for an attacker to turn the logging off during an attack.

### The Emitter configuration API

Emitters will specified in the proxy configuration in a new top-level `audit` property.
Here's an example:

```yaml
audit:
  - name: my-emitter
    type: MyCustomAuditEmitter
    config: 
      myCustomConfig: true
filterDefinitions:
  - name: encryption
    type: RecordEncryption
    config:
      # ...
virtualClusters:
# ...
```

The items in the `audit` array work exactly like `filterDefinitions`. 


### The `LoggingAuditEmitter` implementation

`LoggingAuditEmitter` will implement the `AuditEmitter` interface. 
It will simply render the actions as JSON and log them at `info` level using the proxy's application logging stack.
It will not require or allow any configuration.


## Affected/not affected projects

This proposal covers the proxy.

## Compatibility

* This change is backwards compatible.
* This change adds a new APIs (specifically the schema of the events), which future proposals will need to consider for compatibility.

## Rejected alternatives

* The null alternative: Do Nothing. This means users continue to have a poor and fragile experience which in itself could be grounds to not adopt the proxy.

* Just use the existing SLF4J application logging (e.g., with a logger named `audit` where all these events get logged). This approach would not:
    - in itself, guarantee that the logged event were structured or formatted as valid JSON.
    - be as robust when it comes to guaranteeing the API goal.
    - ensure that metrics and logging were based on a single source of truth about events
    - provide an easy way to add new emitters in the future.
  
* Use a different format than JSON.
  JSON is not ideal, but it seems to be a reasonable compromise for our purposes here. 
  For the SLF4J emitter we need something that is text-based. 
  Support for representing integer values requiring more than 53 bits varies between programming languages and libraries.
  Repeated object properties mean it can be space inefficient, though compression often helps.
  However, no other format is as ubiquitous as JSON, so using JSON ensures compatibility with the widest range of external tools and systems.



