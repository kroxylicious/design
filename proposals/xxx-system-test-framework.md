# xxx - System Test Framework

## Summary

Introduce a layered abstraction for system tests that separates test intent (what the proxy should do) from deployment mechanism (how the proxy is stood up). A `ProxyScenario` describes the desired proxy configuration in deployment-agnostic terms; a `ProxyFixture` translates that into running infrastructure and blocks until convergence; the resulting `ProxyHandle` is a token of convergence that gates all subsequent interaction. Feature tests become portable across deployment mechanisms — the same test runs against an operator-managed proxy, a manifest-managed proxy, or a downstream distribution — and cheap enough to write before the production code, as a specification.

## Current Situation

The system test suite covers the right things at the right level. Assertions in `RecordEncryptionST`, `AuthorizationST`, and `EntityIsolationST` test feature behaviour cleanly. `OperatorChangeDetectionST` tests operator reconciliation behaviour. The abstraction breaks down only in setup.

Every feature test class has a private `deployXxx()` method that reimplements the same builder/template pattern against the operator's CRD types. Adding a new optional parameter (e.g. `ExperimentalKmsConfig`) requires touching every one of them. Timing workarounds are scattered across test classes with comments pointing at unresolved issues. The convergence question — "is the proxy actually serving the configuration I just applied?" — is answered by ad hoc polling in each test class rather than by a framework-level contract.

This setup cost has a second-order effect: system tests are written after features merge, delegated to QE because they are too expensive for a developer to include in a feature PR. The test framework is the bottleneck, not the assertions.

The fix required is narrow: a thin setup layer that hides the deployment machinery without changing the assertions at all.

## Motivation

A system test is a precise, executable description of intended behaviour: deploy the proxy in configuration Y (Given), perturb it (When), assert the result (Then). If the framework makes that cheap to express, writing the system test first is feature-level TDD. The test fails until the production code makes it pass, and passing it is the definition of done.

This model has already been validated in the codebase: the checksum annotation mechanism in the operator was built test-first. The system test described what the operator should do; the implementation followed.

Three problems prevent this from being the norm:

1. **Setup cost**: expressing "a proxy with this filter" requires navigating CRD builders, template classes, namespace management, and ingress configuration. The ceremony dwarfs the test.

2. **No convergence contract**: the framework does not define when the proxy is ready. Each test class independently polls for readiness, with varying strategies and varying reliability.

3. **Operator coupling**: every test implicitly requires the operator. Feature tests — which care only that a correctly-configured proxy is serving traffic — cannot run without the full operator installation. This conflates feature correctness with operator correctness and prevents fast local iteration.

Addressing these enables:

- **Test-first development**: a developer writing a new filter can write a failing system test as the first commit of their feature branch, without reading framework documentation or asking QE for help.
- **Deployment-agnostic feature tests**: the same test runs against an operator-managed proxy, a manifest-managed proxy, or a Helm installation, with no changes to the test body.
- **Reliable convergence**: `proxyFixture.apply()` is a blocking call with a defined contract — when it returns, the proxy is serving the requested configuration. Manual polling disappears from test classes.
- **A TCK for downstream distributions**: downstream distributors can implement `ProxyFixture` and run the upstream feature test suite against their distribution without forking the test module.

## Proposal

### The Primary Seam

The framework needs one organising question answered for every test class: **what is this test covering?**

- **Feature tests** — does record encryption work? Does authorisation enforce ACL rules? These tests care only that a correctly-configured proxy exists and is serving traffic. They must not care how the proxy was deployed.

- **Operator tests** — does the operator detect a configuration change and trigger a rolling restart? These tests are explicitly about the operator's reconciliation behaviour. They require the operator to be present.

This is the primary design axis. Everything else — how resources are applied, how convergence is waited for, what assertions are available — follows from it.

A test in the first group is runnable against an operator-managed deployment, a manifest-managed deployment, or any other deployment mechanism. A test in the second group is necessarily operator-only, is tagged accordingly, and skips gracefully when the operator is not present.

### `ProxyScenario` — Intent Without Deployment

