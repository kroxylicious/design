<!-- This template is provided as an example with sections you may wish to comment on with respect to your proposal. Add or remove sections as required to best articulate the proposal. -->

# Cluster Representation in the  Kroxylicious Model.


## Tom's idea



```
clusterMappings: # <1>
- clusterId: <uuid> # <2>
  upstreamBootstrap: 123.123.123.123/9092 # <3>
  upstreamClusterId: <uuid> # <4>
  minPort: 19092 # <5>
  maxPort; 19192 # <6>
  bootstrapAddress: 0.0.0.0 # <7>
  endpointTemplate: 
    host: broker-${id}.foo-kafka.example.com # <8>
    port: $(minPort + nodeId + 1) # <9>
```    
    
1. There would be one cluster mapping for each cluster
2. The cluster id presented to the client
3. A bootstrap list for the upstream cluster
4. The expected upstream cluster id
5. A base port
The highest port this cluster can allocate (puts a limit on the number of brokers in this cluster). Non-disjoint port ranges between clusterMappings would be an error.
A bootstrap address for clients. Always binds to the minPort. This is needed for clients to be able to bootstrap. Once bootstrapped they'd use the dynamicly generated endpoints. An alternative would be just have a list of broker ids which got bound initially, even before they were observed in MetadataResponse etc. This latter options is closer to to @k-wall's comment above, I think.

6. A template for the hostname used when rewriting the MetadataResponse etc. I think this is what @SamBarker's comment
7. Removing the definition of virtual brokers from the configuration model also implies that Kroxylicious becomes the arbiter of the broker hostname was about.
Likewise for port numbers. IDK if we actually need to make this configurable or if we could just hard code this expression

Notes:

I've not thought much about TLS aspects. Obviously using a wildcard cert for *.foo-kafka.example.com means we don't need to dynamically obtain certs for individual brokers.







Ignore below this line 

====================================






This proposal introduces the concept of _virtual cluster_ and _physical cluster_ into the model.  

