# 83 - Changing Active Proxy Configuration

**Builds on:** [Proposal 016 — Virtual Cluster Lifecycle](https://github.com/kroxylicious/design/blob/main/proposals/016-virtual-cluster-lifecycle.md)

This proposal introduces a mechanism for applying configuration changes to a running Kroxylicious proxy without a full restart. It defines a core `KafkaProxy.applyConfiguration(Configuration)` operation that accepts a complete configuration, detects what changed, and converges the running state to match — restarting only the affected virtual clusters while leaving unaffected clusters available.

This proposal extends the virtual cluster lifecycle model (Proposal 016) with reload operations, an edge-based failure policy, and a configuration change orchestration layer. Where Proposal 016 defines the per-VC state machine and the `VirtualClusterManager` that owns it, this proposal defines the change detection pipeline, the reload orchestration, and the two policy layers (terminal failure and configuration failure) that govern how the proxy responds to problems during reload.

## Current situation

Any change to Kroxylicious configuration — adding, removing, or modifying a virtual cluster, changing a filter definition, or updating default filters — requires a full restart of the proxy process. This means all virtual clusters are torn down and rebuilt, dropping every client connection even if only one cluster was modified.

In Kubernetes deployments, a configuration change means a pod restart. In standalone deployments, it means stopping and restarting the process. Both cause a service interruption that is disproportionate to the scope of the change.

## Motivation

Administrators need to be able to modify proxy configuration in place. Common scenarios include:

- **Adding or removing virtual clusters** as tenants are onboarded or offboarded.
- **Updating filter configuration** (e.g. updating a KMS endpoint, changing a key selection pattern, modifying ACL rules).

The proxy should apply these changes with minimal disruption: only the virtual clusters affected by the change should experience downtime. Unaffected clusters should continue serving traffic without interruption.

This proposal also delivers the startup behaviour change that Proposal 016 made possible. With `serve: successful` and reload, an operator can let healthy VCs serve traffic while fixing a broken VC's config and re-applying — making per-VC independence useful rather than theoretical.

## Proposal

### Core API: `KafkaProxy.applyConfiguration()`

The central operation is:

```java
class KafkaProxy {
    // ... add the following method

    /**
     * Apply the given configuration to this running proxy, restarting only the
     * virtual clusters whose effective configuration differs from the current
     * running state. Unaffected clusters continue serving traffic throughout
     * the apply.
     *
     * <h2>Validation contract</h2>
     * <p>Static validation (schema conformance, required fields, field-value
     * ranges, internal consistency) is the embedder's responsibility and is
     * expected to have been performed on {@code newConfig} before this method
     * is called.
     *
     * <p>Validation which depends on runtime state (like port conflicts) 
     * will be done during applyConfiguration() and reported through the ReloadResult
     *
     * <h2>Error reporting</h2>
     * <p>This method throws synchronously <em>only</em> for programmer errors:
     * <ul>
     *   <li>{@link NullPointerException} if {@code newConfig} is {@code null};</li>
     *   <li>{@link IllegalStateException} if the proxy has not been started or
     *       has been shut down.</li>
     * </ul>
     * <p>All other failures &mdash; validation failures (runtime exceptions), lifecycle transition
     * failures during drain or re-init, partial reloads &mdash; surface via
     * exceptional completion of the returned future.
     *
     * @param newConfig the desired end-state configuration; must be non-null
     *                  and statically valid
     * @return a future that completes with a {@link ReloadResult} listing which
     *         clusters ended up unchanged, added, restarted, removed, or failed
     * @throws NullPointerException  if {@code newConfig} is {@code null}
     * @throws IllegalStateException if the proxy is not in the running state
     */
    public CompletableFuture<ReloadResult> applyConfiguration(Configuration newConfig);
}
```

The caller provides a complete `Configuration` object. The proxy compares it against the currently running configuration, determines what changed, and applies the changes. The method returns a `CompletableFuture<ReloadResult>` that completes with a structured result on success or exceptionally on failure.

`ReloadResult` reports which clusters ended up in each terminal outcome of the apply:

```java
public record ReloadResult(
    Set<String> clustersUnchanged,
    Set<String> clustersAdded,
    Set<String> clustersRestarted,
    Set<String> clustersRemoved,
    Set<String> failedClusters
) {}
```

In this approach: the caller provides the desired end state, and the proxy is responsible for computing and executing the diff. This is the right starting point — it is simple to reason about and avoids the complexity of delta-based or partial-update APIs. More granular approaches (deltas, targeted snapshots) may be worth exploring later, but the initial API should leave room for them without committing to them now.

**Trigger mechanisms are explicitly out of scope for this proposal.** The `KafkaProxy.applyConfiguration()` operation is the internal interface that any trigger plugs into. How the new configuration arrives — whether via an HTTP endpoint, a file watcher detecting a changed ConfigMap, or a Kubernetes operator callback — is a separate concern. Deferring this keeps the proposal focused and avoids blocking on unresolved questions about trigger design (see [Trigger mechanisms](#trigger-mechanisms-future-work) below).

### Two lifecycle policy layers

Proposal 016's lifecycle model has two distinct policy points, each on a different edge of the state graph. This proposal refines the failure policy from a node-based hook (firing when a VC *arrives at* `Stopped`) to an edge-based hook (firing based on *which transition* brought it there).

**Layer 1 — Per-VC recovery (`onVirtualClusterFailed`):**
When a VC hits the `initializing → failed` edge, what happens to that VC? Retry? How many times? Proposal 016 explicitly deferred this to the reload proposal (*"recovery policies defined by a future reload proposal under onVirtualClusterFailed"*). It's a per-VC concern — VC-B getting 3 retry attempts has nothing to do with VC-A. In the initial implementation, retries are hardcoded to 0 — a failed VC immediately transitions to `stopped`. The seam exists in the code but is not exposed in configuration until retry with backoff is needed.

**Layer 2 — Terminal failure (`onVirtualClusterTerminalFailure`):**
When a VC traverses the `failed → stopped` edge — meaning it is truly unrecoverable — what's the blast radius? `serve: none` (proxy shuts down) or `serve: successful` (remaining VCs continue). This fires only on the `failed → stopped` edge, not on `draining → stopped` (intentional removal) or `initializing → stopped` (shutdown during startup). The lifecycle state model is unchanged — same states, same transitions. The intelligence is in the `VirtualClusterManager` knowing which transitions are policy-triggering, not in the state itself.

### Configuration model

Failure behaviour is deployment-level static configuration, split into two independent policy dimensions. A configuration apply triggered by an HTTP endpoint should behave identically to one triggered by a file watcher or an operator callback. These decisions belong in the proxy's static configuration, keeping the `
KafkaProxy.applyConfiguration()` signature simple.

```yaml
proxy:
  # Lifecycle: fires on the failed → stopped edge only
  # Applies at startup AND reload
  onVirtualClusterTerminalFailure:
    serve: none              # none | successful

  # Reload-specific settings
  configurationReload:
    onFailure:
      rollback: true         # true | false
    persistToDisk: true      # true | false
```

| Block | Field | Values | Description |
|-------|-------|--------|-------------|
| `onVirtualClusterTerminalFailure` | `serve` | `none` | **Default.** Any unrecoverable VC shuts down the proxy. |
| | | `successful` | Remaining healthy VCs continue serving. Failed VC is reported. |
| `configurationReload` | `onFailure.rollback` | `true` | **Default.** Atomic reload — revert all VCs to prior config on failure. |
| | | `false` | Best-effort — keep what succeeded, let failed VCs die. |
| | `persistToDisk` | `true` | **Default.** Write the new configuration to the config file (with `.bak` backup of the replaced file). |
| | | `false` | Don't persist. The reload is in-memory only. |

These two dimensions are independently meaningful, producing four distinct behaviours:

| `rollback` | `serve` | Behaviour |
|-----------|---------|-----------|
| `true` | `none` | Atomic reload. Revert on failure. If revert itself fails, proxy dies. |
| `true` | `successful` | Atomic reload. Revert on failure. If revert itself fails, surviving VCs continue. |
| `false` | `none` | Best-effort. Any unrecoverable VC kills the proxy. |
| `false` | `successful` | Best-effort. Failed VCs die, rest continue. (e.g. TLS enforcement case.) |

### Configuration change detection

When `KafkaProxy.applyConfiguration()` is called, the proxy compares the new configuration against the running state to determine which virtual clusters need to be restarted. Change detection is implemented as a pipeline of `ChangeDetector` implementations, each responsible for one category of change:

- **`VirtualClusterChangeDetector`** — identifies clusters that were added, removed, or modified by comparing `VirtualClusterModel` instances via `equals()`. A cluster requires a restart if any property that contributes to `VirtualClusterModel.equals()` changed (bootstrap address, TLS settings, gateway configuration, etc.).
- **`FilterChangeDetector`** — identifies clusters affected by filter configuration changes. A cluster requires a restart if a `NamedFilterDefinition` it references changed (type or configuration, compared via `equals()`), or if the `defaultFilters` list changed (order matters, since filter chain execution is sequential) and the cluster relies on default filters.

Detectors return a `ChangeResult(clustersToRemove, clustersToAdd, clustersToModify)`. Results from all detectors are aggregated and then passed onto `VirtualClusterManager` to perform relevant operations.

Clusters where none of these changed are left untouched — they continue serving traffic throughout the apply operation.

### Cluster modification via lifecycle transitions

A modified virtual cluster is restarted by driving it through the lifecycle states defined in Proposal 016. Proposal 016 defines the per-VC state machine (`VirtualClusterLifecycleState`) and the `VirtualClusterLifecycleManager` that enforces valid transitions. This proposal adds the reload operations that drive those transitions.

The three change operations map to lifecycle transitions as follows:

**Modify (Restart VC):** `SERVING → DRAINING → [drain connections] → [deregister gateways] → INITIALIZING → [register gateways] → SERVING`

A modified cluster is torn down and rebuilt with the new configuration. During restart, the lifecycle state cycles through Draining and back to Initializing without ever reaching the terminal Stopped state. This means the `onVirtualClusterTerminalFailure` callback does not fire during restart — reload is an internal VCM operation that stays within the lifecycle state machine.

**Remove:** `SERVING → DRAINING → [drain connections] → [deregister gateways] → STOPPED`

A removed cluster is permanently torn down. It reaches the terminal Stopped state via `draining → stopped`. This is an intentional removal, not a failure — the `onVirtualClusterTerminalFailure` callback does **not** fire (it only fires on the `failed → stopped` edge).

**Add:** `[create lifecycle manager in INITIALIZING] → [register gateways] → SERVING`

A new cluster starts in the Initializing state with a fresh `VirtualClusterLifecycleManager`, registers its gateways with the `EndpointRegistry`, and transitions to Serving.

Changes are processed in the order: **remove → modify → add**. Removing clusters first frees up ports and resources that new or modified clusters may need.

This means a modified cluster experiences a brief period of unavailability while its ports are unbound and rebound. Clients connected to the cluster will be disconnected during the drain phase. This is a deliberate design choice. More surgical approaches — such as swapping the filter chain on existing connections without dropping them, or performing a rolling handoff — would reduce disruption, but they add significant complexity. The remove+add approach is the right starting point: it is straightforward, predictable, and consistent with how the proxy handles startup failures today. The remove+add approach also creates a thundering herd when all disconnected clients reconnect simultaneously after the cluster comes back up; mitigation strategies (e.g. staggered connection acceptance) are future work.

### Graceful connection draining

Before tearing down a modified or removed cluster, the proxy drives its lifecycle from **Serving to Draining** (via `VirtualClusterLifecycleManager.startDraining()`). The detailed mechanics of connection draining — rejecting new connections, applying backpressure, waiting for in-flight requests, and force-closing after timeout — are defined as part of the `Draining` lifecycle state in Proposal 016 and its implementation. This proposal does not redefine that behaviour; it relies on the lifecycle state machine to handle drain semantics.

Once all connections are drained (or the drain timeout expires), the lifecycle transitions out of Draining:
- For **restart**, gateways are deregistered and re-registered, the lifecycle transitions through Initializing to Serving.
- For **remove**, the lifecycle manager transitions from Draining to Stopped via `drainComplete()`. This is the `draining → stopped` edge — the terminal failure callback does **not** fire.

### VirtualClusterManager integration

[Proposal 016](https://github.com/kroxylicious/design/blob/main/proposals/016-virtual-cluster-lifecycle.md) defines `VirtualClusterManager` as the owner of the VC configuration tree and lifecycle state. It holds the `VirtualClusterModel` list, the per-VC `VirtualClusterLifecycleManager` instances, and the `onVirtualClusterTerminalFailure` callback.

For hot reload, the `VirtualClusterManager` is extended with reload operations that combine lifecycle transitions with infrastructure actions:

- **`removeVirtualCluster(clusterName, rollbackTracker)`** — drives `SERVING → DRAINING → [drain via ConnectionDrainManager] → [deregister via EndpointRegistry] → STOPPED`. This is the `draining → stopped` edge — callback does **not** fire. Tracks the removal for potential rollback.
- **`restartVirtualCluster(clusterName, newModel, rollbackTracker)`** — drives `SERVING → DRAINING → [drain] → [deregister] → INITIALIZING → [register] → SERVING`. Never reaches Stopped; callback does not fire. If re-initialization fails: `INITIALIZING → FAILED → STOPPED` via the `failed → stopped` edge — callback **fires**. Tracks the modification for potential rollback.
- **`addVirtualCluster(newModel, rollbackTracker)`** — creates a new lifecycle manager in Initializing, drives `[register via EndpointRegistry] → INITIALIZING → SERVING`. If initialization fails: `INITIALIZING → FAILED → STOPPED` via the `failed → stopped` edge — callback **fires**. Tracks the addition for potential rollback.

The `VirtualClusterManager` gains two dependencies for reload operations:
- `EndpointRegistry` — for gateway registration and deregistration (port binding/unbinding)
- `ConnectionDrainManager` — for graceful connection draining during the Draining state

The `ConfigurationChangeHandler` calls these `VirtualClusterManager` methods based on the `ChangeResult` from the detection pipeline.

### FilterChainFactory hot-swap

Filter configuration changes require replacing the `FilterChainFactory` that creates filter chains for new connections. The existing architecture creates `FilterChainFactory` once at startup and passes it as a `final` reference to `KafkaProxyInitializer`.

To support hot reload, `KafkaProxy` holds an `AtomicReference<FilterChainFactory>` shared between:
- `KafkaProxyInitializer` — reads via `.get()` on each new connection, always getting the current factory
- `ConfigurationReloadOrchestrator` — swaps via `.set()` after successful reload

On success: the orchestrator atomically swaps to the new factory and closes the old one. On rollback: the new factory is closed and the reference remains unchanged. This ensures a clean transition with no race conditions between connection setup and factory replacement.

### Failure behaviour and rollback

When a VC operation fails during `KafkaProxy.applyConfiguration()`, two independent policies govern the response:

**Orchestration policy (`configurationReload.onFailure.rollback`):**

When `rollback: true` (default), the `ConfigurationChangeHandler` reverts all previously successful operations in reverse order via the `ConfigurationChangeRollbackTracker`. Rollback uses the same lifecycle transitions as normal operations — the state machine doesn't know or care whether it's applying new config or old config:

- For the failed VC: `failed → initializing` with the old config — this is just another initialization attempt
- For successfully modified VCs: `serving → draining → initializing → serving` with the old config
- For successfully added VCs: `serving → draining → stopped` (removed)
- For successfully removed VCs: re-added via `addVirtualCluster` with the old model

When `rollback: false`, the orchestrator does not revert. Successfully applied operations remain in effect. Failed VCs proceed through the lifecycle: `failed → stopped` (terminal failure edge) and the terminal failure policy applies.

**Terminal failure policy (`onVirtualClusterTerminalFailure.serve`):**

When a VC traverses the `failed → stopped` edge — whether during startup, reload, or a failed rollback — the terminal failure callback fires. The `serve` policy then determines the blast radius:

- `serve: none` (default): the proxy shuts down. This matches current behaviour — configuration errors are surfaced immediately.
- `serve: successful`: the proxy continues with remaining healthy VCs. The operator can inspect the failed VC and re-apply.

These policies compose independently. `rollback` determines whether the orchestrator tries to restore previous config. `serve` determines what happens when a VC is truly unrecoverable. Neither knows about or depends on the other.

### Orchestration pipeline

The complete `KafkaProxy.applyConfiguration()` pipeline flows through these layers:

```
KafkaProxy.applyConfiguration(newConfig)
    │
    ├── Reads configurationReload settings from bootstrap config
    ├── Guards: proxy must be running, orchestrator must be initialized
    │
    ▼
ConfigurationReloadOrchestrator.reload(newConfig)
    │
    ├── Acquires reloadLock (prevents concurrent reloads)
    ├── Validates new configuration via Features framework
    ├── Creates new FilterChainFactory with updated filter definitions
    ├── Builds ConfigurationChangeContext (old/new config, models, factories)
    │
    ▼
ConfigurationChangeHandler.handleConfigurationChange(context)
    │
    ├── Aggregates ChangeDetector results:
    │     VirtualClusterChangeDetector → added/removed/modified VCs
    │     FilterChangeDetector → VCs affected by filter changes
    │
    ├── Creates ConfigurationChangeRollbackTracker
    ├── Processes changes in order: Remove → Modify → Add
    │
    ▼
VirtualClusterManager (for each affected VC)
    │
    ├── removeVirtualCluster:   SERVING → DRAINING → drain → deregister → STOPPED
    ├── restartVirtualCluster:  SERVING → DRAINING → drain → deregister → INITIALIZING → register → SERVING
    ├── addVirtualCluster:      INITIALIZING → register → SERVING
    │
    ▼
On success: swap FilterChainFactory, update current config, optionally persist to disk
On failure: apply rollback policy, then terminal failure policy if VC is unrecoverable
```

### Concurrency control

Only one reload operation can execute at a time. The `ConfigurationReloadOrchestrator` uses a `ReentrantLock` to prevent concurrent `KafkaProxy.applyConfiguration()` calls. A second call while a reload is in progress fails immediately with a `ConcurrentReloadException` rather than queuing.

### Worked examples

#### Reload with atomic rollback (default: `rollback: true`)

Setup: VC-A and VC-B serving. Reload modifies both.

```
1. Modify VC-A → succeeds → VC-A serving with new config
2. Modify VC-B → fails → VC-B enters failed

Per-VC recovery (retries: 0 in first impl):
3. No retries configured, recovery immediately exhausted

Orchestration (rollback: true):
4. Try VC-B with old config: failed → initializing → serving ✓
5. Roll back VC-A: serving → draining → initializing → serving (old config) ✓
6. All VCs back to previous known-good state
7. Nothing reaches stopped. Terminal failure callback never fires.
```

#### Reload when rollback itself fails

```
1-3. Same as above — VC-B failed, retries exhausted

Orchestration (rollback: true):
4. Try VC-B with old config → also fails (environment issue?)
5. VC-B is truly unrecoverable
6. Roll back VC-A: serving → draining → initializing → serving (old config) ✓
7. VC-B transitions failed → stopped (terminal failure edge — callback fires)

Terminal failure (serve policy):
8a. serve: none → proxy shuts down
8b. serve: successful → VC-A continues serving (old config), VC-B is gone
```

#### Reload with best-effort (`rollback: false`, `serve: successful`)

Setup: Enforcing new TLS cipher suites across all VCs.

```
1. Modify VC-A → succeeds → VC-A serving with new (secure) config
2. Modify VC-B → fails → VC-B enters failed (upstream doesn't support new ciphers)

Per-VC recovery: exhausted
Orchestration (rollback: false): old config is unacceptable, don't revert

3. VC-B transitions failed → stopped (terminal failure edge — callback fires)

Terminal failure (serve: successful):
4. VC-A continues serving with new cipher suites
5. VC-B is reported as stopped — operator fixes upstream, re-applies
```

#### Startup (no reload)

```
1. Proxy starting. Initializing VC-A and VC-B.
2. VC-A → initializing → serving ✓
3. VC-B → initializing → failed

Per-VC recovery: exhausted (retries: 0)
No reload transaction — there is no old config to roll back to.

4. VC-B transitions failed → stopped (terminal failure edge — callback fires)

Terminal failure (serve policy):
5a. serve: none → proxy shuts down (current default behaviour, unchanged)
5b. serve: successful → VC-A serves, VC-B reported as stopped
```

### Metrics and observability

The following metrics are part of the reload implementation:

- **`kroxylicious_reload_total`** — counter of `KafkaProxy.applyConfiguration()` invocations, labelled by outcome (`success`, `rollback`, `failure`). Enables alerting on reload failures and tracking reload frequency.
- **`kroxylicious_reload_duration_seconds`** — histogram of end-to-end reload duration. Helps operators understand whether reload is meeting SLA expectations and identify slow operations.
- **`kroxylicious_reload_clusters_affected_total`** — counter of per-VC operations during reload, labelled by operation (`add`, `remove`, `modify`) and outcome (`success`, `failure`, `rolledback`). Provides granularity beyond the aggregate reload result.
- **`kroxylicious_drain_duration_seconds`** — histogram of per-VC connection drain duration. Helps tune the `drainTimeout` configuration and detect VCs with long-lived connections.
- **`kroxylicious_drain_connections_force_closed_total`** — counter of connections force-closed after drain timeout. A high rate indicates the drain timeout is too aggressive for the workload.

The per-VC lifecycle state metrics (`kroxylicious_virtual_cluster_state`, `kroxylicious_virtual_cluster_state_duration_seconds`, `kroxylicious_virtual_cluster_transitions_total`) defined in Proposal 016 complement these reload-specific metrics and should be implemented alongside them.

A management endpoint exposing the last reload result (timestamp, outcome, affected clusters, duration) is also valuable for on-demand inspection by operators.

### Plugin resource tracking (known gap)

The change detection described above can identify when a filter's YAML configuration changes (via `equals()` on the configuration model), but it cannot detect when external resources that a plugin reads during initialisation have changed. For example, a password file, TLS keystore, or ACL rules file may have changed on disk even though the plugin's configuration (which only references the file path) is identical.

These reads typically happen deep in nested plugin call stacks (e.g. `RecordEncryption` → `KmsService` → `CredentialProvider` → `FilePassword`), so the runtime has no visibility into what was read or whether it has changed.

Without addressing this gap, an apply operation would miss these changes entirely — the plugin configuration hasn't changed, so no restart is triggered, even though the plugin's actual behaviour would differ if it were reinitialised.

An approach is being explored where plugins read external resources through the runtime (rather than doing direct file I/O), allowing the runtime to track what was read and hash the content for subsequent change detection. This makes dependency tracking automatic rather than relying on plugin authors to opt in. The detailed design for this mechanism will be covered in a separate proposal to keep this one focused on the core apply operation.


## Trigger mechanisms (future work)

The `KafkaProxy.applyConfiguration()` operation is trigger-agnostic. The following trigger mechanisms have been discussed but are explicitly deferred:

- **HTTP endpoint**: An HTTP POST endpoint (e.g. `/admin/config/reload`) that accepts a new configuration and calls `KafkaProxy.applyConfiguration()`. Provides synchronous feedback. Questions remain around security (authentication, binding to localhost vs. network interfaces), whether the endpoint receives the configuration inline or reads it from a file path, and content-type handling.
- **File watcher**: A filesystem watcher that detects changes to the configuration file and triggers `KafkaProxy.applyConfiguration()`. Interacts with Kubernetes ConfigMap mount semantics. Questions remain around debouncing, atomic file replacement, and read-only filesystem constraints.
- **Operator integration**: A Kubernetes operator that reconciles a CRD and calls `KafkaProxy.applyConfiguration()` via the proxy's API. The operator owns the desired state; the proxy does not persist configuration to disk.

Each of these can be designed and implemented independently once the core `KafkaProxy.applyConfiguration()` mechanism is in place.

## Affected/not affected projects

**Affected:**

- **kroxylicious-runtime** (core proxy) — The `KafkaProxy.applyConfiguration()` operation, change detection pipeline (`ChangeDetector`, `VirtualClusterChangeDetector`, `FilterChangeDetector`), reload orchestration (`ConfigurationReloadOrchestrator`, `ConfigurationChangeHandler`, `ConfigurationChangeRollbackTracker`), connection draining infrastructure, and lifecycle-integrated reload operations on `VirtualClusterManager` all live here. This builds on the lifecycle state model (`VirtualClusterLifecycleState`, `VirtualClusterLifecycleManager`, `VirtualClusterManager`) introduced by Proposal 016.
- **kroxylicious-junit5-extension** — Test infrastructure may need to support applying configuration changes to a running proxy in integration tests.

**Not affected:**

- **kroxylicious-operator** — The operator will eventually be a trigger mechanism, but the core apply operation does not depend on it.
- **Filter/plugin implementations** — Existing filters do not need to change. The plugin resource tracking gap (above) may eventually require filters to change how they read external resources, but that is a separate proposal.

## Compatibility

- The `KafkaProxy.applyConfiguration()` operation is additive — it does not change existing startup behaviour.
- The default configuration (`onVirtualClusterTerminalFailure.serve: none`, `configurationReload.onFailure.rollback: true`) matches current behaviour — the proxy shuts down if any VC fails at startup.
- Virtual cluster configuration semantics are unchanged; the proposal only adds the ability to apply changes at runtime.
- Filter definitions and their configuration are unchanged.
- No changes to the on-disk configuration file format beyond the optional `onVirtualClusterTerminalFailure` and `configurationReload` blocks.
- The lifecycle state model (Proposal 016) is unchanged; this proposal only adds operations that drive transitions through the existing state machine and an edge-based policy hook on the `failed → stopped` transition.

## Rejected alternatives

- **File watcher as the primary trigger**: Earlier iterations of this proposal used filesystem watching to detect configuration changes. This was set aside in favour of decoupling the trigger from the apply operation, since the trigger mechanism has unresolved design questions (security, delivery method, Kubernetes integration) that should not block the core capability.
- **Node-based failure policy (`onVirtualClusterStopped`)**: The original Proposal 016 design fired the serve policy when a VC *arrived at* the `Stopped` state. This conflates intentional removal (a success) with terminal failure (a problem). Replaced with edge-based policy that fires only on the `failed → stopped` transition.
- **Single `onFailure: ROLLBACK | TERMINATE` knob**: The original reload design conflated two independent dimensions — orchestration rollback and terminal failure policy — into a single configuration option. Decomposed into `configurationReload.onFailure.rollback` (orchestration) and `onVirtualClusterTerminalFailure.serve` (lifecycle), which compose independently and reveal two additional meaningful behaviour combinations.
- **`ReloadOptions` as a per-call parameter**: An approach where each call to `KafkaProxy.applyConfiguration()` could specify failure behaviour. Rejected because these decisions vary by deployment, not by invocation — they belong in static configuration.
- **`ConfigurationReconciler` naming**: Considered to describe the "compare desired vs current and converge" pattern, but rejected because Kubernetes reconcilers already exist in the Kroxylicious codebase and overloading the term would cause confusion.
- **Plan/apply split on the public interface**: Considered exposing separate `plan()` and `apply()` methods to enable dry-run validation. Decided this is an internal concern — the trigger just needs `KafkaProxy.applyConfiguration()`. A validate/dry-run capability can be added later without changing the interface.
- **Inline configuration via HTTP POST body**: Discussed having the HTTP endpoint accept the full YAML configuration in the request body. An alternative view is that configuration should always live in files (for source control, auditability, consistent state) and the HTTP endpoint should just trigger reading from a specified file path. This question is deferred along with the HTTP trigger design.
- **Separate VirtualClusterManager for reload**: The original hot-reload design had a `VirtualClusterManager` that was purely an operation orchestrator (with `EndpointRegistry` and `ConnectionDrainManager` dependencies). Rather than maintaining two classes with the same name, the reload operations merge into the [Proposal 016](https://github.com/kroxylicious/design/blob/main/proposals/016-virtual-cluster-lifecycle.md) `VirtualClusterManager`, which already owns the VC model list and lifecycle managers. The merged class gains `EndpointRegistry` and `ConnectionDrainManager` dependencies and the `removeVirtualCluster`/`restartVirtualCluster`/`addVirtualCluster` methods.
- **Two terminal states (`Stopped` and `TerminallyFailed`)**: Considered adding a separate terminal state for unrecoverable failures. Rejected because the distinction is about the transition edge, not the terminal state — a stopped cluster is permanently done regardless of why. The edge-based policy hook achieves the same goal without adding state machine complexity.
