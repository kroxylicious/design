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
      static:
        environment: "production"
        team: "platform"
      fromLabels:
        zone: "topology.kubernetes.io/zone"
```

The `micrometer` field is an optional object. When omitted, no hooks are configured (current
behaviour is preserved).

`commonTags` is an optional object grouping all common tag sources:

| Field                    | Type               | Required | Description                                                              |
|--------------------------|--------------------|----------|--------------------------------------------------------------------------|
| `commonTags.static`      | map<string,string> | No       | Static key-value pairs, uniform across all replicas                      |
| `commonTags.fromLabels`  | map<string,string> | No       | Tag name → label key; per-pod values resolved via the downward API       |

#### `commonTags.static`: deployment-wide values

Suited for values that are uniform across all replicas and known at deploy time
(e.g. `environment: "production"`, `team: "platform"`).

#### `commonTags.fromLabels`: per-pod values via label promotion

Some tag values — such as availability zone — differ per pod and cannot be resolved at reconcile time because the proxy config file is shared across all replicas.
`commonTags.fromLabels` maps tag names (valid Prometheus label names) to Kubernetes label keys on the `KafkaProxy` CR, which the operator promotes into per-pod metric tags.

Kubernetes label names frequently contain characters (`.`, `/`, `-`) that are illegal in Prometheus tag names, so the tag name must be specified explicitly rather than derived from the label key.

The mechanism is a two-step process:

1. **Operator (reconcile time):** for each entry in `fromLabels`, the operator adds an environment variable to the proxy pod spec using the Kubernetes downward API, exposing the label value to the pod.
2. **Runtime:** `CommonTagsHook` gains support for environment variable interpolation in tag values. The operator writes the generated config referencing the injected env var, which the runtime resolves per-pod at startup.

This allows tags like availability zone to vary correctly across replicas without baking a single value into the shared config file.

A structured schema is preferred over the runtime's freeform `type` + `config` pattern because:

- The set of hook types is small and stable (two implementations exist today).
- CRD-level schema validation catches typos and invalid configuration at admission time.
- Infrastructure admins get IDE autocompletion and clearer documentation.
- Micrometer hooks are not a primary extensibility point the way filters are — they don't warrant the same open-ended plugin model in the CRD.

### Persona ownership

Micrometer configuration is a proxy-wide, infrastructure concern — it affects what metrics the
proxy process emits and has implications for Prometheus scrape targets and dashboard
provisioning. It belongs on `KafkaProxy` (infrastructure admin) rather than
`VirtualKafkaCluster` (developer).

### Reconciler change

The `KafkaProxyReconciler` maps the structured CRD fields to `MicrometerDefinition` entries
for the `Configuration` constructor, replacing the current `List.of()`:

- `standardBinders` → `MicrometerDefinition` with type `StandardBindersHook`
- `commonTags` → `MicrometerDefinition` with type `CommonTagsHook`, merging `static` tag
  values with env var references generated from `fromLabels` entries

For each entry in `commonTags.fromLabels`, the reconciler also adds a downward API env var to
the proxy pod spec so the runtime can resolve the value per-pod.

### Validation

The structured schema enables validation at the CRD level:

1. **Standard binder names** — the `standardBinders` array is validated against the known set
   of binder names (see table below). Unknown names are rejected at admission time.
2. **Static tag keys/values** — `commonTags.static` validated as a non-empty map of non-empty
   string keys and values when present.
3. **`fromLabels` keys** — tag names in `commonTags.fromLabels` must be valid Prometheus label
   names; label key values must be valid Kubernetes label keys.
4. **Conflicts** — a tag name present in both `commonTags.static` and `commonTags.fromLabels`
   is rejected to avoid ambiguity.

Validation failures are surfaced on the `KafkaProxy` status as an `Accepted: False` condition
with reason `Invalid` and a human-readable message identifying the problem, consistent with
how other invalid configuration is reported by the operator. The proxy will not be
(re)configured until the invalid field is corrected.

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

| Project                       | Affected | Notes                                                                               |
|-------------------------------|----------|-------------------------------------------------------------------------------------|
| `kroxylicious-operator`       | Yes      | CRD schema change, reconciler update, downward API env var injection, validation    |
| `kroxylicious-kubernetes-api` | Yes      | Generated Java types for the new CRD field                                          |
| `kroxylicious-runtime`        | Yes      | `CommonTagsHook` requires env var interpolation support for `commonTags.fromLabels` |
| `kroxylicious-design`         | Yes      | This proposal                                                                       |

## Compatibility

- The `micrometer` field is optional and defaults to the current behaviour (no binders).
  Existing `KafkaProxy` CRs are unaffected.
- This is a purely additive CRD schema change — no breaking changes to the `v1alpha1` API.
- `commonTags.fromLabels` requires a runtime enhancement to `CommonTagsHook` for env var
  interpolation. The `commonTags.static` and `standardBinders` fields require no runtime changes.

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

### Promoting all labels automatically

Automatically promoting every label on the `KafkaProxy` CR as a common tag was considered.
This was rejected because Kubernetes stamps system labels on resources (e.g.
`app.kubernetes.io/managed-by`, `helm.sh/chart`) that would pollute metric tag sets with
internal tooling detail and increase cardinality unpredictably. Explicit opt-in via
`commonTags.fromLabels` keeps the tag set under the operator's control.

### Using annotations as the source for tag values

Using annotations rather than labels as the source for `commonTagsFromLabels` was considered.
Labels are the appropriate Kubernetes construct for identifying and categorising resources —
values like zone, environment, and team naturally belong there and are already present on most
resources. Annotations are intended for arbitrary tooling metadata and their values are opaque
strings, potentially requiring a format convention (e.g. encoded YAML or JSON) with attendant
parsing complexity and merge-order ambiguity. Labels are a cleaner fit.

### Per-VirtualKafkaCluster micrometer configuration

Placing the field on `VirtualKafkaCluster` was considered but rejected. Micrometer binders are
JVM-wide (process CPU, heap memory, GC) — they don't vary per virtual cluster. Placing them on
`KafkaProxy` correctly reflects this scope and the infrastructure admin persona.
