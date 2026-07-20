# 000 - SASL Termination

SASL termination allows the Kroxylicious proxy to authenticate Kafka clients directly, without forwarding SASL exchanges to the upstream Kafka broker. This enables credential isolation, authentication protocol translation, and centralized credential management.

## Current situation

Kroxylicious currently handles client SASL authentication in a number of ways:

1. **SASL Passthrough**: The proxy forwards SASL exchanges unmodified between client and broker. The broker performs all authentication.

2. **SASL Passthrough Inspection**: The [SASL inspection filter][sasl-inspection] observes SASL exchanges as they pass through, extracting the client's authorization ID without making authentication decisions itself. This supports SCRAM-SHA-256, SCRAM-SHA-512, OAUTHBEARER, and PLAIN mechanisms.

3. **OAUTHBEARER Validation**: The [OAUTHBEARER validation filter][oauthbearer-validation] validates JWT tokens before forwarding `SaslAuthenticate` requests to the broker. This is a partial termination — it rejects invalid tokens early but still requires the broker to perform the actual SASL exchange for valid tokens.

None of these approaches allow the proxy to fully terminate SASL: authenticating clients against its own credential store without any SASL interaction with the broker.

[Proposal 004][proposal-004] defined the term "SASL Termination" as: _"a component that responds to a client's `SaslAuthenticate` requests itself, without forwarding those requests to the server."_

[Proposal 006][proposal-006] added the `clientSaslAuthenticationSuccess()` and `clientSaslAuthenticationFailure()` methods to the `FilterContext` API, and explicitly listed "Implement a 1st party SaslTerminator filter" as future work.

This proposal realizes that future work.

## Motivation

### Credential isolation

With SASL termination, the proxy authenticates clients using credentials stored in its own credential store. The broker never sees client credentials. This is valuable when:

- Client credentials should not be shared with or managed by the Kafka cluster administrators.
- Different credential lifecycles are needed for client-facing and broker-facing authentication.
- Compliance requirements mandate credential isolation between organizational boundaries.

### Authentication protocol translation

The proxy can authenticate clients using one SASL mechanism (e.g. SCRAM-SHA-256) while using an entirely different authentication mechanism to connect to the broker (e.g. mTLS, or a service account). This enables:

- Migrating broker authentication without changing client configurations.
- Using client-friendly mechanisms even when the broker supports only a limited set.
- Integrating with identity providers that don't have native Kafka client support.

### Zero-trust edge authentication

In a zero-trust architecture the proxy can enforce authentication at the network edge before any Kafka protocol traffic reaches brokers. Unauthenticated clients are rejected immediately, reducing the broker's attack surface.

### Centralized credential management

A single credential store serves all proxy instances, rather than requiring per-broker credential configuration. Combined with the proxy's existing plugin system, this allows integration with enterprise credential stores.

### Broker-less authentication

A key problem with any passthrough-based technique is that it depends on the availability of a specific Kafka cluster. With the advent of the routing API described by [Proposal 072][proposal-072] there is a need to be able to authenticate a client session before a connection has been made to any target cluster. This is unavoidable because the identity of the client might be an input to the subsequent routing decisions.

## Proposal

This proposal aims to support for the following SASL mechanisms: `SCRAM-SHA-256`, `SCRAM-SHA-512` and `OAUTHBEARER`.
It also aims to be flexible, so as to allow other mechanisms to be supported either in the future, or as plugins.

### The filter

The SASL termination filter intercepts `SASL_HANDSHAKE` and `SASL_AUTHENTICATE` requests, authenticating clients at the proxy and short-circuiting the responses without forwarding them to the broker. It enforces a security barrier: until a client has successfully authenticated, the only requests permitted are `API_VERSIONS`, `SASL_HANDSHAKE`, and `SASL_AUTHENTICATE`. All other request types are rejected with `SASL_AUTHENTICATION_FAILED` and the connection is closed.

#### State machine

The filter maintains per-connection state using a sealed interface `State` with four concrete states:

```
RequiringHandshake ──→ RequiringAuthenticate ←──╮
                              │                  │
                              ├─ (multi-round) ──╯
                              │
                              ├──→ Authenticated ──→ (reauth) ──→ RequiringAuthenticate
                              │         │
                              │         └──→ (expired + non-SASL request) ──→ reject & close
                              │
                              └──→ Failed (terminal)
```

