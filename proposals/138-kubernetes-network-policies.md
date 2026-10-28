# 138 - Kubernetes `NetworkPolicies`

Add support for operator-generated [`NetworkPolicy`](https://kubernetes.io/docs/concepts/services-networking/network-policies/) to limit network ingress to, and egress from, proxy instances running on Kubernetes.

## Current situation

Currently the Kubernetes operator does not generate `NetworkPolicy` resources at all.
If an end user wants to use the Kubernetes `NetworkPolicy` API to limit network access to or from the proxy they must write those policies themselves.

It's worth calling out some important aspects of the `NetworkPolicy` API in Kubernetes:
* Same-kubernetes-cluster rules can be expressed in terms of namespace and pod selectors (e.g. you can say "allow connections to pods matching _this_ selector in namespaces matching _that_ selector"). 
* `NetworkPolicy` has no direct support for expressing rules using external DNS names (e.g. there is no way to say "allow connections to `kms.example.com`").
* Where external DNS names are used for egress, it's necessary to have a "allow egress to anywhere" `NetworkPolicy` rule.
* Enforcement of `NetworkPolicy` depends on the cluster's CNI plugin supporting it (e.g. Calico, Cilium); some CNIs accept `NetworkPolicy` resources without enforcing them. A generated policy still has declarative/audit value on such a cluster (per the Motivation below), but it gives no actual network isolation unless the CNI enforces it.

## Motivation

In a default-deny cluster a `NetworkPolicy` permitting the needed ingresses and egresses is a requirement.

Even in a Kubernetes cluster which is not using a default-deny approach it can be better to have a NetworkPolicy than not.
Tools like the [CIS Kubernetes Benchmark](https://www.armosec.io/glossary/cis-kubernetes-benchmark/) are making it easier for organizations to audit their Kubernetes workloads. 
`NetworkPolicies` are a useful declarative input to such audit tools.
A specific policy statement is better than omitting it, because the former conveys a design requirement whereas the latter could be interpreted as an oversight or configuration error
Some scanner / policies may also flag such NP definitions.


## Proposal

Kafka and proxy networking requirements are somewhat complex:

* The Kafka protocol uses the `Metadata` API to discover the brokers in a Kafka cluster. 
  That means the host addresses given in a typical `bootstrapServers` list is only a subset (or, with a loadbalancer, may be unrelated) to the host addresses which a client (on our case,  proxy instances) will actually need to connect to once the broker topology has been discovered.
* The proxy itself is pluggable, and plugins can bring their own network access requirements.
  In general there is no completely sound way of knowing, just by looking at a plugin's configuration, what it may need to connect to, or where it might need to accept connections from.
  For example, it's possible to imagine a plugin which sends information to a separate Kafka cluster (not one of the target clusters of the proxy).
  It would need some kind of `bootstrapServers` list to specify that connection, but the set of brokers it would need to connect to could be larger than the bootstrap hosts. 
  Looking at the configuration of that plugin does not tell you what the egress rules needed for the plugin should be. 

These facts mean that the operator alone is unable to determine a working minimal `NetworkPolicy` for any given set of custom resources (CRs).
So it's necessary for the user to provide some ingress and egress information for the operator to generate the correct policy.

Some organizations would want the configuration that's used to generate a `NetworkPolicy` to live in a separate CR `kind` than the configuration of proxy behaviour (e.g. `KafkaProtocolFilter`).
That would allow them to use Kubernetes' RBAC authorization to give ownership of these separate concerns to different roles in their organization.
For example, while it's fine for the Data Engineer to have control over which topics should be validated, it may not be acceptable to give that same engineer control over the firewall rules for the proxy as a whole.

### Goals

* Generate `NetworkPolicy` resources targeting the proxy `Pod`.
* Use the policy attachment pattern (as defined by the Kubernetes Gateway API), so that rules live in kinds separate from the CRs they target.
* Generate `NetworkPolicy` resources by default, with the option to disable generation.
  However, for cluster-DNS names we will generate rules scoped to the relevant Kubernetes namespace.
* Support generating multiple `NetworkPolicy` resources with descriptive `metadata.name`, so simplify the auditing of why particular access is needed.
  For example, this would allow identifying which filter requires an egress-to-all rule.

### Non-goals

* Support for other resources than Kubernetes' built-in `NetworkPolicy`.


### New CRDs

Three new custom resource definitions (CRDs) will be added:

| Kind | Scope | Typical owner | Purpose |
| --- | --- | --- | --- |
| `KafkaProxyIngressNetworkPolicy` | Namespaced | Whoever controls the proxy's network exposure (e.g. a security or platform-per-tenant role), or the owner of a `KafkaProtocolFilter` that itself needs inbound access — not necessarily the same role that owns the `KafkaProxyIngress`/`KafkaProtocolFilter` it targets. | Declares the ingress rules needed by a `KafkaProxyIngress` or `KafkaProtocolFilter`, using the policy attachment pattern. Described in this section. |
| `KafkaProxyEgressNetworkPolicy` | Namespaced | Whoever declares the proxy's or a filter's outbound needs — e.g. the platform team for the proxy's egress to the real Kafka cluster (`KafkaService`), or a plugin-owning team for a filter's own egress. This kind's RBAC surface is shared between those two cases; see [Rejected alternatives](#rejected-alternatives) for the trade-off against splitting further. | Declares the egress rules needed by a `KafkaService` or `KafkaProtocolFilter`, using the policy attachment pattern. Described in this section. |
| `KafkaProxyOperatorConfig` | Cluster-scoped | The cluster-admin/platform team that runs the operator itself. | Configures operator-wide behaviour, including whether `NetworkPolicy` generation is enabled and which policy attachments are required. See [Operator-level opt-out](#operator-level-opt-out). |

This is the RBAC separation of concerns motivating this proposal (see above): the role that owns a proxy CR's network behaviour need not be the role that owns the rest of that CR's configuration, and the role that sets operator-wide policy need not be either of those.
Splitting network policy by direction, rather than using one combined kind, further means the role that controls the proxy's ingress exposure need not be the role that declares a filter's own egress need — see [Rejected alternatives](#rejected-alternatives) for the trade-offs against a single combined kind or against splitting further by target kind.

Users wanting to customise the generated `NetworkPolicies` will need to create suitable `KafkaProxyIngressNetworkPolicy` and/or `KafkaProxyEgressNetworkPolicy` CRs.
CRs will not be needed for those willing to accept allow-all type policies.

`KafkaProxyIngressNetworkPolicy` and `KafkaProxyEgressNetworkPolicy` are used for defining ingress and egress rules respectively.
The basic shape of each is the same:
* The `spec.targetRef` references another proxy CR. A `KafkaProxyIngressNetworkPolicy` may target a `KafkaProxyIngress` or a `KafkaProtocolFilter`; a `KafkaProxyEgressNetworkPolicy` may target a `KafkaService` or a `KafkaProtocolFilter`.
* A `spec.allow` list defines the networking requirement implied by that targeted CR. Each entry has essentially the same shape as a `NetworkPolicy` `ingress`/`egress` rule (a list of `from`/`to` peers plus optional `ports`); `ports` is usually omitted and inferred by the operator from the targeted CR, except where noted in later sections.

`targetRef` only resolves within the same namespace as the `KafkaProxyIngressNetworkPolicy`/`KafkaProxyEgressNetworkPolicy` itself; there is no cross-namespace form (unlike, for example, the Gateway API's `ReferenceGrant`-mediated cross-namespace policy attachment). This keeps the ownership split described above confined to a single namespace: neither kind can ever grant or imply network access on behalf of a `KafkaProxyIngress`, `KafkaService`, or `KafkaProtocolFilter` owned by a different namespace/tenant.

Because each kind only has fields for a single direction, `targetRef.kind` is restricted (at the CRD schema level, via an enum) to the kinds that make sense for that direction:

* `KafkaProxyIngressNetworkPolicy.spec.targetRef.kind` is one of `KafkaProxyIngress` or `KafkaProtocolFilter`.
* `KafkaProxyEgressNetworkPolicy.spec.targetRef.kind` is one of `KafkaService` or `KafkaProtocolFilter`.

This makes the invalid combinations possible with a single combined kind — an egress rule against a `KafkaProxyIngress`, or an ingress rule against a `KafkaService` — impossible to express at all, rather than something the operator has to validate and reject at reconcile time.

Further, the allow values in `spec.allow` also depend on the targeted CR, as explained in later sections.

Because `NetworkPolicy` rules are additive (only allowing more access) the effect of multiple `KafkaProxyIngressNetworkPolicy` or `KafkaProxyEgressNetworkPolicy` resources with the same target is also to widen access.
This is a deliberate divergence from the Gateway API's direct policy attachment convention, where a target normally has at most one attached policy of a given kind; here, any number of `KafkaProxyIngressNetworkPolicy`/`KafkaProxyEgressNetworkPolicy` resources may target the same CR, and their rules are unioned rather than one replacing another.

Each generated `NetworkPolicy` is owned (via `ownerReferences`) by whichever CR caused it to be generated. A `NetworkPolicy` generated because a `KafkaProxyIngressNetworkPolicy`/`KafkaProxyEgressNetworkPolicy` targets a resource is owned by that policy CR, so deleting the policy CR removes only the `NetworkPolicy` it produced, leaving any other generated `NetworkPolicy` for that target untouched. A default-allow `NetworkPolicy` (generated when no policy CR targets the resource) is instead owned by the target CR itself (`KafkaProxyIngress`, `KafkaService`, or `KafkaProtocolFilter`), since there is no policy CR to own it in that case.

The generated `NetworkPolicy` names shown throughout this proposal are prefixed versions of a source CR's name, and could in principle exceed Kubernetes' name length limit for a sufficiently long source name. Where that happens, the operator will apply the standard Kubernetes truncate-and-hash pattern (as used for e.g. `ReplicaSet`/`ControllerRevision` names) to keep the generated name both valid and deterministic.

#### Status conditions

Both kinds report the same two standard condition types in `status.conditions`, consistent with the existing `KafkaProxyIngress`/`KafkaService`/`KafkaProtocolFilter` CRs:

| Condition type | Status | Reason | Meaning |
| --- | --- | --- | --- |
| `ResolvedRefs` | `True` | — | `spec.targetRef` resolves to an existing CR of the expected kind, and that CR is itself fully resolved. |
| `ResolvedRefs` | `False` | `ReferencedResourcesNotFound` | No CR named `spec.targetRef.name` of the expected kind exists in this namespace. |
| `ResolvedRefs` | `False` | `TransitivelyReferencedResourcesNotFound` | The targeted CR exists but does not yet report `ResolvedRefs: True` itself (e.g. a targeted `KafkaProxyIngress` whose own `proxyRef` hasn't resolved). |
| `ResolvedRefs` | `Unknown` | — | The last reconciliation attempt failed with an error before refs could be checked. |
| `Accepted` | `True` | — | The policy is valid for its target; a `NetworkPolicy` will be generated from it. |
| `Accepted` | `False` | `Invalid` | Either the `spec.allow` rules use the wrong peer type for the target (e.g. `ipBlock` against a `clusterIP`-mechanism `KafkaProxyIngress`, or `namespaceSelector`/`podSelector` against a `loadBalancer`/`openShiftRoute`-mechanism one), or `ResolvedRefs` is `False` — a policy whose target can't be found or hasn't resolved is never `Accepted`, regardless of how valid its own rules are. |
| `Accepted` | `False` | `Disabled` | `NetworkPolicy` generation is disabled cluster-wide via `KafkaProxyOperatorConfig`. `ResolvedRefs` is unaffected and stays `True` in this case. |
| `Accepted` | `False` | `ReferencedResourceNotReconciled` | The targeted CR resolves (`ResolvedRefs: True`) but hasn't itself reached `Accepted: True` yet. |

The per-mechanism validation failures described in the sections below (e.g. an `ipBlock` rule against a `clusterIP` ingress) are reported as `Accepted: False` with reason `Invalid`, not as a separate condition type.

Because this validation happens on the reconciler's own schedule rather than at `kubectl apply` time, a `KafkaProxyIngressNetworkPolicy`/`KafkaProxyEgressNetworkPolicy` can be admitted and only later found to be rejected. GitOps/CI pipelines applying these CRs should therefore wait on the `Accepted` condition explicitly, e.g. `kubectl wait --for=condition=Accepted <kind>/<name>`, rather than treating a successful `kubectl apply` as confirmation that the policy took effect.

### Policy attachment to `KafkaProxyIngress`

When no `KafkaProxyIngressNetworkPolicy` targets a `KafkaProxyIngress` we will generate a default `NetworkPolicy` which allows access from anywhere.
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

When one or more `KafkaProxyIngressNetworkPolicy` target a given `KafkaProxyIngress` a single `NetworkPolicy` will be generated for each.
The `NetworkPolicy` names will follow the pattern `allow-ingress-${policy-name}`.
The exact content will depend on the ingress mechanism.
The `KafkaProxyIngress` CR supports three ingress mechanisms:

* `clusterIP` for access from Kafka clients running in the same Kubernetes cluster
* `loadBalancer` for access from Kafka clients running outside the Kubernetes cluster
* `openShiftRoute` for access from Kafka clients running outside the OpenShift cluster

#### The `clusterIP` case

The `clusterIP` mechanism is specifically intended for access from the same Kubernetes cluster. 
So when the mechanism is `clusterIP` the rules given in the `from` list of each `spec.allow[]` entry of a `KafkaProxyIngressNetworkPolicy` will be in terms of
`namespaceSelector` and/or `podSelector`.
The operator will reject `KafkaProxyIngressNetworkPolicy` instances where this is not the case (a `Accepted` condition with `status: False`, and an explanatory message).

```yaml
---
# Example ingress allowing connection from any Pod in the cluster
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxyIngress
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
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxyIngressNetworkPolicy
metadata:
  name: my-clusterIP-policy
spec:
  targetRef:
    group: kroxylicious.io
    kind: KafkaProxyIngress
    name: my-ingress
  allow:
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
    - ports: # the ingress's own listening port, since spec.allow[].ports was omitted
        - protocol: TCP
          port: <PORT_NUM>
      from: # copied verbatim from spec.allow[0].from
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

This will function similarly, except the validation of the rules in the `from` property of each `spec.allow[]` entry is different.
`loadBalancer` is explicitly intended for off-cluster access,
so the value must be a list of objects supporting an `ipBlock` property, like so:
```yaml
ipBlock:
  cidr: 203.0.113.0/24
```
(This is exactly the same schema as `NetworkPolicy` supports).
Again, the operator will reject `KafkaProxyIngressNetworkPolicy` instances where this is not the case (a `Accepted` condition with `status: False`, and an explanatory message).

To enforce this correctly some changes will also be needed to the loadBalancer `Service` the operator generates.
`Service.spec.loadBalancerSourceRanges` is a best-effort declaration of the source IPs which should be allowed through the load balance.
In practice enforcement is cloud-provider-dependent, and this can be ignored. 
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
  loadBalancerSourceRanges:
    - 203.0.113.0/24
  externalTrafficPolicy: Local
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
      ports: # for each port
        - protocol: TCP
          port: <PORT_NUM>
```

We currently share a single loadbalancer between all the SNI ingresses.
Sharing amortizes the cost associated with cloud load balancers. 
But sharing means the apparent IP range segregation given by multiple `KafkaProxyIngressNetworkPolicy` resources targeting different `KafkaProxyIngresses` would not actually be honoured. 

Splitting the shared `Service` using a `Service`-per-shared-CIDR-groups would be possible, but has significant drawbacks:

* the cost implication of using multiple services. 
* only the cloud LB layer gets finer-grained rules
* a pod-level `NetworkPolicy` still can't differentiate traffic once it reaches the shared port (it doesn't know which Service/LB a packet arrived through), so the `NetworkPolicy` itself would still need to allow the union of all groups' CIDRs. 

Instead it is proposed to keep the single loadbalancer `Service`.
The operator will construct the union of the CIDRs from all `KafkaProxyIngressNetworkPolicy` resources targeting any ingress sharing that proxy's SNI Service, and apply that single union to both `loadBalancerSourceRanges` and the pod-level `NetworkPolicy`.
(See [Future work](#future-work) for a possible enhancement that would recover per-virtual-cluster isolation on a shared load balancer.)

#### The `openShiftRoute` case

Like `loadBalancer`, the `openShiftRoute` mechanism is explicitly intended for off-cluster access.
Again, the validation of the rules in the `from` property of each `spec.allow[]` entry will require the use of `ipBlock`.
Again, the operator will reject `KafkaProxyIngressNetworkPolicy` instances where this is not the case (a `Accepted` condition with `status: False`, and an explanatory message).

To restrict access by client CIDR with an OpenShift `Route`, we must restrict traffic at the `Route` layer using an annotation, and pair it with a `NetworkPolicy` to restrict `Pod` ingress to only the OpenShift Ingress `Router`.

```yaml
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: my-proxy-cr-my-ingress
  namespace: my-proxy
  annotations:
    # Space-separated list of allowed CIDRs or IP addresses, taken from the KafkaProxyIngressNetworkPolicy
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

When no `KafkaProxyEgressNetworkPolicy` targets a `KafkaService` we will generate a default `NetworkPolicy` which allows access to anywhere.
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

When one or more `KafkaProxyEgressNetworkPolicy` target a given `KafkaService` a single `NetworkPolicy` will be generated for each.
The `NetworkPolicy` names will follow the pattern `allow-egress-${policy-name}`.

The `KafkaService` CR supports two ways to express a target cluster:

* `strimziKafkaRef` is a reference to a Strimzi `Kafka` resource which exists in the same cluster as the `KafkaService` CR.
* `bootstrapServers` is a comma-separated list of the host addresses for some bootstrap servers of a Kafka cluster.


#### The `strimziKafkaRef` case

`strimziKafkaRef` is a very special case. 
We already know the namespace of the `Kafka` cluster, and the `Pod` labels (and hence selectors) are a published part of the Strimzi API. 
So in this case we don't need an explicit `allow` list.
Its contents can always be inferred from the properties of `strimziKafkaRef`.
However, for uniformity with the rest of the API we will require a `KafkaProxyEgressNetworkPolicy` to be present in order to generate a specific `NetworkPolicy`

```yaml
---
kind: KafkaService
metadata:
  namespace: my-proxy-ns
  name: strimzi-target
spec:
  strimziKafkaRef: 
    kind: Kafka
    group: kafka.strimzi.io
    name: my-kafka-cluster
    namespace: my-strimzi-namespace
    listenerName: my-listener
---
# Example egress policy restricting access to the given namespaces and pods
kind: KafkaProxyEgressNetworkPolicy
metadata:
  name: my-strimzi-target
spec:
  targetRef:
    group: kroxylicious.io
    kind: KafkaService
    name: strimzi-target
  allow: []
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
    - ports:
        - protocol: TCP
          port: 9092
      to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: my-strimzi-namespace
        - podSelector:
            matchLabels:
              strimzi.io/cluster: my-kafka-cluster
              strimzi.io/kind: Kafka 
              strimzi.io/broker-role: "true"

```

#### The `bootstrapServers` case


`bootstrapServers` allows any kind of host address to be specified.
Supporting it involves a number of sub-cases:

* the given servers are internal IPv4 or IPv6 addresses
* the given servers are internal DNS names (e.g. `my-kafka-cluster-kafka-bootstrap.my-ns.svc.cluster.local`, a Strimzi bootstrap `Service` DNS name)
* the given servers are external IPv4 or IPv6 addresses
* the given servers are external DNS names (e.g. `node12.kafka.example.com:9092`)

The use of internal IP address will not be supported.
`KafkaService` resources with `bootstrapServers` including any internal IP address will be rejected using an `Accepted` condition with a suitable message.
There is no good reason users should be using IP addresses to specify an internal Kafka cluster. 
IP addresses in Kubernetes are very dynamic, so it's unlikely to work reliably, even if it were supported.

##### Internal DNS names

Strimzi's bootstrap `Service` for a listener is named `<cluster-name>-kafka-bootstrap` (or `<cluster-name>-kafka-<listener-name>-bootstrap` for a named listener), giving an internal DNS name of the form `<cluster-name>-kafka-bootstrap.<namespace>.svc.<cluster-domain>`.
This is the form `bootstrapServers` should expect: it's derived only from the `Kafka` resource's name, so it stays stable across broker scaling and `KafkaNodePool` changes.
Strimzi also makes individual broker pods addressable via a headless `Service` (`<cluster-name>-kafka-<broker-id>.<cluster-name>-kafka-brokers.<namespace>.svc.<cluster-domain>`), but with `KafkaNodePool`s in use the `<broker-id>` portion depends on node pool naming and can change as pools are scaled or renamed, so it's not a reliable choice for a `bootstrapServers` entry.

When the bootstrap servers list is entirely composed of internal DNS names the `to` property of each `spec.allow[]` entry will be required to use `namespaceSelector` and/or `podSelector` rules.


```yaml
---
kind: KafkaService
metadata:
  namespace: my-proxy-ns
  name: internal-dns
spec:
  bootstrapServers: my-kafka-cluster-kafka-bootstrap.my-ns.svc.cluster.local:9092
---
# Example egress policy restricting access to the given namespaces and pods
kind: KafkaProxyEgressNetworkPolicy
metadata:
  name: my-strimzi-target
spec:
  targetRef:
    group: kroxylicious.io
    kind: KafkaService
    name: internal-dns
  allow:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: my-ns
```

##### External DNS names and external IP addresses

When the bootstrap servers list is entirely composed of external DNS names and/or external IP addresses the `to` property of each `spec.allow[]` entry will be required to use `ipBlock` rules.

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
kind: KafkaProxyEgressNetworkPolicy
metadata:
  name: my-strimzi-target
spec:
  targetRef:
    group: kroxylicious.io
    kind: KafkaService
    name: internal-dns
  allow:
    - to:
        - ipBlock:
            cidr: 10.0.23.0/24
```

### Policy attachment to `KafkaProtocolFilter`

The `KafkaProtocolFilter` CR is used to configure filters. 
It is common for filters, or their plugins, to require network egress.
It's also not forbidden for filters to require network ingress.
In the most general case, a filter or its plugin would require rules for both egress and ingress — in which case the filter is targeted by one `KafkaProxyIngressNetworkPolicy` and one `KafkaProxyEgressNetworkPolicy`, each generating its own `NetworkPolicy`.

When no `KafkaProxyIngressNetworkPolicy`/`KafkaProxyEgressNetworkPolicy` targets a `KafkaProtocolFilter`, the `NetworkPolicy` generated for the missing direction(s) depends on `KafkaProxyOperatorConfig.spec.resourceGeneration[].options.filterDefaultPolicy` (see [`filterDefaultPolicy`](#filterdefaultpolicy) below).
Unlike `KafkaProxyIngress` and `KafkaService` — which always need *some* access just to function, so always default to allow — a `KafkaProtocolFilter` may need no network access at all, so whether it's safe to default to allow-all is a real question, not a given.
The default value, `allow`, generates a `NetworkPolicy` which allows access to/from anywhere, named `default-allow-ingress-filter-${kafka-filter-name}`/`default-allow-egress-filter-${kafka-filter-name}`, matching the pattern used elsewhere in this proposal.
The alternative, `deny`, generates a `NetworkPolicy` with the matching `policyTypes` entry but no rules at all (e.g. `ingress: []`), named `default-deny-ingress-filter-${kafka-filter-name}`/`default-deny-egress-filter-${kafka-filter-name}` — Kubernetes' own `NetworkPolicy` semantics mean a `Pod` selected by a policy of a given type with no matching rule denies all traffic of that type, so this blocks the direction entirely until a `KafkaProxyIngressNetworkPolicy`/`KafkaProxyEgressNetworkPolicy` is attached (whose rules are additive with this baseline, per the additive semantics described above).

When a `KafkaProxyIngressNetworkPolicy` or `KafkaProxyEgressNetworkPolicy` targets a given `KafkaProtocolFilter`, a `NetworkPolicy` will be generated for each, in the same way as for `KafkaProxyIngress` and `KafkaService` above.
The `NetworkPolicy` names will follow the patterns `allow-ingress-filter-${policy-name}` and `allow-egress-filter-${policy-name}`.

Here's an example for the `RecordEncryption` filter, which only needs egress:

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
kind: KafkaProxyEgressNetworkPolicy
metadata:
  name: encryption-connect-to-vault
spec:
  targetRef:
    group: kroxylicious.io
    kind: KafkaProtocolFilter
    name: encryption
  allow:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: vault
      ports:
        - protocol: TCP
          port: 8200
```

And the resulting `NetworkPolicy`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-filter-encryption-connect-to-vault
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
          port: 8200
      to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: vault
```


### Operator-level opt-out

We will add a new cluster-scoped CRD for expressing options for the operator.
Here's an example CR:

```yaml
apiVersion: kroxylicious.io/v1alpha1
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
  resourceGeneration:
  - group: networking.k8s.io
    kind: NetworkPolicy
    options: 
      generation: enabled|disabled
      filterDefaultPolicy: allow|deny
  policyAttachment: 
    policyTarget: 
      - group: kroxylicious.io
        kinds: 
          - KafkaProxyIngress
          - KafkaService
          - KafkaProtocolFilter
    requiredAttachments: 
      - group: kroxylicious.io
        kind: KafkaProxyIngressNetworkPolicy
      - group: kroxylicious.io
        kind: KafkaProxyEgressNetworkPolicy
    # also prohibitedAttachments and permittedAttachments
```

The operator `Deployment` itself will support a `CONFIG_NAME` env var which allows to select the `KafkaProxyOperatorConfig` to be used by that operator instance.
The value will default to `default`. 

#### `clusterDomain`

The `clusterDomain` option provides an admin override to the autodetection of the cluster domain DNS suffix.
The default will be based on the `search` stanza of the operator's local `/etc/resolv.conf`, which should normally work without the `clusterDomain` option needing to be defined.

#### `clusterCIDRs`

The `clusterCIDRs` option allows an admin to specify the IP blocks for cluster-local addresses. 
This is needed in order to detect and reject internal addresses for `KafkaService.spec.bootstrapServers`.

#### `resourceGeneration`

This allow enabling/disabling the generation of resources.
The schema is flexible to allow other, additional resource kinds to be optionally generated by the operation in future.
The options for `generation` are as follows:

* `enabled`: `NetworkPolicies` will be generated
* `disabled`: `NetworkPolicies` will not be generated

The default value for `generation` for `NetworkPolicy` will be `enabled`. 

#### `filterDefaultPolicy`

This controls what gets generated for a `KafkaProtocolFilter` when no `KafkaProxyIngressNetworkPolicy`/`KafkaProxyEgressNetworkPolicy` targets it, as described under [Policy attachment to `KafkaProtocolFilter`](#policy-attachment-to-kafkaprotocolfilter) above.
It does not affect `KafkaProxyIngress` or `KafkaService`, which always default to `allow` since they need some access just to function.

The schema default is `allow`, so that upgrading a cluster already running this operator never silently cuts off a filter's access it was previously relying on.
A fresh, net-new install should not have to live with that default indefinitely, though, so the operator applies one piece of first-run logic: on startup, if no `KafkaProxyOperatorConfig` named `default` exists *and* no `KafkaProxy` or `KafkaProtocolFilter` resources exist anywhere in the cluster either, the operator creates one with `filterDefaultPolicy: deny`, giving new installations a secure default with no configuration required. If any such resources already exist, the operator does not auto-create a config, and the `allow` default continues to apply until an administrator explicitly opts in to `deny`.

This heuristic lives entirely in the operator itself, rather than in any install-time tooling, so it behaves identically regardless of how the operator is installed (OLM, via any catalog, Helm, or raw manifests).
It has to: `KafkaProxyOperatorConfig` is a brand-new CRD, so its absence looks identical on a genuinely fresh install and on an existing deployment upgrading to a version with this feature — neither OLM's `ClusterServiceVersion` nor most other install mechanisms can tell those two cases apart from that signal alone, since nothing before this feature shipped a `KafkaProxyOperatorConfig` either way. The one failure mode of this heuristic — an existing-but-never-used install getting classified as "fresh" — is harmless, since there's no existing filter access to break in that case anyway.

#### `policyAttachment`

`NetworkPolicy` is a `Pod`-level control for network access.
Consider a `KafkaProxy` with an external `KafkaService` being used with a Kafka-as-a-Service where the user doesn't know an `ipBlock` range to lock down the rule.
An allow-egress-to-anywhere rule will have to be used. 
However, a particular filter might also require network egress.
With the APIs as described so far that filter can get a free ride from the allow-egress-to-anywhere rule needed for `KafkaService`.
It would function correctly without any `KafkaProxyEgressNetworkPolicy` targeting it.
It would be better if the declarative APIs reflected the true situation, with an explicit `KafkaProxyEgressNetworkPolicy` targeting the `KafkaProtocolFilter`.

`policyAttachment` allows the proxy admin to require that Kroxylicious CRs of certain kinds have policy attachments of certain other kinds.
This could be used to make the operator reject any `KafkaProtocolFilter` which lacked a `KafkaProxyEgressNetworkPolicy` targeting that filter.
The owner of the filter would need to write a `KafkaProxyEgressNetworkPolicy`.

It would still be possible for the owner of the filter to write an _incorrect_ `KafkaProxyEgressNetworkPolicy`, but that is something which might get caught during review.
Without `policyAttachment` it is more likely a review might overlook the incorrectly declared network access, simply because it was omitted.

* `requiredAttachments`: List the policies which **must** be attached. The `policyTarget` will be rejected if a policy of that kind is missing.
* `permittedAttachments`: List the policies which **may** be attached. The `policyTarget` will not be rejected whether or not a policy of that kind is exists.
* `prohibitedAttachments`: List the policies which **must not** be attached. The `policyTarget` will be rejected if a policy of that kind is present.

A use case for `prohibitedAttachments` is where `NetworkPolicy` resource generation is `disabled`. 
For example perhaps the operating organization's processes require that `NetworkPolicies` are maintained manually. 
In this case it might be confusing to have a `KafkaProxyIngressNetworkPolicy` or `KafkaProxyEgressNetworkPolicy` targeting a resource which is actually ignored by the operator. 
Using `prohibitedAttachments` to prevent the attachment of either kind would avoid this.

### Operator RBAC changes

The operator will need to be allowed to CRUD `NetworkPolicy` resources via its dependent resources `ClusterRole`.

It will also need `watch`, `get`, `list`, `patch`, `update` (+ `/status`) on `KafkaProxyIngressNetworkPolicy`, `KafkaProxyEgressNetworkPolicy`, and `KafkaProxyOperatorConfig` in the "watched resources" `ClusterRole`.

### Future work

As a possible future development, we could add an IP-allowlist capability enforced in the proxy itself, and have the operator feed that with the ipBlock rules from the `KafkaProxyIngressNetworkPolicy`.
Crucially this could be done once the SNI host name is known, thus recovering the per-virtual-cluster network isolation on shared load balancers semantic implied by the CR API (which the shared-loadbalancer `Service` CIDR union described under [the `loadBalancer` case](#the-loadbalancer-case) does not).

## Affected/not affected projects

This affects the `kroxylicious/kroxylicious` repo. 

## Compatibility

The proposed changes are backwards compatible, because the `NetworkPolicies` generated in the absence of `KafkaProxyIngressNetworkPolicy`/`KafkaProxyEgressNetworkPolicy` are default allow.
If, due to a bug, the generated policies prevented connections, the user would be able to work around it by setting `KafkaProxyOperatorConfig.spec.generation: disabled`.

This holds even for `KafkaProtocolFilter`'s `filterDefaultPolicy` (see [`filterDefaultPolicy`](#filterdefaultpolicy)), despite its schema default of `allow` being considered insufficiently secure for new installs: an existing deployment upgrading to a version with this feature keeps `allow` unless an administrator opts in to `deny`, while the operator's first-run heuristic gives a genuinely fresh install `deny` with no configuration required. Compatibility is preserved by detecting which situation applies at runtime, rather than by picking one default for everyone.

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
    - However, such policies are not easy to audit because the reason why any particular rule allows access canont be easily traced back where and why that access is needed.
* "Consume a single monolithic policy-attachment CR, rather than one per rule."
    - As for having a single monolithic `NetworkPolicy`, using fine grained resources aids auditing.
    - We can also apply sensible validation to the policy rules.
* "Use a single `KafkaProxyNetworkPolicy` kind for both ingress and egress rules, rather than splitting by direction."
    - A single kind can only be granted or withheld as a whole via Kubernetes RBAC, which is enforced per-kind, not per spec-field or per-`targetRef`.
      In a namespace with one shared `KafkaProxyIngress` and several independently-owned `KafkaProtocolFilter`s, this would mean a role trusted to declare a single filter's own egress need (e.g. "reach Vault on port 8200") would, by that same RBAC grant, also be able to declare an allow-from-anywhere ingress rule against the shared `KafkaProxyIngress`, affecting every tenant of that proxy.
      Splitting by direction gives RBAC a meaningful boundary to grant against.
    - A single kind also requires the operator to validate and reject invalid direction/target combinations (e.g. an ingress rule against a `KafkaService`) at reconcile time. Splitting by direction makes these combinations impossible to express in the first place.
* "Use one kind per target CR (`KafkaProxyIngress`, `KafkaService`, `KafkaProtocolFilter`), rather than splitting by direction."
    - This is the most granular option: it would let an organization separate "who sets the proxy's ingress exposure," "who sets its egress to the real cluster," and "who sets a given filter's needs" into three distinct RBAC-governed roles.
    - Rejected for now as more CRDs/RBAC surface than the problem calls for. Splitting by direction already removes the sharpest issue — a filter's own rules sharing a kind with the proxy's ingress exposure. The residual coarseness it leaves, a `KafkaService`'s bulk egress and an individual filter's egress sharing the `KafkaProxyEgressNetworkPolicy` kind/RBAC surface, was judged an acceptable trade-off for a smaller API surface. This can be revisited, by splitting `KafkaProxyEgressNetworkPolicy` further, if that turns out to matter in practice.
* "Use the same property name (`networkPolicyPeers`) as Strimzi"
    - `networkPolicyPeers` does not distinguish between the ingress and egress cases. We have CRs which support one, but not the other, and other CRs which support both at the same time. Being able to distinguish between the two cases seems like a useful way to ensure unambiguous communication of the user's intent.
* "Put the rules in the existing CRs, rather then forcing the users to create new separate CRs"
    - This is not sympathetic to the existing CR API design. We chose to have different `kinds` for separate concerns like `KafkaProtocolFilter` and `KafkaProxyIngress` precisely because different organizations have different ways of segregating responsibility in their org structure. Using different kinds allows such orgs to use Kubernetes RBAC to achieve the segregation of concerns that they need. Using a separate CR API for what amount to firewall rules seems like a better choice.
* "Use env vars directly for configuring the operator, rather than introducing a new CRD"
    - For the specific operator config options in this proposal env vars would suffice. 
    - However, this would establish env vars as being _the_ mechanism for configuration the operator. We suspect the operator will gain more configurability options in the future. 
    - Using a CR has a number of advantages:
        - Documented and discoverable using tools like `kubectl explain`, in a way that env vars are not.
        - Kubernetes-aware editors can support writing via features like code completion and inline documentation, driven off the CRD schema.
        - Better support for structured values using YAML. For example lists are just YAML lists, rather than needing to define that the env var's value must be a comma separated list.
        - More easily modified by end users (who often don't want to customise `Deployment` env vars)
* "Seed a `deny`-default `KafkaProxyOperatorConfig` via install-time tooling (an OLM `ClusterServiceVersion` `initialization-resource`/`alm-examples` annotation, a Helm hook, or a bundled manifest), rather than having the operator decide at runtime."
    - `KafkaProxyOperatorConfig` is a brand-new CRD, so the CR is absent both on a genuinely fresh install and on an existing deployment upgrading to a version with this feature — any "create this resource if it's absent" mechanism at the install-tooling layer cannot distinguish those two cases from that signal alone.
    - Helm does have `pre-install`/`post-install` hooks that fire only on `helm install`, not `helm upgrade`, which could work for Helm specifically, but OLM's `ClusterServiceVersion` has no equivalent "only on first install" concept, and this operator needs to support both. Relying on install-tooling would therefore behave inconsistently across install mechanisms, or not at all for OLM-based installs (OpenShift's embedded OperatorHub included, since it uses the same CSV mechanics as upstream OLM regardless of catalog source).
    - Deciding this in the operator itself, based on whether any `KafkaProxy`/`KafkaProtocolFilter` resources already exist, works uniformly no matter how the operator was installed.