A plain Java value object describing what configuration the proxy should have. No knowledge of namespaces, CRD templates, or deployment mechanism.

```java
ProxyScenario scenario = ProxyScenario.builder()
        .withUpstream(clusterName)
        .withFilter(new RecordEncryptionFilterSpec(testKmsFacade))
        .build();

ProxyScenario scenario = ProxyScenario.builder()
        .withUpstream(clusterName)
        .withFilter(new RecordEncryptionFilterSpec(testKmsFacade)
                              .withExperimentalConfig(config))
        .withDownstreamTls(tls)
        .build();
```

### `FilterSpec` — The Filter DSL

`FilterSpec` is an interface for expressing which filter the proxy should run and how it should be configured — in terms of the filter's purpose, not its deployment mechanics. No template classes, no filter type names, no namespaces visible to the test author.

First-party filter types ship named implementations:

```java
new RecordEncryptionFilterSpec(testKmsFacade)
new SimpleTransformFilterSpec("foo", "bar")
```

Custom filter authors implement `FilterSpec` directly for their own filter type, using whatever config model their filter defines. This is the same extension point a developer would use when writing a system test before the filter exists: the `FilterSpec` implementation is the specification.

An escape hatch avoids the need for a dedicated class when one is not justified:

```java
new RawFilterSpec("com.example.MyFilter", new MyFilterConfig(...))
```

### `ProxyFixture` — Application and Convergence

The fixture translates a `ProxyScenario` into running infrastructure, blocks until the proxy has converged, and returns a `ProxyHandle`.

```java
interface ProxyFixture {
    ProxyHandle apply(ProxyScenario scenario);
}
```

This is an explicit call — not magic JUnit injection — because the test author needs to understand that `apply()` is a blocking operation that includes convergence waiting. Hiding it behind injection would obscure the framework's most important contract.

Two implementations cover the primary deployment mechanisms:

