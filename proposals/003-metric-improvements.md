<!-- This template is provided as an example with sections you may wish to comment on with respect to your proposal. Add or remove sections as required to best articulate the proposal. -->

# Improvements to Kroxylicious (Proxy) Metrics

The document aims to:

* describe the short-comings with the current metrics
* identify use-cases for Kroxylicious metrics
* propose improvements.
* propose an implementation plan.

<!-- TOC -->
* [Improvements to Kroxylicious (Proxy) Metrics](#improvements-to-kroxylicious-proxy-metrics)
  * [Current situation](#current-situation)
    * [Specific short-comings/weaknesses](#specific-short-comingsweaknesses)
    * [General short-comings/weaknesses](#general-short-comingsweaknesses)
    * [Filter specific metrics](#filter-specific-metrics)
  * [Use Cases](#use-cases)
  * [Proposal](#proposal)
    * [Summary](#summary)
    * [New counters `kroxylicious_<A>_to_<B>_request_total` and `kroxylicious_<A>_to_<B>_response_total`](#new-counters-kroxyliciousatobrequesttotal-and-kroxyliciousatobresponsetotal)
    * [New distributions `kroxylicious_<A>_to_<B>_request_size_bytes` and `kroxylicious_<A>_to_<B>_response_size_bytes`](#new-distributions-kroxyliciousatobrequestsizebytes-and-kroxyliciousatobresponsesizebytes)
    * [New distributions `kroxylicious_client_to_server_request_transit_time` and `kroxylicious_server_to_client_response_transit_time`](#new-distributions-kroxyliciousclienttoserverrequesttransittime-and-kroxyliciousservertoclientresponsetransittime)
    * [New distributions `kroxylicious_filter_to_server_request_transit_time` and `kroxylicious_server_to_filter_response_transit_time`](#new-distributions-kroxyliciousfiltertoserverrequesttransittime-and-kroxyliciousservertofilterresponsetransittime)
    * [Use `kroxylicious_downstream_errors` use to record other downstream errors](#use-kroxyliciousdownstreamerrors-use-to-record-other-downstream-errors)
    * [Out of scope](#out-of-scope)
      * [Distribution/Histogram Buckets](#distributionhistogram-buckets)
    * [TCP/IP Back pressure metrics](#tcpip-back-pressure-metrics)
    * [Auto-read toggle state metrics](#auto-read-toggle-state-metrics)
    * [Specific metric for short circuit responses](#specific-metric-for-short-circuit-responses)
    * [Specific metric for filters that drop connections or suffer an exception](#specific-metric-for-filters-that-drop-connections-or-suffer-an-exception)
    * [Dedicated API for Filter specific metrics](#dedicated-api-for-filter-specific-metrics)
  * [Compatibility](#compatibility)
  * [Rejected alternatives](#rejected-alternatives)
  * [Implementation Schedule](#implementation-schedule)
    * [Essential](#essential)
    * [Highly Desirable](#highly-desirable)
    * [Deferred until Later](#deferred-until-later)
<!-- TOC -->

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
* *3 - downstream errors does not record account for errors such as TLS negotiation errors or failures to determine virtual cluster or broker node.  

### General short-comings/weaknesses

* The metrics endpoint populates `HELP` for each metric, but this is populated with nothing more than the metric's name.
  We ought to be giving a clear description of the metric.
* Some of the label names don't follow Prometheus naming conventions.  Prometheus recommends snake case whereas we have used camel case in some cases.
* Some of the metrics names aren't too clear.  For instance, the word payload has no defined meaning in the [Kafka Protocol Guide](https://kafka.apache.org/protocol).

### Filter specific metrics

As shown by `io.kroxylicious.sample.SampleProduceRequestFilter#SampleProduceRequestFilter` it is possible for filters
to emit their own metrics by making direct use of the Mircometer APIs.  Filters that need their own metrics will probably
be a common use-case.

It is questionable whether giving the giving filters free-reign to use Mircometer API directly is supportable
in the long term.  Mircometer should probably be an internal concern of the Proxy.

Also, there is nothing that that prevents two filters emitting metrics with colliding names.

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
  requests by producing their own responses (the server never sees the request), drop connections, and introduce their
  own requests.
* filters can perform asynchronous work.  When asynchronous work occurs, the proxy stops reading the downstream or upstream.

## Proposal

### Summary

The following metrics will be added.  They will each be described in more detail later in this section.

| Metric                                              | Type         | Labels                                                      | Description                                                                                                                        |
|-----------------------------------------------------|--------------|-------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------|
| kroxylicious_client_to_proxy_request_total          | Counter      | virtual_cluster, node_id, api_key, api_version, decoded     | Incremented by one every time a **request** arrives at the proxy from the downstream (client).                                     |
| kroxylicious_proxy_to_server_request_total          | Counter      | virtual_cluster, node_id, api_key, api_version, decoded     | Incremented by one every time a **request** (#1) goes from the proxy to the upstream (server}.                                     |
| kroxylicious_server_to_proxy_response_total         | Counter      | virtual_cluster, node_id, api_key, api_version, decoded     | Incremented by one every time a **response** (#1) arrives at the proxy from the upstream (server}.                                 |
| kroxylicious_proxy_to_client_response_total         | Counter      | virtual_cluster, node_id, api_key, api_version, decoded     | Incremented by one every time a **response** goes from the proxy to the downstream (client).                                       |
|                                                     |              |                                                             |                                                                                                                                    |
| kroxylicious_client_to_proxy_request_size_bytes     | Distribution | virtual_cluster, node_id, api_key, api_version, decoded     | Records the message size of every **request** arriving from the downstream (client).                                               |
| kroxylicious_proxy_to_server_request_size_bytes     | Distribution | virtual_cluster, node_id, api_key, api_version, decoded     | Records the message size of every **request** (#1) leaving for the upstream (server}.                                              |
| kroxylicious_server_to_proxy_response_size_bytes    | Distribution | virtual_cluster, node_id, api_key, api_version, decoded     | Records the message size of every **response** (#1) arriving from the upstream (server}.                                           |
| kroxylicious_proxy_to_client_response_size_bytes    | Distribution | virtual_cluster, node_id, api_key, api_version, decoded     | Records the message size of every **response** leaving for the downstream (client).                                                |
|                                                     |              |                                                             |                                                                                                                                    |
| kroxylicious_client_to_server_request_transit_time  | Distribution | virtual_cluster, node_id, api_key, api_version, decoded     | Records the time taken for each **request** to transit the proxy                                                                   |
| kroxylicious_client_to_server_response_transit_time | Distribution | virtual_cluster, node_id, api_key, api_version, decoded     | Records the time taken for each **response** to transit the proxy                                                                  |
|                                                     |              |                                                             |                                                                                                                                    |
| kroxylicious_filter_to_server_request_total         | Counter      | virtual_cluster, node_id, api_key, api_version, filter_name | Incremented by one every time a **filter-initiated request** goes from the proxy to the upstream (server}.                         |
| kroxylicious_server_to_filter_response_total        | Counter      | virtual_cluster, node_id, api_key, api_version, filter_name | Incremented by one every time a **response** for a **filter-initiated request** arrives at the proxy from the upstream (server}.   |
|                                                     |              |                                                             |                                                                                                                                    |
| kroxylicious_filter_to_server_request_size_bytes    | Distribution | virtual_cluster, node_id, api_key, api_version, filter_name | Records the message size of every **filter-initiated request** goes from the proxy to the upstream (server}.                       |
| kroxylicious_server_to_filter_response_size_bytes   | Distribution | virtual_cluster, node_id, api_key, api_version, filter_name | Records the message size of every **response** for a **filter-initiated request** arrives at the proxy from the upstream (server}. |
|                                                     |              |                                                             |                                                                                                                                    |
| kroxylicious_filter_to_server_request_transit_time  | Distribution | virtual_cluster, node_id, api_key, api_version, filter_name | Records the time taken for each **filter-initiated request** to transit the proxy                                                  |
| kroxylicious_client_to_server_response_transit_time | Distribution | virtual_cluster, node_id, api_key, api_version, filter_name | Records the time taken for each **response** for a **filter-initiated request** to transit the proxy                               |

**#1** - Requests generated by Filter API's `sendRequest`, and their responses, are not accounted for by these metric

The following metrics will have changes to their labels.

| Metric                                    | Type    | Labels                   | Deprecated Labels | Description                                                                           |
|-------------------------------------------|---------|--------------------------|-------------------|---------------------------------------------------------------------------------------|
| kroxylicious_downstream_connections_total | Counter | virtual_cluster, node_id | virtualCluster    | Incremented by one every time a connection is made from the downstream the proxy. #2  |
| kroxylicious_downstream_error_total       | Counter | virtual_cluster, node_id | virtualCluster    | Incremented by one every time a connection is closed due to downstream error.         |
| kroxylicious_upstream_connections_total   | Counter | virtual_cluster, node_id | virtualCluster    | Incremented by one every time a connection is made to the upstream from the proxy. #2 |
| kroxylicious_upstream_error_total         | Counter | virtual_cluster, node_id | virtualCluster    | Incremented by one every time a connection is closed due to upstream error.           |

**#2** Note - In the case where the connection attempt fails early (TLS error etc), this metric is still incremented.

The labels are defined as follows:

| Label           | Definition                                                                                                                                                                  |
|-----------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| virtual_cluster | Name of virtual cluster.  Label omitted if the virtual cluster has not been established‡.                                                                                   |
| node_id         | Numeric node_id of the broker being communicated with. the value `bootstrap` is used for bootstrapping interactions. Label omitted if the node has not been established #3. |
| api_key         | API key of the kafka message e.g. PRODUCE                                                                                                                                   |                                                                                                                                               |
| api_version     | Numeric API version of the message.                                                                                                                                         |                                                                                                                                               |
| decoded         | Flag indicating if the proxy decoded the message or not (true = decoded, false = not decoded)                                                                               |                                                                                                                                               |
| filter_name     | Name of the filter that initiated the request                                                                                                                               |                                                                                                                                               |

**#3** This happens only in the case of connection to gateways using "SNI Identifies Node" where the connection fails TLS negotiation or the SNI name is unrecognised.

The following metrics will be deprecated.

| Metric                                           |
|--------------------------------------------------|
| kroxylicious_inbound_downstream_messages         |
| kroxylicious_inbound_downstream_decoded_messages |
| kroxylicious_payload_size_bytes                  |



### New counters `kroxylicious_<A>_to_<B>_request_total` and `kroxylicious_<A>_to_<B>_response_total`

Counts the number of request/responses flowing between point A and point B.

Use cases that were previously served by the deprecated metrics `kroxylicious_inbound_downstream_messages` and
`kroxylicious_inbound_downstream_decoded_messages` can now use these metric instead.

In the case where a filter **short-circuits** a request and provides its own response, `client_to_proxy_request_total` will tick
but `kroxylicious_proxy_to_server_request_total` will not.

The `kroxylicious_filter_to_server_request_total` and `kroxylicious_server_to_filter_response_total` are used exclusively
for `FilerContext#sendRequest` interactions.  The `kroxylicious_proxy_to_server_request_total` and
`kroxylicious_server_to_proxy_response_total` do not tick for these use-cases.

### New distributions `kroxylicious_<A>_to_<B>_request_size_bytes` and `kroxylicious_<A>_to_<B>_response_size_bytes`

Records the sizes of request/responses flowing between point A and point B.

Use cases that were previously served by the deprecated metric `kroxylicious_payload_size_bytes` can now use this metric
instead. The new metric records the size of both **opaque** and **decoded** messages allowing the user to understand the
number of bytes traversing the proxy.

In the case where a filter causes a request (or response) to expand, this will be evident from the metrics. `kroxylicious_client_to_proxy_request_size_bytes`
will record the size when the request arrived and `kroxylicious_proxy_to_server_request_size_bytes` will record its new
encoded size as it leaves.  The same thing will happen from responses.   This will allow the effect of adding filters
such as the Record Encryption (where produce request sizes will change) to be understood.

### New distributions `kroxylicious_client_to_server_request_transit_time` and `kroxylicious_server_to_client_response_transit_time`

These metric records the length of time a message (request or response) has taken to transit the proxy.

* The start time will be time the proxy starts to handle the message
* The end time will be the time that the network write at the proxy's opposite end completes (i.e. the Netty write promise completes)
* If the message is decoded, the transit time must include the time taken to decode and any re-encoding of the message. 

The use cases supported by this metric are ones where you are interested in how much processing time it being incurred 
by the proxy decoding and encoding messages and any processing time incurred by the filter chain.

### New distributions `kroxylicious_filter_to_server_request_transit_time` and `kroxylicious_server_to_filter_response_transit_time`

These metrics work like `kroxylicious_client_to_server_request_transit_time` and `kroxylicious_server_to_client_response_transit_time`
but concerns filter-initiated requests and their responses.

For filter-initiated requests, the start time for a request will be time filter called `#sendRequest`. The end time
will be the time the network write at the proxy upstream completes.

For responses to filter-initiated requests, the start time is time the bytes containing the message arrived from the network.
The end time will be the time the response reaches the originating filter (i.e. the future completes).

### Use `kroxylicious_downstream_errors` use to record other downstream errors

Issues such as downstream TLS negotiating errors or failure to resolve virtual cluster result in the connection being
closed, however, there is no metric counting those errors. `kroxylicious_downstream_connections_attempts` and
`kroxylicious_downstream_errors` should be incremented for these case too.  `virtual_cluster` and `node_id` won't be known
so these labels should be omitted.

### Out of scope

#### Distribution/Histogram Buckets

Publication of a histograms is out of scope for this proposal.  This means that the distribution metrics will
emit `_sum`, `_count` and `_max` metrics from the Prometheus endpoint.  This is sufficient information to allow trends
to be observed and things like spikes will be apparent.  The user won't be able to use PromQL functions such as
[histogram_quantile](https://prometheus.io/docs/prometheus/latest/querying/functions/#histogram_quantile).

Future work will be required to allow the user to configure for which metrics histogram buckets should be gathered
and what the bucket sizes should be.  This needs to be done in a way to avoid problematic number of metrics.

### TCP/IP Back pressure metrics

We think that the proxy ought to have some metrics exposing Netty's `channelWritabilityChanged` (in other words, TCP/IP
back-pressure) so that a user can understand how long the proxy is awaiting for the upstream or downstream to be
ready to receive data.

We don't yet know exactly how this metric should look, so we choose to defer working on it for now.  This will be 
subject of a future proposal.

### Auto-read toggle state metrics

We think that the proxy ought to have some metrics exposing now long the reading or writing is blocked whilst the proxy
awaits for asynchronous work of Filters completes.  For instance, the record encryption, the proxy stops reading from
the downstream whilst a new DEK is created.

We don't yet know exactly how this metric should look, so we choose to defer working on it for now. This will be
subject of a future proposal.

### Specific metric for short circuit responses

With this proposal, in the case where a request filter _short circuits_ a request and reproduces its own response, the
`kroxylicious_client_to_proxy_request_total` value will exceed the `kroxylicious_proxy_to_server_request_total`
but this is quite subtle.

We think there is merit in a separate metric that ticks in this case.  Filter can emit their own metric, but it
might be good to have a metric built in.  This might be subject of a future proposal.  The proposal will need to 
think about how the `transit_time` metrics behave in this case.

### Specific metric for filters that drop connections or suffer an exception

Filters can cause a connection to drop (`io.kroxylicious.proxy.filter.FilterResultBuilder#drop`) or a filter's
processing thrown an exception, leading to a connection being closed.

Filter can be coded to emit their own metrics in these scenarios, but it might be good to have a metrics built in. 
This might be subject of a future proposal. The proposal will need to think about how the `transit_time` metrics behave
in these cases.

### Dedicated API for Filter specific metrics

There will subject to a separate proposal.

## Compatibility

This proposal deprecates several metrics and the `virtualCluster` label.  These will be retained for several release before
being removed i.e. the project's normal deprecation practices will be followed.

## Rejected alternatives

* Message size inflation or deflation is mostly a concern for produce request filter and fetch response filters.  We could
  have metrics specifically targeted to measure the changes in sizeof those RPCs.  This proposal favours a uniform approach
  where we treat all API keys equally.
* Have a metric to time the passage of each message through each filter.  I think a courser grained metric `transit time`
  should be good enough.  If the user needs more details, I think that would become a use-case for tracing.

## Implementation Schedule

### Essential

Things we'll probably want in 0.13.0.

* Implement `kroxylicious_<A>_to_<B>_request_total` and `kroxylicious_<A>_to_<B>_response_total` (excluding the case where A or B is `filter`)
* Implement `kroxylicious_<A>_to_<B>_request_size_bytes` and `kroxylicious_<A>_to_<B>_response_size_bytes` (excluding the case where A or B is `filter`)
* Implement `kroxylicious_(down|up)stream_connections_attempts` and `kroxylicious_(down|up)stream_errors` changes
* Deprecate the indicated metrics
* Documentation for metrics

I think we can defer the filter metrics because we don't yet ship filters that rely on `#sendRequest` API.

### Highly Desirable

* Implement `kroxylicious_client_to_server_request_transit_time` and `kroxylicious_server_to_client_response_transit_time`

### Deferred until Later

* Ability to selectively enable histograms and configure buckets
* Implement `kroxylicious_filter_to_server_request_(total|size_bytes)`
* Implement `kroxylicious_server_to_filter_response_(total|size_bytes)`
