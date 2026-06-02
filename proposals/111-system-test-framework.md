# 111 - System Test Framework

## Summary

Introduce a layered abstraction for system tests that separates test intent from deployment mechanism, and organise tests into modules by what they cover: feature behaviour, operator reconciliation, webhook behaviour, and installation validation.

A `ProxyScenario` describes the desired proxy configuration in deployment-agnostic terms; a `ProxyFixture` translates that into running infrastructure and blocks until convergence; the resulting `ProxyHandle` is a token of convergence that gates all subsequent interaction. An `Installer` — the primary downstream extension point — handles getting the operator, CRDs, and RBAC into the cluster independently of how proxies are deployed.

Feature tests become portable across deployment mechanisms — the same test runs against a CRD-deployed proxy, a manifest-managed proxy, a standalone process, or a downstream distribution — and cheap enough to write before the production code, as a specification.

## Current Situation

The system test suite covers the right things at the right level. Assertions in `RecordEncryptionST`, `AuthorizationST`, and `EntityIsolationST` test feature behaviour cleanly. `OperatorChangeDetectionST` tests operator reconciliation behaviour. The abstraction breaks down only in setup.

Every feature test class has a private `deployXxx()` method that reimplements the same builder/template pattern against the operator's CRD types. Adding a new optional parameter (e.g. `ExperimentalKmsConfig`) requires touching every one of them. Timing workarounds are scattered across test classes with comments pointing at unresolved issues. The convergence question — "is the proxy actually serving the configuration I just applied?" — is answered by ad hoc polling in each test class rather than by a framework-level contract.

This setup cost has a second-order effect: system tests are written after features merge, deferred until after merge and often left as an exercise to others because they are perceived as too expensive for a developer to include in a feature PR. The test framework is the bottleneck, not the assertions.

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
- **A TCK for downstream distributions**: downstream distributors implement `Installer` for their distribution and run upstream's test modules — feature, operator, installer, and webhook — without forking.

## Proposal

### The Primary Seam

The framework needs one organising question answered for every test class: **what is this test covering?** The answer determines which module the test belongs to — not which tag it carries, but which compile-time dependencies it has.

Four categories of system test have fundamentally different concerns:

- **Feature tests** — does record encryption work? Does authorisation enforce ACL rules? These tests care only that a correctly-configured proxy exists and is serving traffic. They must not care how the proxy was deployed. They have no Kubernetes dependency.

- **Operator tests** — does the operator detect a configuration change and trigger a rolling restart? These tests are explicitly about the operator's reconciliation behaviour. They interact with Kubernetes resources directly and depend on the Kubernetes client.

- **Webhook tests** — does the admission webhook inject sidecars into the right pods? Does it produce a valid pod spec? These tests are about the webhook's API interception behaviour, not proxy functionality. They depend on the Kubernetes client and the webhook being installed.

- **Installer tests** — does a specific installation method (OLM, Helm, kustomize, standalone) produce a working proxy? These tests are about the installation mechanism, not the proxy features. The test does not vary between installers — CI provides the matrix.

These are not tags on a single test suite — they are separate modules with different compile-time dependencies:

| Module | Depends on | Kubernetes dependency | Portable across fixtures |
|---|---|---|---|
| `systemtest-feature` | `ProxyFixture`, `ProxyScenario`, `ProxyHandle`, `FilterSpec` | None | Yes — runs against any fixture |
| `systemtest-operator` | Above + `KubernetesCapability`, CRD types, K8s client | Yes | No — requires CRD-based fixture |
| `systemtest-webhook` | Above + `KubernetesCapability`, K8s client | Yes | No — requires webhook installed |
| `systemtest-installer` | Above + `KubernetesCapability` | Yes (except standalone) | No — one test per installer |

Feature tests do not import Kubernetes types. They cannot accidentally depend on CRDs, namespaces, or client libraries. The module boundary enforces this at compile time, not by convention.

