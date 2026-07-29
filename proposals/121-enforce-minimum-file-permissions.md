# 121 - Enforce minimum access rights on confidential files

Kroxylicious should validate that confidential files (TLS private keys, keystores, truststores,
password files, and KMS credential files) have suitably restrictive filesystem permissions before
reading them, similar to how the `ssh` command refuses to use a world-readable private key.

## Current situation

Kroxylicious reads confidential material from the filesystem - TLS private keys, keystores,
truststores, and passwords - without checking whether those files are accessible by users other
than the owner. A world-readable private key file (`0644`) is silently accepted and used. This
violates the principle of least privilege and increases the risk of credential exposure through
over-permissive filesystem configurations.

## Motivation

Security best practices require that private key material is accessible only to the process that
owns it. Tools such as `ssh`, `gpg`, and many TLS libraries enforce this by refusing to operate
on files with group or other read bits set. Kroxylicious should provide equivalent protection.

The threat model includes:
- Accidental over-permissive file creation (e.g. default `umask` producing `0644`).
- Multi-tenant environments where other users on the same host could read Kroxylicious credentials.
- Kubernetes deployments where secret volumes default to world-readable `0644` unless explicitly
  configured otherwise.

## Proposal

### File permission policies

Three policy modes are available:

- `STRICT` - files must be owner-only (equivalent to `chmod 400` or `chmod 600`). Any group or
  other read/write/execute bits cause an `IllegalStateException` at startup. Mirrors SSH behaviour.
- `RELAXED` - other-user bits are forbidden, but group bits are permitted. This supports
  Kubernetes deployments where `fsGroup` is used to grant a specific GID read access to mounted
  secrets (e.g. `defaultMode: 0440`).
- `DISABLED` - no enforcement. A warning is logged for files that would be rejected by `STRICT`,
  but startup is never rejected.

### Per-category enforcement

Different files have different sensitivity levels and different control boundaries. A single
global policy forces a trade-off: AWS IRSA/Pod Identity token files are typically mounted with
`0644` by the platform (the user cannot control this), while TLS private keys and passwords are
user-controlled. A single policy either weakens protection for secrets or breaks platform
integrations.

Policies are therefore configured per category:

| Category              | Covers                                                                                           | Default    |
|-----------------------|--------------------------------------------------------------------------------------------------|------------|
| `secrets`             | TLS private keys, keystores, password files (all `FilePassword` uses, including KMS credentials) | `STRICT`   |
| `truststores`         | TLS truststore files                                                                             | `RELAXED`  |
| `platformCredentials` | AWS IRSA web identity tokens, AWS EKS Pod Identity authorization tokens                          | `DISABLED` |

The categories are defined by two axes:

- **Who controls the file permissions:** user/operator-controlled files (`secrets`, `truststores`)
  vs. platform-managed files (`platformCredentials`). Platform-managed files are injected by cloud
  provider webhooks/agents and the user cannot control their permissions.
- **Sensitivity of the content:** high-sensitivity material like private keys and credentials
  (`secrets`) vs. public certificates (`truststores`).

### Configuration

```yaml
---
management:
# ...
virtualClusters:
  - name: "one"
    targetCluster:
    # ...
    gateways:
    # ...
security:
  filePermissions:
    secrets: STRICT
    truststores: RELAXED
    platformCredentials: DISABLED
```

When a category is omitted from the configuration, its default value is used. When the entire
`security.filePermissions` section is omitted, all categories use their defaults.

### Category propagation

`FilePermissionValidator` holds per-category policies that are set when `Configuration` is
constructed. Each call site passes the appropriate category when calling `validate()`.

`FilePassword.getProvidedPassword()` defaults to the `secrets` category. This is correct for all
current callers (KMS API keys, Vault tokens, TLS keystore/truststore passwords are all
user-controlled credential files). If a future caller needs a different category, it can validate
explicitly before calling `getProvidedPassword()`.

### Config file write-protection

