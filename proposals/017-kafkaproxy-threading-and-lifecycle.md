# Proposal 017: KafkaProxy Threading and Lifecycle Contract

## Summary

Define the threading and lifecycle contract for `KafkaProxy`: it is a single-use object with a linear lifecycle (`NEW` -> `STARTING` -> `STARTED` -> `STOPPING` -> `STOPPED`). Both `startup()` and `shutdown()` are idempotent — they may be called multiple times, but only one call performs the work.

## Current Situation

`KafkaProxy` has an `AtomicBoolean running` field that guards `startup()` and `shutdown()` against concurrent or repeated invocation. The field enforces a basic invariant — you cannot start twice or stop twice — but the contract is implicit:

- There is no documentation of which threads may call which methods.
- The two-state boolean cannot distinguish "not yet started" from "stopped," so `startup()` after `shutdown()` silently succeeds in setting `running` back to `true` rather than being rejected.
- The `block()` method checks `running.get()` but does not define what happens if called before `startup()` or after `shutdown()`. More fundamentally, `block()` exists as a separate method only because `startup()` does not return a future — the caller has no other way to wait for shutdown.
- The `close()` method (from `AutoCloseable`) conditionally calls `shutdown()` based on `running.get()`, but the interaction between `close()` and explicit `shutdown()` calls is undocumented.

The lack of a formal contract means that components within the proxy — such as the virtual cluster lifecycle state machine ([016](./016-virtual-cluster-lifecycle.md)) — cannot make informed decisions about their own concurrency models.

## Motivation

The proxy's lifecycle is simple by design: start once, run, stop once. The threading context is similarly simple but not obvious — `shutdown()` is called from a JVM shutdown hook, which runs on a dedicated thread. The virtual cluster lifecycle ([016](./016-virtual-cluster-lifecycle.md)) introduces per-cluster state machines that execute within this proxy-level lifecycle. Without a documented proxy-level contract, each component must independently guess at the concurrency model.

Formalising the contract provides:

- **Correctness**: the only genuinely invalid sequence (start-after-stop) is detected and rejected. All other repeated or concurrent calls are idempotent.
- **Guidance for implementors**: components within the proxy can choose appropriate synchronisation strategies based on documented guarantees rather than assumptions.
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

If `startup()` fails partway through, the proxy transitions directly to `STOPPED` — partially-acquired resources are released before the exception propagates. There is no `FAILED` state at the proxy level; a failed startup is simply a proxy that went straight to `STOPPED`. This is intentional for two reasons: the proxy is not reconfigurable, so there is no recovery transition from a hypothetical `FAILED` state (unlike virtual clusters, which support `failed` -> `initializing` for retry with corrected configuration); and the failure is communicated directly to the caller via the exception from `startup()`, so there is no need to hold the error in state for later inspection.

The lifecycle is **not restartable**. Once a proxy reaches `STOPPED`, it cannot return to any earlier state. To restart, create a new `KafkaProxy` instance. This holds across all deployment models: standalone, Kubernetes, sidecar, and embedded library.

Dynamic configuration reload handles changes within a running proxy; there is no use case for tearing down and re-creating Netty event loops in-process.

### `startup()` Returns a Future

`startup()` returns a `CompletableFuture<Void>` that completes when the proxy reaches `STOPPED`. This lets the caller decide how to wait:

```java
// Standalone — block the main thread until shutdown
proxy.startup().join();

// Embedded / tests — start and hold the future
var stopped = proxy.startup();
// ... do other work ...
stopped.join();
```

The proxy also holds the future internally. The existing `block()` method is deprecated and delegates to `join()` on the same future.

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
3. **The future returned by `startup()` is safe to join concurrently with `shutdown()`.** The future is completed at the end of the shutdown sequence, regardless of whether shutdown succeeds or fails.

### Error Behaviour

The only invalid sequence is attempting to start a proxy that is shutting down or has stopped:

| Attempted operation | Current state | Result |
|---|---|---|
| `startup()` | `STOPPING` or `STOPPED` | `IllegalStateException` — the proxy is not restartable |

All other repeated or concurrent calls are idempotent no-ops (or return the existing future).

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

The one behavioural change is stricter error detection: calling `startup()` on a stopped proxy currently appears to succeed but would leave the proxy in a corrupt state. After this change, it throws `IllegalStateException`. This is a bug fix, not a compatibility break.

## Rejected Alternatives

### Public lifecycle state enum

We considered making the lifecycle state enum part of the public API so that external code (operators, management endpoints) could query proxy state. However, the proxy is not an entity that external systems monitor at the object level — they monitor the process (health endpoints, readiness probes). The lifecycle state is an internal correctness mechanism, not an observability surface. If proxy-level observability is needed in the future, it should be designed as part of a proxy-level lifecycle proposal (identified as future work in [016](./016-virtual-cluster-lifecycle.md)) rather than prematurely exposing an implementation detail.

### Restartable proxy

We considered allowing `startup()` -> `shutdown()` -> `startup()` cycles on the same instance. This would require careful resource management (ensuring all state is fully cleaned up before re-initialisation), add complexity to the lifecycle model, and serves no practical use case. Dynamic configuration reload handles changes within a running proxy, and a full restart in the same process is adequately served by creating a new `KafkaProxy` instance. The added complexity is not justified.
