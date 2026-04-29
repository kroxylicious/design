# 98 - Proposal 019: KafkaProxy Threading and Lifecycle Contract

## Summary

Define the threading and lifecycle contract for `KafkaProxy`: it is a single-use object with a linear lifecycle (`NEW` -> `STARTING` -> `STARTED` -> `STOPPING` -> `STOPPED`). `startup()` returns a single `CompletableFuture<Void>` representing the full proxy lifetime — it completes only when the proxy reaches `STOPPED`. Both `startup()` and `shutdown()` are idempotent — they may be called multiple times, but only one call performs the work.

## Current Situation

`KafkaProxy` is an internal class — it is not part of the public API. It has an `AtomicBoolean running` field that guards `startup()` and `shutdown()` against concurrent or repeated invocation. The field enforces a basic invariant — you cannot start twice or stop twice — but the contract is implicit:

- There is no documentation of which threads may call which methods.
- The two-state boolean cannot distinguish "not yet started" from "stopped," so `startup()` after `shutdown()` silently succeeds in setting `running` back to `true` rather than being rejected.
- The `block()` method checks `running.get()` but does not define what happens if called before `startup()` or after `shutdown()`. More fundamentally, `block()` exists as a separate method only because `startup()` returns `this` rather than a future — the caller has no other way to wait for shutdown. A `shutdown` `CompletableFuture` already exists internally and is what `block()` joins, but it is not surfaced to callers.
- The `close()` method (from `AutoCloseable`) conditionally calls `shutdown()` based on `running.get()`, but the interaction between `close()` and explicit `shutdown()` calls is undocumented.

The lack of a formal contract means that components within the proxy — such as the virtual cluster lifecycle state machine ([016](./016-virtual-cluster-lifecycle.md)) — cannot make informed decisions about their own concurrency models.

## Motivation

The proxy's lifecycle is simple by design: start once, run, stop once. The threading context is similarly simple but not obvious — `shutdown()` is called from a JVM shutdown hook, which runs on a dedicated thread. The virtual cluster lifecycle ([016](./016-virtual-cluster-lifecycle.md)) introduces per-cluster state machines that execute within this proxy-level lifecycle. Without a documented proxy-level contract, each component must independently guess at the concurrency model.

Formalising the contract provides:

- **Correctness**: the only genuinely invalid sequence (start-after-stop) is detected and rejected. All other repeated or concurrent calls are idempotent.
- **Guidance for Kroxylicious developers**: components within the proxy can choose appropriate synchronisation strategies based on documented guarantees rather than assumptions.
- **A foundation for [016](./016-virtual-cluster-lifecycle.md)**: the virtual cluster lifecycle sits inside the proxy lifecycle. Defining the outer contract first avoids circular reasoning.

## Proposal

### KafkaProxy is Single-Use

A `KafkaProxy` instance follows a linear, non-repeatable lifecycle:

```
NEW  ──>  STARTING  ──>  STARTED  ──>  STOPPING  ──>  STOPPED
                │                                        ▲
                └──────────  (startup failure)  ─────────┘
```

- **NEW**: constructed, not yet started.
- **STARTING**: `startup()` is in progress.
- **STARTED**: the proxy is serving traffic.
- **STOPPING**: `shutdown()` is in progress. The caller may join the future returned by `startup()` to wait for completion.
- **STOPPED**: terminal. All resources released.

If `startup()` fails partway through, the proxy transitions directly to `STOPPED` — partially-acquired resources are released before returning a failed future. There is no `FAILED` state at the proxy level; a failed startup is simply a proxy that went straight to `STOPPED`. This is intentional for two reasons: the proxy is not reconfigurable, so there is no recovery transition from a hypothetical `FAILED` state (unlike virtual clusters, which support `failed` -> `initializing` for retry with corrected configuration); and the failure is communicated directly to the caller via the future's exceptional completion, so there is no need to hold the error in state for later inspection.

