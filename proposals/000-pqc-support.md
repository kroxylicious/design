# 133 - PQC Support

PQC support allows the proxy to protect data in transit with encryption resistant to attacks by quantum computers.

## Current Situation

Quantum computing can efficiently solve problems that classical cryptography depends on, breaking current security protocols. Two algorithms, Shor's and Grover's, attack different areas of encryption.

NIST finalized post-quantum cryptography standards in 2024, enabling secure key establishment and digital signatures.

### Data encryption in transit

Shor's algorithm enables quantum computers to efficiently solve problems securing RSA, Diffie-Hellman, and elliptic curve cryptography. Classical public-key mechanisms in TLS and PKI, such as RSA and ECDH, are vulnerable to quantum attacks enabled by Shor's algorithm.

### Data encryption at rest

Grover's algorithm poses a different and often misunderstood quantum threat. Unlike Shor's algorithm, which breaks specific mathematical problems outright, Grover's algorithm provides a quadratic speedup for brute-force search. This applies to any problem that can be framed as searching an unsorted space, including guessing symmetric encryption keys. For cryptography, this means a quantum adversary can search a key space of size N in roughly √N steps instead of N steps.

The key distinction is that Grover's algorithm weakens symmetric encryption but does not fundamentally break it. For example, AES-128 has a classical security level of 128 bits, meaning a brute-force attack requires approximately 2^128 operations. Under Grover's algorithm, the effective complexity drops to roughly 2^64, which is no longer considered sufficient for long-term security. AES-256, however, is reduced from 2^256 to approximately 2^128 operations, which remains extremely strong.

### NIST PQC standards for data in transit

CRYSTALS stands for Cryptographic Suite for Algebraic Lattices. It's the name of the cryptographic suite developed by a consortium of researchers that produced two distinct algorithms:

- **CRYSTALS-Kyber** — a key encapsulation mechanism (KEM) used for secure key exchange / encryption. It was standardized by NIST as ML-KEM (FIPS 203).
- **CRYSTALS-Dilithium** — a digital signature scheme. Standardized by NIST as ML-DSA (FIPS 204).

