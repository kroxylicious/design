# Micrometer Configuration in the KafkaProxy CRD

Expose the proxy's existing Micrometer configuration through the `KafkaProxy` CRD so that
operator-managed proxies have parity with standalone proxy deployments for metrics
instrumentation.

## Current situation

The Kroxylicious runtime supports two Micrometer configuration hooks via the `micrometer`
section in its YAML configuration:

**`StandardBindersHook`** — registers Micrometer binders that expose JVM and process-level
metrics:

```yaml
micrometer:
  - type: StandardBindersHook
    config:
      binderNames:
        - ProcessorMetrics
        - JvmMemoryMetrics
        - JvmGcMetrics
```

**`CommonTagsHook`** — adds common tags to all metrics emitted by the proxy, useful for
distinguishing metrics from multiple proxy instances or environments:

```yaml
micrometer:
  - type: CommonTagsHook
    config:
      commonTags:
        zone: "euc-1a"
        environment: "production"
```

However, the operator's `KafkaProxyReconciler` hardcodes the micrometer list to `List.of()`,
and the `KafkaProxy` CRD has no field to configure either hook. This means operator-managed
proxies cannot emit JVM-level metrics or apply common metric tags.

## Motivation

Without micrometer binders, the Prometheus `/metrics` endpoint only exposes application-level
metrics (filter timings, connection counts). Resource utilisation metrics are absent:

- `process_cpu_seconds_total` / `system_cpu_usage` (from `ProcessorMetrics`)
- `jvm_memory_used_bytes` / `jvm_memory_max_bytes` (from `JvmMemoryMetrics`)
- `jvm_gc_pause_seconds` (from `JvmGcMetrics`)

These are essential for:

1. **Capacity planning and sizing** — understanding proxy resource consumption under load.
2. **Operational monitoring** — alerting on JVM health (memory pressure, excessive GC).
3. **Benchmarking** — the OMB benchmarking infrastructure polls the Prometheus endpoint during
   runs; without these metrics the sizing guide cannot be produced.

The `micrometer` field is the last remaining proxy configuration concept without CRD
representation.

## Proposal

### CRD schema

Add an optional `micrometer` field to the `KafkaProxy` spec with structured sub-fields for
each known hook type, rather than the freeform `type` + `config` pattern used in the runtime
YAML:

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxy
metadata:
  name: benchmark-proxy
spec:
  micrometer:
    standardBinders:
      - ProcessorMetrics
      - JvmMemoryMetrics
      - JvmGcMetrics
    commonTags:
      zone: "euc-1a"
      environment: "production"
