# Proposal 134 - Configuring the shared LoadBalancer Service from KafkaProxyIngress

> **DRAFT for discussion.**
> The direction described here (implicit grouping) has been proposed on
> [kroxylicious/kroxylicious#4161](https://github.com/kroxylicious/kroxylicious/issues/4161)
> but is **not yet agreed by maintainers**.

This proposal adds the ability to configure the shared LoadBalancer Service
from `KafkaProxyIngress`. It does so by partitioning LoadBalancer ingresses on
a proxy into groups by their Service-level configuration —
`externalTrafficPolicy`, `allocateLoadBalancerNodePorts`, and
`infrastructure.annotations` — and materialising one Service per group.
Ingresses wanting the same infrastructure continue to share a load balancer
while ingresses wanting different infrastructure get their own.

## Current situation

`ClusterServiceDependentResource` builds exactly one `type: LoadBalancer`
Service per `KafkaProxy`, named `<proxy>-sni`, in `sniLoadbalancerServices()`.
That Service is shared by every LoadBalancer ingress on the proxy because cloud
providers charge a standing fee per load balancer, so coalescing many ingresses
onto one Service saves money. Ports are aggregated across all of them; bootstrap
addresses are aggregated into a single `kroxylicious.io/bootstrap-servers`
annotation.

`LoadBalancerClusterIngressNetworkingModel.services()` returns `Stream.empty()`
— it owns no Service of its own. It contributes to the shared one through
`SharedLoadBalancerServiceRequirements`, whose entire surface is
`requiredClientFacingPorts()` and `bootstrapServersToAnnotate()`.

Every SNI Service port targets `SHARED_SNI_PORT` (9291) on the proxy pod;
routing is by SNI hostname via `SniHostIdentifiesNodeIdentificationStrategy`.
`requiredClientFacingPorts()` returns a constant (`DEFAULT_CLIENT_FACING_LOADBALANCER_PORT`,
9083) for every LoadBalancer ingress, so the Service has a single port today.

There is no way to set `externalTrafficPolicy` or
`allocateLoadBalancerNodePorts` on that Service.

`KafkaProxyIngress.spec.infrastructure.annotations` exists, but
`applyInfrastructureAnnotations` is called only by the Route model and both
ClusterIP models (`TlsClusterIPClusterIngressNetworkingModel`,
`TcpClusterIPClusterIngressNetworkingModel`). `sniLoadbalancerServiceMetadata()`
takes only the `KafkaProxy` primary and never sees an ingress, so annotations
cannot reach the shared Service by any path.

Users need a declarative, GitOps-style workflow where the system is fully
specified in YAML and applied in one step. Having to apply the CRs, wait for
the generated Services to appear, and then patch them separately is not an
acceptable workflow.

## Motivation

Two open issues, both blocked on the same missing mechanism:

- [kroxylicious/kroxylicious#4161](https://github.com/kroxylicious/kroxylicious/issues/4161)
  — on-premises users need `externalTrafficPolicy` (client source-IP
  preservation) and `allocateLoadBalancerNodePorts` (NodePort ranges are
  constrained on-prem, and some LB implementations route directly to pods so
  NodePorts are waste and unnecessary listening ports on every node are
  additional attack surface that has to be defended and monitored).
- [kroxylicious/kroxylicious#4838](https://github.com/kroxylicious/kroxylicious/issues/4838)
  — an EKS user cannot attach specific security groups, so the controller
  auto-creates one, which is unacceptable in a regulated environment.

The CRD schema for `infrastructure.annotations` says annotations are applied to
"Services and Routes created for this KafkaProxyIngress" with no LoadBalancer
exclusion, and cites AWS Load Balancer Controller annotations as the motivating
example — annotations only meaningful on a `type: LoadBalancer` Service. This
is a documented contract not currently met.

## Proposal

### API

Add to `KafkaProxyIngress`:

```yaml
spec:
  loadBalancer:
    service:
      externalTrafficPolicy: Local             # enum: Cluster | Local
      allocateLoadBalancerNodePorts: false     # boolean
```

Both fields are optional. They are nested under `spec.loadBalancer.service` so
the existing `oneOf` on `spec` rejects them on ClusterIP and Route ingresses
without needing a CEL rule.

No schema `default:` on `externalTrafficPolicy` — a default would cause the API
server to materialise `Cluster` onto every existing resource on its next write.

### Implicit grouping

The operator partitions LoadBalancer ingresses on a proxy into groups by a
group key, and creates one LoadBalancer Service per group. Ingresses wanting the
same infrastructure share a load balancer, preserving the per-load-balancer cost
saving that motivated sharing in the first place; ingresses wanting different
infrastructure get their own.

Group key: `(externalTrafficPolicy, allocateLoadBalancerNodePorts,
infrastructure.annotations)`, normalised.

### Scoping rule for future fields

> Fields that affect the configuration or behaviour of the generated shared
> LoadBalancer Service are part of the grouping identity.

The exception is fields that **aggregate** across ingresses — these do not
contribute to the group key. Ports already work this way (several ports coexist
on one load balancer), as do bootstrap-server annotation entries. The test is
whether a field is single-valued on the Service (disagreement is unresolvable,
so it partitions) or additive (contributions coexist, so it aggregates).

### Why annotations partition rather than merge

On the shared Service there is no such thing as a per-ingress annotation — the
Service IS the load balancer, so every annotation on it configures the whole
load balancer. If one ingress wants `aws-load-balancer-internal: "true"` and
another wants `internet-facing`, any merged map satisfies neither. There is no
correct merge, because the resource can hold only one configuration.

`kroxylicious.io/`-prefixed keys remain reserved (already enforced by a CEL
rule on the CRD) and operator-managed annotations retain precedence, unchanged
from the ClusterIP and Route behaviour. In practice this means ingresses must
have identical `infrastructure.annotations` in order to share a load balancer.

### Normalisation

The key must be canonicalised before hashing. `allocateLoadBalancerNodePorts:
true` is semantically identical to leaving it unset; hashed raw they differ, so
setting a field to the value it already had would provision a new load balancer.
Normalise to semantic values so explicit-default and unset produce the same key.

### Service naming

- `<proxy>-sni-<hash>`, where hash is SHA-256 over the canonical serialisation,
  truncated and base32-encoded (lowercase, DNS-label safe), ~10 characters
  (50 bits — collisions unreachable at any plausible number of groups).
- The group whose normalised key is **empty** is named `<proxy>-sni`, so
  existing deployments whose LoadBalancer ingresses declare no
  `infrastructure.annotations` are unaffected by operator upgrade. However,
  users who already declare `infrastructure.annotations` on a LoadBalancer
  ingress (currently silently ignored — and shown as an example in the operator
  docs) would have a non-empty key after upgrade, causing the Service to be
  renamed and the load balancer replaced. How to make upgrade inert for those
  users is under discussion on this review; adoption of existing Services by
  recorded membership is the leading option. **PENDING.**
- The canonical encoding must be unambiguous so that distinct configs (e.g.
  `{"ab": "c"}` vs `{"a": "bc"}`) cannot produce the same digest input. This
  is met by sorting annotation keys, normalising values, length-prefixing each
  element, and feeding elements incrementally to
  `java.security.MessageDigest#update` — no separator character is needed.
- Under config-derived naming, any change to the canonicalisation format renames
  every Service in every cluster at once, replacing every load balancer with no
  config change. Whether this constraint applies depends on the naming decision
  under discussion — it disappears under membership-based adoption. **PENDING.**
- The hash is computed over `(proxy name, canonical config)` rather than config
  alone, so it disambiguates across proxies in the same namespace as well as
  across groups. Service names must be unique per namespace and a namespace may
  contain several `KafkaProxy` resources, which is why the proxy name must be in
  the hash input. When `<proxy>-sni-<hash>` would exceed 63 characters the proxy
  portion is truncated, which is safe because the hash guarantees uniqueness.

### Behaviour when configuration changes

- **Target config already has a Service and the old group retains other members**
  → two annotation patches; nothing created or deleted; the ingress moves onto
  an existing load balancer.
- **Old group is left empty** → its Service drops out of the desired set and
  that load balancer is destroyed.
- **Target config is one no group has yet** → a Service is created and a load
  balancer provisions.

In all cases the edited ingress ends up behind a different load balancer at a
different address, and `loadBalancerIngressPoints` changes accordingly. Small
setups are the exposed ones: an ingress that is the only member of its group
hits create-and-delete on every edit, while a group with several members is only
patched.

`BulkDependentResourceReconciler.reconcile()` in JOSDK 5.5.1 calls
`deleteExtraResources()` first, then iterates `desiredResources`, sequentially,
with no readiness gate. A rename is therefore delete-then-create: the old cloud
load balancer is destroyed before the replacement begins provisioning, so a
rename is a guaranteed outage for the affected ingress for the duration of cloud
provisioning.

### Status

Add an optional `ingressResource` object to
`VirtualKafkaCluster.status.ingresses[]`:

```yaml
ingressResource:
  group: ""
  kind: Service
  name: myproxy-sni-a1b2c3d4e5
```

This points at whatever Kubernetes resource is exposing that ingress — a Service
for LoadBalancer and ClusterIP, a Route for OpenShift — so it works for all
ingress types, not just Services, and lets tooling walk from a VKC to the
resource exposing it. `buildStatusIngress` already holds the `Service`, so the
Service case is cheap.

`loadBalancerIngressPoints` mirrors the Service's `status.loadBalancer.ingress`
entries (IP for GCE-style, hostname for AWS-style) into `VirtualKafkaCluster`
status so clients can find the external address. It is how an address change
becomes visible to users.

### Implementation outline

- **`sniLoadbalancerServices()`** — partition models by normalised key, one
  Service per group.
- **`getLoadBalancerServiceBootstrapServers()`** — per-group annotation sets
  rather than one aggregate.
- **`VirtualKafkaClusterPrimaryToKubernetesServiceSecondaryMapper`** — currently
  hardcodes `proxyRef + "-sni"`, so it would not find hash-named Services.
- **`SharedLoadBalancerServiceRequirements`** — carry the config and annotations
  so the planner can group on them.

`ClusterServiceDependentResource` is already a
`BulkDependentResource<Service, KafkaProxy, String>` with `desiredResources()`,
`getSecondaryResources()` and `deleteTargetResource()` implemented, so emitting
N Services and cleaning up emptied groups needs no new machinery.

Two things need **no** work:

- `buildIngressStatus` matches Services on the `(clusterName, ingressName)`
  pair read from the bootstrap annotation rather than by name.
- `KubernetesServicesSecondaryToVirtualKafkaClusterPrimaryMapper` works off
  owner references.

One invariant the implementation must maintain: the bootstrap-servers
annotations must form a strict partition across Services.
`ClusterIngressBootstrapServers` is `(clusterName, ingressName,
bootstrapServers)` with nothing preventing two Services claiming the same pair,
and the lookup is a `findFirst()` over an unordered `Set`. A leak means status
picks an arbitrary Service and can flip between reconciliations. It also occurs
transiently during migration, since removing an entry from one Service and
adding it to another is not atomic.

### Testing

- **Unit:** canonicalisation, hashing determinism and order-independence,
  grouping.
- **Integration:** generated Service manifests per group; upgrade path asserting
  the empty-key group keeps `<proxy>-sni`.
- **System:** the expected number of Services is created per group, each with
  the correct spec fields and annotations, and the bootstrap-servers annotations
  form a strict partition across Services.
- CI runs Minikube with the docker driver and no tunnel or MetalLB, so
  LoadBalancer Services stay Pending and real load balancer behaviour cannot be
  verified. Coverage is at the generated-manifest level.

## Affected/not affected projects

**Affected:**

- `kroxylicious-kubernetes-api` — CRD schemas and generated types.
- `kroxylicious-operator` — Service planning, naming, status reporting.

**Not affected:**

- The proxy runtime and its configuration.
- `ProxyDeploymentDependentResource` — it adds `SHARED_SNI_PORT` once,
  conditionally, and never sees Services.
- ClusterIP and Route ingress paths.
- The admission webhook.

This proposal also resolves
[kroxylicious/kroxylicious#4838](https://github.com/kroxylicious/kroxylicious/issues/4838),
since the annotations gap requires the same mechanism.

## Compatibility

- All new fields are optional and additive to `v1alpha1`; existing resources
  stay valid.
- Operator upgrade is a no-op for users whose LoadBalancer ingresses declare no
  `infrastructure.annotations`, via the empty-key naming rule. For users who
  already declare `infrastructure.annotations` on a LoadBalancer ingress
  (currently silently ignored), upgrade would rename the Service and replace the
  load balancer. How to make upgrade inert for those users is under discussion;
  adoption of existing Services by recorded membership is the leading option.
  **PENDING.**
- One-time migration when a user first adopts these fields: their ingress leaves
  the default group, so the Service is renamed and the load balancer replaced
  once. For example, a user who today has an unconfigured `<proxy>-sni` load
  balancer and then adds `infrastructure.annotations` (the
  [#4838](https://github.com/kroxylicious/kroxylicious/issues/4838) scenario)
  moves out of the empty-key default group, causing the Service to be renamed
  and the cloud load balancer replaced with a new address.
- Under config-derived naming, the hash format is frozen once shipped (see
  Service naming). Whether this constraint applies depends on the naming
  decision under discussion. **PENDING.**
- Future Service-level fields are governed by the scoping rule rather than
  case-by-case decisions.

## Rejected alternatives

1. **Fields on `KafkaProxy`.** The proxy owns the Service, so no conflict is
   possible — but networking configuration belongs where users look for it, and
   maintainers steered towards `KafkaProxyIngress` on
   [#4161](https://github.com/kroxylicious/kroxylicious/issues/4161).

2. **An agreement/conflict rule with rejection.** Originally proposed: define
   voting semantics, reject disagreeing ingresses, report via status. Superseded
   by grouping, which makes conflict impossible rather than resolving it. Would
   also have required new plumbing, since `ProxyConfigStateData` is keyed only
   by cluster and `KafkaProxyIngress` status is owned by a reconciler with no
   sibling visibility.

3. **Explicit grouping** — an optional `group:` field naming the group, Service
   named after it. Gives stable identity, in-place patches on edit, and visible
   cost. This draft proposes implicit grouping instead because it is the more
   reversible choice: `group:` can be added later as an optional override if
   the address change on edit proves painful, but a grouping concept users have
   adopted cannot be removed. The implicit-vs-explicit decision is pending the
   discussion requested on
   [#4161](https://github.com/kroxylicious/kroxylicious/issues/4161). Both
   shapes were considered: config alongside the group name on the ingress, and
   the group declared once on `KafkaProxy` with ingresses referencing it.

4. **Merging annotations within a group.** Semantically wrong — the Service IS
   the load balancer, so every annotation configures the whole load balancer.
   Merging maps from ingresses that disagree satisfies neither.

5. **Classifying annotation keys** so behaviour-defining ones join the key and
   incidental ones do not. Requires provider-specific knowledge Kroxylicious
   does not have, goes stale as providers add keys, and misclassification either
   rejects a valid manifest or silently merges something that should not be.

6. **Names from a sorted index** (`-0`, `-1`) — deterministic but renumbers
   existing groups when a new one is added. **Names from member ingresses** —
   membership changes on every edit, and length is unbounded against the 63-char
   limit.

7. **CRC32 via the existing `Crc32ChecksumGenerator`.** That class exists to
   detect change in referenced resources, where a collision means one missed
   update that self-corrects. Here the hash is an identity and a collision means
   two configs permanently sharing a load balancer.

8. **A LoadBalancer Service per ingress unconditionally.** Simplest, but
   discards the per-load-balancer cost saving described in Current situation.

## Open questions

- **Service naming approach:** config-derived hash (as currently described) vs
  adoption by recorded membership. Under config-derived hashing, names are
  deterministic but any change to the canonicalisation format renames every
  Service; under membership-based adoption, names are stable across config
  changes but require persisted state recording which ingresses belong to which
  Service.
- Whether status should report a condition during migration while
  `loadBalancerIngressPoints` is empty.
