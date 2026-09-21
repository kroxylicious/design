# <PR-NUMBER> - Kubernetes NetworkPolicies

Add support for opererator-generated [`NetworkPolicy`](https://kubernetes.io/docs/concepts/services-networking/network-policies/) to limit network ingress to, and egress from, proxy instances running on Kubernetes.

## Current situation

Currently the Kubernetes operator does not generate `NetworkPolicy` resources at all.
If an end user wants to use the Kubernetes `NetworkPolicy` API to limit network access to or from the proxy they must write those policies themselves.

It's worth calling out some important aspects of the `NetworkPolicy` API in Kubernetes:
* Same-kubernetes-cluster rules can be expressed in terms of namespace and pod selectors (e.g. you can say "allow connections to pods matching _this_ selector in namespaces matching _that_ selector"). 
* `NetworkPolicy` has no direct support for expressing rules using external DNS names (e.g. there is no way to say "allow connections to `kms.example.com`").
* Where external DNS names are used for egress, it's necessary to have a "allow egress to anywhere" `NetworkPolicy` rule.

## Motivation

In a default-deny cluster a `NetworkPolicy` permitting the needed ingresses and egresses is a requirement.

Even in a Kubernetes cluster which is not using a default-deny approach it can be better to have a NetworkPolicy than not.
Tools like the [CIS Kubernetes Benchmark](https://www.armosec.io/glossary/cis-kubernetes-benchmark/) are making it easier for organizations to audit their Kubernetes workloads. 
`NetworkPolicies` are a useful declarative input to such audit tools.
A specific policy statement is better than omitting it, because the former conveys a design requirement whereas the latter could be interpreted as an oversight or configuration error
Some scanner / policies may also flag such NP definitions.

<!--In a typical proxy deployment there might be a mixture of same-cluster (e.g. proxying a Strimzi-based Kafka cluster) 
and external (e.g. accessing a cloud KMS service).

It is not simple for users to figure out most restrictive `NetworkPolicy` rules which are actually required for a given `KafkaProxy`.

At the same time, operating organizations are increasing security-conscious. Having locked-down ingress and egress rules is a meanginful security benefit.
-->


## Proposal

Kafka and proxy networking reqirements are somewhat complex:

* The Kafka protocol uses the `Metadata` API to discover the brokers in a Kafka cluster. 
  That means the host addresses given in a typical `bootstrapServers` list is only a subset (or, with a loadbalancer, may be unrelated) to the host addresses which a client (on our case,  proxy instances) will actually need to connect to onces the broker topology has been discovered.
* The proxy itself is pluggable, and plugins can bring their own network access requirements.
  In general there is no completely sound way of knowing, just by looking at a plugin's configuration, what it may need to connect to, or where it might need to accept connections from.
  For example, it's possible to imagine a plugin which sends information to a separate Kafka cluster (not one of the target clusters of the proxy).
  It would need some kind of `bootstrapServers` list to specify that connection, but the set of brokers it would need to connect to could be larger than the bootstrap hosts. 
  Looking at the configuration of that plugin does not tell you what the egress rules needed for the plugin should be. 

These facts mean that the operator alone is unable to determine a working minimal `NetworkPolicy` for any given set of custom resources (CRs).
So it's necessary for the user to provide some ingress and egress information for the operator to generate the correct policy.

Some organizations would want the configuration that's used to generate a `NetworkPolicy` to live in a separate CR `kind` than the configuration of proxy behaviour (e.g. `KafkaProtocolFilter`).
That would allow them to use Kubernetes' RBAC authorization to give ownership of these separate concerns to different roles in their organization.
For example, while it's fine for the Data Engineer to have control over which topics should be validated, it's may be not acceptable to give that same engineer control over the firewall rules for the proxy as a whole.

### Goals

* Generate `NetworkPolicy` resources targetting the proxy `Pod`.
* Use the policy attachment pattern (as defined by the Kubernetes Gateway API), so that rules live in a separate `kind`.
* Generate `NetworkPolicy` resources by default, with the option to disable generation.
  However, for cluster-DNS names we will generate rules scoped to the relevant Kubernetes namespace.
* Support generating multiple `NetworkPolicy` resources with descriptive `metadata.name`, so simplfy the auditing of why particular access is needed.
  For example, this would allow identifying the filter required an egress-to-all rule.

### Non-goals

* Support for other resources than Kubernetes' built-in `NetworkPolicy`.


### New CRDs



Two new custom resource definitions (CRDs) will be added: `KafkaProxyIngressPolicy` and `KafkaProxyEgressPolicy`.
Users wanting to customise the generated `NetworkPolicies` will need to create suitable CRs.
CRs will not be needed for those willing to accept allow-all type policies.

`KafkaProxyIngressPolicy` will be used for defining ingress rules and `KafkaProxyEgressPolicy` is used for defining egress rules.
Note: Despite the name, a `KafkaProxyIngressPolicy` CR is not necessarily _always_ related to a `KafkaProxyIngress` CR, though usually it would be.
The basic shape of both these CRs is the same:
* The `spec.targetRef` references another proxy CR (i.e. a `KafkaProxyIngress`, a `KafkaService`, a `KafkaProtocolFilter`)
* An `allowIngress` or `allowEgress` defines the networking requirement implied by that targeted CR, using a schema that's essentially the same as used in `NetworkPolicy`.

Although not limited at the CRD schema level, the individual rules allowed under `allowIngress` or `allowEgress` may depend on the `targetRef`'s `group` and `kind`.
Specifically, the operator will enforce the following rules

* A `KafkaProxyIngressPolicy` may not target a `KafkaService`, because a `KafkaService` represents an egress from a proxy, not an ingress to it.
* A `KafkaProxyEgressPolicy` may not target a `KafkaProxyIngress`, because a `KafkaProxyIngress` represents an ingress to a proxy, not an egress from it.

Because `NetworkPolicy` rules are additive (only allowing more access) the effect 
multiple `KafkaProxyIngressPolicy` or `KafkaProxyEgressPolicy` having the same target is also to widen access.

### Policy attachment to `KafkaProxyIngress`

When no `KafkaProxyIngressPolicy` targets a `KafkaProxyIngress` we will generate a default `NetworkPolicy` which allows access from anywhere.
This default `NetworkPolicy` will have a name like `default-allow-ingress-${ingress-name}`.
Here's an example of this kind of policy:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-allow-ingress-my-loadbalancer-ingress
spec:
  podSelector:
    matchLabels:
        app.kubernetes.io/name: kroxylicious
        app.kubernetes.io/component: proxy
        app.kubernetes.io/instance: my-proxy-cr
  policyTypes:
    - Ingress
  ingress:
    - ports:
      - protocol: TCP
        port: <PORT_NUM> # for each port
```

When one or more `KafkaProxyIngressPolicies` target a given `KafkaProxyIngress` a single `NetworkPolicy` will be generated for each.
The `NetworkPolicy` names will follow the pattern `allow-ingress-${policy-name}`.
The exact content will depend on the ingress mechanism.
The `KafkaProxyIngress` CR supports three ingress mechanisms:

* `clusterIP` for access from Kafka clients running in the same Kubernetes cluster
* `loadBalancer` for access from Kafka clients running outside the Kubernetes cluster
* `openShiftRoute` for access from Kafka clients running outside the OpenShift cluster

#### The `clusterIP` case

The `clusterIP` mechanism is specifically intended for access from the same Kubernetes cluster. 
So when the mechanism is `clusterIP` the rules given in the `spec.allowIngress.from` list of each `KafkaProxyIngressPolicy` will be in terms of 
`namespaceSelector` and/or `podSelector`.
The operator will reject `KafkaProxyIngressPolicy` instances where this is not the case (a `Accepted` condition with `status: False`, and an explanatory message).

```yaml
---
# Example ingress allowing connection from any Pod in the cluster
kind: KafkaProxyIngress
apiVersion: kroxylicious.io/v1alpha1
metadata:
  namespace: my-proxy-ns
  name: my-ingress
spec:
  proxyRef:
    name: my-proxy-cr
  clusterIP:
    protocol: TCP
---
# Example ingress policy restricting access to the given namespaces and pods
apiVersion: networking.k8s.io/v1
kind: KafkaProxyIngressPolicy
metadata:
  name: my-clusterIP-policy
spec:
  targetRef:
    group: io.kroxylicious
    kind: KafkaProxyIngress
    name: my-ingress
  allowIngress:
    from:
      - namespaceSelector: 
          matchLabels:
            kubernetes.io/metadata.name: my-kafka-app-ns
      - namespaceSelector: 
          matchLabels:
            kubernetes.io/metadata.name: my-other-kafka-app-ns
        podSelector: 
          matchLabels:
          app.kubernetes.io/name: my-kafka-app
```

Those selectors will be copied verbatim to a generated `NetworkPolicy`, so the above example would generate a policy like this:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-my-clusterIP-policy
  namespace: my-proxy
spec:
  podSelector: # The operator determines the pod selector by following the targetRef through to the KafkaProxy resource
    matchLabels:
        app.kubernetes.io/name: kroxylicious
        app.kubernetes.io/component: proxy
        app.kubernetes.io/instance: my-proxy-cr
  policyTypes:
    - Ingress # The policy type will always be ingress
  ingress:
    - from: # The rules will be copied verbatim
      - namespaceSelector: 
          matchLabels:
            kubernetes.io/metadata.name: my-kafka-app-ns
      - namespaceSelector: 
          matchLabels:
            kubernetes.io/metadata.name: my-other-kafka-app-ns
        podSelector: 
          matchLabels:
          app.kubernetes.io/name: my-kafka-app
```

#### The `loadBalancer` case

This will function similarly, except the validation of the rules in the `allowIngress.from` property is different.
`loadBalancer` is explicitly intended for off-cluster access,
so the value must be a list of objects supporting an `ipBlock` propertry, like so:
```yaml
ipBlock:
  cidr: 203.0.113.0/24
```
(This is exactly the same schema as `NetworkPolicy` supports).
Again, the operator will reject `KafkaProxyIngressPolicy` instances where this is not the case (a `Accepted` condition with `status: False`, and an explanatory message).

To enforce this correctly some changes will also be needed to the loadBalancer `Service` the operator generates.
We can use `Service.spec.loadBalancerSourceRanges` so that the service only accepts connections from the IP ranges given in the `KafkaProxyIngressPolicies` targeting 
the `KafkaProxyIngress`.
We will also need to set `Service.spec.externalTrafficPolicy: Local` to preserve the client's source IP address, so that it can be enforced by the
machinery underpinning the generated `NetworkPolicy`.

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: my-proxy-cr-my-ingress
spec:
  type: LoadBalancer
  loadBalancerSourceRanges: # <-------------------- Defense in depth
    - 203.0.113.0/24
  externalTrafficPolicy: Local # <-------------------- Preserves client source IP
  # ...
```

With `externalTrafficPolicy: Local` in place the client's source IP address will be preserved and we can use a NetworkPolicy to allow access

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-my-loadbalancer-policy
  namespace: my-proxy
spec:
  podSelector: # The operator determines the pod selector by following the targetRef through to the KafkaProxy resource
    matchLabels:
        app.kubernetes.io/name: kroxylicious
        app.kubernetes.io/component: proxy
        app.kubernetes.io/instance: my-proxy-cr
  policyTypes:
    - Ingress # The policy type will always be ingress
  ingress: # The rules will be copied verbatim
    - from:
        - ipBlock:
            cidr: 203.0.113.0/24
        port: <PORT_NUM> # for each port
```

#### The `openShiftRoute` case

Like `loadBalancer`, the `openShiftRoute` mechanism is explicitly intended for off-cluster access.
Again, the validation of the rules in the `allowIngress.from` will require the use of `ipBlock`.
Again, the operator will reject `KafkaProxyIngressPolicy` instances where this is not the case (a `Accepted` condition with `status: False`, and an explanatory message).

To restrict access by client CIDR with an OpenShift `Route`, we must restrict traffic at the `Route` layer using an annotation, and pair it with a `NetworkPolicy` to restrict `Pod` ingress to only the OpenShift Ingress `Router`.

```yaml
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: my-proxy-cr-my-ingress
  namespace: my-proxy
  annotations:
    # Space-separated list of allowed CIDRs or IP addresses, takern from the KafkaProxyIngressPolicy
    haproxy.router.openshift.io/ip_whitelist: "203.0.113.0/24 198.51.100.10/32"
spec:
  host: my-app.example.com
  to:
    kind: Service
    name: my-proxy-cr-my-ingress
  port:
    targetPort: 9092
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-my-route-policy
  namespace: my-proxy
spec:
  podSelector: # The operator determines the pod selector by following the targetRef through to the KafkaProxy resource
    matchLabels:
        app.kubernetes.io/name: kroxylicious
        app.kubernetes.io/component: proxy
        app.kubernetes.io/instance: my-proxy-cr
  policyTypes:
    - Ingress # The policy type will always be ingress
ingress: # The rules target the pod running the Router network proxy.
  - from:
      - namespaceSelector:
          matchLabels:
            network.openshift.io/policy-group: ingress
    ports:
      - protocol: TCP
        port: 9092
```


### Policy attachment to `KafkaService`

When no `KafkaProxyEgressPolicy` targets a `KafkaService` we will generate a default `NetworkPolicy` which allows access to anywhere.
This default `NetworkPolicy` will have a name like `default-allow-egress-${kafka-service-name}`.
Here's an example of this kind of policy:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-allow-egress-my-target-cluster
spec:
  podSelector:
    matchLabels:
        app.kubernetes.io/name: kroxylicious
        app.kubernetes.io/component: proxy
        app.kubernetes.io/instance: my-proxy-cr
  policyTypes:
    - Egress
  egress:
  - ports:
    - protocol: TCP
```

When one or more `KafkaProxyEgressPolicies` target a given `KafkaService` a single `NetworkPolicy` will be generated for each.
The `NetworkPolicy` names will follow the pattern `allow-egress-${policy-name}`.

The `KafkaService` CR supports two ways to express a target cluster:

* `strimziKafkaRef` is a reference to a Strimzi `Kafka` resource which exists in the same cluster as the `KafkaService` CR.
* `bootstrapServers` is a comma-separated list of the host addresses for some bootstrap servers of a Kafka cluster.


#### The `strimziKafkaRef` case

`strimziKafkaRef` is a very special case. 
We already know the namespace of the `Kafka` cluster, and the `Pod` labels (and hence selectors) are a published part of the Strimzi API. 
So in this case don't need an explict `allowEgress`.
Its contents can always be inferred from the properties of `strimziKafkaRef`.
However, for uniformity with the rest of the API we will require it to be present in order to generate specific `NetworkPolicy`

```yaml
---
kind: KafkaService
metadata:
  namespace: my-proxy-ns
  name: strimzi-target
spec:
  strimziKafkaRef: 
    kind: Kafka
    group: 
    name: my-kafka-cluster
    namespace: my-strimzi-namespace
    listener: my-listener
---
# Example egress policy restricting access to the given namespaces and pods
apiVersion: networking.k8s.io/v1
kind: KafkaProxyEgressPolicy
metadata:
  name: my-strimzi-target
spec:
  targetRef:
    group: io.kroxylicious
    kind: KafkaService
    name: strimzi-target
  allowEgress: {}
```

That would generate a `NetworkPolicy` like this:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-my-strimzi-target
spec:
  podSelector:
    matchLabels:
        app.kubernetes.io/name: kroxylicious
        app.kubernetes.io/component: proxy
        app.kubernetes.io/instance: my-proxy-cr
  policyTypes:
    - Egress
egress:
  - to:
    - namespaceSelector:
        matchLabels:
          io.kubernetes.metadata.name: my-strimzi-namespace
    - podSelector:
        matchLabels:
          role: frontend   #### TODO whatever labels strimzi uses for brokers
    ports:
    - protocol: TCP
      port: 9092
```

#### The `bootstrapServers` case


`bootstrapServers` allows any kind of host address to be specified.
Supporting it involves a number of sub-cases:

* the given servers are internal IPv4 or IPv6 addresses
* the given servers are internal DNS names (e.g. `node12.my-kafka.my-ns.svc.cluster.local`) TODO check what names strimzi actually uses
* the given servers are external IPv4 or IPv6 addresses
* the given servers are external DNS names (e.g. `node12.kafka.example.com:9092`)

The use of internal IP address will not be supported.
`KafkaService` resources with `bootstrapServers` including any internal IP address will be rejected using an `Accepted` condition with a suitable message.
There is no good reason users should be using IP addresses to specify an internal Kafka cluster. 
IP addresses in Kubernetes are very dynamic, so it's unlikely to work reliably, even if it were supported.

##### Internal DNS names

When the bootstrap servers list is entirely compose of internal DNS names the `spec.allowEgress.to` property will be required to use `namespaceSelector` and/or `podSelector` rules.


```yaml
---
kind: KafkaService
metadata:
  namespace: my-proxy-ns
  name: internal-dns
spec:
  bootstrapServers: my-kafka-boostrap.my-ns.svc.cluster.local:9092  ## TODO Fix this to be an cluster DNS name
---
# Example egress policy restricting access to the given namespaces and pods
apiVersion: networking.k8s.io/v1
kind: KafkaProxyEgressPolicy
metadata:
  name: my-strimzi-target
spec:
  targetRef:
    group: io.kroxylicious
    kind: KafkaService
    name: internal-dns
  allowEgress:
  - to: 
      - namespaceSelector: 
          matchLabels:
            kubernetes.io/metadata.name: my-ns
```

##### External DNS names and external IP addresses

When the bootstrap servers list is entirely compose of external DNS names and/or external IP addresses the `spec.allowEgress.to` property will be required to use `ipBlock` rules.

```yaml
---
kind: KafkaService
metadata:
  namespace: my-proxy-ns
  name: internal-dns
spec:
  bootstrapServers: kafka1.example.com:9092,kafka2.example.com:9092
---
# Example egress policy restricting access to the given namespaces and pods
apiVersion: networking.k8s.io/v1
kind: KafkaProxyEgressPolicy
metadata:
  name: my-strimzi-target
spec:
  targetRef:
    group: io.kroxylicious
    kind: KafkaService
    name: internal-dns
  allowEgress:
    to:
      - ipBlock:
          cidr: 10.0.23.0/24
```

===================================================


### Policy attachment to `KafkaProtocolFilter`

The `KafkaProtocolFilter` CR is used to configure filters. 
It is common for filters, or their plugins, to require network egress.
It's also not forbidden for filters to require network ingress.
In the most general case, a filter or its plugin would require rules for both egress and ingress.

The user will use same same `KafkaProxyIngressPolicy` and `KafkaProxyEgressPolicy` CRs to express the required access.

When no `KafkaProxyEgressPolicy` targets a `KafkaProtocolFilter` we will generate a default `NetworkPolicy`, such as we saw above, which allows access to anywhere.
This default `NetworkPolicy` will have a name like `default-allow-egress-filter-${kafka-filter-name}`.
When no `KafkaProxyIngressPolicy` targets a `KafkaProtocolFilter` we will generate a default `NetworkPolicy`, such as we saw above, which allows access to anywhere.
This default `NetworkPolicy` will have a name like `default-allow-ingress-filter-${kafka-filter-name}`.
**TODO** this would be, without policies lots of access, is that right/defensible?

When one or more `KafkaProxyEgressPolicies` target a given `KafkaProtocolFilter` a single `NetworkPolicy` will be generated for each.
The `NetworkPolicy` names will follow the pattern `allow-egress-${policy-name}`.

Here's an example for the `RecordEncryption` filter:

```yaml
---
# Example protocol filter
kind: KafkaProtocolFilter
metadata:
  name: encryption
spec:
  type: RecordEncryption
  configTemplate:
    kms: VaultKmsService
    kmsConfig:
      vaultTransitEngineUrl: http://vault.vault.svc.cluster.local:8200/v1/transit
      vaultToken:
        password: ${secret:vault:token}
    selector: TemplateKekSelector
    selectorConfig:
      template: "$(topicName)"
---
# egress policy attached to the protocol filter
apiVersion: networking.k8s.io/v1
kind: KafkaProxyEgressPolicy
metadata:
  name: kafka-proxy-my-proxy-ingress-thru-my-loadbalancer
spec:
  targetRef:
    group: io.kroxylicious
    kind: KafkaProtocolFilter
    name: encryption
  allowEgress:
    to: 
      - namespaceSelector:
          matchLabels:
            io.kubernetes.metadata.name: vault
    ports:
    - protocol: TCP
      port: 8200
```



### Operator-level configuration

We will add a new cluster-scoped CRD for expressing options for the operator.
Here's an example CR:

```yaml
kind: KafkaProxyOperatorConfig
metadata:
  name: default
spec:
  clusterDomain: cluster.local
  clusterCIDRs:
    - 10.244.0.0/16     # IPv4 Pod IPs
    - 10.96.0.0/12      # IPv4 Service IPs
    - fd00:10:244::/48  # IPv6 Pod IPs
    - fd00:10:96::/112  # IPv6 Service IPs
  allowIngress:
    presence: denied|permitted|required
  allowEgress:
    presence: denied|permitted|required
  networkPolicy: 
    ingress:
      generation: enabled|disabled
    engress:
      generation: enabled|disabled
```

The operator `Deployment` itself will support a `CONFIG_NAME` env var which allows to select the `KafkaProxyOperatorConfig` to be used by that operator instance.
The value will default to `default`. 

The `clusterDomain` option provides an admin override to the autodetection of the cluster domain DNS suffix.

The `clusterCIDRs` option allows an admin to specify the IP blocks for cluster-local addresses. 
This is needed in order to detect and reject internal addresses for `KafkaService.spec.bootstrapServers`.

The options for `presence` are as follows:

* `disallowed`: CRs with `allowIngress` or `allowEgress` will be rejected.
* `permitted`: CRs with or without `allowIngress` or `allowEgress` will be allowed.
* `required`: CRs without `allowIngress` or `allowEgress` will be rejected.

The default value for `presence` will be `permitted`. 

The options for `generation` are as follows:

* `enabled`: `NetworkPolicies` will be generated
* `disabled`: `NetworkPolicies` will not be generated

The default value for `generation` will be `enabled`. 


-----------------------------------------




-----------------------------------------------



### Built-in rules for `KafkaProxyIngress`

The `KafkaProxyIngress` CR supports three ingress mechanisms:

* `clusterIP` for access from Kafka clients running in the same Kubernetes cluster
* `loadBalancer` for access from Kafka clients running outside the Kubernetes cluster
* `openShiftRoute` for access from Kafka clients running outside the OpenShift cluster

We will add support for the operator also generating `NetworkPolicy` resources with `policyType: Ingress` for these CRs.

The basic pattern will be to generate a single `NetworkPolicy` for each `KafkaProxyIngress` resource.
The `NetworkPolicy` names will follow the pattern `kafka-proxy-${proxy-name}-ingress-thru-${ingress-name}`.

In each case we will use a new `allowIngress` property to define where clients can connect from. 
(`allowIngress` is our equivalent of Strimzi's `networkPolicyPeers`.)
When `allowIngress` is absent we will default to access from anywhere, with a policy like this:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafka-proxy-my-proxy-ingress-thru-my-loadbalancer
spec:
  podSelector:
    matchLabels:
        app.kubernetes.io/name: kroxylicious
        app.kubernetes.io/component: proxy
        app.kubernetes.io/instance: my-proxy-cr
  policyTypes:
    - Ingress
  ingress:
    - ports:
      - protocol: TCP
        port: <PORT_NUM> # for each port
```

When `allowIngress` is present we will only allow access from those specified connection sources.


#### The `clusterIP` case


Currently `clusterIP` just supports a `protocol` property. 
We will add support for `allowIngress` as a sibling of the `protocol` property.
`clusterIP` is explicitly intended for accessing the proxy from within the same Kubernetes cluster, 
so the value will be a list of objects supporting `namespaceSelector` and `podSelector`, analogous to those used in the `NetworkPolicy` resource itself:

```yaml
kind: KafkaProxyIngress
apiVersion: kroxylicious.io/v1alpha1
metadata:
  namespace: my-proxy-ns
  name: my-ingress
spec:
  proxyRef:
    name: my-proxy-cr
  clusterIP:
    protocol: TCP
    allowIngress: # <------------------------ new!
      from:
        - namespaceSelector: 
            matchLabels:
              kubernetes.io/metadata.name: my-kafka-app-ns
        - namespaceSelector: 
            matchLabels:
              kubernetes.io/metadata.name: my-other-kafka-app-ns
          podSelector: 
            matchLabels:
            app.kubernetes.io/name: my-kafka-app
```

When `allowIngress` is present those selectors will be copied verbatim to a generated `NetworkPolicy`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: my-proxy-cr-my-ingress
  namespace: my-proxy
spec:
  podSelector:
    matchLabels:
        app.kubernetes.io/name: kroxylicious
        app.kubernetes.io/component: proxy
        app.kubernetes.io/instance: my-proxy-cr
  policyTypes:
    - Ingress
  ingress:
    - from:
      - namespaceSelector: 
          matchLabels:
            kubernetes.io/metadata.name: my-kafka-app-ns
      - namespaceSelector: 
          matchLabels:
            kubernetes.io/metadata.name: my-other-kafka-app-ns
        podSelector: 
          matchLabels:
          app.kubernetes.io/name: my-kafka-app
```


#### The `loadBalancer` case



We will add support for a new `allowIngress` property as a sibling of the `bootstrapAddress`.
`loadBalancer` is explicitly intended for off-cluster access,
so the value will be a list of objects supporting an `ipBlock` propertry, like so:
```yaml
ipBlock:
  cidr: 203.0.113.0/24
```
This is analogous to those used in the `NetworkPolicy` resource itself:

```yaml
kind: KafkaProxyIngress
apiVersion: kroxylicious.io/v1alpha1
metadata:
  namespace: my-proxy
  name: my-ingress
spec:
  proxyRef:
    name: my-proxy-cr
  loadBalancer:
    bootstrapAddress: "$(virtualClusterName).kafkaproxy.example.com"
    advertisedBrokerAddressPattern: "broker-$(nodeId).$(virtualClusterName).kafkaproxy.example.com"
    allowIngress: # <------------------------ new!
      from:
        - ipBlock:
            cidr: 203.0.113.0/24
      
```

We can use `Service.spec.loadBalancerSourceRanges` so that the service only accepts connections from the IP ranges given in `KafkaProxyIngress.spec.loadBalancer.allowIngress`.
We also need to set `Service.spec.externalTrafficPolicy: Local` to preserve the client's source IP address

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: my-proxy-cr-my-ingress
spec:
  type: LoadBalancer
  loadBalancerSourceRanges: # <-------------------- Defense in depth
    - 203.0.113.0/24
  externalTrafficPolicy: Local # <-------------------- Preserves client source IP
  selector:
        app.kubernetes.io/name: kroxylicious
        app.kubernetes.io/component: proxy
        app.kubernetes.io/instance: my-proxy-cr
  ports:
    - protocol: TCP
      port: 9092
      targetPort: 9092
```

When the client's source IP address is preserved we can use a NetworkPolicy to allow access

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: my-proxy-cr-my-ingress
  namespace: my-proxy
spec:
  podSelector:
    matchLabels:
        app.kubernetes.io/name: kroxylicious
        app.kubernetes.io/component: proxy
        app.kubernetes.io/instance: my-proxy-cr
  policyTypes:
    - Ingress
  ingress:
    - from:
        - ipBlock:
            cidr: 203.0.113.0/24
        port: <PORT_NUM> # for each port
```

#### The `openShiftRoute` case

Currently the `openShiftRoute` object has no defined properties. 
We will add support for a new `allowIngress` property.
`openShiftRoute` is explicitly intended for off-cluster access,
so the value will be a list of objects supporting an `ipBlock` propertry, like so:
```yaml
ipBlock:
  cidr: 203.0.113.0/24
```

This is analogous to those used in the `NetworkPolicy` resource itself.

```yaml
kind: KafkaProxyIngress
apiVersion: kroxylicious.io/v1alpha1
metadata:
  namespace: my-proxy-cr
  name: my-ingress
spec:
  proxyRef:
    name: my-proxy-cr
  openShiftRoute:
    allowIngress: # <------------------------ new!
      from:
        - ipBlock:
            cidr: 203.0.113.0/24
        - ipBlock:
            cidr: 198.51.100.10/32
```

To restrict access by client CIDR with an OpenShift `Route`, we must restrict traffic at the `Route` layer using an annotation, and pair it with a `NetworkPolicy` to restrict `Pod` ingress to only the OpenShift Ingress `Router`.

```yaml
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: my-proxy-cr-my-ingress
  namespace: default
  annotations:
    # Space-separated list of allowed CIDRs or IP addresses
    haproxy.router.openshift.io/ip_whitelist: "203.0.113.0/24 198.51.100.10/32"
spec:
  host: my-app.example.com
  to:
    kind: Service
    name: my-proxy-cr-my-ingress
  port:
    targetPort: 9092
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: my-proxy-cr-my-ingress
  namespace: default
spec:
  podSelector:
    matchLabels:
        app.kubernetes.io/name: kroxylicious
        app.kubernetes.io/component: proxy
        app.kubernetes.io/instance: my-proxy-cr
  policyTypes:
    - Ingress
ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              network.openshift.io/policy-group: ingress
      ports:
        - protocol: TCP
          port: 9092
```

### Built-in rules for `KafkaServices`

The `KafkaService` CR supports two ways to express a target cluster:

* `strimziKafkaRef` is a reference to a Strimzi `Kafka` resource which exists in the same cluster as the `KafkaService` CR.
* `bootstrapServers` is a comma-separated list of the host addresses for some bootstrap servers of a Kafka cluster.

Since the operator always knows about these CRs we will add support for the operator also generating `NetworkPolicy` resources with `policyType: Egress` for these CRs.

The basic pattern will be to generate a single `NetworkPolicy` for each `KafkaService` resource.
The `NetworkPolicy` names will follow the pattern `kafka-proxy-${proxy-name}-egress-to-${service-name}`.

In each case the support will use a new `allowEgress` property to define where clients can connect to.
When `allowEgress` is absent we will default to allowing access to anywhere, like this:

When `allowEgress` is present we will only allow access to those specified destinations, as described in the following sections.


#### The `strimziKafkaRef` case

`strimziKafkaRef` is a very special case. 
We already know the namespace of the `Kafka` cluster, and the `Pod` labels (and hence selectors) are a published part of the Strimzi API. 
So in this case don't need an explict `allowEgress`.
Its contents can always be inferred from the properties of `strimziKafkaRef`.
However, for uniformity with the rest of the API we will require it to be present in order to generate specific `NetworkPolicy`

```yaml
kind: KafkaService
metadata:
  namespace: my-proxy-ns
  name: strimzi-target
spec:
  strimziKafkaRef: 
    kind: Kafka
    group: 
    name: my-kafka-cluster
    namespace: my-strimzi-namespace
    listener: my-listener
  allowEgress: {} # <------------------------------ new
```

That would generate a `NetworkPolicy` like this:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  namespace: my-proxy-ns
  name: my-proxy-cr-kafka-service-strimzi-target
spec:
  podSelector:
    matchLabels:
        app.kubernetes.io/name: kroxylicious
        app.kubernetes.io/component: proxy
        app.kubernetes.io/instance: my-proxy-cr
  policyTypes:
    - Egress
egress:
  - to:
    - namespaceSelector:
        matchLabels:
          io.kubernetes.metadata.name: my-strimzi-namespace
    - podSelector:
        matchLabels:
          role: frontend   #### TODO whatever labels strimzi uses for brokers
    ports:
    - protocol: TCP
      port: 9092
```

#### The `bootstrapServers` case


Suporting `bootstrapServers` involves a number of sub-cases:

* the given servers are internal DNS names (e.g. `node12.my-kafka.my-ns.svc.cluster.local`) TODO check what names strimzi actually uses
* the given servers are internal IPv4 or IPv6 addresses
* the given servers are external DNS names (e.g. `node12.kafka.example.com:9092`)
* the given servers are external IPv4 or IPv6 addresses

Firstly, we shall disallow the internal IP address case entirely. 
There is no good reason users should be using IP addresses to specify an internal Kafka cluster. 
IP addresses in Kubernetes are very dynamic, so it's unlikely to work reliably, even if it were supported.
So resources using internal IP addresses will be rejected.

It is further complicated by the fact that the brokers the client can discover from the bootstrap servers might be a superset of, or entirely unrelated to, the addresses given in `bootstrapServers`.
This means we will need a different property to express the possible brokers which the proxy need to connect.
We'll use a new `allowEgress` property to cover both internal and external cases:


To support the internal servers case `allowEgress` will support a required `namespace` property (note, **not** `namespaceSelectors` as we saw used for `KafkaProxyIngress`), and an optional `podSelector` for microsegmentation to individual broker pods:

```yaml
kind: KafkaService
metadata:
  namespace: my-proxy-ns
  name: arbitrary-target
spec:
  bootstrapServers: kafka.example.com:9092  ## TODO Fix this to be an cluster DNS name
  allowEgress: # <------------------------------ new
    to:
      - namespace: my-kafka-cluster
        podSelector:
          matchLabels:
            role: frontend   #### TODO whatever labels strimzi uses for brokers
```

For the external servers case `allowEgress` will _also_ support the same `ipBlock` mechanism we've already seen. 

```yaml
kind: KafkaService
metadata:
  namespace: my-proxy-ns
  name: kafka-service-arbitrary-target
spec:
  bootstrapServers: kafka.example.com:9092
  allowEgress: # <------------------------------ new
    to:
      - ipBlock:
          cidr: 10.0.23.0/24
  # ...
```


### Built-in rules for `KafkaProtocolFilter`

The `KafkaProtocolFilter` CR is used to configure filters. 
It is common for filters or their plugins to require network egress.
It's also not forbidden for filters to require network ingress.
In the most general case a filters or its plugin would require rules for both egress and ingress.

The basic pattern will be to generate a one or two `NetworkPolicy` for each `KafkaProtocolFilter` resource: One for ingress and one for egress.
The egress `NetworkPolicy` names will follow the pattern `kafka-proxy-${proxy-name}-filter-${filter-name}-egress`.
The igress `NetworkPolicy` names will follow the pattern `kafka-proxy-${proxy-name}-filter-${filter-name}-ingress`.

The `KafkaProtocolFilter` API will support both `allowEgress` and `allowIngress` properties to define where clients can connect to and from.

Here's an example for the `RecordEncryption` filter:

```yaml
kind: KafkaProtocolFilter
metadata:
  name: encryption
spec:
  type: RecordEncryption
  allowEgress:
    to: 
      - namespaceSelector:
          matchLabels:
            io.kubernetes.metadata.name: vault
    ports:
    - protocol: TCP
      port: 8200
  configTemplate:
    kms: VaultKmsService
    kmsConfig:
      vaultTransitEngineUrl: http://vault.vault.svc.cluster.local:8200/v1/transit
      vaultToken:
        password: ${secret:vault:token}
    selector: TemplateKekSelector
    selectorConfig:
      template: "$(topicName)"
```


When `allowEgress` is absent we will default to allowing access to anywhere.
By nature of the `NetworkPolicy` API, allowing access to anywhere will also allow connections made for `KafkaServices` to connect to anywhere, in spite of their own declared `allowEgress` rules.

When `allowIngress` is absent we will default to allowing access from anywhere. 
By nature of the `NetworkPolicy` API, allowing access from anywhere will also allow connections to `KafkaProxyIngresses` from anywhere, in spite of their own declared `allowIngress` rules.

### Operator-level configuration

We will add a new cluster-scoped CRD for expressing options for the operator.
Here's an example CR:

```yaml
kind: KafkaProxyOperatorConfig
metadata:
  name: default
spec:
  clusterDomain: cluster.local
  clusterCIDRs:
    - 10.244.0.0/16     # IPv4 Pod IPs
    - 10.96.0.0/12      # IPv4 Service IPs
    - fd00:10:244::/48  # IPv6 Pod IPs
    - fd00:10:96::/112  # IPv6 Service IPs
  allowIngress:
    presence: denied|permitted|required
  allowEgress:
    presence: denied|permitted|required
  networkPolicy: 
    ingress:
      generation: enabled|disabled
    engress:
      generation: enabled|disabled
```

The operator `Deployment` itself will support a `CONFIG_NAME` env var which allows to select the `KafkaProxyOperatorConfig` to be used by that operator instance.
The value will default to `default`. 

The `clusterDomain` option provides an admin override to the autodetection of the cluster domain DNS suffix.

The `clusterCIDRs` option allows an admin to specify the IP blocks for cluster-local addresses. 
This is needed in order to detect and reject internal addresses for `KafkaService.spec.bootstrapServers`.

The options for `presence` are as follows:

* `disallowed`: CRs with `allowIngress` or `allowEgress` will be rejected.
* `permitted`: CRs with or without `allowIngress` or `allowEgress` will be allowed.
* `required`: CRs without `allowIngress` or `allowEgress` will be rejected.

The default value for `presence` will be `permitted`. 

The options for `generation` are as follows:

* `enabled`: `NetworkPolicies` will be generated
* `disabled`: `NetworkPolicies` will not be generated

The default value for `generation` will be `enabled`. 

## Affected/not affected projects

This affects the `kroxylicious/kroxylicious` repo. 

## Compatibility

The proposed changes are backwards compatible.
When `allowIngress` and `allowEgress` are absent the generated policies will allow wide access, so end users upgrading to a new operator version should find that client, broker and plugin connectivity is not affected. If, due to a bug, the generated policies prevented connections, the user would be able to work around it by setting `KafkaProxyOperatorConfig.spec.generation: disabled`.

## Rejected alternatives

* "Use the static type information in the proxy configuration to infer the ingress and egress needs of plugins, so the user doesn't not have to declare them".
    - Initially we thought this was going to be a good idea. However the operator does not have the plugins on its class path, so it cannot directly interrogate a proxy configuration to figure this out.
      The operator would need to do this indirectly in a container using the proxy image. That could be done in a Pre-flight `Job` orchestrated by the operator, and which communicated back 
      the network requirements of plugins. However, it still relies on some contractually weak conventions (like "always use a `java.net.URI` for plugins which need egress"), so might not work 
      with all plugins. Furthermore this whole technique is incompatible with services using "endpoint discovery" protocols, like Kafka's own. 
      This means we might end up needing a way for the end user to override the rules inferred using an approach like this.
      It would be much simpler to just allow the end user to use this mechanism from the beginning.
* "Let the operator resolve DNS names, generating NetworkPolicies with the resolved IP addresses." 
    - While this could work in simple cases it would not work well enough in practice. Some of the problems include:
        - We cannot guarantee that the resolution done in the operator would have the same results as the resolution in the proxy instances. 
        - It's not uncommon for SaaS services to use very low, or even a 0 TTL, meaning it would be impossible to know how long the results of the resolution would be valid for. 
        - Low or 0 TTLs could also involve  significant update cost for the `NetworkPolicies`.
        - It's inherently racy
        - The sets of resolved IP addresses could be large, the effects of which would flow directly to iptables-based CNIs (e.g. kubeproxy).
* "Generate a single monolithic `NetworkPolicy`". 
    - This would put less load on the Kubernetes API server. 
    - However, such policies are not easy to audit because the reason why any particular rule is allowing access canont be easily traced back to the original resource.
* "Use the same property name (`networkPolicyPeers`) as Strimzi"
    - `networkPolicyPeers` does not distinguish between the ingress and egress cases. We have CRs which support one, but not the other, and other CRs which support both at the same time. Being able to distinguish between the two cases seems like a useful way to ensure unambiguous communication of the user's intent.
* "Use env vars directly for configuring the operator, rather than introducing a new CRD"
    - For the specific operator config options in this proposal env vars would suffice. However, this would establish env vars as being _the_ mechanism for configuration the operator. We suspect the operator will gain more configurability options in the future. Using CRs has a number of advantages:
        - Documented and discoverable using tools like `kubectl explain`
        - Better support for structured values using YAML.
        - More easily modified by end users (who often don't want to customise `Deployment` env vars)
