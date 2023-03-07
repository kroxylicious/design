<!-- This template is provided as an example with sections you may wish to comment on with respect to your proposal. Add or remove sections as required to best articulate the proposal. -->

# Representing Virtual and Physical Clusters in the Kroxylicious Model.

This proposal introduces the concept of _virtual cluster_ and _physical cluster_ into the model.  

A _virtual cluster_ is a kafka cluster that clients connect to. From the perspective of the client, the virtual cluster behaves exactly as a normal kafka cluster would.   Many virtual clusters can be defined with a Kroxylicious instance.   Conceptually, the virtual cluster exists on the [downstream](https://github.com/kroxylicious/design/blob/main/concepts.asciidoc#upstream-vs-downstream) (client side) of Kroxylicious.

A _physical cluster_ is a model representation of an real Apache Kafka cluster.  There is always a one to one correspondance between the _physical cluster_
and a real real Apache Kafka cluster. Many physical clusters can be defined with a Kroxylicious instance.  Conceptually, the physical cluster exists on the [upstream](https://github.com/kroxylicious/design/blob/main/concepts.asciidoc#upstream-vs-downstream) (client side) of Kroxylicious.

There will be a mechansim to map between virtual and physical clusters.  This will allow building useful topologies to serve different use-cases, such as:

- *one to one* - the proxying of a single physical cluster.
- *many to one* - kroxylicious presents many virtual clusters which map to a physical cluster. This would support a multi-tenant use-case where a single physical clusters is shared by isolated tenants.

(There's a possiblity of *one-to-many* where a single virtual cluster maps to several physical, presenting them as if they were one. However, supporting transactions across two or more physical clusters would be difficult.  This use-case is out-of-scope).

## Current situation

Kroxyliciousis currently limited to exposing a single broker of a singel cluster.

## Motivation

Ability to support the *one to one* and *many to one* use-cases described above.

## Proposal

The proposal will change some existing concepts and introduce some new ones.  These are discussed first.  Then, we talk about the changes in high level responsibilities.

### Key Objects


![alternative text](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.github.com/kroxylicious/design/001-ClusterRepresentation/proposals/001/UML/uml.puml)





#### Endpoints

Currently `KafkaProxy` uses the `ProxyConfig` object to get a single address to bind to.  

* For the non-TLS case, multiple endpoints are required to support >1 brokers. 
* For TLS case, SNI gives a mechanism to route the traffic to >1 brokers even when a single endpoint is used, however there may be performance or operational reasons to favour the ability to define endpoints.

`ProxyConfig` will be replaced by an list of _Endpoint_ objects.  

```yaml
- name: endpoint name
  address: bind address/port
  type: PLAIN|TLS
```

#### Virtual Clusters

Conceptually the _virtual cluster_ represents the cluster that the kafka client connects to.  The virtual clusters list specifies
all the kafka clusters are being presented by Kroxylicious. 

A _virtual clusster_ references exactly one _physical cluster_. 

A _virtual cluster_ may reference a `filter chain`.  This provides zero or more filters that the RPCs will pass through before arriving at the physical cluster.

A _virtual cluster_ enumerates the virtual brokers that comprise the virtual cluster.

##### Virtual Brokers

Each broker has a reference to an endpoint that will provide the way in to the broker.   For the SNI case, there is also an addresses matcher.  It is an error
for more than one broker to share an endpoint unless the endpoint type is TLS and the SNI matching address is defined.

Each virtual broker references exactly one physical broker which must exist within the referenced physical cluster.  It is an error if there is not a
one-to-one correspondence between downstream and upstream brokers.

TLS key material may be provided either at the virtual cluster level or at the individual broker level.


```yaml
- name: my-public-cluster
  physicalClusterRef: my-private-cluster
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


#### Physical Clusters

An _physical cluster_ is the in-model representation of a running kafka cluster.   The physical clusters list specifies all the kafka clusters that known to Kroxylicious.

An _physical cluster_ may reference a `filter chain`.  This provides zero or more *additional* filters that the RPCs will pass through before passing to the brokers
of the physical cluster.  

An _physical cluster_ enumerates the upstream brokers that comprise the physical cluster.

#### Physical Brokers

Each physical broker specifies the address of a broker and whether TLS is to be used.  It will also specify trust settings.

TLS trust material may be provided at the upstream broker level or at the individual broker level.

```yaml
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

Currently kroxylicious provide a single filter chain.  It will refactored so that we can support many filter chains, each identified by name. The `virtual cluster` and `physical cluster` may reference a filter chain. 

```yaml
filterChains:
- name: my-upstream-filter-chain
  filters:
  - type: ApiVersions
  - type: BrokerAddress

```


### Responsibilities

All specified endpoints will be bound.

When a connection is made to an endpoint,  the system must resolve that connection to a virtual broker and hence a virtual cluster.

To do this, it resolves the endpoint and any SNI information against the model.   This should yield exactly one broker belonging to a virtual cluster.
It is an error otherwise and the connnection must be closed.

If TLS is in use, the SSLContext can be generated from the virtual cluster definition.  This will be passed to Netty to let it complete the TLS handshake.

The virtual broker and virtual cluster is used to identify the physical broker and physical cluster.

The physical cluster and downstream broker provide the filter chain.

The handler chain connects to the upstream broker.

The system must reload chnages to the model dynammically, without dropping established connections.

### Broker Address Filter

How will broker address filter map the RPCs that contain the upstream broker address to the downstream broker addresss that are resolveable to the client?

In the case where kroxy is being placed in front of a kafka cluster spanning a three-AZ cluster, the kroxylicious instances in the AZ won't need configuration to
*connect* to brokers in the other AZs.  However, BrokerAddressFilter will be to be capable of rewriting the the broker address for the whole cluster.
This leads us to the conclusion that Broker Address filter need separate configuration independent of that what could be derived from the upstream/virtual cluster mapping.

TODO: Maybe used a regexp based mapping would be sufficient

### Example Config Files

#### One to one case.

# 3 broker cluster, exposed via kroxy

```yaml
endpoints:
- name: my-tls-endpoint
  type: TLS
  bindAddress: 0.0.0.0:9092
virtualClusters:
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
physicalClusters:
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
virtualClusters:
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
physicalClusters:
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