```

The `micrometer` field is an optional object. When omitted, no hooks are configured (current
behaviour is preserved).

| Field              | Type              | Required | Description                                                        |
|--------------------|-------------------|----------|--------------------------------------------------------------------|
| `standardBinders`  | array of strings  | No       | List of Micrometer binder names to register (see table below)      |
| `commonTags`       | map<string,string> | No      | Key-value pairs added as tags to all metrics emitted by the proxy  |

#### `commonTags` limitation: static values only

`CommonTagsHook` currently accepts only static string values. This means `commonTags` is
useful for deployment-wide tags (e.g. `environment: "production"`, `team: "platform"`) but
cannot express per-pod values such as availability zone — all replicas would receive the
same tag value.

A future enhancement to the runtime could support environment variable interpolation in tag
values (e.g. `zone: "${AZ}"` or `zone: "env.AZ"`), allowing the operator to inject per-pod
values via the Kubernetes downward API. This is out of scope for this proposal.

A structured schema is preferred over the runtime's freeform `type` + `config` pattern
because:

- The set of hook types is small and stable (two implementations exist today).
- CRD-level schema validation catches typos and invalid configuration at admission time.
- Infrastructure admins get IDE autocompletion and clearer documentation.
- Micrometer hooks are not a primary extensibility point the way filters are — they don't
  warrant the same open-ended plugin model in the CRD.

### Persona ownership

Micrometer configuration is a proxy-wide, infrastructure concern — it affects what metrics the
proxy process emits and has implications for Prometheus scrape targets and dashboard
provisioning. It belongs on `KafkaProxy` (infrastructure admin) rather than
`VirtualKafkaCluster` (developer).

### Reconciler change

The `KafkaProxyReconciler` maps the structured CRD fields to `MicrometerDefinition` entries
for the `Configuration` constructor, replacing the current `List.of()`:

- `standardBinders` → `MicrometerDefinition` with type `StandardBindersHook`
- `commonTags` → `MicrometerDefinition` with type `CommonTagsHook`

### Validation

The structured schema enables validation at the CRD level:

1. **Standard binder names** — the `standardBinders` array should be validated against the
   known set of binder names (see table below). Unknown names are rejected at admission time.
2. **Common tags** — validated as a non-empty map of non-empty string keys and values when
   present.

Validation failures surface as conditions on the `KafkaProxy` status.

### Available standard binders

For reference, `StandardBindersHook` supports these Micrometer binder names:

| Binder                    | Metrics exposed                        |
|---------------------------|----------------------------------------|
| `ProcessorMetrics`        | Process/system CPU usage               |
| `JvmMemoryMetrics`        | Heap/non-heap memory pools             |
| `JvmGcMetrics`            | GC pause times and counts              |
| `JvmThreadMetrics`        | Thread counts (live, daemon, peak)     |
| `JvmHeapPressureMetrics`  | Heap pressure indicators               |
| `JvmCompilationMetrics`   | JIT compilation time                   |
| `JvmInfoMetrics`          | JVM version metadata                   |
| `UptimeMetrics`           | Process uptime                         |
| `FileDescriptorMetrics`   | Open/max file descriptors              |
| `ClassLoaderMetrics`      | Loaded/unloaded class counts           |

### No operator-managed defaults

The operator should not automatically inject binders when the field is omitted. Reasons:

- **Explicitness** — the infrastructure admin should consciously choose which metrics to
  expose. Surprise metrics increase cardinality and may affect Prometheus storage/performance.
- **Consistency** — standalone and operator-managed proxies behave the same way: no binders
  unless configured.
- **Simplicity** — avoids the need for a "disable defaults" escape hatch.

Documentation should include a recommended starting set (e.g. `ProcessorMetrics`,
`JvmMemoryMetrics`, `JvmGcMetrics`) that administrators can copy into their CR.

## Affected/not affected projects

| Project                         | Affected | Notes                                                  |
|---------------------------------|----------|--------------------------------------------------------|
| `kroxylicious-operator`         | Yes      | CRD schema change, reconciler update, validation       |
| `kroxylicious-kubernetes-api`   | Yes      | Generated Java types for the new CRD field             |
| `kroxylicious-runtime`          | No       | Already supports `MicrometerDefinition` — no changes   |
| `kroxylicious-design`           | Yes      | This proposal                                          |

## Compatibility

- The `micrometer` field is optional and defaults to the current behaviour (no binders).
  Existing `KafkaProxy` CRs are unaffected.
- This is a purely additive CRD schema change — no breaking changes to the `v1alpha1` API.
- The feature requires no changes to the proxy runtime; the reconciler maps the structured
  CRD fields to the existing `MicrometerDefinition` model.

## Rejected alternatives

### Freeform `type` + `config` pattern (mirroring the runtime YAML)

Using the same `type` + freeform `config` pattern as `KafkaProtocolFilter` was considered.
This would mirror the runtime's `MicrometerDefinition` model directly. It was rejected because:

- There are only two `MicrometerConfigurationHookService` implementations (`StandardBindersHook`
  and `CommonTagsHook`). A freeform plugin model adds complexity without proportionate benefit.
- Freeform config blocks cannot be validated at the CRD schema level — typos in binder names
  or tag keys would only surface at runtime.
- Filters use the freeform pattern because custom implementations are a primary extensibility
  point with unbounded configuration shapes. Micrometer hooks are not.

If a future hook type is added, the CRD can be extended with a new structured field — this is
a non-breaking additive change under `v1alpha1`.

### Dedicated CRD for micrometer configuration

A separate `KafkaProxyMetrics` or similar CRD was considered but rejected. Micrometer binders
are a simple configuration list with no independent lifecycle — they don't warrant the
complexity of a separate resource and cross-resource references. Filters have their own CRD
(`KafkaProtocolFilter`) because they are composed per-virtual-cluster by a different persona;
micrometer binders apply proxy-wide.

### Implicit defaults with opt-out

Automatically enabling a default set of binders (e.g. `ProcessorMetrics`, `JvmMemoryMetrics`)
unless explicitly overridden was considered. This was rejected because:

- It creates a behavioural difference between standalone and operator-managed proxies.
- It increases metric cardinality for users who don't need JVM metrics.
- It introduces upgrade risk — adding new defaults in a future release would change existing
  deployments' metric output.

### Per-VirtualKafkaCluster micrometer configuration

Placing the field on `VirtualKafkaCluster` was considered but rejected. Micrometer binders are
JVM-wide (process CPU, heap memory, GC) — they don't vary per virtual cluster. Placing them on
`KafkaProxy` correctly reflects this scope and the infrastructure admin persona.
