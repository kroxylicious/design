# Proposal 134 - Configuring the LoadBalancer Service from KafkaProxyIngress

This proposal lets a `KafkaProxyIngress` configure the LoadBalancer Service
that serves it, by giving each `loadBalancer` ingress its own Service. Clusters
sharing an ingress share its load balancer; different infrastructure means a
different ingress.

## Current situation

`ClusterServiceDependentResource` builds exactly one `type: LoadBalancer`
Service per `KafkaProxy`, named `<proxy>-sni`, in `sniLoadbalancerServices()`.
That Service is shared by every LoadBalancer ingress on the proxy because AWS
charges a standing fee per load balancer (and other providers may do likewise),
so coalescing many ingresses onto one Service saves money. Ports are aggregated across all of them; bootstrap
addresses are aggregated into a single `kroxylicious.io/bootstrap-servers`
annotation.

`LoadBalancerClusterIngressNetworkingModel.services()` returns `Stream.empty()`
— it owns no Service of its own. It contributes to the shared one through
`SharedLoadBalancerServiceRequirements`, whose entire surface is
`requiredClientFacingPorts()` and `bootstrapServersToAnnotate()`. The
LoadBalancer model is the odd one out — `TcpClusterIPClusterIngressNetworkingModel`,
`TlsClusterIPClusterIngressNetworkingModel` and the Route model each own the
Services they need, while `LoadBalancerClusterIngressNetworkingModel` defers to
a per-proxy shared Service.

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

The operator uses server-side apply, so it only owns the fields it sets, and
hand-applied edits to other fields do survive reconciliation. That still is not
a solution: users need a declarative, GitOps-style workflow where the system is
fully specified in YAML and applied in one step. Having to apply the CRs, wait
for the generated Services to appear, and then patch them separately is not an
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
  — an AWS EKS user cannot attach specific security groups, so the controller
  auto-creates one, which is unacceptable in a regulated environment.

The CRD schema for `infrastructure.annotations` says annotations are applied to
"Services and Routes created for this KafkaProxyIngress" with no LoadBalancer
exclusion, and cites AWS Load Balancer Controller annotations as the motivating
example — annotations only meaningful on a `type: LoadBalancer` Service. This
is a documented contract not currently met.

Gateway API treats infrastructure as an explicit named resource with sharing by
reference. This proposal follows the same principle.

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

Both fields are optional, nested under `spec.loadBalancer.service`.

No schema `default:` on `externalTrafficPolicy` — a default would cause the API
server to materialise `Cluster` onto every existing resource on its next write.

### Model

Each `KafkaProxyIngress` of type `loadBalancer` materialises exactly one
`type: LoadBalancer` Service.

Sharing across `VirtualKafkaClusters` is unchanged: every VKC referencing that
ingress shares its Service, addressed by SNI, with per-cluster addresses
produced by the `$(virtualClusterName)` token in `bootstrapAddress` (see
`LoadBalancerClusterIngressNetworkingModel`, which substitutes it). This is the
sharing that delivers the per-load-balancer cost saving, and it is preserved.

Users who need different infrastructure — a different `externalTrafficPolicy`,
`allocateLoadBalancerNodePorts`, or annotations — create a different
`KafkaProxyIngress`. Infrastructure is an explicit resource; sharing is by
reference. This follows the Gateway API principle.

The LoadBalancer model becomes consistent with its siblings. One deliberate
difference remains: ClusterIP and Route Services are per `(cluster, ingress)` —
named `<cluster>-<ingress>-bootstrap` — while the LoadBalancer Service is per
ingress, because SNI lets one Service serve many clusters.

The existing `loadBalancerIngressPoints` status field is populated from the
ingress's own Service.

### Service naming

Name: `<ingress>-sni` (`KafkaProxyIngress` name plus the `-sni` suffix).
Unique because `KafkaProxyIngress` names are unique within a namespace, and
each ingress references exactly one proxy. No hash, no canonicalisation.

Identity is stable by construction: the name derives from the ingress name,
which is the ingress's identity. Editing any field patches the Service in
place; the Service is never renamed.

Length: the `KafkaProxyIngress` name must leave room for the `-sni` suffix
within the 63-character Service name limit. How to handle an existing
`loadBalancer` ingress whose name is already too long is an open question — a
CEL rule would be breaking, truncation loses the uniqueness guarantee, and a
status condition is probably the right approach.

### Annotations

`infrastructure.annotations` apply to the ingress's Service through the
existing `applyInfrastructureAnnotations` path, exactly as they do for ClusterIP
and Route today. Because a Service serves one ingress, there is no merge and no
partition question. The reserved `kroxylicious.io/` prefix and operator-wins
precedence are unchanged.

