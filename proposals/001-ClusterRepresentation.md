<!-- This template is provided as an example with sections you may wish to comment on with respect to your proposal. Add or remove sections as required to best articulate the proposal. -->

#  Representating Clusters in the Kroxylicious Model.

## Goals

Currently Kroxylicious is limited to the exposing of a single broker of a single broker.   For production use-cases, we need Kroxylicious to support richer topologies, such as:

- exposing several clusters
- exposing clusters that comprise >1 brokers
- presenting a single cluster as if it were many clusters (a pre-requiste for multi-tenancy)

We also want to support topology changes at runtime, such as:

- scaling-up or scaling down of the number of brokers within a cluster that is being exposed by Kroxylicious.
- additions to or removal from the list of clusters being exposed by Kroxylicious.

We want to support TLS connections for both the downstream (client to kroxylicious) and the upstream (kroxylicious to cluster).  For convience in development
and test use-cases we want to support non-TLS too.  As the Apache Kafka protocol does not have an analogue of the [Http Host: header](https://www.rfc-editor.org/rfc/rfc2616#section-14.23), this means that Kroxylicious must be capable of exposing a separate socket per exposed broker in order for traffic to be routed to the correct broker.  In the TLS case, SNI can be used as an alternative to socket per broker.

Filter implementations require knowledge of the current upstream to downstream broker mapping.  This proposal will define an API.

## Current situation

Kroxylicious is currently limited to exposing a single broker of a single cluster.

It is configured with a single listener address where Kroxylicious accepts incoming connections:

```yaml
proxy:
  address: localhost:9192
  logNetwork: false
  logFrames: false
```

and has a list of upstream clusters that provide the cluster being exposed.  Whilst the configuration is a list,
the implementation supports only one element.

```yaml
clusters:
  demo:
    bootstrap_servers: localhost:9092
```

## Proposal

### High Level

Central to the model will be the *virtual cluster*.  This is on the downstream side and is the kafka cluster that the client will connect to.

Each *virtual cluster* will specify an *target cluster*.  The *target cluster* is the model representation of the physical kafka cluster being proxied. The target cluster is on the upstream side.

It is possible for many *virtual clusters* to specify the same *target cluster*.  

Kroxylicious's will install it own -internal- Metadata filter.  It will use the metadata response to discover the target cluster's broker topology and use that information to bind any listening ports required to allow ingress from the upstream.  As the broker topology of the target cluster may change at runtime, kroxylicious must be capable of reacting to this and reflecting this in the listening port and routing used on the upstream side.

There is a choice to be made about whether Kroxylicious proactively discovers metadata for itself, by making its own connection to the target cluster and sending its own metadata request or whether it should piggy-back on metadata request that Kafka Clients make.  The disadvantage with the former is that it requires the Kroxylicious to have permissions to connect to upstream cluster in its own right.    It also implies that kroxylicious will regularly poll for updates to the topology using this side-channel. What if the topology changes in between polls? How would the client RPC responses be rewritten in the meanwhile?  The piggy-back approach has an assumption that clients will send a metadata request. Is this safe?  There is also complexity in the handling of concurrent metadata responses from many client connections.   Thread safety in the code responsible for binding/unbinding ports will be important as will ensuring the code performs well.

Kroxylicious's will install it own -internal- Metadata filter.  It will use the metadata response to discover the target cluster's broker topology and use that information to bind any listening ports required to allow ingress from the upstream.  As the broker topology of the target cluster may change at runtime, kroxylicious must be capable of reacting to this and reflecting this in the listening port and routing used on the upstream si
As Kroxylicious needs its own metadata filter, it makes sense for it to take responsibily for rewriting the broker address in the metadata response.  It will also
take this responsibility for other RPCs carrying broker address information, namely FindCoordinatorResponse and DescribeCluster.   This will relief the user of
kroxylicious of this burden.  The user can of course install their own filters intercepting these RPCs as their use-case demands.


### Detailed


#### Virtual Cluster List

The existing `proxy` configuration will be removed and the existing `clusters` list will be remodelled to provide a list of `virtual clusters`.  A virtual cluster is the cluster that is being presented to the client. 

Each *virtual cluster* will define a mapping to an *upstream cluster*.   The upstream cluster definition provides the bootstrap address of the upstream cluster.
Kroxylicious will use this to discover the broker's topology.  This is described later.

It is permitted for two or more downstream clusters to refer to the same upstream cluster.   This many to one mapping will support multi-tenancy use-cases.

```yaml
virtualClusters:
- name: mycluster1
  upstream:
    bootstrap: 123.123.123.123:9092
    ...
- name: mycluster2
  upstream:
    bootstrap: 123.123.123.123:9092
    ...
```

The next section describes the Virtual Cluster in more details.

#### Virtual Cluster 

The virtual cluster provides a name (used for logging and metric labels) and a clusterId (used to identify the cluster to client as a Kafka RPC level).

The upstream defines the bootstrap address of the upstream cluster.  The upstream may define a clusterId of the upstream.  If this is present, Kroxylicious
will automatically verify that the upstream cluster presents this clusterid as part of the `DescribeCluster` response.  If it does not not, the connection will
be dropped with an error.  This exists to help prevent misconfigurations.

The virtual cluster defines an *endpoint assigner*.  The endpoint assigner will have a pluggable implementation.  Its role is to provide a virtual bootstrap
address for the cluster and provide a function that produces a stable virtual broker address given a broker nodeid.  It is virtual broker addresses that will
be returned to the client as part of the MetadataResponse, FindCoordinatorResponse, DescribeCluster responses.

```yaml
name: mycluster1  # [required] virtual cluster name - must be unique - used for logging and metric label.
clusterId: uid    # [required] virtual cluster name uid  - must be unique - used to identify the cluster to the client.
upstream:         
  bootstrap: 123.123.123.123:9092 # [required] Bootstrap of the upstream cluster
  clusterId: <uuid>               # [optional] asserts the cluster id presented cluster
endpointAssigner:
  type: AssignerType
  config:
   abc: def
   ghi: jkl
```

#### Endpoint Assigner

The endpoint assigner is responsible for assigning network endpoints for the virtual cluster.  It will be a pluggable implementation that will expose
two methods:

```
#InetAddress getBootstrapAddress() - return the bootstrapf for this cluster
#InetAddress getBrokerAddressForNode(int nodeId) - returns a stable address for the broker identified by its nodeId.
#Set<InetAddress> getExclusiveAddresses() - returns the set of addresses which this assigner requires exclusive use
```


XXXXXX [Kroxylicious Class] will use be responsible for binding and unbinding listening ports.  It will use the endpoint assigners to work out which need to be
bound.

The endpoint assigner will accept configuration which will be specific to its implementation.

There will be two implementations:

##### ExclusivePortPerBroker Assigner

The *ExclusivePortPerBroker* assigner allocates each broker an exclusive port.  The port number assignment is driven by a port range.  The broker address
is formed from a pattern.

type: ExclusivePortPerBroker
config:
 bootstrapPort: 9092
 minPort: 19092
 maxPort: 19192
 brokerHostPattern: broker-$(nodeId).foo-kafka.example.com
 brokerPort: $(minPort + nodeId)


##### SniSharedPort Assigner

The *ShareddPortSni* assigner is an implementation that allows the sharing of a single port amongst brokers and virtual clusters.  The advantage of this assigner
is that it will exposes a single port to the world. This simplifies ingress configuration when using Kubernetes (a cloud load balancer can be pointed at the single port).

This assigner requires the use of TLS.  The bootstrap host and broker host addresses will be matched against the SNI name presented in the TLS hello.  This will allow the traffic to be routed appropiately.

type: SniSharedPort
config:
 bootstrapHost: foo-kafka.example.com # host is used for SNI based routing
 brokerHostPattern: broker-${nodeId}.foo-kafka.example.com
 port: 9092






Need some sequence diagrams.







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

## SNI case

In this case, Kroxy listens on a single port.  SNI is used to route traffic to boostrap/brokers.

```yaml
clusterMappings: # <1> - as above
- clusterId: <uuid> # <2> - as above
  upstream:
    bootstrap: 123.123.123.123:9092 # <3> - as above
    requiredClusterId: <uuid> # Optional: <4> - as above
    tls:   # carries trust/SSL client auth for connecting to the upstream
       trust:...
  bindAddress: 0.0.0.0 # Optional. Defaults to all interfaces if unspecified. Used as bind address for all listening sockets.
  
  endpointAssigner:
     type: SniSharedPort
     config:
       bootstrapHost: foo-kafka.example.com # host  is used for SNI based routing
       brokerHostPattern: broker-${nodeId}.foo-kafka.example.com
       port: 9092
  tls:  # 
     key:
     cert:
     cipherSuite:
```

# Non-SNI 

In this case, Kroxy binds a port for bootstrap and dynamically assigns a port 

```yaml
clusterMappings: # <1> - as above
- clusterId: <uuid> # <2> - as above
  upstream:
    bootstrap: 123.123.123.123:9092 # <3> - as above
    requiredClusterId: <uuid> # Optional: <4> - as above
  endpointAssigner:
     type: ExclusivePortPerBroker
     config:
       bootstrapPort: 9092
       minPort: 19092 # <5>
       maxPort: 19192 # <6>
       brokerHostPattern: broker-${nodeId}.foo-kafka.example.com # <8>
       brokerPort: $(minPort + nodeId) # <9>
```



EndpointAssigner - responsibilities

* provides a bootstrap address and port
* assigningg brokers to endpoint addresses and listener ports
* exposes a list of exclusiviely 


for validation, the steward interface exposes a method like EndpointSteward#getExclusiveClaimedPorts().  This allows XXXX to query all the configured endpoint stewards and check for potential port conflicts.  The SniRouting steward, will return an empty list, because it doesn't exlusively claim any port.





Ignore below this line 

====================================






This proposal introduces the concept of _virtual cluster_ and _physical cluster_ into the model.  

A _virtual cluster_ is a kafka cluster that clients connect to. From the perspective of the client, the virtual cluster behaves exactly as a normal kafka cluster would.   Many virtual clusters can be defined with a Kroxylicious instance.  Each _virtual clusters_ comprises one or more _virtual brokers_.  Conceptually, the virtual cluster and virtual broker exists on the [downstream](https://github.com/kroxylicious/design/blob/main/concepts.asciidoc#upstream-vs-downstream) (client side) of Kroxylicious.

A _physical cluster_ is a model representation of a real Apache Kafka cluster.  There is always a one to one correspondance between the _physical cluster_
and a real Apache Kafka cluster. Many physical clusters can be defined with a Kroxylicious instance. Each _physical cluster_ comprises one or more _physical brokers_.  Conceptually, the physical cluster exists on the [upstream](https://github.com/kroxylicious/design/blob/main/concepts.asciidoc#upstream-vs-downstream) (client side) of Kroxylicious.

There will be a mechansim to map between virtual and physical clusters.  This will allow the building useful topologies to serve different use-cases, such as:



## Illustration of many-to-one use-case

![alternative text](https://raw.githubusercontent.com/kroxylicious/design/001-ClusterRepresentation/proposals/001/many-to-one.png)




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