A _virtual cluster_ is a kafka cluster that clients connect to. From the perspective of the client, the virtual cluster behaves exactly as a normal kafka cluster would.   Many virtual clusters can be defined with a Kroxylicious instance.  Each _virtual clusters_ comprises one or more _virtual brokers_.  Conceptually, the virtual cluster and virtual broker exists on the [downstream](https://github.com/kroxylicious/design/blob/main/concepts.asciidoc#upstream-vs-downstream) (client side) of Kroxylicious.

A _physical cluster_ is a model representation of a real Apache Kafka cluster.  There is always a one to one correspondance between the _physical cluster_
and a real Apache Kafka cluster. Many physical clusters can be defined with a Kroxylicious instance. Each _physical cluster_ comprises one or more _physical brokers_.  Conceptually, the physical cluster exists on the [upstream](https://github.com/kroxylicious/design/blob/main/concepts.asciidoc#upstream-vs-downstream) (client side) of Kroxylicious.

There will be a mechansim to map between virtual and physical clusters.  This will allow the building useful topologies to serve different use-cases, such as:

- *one to one* - the proxying of a single physical cluster.
- *many to one* - kroxylicious presents many virtual clusters which map to a physical cluster. This would support a multi-tenant use-case where a single physical clusters is shared by isolated tenants.

## Illustration of many-to-one use-case

![alternative text](https://raw.githubusercontent.com/kroxylicious/design/001-ClusterRepresentation/proposals/001/many-to-one.png)

## Goals

* Ability to support the *one to one* and *many to one* use-cases described above.
* Ability to add/remove/change virtual or physical clusters at runtime, without interrupting connections established.


## Non-Goals

* There's a possiblity of *one-to-many* where a single virtual cluster maps to several physical, presenting them as if they were one. However, supporting transactions across two or more physical clusters would be difficult.  This use-case is out-of-scope.
* It might be possible for a virtual cluster to present a subset of a physical cluster's brokers as virtual brokers by clevery exposing only those brokers that host topic partitions belonging to that virtual cluster.  This might be advantagous in the case where the physical cluster comprises a very large number of brokers.  We won't consider this use-case as part of this proposal.


## Current situation

Kroxylicious is currently limited to exposing a single broker of a single cluster.


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

A _virtual cluster_ references exactly one _physical cluster_. 

A _virtual cluster_ may define a chain of filters.  This provides zero or more filters that the RPCs will pass through as they traverse the virtual cluster,
before they reach the physical cluster.

A _virtual cluster_ enumerates the virtual brokers that comprise the virtual cluster.

##### Virtual Brokers

Each broker has a reference to an endpoint that will provide the way in to the broker.   For the SNI case, there is also an addresses matcher.  It is an error
for more than one broker to share an endpoint unless the endpoint type is TLS and the SNI matching address is defined.

Each virtual broker references exactly one physical broker which must exist within the referenced physical cluster.  It is an error if there is not a
one-to-one correspondence between physical and virtual brokers.

TLS key material may be provided either at the virtual cluster level or at the individual broker level.


```yaml
virtualClusters:
- name: my-public-cluster
  physicalClusterRef: my-private-cluster
  filters:
  - type: Filter1
    config:
       foo: bar
  - type: Filter2
  brokers:
  - name: broker-1
    endpointRef: my-tls-endpoint
    sniMatchAddress: broker-1-public.example.com
    physicalBrokerRef: broker-1
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

A physical cluster_ may define a chain of filters.  This provides zero or more filters that the RPCs will pass through as they traverse the physical cluster.
Note that it is possible for both virtual and physical clusters to define filter chains. RPCs pass through both sets of filters in the order they are defined depending on the direction of message flow (that is messages flowing: upstream traverse the `virtual` filter chain then the `physical` filter chain.  messages flowing downstream will traverse the `physical` filter chain then the `virtual` chain).

An _physical cluster_ enumerates the brokers that comprise the physical cluster.

#### Physical Brokers

Each physical broker specifies the address of a broker and whether TLS is to be used.  It will also specify trust settings.

TLS trust material may be provided at the virtual broker level or at the individual broker level.

```yaml
physicalClusters:
- name: my-private-cluster
  filters:
  - type: Filter1
    config:
       foo: bar
  - type: Filter2
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


### High Level Responsibilities

#### Connection Handling


All declared endpoints will be bound.

When a connection is made to an endpoint,  the system must resolve that connection to a virtual broker and hence a virtual cluster.

To do this, it resolves the endpoint (and any SNI information) against the model.   This should yield exactly one broker belonging to a virtual cluster.
It is an error otherwise and the connnection must be closed.

If TLS is in use, the SSLContext can be generated from the virtual cluster definition.  This will be passed to Netty to let it complete the TLS handshake.

The virtual broker and virtual cluster is used to identify the physical broker and physical cluster.

The filter chains are constructed.

The handler chain connects to the physical broker.

#### Model Changes

The system must reload chnages to the model dynammically, without dropping established connections.

#### Broker Address Filter

The BrokerAddressFilter must map the RPC reponses that contain the physical broker address to the virtual broker addresses that are resolveable to the client.  DescribeCluster response is an example of an RPC that needs to be mapped.

In the case where Kroxylicious is being placed in front of a kafka cluster spanning a three-AZ cluster, the kroxylicious instances in the AZ won't need configuration to *connect* to brokers in the other AZs.  However, BrokerAddressFilter must be capable of rewriting the broker address for the whole cluster.
This leads us to the conclusion that Broker Address filter need separate configuration, independent of that what could be derived from the virtual/physical cluster mapping.

The BrokerAddressFilter will accept a mapping, which will map the addresses returned by the upstream broker to routable addresses that route to the virtual brokers of the cluster in question.

To do this, we can use the existing filter configuration mechanism.

```
  - type: BrokerAddress
    config:
      brokerAddressMapping:
        broker-1.azA.internal.svc:19080: broker-A.myvanitydomain.com:9092
        broker-2.azB.internal.svc:19080: broker-B.myvanitydomain.com:9092
        broker-3.azC.internal.svc:19080: broker-C.myvanitydomain.com:9092
```       


### Example Config Files

#### One to one case.

##### Single Cluster with 3 brokers, exposed via kroxylicious

```yaml
endpoints:
- name: my-tls-endpoint
  type: TLS
  bindAddress: 0.0.0.0:9092
virtualClusters:
- name: my-public-cluster
  physicalClusterRef: my-private-cluster
  filters:
  - type: ApiVersions
  - type: BrokerAddress
    config:
      brokerAddressMapping:
        broker-1.azA.internal.svc:19080: broker-A.myvanitydomain.com:9092
        broker-2.azB.internal.svc:19080: broker-B.myvanitydomain.com:9092
        broker-3.azC.internal.svc:19080: broker-C.myvanitydomain.com:9092
  - type: MyFunkyFilter
  tls:
    key:
    cert:
  brokers:
  - name: broker-1
    sniMatchAddress: broker-A.myvanitydomain.com
    endpointRef: my-tls-endpoint
    physicalBrokerRef: private-broker-1
  - name: broker-2
    sniMatchAddress: broker-B.myvanitydomain.com
    endpointRef: my-tls-endpoint
    physicalBrokerRef: private-broker-2
  - name: broker-3
    sniMatchAddress: broker-C.myvanitydomain.com
    endpointRef: my-tls-endpoint
    physicalBrokerRef: private-broker-3
physicalClusters:
- name: my-private-cluster
  brokers:
  - name: private-broker-1
    address: broker-1.azA.internal.svc:19080
  - name: private-broker-2
    address: broker-2.azB.internal.svc:19080
  - name: private-broker-3
    address: broker-3.azC.internal.svc:19080
```

#### Many-to-one case (multi tenancy)

Note that in this case we've defined two separate virtual clusters, one for each tenant.  We leveraged the fact that filters can be defined at the
virtual cluster level to pass in tenant specific information to the filters. Specifically, this is how we pass in the tenant key (prefix) and the
broker address mapping.

```yaml
endpoints:
- name: my-tls-endpoint
  type: TLS
  bindAddress: 0.0.0.0:9092
virtualClusters:
- name: my-tenant1
  physicalClusterRef: my-big-cluster
  tls:
    key:
    cert:
  filters:
  - type: ApiVersions
  - type: BrokerAddress
    config:
      brokerAddressMapping:
        broker-1.azA.internal.svc:19080: broker-1.my-tenant1.kafka.com:9092
        broker-2.azB.internal.svc:19080: broker-2.my-tenant1.kafka.com:9092
        broker-3.azC.internal.svc:19080: broker-3.my-tenant1.kafka.com:9092
  - type: MultiTenantFilter
    config:
      tenantKey: z4de # prefix used to prefix objects owned by the tenant.
  brokers:
  - name: broker-1
    sniMatchAddress: broker-1.my-tenant1.kafka.com
    endpointRef: my-tls-endpoint
    physicalBrokerRef: private-broker-1
  - name: broker-2
    sniMatchAddress: broker-2.my-tenant1.kafka.com
    endpointRef: my-tls-endpoint
    physicalBrokerRef: private-broker-2
  - name: broker-3
    sniMatchAddress: broker-3.my-tenant1.kafka.com
    endpointRef: my-tls-endpoint
    physicalBrokerRef: private-broker-3
- name: my-tenant2
  physicalClusterRef: my-big-cluster
  tls:
    key:
    cert:
  filters:
  - type: ApiVersions
  - type: BrokerAddress
    config:
      brokerAddressMapping:
        broker-1.azA.internal.svc:19080: broker-1.my-tenant2.kafka.com:9092
        broker-2.azB.internal.svc:19080: broker-2.my-tenant2.kafka.com:9092
        broker-3.azC.internal.svc:19080: broker-3.my-tenant2.kafka.com:9092
  - type: MultiTenantFilter
    config:
      tenantKey: ab7ge
  brokers:
  - name: broker-1
    sniMatchAddress: broker-1.my-tenant2.kafka.com
    endpointRef: my-tls-my-tls-endpoint
    physicalBrokerRef: private-broker-1
  - name: broker-2
    sniMatchAddress: broker-2.my-tenant2.kafka.com
    endpointRef: my-tls-endpoint
    physicalBrokerRef: private-broker-2
  - name: broker-3
    sniMatchAddress: broker-3.my-tenant2.kafka.com
    endpointRef: my-tls-endpoint
    physicalBrokerRef: private-broker-3
physicalClusters:
- name: my-big-cluster
  brokers:
  - name: private-broker-1
    address: beefy:9092
  - name: private-broker-2
    address: chunky:9092
  - name: private-broker-3
    address: stocky:9092
```


Provide an introduction to the proposal. Use sub sections to call out considerations, possible delivery mechanisms etc.

## Affected/not affected projects

Call out the projects in the Kroxylicious organisation that are/are not affected by this proposal. 

## Compatibility

Call out any future or backwards compatibility considerations this proposal has accounted for.

## Rejected alternatives

Call out options that were considered while creating this proposal, but then later rejected, along with reasons why.
