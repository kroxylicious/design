# Audit logging

The proposal is for centralized audit logging within the proxy.

## Current situation

Currently, the proxy has no organized audit logging. 
Security-related events are logged though the same SLF4J API used for general application logging.
Someone deploying the proxy would need to:

* know which logger names contained security-related events (these are not documented)
* handle the fact that non-security relevant messages may be emitted through those loggers
* handle the fact that the security relevant messages emitted through those loggers are not structured
* accept the maintenance burden implied by the fact that the log messages are not considered part of the proxy API
* use custom plugins to generate logging messages for which there is no existing logging in place. 
  This might not even be possible if the events are only really visible within the runtime. 

Overall this results in:
* a poor user experience in getting anything set up in the first place 
* ongoing fragility once set up (due to the API aspect) 

## Motivation

We want to make security audit logging a first-class responsibility of the proxy.

Goals:

* enable users to _easily_ collect a _complete_ log of security-related events
* for the security events to be structured and amenable to automated post-processing
* for the security events to be an API of the project, with the same compatibility guarantees as other APIs

Non-goals:

* collecting events which are *not* security-related.
* create a replacement for a logging facade API (like the existing use of SLF4J already used by the proxy).

## Proposal

### Covered events

The events we define here aim to capture:
* who the client was (authentication)
* what the client tried to do (authorization)
* what a client actually did, in terms of writing, reading or deleting Kafka records.

It is not intended to provide a complete capture of the protocol-level conversation between the client, the proxy and the broker.

The logical event schemas described below contain the minimal information about that event. This keeps events as small as possible, at the cost of requiring event log post-processing to  reconstruct a complete picture.  

#### Proxy-scoped events

* `ProxyStartup` — Emitted when the proxy starts up, before it binds to any sockets.
    - `processUuid` — identifies this process uniquely in time and space.
    - `instanceName` — is optionally provided by the user to identify this instance.
    - `currentTimeMillis` — The number of milliseconds since the UNIX epoch.
    - `hostName` — The name of the host on which the proxy is running.   
* `ProxyCleanShutdown` — Emitted when the proxy shuts down normally. Obviously it's not possible to emit anything in the case of a crash (e.g. `SIGKILL`).
  The absence of a `ProxyCleanShutdown` in a stream of events with the same `processUuid`
  would indicate a crash (or that the process is still alive). 
    - `processAgeMicros` — The time of the event, measured as the number of microseconds since proxy startup.

#### Session-scoped events

Session-scoped events all have at least the following  attributes: 
- `processAgeMicros` — The time of the event, measured as the number of microseconds since proxy startup.
- `sessionId` — A UUID that uniquely identifies the session in time and space.

* `ClientAccept` — Emitted when the proxy accepts a connection from a client
    - `processUuid` — Allows sessions of the same proxy process to be correlated.
    - `virtualCluster` — The name of the virtual cluster the client is connecting to
    - `peerAddress` — The IP address and port number of the remote peer.
* `BrokerConnect` — Emitted when the proxy connects to a broker
    - `brokerAddress` — The IP address and port number of the remote peer.
* `ClientSaslAuthFailure` — Emitted when a client completes SASL authentication unsuccessfully
    - `attemptedAuthorizedId` — The authorized id the client attempted to use, if known.
* `ClientSaslAuthSuccess` — Emitted when a client completes SASL authentication successfully
    - `authorizedId` — The authorised id