- **RequiringHandshake:** Initial state. Accepts `SASL_HANDSHAKE` requests, which negotiate the mechanism and transition to `RequiringAuthenticate`.
- **RequiringAuthenticate:** Accepts `SASL_AUTHENTICATE` requests. Loops back to itself for multi-round mechanisms (e.g. SCRAM). Carries a reference to the `MechanismHandler` for the negotiated mechanism.
- **Authenticated:** Success state. The filter calls `filterContext.clientSaslAuthenticationSuccess(mechanism, subject)` to propagate the authenticated identity to downstream filters, then forwards all subsequent requests. If reauthentication is configured, this state also stores the session expiry time and allows transition back to `RequiringAuthenticate` via a new `SASL_HANDSHAKE`.
- **Failed:** Terminal failure state. The connection is closed.

The sealed interface prevents creation of invalid states at compile time.

#### Reauthentication (KIP-368)

The filter supports [KIP-368][kip368] reauthentication. When `connectionsMaxReauth` is configured, the filter includes a `sessionLifetimeMs` value in the `SaslAuthenticateResponse` (v1+), informing the client when to reauthenticate.

**Session lifetime computation:** The effective session lifetime is the minimum of:
1. The configured `connectionsMaxReauth` value.
2. The handler-reported credential/token lifetime (e.g. the JWT token's expiry for OAUTHBEARER).

If either value is zero (no opinion / no expiry), the other is used. If both are zero, no reauthentication is required.

**Client behaviour:** Standard Kafka clients (4.0+) handle reauthentication transparently via the `Selector`. When the session nears expiry, the client sends a new `SASL_HANDSHAKE` + `SASL_AUTHENTICATE` sequence over the existing connection. This is invisible to application code.

**Server-side enforcement:** If the session has expired and a non-SASL request arrives, the filter rejects it with `SASL_AUTHENTICATION_FAILED` and closes the connection. `SASL_HANDSHAKE` and `SASL_AUTHENTICATE` requests are always accepted regardless of session expiry, to allow reauthentication.

### Mechanism handler extension point

The filter delegates the actual authentication exchange to mechanism-specific handlers, discovered via an internal extension point:

- `MechanismHandler` — handles the authentication exchange for a single connection. Implementations process `SaslAuthenticate` request bytes and return `AuthenticationResult` (CHALLENGE, SUCCESS, or FAILURE). Handlers are per-connection and not thread-safe.

- `MechanismHandlerFactory` — manages mechanism-specific resources and creates handler instances. Discovered via `ServiceLoader`. Each factory:
  1. Reports its IANA-registered mechanism name.
  2. Receives mechanism-specific configuration at `initialize()` time and creates whatever resources the mechanism requires (credential stores, JWKS callback handlers, etc.).
  3. Creates per-connection `MechanismHandler` instances, injecting shared resources.
  4. Releases resources on `close()`.

These are **not** user-facing plugins (no `@Plugin` annotation). They provide internal extensibility for adding new mechanism support without modifying the filter itself.
The intention behind the decision **not** to make these user-facing plugins is to encourage a small number of secure, high-quality implementations, one for each mechanism. 
Allowing pluggable implementations would make auditing for correctness and security significantly harder.

**Initial mechanism support:**

| Mechanism | Handler | Notes |
|-----------|---------|-------|
| SCRAM-SHA-256 | `ScramHandler` via `ScramSha256HandlerFactory` | RFC 5802 |
| SCRAM-SHA-512 | `ScramHandler` via `ScramSha512HandlerFactory` | RFC 5802 |
| OAUTHBEARER | `OauthBearerHandler` via `OauthBearerHandlerFactory` | RFC 6750 / RFC 7628 |

### OAUTHBEARER implementation

The OAUTHBEARER handler validates JWT bearer tokens at the proxy without forwarding them to the broker.

The handler uses Kafka's `OAuthBearerValidatorCallbackHandler` for JWT validation, the same mechanism used by the existing OAUTHBEARER validation filter. The `OauthBearerHandlerFactory` manages the JWKS endpoint configuration and callback handler lifecycle: at `initialize()`-time it configures the callback handler with the JWKS endpoint, expected audience/issuer, and refresh settings; per-connection handlers receive the shared callback handler and use it to create a `SaslServer` via the JSSE/SASL framework.

OAUTHBEARER is architecturally the simpler mechanism — it requires no credential store. The factory's only external dependency is the JWKS endpoint, and authentication is typically single-round (client sends token, server validates it). After successful authentication, the handler extracts the token's remaining lifetime from the `SaslServer`'s negotiated `CREDENTIAL.LIFETIME.MS` property for use in session lifetime computation (see [Reauthentication](#reauthentication-kip-368)).

**Key differences from the existing OAUTHBEARER validation filter:**
- The existing validation filter validates tokens then _forwards_ the SASL exchange to the broker. It is fundamentally a SASL passthrough technique. In contrast, the termination handler validates tokens and _short-circuits_ — the broker never sees a SASL exchange.
- The handler factory owns its callback handler and JWKS configuration, receiving them at `initialize()`-time rather than requiring a credential store.

### SCRAM implementation

SCRAM is more complex than OAUTHBEARER because it is a multi-round challenge-response protocol that requires stored credentials.

The SCRAM handler delegates to Apache Kafka's own `SaslServer` implementation via the JSSE/SASL framework:

1. **First round:** Extract the username from the SCRAM client-first-message, asynchronously look up the credential from the store, create a `SaslServer` with a `CallbackHandler` that supplies the credential, and process the first message.

2. **Subsequent rounds:** Process messages through the existing `SaslServer` synchronously. When `SaslServer.isComplete()` returns true, return SUCCESS with the authorization ID from `SaslServer.getAuthorizationID()`.

This approach avoids reimplementing the SCRAM protocol and benefits from Kafka's battle-tested implementation.

#### SCRAM Credential store SPI

SCRAM mechanisms need a way to look up stored credentials. The credential store SPI provides async credential lookup, decoupled from any particular storage backend.

**Core types:**

- `ScramCredentialStore` — the lookup interface, returning `CompletionStage<ScramCredential>` for a given username. Returns `null` (via completed stage) when the user is not found. Exceptional completions indicate infrastructure failures.

- `ScramCredentialStoreService<C>` — the lifecycle interface for credential store providers. Follows the initialize/build/close pattern used by `KmsService<C>`:
  1. `initialize(C config)` — validate and store configuration.
  2. `buildCredentialStore()` — create an operational store instance.
  3. `close()` — release resources.

- `ScramCredential` — an immutable sealed record holding the username, salt, iteration count, server key, stored key, and hash algorithm. Byte array fields use defensive copies in the constructor and accessors to prevent mutation. The `toString()` method redacts sensitive fields.

- Exception hierarchy: `CredentialLookupException` with subtypes `CredentialServiceUnavailableException` and `CredentialServiceTimeoutException`.

**Design note:** The SPI is intentionally SCRAM-specific. OAUTHBEARER uses token validation against a JWKS endpoint, which has a fundamentally different shape from stored credential lookup. Rather than creating a leaky abstraction that covers both, each mechanism family uses its own resource management approach (see [Rejected alternatives](#rejected-alternatives)).

#### `KeyStore`-based credential store provider

The first-party provider stores SCRAM credentials in a Java `KeyStore` file, following the project's established pattern of using `KeyStores` to store secrets. Each credential is serialized as JSON and stored as a `SecretKey` entry keyed by username.

**Characteristics:**

- Loads the entire KeyStore into memory at construction time for sub-millisecond lookups.
- Does not support hot reloading — credential changes require a proxy restart or virtual cluster reconfiguration.
- Supports PKCS12 and JKS store types.
- Uses the Kroxylicious `PasswordProvider` abstraction for KeyStore and key passwords, supporting both file-based (production) and inline (development) password configuration.

**CLI credential management tool** (`KeystoreCredentialTool`):

The credentials stored in the KeyStore are serialized JSON, which makes for less than ideal UX: The user needs ensure the JSON has the required format.
Moreover, the values of that JSON are not all obvious things like the username. Some of the fields are computed from cryptographic operation on the password which need to 
be done correctly for the authentication to work, and where incorrect construction can undermine security.

To provide a better UX and to reduce the possibility of user error compromising security a PicoCLI-based command-line tool will be provided for managing credentials in KeyStore files. Supports: `create`, `add-user`, `remove-user`, `update-password`, `list-users`.

Security measures:
- Passwords are read via interactive console prompts by default because passing secrets via CLI arguments is insecure. Command-line password arguments are supported, but gated behind an `--unlock-insecure-options` flag that displays security warnings.
- A 12-character minimum password length is enforced, following [NIST SP 800-63B][nist-sp800-63b] guidance.
- SCRAM credentials are generated with 10,000 iterations (above the RFC-5802 minimum of 4,096) and 20 bytes of random salt.

### Configuration model

```yaml
filters:
  - type: SaslTermination
    config:
      connectionsMaxReauth: 1h
      mechanisms:
        SCRAM-SHA-256:
          credentialStore: KeystoreScramCredentialStoreService
          credentialStoreConfig:
            file: /path/to/credentials.p12
            storePassword:
              file: /etc/kroxylicious/keystore-password.txt
            storeType: PKCS12
        OAUTHBEARER:
          jwksEndpointUrl: https://idp.example.com/.well-known/jwks.json
          expectedAudience: kafka
          expectedIssuer: https://idp.example.com
```

The `mechanisms` map is keyed by IANA-registered mechanism name. The config shape for each entry depends on the mechanism: SCRAM mechanisms use `credentialStore`/`credentialStoreConfig`, while OAUTHBEARER uses JWKS endpoint configuration directly.

The optional `connectionsMaxReauth` sets the maximum session lifetime before reauthentication is required (KIP-368). Uses golang-style duration syntax (e.g. `1h`, `30m`, `1h30m`). Omit or set to `0` to disable.

### Module architecture

The implementation is organized into three modules, following the same pattern as the existing KMS modules (`kroxylicious-kms`, `kroxylicious-kms-provider-*`):

| Module | Purpose |
|--------|---------|
| `kroxylicious-filters/kroxylicious-sasl-termination` | The termination filter, state machine, mechanism handler extensibility, and all built-in mechanism implementations |
| `kroxylicious-sasl-credential-store` | Public API: defines the credential store SPI used by SCRAM mechanism handlers |
| `kroxylicious-sasl-credential-store-providers/kroxylicious-sasl-credential-store-provider-keystore` | First-party SCRAM credential provider: Java KeyStore-backed implementation with CLI management tool |

## Security model

### Credential storage

- **KeyStore encryption:** Credentials are stored in Java KeyStore files, encrypted with the KeyStore password. File-system permissions and KeyStore passwords are the primary access controls.
- **PasswordProvider abstraction:** Production deployments should use file-based passwords rather than inline passwords in configuration. The `PasswordProvider` interface supports both.
- **In-memory handling:** `ScramCredential` uses defensive copies for all `byte[]` fields (salt, serverKey, storedKey) in both the constructor and accessors, preventing callers from mutating stored credential data. `toString()` redacts sensitive fields.

### SCRAM protocol correctness

The implementation delegates to Kafka's own `SaslServer` for SCRAM, which is widely deployed and well-tested. The handler is responsible only for credential lookup and passing credentials to the `SaslServer` via a `CallbackHandler`.

### Username enumeration prevention

When a user is not found in the credential store, the handler returns a generic `"Authentication failed"` error message, identical to the message returned for incorrect credentials. The error does not reveal whether the username exists.

### Timing side-channel mitigation

Without mitigation, an attacker could distinguish existing from non-existing users by measuring response times: credential lookup, deserialization, and SCRAM server creation take different amounts of time depending on whether the user exists. Rather than trying to equalize these inherently different code paths (which is fragile under JIT optimizations and varies by credential store implementation), the SCRAM handler applies a fixed delay to all authentication rounds. The delay is long enough to swamp any timing differences but short enough to be negligible for Kafka's typically long-lived connections.

### Connection lifecycle safety

- The sealed state machine prevents invalid state transitions at compile time.
- The security barrier is enforced for all non-SASL request types. Unauthenticated requests are rejected and the connection is closed.
- On authentication failure, the connection is closed immediately.

### CLI tool security

- Interactive password prompts prevent exposure of passwords in shell history and process listings.
- The `--unlock-insecure-options` flag gates command-line password arguments with explicit security warnings.
- 12-character minimum password length follows NIST SP 800-63B recommendations.

### Threats considered but out of scope

- **Compromised KeyStore files:** Protecting the KeyStore file at rest is an operational concern (file permissions, encryption at rest) rather than an application concern.
- **SCRAM channel binding:** [RFC 5802 Section 6][rfc5802-s6] describes channel binding for SCRAM. Kafka does not use SCRAM channel binding, so this implementation follows Kafka's approach.

## Affected/not affected projects

**New modules:**
- `kroxylicious-sasl-credential-store` — public API module
- `kroxylicious-sasl-credential-store-providers/kroxylicious-sasl-credential-store-provider-keystore` — KeyStore provider
- `kroxylicious-filters/kroxylicious-sasl-termination` — termination filter

**Modified modules:**
- `kroxylicious-bom` — new dependency declarations
- Root `pom.xml` — new module entries
- `kroxylicious-integration-tests` — SASL termination integration tests
- `kroxylicious-docs` — authentication guide (expanded from SASL inspection guide)

**Not affected:**
- `kroxylicious-api` — no API changes needed (uses existing `clientSaslAuthenticationSuccess`/`clientSaslAuthenticationFailure` from proposal 006)
- `kroxylicious-runtime` — no runtime changes
- `kroxylicious-kms` and KMS providers — unrelated
- `kroxylicious-kubernetes` — no operator changes (the termination filter is configured via standard filter configuration)

## Compatibility

This is a new feature with no breaking changes:
- Existing proxy configurations continue to work unchanged.
- The SASL inspection filter is unaffected and can still be used for passthrough inspection.
- The OAUTHBEARER validation filter is unaffected.
- The credential store API (`kroxylicious-sasl-credential-store`) is a new public API. Once released, it will follow the project's API stability rules.

## Rejected alternatives

### Generic CredentialStore covering all mechanisms

A single `CredentialStore` interface serving both SCRAM and OAUTHBEARER was considered. This was rejected because:
- SCRAM uses stored credential lookup (username → salt, iterations, server key, stored key).
- OAUTHBEARER uses token validation against a JWKS endpoint (no stored credentials at all).
- A generic interface would either be too abstract to be useful or would leak mechanism-specific concepts into the abstraction.

Instead, each mechanism family manages its own resources. The `MechanismHandlerFactory` is the point where mechanism-specific resources (credential stores, JWKS handlers) are injected.

### Using @Plugin for mechanism handlers

Making `MechanismHandlerFactory` a user-facing plugin (with `@Plugin` annotation and plugin discovery) was considered. This was rejected because:
- Mechanism handlers are internal implementation details, not user-facing extension points.
- Users configure _mechanisms_, not _handlers_. The mapping from mechanism name to handler is an implementation concern.
- `ServiceLoader` discovery is sufficient for internal extensibility.

### Extending the OAUTHBEARER validation filter

Adding SASL termination support to the existing OAUTHBEARER validation filter was considered. This was rejected because:
- The validation filter performs a fundamentally different operation: it validates tokens then _forwards_ the SASL exchange to the broker. Termination _short-circuits_ — the broker never sees SASL traffic.
- The filter lifecycle, state management, and security barrier requirements are different.
- Combining both would create a complex filter with two distinct operational modes.

### PLAIN mechanism support

Supporting SASL PLAIN was deferred because:
- PLAIN transmits passwords in cleartext (Base64 encoded, not encrypted), making it unsuitable for production use without TLS.
- SCRAM provides mutual authentication and never transmits the password (though should also be used with TLS to avoid MitM attacks).
- If PLAIN support is needed in the future, it could be added as a new `MechanismHandler` implementation.

## References

- [Proposal 004 — Terminology for Authentication][proposal-004]
- [Proposal 006 — API to expose client SASL information to Filters][proposal-006]
- [RFC 4422 — Simple Authentication and Security Layer (SASL)][rfc4422]
- [RFC 5802 — Salted Challenge Response Authentication Mechanism (SCRAM)][rfc5802]
- [RFC 6750 — The OAuth 2.0 Authorization Framework: Bearer Token Usage][rfc6750]
- [RFC 7628 — A Set of Simple Authentication and Security Layer (SASL) Mechanisms for OAuth][rfc7628]
- [KIP-84 — Support SASL SCRAM mechanisms][kip84]
- [KIP-255 — OAuth Authentication via SASL/OAUTHBEARER][kip255]
- [KIP-368 — Allow SASL Connections to Periodically Re-Authenticate][kip368]
- [NIST SP 800-63B — Digital Identity Guidelines: Authentication and Lifecycle Management][nist-sp800-63b]

[proposal-004]: 004-terminology-for-authentication.md
[proposal-006]: 006-filter-api-to-expose-client-sasl-info.md
[proposal-072]: 070-routing-api.md
[rfc4422]: https://www.rfc-editor.org/rfc/rfc4422
[rfc5802]: https://www.rfc-editor.org/rfc/rfc5802
[rfc5802-s6]: https://www.rfc-editor.org/rfc/rfc5802#section-6
[rfc6750]: https://www.rfc-editor.org/rfc/rfc6750
[rfc7628]: https://www.rfc-editor.org/rfc/rfc7628
[kip84]: https://cwiki.apache.org/confluence/display/KAFKA/KIP-84%3A+Support+SASL+SCRAM+mechanisms
[kip255]: https://cwiki.apache.org/confluence/pages/viewpage.action?pageId=75968876
[kip368]: https://cwiki.apache.org/confluence/spaces/KAFKA/pages/89068981/KIP-368+Allow+SASL+Connections+to+Periodically+Re-Authenticate
[nist-sp800-63b]: https://pages.nist.gov/800-63-4/sp800-63b.html
[sasl-inspection]: https://kroxylicious.io/kroxylicious/#assembly-sasl-inspection
[oauthbearer-validation]: https://kroxylicious.io/kroxylicious/#assembly-configuring-oauth-bearer-validation-filter