### Behaviour when configuration changes

Editing `externalTrafficPolicy`, `allocateLoadBalancerNodePorts` or
`infrastructure.annotations` on an ingress patches its Service in place.
Address unchanged. No outage.

Changing a `VirtualKafkaCluster`'s `ingressRef` moves that cluster between
Services: its bootstrap entry leaves one Service's
`kroxylicious.io/bootstrap-servers` annotation and joins another's, and its
address changes. The two patches are separate API calls, so `buildIngressStatus`
(`findFirst` over an unordered `Set`) may briefly report either; self-corrects
on the next reconcile.

`allocateLoadBalancerNodePorts`: Kubernetes only honours this field at
allocation time, so flipping `true` to `false` on a live Service leaves
existing NodePorts allocated. The operator should clear `spec.ports[].nodePort`
when the field transitions to `false`. This needs maintainer confirmation.

### Migration from the shared Service

Today every LoadBalancer ingress on a proxy shares `<proxy>-sni`. Renaming it
is delete-then-create (`BulkDependentResourceReconciler.reconcile()` in JOSDK
5.5.1 calls `deleteExtraResources()` before creating, with no readiness gate),
which is an outage for the length of cloud provisioning. So upgrade must not
rename.

The new operator labels every LoadBalancer Service it creates (see
Implementation outline). The legacy Service `<proxy>-sni` was created by an
older operator and therefore does not carry this label. Its absence is the
legacy marker.

Proposed rule:

- On reconcile, if a Service named `<proxy>-sni` exists, is owned by the
  proxy, and lacks the LoadBalancer label, it is a legacy Service.
- If the proxy has exactly one `loadBalancer` ingress, that ingress adopts
  `<proxy>-sni` permanently: the Service is patched (gaining the label), not
  replaced. Upgrade is a no-op for this case, which is expected to be the
  overwhelming majority.
- If the proxy has several `loadBalancer` ingresses, one adopts `<proxy>-sni`
  — prefer an ingress whose natural name `<ingress>-sni` already equals
  `<proxy>-sni` if one exists, otherwise the lexicographically smallest
  ingress name — and the rest get new `<ingress>-sni` Services.
- Once adopted, the Service carries the label and is no longer legacy, so the
  rule never fires again. Ingresses added later cannot change the assignment.

The alternative — accept the rename with a release note — was rejected because
the outage is avoidable. A Service retaining its existing name is not a problem
in itself, and avoiding the rename avoids an outage.

### Implementation outline

- **`sniLoadbalancerServices()`** — group the LoadBalancer networking models by
  ingress (not all together), emit one Service per ingress with that ingress's
  ports, bootstrap entries and infrastructure annotations. Apply the legacy
  naming rule.
- **`SharedLoadBalancerServiceRequirements`** — its sharing scope narrows from
  per-proxy to per-ingress; it must expose the ingress's Service-level config
  and annotations. Alternatively, fold it into the model — leave that to
  implementation.
- **`getLoadBalancerServiceBootstrapServers()`** — per-ingress rather than one
  aggregate.
- **`VirtualKafkaClusterPrimaryToKubernetesServiceSecondaryMapper`** — currently
  hardcodes `proxyRef + "-sni"`; must compute `<ingress>-sni` per referenced
  ingress, plus the legacy name.

`ClusterServiceDependentResource` is already a
`BulkDependentResource<Service, KafkaProxy, String>` with `desiredResources()`,
`getSecondaryResources()` and `deleteTargetResource()` implemented, so emitting
N Services and cleanup need no new machinery.

The operator should label the LoadBalancer Services it creates so they can be
identified as a set. `Labels.standardLabels(proxy)` currently returns four
labels (`app.kubernetes.io/managed-by`, `name`, `component=proxy`,
`instance=<proxy>`) and is applied identically to the SNI Service and the
per-cluster ClusterIP Services, so nothing distinguishes a LoadBalancer Service
today. Since `getSecondaryResources` returns every Service owned by the proxy,
a label is what lets the code reason about the LoadBalancer subset without
inferring from names. The exact label key is left to implementation; it must be
under a `kroxylicious.io/` or `app.kubernetes.io/` prefix consistent with
existing labels. The set-difference reconcile loop is already provided by
`BulkDependentResource` (`getSecondaryResources` plus `deleteExtraResources` in
JOSDK), so the label is the addition, not the loop.

Two things need **no** work:

- `buildIngressStatus` matches Services on the `(clusterName, ingressName)`
  pair read from the bootstrap annotation rather than by name.
- `KubernetesServicesSecondaryToVirtualKafkaClusterPrimaryMapper` works off
  owner references.

