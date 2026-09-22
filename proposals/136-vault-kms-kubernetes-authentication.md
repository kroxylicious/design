# 136 - Vault KMS: Kubernetes Authentication and Credentials Restructure

<!-- TOC -->
* [136 - Vault KMS: Kubernetes Authentication and Credentials Restructure](#136---vault-kms-kubernetes-authentication-and-credentials-restructure)
  * [Current situation](#current-situation)
  * [Motivation](#motivation)
  * [Proposal](#proposal)
    * [Grouped `credentials` configuration node](#grouped-credentials-configuration-node)
    * [Vault URL, Enterprise Namespaces, and Path resolution](#vault-url-enterprise-namespaces-and-path-resolution)
    * [Token Authentication (`credentials.vaultToken`)](#token-authentication-credentialsvaulttoken)
    * [Kubernetes Authentication (`credentials.kubernetes`)](#kubernetes-authentication-credentialskubernetes)
    * [Backward compatibility and deprecation of top-level `vaultTransitEngineUrl` and `vaultToken`](#backward-compatibility-and-deprecation-of-top-level-vaulttransitengineurl-and-vaulttoken)
    * [Java Configuration Schema](#java-configuration-schema)
    * [OpenRewrite YAML migration tooling](#openrewrite-yaml-migration-tooling)
    * [Request flow for Kubernetes authentication](#request-flow-for-kubernetes-authentication)
    * [Token lifecycle and refresh strategy](#token-lifecycle-and-refresh-strategy)
    * [Metrics and Observability](#metrics-and-observability)
    * [End-to-end testing with Testcontainers and Minikube](#end-to-end-testing-with-testcontainers-and-minikube)
  * [Affected/not affected projects](#affectednot-affected-projects)
  * [Compatibility](#compatibility)
  * [Rejected alternatives](#rejected-alternatives)
<!-- TOC -->

This proposal introduces native Kubernetes authentication for the HashiCorp Vault KMS provider and restructures Vault KMS credentials under a grouped `credentials` configuration node, deprecating the legacy flat `vaultToken` configuration property and top-level `vaultTransitEngineUrl`.

## Current situation

The HashiCorp Vault KMS provider for the Record Encryption filter currently authenticates to Vault using a static or file-based token configured via the top-level `vaultToken` property on the `Config` record, along with `vaultTransitEngineUrl`:

```yaml
kms: VaultKmsService
kmsConfig:
  vaultTransitEngineUrl: https://myhashicorpvault:8200/v1/transit
  vaultToken:
    passwordFile: /opt/vault/token
  tls:
    trust: ...
```

In the current implementation:
- `vaultToken` is a required `PasswordProvider` property on the `Config` record.
- `vaultTransitEngineUrl` requires the full path to the transit engine including the `/v1/` API prefix.
- The token is read during initialization and passed to Vault requests via the `X-Vault-Token` HTTP header.
- For long-lived deployments in Kubernetes, users must rely on external sidecars or cron jobs (such as Vault Agent) to refresh token files on disk, or manually administer periodic tokens.

## Motivation

1. **Native Kubernetes Workload Identity**: In Kubernetes, pods have access to a projected `ServiceAccount` JWT token mounted by kubelet. HashiCorp Vault provides a native [Kubernetes auth method](https://developer.hashicorp.com/vault/docs/auth/kubernetes), where a client submits its projected ServiceAccount JWT and a configured Vault role name (`vaultRole`) to `auth/<authPath>/login`, and Vault validates the token against the Kubernetes `TokenReview` API before issuing a temporary client token with a lease.
2. **Eliminate Static Token Management**: Requiring long-lived static tokens in Kubernetes clusters introduces security anti-patterns and operational burden. Using Kubernetes ServiceAccount tokens provides automatic, short-lived, verifiable authentication tied to the pod's identity.
3. **Consistency with Established KMS Design Patterns**: Proposals 017 and 018 restructured AWS KMS from flat mutually exclusive fields (`longTermCredentials`, `ec2MetadataCredentials`) to a grouped `credentials` node (`credentials.longTerm`, `credentials.webIdentity`, `credentials.podIdentity`). Applying the same pattern to HashiCorp Vault ensures consistent configuration across KMS providers (using `vaultUrl` to match the `Url` suffix used in AWS, Thales, and Fortanix) and allows future Vault auth methods (e.g., AppRole, TLS certificates) to be added cleanly without top-level configuration bloat.

## Proposal

### Grouped `credentials` configuration node

Group all Vault authentication mechanisms under a `credentials` node in `kmsConfig`. Exactly one credential mechanism must be configured:

```yaml
kms: VaultKmsService
kmsConfig:
  vaultUrl: https://myhashicorpvault:8200
  vaultNamespace: a/b # optional, for Vault Enterprise namespaces
  transitEnginePath: transit # optional, defaults to transit
  credentials:
    vaultToken:
      token:
        passwordFile: /opt/vault/token
```

```yaml
kms: VaultKmsService
kmsConfig:
  vaultUrl: https://myhashicorpvault:8200
  vaultNamespace: a/b # optional
  transitEnginePath: transit # optional, defaults to transit
  credentials:
    kubernetes:
      vaultRole: kroxylicious-vault-role
      serviceAccountTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
      authPath: kubernetes
```

### Vault URL, Enterprise Namespaces, and Path resolution

To cleanly separate host addresses from endpoint paths and support Vault Enterprise namespaces, `vaultTransitEngineUrl` is replaced by `vaultUrl` alongside explicit path configuration properties:

- `vaultUrl`: The scheme, host, and port of the Vault server (e.g. `https://myhashicorpvault:8200`).
- `vaultNamespace`: Optional field for Vault Enterprise [namespaces](https://developer.hashicorp.com/vault/docs/enterprise/namespaces) (e.g., `a/b`). Defaults to `null` (no namespace). When set, it is both interpolated into URL paths (right after `/v1/`) **and** sent as the `X-Vault-Namespace` HTTP header on every request — consistent with how the Vault CLI (`VAULT_NAMESPACE`), External Secrets Operator, Spring Cloud Vault (`spring.cloud.vault.namespace`), and Quarkus (`quarkus.vault.enterprise.namespace`) all treat namespace as orthogonal to mount-path configuration.
- `transitEnginePath`: Mount path of the Transit secrets engine. Defaults to `transit`.
- `authPath`: Mount path of the Kubernetes authentication method in Vault. Defaults to `kubernetes`.

**URL Resolution Logic:**
- **Transit Engine Endpoint:** `<vaultUrl>/v1/[<vaultNamespace>/]<transitEnginePath>`
- **Kubernetes Auth Login Endpoint:** `<vaultUrl>/v1/[<vaultNamespace>/]auth/<authPath>/login`
- **`X-Vault-Namespace` header:** Set to `vaultNamespace` on all requests when `vaultNamespace` is non-null.

> [!NOTE]
> The provider will log the fully-resolved Transit and Auth login URLs at INFO level during plugin initialization, so administrators can confirm which endpoints will be contacted without enabling full request tracing.

> [!NOTE]
> User documentation in `kroxylicious-docs` will explicitly illustrate how `vaultUrl`, `vaultNamespace`, `transitEnginePath`, and `authPath` combine to form resolved Vault HTTP endpoints across different deployment topographies.

#### Configuration Examples and Endpoint Resolution

1. **Standard Open-Source Vault (Default Mount Paths)**:
   ```yaml
   kmsConfig:
     vaultUrl: https://vault.example.com:8200
     credentials:
       kubernetes:
         vaultRole: kroxylicious-vault-role
   ```
   - **Resolved Transit Endpoint:** `https://vault.example.com:8200/v1/transit`
   - **Resolved K8s Auth Login Endpoint:** `https://vault.example.com:8200/v1/auth/kubernetes/login`

2. **Custom Mount Paths**:
   ```yaml
   kmsConfig:
     vaultUrl: https://vault.example.com:8200
     transitEnginePath: custom-transit
     credentials:
       kubernetes:
         vaultRole: kroxylicious-vault-role
         authPath: custom-k8s
   ```
   - **Resolved Transit Endpoint:** `https://vault.example.com:8200/v1/custom-transit`
   - **Resolved K8s Auth Login Endpoint:** `https://vault.example.com:8200/v1/auth/custom-k8s/login`

3. **Vault Enterprise Namespaces**:
   ```yaml
   kmsConfig:
     vaultUrl: https://vault.example.com:8200
     vaultNamespace: finance/payments
     transitEnginePath: transit
     credentials:
       kubernetes:
         vaultRole: kroxylicious-vault-role
         authPath: kubernetes
   ```
   - **Resolved Transit Endpoint:** `https://vault.example.com:8200/v1/finance/payments/transit`
   - **Resolved K8s Auth Login Endpoint:** `https://vault.example.com:8200/v1/finance/payments/auth/kubernetes/login`

### Token Authentication (`credentials.vaultToken`)

Configured via a dedicated `TokenCredentialsConfig` record supplying a `PasswordProvider` for static or file-based Vault tokens:

```yaml
# File-based token (recommended for static tokens)
credentials:
  vaultToken:
    token:
      passwordFile: /opt/vault/token
```

```yaml
# Inline token
credentials:
  vaultToken:
    token:
      password: s.my-vault-token
```

#### Full Record Encryption Filter Configuration Examples

Below are complete Kroxylicious filter configuration examples demonstrating how the updated Vault KMS provider is configured within the `RecordEncryption` filter:

##### Kubernetes Authentication Example
```yaml
filters:
  - type: RecordEncryption
    config:
      kms: VaultKmsService
      kmsConfig:
        vaultUrl: https://vault.example.com:8200
        credentials:
          kubernetes:
            vaultRole: kroxylicious-vault-role
            serviceAccountTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
      selector: TemplateKmsDefinition
      selectorConfig:
        template: "${topicName}"
```

##### Token Authentication Example
```yaml
filters:
  - type: RecordEncryption
    config:
      kms: VaultKmsService
      kmsConfig:
        vaultUrl: https://vault.example.com:8200
        credentials:
          vaultToken:
            token:
              passwordFile: /opt/vault/token
      selector: TemplateKmsDefinition
      selectorConfig:
        template: "${topicName}"
```

### Kubernetes Authentication (`credentials.kubernetes`)

Configured via a dedicated `KubernetesCredentialsConfig` record:

```yaml
credentials:
  kubernetes:
    vaultRole: kroxylicious-vault-role
    serviceAccountTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token # optional
    authPath: kubernetes # optional
```

| Field | Description | Required? | Default |
|---|---|---|---|
| `vaultRole` | Vault role bound to the Kubernetes ServiceAccount. | Yes | - |
| `serviceAccountTokenFile` | Path to the projected Kubernetes ServiceAccount token file. | No | `/var/run/secrets/kubernetes.io/serviceaccount/token` |
| `authPath` | Mount path of the Kubernetes authentication method in Vault. | No | `kubernetes` |

### Backward compatibility and deprecation of top-level `vaultTransitEngineUrl` and `vaultToken`

To ensure full backward compatibility:
1. The top-level `vaultTransitEngineUrl` and `vaultToken` fields are retained on `Config` and marked with `@Deprecated(since = "0.25.0", forRemoval = true)`.
2. The `Config` compact constructor transparently maps `vaultToken` into `credentials.vaultToken` and derives `vaultUrl` / `transitEnginePath` from `vaultTransitEngineUrl`.
3. If both legacy properties (`vaultTransitEngineUrl` / `vaultToken`) and modern properties (`vaultUrl` / `credentials`) are specified, validation fails fast with an `IllegalArgumentException`.
4. Marking the deprecated fields with `@JsonProperty(access = Access.WRITE_ONLY)` ensures that serializing or round-tripping configuration outputs only the modern `vaultUrl` and `credentials` nodes.

```yaml
# Legacy style - continues to work, but deprecated
kms: VaultKmsService
kmsConfig:
  vaultTransitEngineUrl: https://myhashicorpvault:8200/v1/transit
  vaultToken:
    passwordFile: /opt/vault/token
```

### Java Configuration Schema

```java
public record Config(
    @JsonProperty(value = "vaultUrl", required = false) @Nullable URI vaultUrl,
    @JsonProperty(value = "vaultNamespace", required = false) @Nullable String vaultNamespace,
    @JsonProperty(value = "transitEnginePath", required = false) @Nullable String transitEnginePath,
    @Deprecated(since = "0.25.0", forRemoval = true) @JsonProperty(value = "vaultTransitEngineUrl", required = false, access = Access.WRITE_ONLY) @Nullable URI vaultTransitEngineUrl,
    @Deprecated(since = "0.25.0", forRemoval = true) @JsonProperty(value = "vaultToken", required = false, access = Access.WRITE_ONLY) @Nullable PasswordProvider vaultToken,
    @JsonProperty(value = "credentials", required = false) @Nullable VaultCredentialsConfig credentials,
    @Nullable Tls tls) {

    public Config {
        if (vaultUrl != null && vaultTransitEngineUrl != null) {
            throw new IllegalArgumentException("Cannot specify both 'vaultUrl' and deprecated 'vaultTransitEngineUrl'");
        }
        if (vaultUrl == null && vaultTransitEngineUrl == null) {
            throw new IllegalArgumentException("Either 'vaultUrl' or deprecated 'vaultTransitEngineUrl' must be provided");
        }
        if (vaultToken != null && credentials != null) {
            throw new IllegalArgumentException("Cannot specify both 'vaultToken' and 'credentials' - use 'credentials.vaultToken' instead");
        }
        if (vaultToken == null && credentials == null) {
            throw new IllegalArgumentException("Either 'credentials' or deprecated 'vaultToken' must be provided");
        }
        if (credentials == null) {
            credentials = new VaultCredentialsConfig(new TokenCredentialsConfig(vaultToken), null); // maps legacy vaultToken -> credentials.vaultToken
        }
        if (vaultTransitEngineUrl != null) {
            vaultUrl = URI.create(vaultTransitEngineUrl.getScheme() + "://" + vaultTransitEngineUrl.getAuthority());
            if (transitEnginePath == null) {
                transitEnginePath = extractTransitPath(vaultTransitEngineUrl);
            }
        } else if (transitEnginePath == null) {
            transitEnginePath = "transit";
        }
    }
}

public record VaultCredentialsConfig(
    @JsonProperty("vaultToken") @Nullable TokenCredentialsConfig vaultToken,
    @JsonProperty("kubernetes") @Nullable KubernetesCredentialsConfig kubernetes) {

    public VaultCredentialsConfig {
        if (vaultToken == null && kubernetes == null) {
            throw new IllegalArgumentException("Exactly one of 'vaultToken' or 'kubernetes' credentials must be provided");
        }
        if (vaultToken != null && kubernetes != null) {
            throw new IllegalArgumentException("Exactly one of 'vaultToken' or 'kubernetes' credentials must be provided");
        }
    }
}

public record TokenCredentialsConfig(
    @JsonProperty(value = "token", required = true) PasswordProvider token) {
    public TokenCredentialsConfig {
        Objects.requireNonNull(token, "token must not be null");
    }
}

public record KubernetesCredentialsConfig(
    @JsonProperty(value = "vaultRole", required = true) String vaultRole,
    @JsonProperty(value = "serviceAccountTokenFile", required = false) @Nullable String serviceAccountTokenFile,
    @JsonProperty(value = "authPath", required = false) @Nullable String authPath) {

    public KubernetesCredentialsConfig {
        Objects.requireNonNull(vaultRole, "vaultRole must not be null");
        if (serviceAccountTokenFile == null) {
            serviceAccountTokenFile = "/var/run/secrets/kubernetes.io/serviceaccount/token";
        }
        if (authPath == null) {
            authPath = "kubernetes";
        }
    }
}
```

### OpenRewrite YAML migration tooling

To assist users migrating existing configuration files to the modern schema (`vaultUrl`, `credentials`, etc.), Kroxylicious plans to explore providing refactoring recipes using `openrewrite-yaml`. This tooling will automate updating legacy `vaultTransitEngineUrl` and `vaultToken` properties into `vaultUrl` and `credentials.vaultToken`.

### Request flow for Kubernetes authentication

1. **Read projected token**: When acquiring a token, the provider reads the ServiceAccount JWT from `serviceAccountTokenFile` (re-reading on refresh so token rotations by kubelet are observed).
2. **Login to Vault**: An HTTP POST is dispatched to `<vaultUrl>/v1/[<vaultNamespace>/]auth/<authPath>/login`. For example, `https://myhashicorpvault:8200/v1/auth/kubernetes/login`:
   ```json
   {
     "jwt": "<service-account-jwt>",
     "role": "<vaultRole>"
   }
   ```
3. **Parse auth response**: Vault validates the JWT with Kubernetes and returns a JSON response containing `auth.client_token` and `auth.lease_duration`.
4. **Cache and pre-emptive refresh**: The returned `client_token` is used for `X-Vault-Token` headers. The token is refreshed before expiry based on `lease_duration`.

### Token lifecycle and refresh strategy

- Vault tokens issued by the Kubernetes auth method have a finite TTL (`lease_duration`).
- A percentage-based refresh threshold (80% of `lease_duration`, leaving a 20% safety window before hard expiry) is used to trigger background re-authentication.
- Concurrent requests share the cached or in-flight `CompletableFuture<String>` to prevent duplicate login calls.
- Non-successful HTTP responses and responses missing `auth.client_token` or a positive `auth.lease_duration` fail the login attempt with an error containing Vault's response status and message when available.
- If a refresh fails while the cached token is still valid, requests continue using that token and the refresh is retried with backoff. Once the cached token expires, requests fail until re-authentication succeeds.

### Metrics and Observability

> [!NOTE]
> Raised by @SamBarker: "Do we have existing metrics to cover this request succeeding or failing? Should our metrics be granular enough that we can tell the difference between a request for a DEK failing from a request for a token failing or is it just enough to track that we can't connect to the Vault instance?"

The existing KMS provider metrics track overall DEK encrypt/decrypt request outcomes at the `VaultKms` level but do not currently distinguish **authentication failures** (token acquisition via Kubernetes auth login) from **DEK operation failures** (transit engine encrypt/decrypt calls). With the addition of the Kubernetes authentication flow — a distinct network call that can fail independently — this granularity becomes operationally important:

- A **token acquisition failure** (`/v1/auth/<authPath>/login`) indicates an authentication/configuration problem: bad `vaultRole`, expired ServiceAccount token, Vault RBAC misconfiguration, or a network issue reaching the auth endpoint.
- A **DEK request failure** (`/v1/<transitEnginePath>/datakey`) indicates a transit engine problem: key policy, permissions, or Vault availability.

These have different root causes and different remediation steps, so surfacing them as separate signals is valuable for operators.

**Proposal**: Introduce the following additional metrics for the Kubernetes auth flow:

| Metric | Type | Description |
|---|---|---|
| `kroxylicious_vault_k8s_auth_login_total` | Counter | Total Kubernetes auth login attempts (label: `outcome=success\|failure`) |
| `kroxylicious_vault_k8s_auth_login_duration_seconds` | Histogram | Latency of the Vault Kubernetes auth login call |
| `kroxylicious_vault_k8s_token_refresh_total` | Counter | Total background token refresh attempts (label: `outcome=success\|failure`) |

These complement the existing DEK-level metrics, giving operators the ability to distinguish "can't authenticate to Vault" from "can authenticate but DEK operation failed".

> [!NOTE]
> Whether this metric addition is in scope for the initial implementation or a follow-up is an open question — the critical path is the auth flow itself. At minimum, failures in `KubernetesTokenProvider` should be surfaced clearly in logs (at ERROR level with the Vault response status) to aid diagnosis even without dedicated metrics.

### End-to-end testing with Testcontainers and Minikube

1. **Integration tests (`VaultKmsKubernetesAuthIT`)**:
   - Uses `Testcontainers` to start a Vault container.
   - Spins up a WireMock server stubbing the Kubernetes TokenReview API (`/apis/authentication.k8s.io/v1/tokenreviews`).
   - Generates RSA key pairs and signed JWTs using `jose4j` to simulate the Kubernetes ServiceAccount token.
   - Configures Vault with Kubernetes auth pointing to the WireMock stub via `Testcontainers.exposeHostPorts(...)`, including the Kubernetes API host, CA certificate, JWT issuer, and reviewer JWT.
   - Configures a Vault Kubernetes auth role binding the test JWT's ServiceAccount namespace and name, and stubs a successful `TokenReview` response for that JWT.
   - Verifies the returned Vault client token, lease duration, refresh after expiry, and failure behavior for rejected or malformed login responses.
   - Annotated with `@EnabledIf(value = "isDockerAvailable", disabledReason = "docker unavailable")`.
2. **Minikube deployment verification**:
   - Verified end-to-end on Minikube with a live Vault pod, ClusterRoleBinding for `system:auth-delegator`, and a dedicated `ServiceAccount` for Kroxylicious.
3. **Automated On-Cluster System Test Aspiration**:
   - Expresses an aspiration for automated end-to-end system tests that deploy Kroxylicious on a Kubernetes cluster, wire Vault authentication via ServiceAccount tokens, and verify record encryption on-cluster.
   - Notes that customizing the ServiceAccount mounted to the Kroxylicious proxy pod when deployed by the Kroxylicious Operator depends on proposal #135.

## Affected/not affected projects

**Affected:**
- `kroxylicious-kms-providers/kroxylicious-kms-provider-hashicorp-vault`:
  - New config records: `VaultCredentialsConfig`, `TokenCredentialsConfig`, `KubernetesCredentialsConfig`
  - Updated `Config` record with `vaultUrl`, `vaultNamespace`, `transitEnginePath`, and deprecation handling
  - New token providers: `VaultTokenProvider`, `KubernetesTokenProvider`, `StaticTokenProvider`
  - Updated `VaultKmsService` and `VaultKms`
- `kroxylicious-kms-providers/kroxylicious-kms-provider-hashicorp-vault-test-support`: test fixtures and facades
- `kroxylicious-docs`: updated Vault setup instructions, detailing `vaultUrl`, `vaultNamespace`, `transitEnginePath`, and `authPath` alongside worked configuration examples for standard Vault, custom engine mount paths, and Vault Enterprise namespaces.

**Not affected:**
- Other KMS providers (`aws-kms`, `azure-key-vault-kms`, `fortanix-dsm`, `inmemory`)
- Core Kroxylicious runtime and filter APIs
- Kroxylicious Kubernetes Operator

## Compatibility

- **Backward compatible**: Existing deployments using `vaultTransitEngineUrl` and `vaultToken` at the root of `kmsConfig` continue to operate without change.
- **Deprecation notice**: `vaultTransitEngineUrl` and `vaultToken` are marked as `@Deprecated(since = "0.25.0", forRemoval = true)`. Clear errors are thrown if both legacy and modern properties are specified simultaneously.
- **Forward extensible**: Additional Vault authentication engines (e.g., AppRole, TLS certificates) can be introduced as new fields on `VaultCredentialsConfig` without altering `Config`.

## Rejected alternatives

1. **Flat top-level properties on `Config`**:
   Placing `vaultRole`, `serviceAccountTokenFile`, and `authPath` directly on `Config` alongside `vaultToken`.
   *Rejected because*: It creates confusing mutual exclusivity between top-level fields and diverges from the structured `credentials` pattern established in AWS KMS (proposals 017/018).

2. **External sidecars (Vault Agent Injector) as the only option**:
   Requiring users in Kubernetes to run a Vault Agent sidecar to populate a token file, and providing no native Kubernetes authentication alternative.
   *Not adopted as the only path because*: Native in-process authentication avoids sidecar pod startup latency, resource overhead, and operational complexity.
   *However*: Using a Vault Agent sidecar to manage the token file alongside `credentials.vaultToken.token.passwordFile` **remains a fully supported and valid configuration**. This proposal does not prevent or deprecate that approach — it simply offers native Kubernetes authentication as the preferred path for new deployments. Users already relying on Vault Agent sidecars may continue to do so without any changes.

