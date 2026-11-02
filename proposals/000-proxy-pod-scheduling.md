# 000 - Proxy pod scheduling for KafkaProxy

Add optional `nodeSelector`, `tolerations`, `affinity`, and `topologySpreadConstraints` fields to
`KafkaProxy.spec.infrastructure`, so users can control where proxy pods are scheduled. This also proposes
an answer to the strategy question in
[issue #4978](https://github.com/kroxylicious/kroxylicious/issues/4978) for pod-level settings.

## Current situation

The operator builds the proxy Deployment's pod template in code. Users can set only
`spec.infrastructure.proxyContainer.resources` and `spec.infrastructure.serviceAccountName`
([proposal 135](./135-dedicated-service-account.md)). There is no way to set a node selector, tolerations,
affinity, or topology spread constraints, so proxy pods:

- cannot run on tainted nodes, such as a dedicated node pool;
- cannot be pinned to or kept off particular nodes; and
- cannot be spread across zones beyond the cluster's default spreading.

`KafkaProxy.spec.podTemplate` once existed ([#1596](https://github.com/kroxylicious/kroxylicious/pull/1596)),
was limited to `metadata.labels`, and was removed in favour of `infrastructure`
([#2323](https://github.com/kroxylicious/kroxylicious/pull/2323)), noting that pod configuration would be
reintroduced under `infrastructure`.

Because the operator owns the Deployment and reconciles it, users cannot patch these fields onto the
Deployment themselves in a supported way. The current workarounds are mutating admission webhooks or a
second server-side-apply field manager on the operator's Deployment, and neither is acceptable in every
cluster.

## Motivation

Scheduling control is a basic requirement for running a workload in a shared or production cluster:

- **Dedicated or tainted node pools.** Many clusters taint node pools and require workloads to carry
  matching tolerations, often enforced by admission policy. Today the proxy cannot run on them.
- **Availability.** A proxy that fronts Kafka is on the data path. Users need to spread replicas across
  zones and nodes so that a single zone or node failure does not take out every replica.
- **Hardware and cost.** Users need to place the proxy on particular architectures, instance types, or
  capacity types (for example, on-demand rather than spot nodes).

## Proposal

### API

Add four optional fields to `KafkaProxy.spec.infrastructure`:

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxy
metadata:
  name: simple
  namespace: my-proxy
spec:
  replicas: 3
  infrastructure:
    nodeSelector:
      node-pool: kafka-proxy
    tolerations:
      - key: node-pool
        operator: Equal
        value: kafka-proxy
        effect: NoSchedule
    affinity:
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              topologyKey: kubernetes.io/hostname
              labelSelector:
                matchLabels:
                  app.kubernetes.io/instance: simple
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: topology.kubernetes.io/zone
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels:
            app.kubernetes.io/instance: simple
```

### API semantics

- Each field has exactly the type, schema, and semantics of the field with the same name in the Kubernetes
  `core/v1` `PodSpec`. The CRD schema inlines the Kubernetes OpenAPI definitions, so the API server
  validates them the same way and `kubectl explain` documents them.
- The generated Java model uses the fabric8 types (`Toleration`, `Affinity`, `TopologySpreadConstraint`)
  through `existingJavaTypes`, as is already done for `ResourceRequirements`.
- When set, the operator copies each field unchanged to the proxy pod template. The operator does not add,
  merge, or default any scheduling values of its own, so there is nothing to conflict with.
- When omitted, the pod template leaves the field unset, which is today's behaviour.
- Pod affinity, anti-affinity, and topology spread constraints select pods by label. Users select the
  proxy pods of a `KafkaProxy` with the labels the operator already sets on them
  (`app.kubernetes.io/name: kroxylicious`, `app.kubernetes.io/component: proxy`,
  `app.kubernetes.io/instance: <KafkaProxy name>`), which are documented.

### Lifecycle

- Changing any field changes the pod template, so the proxy pods are replaced through a normal Deployment
  rollout. Rollout strategy is unchanged.
- The operator applies the Deployment with server-side apply. Removing a field from the `KafkaProxy`
  removes it from the Deployment, because the operator stops claiming it. None of these fields has a
  deprecated alias, unlike `serviceAccountName`, so no extra handling is needed.
- If no node satisfies the constraints, replacement pods stay `Pending` with scheduler events explaining
  why, and the existing pods keep running. This is standard Kubernetes behaviour; the operator does not
  add a status condition for it.

### Strategy for pod-level settings (issue #4978)

Issue #4978 asks how the project should expose user controls over the proxy Deployment. For pod-level
settings this proposal recommends continuing the inline approach under `infrastructure`, with these rules:

1. Add a field only when there is a demonstrated need.
2. Reuse the Kubernetes field name, type, and schema verbatim, rather than inventing a Kroxylicious shape.
3. The operator copies the field; it does not merge user values with values it sets itself. Fields the
   operator must own (containers, volumes, security context, probes) are not exposed this way.

Rules 2 and 3 keep each field easy to learn, validate, and implement, and avoid the conflict-reporting
problem that a pod template raises. Deployment-level controls such as rollout strategy remain out of scope
here and can follow the same rules in a later proposal.

## Affected/not affected projects

**Affected:**

- `kroxylicious-kubernetes/kroxylicious-kubernetes-api`: the four CRD fields and `existingJavaTypes`
  mappings.
- `kroxylicious-kubernetes/kroxylicious-operator`: copy the fields to the proxy pod template; unit,
  CRD validation, and reconciler integration tests.
- `kroxylicious-docs`: a "Controlling where proxy pods are scheduled" section in the operator guide.

**Not affected:**

- The operator's own Deployment, which the install manifests already let users schedule.
- Non-Kubernetes deployments and proxy or filter behaviour.

## Compatibility

All four fields are additive and optional. Omitting them preserves the current pod template exactly.
Because they mirror stable `core/v1` fields, they can be carried unchanged into later API versions.

## Rejected alternatives

### A full or partial `podTemplate`

Rejected for the reasons that led to the removal of `spec.podTemplate` in
[#2323](https://github.com/kroxylicious/kroxylicious/pull/2323): a pod template exposes fields the operator
must own, so the project would need merge rules, conflict detection and reporting, and a compatibility
commitment to all of `PodTemplateSpec`. Scheduling needs none of that.

### A referenced parameters object, as in the Kubernetes Gateway API

Rejected for now because it adds a new resource type, a watch, cross-resource status reporting, and an
indirection users must learn, for four fields that belong to a single `KafkaProxy`. It may be worth
revisiting if the same settings must be shared by many proxies.

### Kroxylicious-specific scheduling fields

For example, a `nodePool` field that the operator translates into a selector and toleration. Rejected
because it covers fewer cases than the Kubernetes fields, and users would have to learn a second
vocabulary for something they already know.

### Leaving it to admission webhooks or a second field manager

Rejected because these are workarounds that depend on cluster-specific tooling, are invisible in the
`KafkaProxy`, and some organisations forbid mutating webhooks.

## Verification criteria

The implementation is complete when tests and documentation show that:

- omitting the fields leaves them unset in the pod template;
- configured values are copied unchanged to the pod template and reach scheduled pods;
- removing the configuration removes the fields from the Deployment;
- the CRD rejects invalid values with errors naming the field path, and accepts valid ones; and
- the operator guide documents the fields, the pod labels to select on, and how to diagnose `Pending`
  pods.