The cross-Service strict-partition invariant from the earlier grouping design is
no longer a design concern — it holds trivially since each Service serves one
ingress.

### Testing

- **Unit:** per-ingress Service generation; legacy naming rule (single ingress
  keeps `<proxy>-sni`; multiple ingresses produce a deterministic choice);
  adding a smaller-named ingress to a proxy that has an adopted legacy Service
  does not rename it.
- **Integration:** config edit is an in-place patch with the Service name
  unchanged; upgrade from a `<proxy>-sni` deployment keeps the Service;
  annotations reach the Service.
- **System:** expected number of Services per proxy with correct spec fields
  and annotations.
- CI runs Minikube with the docker driver and no tunnel or MetalLB, so
  LoadBalancer Services stay Pending and real load balancer behaviour cannot be
  verified.

## Affected/not affected projects

**Affected:**

- `kroxylicious-kubernetes-api` — CRD schemas and generated types.
- `kroxylicious-operator` — Service planning, naming, status reporting.
- Operator documentation — `con-kafkaproxyingress-infrastructure-annotations.adoc`
  currently states annotations apply "regardless of the ingress type" with a
  LoadBalancer example that does not work today, and must be corrected.

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
- Upgrade is inert for proxies with one `loadBalancer` ingress: the legacy
  naming rule keeps `<proxy>-sni` and patches the Service in place.
- For proxies with several `loadBalancer` ingresses, upgrade moves from one
  load balancer to one per ingress. One ingress adopts `<proxy>-sni` via the
  label-based legacy rule (see Migration); the others get new `<ingress>-sni`
  Services and their clusters change address once. The adoption is sticky:
  ingresses added later cannot change it. This has a cost implication: more load
  balancers means higher cloud spend. We accepted this on the grounds
  that cross-cluster sharing via `$(virtualClusterName)` covers the common
  case and cross-ingress sharing can be revisited on user feedback.
- Downgrade: an older operator computes only `<proxy>-sni` and its
  `getSecondaryResources` returns every owned Service, so it would delete the
  per-ingress Services and recreate `<proxy>-sni` — an outage. This must be
  documented.
- `allocateLoadBalancerNodePorts`: Kubernetes only honours it at allocation
  time. Flipping `true` to `false` on a live Service requires the operator to
  clear `spec.ports[].nodePort` to release the NodePorts.
- Future Service-level fields are added under `spec.loadBalancer.service` and
  apply to that ingress's Service; no grouping decision is involved.

## Rejected alternatives

1. **Fields on `KafkaProxy`.** The proxy owns the Service, so no conflict is
   possible — but networking configuration belongs where users look for it, and
   we steered towards `KafkaProxyIngress` on
   [#4161](https://github.com/kroxylicious/kroxylicious/issues/4161).

2. **Keeping one shared Service per proxy with an agreement/conflict rule.**
   Originally proposed: define voting semantics, reject disagreeing ingresses,
   report via status. Superseded by one-Service-per-ingress, which makes
   conflict impossible rather than resolving it. Would also have required new
   plumbing, since `ProxyConfigStateData` is keyed only by cluster and
   `KafkaProxyIngress` status is owned by a reconciler with no sibling
   visibility.

3. **Implicit grouping by config** — one Service per distinct configuration,
   hash-derived names. Rejected: names derived from config change when config
   changes, a rename is delete-then-create with no readiness gate, users who
   already declare `infrastructure.annotations` would have their load balancer
   replaced on upgrade, and it required canonicalisation, normalisation and a
   cross-Service partition invariant to work at all. Sub-points also rejected:
   CRC32 (collision means two configs permanently sharing a load balancer),
   index-based names (renumber on insert), membership-derived names (unbounded
   length).

4. **Adoption by recorded membership** — grouping by config, but matching
   existing Services on the ingresses they serve. Rejected: fixes the rename
   problem but at the cost of overlap matching, tie-break rules,
   history-dependent names and a membership annotation — complexity that only
   exists to preserve cross-ingress sharing, which was not a requirement.

5. **Explicit grouping via a `group:` field.** More API surface than needed
   once the ingress itself is the unit of infrastructure.

6. **Accepting the `<proxy>-sni` rename on upgrade with a release note.**
   Rejected because the outage is avoidable with the legacy naming rule.

## Open questions

- The legacy naming rule — pending maintainer confirmation.
- NodePort clearing on transition to `false` — pending maintainer confirmation.
- Handling of existing `loadBalancer` ingresses whose names are too long for
  `<ingress>-sni` within the 63-character Service name limit. Preferred
  approach: report the condition on status rather than truncating or adding a
  CEL rule, because truncation adds conditional logic and bug surface, and a
  CEL rule would be breaking for existing resources.
