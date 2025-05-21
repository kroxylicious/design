<!-- This template is provided as an example with sections you may wish to comment on with respect to your proposal. Add or remove sections as required to best articulate the proposal. -->

# Improvements to Kroxylicious (Proxy) Metrics

The document aims to:

* describe the short-comings with the current metrics
* identify use-cases for Kroxylicious metrics
* propose improvements.

## Current situation

Currently, the proxy emits the following metrics:

| Metric                                           | Type         | Labels                                      | Description                                                                                                         |
|--------------------------------------------------|--------------|---------------------------------------------|---------------------------------------------------------------------------------------------------------------------|
| kroxylicious_inbound_downstream_messages         | Counter      | flowing, virtualCluster                     | Incremented by one every time every inbound RPC arriving _from the downstream only_. (*1)                           |
| kroxylicious_inbound_downstream_decoded_messages | Counter      | flowing, virtualCluster                     | Incremented by one every time every inbound RPC arriving _from the downstream that the proxy needs to decode_. (*1) |
| kroxylicious_payload_size_bytes                  | Distribution | flowing, virtualCluster, ApiKey, ApiVersion | Incremented with RPC's frame size for every _decoded_ RPC from either the _downstream or upstream_. (*2)            |
| kroxylicious_downstream_connections              | Counter      | flowing, virtualCluster                     | Incremented by one each time a connection arrives from the downstream                                               |
| kroxylicious_downstream_errors                   | Counter      | flowing, virtualCluster                     | Incremented by one each time a connection fails owning to a downstream error (dropped connection) (*3)              |
| kroxylicious_upstream_connections_attempts       | Counter      | flowing, virtualCluster                     | Incremented by one each time a connection attempt to made to the upstream.                                          |
| kroxylicious_upstream_errors                     | Counter      | flowing, virtualCluster                     | Incremented by one each time a connection attempt fails owning to a upstream error (tls negotiation etc)            |

### Specific short-comings/weaknesses

* *1 - these metrics record only the **requests**, there's nothing analogous that records the responses.
* *1 - these metrics aren't discriminated by ApiKey (etc.). This limits their usefulness for problem-solving.
* *2 - the metric name is quite misleading - nothing tells the user that it is only recording the sizes of RPCs that are actually **decoded**.
* *2 - there are no quantised buckets configured for this metric. it gives the user count/sum/max values only. it would be
  hard to use this metric to understand something about produce requests or fetch responses.
* *1 / *2 - we have contradictory meanings for the `flowing` label.  in *2, requests flow `UPSTREAM`, responses flow `DOWNSTREAM`.
  In *1 requests flow `DOWNSTREAM` which makes no sense.
* *3 - downstream errors does not record account for errors such as TLS negotiation errors or failures to determine virtual cluster or broker.  

### General short-comings/weaknesses

* The metrics endpoint populates `HELP` for each metric, but this is populated with nothing more than the metric's name.
  We ought to be giving a clear description of the metric.
* Some of the label names don't follow Prometheus naming conventions.  Prometheus recommends snake case whereas we have used camel case in some cases.

## Use Cases

In general, metrics exist to help a user understand the health and performance of the proxy. They help inform
capacity planning, drive system alerts reporting abnormal conditions and help with problem-solving (things like
diagnosing failures or system slow-downs).

Introducing a proxy to a Kafka system will increase latency of the system. Users will need a mechanism to understand how
much latency is being added for their particular use-cases and have the ability to monitor this latency over time.

Kroxylicious Filters themselves have the potential to alter behaviour of the Kafka system.  Users will need insights into
performance and other issues that might result from filter behaviour. Specifically:

* filters have the ability to change the size of the RPCs as they traverse the proxy (record encryption)
* filters have the ability to change the flow of messages within the Kafka system. Specifically, they can short-circuit
  requests by producing their own responses (the broker never sees the request) and introduce their own requests.

## Proposal

## Summary

The following metrics will be added.  They will each be described in more detail later in this section.

| Metric                                           | Type         | Labels                                                                                | Description                                                                             |
|--------------------------------------------------|--------------|---------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| kroxylicious_downstream_kafka_message_total      | Counter      | virtual_cluster, node_id†, flowing, api_key, api_version, opaque                      | Incremented by one every time a request comes from/response goes to the downstream.     |
| kroxylicious_upstream_kafka_message_total        | Counter      | virtual_cluster, node_id†, flowing, api_key, api_version, opaque, originating_filter† | Incremented by one every time a request goes to/response comes from the upstream.       |
| kroxylicious_downstream_kafka_message_size_bytes | Distribution | virtual_cluster, node_id†, flowing, api_key, api_version  opaque                      | Records the message size of every message coming from/response going to the downstream. |
| kroxylicious_upstream_kafka_message_size_bytes   | Distribution | virtual_cluster, node_id†, flowing, api_key, api_version, opaque, originating_filter† | Records the message size of every message coming from/response going to the upstream.   |
| kroxylicious_message_process_time                | Distribution | virtual_cluster, node_id†, flowing, api_key, api_version, opaque, originating_filter† | Records the time taken for the message to traverse the proxy                            |

The following metrics wil have changes to their labels.