All four modules are consumable as a TCK. A downstream distributor runs feature tests to prove their distribution satisfies the proxy's behavioural contract, operator tests to prove reconciliation works with their installation, webhook tests to prove admission webhook behaviour, and installer tests to prove their installation method works.

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

Fixture implementations span two independent concerns: how the infrastructure is installed (CRDs, RBAC, operator Deployment) and how proxy instances are deployed. These concerns are separated by composing a `ProxyFixture` with an `Installer`.

### `Installer` — Infrastructure Installation

`Installer` handles getting the operator, CRDs, RBAC rules, and ServiceAccounts into the cluster. It is a **public interface** — the primary extension point for downstream distributors, who typically vary only by installation method (their own OLM catalog, their own Helm chart) and not by how proxies are deployed.

```java
interface Installer {
    void install();
    void uninstall();
}
```

Upstream ships implementations for each supported installation method:

| Installer | What it installs |
|---|---|
| `ManifestInstaller` | Operator via kustomize/raw manifests (upstream default) |
| `HelmInstaller` | Operator via Helm chart |
| `OlmInstaller` | Operator via OLM catalog |

A downstream distributor implements `Installer` for their distribution and composes it with upstream's fixture — no need to reimplement proxy deployment or convergence logic.

### Fixture Implementations

Tests never instantiate fixtures or installers — the JUnit extension reads system properties (`-Dfixture`, `-Dinstaller`) and composes them. The composition is extension-internal; the test sees only an injected `ProxyFixture`.

Four fixture implementations cover the deployment mechanisms:

**`CrdProxyFixture`**: takes an `Installer` as a constructor dependency. The installer puts the operator into the cluster; the fixture applies Kroxylicious CRDs (`KafkaProxy`, `VirtualKafkaCluster`, `KafkaProtocolFilter`) via Server-Side Apply, then waits for observable convergence signals — the controller has reconciled the resources and the Deployment has reached stable state with updated replicas ready and serving. The fixture knows the CRD schema and the convergence protocol, not the operator's internals.

**`ManifestProxyFixture`**: translates `ProxyScenario` into a proxy configuration file and a Kubernetes Deployment, applies them, then waits for the Deployment to reach stable state. No operator or installer required.

**`SidecarProxyFixture`**: takes an `Installer` as a constructor dependency. The installer puts the operator and admission webhook into the cluster; the fixture creates a pod with the injection annotation, waits for the webhook to mutate it and the sidecar to be ready, then returns a `ProxyHandle`. Feature tests run against it unchanged — the proxy happens to be a sidecar rather than a standalone Deployment.

**`StandaloneProxyFixture`**: starts the proxy as a local Java process with a generated configuration file, waits for the port to be ready, and returns a `ProxyHandle` with a localhost bootstrap. No Kubernetes, no installer, no namespaces. `KubernetesCapability` is not available for tests running against this fixture.

Kubernetes fixtures use Server-Side Apply. Neither `CrdProxyFixture` nor `ManifestProxyFixture` requires `createOrUpdate` branching or `resourceVersion` management.

**A note on convergence**: the framework waits for the best observable signal, not a guarantee. There is an inherent gap between "the operator updated the Deployment" and "the new pods are handling traffic." The `ProxyFixture` contract is: when `apply()` returns, the proxy is serving the requested configuration to the best observable precision.

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

### Injection Model and Tags

`ProxyFixture` is injected by the JUnit extension at class scope — it is an environment configuration concern, long-lived, with no timing implications. `ProxyHandle` is always obtained explicitly by calling `proxyFixture.apply()` in the test body. This call is blocking and includes convergence waiting; making it explicit ensures the test author understands the contract.

```java
ProxyHandle proxy = proxyFixture.apply(scenario);  // explicit — convergence visible
```

