# 138 - Kubernetes `NetworkPolicies`

Add support for operator-generated [`NetworkPolicy`](https://kubernetes.io/docs/concepts/services-networking/network-policies/) to limit network ingress to, and egress from, proxy instances running on Kubernetes.

## Current situation

Originally Kubernetes supported only `NetworkPolicy` (NP), which got used by both Kubernetes admins and application developers/tenants.
Due to the friction this caused, since about 2022 Kubernetes has supported a tiered model:
* The Kubernetes admin-owned `AdminNetworkPolicy` (ANP) is evaluated before NPs, and provides non-negotiable rules (e.g., "Nobody can talk to the kube-system namespace").
* The Kubernetes admin-owned `BaselineAdminNetworkPolicy` (BANP) is evaluated after NPs, and provides a set of fallback rules (e.g., "If the developer didn't specify a rule, deny the traffic").
* This means NP are now unambiguously intended to be owned by developers/tenants to express their needs.

Users of the Kroxylicious operator are assumed to fall into the "developers/tenants" bucket, rather than also being Kubernetes admins.
Currently the Kroxylicious operator for Kubernetes does not generate `NetworkPolicy` resources at all.
So those users have needed to write NP for the proxy in order to work within Kubernetes's tiered model.

It's worth calling out some important aspects of the `NetworkPolicy` API in Kubernetes:
* Enforcement of `NetworkPolicy` depends on the cluster's CNI plugin supporting it (e.g. Calico, Cilium); some CNIs accept `NetworkPolicy` resources without enforcing them.
  A generated policy still has declarative/audit value on such a cluster, but it gives no actual network isolation unless the CNI enforces it.
* Each rule in a policy can only widen access, never narrow access. In other words, policies are "additive". This holds both within a single `NetworkPolicy` and across multiple `NetworkPolicy` resources selecting the same `Pod`: Kubernetes unions all their rules rather than letting one override another.
* `NetworkPolicy` has no direct support for expressing rules using external DNS names (e.g. there is no way to say "allow connections to `kms.example.com`").
  Where external DNS names are used for egress, it's necessary to have an "allow egress to anywhere" `NetworkPolicy` rule.
  Some CNIs support custom APIs which support these rules, but they're out of scope for this proposal.
* Same-kubernetes-cluster rules can be expressed in terms of namespace and pod selectors (e.g. you can say "allow connections to pods matching _this_ selector in namespaces matching _that_ selector"). Moreover, it is considered bad practice to use an `ipBlock` to allow access to/from a pod in the same cluster.

## Motivation

Enterprises are increasingly security-conscious: Kubernetes vendors and admins are adopting default-deny and microsegmentation approaches that make a `NetworkPolicy` a requirement, and even clusters without a default-deny posture are usually better off with one than without.
Tools like the [CIS Kubernetes Benchmark](https://www.armosec.io/glossary/cis-kubernetes-benchmark/) also use `NetworkPolicies` as a declarative input when auditing Kubernetes workloads: a specific policy statement conveys a design requirement, whereas the absence of one could be interpreted as an oversight — and some scanners flag that absence directly.

While it's easy to say "the user should write the NP themselves," that's difficult to do _well_ given how Kafka, the proxy, and the operator interact:

* The Kafka protocol uses the `Metadata` API to discover brokers, so the host addresses in a `KafkaService`'s `bootstrapServers` are only a subset of (or, when behind a load balancer, unrelated to) what a client — here, the proxy — ends up needing to connect to once the broker topology is discovered. For a proxy targeting a Strimzi-managed cluster on the same Kubernetes cluster, the operator can work this out for the user.
* The proxy itself is pluggable, and plugins can bring their own network access requirements — but there's no sound way for the operator, or the proxy itself, to infer those from a plugin's configuration. A plugin that reports to a separate Kafka cluster, for instance, would need its own `bootstrapServers`-like list, but the actual set of brokers it ends up talking to could be larger than that list, and nothing in the plugin's configuration reveals what its egress rules should be.

## Proposal

Since the operator alone is unable to determine a working minimal `NetworkPolicy` for any given set of Kroxylicious resources (`KafkaProxy`, `KafkaProtocolFilter`, etc), it's necessary for the user to provide some ingress and egress information.
However, the operator is uniquely positioned to make that as simple as possible for the user — simpler than them writing their own NP.

To make best use of Kubernetes' RBAC authorization, it is proposed to express ingress and egress information in a dedicated CR, rather than in the existing Kroxylicious resources.
This will permit the Data Engineer to have access to a `KafkaProtocolFilter` without also granting them control over the firewall rules for the proxy as a whole.

Each `KafkaProxy` has at most one companion `KafkaProxyNetworkPolicy`, which declares, in one place, the ingress rules for every `KafkaProxyIngress`, and the egress rules for every `KafkaService` and `KafkaProtocolFilter`, that belong to that proxy. This results in a simple CRD, validation, and reconciliation story, and a single place to review a proxy's complete declared network policy.

### Non-goals

* Support for other resources than Kubernetes' built-in `NetworkPolicy`.
* RBAC separation finer than "who may shape this `KafkaProxy`'s network policy as a whole" — e.g. separately granting one role control over a proxy's ingress exposure, another over its egress to the real cluster, and a third over an individual filter's own needs. 
* Support for the new `KafkaProtocolRouter` CR, from [proposal #142](https://github.com/kroxylicious/design/blob/main/proposals/142-kube-api-routing.md), or the new `spec.tlsSubjectBuilder` of `VirtualKafkaCluster`, from [proposal #146](https://github.com/kroxylicious/design/blob/main/proposals/146-tls-subject-builder-crd.md). Either can end up needing real network access — a router plugin making its own upstream calls, or a `tlsSubjectBuilder` backed by LDAP or OAuth token introspection — but neither is addressed here. Both are structurally like `KafkaProtocolFilter` — standalone CRs that resolve transitively to a proxy — so adding either as a target later is a purely additive extension to `KafkaProxyNetworkPolicy`, following the same `filterRef`-style resolution and required-`ports` pattern already used for filters, rather than a redesign.

### Goals

* Introduce a new CRD allowing a user to express, for a given `KafkaProxy`, the complete set of ingress and egress rules it needs: its ingress exposure, its egress to the real Kafka cluster(s), and any ingress/egress its filters need.
* Keep that CRD separate from `KafkaProxyIngress`, `KafkaService`, and `KafkaProtocolFilter`, so that the RBAC grant needed to shape a proxy's network behaviour can be distinct from the grant needed to configure the rest of it.
* A single CR should be authoritative for a given `KafkaProxy`'s entire declared network policy, so that auditing a proxy's access doesn't require enumerating objects scattered elsewhere in the namespace.
* Generate `NetworkPolicy` resources targeting the proxy's `Pods`, one per declared (or defaulted) ingress/service/filter, with descriptive `metadata.name`s, so that auditing why a particular rule exists doesn't require reading the content of every rule.
* Generate `NetworkPolicy` resources by default on new installations; require existing installations to opt in, so the operator never silently widens access a user may already have restricted with hand-written `NetworkPolicy`. Generation can always be disabled.
* Whenever a target has no declared rule, default to generating an allow-everywhere `NetworkPolicy` for it rather than a deny-everything one — on both new and existing installations.
* A gap in, or failure to resolve, one target's declared rules must never retract already-working enforcement for another target on the same proxy ("stale but safe" — see [Resolution, exhaustiveness, and generation semantics](#resolution-exhaustiveness-and-generation-semantics)).

How the operator tells a fresh install from an upgrade is explained in [`networkPolicyGeneration`](#networkpolicygeneration).

### New CRDs

Two new custom resource definitions (CRDs) will be added:

| Kind | Scope | Typical owner | Purpose |
| --- | --- | --- | --- |
| `KafkaProxyNetworkPolicy` | Namespaced | Whoever declares a proxy's network needs as a whole — e.g. a security/platform-per-tenant role, distinct from whoever owns the proxy's `KafkaProxyIngress`, `KafkaService`, and `KafkaProtocolFilter` resources. | Declares the ingress rules for every `KafkaProxyIngress`, and the egress rules for every `KafkaService` and `KafkaProtocolFilter`, belonging to one `KafkaProxy`. Described in this section. |
| `KafkaProxyOperatorConfig` | Cluster-scoped | The cluster-admin/platform team that runs the operator itself. | Configures operator-wide behaviour, including whether `NetworkPolicy` generation is enabled and what to generate when a target has no declared rule. See [`KafkaProxyOperatorConfig`](#kafkaproxyoperatorconfig). |

#### `KafkaProxyNetworkPolicy`

Each `KafkaProxy` may have **at most one** `KafkaProxyNetworkPolicy`, referencing it explicitly via `spec.proxyRef` — the same pattern used elsewhere in this API (e.g. `KafkaProxyIngress.spec.proxyRef`). If a second `KafkaProxyNetworkPolicy` is created with a `proxyRef` to a `KafkaProxy` that already has one, the second is rejected: `Accepted: False`, reason `Conflicting`, pointing at the name of the one already in effect. Ordering is by creation timestamp, breaking ties — timestamps only have second-level resolution — by lexicographically later `metadata.name`.

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxyNetworkPolicy
metadata:
  name: my-proxy-network-policy
spec:
  proxyRef:
    name: my-proxy
  kafkaProxyIngresses:
    - ingressRef:
        name: my-ingress
      allowIngressFrom:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: my-kafka-app-ns
        - ipBlock:
            cidr: 203.0.113.0/24
            except:
              - 203.0.113.128/27
    - ingressRef:
        name: my-other-ingress
      allowIngressFrom: [...]
  kafkaServices:
    - serviceRef:
        name: my-strimzi
    - serviceRef:
        name: my-external-kafka-cluster
      allowEgress:
        - ports:
            - protocol: TCP
              port: 9092
          to:
            - ipBlock:
                cidr: 198.51.100.0/24
  kafkaProtocolFilters:
    - filterRef:
        name: my-encryption-filter
      allowEgress:
        - ports:
            - protocol: TCP
              port: 8200
          to:
            - namespaceSelector:
                matchLabels:
                  kubernetes.io/metadata.name: vault
```

* `spec.proxyRef` identifies the `KafkaProxy` this `KafkaProxyNetworkPolicy` governs. It resolves only within the same namespace — there is no cross-namespace form.
* `spec.kafkaProxyIngresses[]` declares, per `ingressRef`, the `from` peers allowed to reach that ingress. There is no `ports` field here: the port(s) are always the ingress's own listening port(s), which the operator already knows — see [Ports](#ports) for why this differs from the other two lists.
* `spec.kafkaServices[]` declares, per `serviceRef`, zero or more `{ports, to}` rules for egress to that `KafkaService`. An entry with no `allowEgress` at all is valid — see [The `strimziKafkaRef` case](#the-strimzikafkaref-case) for why, and [Ports](#ports) for what an entry's own omitted `ports` means.
* `spec.kafkaProtocolFilters[]` declares, per `filterRef`, zero or more `{ports, from}` rules under `allowIngress` and/or zero or more `{ports, to}` rules under `allowEgress`. Unlike the other two lists, `ports` is **required** on every entry here — see [Ports](#ports).

Each list entry's peer type (`namespaceSelector`/`podSelector` vs. `ipBlock`) is constrained by the mechanism of the thing it targets — e.g. a `clusterIP`-mechanism `KafkaProxyIngress` only makes sense with selector peers, a `loadBalancer`-mechanism one only with `ipBlock`. This depends on the state of a different object (the targeted `KafkaProxyIngress`/`KafkaService`), which a CRD-schema CEL rule cannot look up, so it's validated in the reconciler and reported via `Accepted: False` — see the mechanism-specific sections below and [Status conditions](#status-conditions).

Every generated `NetworkPolicy` shares a common `podSelector`, `ownerReferences` rule, and naming scheme — see [Common structure of generated `NetworkPolicy` resources](#common-structure-of-generated-networkpolicy-resources) below.

#### Ports

Whether `ports` may, must, or must never be specified follows directly from whether the operator has any other way to know the right answer:

| List | `ports` allowed? | Rationale |
| --- | --- | --- |
| `kafkaProxyIngresses[].allowIngressFrom` | Never (no field at all) | The ingress's own listening port(s) are already known to the operator from the targeted `KafkaProxyIngress`, and there's no sensible reason to allow a narrower subset of your own listener's port. |
| `kafkaServices[].allowEgress` (via `strimziKafkaRef`) | Optional, additive only | The broker listener port is already known precisely from the referenced Strimzi `Kafka` resource — see [the `strimziKafkaRef` case](#the-strimzikafkaref-case). An entry's `ports`/`to` here can only add further destinations, never replace the auto-derived rule. |
| `kafkaServices[].allowEgress` (via `bootstrapServers`) | Optional; omitted means **all ports** | `bootstrapServers` gives the bootstrap port, but Kafka allows individual brokers to advertise arbitrary other combinations of ports and brokers, so the bootstrap port isn't guaranteed to be the only port the proxy ends up dialling once broker topology is discovered. The operator cannot safely narrow this on the user's behalf; a user who knows their cluster's brokers all share one port may narrow it explicitly. |
| `kafkaProtocolFilters[].allowIngress`/`allowEgress` | **Required** | A filter's destination is arbitrary and plugin-defined; the operator has no mechanism to infer a port the way it can for an ingress or a Strimzi-backed service. |

### `KafkaProxyOperatorConfig`

The operator `Deployment` itself will support a `CONFIG_NAME` env var which allows selecting the `KafkaProxyOperatorConfig` to be used by that operator instance.
The value will default to `default`.

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxyOperatorConfig
metadata:
  name: default
spec:
  clusterDomain: ...
  clusterCIDRs: ...
  networkPolicyGeneration: ...
```

#### `clusterDomain`

Example:
```yaml
spec:
  clusterDomain: cluster.local
```

The `clusterDomain` option provides an admin override to the autodetection of the cluster domain DNS suffix.
The default will be based on the `search` stanza of the operator's local `/etc/resolv.conf`, which should normally work without the `clusterDomain` option needing to be defined.

#### `clusterCIDRs`

Example:
```yaml
spec:
  clusterCIDRs:
    - 10.244.0.0/16     # IPv4 Pod IPs
    - 10.96.0.0/12      # IPv4 Service IPs
    - fd00:10:244::/48  # IPv6 Pod IPs
    - fd00:10:96::/112  # IPv6 Service IPs
```

The `clusterCIDRs` option allows an admin to specify the IP blocks for cluster-local addresses.
This is needed in order to detect and reject internal addresses for `KafkaService.spec.bootstrapServers`.
Unlike `clusterDomain`, there is no autodetection fallback: Kubernetes offers no reliable, low-privilege way to derive pod/service CIDRs that holds across CNIs (many cloud CNIs don't populate `Node.spec.podCIDRs` at all, and reading it cluster-wide would need a `nodes` RBAC grant disproportionate to this one check).
If `clusterCIDRs` is left unset, the internal-address check is skipped rather than enforced some other way — an admin relying on it should make sure it's actually configured.

#### `networkPolicyGeneration`

Example:
```yaml
spec:
  networkPolicyGeneration: 
    generation: enabled|disabled
    whenAbsent: allow|deny
```

This allows enabling/disabling the generation of NP, and configuring that generation's behaviour.

**`networkPolicyGeneration.generation`** controls whether `NetworkPolicy` resources are generated at all:

* `enabled`: `NetworkPolicies` will be generated
* `disabled`: `NetworkPolicies` will not be generated

`generation` has no fixed schema-level default: the right default genuinely differs between a fresh install and an upgrade, and `KafkaProxyOperatorConfig` is itself a brand-new CRD, so there's no pre-existing object either path could read a default from. Instead, if no `KafkaProxyOperatorConfig` named `CONFIG_NAME` exists, the operator creates one, setting `spec.networkPolicyGeneration.generation` according to whether any `KafkaProxy` resources already exist in the cluster at that moment: `enabled` if none do, since this is a fresh install; `disabled` if at least one does, since this is an existing install that may already have hand-written `NetworkPolicy` in place. Generating allow-everywhere `NetworkPolicy` by default is harmless on a fresh install, but on an existing one it can silently widen access past a user's existing rules — `NetworkPolicy` is additive only, see [Current situation](#current-situation) — so a new allow-all rule unions with, and defeats, a restrictive one rather than being overridden by it. Once created, the object is a normal, mutable resource: an admin can change `generation` afterwards like any other field, and the operator never re-derives or overwrites it later.

**`networkPolicyGeneration.whenAbsent`** governs what's generated for **any** target — a `KafkaProxyIngress`, a `KafkaService`, or a `KafkaProtocolFilter` direction — with no explicit rule currently in effect for it; see [Resolution, exhaustiveness, and generation semantics](#resolution-exhaustiveness-and-generation-semantics) for exactly when that applies.

* `allow` generates a `NetworkPolicy` permitting that traffic from/to anywhere.
* `deny` generates a `NetworkPolicy` with the matching `policyTypes` entry but no rules at all for that direction. Kubernetes' own `NetworkPolicy` semantics mean a `Pod` selected by a policy of a given type with no matching rule denies all traffic of that type by default.

Neither value is an unconditional verdict on its own. Both depend on the cluster's CNI actually enforcing `NetworkPolicy` at all — see [Current situation](#current-situation) — and `deny` additionally only holds so long as no *other* target on the same `KafkaProxy` has a broader rule for the same direction, since rules generated for different targets on the same proxy are unioned together rather than evaluated independently — see [`podSelector`](#podselector). `deny` therefore means "this entry grants nothing of its own", not "this direction is blocked".

`allow` is the schema default for `whenAbsent`, for every install, fresh or upgraded alike: the bar to getting a working proxy should be low, so a brand-new `KafkaProxy` should pass traffic immediately rather than needing a `KafkaProxyNetworkPolicy` authored first, and an upgrade should never silently cut off access a target was previously relying on.

This default isn't a dead end for security, though: every generated policy, including the wide-open ones, is still named descriptively and labelled `kroxylicious.io/default-policy: allow` (see [Naming](#naming)), so an administrator can enumerate every allow-everywhere rule in the cluster with `kubectl get networkpolicy -l kroxylicious.io/default-policy=allow` and tighten them at their own pace — either by adding explicit entries to the relevant `KafkaProxyNetworkPolicy`, or, once confident nothing still depends on the wide-open default, flipping `networkPolicyGeneration.whenAbsent` to `deny`. `deny` is always a deliberate, explicit administrator choice; the operator never switches to it on its own.

### Resolution, exhaustiveness, and generation semantics

`spec.proxyRef`, `ingressRef`, `serviceRef`, and `filterRef` are all resolved by the operator, which updates `status` accordingly (see [Status conditions](#status-conditions)). A reference is only considered resolved if:

* the referenced CR exists 
* **and** the referenced CR has `ResolvedRefs: True`
* **and** the referenced CR, directly or transitively, resolves to the same `KafkaProxy` named by this `KafkaProxyNetworkPolicy`'s own `spec.proxyRef` — e.g. a `serviceRef` pointing at a `KafkaService` that isn't actually attached to this proxy's `VirtualKafkaCluster`(s) does not resolve.

**Exhaustiveness.** A `KafkaProxyNetworkPolicy` is only `Accepted: True` if, in addition to every listed ref resolving, the reverse also holds: every `KafkaProxyIngress`, `KafkaService`, and `KafkaProtocolFilter` that resolves to this proxy has a corresponding entry in the relevant list of the `KafkaProxyNetworkPolicy`. This means there's no way for some targets on a proxy to have declared rules while others silently don't, and a filter can never get a "free ride" on a sibling's broad rule without an explicit entry of its own making that visible.

**Generation is per-target.** Each `ingressRef`/`serviceRef`/`filterRef` entry is resolved, validated, and used to generate (or update) its own `NetworkPolicy` independently:

* An entry that resolves and validates generates/updates its `NetworkPolicy` from its declared rules, regardless of the state of any other entry.
* A target with **no** entry in the `KafkaProxyNetworkPolicy` (e.g. a `KafkaProtocolFilter` just added to the proxy, before its owner has updated the shared CR) is treated exactly as if the whole `KafkaProxyNetworkPolicy` were absent for that one target: the `whenAbsent` fallback applies to it alone, generating an allow- or deny-everywhere `NetworkPolicy` labelled `kroxylicious.io/default-policy` (see [Naming](#naming)). It does not affect any other, already-declared target. This is what keeps exhaustiveness from becoming a cliff-edge: a `KafkaProxyNetworkPolicy` that's temporarily `Accepted: False` because of one missing entry still has every other entry's precise, declared rules in full effect.
* An entry that previously resolved and validated, but no longer does (e.g. its ref now names a deleted `KafkaProtocolFilter`, or its rules have become invalid for the target's mechanism), leaves its **previously generated `NetworkPolicy` untouched** — "stale but safe". The operator does not delete it, and does not fall back to `whenAbsent` for it, since either of those would change what's enforced based on an error condition rather than a deliberate choice. The entry is reported as unresolved/invalid in `status` (see below) until it's fixed or removed.

This means `Accepted` on the `KafkaProxyNetworkPolicy` itself is primarily a human-facing signal — "is every target for this proxy explicitly and validly declared?" — rather than a gate on whether generation happens at all.

### Status conditions

`KafkaProxyNetworkPolicy` reports three standard roll-up conditions in `status.conditions`, consistent with the existing `KafkaProxyIngress`/`KafkaService`/`KafkaProtocolFilter` CRs, plus per-entry status for each list item (following the same per-item status convention as e.g. the Gateway API's `HTTPRoute.status.parents[]`):

```yaml
status:
  conditions:
    - type: ResolvedRefs
      status: "True"
    - type: Accepted
      status: "False"
      reason: Incomplete
      message: "KafkaProtocolFilter 'my-other-filter' is attached to this proxy but has no entry in spec.kafkaProtocolFilters"
    - type: Programmed
      status: "True"
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
| `ResolvedRefs` | `True` | — | `spec.proxyRef` resolves, and every listed `ingressRef`/`serviceRef`/`filterRef` resolves to a CR that itself, directly or transitively, resolves to the same `KafkaProxy`. |
| `ResolvedRefs` | `False` | `ReferencedResourcesNotFound` | `spec.proxyRef`, or at least one listed ref, does not resolve to an existing CR in this namespace. |
| `ResolvedRefs` | `False` | `TransitivelyReferencedResourcesNotFound` | A listed ref resolves to an existing CR, but it does not resolve to the `KafkaProxy` named by `spec.proxyRef` (or doesn't itself report `ResolvedRefs: True`). |
| `ResolvedRefs` | `Unknown` | — | The last reconciliation attempt failed with an error before refs could be checked. |
| `Accepted` | `True` | — | `ResolvedRefs` is `True`, every entry's rules are valid for its target's mechanism, and every `KafkaProxyIngress`/`KafkaService`/`KafkaProtocolFilter` resolving to this proxy has a corresponding entry (the exhaustiveness check). |
| `Accepted` | `False` | `Incomplete` | `ResolvedRefs` is `True`, but at least one `KafkaProxyIngress`/`KafkaService`/`KafkaProtocolFilter` resolving to this proxy has no corresponding entry. |
| `Accepted` | `False` | `Invalid` | At least one entry's rules use a peer type its target's mechanism doesn't allow (see the mechanism-specific sections below). |
| `Accepted` | `False` | `Disabled` | `NetworkPolicy` generation is disabled cluster-wide via `KafkaProxyOperatorConfig`. `ResolvedRefs` is unaffected. |
| `Accepted` | `False` | `Conflicting` | Another `KafkaProxyNetworkPolicy` already targets the same `KafkaProxy` (see [`KafkaProxyNetworkPolicy`](#kafkaproxynetworkpolicy)). |
| `Programmed` | `True` | — | Every `NetworkPolicy` implied by every entry's last successfully-resolved spec has been created/updated in the API server. This says nothing about whether the cluster's CNI has actually enforced it — see [Current situation](#current-situation). |
| `Programmed` | `False` | `UpdateFailed` | The operator attempted to create/update at least one target's `NetworkPolicy` and the write failed. |
| `Programmed` | `Unknown` | — | Reconciliation hasn't reached the generation step yet, or the last attempt failed before getting there. |

Per-entry conditions use the same `ResolvedRefs`/`Accepted`/`Programmed` vocabulary, scoped to that one entry, so a user can tell at a glance which specific target is holding back the roll-up `Accepted: True` — and, per [Resolution, exhaustiveness, and generation semantics](#resolution-exhaustiveness-and-generation-semantics), which targets are currently relying on a stale or default-generated `NetworkPolicy` rather than their own declared rules. A "stale but safe" entry keeps `Programmed: True` even once `ResolvedRefs`/`Accepted` flips to `False`, since its existing `NetworkPolicy` still correctly reflects the last spec that did resolve.

Because this validation happens on the reconciler's own schedule rather than at `kubectl apply` time (except for the schema-level constraints noted in [`KafkaProxyNetworkPolicy`](#kafkaproxynetworkpolicy), e.g. `ports` being absent/required per list), a `KafkaProxyNetworkPolicy` can be admitted and only later found to be rejected. GitOps/CI pipelines applying these CRs should therefore wait on both the `Accepted` and `Programmed` conditions explicitly, e.g. `kubectl wait --for=condition=Accepted --for=condition=Programmed kafkaproxynetworkpolicy/<name>`, rather than treating a successful `kubectl apply` as confirmation that every entry took effect.

### Common structure of generated `NetworkPolicy` resources

Every `NetworkPolicy` the operator generates — a default (no rule declared for that target), or the result of a declared entry, whether user-specified or, for a `strimziKafkaRef`-based `KafkaService`, auto-derived — shares the same `podSelector`, the same `ownerReferences` rule, and is named using the same scheme. This section defines all three once; the sections below describe only what's specific to each target kind: the shape of the `from`/`to` peers and `ports` in the generated `ingress`/`egress` rule.

#### `podSelector`

The operator resolves `spec.proxyRef` to the `KafkaProxy`, and copies that `KafkaProxy`'s own `Pod`-selector labels, unchanged, into every generated `NetworkPolicy`:

```yaml
podSelector:
  matchLabels:
      app.kubernetes.io/name: kroxylicious
      app.kubernetes.io/component: proxy
      app.kubernetes.io/instance: my-proxy-cr
```

Because this `podSelector` is identical on every `NetworkPolicy` generated for a given `KafkaProxy` — regardless of which entry drove its generation — they all select the same `Pods`, and `NetworkPolicy` rules are additive across policies selecting the same `Pod` (see [Current situation](#current-situation)). This means a broad rule generated for *any one* target on a proxy is unioned with every other target's rules for the same direction. For example, a `KafkaProxy` with one `KafkaService` using `strimziKafkaRef` and a declared entry (getting the narrow, auto-derived rule) and a second `KafkaService` using `bootstrapServers` with no declared `allowEgress` (getting the `whenAbsent` fallback) ends up, if that default is `allow`, with unrestricted egress on that port from the proxy's `Pods`: the first `KafkaService`'s narrow rule is still generated correctly and still has naming/audit value, but it adds no enforcement once a sibling target's rule already allows everything. Restricting a proxy's effective ingress or egress for a given direction therefore means addressing *every* target on that proxy, not just the one under review.

#### `ownerReferences`

Every `NetworkPolicy` generated for a `KafkaProxy`'s targets — whether from a declared entry (auto-derived, for a `strimziKafkaRef`-based `KafkaService`) or the `whenAbsent` fallback — is owned by that `KafkaProxy` itself, regardless of whether a `KafkaProxyNetworkPolicy` exists for it. Ownership is uniform: deleting a `KafkaProxy` cleans up every generated `NetworkPolicy` via normal garbage collection, with no special case for whether a `KafkaProxyNetworkPolicy` was involved.

Deleting a `KafkaProxyNetworkPolicy` does not, by itself, delete any generated `NetworkPolicy` — the objects stay in place, still owned by the `KafkaProxy`. Instead, the reconciler, already watching `KafkaProxyNetworkPolicy` and triggered by its deletion, rewrites each affected target's `NetworkPolicy` content back to the `whenAbsent` fallback in place. This is the same create-or-update logic the reconciler already applies whenever a declared entry's rules change; a deleted `KafkaProxyNetworkPolicy` is just another change in a target's effective source of truth, not a special case.

#### Naming

Each generated `NetworkPolicy`'s `metadata.name` is `${token}.${name}`, where `${name}` is copied verbatim from the `metadata.name` of the `KafkaProxyIngress`/`KafkaService`/`KafkaProtocolFilter` that entry targets, and `${token}` identifies the direction/role:

| Token | Generated for |
| --- | --- |
| `ingress` | A `KafkaProxyIngress` entry (or default) |
| `egress` | A `KafkaService` entry (or default), including the `strimziKafkaRef` auto-derived rule |
| `filter-ingress` | A `KafkaProtocolFilter` entry's `allowIngress` (or default) |
| `filter-egress` | A `KafkaProtocolFilter` entry's `allowEgress` (or default) |

This is collision-free by construction, without needing any constraint on `metadata.name` beyond what each of these CRDs already allows. The four tokens are mutually non-prefix, diverging from one another within their first 8 characters regardless of what follows: `ingress`/`egress` diverge from each other and from the `filter-*` tokens at their very first character, and `filter-ingress`/`filter-egress` diverge at their 8th. So `${token1}.${name1}` can only equal `${token2}.${name2}` if `token1 == token2` — and since each token maps to exactly one source kind, that in turn requires `name1 == name2`, which can't happen for two distinct objects of the same kind in the same namespace. This holds regardless of what characters `name` itself contains, including `.`.

Whether a given `ingress`/`egress`/`filter-ingress`/`filter-egress` `NetworkPolicy` came from a declared entry or from the `whenAbsent` fallback is recorded as a label, not in the name:

```yaml
metadata:
  labels:
    kroxylicious.io/default-policy: allow # or: deny
```

This label is present whenever a `NetworkPolicy` was generated via the `whenAbsent` fallback (see [Resolution, exhaustiveness, and generation semantics](#resolution-exhaustiveness-and-generation-semantics)), letting all such rules be selected independent of target kind, e.g. `kubectl get networkpolicy -l kroxylicious.io/default-policy=deny`. It's absent once an entry's own declared rules are in effect — including the `strimziKafkaRef` auto-derived rule, which is itself only generated once an entry exists — since that's not driven by `whenAbsent`.

Length is a separate concern from collision, and needs separate handling: `KafkaProxyIngress` and `KafkaService` impose no `maxLength` on `metadata.name` today, so a name can be as long as the API server's generic 253-character default. Tightening that retroactively isn't available as an option — see [Rejected alternatives](#rejected-alternatives) — so when the computed `${token}.${name}` would exceed `NetworkPolicy`'s own 253-character limit, the operator instead generates `${token}.${name-prefix}-${hash}`, where `name-prefix` is the first 229 characters of `name` and `hash` is 8 lowercase hex characters derived from a stable hash of the full, untruncated `name`. This only ever applies once `name` exceeds 238 characters, already a pathological outlier, and makes a collision between two different overly-long names vanishingly unlikely rather than structurally impossible — the same trade-off as a `git` short hash.

### Policy for `KafkaProxyIngress`

For a `KafkaProxyIngress` with no entry in `spec.kafkaProxyIngresses` (or no `KafkaProxyNetworkPolicy` at all), the `whenAbsent` fallback applies, generating a `NetworkPolicy` named `ingress.${ingress-name}` (see [Naming](#naming)). Here's the `allow` case:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ingress.my-loadbalancer-ingress
spec:
  podSelector: ... # see Common structure above
  policyTypes:
    - Ingress
  ingress:
    - ports:
      - protocol: TCP
        port: <PORT_NUM> # for each port
```

When an entry targets a given `KafkaProxyIngress`, the same `NetworkPolicy` name is used, now built from `allowIngressFrom`. The exact content depends on the ingress mechanism.
The `KafkaProxyIngress` CR supports three ingress mechanisms:

* `clusterIP` for access from Kafka clients running in the same Kubernetes cluster
* `loadBalancer` for access from Kafka clients running outside the Kubernetes cluster
* `openShiftRoute` for access from Kafka clients running outside the OpenShift cluster

#### The `clusterIP` case

The `clusterIP` mechanism is specifically intended for access from the same Kubernetes cluster, so each entry's `allowIngressFrom` list must use `namespaceSelector` and/or `podSelector` (see [Status conditions](#status-conditions) for how the operator reports a violation).

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
  proxyRef:
    name: my-proxy-cr
  kafkaProxyIngresses:
    - ingressRef:
        name: my-ingress
      allowIngressFrom:
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
  name: ingress.my-ingress
  namespace: my-proxy-ns
spec:
  podSelector: ... # see Common structure above
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

This works the same way, except `loadBalancer` is explicitly intended for off-cluster access, so each entry's `allowIngressFrom` list must instead use `ipBlock` (the same schema `NetworkPolicy` itself supports):
```yaml
ipBlock:
  cidr: 203.0.113.0/24
```

`Service.spec.loadBalancerSourceRanges` is a best-effort declaration of the source IPs which should be allowed through the load balancer.
In practice enforcement is cloud-provider-dependent, and can be ignored.

For `loadBalancerSourceRanges` and the pod-level `NetworkPolicy` below to restrict access correctly, the generated `Service` also needs `externalTrafficPolicy: Local`, to preserve the client's source IP address rather than losing it to SNAT.
`KafkaProxyIngress` already supports this via `spec.loadBalancer.service.externalTrafficPolicy` (added by [proposal #134](https://github.com/kroxylicious/design/pull/134)).
The operator should reject an `allowIngressFrom` entry with `ipBlock` rules targeting a `loadBalancer` ingress whose `externalTrafficPolicy` isn't `Local` (`Accepted: False` on that entry), since otherwise the restriction would silently fail to match real client addresses.

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
  name: ingress.my-loadbalancer-ingress
  namespace: my-proxy-ns
spec:
  podSelector: ... # see Common structure above
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

Proposal #134 gives each `loadBalancer`-type `KafkaProxyIngress` its own dedicated `Service`, so an entry's CIDRs apply directly to that ingress's own `Service.spec.loadBalancerSourceRanges` and pod-level `NetworkPolicy`, with no cross-ingress CIDR union to construct.

Sharing hasn't disappeared entirely, though: multiple `VirtualKafkaClusters` can still reference the same ingress, addressed by SNI on that ingress's one `Service` — this is what delivers the per-load-balancer cost saving proposal #134 preserves.
An entry targeting that ingress applies uniformly to all of them: a pod-level `NetworkPolicy` can't differentiate traffic by the SNI hostname it arrived on, so there's no way to give one `VirtualKafkaCluster` a narrower CIDR allowlist than another if they share an ingress.
(See [Future work](#future-work) for a possible enhancement that would recover that per-virtual-cluster isolation.)

#### The `openShiftRoute` case

Like `loadBalancer`, `openShiftRoute` is explicitly intended for off-cluster access, so the same `ipBlock` requirement applies to each entry's `allowIngressFrom` list.

To restrict access by client CIDR with an OpenShift `Route`, we must restrict traffic at the `Route` layer using an annotation, and pair it with a `NetworkPolicy` to restrict `Pod` ingress to only the OpenShift Ingress `Router`.

```yaml
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: my-proxy-cr-my-ingress
  namespace: my-proxy-ns
  annotations:
    # Space-separated list of allowed CIDRs or IP addresses, taken from the KafkaProxyNetworkPolicy
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
  name: ingress.my-route-ingress
  namespace: my-proxy-ns
spec:
  podSelector: ... # see Common structure above
  policyTypes:
    - Ingress
  ingress: # The rules target the pod running the Router network proxy.
    - from:
        - namespaceSelector:
            matchLabels:
              network.openshift.io/policy-group: ingress
      ports:
        - protocol: TCP
          port: 9092
```

### Policy for `KafkaService`

For a `KafkaService` using `bootstrapServers` with no entry in `spec.kafkaServices` (or no `KafkaProxyNetworkPolicy` at all), the `whenAbsent` fallback applies, generating a `NetworkPolicy` named `egress.${kafka-service-name}` (see [Naming](#naming)). This applies identically to a `KafkaService` using `strimziKafkaRef` that has no entry — see [the `strimziKafkaRef` case](#the-strimzikafkaref-case) below for what it gets once one exists. Here's the `allow` case:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: egress.my-target-cluster
spec:
  podSelector: ... # see Common structure above
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

`strimziKafkaRef` is a very special case: we already know the namespace of the `Kafka` cluster, and the `Pod` labels, and hence selectors, are a published part of the Strimzi API, so the operator can always compute the exact egress rule itself once a `KafkaProxyNetworkPolicy` entry exists for it, without needing an `allowEgress` entry at all.

As with `bootstrapServers` above, a `strimziKafkaRef`-based `KafkaService` with no entry gets the ordinary `whenAbsent` fallback. Once a `- serviceRef: {name: ...}` entry exists — with or without `allowEgress` — the operator instead generates the precise rule itself, since a correct answer is already available for free and there's no reason to ask the user to supply `to`/`ports` manually. This entry is also what the [exhaustiveness](#resolution-exhaustiveness-and-generation-semantics) check requires for `Accepted: True`.

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
  proxyRef:
    name: my-proxy-cr
  kafkaServices:
    - serviceRef:
        name: strimzi-target
```

A bare entry like this, with no `allowEgress`, is enough to generate a `NetworkPolicy` named `egress.${kafka-service-name}` (see [Naming](#naming)):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: egress.strimzi-target
spec:
  podSelector: ... # see Common structure above
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

An `allowEgress` entry can still be added for a `strimziKafkaRef`-based `KafkaService` if needed — for example to grant egress to some additional destination beyond the Strimzi brokers themselves. Its rules are additive with the auto-derived rule above (see [Current situation](#current-situation)), rather than replacing it. The same additivity applies across *other* targets on the same proxy, not just within this one — see [`podSelector`](#podselector) for why a precise rule like this one offers no enforcement guarantee if a sibling `KafkaService` on the same `KafkaProxy` ends up with a broader rule on the same port.

#### The `bootstrapServers` case

`bootstrapServers` allows any kind of host address to be specified.
Supporting it involves a number of sub-cases:

* the given servers are internal IPv4 or IPv6 addresses
* the given servers are internal DNS names (e.g. `my-kafka-cluster-kafka-bootstrap.my-ns.svc.cluster.local`, a Strimzi bootstrap `Service` DNS name)
* the given servers are external IPv4 or IPv6 addresses
* the given servers are external DNS names (e.g. `node12.kafka.example.com:9092`)

The use of internal IP addresses will not be supported.
`KafkaService` resources with `bootstrapServers` including any internal IP address will be rejected using an `Accepted` condition with a suitable message.
There is no good reason users should be using IP addresses to specify an internal Kafka cluster.
IP addresses in Kubernetes are very dynamic, so it's unlikely to work reliably, even if it were supported.

##### Internal DNS names

Strimzi's bootstrap `Service` for a listener is named `<cluster-name>-kafka-bootstrap` (or `<cluster-name>-kafka-<listener-name>-bootstrap` for a named listener), giving an internal DNS name of the form `<cluster-name>-kafka-bootstrap.<namespace>.svc.<cluster-domain>`.
This is the form `bootstrapServers` should expect: it's derived only from the `Kafka` resource's name, so it stays stable across broker scaling and `KafkaNodePool` changes.
Strimzi also makes individual broker pods addressable via a headless `Service` (`<cluster-name>-kafka-<broker-id>.<cluster-name>-kafka-brokers.<namespace>.svc.<cluster-domain>`), but with `KafkaNodePool`s in use the `<broker-id>` portion depends on node pool naming and can change as pools are scaled or renamed, so it's not a reliable choice for a `bootstrapServers` entry.

When the bootstrap servers list is entirely composed of internal DNS names, each `allowEgress` entry's `to` property is required to use `namespaceSelector` and/or `podSelector` rules.

```yaml
---
kind: KafkaService
metadata:
  namespace: my-proxy-ns
  name: internal-dns
spec:
  bootstrapServers: my-kafka-cluster-kafka-bootstrap.my-ns.svc.cluster.local:9092
---
# Example network policy restricting access to the given namespace
kind: KafkaProxyNetworkPolicy
metadata:
  name: my-proxy-network-policy
spec:
  proxyRef:
    name: my-proxy-cr
  kafkaServices:
    - serviceRef:
        name: internal-dns
      allowEgress:
        - to:
            - namespaceSelector:
                matchLabels:
                  kubernetes.io/metadata.name: my-ns
```

##### External DNS names and external IP addresses

When the bootstrap servers list is entirely composed of external DNS names and/or external IP addresses, each `allowEgress` entry's `to` property is required to use `ipBlock` rules.

```yaml
---
kind: KafkaService
metadata:
  namespace: my-proxy-ns
  name: external-cluster
spec:
  bootstrapServers: kafka1.example.com:9092,kafka2.example.com:9092
---
kind: KafkaProxyNetworkPolicy
metadata:
  name: my-proxy-network-policy
spec:
  proxyRef:
    name: my-proxy-cr
  kafkaServices:
    - serviceRef:
        name: external-cluster
      allowEgress:
        - to:
            - ipBlock:
                cidr: 198.51.100.0/24
```

### Policy for `KafkaProtocolFilter`

The `KafkaProtocolFilter` CR is used to configure filters.
It is common for filters, or their plugins, to require network egress.
It's also not forbidden for filters to require network ingress.
In the most general case, a filter or its plugin would require rules for both; a single entry can set both `allowIngress` and `allowEgress`, generating two `NetworkPolicy` resources — one per direction (see [Naming](#naming)).

For a `KafkaProtocolFilter` with no entry in `spec.kafkaProtocolFilters` (or no `KafkaProxyNetworkPolicy` at all), the `whenAbsent` fallback applies per direction, generating `NetworkPolicy` resources named `filter-ingress.${kafka-filter-name}` and/or `filter-egress.${kafka-filter-name}` (see [Naming](#naming)). Unlike `KafkaProxyIngress`/`KafkaService`, which always need *some* access just to function, a `KafkaProtocolFilter` may need none at all — but the same `allow`/`deny` choice and reasoning (see [`networkPolicyGeneration`](#networkpolicygeneration)) applies regardless.

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
  proxyRef:
    name: my-proxy-cr
  kafkaProtocolFilters:
    - filterRef:
        name: encryption
      allowEgress:
        - ports:
            - protocol: TCP
              port: 8200
          to:
            - namespaceSelector:
                matchLabels:
                  kubernetes.io/metadata.name: vault
```

And the resulting `NetworkPolicy`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: filter-egress.encryption
spec:
  podSelector: ... # see Common structure above
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

A filter needing egress to more than one kind of destination for different reasons (e.g. a `SaslTermination` filter using OAUTHBEARER tokens plus a `SaslSubjectBuilder` plugin doing LDAP lookups) expresses that as multiple entries in its `allowEgress` list — both still feed the one generated `filter-egress.${name}` `NetworkPolicy`, which can have multiple rules.

### Operator RBAC changes

The operator will need to be allowed to CRUD `NetworkPolicy` resources via its dependent resources `ClusterRole`.
This means the operator has the ability to widen NP on every Pod in every namespace in the cluster, even though it's only ever needed for proxy Pods.
That's unavoidable with Kubernetes's RBAC authorization model: RBAC grants by resource type, not by object identity, so there's no way to restrict the grant to just the `NetworkPolicy` objects the operator itself created.

In the "watched resources" `ClusterRole` the operator will need:
* `watch`, `get`, `list`, `create` on `KafkaProxyOperatorConfig`,
* `watch`, `get`, `list`, `patch`, `update` (+ `/status`) on `KafkaProxyNetworkPolicy`.

### Future work

As a possible future development, we could add an IP-allowlist capability enforced in the proxy itself, and have the operator feed that with the `ipBlock` rules from the `KafkaProxyNetworkPolicy`.
Crucially this could be done once the SNI host name is known, thus recovering the per-virtual-cluster isolation that `Service`-level CIDR restriction cannot provide when multiple `VirtualKafkaClusters` share one ingress's `Service` (see [the `loadBalancer` case](#the-loadbalancer-case)).

[Proposal #148](https://github.com/kroxylicious/design/pull/148) is pursuing per-gateway source-address allow/deny filtering in the proxy application itself. Should that land, `KafkaProxyOperatorConfig.spec.clusterCIDRs` would gain a second consumer: seeding a default "cluster-local only" source filter for `clusterIP`-mechanism gateways, alongside its existing use validating `KafkaService.spec.bootstrapServers`.

## Affected/not affected projects

This affects the `kroxylicious/kroxylicious` repo.

## Compatibility

The proposed changes are backwards compatible. On an upgrade, `NetworkPolicy` generation defaults to `disabled` — see [`networkPolicyGeneration`](#networkpolicygeneration) — so nothing changes for an existing install until an administrator opts in.
Once generation is enabled — on a fresh install by default, or on an upgrade once an administrator opts in — `whenAbsent` defaults to `allow` for every target with no declared rule, so enabling it never locks out traffic a target was previously relying on.
If, due to a bug, generated policies did prevent connections, an administrator can set `KafkaProxyOperatorConfig.spec.networkPolicyGeneration.generation` back to `disabled` to remove them.
`deny` remains available for `whenAbsent`, but only ever as an explicit administrator choice.
The "stale but safe" generation semantics (see [Resolution, exhaustiveness, and generation semantics](#resolution-exhaustiveness-and-generation-semantics)) extend the same guarantee forward: once a target has a working, explicitly declared rule, a later mistake elsewhere in the `KafkaProxyNetworkPolicy` cannot retract it.

## Rejected alternatives

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
* "Use env vars directly for configuring the operator, rather than introducing a new CRD"
    - For the specific operator config options in this proposal env vars would suffice.
    - However, this would establish env vars as being _the_ mechanism for configuring the operator. We suspect the operator will gain more configurability options in the future.
    - Using a CR has a number of advantages:
        - Documented and discoverable using tools like `kubectl explain`, in a way that env vars are not.
        - Kubernetes-aware editors can support writing via features like code completion and inline documentation, driven off the CRD schema.
        - Better support for structured values using YAML. For example lists are just YAML lists, rather than needing to define that the env var's value must be a comma-separated list.
        - More easily modified by end users (who often don't want to customise `Deployment` env vars)
* "Default `networkPolicyGeneration.whenAbsent` to `deny` for genuinely fresh installs while existing installs keep `allow` — whether by having the operator apply this itself via a first-run heuristic (e.g. no `KafkaProxyOperatorConfig` and no `KafkaProxy` resources exist yet), or by seeding a `deny`-default `KafkaProxyOperatorConfig` through install-time tooling (an OLM `ClusterServiceVersion` `initialization-resource`/`alm-examples` annotation, a Helm hook, or a bundled manifest)."
    - A secure-by-default `deny` sounds like the right call, but it raises the bar to getting a working proxy: a fresh `KafkaProxy` would pass no traffic at all until the right `KafkaProxyNetworkPolicy` exists, and every quickstart or example manifest targeting such an install would need to ship one too — otherwise a new user's first experience is a proxy that clearly reports why it isn't working, but still doesn't work. We decided the better trade-off is `allow` everywhere, with the generated policies' descriptive naming and `kroxylicious.io/default-policy` label (see [Naming](#naming)) giving administrators the audit trail to find and tighten `allow` rules on their own schedule, rather than forcing that decision on day one.
    - The install-tooling route would also have been awkward to implement consistently, which was a further reason not to go there: `KafkaProxyOperatorConfig` is a brand-new CRD, so its absence looks identical on a genuinely fresh install and on an existing deployment upgrading to a version with this feature — install-tooling can't distinguish those two cases from that signal alone. Helm's `pre-install` hooks (which fire only on `helm install`, not `helm upgrade`) could have worked for Helm specifically, but OLM's `ClusterServiceVersion` has no equivalent "only on first install" concept, so the two install paths would have behaved inconsistently. An operator-side first-run heuristic could have told the two cases apart reliably where install-tooling couldn't — indeed, `networkPolicyGeneration.generation`'s own default uses exactly that approach (see [`networkPolicyGeneration`](#networkpolicygeneration)) — but since we rejected the underlying goal for `whenAbsent`, there was no reason to build it here too.
* "Add CRD-level validation to `KafkaProxyIngress` and `KafkaService` capping `metadata.name` at 63 characters, matching `KafkaProtocolFilter`'s existing constraint, instead of a hash suffix for over-length names."
    - This would give an exact length guarantee rather than the hash suffix's vanishingly-small-but-nonzero collision risk (see [Naming](#naming)).
    - It isn't available as a backwards-compatible option, though. `metadata.name` is immutable, and CRD schema validation applies to the whole object on every write, not just to the fields being changed. Tightening either CRD's name constraint would permanently block any future update to an existing object whose name already exceeds it, with no way to bring that object into compliance short of deleting and recreating it under a new name. A hash suffix, applied only at `NetworkPolicy`-generation time rather than as a CRD-level constraint, avoids this entirely.