**`OperatorProxyFixture`**: applies the Kroxylicious CRDs via Server-Side Apply, then waits for observable convergence signals — the operator has reconciled the resource (e.g. `status.observedGeneration` matches `metadata.generation`) and the Deployment has reached stable state with updated replicas ready and serving. The specific convergence signals may evolve as the operator matures (see [OperatorCapability](#operatorcapability--operator-observable-state)).

**`ManifestProxyFixture`**: translates `ProxyScenario` into a proxy configuration file and a Kubernetes Deployment, applies them, then waits for the Deployment to reach stable state.

Both implementations use Server-Side Apply. Neither requires `createOrUpdate` branching or `resourceVersion` management.

**A note on convergence**: the framework waits for the best observable signal, not a guarantee. There is an inherent gap between "the operator updated the Deployment" and "the new pods are handling traffic." Tests that need stronger guarantees use extension points (described below). The `ProxyFixture` contract is: when `apply()` returns, the proxy is serving the requested configuration to the best observable precision.

### `ProxyHandle` — A Token of Convergence

The only way to obtain a `ProxyHandle` is through `ProxyFixture.apply()`. This means a test cannot accidentally interact with the proxy before convergence has been waited for.

```java
interface ProxyHandle {
    String bootstrap();
    String bootstrap(ClientLocation location);
    ProxyHandle reconfigure(ProxyScenario scenario);
    void waitForRestart();
}
```

`bootstrap()` defaults to `ClientLocation.ON_CLUSTER`. Tests using off-cluster clients call `bootstrap(ClientLocation.OFF_CLUSTER)` to obtain the externally accessible address; the fixture provides the right value for the deployment.

`waitForRestart()` is on `ProxyHandle` rather than on any capability because restarting the proxy is meaningful across all fixture types — on Kubernetes the fixture observes the Deployment rollout; on bare metal the fixture manages the process restart directly. The concept is universal; the mechanism is fixture-specific.

### Injection Model

`ProxyFixture` is injected by the JUnit extension at class scope — it is an environment configuration concern, long-lived, with no timing implications. `ProxyHandle` is always obtained explicitly by calling `proxyFixture.apply()` in the test body. This call is blocking and includes convergence waiting; making it explicit ensures the test author understands the contract.

```java
ProxyHandle proxy = proxyFixture.apply(scenario);  // explicit — convergence visible
```

Tests tagged `@Operator` have `OperatorCapability` injected as a test parameter by the JUnit extension. The tag declares the requirement; if the active fixture does not support the operator, the extension skips the test before it runs.

```java
@Operator
@Test
void testReconciliation(OperatorCapability operator) {
    ProxyHandle proxy = proxyFixture.apply(scenario);
    long generation = operator.observedGeneration(filterResource);
    proxy.reconfigure(updatedScenario);
    operator.waitForReconciliation(filterResource, generation);
}
```

| Concept | How obtained | Reason |
|---|---|---|
| `ProxyFixture` | Injected (class-scoped) | Environment config, no timing implications |
| `OperatorCapability` | Injected for `@Operator` tests | Tag declares requirement; skip handled by extension |
| `ProxyHandle` | Always explicit via `apply()` | Convergence is a blocking operation; must be visible |

### `OperatorCapability` — Operator-Observable State

`OperatorCapability` models the externally observable state of the operator — what an observer can determine by inspecting Kubernetes resource status, not by knowing the operator's internal mechanisms.

```java
interface OperatorCapability {
    long observedGeneration(HasMetadata resource);
    void waitForReconciliation(HasMetadata resource, long sinceGeneration);
    List<StatusCondition> currentStatusConditions();
}
```

`observedGeneration()` returns the generation the operator has most recently reconciled for a given resource. `waitForReconciliation()` blocks until the operator has reconciled past the specified generation. The fixture implementation can use whatever signal backs this — `status.observedGeneration`, annotation changes, or lifecycle state transitions — without affecting the test.

Tests that assert on specific operator mechanisms (e.g. `OperatorChangeDetectionST` verifying that checksum annotations change in response to referent mutations) should observe resource state directly rather than through `OperatorCapability`. Those tests exist to prove a specific mechanism works; abstracting it away would hide the thing being tested.

`waitForRestart()` is intentionally absent — it lives on `ProxyHandle` because it applies to all fixture types. Other capabilities (`MetricsCapability`, `TlsCapability`) follow the same injection pattern for their respective tags.

### `KafkaClient` Abstraction

The existing `KafkaClient` interface with its multiple implementations (StrimziTestClient, KcatClient, KafClient, PythonTestClient) — selected at runtime via environment variable — is the right shape and largely works. The gap is off-cluster support. All current implementations run as Kubernetes jobs; an off-cluster client (an embedded Java client in the test JVM, or a client process on a bare metal host) has no namespace and no container image.

The current interface conflates the core produce/consume contract with Kubernetes-specific machinery:

```java
KafkaClient inNamespace(String namespace);
String getImage();
void preloadImage();
```

These move to a `KubernetesClientCapability`, following the same extension point pattern as `OperatorCapability`:

```java
interface KafkaClient {
    ExecResult produceMessages(...);
    List<ConsumerRecord> consumeMessages(...);
    <C> Optional<C> as(Class<C> capability);
}

interface KubernetesClientCapability {
    KafkaClient inNamespace(String namespace);
    String getImage();
    void preloadImage();
}
```

An off-cluster embedded Java client implements `KafkaClient` only. The existing pod-based clients implement both. Code that pre-pulls images or sets a namespace calls `as(KubernetesClientCapability.class)` and skips gracefully if absent.

**Bootstrap address pairing**: an off-cluster client needs an externally accessible bootstrap address, not the cluster-internal Service DNS. This pairs naturally with `ProxyHandle.bootstrap(ClientLocation)` — the framework wires client location to bootstrap address at test setup time. The test author calls `proxy.bootstrap()` and receives the right address for the client that is configured.

### Cluster Environment

The framework must be runnable across three meaningfully different environments:

| Environment | Characteristics |
|---|---|
| Minikube / local K8s | Local dev path. No OLM. Limited networking. Fast iteration. |
| Vanilla remote K8s | CI path. OLM optional. LoadBalancer or NodePort ingress. |
| OpenShift (OCP) | OLM native. Routes instead of Ingress. Security Context Constraints. |

The principle is that **environment differences are absorbed by the fixture, not exposed to the test**. An `OperatorProxyFixture` on OCP creates a Route; on vanilla K8s it creates a LoadBalancer Service. The test sees only `proxy.bootstrap()`. Cluster environment is a constructor-time or environment-variable-time concern for the fixture implementation.

Where a fixture genuinely cannot run in a given environment — OLM absent, OCP required — it throws `AssumptionViolatedException` and the test skips. This is the same mechanism as `@Operator` and `@AdmissionWebhook` tags, extended to cluster environment. A test run on minikube naturally skips OLM deployment tests and any OCP-specific webhook behaviour tests without configuration.

### Deployment Tests

A separate, lightweight test class per supported install method confirms that the installation mechanism produces a working proxy. Each test is a single scenario: deploy a proxy with a file-based filter (one that reads substitution values from a mounted file), produce a message, assert the consumer sees the transformed value.

This test is deliberately minimal — it is not a feature matrix. Its purpose is to catch installation failures: the plugin does not load, the Secret is not mounted, the file path is wrong. Features are correct by virtue of the feature test suite; the deployment test only asserts that the installation mechanism puts the proxy in a state where features can run.

Each deployment test has a single reason to fail: the consumer did not see the transformed value. Every possible installation failure collapses into that one observable. No separate assertions per failure mode are needed or wanted; they all manifest identically, and the test name tells you which installation mechanism failed.

| Install method | Fixture | File config mechanism |
|---|---|---|
| Operator (Helm) | `OperatorProxyFixture` | Kubernetes Secret mount |
| Operator (OLM) | `OlmProxyFixture` | Kubernetes Secret mount |
| Manifest (Helm, no operator) | `ManifestProxyFixture` | Kubernetes Secret mount |
| Manifest (Kustomize / raw YAML) | `ManifestProxyFixture` | Kubernetes Secret mount |
| Sidecar injection (webhook) | `SidecarProxyFixture` | Kubernetes Secret mount |
| Bare metal | `BareMetalProxyFixture` | File written to local path |

### Admission Webhook Tests

There are two distinct classes of test for the admission webhook.

**Sidecar injection as a deployment path**: `SidecarProxyFixture` creates a pod with the injection annotation, waits for the webhook to mutate it, waits for the sidecar to be ready, and returns a `ProxyHandle`. Feature tests run against it unchanged. The deployment smoke test for this path is the same file-based filter scenario as every other install method — if the sidecar is injected and the plugin loads, the installation mechanism works.

**Webhook behaviour tests**: a separate category that asserts on the Kubernetes API interception layer rather than on proxy behaviour. These tests ask questions that do not produce a `ProxyHandle`: does the webhook inject into pods with annotation X but not Y? Does it produce a valid pod spec? What happens when the webhook is unavailable and `failurePolicy: Ignore`?

These are tagged `@AdmissionWebhook` and skip automatically when the webhook is not installed — the same pattern as `@Operator` tests.

### `ProxyFixture` as a TCK Extension Point

`ProxyFixture` is a plain Java interface with no upstream-specific dependencies in its signature. A downstream distributor can implement `ProxyFixture` without forking the upstream test module.

With a downstream fixture in place, they can run the upstream feature test suite against their distribution:

```bash
mvn test -Pfixture=com.example.downstream.MyProxyFixture
```

The feature test assertions are upstream's; the deployment is downstream's. Upstream maintains the definition of "correct behaviour"; downstream validates that their distribution satisfies it. This is the TCK model — the same seam that separates operator from manifest also separates upstream from downstream.

There is no separate downstream framework to maintain. The extension point is the interface.

### What Feature Tests Look Like

The before/after comparison illustrates the effect of the abstraction on a representative test.

**Before** (current `RecordEncryptionST`):

```java
private void deployPortIdentifiesNodeWithRecordEncryptionFilter(
        TestKmsFacade<?, ?, ?> testKmsFacade, ExperimentalKmsConfig config) {
    String filterName = KROXYLICIOUS_ENCRYPTION_FILTER_NAME + "-"
            + testKmsFacade.getKmsServiceClass().getSimpleName().toLowerCase();
    kroxylicious = new KroxyliciousBuilder()
            .withNamespace(Constants.KROXYLICIOUS_NAMESPACE)
            .withKafkaProxy(KroxyliciousKafkaProxyTemplates
                    .defaultKafkaProxyCR(KROXYLICIOUS_PROXY_SIMPLE_NAME, 1).build())
            .withKafkaProxyIngress(KroxyliciousKafkaProxyIngressTemplates
                    .defaultKafkaProxyIngressCR(KROXYLICIOUS_INGRESS_CLUSTER_IP,
                            KROXYLICIOUS_PROXY_SIMPLE_NAME).build())
            .withKafkaService(KroxyliciousKafkaClusterRefTemplates
                    .defaultKafkaClusterRefCR(clusterName).build())
            .addKafkaProtocolFilter(KroxyliciousFilterTemplates
                    .kroxyliciousRecordEncryptionFilter(KROXYLICIOUS_NAMESPACE,
                            filterName, testKmsFacade, config).build())
            .withVirtualKafkaCluster(KroxyliciousVirtualKafkaClusterTemplates
                    .virtualKafkaClusterWithFilterCR(clusterName,
                            KROXYLICIOUS_PROXY_SIMPLE_NAME, clusterName,
                            KROXYLICIOUS_INGRESS_CLUSTER_IP,
                            List.of(filterName)).build())
            .build();
    kroxylicious.createOrUpdateResources();
}
```

**After**:

```java
@Test
void ensureClusterHasEncryptedMessage(String namespace) {
    testKmsFacade.getTestKekManager().generateKek(KEK_PREFIX + topicName);

    ProxyHandle proxy = proxyFixture.apply(ProxyScenario.builder()
            .withUpstream(clusterName)
            .withFilter(new RecordEncryptionFilterSpec(testKmsFacade))
            .build());

    KafkaSteps.createTopic(namespace, topicName, proxy.bootstrap(), 1, 1);
    KroxyliciousSteps.produceMessages(namespace, topicName, proxy.bootstrap(), MESSAGE, 1);

    var consumed = KroxyliciousSteps.consumeMessageFromKafkaCluster(...);
    assertThat(consumed).allMatch(r -> !r.getPayload().contains(MESSAGE));
}
```

The test contains only the Given/When/Then relevant to record encryption. It works against both an operator-managed and a manifest-managed proxy. It can be written before the filter exists — it will fail (correctly) until the production code makes it pass.

### What Operator Tests Look Like

**Before** (current `OperatorChangeDetectionST`):

```java
@Test
void shouldUpdateWhenFilterConfigurationChanges(String namespace) {
    resourceManager.createOrUpdateResourceFromBuilderWithWait(arbitraryFilterBuilder);
    deployPortIdentifiesNodeWithFilters(namespace, kafkaClusterName, List.of("arbitrary-filter"));

    var originalChecksum = getInitialChecksum(namespace); // ~30 lines of polling
    var replacementConfig = Map.of("transformation", "Replacing",
            "transformationConfig", Map.of("findPattern", "foo", "replacementValue", "updated"));

    resourceManager.replaceResourceWithRetries(arbitraryFilter, current -> {
        current.getSpec().setConfigTemplate(replacementConfig);
    });

    assertDeploymentUpdated(namespace, originalChecksum); // polls checksum annotation
}
```

**After**:

```java
@Operator
@Test
void shouldUpdateWhenFilterConfigurationChanges(OperatorCapability operator) {
    ProxyHandle proxy = proxyFixture.apply(ProxyScenario.builder()
            .withUpstream(clusterName)
            .withFilter(new SimpleTransformFilterSpec("foo", "bar"))
            .build());

    long generation = operator.observedGeneration(arbitraryFilter);

    resourceManager.replaceResourceWithRetries(arbitraryFilter, current ->
            current.getSpec().setConfigTemplate(replacementConfig));

    operator.waitForReconciliation(arbitraryFilter, generation);
}
```

`getInitialChecksum` disappears: `proxyFixture.apply()` blocks until convergence, so `operator.observedGeneration()` is called against stable state — no polling required to establish a baseline. The direct `resourceManager.replaceResourceWithRetries` call is intentionally visible — these tests exist to prove the operator detects and responds to mutations made outside the fixture.

A test like `OperatorChangeDetectionST` that specifically asserts the checksum annotation mechanism works would not use `OperatorCapability` for this — it would read the pod template annotation directly, since the annotation is the thing being tested.

## Affected/Not Affected Projects

**Affected:**
- **kroxylicious-systemtest**: the test framework module. New abstractions (`ProxyScenario`, `FilterSpec`, `ProxyFixture`, `ProxyHandle`, `OperatorCapability`) are introduced here. Existing test classes are migrated incrementally.
- **kroxylicious-operator**: no code changes, but operator-managed system tests are rewritten to use `OperatorProxyFixture` and `OperatorCapability`.

**Not affected:**
- **kroxylicious-proxy (runtime)**: no production code changes. The framework abstracts over the proxy; it does not change it.
- **kroxylicious-api**: the filter SPI is unaffected.
- **kroxylicious-kms and plugin modules**: no changes needed.

## Compatibility

This proposal introduces new framework abstractions alongside the existing code. Existing tests continue to work throughout the migration — the new layer wraps the existing `Kroxylicious` class internally. No test assertions change; only setup code is replaced.

The `ProxyFixture` interface is designed for extension. Downstream distributors can implement it without depending on upstream internals. Once published, the `ProxyFixture`, `ProxyScenario`, and `ProxyHandle` interfaces become API surface for downstream consumers — their signatures should be treated as a compatibility commitment.

## Rejected Alternatives

### Magic JUnit injection of `ProxyHandle`

We considered having the JUnit extension inject `ProxyHandle` directly as a test parameter (similar to how `ProxyFixture` is injected), with convergence waiting happening transparently during parameter resolution. This hides the most important contract in the framework — that `apply()` is a blocking operation — behind invisible lifecycle callbacks. The test author would not see when convergence happens, making it harder to reason about test timing and harder to debug when convergence fails. The explicit `proxyFixture.apply()` call keeps the blocking operation visible.

### Unified `ProxyFixture.apply()` for both feature and operator tests

We considered having operator tests use `proxyFixture.apply()` for all mutations, including the mid-test configuration changes that operator tests need to assert on. However, operator tests exist specifically to prove that the operator detects mutations made outside the fixture — bypassing the fixture for the mid-test mutation is the point of the test. Routing those mutations through the fixture would test the fixture's update path, not the operator's reconciliation behaviour.

### Merging `OperatorCapability` into `ProxyHandle`

We considered putting operator-specific methods (reconciliation observation, status conditions) directly on `ProxyHandle`, with runtime exceptions for unsupported operations. This conflates two concerns: `ProxyHandle` represents a converged proxy regardless of deployment mechanism, while `OperatorCapability` represents state that only exists in operator-managed deployments. Keeping them separate means `ProxyHandle` has no methods that might throw "not supported" — every method on it is meaningful for every fixture type.

### Per-environment fixture implementations

We considered separate fixture classes for each cluster environment (e.g. `MinikubeOperatorProxyFixture`, `OCPOperatorProxyFixture`). This creates a combinatorial explosion of fixture classes and pushes environment-specific logic into class hierarchies. Environment differences are narrower than deployment-mechanism differences: the same `OperatorProxyFixture` can create a Route on OCP and a LoadBalancer Service on vanilla K8s based on a constructor-time environment flag. The fixture class models the deployment mechanism; environment variation is configuration within that class.

### Abstract base class instead of `ProxyFixture` interface

We considered providing an abstract base class with shared convergence-waiting logic rather than a plain interface. This would simplify fixture implementations at the cost of coupling them to the upstream base class. A downstream distributor who needs different convergence behaviour (e.g. polling a proprietary health endpoint) would need to override carefully or bypass the base class entirely. The plain interface is a cleaner extension point — shared convergence utilities can be offered as composition rather than inheritance.