The configuration file is the trust root for the per-category policies above. If an attacker can
write to the config file, they can weaken the policies to `DISABLED`, rendering the entire feature
useless. Hot-reload ([proposal #83](https://github.com/kroxylicious/design/pull/83), already implemented)
amplifies the risk: with a filesystem watcher trigger, the change takes effect immediately without a restart.

To solve this, Kroxylicious enforces a hardcoded write-protection check on the config file
**before** reading it. This check is independent of any policy setting in the config file.

The config file must not have group-write or other-write bits set. Typical `0644` (`rw-r--r--`)
passes. Group-writable (`0664`) or world-writable (`0666`) files are rejected. Kubernetes
ConfigMap mounts are typically `0644` and pass.

For environments where the config file genuinely needs weaker permissions, an environment variable
with a deliberately alarming name can relax the check:

```
KROXYLICIOUS_DANGEROUSLY_OVERRIDE_CONFIG_FILE_PERMISSION_POLICY=RELAXED
```

This accepts `STRICT` (default when unset), `RELAXED`, or `DISABLED`. The env var is read at
process start and is immutable during the process lifetime - it cannot be weakened by config file
modification or hot-reload. The operator should not set this env var under normal circumstances.

### Exit code for permission failures

When a file permission violation causes the proxy to fail at startup, the proxy exits with exit
code 78 (`EX_CONFIG` from [sysexits.h](https://manpages.ubuntu.com/manpages/noble/man3/sysexits.h.3head.html))
instead of the generic exit code 1. This is implemented via picocli's `IExitCodeExceptionMapper`,
which walks the exception cause chain looking for an `IllegalStateException` containing `"too open"`.

The distinct exit code allows the Kubernetes operator to determine _why_ the proxy crashed by
inspecting `containerStatuses[*].lastState.terminated.exitCode` on the pod - without reading
logs or parsing error messages.

The termination message (the human-readable error text) is surfaced automatically via the
`terminationMessagePolicy: FallbackToLogsOnError` already configured on the proxy container.
Kubernetes captures the last 2048 bytes of log output as
`containerStatuses[*].lastState.terminated.message` when the container exits with a non-zero
exit code.

### Kubernetes operator

The operator mounts all secret volumes with `defaultMode: 0440` (group-readable, no world
access).

On plain Kubernetes, it sets `fsGroup` and `runAsGroup` to the
[Kroxylicious Dockerfile](kroxylicious-app/src/main/docker/proxy.dockerfile) GID (185)
so the kubelet chowns volume files to that GID and the container process can read them via group
membership.

On OpenShift,
[`fsGroup` and `runAsGroup` are omitted](https://www.redhat.com/en/blog/a-guide-to-openshift-and-uids);
[the `restricted-v2` SCC's `MustRunAs` strategy injects the namespace-allocated GID automatically](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/authentication_and_authorization/managing-pod-security-policies#security-context-constraints-example_configuring-internal-oauth).

The `KafkaProxy` CRD exposes `spec.security.filePermissions` with per-category policy fields
(default `secrets: STRICT`, `truststores: RELAXED`, `platformCredentials: DISABLED`) to allow
users to override the policies.

### Operator status condition: `FilePermissionsValid`

The operator surfaces file permission validation failures as a status condition on the
`KafkaProxy` resource:

- `FilePermissionsValid=True` - the proxy is running and no permission violation has been detected.
- `FilePermissionsValid=False` with reason `FilePermissionsViolation` - the proxy crashed
  with exit code 78, indicating a file permission policy violation. The condition's `message`
  field contains the error detail from the termination message.

The operator watches proxy pods via a JOSDK `InformerEventSource<Pod>`, filtered by the
`app.kubernetes.io/managed-by=kroxylicious-operator` label selector. When a pod's container
status shows a terminated state with exit code 78, the operator sets `FilePermissionsValid=False`.
The condition clears automatically when the proxy restarts successfully (the container is no
longer in a terminated state).

Only containers that are not currently running are inspected - if the container has recovered
and is running, the previous crash in `lastState.terminated` is treated as resolved.

## Affected/not affected projects

**Affected:**
- `kroxylicious-security` - new module; contains `FilePermissionValidator` and `FilePermissionConfig`
- `kroxylicious-app` - config file write-protection check before parsing, env var override, `IExitCodeExceptionMapper` for exit code 78
- `kroxylicious-api` - `FilePassword.getProvidedPassword()` validates permissions with `secrets` category
- `kroxylicious-runtime` - `Configuration`, `NettyKeyProvider`, `NettyTrustProvider`, `VirtualClusterModel`, `ServerConnectionStateMachine`
- `kroxylicious-kms-providers` / `kroxylicious-kms-provider-aws-kms` - IRSA and Pod Identity providers validate their token files with `platformCredentials` category
- `kroxylicious-kubernetes` / `kroxylicious-operator` - secret volume `defaultMode`, conditional `fsGroup`, `KafkaProxy` CRD fields, `FilePermissionsValid` status condition, Pod `InformerEventSource`, pods RBAC

**Not affected:**
- `kroxylicious-filters` - no file reading
- `kroxylicious-authorizer-api`, `kroxylicious-authorizer-providers` - no file reading
- KMS providers other than AWS (vault token, Azure, Fortanix) - covered transitively via `FilePassword`

## Delivery

In order to comply with the project's [deprecation policy](https://github.com/kroxylicious/kroxylicious/blob/main/DEV_GUIDE.md#deprecation-policy),
the change in default policies should be staged across two releases.

**Stage 1 (this proposal):** Introduce the feature with `DISABLED` as the default for all
categories for backward compatibility. When `DISABLED` is the effective policy, Kroxylicious logs
a `WARN` for every confidential file whose permissions would be rejected by that category's
intended default (`STRICT` for `secrets`, `RELAXED` for `truststores`). This gives users a
deprecation period to identify and harden their file permissions. The deprecation of `DISABLED`
as the default should be announced in the `CHANGELOG` under "Changes, deprecations and removals".

**Stage 2 (subsequent release, following the deprecation policy):** Change the defaults to their
intended values: `secrets: STRICT`, `truststores: RELAXED`, `platformCredentials: DISABLED`.
This will be a breaking change for deployments that have confidential files with overly permissive
permissions and have not explicitly configured a policy. Deployments that explicitly set
categories to `DISABLED` will be unaffected.
The change in defaults should be documented in the `CHANGELOG` as a breaking change.

## Compatibility

### Backward compatibility

The default policy for all categories in Stage 1 is `DISABLED`, so existing deployments are
unaffected. Warnings are emitted for insecure files to assist users in identifying files to
harden before the defaults change in Stage 2.

### `FilePassword.getProvidedPassword()` behaviour change

With a non-`DISABLED` `secrets` policy, `FilePassword.getProvidedPassword()` can now throw
`IllegalStateException` if the password file has group or other read bits set. This is an
unchecked exception that did not previously occur. Filter authors using `FilePassword` directly
should be aware of this.

### API additions

`FilePermissionValidator` and `FilePermissionConfig` in the new `kroxylicious-security` module
become accessible to consumers of `kroxylicious-api` (which depends on `kroxylicious-security`).
`FilePermissionValidator.setGlobalPolicies()` is necessarily public because `Configuration` (in
`kroxylicious-runtime`) and `FilePermissionValidator` (in `kroxylicious-security`) are in
different modules and Java's access control cannot express "accessible to exactly one other module"
without JPMS. This is a known design limitation: third-party code could in principle call
`setGlobalPolicies()` and alter the global policies for all validations. A future improvement
could adopt JPMS module encapsulation to restrict the method to the `kroxylicious.runtime` module
only.

## Rejected alternatives

### Move `FilePermissionValidator` to `kroxylicious-runtime`

`FilePassword` (in `kroxylicious-api`) needs to call the validator to enforce permissions before
reading a password file. `kroxylicious-runtime` already depends on `kroxylicious-api`, so
`kroxylicious-api` depending back on `kroxylicious-runtime` would create a circular dependency.
The validator therefore cannot live in `kroxylicious-runtime` if `FilePassword` is to use it
directly.

### Move `FilePermissionValidator` to `kroxylicious-api`

Moving the validator directly to `kroxylicious-api` (rather than creating `kroxylicious-security`)
was considered. Rejected because `kroxylicious-api` is conceptually a contract/interface layer;
adding a logging-heavy implementation utility (with SLF4J, `AtomicBoolean`, `ConcurrentHashMap`)
would pollute the API module with infrastructure concerns. A dedicated `kroxylicious-security`
module is the right architectural home.

### Single global policy

A single `security.filePermissions.policy` setting applying to all files was considered. Rejected
because it forces a trade-off between security and platform compatibility: AWS IRSA/Pod Identity
token files are typically `0644` (platform-managed, user cannot control this), so a global
`STRICT` or `RELAXED` policy would break AWS integrations, while a global `DISABLED` policy would
weaken protection for user-controlled secrets. Per-category policies allow each file type to have
the appropriate level of enforcement.

## Future considerations

The following additions to `security.filePermissions` are out of scope for this proposal but could
be added in future work:

- **Symlink policy:** whether to follow symlinks when reading secret files. Kubernetes mounts
  ConfigMaps and Secrets using symlinks internally (`..data` → `..timestamp_directory`), so
  blanket symlink rejection is not viable, but a policy could restrict symlinks in non-Kubernetes
  environments to prevent symlink-based attacks.
- **Path allowlist:** restrict where secret files can be loaded from (e.g. only under
  `/etc/kroxylicious/secrets/`), preventing a configuration from pointing at unexpected filesystem
  locations.

**Probably overkill:**

- **ACL or SELinux context validation:** very environment-specific, hard to get right generically.
- **File integrity (checksum):** verifying file contents against a known hash belongs in a
  different layer (config signing or image verification) rather than in the file permission
  subsystem.