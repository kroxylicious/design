# Changing Active Proxy Configuration

**Builds on:** [Proposal 016 — Virtual Cluster Lifecycle](https://github.com/kroxylicious/design/blob/main/proposals/016-virtual-cluster-lifecycle.md)

This proposal introduces a mechanism for applying configuration changes to a running Kroxylicious proxy without a full restart. It defines a core `applyConfiguration(Configuration)` operation that accepts a complete configuration, detects what changed, and converges the running state to match — restarting only the affected virtual clusters while leaving unaffected clusters available.

This proposal extends the virtual cluster lifecycle model (Proposal 016) with reload operations. Where Proposal 016 defines the per-VC state machine and the `VirtualClusterManager` that owns it, this proposal defines the change detection pipeline, the reload orchestration layer, and the connection draining infrastructure that drive lifecycle transitions during a configuration apply.

## Current situation

Any change to Kroxylicious configuration — adding, removing, or modifying a virtual cluster, changing a filter definition, or updating default filters — requires a full restart of the proxy process. This means all virtual clusters are torn down and rebuilt, dropping every client connection even if only one cluster was modified.

In Kubernetes deployments, a configuration change means a pod restart. In standalone deployments, it means stopping and restarting the process. Both cause a service interruption that is disproportionate to the scope of the change.

## Motivation

Administrators need to be able to modify proxy configuration in place. Common scenarios include:

- **Adding or removing virtual clusters** as tenants are onboarded or offboarded.
- **Updating filter configuration** (e.g. updating a KMS endpoint, changing a key selection pattern, modifying ACL rules).
- **Rotating TLS certificates or credentials** that filters reference.

The proxy should apply these changes with minimal disruption: only the virtual clusters affected by the change should experience downtime. Unaffected clusters should continue serving traffic without interruption.

## Proposal

### Core API: `applyConfiguration()`

The central operation is:

```java
public CompletableFuture<ReloadResult> applyConfiguration(Configuration newConfig)
```

The caller provides a complete `Configuration` object. The proxy compares it against the currently running configuration, determines what changed, and applies the changes. The method returns a `CompletableFuture<ReloadResult>` that completes with a structured result on success or exceptionally on failure.

In this approach: the caller provides the desired end state, and the proxy is responsible for computing and executing the diff. This is the right starting point — it is simple to reason about and avoids the complexity of delta-based or partial-update APIs. More granular approaches (deltas, targeted snapshots) are worth exploring later, but the initial API should leave room for them without committing to them now.

**Trigger mechanisms are explicitly out of scope for this proposal.** The `applyConfiguration()` operation is the internal interface that any trigger plugs into. How the new configuration arrives — whether via an HTTP endpoint, a file watcher detecting a changed ConfigMap, or a Kubernetes operator callback — is a separate concern. Deferring this keeps the proposal focused and avoids blocking on unresolved questions about trigger design (see [Trigger mechanisms](#trigger-mechanisms-future-work) below).

**Failure behaviour is deployment-level static configuration.** Whether the proxy rolls back or terminates on failure is controlled by `ReloadOptions`, defined once in the proxy's static YAML configuration file. This ensures consistent, operator-controlled behaviour regardless of trigger mechanism. A configuration apply triggered by an HTTP endpoint should behave identically to one triggered by a file watcher or an operator callback. These decisions belong in the proxy's static configuration, keeping the `applyConfiguration()` signature simple.

```yaml
reloadOptions:
  onFailure: ROLLBACK          # ROLLBACK | TERMINATE
  persistConfigToDisk: true    # true | false
```

| Field | Values | Description                                                                                            |
|-------|--------|--------------------------------------------------------------------------------------------------------|
| `onFailure` | `ROLLBACK` | **Default.** Undo all changes, restore proxy to previous stable state.                                 |
| | `TERMINATE` | Shut down the entire proxy. Let external supervision (K8s, systemd) restart.                           |
| `persistConfigToDisk` | `true` | **Default.** Write the new configuration to the config file (with `.bak` backup of the replaced file). |
| | `false` | Don't persist. The reload is in-memory only.                                                           |

### Configuration change detection

When `applyConfiguration()` is called, the proxy compares the new configuration against the running state to determine which virtual clusters need to be restarted. Change detection is implemented as a pipeline of `ChangeDetector` implementations, each responsible for one category of change:

- **`VirtualClusterChangeDetector`** — identifies clusters that were added, removed, or modified by comparing `VirtualClusterModel` instances via `equals()`. A cluster requires a restart if any property that contributes to `VirtualClusterModel.equals()` changed (bootstrap address, TLS settings, gateway configuration, etc.).
- **`FilterChangeDetector`** — identifies clusters affected by filter configuration changes. A cluster requires a restart if a `NamedFilterDefinition` it references changed (type or configuration, compared via `equals()`), or if the `defaultFilters` list changed (order matters, since filter chain execution is sequential) and the cluster relies on default filters.

Detectors return a `ChangeResult(clustersToRemove, clustersToAdd, clustersToModify)`. Results from all detectors are aggregated via `LinkedHashSet` to maintain order while deduplicating cluster names that appear in multiple detector results.

Clusters where none of these changed are left untouched — they continue serving traffic throughout the apply operation.

### Cluster modification via lifecycle transitions

A modified virtual cluster is restarted by driving it through the lifecycle states defined in Proposal 016. Proposal 016 defines the per-VC state machine (`VirtualClusterLifecycleState`) and the `VirtualClusterLifecycleManager` that enforces valid transitions. This proposal adds the reload operations that drive those transitions.

The three reload operations map to lifecycle transitions as follows:

**Restart (modify):** `SERVING → DRAINING → [drain connections] → [deregister gateways] → INITIALIZING → [register gateways] → SERVING`

A modified cluster is torn down and rebuilt with the new configuration. During restart, the lifecycle state cycles through Draining and back to Initializing without ever reaching the terminal Stopped state. This means the `onVirtualClusterStopped` callback (defined in Proposal 016) does not fire during restart — reload is an internal VCM operation that stays within the lifecycle state machine.

**Remove:** `SERVING → DRAINING → [drain connections] → [deregister gateways] → STOPPED`

A removed cluster is permanently torn down. It reaches the terminal Stopped state, and the `onVirtualClusterStopped` callback fires. If the proxy's `onVirtualClusterStopped` failure policy is `serve: none` (the default from Proposal 016), the proxy shuts down. If the policy is `serve: successful`, the proxy continues with the remaining healthy virtual clusters.

**Add:** `[create lifecycle manager in INITIALIZING] → [register gateways] → SERVING`

A new cluster starts in the Initializing state with a fresh `VirtualClusterLifecycleManager`, registers its gateways with the `EndpointRegistry`, and transitions to Serving.

Changes are processed in the order: **remove → modify → add**. Removing clusters first frees up ports and resources that new or modified clusters may need.

This means a modified cluster experiences a brief period of unavailability while its ports are unbound and rebound. Clients connected to the cluster will be disconnected during the drain phase. This is a deliberate design choice. More surgical approaches — such as swapping the filter chain on existing connections without dropping them, or performing a rolling handoff — would reduce disruption, but they add significant complexity. The remove+add approach is the right starting point: it is straightforward, predictable, and consistent with how the proxy handles startup failures today. The remove+add approach also creates a thundering herd when all disconnected clients reconnect simultaneously after the cluster comes back up; mitigation strategies (e.g. staggered connection acceptance) are future work.

### Graceful connection draining

Before tearing down a modified or removed cluster, the proxy drives its lifecycle from **Serving to Draining** (via `VirtualClusterLifecycleManager.startDraining()`). The detailed mechanics of connection draining — rejecting new connections, applying backpressure, waiting for in-flight requests, and force-closing after timeout — are defined as part of the `Draining` lifecycle state in Proposal 016 and its implementation. This proposal does not redefine that behaviour; it relies on the lifecycle state machine to handle drain semantics.

Once all connections are drained (or the drain timeout expires), the lifecycle transitions out of Draining:
- For **restart**, gateways are deregistered and re-registered, the lifecycle transitions through Initializing to Serving.
- For **remove**, the lifecycle manager transitions from Draining to Stopped via `drainComplete()`, and the `onVirtualClusterStopped` callback fires.

### VirtualClusterManager integration

[Proposal-016](https://github.com/kroxylicious/design/blob/main/proposals/016-virtual-cluster-lifecycle.md) defines `VirtualClusterManager` as the owner of the VC configuration tree and lifecycle state. It holds the `VirtualClusterModel` list, the per-VC `VirtualClusterLifecycleManager` instances, and the `onVirtualClusterStopped` callback.

For hot reload, the `VirtualClusterManager` is extended with reload operations that combine lifecycle transitions with infrastructure actions:

- **`removeVirtualCluster(clusterName, rollbackTracker)`** — drives `SERVING → DRAINING → [drain via ConnectionDrainManager] → [deregister via EndpointRegistry] → STOPPED`. Fires `onVirtualClusterStopped` callback. Tracks the removal for potential rollback.
- **`restartVirtualCluster(clusterName, newModel, rollbackTracker)`** — drives `SERVING → DRAINING → [drain] → [deregister] → INITIALIZING → [register] → SERVING`. Never reaches Stopped; callback does not fire. Tracks the modification for potential rollback.
- **`addVirtualCluster(newModel, rollbackTracker)`** — creates a new lifecycle manager in Initializing, drives `[register via EndpointRegistry] → INITIALIZING → SERVING`. Tracks the addition for potential rollback.

The `VirtualClusterManager` gains two dependencies for reload operations:
- `EndpointRegistry` — for gateway registration and deregistration (port binding/unbinding)
- `ConnectionDrainManager` — for graceful connection draining during the Draining state

The `ConfigurationChangeHandler` calls these `VirtualClusterManager` methods based on the `ChangeResult` from the detection pipeline.

### FilterChainFactory hot-swap

Filter configuration changes require replacing the `FilterChainFactory` that creates filter chains for new connections. The existing architecture creates `FilterChainFactory` once at startup and passes it as a `final` reference to `KafkaProxyInitializer`.

To support hot reload, `KafkaProxy` holds an `AtomicReference<FilterChainFactory>` shared between:
- `KafkaProxyInitializer` — reads via `.get()` on each new connection, always getting the current factory
- `ConfigurationReloadOrchestrator` — swaps via `.set()` after successful reload

On success: the orchestrator atomically swaps to the new factory and closes the old one. On failure with `ROLLBACK`: the new factory is closed and the reference remains unchanged. This ensures a clean transition with no race conditions between connection setup and factory replacement.

### Failure behaviour and rollback

The `onFailure` option in `ReloadOptions` controls what happens when a cluster operation fails during apply:

**`ROLLBACK` (default):** All previously successful operations in that apply are rolled back in reverse order via the `ConfigurationChangeRollbackTracker`. Added clusters are removed, modified clusters are reverted to their original configuration, and removed clusters are re-added. The `FilterChainFactory` reference remains unchanged (old factory stays active). After a failed apply, the proxy is in its previous known-good state.

Rollback drives the same lifecycle transitions in reverse: a successfully added cluster is removed (driven to Stopped), a successfully modified cluster is restarted with the original model, and a successfully removed cluster is re-added (registered and driven to Serving).

**`TERMINATE`:** No rollback is attempted. `KafkaProxy.applyConfiguration()` calls `shutdown()`, which drives all VCs through the standard shutdown path (`transitionAllToDraining()` → `transitionAllToStopped()`), firing `onVirtualClusterStopped` for each. The process supervisor (Kubernetes, systemd) is expected to restart the proxy.

For removed clusters that reach Stopped during apply, the `onVirtualClusterStopped` callback fires per the Proposal 016 contract. The callback's failure policy (`serve: none` or `serve: successful`) applies independently of the `onFailure` reload option — these are orthogonal policies. The reload `onFailure` controls whether the orchestration layer rolls back; the `onVirtualClusterStopped` policy controls whether the proxy-level owner shuts down when any VC reaches Stopped.

### Orchestration pipeline

The complete `applyConfiguration()` pipeline flows through these layers:

```
KafkaProxy.applyConfiguration(newConfig)
    │
    ├── Reads ReloadOptions from bootstrap config
    ├── Guards: proxy must be running, orchestrator must be initialized
    │
    ▼
ConfigurationReloadOrchestrator.reload(newConfig, reloadOptions)
    │
    ├── Acquires reloadLock (prevents concurrent reloads)
    ├── Validates new configuration via Features framework
    ├── Creates new FilterChainFactory with updated filter definitions
    ├── Builds ConfigurationChangeContext (old/new config, models, factories)
    │
    ▼
ConfigurationChangeHandler.handleConfigurationChange(context, onFailure)
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
On failure: apply onFailure policy (ROLLBACK / TERMINATE)
```

### Concurrency control

Only one reload operation can execute at a time. The `ConfigurationReloadOrchestrator` uses a `ReentrantLock` to prevent concurrent `applyConfiguration()` calls. A second call while a reload is in progress fails immediately with a `ConcurrentReloadException` rather than queuing.

### Plugin resource tracking (known gap)

The change detection described above can identify when a filter's YAML configuration changes (via `equals()` on the configuration model), but it cannot detect when external resources that a plugin reads during initialisation have changed. For example, a password file, TLS keystore, or ACL rules file may have changed on disk even though the plugin's configuration (which only references the file path) is identical.

These reads typically happen deep in nested plugin call stacks (e.g. `RecordEncryption` → `KmsService` → `CredentialProvider` → `FilePassword`), so the runtime has no visibility into what was read or whether it has changed.

Without addressing this gap, an apply operation would miss these changes entirely — the plugin configuration hasn't changed, so no restart is triggered, even though the plugin's actual behaviour would differ if it were reinitialised.

An approach is being explored where plugins read external resources through the runtime (rather than doing direct file I/O), allowing the runtime to track what was read and hash the content for subsequent change detection. This makes dependency tracking automatic rather than relying on plugin authors to opt in. The detailed design for this mechanism will be covered in a separate proposal to keep this one focused on the core apply operation.

### Metrics and observability (future work)

The initial implementation does not include reload-specific metrics or observability endpoints.
However, the following metrics are identified as valuable for future work and should be introduced once the core reload mechanism is stable:

- **`kroxylicious_reload_total`** — counter of `applyConfiguration()` invocations, labelled by outcome (`success`, `rollback`, `terminate`). Enables alerting on reload failures and tracking reload frequency.
- **`kroxylicious_reload_duration_seconds`** — histogram of end-to-end reload duration. Helps operators understand whether reload is meeting SLA expectations and identify slow operations.
- **`kroxylicious_reload_clusters_affected_total`** — counter of per-VC operations during reload, labelled by operation (`add`, `remove`, `modify`) and outcome (`success`, `failure`, `rolledback`). Provides granularity beyond the aggregate reload result.
- **`kroxylicious_drain_duration_seconds`** — histogram of per-VC connection drain duration. Helps tune the `drainTimeout` configuration and detect VCs with long-lived connections.
- **`kroxylicious_drain_connections_force_closed_total`** — counter of connections force-closed after drain timeout. A high rate indicates the drain timeout is too aggressive for the workload.

The per-VC lifecycle state metrics (`kroxylicious_virtual_cluster_state`, `kroxylicious_virtual_cluster_state_duration_seconds`, `kroxylicious_virtual_cluster_transitions_total`) defined in Proposal 016 complement these reload-specific metrics and should be implemented alongside them.

A management endpoint exposing the last reload result (timestamp, outcome, affected clusters, duration) would also be valuable for on-demand inspection by operators. The design of this endpoint is deferred along with the metrics implementation.

## Open questions

- **Rollback and `onVirtualClusterStopped` interaction**: If a remove operation succeeds (VC reaches Stopped, callback fires) but a subsequent add operation fails and triggers rollback (re-adding the removed VC), the callback will have already fired for the Stopped transition. Should the rollback suppress or compensate for the callback? With `serve: none`, the callback may trigger proxy shutdown before rollback has a chance to restore the VC.

## Trigger mechanisms (future work)

The `applyConfiguration()` operation is trigger-agnostic. The following trigger mechanisms have been discussed but are explicitly deferred:

- **HTTP endpoint**: An HTTP POST endpoint (e.g. `/admin/config/reload`) that accepts a new configuration and calls `applyConfiguration()`. Provides synchronous feedback. Questions remain around security (authentication, binding to localhost vs. network interfaces), whether the endpoint receives the configuration inline or reads it from a file path, and content-type handling.
- **File watcher**: A filesystem watcher that detects changes to the configuration file and triggers `applyConfiguration()`. Interacts with Kubernetes ConfigMap mount semantics. Questions remain around debouncing, atomic file replacement, and read-only filesystem constraints.
- **Operator integration**: A Kubernetes operator that reconciles a CRD and calls `applyConfiguration()` via the proxy's API. The operator owns the desired state; the proxy does not persist configuration to disk.

Each of these can be designed and implemented independently once the core `applyConfiguration()` mechanism is in place.

## Compatibility

- The `applyConfiguration()` operation is additive — it does not change existing startup behaviour.
- Virtual cluster configuration semantics are unchanged; the proposal only adds the ability to apply changes at runtime.
- Filter definitions and their configuration are unchanged.
- No changes to the on-disk configuration file format beyond the optional `reloadOptions` block.
- The lifecycle state model (Proposal 016) is unchanged; this proposal only adds operations that drive transitions through the existing state machine.

## Rejected alternatives

- **File watcher as the primary trigger**: Earlier iterations of this proposal used filesystem watching to detect configuration changes. This was set aside in favour of decoupling the trigger from the apply operation, since the trigger mechanism has unresolved design questions (security, delivery method, Kubernetes integration) that should not block the core capability.
- **`ReloadOptions` as a per-call parameter**: An approach where each call to `applyConfiguration()` could specify failure behaviour (rollback/terminate). Rejected because these decisions vary by deployment, not by invocation — they belong in static configuration.
- **`ConfigurationReconciler` naming**: Considered to describe the "compare desired vs current and converge" pattern, but rejected because Kubernetes reconcilers already exist in the Kroxylicious codebase and overloading the term would cause confusion.
- **Plan/apply split on the public interface**: Considered exposing separate `plan()` and `apply()` methods to enable dry-run validation. Decided this is an internal concern — the trigger just needs `applyConfiguration()`. A validate/dry-run capability can be added later without changing the interface.
- **Inline configuration via HTTP POST body**: Discussed having the HTTP endpoint accept the full YAML configuration in the request body. An alternative view is that configuration should always live in files (for source control, auditability, consistent state) and the HTTP endpoint should just trigger reading from a specified file path. This question is deferred along with the HTTP trigger design.
- **Separate VirtualClusterManager for reload**: The original hot-reload design had a `VirtualClusterManager` that was purely an operation orchestrator (with `EndpointRegistry` and `ConnectionDrainManager` dependencies). Rather than maintaining two classes with the same name, the reload operations merge into the [Proposal 016](https://github.com/kroxylicious/design/blob/main/proposals/016-virtual-cluster-lifecycle.md) `VirtualClusterManager`, which already owns the VC model list and lifecycle managers. The merged class gains `EndpointRegistry` and `ConnectionDrainManager` dependencies and the `removeVirtualCluster`/`restartVirtualCluster`/`addVirtualCluster` methods.