The lifecycle is **not restartable**. Once a proxy reaches `STOPPED`, it cannot return to any earlier state. To restart, create a new `KafkaProxy` instance. This holds across all deployment models: standalone and Kubernetes today, and sidecar or embedded library if those models are supported in the future.

Dynamic configuration reload will handle changes within a running proxy; there is no use case for tearing down and re-creating a proxy instance.

### The Lifecycle Future

`startup()` returns a `CompletableFuture<Void>` that represents the proxy's **full lifetime** — it is the same future on every call, and completes only when the proxy reaches `STOPPED`. The caller always discovers the final outcome by joining the future received from `startup()`:

```java
// Standalone — block the main thread until shutdown
proxy.startup().join();

// Embedded / tests — start and hold the future
CompletableFuture<Void> stopped = proxy.startup();
// ... do other work ...
stopped.join();
```

The future has three terminal outcomes:

| Path | Completion |
|---|---|
| Startup failure (`STARTING → STOPPED`) | Exceptionally — the startup error |
| Clean shutdown (`STOPPING → STOPPED`) | Normally |
| Shutdown failure (`STOPPING → STOPPED`) | Exceptionally — the shutdown error |

Calling `cancel()` on the future is equivalent to calling `shutdown()` — it initiates a graceful shutdown. The `mayInterruptIfRunning` parameter is ignored; shutdown is always graceful regardless of its value.

The existing `block()` method is deprecated and delegates to `join()` on the lifecycle future.

### Threading Contract

| Method | May be called from | Behaviour |
|---|---|---|
| `startup()` | Any thread | First call initialises the proxy and returns a future. Subsequent calls return the same future. Throws `IllegalStateException` if the proxy is `STOPPING` or `STOPPED`. |
| `shutdown()` | Any thread (including JVM shutdown hook) | First call initiates shutdown. Subsequent calls are no-ops. No-op if the proxy was never started. |
| `close()` | Any thread | Delegates to `shutdown()`. |

Both `startup()` and `shutdown()` are idempotent — callers do not need to coordinate. Only one call actually does the work; additional calls are harmless. This avoids requiring defensive checks at every call site (e.g. a test calling `shutdown()` explicitly and `@AfterEach` calling it again).

**Concurrency guarantees:**

1. **At most one startup and one shutdown sequence will execute.** Multiple concurrent calls to `startup()` all receive the same future; only one thread performs initialisation. Multiple concurrent calls to `shutdown()` are similarly safe; only one thread performs the shutdown sequence.
2. **`shutdown()` may be called from a different thread than `startup()`.** This is the common case: `startup()` on the application thread, `shutdown()` from a JVM shutdown hook.
3. **The caller joins the same future for both startup and shutdown outcomes.** It is safe to join the future concurrently with `shutdown()` — `shutdown()` is what completes it, at the end of the shutdown sequence.

### Error Behaviour

The only invalid sequence is attempting to start a proxy that is shutting down or has stopped:

| Attempted operation | Current state | Result |
|---|---|---|
| `startup()` | `STOPPING` or `STOPPED` | `IllegalStateException` — the proxy is not restartable |

All other repeated or concurrent calls are idempotent no-ops (or return the existing future).

### Process Exit Codes

There are three paths into `STOPPED`, each reflected in the lifecycle future:

1. **Startup failure** (`STARTING → STOPPED`): the future completes exceptionally. The caller (typically `main()`) receives the exception and should exit with a non-zero status code.
2. **Clean shutdown** (`STOPPING → STOPPED`): the future completes normally. The caller exits with zero.
3. **Shutdown failure** (`STOPPING → STOPPED`): the future completes exceptionally with the shutdown error. The caller should exit with a non-zero status code.

`KafkaProxy` itself does not call `System.exit()` — translating the outcome into a process exit code is the responsibility of the application entry point. This keeps `KafkaProxy` usable in embedded and test contexts where process termination is not appropriate.

### Metrics