**Tags as skip conditions**: module boundaries are the primary separation — `systemtest-operator` tests have compile-time Kubernetes dependencies that `systemtest-feature` tests do not. Within Kubernetes-dependent modules, `@Operator` and `@AdmissionWebhook` tags serve as runtime skip conditions: if the required component is not present in the active fixture, the extension skips the test. Tags declare requirements — they do not select fixtures. Fixture and installer selection is by system property (see [Fixture and Installer Selection](#fixture-and-installer-selection)).

**`KubernetesCapability`**: any test running on Kubernetes can have `KubernetesCapability` injected as a test parameter. This provides general-purpose access to the cluster environment — the namespace the proxy was deployed into and a `KubernetesClient` for observing resource state. Tests running on bare metal do not have `KubernetesCapability` available.

| Concept | How obtained | Reason |
|---|---|---|
| `ProxyFixture` | Injected (class-scoped) | Environment config, no timing implications |
| `KubernetesCapability` | Injected for Kubernetes-deployed tests | Namespace and client access for resource observation |
| `ProxyHandle` | Always explicit via `apply()` | Convergence is a blocking operation; must be visible |

### `KubernetesCapability` — Cluster Environment Access

`KubernetesCapability` provides access to the Kubernetes environment the proxy was deployed into. It is not operator-specific — it is available for any Kubernetes-backed fixture (operator, manifest, sidecar).

```java
interface KubernetesCapability {
    String namespace();
    KubernetesClient client();
}
```

The namespace is managed by the fixture. Each `apply()` call deploys into a namespace the fixture controls; the test discovers it through the capability rather than supplying it. This keeps `ProxyScenario` free of deployment concerns while giving tests the access they need for resource observation and client operations.

### Tags and Component Requirements

`@Operator` and `@AdmissionWebhook` are skip tags — they declare that a test requires a specific component and cause the extension to skip the test if that component is not present. The operator itself is infrastructure: the extension uses the configured `Installer` to deploy it before operator-tagged tests run.

The test does not interact with the operator directly. It interacts with the proxy (via `ProxyHandle`) and with Kubernetes resources (via `KubernetesCapability`). The operator is the mechanism that makes the proxy appear in response to CRDs; the test observes the result, not the mechanism.

### Fixture and Installer Selection

Fixture and installer are selected independently via system properties:

```bash
# Default upstream: operator installed via manifests, proxy deployed via CRDs
mvn test -Dfixture=crd -Dinstaller=manifest

# OLM installation
mvn test -Dfixture=crd -Dinstaller=olm

# Downstream custom installer, upstream fixture
mvn test -Dfixture=crd -Dinstaller=com.example.downstream.MyInstaller

# Manifest-managed proxy (no operator)
mvn test -Dfixture=manifest

# Standalone
mvn test -Dfixture=standalone
```

The extension composes them: it instantiates the installer, passes it to the fixture constructor, and manages the lifecycle. When `-Dinstaller` is not specified, the fixture uses its default (`ManifestInstaller` for operator fixtures). Standalone and manifest fixtures do not take an installer.

If a test in `systemtest-operator` runs but the active fixture is `ManifestProxyFixture` or `StandaloneProxyFixture`, the test skips — the operator is not present, and the fixture cannot satisfy the requirement.

### `KafkaClient` Abstraction

The existing `KafkaClient` interface with its multiple implementations (StrimziTestClient, KcatClient, KafClient, PythonTestClient) — selected at runtime via environment variable — is the right shape and largely works. The gap is off-cluster support. All current implementations run as Kubernetes jobs; an off-cluster client (an embedded Java client in the test JVM, or a client process on a bare metal host) has no namespace and no container image.

The current interface conflates the core produce/consume contract with Kubernetes-specific machinery:

```java
KafkaClient inNamespace(String namespace);
String getImage();
void preloadImage();
```

These move to a `KubernetesClientCapability`:

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

The principle is that **environment differences are absorbed by the fixture, not exposed to the test**. A `CrdProxyFixture` on OCP creates a Route; on vanilla K8s it creates a LoadBalancer Service. The test sees only `proxy.bootstrap()`. Cluster environment is a constructor-time or environment-variable-time concern for the fixture implementation.

Where a fixture genuinely cannot run in a given environment — OLM absent, OCP required — it throws `AssumptionViolatedException` and the test skips. This is the same mechanism as `@Operator` and `@AdmissionWebhook` tags, extended to cluster environment. A test run on minikube naturally skips OLM deployment tests and any OCP-specific webhook behaviour tests without configuration.

### Installer Tests

The `systemtest-installer` module contains a single smoke test: deploy a proxy with a file-based filter (one that reads substitution values from a mounted file), produce a message, assert the consumer sees the transformed value. The test does not vary between installers — it is the same test run with different `-Dinstaller` and `-Dfixture` values. CI provides the matrix; the test provides the assertion.

This test is deliberately minimal — it is not a feature matrix. Its purpose is to catch installation failures: the plugin does not load, the Secret is not mounted, the file path is wrong. Features are correct by virtue of the `systemtest-feature` module; the installer test only asserts that the installation mechanism puts the proxy in a state where features can run.

Each installer test run has a single reason to fail: the consumer did not see the transformed value. Every possible installation failure collapses into that one observable. No separate assertions per failure mode are needed or wanted; they all manifest identically, and the CI matrix entry tells you which installation mechanism failed.

| Install method | Fixture | Installer | File config mechanism |
|---|---|---|---|
| CRD (manifests) | `CrdProxyFixture` | `ManifestInstaller` | Kubernetes Secret mount |
| CRD (Helm) | `CrdProxyFixture` | `HelmInstaller` | Kubernetes Secret mount |
| CRD (OLM) | `CrdProxyFixture` | `OlmInstaller` | Kubernetes Secret mount |
| Manifest (Helm, no operator) | `ManifestProxyFixture` | — | Kubernetes Secret mount |
| Manifest (Kustomize / raw YAML) | `ManifestProxyFixture` | — | Kubernetes Secret mount |
| Sidecar injection (webhook) | `SidecarProxyFixture` | `ManifestInstaller` | Kubernetes Secret mount |
| Standalone | `StandaloneProxyFixture` | — | File written to local path |

### Webhook Tests

The webhook touches two modules:

**As a deployment path** (`systemtest-installer`): `SidecarProxyFixture` is an installer test entry in the matrix — it proves that sidecar injection produces a working proxy. The same single smoke test runs against it. Feature tests in `systemtest-feature` also run against `SidecarProxyFixture` unchanged.

**As behaviour under test** (`systemtest-webhook`): a separate module that asserts on the webhook's API interception behaviour. These tests ask questions that do not produce a `ProxyHandle`: does the webhook inject into pods with annotation X but not Y? Does it produce a valid pod spec? What happens when the webhook is unavailable and `failurePolicy: Ignore`? These tests depend on `KubernetesCapability` and require the webhook to be installed.

### TCK Extension Points

The framework provides two public interfaces for downstream extensibility: `ProxyFixture` and `Installer`.

Most downstream distributors differ only in how the operator is installed — their own OLM catalog, their own Helm chart, a different RBAC configuration. These distributors implement `Installer` and compose it with upstream's `CrdProxyFixture`, inheriting all proxy deployment and convergence logic:

```bash
mvn test -Dfixture=crd -Dinstaller=com.example.downstream.MyInstaller
```

Distributors with fundamentally different deployment models (e.g. a custom orchestrator, a managed service) implement `ProxyFixture` directly. Both interfaces have no upstream-specific dependencies in their signatures.

All four test modules are consumable as a TCK:

- **`systemtest-feature`**: downstream proves their distribution satisfies the proxy's behavioural contract — features work regardless of installation method.
- **`systemtest-installer`**: downstream proves their installation method produces a working system — their OLM catalog installs correctly, their Helm chart renders valid resources.
- **`systemtest-operator`**: downstream proves operator reconciliation works with their installation — change detection, status conditions, rolling restarts all function correctly.
- **`systemtest-webhook`**: downstream proves admission webhook behaviour works with their installation — sidecar injection targets the right pods, produces valid pod specs, and respects failure policies.

Upstream maintains the definition of correct behaviour across all four modules; downstream provides the `Installer` (and optionally the `ProxyFixture`) that adapts the tests to their distribution.

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
void ensureClusterHasEncryptedMessage() {
    testKmsFacade.getTestKekManager().generateKek(KEK_PREFIX + topicName);

    ProxyHandle proxy = proxyFixture.apply(ProxyScenario.builder()
            .withUpstream(clusterName)
            .withFilter(new RecordEncryptionFilterSpec(testKmsFacade))
            .build());

    kafkaClient.createTopic(topicName, proxy.bootstrap(), 1, 1);
    kafkaClient.produceMessages(topicName, proxy.bootstrap(), MESSAGE, 1);

    var consumed = kafkaClient.consumeMessages(topicName, proxy.bootstrap(), 1);
    assertThat(consumed).allMatch(r -> !r.getPayload().contains(MESSAGE));
}
```

The test contains only the Given/When/Then relevant to record encryption. No Kubernetes imports, no namespace — this is a `systemtest-feature` test. It works against a CRD-deployed proxy, a manifest-managed proxy, a sidecar, or a standalone process. It can be written before the filter exists — it will fail (correctly) until the production code makes it pass.

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
void shouldUpdateWhenFilterConfigurationChanges(KubernetesCapability kube) {
    ProxyHandle proxy = proxyFixture.apply(ProxyScenario.builder()
            .withUpstream(clusterName)
            .withFilter(new SimpleTransformFilterSpec("foo", "bar"))
            .build());

    String beforeChecksum = readChecksumAnnotation(kube.client(), kube.namespace());

    kube.client().resources(KafkaProtocolFilter.class)
            .inNamespace(kube.namespace())
            .withName(filterName)
            .edit(current -> {
                current.getSpec().setConfigTemplate(replacementConfig);
                return current;
            });

    await().until(
            () -> readChecksumAnnotation(kube.client(), kube.namespace()),
            not(equalTo(beforeChecksum)));
}
```

`getInitialChecksum` disappears: `proxyFixture.apply()` blocks until convergence, so `readChecksumAnnotation()` is called against stable state — no polling required to establish the baseline. This test lives in the `systemtest-operator` module, which has compile-time access to `KubernetesCapability` and the CRD types. The test does not interact with the operator directly — it observes the operator's effect on Kubernetes resources. The resource mutation is intentionally direct — this test exists to prove the operator detects and responds to changes made outside the fixture.

## Affected/Not Affected Projects

**Affected:**
- **systemtest-feature**: new module. Feature tests migrated here. Depends only on the framework abstractions (`ProxyFixture`, `ProxyScenario`, `ProxyHandle`, `FilterSpec`). No Kubernetes dependency.
- **systemtest-operator**: new module. Operator behaviour tests (`OperatorChangeDetectionST`) migrated here. Depends on `KubernetesCapability` and CRD types.
- **systemtest-webhook**: new module. Webhook behaviour tests migrated here. Depends on `KubernetesCapability`.
- **systemtest-installer**: new module. One deployment smoke test, run across the installer/fixture matrix by CI.
- **kroxylicious-systemtest (framework)**: the shared framework module providing `ProxyFixture`, `Installer`, `ProxyScenario`, `ProxyHandle`, `KubernetesCapability`, and fixture implementations.
- **kroxylicious-operator**: no code changes, but operator-managed system tests move to `systemtest-operator`.

**Not affected:**
- **kroxylicious-proxy (runtime)**: no production code changes. The framework abstracts over the proxy; it does not change it.
- **kroxylicious-api**: the filter SPI is unaffected.
- **kroxylicious-kms and plugin modules**: no changes needed.

## Compatibility

This proposal introduces new framework abstractions alongside the existing code. Existing tests continue to work throughout the migration — the new layer wraps the existing `Kroxylicious` class internally. No test assertions change; only setup code is replaced.

The `ProxyFixture` and `Installer` interfaces are designed for extension. Downstream distributors typically implement `Installer` and compose it with upstream fixtures; distributors with fundamentally different deployment models implement `ProxyFixture` directly. Once published, `ProxyFixture`, `Installer`, `ProxyScenario`, and `ProxyHandle` become API surface for downstream consumers — their signatures should be treated as a compatibility commitment.

## Rejected Alternatives

### Magic JUnit injection of `ProxyHandle`

We considered having the JUnit extension inject `ProxyHandle` directly as a test parameter (similar to how `ProxyFixture` is injected), with convergence waiting happening transparently during parameter resolution. This hides the most important contract in the framework — that `apply()` is a blocking operation — behind invisible lifecycle callbacks. The test author would not see when convergence happens, making it harder to reason about test timing and harder to debug when convergence fails. The explicit `proxyFixture.apply()` call keeps the blocking operation visible.

### Unified `ProxyFixture.apply()` for both feature and operator tests

We considered having operator tests use `proxyFixture.apply()` for all mutations, including the mid-test configuration changes that operator tests need to assert on. However, operator tests exist specifically to prove that the operator detects mutations made outside the fixture — bypassing the fixture for the mid-test mutation is the point of the test. Routing those mutations through the fixture would test the fixture's update path, not the operator's reconciliation behaviour.

### `OperatorCapability` as a test-facing API

We considered exposing an `OperatorCapability` interface to tests, providing methods like `observedGeneration()`, `waitForReconciliation()`, and `currentStatusConditions()`. This would give operator tests a typed API for interacting with the operator's observable state.

On closer examination, operator tests do not need to interact with the operator — they observe its effects on Kubernetes resources. The change detection test reads a checksum annotation; the status condition test reads a resource's status. Both are Kubernetes API observations, not operator interactions. `KubernetesCapability` provides everything these tests need. The operator is infrastructure the extension manages; the `@Operator` tag ensures it is present. Making the operator invisible to the test keeps `ProxyHandle` deployment-agnostic and avoids an abstraction that doesn't carry its weight.

### Merging `KubernetesCapability` into `ProxyHandle`

We considered putting Kubernetes-specific methods (namespace, client access) directly on `ProxyHandle`. This would make `ProxyHandle` Kubernetes-aware, breaking its deployment-agnostic contract — a bare metal `ProxyHandle` has no namespace. Keeping them separate means every method on `ProxyHandle` is meaningful for every fixture type.

### Fixture selection via ServiceLoader

We considered using `ServiceLoader` to discover `ProxyFixture` implementations automatically from the classpath. This creates ambiguity when multiple fixture implementations are present (e.g. both OLM and Helm operator fixtures) and makes test runs non-deterministic. An explicit system property or Maven profile provides clear, reproducible fixture selection and composes naturally with CI matrix builds.

### Per-environment fixture implementations

We considered separate fixture classes for each cluster environment (e.g. `MinikubeCrdProxyFixture`, `OCPCrdProxyFixture`). This creates a combinatorial explosion of fixture classes and pushes environment-specific logic into class hierarchies. Environment differences are narrower than deployment-mechanism differences: the same `CrdProxyFixture` can create a Route on OCP and a LoadBalancer Service on vanilla K8s based on a constructor-time environment flag. The fixture class models the deployment mechanism; environment variation is configuration within that class.

### `Installer` as extension-internal

We considered hiding `Installer` as an extension-internal interface, with downstream distributors implementing the full `ProxyFixture`. However, downstream typically varies only by installation method (their own OLM catalog, their own Helm chart) and not by how proxies are deployed or converged. Making `Installer` public lets downstream write a single class and compose it with upstream's fixture, inheriting all proxy deployment and convergence logic. Forcing them to reimplement `ProxyFixture` for a difference that is entirely in the installation dimension wastes effort and risks divergence.

### Abstract base class instead of `ProxyFixture` interface

We considered providing an abstract base class with shared convergence-waiting logic rather than a plain interface. This would simplify fixture implementations at the cost of coupling them to the upstream base class. A downstream distributor who needs different convergence behaviour (e.g. polling a proprietary health endpoint) would need to override carefully or bypass the base class entirely. The plain interface is a cleaner extension point — shared convergence utilities can be offered as composition rather than inheritance.