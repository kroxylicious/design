# Proposal 017: PROXY Protocol v2 Authority-Based Routing

## Summary

Introduce a new gateway routing strategy that uses the `PP2_TYPE_AUTHORITY` TLV from PROXY protocol v2 headers to identify the target broker. This enables deployments where TLS is terminated at a load balancer (such as AWS NLB or HAProxy) while Kroxylicious runs plaintext, with the load balancer forwarding the original SNI hostname as the PPv2 authority TLV.

## Current Situation

Kroxylicious currently offers two gateway routing strategies:

1. **`portIdentifiesNode`** — Each broker is assigned a unique port. The port the client connects to determines which upstream broker handles the connection. This requires one port per broker, and the load balancer must expose all of them.

2. **`sniIdentifiesNode`** — The TLS SNI (Server Name Indication) from the client's TLS ClientHello is used to identify the target broker. All brokers share a single port, and Kroxylicious terminates TLS. This requires Kroxylicious to manage TLS certificates and perform TLS termination.

Kroxylicious also supports receiving PROXY protocol v1/v2 headers (`proxyProtocol.mode: allowed | required`), but today the information extracted from these headers is limited to source address preservation. The `PP2_TYPE_AUTHORITY` TLV is captured and logged but not used for routing decisions.

Example of what Kroxylicious already captures:

```
2026-04-17 09:26:20 DEBUG io.kr.pr.in.ne.HaProxyContext -
  Captured TLV from PROXY header {tlvLength=27, tlvType=PP2_TYPE_AUTHORITY, tlvValue=bootstrap.kafka.example.com}
  Captured TLV from PROXY header {tlvLength=26, tlvType=PP2_TYPE_AUTHORITY, tlvValue=broker-0.kafka.example.com}
```

## Motivation

In many production environments, TLS termination happens at the load balancer layer rather than at the application. This is standard practice for several reasons:

- **Operational simplicity**: Certificate management is centralised at the load balancer (e.g. AWS Certificate Manager for NLB) rather than distributed to every application instance.
- **Reduced application complexity**: The application runs plaintext, avoiding the need to configure keystores, truststores, and TLS parameters.
- **Lower CPU overhead**: TLS handshakes and encryption are offloaded to purpose-built load balancer hardware/software.
- **Consistent security posture**: The organisation's TLS policies (cipher suites, protocol versions, certificate rotation) are enforced at one layer.

The challenge is that when TLS is terminated at the load balancer, the application loses access to the SNI hostname — the very information `sniIdentifiesNode` relies on for routing.

PROXY protocol v2 solves this. Load balancers that terminate TLS can forward the original SNI hostname as the `PP2_TYPE_AUTHORITY` TLV (type `0x02`). This is supported by:

- **AWS Network Load Balancer (NLB)**: When configured with a TLS listener and PROXY protocol v2 enabled on the target group, NLB automatically includes `PP2_TYPE_AUTHORITY` containing the SNI from the client's TLS ClientHello. (Subject to validation — the proof of concept used HAProxy; NLB behaviour is based on AWS documentation but has not been explicitly tested.)
- **HAProxy**: The `send-proxy-v2 proxy-v2-options authority` server option includes the SNI as the authority TLV. Validated in the proof of concept.
- **Envoy**: Envoy's `ProxyProtocolUpstreamTransport` supports PPv2 but **cannot dynamically inject the SNI as the authority TLV**. The `added_tlvs` field (v1.31+) only accepts static values, and there is no built-in mechanism to source a TLV value from connection metadata such as the SNI captured by `tls_inspector`. `pass_through_tlvs` only forwards TLVs from an existing downstream PPv2 header — it does not originate them. This means Envoy is not a viable option for this use case without a custom filter or external scripting.

A PPv2 authority-based routing strategy would give Kroxylicious the same single-port, hostname-based routing capability as `sniIdentifiesNode`, but without requiring Kroxylicious to terminate TLS.

## Proposal

### New routing strategy: `proxyProtocolAuthorityIdentifiesNode`

Introduce a new gateway configuration that routes connections based on the `PP2_TYPE_AUTHORITY` TLV value from the PROXY protocol v2 header:

```yaml
virtualClusters:
  - name: demo
    targetCluster:
      bootstrapServers: upstream-kafka:9092
    gateways:
      - name: via-nlb
        proxyProtocolAuthorityIdentifiesNode:
          bootstrapAddress: 0.0.0.0:9192
          advertisedBrokerAddressPattern: broker-$(nodeId).kafka.example.com
```

Like `sniIdentifiesNode`, this strategy does not require `nodeIdRanges` — the node identity is derived dynamically from the authority hostname by matching it against the `advertisedBrokerAddressPattern`. The proxy discovers the set of upstream brokers from the target cluster's metadata, not from a pre-declared range.

### Architecture

