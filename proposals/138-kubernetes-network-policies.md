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
  A generated policy still has declarative/audit value on such a cluster (per the Motivation below), but it gives no actual network isolation unless the CNI enforces it.
* Each rule in a policy can only widen access, never narrow access. In other words, policies are "additive". This holds both within a single `NetworkPolicy` and across multiple `NetworkPolicy` resources selecting the same `Pod`: Kubernetes unions all their rules rather than letting one override another.
* `NetworkPolicy` has no direct support for expressing rules using external DNS names (e.g. there is no way to say "allow connections to `kms.example.com`").
  Where external DNS names are used for egress, it's necessary to have a "allow egress to anywhere" `NetworkPolicy` rule.
  Some CNIs support custom APIs which supports these rules, but they're out of scope for this proposal.
* Same-kubernetes-cluster rules can be expressed in terms of namespace and pod selectors (e.g. you can say "allow connections to pods matching _this_ selector in namespaces matching _that_ selector"). Moreover, it is considered bad practice to use an `ipBlock` to allow access to/from a pod in the same clusters.

## Motivation

Enterprises are increasingly security-conscious: Kubernetes vendors and admins are adopting default-deny and microsegmentation approaches that make a `NetworkPolicy` a requirement, and even clusters without a default-deny posture are usually better off with one than without.
Tools like the [CIS Kubernetes Benchmark](https://www.armosec.io/glossary/cis-kubernetes-benchmark/) also use `NetworkPolicies` as a declarative input when auditing Kubernetes workloads: a specific policy statement conveys a design requirement, whereas the absence of one could be interpreted as an oversight — and some scanners flag that absence directly.

While it's easy to say "the user should write the NP themselves," that's difficult to do _well_ given how Kafka, the proxy, and the operator interact:

* The Kafka protocol uses the `Metadata` API to discover brokers, so the host addresses in a `KafkaService`'s `bootstrapServers` are only a subset of (or, when behind a load balancer, unrelated to) what a client — here, the proxy — ends up needing to connect to once the broker topology is discovered. For a proxy targeting a Strimzi-managed cluster on the same Kubernetes cluster, the operator can work this out for the user.
* The proxy itself is pluggable, and plugins can bring their own network access requirements — but there's no sound way for the operator, or the proxy itself, to infer those from a plugin's configuration. A plugin that reports to a separate Kafka cluster, for instance, would need its own `bootstrapServers`-like list, but the actual set of brokers it ends up talking to could be larger than that list, and nothing in the plugin's configuration reveals what its egress rules should be.

## Proposal

Since the operator alone is unable to determine a working minimal `NetworkPolicy` for any given set of Kroxylicious resources (`KafkaProxy`, `KafkaProtocolFilter`, etc),
it's necessary for the user to provide some ingress and egress information.
However, the operator is uniquely positioned to make that as simple as possible for the user -- simpler than them writing their own NP.

To make best use of Kubernetes' RBAC authorization, it is proposed to express ingress and egress information in a dedicated CR, rather than in the existing Kroxylicious resources.
This will permit the Data Engineer to have access to the `KafkaProtocolFilter` without also granting them control over the firewall rules for the proxy as a whole.

### Non-goals

* Support for other resources than Kubernetes' built-in `NetworkPolicy`.

### Goals

* Introduce new `CustomResourceDefinitions` (CRDs) to allow a user to express the network connectivity needed using dedicated ingress and egress policies
* Use the policy attachment pattern (as defined by the Kubernetes Gateway API), so that rules live in kinds separate from the CRs they target.
* Generate `NetworkPolicy` resources targeting the proxy `Pods`.
* For new installations, generate `NetworkPolicy` resources by default, with the option to disable generation. 
  In the absence of ingress and egress policy resources, the generated `NetworkPolicy` will be allow-by-default.
* For existing installations, do **not** generate `NetworkPolicy` resources by default. Require the user to enable generation.
  This avoids the operator silently widening any existing NP that a user might already have written.
* Generate multiple `NetworkPolicy` resources with descriptive `metadata.name`, to simplify the auditing of why particular access is needed.
  For example, this would allow identifying which filter requires an egress-to-all rule.

### New CRDs

Two new custom resource definitions (CRDs) will be added:

| Kind | Scope | Typical owner | Purpose |
| --- | --- | --- | --- |
| `KafkaProxyNetworkPolicy` | Namespaced | Whoever declares the proxy's or a filter's network needs — e.g. a security/platform-per-tenant role for the proxy's ingress exposure and its egress to the real Kafka cluster (`KafkaService`), or a plugin-owning team for a filter's own ingress and/or egress. This kind's RBAC surface is shared across all of those cases; see [Rejected alternatives](#rejected-alternatives) for the trade-off against splitting it. | Declares ingress and/or egress rules needed by a `KafkaProxyIngress`, `KafkaService`, or `KafkaProtocolFilter`, using the policy attachment pattern. Described in this section. |
| `KafkaProxyOperatorConfig` | Cluster-scoped | The cluster-admin/platform team that runs the operator itself. | Configures operator-wide behaviour, including whether `NetworkPolicy` generation is enabled and which policy attachments are required. See [Operator-level opt-out](#operator-level-opt-out). |

This is the RBAC separation of concerns motivating this proposal: the role that owns a proxy CR's network behaviour need not be the role that owns the rest of that CR's configuration, and the role that sets operator-wide policy need not be either of those.
A single `KafkaProxyNetworkPolicy` kind doesn't subdivide any further than that — e.g. a role trusted to add one filter's own egress rule can, via that same grant, also add an allow-from-anywhere ingress rule against the shared `KafkaProxyIngress`.

Users wanting to customise the generated `NetworkPolicies` will need to create suitable `KafkaProxyNetworkPolicy` CRs.
CRs will not be needed for those willing to accept allow-all type NP.

`KafkaProxyNetworkPolicy` is used for defining both ingress and egress rules. Its basic shape:

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxyNetworkPolicy
metadata:
  name: ...
spec:
  targetRef:
    group: kroxylicious.io
    kind: KafkaProxyIngress|KafkaService|KafkaProtocolFilter
    name: ...
  ingress: ...
  egress: ...
```

* The `spec.targetRef` references another proxy CR — restricted (via an enum on the `kind` property at the CRD schema level) to `KafkaProxyIngress`, `KafkaService`, or `KafkaProtocolFilter`.
* An optional `spec.ingress` list and an optional `spec.egress` list define the networking requirement implied by the targeted CR. Each entry in either list has essentially the same shape as a `NetworkPolicy` `ingress`/`egress` rule (a list of `from`/`to` peers plus optional `ports`); `ports` is usually omitted and inferred by the operator from the targeted CR, except where noted in later sections.

Which of `spec.ingress`/`spec.egress` may be set depends on `targetRef.kind`. A `KafkaProxyIngress` target only makes sense with `spec.ingress`; a `KafkaService` target only makes sense with `spec.egress`; a `KafkaProtocolFilter` target may use either or both, since a filter may need rules in either direction (or both — see [Policy attachment to `KafkaProtocolFilter`](#policy-attachment-to-kafkaprotocolfilter)). This is enforced with CEL validation rules (`x-kubernetes-validations`) on the CRD, so an invalid combination is rejected at `kubectl apply` time:

```yaml
x-kubernetes-validations:
  - rule: "self.targetRef.kind != 'KafkaService' || !has(self.ingress)"
    message: "spec.ingress is not valid when targetRef.kind is KafkaService"
  - rule: "self.targetRef.kind != 'KafkaProxyIngress' || !has(self.egress)"
    message: "spec.egress is not valid when targetRef.kind is KafkaProxyIngress"
  - rule: "has(self.ingress) || has(self.egress)"
    message: "at least one of spec.ingress or spec.egress must be set"
```

Most of the remaining peer-type validation described in the sections below — e.g. `ipBlock` vs. selector, which depends on the *targeted* `KafkaProxyIngress`'s own `clusterIP`/`loadBalancer`/`openShiftRoute` mechanism — depends on the state of a different object, which a CRD-schema CEL rule cannot look up. That validation happens in the reconciler instead, and is reported via `Accepted: False` (see [Status conditions](#status-conditions)); each mechanism-specific section below therefore states only which peer type it requires, not how a violation gets reported.

`targetRef` only resolves within the same namespace as the `KafkaProxyNetworkPolicy` itself; there is no cross-namespace form (unlike, for example, the Gateway API's `ReferenceGrant`-mediated cross-namespace policy attachment). This keeps the ownership split described above confined to a single namespace: `KafkaProxyNetworkPolicy` can never grant or imply network access on behalf of a `KafkaProxyIngress`, `KafkaService`, or `KafkaProtocolFilter` owned by a different namespace/tenant.

The values allowed in `spec.ingress`/`spec.egress` also depend on the targeted CR, as explained in later sections.

Since `NetworkPolicy` rules are additive (see [Current situation](#current-situation)), any number of `KafkaProxyNetworkPolicy` resources may target the same CR, and their rules are unioned rather than one replacing another — a deliberate divergence from the Gateway API's direct policy attachment convention, where a target normally has at most one attached policy of a given kind. This is useful for composing fine-grained policies: for example a `SaslTermination` filter using OAUTHBEARER tokens plus a `SaslSubjectBuilder` plugin doing LDAP lookups could have two `KafkaProxyNetworkPolicies` — one per destination — each named descriptively enough to audit without needing to read its contents.

Every generated `NetworkPolicy` shares a common `podSelector`, `ownerReferences` rule, and naming scheme — see [Common structure of generated `NetworkPolicy` resources](#common-structure-of-generated-networkpolicy-resources) below.

### Operator-level opt-out

We will add a new cluster-scoped CRD for expressing options for the operator.
The operator `Deployment` itself will support a `CONFIG_NAME` env var which allows to select the `KafkaProxyOperatorConfig` to be used by that operator instance.
The value will default to `default`. 

Here's an example outline CR:

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxyOperatorConfig
metadata:
  name: default
spec:
  clusterDomain: ...
  clusterCIDRs: ...
  resourceGeneration: ...
  policyAttachment: ...
```

Each of the spec properties will be explained in the following sections.

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

#### `resourceGeneration`

Example:
```yaml
  resourceGeneration:
  - group: networking.k8s.io
    kind: NetworkPolicy
    options: 
      generation: enabled|disabled
```

This allows enabling/disabling the generation of optional resources, where `NetworkPolicy` is the first such optional resource.
The schema is flexible to allow other, additional resource kinds to be optionally generated by the operator in future.
The options for `generation` are as follows:

* `enabled`: `NetworkPolicies` will be generated
* `disabled`: `NetworkPolicies` will not be generated

The default value for `generation` for `NetworkPolicy` will be `enabled`. 

#### `policyAttachment`

Example:
```yaml
  policyAttachment: 
    policyTarget: 
      - group: kroxylicious.io
        kind: KafkaProxyIngress
        permittedAttachments:
          - group: kroxylicious.io
            kind: KafkaProxyNetworkPolicy
            direction: ingress
            whenAbsent: allow|deny
      - group: kroxylicious.io
        kind: KafkaService
        permittedAttachments:
          - group: kroxylicious.io
            kind: KafkaProxyNetworkPolicy
            direction: egress
            whenAbsent: allow|deny
      - group: kroxylicious.io
        kind: KafkaProtocolFilter
        requiredAttachments:
          - group: kroxylicious.io
            kind: KafkaProxyNetworkPolicy
            direction: egress
        permittedAttachments:
          - group: kroxylicious.io
            kind: KafkaProxyNetworkPolicy
            direction: ingress
            whenAbsent: allow|deny
```

Each attachment entry carries a `direction: ingress|egress` field alongside `kind`. This is needed because a single `KafkaProxyNetworkPolicy` kind covers both directions, so "which kind is attached" alone doesn't say which direction is being declared — a `KafkaProtocolFilter` target needs `direction` on each of its two independent attachment rules to disambiguate. For `KafkaProxyIngress`/`KafkaService`, only one direction is ever valid (enforced by the CEL rules on `KafkaProxyNetworkPolicy` itself — see [New CRDs](#new-crds)), so `direction` is redundant with the target kind there, but it's included on every entry for a uniform schema.

`policyAttachment.policyTarget` lists, per targeted kind and direction, which attachments are required, permitted, or prohibited:

* `requiredAttachments`: List the (kind, direction) pairs which **must** be present. The target is rejected (`Accepted: False`, reason `NetworkPolicyRequired`) if no `KafkaProxyNetworkPolicy` targets it with that direction set.
* `permittedAttachments`: List the (kind, direction) pairs which **may** be present, each with a `whenAbsent: allow|deny` setting controlling what's generated if no policy with that direction targets the resource. The target is never rejected for this being absent.

**`permittedAttachments[].whenAbsent` is the one mechanism this proposal uses, everywhere, for what to generate when a target has no attached policy for a direction it supports:**
* `allow` generates a `NetworkPolicy` permitting that traffic from/to anywhere.
* `deny` generates a `NetworkPolicy` with the matching `policyTypes` entry but no rules at all for that direction. Kubernetes' own `NetworkPolicy` semantics mean a `Pod` selected by a policy of a given type with no matching rule denies all traffic of that type, so this blocks the direction entirely until a `KafkaProxyNetworkPolicy` with that direction is attached — whose rules are then additive with this (empty) baseline, i.e. exactly what it specifies.

`KafkaProxyIngress`, `KafkaService`, and `KafkaProtocolFilter` are each a target of this mechanism; the section for each below gives only the specific `${token}.${name}` its generated `NetworkPolicy` is given in the `allow`/`deny` case (see [Naming](#naming)) — this paragraph is the one place the `allow`/`deny` behaviour itself is defined. The one exception is a `strimziKafkaRef`-based `KafkaService`, which always gets a precise, auto-derived rule regardless of `whenAbsent` — see [the `strimziKafkaRef` case](#the-strimzikafkaref-case). Either way, the resulting outcome is recorded on the generated `NetworkPolicy` itself via the `kroxylicious.io/default-policy` label (see [Naming](#naming)).

`requiredAttachments` exists because, without it, a filter needing its own egress can get a "free ride" on a bulk rule that was only written to satisfy something else's needs. For example, a `KafkaService` using Kafka-as-a-Service brokers the user can't pin down by `ipBlock` will need an allow-egress-to-anywhere rule; a filter requiring egress would function correctly under that rule alone, with no `KafkaProxyNetworkPolicy` of its own. `requiredAttachments` forces the declarative API to reflect the true situation instead, by rejecting the filter (`Accepted: False`) until an explicit `KafkaProxyNetworkPolicy` with `spec.egress` targets it. The owner of the filter could still write an _incorrect_ rule, but that's something review can catch — whereas omitted-but-working network access is easy for a review to overlook entirely.

`allow` is the schema default for every install, fresh or upgraded alike. The bar to getting a working proxy should be low: a brand-new `KafkaProxy` should pass traffic immediately, not force the user to author `KafkaProxyNetworkPolicy` CRs before anything works, and upgrading a cluster already running this operator should never silently cut off access a target was previously relying on.

`allow` isn't a dead end for security, though: every generated policy — including the wide-open ones — is still named descriptively and labelled `kroxylicious.io/default-policy: allow` (see [Naming](#naming)), so an administrator can enumerate every allow-everywhere rule in the cluster (`kubectl get networkpolicy -l kroxylicious.io/default-policy=allow`) and tighten them at their own pace: attach a scoped `KafkaProxyNetworkPolicy` for a given target, or, once confident nothing still depends on the wide-open default, flip that target's `permittedAttachments` entry to `whenAbsent: deny` in `KafkaProxyOperatorConfig`. `deny` is always a deliberate, explicit administrator choice — the operator never switches a target to it on its own.

When `whenAbsent: deny` applies and no matching policy is attached, the target is given `Accepted: False` with reason `NetworkPolicyRequired` — the same treatment, and the same reason, as a `requiredAttachments` violation, since the resource genuinely isn't passing traffic in that direction and that should be visible rather than silent. This also means it propagates to dependents the same way an existing `ResolvedRefs`/`Accepted` failure already does: a `KafkaProxyIngress` left with no working ingress rule blocks anything that references it, just as it would if its own `KafkaProxy` reference couldn't be resolved.

An administrator who opts in to `deny` should expect it to take effect immediately: any quickstart, example manifest, or getting-started documentation aimed at an installation configured that way needs its own `KafkaProxyNetworkPolicy` CRs, or a `KafkaProxy` created against it won't pass traffic until they're added.

### Common structure of generated `NetworkPolicy` resources

Every `NetworkPolicy` the operator generates — a default (no policy CR attached), the `strimziKafkaRef` auto-derived rule, or the result of an attached `KafkaProxyNetworkPolicy` — shares the same `podSelector`, the same `ownerReferences` rule, and is named using the same scheme. This section defines all three once; the sections below describe only what's specific to each target kind: the shape of the `from`/`to` peers and `ports` in the generated `ingress`/`egress` rule.

#### `podSelector`

The operator resolves `spec.targetRef` through to the `KafkaProxy` that ultimately owns the targeted resource, and copies that `KafkaProxy`'s own `Pod`-selector labels, unchanged, into every generated `NetworkPolicy`:

```yaml
podSelector:
  matchLabels:
      app.kubernetes.io/name: kroxylicious
      app.kubernetes.io/component: proxy
      app.kubernetes.io/instance: my-proxy-cr
```

Because this `podSelector` is identical on every `NetworkPolicy` generated for a given `KafkaProxy` — regardless of which `KafkaProxyIngress`, `KafkaService`, or `KafkaProtocolFilter` drove its generation — they all select the same `Pods`, and `NetworkPolicy` rules are additive across policies selecting the same `Pod` (see [Current situation](#current-situation)). This means a broad rule generated for *any one* target on a proxy is unioned with every other target's rules for the same direction. For example, a `KafkaProxy` with one `KafkaService` using `strimziKafkaRef` (always getting the narrow, auto-derived `target-strimzi` rule) and a second `KafkaService` using `bootstrapServers` with no `KafkaProxyNetworkPolicy` attached (getting the allow-all `target-default` fallback) ends up, in practice, with unrestricted egress on that port from the proxy's `Pods`: the first `KafkaService`'s narrow rule is still generated correctly and still has naming/audit value, but it adds no enforcement once a sibling target's rule already allows everything. Restricting a proxy's effective ingress or egress for a given direction therefore means addressing *every* target attached to that proxy, not just the one under review.

#### `ownerReferences`

* A `NetworkPolicy` generated because a `KafkaProxyNetworkPolicy` targets a resource is owned by that policy CR. Deleting the policy CR removes only the `NetworkPolicy`/`NetworkPolicies` it produced, leaving any other generated `NetworkPolicy` for that target untouched.
* A `NetworkPolicy` generated in the absence of any targeting policy CR — a default-allow/default-deny rule, or the `strimziKafkaRef` auto-derived rule — is instead owned by the target CR itself (`KafkaProxyIngress`, `KafkaService`, or `KafkaProtocolFilter`), since there's no policy CR to own it in that case.

#### Naming

Each generated `NetworkPolicy`'s `metadata.name` is `${token}.${name}`, where `${name}` is copied verbatim from the `metadata.name` of whichever CR drove that generation, and `${token}` identifies which rule produced it:

| Token | `${name}` comes from | Generated when |
| --- | --- | --- |
| `ingress-default` | `KafkaProxyIngress` | No `KafkaProxyNetworkPolicy` with `spec.ingress` set targets it |
| `ingress-policy` | `KafkaProxyNetworkPolicy` | A `KafkaProxyNetworkPolicy` with `spec.ingress` set targets it |
| `filter-ingress-default` | `KafkaProtocolFilter` | No `KafkaProxyNetworkPolicy` with `spec.ingress` set targets it |
| `filter-ingress-policy` | `KafkaProxyNetworkPolicy` | A `KafkaProxyNetworkPolicy` with `spec.ingress` set targets it |
| `target-default` | `KafkaService` | Using `bootstrapServers`, and no `KafkaProxyNetworkPolicy` with `spec.egress` set targets it |
| `target-strimzi` | `KafkaService` | Using `strimziKafkaRef` (unconditional — see [the `strimziKafkaRef` case](#the-strimzikafkaref-case)) |
| `target-policy` | `KafkaProxyNetworkPolicy` | A `KafkaProxyNetworkPolicy` with `spec.egress` set targets it |
| `filter-egress-default` | `KafkaProtocolFilter` | No `KafkaProxyNetworkPolicy` with `spec.egress` set targets it |
| `filter-egress-policy` | `KafkaProxyNetworkPolicy` | A `KafkaProxyNetworkPolicy` with `spec.egress` set targets it |

Since a single `KafkaProxyNetworkPolicy` targeting a `KafkaProtocolFilter` can set both `spec.ingress` and `spec.egress` at once, one CR can drive the generation of two `NetworkPolicy` resources — `filter-ingress-policy.${name}` and `filter-egress-policy.${name}` — both owned by it, both sharing its name, and distinguished from one another by token exactly as the table above already provides for.

This is collision-free **by construction**, not merely unlikely to collide. `.` is reserved as the delimiter between token and name: the CRD schemas for `KafkaProxyIngress`, `KafkaService`, `KafkaProtocolFilter`, and `KafkaProxyNetworkPolicy` forbid `.` in `metadata.name`, and none of the nine tokens above contain `.` either. So every generated name contains exactly one `.`, and two generated names can only be equal if their token and their source name are both equal.

This matters because plain string concatenation, without a reserved delimiter, cannot give that guarantee: a literal `-filter-` infix used to mark filter-related rules is just text, indistinguishable from a hyphen that happens to occur inside a user-chosen name. For example, a `KafkaProxyIngress` named `filter-myfilter` and a `KafkaProtocolFilter` named `myfilter` are different kinds — Kubernetes happily allows both to exist in the same namespace — but concatenating `default-allow-ingress-` with the first name, or `default-allow-ingress-filter-` with the second, produces the identical string either way. The `.` delimiter rules this out, regardless of what the rest of a name contains.

The `-default` tokens cover what might otherwise be described as separate "allow" and "deny" outcomes. That distinction doesn't need to appear in the name: for a given target, `policyAttachment.whenAbsent` (see [`policyAttachment`](#policyattachment)) selects allow *or* deny, never both at once, so there's no risk of the two colliding by sharing a token. The reason is instead recorded as a label:

```yaml
metadata:
  labels:
    kroxylicious.io/default-policy: allow # or: deny
```

This label is present on every `NetworkPolicy` using one of the four `-default` tokens, letting them be selected independent of target kind, e.g. `kubectl get networkpolicy -l kroxylicious.io/default-policy=deny`. It's absent from `-policy` and `target-strimzi` resources, since those aren't driven by `whenAbsent`.

If the computed `${token}.${name}` would exceed Kubernetes' `NetworkPolicy` name length limit, the truncation algorithm defined in https://github.com/kroxylicious/design/pull/150 is applied to the whole string.

### Status conditions

`KafkaProxyNetworkPolicy` reports two standard condition types in `status.conditions`, consistent with the existing `KafkaProxyIngress`/`KafkaService`/`KafkaProtocolFilter` CRs:

| Condition type | Status | Reason | Meaning |
| --- | --- | --- | --- |
| `ResolvedRefs` | `True` | — | `spec.targetRef` resolves to an existing CR of the expected kind, and that CR is itself fully resolved. |
| `ResolvedRefs` | `False` | `ReferencedResourcesNotFound` | No CR named `spec.targetRef.name` of the expected kind exists in this namespace. |
| `ResolvedRefs` | `False` | `TransitivelyReferencedResourcesNotFound` | The targeted CR exists but does not yet report `ResolvedRefs: True` itself (e.g. a targeted `KafkaProxyIngress` whose own `proxyRef` hasn't resolved). |
| `ResolvedRefs` | `Unknown` | — | The last reconciliation attempt failed with an error before refs could be checked. |
| `Accepted` | `True` | — | The policy is valid for its target; a `NetworkPolicy` will be generated from it for each of `spec.ingress`/`spec.egress` that's set. |
| `Accepted` | `False` | `Invalid` | Either a `spec.ingress`/`spec.egress` rule uses a peer type the target's mechanism doesn't allow (see the mechanism-specific sections below for which peer type each requires), or `ResolvedRefs` is `False` — a policy whose target can't be found or hasn't resolved is never `Accepted`, regardless of how valid its own rules are. |
| `Accepted` | `False` | `Disabled` | `NetworkPolicy` generation is disabled cluster-wide via `KafkaProxyOperatorConfig`. `ResolvedRefs` is unaffected and stays `True` in this case. |
| `Accepted` | `False` | `ReferencedResourceNotReconciled` | The targeted CR resolves (`ResolvedRefs: True`) but hasn't itself reached `Accepted: True` yet. |

Note what's *not* in this table: a `spec.ingress` set against a `KafkaService` target, or a `spec.egress` set against a `KafkaProxyIngress` target, never reaches the reconciler at all — it's rejected by the API server at `kubectl apply` time via the CEL rules described in [New CRDs](#new-crds). Only the peer-type-vs-mechanism class of error (which depends on looking up the state of the *targeted* CR, something CEL can't do) surfaces as a reconciler-reported `Accepted: False`/`Invalid`.

Because this validation happens on the reconciler's own schedule rather than at `kubectl apply` time, a `KafkaProxyNetworkPolicy` can be admitted and only later found to be rejected. GitOps/CI pipelines applying these CRs should therefore wait on the `Accepted` condition explicitly, e.g. `kubectl wait --for=condition=Accepted <kind>/<name>`, rather than treating a successful `kubectl apply` as confirmation that the policy took effect.

### Policy attachment to `KafkaProxyIngress`

When no `KafkaProxyNetworkPolicy` with `spec.ingress` set targets a `KafkaProxyIngress`, the `whenAbsent` fallback described under [`policyAttachment`](#policyattachment) applies, generating a `NetworkPolicy` named `ingress-default.${ingress-name}` (see [Naming](#naming)). Here's the `allow` case:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ingress-default.my-loadbalancer-ingress
spec:
  podSelector: ... # see Common structure above
  policyTypes:
    - Ingress
  ingress:
    - ports:
      - protocol: TCP
        port: <PORT_NUM> # for each port
```

When one or more `KafkaProxyNetworkPolicy` with `spec.ingress` set target a given `KafkaProxyIngress` a single `NetworkPolicy` will be generated for each, named `ingress-policy.${policy-name}` (see [Naming](#naming)).
The exact content will depend on the ingress mechanism.
The `KafkaProxyIngress` CR supports three ingress mechanisms:

* `clusterIP` for access from Kafka clients running in the same Kubernetes cluster
* `loadBalancer` for access from Kafka clients running outside the Kubernetes cluster
* `openShiftRoute` for access from Kafka clients running outside the OpenShift cluster

#### The `clusterIP` case

The `clusterIP` mechanism is specifically intended for access from the same Kubernetes cluster, so the rules given by the user in the `from` list of each `spec.ingress[]` entry of a `KafkaProxyNetworkPolicy` must use `namespaceSelector` and/or `podSelector` (see [Status conditions](#status-conditions) for how the operator reports a violation).

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
kind: KafkaProxyNetworkPolicy
metadata:
  name: my-clusterIP-policy
spec:
  targetRef:
    group: kroxylicious.io
    kind: KafkaProxyIngress
    name: my-ingress
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

Those selectors will be copied verbatim to a generated `NetworkPolicy`, so the above example would generate a policy like this:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ingress-policy.my-clusterIP-policy
  namespace: my-proxy
spec:
  podSelector: ... # see Common structure above
  policyTypes:
    - Ingress
  ingress:
    - ports: # the ingress's own listening port, since spec.ingress[].ports was omitted
        - protocol: TCP
          port: <PORT_NUM>
      from: # copied verbatim from spec.ingress[0].from
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

This works the same way, except `loadBalancer` is explicitly intended for off-cluster access, so the `from` list of each `spec.ingress[]` entry must instead use `ipBlock` (the same schema `NetworkPolicy` itself supports):
```yaml
ipBlock:
  cidr: 203.0.113.0/24
```

`Service.spec.loadBalancerSourceRanges` is a best-effort declaration of the source IPs which should be allowed through the load balancer.
In practice enforcement is cloud-provider-dependent, and can be ignored. 

For `loadBalancerSourceRanges` and the pod-level `NetworkPolicy` below to restrict access correctly, the generated `Service` also needs `externalTrafficPolicy: Local`, to preserve the client's source IP address rather than losing it to SNAT.
`KafkaProxyIngress` already supports this via `spec.loadBalancer.service.externalTrafficPolicy` (added by [proposal #134](https://github.com/kroxylicious/design/pull/134)).
The operator should reject a `KafkaProxyNetworkPolicy` with `ipBlock` rules targeting a `loadBalancer` ingress whose `externalTrafficPolicy` isn't `Local` (`Accepted: False`), since otherwise the restriction would silently fail to match real client addresses.

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

With `externalTrafficPolicy: Local` in place the client's source IP address will be preserved and we can use a NetworkPolicy to allow access

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ingress-policy.my-loadbalancer-policy
  namespace: my-proxy
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

Proposal #134 gives each `loadBalancer`-type `KafkaProxyIngress` its own dedicated `Service` so a `KafkaProxyNetworkPolicy`'s CIDRs apply directly to that ingress's own `Service.spec.loadBalancerSourceRanges` and pod-level `NetworkPolicy`, with no cross-ingress CIDR union to construct.

Sharing hasn't disappeared entirely, though: multiple `VirtualKafkaClusters` can still reference the same ingress, addressed by SNI on that ingress's one `Service` — this is what delivers the per-load-balancer cost saving proposal #134 preserves.
A `KafkaProxyNetworkPolicy` targeting that ingress applies uniformly to all of them: a pod-level `NetworkPolicy` can't differentiate traffic by the SNI hostname it arrived on, so there's no way to give one `VirtualKafkaCluster` a narrower CIDR allowlist than another if they share an ingress.
(See [Future work](#future-work) for a possible enhancement that would recover that per-virtual-cluster isolation.)

#### The `openShiftRoute` case

Like `loadBalancer`, `openShiftRoute` is explicitly intended for off-cluster access, so the same `ipBlock` requirement applies to the `from` list of each `spec.ingress[]` entry.

To restrict access by client CIDR with an OpenShift `Route`, we must restrict traffic at the `Route` layer using an annotation, and pair it with a `NetworkPolicy` to restrict `Pod` ingress to only the OpenShift Ingress `Router`.

```yaml
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: my-proxy-cr-my-ingress
  namespace: my-proxy
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
  name: ingress-policy.my-route-policy
  namespace: my-proxy
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


### Policy attachment to `KafkaService`

When no `KafkaProxyNetworkPolicy` with `spec.egress` set targets a `KafkaService` using `bootstrapServers`, the same `whenAbsent` fallback applies, generating a `NetworkPolicy` named `target-default.${kafka-service-name}` (see [Naming](#naming)). (A `KafkaService` using `strimziKafkaRef` is unaffected by this — see [the `strimziKafkaRef` case](#the-strimzikafkaref-case) below.) Here's the `allow` case:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: target-default.my-target-cluster
spec:
  podSelector: ... # see Common structure above
  policyTypes:
    - Egress
  egress:
  - ports:
    - protocol: TCP
```

When one or more `KafkaProxyNetworkPolicy` with `spec.egress` set target a given `KafkaService` a single `NetworkPolicy` will be generated for each, named `target-policy.${policy-name}` (see [Naming](#naming)).

The `KafkaService` CR supports two ways to express a target cluster:

* `strimziKafkaRef` is a reference to a Strimzi `Kafka` resource which exists in the same cluster as the `KafkaService` CR.
* `bootstrapServers` is a comma-separated list of the host addresses for some bootstrap servers of a Kafka cluster.


#### The `strimziKafkaRef` case

`strimziKafkaRef` is a very special case. 
We already know the namespace of the `Kafka` cluster, and the `Pod` labels (and hence selectors) are a published part of the Strimzi API. 
So the operator can always compute the exact egress rule itself, without needing a `spec.egress` list — or indeed any `KafkaProxyNetworkPolicy` at all — from the user.
It does so unconditionally: this is the one case in this proposal where neither `allow`-everywhere nor `deny`-everything is the right default, because a precise, correct answer is already available for free, so `policyAttachment`'s `whenAbsent` setting doesn't apply here.

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
```

That alone, with no `KafkaProxyNetworkPolicy` at all, generates a `NetworkPolicy` named `target-strimzi.${kafka-service-name}` (see [Naming](#naming)):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: target-strimzi.strimzi-target
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

A `KafkaProxyNetworkPolicy` with `spec.egress` set can still be attached to a `strimziKafkaRef`-based `KafkaService` if needed — for example to grant egress to some additional destination beyond the Strimzi brokers themselves. Its rules are additive with the auto-derived rule above (see [Current situation](#current-situation)), rather than replacing it. The same additivity applies across *other* targets on the same proxy, not just within this one — see [`podSelector`](#podselector) for why a precise rule like this one offers no enforcement guarantee if a sibling `KafkaService` on the same `KafkaProxy` ends up with a broader rule on the same port.

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

When the bootstrap servers list is entirely composed of internal DNS names the `to` property of each `spec.egress[]` entry will be required to use `namespaceSelector` and/or `podSelector` rules.

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
kind: KafkaProxyNetworkPolicy
metadata:
  name: my-strimzi-target
spec:
  targetRef:
    group: kroxylicious.io
    kind: KafkaService
    name: internal-dns
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: my-ns
```

##### External DNS names and external IP addresses

When the bootstrap servers list is entirely composed of external DNS names and/or external IP addresses the `to` property of each `spec.egress[]` entry will be required to use `ipBlock` rules.

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
kind: KafkaProxyNetworkPolicy
metadata:
  name: my-strimzi-target
spec:
  targetRef:
    group: kroxylicious.io
    kind: KafkaService
    name: internal-dns
  egress:
    - to:
        - ipBlock:
            cidr: 10.0.23.0/24
```

### Policy attachment to `KafkaProtocolFilter`

The `KafkaProtocolFilter` CR is used to configure filters. 
It is common for filters, or their plugins, to require network egress.
It's also not forbidden for filters to require network ingress.
In the most general case, a filter or its plugin would require rules for both egress and ingress. A single `KafkaProxyNetworkPolicy` can set both `spec.ingress` and `spec.egress` against the same `KafkaProtocolFilter` target, generating two `NetworkPolicy` resources — one per direction (see [Naming](#naming)) — from that one CR. Because rules are additive (see [Current situation](#current-situation)), a filter's ingress and egress needs can equally be declared across two separate `KafkaProxyNetworkPolicy` CRs instead, e.g. for clearer auditing, or because different owners manage the filter's inbound and outbound needs. That choice doesn't affect what's enforced, only how the rules are organized and named — it has no RBAC consequence, since both directions share the same kind regardless (see [Rejected alternatives](#rejected-alternatives)).

When no `KafkaProxyNetworkPolicy` targets a `KafkaProtocolFilter` with a given direction set, the same `whenAbsent` fallback applies per direction, generating a `NetworkPolicy` named `filter-ingress-default.${kafka-filter-name}` and/or `filter-egress-default.${kafka-filter-name}` (see [Naming](#naming)). Unlike `KafkaProxyIngress`/`KafkaService`, which always need *some* access just to function, a `KafkaProtocolFilter` may need none at all — but the same `allow`/`deny` choice and reasoning (see [`policyAttachment`](#policyattachment)) applies regardless.

When a `KafkaProxyNetworkPolicy` targets a given `KafkaProtocolFilter` with `spec.ingress` and/or `spec.egress` set, a `NetworkPolicy` will be generated for each direction present, in the same way as for `KafkaProxyIngress` and `KafkaService` above, named `filter-ingress-policy.${policy-name}` and/or `filter-egress-policy.${policy-name}` respectively (see [Naming](#naming)).

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
kind: KafkaProxyNetworkPolicy
metadata:
  name: encryption-connect-to-vault
spec:
  targetRef:
    group: kroxylicious.io
    kind: KafkaProtocolFilter
    name: encryption
  egress:
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
  name: filter-egress-policy.encryption-connect-to-vault
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


### Operator RBAC changes

The operator will need to be allowed to CRUD `NetworkPolicy` resources via its dependent resources `ClusterRole`.

It will also need `watch`, `get`, `list`, `patch`, `update` (+ `/status`) on `KafkaProxyNetworkPolicy` and `KafkaProxyOperatorConfig` in the "watched resources" `ClusterRole`.

### Future work

As a possible future development, we could add an IP-allowlist capability enforced in the proxy itself, and have the operator feed that with the ipBlock rules from the `KafkaProxyNetworkPolicy`.
Crucially this could be done once the SNI host name is known, thus recovering the per-virtual-cluster isolation that `Service`-level CIDR restriction cannot provide when multiple `VirtualKafkaClusters` share one ingress's `Service` (see [the `loadBalancer` case](#the-loadbalancer-case)).

[Proposal #148](https://github.com/kroxylicious/design/pull/148) is pursuing per-gateway source-address allow/deny filtering in the proxy application itself. Should that land, `KafkaProxyOperatorConfig.spec.clusterCIDRs` would gain a second consumer: seeding a default "cluster-local only" source filter for `clusterIP`-mechanism gateways, alongside its existing use validating `KafkaService.spec.bootstrapServers`.

## Affected/not affected projects

This affects the `kroxylicious/kroxylicious` repo. 

## Compatibility

The proposed changes are backwards compatible, because the `NetworkPolicies` generated in the absence of `KafkaProxyNetworkPolicy` are default allow.
If, due to a bug, the generated policies prevented connections, the user would be able to work around it by setting `KafkaProxyOperatorConfig.spec.generation: disabled`.

This also holds for the `allow`/`deny` choice on `KafkaProxyIngress`, `KafkaService`, and `KafkaProtocolFilter` (`policyAttachment.policyTarget[].permittedAttachments[].whenAbsent`, see [`policyAttachment`](#policyattachment)): `allow` is the schema default for every install, fresh or upgraded, so adopting this feature never locks out traffic a target was previously relying on. `deny` remains available, but only ever as an explicit administrator choice.

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
* "Split ingress and egress into two kinds (`KafkaProxyIngressNetworkPolicy` and `KafkaProxyEgressNetworkPolicy`), rather than a single combined `KafkaProxyNetworkPolicy` kind."
    - An earlier revision of this proposal did this. The argument was that a single kind can only be granted or withheld as a whole via Kubernetes RBAC, which is enforced per-kind, not per spec-field or per-`targetRef`: in a namespace with one shared `KafkaProxyIngress` and several independently-owned `KafkaProtocolFilter`s, a role trusted to declare a single filter's own egress need (e.g. "reach Vault on port 8200") would, by that same RBAC grant, also be able to declare an allow-from-anywhere ingress rule against the shared `KafkaProxyIngress`, affecting every tenant of that proxy. Splitting by direction was meant to give RBAC a meaningful boundary to grant against.
    - On closer inspection that boundary was weaker than it looked. Each of the two kinds still mixed one shared, proxy-wide target with per-filter ownership: `KafkaProxyIngressNetworkPolicy` could target either the shared `KafkaProxyIngress` *or* a `KafkaProtocolFilter`'s own ingress need, and `KafkaProxyEgressNetworkPolicy` could likewise target either the shared `KafkaService` *or* a `KafkaProtocolFilter`'s own egress need. So a role trusted only for a filter's own egress could, via that same kind, still rewrite the shared `KafkaService`'s bulk egress rule — the identical cross-contamination pattern the split was meant to prevent, just confined to one direction instead of two. Splitting by direction only ever removed the ingress↔egress straddle, never the shared-target↔filter straddle; the latter is the residual coarseness the next bullet discusses.
    - Given that the RBAC benefit was partial rather than complete, it didn't justify doubling the CRD/controller/status-machinery/RBAC/documentation surface (two reconciled kinds instead of one) to get it. A single kind, with the `targetRef.kind`/direction combinations it allows narrowed by CEL validation instead of by which kind exists, gets equivalent functional behaviour for substantially less ongoing engineering cost.
    - Organizations that do need finer-than-kind-level separation — including the specific ingress-exposure-vs-filter-egress separation this alternative was trying to buy — can get it from a policy engine (Kyverno, OPA Gatekeeper, or a `ValidatingAdmissionPolicy` bound to the requester's identity) layered on top of the single kind, restricting which `targetRef.kind`/field combinations a given identity may submit. Kubernetes' native RBAC was never going to offer a unit of control finer than "kind" (short of an unwieldy, manually-maintained `resourceNames` allowlist per tenant), so reaching for more CRDs to simulate field-level RBAC was solving the problem at the wrong layer.
* "Use one kind per target CR (`KafkaProxyIngress`, `KafkaService`, `KafkaProtocolFilter`), rather than a single combined kind."
    - This is the most granular option: it would let an organization separate "who sets the proxy's ingress exposure," "who sets its egress to the real cluster," and "who sets a given filter's needs" into three distinct RBAC-governed roles — the one separation a single combined kind doesn't give you.
    - Rejected for the same reason the two-kind split above was reverted to one: more CRDs/controllers/RBAC surface than the problem calls for, for a form of separation a policy engine can already provide on top of a single kind (see previous bullet). If finer separation turns out to matter in practice despite that option being available, this remains the fallback to revisit.
* "Use a hash suffix (extending proposal #150's truncation mechanism) to avoid name collisions between generated `NetworkPolicy` resources, rather than a reserved delimiter."
    - This would avoid needing new CRD-level validation forbidding `.` in the names of the four source kinds (see [Naming](#naming)).
    - However it only makes collisions vanishingly unlikely, not impossible, reintroducing exactly the kind of small-but-nonzero risk proposal #150 already accepts for the (much rarer) long-name case. Since the naming scheme also has to double as a human-auditable identifier, the one-off cost of a single extra CRD validation rule was judged worth paying for an actual guarantee instead.
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
* "Default `policyAttachment.permittedAttachments[].whenAbsent` to `deny` for genuinely fresh installs while existing installs keep `allow` — whether by having the operator apply this itself via a first-run heuristic (e.g. no `KafkaProxyOperatorConfig` and no `KafkaProxy` resources exist yet), or by seeding a `deny`-default `KafkaProxyOperatorConfig` through install-time tooling (an OLM `ClusterServiceVersion` `initialization-resource`/`alm-examples` annotation, a Helm hook, or a bundled manifest)."
    - A secure-by-default `deny` sounds like the right call, but it raises the bar to getting a working proxy: a fresh `KafkaProxy` would pass no traffic at all until the right `KafkaProxyNetworkPolicy` CRs exist, and every quickstart or example manifest targeting such an install would need to ship them too — otherwise a new user's first experience is a proxy that clearly reports why it isn't working, but still doesn't work. We decided the better trade-off is `allow` everywhere, with the generated policies' descriptive naming and `kroxylicious.io/default-policy` label (see [Naming](#naming)) giving administrators the audit trail to find and tighten `allow` rules on their own schedule, rather than forcing that decision on day one.
    - The install-tooling route would also have been awkward to implement consistently, which was a further reason not to go there: `KafkaProxyOperatorConfig` is a brand-new CRD, so its absence looks identical on a genuinely fresh install and on an existing deployment upgrading to a version with this feature — install-tooling can't distinguish those two cases from that signal alone. Helm's `pre-install` hooks (which fire only on `helm install`, not `helm upgrade`) could have worked for Helm specifically, but OLM's `ClusterServiceVersion` has no equivalent "only on first install" concept, so the two install paths would have behaved inconsistently. An operator-side first-run heuristic could have told the two cases apart reliably where install-tooling couldn't — but since we rejected the underlying goal, there was no reason to build it either.
