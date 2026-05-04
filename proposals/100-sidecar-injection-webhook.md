# Proposal 016 — Sidecar Injection Webhook

A Kubernetes mutating admission webhook that automatically injects a Kroxylicious proxy sidecar into application pods. The sidecar intercepts Kafka traffic on localhost, allowing filters to be applied transparently without changes to the application.

## Current situation

Kroxylicious is deployed either standalone or via the operator as a shared proxy tier, fronting one or more Kafka clusters with ingress networking. Applications connect to the proxy over the network.

There is no mechanism for running Kroxylicious as a per-pod sidecar. Users who want per-pod proxying must manually construct the sidecar container spec, generate proxy configuration, and manage the lifecycle themselves.

The proxy already has properties that make it suitable for sidecar use: it can bind to localhost, and runs as non-root with no special capabilities.

## Motivation

A sidecar model is useful when:

- The application should connect to Kafka via `localhost` rather than through a shared proxy tier.
- Per-pod filter configuration is needed (e.g. different encryption keys per tenant).
- The organisation prefers a service mesh-style deployment where each pod carries its own proxy.

Manual sidecar construction is error-prone and creates a maintenance burden. A webhook automates injection, enforces a consistent security posture, and gives the webhook administrator control over what runs in the sidecar.

## Proposal

### Trust model

The webhook is design to eventually operate under a strict two-party trust model:

- **Webhook administrator**: controls what gets injected — the proxy image, target Kafka address, filter definitions, security context. These are never overridable by the app owner.
- **Application pod owner**: can opt out of injection, and may override specific settings (bootstrap port, node ID range, resource requests) if the admin explicitly delegates those annotations.

