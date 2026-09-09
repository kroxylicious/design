# 000 - Dedicated ServiceAccount for KafkaProxy pods

Add an optional `KafkaProxy.spec.serviceAccountName` field so users can define a dedicated,
user-managed Kubernetes ServiceAccount for proxy pods.

## Current situation

Each `KafkaProxy` pod currently uses the `default` ServiceAccount in the proxy namespace.

## Non-goals

This proposal does not add:

- Operator creation, ownership, mutation, annotation management, or deletion of proxy
  ServiceAccounts.
- Operator management of Roles, ClusterRoles, RoleBindings, or ClusterRoleBindings for proxy
  workloads.
- Cross-namespace ServiceAccount references.
- Changes to automatic ServiceAccount token mounting for proxy pods.
- ServiceAccount watches or an existence preflight.

## Motivation

Users may need KafkaProxy pods to use a distinct Kubernetes identity. This is useful when proxy
configuration or an external workload identity integration requires permissions or annotations that
must not be shared with every pod using the namespace's default ServiceAccount.

The feature also allows users to apply least-privilege RBAC and to audit proxy API actions separately
from other workloads. The operator should not need to own or mutate those identity resources to
provide this capability.

## Proposal

Add one optional field to `KafkaProxy.spec`:

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxy
metadata:
  name: simple
  namespace: my-proxy
spec:
  serviceAccountName: kroxylicious-proxy
```

The user creates and manages the referenced ServiceAccount separately:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kroxylicious-proxy
  namespace: my-proxy
```

### API semantics

- `serviceAccountName` is optional and is available on `KafkaProxy`; no other CRD is changed.
- The value is a ServiceAccount `metadata.name`, not a `namespace/name` reference.
- Kubernetes resolves the name in the namespace of the `KafkaProxy` and its generated pod.
- The value is validated as a DNS-1123 subdomain with a maximum length of 253 characters.
- When set, the operator copies `serviceAccountName` to the generated pod template.
- When omitted, Kubernetes uses the namespace's `default` ServiceAccount.
- The operator does not silently fall back to `default` when a configured account is unavailable.

Like Prometheus Operator, this is an optional, user-managed `spec.serviceAccountName`.

### Ownership, permissions, and security boundary

Users manage the ServiceAccount, including its annotations, RBAC, token settings, and cloud
associations. The operator only copies its name to the generated Deployment; it does not manage,
read, or watch the account.

### Missing accounts and lifecycle

If the configured ServiceAccount is missing, replacement pods fail admission and Kubernetes does not
fall back to `default`. Deployment status and ReplicaSet events expose the failure; existing pods may
continue running until replaced.

To change accounts safely, create and configure the new account, update the `KafkaProxy`, wait for
rollout completion, then remove the old account.

### Rollout behavior

The generated proxy Deployment uses an explicit rolling-update policy:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 1
```

This preserves ready old replicas when replacement pods fail, but affects every proxy rollout and
requires one additional schedulable pod. Rollouts may remain pending when a surge pod cannot be
scheduled.

### Validation evidence

Kind validation on Kubernetes v1.31.0 confirmed that missing accounts produce
`ReplicaFailure=True`/`FailedCreate` without fallback, while `maxUnavailable: 0` retains existing
ready pods during a failed replacement. Focused operator tests covered configuring, changing,
removing, and recovering accounts; the removal test also passed on v1.30.0. Provider-specific cloud
identity behavior was not tested because it is unavailable in kind.

## Affected/not affected projects

**Affected:**

- `kroxylicious-kubernetes/kroxylicious-kubernetes-api` — add the optional CRD field and validation.
- `kroxylicious-kubernetes/kroxylicious-operator` — copy the field to generated proxy Deployments,
  apply the rollout policy, and add tests.
- `kroxylicious-docs` — document creation, configuration, security, lifecycle, ServiceAccount
  changes, and troubleshooting.

**Not affected:**

- The operator's own ServiceAccount, RBAC, and admission webhook.
- Non-Kubernetes deployments and existing proxy/filter behavior.

## Compatibility

The API field is additive and optional. Existing `KafkaProxy` resources that omit it retain the
current default ServiceAccount behavior. Removing the field removes the explicit pod-template value
on the next reconciliation and returns to Kubernetes default selection.

Existing user-managed ServiceAccounts are not adopted, owner-referenced, or modified. No additional
operator ServiceAccount permissions are required for the reference itself.

The rollout policy applies to all proxy updates. It preserves healthy old replicas during failed
replacements but requires surge capacity and may reduce rollout parallelism.

## Rejected alternatives

### Operator-created ServiceAccounts

Rejected because the operator would need ownership, deletion, annotation, conflict, and RBAC
semantics. Those permissions are unnecessary for selecting a user-managed identity and would make
provider-specific identity configuration operator-owned.

### A creation or RBAC-management boolean

Rejected because a name already provides an explicit opt-in. A second API would introduce larger
lifecycle and security semantics outside this feature.

### A read-only preflight, status condition, or ServiceAccount watch

Outside the scope because it would require additional RBAC and would still be subject to races before
pod admission.

### A namespace in the reference

Rejected because `PodSpec.serviceAccountName` is a name resolved in the pod namespace. Accepting a
namespace would imply cross-namespace pod ServiceAccount semantics that Kubernetes does not provide.

## Verification criteria

The implementation is complete when tests and documentation demonstrate that:

- ServiceAccount settings render the expected pod template;
- valid DNS-1123 names are accepted and empty or invalid names are rejected by the CRD;
- changing the name replaces proxy pods through a normal Deployment rollout;
- a missing account never falls back to `default`, and the resulting Kubernetes failure is visible;
- a failed replacement rollout retains existing ready proxy pods and recovers after the account is
  restored;
- the operator does not create, mutate, adopt, bind, delete, read, or watch the referenced account.

This proposal addresses [issue #3758](https://github.com/kroxylicious/kroxylicious/issues/3758), follows
the Prometheus Operator API pattern, and uses the explicit rollout strategy used by
Strimzi.
