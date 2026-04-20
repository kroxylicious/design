# 018 - AWS KMS: EKS workload authentication (IRSA & Pod Identity)

<!-- TOC -->
* [018 - AWS KMS: EKS workload authentication (IRSA & Pod Identity)](#018---aws-kms-eks-workload-authentication-irsa--pod-identity)
  * [Current situation](#current-situation)
  * [Motivation](#motivation)
  * [Proposal](#proposal)
    * [IRSA (AssumeRoleWithWebIdentity)](#irsa-assumerolewithwebidentity)
      * [Request flow](#request-flow)
      * [Configuration](#configuration)
    * [EKS Pod Identity](#eks-pod-identity)
      * [Request flow](#request-flow-1)
      * [Configuration](#configuration-1)
    * [Shared refresh infrastructure](#shared-refresh-infrastructure)
    * [Environment variable defaults](#environment-variable-defaults)
  * [Affected/not affected projects](#affectednot-affected-projects)
  * [Compatibility](#compatibility)
  * [Rejected alternatives](#rejected-alternatives)
<!-- TOC -->

## Current situation

The AWS KMS provider for the Record Encryption filter supports two authentication mechanisms: long-term IAM credentials and EC2 instance metadata.  Per proposal 017, these are being restructured under a `credentials` configuration node.

The existing `Credentials` interface already supports an optional `securityToken()` for temporary credentials, and `AwsV4SigningHttpRequestBuilder` adds the `X-Amz-Security-Token` header when present — so the signing layer is already ready for temporary credentials from STS.

The implementation is AWS-SDK-free: all HTTP calls use `java.net.http.HttpClient` with a custom SigV4 implementation.

Neither existing mechanism works for pods on **Amazon EKS**: long-term keys are a security anti-pattern, and EC2 IMDS is only reachable from EC2 instances.

## Motivation

Amazon EKS is the primary deployment target for Kroxylicious on AWS.  AWS supports two pod-level authentication mechanisms:

1. **IAM Roles for Service Accounts (IRSA)** — a projected OIDC token is exchanged for temporary credentials via STS `AssumeRoleWithWebIdentity`.  This requires an OIDC trust-policy on the IAM role and an annotated Kubernetes service account.  The assumed role must have permissions to perform KMS operations on the KEKs (at minimum `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey*`, `kms:DescribeKey`) as described in the alias-based policy setup.

2. **EKS Pod Identity** — the AWS-recommended successor to IRSA.  An in-cluster Pod Identity Agent (link-local HTTP endpoint) exchanges a projected service-account token for temporary credentials.  No OIDC trust-policy boilerplate is required — the binding is established via an EKS pod-identity association.

Both return the same credential triple (access key, secret key, session token) that the existing `Credentials` interface supports.

This proposal also extracts the async credential refresh machinery from `Ec2MetadataCredentialsProvider` into a shared base class, so the three refreshing providers (EC2, IRSA, Pod Identity) share the same battle-tested code.

## Proposal

### IRSA (AssumeRoleWithWebIdentity)

#### Request flow

1. Read the projected JWT from `webIdentityTokenFile` — **fresh on every refresh**, since kubelet rotates this file roughly hourly.
2. Build an **unsigned** `POST` to the regional STS endpoint:
   ```
   Action=AssumeRoleWithWebIdentity&Version=2011-06-15
   &RoleArn=<url-encoded>&RoleSessionName=<url-encoded>
   &WebIdentityToken=<url-encoded JWT>
   ```
   `AssumeRoleWithWebIdentity` is unsigned by design — the JWT is the credential.
3. Request `Accept: application/json` so STS replies with JSON (no XML parser needed).  This header is not documented in the STS API reference but is used by the AWS SDK v2 and works in practice.
4. Parse `AssumeRoleWithWebIdentityResponse.AssumeRoleWithWebIdentityResult.Credentials` into a record implementing `Credentials`.
5. On HTTP 4xx, surface the STS error code (`InvalidIdentityToken`, `AccessDenied`, `ExpiredTokenException`) in the exception message.

#### Configuration

Registered under `credentials.webIdentity` (per proposal 017):

```yaml
credentials:
  webIdentity:
    roleArn: arn:aws:iam::123456789012:role/KroxyliciousIRSA
    webIdentityTokenFile: /var/run/secrets/eks.amazonaws.com/serviceaccount/token
    roleSessionName: my-session            # optional
    stsEndpointUrl: https://sts.us-east-1.amazonaws.com  # optional, derived from Config.region
    durationSeconds: 3600                  # optional
    credentialLifetimeFactor: 0.8          # optional
```

| Field | Description | Required? | Default | Env var fallback |
|-------|-------------|-----------|---------|-----------------|
| `roleArn` | ARN of the IAM role to assume via STS. | No | — | `AWS_ROLE_ARN` |
| `webIdentityTokenFile` | Path to the projected service-account OIDC token file. Read fresh on every credential refresh (kubelet rotates it roughly hourly). | No | — | `AWS_WEB_IDENTITY_TOKEN_FILE` |
| `roleSessionName` | Identifier for the assumed-role session, visible in AWS CloudTrail. Must match `[\w+=,.@-]{2,64}`. | No | `kroxylicious-<uuid>` (generated at construction time) | `AWS_ROLE_SESSION_NAME` |
| `stsEndpointUrl` | STS endpoint URL for the `AssumeRoleWithWebIdentity` call. Override for non-standard partitions where the endpoint pattern differs (e.g. China: `sts.<region>.amazonaws.com.cn`, ISO: `sts.<region>.c2s.ic.gov`). | No | `https://sts.<Config.region>.amazonaws.com` | — |
| `durationSeconds` | Requested duration of the assumed-role session, in seconds. Valid range: [900, 43200](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html). The effective maximum is further capped by the IAM role's `MaxSessionDuration` setting (default 3600). Validated at construction time. When absent the field is omitted from the STS request and STS applies the role's configured maximum session duration. | No | Omitted (STS default) | — |
| `credentialLifetimeFactor` | Controls preemptive refresh: the credential is refreshed in the background once it reaches this fraction of its total lifetime. Must be in the range (0, 1). For example, 0.8 means the credential is refreshed at 80% of its lifetime. This behaviour is shared with the existing EC2 metadata provider via the `AbstractRefreshingCredentialsProvider` base class. | No | `0.8` | — |

The provider **fails fast** at construction time with a `KmsException` if `roleArn` and `webIdentityTokenFile` cannot be resolved from either YAML configuration or their respective environment variables.  `roleSessionName` is validated against the `[\w+=,.@-]{2,64}` regex and `durationSeconds` against [900, 43200] at construction time for immediate feedback.

On a properly-annotated EKS pod the webhook injects `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE`, so the minimal configuration is:

```yaml
credentials:
  webIdentity: {}
```

### EKS Pod Identity

#### Request flow

1. Read the projected token from `authorizationTokenFile` — **fresh on every refresh**.
2. `GET credentialsFullUri` with header `Authorization: <raw token>` (no `Bearer` prefix — this is the documented Pod Identity Agent contract).
3. Parse the JSON response (`AccessKeyId`, `SecretAccessKey`, `Token`, `Expiration`) into a record implementing `Credentials`.
4. Validate the URI scheme (`http`/`https` only) at construction time.

#### Configuration

Registered under `credentials.podIdentity` (per proposal 017):

```yaml
credentials:
  podIdentity:
    credentialsFullUri: http://169.254.170.23/v1/credentials
    authorizationTokenFile: /var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token
    credentialLifetimeFactor: 0.8          # optional
```

| Field | Description | Required? | Default | Env var fallback |
|-------|-------------|-----------|---------|-----------------|
| `credentialsFullUri` | URL of the Pod Identity Agent credentials endpoint. Must use `http` or `https` scheme (validated at construction time). | No | — | `AWS_CONTAINER_CREDENTIALS_FULL_URI` |
| `authorizationTokenFile` | Path to the projected service-account token file used as the `Authorization` header when calling the agent. Read fresh on every credential refresh. | No | — | `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` |
| `credentialLifetimeFactor` | Controls preemptive refresh: the credential is refreshed in the background once it reaches this fraction of its total lifetime. Must be in the range (0, 1). For example, 0.8 means the credential is refreshed at 80% of its lifetime. This behaviour is shared with the existing EC2 metadata provider via the `AbstractRefreshingCredentialsProvider` base class. | No | `0.8` | — |

The Pod Identity Agent listens on a link-local address (`169.254.170.23`) assigned by AWS, reachable only from the same node.  Communication uses plain HTTP by design (same trust boundary as EC2 IMDS at `169.254.169.254`).  The projected service-account token authenticates each pod to the agent.

The provider **fails fast** at construction time with a `KmsException` if `credentialsFullUri` and `authorizationTokenFile` cannot be resolved from either YAML configuration or their respective environment variables.

On a properly-associated EKS pod the agent injects `AWS_CONTAINER_CREDENTIALS_FULL_URI` and `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`, so the minimal configuration is:

```yaml
credentials:
  podIdentity: {}
```

### Shared refresh infrastructure

The async refresh / expiry / exponential-backoff state machine embedded in `Ec2MetadataCredentialsProvider` is extracted into a package-private `AbstractRefreshingCredentialsProvider<C extends Credentials>`.

The base class owns:
- `AtomicReference<CompletableFuture<C>>` credential state machine
- Single-thread `ScheduledExecutorService` for background refresh
- `ExponentialBackoff(500ms, factor 2, cap 60s, jitter)` for retries
- Preemptive refresh at configurable `lifetimeFactor` (default 0.8)
- `close()` to shut down the executor

Subclasses implement:
- `fetchCredentials()` — provider-specific HTTP call
- `expirationOf(C)` — extract expiration instant
- `onRefreshFailure(Throwable)` / `onRefreshSuccess(C)` — optional log hooks

`Ec2MetadataCredentialsProvider` becomes a subclass with identical external behaviour.

### Environment variable defaults

Several configuration fields fall back to standard AWS environment variables when not set in YAML.  The Kroxylicious proxy generally prefers explicit YAML configuration where all settings are visible in a single file.  However, environment variable defaults are justified here for the following reasons:

1. **Platform-injected values** — the EKS IRSA webhook and the Pod Identity agent webhook automatically inject these environment variables into every pod that uses an annotated service account.  The file paths and URIs they inject are not published at well-known stable addresses (unlike the EC2 metadata endpoint at `169.254.169.254`), so the environment is the canonical way the platform communicates them.
2. **Separation of concerns** — requiring these values to be duplicated in the Kroxylicious YAML leaks AWS infrastructure configuration (IAM role ARNs, projected token paths) into Kubernetes manifests.  This breaks the clean separation between infrastructure-level setup (IAM roles, EKS webhook annotations, pod-identity associations — managed by platform admins) and application-level configuration (the Kroxylicious YAML — managed by application teams).
3. **AWS SDK convention** — the [AWS SDK](https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html) itself discovers these values from the environment rather than expecting application-level configuration, so using env-var defaults follows the established AWS convention that EKS users are already familiar with.

All env-var-backed fields can still be overridden explicitly in YAML when the operator wants full control.

## Affected/not affected projects

**Affected:**
- `kroxylicious-kms-provider-aws-kms` — new provider classes, refactored `Ec2MetadataCredentialsProvider`, new `AbstractRefreshingCredentialsProvider`, updated `CredentialsConfig` (per 017)
- `kroxylicious-docs` — new AsciiDoc procedures and configuration snippets

**Not affected:**
- Other KMS providers
- The Kroxylicious operator
- Proxy runtime core

## Compatibility

- **Additive:** both new providers are new configuration options under the `credentials` node (proposal 017).  No existing configuration changes.
- **No breaking changes:** the refactoring of `Ec2MetadataCredentialsProvider` into a subclass of `AbstractRefreshingCredentialsProvider` preserves its external behaviour, including log messages.
- **Testing:** no real EKS cluster is available in CI.  The providers are unit-tested against WireMock-stubbed STS / Pod Identity Agent endpoints.  End-to-end validation on a real EKS cluster is a manual pre-merge step.

## Rejected alternatives

1. **Use the AWS SDK** — The SDK brings transitive dependencies on Netty, Project Reactor, and its own Jackson modules.  The existing provider is deliberately SDK-free.  Both STS `AssumeRoleWithWebIdentity` (one unsigned POST) and the Pod Identity Agent protocol (one authenticated GET) are simple enough to implement directly.

2. **Default credential chain** — The AWS SDK implements an implicit chain that tries sources in order.  Rejected in favour of explicit configuration: users choose exactly one provider in YAML.  An implicit chain makes misconfiguration harder to diagnose and contradicts the explicit-config pattern used by other KMS providers (Azure `entraIdentity`, Fortanix `apiKeySession`).

3. **Support only IRSA, defer Pod Identity** — Pod Identity is the AWS-recommended successor to IRSA.  The shared base class makes the Pod Identity implementation small (~150 lines of provider-specific code), so deferring adds process overhead without meaningful risk reduction.

4. **Duplicate the refresh state machine** — copying the async refresh / backoff code into each new provider avoids touching the existing `Ec2MetadataCredentialsProvider`.  Rejected because the duplication (~200 lines per provider) increases maintenance burden and divergence risk.  The extracted base class is tested via the existing `Ec2MetadataCredentialsProviderTest` which must continue to pass unchanged.