```
                          ┌──────────────────────────┐
                          │     AWS NLB / HAProxy    │
Kafka client ──── TLS ───►│  TLS listener :9192      │
  (SNI: broker-0.         │  Terminates TLS          │
   kafka.example.com)     │  Extracts SNI            │
                          └───────────┬──────────────┘
                                      │ Plaintext TCP
                                      │ + PPv2 header with
                                      │   PP2_TYPE_AUTHORITY =
                                      │   "broker-0.kafka.example.com"
                                      ▼
                          ┌──────────────────────────┐
                          │     Kroxylicious         │
                          │  Reads PP2_TYPE_AUTHORITY│
                          │  Routes to broker 0      │
                          │  Listens plaintext :9192 │
                          └───────────┬──────────────┘
                                      │
                                      ▼
                          ┌──────────────────────────┐
                          │   Upstream Kafka Broker  │
                          └──────────────────────────┘
```

### Routing logic

The routing logic mirrors `sniIdentifiesNode` but reads the hostname from the PPv2 authority TLV instead of the TLS SNI:

1. A new connection arrives with a PROXY protocol v2 header.
2. Kroxylicious extracts the `PP2_TYPE_AUTHORITY` TLV value (a UTF-8 hostname string).
3. The authority hostname is matched against the `advertisedBrokerAddressPattern` to determine the target node ID.
4. The connection is routed to the corresponding upstream broker.

If the PPv2 header is missing or does not contain a `PP2_TYPE_AUTHORITY` TLV, the connection is rejected. This strategy implicitly requires `proxyProtocol.mode: required`.

### Metadata response rewriting

Like `sniIdentifiesNode`, the proxy rewrites Metadata responses so that each broker's advertised address uses the pattern hostname. Clients then reconnect using the broker-specific hostname (e.g. `broker-0.kafka.example.com`), which the load balancer captures as SNI and forwards as PP2_TYPE_AUTHORITY on the next connection.

### Interaction with existing proxy protocol support

This strategy builds on the existing PROXY protocol support. When `proxyProtocolAuthorityIdentifiesNode` is configured:

- `proxyProtocol.mode` is implicitly `required` for gateways using this strategy.
- The existing `HaProxyContext` TLV capture is extended to make the authority value available to the routing layer.

### Validation

The following conditions should be validated at configuration time:

- `proxyProtocol.mode` must not be `disabled` (or it is set to `required` implicitly).
- `advertisedBrokerAddressPattern` must be defined.
- The pattern must be derivable to a hostname that allows extracting a node ID (similar to `sniIdentifiesNode`).

### Proof of concept

A working proof-of-concept has been validated using HAProxy as a TLS-terminating proxy in front of Kroxylicious:

- **HAProxy config**: TLS frontend with `send-proxy-v2 proxy-v2-options authority` on backends.
- **Kroxylicious config**: `proxyProtocol.mode: allowed` with `portIdentifiesNode` gateway.
- **Result**: Kroxylicious successfully received and logged the `PP2_TYPE_AUTHORITY` TLV containing the SNI hostname from the client's TLS ClientHello.

Kafka clients connecting via TLS to HAProxy with bootstrap server `bootstrap.kafka.example.com:49192` produced the following in Kroxylicious logs:

```
Captured TLV from PROXY header {tlvLength=27, tlvType=PP2_TYPE_AUTHORITY, tlvValue=bootstrap.kafka.example.com}
Captured TLV from PROXY header {tlvLength=26, tlvType=PP2_TYPE_AUTHORITY, tlvValue=broker-0.kafka.example.com}
```

The test setup (HAProxy + docker-compose + cert generation) is available in `dev/envoy-proxy-protocol/` of the Kroxylicious repository.

## Affected/not affected projects

| Project | Affected | Notes |
|---------|----------|-------|
| kroxylicious-proxy | Yes | New routing strategy implementation, extends `HaProxyContext` to expose authority TLV to routing layer |
| kroxylicious-operator | Yes | CRD update to support the new gateway type |
| kroxylicious-junit5-extension | Possibly | Test infrastructure for integration testing with PPv2 authority |
| kroxylicious-filter-api | No | No filter API changes needed |

## Compatibility

- **Backwards compatible**: This is a new routing strategy. Existing configurations are unaffected.
- **PROXY protocol v2 only**: The `PP2_TYPE_AUTHORITY` TLV is a v2 feature. PROXY protocol v1 does not support TLVs and cannot carry authority information.
- **Load balancer requirement**: The upstream load balancer must support PPv2 with dynamic authority TLV injection from the TLS SNI. This is natively supported by AWS NLB (TLS listener + PPv2 target group) and HAProxy 1.5+ (`proxy-v2-options authority`). Envoy does not support this natively — its `added_tlvs` only accepts static values and cannot source from connection metadata like SNI.

## Rejected alternatives

### Use SNI passthrough at the load balancer

Instead of terminating TLS at the load balancer, configure TLS passthrough so that Kroxylicious receives the raw TLS ClientHello and can extract SNI itself (the existing `sniIdentifiesNode` strategy).

**Rejected because**: This requires Kroxylicious to manage TLS certificates and perform TLS termination, which is exactly what many organisations want to avoid. TLS passthrough also prevents the load balancer from inspecting or health-checking the connection at the application layer.

### Custom TLV-based routing

Allow routing based on arbitrary PPv2 TLV types, not just authority.

**Rejected because**: This adds unnecessary complexity. `PP2_TYPE_AUTHORITY` (type `0x02`) is the standard TLV for this purpose, is widely supported by load balancers, and directly represents the client's intended hostname. Custom TLV routing could be considered as future work if a concrete use case emerges.
