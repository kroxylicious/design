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

Networking models are per `(cluster, ingress)` — `ClusterIngressNetworkingModel`
requires both — so a `KafkaProxyIngress` that no `VirtualKafkaCluster`
references produces no model and therefore no Service. This is also the
behaviour we want on cost grounds: no load balancer for an ingress serving
nothing. The `VirtualKafkaCluster` CRD enforces a CEL rule that bounds ingress
name length:

  self.spec.ingresses.all(ingress,
    (ingress.ingressRef.name.size() + self.metadata.name.size()) <= 51)

so any ingress referenced by a VKC has a name of at most 50 characters, well
within the 63-character Service name limit.

### Service naming

Name: the `KafkaProxyIngress` name. Unique because `KafkaProxyIngress` names
are unique within a namespace and each ingress produces at most one Service.

No collision with the ClusterIP and Route Services, which are named
`<cluster>-<ingress>-bootstrap`.

The Service carries owner references to the `KafkaProxy` and the
`KafkaProxyIngress`, with no `VirtualKafkaCluster` reference since one ingress
serves many clusters. Deletion is operator-driven: when an ingress goes, its
Service leaves `desiredResources()` and is deleted.

Identity is stable by construction: the name derives from the ingress name,
which is the ingress's identity. Editing any field patches the Service in
place.

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

`allocateLoadBalancerNodePorts`: when the field is `false` and the live
Service still reports a `nodePort`, the operator applies `nodePort: 0` to
release it. Omitting the field is not enough under server-side apply, since the
operator does not own it. This is a one-time transition; once released, the
operator omits the field again and the port stays released.

`healthCheckNodePort` is allocated by a separate allocator and is unaffected by
`allocateLoadBalancerNodePorts: false`. It is allocated precisely when
`externalTrafficPolicy: Local` is set. So a user setting `Local` for source-IP
preservation and `false` to close NodePorts still gets a health-check NodePort
open on every node. Given that attack surface is part of the motivation in
[#4161](https://github.com/kroxylicious/kroxylicious/issues/4161), this
interaction must be documented. Exposing `healthCheckNodePort` as a
configuration field is out of scope here.

### Migration from the shared Service

On upgrade, the per-proxy `<proxy>-sni` Service is deleted and one Service per
`loadBalancer` ingress is created, named after the ingress. The new Services get
new external addresses, so DNS records pointing at the old load balancer must be
re-pointed at the new ones. The interruption therefore lasts until re-pointing
has happened and propagated, not just until a Kafka client retries. How long
depends on whether the records are managed automatically (e.g. external-dns
watching the new Service) or updated by hand, and on the TTLs in play.

`BulkDependentResourceReconciler.reconcile()` in JOSDK 5.5.1 calls
`deleteExtraResources()` before creating, so the old load balancer is destroyed
before the replacement is ready.

This is a one-time event at upgrade, not something that recurs — config edits
patch in place and never rename (see Behaviour when configuration changes). It
must be called out in the release note, with the re-pointing step described.

### Implementation outline

- **`sniLoadbalancerServices()`** — group the LoadBalancer networking models by
  ingress (not all together), emit one Service per ingress with that ingress's
  ports, bootstrap entries and infrastructure annotations.
- **`SharedLoadBalancerServiceRequirements`** — its sharing scope narrows from
  per-proxy to per-ingress; it must expose the ingress's Service-level config
  and annotations. Alternatively, fold it into the model — leave that to
  implementation.
- **`getLoadBalancerServiceBootstrapServers()`** — per-ingress rather than one
  aggregate.
- **`VirtualKafkaClusterPrimaryToKubernetesServiceSecondaryMapper`** — currently
  derives the Service name as `proxyRef.getName() + "-sni"`; it should instead
  read `ingressRef.getName()` from each entry in the cluster's `spec.ingresses`,
  since the Service name is the ingress name. This matches the shape of the
  existing ClusterIP and Route handling in the same mapper, minus the name
  construction.

`ClusterServiceDependentResource` is already a
`BulkDependentResource<Service, KafkaProxy, String>` with `desiredResources()`,
`getSecondaryResources()` and `deleteTargetResource()` implemented, so emitting
N Services and cleanup need no new machinery. The operator filters owned
Services on `spec.type == LoadBalancer` when it needs to identify the
LoadBalancer subset.

Two things need **no** work:

- `buildIngressStatus` matches Services on the `(clusterName, ingressName)`
  pair read from the bootstrap annotation rather than by name.
- `KubernetesServicesSecondaryToVirtualKafkaClusterPrimaryMapper` works off
  owner references.

The cross-Service strict-partition invariant from the earlier grouping design is
no longer a design concern — it holds trivially since each Service serves one
ingress.

### Testing

- **Unit:** per-ingress Service generation; `allocateLoadBalancerNodePorts`
  transition (when `false` and a `nodePort` is still allocated, the operator
  applies `nodePort: 0`).
- **Integration:** config edit is an in-place patch with the Service name
  unchanged; annotations reach the Service.
- **System:** expected number of Services per proxy with correct spec fields
  and annotations; assert real LoadBalancer behaviour. System tests skip on
  environments that cannot provision a load balancer, so they run on real
  Kubernetes environments. The established pattern is `@EnabledIf` for
  integration tests and `@Disabled` for excluded system tests (see
  `KroxyliciousAppST`).

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
- Upgrade replaces the shared `<proxy>-sni` Service with per-ingress Services.
  The new Services get new external addresses, so DNS records must be
  re-pointed. The interruption lasts until re-pointing has happened and
  propagated. This is a one-time event, to be release-noted with the
  re-pointing step described.
- For proxies with several `loadBalancer` ingresses, upgrade moves from one
  load balancer to one per ingress. This has a cost implication: more load
  balancers means higher cloud spend. We accepted this on the grounds that
  cross-cluster sharing via `$(virtualClusterName)` covers the common case and
  cross-ingress sharing can be revisited on user feedback.
- Downgrade: an older operator computes only `<proxy>-sni` and its
  `getSecondaryResources` returns every owned Service, so it would delete the
  per-ingress Services and recreate `<proxy>-sni` — an outage. This must be
  documented.
- `allocateLoadBalancerNodePorts`: the operator clears `spec.ports[].nodePort`
  when the field transitions to `false` (see Behaviour when configuration
  changes).
- This proposal establishes `spec.loadBalancer.service` as where Service-level
  fields go if they are added individually; no grouping decision is involved.
  Whether to continue adding them one at a time or to externalise infrastructure
  configuration behind a reference is an open direction and deferred to a separate 
  proposal (see Rejected alternatives).

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

6. **Externalising infrastructure configuration behind a reference** — rather
   than adding named fields one at a time, the ingress could reference a
   resource holding infrastructure configuration, as Gateway API does with
   `parametersRef`. This would let configuration be shared across resources and
   split ownership between infrastructure admins and application teams, which
   isn't possible today. It would need a curated subset rather than a free-form
   `ServiceSpec`, since `ports`, `selector` and `type` must stay
   operator-owned. Deferred to a separate proposal; the design here doesn't
   foreclose it.
