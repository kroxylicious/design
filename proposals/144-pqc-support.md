# 144 - PQC Support

PQC support allows the proxy to protect data in transit with encryption resistant to attacks by quantum computers.

This proposal addresses data in transit. Data at rest is largely out of scope: the symmetric encryption the proxy uses (AES-256) is weakened but not broken by Grover's algorithm. The exception is data at rest that is protected by classical asymmetric cryptography, such as a data encryption key wrapped by a classical KEK, which Shor's algorithm can break. Addressing that is out of scope here and is tracked separately (see the Record encryption filter section and issue #783), potentially as its own proposal.

## Current Situation

Quantum computing can efficiently solve problems that classical cryptography depends on, breaking current security protocols. Two algorithms, Shor's and Grover's, attack different areas of encryption.

NIST finalized post-quantum cryptography standards in 2024, enabling secure key establishment and digital signatures.

### Data encryption in transit

Shor's algorithm enables quantum computers to efficiently solve problems securing RSA, Diffie-Hellman, and elliptic curve cryptography. Classical public-key mechanisms in TLS and PKI, such as RSA and ECDH, are vulnerable to quantum attacks enabled by Shor's algorithm.

### Data encryption at rest (background)

This section is background that explains why symmetric data at rest is largely out of scope for this proposal; it is not part of the proposed work.

Grover's algorithm poses a different and often misunderstood quantum threat. Unlike Shor's algorithm, which breaks specific mathematical problems outright, Grover's algorithm provides a quadratic speedup for brute-force search. This applies to any problem that can be framed as searching an unsorted space, including guessing symmetric encryption keys. For cryptography, this means a quantum adversary can search a key space of size N in roughly √N steps instead of N steps.

The key distinction is that Grover's algorithm weakens symmetric encryption but does not fundamentally break it. For example, AES-128 has a classical security level of 128 bits, meaning a brute-force attack requires approximately 2^128 operations. Under Grover's algorithm, the effective complexity drops to roughly 2^64, which is no longer considered sufficient for long-term security. AES-256, however, is reduced from 2^256 to approximately 2^128 operations, which remains extremely strong. As the proxy uses AES-256 for symmetric data at rest, that data stays secure against quantum attack. The exception is data at rest protected by classical asymmetric cryptography, such as a data encryption key wrapped by a classical KEK, which Shor's algorithm can break. That case is out of scope here and is discussed in the Record encryption filter section.

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

- **Algorithm support** - the ML-KEM and ML-DSA implementations. This proposal relies on the JDK to provide them. Third party libraries such as BouncyCastle or OpenSSL-based providers using OQS can also supply them, but the JDK is used here (see Rejected alternatives).
- **JSSE framework control** - ability to use the JSSE framework to control the TLS handshake algorithms:
  - Named groups control the key exchange algorithm
  - Signature schemes control the certificate signature validation
  - JSSE defines constants that vendor JSSE implementations understand
- **Certificate handling** - ability for frameworks to read Dilithium generated certificates (this is not part of the JVM implementation as they conform to X509 structure and need no special handling in the TLS handshake)
- **TLS 1.3 requirement** - PQC key exchange requires TLS 1.3

This multi-layered ecosystem has fragmented vendor support, and JDK vendors have different roadmaps for PQC adoption. As the proposal uses the JDK provider, the availability of PQC in the running JDK determines when hybrid key exchange can be offered. That dependency is described under PQC provider below.

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

Provide the ability to configure an endpoint that accepts only PQC key exchange, which gives a stronger guarantee that a back-level client did not connect over an endpoint offering classical fallback and negotiate an insecure key exchange. This is achieved by listing only a hybrid ML-KEM named group (with no classical group as a fallback), which prevents downgrade attacks.

## Proposal

This proposal aims to support the proxy offering PQC support in the following scenarios:

- Clients connecting to the proxy
- Proxy connecting to upstream clusters
- Filters that make connections

More generally, the requirement for PQC support applies to all TLS connections the proxy makes, whether by the runtime or by filters, now or in the future. This includes connections that are easy to overlook, such as the SASL termination connection to an OAuth server used to validate bearer tokens, and the Record Validation filter's connection to a schema registry such as Apicurio. Whilst a harvest now, decrypt later attack is less of a concern for these, an audit may flag them as not PQC compliant, so they are in scope. This will also need to be reflected in the developers guide, especially if Proposal #94 is implemented and there is no longer a shared TLS configuration.

### PQC provider

The proxy relies on the JDK as the PQC provider rather than adding a third party cryptographic library to the runtime. The algorithms are reached through the standard JSSE framework, so the named groups configuration described below is expressed using the JSSE standard names and is interpreted by a single, known provider. This keeps the proxy aligned with the JDK's own security machinery and avoids a provider-dependent configuration surface (see Rejected alternatives for the BouncyCastle option that was considered).

This proposal targets OpenJDK 21, the project's current baseline, and the configuration will also work on OpenJDK 25. As the project only moved to OpenJDK 21 recently, targeting it keeps the work on the JDK that deployments are running today rather than depending on a further runtime bump. On OpenJDK 21 the named groups configuration surface can be built now, with the hybrid key exchange itself arriving through the back-port on the [Java crypto roadmap](https://www.java.com/en/jre-jdk-cryptoroadmap.html), scheduled for 1H27. On OpenJDK 25, [JEP-527](https://openjdk.org/jeps/527) provides hybrid key exchange sooner, enabling `X25519MLKEM768` by default. [Proposal #143](https://github.com/kroxylicious/design/pull/143) proposes OpenJDK 21 as the minimum runtime with OpenJDK 25 preferred, which fits this approach. Tests can be written now and skipped on a JDK that does not yet provide the algorithms. The full set of PQC named group standard names is present from JDK 27.

### Dependency on Proposal #94

[Proposal #94](https://github.com/kroxylicious/design/pull/94) proposes deprecating the common [`io.kroxylicious.proxy.config.tls`](https://github.com/kroxylicious/kroxylicious/tree/main/kroxylicious-api/src/main/java/io/kroxylicious/proxy/config/tls) classes (including [`Tls`](https://github.com/kroxylicious/kroxylicious/blob/main/kroxylicious-api/src/main/java/io/kroxylicious/proxy/config/tls/Tls.java)). That proposal has enough votes to pass but has not yet been merged.

This proposal does not have to wait for Proposal #94. If this work is done first, it is a minor addition to the existing work to implement #94.

If #94 proceeds before implementation of this proposal, the `namedGroups` field described below is added to whatever configuration type replaces Tls. If this proposal proceeds first, the field is added to the existing Tls record and migrated when #94 is implemented.

### TLS configuration changes

TLS configurations gain a new field `namedGroups` (allowed or disallowed) which controls the algorithms used during TLS key exchange.

TLS connections can be controlled with the following configuration options:

- TLS version (allowed/denied)
- Cipher suites (allowed/denied)
- **Named groups (allowed/denied)** - new field. Named groups are part of the TLS 1.3 key exchange. The field is optional and defaults to the JDK's standard groups when unset.

The order of the `allowed` named groups is significant. The first entry is the most preferred, with the remaining entries used as fallbacks in preference order. For example, `[X25519MLKEM768, X25519, secp256r1]` prefers the hybrid PQC group and falls back to classical groups only if the peer does not support it.

Two endpoint postures follow from this. An endpoint that lists a hybrid ML-KEM group alongside classical groups accepts PQC-capable and classical clients, falling back to a classical key exchange where the peer cannot do ML-KEM. An endpoint that lists only a hybrid ML-KEM group accepts only PQC-capable clients, as a classical client cannot complete the ML-KEM part of the handshake, so the connection fails rather than silently downgrading. The hybrid group `X25519MLKEM768` combines classical X25519 ECDH with ML-KEM-768, so both must be broken for a compromise, providing defence against both quantum and classical attacks. The term 'hybrid' here refers to the key exchange algorithm combining a classical and a post-quantum part, not to whether classical clients are allowed to connect.

Enabling PQC requires aligned values across protocols, cipher suites, and named groups. Misconfiguration can break PQC guarantees or prevent endpoints from loading. It is possible to set these to misaligned values and have the endpoint still become available, silently failing to provide PQC protection. Users configuring an endpoint should therefore set TLS 1.3 only, an AES-256-GCM or ChaCha20-Poly1305 cipher suite, and the appropriate named groups together.

#### Configuration examples

Example of a PQC endpoint that allows classical fallback:

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

Example of a PQC-only endpoint (no classical fallback), which lists a single hybrid ML-KEM group:

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
    allowed: [X25519MLKEM768]
```

### ML-DSA certificate support

Existing configuration will work as-is for ML-DSA (Dilithium) certificates as these certificates conform to the X.509 structure and require no special TLS handshake handling. However, certificate parsing will require updating to support Dilithium key types.

There is a current limitation to be aware of. Netty's PEM parser cannot read post-quantum key types yet (#4481), and the project's own PEM parsing has the same gap (#4476). Until that support lands, users supplying ML-DSA certificates will be blocked from using them in PEM form and will have to provide them in a PKCS12 keystore instead. This limitation will need to be documented until Netty catches up.

### ClientTlsContext API extensions

Filters gain visibility into negotiated TLS parameters via [`ClientTlsContext`](https://github.com/kroxylicious/kroxylicious/blob/main/kroxylicious-api/src/main/java/io/kroxylicious/proxy/tls/ClientTlsContext.java) additions.

The API will expose `negotiatedNamedGroup()`, `negotiatedCipherSuite()` and `negotiatedProtocol()`, giving filters visibility into the negotiated handshake parameters. Exposing the named group without the cipher suite and protocol would be inconsistent, as all three are outputs of the same handshake. A filter that cares about the connection's cryptographic posture, for example whether an AES-GCM suite was negotiated, then has the relevant information.

An earlier draft also proposed an `isPqcConnection()` accessor. That has been dropped. Deciding whether a connection counts as PQC puts the proxy on the hook for a judgment that becomes wrong as the JDK adds new named groups, whereas with the suite, protocol and named group exposed a filter can make that determination itself (for example an AES-256 or ChaCha20 suite combined with a hybrid ML-KEM group).

This permits filters to enforce PQC requirements or route based on connection security.

### Client downstream connections

mTLS authentication will require the proxy to understand a client-supplied ML-DSA certificate. The downstream client connection is secured at the gateway level with the `tls` section.

```yaml
# This secures the client-to-proxy connection.
virtualClusters:
  - name: demo
    gateways:
      - name: default
        tls:
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
          protocols:
            allowed: [TLSv1.3]
          cipherSuites:
            allowed: [TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256]
          namedGroups:
            # Allow-list order sets preference; the first entry is most preferred.
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
      # Omit key unless upstream Kafka requires mTLS.
      key:
        privateKeyFile: /etc/kroxylicious/tls/proxy-client.key
        certificateFile: /etc/kroxylicious/tls/proxy-client.crt
      trust:
        storeFile: /etc/kroxylicious/tls/upstream-ca.pem
        storeType: PEM
      protocols:
        allowed: [TLSv1.3]
      cipherSuites:
        allowed: [TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256]
      namedGroups:
        allowed: [X25519MLKEM768, X25519, secp256r1]
```

### Record encryption filter

The record encryption filter already uses AES-256-GCM for record encryption and does not need changing. However, the exchange with the KMS needs to be over PQC connections, so KMS provider implementations will need to be updated. This proposal is limited to those connections.

The proxy does not enforce anything about the KEK; it uses whatever key the user configures the filter with. The `namedGroups` setting controls the TLS connection to the KMS and governs how the DEK is protected in transit, but has no relationship to the KEK and cannot mandate its characteristics. Full PQC protection therefore also depends on the user choosing a quantum-resistant KEK, as the wrapped DEK (edek) is stored alongside the record and is at rest for as long as the record is retained. For example, an Azure Key Vault KEK using RSA-OAEP-256 rather than a 256-bit AES-GCM symmetric key is not quantum-resistant.

Validating the KEK's characteristics is out of scope for this proposal and is captured by issue [#783](https://github.com/kroxylicious/kroxylicious/issues/783), of which quantum resistance would be one use case. A separate proposal covering PQC for data at rest in the proxy is anticipated.

### Operator Ingress

CRD changes analogous to the config YAML changes to support the new `namedGroups` field.

**VirtualKafkaCluster:**

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

### Admission webhook

The admission webhook TLS server configuration gains PQC support analogous to VirtualKafkaCluster ingress configuration.

```yaml
# Admission webhook server TLS configuration
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

CI already runs on JDK 21 and JDK 25, so the tests can be written now and skipped on JDKs that do not yet provide the PQC algorithms (see PQC provider). This lets the configuration and API work progress ahead of the runtime moving to a JDK with hybrid key exchange available.

## Future work: PQC topic filters

This is a future capability that PQC enables, rather than part of the work proposed here. The redirect capability and the topic-based routing it depends on do not exist yet.

The idea is to have a filter that can redirect client connections to PQC or hybrid/non-PQC proxy endpoints based on the topic that they are accessing. This allows a more granular migration strategy and caters for integrating with external business partners where you have no control over their PQC support. Where sensitive data has to travel over a non-PQC endpoint, this could be combined with other filters to redact or encrypt parts of the message.

**Example consume use case:**

1. Create a filter that redacts sensitive fields from the message payload.
2. PQC filter intercepts metadata request. If client is not connected over PQC, rewrite proxy endpoint to the non-PQC endpoint. PQC clients can receive the full data.

**Example produce use case:**

Production to topics that contain sensitive data can be forced over a PQC compliant endpoint. Data that is not sensitive (e.g., temperature readings) can remain over non-PQC endpoints.

## Future work: reload behaviour

Changing `namedGroups` on a running proxy is a virtual-cluster-scoped configuration change, so under the current hot-reload model ([Proposal #83](https://github.com/kroxylicious/design/pull/83)) it triggers a drain and reconnect. Operators planning a phased migration should expect active connections to be dropped when they change these parameters.

TLS parameters are a candidate for a lighter-touch reload. They only affect new handshakes, so in principle existing connections that are already compliant with the new policy do not need draining. Tightening an endpoint from allowing classical fallback to PQC-only could keep connections that already negotiated a hybrid ML-KEM group and drain only the classical ones. That needs a change detector that asks whether existing connections are still compliant, rather than #83's detector that only asks whether the configuration changed, so it's a different shape of problem and is noted here for when the reload model is revisited.

## Deferred and out of scope

### TLS provider selection

The set of available algorithms depends on which TLS provider is active at runtime, and the Java ecosystem has several (the JDK built-in provider, BouncyCastle, native OpenSSL via netty-tcnative). This proposal standardises on the JDK provider, so the configured named groups and cipher suites are interpreted by one known provider and the valid values are well-defined. A general capability to control provider selection, for example to restrict or remove non-JDK providers, is a separate concern. The motivation there is usually to stop a particular provider being used rather than to positively assert one, and it can be discussed separately. For the same reason, `ClientTlsContext` does not expose which provider handled a connection, as the proxy uses the JDK provider throughout.

### Configuration reuse and drift

Reviewers noted that defining TLS configuration inline on every virtual cluster, gateway, KMS and filter risks divergence over time, where one definition drifts from the intended policy because someone forgot to update it. Several approaches were discussed, including named TLS profile objects referenced by name, YAML anchors and merge keys, and externalized presets shipped in the distribution or applied as a Kubernetes custom resource (with a plugin API so filters making their own connections could resolve them). This is a general TLS-configuration concern rather than something specific to PQC, and it overlaps with Proposal #94, so it's deferred. This proposal adds `namedGroups` to the existing per-connection TLS structure and would adopt whatever reuse model the project settles on.

## Affected/not affected projects

**Affected:**

- [`kroxylicious-api`](https://github.com/kroxylicious/kroxylicious/tree/main/kroxylicious-api): [`Tls`](https://github.com/kroxylicious/kroxylicious/blob/main/kroxylicious-api/src/main/java/io/kroxylicious/proxy/config/tls/Tls.java) record and [`ClientTlsContext`](https://github.com/kroxylicious/kroxylicious/blob/main/kroxylicious-api/src/main/java/io/kroxylicious/proxy/tls/ClientTlsContext.java) interface changes
- [`kroxylicious-runtime`](https://github.com/kroxylicious/kroxylicious/tree/main/kroxylicious-runtime): Netty TLS pipeline configuration
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

Existing TLS configurations work unchanged as the `namedGroups` field is optional and defaults to the JDK's standard groups when unset.

### Forwards compatibility

Additional named groups can be added to the configuration as standards evolve, as the field is expressed in terms of the JSSE standard names and takes whatever groups the active JDK supports.

## Rejected alternatives

### Use BouncyCastle as the PQC provider

An earlier draft proposed changing the existing BouncyCastle dependency from test scope to runtime scope to provide ML-KEM and ML-DSA ahead of JDK vendor support. The attraction was control: BouncyCastle 1.85 provides production-ready ML-KEM and ML-DSA for Java 21, it is independent of JDK vendor roadmaps, and it has been in production use far longer than any first release from a JDK vendor.

This was rejected in favour of the JDK provider. Moving BouncyCastle to runtime scope is a material increase in the footprint of a security-critical dependency. With more than one provider in play the available algorithm and named-group surface varies by the active provider, and the JSSE and provider names for the same group may differ, which complicates validating a configuration. Standardising on the JDK keeps the proxy aligned with the platform's own security machinery and is consistent with Strimzi's direction, which also rejects BouncyCastle. The JDK availability gap is also closing, with JEP-527 landing in OpenJDK 25 and the OpenJDK 21 back-port on the roadmap for 1H27. The trade-off accepted is that the proxy depends on JDK timelines, and on the running JDK version, for when hybrid key exchange is available.

## References

- [NIST FIPS 203 - ML-KEM](https://csrc.nist.gov/pubs/fips/203/final)
- [NIST FIPS 204 - ML-DSA](https://csrc.nist.gov/pubs/fips/204/final)
- [JEP 527 - Hybrid Key Exchange for TLS 1.3](https://openjdk.org/jeps/527)
- [Oracle Java SE crypto roadmap](https://www.java.com/en/jre-jdk-cryptoroadmap.html)
- [Proposal #94 - TLS Configuration Refactoring](https://github.com/kroxylicious/design/pull/94)
- [Proposal #143 - adopt JDK 25 as preferred runtime (JDK 21 minimum)](https://github.com/kroxylicious/design/pull/143)

### Related GitHub Issues

- [#783](https://github.com/kroxylicious/kroxylicious/issues/783) - Validate KEK characteristics (candidate to be extended to cover quantum resistance)
- [#4475](https://github.com/kroxylicious/kroxylicious/issues/4475) - Project-wide quantum-safe TLS
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
