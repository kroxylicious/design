# 117 - Virtual Cluster Config Controller SPI

**Builds on:** [Proposal 083 — Changing Active Proxy Configuration](https://github.com/kroxylicious/design/blob/main/proposals/083-hot-reload-feature.md)

This proposal defines a pluggable Service Provider Interface (SPI) for controlling virtual cluster configuration — sourcing it, detecting changes, and driving `KafkaProxy.reconfigure()`. Controller implementations are discovered via `ServiceLoader`, configured in the proxy's process configuration, and are the sole source of virtual cluster configuration — including the initial load at startup. The proposal introduces a logical split between **process configuration** (static settings read once at startup) and **virtual cluster configuration** (virtual clusters, filters, and plugins delivered via `Snapshot`). The SPI formalises the controller responsibilities established during the design of Proposal 083 and provides the extension point that allows different deployment models — standalone, Kubernetes, embedded — to use different reconfiguration strategies without proxy changes.

## Current situation

Proposal 083 delivered `KafkaProxy.reconfigure(Configuration)` — the core mechanism for applying configuration changes to a running proxy without a full restart. The method accepts a complete `Configuration`, detects what changed, and converges the running state to match.

However, nothing calls `reconfigure()` today. The standalone binary (`kroxylicious-app`) has no way to apply configuration changes at runtime. Operators who embed the proxy can call `reconfigure()` directly from their own code, but the project-shipped binary needs a controller mechanism to make hot reload usable.

During the Proposal 083 review, several mechanisms were discussed — file watchers, HTTP endpoints, and operator callbacks — but all were explicitly deferred to keep that proposal focused on the reconfiguration machinery itself. The discussion also established that the controller of virtual cluster configuration carries significant responsibility: configuration sourcing, static validation, failure policy, rollback, concurrency handling, debouncing, and configuration persistence. These responsibilities need a formal contract.

## Motivation

- **The shipped binary needs hot reload.** Without a controller mechanism, `kroxylicious-app` cannot use the reconfiguration capability that Proposal 083 introduced. Configuration changes still require a full process restart.

- **Different deployments need different controllers.** A bare-metal deployment watching a config file has different requirements from a Kubernetes operator reconciling a CRD, which has different requirements from a custom control plane using an HTTP API. The controller mechanism must be pluggable.

- **Controller authors need a contract.** Proposal 083 pushed substantial responsibility onto the caller of `reconfigure()` — failure policy, rollback, concurrency handling — but that responsibility is currently documented only in PR comments. A formal SPI with documented responsibilities makes it possible for third parties to write correct controller implementations.

## Proposal

### SPI overview

The controller SPI consists of three interfaces:

- **`VirtualClusterConfigController`** — the controller implementation itself, created by the factory. It sources virtual cluster configuration, detects changes, and drives `reconfigure()`.
- **`VirtualClusterConfigControllerFactory`** — discovered via `ServiceLoader`, responsible for creating a `VirtualClusterConfigController` from its typed configuration.
- **`VirtualClusterConfigControllerContext`** — provided by the runtime, gives the controller access to `reconfigure()`, `validate()`, and `shutdown()`. Controllers provide configuration as a `Snapshot` (adopted from Proposal 096) — a source-agnostic representation of the virtual cluster configuration that decouples the controller from the configuration format.

The name "controller" borrows from the Kubernetes controller pattern: a control loop that watches desired state, detects drift, and reconciles. A `VirtualClusterConfigController` does the same — it watches a configuration source, detects changes, and reconciles the proxy's running state to match via `reconfigure()`. The failure handling, retry, and rollback responsibilities are natural parts of this reconciliation loop.

A proxy has at most one active controller. Controllers are not composable (unlike filters in a chain). When no controller is configured, the proxy operates as it does today — hot reload is not available.

### `VirtualClusterConfigController`

```java
/**
 * A virtual cluster config controller is the sole source of virtual cluster
 * configuration for the proxy. It sources configuration, detects changes,
 * and drives reconfiguration via
 * {@link VirtualClusterConfigControllerContext#reconfigure(Snapshot)} in both cases.
 *
 * <h2>Lifecycle</h2>
 * <p>A controller instance is created by its {@link VirtualClusterConfigControllerFactory}
 * and has proxy-level lifecycle: one instance exists per proxy, and it lives
 * for the lifetime of the proxy process.
 *
 * <ul>
 *   <li>{@link #start()} is called after the proxy has completed its bootstrap
 *       (management endpoints, metrics) but before any virtual clusters exist.
 *       The controller must perform the initial configuration load — reading its
 *       source, constructing a {@link Snapshot}, and calling
 *       {@link VirtualClusterConfigControllerContext#reconfigure(Snapshot)} — before
 *       setting up background watching for subsequent changes.</li>
 *   <li>{@link #close()} is called before proxy shutdown begins. The controller
 *       should stop watching, release resources, and return promptly. Any
 *       in-flight {@code reconfigure()} call will complete independently.</li>
 * </ul>
 *
 * <h2>Threading</h2>
 * <p>{@code start()} and {@code close()} are called on the proxy's main thread.
 * The initial configuration load within {@code start()} happens synchronously
 * on the calling thread. Subsequent change detection (file watching, HTTP
 * listening) should happen on background threads managed by the controller.
 * {@code reconfigure()} is thread-safe and may be called from any thread.
 *
 * <h2>Controller responsibilities</h2>
 * <p>See the "Controller responsibilities" section of this proposal for the full
 * contract that controller implementations must follow.
 */
public interface VirtualClusterConfigController extends Closeable {

    /**
     * Perform the initial configuration load and begin watching for changes.
     *
     * <p>Called once, after the proxy has completed its bootstrap. The proxy
     * has no virtual clusters at this point — the controller must load the
     * current configuration from its source, construct a {@link Snapshot},
     * and call {@link VirtualClusterConfigControllerContext#reconfigure(Snapshot)}
     * to bring virtual clusters to life. Only after the initial load
     * succeeds should the controller set up background watching for subsequent
     * changes.
     *
     * <p>The initial load is synchronous: this method should not return
     * until the first {@code reconfigure()} call has completed. Background
     * watching for subsequent changes should be set up before returning.
     *
     * @throws Exception if the controller cannot start (e.g. cannot read the
     *         configuration source, cannot open a watch on the configuration
     *         file, cannot bind an HTTP port). If this method throws, the
     *         proxy will exit — an empty proxy with no virtual clusters is
     *         not useful.
     */
    void start() throws Exception;

    /**
     * Stop watching and release resources. Called before proxy shutdown.
     */
    @Override
    void close();
}
```

### `VirtualClusterConfigControllerFactory`

```java
/**
 * Factory for creating {@link VirtualClusterConfigController} instances. Discovered
 * via {@link java.util.ServiceLoader}.
 *
 * <p>Each factory declares the type of its configuration object via
 * {@link #configType()}. The runtime deserialises the controller-specific
 * configuration from the proxy's process configuration and passes it to
 * {@link #create(VirtualClusterConfigControllerContext, Object)}.
 *
 * @param <C> the controller-specific configuration type. Must be deserializable
 *            from YAML by Jackson.
 */
public interface VirtualClusterConfigControllerFactory<C> {

    /**
     * Creates a new controller instance.
     *
     * <p>The controller is not yet active — the caller will invoke
     * {@link VirtualClusterConfigController#start()} after this method returns.
     *
     * @param context provides access to reconfigure() and configuration parsing
     * @param config  the controller-specific configuration, deserialized from YAML
     * @return a new controller instance, ready to be started
     * @throws Exception if the controller cannot be constructed (e.g. invalid
     *         configuration values)
     */
    VirtualClusterConfigController create(VirtualClusterConfigControllerContext context, C config) throws Exception;

    /**
     * Returns the type of the controller-specific configuration object.
     * The runtime uses this to deserialize the {@code config:} section of the
     * controller's process configuration block.
     *
     * @return the configuration class
     */
    Class<C> configType();
}
```

### `Snapshot`

Controllers deliver configuration to the runtime as a `Snapshot` — a source-agnostic representation of the desired virtual cluster configuration (virtual clusters, filters, plugin instances). A `Snapshot` does not include process configuration (management, metrics, controller settings) — that is read once at startup and is not the controller's concern.

The `Snapshot` type is adopted from [Proposal 096 — Reworking proxy configuration](https://github.com/kroxylicious/design/pull/96), where it is described as an internal runtime abstraction. This proposal promotes `Snapshot` to public API so that controllers can produce configuration from any source without coupling to the configuration format.

For the current configuration model, a `Snapshot` wraps the virtual-cluster portions of the proxy's YAML. As the configuration format evolves, the same `Snapshot` interface can support richer representations — multi-file layouts, Kubernetes-backed configurations, in-memory representations — without any change to the controller SPI.

The `Snapshot` interface is defined in Proposal 096. This proposal does not redefine it; it adopts it as-is.

### `VirtualClusterConfigControllerContext`

```java
/**
 * Runtime context provided to a {@link VirtualClusterConfigController}. This is the
 * controller's view of the proxy — controllers never interact with
 * {@code KafkaProxy} directly.
 *
 * <p>The context provides three capabilities:
 * <ul>
 *   <li><b>Reconfiguration</b> — {@link #reconfigure(Snapshot)} drives
 *       the proxy to converge to a new configuration. The controller provides
 *       a {@link Snapshot} representing the desired virtual cluster configuration; the
 *       runtime handles parsing and change detection internally.</li>
 *   <li><b>Validation</b> — {@link #validate(Snapshot)} allows controllers to
 *       pre-validate a snapshot before applying it, catching structural
 *       errors before any virtual cluster experiences downtime. Returns a
 *       {@link ValidationResult} with errors deduplicated by root cause.</li>
 *   <li><b>Proxy lifecycle</b> — {@link #shutdown()} initiates an orderly
 *       proxy shutdown, enabling failure policies that terminate the proxy
 *       on unrecoverable errors.</li>
 * </ul>
 *
 * <p>The context is thread-safe. All methods may be called from any thread.
 */
public interface VirtualClusterConfigControllerContext {

    /**
     * Apply a new configuration to the running proxy. The runtime parses the
     * snapshot, detects what changed, and converges the running state to match.
     * See {@link KafkaProxy#reconfigure} (Proposal 083) for the full contract
     * including error reporting and concurrency control.
     *
     * <p>This method handles both the initial load (when no virtual clusters
     * exist) and subsequent reconfigurations. The controller calls it in both
     * cases — the runtime handles the "from nothing to something" case
     * naturally.
     *
     * @param newConfig a snapshot representing the desired virtual cluster
     *                  configuration (virtual clusters, filters, plugins)
     * @return a future that completes with a {@link ReconfigureResult}
     *         describing any per-component failures, or completes
     *         exceptionally on catastrophic failure or input rejection
     */
    CompletableFuture<ReconfigureResult> reconfigure(Snapshot newConfig);

    /**
     * Initiate an orderly shutdown of the proxy.
     *
     * <p>Controllers use this to implement failure policies that terminate the
     * proxy on unrecoverable errors — for example, shutting down when
     * {@code reconfigure()} returns non-empty {@code errors()}, or as a
     * last resort when a rollback attempt itself fails.
     *
     * <p>This method returns immediately; the actual shutdown proceeds
     * asynchronously. The controller's {@link VirtualClusterConfigController#close()}
     * method will be called as part of the shutdown sequence.
     */
    void shutdown();

    /**
     * Validate a snapshot without applying it. Performs the same pre-flight
     * checks that {@link #reconfigure(Snapshot)} would perform before
     * beginning any state-changing work — parsing and static validation.
     *
     * <p>A controller can use this to implement a two-phase workflow:
     * validate first, then apply only if validation passes. This catches
     * problems before any virtual cluster experiences downtime.
     *
     * <p>A successful validation does not guarantee that a subsequent
     * {@code reconfigure()} call will succeed — runtime conditions (port
     * availability, upstream reachability) may change between validation
     * and application. But it does guarantee that the snapshot will not be
     * rejected for structural reasons.
     *
     * <p>The returned {@link ValidationResult} collects all errors found
     * during validation, deduplicated by root cause. For example, if a
     * single unknown filter type is referenced by multiple virtual clusters,
     * the result reports the root cause once rather than once per usage.
     * This prevents cascading errors from obscuring the actual problem.
     *
     * @param config the snapshot to validate
     * @return a {@link ValidationResult} describing any validation errors.
     *         Call {@link ValidationResult#isValid()} to check whether the
     *         snapshot passed validation.
     */
    ValidationResult validate(Snapshot config);
}
```

### Process configuration and virtual cluster configuration

This proposal introduces a logical split in proxy configuration:

- **Process configuration** — static settings read once at startup: management endpoints, metrics, admin, and the controller selection and configuration. These cannot change without a process restart. Process configuration is everything required to start a live proxy process.

- **Virtual cluster configuration** — virtual clusters, filters, and plugin instances. This is the configuration that changes at runtime — everything required to make the proxy do something users care about. It is always delivered as a `Snapshot` via `reconfigure()`, and the controller is the sole source — including for the initial load at startup.

This split formalises what Proposal 083 established implicitly: `reconfigure()` only applies virtual-cluster and filter configuration, and rejects changes to management, metrics, or admin sections. Rather than detecting out-of-scope changes in a monolithic configuration and rejecting them, the split separates the concerns logically. Snapshots contain only virtual cluster configuration, so there is nothing out-of-scope to detect.

How the logical split manifests on disk — whether process and virtual cluster configuration live in the same file, separate files, or separate directories — is a configuration format concern outside the scope of this proposal. What matters for the controller SPI is the contract: the controller produces `Snapshot` objects containing virtual cluster configuration, and the runtime handles process configuration independently.

The controller is selected and configured within the process configuration. This follows the same `type` + `config` pattern used by filters, routers, and other Kroxylicious plugins:

```yaml
virtualClusterConfigController:
  type: FileWatcher
  config:
    debounceInterval: 1s
```

When the `virtualClusterConfigController` section is absent, no controller is created and the proxy operates as today — configuration is loaded at startup and changes require a restart.

The process/virtual-cluster split has a direct consequence for the controller lifecycle: because the controller is the sole source of virtual cluster configuration, the proxy starts in an **empty state** — process infrastructure (management endpoints, metrics) is running but no virtual clusters exist. The controller's first `reconfigure()` call brings up the virtual clusters. This is described in detail in the [Controller lifecycle](#controller-lifecycle) section.

### Controller responsibilities

Proposal 083 defined `KafkaProxy.reconfigure()` as a minimal operation that reports outcomes without taking policy action. This was a deliberate design choice — it pushes failure handling, rollback, and operational policy onto the caller. For controllers, "the caller" is the controller implementation. The following responsibilities form the contract that controller implementations must satisfy.

#### Configuration sourcing

The controller is responsible for obtaining and delivering a new `Snapshot` to `reconfigure()`. How the snapshot is produced — watching a filesystem directory, receiving an HTTP request, responding to a CRD reconciliation — is the controller's concern. The `Snapshot` abstraction (adopted from Proposal 096) decouples the controller from the configuration format: a file watcher produces a filesystem-backed snapshot, an operator produces a Kubernetes-backed snapshot, and so on. The runtime handles parsing and validation internally.

#### Validation

Controllers can use `validate(Snapshot)` to pre-validate a snapshot before applying it. This performs the same pre-flight checks as `reconfigure()` — parsing and static validation — without modifying any running state. The returned `ValidationResult` collects all errors found during validation, deduplicated by root cause — so a single misconfigured plugin referenced by many virtual clusters produces one error, not one per usage. This enables a validate-then-apply workflow that catches problems before any virtual cluster experiences downtime.

#### Failure policy

The proxy does not act on `ReconfigureResult.errors()`. The controller expresses its failure policy via `whenComplete()` on the returned future. Three canonical patterns are defined in Proposal 083:

- **Shut down on any failure** — call `context.shutdown()` if `errors()` is non-empty
- **Best-effort** — log failures, take no proxy-level action; surviving VCs continue serving
- **Rollback on failure** — call `reconfigure(oldConfig)` when `errors()` is non-empty

The choice between these (or a custom policy) is the controller's decision, typically determined at deployment time by the controller's configuration or hardcoded by the controller implementation.

#### Previous configuration tracking

Controllers that support rollback must maintain their own record of the previous known-good `Snapshot`. The proxy does not expose a getter for its running configuration. Controllers typically have a natural source-of-truth for this: a previous filesystem snapshot, a ConfigMap revision, an HTTP request history.

#### Concurrency handling

`reconfigure()` rejects concurrent calls with `ConcurrentReconfigureException` (the future completes exceptionally). The controller **must not** treat this as a real failure:

- **Do not shut down** — the proxy is healthy; another reconfiguration is in flight.
- **Do not roll back** — rolling back would undo the other reconfiguration's changes.
- **Do retry** — typically after a short delay, with the most recent desired configuration.

The recommended discrimination is `ex instanceof ConcurrentReconfigureException` — respond with retry or no-op rather than a destructive policy.

#### Out-of-scope change handling

Because the process/virtual-cluster split separates static configuration from virtual cluster configuration structurally, `OutOfScopeChangeException` is not expected in controller-driven reconfiguration — the `Snapshot` contains only virtual cluster configuration and there is nothing out-of-scope to detect. However, controller implementations should handle unexpected exceptions from `reconfigure()` defensively: log the rejection and **not** apply destructive policies (shutdown, rollback).

#### Debouncing

Since concurrent `reconfigure()` calls are rejected rather than queued, controllers that may receive rapid configuration changes (e.g. a file watcher receiving multiple filesystem events during an atomic file replacement) must debounce internally. The pattern is: absorb events for a short window, then call `reconfigure()` with the latest configuration. The debounce interval is a controller-specific configuration concern.

#### Configuration persistence

Whether to persist the applied configuration to disk is a controller concern. A Kubernetes operator owns configuration state via CRD and does not want the proxy overwriting files. A bare-metal file watcher may not need persistence because the file is already the source of truth. A custom controller may persist to a database. The proxy takes no action on configuration persistence.

#### Change detection (optimisation)

Controllers may perform their own change detection to avoid unnecessary `reconfigure()` calls. For example, a Kubernetes operator might compare ConfigMap checksums to skip no-op reconciliation loops. The proxy performs its own change detection internally (it will not restart unaffected virtual clusters), so controller-level detection is an optimisation, not a correctness requirement.

### Controller lifecycle

The controller lifecycle is tied to the proxy's lifecycle. Because the controller is the sole source of virtual cluster configuration, the proxy starts in an empty state — process infrastructure only — and the controller's first `reconfigure()` call brings virtual clusters to life.

```
Proxy startup
    │
    ├── Parse process configuration (management, controller selection)
    ├── Start process infrastructure (management endpoints, metrics)
    ├── Discover VirtualClusterConfigControllerFactory via ServiceLoader
    ├── Deserialize controller-specific config from process configuration
    ├── Call factory.create(context, config) → VirtualClusterConfigController
    │
    ├── Call controller.start()
    │     │
    │     ├── Trigger reads current config from its source
    │     ├── Trigger calls context.reconfigure(snapshot)  ← initial load
    │     ├── VCs come up
    │     ├── Trigger sets up background watching for changes
    │     │
    │     ├── Start success: controller is active, VCs serving
    │     └── Start failure: proxy has no VCs, proxy exits
    │
    ├── ... proxy running, controller calling reconfigure() as needed ...
    │
    ├── Proxy shutdown initiated
    │
    ├── Call controller.close()
    │     (controller stops watching, releases resources)
    │
    └── Proxy completes shutdown
```

**Initial load within `start()`.** The controller performs the initial configuration load synchronously within `start()`: it reads its source, constructs a `Snapshot`, and calls `context.reconfigure(snapshot)`. This first `reconfigure()` call creates all virtual clusters and brings the proxy to a serving state. Only after the initial load succeeds does the controller set up background watching for subsequent changes. This means `start()` blocks for the duration of the initial load — which is acceptable because the proxy cannot serve traffic until the first configuration is applied. Subsequent changes happen asynchronously on the controller's own threads.

**Why separate `create()` from `start()`.** The `VirtualClusterConfigControllerFactory` creates the controller during proxy initialisation, but `start()` is called separately so that the proxy can complete its own bootstrap (management endpoints, metrics) before the controller begins loading configuration. This also allows the runtime to handle controller creation failures differently from controller start failures.

**Failure to start.** If the controller's `start()` method throws, the proxy has no virtual clusters and cannot serve traffic. The proxy should exit — an empty proxy with no VCs is not useful, and the operator needs to diagnose the controller failure. This is a deliberate difference from the controller-optional model: when a controller is configured, the proxy depends on it for all virtual cluster configuration, so a controller failure is a proxy failure.

**Shutdown ordering.** The controller is closed *before* the proxy begins its shutdown sequence. This prevents the controller from attempting a `reconfigure()` call while the proxy is shutting down. Any `reconfigure()` call already in flight will complete independently — the proxy handles the `IllegalStateException` case per Proposal 083.

**In-flight reconfiguration at shutdown.** If a controller-initiated `reconfigure()` is in progress when the proxy receives a shutdown signal, the proxy waits for the reconfiguration to complete before proceeding with shutdown. The controller's `close()` is called after the reconfiguration completes.

### Example: File watcher controller

To illustrate the SPI in use, here is a sketch of how a file watcher controller would be structured. This is not a specification for a file watcher — that is an implementation concern — but demonstrates that the SPI is sufficient for the most common controller pattern.

```java
public class FileWatcherControllerFactory
        implements VirtualClusterConfigControllerFactory<FileWatcherConfig> {

    @Override
    public VirtualClusterConfigController create(
            VirtualClusterConfigControllerContext context,
            FileWatcherConfig config) {
        return new FileWatcherController(context, config);
    }

    @Override
    public Class<FileWatcherConfig> configType() {
        return FileWatcherConfig.class;
    }
}

// Registered in META-INF/services/...VirtualClusterConfigControllerFactory
```

```java
class FileWatcherController implements VirtualClusterConfigController {

    private final VirtualClusterConfigControllerContext context;
    private final FileWatcherConfig config;
    private WatchService watchService;
    private Thread watchThread;

    // ... constructor ...

    @Override
    public void start() throws Exception {
        Path watchPath = config.watchPath();

        // Initial load — synchronous, brings up VCs for the first time
        Snapshot snapshot = Snapshot.fromPath(watchPath);
        context.reconfigure(snapshot).join();

        // Begin watching for subsequent changes
        watchService = FileSystems.getDefault().newWatchService();
        watchPath.getParent().register(watchService, ENTRY_MODIFY, ENTRY_CREATE);

        watchThread = new Thread(() -> {
            while (!Thread.currentThread().isInterrupted()) {
                // wait for events, debounce, then:
                Snapshot newSnapshot = Snapshot.fromPath(watchPath);
                ValidationResult validation = context.validate(newSnapshot);
                if (!validation.isValid()) {
                    LOG.error("Configuration validation failed: {}",
                              validation.errors());
                    continue;
                }
                context.reconfigure(newSnapshot)
                       .whenComplete((result, ex) -> {
                           if (ex instanceof ConcurrentReconfigureException) {
                               // retry later
                               return;
                           }
                           if (ex != null) {
                               LOG.error("Reconfigure failed", ex);
                               return;
                           }
                           for (var error : result.errors()) {
                               LOG.error("Component failed: {}",
                                         error.humanReadableIdentifier(),
                                         error.cause());
                           }
                       });
            }
        });
        watchThread.setDaemon(true);
        watchThread.start();
    }

    @Override
    public void close() {
        watchThread.interrupt();
        watchService.close();
    }
}
```

This example demonstrates:
- `start()` performs the initial load synchronously, then sets up background watching
- The initial `reconfigure()` call creates all virtual clusters — same path as subsequent changes
- The controller produces a `Snapshot` from the filesystem — other controllers would produce snapshots from other sources
- `validate()` returns a `ValidationResult` — the controller checks `isValid()` and logs errors without catching exceptions
- `whenComplete()` implements failure policy (best-effort in this case)
- `ConcurrentReconfigureException` is handled with retry semantics

## Affected projects

- **kroxylicious-runtime** (`kroxylicious-api` module) — the SPI interfaces (`VirtualClusterConfigController`, `VirtualClusterConfigControllerFactory`, `VirtualClusterConfigControllerContext`) are added as public API.
- **kroxylicious-runtime** (runtime module) — implements `VirtualClusterConfigControllerContext`, integrates controller lifecycle with `KafkaProxy` startup and shutdown, and performs ServiceLoader discovery.
- **kroxylicious-app** — configures a controller (initially a file watcher, shipped as a separate module) for the standalone binary.
- **kroxylicious-operator** — not directly affected. The operator embeds the proxy and calls `reconfigure()` directly; it does not use the controller SPI. If a future operator design prefers to delegate to an in-proxy controller, it can configure one via the SPI.

## Compatibility

- **Additive.** No existing behaviour changes. A proxy with no `virtualClusterConfigController` configuration operates identically to today — configuration is loaded from a single file at startup and changes require a restart.
- **Proposal 083 extension.** This proposal extends Proposal 083's `reconfigure()` contract to handle the "from nothing to something" case — where `reconfigure()` is called with no virtual clusters running. This is a natural extension: Proposal 083's remove/replace/add flow already handles the "add" case; when there is no prior state, there is nothing to remove or replace and everything is an add. The `ReconfigureResult`, `ReconfigureError`, and concurrency control contracts are unchanged. `OutOfScopeChangeException` remains part of the Proposal 083 contract for embedded callers who provide a full `Configuration` directly, but is not relevant for controller-driven reconfiguration because `Snapshot` contains only virtual cluster configuration.
- **Configuration format.** The `virtualClusterConfigController` section is new; its absence means no controller — the proxy loads configuration at startup as today.
- **Plugin convention.** The `type` + `config` pattern and `ServiceLoader` discovery follow established Kroxylicious conventions and do not introduce new mechanisms.
- **Proposal 096 (configuration rework).** This proposal adopts Proposal 096's `Snapshot` abstraction as the type controllers provide to `reconfigure()`. The process/virtual-cluster split established here is a simpler foundation than Proposal 096's full multi-file structure, but the two are compatible: Proposal 096's ideas — per-plugin versioning, dependency tracking, richer `Snapshot` implementations — can evolve on top of this split. This proposal does not commit to Proposal 096's specific filesystem layout (e.g. `plugins.d/` keyed by plugin interface FQCN).

## Rejected alternatives

- **Per-call `ReloadOptions`**: An earlier Proposal 083 iteration proposed a `ReloadOptions` parameter on each `reconfigure()` call carrying failure policy (rollback/terminate) and persistence settings. Rejected because failure policy is a deployment-time decision that should not vary between invocations. A trigger that hardcodes "best-effort" and another that hardcodes "rollback" should not be able to vary their behaviour per call — that creates inconsistency. The `whenComplete()` pattern achieves the same expressiveness without a per-call parameter.

- **`VirtualClusterLifecycleObserver`**: An earlier Proposal 083 iteration proposed a push-based observer injected at `KafkaProxy` construction time, notified of every lifecycle transition. While valuable for a future control-plane integration, it is a broader mechanism than controllers need and was deferred to avoid coupling it with the controller SPI. The `whenComplete()` pattern on `reconfigure()` is sufficient for the failure-handling use case.

- **Multiple simultaneous controllers**: Considered allowing multiple controllers to be active (e.g. both a file watcher and an HTTP endpoint). Rejected because `reconfigure()` only allows one reconfiguration at a time (`ConcurrentReconfigureException`), and multiple controllers racing to reconfigure would create unpredictable behaviour. If a deployment needs both file-based and HTTP-based triggering, a single controller implementation can support both input mechanisms internally.

- **Trigger signals "config changed" without providing a `Snapshot`**: An alternative where the controller simply signals "reload" and the runtime re-reads the configuration from its startup path. Simpler for the file watcher case but does not support non-filesystem configuration sources (HTTP request bodies, CRD specs, in-memory representations). The `Snapshot` abstraction gives file-based controllers comparable simplicity (`Snapshot.fromPath(...)`) while supporting any source.

- **Hardcoded trigger in `kroxylicious-app`**: Instead of an SPI, wire a file watcher directly into the standalone binary. Rejected because it forces users who need a different trigger mechanism (HTTP, custom control plane) to embed the proxy rather than just providing a different trigger on the classpath. The SPI cost is small and the extensibility value is high.

- **Proxy-managed configuration persistence**: An earlier design had the proxy persist the applied configuration to disk after a successful `reconfigure()`. Rejected because persistence requirements vary by deployment: a Kubernetes operator owns state via CRD and does not want the proxy overwriting files; a bare-metal deployment may want file persistence; a custom control plane may persist to a database. This is a controller concern, not a proxy concern.

- **Trigger configuration in `updateStrategy` or `configurationReload` YAML block**: Earlier iterations of Proposal 083 proposed YAML-level configuration for failure policy and rollback behaviour. Rejected in favour of caller-side policy via `whenComplete()` — the proxy reports outcomes and takes no policy action. The only YAML configuration for controllers is the `virtualClusterConfigController` section that selects and configures the controller implementation.

- **Runtime loads initial configuration, trigger handles subsequent changes**: An earlier version of this proposal had the proxy load its initial configuration directly at startup (via the constructor, as in Proposal 083), with the controller only responsible for detecting and applying subsequent changes. Rejected because it creates two code paths for configuration loading: one in the runtime (startup) and one in the controller (reload). The unified model — where the controller is the sole source of virtual cluster configuration, including the initial load — is simpler, eliminates the two-path inconsistency, and gives the controller control over initial validation and failure policy from the start.

- **Separate `ConfigurationSource` and `VirtualClusterConfigController` plugins**: We considered splitting the controller into two independently pluggable SPIs: a `ConfigurationSource` responsible for producing `Snapshot` objects from a backing store, and a `VirtualClusterConfigController` responsible for orchestration (debouncing, validation, failure policy). The motivation was reuse — the same filesystem source could be paired with either a file watcher trigger or an HTTP trigger that accepts `reloadNow` requests. Rejected because the coupling between source and trigger is deployment-specific and no single SPI boundary works for all cases. A file watcher trigger and its source share a path. An HTTP PUT trigger that accepts configuration in the request body *is* the source — there is nothing to load from. A trigger that accepts partial configuration (e.g. config for a single named virtual cluster) needs to merge with the current state, which goes beyond what a passive `load()` method can express. The separation between sourcing and orchestration is a real design concern, and controller implementations may factor these responsibilities internally. But forcing this factoring at the SPI level creates an interface that is either too restrictive for push-based controllers or too leaky for pull-based ones. The single-controller SPI accommodates all deployment models; utility types like `Snapshot.fromPath()` and `Snapshot.fromYaml()` can provide building blocks without constraining the design.