* `OperationAllowed` — Emitted when an `Authorizer` allows access to a resource.
    - `op` — The operation that was allowed (e.g. `READ`)
    - `resourceType` — The type of the resource (e.g. `Topic`)
    - `resourceName` — The name of the resource (e.g. `my-topic`
* `OperationDenied` — Emitted when an `Authorizer` denies access to a resource.
    - `op` — The operation that was denied (e.g. `READ`)
    - `resourceType` — The type of the resource (e.g. `Topic`)
    - `resourceName` — The name of the resource (e.g. `my-topic`
* `Read` — Emitted when a client successfully reads records from a topic. It is called `Read` rather than `Fetch` because it covers reads generally, including the `ShareFetch` API key. It will be possible to disable these events, because of the potential for high volume. 
    - `topicName` — The name of the topic.
    - `partition` — The index of the partition.
    - `offsets` — Offsets are included so that it's possible to record exactly which data has been read by a client.

* `Write` — Emitted when a client successfully writes records to a topic. It is called `Write` rather than `Produce` for symmetry with `Read` (which also allows introduction of other produce-like APIs in the future). It will be possible to disable these events, because of the potential for high volume. 
    - `topicName` — The name of the topic.
    - `partition` — The index of the partition.
    - `offsets` — Offsets are included so that it's possible to record exactly which data has been read by a client.
* `ClientClose` — Emitted when a client connection is closed (whether client or proxy initiated)
* `BrokerClose` — Emitted when a broker connection is closed (whether broker or proxy initiated).
    

### Log emitter

We will provide an emitter which will simply emit the above events in JSON format to an SLF4J `Logger` with a 
given name (e.g. `security`).

The intent of offering this emitter is to provide the simplest possible mechanism for providing access to an audit log. It requires no additional infrastructure.


### Metric counting emitter

We will provide an emitter which increments a count the number of occurrences of each type of event and makes these available though the existing metrics scrape endpoint.
The metric name will be fixed, and metric tags will be used to distinguish the different event types.

The intent of offering this emitter is to provide a _simple_ way for users to set up basic alerting on security events, such as a sudden increase in the number of failed authentication attempts. 
A more detailed understanding would require consulting a log of security events obtained using one of the other emitters. 

### Kafka emitter

We will provide an emitter which produces the above events to a Kafka topic. 

The intent of offering this emitter is to decouple the proxy from systems consuming these security events, such as [SIEM systems](https://en.wikipedia.org/wiki/Security_information_and_event_management). 
For example, users or 3rd parties can provide their own Kafka Streams application 
which converts this message format to the format required by a SIEM, or perform aggregations 
to better understand the events (e.g. number of failed authentications in a 15-minute window).

The events will be JSON encoded.
The configuration for the producer will be configurable.
In particular, the bootstrap brokers for the destination cluster could be any of:

* An unrelated (not proxied) cluster,
* The address of one of the proxy's target clusters,
* The address of one of the proxy's virtual cluster gateways.

In the latter case the user would need to take care to avoid infinite write amplification, where a initial client activity generates audit records which themselves require auditing. This results in an infinite feedback cycle. 

A possible technical measure to avoid this infinite feedback would be to use a securely random `client.id` for the `KafkaProducer`, and intentionally not record security events associated with this `client.id`. However, this only works in the direct case. Infinite feedback would still be possible between two proxies each configured as the other's audit logging cluster.

The topic name will be configurable.
The partitioning of proxy-scoped events will be based on the proxy instance name.
The partitioning of session-scoped events will be based on the session id.
A total order for events from the same process will be recoverable using the `processAgeMicros`. The `processUuid` of the `ClientConnect` event allows for correlation of sessions from the same proxy instance stored in different topic partitions.

### APIs

Under this proposal the following new APIs would be established:

* The JSON representation of the events exposed via the SLF4J and Kafka emitters.
* The metric name and tag names exposed by the metrics emitter.

The future evolution of these APIs would follow the usual compatibility rules. 

## Affected/not affected projects

This proposal covers the proxy.

## Compatibility

* This change is backwards compatible.
* This change adds a new API (the schema of the events), which future proposals will need to consider for compatibility.

## Rejected alternatives

* The null alternative: Do Nothing. This means users continue to have a poor and fragile experience which in itself could be grounds to not adopt the proxy.

* Just use the existing SLF4J application logging (e.g., with a logger named `audit` where all these events get logged). This approach would not:
    - in itself, guarantee that the logged event were structured or formatted as valid JSON.
    - be as robust when it comes to guaranteeing the API goal.
    - ensure that metrics and logging were based on a single source of truth about events
    - provide the Kafka topic output included in this proposal
    - provide an easy way to add new emitters in the future.
  
* Use a different format than JSON.
  JSON is not ideal, but it seems to be a reasonable compromise for our purposes here. 
  For the SLF4J emitter we need something that is text-based. 
  Support for representing integer values requiring more than 53 bits varies between programming languages and libraries.
  Repeated object properties mean it can be space inefficient, though compression often helps.
  However, no other format is as ubiquitous as JSON, so using JSON ensures compatibility with the widest range of external tools and systems.

* Deeper integrations with specific SIEM systems.
  Having Kafka itself as an output provides a natural way to decouple the Kroxylicious project from having to provide SIEM integrations.
  The choice we're making in this proposal can be contrasted with the "batteries included" approach we've taken with KMSes in the `RecordEncryption` filter.
  Implementing a KMS (and doing so correctly) is fundamental to the `RecordEncryption` functionality, where the filter unavoidably needs to consume the services provided by the KMS.

    