Making the boundary between the webhook administrator and the application pod owner a _reliable_ trust boundary will require further development than is specified in this proposal.
However pod annotations in the `sidecar.kroxylicious.io/` namespace form the basic building blocks for a flexible but reliable trust boundary.
* Some annotations are always set by the webhook.
For example, the webhook generates proxy configuration YAML from the `KroxyliciousSidecarConfig` and stores it in a `sidecar.kroxylicious.io/proxy-config` pod annotation (see [Config injection](#config-injection)).
This annotation is projected into the sidecar container as a file via a `downwardAPI` volume.
The webhook always overwrites `sidecar.kroxylicious.io/proxy-config` on the pod, regardless of any value the app owner may have set.
* The administrator can delegate some annotations to be specified by/overridden by the application owner. When specified by the application owner they will not be overwritten by the webhook. Examples defined in this proposal are `sidecar.kroxylicious.io/resources-cpu` and `sidecar.kroxylicious.io/resources-memory` (see below).
* Annotations which the administrator has **not** delegated will have their effect overridden by the webhook based on the Administrator-controlled `KroxyliciousSidecarConfig` resource. A warning will be logged when such overriding is necessary.


### Injection decision

Injection is opt-in at the namespace level and opt-out at the pod level, following the Istio/Linkerd convention:

| Mechanism | Key | Effect |
|-----------|-----|--------|
| Namespace label | `sidecar.kroxylicious.io/injection: enabled` | Webhook intercepts pod creates in this namespace |
| Pod label | `sidecar.kroxylicious.io/inject: "false"` | Pod is excluded via `objectSelector` — never reaches the webhook |

The `MutatingWebhookConfiguration` uses `namespaceSelector` to scope interception and `objectSelector` to exclude opted-out pods. The webhook itself is idempotent: if a container named `kroxylicious-proxy` already exists, injection is skipped.

The failure policy of the webhook will be configurable.
It will default to fail closed (`failurePolicy: Fail`), which is safe, but sacrifices availability of the Kubernetes control plane to admit workloads in cases where the webhook experiences internal errors.
When configured to fail open and the webhook experiences an internal errors, it will log the error and return `allowed: true`; the pod will be admitted unmodified. 

#### Bypass prevention

The webhook sets `KAFKA_BOOTSTRAP_SERVERS` to point at the sidecar, but nothing prevents an application from connecting directly to the target Kafka cluster. Kubernetes `NetworkPolicy` cannot help here: it operates at the pod level, so a policy blocking egress to Kafka would also block the sidecar's connection to the target cluster.

The Istio model — an init container with `NET_ADMIN` that sets up iptables rules to redirect Kafka-port traffic to the sidecar, excluding the proxy process by UID — would enforce this, but requires granting `NET_ADMIN` to the init container, conflicting with the security posture of dropping all capabilities.

In practice, bypassing the sidecar requires the application to deliberately hardcode the real Kafka address. An app owner determined to bypass can also opt out of injection entirely via pod labels. The enforcement boundary is RBAC on who can create pods in the namespace, not network controls within the pod. If the threat model requires enforcement against a hostile app owner, iptables redirection could be added as an opt-in capability in a future iteration.

SASL handling (e.g. rejecting downstream SASL handshakes or requiring proxy-initiated authentication to the target cluster) is out of scope for the alpha. The proxy passes SASL frames through unmodified.

### CRD: `KroxyliciousSidecarConfig`

A namespaced CRD (group `kroxylicious.io`, version `v1alpha1`) defines the sidecar configuration. The webhook admin creates one per namespace. The following edge cases are handled:

1. **No config in namespace**: the pod is admitted without injection (debug log only). This is the common case for namespaces where the admin has enabled the namespace label but not yet created a config.
2. **Multiple configs in namespace**: the pod is admitted without injection (warning logged). The pod can select a specific config via the `sidecar.kroxylicious.io/config` annotation; without this annotation the webhook cannot choose and skips injection.
3. **Config is invalid in a way the webhook can detect** (e.g. malformed delegated annotation values, plugin image without a digest): the webhook logs a warning and admits the pod without injection. Consistent with fail-open semantics.
4. **Config is invalid in a way only the proxy can detect** (e.g. unreachable target Kafka cluster, wrong TLS trust anchor, non-existent filter type): the webhook injects the sidecar normally. The proxy will fail its startup probe and the pod will not become ready, surfacing the problem via standard Kubernetes health-check mechanisms.

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KroxyliciousSidecarConfig
metadata:
  name: my-config
spec:
  targetBootstrapServers: kafka-prod.internal:9092
  bootstrapPort: 9092              # default, configurable
  nodeIdRange:
    startInclusive: 0
    endInclusive: 2
  managementPort: 9082             # default, configurable
  proxyImage: quay.io/kroxylicious/proxy:0.21.0   # optional override
  resources:                       # default resource requests/limits for the sidecar
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
  setBootstrapEnvVar: true         # sets KAFKA_BOOTSTRAP_SERVERS on app containers
  filterDefinitions:
    - name: my-filter
      type: io.example.MyFilterFactory
      config: { ... }
  targetClusterTls:
    trustAnchorSecretRef:
      name: kafka-ca
      key: ca.crt
  plugins:
    - name: my-plugin
      image:
        reference: registry.example.com/my-filter:v1.0@sha256:abc123
        pullPolicy: IfNotPresent
  delegatedAnnotations:
    - sidecar.kroxylicious.io/resources-cpu
    - sidecar.kroxylicious.io/resources-memory
```

**Why a CRD, not a ConfigMap?** Schema validation by the API server, RBAC separation (admin creates, app owners can't modify), status conditions for observability, consistency with the existing Kroxylicious Kubernetes API.

**Why not reuse the operator's CRDs?** The operator CRDs model a shared proxy deployment with ingress networking, multi-cluster support, and cross-resource references. The sidecar use case is fundamentally simpler — one virtual cluster, localhost binding, no ingress. Coupling them would constrain both models.

### Config injection

The webhook generates proxy configuration YAML from the `KroxyliciousSidecarConfig` spec, using the same `Configuration` model from `kroxylicious-runtime`. The generated config is stored in a pod annotation (`sidecar.kroxylicious.io/proxy-config`) and projected into the sidecar container via a `downwardAPI` volume.

This avoids creating per-pod ConfigMaps, which would require additional RBAC, lifecycle management for orphaned ConfigMaps, and unique name generation. The annotation approach is self-contained within the pod.

A typical sidecar config is a few hundred bytes, well within the ~256KB practical annotation size limit.

### Port allocation

| Port | Purpose | Bind address |
|------|---------|-------------|
| 9092 | Kafka bootstrap | `localhost` |
| 9093+ | Per-broker ports (one per node ID) | `localhost` |
| 9082 | Management (`/livez`, `/metrics`) | `0.0.0.0` |

The webhook sets `KAFKA_BOOTSTRAP_SERVERS=localhost:9092` on application containers (configurable, can be disabled).

The management endpoint binds to `0.0.0.0` because kubelet HTTP probes target the pod IP, not loopback. This means the application container can also reach `/livez` and `/metrics`, but neither endpoint exposes sensitive data.

### Native sidecar containers

On Kubernetes 1.28+, the webhook injects the proxy as a native sidecar — an init container with `restartPolicy: Always`. This gives proper startup ordering (proxy starts before the application) and shutdown ordering (proxy stops after the application). On older clusters, the webhook falls back to injecting into `spec.containers`.

The webhook detects the cluster's Kubernetes version at startup and chooses the injection strategy accordingly.

### Sidecar container spec

The injected sidecar follows the same patterns as `ProxyDeploymentDependentResource` in the operator:

- `securityContext`: `allowPrivilegeEscalation: false`, `capabilities: drop ALL`, `readOnlyRootFilesystem: true`
- Probes: `startupProbe` (30 x 2s), `livenessProbe`, `readinessProbe` — all HTTP GET `/livez` on port 9190
- `terminationMessagePolicy: FallbackToLogsOnError`

The security context is never weakened. If the pod already has a stricter security context, it is preserved.

### Target cluster TLS

When `spec.targetClusterTls.trustAnchorSecretRef` is set, the webhook adds a volume mounting the referenced Secret into the sidecar and configures the proxy to use it as a PEM trust store. The Secret must exist in the pod's namespace.

### Delegated annotations

The `delegatedAnnotations` field in `KroxyliciousSidecarConfig` lists which annotations the app owner may set on their pod to override sidecar parameters. The admin sets defaults via the CRD spec (e.g. `spec.resources`); delegation allows the app owner to override those defaults for a specific pod.

Initially it will support:

| Annotation | Effect |
|-----------|--------|
| `sidecar.kroxylicious.io/resources-cpu` | Override the CPU request/limit from `spec.resources` |
| `sidecar.kroxylicious.io/resources-memory` | Override the memory request/limit from `spec.resources` |

Delegation is opt-in per annotation. By default nothing is delegated.

### Configuration drift detection

The webhook stamps each injected pod with a `sidecar.kroxylicious.io/config-generation` annotation recording the `metadata.generation` of the `KroxyliciousSidecarConfig` at injection time. This annotation serves two purposes:

1. **Idempotency guard**: its presence indicates that the sidecar has already been injected, preventing re-injection when the webhook is reinvoked.
2. **Drift detection**: its value can be compared (equality only) with the current generation of the `KroxyliciousSidecarConfig` to identify pods running stale configuration.

Because the webhook only mutates pods at creation time, configuration changes to `KroxyliciousSidecarConfig` do not propagate to running pods. This matches how Istio and Linkerd handle sidecar injection. Users must restart pods to pick up new configuration.

The generation stamp allows operators to identify stale pods:

```
kubectl get pods -n my-ns -o json | jq '[.items[] |
  select(.metadata.annotations["sidecar.kroxylicious.io/config-generation"] != null) |
  {name: .metadata.name, generation: .metadata.annotations["sidecar.kroxylicious.io/config-generation"]}]'
```

In a future iteration, a reconciler could watch for pods with outdated generations and surface an `UpToDate` condition on the `KroxyliciousSidecarConfig` status, giving operators visibility into configuration drift without requiring manual queries.

### Third-party plugin support

#### The problem

Users will want to run third-party Kroxylicious plugins (custom filters, KMS providers) in the sidecar. The proxy discovers plugins via `ServiceLoader` from the classpath. Built-in plugins live in `libs/`. Third-party plugin JARs must be delivered separately.

OCI image volumes (KEP-4639) allow mounting an OCI image as a read-only volume in a pod. This is the cleanest delivery mechanism: plugin authors package their JARs in a `FROM scratch` image, and the webhook mounts it into the sidecar at a known path.

#### Solution

The proxy startup script already scans `/opt/kroxylicious/classpath-plugins/*/` for subdirectories containing JARs and adds them to the classpath. The webhook mounts each plugin's OCI image at `/opt/kroxylicious/classpath-plugins/<name>/`.

For each plugin in `spec.plugins`, the webhook adds:

1. An OCI image volume referencing the plugin image.
2. A read-only volume mount on the sidecar container.

```yaml
volumes:
  - name: plugin-my-filter
    image:
      reference: registry.example.com/my-filter:v1.0@sha256:abc123
      pullPolicy: IfNotPresent
```

```yaml
volumeMounts:
  - name: plugin-my-filter
    mountPath: /opt/kroxylicious/classpath-plugins/my-filter
    readOnly: true
```

ServiceLoader discovers the plugin implementations from the combined classpath. Multiple plugin images can be mounted simultaneously, each at its own subdirectory.

A known and accepted risk of supporting OCI image mounting while the proxy only uses a flat classpath for plugin loading is that the ordering of Jars on that classpath is poorly defined. The longer term solution for that is plugin classloader isolation, which is out of scope for this proposal.

#### Plugin image convention

Plugin images should be built `FROM scratch` with JARs at the image root:

```dockerfile
FROM scratch
COPY target/my-filter.jar /my-filter.jar
COPY target/dependency/*.jar /
```

#### Flat classpath limitations

All plugin JARs share the proxy's flat classpath. There is no classloader isolation. If two plugins bundle different versions of the same library, the one the classloader finds first wins — silently, without error.

Jackson is the concrete concern. The proxy ships Jackson and uses it for filter config deserialization. A plugin bundling an incompatible Jackson version could cause silent serialization differences. Other proxy-provided libraries (Netty, Kafka clients, SLF4J, Micrometer) carry the same risk.

**Mitigations:**

- **Document the constraint**: plugin images should not bundle libraries the proxy already provides. Plugin authors should treat the proxy's dependencies as `provided` scope. Publishing the proxy's transitive dependency closure as a Maven BOM would make this mechanical.
- **Shade transitive dependencies**: plugin authors should shade (relocate) any transitive dependency that might conflict.

Classloader isolation (a classloader per plugin directory, similar to what application servers do) would eliminate this problem but is a significant architectural change. It should be treated as a known future requirement, not a hypothetical.

#### Kubernetes version requirements

| Feature | K8s version | OpenShift version | Status |
|---------|-------------|-------------------|--------|
| OCI image volumes (alpha) | 1.31+ | 4.18+ | Feature gate `ImageVolume` must be enabled |
| OCI image volumes (beta) | 1.33+ | 4.20+ | Feature gate `ImageVolume` must be enabled |
| OCI image volumes (default on) | 1.35+ | 4.22+ | Enabled by default |

**Container runtime support**: OpenShift uses CRI-O exclusively, which supports OCI image volumes from v1.31+ (matching the Kubernetes version). containerd support is maturing (alpha in v2.1.0) but is not relevant to OpenShift deployments. For non-OpenShift clusters using containerd, the init-container fallback (below) is the practical path until containerd support stabilises.

#### Init-container fallback

For clusters without OCI image volume support, the webhook supports an init-container fallback:

1. An init container per plugin image copies JARs to an `emptyDir` volume.
2. The `emptyDir` is mounted at `/opt/kroxylicious/classpath-plugins/<name>` on the sidecar with `readOnly: true`.

This works on any Kubernetes version but adds startup latency and uses writable storage (though the mount itself is read-only on the sidecar).

The webhook auto-detects OCI image volume support via the Kubernetes API server version.

#### Security analysis: admin-controlled plugin images

When the admin specifies plugin images in `KroxyliciousSidecarConfig.spec.plugins`:

- The admin trusts the plugin image publisher.
- The app owner has no control over which images are mounted.
- OCI image volumes are read-only and `noexec` by design.
- Plugin JARs run on the proxy's classpath with the proxy's JVM permissions (non-root, no capabilities, read-only root filesystem).

**Remaining risks:**

- **Supply chain**: a compromised plugin image contains malicious code with access to Kafka traffic and mounted credentials. Mitigate with image signing and digest-pinned references.
- **Dependency conflicts**: as described above under flat classpath limitations.

### Target cluster selection

In many deployments the admin manages multiple Kafka clusters (e.g. production, staging) and the app owner needs to choose which one their pod connects to. Rather than creating a separate `KroxyliciousSidecarConfig` per cluster, the admin defines an allow-list of named target clusters:

```yaml
spec:
  allowedTargetClusters:
    - name: production
      bootstrapServers: kafka-prod.internal:9092
    - name: staging
      bootstrapServers: kafka-staging.internal:9092
```

The app owner selects a cluster by annotation:

```yaml
sidecar.kroxylicious.io/target-cluster: staging
```

The admin retains control over which clusters are reachable. The app owner cannot specify an arbitrary bootstrap address — only names from the allow-list are accepted. If the annotation names a cluster not in the list, or is absent when multiple clusters are defined, injection is skipped with a warning.

When `allowedTargetClusters` is not set, the existing `targetBootstrapServers` field is used directly and there is no cluster selection.

This is the lowest-risk form of delegation — the app owner chooses a network destination from an admin-controlled set — and is likely the highest-demand delegation feature for app teams. It is included in the initial implementation.

### Future delegation

The delegated annotations mechanism (bootstrap port, node ID range, resource requests, plugin images) described above provides a general-purpose extension point for further delegation. These are ordered roughly by blast radius:

1. **Port and resource overrides** — app owner adjusts operational parameters. Low risk.
2. **Filter configuration** — app owner adjusts parameters on admin-selected filters. Medium risk: bounded by the filter's config surface.
3. **Plugin image selection** — app owner chooses what code runs in the proxy JVM. High risk: arbitrary code execution (see security analysis above).

All delegation beyond target cluster selection requires the admin to explicitly list the delegated annotations. Nothing is delegated by default.

### Webhook deployment

The webhook is packaged as a container image and deployed as a single-replica `Deployment` in a dedicated `kroxylicious-webhook` namespace. Install manifests are provided for:

- Namespace, ServiceAccount, ClusterRole, ClusterRoleBinding
- Deployment (port 8443)
- Service (port 443 -> 8443)
- MutatingWebhookConfiguration
- cert-manager Certificate (optional)

**TLS**: Kubernetes requires HTTPS for admission webhooks. The primary path uses cert-manager with a self-signed issuer. A manual alternative (admin provides cert/key Secret) is documented. The webhook watches cert files for rotation and reloads the SSLContext.

**RBAC**: The webhook needs only `get`, `list`, `watch` on `KroxyliciousSidecarConfig` resources and `get`, `list`, `watch` on namespaces. No ConfigMap or Secret creation permissions are needed.

**HTTP server**: Uses the JDK built-in `HttpsServer` (same pattern as `OperatorMain.java`), serving `POST /mutate` and `GET /livez`. No additional HTTP framework dependencies.

### Independence from the operator

The webhook operates independently of the operator. It does not depend on the operator being deployed, does not use JOSDK, and does not reference operator CRDs.

The only shared dependencies are:

- `kroxylicious-kubernetes-api` — for the CRD Java types
- `kroxylicious-runtime` — for the proxy `Configuration` model, used to generate valid proxy config YAML

## Affected/not affected projects

| Project | Affected | Nature of change |
|---------|----------|-----------------|
| `kroxylicious-kubernetes-web-hook` | Yes | New module |
| `kroxylicious-kubernetes-api` | Yes | New CRD: `KroxyliciousSidecarConfig` |
| `kroxylicious-app` | Already merged | `classpath-plugins/` directory scanning |
| `kroxylicious-operator` | No | |
| `kroxylicious-runtime` | No | Used as a dependency, not modified |
| `kroxylicious-filters` | No | |

## Compatibility

This is a new feature with no backwards compatibility concerns.

The `KroxyliciousSidecarConfig` CRD uses `v1alpha1`, signalling that the API may change without notice in future releases.

The webhook can be deployed alongside the operator without conflict — they watch different CRDs and do not interact.

## Rejected alternatives

### ConfigMap instead of CRD for sidecar configuration

A ConfigMap is simpler to create but lacks schema validation, gives no status reporting, and cannot be distinguished from other ConfigMaps by RBAC policy. The CRD provides all of these and is consistent with the project's existing Kubernetes API patterns.

### Per-pod ConfigMap for proxy configuration

Creating a ConfigMap per pod avoids the annotation size limit but introduces lifecycle management (orphaned ConfigMaps), requires `create`/`delete` RBAC for the webhook, and requires unique name generation. The annotation + downwardAPI approach is self-contained.

### Reuse of operator CRDs (`KafkaProxy`, `VirtualKafkaCluster`)

The operator CRDs model multi-cluster, multi-ingress proxy deployments. The sidecar use case is a single virtual cluster on localhost. Coupling them would constrain both APIs and prevent deploying the webhook independently of the operator.

### Classloader-per-plugin isolation

A custom classloader per plugin directory would eliminate dependency conflicts between plugins. This is architecturally significant (the proxy currently assumes a flat classpath via `ServiceLoader.load()`) and is deferred as a future enhancement. The flat classpath with documented constraints is the right tactical choice for the initial implementation.

### `KROXYLICIOUS_CLASSPATH` environment variable for plugins

The proxy already supports a `KROXYLICIOUS_CLASSPATH` env var. However, this is a single classpath string and cannot accommodate multiple independently-mounted plugin directories. The `classpath-plugins/` subdirectory scanning is more natural for volume-per-plugin mounting.
