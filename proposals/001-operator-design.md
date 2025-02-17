<!-- This template is provided as an example with sections you may wish to comment on with respect to your proposal. Add or remove sections as required to best articulate the proposal. -->

# Kroxylicious Operator

Deploying Kroxylicious on kubernetes is complicated. The user has to create numerous resources to configure and expose
the proxy. The responsibilities for infrastructure (network exposition/certificates) and business logic are mingled, so
making the Proxy self-service is challenging. We can build an Operator that makes deployment easy and offer a useful
separation of concerns, so that different personas can collaborate, taking advantage of Kubernetes RBAC.

<!-- TOC -->
* [Kroxylicious Operator](#kroxylicious-operator)
  * [Scope](#scope)
  * [Proposal](#proposal)
    * [Principles](#principles)
  * [Proposed Custom Resources](#proposed-custom-resources)
    * [KafkaGateway Custom Resource](#kafkagateway-custom-resource)
      * [SNI networking required](#sni-networking-required)
      * [Example KafkaGateway status](#example-kafkagateway-status)
    * [KafkaGatewayParameters Custom Resource](#kafkagatewayparameters-custom-resource)
      * [Example KafkaGatewayParameters CR](#example-kafkagatewayparameters-cr)
    * [KafkaBackendTLSPolicy Custom Resource](#kafkabackendtlspolicy-custom-resource)
    * [KafkaRoute Custom Resource](#kafkaroute-custom-resource)
      * [Relation to HTTPRoute](#relation-to-httproute)
      * [Broker Topology](#broker-topology)
      * [Problem Making things work with Hostnames](#problem-making-things-work-with-hostnames)
      * [A possible solution](#a-possible-solution)
    * [KafkaFilter Custom Resource](#kafkafilter-custom-resource)
      * [Filter Secrets](#filter-secrets)
  * [TLS Certificates](#tls-certificates)
  * [Network Exposition](#network-exposition)
    * [Background - Proxy Exposition Capabilities](#background---proxy-exposition-capabilities)
    * [Operator Exposition Strategy](#operator-exposition-strategy)
    * [1. In-Cluster access](#1-in-cluster-access)
    * [2. Off-Cluster access](#2-off-cluster-access)
    * [3. SNI external DNS using OpenShift Routes](#3-sni-external-dns-using-openshift-routes)
    * [4. In-cluster and off-cluster access](#4-in-cluster-and-off-cluster-access)
    * [5. Multiple Routes](#5-multiple-routes)
<!-- TOC -->

## Scope

The scope of this document is to propose the minimum viable Operator CRD design that could deliver a production
Kroxylicious installation, ready for clients to connect to securely.

## Proposal

We propose aligning the Custom Resource Definitions as closely as we can with the Gateway API, a Kubernetes standard for
declaring ingress/routing. Using an established API will allow us to lean on their experience in designing a proxying
API and use already defined concepts like Gateway/Route, which may already be familiar to some users. We also would
leave the door open to implementing the Gateway API directly later.

KafkaGateway API could evolve into the abstraction for connecting to Kafka on Kube. It wouldn't matter if your Kafka was
a real kafka cluster, a remote kafka cluster or a proxied kafka cluster. The API would be the same. As a user of the
API, you wouldn't know nor care.

The Gateway API has a well-defined notions of role and responsibilities which is mapped well in the Kube RBAC. This
supports the principle of least privilege.

We propose using TLS with SNI as the network exposition mechanism. Users will bring their own certificates. Using SNI is
a much better fit for the Gateway API than plain access, because we can route to multiple clusters per ip/port (listener
in Gateway). With plain access we need a unique listener for each virtual broker, meaning KafkaGateway and KafkaRoute
would have to change in lockstep, rather than having some ability to change independently. See here for details on why
plain access is a poor fit.

### Principles

1. Align as closely as we can with Gateway API. Offer a KafkaGateway CR and KafkaRoute CR. The hope is we can have a
   KafkaGateway API that (apart from the kind and apiVersion) is a compatible subset of Gateway. I.e., you could take
   any valid KafkaGateway CR, and changing just its kind and apiVersion, you would have a valid Gateway CR. By not
   adopting the real Gateway API from the start we’re giving ourselves an escape hatch should we find ways in which it’s
   too constraining.
2. In-cluster access should be easy. Users should be able to configure a KafkaGateway/KafkaRoute such that clients in
   the same kubernetes cluster can connect to it.
3. Off-cluster access should be possible. Users should be able to expose their kafka outside the kubernetes-cluster.
   More user legwork is permissible, such as the user being responsible for external DNS or creating openshift routes.
   Though the more seamless the better
4. Security matters. Proxies deployed by the Operator must support upstream and downstream TLS (mutual TLS on upstream
   and downstream can be added later). Filters should have access to secrets too, so that Record Encryption can access
   API secrets for example.
5. Certificate generation handled externally. The proxy will consume Secrets emitted by established technology like
   cert-manager and Strimzi, following their conventions. The operator will not attempt to orchestrate generation.
6. Initially support PEM KeyPairs only for TLS configuration. Most Gateway technology, like nginx etc, is not java-based
   and so doesn’t operate on keystore formats. So the path of least surprise is to use the same inputs, PEM formatted
   files containing keys and certs.

## Proposed Custom Resources

We propose implementing five Custom Resources:

1. [KafkaGateway](#kafkagateway-custom-resource) (analogous to Gateway in Gateway API)
2. [KafkaGatewayParameters](#kafkagatewayparameters-custom-resource) (contains additional proxy config that doesn’t fit
   in the KafkaGateway)
3. [KafkaBackendTlsPolicy](#kafkabackendtlspolicy-custom-resource)
4. [KafkaRoute](#kafkaroute-custom-resource) (HttpRoute is the closest analogue in Gateway API)
5. [KafkaFilter](#kafkafilter-custom-resource) - filter definitions referenced by KafkaRoutes.

### KafkaGateway Custom Resource

```yaml
---
kind: KafkaGateway
apiVersion: kroxylicious.io/v1alpha1
metadata:
  name: simple
spec:
  listeners: # at least one listener is required
    - name: my-listener # must be unique within a KafkaGateway
      port: 9092 # required
      protocol: kroxylicious.io/kafka-tls #required
      tls:
        mode: Terminate # optional, but must be Terminate
        certificateRefs: # required, non-empty
          - # Certificate (and keys) to be presented to clients
            group: "" # Must be the empty string (i.e. kube core API group)
            kind: Secret # Must be Secret
            name: "" # Required
            namespace: "" # Must not be present (only support local certs for now)
        frontendValidation:
          caCertificateRefs:
            - # CA certificates which we trust, (will be used to sign client certificates) 
              group: "" # Must be the empty string (i.e. kube core API group)
              kind: Secret # Must be Secret
              name: "" # Required
              namespace: "" # Must not be present (only support local certs for now)
          options:
            kroxylicious.io/enabled-protocols: TLSv1.3
            kroxylicious.io/disabled-protocols: TLSv1.2
            kroxylicious.io/enabled-cipher-suites: TLS_AES_256_GCM_SHA384
            kroxylicious.io/disabled-cipher-suites: TLS_CHACHA20_POLY1305_SHA256
    # allowedRoutes: # Not supported for now
  # addresses: # Not supported for now
  infrastructure:
    labels:
      example.com/foo: bar
    annotations:
      example.com/foo: bar
    parametersRef:
      group: kroxylicious.io
      kind: KafkaGatewayParameters
      name: my-params
  backendTLS:
    clientCertificateRef:
      group: "" # Required, but must be the empty string (i.e. kube core API group)
      kind: Secret # required, but must be Secret
      name: "" # Required
      namespace: "" # Must not be present
```

#### SNI networking required

A consequence of this Gateway compatibility semantic is that it’s incompatible with the port-per-broker networking in
the proxy. That’s because port-per-broker necessarily requires the specification of multiple ports, but
Gateway.spec.listeners[] has a required, but single-valued, port field. That’s OK, because we were expecting to support
only SNI networking, though that can require more work by the user in terms of supplying all the necessary certificates.

#### Example KafkaGateway status

Applying the compatibility principle we can see that the schema for the KafkaGateway CR’s status must be the same as for
Gateway’s status, with conditions as well as listener and address specific statuses.

```yaml
---
kind: KafkaGateway
apiVersion: kroxylicious.io/v1alpha1
metadata:
  name: simple
spec:
# ...
status:
  conditions:
    - observedGeneration: 1 # the KafkaRoute's generation
      type: Ready
      status: True
  listeners:
    - name: my-listener
      supportedKinds:
        - group: kroxylicious.io
          kind: KafkaRoute
  addresses:
    -
```

### KafkaGatewayParameters Custom Resource

This is the other end of the KafkaGateway.spec.infrastructure.parametersRef reference. It’s essentially a place to dump
all the proxy config which doesn’t fit nicely into the KafkaGateway (aka, Gateway) API.

#### Example KafkaGatewayParameters CR

```yaml
---
kind: KafkaGatewayParameters
apiVersion: kroxylicious.io/v1alpha1
metadata:
  name: my-params
spec:
  replicas: 3 # the number of proxy pods to create
  management: # optional, but omission =/=> no http server, 
  # because we always expose kube health endpoints
  port: 8080 # this port is also used to expose kube health
  prometheusMetrics: true
```

### KafkaBackendTLSPolicy Custom Resource

We need to support customising TLS trusted certificates on the backend connection to the target cluster.

In the Gateway API, GatewaySpec has a backendTLS property that contains a reference to a single clientCertificateRef for
that Gateway.

The use of spec.backendTLS on its own limits possibilities by requiring that all Kafka clusters are configured to trust
a common CA certificate used to sign the clientCertificateRef.

The Gateway API also has a BackendTLSPolicy (at v1alpha3), described here, which could be used to support backends with
different trusted CA certificates within the same gateway. However, that’s still a bit of a compromise:
BackendTLSPolicy could be limiting in the long term if proxy was performing its own SASL authentication with the
brokers (i.e. how a proxy connect to a backend in general might depend on more that hostname, port and TLS settings, but
also some SASL settings).

```yaml
# example with caCerts
---
kind: KafkaBackendTLSPolicy
apiVersion: kroxylicious.io/v1alpha1
metadata:
  name: my-tls-policy
spec:
  targetRefs:
    - kind: Service
      name: my-kafka-bootstrap-service
      namespace: kafka
      sectionName: tls-port # port name on service
  validation:
    caCertificateRefs:
      - kind: Secret
        name: my-ca-cert-secret
    hostname: my-kafka-bootstrap-service.kafka
  options:
    kroxylicious.io/enabled-protocols: TLSv1.3
    kroxylicious.io/disabled-protocols: TLSv1.2
    kroxylicious.io/enabled-cipher-suites: TLS_AES_256_GCM_SHA384
    kroxylicious.io/disabled-cipher-suites: TLS_CHACHA20_POLY1305_SHA256
```

### KafkaRoute Custom Resource

#### Relation to HTTPRoute

KafkaRoute is inspired by HttpRoute, but it is necessarily quite different because KRPC is not HTTP. It lacks things
like headers and methods, which means HTTPRoute features such as the matches field of rules don’t really have an analog
in Kafka.

#### Broker Topology

For convenient in-cluster access we need to generate a service per broker, therefore we need to know the target broker
ids. For now we will require users to explicitly describe the target cluster node ids so the operator can manifest these
services.

#### Problem Making things work with Hostnames

There are at least a couple of ways in which Kafka networking differs from HTTP and which doesn’t work nicely with the
Gateway API.

* HTTP doesn’t routinely propagate host names though the protocol in the same that Kafka does (so a proxied HTTP
  server’s network address doesn’t leak out to clients accessing it via a proxy)
* Gateway API can use a single Kubernetes resource (Service) to represent an HTTP-based service, but not so with Kafka,
  where you need a family of Services. Likewise with hostnames.
* In Kubernetes a Service's metadata.name must be a single DNS label. In order to represent all the brokers in a Kafka
  cluster we need that label to have additional structure (naming convention). E.g. foo-broker-0, foo-broker-1 etc. We
  need the ‘foo’ part because we'd like to support multiple clusters in the same namespace (so bar-broker-0,
  bar-broker-1). But applying additional structure to the DNS label like this is not compatible with TLS wildcard
  certificates. So we end with a certificate provisioning problem (e.g. Kafka cluster scale up => Need more Services =>
  Need new certificates).
* It follows from this that the hostname property on Gateway is kind of useless for Kafka.
    * For a non-wildcard hostname it must identify a single broker, which is useless.
    * For a wildcard hostname in the cluster.local domain it must identify all the brokers (from multiple Kafka
      clusters) in that namespace.

#### A possible solution

* Don’t support hostname on KafkaGateway at all (which is compatible because it’s optional in Gateway)
* Support hostname on KafkaRoute, but don’t support traditional wildcards (using *, which can match multiple DNS labels)
* Instead, support a different wildcard syntax, using %, which matches only a part of a single DNS label (require it to
  be in the first label and to have some prefixing characters)

In the Gateway API you can declare a list of hostnames for a route. In the proxy we have two sets of hostnames to route
to a Virtual Cluster; a bootstrap SNI hostname, and a brokerAddress pattern which routes a pattern to the right cluster.
We would like each hostname entry in the list to fully describe a virtual cluster. So we introduce a hostname scheme
convention:

1. Bootstrap address = ${prefix}bootstrap.${suffix}
2. Broker address for broker id N = ${prefix}broker-${N}.${suffix}

By requiring a prefix we can validate that the hostnames are disjoint and we can unambiguously route traffic for a
hostname to a Route.

This means the user will specify a hostname with notation like my-cluster-%.kafka.example.com and, following our
convention, we will determine that the bootstrap hostname is my-cluster-boostrap.kafka.example.com and the node id
pattern is my-cluster-broker-$(nodeId).kafka.example.com.

We don’t anticipate users needing great control over the first hostname section.

Example KafkaRoute spec

```yaml
---
kind: KafkaRoute
apiVersion: kroxylicious.io/v1alpha1
metadata:
  name: my-route
spec:
  parentRefs:
    - # A reference to the KafkaProxies this Route is a part of
      group: kroxylicious.io # Must be kroxylicious.io
      kind: KafkaGateway # Must be KafkaGateway
      name: simple
      sectionName: my-listener
      brokers:
        - advertisedBrokerIds: [ 1,2,3,4,5,6,7,8,9 ]
          brokerIdentityMapping: identity | hash # to be added eventually, default is identity
      hostnames:
        # When a hostnamePattern ends with the cluster/namespace 
        # domain we'd create ClusterIP Services automatically. Else
        # we expose a single LoadBalancer service.
        - foo-%.svc.ns.cluster.local
        - bar-%.example.net
        - bar-%.example.com
      rules:
    - name: my-rule # required
      filters: # Deviate from the HttpRoute model, 
          # because we want first-class 
            # filter resources
        - group: filter.kroxylicious.io # required, but must be this value
          kind: KafkaFilter # required, but must be Filter
          name: encryption # required
      backendRefs:
        - group: '' # must be empty
          kind: Service # must be Kafka
          namespace: kafka # local namespace is absent
          name: my-cluster # required
          port: 9092
```

### KafkaFilter Custom Resource

```yaml
---
kind: KafkaFilter
apiVersion: filter.kroxylicious.io/v1alpha1
metadata:
  name: encryption
  namespace: my-proxy
spec:
  type: io.kroxylicious.filter.encryption.RecordEncryption
  config:
    kms: Foo
    kmsConfig: { }
    selector: Bar
    selectorConfig: { }
```

Where the spec contains the filter type, and arbitrary configuration yaml. The Operator will not be aware of the details
of how to configure each filter type. It will simply forward through the whole config object as YAML.

#### Filter Secrets

Users will need a way to wire secrets into their Filter configurations, for example to configure API keys for Record
Encryption.

A naive way would be for the KafkaFilter CR to define a list of secrets and where to mount them and the operator would
honour that. Users would have to be aware of which locations are safe to mount to and the Operator would need to prevent
conflicts.

Another idea is to have some syntax embedded in the config like:

```yaml
metadata:
  name: encryption
  namespace: my-proxy
spec:
  type: io.kroxylicious.filter.encryption.RecordEncryption
  config:
    kms: Foo
    kmsConfig:
      myApiTokenFile: $(secretFile:secretName:subPath) # secret will be mounted into container and config replaced with path to secret
      mySecretDir: $(secretDir:secretName) # secret will be mounted into container and config replaced with path to secret dir
    selector: Bar
    selectorConfig: { }
```

Downside being we introduce an Operator specific syntax that we now need to explain to users. On the upside the Operator
is in control of the mounts, we can force them to be in a safe location and never conflict.

## TLS Certificates

Currently downstream TLS is configured per Virtual Cluster. Multiple VirtualClusters can be associated with a single
port and different certificates will be presented to the client based on the SNI hostname received by the proxy.
Downstream trust is also configured per Virtual Cluster.

This is relevant because in the Gateway API, a listener (ip/port) can have a list of certificates, but there is no
defined mechanism for associating specific certificates with specific routes. We will have to implement this.

As mentioned in the introduction, there is an issue in that the Gateway API enables you to specify a list of
certificates for a listener (ip/port), and then in the Route we define the hostnames we want to route to each Virtual
Cluster. The problem is we may want to use certificate X for virtual cluster Y exposed as my-cluster-%.example.com and
certificate z for virtual cluster S exposed as another-cluster-%.old-domain.com. We need a way for the VirtualCluster to
pick a certificate associated with the listener.

We propose that a Virtual Cluster should have a new way to be configured with certificates. A virtual cluster should be
configurable with a Key Pair Set. Where we pass it a list of KeyPairs like:

```yaml
tls:
  key:
    keyPairs:
      - privateKeyFile: /opt/kroxylicious/server/key-material/tls.key
        certificateFile: /opt/kroxylicious/server/key-material/tls.crt
      - privateKeyFile: /opt/kroxylicious/server/key-material-2/tls.key
        certificateFile: /opt/kroxylicious/server/key-material-2/tls.crt
```

Then the Proxy will be responsible for determining which certificate to use for the virtual cluster based on the SNI
bootstrap address. We will look into the certificates and discover which ones contain the bootstrap address in the
SANs (or fallback to common name if SANs not present?). Then using some criteria we will pick the ‘best’ cert (using
expiry time perhaps).

The end result is that all virtual clusters associated with a port can have all the certificates of the listener wired
into them, and they will pick the certificate to use for each Virtual Cluster.

## Network Exposition

This section covers how the Operator will manifest the above resources into kubernetes objects and Proxy Configuration
so that clients can access the proxy.

### Background - Proxy Exposition Capabilities

A fundamental aspect of Apache Kafka is that Kafka clients need to be able to directly address every broker in the
cluster. The client obtains the broker identities/addresses and partition layouts, then it sends messages directly to
the brokers it wants to produce/fetch data to/from. The only mechanism used to identify brokers is networking. That is,
the clients connect by IP address or domain name to each broker, and know which broker ID they are communicating with.
There is no support in the kafka protocol for anything equivalent to the HTTP Host header, where the protocol message
identifies the desired host, enabling proxies to route messages based on the message contents, rather than some facet of
the network connection (though we can use SNI in the proxy to achieve something like this).

A relevant aspect of the current proxy implementation is that the proxy is transparent in the sense that it only
intercepts and proxies messages from client and server. The proxy piggy-backs on a client connection, relying on the
client to drive SASL authentication, and intercepting metadata responses to discover the broker addresses. It does not
actively make its own connections to the target cluster to discover topology and relies on standard client behaviour to
obtain broker addresses.

Another relevant aspect is that the current proxy implementation is identityless. Any proxy instance can handle a client
connection for any target broker. This is convenient as we can scale the number of proxies independently of the scale of
the Kafka cluster. Enabling us to give the proxies resources tailored to their workload.

Putting those together we require each proxy instance to:

1. accept connections from clients for any proxied broker
2. identify which broker the client is trying to connect to (based on SNI hostname or TCP port)
3. If the broker metadata has been intercepted already, connect to the relevant broker and start forwarding, else
   discover the metadata

To implement this in the proxy we have two mechanisms to allow a single proxy instance to handle connections for all
brokers, and route those connections off to the identified broker.

1. [Port-per-broker](https://kroxylicious.io/docs/v0.9.0/#broker-address-provider), where the proxy binds a port for
   each broker ID specified by the user (and a bootstrap port). The port therefore identifies the broker.
2. [SNI](https://kroxylicious.io/docs/v0.9.0/#sni-routing-address-provider), where the proxy uses the TLS Server Name
   Indicator to obtain the hostname the client is attempting to connect to. We then use a user-configured pattern to
   extract the broker ID. SNI can use a single port to serve multiple virtual clusters, which as noted in the docs is
   friendly to public cloud load balancers.

With both strategies the proxy does not interfere with the broker/replica topology, the client is aware of the target
topology and partition mappings. So if the target cluster is expanded the client must be able to address those new
brokers. Meaning that in port-per-broker mode we must bind more ports to cover the new brokers (or overprovision ports
in anticipation of expansion). With SNI this responsibility is outside the proxy in the DNS/network layer, the user must
ensure that new broker IDs will be routed correctly to the proxy.

### Operator Exposition Strategy

The drawback of port-per-broker is that we require one port to address one virtual broker. In the Gateway API a listener
represents an ip/port and a route can be associated with a listener. Therefore, we would need a listener for every
virtual broker and would be unable to configure a KafkaRoute independently of the KafkaGateway, they would have to move
in lockstep, each route implies the need for additional listeners. It is a really awkward fit for the Gateway API where
we typically would be able to associate numerous routes with a listener, and be able to add/remove listeners without
having to modify the Gateway with every change.

SNI uses fewer resources (all brokers of a virtual cluster share a port, all virtual clusters can optionally share a
port) and requires TLS (which we should recommend for all production installations), but the problem of addressing the
target brokers may become the user’s problem. For off-cluster access their DNS systems must be able to address all
target brokers. Perhaps they could set up a wildcard DNS record for `*.my-kafka-virtual-cluster.my-host.com` pointing at
a pool of proxies. (note that kubernetes does not support wildcard DNS for services). For in-cluster access the Operator
could manifest a service for each bootstrap and broker host.

SNI is a much better fit for the Gateway API as a single listener (ip/port) can be used to route traffic for numerous
hostnames. We will have some degree of independence where a Gateway can declare the ports it exposes, configure the
certificates for each of those ports. Then Routes can be attached to route specific hostnames through to a particular
virtual cluster.

### 1. In-Cluster access

```yaml
---
kind: KafkaGateway
apiVersion: kroxylicious.io/v1alpha1
metadata:
  name: simple
  namespace: my-namespace
spec:
  listeners:
    - name: my-listener
      port: 9092 # required
      protocol: kroxylicious.io/kafka-tls
      tls:
        certificateRefs:
          - # user supplied secret containing tls.crt and tls.key
            kind: Secret
            name: my-cert
            namespace: my-namespace
---
kind: KafkaRoute
apiVersion: kroxylicious.io/v1alpha1
metadata:
  name: my-route
  namespace: my-namespace
spec:
  parentRefs:
    - group: kroxylicious.io
      kind: KafkaGateway
      name: simple
      sectionName: my-listener
      brokers:
        - advertisedBrokerIds: [ 1,2,3 ]
          brokerIdentityMapping: identity
      hostnames:
        - my-cluster-%.svc.cluster.local
      rules:
        - name: my-rule
          filters: [ ]
          backendRefs:
            - kind: Service
              namespace: kafka
              name: my-cluster
              port: 9093
```

Because the hostname is suffixed with `svc.cluster.local` the operator will infer that we want to expose this hostname
in-cluster. The operator will create:

1. A ClusterIP Service named `my-cluster-bootstrap` mapping port 9092 to all the Proxy instances
2. A ClusterIP Service named `my-cluster-broker-1` mapping port 9092 to all the Proxy instances
3. A ClusterIP Service named `my-cluster-broker-2` mapping port 9092 to all the Proxy instances
4. A ClusterIP Service named `my-cluster-broker-3` mapping port 9092 to all the Proxy instances

The certificate secret will be mounted into the pod at a known location
like `/opt/kroxylicious/secrets/tls/${listenerName}/${certSecretName}/`

The proxy will be configured with a single VirtualCluster with SNI exposition (bootstrap ==
my-cluster-bootstrap.my-namespace.svc.cluster.local, brokerPattern = my-cluster-broker-$(nodeId)
.my-namespace.svc.cluster.local).

The VirtualCluster will have the certificate wired in and know how to select the certificate as discussed here.

The virtual cluster target cluster bootstrap will be configured as `my-cluster.kafka:9093`

From there, the client can bootstrap with `my-cluster-bootstrap.my-namespace.svc.cluster.local:9092` within the cluster.

### 2. Off-Cluster access

```yaml
---
kind: KafkaGateway
apiVersion: kroxylicious.io/v1alpha1
metadata:
  name: simple
  namespace: my-namespace
spec:
  listeners:
    - name: my-listener
      port: 9092 # required
      protocol: kroxylicious.io/kafka-tls
      tls:
        certificateRefs:
          - # user supplied secret containing tls.crt and tls.key
            kind: Secret
            name: my-cert
            namespace: my-namespace
---
kind: KafkaRoute
apiVersion: kroxylicious.io/v1alpha1
metadata:
  name: my-route
  namespace: my-namespace
spec:
  parentRefs:
    - group: kroxylicious.io
      kind: KafkaGateway
      name: simple
      sectionName: my-listener
      brokers:
        - advertisedBrokerIds: [ 1,2,3 ]
          brokerIdentityMapping: identity
      hostnames:
        - my-cluster-%.example.com
      rules:
        - name: my-rule
          filters: [ ]
          backendRefs:
            - kind: Service
              namespace: kafka
              name: my-cluster
              port: 9093
```

Because the hostname is not suffixed with `svc.cluster.local` the operator will infer that we want to expose this
hostname off-cluster.

The operator will create a LoadBalancer Service named `my-route` mapping port 9092 to all the Proxy instances

The proxy will be configured with a single VirtualCluster with SNI exposition (
bootstrap == `my-cluster-bootstrap.example.com`, brokerPattern = `my-cluster-$(nodeId).example.com`).

The VirtualCluster will have the certificate wired in and know how to select the certificate as discussed here.

The virtual cluster target cluster bootstrap will be configured as `my-cluster.kafka:9093`

The user will be responsible for configuring external DNS to route those hostnames to the loadbalancer IP and they can
bootstrap with `my-cluster-bootstrap.example.com:9092`

### 3. SNI external DNS using OpenShift Routes

With this solution we would leverage OpenShift Routes for getting the traffic to the Proxy. It would work the same as it
does for [Strimzi](https://strimzi.io/blog/2019/04/30/accessing-kafka-part-3/).

The Kroxylicious Operator would need to create Routes (passthrough) for each bootstrap and broker endpoint. This would
be in addition to the per bootstrap/broker Kube Service The OpenShift’s Ingress Operator automatically sets up external
DNS so that those names resolve externally.

Advantages:

- DNS twiddling is automated by the platform.

Disadvantage:

- It’s OpenShift only
- We're proxying the proxy with HAProxy. More latency. More machinery.
- Known issues with haproxy getting restarted every time a new Route is created = dropped Kafka connections. However
  they seem to be fixing that (https://issues.redhat.com/browse/NE-879)!

We could have a configurable list of ingress domains in KafkaGatewayParameters, then when we find a hostname that is a
subdomain of an ingress domain, the operator will create a single ClusterIP service and create passthrough routes
following the same naming convention. So if the hostname in the CR is `my-ingress-route-%.<ingress-domain>` the Operator
would create routes:

`my-ingress-route-bootstrap.<ingress-domain>`
`my-ingress-route-broker-0.<ingress-domain>`
`my-ingress-route-broker-1.<ingress-domain>`
`my-ingress-route-broker-2.<ingress-domain>`

Then the user can bootstrap with `my-ingress-route-bootstrap.<ingress-domain>:443`

Note that the TLS ingress routes will all be on a single port. The user will still be responsible for ensuring their
certificates are configured correctly as the passthrough TLS will terminate at the proxy.

### 4. In-cluster and off-cluster access

Users will likely want in-cluster and off-cluster access via the same proxy instance.

```yaml
---
kind: KafkaGateway
apiVersion: kroxylicious.io/v1alpha1
metadata:
  name: simple
  namespace: my-namespace
spec:
  listeners:
    - name: my-listener
      port: 9092 # required
      protocol: kroxylicious.io/kafka-tls
      tls:
        certificateRefs:
          - # user supplied secret containing tls.crt and tls.key
            kind: Secret
            name: my-cert-off-cluster
            namespace: my-namespace
          - # user supplied secret containing tls.crt and tls.key
            kind: Secret
            name: my-cert-in-cluster
            namespace: my-namespace
---
kind: KafkaRoute
apiVersion: kroxylicious.io/v1alpha1
metadata:
  name: my-route
  namespace: my-namespace
spec:
  parentRefs:
    - group: kroxylicious.io
      kind: KafkaGateway
      name: simple
      sectionName: my-listener
      brokers:
        - advertisedBrokerIds: [ 1,2,3 ]
          brokerIdentityMapping: identity
      hostnames:
        - my-cluster-%.svc.cluster.local
        - my-cluster-%.example.com
      rules:
        - name: my-rule
          filters: [ ]
          backendRefs:
            - kind: Service
              namespace: kafka
              name: my-cluster
              port: 9093
```

The Operator will manifest this as two virtual clusters in the proxy configuration, both with 9092 as the bootstrap
address port. Both virtual clusters will be configured with the same set of certificate KeyPairs, containing the
`my-cert-in-cluster` and `my-cert-off-cluster`. Each virtual cluster will select one of the certificates as discussed
[here](#tls-certificates).

Both virtual clusters will be configured with target bootstrap `my-cluster.kafka:9093`

The Operator will manifest these Services:

1. A ClusterIP Service named `my-cluster-bootstrap` mapping port 9092 to all the Proxy instances 4
2. A ClusterIP Service named `my-cluster-broker-1` mapping port 9092 to all the Proxy instances
3. A ClusterIP Service named `my-cluster-broker-2` mapping port 9092 to all the Proxy instances
4. A ClusterIP Service named `my-cluster-broker-3` mapping port 9092 to all the Proxy instances
5. A LoadBalancer Service named `my-route` mapping port 9092 to all the Proxy instances

### 5. Multiple Routes

Users should be able to configure a single Proxy instance with multiple virtual clusters, targeting different target
clusters.

```yaml
---
kind: KafkaGateway
apiVersion: kroxylicious.io/v1alpha1
metadata:
  name: simple
  namespace: my-namespace
spec:
  listeners:
    - name: my-listener
      port: 9092 # required
      protocol: kroxylicious.io/kafka-tls
      tls:
        certificateRefs:
          - # user supplied secret containing tls.crt and tls.key
            kind: Secret
            name: my-cert
            namespace: my-namespace
---
kind: KafkaRoute
apiVersion: kroxylicious.io/v1alpha1
metadata:
  name: my-route
  namespace: my-namespace
spec:
  parentRefs:
    - group: kroxylicious.io
      kind: KafkaGateway
      name: simple
      sectionName: my-listener
      brokers:
        - advertisedBrokerIds: [ 1,2,3 ]
          brokerIdentityMapping: identity
      hostnames:
        - my-cluster-%.example.com
      rules:
        - name: my-rule
          backendRefs:
            - kind: Service
              namespace: kafka
              name: my-cluster
              port: 9093
---
kind: KafkaRoute
apiVersion: kroxylicious.io/v1alpha1
metadata:
  name: my-route
  namespace: my-namespace
spec:
  parentRefs:
    - group: kroxylicious.io
      kind: KafkaGateway
      name: simple
      sectionName: my-listener
      brokers:
        - advertisedBrokerIds: [ 1,2,3 ]
          brokerIdentityMapping: identity
      hostnames:
        - my-cluster-2-%.example.com
      rules:
        - name: my-rule
          backendRefs:
            - kind: Service
              namespace: kafka
              name: my-cluster-2
              port: 9093
```

The operator will manifest a proxy configuration with two virtual cluster configurations:

1. One with SNI bootstrap `my-cluster-bootstrap.example.com` and brokerPattern `my-cluster-broker-$(nodeId).example.com`
   is routed to target cluster bootstrap `my-cluster.kafka:9093`
2. Another with SNI bootstrap `my-cluster-2-bootstrap.example.com` and
   brokerPattern `my-cluster-2-broker-$(nodeId).example.com `is routed to target
   cluster `bootstrap my-cluster-2.kafka:9093`

The certificate secret will be mounted into the Proxy pod at a known location like
`/opt/kroxylicious/secrets/tls/${listenerName}/${certSecretName}/`

Both VirtualClusters will be configured to load the certificates from the mounted directories. Each virtual cluster will
select one of the certificates as discussed [here](#tls-certificates).