| Metric                                        | Type    | Labels                     | Deprecated Labels | Description                                                                         |
|-----------------------------------------------|---------|----------------------------|-------------------|-------------------------------------------------------------------------------------|
| kroxylicious_downstream_connections_total     | Counter | virtual_cluster, node_id†  | virtualCluster    | Incremented by one every time a request comes from/response goes to the downstream. |
| kroxylicious_downstream_error_total           | Counter | virtual_cluster†, node_id† | virtualCluster    | Incremented by one every time a request goes to/response comes from the upstream.   |
| kroxylicious_upstreamstream_connections_total | Counter | virtual_cluster,  node_id† | virtualCluster    | Incremented by one every time a request comes from/response goes to the downstream. |
| kroxylicious_upstreamstream_error_total       | Counter | virtual_cluster,  node_id† | virtualCluster    | Records the time taken for the message to traverse the proxy                        |


The following metrics will be deprecated.

| Metric                                           |
|--------------------------------------------------|
| kroxylicious_inbound_downstream_messages         |
| kroxylicious_inbound_downstream_decoded_messages |
| kroxylicious_payload_size_bytes                  |


(† signifies labels that will be omitted in some circumstances. The circumstances are explained below).

### New counter `kroxylicious_downstream_kafka_message_total`

`kroxylicious_downstream_kafka_message_total` is incremented every time a message passes to/from the downstream.
It is discriminated by `virtual_cluster`, `node_id`, `flowing`, `opaque`, api_key`, and `api_version` labels.

`node_id` will only be present if for requests going to or responses coming from a broker.  For bootstrap interactions,
`node_id` will be absent.

`flowing` has two values - `upstream` signifies a request following towards the broker, `downstream` signifies a response
following towards the client.

Use cases that were previously served by the deprecated metrics `kroxylicious_inbound_downstream_messages` and
`kroxylicious_inbound_downstream_decoded_messages` can now use this metric instead.

### New counter `kroxylicious_upstream_kafka_message_total`

`kroxylicious_upstream_kafka_message_total` is incremented every time a message passes to/from the upstream.
It is discriminated by `virtual_cluster`, `node_id`, `flowing`, `opaque`, `api_key`, `api_version` and `originating_filter` labels.

`node_id` will only be present if for requests going to or responses coming from a broker.  For bootstrap interactions,
`node_id` will be absent.

`originating_filter` is only used for requests generated by the filters themselves (`sendRequest` API)
and their responses.  It will be populated with the filter's name. Otherwise `originating_filter` will be absent.
`originating_filter` supports the metrics use-cases where the requests sent by the filters themselves need to be understood.

### New distribution `kroxylicious_downstream_kafka_message_size_bytes`

`kroxylicious_downstream_kafka_message_size_bytes` records the message size of every message passing to/from the downstream.
It is discriminated by `virtual_cluster`, `node_id`, `flowing`, `opaque`, `api_key`, and `api_version` labels.  `node_id` will only
be present if for requests going to or responses coming from a broker.  For bootstrap interactions, `node_id` will be
absent.

Use cases that were previously served by the deprecated metric `kroxylicious_payload_size_bytes` can now use this metric
instead. The new metric records the size of both **opaque** and **decoded** messages allowing the user to understand the
number of bytes traversing the proxy.

### New distribution `kroxylicious_upstream_kafka_message_size_bytes`

`kroxylicious_upstream_kafka_message_size_bytes` records the message size of every message passing to/from the upstream.
It is discriminated by `virtual_cluster`, `node_id`, `flowing`, `opaque`, `api_key`, `api_version` and `originating_filter` labels.

`node_id` will only be present if for requests going to or responses coming from a broker.  For bootstrap interactions, `node_id` will be
absent.

`originating_filter` is only used for requests sent by the filters themselves (i.e. the `sendRequest` API)
and their responses.  It will be populated with the filter's name.  Otherwise `originating_filter` will be absent.

### New distribution `kroxylicious_message_process_time`

This metric records the length of time a message (request or response) has taken to traverse the proxy.

* The start time will be time the bytes containing the message arrived from the network (in the Netty handler, before any decoding).
* The end time will be the time that the network write at the proxy's opposite end completes (i.e. the Netty write promise completes)

The use cases supported by this metric are ones where you are interested in how much processing time it being incurred 
by the proxy decoding and encoding messages and any processing time incurred by the filter.

The requests sent by filter themselves, the start time for a request will be time filter called `#sendRequest`. The end time
will be the time the network write at the proxy upstream completes.  For responses, the start time is time the bytes containing
the message arrived from the network. The end time will be the time the response reaches the originating filter (i.e. the future completes).

#### Add label `node_id` and `virtual_cluster` to `kroxylicious_(down|up)stream_connections_attempts` and `kroxylicious_(down|up)stream_errors`

`node_id` will only be present if for requests going to or responses coming from a broker.  For bootstrap interactions,
`node_id` will be absent.

The existing label `virtualCluster` will be deprecated.  A new label `virtual_cluster` will be added.  It will carry
the virtual cluster's name.

#### Use `kroxylicious_downstream_errors` use to record other downstream errors

Issues should as downstream TLS negotiating errors or failure to resolve virtual cluster result in the connection being
closed, however, there is no metric counting those errors. `kroxylicious_downstream_connections_attempts` and
`kroxylicious_downstream_errors` should be incremented for these case too.  `virtual_cluster` and `node_id` won't be known
so these labels should be omitted.

## Compatibility

This proposal deprecates several metrics and the `virtualCluster` label.  These will be retained for several release before
being removed i.e. the project's normal deprecation practices will be followed.

## Rejected alternatives

* Message size inflation or deflation is mostly a concern for produce request filter and fetch response filters.  We could
  have metrics specifically targeted to measure the changes in size.  I favoured a uniform approach where we treat all API
  keys equally.
* Have a metric to time the passage of each message through each filter.  I think a courser grained metric `process time`
  should be good enough.  If the user needs more details, I think that would become a use-case for tracing.

## Implementation Plan

TBD.