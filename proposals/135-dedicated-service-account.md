# 135 - Dedicated ServiceAccount for KafkaProxy pods

Add an optional `KafkaProxy.spec.infrastructure.serviceAccountName` field so users can define a
dedicated, user-managed Kubernetes ServiceAccount for KafkaProxy pods.

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
- Changes to Deployment rollout strategy (tracked by
  [issue #4978](https://github.com/kroxylicious/kroxylicious/issues/4978)).
- Changes to `KafkaProxy` status reporting (tracked by
  [issue #4906](https://github.com/kroxylicious/kroxylicious/issues/4906)).

## Motivation

Users may need KafkaProxy pods to use a distinct Kubernetes identity when proxy configuration or an
external workload identity integration requires permissions or annotations that must not be shared
with every pod using the namespace's default ServiceAccount.

The feature also allows users to apply least-privilege RBAC. The operator should not need to own or
mutate those identity resources to provide this capability.

## Proposal

Configure the ServiceAccount on `KafkaProxy.spec`:

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxy
metadata:
  name: simple
  namespace: my-proxy
spec:
  infrastructure:
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

- `serviceAccountName` is optional and is available on `KafkaProxy` under
  `infrastructure`; no other CRD is changed.
- The value is a ServiceAccount `metadata.name`, not a `namespace/name` reference.
- Kubernetes resolves the name in the namespace of the `KafkaProxy` and its generated pod.
- The value is validated as a DNS-1123 subdomain with a maximum length of 253 characters.
- When set, the operator copies the value to the generated pod template. When omitted, the
  generated pod template leaves the field unset and Kubernetes uses the namespace's `default`
  ServiceAccount.
- The operator does not silently fall back to `default` when a configured account is unavailable.

This adds the one required field without defining a broader pod-template API. The user-managed
ServiceAccount lifecycle follows the Prometheus Operator's optional `spec.serviceAccountName` pattern.

### Ownership, permissions, and security boundary

Users manage the ServiceAccount, including its annotations, RBAC, token settings, and cloud
associations. The operator only copies its name to the generated Deployment; it does not manage,
read, or watch the account.

### Missing accounts and lifecycle

If the configured ServiceAccount is missing, proxy pods cannot be created and Kubernetes does not
fall back to `default`. The generated Deployment reports `ReplicaFailure=True` with reason
`FailedCreate`, and ReplicaSet events identify the missing account. Users can inspect those resources
to diagnose the failed rollout. This proposal leaves Deployment rollout behavior unchanged.

To change accounts safely, create and configure the new account, update the `KafkaProxy`, wait for
rollout completion, then remove the old account.

### Validation evidence

Kind integration validation on Kubernetes v1.31.0 and v1.36.1 confirmed that a missing account
produces `ReplicaFailure=True`/`FailedCreate` and an event stating that the referenced
ServiceAccount was not found. Creating the account allowed the rollout to complete.

## Affected/not affected projects

**Affected:**

- `kroxylicious-kubernetes/kroxylicious-kubernetes-api` — add the optional CRD field and validation.
- `kroxylicious-kubernetes/kroxylicious-operator` — copy the field to generated proxy Deployments and
  add tests.
- `kroxylicious-docs` — document creation, configuration, security, lifecycle, ServiceAccount
  changes, and troubleshooting.

**Not affected:**

- The operator's own ServiceAccount, RBAC, and admission webhook.
- Non-Kubernetes deployments and existing proxy/filter behavior.

## Compatibility

The field is additive and optional. Omitting it preserves the current default ServiceAccount and
Deployment rollout behavior. Removing it returns to namespace-default ServiceAccount selection.

## Rejected alternatives

### Operator-created ServiceAccounts

Rejected because the operator would need ownership, deletion, annotation, conflict, and RBAC
semantics. Those permissions are unnecessary for selecting a user-managed identity and would make
provider-specific identity configuration operator-owned.

### A creation or RBAC-management boolean

Rejected because a name already provides an explicit opt-in. A second API would introduce larger
lifecycle and security semantics outside this feature.

### No ServiceAccount preflight or watch

Not included because it would require additional RBAC and would still be subject to races before pod
admission. The generated Deployment and ReplicaSet already expose admission failures.

### A namespace in the reference

Rejected because `PodSpec.serviceAccountName` is a name resolved in the pod namespace. Accepting a
namespace would imply cross-namespace pod ServiceAccount semantics that Kubernetes does not provide.

## Verification criteria

The implementation is complete when tests and documentation demonstrate that:

- ServiceAccount settings render the expected pod template;
- valid DNS-1123 names are accepted and empty or invalid names are rejected by the CRD;
- changing the name replaces proxy pods through a normal Deployment rollout;
- a missing account never falls back to `default`, appears as Deployment `ReplicaFailure` and a
  ReplicaSet event, with rollout recovery after the account is restored;
- the generated Deployment rollout strategy and `KafkaProxy` status behavior remain unchanged;
- the operator does not create, mutate, adopt, bind, delete, read, or watch the referenced account.

This proposal addresses [issue #3758](https://github.com/kroxylicious/kroxylicious/issues/3758) and
follows the Prometheus Operator API pattern.
