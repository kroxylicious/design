# Kroxylicious Operator API - Alternative Proposal.

<!-- TOC -->
* [Kroxylicious Operator API - Alternative Proposal.](#kroxylicious-operator-api---alternative-proposal)
* [Background](#background)
* [CRDs](#crds)
* [Personas / Responsibilities](#personas--responsibilities)
  * [Infrastructure admin](#infrastructure-admin)
  * [Developer](#developer)
* [API](#api)
  * [KafkaProxy](#kafkaproxy)
  * [KafkaGateway](#kafkagateway)
  * [VirtualKafkaCluster](#virtualkafkacluster)
  * [KafkaProtocolFilter](#kafkaprotocolfilter)
* [Worked examples](#worked-examples)
  * [On Cluster Traffic - plain downstream & upstream](#on-cluster-traffic---plain-downstream--upstream)
  * [On Cluster Traffic - tls downstream & upstream](#on-cluster-traffic---tls-downstream--upstream)
    * [On Cluster Traffic - tls downstream & upstream - varation using OpenShift Cluster CA generated cert](#on-cluster-traffic---tls-downstream--upstream---varation-using-openshift-cluster-ca-generated-cert)
  * [Off Cluster Traffic (OpenShift Route)](#off-cluster-traffic-openshift-route)
  * [Off Cluster Traffic (Load Balancer)](#off-cluster-traffic-load-balancer)
  * [Upstream specified by Kafka CR](#upstream-specified-by-kafka-cr)
* [Phased High Level Implementation Plan](#phased-high-level-implementation-plan)
* [Not in Scope](#not-in-scope)
<!-- TOC -->
# Background

Keith isn't sure that '[Gateway API flavoured approach](https://github.com/kroxylicious/design/pull/52)' for modelling
ingress is the right one for Kroxylicious Operator. He thinks that our ingress API should work with Gateway APIs, rather than be one itself.  So, this 
has prompted him to think about an alternative API design.

# CRDs

* KafkaProxy CR - an instance of the Kroxylicious
* KafkaGateway CR - Defines a way to access a KafkaProxy
* VirtualKafkaCluster CR - a virtual cluster
* KafkaProtocolFilter CR - a filter definition

![image](diagrams/kroxylicious-operator-apis.png)

https://excalidraw.com/#json=8UKYvKppCHjuVXGjDWVhi,9ixEeUx2ayn6fwlMFixvsA


# Personas / Responsibilities

## Infrastructure admin

Responsible for the proxy tier and how proxies are exposed to the network.

## Developer

Responsible for the configuration of the virtualcluster and filters.
Responsible for providing the virtualcluster TLS key/trust material (in Secret and ConfigMap respectively).
Responsible for providing any key/trust material required to connect to the target cluster (in Secret and ConfigMap respectively).

# API

## KafkaProxy

The KafkaProxy CR is the responsibility of the Infrastructure admin.

Declares an instance of the proxy and defines the gateway mechanisms available to it.

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxy
metadata:
  name: myproxy
spec:

   # Optional - controls the KafkaProxy infrastructure.
   infrastructure:
      # Influences the annotations and labels on all resources created by the operator.
      annotations:
         x: y
      labels:
         x: y
      proxy:
        # Controls specific to operand deployment
        replicas: 2
        resources:
          requests:
            memory: "64Mi"
            cpu: "250m"
#  # Optional: default ordered list of filters to be used by a virtualcluster that doesn't apply it own.  (this doesn't fit well with the Infra role - drop it?).
#  defaultFilterRefs:
#  - group: filter.kroxylicious.io
#    kind: KafkaProtocolFilter
#    name: encryption```

status:
   # status of the proxy tbd
   conditions:
   - status: x
     type: y
     reason: r
   # per listener status 
   gateways:
   - name: myclusterip
     conditions:
     - ...
```

## KafkaGateway

The KafkaGateway CR is the responsibility of the Infrastructure admin.

It declares a named Gateway - in other words, a way for traffic to get to a proxy.  KafkaGateway knows about four types:

* clusterIP - for on-cluster traffic realised using Kubernetes ClusterIP Service. Supports TCP or TLS.
* loadBalancer - for off-cluster realised using a Kubernetes LoadBalancer Service.  Supports TLS only.
* openShiftRoute - for off-cluster realised using OpenShift Routes (OpenShift specific)
* gateway - for off-cluster realised using Gateway API.  Supports `TLSRoutes` with listener type of `passthrough`.

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaGateway
metadata:
  name: myclusterip
spec:
  # reference to the proxy that will use this gateway.
  proxyRef:
    kind: KafkaProxy  # if present must be Gateway, otherwise defaulted
    group: kroxylicious.io # if present must be proxy.kroxylicious, otherwise defaulted=
    name: myproxy  # name of proxy

  # oneOf: clusterIP, loadBalancer, openShiftRoute, gateway
  clusterIP:
    protocol: TCP|TLS (ClusterIP supports both)
    port: # optional, defaults to 9082
  loadBalancer:
    bootstrapAddressPattern: $(vitrtualClusterName).kafka.com 
    brokerAddressPattern: broker-$(nodeId).$(vitrtualClusterName).kafka.com
    port: # optional, defaults to 9082
  openShiftRoute:
    # ingress controller name (optional, if omitted defaults to default in the openshift-ingress-operator namespace).
    resourceRef:
      kind: IngressController  # if present must be IngressController, otherwise defaulted to IngressController
      group: operator.openshift.io # if present must be operator.openshift.io, otherwise defaulted to operator.openshift.io
      name: myingresscontroller
      namespace: openshift-ingress-operator # namespace of the gateway, if omitted assumes namespace of this resource
  gateway:
    type: TLSRoute
    resourceRef:
      kind: Gateway  # if present must be Gateway, otherwise defaulted to Gateway
      group: gateway.networking.k8s.io # if present must be gateway.networking.k8s.io, otherwise defaulted to gateway.networking.k8s.io
      name: foo-gateway  # name of gateway resource to be used
      namespace: namespace # namespace of the gateway, if omitted assumes namespace of this resource
      sectionName: mytlspassthrough # refers to a TLS passthrough listener defined in the Gateway

  # Optional
  infrastructure:
    # Controls the Admin influence the annotations/labels created on the gateway objects (Service, OpenShift Routes, TLSRoutes etc).
    # This lets the Infrastructure admin  specify things like:
    # https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.2/guide/service/annotations/#lb-type
    annotations:
       x: y
    labels:
       x: y
status:
   # describes the validity state of the gateway.  For instance:
   # - for openShiftRoute the operator will verify that the ingress controller exists.
   # - for gateway, it will verify that the gateway exists and the listener is defined as TLS passthrough.
   conditions:
   - status: x
     type: y
     reason: r 
```      

## VirtualKafkaCluster

The VirtualKafkaCluster CR is the responsibility of the Developer.

Declares a virtualcluster.

A Virtualcluster is associated with exactly one KafkaProxy.

It enumerates the gateways that are to be used by the virtualcluster.  It also supplies the virtual cluster gateway specific information
such as the TLS certificates.

The virtualcluster has a reference to a single target cluster which may be expressed using either a reference to a Strimzi Kafka object, or generic bootstraping information.

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: VirtualKafkaCluster
metadata:
  name: mycluster
spec:
  proxyRef:
    kind: KafkaProxy  # if present must be KafkaProxy, otherwise defaulted
    group: kroxylicious.io # if present must be kroxylicious.io, otherwise defaulted
    name: myproxy
 
  # list of gateways the virtual cluster wishes to use.  Each Gateway selected must be one associated with
  # the proxy.  It is legal for the virtualcluster to choose only a subset.
  gateways:
  - name: myclusterip
    tls:
      # server certificate - initial implementation will permit at most one entry in the array. keystore needs to contain a certficate for bootstrap and brokers.  It might be a single certificate with SANs matching all, or keystore with a certificate per host.  We'll rely on sun.security.ssl.X509KeyManagerImpl.CheckType#check to select the most appropiate cert.
      # secrets provided by the Developer.
      certificateRefs:
      - kind: Secret # if present must be Secret, otherwise defaulted to Secret
        group: ""  # if present must be "", otherwise defaulted to ""
        name: servercert
        namespace: # namespace of the secret, if omitted assumes namespace of this resource
      # peer trust
      # configMap provided by the Developer
      trustAnchorRefs:
      - kind: ConfigMap # if present must be ConfigMap, otherwise defaulted to ConfigMap
        group: ""  # if present must be "", otherwise defaulted to ""
        name: trustbundle
        namespace: # namespace of the configmap, if omitted assumes namespace of this resource
      trustOptions:
       clientAuth: REQUIRED
    infrastructure:
      # Controls that let the Developer influence the annotations/labels created on the Gateway objects (Service, OpenShift Routes, TLSRoutes etc).
      # If an annotation or label supplied here duplicates one provided by the KafkaGateway, the one defined by the KafkaGateway takes precendence. 
      # The specific use case for this is https://docs.openshift.com/container-platform/4.17/security/certificates/service-serving-certificate.html#add-service-certificate_service-serving-certificate
      # where the developer wishes their VC to use Certificates created by OpenShift (useful for ClusterIP type TLS).
      annotations:
         x: y
      labels:
         x: y

  # Points to the cluster being proxied.  Can either be Strimzi Kafka resource or endpoint details.
  targetCluster:
    # one of: resourceRef or bootstrapping
    resourceRef:
      kind: Kafka  # must be Kafka
      group: strimzi.io # must be strimzi.io
      name: my-cluster
      listenerName: listener # name of strimzi listener 
    bootstrapping:
       bootstrap: bootstrap:9092
       protocol: TCP|TLS
       nodeIdRanges:
       - name: mybrokers
         range:
          startInclusive: 0
          endExclusive: 3
    tls:
      # Optional - client auth
      # secret provided by the Developer.
      certificateRef:
        kind: Secret # if present must be Secret, otherwise defaulted to Secret
        group: ""  # if present must be "", otherwise defaulted to ""
        name: servercert
        namespace: # namespace of the secret, if omitted assumes namespace of this resource
      # Optional - peer trust
      # configMap provided by the Developer.
      trustAnchorRefs:
      - kind: ConfigMap # if present must be ConfigMap, otherwise defaulted to ConfigMap
        group: ""  # if present must be "", otherwise defaulted to ""
        name: trustbundle
        namespace: # namespace of the configmap, if omitted assumes namespace of this resource

  # ordered list of filters to be used by the virtualcluster
  filterRefs:
  - group: filter.kroxylicious.io
    kind: KafkaProtocolFilter
    name: encryption
status:
   # overall status
   conditions:
   - status: x
     type: y
     reason: r 
   # per gateway status 
   gateways:
   - name: myclusterip
     bootstrap: xxx.local:9082   # the bootstrap address
     protocol: TCP|TLS
     conditions:
     - ...
   # per filter status 
   filters:
   - name: myclusterip
     conditions:
     - ...
```

## KafkaProtocolFilter

The VirtualKafkaCluster CR is the responsibility of the Developer - As per current implementation.

```yaml
apiVersion: filter.kroxylicious.io/v1alpha1
kind: KafkaProtocolFilter
metadata:
  name: myfilter
spec:
  type: io.kroxylicious.filter.encryption.RecordEncryption
  config:
    kms: Foo
    kmsConfig: {}
    selector: Bar
    selectorConfig: {}
```

# Worked examples

## On Cluster Traffic - plain downstream & upstream

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxy
metadata:
  name: myproxy
spec: {}
```

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaGateway
metadata:
  name: myclusterip
spec:
  proxyRef:
    name: myproxy
  clusterIP:
    protocol: TCP
    port: 9082
```

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: VirtualKafkaCluster
metadata:
  name: mycluster
spec:
  proxyRef:
    name: myproxy
    kind: KafkaProxy
    group: kroxylicious.io

  gateways:
  - name: myclusterip

  targetCluster:
    bootstrapping:
       bootstrap: upstream:9092
       protocol: TCP
       nodeIdRanges:
       - name: mybrokers
         range:
          startInclusive: 0
          endExclusive: 3
  filterRefs:
  - group: filter.kroxylicious.io
    kind: KafkaProtocolFilter
    name: encryption 
```

What would operator create:
* kroxylicious deployment, 1 replica
* proxy relies on port based routing (needs new PortPerNode scheme that allows the Operator to control the ports precisely.  This is needed to prevent the potential for "crossed-lines" during reconcilations.)
* 1 ClusterIP services (with n+1 ports) - operator needs to _deterministically_ assign a block of ports for this VC and create the port/target mapping in the Service accordingly.
* Kafka Clients connect to serviceaddress:9082 

## On Cluster Traffic - tls downstream & upstream

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxy
metadata:
  name: myproxy
spec: {}
```

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaGateway
metadata:
  name: oncluster
spec:
  proxyRef:
    name: myproxy

  clusterIP:
    protocol: TLS
    port: 9082
```

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: VirtualKafkaCluster
metadata:
  name: mycluster
spec:
  proxyRef:
    name: myproxy
    kind: KafkaProxy
    group: kroxylicious.io

  gateways:
  - name: myclusterip
    tls:
      certificateRef:
         ...

  targetCluster:
    bootstrapping:
       bootstrap: upstream:9092
       protocol: TLS
       nodeIdRanges:
       - name: mybrokers
         range:
          startInclusive: 0
          endExclusive: 3

  filterRefs:
  - group: filter.kroxylicious.io
    kind: KafkaProtocolFilter
    name: encryption 
```

What the Developer would provide:
* secret containing server certificate to be used by the virtual cluster.  SAN name would need to match the service that will be created by the Operator (documentation required).

What would operator create:
* kroxylicious deployment, 1 replica
* proxy relies on port based routing  (needs new PortPerNode scheme that allows the Operator to control the ports precisely.  This is needed to prevent the potential for "crossed-lines" during reconcilations.)
* 1 ClusterIP services (with n+1 ports) - operator needs to _deterministically_ assign a block of ports for this VC and create the port/target mapping in the Service accordingly.
* Kafka Clients connect to serviceaddress:9082 


### On Cluster Traffic - tls downstream & upstream - varation using OpenShift Cluster CA generated cert

KafkaProxy and KafkaGateway as above

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: VirtualKafkaCluster
metadata:
  name: mycluster
spec:
  proxyRef:
     ...

  gateways:
  - name: myclusterip
    infrastructure:
       annotations:
         service.beta.openshift.io/serving-cert-secret-name=myservingcert   # Tells openshift to generate a secret
    tls:
      certificateRefs:
      - name: myservingcert
  targetCluster:
     ...

  filterRefs:
     ...
```

What the Developer would provide:
(nothing - openshift is generating the serving cert for us and providing DNS)

What would operator create:
(as above)


## Off Cluster Traffic (OpenShift Route)

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxy
metadata:
  name: myproxy
spec: {}
```

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaGateway
metadata:
  name: myopenshiftroute
spec:
  proxyRef:
    name: myproxy

  openShiftRoute: {}
```

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: VirtualKafkaCluster
metadata:
  name: mycluster
spec:
  proxyRef:
    name: myproxy
    kind: KafkaProxy
    group: kroxylicious.io

  gateways:
  - name: myopenshiftroute
    tls:
      certificateRef:
         ...

  targetCluster:
     bootstrapping:
       bootstrap: upstream:9092
       protocol: TLS
       nodeIdRanges:
       - name: mybrokers
         range:
          startInclusive: 0
          endExclusive: 3

  filterRefs:
  - group: filter.kroxylicious.io
    kind: KafkaProtocolFilter
    name: encryption 
```

What the Developer would provide:
* secret containing server certificate with SAN names matching the hostnames applied to the routes

What would operator create:
* kroxylicious deployment, 1 replica
* proxy relies on SNI based routing (use SNI scheme)
* ClusterIP service called `myopenshiftroute-service` (shared)
* n+1 OpenShift Routes configured for pass-through. The `to` points to the `myopenshiftroute-service`.

Note: that the operator would write the virtualcluster proxy config based on the hostnames assigned to the Routes by the Ingress Controller.



## Off Cluster Traffic (Load Balancer)

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxy
metadata:
  name: myproxy
spec: {}
```

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaGateway
metadata:
  name: myloadbalancer
spec:
  proxyRef:
    name: myproxy

  loadBalancer:
    bootstrapAddressPattern: $(vitrtualClusterName).kafka.com 
    brokerAddressPattern: broker-$(nodeId).$(vitrtualClusterName).kafka.com
    port: 9082
```

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: VirtualKafkaCluster
metadata:
  name: mycluster
spec:
  proxyRef:
    name: myproxy
    kind: KafkaProxy
    group: kroxylicious.io

  gateways:
  - name: myloadbalancer
    tls:
      certificateRef:
         ...

  targetCluster:
     bootstrapping:
       bootstrap: upstream:9092
       protocol: TLS

  filterRefs:
  - group: filter.kroxylicious.io
    kind: KafkaProtocolFilter
    name: encryption 
```

What Developer would provide:

* DNS configuration that resolves the virtual clusters names to the service's assigned ClusterIP.
* secret containing server certificate with SAN names matching the hostnames applied to the routes

What would operator create:
* kroxylicious deployment, 1 replica
* proxy relies on SNI based routing (use SNI scheme)
* LoadBalancer service called `myloadbalancer-service` (shared)



## Upstream specified by Kafka CR

We'd also allow the upstream t be specified by a Kafka CR.  This would be useful for use-cases where the KafkaProxy is
deployed to same cluster as the Kafka. This reduces the amount of configuration as the operator can take advantage of
the listener status section reported by Strimzi.

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxy
metadata:
  name: myproxy
spec: {}
```

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaGateway
metadata:
  name: myclusterip
spec:
  proxyRef:
    name: myproxy
  clusterIP:
    protocol: TCP
    port: 9082
```

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: VirtualKafkaCluster
metadata:
  name: mycluster
spec:
  proxyRef:
    name: myproxy
    kind: KafkaProxy
    group: kroxylicious.io

  gateways:
  - name: myclusterip

  targetCluster:
    resourceRef:
      kind: Kafka  
      group: strimzi.io 
      name: my-cluster
      listenerName: mylistener

  filterRefs:
  - group: filter.kroxylicious.io
    kind: KafkaProtocolFilter
    name: encryption 
```

# Phased High Level Implementation Plan

1. ClusterIP/TCP

* ClusterIP/TCP support only
* Operator restricted to max of 1 gateway per proxy (in other words matches the current capabilities of Kroxylicious operand)
* Target Cluster `bootstrapping` supported -  TCP only.  No Kafka refs.
* Simple status section reporting the bootstrap.
* Any changes to any KafkaProxy/KafkaGateway/VirtualKafkaCluster/KafkaProtocolFilter CRs or secrets providing TLS material will cause the KafkaProxy Deployment to roll.
* Start building out system test suite

2. ClusterIP/TLS

* Adds basic TLS support for downstream side
* `cerificateRefs` array limited to single secret (in other words matches the current capabilities of Kroxylicious)
* support only one kind of key material (suggest secret containing PEM formatted `tls.crt` and password-less `tls.key`)
* Enhances status section ->  more errors and warnings reported

3. LoadBalancer

4. OpenShift Route

5. Upstream TLS and other TLS controls.

* TLS controls like protocol & cipher suite restrictions   

6. Allow the upstream to be specified by the Strimzi Kafka reference.

* Use the Kafka CR status to provide things like TLS settings

Parallel work:

~1. Kroxylicious - server certificate grab bag support (serve the right certificate and intermediates based on SNI match)~ _(edit: not required)_
1. Allow Kroxylicious to have multiple listeners per virtual cluster _routed to the same target cluster listener_.  This makes the cluster accessible by both on-cluster and off-cluster workloads.
1. Allow KafkaProtocolFilters to reference secrets
1. Proxy dynamically reloads files providing TLS material (i.e. allows certificates to be rolled).

# Not in Scope

1. Gateway API integration.   This proposal imagines integrating with the `TLSRoute` Gateway API object.   This Gateway API isn't yet considered stable.   There are some Gateway API implementations
   providing it as a beta feature.   We might experiment with those, but I don't imaging we'll actually implement `gateway: {}` part of KafkaGateway until the API firms up.
1. Allow virtual cluster listener to target specific listeners of the target cluster.   This might be useful say if user want
   to use different SASL mechanisms for different applications (say OAUTH for webapps and SCRAM for traditional apps).


