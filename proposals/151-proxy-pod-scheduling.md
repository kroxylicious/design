# 151 - Proxy pod scheduling for KafkaProxy

Add optional `nodeSelector`, `tolerations`, `affinity`, and `topologySpreadConstraints` fields to
`KafkaProxy.spec.infrastructure`, so users can control where proxy pods are scheduled. This relates to
[issue #4978](https://github.com/kroxylicious/kroxylicious/issues/4978): it covers the scheduling part of
that issue and proposes rules for adding further pod-level settings, but leaves Deployment-level controls
such as rollout strategy to a later proposal.

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
([#2323](https://github.com/kroxylicious/kroxylicious/pull/2323)), which said that some pod configuration
would be reintroduced under `infrastructure` and left support for a full pod template to be decided.

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
  `core/v1` `PodSpec`. The CRD schema inlines the Kubernetes OpenAPI definitions, so the API server checks
  their structure (types and required fields) when the `KafkaProxy` is written, and `kubectl explain`
  documents them.
- The OpenAPI schema does not carry the rest of Kubernetes' pod validation, such as allowed toleration
  operators or `weight` and `maxSkew` ranges. Such errors are reported when the operator applies the
  Deployment: the apply fails, and the `KafkaProxy` `Ready` condition becomes `Unknown` with the API
  server's message, as for any other failure to apply a dependent resource. Until the value is corrected,
  the Deployment is not updated. Duplicating pod validation as CEL rules in the CRD was considered and is
  not proposed, because it would have to track Kubernetes' validation across versions.
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
  why. The Deployment's default rolling update strategy (`maxUnavailable` of 25%, rounded down) may stop
  some existing pods first: none with fewer than four replicas, and at least one with four or more. This
  is standard Kubernetes behaviour; the operator does not add a status condition for it, and the operator
  guide documents it.

### Rules for further pod-level settings (issue #4978)

Issue #4978 asks how the project should expose user controls over the proxy Deployment. For pod-level
settings this proposal recommends continuing the inline approach under `infrastructure`, with these rules:

1. Add a field only when there is a demonstrated need.
2. Reuse the Kubernetes field name, type, and schema verbatim, rather than inventing a Kroxylicious shape.
3. The operator copies the field; it does not merge user values with values it sets itself.

Rules 2 and 3 keep each field easy to learn, validate, and implement, and mean there are no conflicts
between user and operator values to report.

This proposal does not settle the rest of #4978:

- **Deployment-level controls** such as rollout strategy could follow the same rules (for example, an
  `infrastructure.deploymentStrategy` field mirroring `DeploymentSpec.strategy`), but they need their own
  proposal.
- **Fields the operator sets itself**, such as containers, volumes, security context, and probes, cannot
  follow rule 3. Overriding them needs merge and conflict-reporting semantics, which is out of scope.

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

Rejected because a pod template exposes fields the operator must own, such as containers, volumes, and
the security context. The project would need merge rules, conflict detection and reporting, and a
compatibility commitment to all of `PodTemplateSpec`. Scheduling needs none of that.
[#2323](https://github.com/kroxylicious/kroxylicious/pull/2323) removed the earlier `spec.podTemplate` and
left full pod template support to be decided.

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
- the CRD rejects structurally invalid values with errors naming the field path, and accepts valid ones;
- a value that passes the CRD but fails pod validation is reported on the `KafkaProxy` `Ready` condition;
  and
- the operator guide documents the fields, the pod labels to select on, how to diagnose `Pending` pods,
  and how rollouts behave when pods cannot be scheduled.
