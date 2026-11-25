# 138 - Kubernetes `NetworkPolicies`

Add support for operator-generated [`NetworkPolicy`](https://kubernetes.io/docs/concepts/services-networking/network-policies/) to limit network ingress to, and egress from, proxy instances running on Kubernetes.

## Current situation

Currently the Kroxylicious operator for Kubernetes does not generate `NetworkPolicy` resources at all.
So Kroxylicious users have needed to write NP for the proxy in order to work within Kubernetes's tiered model.

Originally Kubernetes supported only `NetworkPolicy` (NP), which got used by both Kubernetes admins and application developers/tenants.
Due to the friction this caused, since about 2022 Kubernetes has supported a tiered model:
* The Kubernetes admin-owned `AdminNetworkPolicy` is evaluated before NPs, and provides non-negotiable rules (e.g., "Nobody can talk to the kube-system namespace").
* The Kubernetes admin-owned `BaselineAdminNetworkPolicy` is evaluated after NPs, and provides a set of fallback rules (e.g., "If the developer didn't specify a rule, deny the traffic").
* This means NP are now unambiguously intended to be owned by developers/tenants to express their needs.

It's worth calling out some important aspects of the `NetworkPolicy` API in Kubernetes:
* Enforcement of `NetworkPolicy` depends on the cluster's CNI plugin supporting it (e.g. Calico, Cilium); some CNIs accept `NetworkPolicy` resources without enforcing them.
  A generated policy still has declarative/audit value on such a cluster, but it gives no actual network isolation unless the CNI enforces it.
  The same caveat applies one layer up, to `Service.spec.loadBalancerSourceRanges` (used by [the `loadBalancer` case](#the-loadbalancer-case) below): enforcement depends on the cloud provider's load-balancer controller honouring it, and some (e.g. certain bare-metal/MetalLB setups) accept the field without enforcing it, giving no actual source-IP restriction despite the declared `ipBlock`.
* Each rule in a policy can only widen access, never narrow access. In other words, policies are "additive". This holds both within a single `NetworkPolicy` and across multiple `NetworkPolicy` resources selecting the same `Pod`: Kubernetes unions all their rules rather than letting one override another.
* `NetworkPolicy` has no direct support for expressing rules using external DNS names (e.g. there is no way to say "allow connections to `kms.example.com`").
  Where external DNS names are used for egress, it's necessary to have an "allow egress to anywhere" `NetworkPolicy` rule.
  Some CNIs support custom APIs which support these rules, but they're out of scope for this proposal.
* Same-kubernetes-cluster rules can be expressed in terms of namespace and pod selectors (e.g. you can say "allow connections to pods matching _this_ selector in namespaces matching _that_ selector"). Moreover, it is considered bad practice to use an `ipBlock` to allow access to/from a pod in the same cluster.

Users of the Kroxylicious operator are assumed to fall into the "developers/tenants" bucket, rather than also being Kubernetes admins.

## Motivation

Enterprises are increasingly security-conscious: Kubernetes vendors and admins are adopting default-deny and microsegmentation approaches that make a `NetworkPolicy` a requirement, and even clusters without a default-deny posture are usually better off with one than without.
Tools like the [CIS Kubernetes Benchmark](https://www.armosec.io/glossary/cis-kubernetes-benchmark/) also use `NetworkPolicies` as a declarative input when auditing Kubernetes workloads: a specific policy statement conveys a design requirement, whereas the absence of one could be interpreted as an oversight — and some scanners flag that absence directly.

While it's easy to say "the user should write the NP themselves," that's difficult to do _well_ given how Kafka, the proxy, and the operator interact:

* The Kafka protocol uses the `Metadata` API to discover brokers, so the host addresses in a `KafkaService`'s `bootstrapServers` are only a subset of (or, when behind a load balancer, unrelated to) what a client — here, the proxy — ends up needing to connect to once the broker topology is discovered. For a proxy targeting a Strimzi-managed cluster on the same Kubernetes cluster, the operator can work this out for the user.
* The proxy itself is pluggable, and plugins can bring their own network access requirements — but there's no sound way for the operator, or the proxy itself, to infer those from a plugin's configuration. A plugin that reports to a separate Kafka cluster, for instance, would need its own `bootstrapServers`-like list, but the actual set of brokers it ends up talking to could be larger than that list, and nothing in the plugin's configuration reveals what its egress rules should be.

## Proposal

Since the operator alone is unable to determine a working minimal `NetworkPolicy` for any given set of Kroxylicious resources (`KafkaProxy`, `KafkaProtocolFilter`, etc), it's necessary for the user to provide some ingress and egress information.

To make best use of Kubernetes' RBAC authorization, it is proposed to express ingress and egress information in a dedicated CR, rather than in the existing Kroxylicious resources.
This will permit the Data Engineer to have access to a `KafkaProtocolFilter` without also granting them control over the firewall rules for the proxy as a whole.

Each `KafkaProxy` has at most one companion `KafkaProxyNetworkPolicy`, which declares, in one place, the ingress and egress rules for CR belonging to that proxy. This results in a simple CRD, validation, and reconciliation story, and a single place to review a proxy's complete declared network policy.

`NetworkPolicy` generation is controlled by the `KROXYLICIOUS_KPNP_ABSENT` environment variable on the operator `Deployment`. This variable controls what happens when no `KafkaProxyNetworkPolicy` exists for a proxy at all. It can take three values:
- `allow-all`: generates a `NetworkPolicy` allowing traffic from/to anywhere for every target (the default)
- `deny-all`: generates a `NetworkPolicy` with no rules for every target
- `no-np`: disables `NetworkPolicy` generation entirely — this is a true off switch: transitioning to `no-np` actively deletes any previously-generated `kroxylicious.io/default-policy`-labelled `NetworkPolicy`, rather than merely leaving existing ones in place

### Non-goals

* Support for other resources than Kubernetes' built-in `NetworkPolicy`.
* RBAC separation finer than "who may shape this `KafkaProxy`'s network policy as a whole" — e.g. separately granting one role control over a proxy's ingress exposure, another over its egress to the real cluster, and a third over an individual filter's own needs. 
* Support for the new `KafkaProtocolRouter` CR, from [proposal #142](https://github.com/kroxylicious/design/blob/main/proposals/142-kube-api-routing.md), or the new `spec.tlsSubjectBuilder` of `VirtualKafkaCluster`, from [proposal #146](https://github.com/kroxylicious/design/blob/main/proposals/146-tls-subject-builder-crd.md). Either can end up needing real network access — a router plugin making its own upstream calls, or a `tlsSubjectBuilder` backed by LDAP or OAuth token introspection — but neither is addressed here. Both are structurally like `KafkaProtocolFilter` — standalone CRs that resolve transitively to a proxy — so adding either as a target later is a purely additive extension to `KafkaProxyNetworkPolicy`, following the same `filterRef`-style resolution and required-`ports` pattern already used for filters, rather than a redesign.

### Goals

* Introduce a new CRD allowing a user to express, for a given `KafkaProxy`, the complete set of ingress and egress rules it needs: its ingress exposure, its egress to the real Kafka cluster(s), and any ingress/egress its filters need.
* Keep that CRD separate from `KafkaProxyIngress`, `KafkaService`, and `KafkaProtocolFilter`, so that the RBAC grant needed to shape a proxy's network behaviour can be distinct from the grant needed to configure the rest of it.
* A single CR should be authoritative for a given `KafkaProxy`'s entire declared network policy, so that auditing a proxy's access doesn't require enumerating objects scattered elsewhere in the namespace.
* Generate `NetworkPolicy` resources targeting the proxy's `Pods`, one per declared (or defaulted) ingress/service/filter, with descriptive `metadata.name`s, so that auditing why a particular rule exists doesn't require reading the content of every rule.
* `KROXYLICIOUS_KPNP_ABSENT` defaults to `allow-all` so a `KafkaProxy` generates `NetworkPolicy` resources for every target with no declared rules and passes traffic immediately, without requiring a `KafkaProxyNetworkPolicy` to exist first. This is a deliberate, one-off exception to the project's usual backwards-compatibility bar — see [Compatibility](#compatibility) for the rationale and the risks it accepts.
* A gap in, or failure to resolve, one target's declared rules must never retract already-working enforcement for another target on the same proxy ("stale but safe" — see [`ownerReferences`](#ownerreferences)).

### New CRD: `KafkaProxyNetworkPolicy`

A single new custom resource definition will be added: `KafkaProxyNetworkPolicy` (namespaced).
This CRD lets whoever declares a proxy's network needs — e.g. which may be a distinct role that whoever owns the proxy's `KafkaProxyIngress`, `KafkaService`, and `KafkaProtocolFilter` resources — declare the networking needs for one `KafkaProxy` and its related CRs.

Each `KafkaProxy` may have **at most one** `KafkaProxyNetworkPolicy`, referencing it explicitly via `spec.kafkaProxy.proxyRef` — the same pattern used elsewhere in this API (e.g. `KafkaProxyIngress.spec.proxyRef`). 
If a second `KafkaProxyNetworkPolicy` is created with a `proxyRef` to a `KafkaProxy` that already has one, the second is rejected: `Accepted: False`, reason `Conflicting`, pointing at the name of the one already in effect. 
Ordering is by creation timestamp, breaking ties — timestamps only have second-level resolution — by lexicographically later `metadata.name`.

Unlike `proxyRef` elsewhere in this API (none of which enforce it today), `spec.kafkaProxy.proxyRef` on `KafkaProxyNetworkPolicy` is immutable (a CEL `self == oldSelf` validation rule), rejecting any attempt to change it after creation. Without this, re-pointing `proxyRef` on a live `KafkaProxyNetworkPolicy` would silently revert the old proxy to its `KROXYLICIOUS_KPNP_ABSENT` fallback (it would no longer have a `KafkaProxyNetworkPolicy` of its own) while leaving that proxy's previously generated `NetworkPolicy`s — owned by the target CRs, not by the `KafkaProxyNetworkPolicy` itself — in place until their content is next recomputed against the new proxy. Making the field immutable means re-pointing requires deleting and recreating the `KafkaProxyNetworkPolicy`, which goes through the same, already-specified deletion/garbage-collection and `KROXYLICIOUS_KPNP_ABSENT`-fallback paths as any other removal.

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxyNetworkPolicy
metadata:
  name: my-proxy-network-policy
spec:
  defaultIngress: allow-all               # required
  defaultEgress: allow-all                # required
  kafkaProxy:                             # required
    proxyRef:                             # required
      name: my-proxy                      # required
    ...
  kafkaProxyIngresses:                    # required, may be []
    - ingressRef:                         # required
        name: my-ingress                  # required
      ...
    - ingressRef:                         # required
        name: my-other-ingress            # required
      ...
  kafkaServices:                          # required, may be []
    - serviceRef:                         # required
        name: my-strimzi                  # required
    - serviceRef:                         # required
        name: my-external-kafka-cluster   # required
      ...
  kafkaProtocolFilters:                   # required, may be []
    - filterRef:                          # required
        name: my-encryption-filter        # required
      ...
```

The `defaultIngress` and `defaultEgress` specify how the operator handles missing references. These will be explained in later sections.

The `kafkaProxyIngresses`, `kafkaServices`, and `kafkaProtocolFilters` lists are themselves required, though each may be empty, rather than being optional and defaulting to empty: this keeps "no entries" an explicit statement in the CR rather than an absent field whose default behaviour a reader would have to go and look up.

The elipsis for each section of the CR represent some network rules which apply to that CR. For example an object with a `filterRef` has other properties which are used to describe the network ingress and egress needs of that filter.

These properties aren't uniformly shaped, because the sections genuinely differ: where the operator already knows the ports or peers itself, the user only supplies what it can't infer; and a rule needed almost universally may be offered as a simple boolean rather than a full rule list. See the per-target sections below for specifics.

### Resolution

The operator resolves each of the referenced CRs (`spec.kafkaProxy.proxyRef`, `ingressRef`, `serviceRef`, and `filterRef`) to determine whether the KPNP is well-formed and acceptable, updating the `status` with the result. A reference is only considered resolved if:

* the referenced CR exists 
* **and** the referenced CR has `ResolvedRefs: True`
* **and** the referenced CR, directly or transitively, resolves to the same `KafkaProxy` named by this `KafkaProxyNetworkPolicy`'s own `spec.kafkaProxy.proxyRef` — e.g. a `serviceRef` pointing at a `KafkaService` that isn't actually attached to this proxy's `VirtualKafkaCluster`(s) does not resolve.

This is a per-`KafkaProxyNetworkPolicy` check, not an exclusivity check: a `KafkaService` or `KafkaProtocolFilter` with no `proxyRef` of its own can legitimately be attached, via one or more `VirtualKafkaCluster`s, to more than one `KafkaProxy` at once, in which case it resolves for each of those proxies' `KafkaProxyNetworkPolicy`s independently and simultaneously.

A `KafkaProxyNetworkPolicy` is only `Accepted: True` if, in addition to every listed ref resolving, the reverse also holds: every `KafkaProxyIngress`, `KafkaService`, and `KafkaProtocolFilter` that resolves to this proxy has a corresponding entry in the relevant list of the `KafkaProxyNetworkPolicy`. This means there's no way for a CR related to the `KafkaProxy` to get a "free ride" on a sibling's broad network access rule without an explicit entry of its own making that visible.

#### Status conditions

`KafkaProxyNetworkPolicy` reports three standard roll-up conditions in `status.conditions`, consistent with the existing `KafkaProxyIngress`/`KafkaService`/`KafkaProtocolFilter` CRs, plus per-entry status for each list item (following the same per-item status convention as e.g. the Gateway API's `HTTPRoute.status.parents[]`):

```yaml
status:
  conditions:
    - type: ResolvedRefs
      status: "True"
    - type: Accepted
      status: "False"
      reason: Incomplete
      message: |-
        2 resources attached to this proxy have no corresponding entry:
        - KafkaProtocolFilter 'my-other-filter'
        - KafkaService 'my-second-cluster'
    - type: Programmed
      status: "True"
  effectivelyUnrestrictedIngress: false
  effectivelyUnrestrictedEgress: true  # some target's allow-all makes other targets' narrow egress rules moot
  kafkaProxyIngresses:
    - ingressRef:
        name: my-ingress
      conditions: [...]
  kafkaServices:
    - serviceRef:
        name: my-strimzi
      conditions: [...]
  kafkaProtocolFilters:
    - filterRef:
        name: my-encryption-filter
      conditions: [...]
```

Roll-up conditions:

| Condition type | Status | Reason | Meaning |
| --- | --- | --- | --- |
| `ResolvedRefs` | `True` | — | `spec.kafkaProxy.proxyRef` resolves, and every listed `ingressRef`/`serviceRef`/`filterRef` resolves to a CR that itself, directly or transitively, resolves to the same `KafkaProxy`. |
| `ResolvedRefs` | `False` | `ReferencedResourcesNotFound` | `spec.kafkaProxy.proxyRef`, or at least one listed ref, does not resolve to an existing CR in this namespace. |
| `ResolvedRefs` | `False` | `TransitivelyReferencedResourcesNotFound` | A listed ref resolves to an existing CR, but it does not resolve to the `KafkaProxy` named by `spec.kafkaProxy.proxyRef` (or doesn't itself report `ResolvedRefs: True`). |
| `ResolvedRefs` | `Unknown` | — | The last reconciliation attempt failed with an error before refs could be checked. |
| `Accepted` | `True` | — | `ResolvedRefs` is `True`, every entry's rules are valid for its target's mechanism, and every `KafkaProxyIngress`/`KafkaService`/`KafkaProtocolFilter` resolving to this proxy has a corresponding entry (the exhaustiveness check). |
| `Accepted` | `False` | `Incomplete` | `ResolvedRefs` is `True`, but at least one `KafkaProxyIngress`/`KafkaService`/`KafkaProtocolFilter` resolving to this proxy has no corresponding entry. `message` lists every missing ref by kind and name (not just the first found). |
| `Accepted` | `False` | `Conflicting` | Another `KafkaProxyNetworkPolicy` already targets the same `KafkaProxy` (see [`KafkaProxyNetworkPolicy`](#kafkaproxynetworkpolicy)). |
| `Programmed` | `True` | — | Every `NetworkPolicy` implied by every entry's last successfully-resolved spec has been created/updated in the API server. This says nothing about whether the cluster's CNI has actually enforced it — see [Current situation](#current-situation). |
| `Programmed` | `False` | `UpdateFailed` | The operator attempted to create/update at least one target's `NetworkPolicy` and the write failed. |
| `Programmed` | `Unknown` | — | Reconciliation hasn't reached the generation step yet, or the last attempt failed before getting there. |

Per-entry conditions use the same `ResolvedRefs`/`Accepted`/`Programmed` vocabulary, scoped to that one entry, so a user can tell at a glance which specific target is holding back the roll-up `Accepted: True` — and, per [Generation](#generation), which targets are currently relying on a stale or default-generated `NetworkPolicy` rather than their own declared rules. A "stale but safe" entry keeps `Programmed: True` even once `ResolvedRefs`/`Accepted` flips to `False`, since its existing `NetworkPolicy` still correctly reflects the last spec that did resolve.

**Known limitation:** all of this status lives only on `KafkaProxyNetworkPolicy`. `KafkaProxyIngress`, `KafkaService`, and `KafkaProtocolFilter` gain no new status field or condition of their own to reflect whether, or how, they're covered by it — a `KafkaProtocolFilter`'s own `status` says nothing about whether its egress is currently governed by its own declared rule, a stale one, or a `defaultEgress`/`KROXYLICIOUS_KPNP_ABSENT` fallback. This is in tension with this proposal's own RBAC-separation goal (see [Goals](#goals)): a user who's deliberately been granted access to `KafkaProtocolFilter` but not `KafkaProxyNetworkPolicy` has no self-service way to discover, from the object they can see, that their filter is stuck on `deny-all` because nobody's added an entry for it yet — they have to ask (or escalate to) whoever holds the `KafkaProxyNetworkPolicy` RBAC grant. A proper fix would mean propagating a status backlink onto the target CRs, similar in spirit to how Gateway API's `HTTPRoute.status.parents[]` reports per-parent-`Gateway` status back onto the route — but this codebase has no existing precedent for that kind of cross-resource status propagation, and retrofitting it is substantial, ongoing reconciler work for every target kind, not something justified by this proposal alone. We accept this as a known gap rather than solve it here: for now, diagnosing a network-policy-caused failure for a `KafkaProtocolFilter`/`KafkaService`/`KafkaProxyIngress` owner without `KafkaProxyNetworkPolicy` access requires reading `KafkaProxyNetworkPolicy.status` directly (or being told its contents by whoever can).

Because this validation happens on the reconciler's own schedule rather than at `kubectl apply` time (except for the schema-level constraints noted in [`KafkaProxyNetworkPolicy`](#kafkaproxynetworkpolicy), e.g. `ports` being absent/required per list), a `KafkaProxyNetworkPolicy` can be admitted and only later found to be rejected. GitOps/CI pipelines applying these CRs should therefore wait on both the `Accepted` and `Programmed` conditions explicitly, e.g. `kubectl wait --for=condition=Accepted --for=condition=Programmed kafkaproxynetworkpolicy/<name>`, rather than treating a successful `kubectl apply` as confirmation that every entry took effect.


### Generation

The operator also generates up to two `NetworkPolicies` (one for ingress and/or one for egress) for each of the referenced CRs.
Every generated `NetworkPolicy` shares a common `podSelector`, `ownerReferences` rule, and naming scheme.

* An entry that resolves and validates always generates/updates its `NetworkPolicy` from its declared rules, regardless of the state of any other entry.
* A target with **no** entry in the `KafkaProxyNetworkPolicy` (e.g. a `KafkaProtocolFilter` just added to the proxy, before `KafkaProxyNetworkPolicy` is updated) is treated according to the `spec.defaultIngress` or `spec.defaultEgress`: if set to `allow-all`, an allow-everywhere `NetworkPolicy` is generated; if set to `deny-all`, a `NetworkPolicy` with no rules is generated. These fallback policies are labelled `kroxylicious.io/default-policy` (see [Naming](#naming)). The fallback for one target does not affect any other, already-declared target. This is what keeps exhaustiveness from becoming a cliff-edge: a `KafkaProxyNetworkPolicy` that's `Accepted: False` because of one missing entry still has every other entry's precise, declared rules in full effect.
* An entry that previously resolved and validated, but no longer does because its referenced CR has been deleted, needs no special handling: that `NetworkPolicy` is owned by the referenced CR (see [`ownerReferences`](#ownerreferences)), so it's garbage-collected along with it. An entry that stops resolving for any other reason (e.g. its referenced CR still exists, but no longer resolves to this proxy) leaves its previously generated `NetworkPolicy` untouched under its existing owner — "stale but safe". The entry is reported as unresolved in `status` (see below) until it's fixed or removed.

This means `Accepted` on the `KafkaProxyNetworkPolicy` is primarily a human-facing signal — "is every target for this proxy explicitly and validly declared?". It is not a gate on whether generation happens at all.


### Common structure of generated `NetworkPolicy` resources

Every `NetworkPolicy` the operator generates — a default (no rule declared for that target), or the result of a declared entry, whether user-specified or, for a `strimziKafkaRef`-based `KafkaService`, auto-derived — shares the same `podSelector`, the same `ownerReferences` rule, and is named using the same scheme. This section defines all three once; the sections below describe only what's specific to each target kind: the shape of the `from`/`to` peers and `ports` in the generated `ingress`/`egress` rule.

#### Naming

Each generated `NetworkPolicy`'s `metadata.name` is built from `${token}`, identifying the direction/role, `${name}` copied verbatim from the `metadata.name` of the `KafkaProxyIngress`/`KafkaService`/`KafkaProtocolFilter` that entry targets, and — for the two target kinds that aren't owned by exactly one `KafkaProxy` — `${proxyName}`, copied verbatim from the `metadata.name` of the `KafkaProxy` this generated policy is for:

| Token | Generated for | `metadata.name` |
| --- | --- | --- |
| `kafkaproxy-ingress` | A `KafkaProxy` entry's `allowIngress` (or default) | `kafkaproxy-ingress.${name}` |
| `kafkaproxy-egress` | A `KafkaProxy` entry's `allowEgress` (or default) | `kafkaproxy-egress.${name}` |
| `kafkaproxyingress-ingress` | A `KafkaProxyIngress` entry (or default) | `kafkaproxyingress-ingress.${name}` |
| `kafkaservice-egress` | A `KafkaService` entry (or default), including the `strimziKafkaRef` auto-derived rule | `kafkaservice-egress.${proxyName}.${name}` |
| `kafkaprotocolfilter-ingress` | A `KafkaProtocolFilter` entry's `allowIngress` (or default) | `kafkaprotocolfilter-ingress.${proxyName}.${name}` |
| `kafkaprotocolfilter-egress` | A `KafkaProtocolFilter` entry's `allowEgress` (or default) | `kafkaprotocolfilter-egress.${proxyName}.${name}` |

`${proxyName}` only appears for `KafkaService` and `KafkaProtocolFilter`. Unlike `KafkaProxy` itself and `KafkaProxyIngress` — whose `spec.proxyRef` ties it to exactly one proxy at a time — neither `KafkaService` nor `KafkaProtocolFilter` carries a `proxyRef` at all, and both are designed to be shared: the same `KafkaService` or `KafkaProtocolFilter` can be referenced, directly or via one or more `VirtualKafkaCluster`'s `targetKafkaServiceRef`/`filterRefs`, from more than one `KafkaProxy`'s resource graph at once. Each such proxy can independently and validly carry its own entry for that same `KafkaService`/`KafkaProtocolFilter` in its own `KafkaProxyNetworkPolicy` — the [Resolution](#resolution) check only asks whether a given ref resolves to *this* `KafkaProxyNetworkPolicy`'s own proxy, not whether it resolves to that proxy *exclusively*. Two such entries, for two different proxies, generate two different `NetworkPolicy` objects with two different `podSelector`s (one per proxy's `Pods`), so `${name}` alone is not enough to tell them apart; `${proxyName}` is needed both to avoid a `metadata.name` collision between them and, as a bonus, to make clear at a glance which proxy's `Pods` a given copy of a shared target's rule applies to.

This is collision-free by construction, without needing any constraint on `metadata.name` beyond what each of these CRDs already allows. For the three unqualified tokens, two generated names can only collide if both the token and `name` match — and since each of those tokens maps to exactly one source kind whose objects are each owned by at most one proxy, that can't happen for two distinct objects of the same kind in the same namespace. For the three `${proxyName}`-qualified tokens, the same argument applies to the `(proxyName, name)` pair instead of `name` alone: a collision would require both the owning proxy and the target's own name to match, which can't happen for two distinct `(KafkaProxy, KafkaService)` or `(KafkaProxy, KafkaProtocolFilter)` pairs. This holds regardless of what characters `name` or `proxyName` contain, including `.`.

Length is a separate concern from collision, and needs separate handling: `KafkaProxyIngress` and `KafkaService` impose no `maxLength` on `metadata.name` today, so either can be as long as the API server's generic 253-character default, whereas `KafkaProxy` is capped at 50 characters and `KafkaProtocolFilter` at 63 (matching the existing constraint discussed in [Rejected alternatives](#rejected-alternatives)). That means overflow is only possible for the `kafkaproxyingress-ingress` token (via an over-long `KafkaProxyIngress` name) and the `kafkaservice-egress` token (via an over-long `KafkaService` name) — `${proxyName}` itself, being at most 50 characters, never needs truncating. Tightening `KafkaProxyIngress`/`KafkaService`'s limit retroactively isn't available as an option — see [Rejected alternatives](#rejected-alternatives) — so whenever the computed name would exceed `NetworkPolicy`'s own 253-character limit, the operator instead generates `${token}.${name-prefix}-${hash}` (or, for `kafkaservice-egress`, `${token}.${proxyName}.${name-prefix}-${hash}`), where `hash` is 8 lowercase hex characters derived from a stable hash of the full, untruncated `name`, and `name-prefix` is `name` truncated to however many characters keep the total at exactly 253 — i.e. `name` is the only component ever truncated, since it's the only one without a fixed upper bound. This only ever applies once `name` is long enough to overflow the limit, already a pathological outlier, and makes a collision between two different overly-long names vanishingly unlikely rather than structurally impossible — the same trade-off as a `git` short hash.


#### Labels

Whether a given generated `NetworkPolicy` came from a declared entry or via the `spec.defaultIngress`, `spec.defaultEgress` or `KROXYLICIOUS_KPNP_ABSENT` fallbacks, is recorded as a label, not in the name. Every generated `NetworkPolicy` also carries a label naming the `KafkaProxy` it's for, regardless of which entry drove its generation:

```yaml
metadata:
  labels:
    kroxylicious.io/default-policy: allow-all # or: deny-all
    kroxylicious.io/proxy-name: my-proxy
```

This label is present whenever a `NetworkPolicy` was generated via the `spec.defaultIngress`, `spec.defaultEgress` or `KROXYLICIOUS_KPNP_ABSENT` fallback, or (see [Generation](#generation)), letting all such rules be selected independent of target kind, e.g. `kubectl get networkpolicy -l kroxylicious.io/default-policy=allow-all`. It's absent once an entry's own declared rules are in effect — including the `strimziKafkaRef` auto-derived rule, which is itself only generated once an entry exists — since that's not driven by `KROXYLICIOUS_KPNP_ABSENT`.

`kroxylicious.io/proxy-name` has no such conditions — it's always present, on every generated `NetworkPolicy`, for every proxy. The proxy's own identity is otherwise only visible via `spec.podSelector.matchLabels` (not `metadata.labels`) or by parsing it out of the generated name, neither of which `kubectl -l` can select on; this label makes "every `NetworkPolicy` for proxy X" a one-line query.


#### `podSelector`

The operator resolves `spec.kafkaProxy.proxyRef` to the `KafkaProxy`, and copies that `KafkaProxy`'s own `Pod`-selector labels, unchanged, into every generated `NetworkPolicy`:

```yaml
podSelector:
  matchLabels:
      app.kubernetes.io/name: kroxylicious
      app.kubernetes.io/component: proxy
      app.kubernetes.io/instance: my-proxy-cr
```

Because this `podSelector` is identical on every `NetworkPolicy` generated for a given `KafkaProxy` — regardless of which entry drove its generation — they all select the same `Pods`, and `NetworkPolicy` rules are additive across policies selecting the same `Pod` (see [Current situation](#current-situation)). This means a broad rule generated for *any one* target on a proxy is unioned with every other target's rules for the same direction. For example, a `KafkaProxy` with one `KafkaService` using `strimziKafkaRef` and a declared entry (getting the narrow, auto-derived rule) and a second `KafkaService` using `bootstrapServers` with no declared `allowEgress` (falling back to `KROXYLICIOUS_KPNP_ABSENT`) ends up, if that fallback is `allow-all`, with unrestricted egress on that port from the proxy's `Pods`: the first `KafkaService`'s narrow rule is still generated correctly and still has naming/audit value, but it adds no enforcement once a sibling target's rule already allows everything. Restricting a proxy's effective ingress or egress for a given direction therefore means addressing *every* target on that proxy, not just the one under review.

**Known limitation:** this isn't only a transient, defaulting-related risk — it holds for as long as *any* target on the proxy has an `allow-all` rule in a given direction, declared or defaulted, even once `KafkaProxyNetworkPolicy` is fully `Accepted: True` with every target explicitly covered. A reviewer who sees one `KafkaProtocolFilter` entry with a tight `allowEgress` to, say, just its KMS can't tell from that entry alone whether it does anything: that depends on every other target on the same proxy also lacking an `allow-all` rule for egress. `status.effectivelyUnrestrictedIngress`/`effectivelyUnrestrictedEgress` (see [Status conditions](#status-conditions)) surfaces this at the proxy level — `true` if any generated policy for the proxy has, in that direction, an empty/absent peer list or an `ipBlock` spanning the whole address space (`0.0.0.0/0`/`::/0`) — but a reviewer still has to consult that field rather than reading it off any single `NetworkPolicy`, and it can't say *which* target's rule is the one making others redundant. (It doesn't attempt to catch a full range reconstructed from multiple narrower `ipBlock`s — a deliberately obscure case not worth the detection cost.)

#### `ownerReferences`

A generated `NetworkPolicy` is owned by whatever resolved to produce its content:

* One generated from a declared, resolved entry — including the `strimziKafkaRef` auto-derived rule — is owned by the `KafkaProxyIngress`/`KafkaService`/`KafkaProtocolFilter` that entry targets. Since a `KafkaService` or `KafkaProtocolFilter` can be shared across more than one `KafkaProxy` (see [Naming](#naming)), it can end up owning more than one generated `NetworkPolicy` this way — one per proxy whose `KafkaProxyNetworkPolicy` carries an entry for it. Deleting that `KafkaService`/`KafkaProtocolFilter` garbage-collects all of them together, which is the correct outcome: none of those proxies has access via it any more.
* One generated for `spec.kafkaProxy`, and one generated via the `KROXYLICIOUS_KPNP_ABSENT` fallback for a target with no entry, is owned by the `KafkaProxy` itself — there's no more specific CR to attribute either of these to.

This makes cleanup automatic rather than something the reconciler has to implement: deleting a `KafkaProxyIngress`/`KafkaService`/`KafkaProtocolFilter` that has a declared entry garbage-collects its `NetworkPolicy` along with it. Deleting the `KafkaProxy` cleans up everything regardless of ownership.

Deleting a `KafkaProxyNetworkPolicy`, or removing one of its entries while the entry's target CR still exists, changes that target's effective source of truth from a declared entry back to the `KROXYLICIOUS_KPNP_ABSENT` fallback. The reconciler's usual create-or-update logic handles this the same way it handles any other spec change, including re-pointing `ownerReferences` from the target CR to the `KafkaProxy`.

### Policy for `KafkaProxy`

The proxy itself usually generates ingress and egress traffic that the operator must account for:

* **Egress** to DNS (to resolve hostnames used in `KafkaService.spec.bootstrapServers`, and elsewhere).
* **Ingress** to allow metric scraping by a Prometheus instance (or similar metrics collector). This requires knowing where the metrics instance lives which the operator cannot infer on its own.

Should a `KafkaProxy` lack a `KafkaProxyNetworkPolicy` entirely, the fallback controlled by `KROXYLICIOUS_KPNP_ABSENT` applies independently to ingress and egress directions. 
Here's the `allow-all` case for egress:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafkaproxy-egress.my-proxy
spec:
  podSelector: ... # see Common structure above
  policyTypes:
    - Egress
  egress:
    - to: []  # allow to anywhere
```

And the `deny-all` case:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafkaproxy-egress.my-proxy
spec:
  podSelector: ... # see Common structure above
  policyTypes:
    - Egress
  egress: []  # deny all egress
```

When a `KafkaProxyNetworkPolicy` exists which targets the `KafkaProxy` via `spec.kafkaProxy`, the same `NetworkPolicy` are built using the given rules. 
An example `KafkaProxyNetworkPolicy` entry:

```yaml
---
# Example proxy with ingress from Prometheus and egress to DNS
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxyNetworkPolicy
metadata:
  name: my-proxy-network-policy
spec:
  kafkaProxy:                      # required
    proxyRef:                      # required
      name: my-proxy               # required
    allowEgressToClusterDns: true  # required
    allowIngressForMetrics:        # required, but may be []  
      - from:
          - namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: prometheus
```

The core proxy itself only requires egress for DNS — any other egress is more accurately associated with a `KafkaService` or `KafkaProtocolFilter`. 
We use `allowEgressToClusterDns` as a shorthand, rather than having `NetworkPolicy`-style arrays of egress rules (which would always need the same rule for talking to the cluster DNS server). 
`spec.kafkaProxy.allowIngressForMetrics` lacks a `ports` property: the proxy's metrics listening port is already known to the operator.

Cluster DNS topology — which namespace and which `Pod` labels identify the DNS server — isn't part of the stable, cross-distribution Kubernetes API, so `allowEgressToClusterDns: true` can't resolve to one fixed selector. Instead the operator picks between a small number of known topologies based on the platform it's running on, reusing the same API-discovery-based detection it already needs for `openShiftRoute` ingress support (`IsOpenshiftRouteSupportedActivationCondition`, which checks `client.supports(Route.class)`): on a vanilla/kubeadm/GKE/EKS/AKS-style cluster it generates the `kube-system`/`k8s-app: kube-dns` rule shown below, unconditionally paired with a second peer matching `k8s-app: node-local-dns` in the same namespace — the conventional label for upstream NodeLocal DNSCache — since matching a label that happens not to be present costs nothing; on OpenShift it instead targets the `openshift-dns` namespace and `Pods` labelled `dns.operator.openshift.io/daemonset-dns: default` (OpenShift's DNS Operator-managed CoreDNS `DaemonSet`).

**Known limitation:** this still isn't exhaustive, and the gap is no longer a rare one. AKS's own LocalDNS proxy (a distinct implementation from upstream NodeLocal DNSCache, under a label this proposal doesn't account for), a CoreDNS deployment relocated out of `kube-system`, or any other custom DNS layout fall outside both detected topologies — and some of these are now the *default*, not the exception: GKE Autopilot always runs NodeLocal DNSCache, and EKS Auto Mode and recent AKS node pools enable their own equivalents automatically. On such a cluster, `allowEgressToClusterDns: true` silently generates a rule that doesn't match the `Pods` DNS traffic actually reaches, while still reporting `Programmed: True`. The only remedies today are a `KafkaProtocolFilter`-style explicit `allowEgress` entry targeting the real DNS `Pods` directly (every generated `NetworkPolicy` for a proxy shares the same `podSelector`, so such an entry's rule takes effect regardless of which CR nominally owns it — see [`podSelector`](#podselector)), or falling back to a broader `defaultEgress`/`KROXYLICIOUS_KPNP_ABSENT` setting. We accept this as a known gap rather than attempt to enumerate every DNS topology in existence up front; see [Future work](#future-work) for a possible way to close it later.

Generated `NetworkPolicies` for the above example on a vanilla/kubeadm-style cluster:

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafkaproxy-ingress.my-proxy
spec:
  podSelector: ...
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: prometheus
      ports:
        - protocol: TCP
          port: 9190
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafkaproxy-egress.my-proxy
spec:
  podSelector: ...
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: node-local-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

The same `kafkaproxy-egress.my-proxy` policy on OpenShift instead reads:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafkaproxy-egress.my-proxy
spec:
  podSelector: ...
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: openshift-dns
          podSelector:
            matchLabels:
              dns.operator.openshift.io/daemonset-dns: default
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

### Policy for `KafkaProxyIngress`

When no `KafkaProxyNetworkPolicy` for the `KafkaProxyIngress`'s proxy exists the fallback is controlled by `KROXYLICIOUS_KPNP_ABSENT`.
When a `KafkaProxyNetworkPolicy` exists for the `KafkaProxyIngress`'s proxy the fallback is controlled by the `spec.defaultIngress`.
Here's the `allow-all` case:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafkaproxyingress-ingress.my-loadbalancer-ingress
  labels:
    kroxylicious.io/default-policy: allow-all
spec:
  podSelector: ...
  policyTypes:
    - Ingress
  ingress:
    - ports:
      - protocol: TCP
        port: <PORT_NUM> # for each port
```

When an entry targets a given `KafkaProxyIngress` the behaviour of the operator depends on the ingress mechanism.
The `KafkaProxyIngress` CR supports three ingress mechanisms:

* `clusterIP` for access from Kafka clients running in the same Kubernetes cluster
* `loadBalancer` for access from Kafka clients running outside the Kubernetes cluster
* `openShiftRoute` for access from Kafka clients running outside the OpenShift cluster

In all cases the user does not specify any `ports` in the `KafkaProxyNetworkPolicy`, because the ports are already known to the operator.

For `loadBalancer` and `openShiftRoute`, `allowIngressFrom` only accepts `ipBlock` peers: external clients carry no Kubernetes namespace/Pod identity for a `namespaceSelector`/`podSelector` to match against. `ipBlock.except` is rejected for both, too — neither `Service.spec.loadBalancerSourceRanges` nor the OpenShift `Route`'s `ip_whitelist` annotation (see [the `openShiftRoute` case](#the-openshiftroute-case)) has a way to express a subtracted sub-range, so there'd be no correct way to carry one through to the generated `Service`/`Route`.

#### The `clusterIP` case

The `clusterIP` mechanism is specifically intended for access from the same Kubernetes cluster.

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
# Example network policy restricting access to the given namespaces and pods
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxyNetworkPolicy
metadata:
  name: my-proxy-network-policy
spec:
  kafkaProxy:                      # required
    proxyRef:                      # required
      name: my-proxy-cr            # required
    ...
  kafkaProxyIngresses:             # required, may be []
    - ingressRef:                  # required
        name: my-ingress           # required
      allowIngressFrom:            # required
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
  name: kafkaproxyingress-ingress.my-ingress
  namespace: my-proxy-ns
spec:
  podSelector: ...
  policyTypes:
    - Ingress
  ingress:
    - ports: # the ingress's own listening port — see Ports
        - protocol: TCP
          port: <PORT_NUM>
      from: # copied verbatim from allowIngressFrom
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

This works the same way. `loadBalancer` is explicitly intended for off-cluster access.

For `loadBalancerSourceRanges` and the pod-level `NetworkPolicy` below to restrict access correctly, the generated `Service` also needs `externalTrafficPolicy: Local`, to preserve the client's source IP address rather than losing it to SNAT.
`KafkaProxyIngress` already supports this via `spec.loadBalancer.service.externalTrafficPolicy` (added by [proposal #134](https://github.com/kroxylicious/design/pull/134)).
Even with that in place, `loadBalancerSourceRanges` enforcement is only as good as the cloud provider's load-balancer controller — see [Current situation](#current-situation).

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: my-loadbalancer-ingress # named after the KafkaProxyIngress — one Service per ingress, per proposal #134
spec:
  type: LoadBalancer
  loadBalancerSourceRanges:
    - 203.0.113.0/24
  externalTrafficPolicy: Local # from the KafkaProxyIngress's own spec.loadBalancer.service.externalTrafficPolicy (proposal #134)
  # ...
```

With `externalTrafficPolicy: Local` in place the client's source IP address will be preserved and we can use a NetworkPolicy to allow access:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafkaproxyingress-ingress.my-loadbalancer-ingress
  namespace: my-proxy-ns
spec:
  podSelector: ... 
  policyTypes:
    - Ingress
  ingress: # The rules will be copied verbatim
    - from:
        - ipBlock:
            cidr: 203.0.113.0/24
      ports: # for each port
        - protocol: TCP
          port: <PORT_NUM>
```

The operator will create a `Accepted: False` condition if `externalTrafficPolicy` is not `Local`.

Proposal #134 gives each `loadBalancer`-type `KafkaProxyIngress` its own dedicated `Service`, so an entry's CIDRs apply directly to that ingress's own `Service.spec.loadBalancerSourceRanges` and pod-level `NetworkPolicy`, with no cross-ingress CIDR union to construct.

Sharing hasn't disappeared entirely, though: multiple `VirtualKafkaClusters` can still reference the same ingress, addressed by SNI on that ingress's one `Service` — this is what delivers the per-load-balancer cost saving proposal #134 preserves.
An entry targeting that ingress applies uniformly to all of them: a pod-level `NetworkPolicy` can't differentiate traffic by the SNI hostname it arrived on, so there's no way to give one `VirtualKafkaCluster` a narrower CIDR allowlist than another if they share an ingress.
(See [Future work](#future-work) for a possible enhancement that would recover that per-virtual-cluster isolation.)

#### The `openShiftRoute` case

Like `loadBalancer`, `openShiftRoute` is explicitly intended for off-cluster access.

To restrict access by client CIDR with an OpenShift `Route`, we must restrict traffic at the `Route` layer using an annotation, and pair it with a `NetworkPolicy` to restrict `Pod` ingress to only the OpenShift Ingress `Router`.

```yaml
---
# Example network policy restricting access to the given CIDRs
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxyNetworkPolicy
metadata:
  name: my-proxy-network-policy
spec:
  kafkaProxy:                      # required
    proxyRef:                      # required
      name: my-proxy-cr            # required
    ...
  kafkaProxyIngresses:             # required, may be []
    - ingressRef:                  # required
        name: my-route-ingress     # required
      allowIngressFrom:            # required
        - ipBlock:
            cidr: 203.0.113.0/24
        - ipBlock:
            cidr: 198.51.100.10/32
```

This produces both the `Route`'s `ip_whitelist` annotation and the accompanying `NetworkPolicy`:

```yaml
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: my-proxy-cr-my-ingress
  namespace: my-proxy-ns
  annotations:
    # Space-separated list of allowed CIDRs or IP addresses, taken from allowIngressFrom
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
  name: kafkaproxyingress-ingress.my-route-ingress
  namespace: my-proxy-ns
spec:
  podSelector: ... 
  policyTypes:
    - Ingress
  ingress: # The rules target the pod running the Router network proxy, not the declared allowIngressFrom peers.
    - from:
        - namespaceSelector:
            matchLabels:
              network.openshift.io/policy-group: ingress
      ports:
        - protocol: TCP
          port: 9092
```

The declared `ipBlock` CIDRs only ever reach the `Route`'s `ip_whitelist` annotation — the `NetworkPolicy`'s `from` is always the Router's own namespace, regardless of what's declared. Every client's traffic arrives at the proxy's `Pod` by way of the Router, so the `Pod`-level `NetworkPolicy` never sees the original client CIDR and can't restrict by it; that restriction is enforced entirely at the `Route`/HAProxy layer instead. This means reviewing the generated `NetworkPolicy` alone is not enough to know who can reach an `openShiftRoute` ingress — the `Route`'s own annotation has to be read too.

**Known limitation:** this is a real exception to this proposal's own goal of letting a generated `NetworkPolicy` be audited on its own terms (see [Goals](#goals)) — for every other ingress mechanism, the `NetworkPolicy`'s `from` *is* the actual restriction; for `openShiftRoute` it structurally cannot be, and nothing on either object points a reader from one to the other. A user who opens `kafkaproxyingress-ingress.my-route-ingress` first, without already knowing this mechanism's limitation, will see only "from the Router's namespace" and have no indication that a separate, unrelated-looking `Route` annotation is where the real client restriction lives. We accept this as an inherent consequence of how OpenShift `Route`s work rather than something this proposal can fix: there's no cross-reference between the two objects, so finding the `Route` requires already knowing to look for it (e.g. via this document, or the `KafkaProxyIngress`'s own generated `Route`, which is named after the ingress in the same way).

Users already have a way of setting annotations on the `Route`, via `spec.infrastructure.annotations` on the `KafkaProxyIngress`. The operator will ensure that the IP address ranges given explicitly via a `haproxy.router.openshift.io/ip_whitelist` annotations in `spec.infrastructure.annotations` are the same as those given in the `KafkaProxyNetworkPolicy`, and create an `Accepted: False` condition when this is not the case. Resolving the ambiguity will be left to the user.

### Policy for `KafkaService`

When no `KafkaProxyNetworkPolicy` for the `KafkaService`'s proxy exists the fallback is controlled by `KROXYLICIOUS_KPNP_ABSENT`.
When a `KafkaProxyNetworkPolicy` exists for the `KafkaService`'s proxy, but has no entry for this service, the fallback is controlled by `spec.defaultEgress`.
Here's the `allow-all` case:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafkaservice-egress.my-proxy-cr.my-target-cluster
  labels:
    kroxylicious.io/default-policy: allow-all
spec:
  podSelector: ... 
  policyTypes:
    - Egress
  egress:
  - ports:
    - protocol: TCP
```

The `KafkaService` CR supports two ways to express a target cluster:

* `strimziKafkaRef` is a reference to a Strimzi `Kafka` resource which exists in the same cluster as the `KafkaService` CR.
* `bootstrapServers` is a comma-separated list of the host addresses for some bootstrap servers of a Kafka cluster.

#### The `strimziKafkaRef` case

`strimziKafkaRef` is a very special case: we already know the namespace of the `Kafka` cluster, and the `Pod` labels, and hence selectors, are a published part of the Strimzi API, so the operator can always compute the exact egress rule itself once a `KafkaProxyNetworkPolicy` entry exists for it. No `allowEgress` is needed, or accepted, for this case.

As with `bootstrapServers` above, a `strimziKafkaRef`-based `KafkaService` with no entry gets the same fallback described above. Once a bare `- serviceRef: {name: ...}` entry exists, the operator instead generates the precise rule itself, since a correct answer is already available for free and there's no reason to ask the user to supply `to`/`ports` manually. This entry is also what the [exhaustiveness](#resolution) check requires for `Accepted: True`.

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
kind: KafkaProxyNetworkPolicy
metadata:
  name: my-proxy-network-policy
spec:
  kafkaProxy:                 # required
    proxyRef:                 # required
      name: my-proxy-cr       # required
    ...
  kafkaServices:              # required, may be []
    - serviceRef:             # required
        name: strimzi-target  # required
```

A bare entry like this, with no `allowEgress`, is enough to generate a `NetworkPolicy`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafkaservice-egress.my-proxy-cr.strimzi-target
spec:
  podSelector: ... 
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
There are a number of sub-cases:

* the given servers are internal IPv4 or IPv6 addresses
* the given servers are internal DNS names (e.g. `my-kafka-cluster-kafka-bootstrap.my-ns.svc.cluster.local`, a Strimzi bootstrap `Service` DNS name)
* the given servers are external IPv4 or IPv6 addresses
* the given servers are external DNS names (e.g. `node12.kafka.example.com:9092`)

but the operator will not attempt to distinguish between them, and instead just propagate the rules given in the `KafkaProxyNetworkPolicy` to the `NetworkPolicy`. Unlike `strimziKafkaRef`, there's no `ports`/`to` the operator can compute on the user's behalf here — both are always required, for every entry. (Note: `to: []` means *unrestricted*, not denied, like with `NetworkPolicy`.)

```yaml
---
# Example external, non-Strimzi Kafka cluster
kind: KafkaService
metadata:
  namespace: my-proxy-ns
  name: my-external-kafka-cluster
spec:
  bootstrapServers: "node12.kafka.example.com:9092,node13.kafka.example.com:9092"
---
kind: KafkaProxyNetworkPolicy
metadata:
  name: my-proxy-network-policy
spec:
  kafkaProxy:                          # required
    proxyRef:                          # required
      name: my-proxy-cr                # required
    ...
  kafkaServices:                       # required, may be []
    - serviceRef:                      # required
        name: my-external-kafka-cluster # required
      allowEgress:                     # required, may be []
        - ports:
            - protocol: TCP
              port: 9092
          to:
            - ipBlock:
                cidr: 203.0.113.10/32
            - ipBlock:
                cidr: 203.0.113.11/32
```

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafkaservice-egress.my-proxy-cr.my-external-kafka-cluster
  namespace: my-proxy-ns
spec:
  podSelector: ...
  policyTypes:
    - Egress
  egress:
    - ports:
        - protocol: TCP
          port: 9092
      to:
        - ipBlock:
            cidr: 203.0.113.10/32
        - ipBlock:
            cidr: 203.0.113.11/32
```

**Known limitation:** for a non-Strimzi, off-cluster target — the common case for a managed Kafka service such as Amazon MSK or Confluent Cloud — `to` can only be expressed as `ipBlock` (see [Current situation](#current-situation)), and the operator doesn't resolve or track the DNS names in `bootstrapServers` on the user's behalf (see the rejected "let the operator resolve DNS names" alternative). The user is left to discover and maintain the correct CIDRs by hand, and to update them whenever the provider's broker IPs change — which, for some managed offerings, can be often enough to make a precise `ipBlock` rule impractical to keep current. In that situation the realistic choices are accepting the maintenance burden, widening the `ipBlock` to a provider-published range if one exists and is stable enough, or falling back to this entry having no `allowEgress` restriction worth the name (effectively `0.0.0.0/0`) and relying on other layers (TLS, authentication) for protection.


### Policy for `KafkaProtocolFilter`

The `KafkaProtocolFilter` CR is used to configure filters.
It is common for filters, or their plugins, to require network egress.
It's also not forbidden for filters to require network ingress.
In the most general case, a filter or its plugin would require rules for both; a single entry can set both `allowIngress` and `allowEgress`, generating two `NetworkPolicy` resources — one per direction.

When no `KafkaProxyNetworkPolicy` for the `KafkaProtocolFilter`'s proxy exists the fallback is controlled by `KROXYLICIOUS_KPNP_ABSENT`, per direction.
When a `KafkaProxyNetworkPolicy` exists for the `KafkaProtocolFilter`'s proxy, but has no entry for this filter, the fallback is controlled by `spec.defaultIngress`/`spec.defaultEgress`, per direction.
Unlike `KafkaProxyIngress`/`KafkaService`, which always need *some* access just to function, a `KafkaProtocolFilter` may need none at all — but the same `allow-all`/`deny-all` choice and reasoning applies regardless.
The user will need to define `allowIngress: []` (or `allowEgress: []`) in order to produce a NetworkPolicy that disallows ingress (or egress).

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
# network policy attached to the proxy, including a rule for this filter's egress
kind: KafkaProxyNetworkPolicy
metadata:
  name: my-proxy-network-policy
spec:
  kafkaProxy:                 # required
    proxyRef:                 # required
      name: my-proxy-cr       # required
  ...
  kafkaProtocolFilters:       # required, may be []
    - filterRef:              # required
        name: encryption      # required
      allowIngress: []        # required, may be []
      allowEgress:            # required, may be []
        - ports:
            - protocol: TCP
              port: 8200
          to:
            - namespaceSelector:
                matchLabels:
                  kubernetes.io/metadata.name: vault
```

And the resulting egress `NetworkPolicy`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafkaprotocolfilter-egress.my-proxy-cr.encryption
spec:
  podSelector: ... 
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

A filter needing egress to more than one kind of destination for different reasons (e.g. a `SaslTermination` filter using OAUTHBEARER tokens plus a `SaslSubjectBuilder` plugin doing LDAP lookups) expresses that as multiple entries in its `allowEgress` list: the one generated `kafkaprotocolfilter-egress.${proxyName}.${name}` `NetworkPolicy`, will have multiple rules.

### Operator RBAC changes

The operator will need to be allowed to CRUD `NetworkPolicy` resources via its dependent resources `ClusterRole`.
This means the operator has the ability to widen NP on every Pod in every namespace in the cluster, even though it's only ever needed for proxy Pods.
That's unavoidable with Kubernetes's RBAC authorization model: RBAC grants by resource type, not by object identity, so there's no way to restrict the grant to just the `NetworkPolicy` objects the operator itself created.

In the "watched resources" `ClusterRole` the operator will need:
* `watch`, `get`, `list`, `patch`, `update` (+ `/status`) on `KafkaProxyNetworkPolicy`.

### Future work

As a possible future development, we could add an IP-allowlist capability enforced in the proxy itself, and have the operator feed that with the `ipBlock` rules from the `KafkaProxyNetworkPolicy`.
Crucially this could be done once the SNI host name is known, thus recovering the per-virtual-cluster isolation that `Service`-level CIDR restriction cannot provide when multiple `VirtualKafkaClusters` share one ingress's `Service` (see [the `loadBalancer` case](#the-loadbalancer-case)).

Separately, the cluster-DNS-topology detection used by `allowEgressToClusterDns` (see [Policy for `KafkaProxy`](#policy-for-kafkaproxy)) could be made overridable by whoever installs the operator, for topologies it can't detect on its own. We've deliberately left this out of scope for now rather than guess at the right mechanism (an env var, a small cluster-scoped CRD, or something else) ahead of real-world demand.

## Affected/not affected projects

This affects the `kroxylicious/kroxylicious` repo.

## Compatibility

`KROXYLICIOUS_KPNP_ABSENT` defaults to `allow-all`. Upgrading the operator therefore starts generating `NetworkPolicy` resources for every target with no declared `KafkaProxyNetworkPolicy` entry, rather than leaving generation off until the administrator opts in.

This is a deliberate exception to the project's usual backwards-compatibility requirement. Defaulting to `allow-all` unconditionally accepts two risks on upgrade:

1. **Silent widening for users with their own hand-written `NetworkPolicy`.** An administrator who already locked down a proxy's `Pods` with their own `NetworkPolicy` gets, after upgrading, an additional `allow-all` `NetworkPolicy` generated for any target not covered by a `KafkaProxyNetworkPolicy` — and because `NetworkPolicy` rules are additive across policies selecting the same `Pod` (see [Current situation](#current-situation)), that silently widens effective access for that target regardless of how tight their own rule was. We mitigate this via the release notes for the version introducing `NetworkPolicy` generation, which call out the behaviour change explicitly and direct affected users to set `KROXYLICIOUS_KPNP_ABSENT` to `no-np` or `deny-all` before upgrading — or to add a `KafkaProxyNetworkPolicy` covering every target up front — rather than relying on the new default.
2. **Name collision with a pre-existing, unrelated `NetworkPolicy`.** A user's own `NetworkPolicy` could happen to share a `metadata.name` with one the operator generates, in which case it gets silently adopted and overwritten. This risk exists independently of the default chosen here, but defaulting to generation more often widens the opportunity for it to bite. Given the naming scheme's distinctive `kroxylicious.io`-specific token prefixes (see [Naming](#naming)), we consider this exceedingly unlikely.

Targets with no declared `KafkaProxyNetworkPolicy` entry get a default policy based on `KROXYLICIOUS_KPNP_ABSENT`, with descriptive names and `kroxylicious.io/default-policy` labels, so administrators can audit and tighten rules on their own schedule.
The "stale but safe" generation semantics (see [`ownerReferences`](#ownerreferences)) ensure that once a target has a working, explicitly declared rule, a later mistake elsewhere in the `KafkaProxyNetworkPolicy` cannot retract it.

## Rejected alternatives

* "Distinguish cluster-local DNS names from external names and constrain the peer types (`ipBlock` vs. `namespaceSelector`/`podSelector`) based on that distinction."
    - The operator would need to either maintain a list of internal DNS suffixes and CIDRs, or perform DNS lookups to tell the two apart. Maintaining lists is error-prone and couples the operator to cluster configuration; DNS lookup is unreliable across different operator instances and can return different results at different times. The effort to correctly distinguish internal from external was disproportionate to the value gained, so we decided to let users choose the appropriate peer type themselves based on their configuration.

* "Attach fine-grained policy CRs per target via a generic `targetRef`, following the Gateway API's policy attachment convention (an earlier revision of this proposal)."
    - The earlier design used a `KafkaProxyNetworkPolicy` with a `spec.targetRef` restricted to `KafkaProxyIngress`, `KafkaService`, or `KafkaProtocolFilter`, any number of which could attach to the same target, plus a `KafkaProxyOperatorConfig.spec.policyAttachment` matrix of per-kind, per-direction `requiredAttachments`/`permittedAttachments`/`whenAbsent` settings, plus a 9-token `${token}.${name}` naming scheme to distinguish `-default` from `-policy` outcomes per kind and direction.
    - Its chief argument was RBAC separation finer than kind-level: a role trusted to declare one filter's own egress could, in principle, be scoped away from also declaring the shared `KafkaProxyIngress`'s rules, since each was a separately named object. In practice this only worked via a manually-maintained `resourceNames` RBAC allowlist per object — the same design's own reasoning (see the now-superseded "split ingress/egress into two kinds" and "one kind per target CR" alternatives it carried) already concluded that *any* separation finer than whole-kind needs an external policy engine (Kyverno, OPA Gatekeeper, a `ValidatingAdmissionPolicy`) to be workable at scale. That conclusion applies with equal force to the finer separation this design gave up: an org that needs it can still get it from a policy engine layered on top of a single per-proxy `KafkaProxyNetworkPolicy`, inspecting which part of its spec a given identity is allowed to change.
    - Against that partial, policy-engine-dependent RBAC benefit, the earlier design carried substantial, ongoing engineering cost: the attachment matrix, dual CEL-plus-reconciler validation split by `targetRef.kind`, transitive `ResolvedRefs` bookkeeping spread across many small objects, and a naming scheme large enough to need an explicit collision-freedom proof. A single `KafkaProxyNetworkPolicy` per `KafkaProxy` gets equivalent functional behaviour — including, via the exhaustiveness check, a cleaner replacement for `requiredAttachments` — for substantially less of that cost, and as a bonus gives a single place to review a proxy's complete declared network policy instead of needing to enumerate objects across the namespace.
    - One capability is knowingly given up outright, not just made policy-engine-dependent: cheaply scoping a tenant's write access to *just their own* filter's rule via a plain RBAC `resourceNames` allowlist, since there's no longer a separate named object per filter to list. This is accepted as a niche requirement — `NetworkPolicy` itself is granted per-`Pod`, not per-rule, so a single shared RBAC boundary around "who can shape this proxy's network policy" is already consistent with the granularity the underlying Kubernetes primitive offers.
* "Use the static type information in the proxy configuration to infer the ingress and egress needs of plugins, so the user does not have to declare them".
    - Initially we thought this was going to be a good idea. However the operator does not have the plugins on its class path, so it cannot directly interrogate a proxy configuration to figure this out.
      The operator would need to do this indirectly in a container using the proxy image. That could be done in a pre-flight `Job` orchestrated by the operator, which communicated back
      the network requirements of plugins. However, it still relies on some contractually weak conventions (like "always use a `java.net.URI` for plugins which need egress"), so might not work
      with all plugins. Furthermore this whole technique is incompatible with services using "endpoint discovery" protocols, like Kafka's own.
      This means we might end up needing a way for the end user to override the rules inferred using an approach like this.
      It would be much simpler to just allow the end user to use this mechanism from the beginning.
* "Let the operator resolve DNS names, generating NetworkPolicies with the resolved IP addresses."
    - While this could work in simple cases it would not work well enough in practice. Some of the problems include:
        - We cannot guarantee that the resolution done in the operator would have the same results as the resolution in the proxy instances.
        - It's not uncommon for SaaS services to use very low, or even a 0 TTL, meaning it would be impossible to know how long the results of the resolution would be valid for.
        - Low or 0 TTLs could also involve significant update cost for the `NetworkPolicies`.
        - It's inherently racy.
        - The sets of resolved IP addresses could be large, the effects of which would flow directly to iptables-based CNIs (e.g. kube-proxy).
* "Generate a single monolithic `NetworkPolicy` per proxy, rather than one per target."
    - This would put less load on the Kubernetes API server.
    - However, such a policy is not easy to audit, because the reason why any particular rule allows access cannot be easily traced back to where and why that access is needed. We still generate one `NetworkPolicy` per declared (or defaulted) target even though the declarations themselves now live in a single input CR — see [Naming](#naming).
* "Use the same property name (`networkPolicyPeers`) as Strimzi"
    - `networkPolicyPeers` does not distinguish between the ingress and egress cases. We have CRs which support one, but not the other, and other CRs which support both at the same time. Being able to distinguish between the two cases seems like a useful way to ensure unambiguous communication of the user's intent.
* "Put the rules in the existing CRs, rather than forcing the users to create a new, separate CR"
    - This is not sympathetic to the existing CR API design. We chose to have different `kinds` for separate concerns like `KafkaProtocolFilter` and `KafkaProxyIngress` precisely because different organizations have different ways of segregating responsibility in their org structure. Using a different kind for network policy allows an org that wants to separate "who can run the proxy" from "who can shape its network policy" to do so via Kubernetes RBAC. Using a separate CR API for what amount to firewall rules seems like a better choice.
    - This is also strictly worse, not just equivalent, under the single-CR-per-proxy shape in this proposal: putting egress rules directly on each `KafkaProtocolFilter` would at least let a filter's own owner manage its own rules inline; consolidating them in a CR shared across every filter on the proxy does not.
* "Use `KafkaProxyOperatorConfig` CRD instead of environment variables"
    - `KafkaProxyOperatorConfig` was initially proposed to consolidate operator configuration, including `clusterDomain`, `clusterCIDRs`, and `networkPolicyGeneration`. However, with the decision to drop validation/enforcement around internal vs. external DNS names, the need for `clusterDomain` and `clusterCIDRs` was eliminated. The reduced scope meant that `KafkaProxyOperatorConfig` only contained `networkPolicyGeneration`, which is straightforward to control via a single environment variable `KROXYLICIOUS_KPNP_ABSENT`. Using an env var is simpler than introducing a cluster-scoped CRD for this single aspect of operator behaviour.
* "Default `KROXYLICIOUS_KPNP_ABSENT` to `deny-all` for fresh installs."
    - A secure-by-default `deny-all` sounds like the right call, but it raises the bar to getting a working proxy: a fresh `KafkaProxy` would pass no traffic at all until the right `KafkaProxyNetworkPolicy` exists. We decided the better trade-off is `allow-all` everywhere, with the generated policies' descriptive naming and `kroxylicious.io/default-policy` label giving administrators the audit trail to find and tighten `allow` rules on their own schedule.
* "Default `KROXYLICIOUS_KPNP_ABSENT` to `allow-all` on fresh installs but `no-np` on existing installs, so upgrading could never widen access a user may already have restricted with a hand-written `NetworkPolicy` (an earlier revision of this proposal)."
    - This is the more conservative option, and was the original design — see [Compatibility](#compatibility). We dropped the fresh/existing distinction during review as too fiddly: it requires the operator to reliably tell the two apart, and it leaves administrators reasoning about two different defaults depending on install history rather than one. We decided a single, unconditional `allow-all` default was worth it for the simplicity, accepting as a deliberate, mitigated exception to our usual backwards-compatibility bar the small risk of widening an existing hand-written `NetworkPolicy` on upgrade — see [Compatibility](#compatibility) for the risks this accepts and how they're mitigated.
* "Add CRD-level validation to `KafkaProxyIngress` and `KafkaService` capping `metadata.name` at 63 characters, matching `KafkaProtocolFilter`'s existing constraint, instead of a hash suffix for over-length names."
    - This would give an exact length guarantee rather than the hash suffix's vanishingly-small-but-nonzero collision risk (see [Naming](#naming)).
    - It isn't available as a backwards-compatible option, though. `metadata.name` is immutable, and CRD schema validation applies to the whole object on every write, not just to the fields being changed. Tightening either CRD's name constraint would permanently block any future update to an existing object whose name already exceeds it, with no way to bring that object into compliance short of deleting and recreating it under a new name. A hash suffix, applied only at `NetworkPolicy`-generation time rather than as a CRD-level constraint, avoids this entirely.
