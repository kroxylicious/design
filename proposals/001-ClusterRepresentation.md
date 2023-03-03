<!-- This template is provided as an example with sections you may wish to comment on with respect to your proposal. Add or remove sections as required to best articulate the proposal. -->

# Cluster Representation in the Model

This proposal introduces the concept of _cluster_ into the model.

A _downstream cluster_ is a kafka cluster that the clients connect to.   The downstream cluster can be thought of as a 'virtual' cluster or a 'facade' to
one or more _upstream clusters_.    An _upstream cluster_ represents the physical kafka cluster.  There is a one to one correspondance between
a _upstream cluster_ and a physical cluster in the world.

There will be a mechansim to route flexibly between downstreams and upstreams.  This will allow useful topologies to built to serve different use-cases.

- *one to one* - the simple exposure of a physical cluster 
- *many to one* - kroxy presents many downstream clusters which route to a single upstream - this would support a multitenant use-cases 

(There's a possiblity of *one-to-many* which a single downstream routes to several upstreams as if they were one, which might be useful for presenting several
kafka clusters as if they were one, however, supporting transactions across two clusters would be difficult.  We consider won't this use-case futrther).

## Current situation

Currently Kroxyilicious binds a single port to the downstream and connects to a single upstream broker.  There is no support for clusters comprised of more
then one broker.

## Motivation

1. Ability for Kroxylicious to expose multiple physical kafka clusters.
1. Ability for Kroxylicious to support clusters formed of more than one broker.
1. Ability for Kroxylicious to provide a building block to support multi-tenancy.

## Proposal

The proposal will change some existing concepts and introduce some new ones.  These are discussed first.  Then, we talk about the changes in high level responsibilities.

### Key Objects


![alternative text](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.github.com/kroxylicious/design/001-ClusterRepresentation/proposals/001/UML/uml.puml)





#### Endpoints

Currently `KafkaProxy` uses the `ProxyConfig` object to get a single address to bind to.  

* For the non-TLS case, multiple endpoints are required to support >1 brokers. 
* For TLS case, SNI gives a mechanism to route the traffic to a >1 brokers even when a single endpoint is used, however there may be performance or operational reasons to favour the ability to define endpoints.

`ProxyConfig` will be replaced by an list of _Endpoint_ objects.  

```
- name: endpoint name
  address: bind address/port
  type: PLAIN|TLS
```

#### Downstream Clusters

Conceptually the _downstream cluster_ represents the cluster that the kafka client connects to.  The downstream clusters list specifies
all the kafka clustsers are being presented by Kroxylicious. 

A _downstream clustser_ references exactly one _upstream cluster_. 

A _downstream cluster_ may reference a `filter chain`.  This provides zero or more filters that the RPCs will pass through before arriving at the upstream cluster.

A _downstream cluster_ enumerates the downstream brokers that comprise the downstream cluster.

##### Downstream Brokers

Each broker has a reference to an endpoint that will provide the way in to the broker.   For the SNI case, there is also an addresses matcher.  It is an error
for more than one broker to share an endpoint unless the endpoint type is TLS and the SNI matching address is defined.

Each downstream broker references exactly one upstream broker which must exist within the referenced upstream cluster.  It is an error if there is not a
one-to-one correspondence between downstream and upstream brokers.

TLS key material may be provided either at the downstream cluster level or at the individual broker level.


```yaml
- name: my-public-cluster
  upstreamClusterRef: my-private-cluster
  filterChainRef: my-upstream-filter-chain
  brokers:
  - name: broker-1
    endpointRef: my-tls-endpoint
    sniMatchAddress: broker-1-public.example.com
    upstreamBrokerRef: broker-1
    # or brokers themselves provide the key/cert
    - tls:
        key:
        cert:
  - name: broker-2
    ...
  # cluster wide TLS cert
  tls:
    key:
    cert:
```


#### Upstream Clusters

An _upstream cluster_ represents a physical kafka cluster.   The upstream clusters list specifies all the kafka clustsers that are being exposed through Kroxylicious.  

An _upstream cluster_ may reference a `filter chain`.  This provides zero or more *additional* filters that the RPCs will pass through before passing to the brokers
of the physical cluster.  

An _upstream cluster_ enumerates the upstream brokers that comprise the physical cluster.

#### Upstream Brokers

Each upstream broker specifies the address of the physical broker and whether TLS is to be used.  It will also specify trust settings.

TLS trust material may be provided at the upstream broker level or at the individual broker level.

```
- name: my-private-cluster
  filterChainRef: my-downstream-filter-chain
  tls:
    trust:
    ...
  brokers:
  - name: broker-1
    address: broker-1-private:9092
    ...
    tls:
      trust:
      ...
  - name: broker-2
    address: broker-1-private:9092
    ...
    tls:
      trust:
```

#### Filter Chain

Currently kroxylicious provide a single filter chain.  It will refactored so that we can support many filter chains, each identified by name. The `downstream cluster` and `upstream cluster` may reference a filter chain. 

```yaml
filterChains:
- name: my-upstream-filter-chain
  filters:
  - type: ApiVersions
  - type: BrokerAddress

```


### Responsibilities

All specified endpoints will be bound.

When a connection is made to an endpoint,  the system must resolve that connection to a downstream broker and hence a downstream cluster.

To do this, it resolves the endpoint and any SNI information against the model.   This should yield exactly one broker belonging to a downstream cluster.
It is an error otherwise and the connnection must be closed.

If TLS is in use, the SSLContext can be generated from the downstream cluster definition.  This will be passed to Netty to let it complete the TLS handshake.

The downstream broker and downstream cluster is used to identify the upstream broker and upstream cluster.

The upstream cluster and downstream broker provide the filter chain.

The handler chain connects to the upstream broker.


### Broker Address Filter

How will broker address filter map the RPCs that contain the upstream broker address to the downstream broker addresss that are resolveable to the client?

In the case where kroxy is being placed in front of a kafka cluster spanning a three-AZ cluster, the kroxylicious instances in the AZ won't need configuration to
*connect* to brokers in the other AZs.  However, BrokerAddressFilter will be to be capable of rewriting the the broker address for the whole cluster.
This leads us to the conclusion that Broker Address filter need separate configuration independent of that what could be derived from the upstream/downstream cluster mapping.

TODO: Maybe used a regexp based mapping would be sufficient

### Example Config Files

#### One to one case.

# 3 broker cluster, exposed via kroxy

```yaml
endpoints:
- name: my-tls-endpoint
  type: TLS
  bindAddress: 0.0.0.0:9092
downstreams:
- name: my-public-cluster
  upstreamClusterRef: my-private-cluster
  filterChainRef: my-downstream--filter-chain
  tls:
    key:
    cert:
  brokers:
  - name: broker-1
    sniMatchAddress: broker-1.public.kafka.com
    endpointRef: my-tls-endpoint
    upstreamBrokerRef: private-broker-1
  - name: broker-2
    sniMatchAddress: broker-2.public.kafka.com
    endpointRef: my-tls-endpoint
    upstreamBrokerRef: broker-2
  - name: broker-3
    sniMatchAddress: broker-3.public.kafka.com
    endpointRef: my-tls-endpoint
    upstreamBrokerRef: broker-3 
upstreams:
- name: my-private-cluster
  brokers:
  - name: private-broker-1
    address: broker-1-private:9092
  - name: private-broker-2
    address: broker-2-private:9092
  - name: private-broker-3
    address: broker-3-private:9092
filterChains:
- name: my-downstream--filter-chain
  filters:
  - type: ApiVersions
  - type: BrokerAddress
  - type: MyFunkyServiceFilter
```

#### Many-to-one case (multi tenancy)

# Single cluster, exposed to to two tenants.


```yaml
endpoints:
- name: my-tls-endpoint
  type: TLS
  bindAddress: 0.0.0.0:9092
downstreams:
- name: my-tenant1
  upstreamClusterRef: my-private-cluster
  tls:
    key:
    cert:
  brokers:
  - name: broker-1
    sniMatchAddress: broker-1.my-tenant1.kafka.com
    endpointRef: my-tls-endpoint
    upstreamBrokerRef: private-broker-1
  - name: broker-2
    sniMatchAddress: broker-2.my-tenant1.kafka.com
    endpointRef: my-tls-endpoint
    upstreamBrokerRef: broker-2
  - name: broker-3
    sniMatchAddress: broker-3.my-tenant1.kafka.com
    endpointRef: my-tls-endpoint
    upstreamBrokerRef: broker-3 
- name: my-tenant2
  upstreamClusterRef: my-private-cluster
  tls:
    key:
    cert:
  brokers:
  - name: broker-1
    sniMatchAddress: broker-1.my-tenant2.kafka.com
    endpointRef: my-tls-my-tls-endpoint
    upstreamBrokerRef: private-broker-1
  - name: broker-2
    sniMatchAddress: broker-2.my-tenant2.kafka.com
    endpointRef: my-tls-endpoint
    upstreamBrokerRef: broker-2
  - name: broker-3
    sniMatchAddress: broker-3.my-tenant2.kafka.com
    endpointRef: my-tls-endpoint
    upstreamBrokerRef: broker-3 
upstreams:
- name: my-big-cluster
  brokers:
  - name: broker-1
    address: beefy:9092
  - name: broker-2
    address: chunky:9092
  - name: broker-3
    address: hunky:9092
filterChains:
- name: my-upstream-filter-chain
  filters:
  - type: ApiVersions
  - type: BrokerAddress
  - type: MultiTenantFilter
```


Provide an introduction to the proposal. Use sub sections to call out considerations, possible delivery mechanisms etc.

## Affected/not affected projects

Call out the projects in the Kroxylicious organisation that are/are not affected by this proposal. 

## Compatibility

Call out any future or backwards compatibility considerations this proposal has accounted for.

## Rejected alternatives

Call out options that were considered while creating this proposal, but then later rejected, along with reasons why.