While the lifecycle state enum remains internal (see [Rejected Alternatives](#public-lifecycle-state-enum)), the proxy should expose metrics that reflect its lifecycle state. Platform-level observability (restart counts, container termination reasons) treats the process as a black box — it can tell an operator *that* a process restarted but not *why*, and cannot distinguish a startup failure from a crash during normal operation without heuristics.

The proxy should expose:

- **State gauge**: a metric indicating the current lifecycle state (`starting`, `started`, `stopping`, `stopped`). This gives dashboards and alerts a definitive signal rather than requiring inference from Kubernetes-level indicators.
- **Startup duration**: time elapsed from `STARTING` to `STARTED` (or failure). This helps operators identify configuration or environment issues that slow startup across restarts.

These metrics are public API surface — once exposed, their names and semantics become a compatibility commitment. The specific metric names and labelling conventions should be consistent with any metrics framework adopted for virtual cluster lifecycle ([016](./016-virtual-cluster-lifecycle.md)).

## Affected/Not Affected Projects

**Affected:**
- **kroxylicious-proxy (runtime)**: `KafkaProxy` gains a formal lifecycle contract. `startup()` returns a `CompletableFuture<Void>`. `block()` is deprecated.
- **kroxylicious-proxy tests**: tests that exercise lifecycle edge cases (double-start, start-after-stop) should be added.

**Not affected:**
- **kroxylicious-api**: the filter SPI does not interact with proxy lifecycle.
- **kroxylicious-operator**: interacts with the proxy process, not the `KafkaProxy` object directly.
- **kroxylicious-kms and plugin modules**: no changes needed.

## Compatibility

This proposal formalises existing behaviour rather than changing it. The proxy is already single-use in practice — no code path calls `startup()` twice or restarts after `shutdown()`. The change makes the contract explicit and enforces it.

The API change is that `startup()` changes its return type from `KafkaProxy` to `CompletableFuture<Void>`. Since `KafkaProxy` is an internal class, there are no external callers to migrate.

The one behavioural change is stricter error detection: calling `startup()` on a stopped proxy currently appears to succeed but would leave the proxy in a corrupt state. After this change, it throws `IllegalStateException`. This is a bug fix, not a compatibility break.

## Rejected Alternatives

### Public lifecycle state enum

We considered making the lifecycle state enum part of the public API so that external code (operators, management endpoints) could query proxy state programmatically. The enum remains internal — external observability is better served by metrics (see [Metrics](#metrics)), which provide the same information through a standard interface without coupling consumers to an internal type.

### Separate futures per phase

We considered a three-phase model: `startup()` returns a future completing at `STARTED`, `block()` keeps the main thread alive through the running phase, and `shutdown()` returns a future completing at `STOPPED`. This gives a clear signal when the proxy is ready to serve traffic, but it requires the caller to manage three separate handles. It also does not simplify the existing API — `block()` must remain because without it, the main thread returns as soon as startup completes and `shutdown()` is never called. The single lifetime future is simpler: joining it keeps the main thread alive through the running phase, and its completion mode (normal or exceptional) captures the full outcome.

### Hard shutdown via `cancel(true)`

`cancel(mayInterruptIfRunning)` could distinguish graceful shutdown (`false`) from hard shutdown (`true` — bypass drain, force-close connections immediately). However, hard shutdown is better expressed as a dedicated method on `KafkaProxy` itself, where the intent is explicit and the API can evolve independently of `Future` semantics. There is no current use case driving a hard shutdown capability, so this is left for a future proposal.

### Restartable proxy

We considered allowing `startup()` -> `shutdown()` -> `startup()` cycles on the same instance. This would require careful resource management (ensuring all state is fully cleaned up before re-initialisation), add complexity to the lifecycle model, and serves no practical use case. Dynamic configuration reload handles changes within a running proxy, and a full restart in the same process is adequately served by creating a new `KafkaProxy` instance. The added complexity is not justified.