CRYSTALS-Kyber, standardized by NIST as ML-KEM in [FIPS 203](https://csrc.nist.gov/pubs/fips/203/final), is the primary post-quantum replacement for RSA and elliptic-curve-based key exchange. Kyber is a Key Encapsulation Mechanism (KEM), which means it is specifically designed to allow two parties to establish a shared secret over an untrusted network. That shared secret is then used with symmetric encryption such as AES to protect application data. This maps cleanly onto how TLS already works today.

CRYSTALS-Dilithium, standardized as ML-DSA in [FIPS 204](https://csrc.nist.gov/pubs/fips/204/final), addresses the second major vulnerability exposed by quantum computing: digital signatures. While Kyber secures key exchange, Dilithium replaces RSA and ECDSA for authentication, certificates, and code signing. Like Kyber, Dilithium is lattice-based and relies on hard problems believed to be resistant to both classical and quantum attacks.

Digital signatures play a critical role in Java ecosystems. TLS certificates, JAR signing, software update mechanisms, and authentication tokens all depend on signatures to establish trust. Shor's algorithm breaks RSA and ECDSA signatures completely, allowing attackers to forge identities or distribute malicious code that appears legitimate. Dilithium is designed to close this gap with a quantum-resistant alternative.

Dilithium offers a careful balance between security and performance. Compared to some other post-quantum signature schemes, it has relatively moderate signature sizes and verification costs, making it suitable for high-frequency operations such as TLS handshakes and API authentication. This practicality is one of the reasons NIST selected it as the primary post-quantum signature standard.

### Java support for PQC algorithms

PQC support in Java is composed of multiple layers:

- **Algorithm support** - can be provided by JVMs or 3rd party libraries such as BouncyCastle or OpenSSL based ones with the OQS provider.
- **JSSE framework control** - ability to use the JSSE framework to control the TLS handshake algorithms:
  - Named groups control the key exchange algorithm
  - Signature schemes control the certificate signature validation
  - JSSE defines constants that vendor JSSE implementations understand
- **Certificate handling** - ability for frameworks to read Dilithium generated certificates (this is not part of the JVM implementation as they conform to X509 structure and need no special handling in the TLS handshake)
- **TLS 1.3 requirement** - PQC key exchange requires TLS 1.3

This multi-layered ecosystem has fragmented vendor support. JVM vendors have different roadmaps for PQC adoption. Algorithm backports for ML-KEM and ML-DSA to Java 21/17 are scheduled for 4Q26, hybrid TLS key exchange is targeted for 1H27. Java 28 is the next LTS where all vendors will support PQC.

The project already depends on BouncyCastle (test scope). BouncyCastle 1.85 provides production-ready ML-KEM and ML-DSA implementations for Java 21. This proposal changes BouncyCastle scope from test to runtime rather than waiting for JVM vendor convergence, enabling PQC support now rather than waiting for JDK adoption.

### Current Kroxylicious TLS support

Kroxylicious currently supports classical TLS only. Configuration permits selecting TLS versions and cipher suites but provides no control over key exchange algorithms (named groups in TLS 1.3). The proxy cannot negotiate ML-KEM key exchange or validate ML-DSA certificates.

## Motivation

### Harvest now, decrypt later

Harvest now, decrypt later attacks risk future exposure of sensitive data with long confidentiality lifetimes such as account numbers and other forms of PII and SPI. Adversaries capture encrypted traffic today for decryption when a suitably powerful quantum computer becomes available. Session keys derived via ECDH or RSA will be retroactively broken, and the data will be exposed.

### Regulatory compliance

PQC is mandated across multiple jurisdictions and sectors with near-term enforcement deadlines (which are subject to change, although almost all changes are to mandate earlier timescales). Governments have typically already embarked on creating migration plans with target implementation dates between 2030-2035. Banks need to adopt PQC under existing regulatory frameworks such as the Digital Operational Resilience Act (DORA): Requires banks to enhance encryption practices and manage cryptographic risks effectively.

Organizations subject to these requirements cannot deploy systems relying solely on classical cryptography. Non-compliance blocks deployment in government, banking, healthcare, and defense sectors. Organizations face compliance penalties, certification failures, and market access restrictions.

### Support phased migration of deployed infrastructure

The proxy decouples client-side and broker-side PQC adoption. The proxy can provide PQC to clients or PQC to Kafka clusters. This allows independent migration paths to be followed and can speed up adoption by not requiring large infrastructure investments in Kafka to support PQC (it will in time). The proxy can be used to provide PQC over untrusted networks while backend infrastructure migrates on a different timeline.

### Support phased adoption of PQC

Changing to use Dilithium certificates has a large blast radius. It's not just an algorithm name - certificates have to be created, injected into build/test systems, and capable of being read by various Java frameworks. Certificates are used to provide point-in-time authentication and do not suffer from the harvest now, decrypt later issue. They can be adopted at a later date. Changing the TLS key exchange algorithms is the priority.

### PQC endpoint enforcement

Provide the ability to only allow PQC endpoints, which gives a stronger guarantee that a back-level client did not connect over a hybrid endpoint and negotiate an insecure key exchange. Strict mode prevents downgrade attacks.

### PQC topic enforcement

Not all topics contain data that need to be PQC protected and not all clients are PQC capable. The proxy is able to redirect clients to PQC endpoints based on the topic being accessed. This can also be combined with existing functionality such as replacing sensitive values and allowing that access to be over non-PQC endpoints.

## Proposal

This proposal aims to support the proxy offering PQC support in the following scenarios:

- Clients connecting to the proxy
- Proxy connecting to upstream clusters
- Filters that make connections
- Filter enforcement of PQC for topics

### Dependency on Proposal #94

[Proposal #94](https://github.com/kroxylicious/design/pull/94) proposes deprecating the common [`io.kroxylicious.proxy.config.tls`](https://github.com/kroxylicious/kroxylicious/tree/main/kroxylicious-api/src/main/java/io/kroxylicious/proxy/config/tls) classes (including [`Tls`](https://github.com/kroxylicious/kroxylicious/blob/main/kroxylicious-api/src/main/java/io/kroxylicious/proxy/config/tls/Tls.java)). That proposal has enough votes to pass but has not yet been merged.

This proposal does not have to wait for Proposal #94. If this work is done first, it is a minor addition to the existing work to implement #94.

If #94 proceeds before implementation of this proposal, the `namedGroups` and `pqc` fields described below are added to whatever configuration type replaces Tls. If this proposal proceeds first, fields are added to the existing Tls record and migrated when #94 is implemented.

### TLS configuration changes

TLS configurations gain a new field `namedGroups` (allowed or disallowed) which controls the algorithms used during TLS key exchange.

TLS connections can be controlled with the following configuration options:

- TLS version (allowed/denied)
- Cipher suites (allowed/denied)
- **Named groups (allowed/denied)** - new field, required for TLS 1.3 key exchange

#### The `pqc` convenience field

Enabling PQC requires aligned values across protocols, cipher suites, and named groups. Misconfiguration can break PQC guarantees or prevent endpoints from loading. Currently you can set these to misaligned values and the endpoint will still become available, silently failing to provide PQC protection.

A new field `pqc` can be set to `hybrid` or `strict`. Setting it applies coordinated values and prevents manual configuration of protocols, cipher suites, or named groups. This prevents breaking PQC guarantees and helps prevent misconfiguration.

**Benefits:**
- **Prevents misconfiguration**: Ensures protocols, cipher suites, and named groups are correctly aligned
- **Human-readable intent**: Seeing `pqc: hybrid` immediately signals the endpoint's security posture
- **Simplified configuration**: One field instead of coordinating three separate fields

**Mechanics:**
- The `pqc` field is mutually exclusive with manual `protocols`, `cipherSuites`, or `namedGroups` configuration
- Conflicts are detected and prevent the endpoint from loading
- Users can still use individual fields when they need fine-grained control

**PQC: hybrid**

TLS 1.3 only
Named groups: `X25519MLKEM768`, `X25519`, `secp256r1`
Cipher suites: `TLS_AES_256_GCM_SHA384`, `TLS_CHACHA20_POLY1305_SHA256`

Fallback to classical if peer lacks ML-KEM support. The hybrid named group `X25519MLKEM768` combines classical X25519 ECDH with ML-KEM-768. Both must be broken for compromise, providing defense against both quantum and classical attacks.

**PQC: strict**

TLS 1.3 only
Named groups: `X25519MLKEM768` only (single entry prevents classical fallback)
Cipher suites: `TLS_AES_256_GCM_SHA384`, `TLS_CHACHA20_POLY1305_SHA256`

Hard failure if peer doesn't support the named group - intentional by design.

Strict mode uses `X25519MLKEM768` (hybrid) rather than pure `ML-KEM-768`. While `X25519MLKEM768` includes a classical component, it can only be successfully negotiated if the client is PQC capable. It provides better protection against broken initial PQC algorithm implementations as both X25519 and ML-KEM must be broken. "Strict" refers to no classical fallback (the named group list has only one entry), not absence of classical components. The hybrid is strictly stronger than either pure classical or pure PQC alone.

#### Configuration examples

Example PQC hybrid using individual settings (requires alignment across all fields):

```yaml
tls:
  key:
    storeFile: /etc/kroxylicious/tls/server.p12
    storeType: PKCS12
    storePassword:
      passwordFile: /etc/kroxylicious/secrets/server-store-password
  trust:
    # trust configuration
  protocols:
    allowed: [TLSv1.3]
  cipherSuites:
    allowed: [TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256]
  namedGroups:
    allowed: [X25519MLKEM768, X25519, secp256r1]
```

Example PQC hybrid using convenience field:

```yaml
tls:
  key:
    storeFile: /etc/kroxylicious/tls/server.p12
    storeType: PKCS12
    storePassword:
      passwordFile: /etc/kroxylicious/secrets/server-store-password
  trust:
    # trust configuration
  pqc: hybrid
  # When pqc is present, it is invalid to set protocols, cipherSuites, or namedGroups
```

The `pqc` field prevents the misconfiguration shown in the individual settings example (e.g., forgetting to set TLS 1.3, or allowing weak cipher suites).

### ML-DSA certificate support

Existing configuration will work as is for ML-DSA (Dilithium) certificates as these certificates conform to the X.509 structure and require no special TLS handshake handling. However, certificate parsing will require updating to support Dilithium key types.


### ClientTlsContext API extensions

Filters gain visibility into negotiated TLS parameters via [`ClientTlsContext`](https://github.com/kroxylicious/kroxylicious/blob/main/kroxylicious-api/src/main/java/io/kroxylicious/proxy/tls/ClientTlsContext.java) additions.

The API will expose both `negotiatedNamedGroup()` and `isPqcConnection()` convenience method. This follows the same philosophy as the configuration: provide both convenience (the PQC boolean) and granular control (the actual named group for non-PQC logic). Sometimes filters need only the PQC status, other times they need the specific named group for logic unrelated to PQC.

This permits filters to enforce PQC requirements or route based on connection security.

### Client downstream connections

mTLS authentication will require the proxy to understand a client-supplied ML-DSA certificate. Securing the downstream client connection is configured with the `tls` section.

```yaml
# This secures the client-to-proxy connection.
virtualClusters:
  demo:
    targetCluster:
      bootstrap_servers: kafka.example.com:9092
    tls:
      pqc: hybrid  # or: strict
      # Setting pqc is incompatible with protocols, namedGroups, and cipherSuites
      key:
        # Keystore form. storeType accepts a JDK keystore type or PEM.
        storeFile: /etc/kroxylicious/tls/server.p12
        storeType: PKCS12
        # Use a file provider in production. Do not commit secret files.
        storePassword:
          passwordFile: /etc/kroxylicious/secrets/server-store-password
        # Optional; defaults to the store password when omitted.
        keyPassword:
          passwordFile: /etc/kroxylicious/secrets/server-key-password
      # Optional. Trust client certificates and control mTLS.
      trust:
        storeFile: /etc/kroxylicious/tls/client-ca.p12
        storeType: PKCS12
        storePassword:
          passwordFile: /etc/kroxylicious/secrets/client-ca-password
        trustOptions:
          clientAuth: REQUIRED  # REQUIRED, REQUESTED, or NONE
```

When using individual field configuration (not `pqc`):

```yaml
tls:
  # Optional. Allow-list order sets TLS preference; denied entries are excluded.
  protocols:
    allowed: [TLSv1.3, TLSv1.2]
  cipherSuites:
    # Use suites supported by the selected JDK/provider.
    allowed: [TLS_AES_256_GCM_SHA384, TLS_AES_128_GCM_SHA256]
  namedGroups:
    allowed: [X25519MLKEM768, X25519, secp256r1]
```

### Kafka upstream connections

```yaml
clusterDefinitions:
  - name: upstream-orders
    # Required. One or more comma-separated upstream host:port pairs.
    bootstrapServers: broker-0.kafka.example.net:9093,broker-1.kafka.example.net:9093
    # Optional. The same TLS structure used by virtual clusters, but for proxy-to-Kafka connections.
    tls:
      pqc: hybrid
      # Omit key unless upstream Kafka requires mTLS.
      key:
        privateKeyFile: /etc/kroxylicious/tls/proxy-client.key
        certificateFile: /etc/kroxylicious/tls/proxy-client.crt
      trust:
        storeFile: /etc/kroxylicious/tls/upstream-ca.pem
        storeType: PEM
```

### Record encryption filter

Already uses AES-256-GCM and does not need changing. However, the KMS exchange needs to be over PQC connections, so KMS provider implementations will need to be updated.

If `pqc: strict` is required for the record filter then it will mandate the use of 256-bit AES-GCM symmetric keys. See current warning: `If you are using Azure Key Vault and Managed HSM is not available, you can use RSA-OAEP-256 encryption, using a 2048-bit (or greater) asymmetric key instead of 256-bit AES-GCM symmetric keys. This approach is not quantum-resistant.`

### Operator Ingress

CRD changes analogous to config YAML changes to support the new `namedGroups` field as well as the `pqc` convenience field.

**VirtualKafkaCluster (manual configuration):**

```yaml
kind: VirtualKafkaCluster
metadata:
  name: my-cluster
spec:
  ingresses:
    - ingressRef:
        name: cluster-ip
      tls:
        certificateRef:
          name: server-cert
        namedGroups:
          allowed:
            - X25519MLKEM768
            - X25519
            - secp256r1
```

**VirtualKafkaCluster (convenience field):**

```yaml
kind: VirtualKafkaCluster
metadata:
  name: my-cluster
spec:
  ingresses:
    - ingressRef:
        name: cluster-ip
      tls:
        certificateRef:
          name: server-cert
        pqc: hybrid
```

### Operator Egress

**KafkaService:**

```yaml
kind: KafkaService
metadata:
  name: upstream
spec:
  bootstrapServers: kafka.example.com:9092
  tls:
    namedGroups:
      allowed:
        - X25519MLKEM768
        - X25519
        - secp256r1
```

**KafkaService (convenience field):**

```yaml
kind: KafkaService
metadata:
  name: upstream
spec:
  bootstrapServers: kafka.example.com:9092
  tls:
    pqc: strict
```

### Admission webhook

The admission webhook TLS server configuration gains PQC support analogous to VirtualKafkaCluster ingress configuration.

```yaml
# Admission webhook server TLS configuration
webhookServer:
  tls:
    certificateRef:
      name: webhook-server-cert
    pqc: hybrid
```

Alternatively with manual configuration:

```yaml
webhookServer:
  tls:
    certificateRef:
      name: webhook-server-cert
    protocols:
      allowed: [TLSv1.3]
    cipherSuites:
      allowed: [TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256]
    namedGroups:
      allowed: [X25519MLKEM768, X25519, secp256r1]
```

### Build and test

Testing infrastructure will need:
- Ability to generate ML-DSA certificates for integration testing
- Test clients that support PQC and ML-DSA certificates
- Certificate injection into test infrastructure

### Metrics and observability

Existing connection metrics follow a directional naming pattern. PQC support augments these existing metrics with a `pqc` label rather than creating separate metrics.

**Modified existing metrics (label added):**

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `kroxylicious_client_to_proxy_connections_total` | Counter | `virtual_cluster`, `node_id`, **`pqc`** | Count of client-to-proxy connections. **New label** `pqc` with values: `strict`, `hybrid`, `none` |
| `kroxylicious_proxy_to_server_connections_total` | Counter | `cluster`, `node_id`, **`pqc`** | Count of proxy-to-broker connections. **New label** `pqc` with values: `strict`, `hybrid`, `none` |

**New metrics for migration planning:**

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `kroxylicious_client_to_proxy_connections_failed_total` | Counter | `virtual_cluster`, `pqc` | Failed client-to-proxy connection attempts by PQC mode |
| `kroxylicious_proxy_to_server_connections_failed_total` | Counter | `cluster`, `pqc` | Failed proxy-to-broker connection attempts by PQC mode |

The directional metrics support migration planning. Proxy owners can observe PQC adoption separately for client-facing and broker-facing connections, contacting application developers or Kafka cluster owners independently as migration progresses. Failed connection metrics identify PQC compatibility issues.

## PQC topic filters

The idea is to have a filter that can redirect client connections to PQC or hybrid/non-PQC proxy endpoints based on the topic that they are accessing. This allows a more granular migration strategy and caters for integrating with external business partners where you have no control over their PQC support.

**Example consume use case:**

1. Create a filter that redacts sensitive fields from the message payload.
2. PQC filter intercepts metadata request. If client is not connected over PQC, rewrite proxy endpoint to the non-PQC endpoint. PQC clients can receive the full data.

**Example produce use case:**

Production to topics that contain sensitive data can be forced over a PQC compliant endpoint. Data that is not sensitive (e.g., temperature readings) can remain over non-PQC endpoints.

## Affected/not affected projects

**Affected:**

- [`kroxylicious-api`](https://github.com/kroxylicious/kroxylicious/tree/main/kroxylicious-api): [`Tls`](https://github.com/kroxylicious/kroxylicious/blob/main/kroxylicious-api/src/main/java/io/kroxylicious/proxy/config/tls/Tls.java) record and [`ClientTlsContext`](https://github.com/kroxylicious/kroxylicious/blob/main/kroxylicious-api/src/main/java/io/kroxylicious/proxy/tls/ClientTlsContext.java) interface changes
- [`kroxylicious-runtime`](https://github.com/kroxylicious/kroxylicious/tree/main/kroxylicious-runtime): Netty TLS pipeline configuration, connection metrics
- [`kroxylicious-kms-tls-support`](https://github.com/kroxylicious/kroxylicious/tree/main/kroxylicious-kms-tls-support): TLS configuration for KMS HTTP clients
- [`kroxylicious-kubernetes-api`](https://github.com/kroxylicious/kroxylicious/tree/main/kroxylicious-kubernetes/kroxylicious-kubernetes-api): CRD schema changes
- [`kroxylicious-operator`](https://github.com/kroxylicious/kroxylicious/tree/main/kroxylicious-kubernetes/kroxylicious-operator): CRD reconciliation
- [`kroxylicious-admission`](https://github.com/kroxylicious/kroxylicious/tree/main/kroxylicious-kubernetes/kroxylicious-admission): Webhook TLS server configuration
- [`kroxylicious-record-encryption`](https://github.com/kroxylicious/kroxylicious/tree/main/kroxylicious-filters/kroxylicious-record-encryption): KMS HTTP clients gain PQC
- [`kroxylicious-record-validation`](https://github.com/kroxylicious/kroxylicious/tree/main/kroxylicious-filters/kroxylicious-record-validation): Schema registry HTTP clients gain PQC

**Not affected:**

- Other filters: Transparent change for filters not initiating TLS connections
- [`kroxylicious-authorizer-providers`](https://github.com/kroxylicious/kroxylicious/tree/main/kroxylicious-authorizer-providers): No TLS changes
- [`kroxylicious-kms`](https://github.com/kroxylicious/kroxylicious/tree/main/kroxylicious-kms) API: Unchanged; implementations gain PQC via TlsHttpClientConfigurator

## Compatibility

### Backwards compatibility

Existing TLS configurations work unchanged as `namedGroups` and `pqc` fields are optional.

### Forwards compatibility

Additional named groups can be added as standards evolve. The `pqc` enum can be extended with additional modes.

## Rejected alternatives

### Wait for JDK native PQC support

An alternative option was to defer PQC support until the JDK provides native ML-KEM and ML-DSA across all JVM vendors.

Rejected due to the potential for delay and a fragmented implementation landscape. BouncyCastle provides production-ready PQC today. The project already depends on BouncyCastle (test scope), so changing to runtime scope has minimal dependency footprint.

Additionally, even when JDK PQC arrives it can potentially be the first release from a vendor. First releases carry adoption risk. BouncyCastle PQC has been in production use for significantly longer, providing a more mature implementation.

## References

- [NIST FIPS 203 - ML-KEM](https://csrc.nist.gov/pubs/fips/203/final)
- [NIST FIPS 204 - ML-DSA](https://csrc.nist.gov/pubs/fips/204/final)
- [Proposal #94 - TLS Configuration Refactoring](https://github.com/kroxylicious/design/pull/94)

### Related GitHub Issues

- [#4476](https://github.com/kroxylicious/kroxylicious/issues/4476) - PemUtils.tryParsePKCS8 fails to parse post-quantum key types
- [#4477](https://github.com/kroxylicious/kroxylicious/issues/4477) - Add namedGroups configuration to Tls record for per-connection KEM control
- [#4478](https://github.com/kroxylicious/kroxylicious/issues/4478) - Implement named groups support in TlsHttpClientConfigurator for KMS providers
- [#4479](https://github.com/kroxylicious/kroxylicious/issues/4479) - Implement named groups support in Netty runtime for client-proxy and proxy-broker TLS
- [#4480](https://github.com/kroxylicious/kroxylicious/issues/4480) - Extend TlsUtil.validateKeyAndCertMatch to support post-quantum key types
- [#4481](https://github.com/kroxylicious/kroxylicious/issues/4481) - Netty's PEM parser cannot handle post-quantum key types
- [#4482](https://github.com/kroxylicious/kroxylicious/issues/4482) - Record Validation filter has no per-connection named groups control for schema registry TLS
- [#4483](https://github.com/kroxylicious/kroxylicious/issues/4483) - Document PQC TLS configuration for end users
- [#4484](https://github.com/kroxylicious/kroxylicious/issues/4484) - Add named groups support to Kubernetes CRDs and operator proxy config generation
- [#4485](https://github.com/kroxylicious/kroxylicious/issues/4485) - Admission webhook HTTPS server has no TLS named groups configuration
- [#4486](https://github.com/kroxylicious/kroxylicious/issues/4486) - System tests for PQC TLS named groups configuration
- [#4487](https://github.com/kroxylicious/kroxylicious/issues/4487) - AWS credential provider HTTP clients have no user-configurable TLS
