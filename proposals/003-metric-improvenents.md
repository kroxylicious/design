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
| kroxylicious_downstream_errors                   | Counter      | flowing, virtualCluster                     | Incremented by one each time a connection fails owning to a downstream error (tls negotiation, protocol error etc)  |
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

### Deprecate `kroxylicious_inbound*`/`kroxylicious_payload_size_bytes` replace with new `kroxylicious_(downstream|upstream)_kafka_rpc_message_size_bytes` metrics

This proposal suggests that we deprecate the `kroxylicious_inbound*`/`kroxylicious_payload_size_bytes` metrics and replace
with two new **distribution** (aka histogram) metrics `kroxylicious_downstream_kafka_rpc_message_size_bytes` and `kroxylicious_upstream_kafka_rpc_message_size_bytes`.

The new "message_size" differ from the old "payload_size" in several key ways:
1. New "message_size" will be used to track both **opaque** and **decoded** messages ("payload_size" tracked only decoded messages).
2. Downstream "message size" will track [message size](https://kafka.apache.org/protocol#:~:text=DESCRIPTION-,message_size,-The%20message_size%20field)
   as messages come in from or leave for the client.  Upstream "message size" will track message size as messages go to or arrive from the broker.
3. The design of the metric allows it to be used to track messages that originate within a filter.
4. The design of metric allow a message-size histogram to be added.  This would allow the collection of statistical information
   on, say, the size of the produce request or the fetch response.  If added, we would make this configurable.

In Micrometer, `Distribution` type metrics actually comprise three Prometheus metrics `_sum`, `_count` and `_max`.  This means that
the use-cases for the deprecated counters `kroxylicious_inbound*` are actually covered.  If a user wants a count of the
number of requests they'll be able to query `kroxylicious_downstream_kafka_rpc_message_size_bytes_count[flowing="upstream"]`.

**How this supports the use-cases?**

Point `1` should assist capacity planning use-cases.  It gives you the means to know the number of bytes (layer 7) that are traversing the proxy.
This information should help a user, say, scale the proxy replicas to match load.

Point `2` should help use cases where the filters are changing the sizes of the messages as they go through the proxy.  The user
will be able to compare metrics for, say, produce requests received on the downstream with the 
produce requests leaving on the upstream side.

Point `3` gives the ability for the user to focus in a Kafka requests sent by filters and responses to those requests.

#### kroxylicious_downstream_kafka_rpc_message_size_bytes

Records the [message size](https://kafka.apache.org/protocol#:~:text=DESCRIPTION-,message_size,-The%20message_size%20field)
of all messages (RPCs) arriving at or leaving the downstream side of the proxy.

| Label                | Description                                                                                              |
|----------------------|----------------------------------------------------------------------------------------------------------|
| `virtual_cluster`    | name of virtual cluster                                                                                  |
| `node_id`            | node id of the broker (or absent if this request/response is to/from boostrap)                           |
| `api_key`            | API key of the message e.g. PRODUCE                                                                      |
| `api_version`        | API version of the message                                                                               |
| `flowing`            | `upstream` - request following towards the broker, `downstream` - response following towards the client. |
| `opaque`             | 1 if this message transited the proxy without being decoded                                              |
| `originating_filter` | if the request was originated by the filter, the name of the filter.                                     |

####  kroxylicious_upstream_kafka_rpc_message_size_bytes

Records the [message size](https://kafka.apache.org/protocol#:~:text=DESCRIPTION-,message_size,-The%20message_size%20field)
of all messages (RPCs) arriving at or leaving the upstream side of the proxy.

This metric will the same set of labels as `kroxylicious_downstream_kafka_rpc_message_size_bytes`.

### Add new `kroxylicious_rpc_message_process_time` metric

This proposal suggests that we add a new distribution metric `kroxylicious_rpc_message_process_time`. This metric records
the length of time a message (request or response) has taken to traverse the proxy.  Specifically, it will record 
the length of time between the initial conversion of the wire byte-buf into objects, until the time the write promise
completes.  The processing time will be recorded quantised buckets.  The size/number of buckets will be made configurable.

**How this supports the use-cases?**
This should aid diagnosis into performance problems or system slow-downs.  It should allow a user to quickly establish if
a slow-down is due to the proxy, and then drill down to understand which RPCs are causing the issue.

| Label                | Description                                                                                              |
|----------------------|----------------------------------------------------------------------------------------------------------|
| `virtual_cluster`    | name of virtual cluster                                                                                  |
| `node_id`            | node id of the broker (or absent if this request/response is to/from boostrap)                           |
| `api_key`            | API key of the message e.g. PRODUCE                                                                      |
| `api_version`        | API version of the message                                                                               |
| `flowing`            | `upstream` - request following towards the broker, `downstream` - response following towards the client. |
| `opaque`             | 1 if this message transited the proxy without being decoded                                              |
| `originating_filter` | if the request was originated by the filter, the name of the filter.                                     |

#### Add label `node_id` to `kroxylicious_upstream_connections_attempts` and `kroxylicious_upstream_errors`

The proposal is to add the `node_id` of the upstream broker being connected to.  If the connection being made is
for boostrap, the label will be absent.

**How this supports the use-cases?**

This should aid problem diagnosis. If a single upstream broker of a cluster has an issue, it will be obvious from the metrics (and alerts)
which broker is down.

(Note: that proposal is not suggesting adding `node_id` to the `kroxylicious_downstream_connections_attempts` or
`kroxylicious_downstream_errors`. This is because at the point these metrics are emitted, the upstream target has not yet
been identified.  Emitting the metric early has advantages)

#### Deprecate label `virtualCluster`, replace with `virtual_cluster`.

## Compatibility

This proposal deprecates several metrics and the `virtualCluster` label.  These will be retained for several release before
being removed i.e. the project's deprecation policy will apply.

## Rejected alternatives

* Message size inflation or deflation is mostly a concern for produce request filter and fetch response filters.  We could
  have metrics specifically targeted to measure the changes in size.  I favoured a uniform approach where we treat all API
  keys equally.
* Have a metric to time the passage of each message through each filter.  I think a courser grained metric `process time`
  should be good enough.  If the user needs more details, I think that would become a use-case for tracing.

## Implementation Plan

TBD.