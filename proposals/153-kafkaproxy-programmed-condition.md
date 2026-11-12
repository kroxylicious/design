# 153 - Add a `Programmed` condition to `KafkaProxy`

Today the operator marks a `KafkaProxy` as `Ready=True` as soon as reconciliation finishes without error, even if no proxy pod is running.
What that condition actually reports is "the configuration has been applied to Kubernetes", which is the meaning the Gateway API gives to the `Programmed` condition.
This proposal adds a `Programmed` condition with that meaning to the `KafkaProxy` status, and leaves `Ready` as it is until its meaning is defined in a separate proposal.

Issue: [kroxylicious#4976](https://github.com/kroxylicious/kroxylicious/issues/4976).

## Current situation

The `KafkaProxyReconciler` manages five dependent resources, in this order: the state `ConfigMap`, the `ConfigMap` holding the proxy configuration, the `Deployment`, the `Services` for each virtual cluster and, on OpenShift, the `Routes`.

The `KafkaProxy` status gets its `Ready` condition in two places:

- `reconcile()` writes `Ready=True` (reason `Ready`) whenever it is called.
- `updateErrorStatus()` writes `Ready=Unknown`, with the exception's class name as the reason, when a dependent throws an exception.

Neither looks at the state of the pods.
The result was reported in [kroxylicious#4906](https://github.com/kroxylicious/kroxylicious/issues/4906): with an invalid image, the pods sit in `ImagePullBackOff` and the `KafkaProxy` still shows `Ready=True`.

There is a second detail.
The `Deployment` is declared with `readyPostcondition = DeploymentReadyCondition`, which is only met when `status.readyReplicas == status.replicas`.
In the Java Operator SDK, while that condition is not met, the dependents that come after it (`Services` and `Routes`) are not reconciled, but `reconcile()` is still called.
So today `Ready=True` can appear when the pods are not ready and also when the `Services` and `Routes` have not been created yet.

The `Ready` condition is used in three user-visible places:

- the `Ready` column of `kubectl get kafkaproxy`;
- `kubectl wait kafkaproxy/simple --for=condition=Ready=True` in the record encryption quick start and in `scripts/run-operator.sh`;
- the README of the `kroxylicious-kubernetes-api` module, which already lists `Programmed` as a standard condition and shows reasons (`ReconciliationSucceeded`, `DeploymentNotReady`) that the operator never emits.

In the operator, only `KafkaProxy` uses `Ready`.
`KafkaProxyIngress`, `VirtualKafkaCluster`, `KafkaService` and `KafkaProtocolFilter` use `ResolvedRefs` and `Accepted`.

## Motivation

The Gateway API, which inspires the operator's conditions model, separates two concepts:

- `Programmed`: the configuration has been generated and sent to the data plane.
- `Ready`: reserved for future use; it would guarantee that the data plane is already serving traffic.

The community call on 2026-09-24 concluded that the current `Ready` on `KafkaProxy` has the semantics of `Programmed`, and that the meaning of `Ready` needs more research before it is decided.

Adding `Programmed` now brings three benefits:

- Users get a condition with a defined and documented meaning.
- `Ready` is free to be redefined in [kroxylicious#4906](https://github.com/kroxylicious/kroxylicious/issues/4906) without losing the information it carries today.
- Anyone automating on the status can move to `Programmed` before `Ready` changes behaviour.

## Proposal

### Meaning

`Programmed` on a `KafkaProxy` means that the operator has generated, from the observed `metadata.generation`, all the Kubernetes resources the proxy needs, and that the API server has accepted all of them.

`Programmed` does not mean that:

- the proxy pods are running or ready;
- the `Services` have been assigned addresses or the `Routes` have been admitted;
- clients can connect.

Those points belong to the definition of `Ready`, which is out of scope for this proposal.

### Values

| status | reason | When |
|---|---|---|
| `True` | `Programmed` | All active dependents were reconciled without error for the observed generation. |
| `Unknown` | the exception's class name | A dependent threw an exception. `message` carries the exception message. |

This reuses the behaviour `StatusFactory` already has for the other conditions: the reason of a `True` condition is the type name, and unexpected errors become `Unknown`.

When reconciliation is interrupted by a `StaleReferentStatusException`, the operator still does not update the status, as today.
In that case `Programmed` keeps its previous value, with the old `observedGeneration`, which tells the user it is out of date.

Example status with the pods in `ImagePullBackOff`:

```yaml
status:
  observedGeneration: 3
  replicas: 0
  conditions:
    - type: Ready
      status: "True"
      reason: Ready
      message: ""
      observedGeneration: 3
      lastTransitionTime: "2026-11-12T10:30:00Z"
    - type: Programmed
      status: "True"
      reason: Programmed
      message: ""
      observedGeneration: 3
      lastTransitionTime: "2026-11-12T10:30:00Z"
```

### Create `Services` and `Routes` without waiting for the pods

For `Programmed=True` to be true, all the resources must have been applied.
With the current `DeploymentReadyCondition` that does not happen until the pods become ready.

The proposal is to remove the `readyPostcondition` from the `Deployment`, so that `Services` and `Routes` are created straight after the `Deployment`, without depending on the pods.
This is safe for traffic: a `Service` only forwards connections to ready pods, so creating it earlier does not expose a proxy that is not serving yet.

With this change, by the time `reconcile()` is called all active dependents have been applied, and writing `Programmed=True` at that point is correct.

### The `Ready` condition

`Ready` continues to be written exactly as today, with the same status as `Programmed`.
The documentation will say that:

- `Programmed` is the condition to check to find out whether the configuration has been applied;
- the meaning of `Ready` will change in a future release, following the decision on [kroxylicious#4906](https://github.com/kroxylicious/kroxylicious/issues/4906).

### API changes

- `Condition.Type` gains the value `Programmed`, added at the end of the enum so the order of existing conditions in the status does not change.
- The CRD schema does not change: `type` is already a free-form string.
- The `KafkaProxy` CRD gains a `Programmed` column in `additionalPrinterColumns`, next to `Ready`.
- The description of the `Ready` column is corrected. Today it says "Whether the other resources referenced by this proxy can be found", which does not match what the condition reports.

Expected result:

```
$ kubectl get kafkaproxy -n my-proxy
NAME     READY   PROGRAMMED
simple   True    True
```

### Documentation

- A new module in `kroxylicious-docs` explaining the `KafkaProxy` status, in the same format as the existing ones for `VirtualKafkaCluster` and `KafkaProxyIngress`.
- The `kroxylicious-kubernetes-api` README corrected to show only the conditions and reasons the operator actually emits.
- The quick start keeps using `--for=condition=Ready=True` until `Ready` is redefined.

### Testing

- `KafkaProxyReconcilerTest` and `KafkaProxyStatusFactoryTest`: `Programmed=True` on the happy path, `Unknown` on the error path, `lastTransitionTime` preserved when the status does not change.
- `KafkaProxyReconcilerIT`: `Services` are created even when the `Deployment` has no ready replicas, and `Programmed=True` is reported in that state.
- `ConditionAssert` gains the matching helpers (`isProgrammedTrue()` and so on).

## Affected/not affected projects

Affected:

- `kroxylicious-kubernetes-api`: the `Condition.Type` enum and the `KafkaProxy` CRD.
- `kroxylicious-operator`: `KafkaProxyReconciler`, `KafkaProxyStatusFactory` and the workflow declaration.
- `kroxylicious-operator-test-support`: assertions.
- `kroxylicious-docs`.

Not affected:

- the proxy (`kroxylicious-runtime`), the filters and the plugin APIs;
- the operator's other CRDs;
- the admission webhook (`kroxylicious-admission`), which has its own `Condition` type.

## Compatibility

The change is additive.
`Ready` keeps its status, reason and transition time, so `kubectl wait --for=condition=Ready` and the `Ready` column keep working.

On operator upgrade, existing `KafkaProxy` resources get `Programmed` on their first reconciliation.
The CRD must be reapplied for the new column to appear.

`Services` and `Routes` are now created before the pods become ready.
Anyone who watches for the existence of the `Service` as a signal that the proxy is ready needs to watch the `KafkaProxy` status or the `Service` endpoints instead.

Operator rollback is a risk to verify during implementation.
An older operator version reads a status containing a `Condition.Type` it does not know, and deserialising the enum may fail.
If it does, the proposal should include one of two mitigations: document that rollback requires clearing the status, or make deserialisation tolerant of unknown types in a release before the one that introduces `Programmed`.

## Open questions

1. **Reasons for failure.**
   The proposal keeps `Unknown` with the exception's class name, the same as the other conditions.
   The Gateway API uses `False` with reasons such as `Invalid` and `Pending`.
   Adopting that vocabulary would be better for users, but it would require classifying the reconciler's exceptions and should apply to all of the operator's conditions, not only `Programmed`.
2. **Removing `DeploymentReadyCondition`.**
   If there is a reason to keep the `Services` waiting for the pods, the alternative is to keep the condition and report `Programmed=False` with reason `Pending` while there are unreconciled dependents.
   In that case `Programmed` would depend on the pods again, which contradicts the definition in the issue.
3. **Other resources.**
   `VirtualKafkaCluster` and `KafkaProxyIngress` also result in Kubernetes resources, but it is the `KafkaProxy` reconciler that creates them.
   This proposal does not add `Programmed` to them.
4. **Fix `Ready` instead of adding `Programmed`.**
   [kroxylicious#4906](https://github.com/kroxylicious/kroxylicious/issues/4906) describes the option of tying `Ready` to the state of the `Deployment`, and the community call decided to research the meaning of `Ready` further before choosing.
   This proposal assumes the two are separate, but it is open whether the community would prefer to handle both in a single change.
5. **Keep, rename or stop writing `Ready`.**
   The proposal keeps `Ready` as it is, so as not to break `kubectl wait --for=condition=Ready`, the `kubectl get` column and existing automation.
   The other options are to rename `Ready` to `Programmed` in one step, or to stop writing `Ready` until it is redefined.
   Neither was discussed in the issue.
6. **Where to derive `Programmed` from.**
   The proposal derives it from the result of reconciling the dependents.
   Another option would be to use the `Deployment`'s conditions (`Available`, `Progressing`), but those describe the state of the pods, which by the issue's definition is not part of `Programmed`.

## Rejected alternatives
