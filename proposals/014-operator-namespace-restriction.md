# Proposal 014 - Restrict Operator to a Configurable Set of Namespaces

Allow the Kroxylicious Operator to be restricted to watching a static, user-defined set of
Kubernetes namespaces via an environment variable, rather than always watching the entire cluster.

## Current situation

The Kroxylicious Operator currently watches all namespaces in a Kubernetes cluster. 

When the operator starts, the Java Operator SDK (JOSDK) initialises informers that cache all `Secret` and
`ConfigMap` objects across the whole cluster. These caches are held in the operator's JVM heap and
grow proportionally with the total number of such objects present in the cluster.

There is no built-in mechanism to narrow the scope of what the operator watches at deployment time.

## Motivation

On a large shared Kubernetes or OpenShift cluster there can be hundreds or thousands of
`Secret` and `ConfigMap` objects unrelated to Kroxylicious. Because the operator caches all of
them, there is the possibility that the Operator may run out of memory.

This behaviour was first observed in issue [#2246](https://github.com/kroxylicious/kroxylicious/issues/2246), where the
operator crashed with an `OutOfMemoryError` under default memory settings when deployed to an
OpenShift cluster with many configmaps. 

Increasing the operator's memory limit is a valid short-term workaround, but it is wasteful and
does not scale: the memory required will keep growing as the cluster grows, irrespective of how
many Kroxylicious resources exist.

A more targeted solution is to allow operators to restrict the operator to the namespace(s) in which Kroxylicious resources will actually be deployed.

## Proposal

A new optional environment variable, `KROXYLICIOUS_WATCHED_NAMESPACES`, is introduced on the
operator `Deployment`. 

Its value is a comma-separated list of namespace names:

```
KROXYLICIOUS_WATCHED_NAMESPACES=team-a,team-b,shared-kafka
```

### Behaviour

- **Variable absent or empty** – the operator behaves exactly as today, watching all namespaces
  cluster-wide. Existing deployments are unaffected.
- **Variable present with one or more namespace names** – the operator restricts its informers
  to those namespaces only. Resources in any other namespace are invisible to the operator.

### Implementation

At startup the operator reads `KROXYLICIOUS_WATCHED_NAMESPACES` from the environment. If a
non-empty value is found, it parses the comma-separated list, trims whitespace from each token,
and passes the resulting set to the JOSDK `operator.register()` call via a
`ControllerConfigurationOverrider`.

```java
configOverrider.settingNamespaces(watchedNamespaces)
```

### OLM compatibility

Although the Kroxylicious Operator does not yet integrate with the Operator Lifecycle Manager
(OLM), the semantics of the environment variable are designed to cooperate with OLM's
[target-namespace-selection](https://olm.operatorframework.io/docs/concepts/crds/operatorgroup/#target-namespace-selection).

A CSV entry can forward the OLM-injected annotation directly to the operator:

```yaml
- name: KROXYLICIOUS_WATCHED_NAMESPACES
  valueFrom:
    fieldRef:
      fieldPath: metadata.annotations['olm.targetNamespaces']
```

This means that once OLM support is added, namespace scoping will work with zero additional operator changes.

## Affected/not affected projects

**Affected:**

- `kroxylicious-operator`

**Not affected:**

- `kroxylicious-runtime` – the proxy runtime is wholly unaware of the operator's namespace watch scope.

## Compatibility

### Backwards compatibility

The change is fully backwards compatible. The environment variable is optional and, when absent,
the operator continues to watch all namespaces as it does today. No existing manifests, Helm
values, or operator deployments need to be modified to upgrade to a version that includes this
feature.

## Rejected alternatives

### Dynamic namespace change

JOSDK provides a richer mechanism for changing the set of watched namespaces while the operator is running.

When a reconciler is registered, a
[`RegisteredController`](https://github.com/java-operator-sdk/java-operator-sdk/blob/ec37025a15046d8f409c77616110024bf32c3416/operator-framework-core/src/main/java/io/javaoperatorsdk/operator/RegisteredController.java)
instance is returned, and its `changeNamespaces(Set<String>)` method can be called at any time to hot-reload the namespace set without restarting the operator pod.

Kroxylicious could _potentially_ leverage this in a couple of ways:

1. Allowing the set of namespaces to be defined by a regular expression, or Kubernetes selector, in such a way that if new namespaces appear at runtime, the system dynamically reconfigures itself.
2. Adopting the usage pattern suggested by the [JOSDK configuration documentation](https://javaoperatorsdk.io/docs/documentation/configuration/#dynamically-changing-target-namespaces)
where a`ConfigMap` (or similar resource) would be watched that contains the desired namespaces.

**Reasons for rejection:** 

Whilst this approach is powerful, it introduces significant additional complexity:

1. **New configuration surface.** A `ConfigMap` (or similar) must be defined, maintained, and RBAC-protected. Users would need to understand a new Kroxylicious-specific configuration
   object purely to configure the operator itself, rather than their Kafka proxies.

2. **Operator-watches-itself problem.** If the namespace list is stored in a `ConfigMap`, the operator must watch at least the namespace containing that `ConfigMap` before it knows which
   other namespaces to watch. This bootstrap ordering problem requires careful design to avoid race conditions or missed updates during startup.

3. **Unclear operational semantics.** When the namespace set changes at runtime, all informer caches for removed namespaces are torn down and rebuilt for added namespaces. This can cause a
   transient period during which the operator may not reconcile resources correctly and could produce unwanted side effects.

Dynamic namespace changes remain a valid future enhancement, and the static implementation proposed here does not close that door: the two approaches use the same underlying JOSDK APIs
and can coexist.
