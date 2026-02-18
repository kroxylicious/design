# Changing Active Proxy Configuration

This proposal introduces a mechanism for applying configuration changes to a running Kroxylicious proxy without a full restart.
It proposes a core `applyConfiguration(Configuration)` operation that would accept a complete configuration, detect what changed, and converge the running state to match — restarting only the affected virtual clusters while leaving unaffected clusters available.

## Current situation

Any change to Kroxylicious configuration — adding, removing, or modifying a virtual cluster, changing a filter definition, or updating default filters — requires a full restart of the proxy process.
This means all virtual clusters are torn down and rebuilt, dropping every client connection even if only one cluster was modified.

In Kubernetes deployments, a configuration change means a pod restart.
In standalone deployments, it means stopping and restarting the process.
Both cause a service interruption that is disproportionate to the scope of the change.

## Motivation

Administrators need to be able to modify proxy configuration in place.
Common scenarios include:

- **Adding or removing virtual clusters** as tenants are onboarded or offboarded.
- **Updating filter configuration** (e.g. updating a KMS endpoint, changing a key selection pattern, modifying ACL rules).
- **Rotating TLS certificates or credentials** that filters reference.

The proxy should apply these changes with minimal disruption: only the virtual clusters affected by the change should experience downtime.
Unaffected clusters should continue serving traffic without interruption.

## Proposal

### Core API: `applyConfiguration()`

The central operation is:

```
applyConfiguration(Configuration)
```

The caller provides a complete `Configuration` object.
The proxy compares it against the currently running configuration, determines what changed, and applies the changes.

This is a **state-of-the-world** approach: the caller provides the desired end state, and the proxy is responsible for computing and executing the diff.
This is the right starting point — it is simple to reason about and avoids the complexity of delta-based or partial-update APIs.
More granular approaches (deltas, targeted snapshots) are worth exploring later, but the initial API should leave room for them without committing to them now.

