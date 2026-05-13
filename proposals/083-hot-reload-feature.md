# 83 - Changing Active Proxy Configuration

**Builds on:** [Proposal 016 — Virtual Cluster Lifecycle](https://github.com/kroxylicious/design/blob/main/proposals/016-virtual-cluster-lifecycle.md)

This proposal introduces a mechanism for applying configuration changes to a running Kroxylicious proxy without a full restart. It defines a core `KafkaProxy.reconfigure(Configuration)` operation that accepts a complete configuration, detects what changed, and converges the running state to match — restarting only the affected virtual clusters while leaving unaffected clusters available.

This proposal extends the virtual cluster lifecycle model (Proposal 016) with reload operations, an edge-based failure policy, and a configuration change orchestration layer. Where Proposal 016 defines the per-VC state machine and the `VirtualClusterRegistry` that owns it, this proposal defines the change detection pipeline, the reload orchestration, and the two policy layers (terminal failure and configuration failure) that govern how the proxy responds to problems during reload.

## Current situation

Any change to Kroxylicious configuration — adding, removing, or modifying a virtual cluster, changing a filter definition, or updating default filters — requires a full restart of the proxy process. This means all virtual clusters are torn down and rebuilt, dropping every client connection even if only one cluster was modified.

In Kubernetes deployments, a configuration change means a pod restart. In standalone deployments, it means stopping and restarting the process. Both cause a service interruption that is disproportionate to the scope of the change.

## Motivation

Administrators need to be able to modify proxy configuration in place. Common scenarios include:

- **Adding or removing virtual clusters** as tenants are onboarded or offboarded.
- **Updating filter configuration** (e.g. updating a KMS endpoint, changing a key selection pattern, modifying ACL rules).

The proxy should apply these changes with minimal disruption: only the virtual clusters affected by the change should experience downtime. Unaffected clusters should continue serving traffic without interruption.

This proposal also delivers the runtime capability that Proposal 016 made possible: with `reconfigure()` available, an operator (via whatever trigger they're using) can let healthy VCs continue serving while fixing a broken VC's config and re-applying — making per-VC independence useful rather than theoretical.

## Proposal

### Core API: `KafkaProxy.reconfigure()`

The central operation is:

```java
class KafkaProxy {
    // ... add the following method

    /**
     * Reconfigure this running proxy with the given configuration, restarting only
     * the virtual clusters whose effective configuration differs from the current
     * running state. Unaffected clusters continue serving traffic throughout
     * the reconfiguration.
     *
     * <h2>Scope</h2>
     * <p>This method handles <em>replacement</em> configurations on an already-running
     * proxy. The initial configuration is supplied via the {@link KafkaProxy}
     * constructor at proxy startup.
     *
     * <p>Within that scope, this method applies only the virtual-cluster sections of
     * the configuration and the named filter definitions that those virtual clusters
     * reference. Other configuration sections (management, metrics, admin, etc.) are
     * out of scope.
     *
     * <p>If {@code newConfig} differs from the running configuration in any out-of-scope
     * section, the reconfiguration is rejected as a pre-flight check before any virtual-cluster
     * change is attempted: the returned future completes exceptionally with an
     * {@link OutOfScopeChangeException} naming the differing section(s) and the proxy's
     * running state is unchanged. Changes to those sections still require a proxy restart.
     * Rejecting (rather than silently ignoring) out-of-scope diffs preserves freedom of
     * manoeuvre: if a future iteration supports hot-reload of additional sections, the
     * exception simply stops being thrown for those sections — silent-ignore would by
     * contrast become a breaking semantic change without an API-version bump.
     *
     * <h2>Validation contract</h2>
     * <p>Static validation (schema conformance, required fields, field-value
     * ranges, internal consistency) is the caller's responsibility and is
     * expected to have been performed on {@code newConfig} before this method
     * is called.
     *
     * <p>Validation which depends on runtime state (port conflicts, plugin
     * instantiation, TLS material readability) is performed during
     * {@code reconfigure()} and reported via the returned future's
     * {@link ReconfigureResult}.
     *
     * <h2>Error reporting</h2>
     * <p>This method throws synchronously <em>only</em> for programmer errors:
     * <ul>
     *   <li>{@link NullPointerException} if {@code newConfig} is {@code null};</li>
     *   <li>{@link IllegalStateException} if the proxy has not been started or
     *       has been shut down.</li>
     * </ul>
     *
     * <p>All other failures surface through the returned future:
     * <ul>
     *   <li><b>Input rejection</b> — the submitted configuration is not acceptable
     *       to this method (e.g. a change to an out-of-scope section). Detected as a
     *       pre-flight check before any state change is attempted; no virtual cluster
     *       is touched. The future completes exceptionally with a specific exception
     *       type identifying the rejection reason (e.g. {@link OutOfScopeChangeException}).</li>
     *   <li><b>Catastrophic failure</b> — the reconfiguration began but could not be completed
     *       (e.g. internal proxy bug, unexpected I/O failure inside the orchestrator).
     *       The future completes exceptionally.</li>
     *   <li><b>Per-component failure</b> — the reconfiguration was evaluated and one or
     *       more components (virtual clusters or referenced filters) failed to
     *       converge. The future completes normally with a {@code ReconfigureResult}
     *       whose {@code errors()} collection is non-empty.</li>
     * </ul>
     *
     * <p>Failure-handling policy (whether to shut down on partial failure, attempt
     * a rollback, alert, or retry) is the caller's responsibility, expressed via
     * the standard {@link java.util.concurrent.CompletableFuture#whenComplete}
     * pattern. The proxy itself takes no policy action based on {@code errors()};
     * it only reports.
     *
     * @param newConfig the desired end-state configuration; must be non-null
     *                  and statically valid
     * @return a future that completes with a {@link ReconfigureResult} describing
     *         any per-component failures encountered while reconfiguring
     * @throws NullPointerException  if {@code newConfig} is {@code null}
     * @throws IllegalStateException if the proxy is not in the running state
     */
    public CompletableFuture<ReconfigureResult> reconfigure(Configuration newConfig);
}
```

The caller provides a complete `Configuration` object. The proxy compares the in-scope sections (virtual clusters + referenced named filters) against the currently running configuration, determines what changed, and applies the changes. The method returns a `CompletableFuture<ReconfigureResult>` that completes with the reconfiguration outcome or exceptionally on catastrophic failure.

`ReconfigureResult` reports any per-component failures encountered during the reconfiguration. The interface is deliberately minimal: it only enumerates *what failed* and *why*, and leaves any reaction to the caller.

```java
public interface ReconfigureResult {
    /**
     * Returns the per-component failures encountered while reconfiguring.
     * One entry per failed component (e.g. one virtual cluster, one referenced filter).
     * Empty when the reconfiguration succeeded with no failed components.
     * <p>
     * The returned collection is immutable; iteration order is unspecified.
     */
    Collection<ReconfigureError> errors();

    /** Convenience predicate equivalent to {@code !errors().isEmpty()}. */
    default boolean hasErrors() { return !errors().isEmpty(); }
}

public record ReconfigureError(String humanReadableIdentifier, Throwable cause) { }
```

`ReconfigureError.humanReadableIdentifier` is a best-effort string that identifies which component failed (a virtual cluster name, a filter reference, etc.). The string's format is implementation-defined and intended for human consumption — operators reading logs, alerts, or admin endpoints. Programmatic consumers should rely on `cause` (the underlying exception) for typed failure detection rather than parsing the identifier.

In this approach the caller provides the desired end state, the proxy computes and executes the diff, and the proxy reports per-component outcomes — but takes no action on those outcomes. The intentional minimalism preserves freedom of manoeuvre for the broader proxy-configuration rework tracked separately; richer APIs (categorised outcomes, structured identifiers, lifecycle event streams) can be added without breaking this contract.

#### Caller-side failure handling

Because the proxy does not act on `errors()`, callers express their failure policy via `whenComplete` on the returned future. Three illustrative patterns:

**Shut down on any failure**:

```java
proxy.reconfigure(newConfig)
     .whenComplete((result, ex) -> {
         if (ex instanceof ConcurrentReconfigureException) {
             // Another reconfigure is in flight; the proxy is healthy. Don't shut down — retry later.
             LOGGER.atWarn().log("reconfigure rejected: another reconfigure in progress; will retry");
             return;
         }
         if (ex != null) {
             LOGGER.atError().setCause(ex).log("Reconfigure failed catastrophically");
             proxy.shutdown();
             return;
         }
         for (var error : result.errors()) {
             LOGGER.atError()
                   .setCause(error.cause())
                   .addKeyValue("component", error.humanReadableIdentifier())
                   .log("Reconfigure failed for component");
         }
         if (result.hasErrors()) {
             proxy.shutdown();
         }
     });
```

The future completes with the aggregate result *before* any action is taken, so logging happens before shutdown — no ordering problem.

**Best-effort reconfigure, keep what worked**:

```java
proxy.reconfigure(newConfig)
     .whenComplete((result, ex) -> {
         if (ex instanceof ConcurrentReconfigureException) {
             // Another reconfigure is in flight; not a real failure — trigger can retry later.
             return;
         }
         if (ex != null) {
             alerter.send("catastrophic-reconfigure-failure", ex);
             return;
         }
         for (var error : result.errors()) {
             alerter.send("component-reconfigure-failure", error);
         }
         // Surviving components continue serving; no proxy-level action taken.
     });
```

**Rollback on failure** (a sophisticated trigger):

```java
proxy.reconfigure(newConfig)
     .whenComplete((result, ex) -> {
         if (ex instanceof ConcurrentReconfigureException) {
             // Another reconfigure is in flight; not a real failure — trigger can retry later.
             return;
         }
         if (result != null && result.hasErrors()) {
             proxy.reconfigure(oldConfig)
                  .whenComplete((rollbackResult, rollbackEx) -> {
                      if (rollbackEx != null || rollbackResult.hasErrors()) {
                          // rollback itself failed — last-resort policy
                          proxy.shutdown();
                      }
                  });
         }
     });
```

The caller supplies `oldConfig` from its own state — the proxy does not currently expose a getter for its running configuration. This is sufficient because triggers that perform rollback typically already have their own source-of-truth for the previous desired state (a Kubernetes ConfigMap revision, an HTTP-endpoint request history, a previously-loaded file). If a future use case requires the proxy to be queryable for its current state, an accessor can be added without changing the `reconfigure` contract.

Each of these is a trigger-side concern. The proxy does not need to know which policy is in use, and adding a new policy in the future does not require any proxy changes.

**Trigger mechanisms are explicitly out of scope for this proposal.** The `KafkaProxy.reconfigure()` operation is the internal interface that any trigger plugs into. How the new configuration arrives — whether via an HTTP endpoint, a file watcher detecting a changed ConfigMap, or a Kubernetes operator callback — is a separate concern. Deferring this keeps the proposal focused and avoids blocking on unresolved questions about trigger design (see [Trigger mechanisms](#trigger-mechanisms-future-work) below).

### Configuration change detection

When `KafkaProxy.reconfigure()` is called, the proxy compares the new configuration against the running state to determine which virtual clusters need to be restarted. Change detection is implemented as a pipeline of `ChangeDetector` implementations, each responsible for one category of change:

- **`VirtualClusterChangeDetector`** — identifies clusters that were added, removed, or modified by comparing `VirtualClusterModel` instances via `equals()`. A cluster requires a restart if any property that contributes to `VirtualClusterModel.equals()` changed (bootstrap address, TLS settings, gateway configuration, etc.).
- **`FilterChangeDetector`** — identifies clusters affected by filter configuration changes. A cluster requires a restart if a `NamedFilterDefinition` it references changed (type or configuration, compared via `equals()`), or if the `defaultFilters` list changed (order matters, since filter chain execution is sequential) and the cluster relies on default filters.

Detectors return a `ChangeResult(clustersToRemove, clustersToAdd, clustersToModify)`. Results from all detectors are aggregated and then passed onto `VirtualClusterRegistry` to perform relevant operations.

Clusters where none of these changed are left untouched — they continue serving traffic throughout the reconfiguration operation.

### Cluster modification via lifecycle transitions

The reload operations are exposed as **methods on `VirtualClusterRegistry`** (Proposal 016). Each method drives the per-VC state machine (`VirtualClusterLifecycleState`) through one of three transition sequences. This proposal adds these methods; Proposal 016's existing state machine and transition guards are unchanged.

**`removeVirtualCluster(clusterName)`**

- **Lifecycle path:** `SERVING → DRAINING → [drain connections] → [deregister gateways] → STOPPED`
- **Behaviour:** The cluster is permanently torn down. It reaches the terminal Stopped state via the `draining → stopped` edge.
- **Failure reporting:** This is an intentional removal, not a failure; it is not reported through `ReconfigureResult.errors()`.

**`replaceVirtualCluster(clusterName, newModel)`**

- **Intent:** Apply a new configuration to an existing cluster. The method is named by intent rather than implementation.
- **Current implementation:** Equivalent to `removeVirtualCluster(clusterName)` followed by `addVirtualCluster(newModel)` — the cluster cycles through `SERVING → DRAINING → [drain connections] → [deregister gateways] → INITIALIZING → [register gateways] → SERVING`. Clients connected to the cluster are disconnected during the drain phase.
- **Caveats of the current implementation:** The drain + re-init approach means a replaced cluster experiences a brief period of unavailability while its ports are unbound and rebound. It also creates a thundering herd when all disconnected clients reconnect simultaneously after the cluster comes back up; mitigation strategies (e.g. staggered connection acceptance) are future work. These are properties of the *current implementation*, not of the `replaceVirtualCluster` contract — a future implementation may eliminate them without breaking callers.
- **Failure reporting:** If the invocation fails — i.e. the VC traverses the `initializing → failed → stopped` path during the reconfiguration — the failure is reported as a `ReconfigureError` entry in the result returned to the caller. The caller decides whether to retry, rollback, alert, or shut down via the `whenComplete` patterns shown above.

**`addVirtualCluster(newModel)`**

- **Lifecycle path:** `[create lifecycle manager in INITIALIZING] → [register gateways] → SERVING`
- **Behaviour:** A new cluster starts in the Initializing state with a fresh `VirtualClusterLifecycle`, registers its gateways with the `EndpointRegistry`, and transitions to Serving.
- **Failure reporting:** If the invocation fails — i.e. the VC traverses the `initializing → failed → stopped` path during the reconfiguration — the failure is reported as a `ReconfigureError` entry in the result returned to the caller. The caller decides whether to retry, rollback, alert, or shut down via the `whenComplete` patterns shown above.

**Processing order**

Changes are processed in the order: **remove → replace → add**. Removing clusters first frees up ports and resources that new or replacement clusters may need.

### Graceful connection draining

Before tearing down a modified or removed cluster, the proxy drives its lifecycle from **Serving to Draining**. The detailed mechanics of connection draining — rejecting new connections, applying backpressure, waiting for in-flight requests, and force-closing after timeout — are defined as part of the `Draining` lifecycle state in Proposal 016 and its implementation. This proposal does not redefine that behaviour; it relies on the lifecycle state machine to handle drain semantics.

Once all connections are drained (or the drain timeout expires), the lifecycle transitions out of Draining:
- For **restart**, gateways are deregistered and re-registered, the lifecycle transitions through Initializing to Serving.
- For **remove**, the lifecycle manager transitions from Draining to Stopped via `drainComplete()`. This is the `draining → stopped` edge — the terminal failure callback does **not** fire.


### ConfigurationReloadOrchestrator

`ConfigurationReloadOrchestrator` is an internal class of `kroxylicious-runtime`. It is not part of the public API; embedders interact with the proxy only via `KafkaProxy.reconfigure()`. `KafkaProxy` constructs and holds the orchestrator privately, and embedders never obtain a reference to it.

The orchestrator owns the reconfiguration pipeline end-to-end. Its responsibilities are:

- **Concurrency control** — serialises overlapping reconfigure calls (see [Concurrency control](#concurrency-control) below).
- **Pre-flight validation** — runs static-validation on `newConfig` before any state-changing work, and rejects out-of-scope changes (see the Javadoc on `KafkaProxy.reconfigure` and the [Orchestration pipeline](#orchestration-pipeline) section below).
- **Change detection** — calls the `VirtualClusterChangeDetector` and `FilterChangeDetector` (described in [Configuration change detection](#configuration-change-detection) above) directly. The detectors are internal collaborators of the orchestrator; the orchestrator does *not* receive a pre-computed `ChangeResult` from `KafkaProxy`.
- **Per-VC change execution** — drives the `VirtualClusterRegistry` (Proposal 016) to apply the detected changes in `removeVirtualCluster → replaceVirtualCluster → addVirtualCluster` order. Each method invocation runs the corresponding per-VC lifecycle transitions described in [Cluster modification via lifecycle transitions](#cluster-modification-via-lifecycle-transitions) above.
- **`FilterChainFactory` hot-swap** — atomically swaps the `FilterChainFactory` reference held by `KafkaProxy` on success (see [FilterChainFactory hot-swap](#filterchainfactory-hot-swap) below).
- **Result construction** — accumulates per-component outcomes into a `ReconfigureResult` and completes the future returned to the caller.

The orchestrator does **not** own connection-level mechanics, per-VC lifecycle state, or endpoint registration — those remain with the per-VC `VirtualClusterLifecycle`, the `VirtualClusterRegistry` (both Proposal 016), and the `EndpointRegistry` (existing infrastructure) respectively. The orchestrator coordinates these collaborators; it does not duplicate their responsibilities.


### FilterChainFactory hot-swap

Filter configuration changes require replacing the `FilterChainFactory` that creates filter chains for new connections. The existing architecture creates `FilterChainFactory` once at startup and passes it as a `final` reference to `KafkaProxyInitializer`.

To support hot reload, `KafkaProxy` holds an `AtomicReference<FilterChainFactory>` shared between:
- `KafkaProxyInitializer` — reads via `.get()` on each new connection, always getting the current factory
- `ConfigurationReloadOrchestrator` — swaps via `.set()` after successful reload

On success: the orchestrator atomically swaps to the new factory and closes the old one. If the reconfiguration fails before the swap (e.g. the new factory cannot be constructed, or a VC re-initialization fails during the reconfiguration), the new factory is closed and the reference remains unchanged — the previous factory keeps serving. This ensures a clean transition with no race conditions between connection setup and factory replacement.

### Failure behaviour

When a VC operation fails during `KafkaProxy.reconfigure()`, the orchestrator does **not** take any policy action. It records the failure as a `ReconfigureError` entry and continues with the remaining changes. Once all change operations have been attempted, the aggregate `ReconfigureResult` is delivered to the caller via the returned future.

Specifically, on a per-VC failure:

- The failed VC traverses `initializing → failed → stopped` (per Proposal 016's lifecycle).
- Other VCs that were already modified earlier in the reconfiguration are not reverted — their new configuration remains in effect.
- Pending changes for other VCs continue to be processed.

The caller receives the full set of failures and chooses the response (shutdown, rollback, alert, retry) via `whenComplete`. Three illustrative trigger-side patterns are shown in the [Core API](#core-api-kafkaproxyreconfigure) section above.

Rollback, in particular, is a trigger-side concern: a trigger that wants atomic "all-or-nothing" semantics calls `reconfigure(oldConfig)` from its `whenComplete` callback when the previous reconfigure returned non-empty `errors()`. The proxy does not know it is "rolling back" — it just runs another reconfigure. This keeps the proxy implementation small and lets different deployment scenarios (CLI, operator, custom trigger) express different policies without proxy changes.

### Orchestration pipeline

The complete `KafkaProxy.reconfigure()` pipeline flows through these layers:

```
KafkaProxy.reconfigure(newConfig)
    │
    ├── Guards: proxy must be running, orchestrator must be initialized
    ├── Pre-flight: reject if newConfig differs from current config in any
    │   out-of-scope section (future completes exceptionally with
    │   OutOfScopeChangeException; no further evaluation)
    │
    ▼
ConfigurationReloadOrchestrator.reload(newConfig)
    │
    ├── Acquires reloadLock (prevents concurrent reloads)
    ├── Validates new configuration via Features framework
    ├── Creates new FilterChainFactory with updated filter definitions
    │
    ├── Aggregates ChangeDetector results (called directly by orchestrator):
    │     VirtualClusterChangeDetector → added/removed/modified VCs
    │     FilterChangeDetector → VCs affected by filter changes
    │
    ├── Processes changes in order: remove → replace → add
    │     For each change: invoke the corresponding VirtualClusterRegistry
    │     method (removeVirtualCluster / replaceVirtualCluster / addVirtualCluster).
    │     Accumulate successes; collect failures as ReconfigureError entries.
    │
    ▼
VirtualClusterRegistry (for each affected VC)
    │
    ├── removeVirtualCluster:    SERVING → DRAINING → drain → deregister → STOPPED
    ├── replaceVirtualCluster:   SERVING → DRAINING → drain → deregister → INITIALIZING → register → SERVING
    │                            (current impl; intent is "apply newModel" — future impl may be more surgical)
    ├── addVirtualCluster:       INITIALIZING → register → SERVING
    │
    ▼
On success (no errors): swap FilterChainFactory, update current config, complete
                        future with ReconfigureResult.errors() empty
On per-VC failures:     keep successfully-applied changes in effect, complete
                        future with ReconfigureResult.errors() non-empty.
                        The caller decides next steps via whenComplete.
On catastrophic error:  complete future exceptionally
```

### Concurrency control

Only one reconfigure operation can execute at a time. The orchestrator uses a `ReentrantLock` to prevent overlap. A second `KafkaProxy.reconfigure()` call that arrives while a reconfigure is in progress is **not queued**: it completes exceptionally with a `ConcurrentReconfigureException`. The trigger is expected to retry, typically with the most recent desired configuration.

Rejecting (rather than queuing) the second call is deliberate. Queuing would raise three questions the proposal does not want to answer:

- **Staleness**: a queued reconfigure may carry configuration that is already obsolete by the time it executes (the trigger's source of truth has moved on). Triggers cannot easily detect this.
- **Bounded depth**: an unbounded queue is a memory hazard; a bounded queue forces a "what to do when full?" policy, which is the very thing we're trying to avoid pushing into the proxy.
- **Coalescing semantics**: should an arriving call replace the oldest queued call, the most recent one, or neither? Each choice is defensible and trigger-specific.

By rejecting fast, the proxy forces these decisions onto the trigger, where they can be made with full knowledge of the trigger's source of truth. A trigger that wants "always apply the most recent config" can implement it cleanly via the rejection-and-retry loop (debounce, then call `reconfigure` with the latest config); a trigger that needs different semantics can implement those too without the proxy having pre-committed to a policy.

`ConcurrentReconfigureException` is the exceptional-completion cause for this scenario (i.e. accessed via `future.exceptionally(...)` or the `ex` parameter of `whenComplete`, not thrown synchronously from `reconfigure` itself — that distinction matches the rest of the error-reporting contract).

**Implication for callers' error-handling patterns.** Because `ConcurrentReconfigureException` indicates the reconfiguration was *not attempted* — another reconfigure was in flight, and the proxy's state may reflect *that* reconfigure's changes — callers must distinguish it from per-component failure or catastrophic failure when reacting to the future's exceptional completion. In particular:

- A trigger that performs rollback on reconfigure failure (the [Rollback on failure](#core-api-kafkaproxyreconfigure) pattern shown above) must *not* roll back on `ConcurrentReconfigureException`: doing so would replay this trigger's `oldConfig` over the *other* trigger's just-applied changes, undoing them.
- A trigger that shuts down on reconfigure failure (the [Shut down on any failure](#core-api-kafkaproxyreconfigure) pattern shown above) must *not* shut down on `ConcurrentReconfigureException`: the proxy is healthy and the other trigger is mid-reconfigure.

The recommended discrimination is `ex instanceof ConcurrentReconfigureException` — respond with retry (or no-op) rather than the destructive policy. The same discipline applies to any other "rejected before attempt" exception (e.g. `OutOfScopeChangeException`): those also indicate the proxy did not change state, and the trigger's response should reflect that.

### Worked examples

All examples assume: VC-A and VC-B serving; `reconfigure(newConfig)` modifies both. Differences below are in what the caller's `whenComplete` does on failure.

#### Best-effort reconfigure (CLI / operator that wants surviving VCs to keep serving)

```
1. Modify VC-A → succeeds → VC-A serving with new config
2. Modify VC-B → fails (e.g. upstream unreachable) → VC-B enters failed → stopped
3. Future completes with: ReconfigureResult.errors() = [ReconfigureError("vc-b", IOException)]
4. Caller's whenComplete logs the error and takes no further action.
   VC-A continues serving with new config; VC-B is gone.
```

This matches the existing "serve: successful" behaviour, expressed entirely on the caller side.

#### Fail-fast (CLI app that wants any failure to take down the proxy)

```
1. Modify VC-A → succeeds → VC-A serving with new config
2. Modify VC-B → fails → VC-B enters failed → stopped
3. Future completes with: ReconfigureResult.errors() = [ReconfigureError("vc-b", IOException)]
4. Caller's whenComplete sees hasErrors() == true and calls proxy.shutdown().
   The future has already delivered the result, so logging happens before shutdown.
```

This matches the existing "serve: none" behaviour, again expressed on the caller side.

#### Atomic reconfigure with rollback (sophisticated trigger)

```
1. Caller saves oldConfig before calling reconfigure(newConfig).
2. Modify VC-A → succeeds (new config) → VC-A serving with new config.
3. Modify VC-B → fails → VC-B enters failed → stopped.
4. Future completes with: errors() non-empty.
5. Caller's whenComplete calls reconfigure(oldConfig):
     - Removes VC-A's new config, restores old config: VC-A drains and re-initializes
     - Re-adds VC-B with old config: succeeds, VC-B back to serving
6. Rollback's future completes with errors() empty. The system is back to oldConfig.
```

If the rollback itself returns non-empty `errors()`, the trigger applies its last-resort policy (typically shutdown).

#### Catastrophic failure

```
1. reconfigure(newConfig) is called.
2. The orchestrator encounters an internal error (e.g. an unexpected runtime exception
   in change-detection itself, not in any particular VC).
3. Future completes exceptionally with that throwable.
4. Caller's whenComplete sees ex != null and applies its catastrophic-error policy.
```

The distinction between "per-VC failure" (future completes normally, `errors()` non-empty) and "catastrophic failure" (future completes exceptionally) is the boundary between *the reconfiguration ran and at least one component failed* and *the reconfiguration could not be evaluated at all*.

### Metrics and observability

The following metrics are part of the reload implementation:

- **`kroxylicious_reconfigure_total`** — counter of `KafkaProxy.reconfigure()` invocations, labelled by outcome (`success` = future completes with empty `errors()`; `partial_failure` = future completes with non-empty `errors()`; `catastrophic` = future completes exceptionally). Enables alerting on reconfigure failures and tracking reconfigure frequency.
- **`kroxylicious_reconfigure_duration_seconds`** — histogram of end-to-end reconfigure duration. Helps operators understand whether reconfigure is meeting SLA expectations and identify slow operations.
- **`kroxylicious_reconfigure_clusters_affected_total`** — counter of per-VC operations during a reconfigure, labelled by operation (`add`, `remove`, `modify`) and outcome (`success`, `failure`). Provides granularity beyond the aggregate result.
- **`kroxylicious_drain_duration_seconds`** — histogram of per-VC connection drain duration. Helps tune the `drainTimeout` configuration and detect VCs with long-lived connections.
- **`kroxylicious_drain_connections_force_closed_total`** — counter of connections force-closed after drain timeout. A high rate indicates the drain timeout is too aggressive for the workload.

Note: there is no proxy-side `rollback` metric because rollback is a trigger-side concern (the trigger calls `reconfigure()` a second time with the previous configuration). Each reconfigure — original or rollback — is counted independently as a regular invocation. Triggers that perform rollback can add their own metrics if needed.

The per-VC lifecycle state metrics (`kroxylicious_virtual_cluster_state`, `kroxylicious_virtual_cluster_state_duration_seconds`, `kroxylicious_virtual_cluster_transitions_total`) defined in Proposal 016 complement these reload-specific metrics and should be implemented alongside them.

A management endpoint exposing the last reload result (timestamp, outcome, affected clusters, duration) is also valuable for on-demand inspection by operators.

### Plugin resource tracking (known gap)

The change detection described above can identify when a filter's YAML configuration changes (via `equals()` on the configuration model), but it cannot detect when external resources that a plugin reads during initialisation have changed. For example, a password file, TLS keystore, or ACL rules file may have changed on disk even though the plugin's configuration (which only references the file path) is identical.

These reads typically happen deep in nested plugin call stacks (e.g. `RecordEncryption` → `KmsService` → `CredentialProvider` → `FilePassword`), so the runtime has no visibility into what was read or whether it has changed.

Without addressing this gap, an reconfigure operation would miss these changes entirely — the plugin configuration hasn't changed, so no restart is triggered, even though the plugin's actual behaviour would differ if it were reinitialised.

An approach is being explored where plugins read external resources through the runtime (rather than doing direct file I/O), allowing the runtime to track what was read and hash the content for subsequent change detection. This makes dependency tracking automatic rather than relying on plugin authors to opt in. The detailed design for this mechanism will be covered in a separate proposal to keep this one focused on the core reconfigure operation.


## Trigger mechanisms (future work)

The `KafkaProxy.reconfigure()` operation is trigger-agnostic. The following trigger mechanisms have been discussed but are explicitly deferred:

- **HTTP endpoint**: An HTTP POST endpoint (e.g. `/admin/config/reload`) that accepts a new configuration and calls `KafkaProxy.reconfigure()`. Provides synchronous feedback. Questions remain around security (authentication, binding to localhost vs. network interfaces), whether the endpoint receives the configuration inline or reads it from a file path, and content-type handling.
- **File watcher**: A filesystem watcher that detects changes to the configuration file and triggers `KafkaProxy.reconfigure()`. Interacts with Kubernetes ConfigMap mount semantics. Questions remain around debouncing, atomic file replacement, and read-only filesystem constraints.
- **Operator integration**: A Kubernetes operator that reconciles a CRD and calls `KafkaProxy.reconfigure()` via the proxy's API. The operator owns the desired state; the proxy does not persist configuration to disk.

Each of these can be designed and implemented independently once the core `KafkaProxy.reconfigure()` mechanism is in place.

## Compatibility

- The `KafkaProxy.reconfigure()` operation is additive — it does not change existing startup behaviour.
- This proposal adds **no new YAML configuration**. All failure-handling policy is expressed by the caller via `whenComplete`.
- Virtual cluster configuration semantics are unchanged; the proposal only adds the ability to apply changes at runtime.
- Filter definitions and their configuration are unchanged.
- The on-disk configuration file format is unchanged.
- The lifecycle state model (Proposal 016) is unchanged; this proposal only adds operations that drive transitions through the existing state machine.
- **Proposal 016 compatibility:** This proposal supersedes the *Virtual Cluster Failure Policy* section of Proposal 016. The `onVirtualClusterStopped.serve` configuration described there is not implemented; failure-handling policy is instead expressed by the caller via `whenComplete` on the `CompletableFuture<ReconfigureResult>` returned by `reconfigure()`.

## Rejected alternatives

- **File watcher as the primary trigger**: Earlier iterations of this proposal used filesystem watching to detect configuration changes. This was set aside in favour of decoupling the trigger from the reconfiguration operation, since the trigger mechanism has unresolved design questions (security, delivery method, Kubernetes integration) that should not block the core capability.
- **Node-based failure policy (`onVirtualClusterStopped`)**: The original Proposal 016 design fired the serve policy when a VC *arrived at* the `Stopped` state. This conflates intentional removal (a success) with terminal failure (a problem). The current design avoids this entirely by surfacing failures through `ReconfigureResult.errors()` and letting the caller decide blast radius.
- **`onVirtualClusterTerminalFailure` / `configurationReload` YAML config blocks**: An earlier iteration proposed YAML-level deployment policy for "what to do when a VC fails" and "should reload roll back atomically." Rejected in favour of caller-side policy via `whenComplete`. The proxy reports outcomes; the caller chooses the response. This shrinks the proxy's API surface and lets different deployment scenarios (CLI, operator, sophisticated trigger) express different policies without proxy changes.
- **`ReloadOptions` as a per-call parameter**: An approach where each call to `KafkaProxy.reconfigure()` could specify failure behaviour. Rejected because the caller can express any policy on the future returned by the method — a per-call parameter would not add expressive power and would commit the proxy to a specific failure-policy taxonomy.
- **`VirtualClusterLifecycleObserver` injected at construction**: An earlier iteration proposed a push-based observer notified of every lifecycle transition. Rejected for this proposal in favour of the simpler `whenComplete` model, which covers the failure-handling use case without introducing a new extension point. A general-purpose lifecycle event stream (useful for control-plane status push) may be revisited in a follow-up proposal.
- **Structured `ReconfigureError` (typed by failure layer)**: An earlier iteration proposed `ReconfigureError(String virtualClusterName, @Nullable String filterName, ReloadPhase phase, Throwable cause)`. The current minimal form (one identifier + cause) is intentional — committing to a phase enum or a structured-fields shape now would constrain the broader proxy-config rework. Programmatic consumers should use `cause` for typed handling; the identifier is for human consumption.
- **`ConfigurationReconciler` naming**: Considered to describe the "compare desired vs current and converge" pattern, but rejected because Kubernetes reconcilers already exist in the Kroxylicious codebase and overloading the term would cause confusion.
- **Plan/apply split on the public interface**: Considered exposing separate `plan()` and `apply()` methods to enable dry-run validation. Decided this is an internal concern — the trigger just needs `KafkaProxy.reconfigure()`. A validate/dry-run capability can be added later without changing the interface.
- **Inline configuration via HTTP POST body**: Discussed having the HTTP endpoint accept the full YAML configuration in the request body. An alternative view is that configuration should always live in files (for source control, auditability, consistent state) and the HTTP endpoint should just trigger reading from a specified file path. This question is deferred along with the HTTP trigger design.
- **Separate VirtualClusterManager for reload**: The original hot-reload design had a `VirtualClusterManager` that was purely an operation orchestrator (with `EndpointRegistry` and `ConnectionDrainManager` dependencies). Rather than maintaining two classes with the same name, the reload operations merge into the [Proposal 016](https://github.com/kroxylicious/design/blob/main/proposals/016-virtual-cluster-lifecycle.md) class (originally also called `VirtualClusterManager`, renamed to `VirtualClusterRegistry` in kroxylicious PR #3888), which already owns the VC model list and lifecycle managers. The merged class gains `EndpointRegistry` and `ConnectionDrainManager` dependencies and the `removeVirtualCluster`/`replaceVirtualCluster`/`addVirtualCluster` methods.
- **Two terminal states (`Stopped` and `TerminallyFailed`)**: Considered adding a separate terminal state for unrecoverable failures. Rejected because the distinction is about the transition edge, not the terminal state — a stopped cluster is permanently done regardless of why. The edge-based policy hook achieves the same goal without adding state machine complexity.