**Trigger mechanisms are explicitly out of scope for this proposal.**
The `applyConfiguration()` operation is the internal interface that any trigger plugs into.
How the new configuration arrives — whether via an HTTP endpoint, a file watcher detecting a changed ConfigMap, or a Kubernetes operator callback — is a separate concern.
Deferring this keeps the proposal focused and avoids blocking on unresolved questions about trigger design (see [Trigger mechanisms](#trigger-mechanisms-future-work) below).

**Failure behaviour is deployment-level static configuration.**
Whether the proxy rolls back, terminates, or continues on failure will vary between deployments (a multi-tenant ingress has different requirements than a sidecar), but it should not vary between invocations or between trigger mechanisms within the same deployment.
A configuration apply triggered by an HTTP endpoint should behave identically to one triggered by a file watcher or an operator callback.
These decisions belong in the proxy's static configuration, keeping the `applyConfiguration()` signature simple.

### Configuration change detection

When `applyConfiguration()` is called, the proxy compares the new configuration against the running state to determine which virtual clusters need to be restarted.
A cluster requires a restart if any of the following changed:

- **The virtual cluster model itself** — bootstrap address, TLS settings, gateway configuration, or any other property that contributes to `VirtualClusterModel.equals()`.
- **A filter definition used by the cluster** — if the type or configuration of a `NamedFilterDefinition` referenced by the cluster changed (compared via `equals()`).
- **The default filters list** — if the cluster relies on default filters and the default filters list changed (order matters, since filter chain execution is sequential).

Clusters where none of these changed are left untouched — they continue serving traffic throughout the apply operation.

### Cluster modification: remove + add

A modified virtual cluster is restarted by tearing it down and rebuilding it with the new configuration.
This is a **remove then add** operation:

1. Gracefully drain existing connections (see below).
2. Deregister the cluster's gateways from the endpoint registry (unbind ports).
3. Register the cluster's new gateways with the endpoint registry (bind ports with new configuration).
4. Accept new connections.

This means a modified cluster experiences a brief period of unavailability while its ports are unbound and rebound.
Clients connected to the cluster will be disconnected during the drain phase.

This is a deliberate design choice.
More surgical approaches — such as swapping the filter chain on existing connections without dropping them, or performing a rolling handoff — would reduce disruption, but they add significant complexity (connection migration, state transfer between filter chain instances, partial rollback of in-flight connections).
The remove+add approach is the right starting point: it is straightforward, predictable, and consistent with how the proxy handles startup failures today.
The remove+add approach also creates a thundering herd when all disconnected clients reconnect simultaneously after the cluster comes back up; mitigation strategies (e.g. staggered connection acceptance) are future work.
More surgical alternatives are worth exploring as future work once the foundation is solid.

Changes are processed in the order: **remove → modify → add**.
Removing clusters first frees up ports and resources that new or modified clusters may need.

### Graceful connection draining

Before tearing down a modified or removed cluster, the proxy drains its connections gracefully rather than dropping them abruptly.
The drain process has three phases:

1. **Reject new connections.** The cluster is marked as draining. Any new client connection attempt to the cluster is immediately refused. Unaffected clusters continue accepting connections normally.

2. **Apply backpressure to existing connections.** On each downstream (client → proxy) channel, reading is disabled (`autoRead = false`) so no new requests are accepted from the client. Upstream (proxy → Kafka) channels continue reading so that responses to already-forwarded requests can flow back to clients.

3. **Wait for in-flight requests to complete, then close.** Each connection is monitored for in-flight Kafka requests. Once the pending request count for a connection reaches zero, the connection is closed. If the count does not reach zero within the drain timeout, the connection is force-closed. The drain timeout should be configurable — long-running consumer rebalances or slow produces with `acks=all` can legitimately exceed a short default.

This approach ensures that in-progress Kafka operations complete where possible, while bounding the time the proxy waits before proceeding with the restart.

### Failure behaviour and rollback

The initial default is **all-or-nothing rollback**: if any cluster operation fails during apply (e.g. a port conflict when rebinding, a TLS error, a plugin initialisation failure), all previously successful operations in that apply are rolled back in reverse order.
Added clusters are removed, modified clusters are reverted to their original configuration, and removed clusters are re-added.

This is consistent with startup behaviour, where a failure in any virtual cluster fails the entire proxy.
It produces a predictable outcome: after a failed apply, the proxy is in its previous known-good state, and the administrator can investigate and retry.

Other deployment models may need different behaviour:

- A **multi-tenant ingress** deployment might prefer to continue running with partial success rather than rolling back all changes because one tenant's cluster failed.
- A **Kubernetes sidecar** deployment might prefer to terminate the process and let the supervisor restart it.

These alternatives are deployment-level configuration choices (as discussed above) and do not need to be resolved for the initial implementation.
All-or-nothing rollback is the safe default that covers the common case.

### Plugin resource tracking (known gap)

The change detection described above can identify when a filter's YAML configuration changes (via `equals()` on the configuration model), but it cannot detect when external resources that a plugin reads during initialisation have changed.
For example, a password file, TLS keystore, or ACL rules file may have changed on disk even though the plugin's configuration (which only references the file path) is identical.

These reads typically happen deep in nested plugin call stacks (e.g. `RecordEncryption` → `KmsService` → `CredentialProvider` → `FilePassword`), so the runtime has no visibility into what was read or whether it has changed.

Without addressing this gap, an apply operation would miss these changes entirely — the plugin configuration hasn't changed, so no restart is triggered, even though the plugin's actual behaviour would differ if it were reinitialised.

An approach is being explored where plugins read external resources through the runtime (rather than doing direct file I/O), allowing the runtime to track what was read and hash the content for subsequent change detection.
This makes dependency tracking automatic rather than relying on plugin authors to opt in.
The detailed design for this mechanism will be covered in a separate proposal to keep this one focused on the core apply operation.

## Open questions

- **Configuration granularity**: The initial design uses state-of-the-world snapshots. Is there a use case that requires delta-based operations or more targeted snapshots in the near term, or is this purely future work?
- **Failure behaviour options beyond all-or-nothing**: What specific deployment models need partial-success or terminate-on-failure semantics, and what configuration surface do they need?
- **Drain timeout default and configurability**: What is a reasonable default drain timeout? How should it be configured — globally, per-cluster, or both?

## Trigger mechanisms (future work)

The `applyConfiguration()` operation is trigger-agnostic.
The following trigger mechanisms have been discussed but are explicitly deferred:

- **HTTP endpoint**: An HTTP POST endpoint (e.g. `/admin/config/reload`) that accepts a new configuration and calls `applyConfiguration()`. Provides synchronous feedback. Questions remain around security (authentication, binding to localhost vs. network interfaces), whether the endpoint receives the configuration inline or reads it from a file path, and content-type handling.
- **File watcher**: A filesystem watcher that detects changes to the configuration file and triggers `applyConfiguration()`. Interacts with Kubernetes ConfigMap mount semantics. Questions remain around debouncing, atomic file replacement, and read-only filesystem constraints.
- **Operator integration**: A Kubernetes operator that reconciles a CRD and calls `applyConfiguration()` via the proxy's API. The operator owns the desired state; the proxy does not persist configuration to disk.

Each of these can be designed and implemented independently once the core `applyConfiguration()` mechanism is in place.

## Affected/not affected projects

**Affected:**

- **kroxylicious** (core proxy) — The `applyConfiguration()` operation, change detection, cluster lifecycle management, and connection draining all live here.
- **kroxylicious-junit5-extension** — Test infrastructure may need to support applying configuration changes to a running proxy in integration tests.

**Not affected:**

- **kroxylicious-operator** — The operator will eventually be a trigger mechanism, but the core apply operation does not depend on it.
- **Filter/plugin implementations** — Existing filters do not need to change. The plugin resource tracking gap (above) may eventually require filters to change how they read external resources, but that is a separate proposal.

## Compatibility

- The `applyConfiguration()` operation is additive — it does not change existing startup behaviour.
- Virtual cluster configuration semantics are unchanged; the proposal only adds the ability to apply changes at runtime.
- Filter definitions and their configuration are unchanged.
- No changes to the on-disk configuration file format.

## Rejected alternatives

- **File watcher as the primary trigger**: Earlier iterations of this proposal used filesystem watching to detect configuration changes. This was set aside in favour of decoupling the trigger from the apply operation, since the trigger mechanism has unresolved design questions (security, delivery method, Kubernetes integration) that should not block the core capability.
- **`ReloadOptions` as a per-call parameter**: An approach where each call to `reload()` could specify failure behaviour (rollback/terminate/continue) and whether to persist to disk. Rejected because these decisions vary by deployment, not by invocation — they belong in static configuration.
- **`ConfigurationReconciler` naming**: Considered to describe the "compare desired vs current and converge" pattern, but rejected because Kubernetes reconcilers already exist in the Kroxylicious codebase and overloading the term would cause confusion.
- **Plan/apply split on the public interface**: Considered exposing separate `plan()` and `apply()` methods to enable dry-run validation. Decided this is an internal concern — the trigger just needs `applyConfiguration()`. A validate/dry-run capability can be added later without changing the interface.
- **Inline configuration via HTTP POST body**: Discussed having the HTTP endpoint accept the full YAML configuration in the request body. An alternative view is that configuration should always live in files (for source control, auditability, consistent state) and the HTTP endpoint should just trigger reading from a specified file path. This question is deferred along with the HTTP trigger design.
