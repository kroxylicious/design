# 148 - Per-Gateway Source Address Filtering

Proposes adding per-gateway source address filtering to Kroxylicious, allowing administrators to define CIDR-based allow and deny rules that control which IP addresses are permitted to open connections to each gateway.

## Current situation

Kroxylicious has no built-in mechanism for restricting connections by source IP address. Administrators wishing to limit access by network origin must rely entirely on external controls such as cloud security groups, host-based firewalls (`iptables`/`nftables`), or Kubernetes `NetworkPolicy`. These controls operate at the infrastructure level and have no awareness of the Kroxylicious gateway configuration.

## Motivation

### Defence in depth

Firewalls and security groups are essential but can be misconfigured, circumvented, or out of the operator's direct control (e.g. shared infrastructure). Enforcing an allow/deny policy at the proxy layer provides a second line of defence that is co-located with the proxy configuration and version-controlled alongside it.

### Per-gateway granularity

A single Kroxylicious instance may expose multiple virtual clusters, each with multiple gateways, all sharing the same host address. A firewall rule applied to that host address cannot differentiate between gateways: allowing a port allows access to every gateway listening on that port.

Kroxylicious can, however, distinguish gateways by SNI hostname after reading the TLS `ClientHello`. This means it can enforce different source-address policies on two gateways that share the same listening address and port — something a firewall cannot do.

A typical example: a virtual cluster accessible via a public load-balancer gateway and a private on-cluster gateway on the same port. The load-balancer gateway should accept connections only from the known load-balancer CIDR; the on-cluster gateway should accept connections only from the pod CIDR. A single firewall rule cannot express both constraints simultaneously.

### Restricting PROXY protocol header injection

[Proposal 147](147-per-gateway-proxy-protocol.md) introduces per-gateway PROXY protocol configuration. The PROXY protocol specification warns that PROXY headers must only be accepted from known, trusted intermediaries — if any connecting host can send a PROXY header, a malicious client can forge its apparent origin.

Source address filtering provides the mechanism to enforce this: a gateway configured with `proxyProtocol: mode: required` can additionally use `sourceAddressFilter` to restrict connections to the known load-balancer CIDR. Any peer that does not pass the source filter is rejected before it can present a PROXY header, closing the injection vector.

## Out of scope

### Kubernetes CRD

Adding `sourceAddressFilter` to `KafkaProxyIngress` or other CRDs is not covered by this proposal. The plain configuration API is the focus here; a follow-up can extend the operator.

### Automatic source filter population from Service status

When a `KafkaProxyIngress` uses a `LoadBalancer`-type Service, the cloud provider assigns one or more external IP addresses that are reflected in the Service's `status.loadBalancer.ingress` field. It would be possible for the operator to read those addresses and automatically populate the gateway's `sourceAddressFilter` — so that only traffic originating from the assigned load-balancer IP is accepted, without the administrator having to configure CIDRs manually. This auto-population behaviour is not covered by this proposal and is left for consideration alongside the Kubernetes CRD work.

## Proposal

### Proxy Configuration

Add an optional `sourceAddressFilter` block to `VirtualClusterGateway`. When absent, all connections are accepted (current behaviour; backward compatible).

```yaml
virtualClusters:
  - name: my-cluster
    gateways:
      - name: external
        sniHostIdentifiesNode:
          # ...
        tls:
          # ...
        sourceAddressFilter:
          allow:
            - 203.0.113.0/24       # trusted load-balancer IPv4 range
            - 2001:db8::/32        # trusted load-balancer IPv6 range
          deny:
            - 203.0.113.100/32     # specific host blocked within the allow range

      - name: internal
        portIdentifiesNode:
          # ...
        sourceAddressFilter:
          allow:
            - 10.0.0.0/8           # pod CIDR only

      - name: unrestricted
        portIdentifiesNode:
          # ...
        # no sourceAddressFilter — all source addresses are accepted
```

Both `allow` and `deny` are lists of CIDR strings in the notation defined by [RFC 4632](https://datatracker.ietf.org/doc/html/rfc4632) (IPv4) and [RFC 4291](https://datatracker.ietf.org/doc/html/rfc4291) (IPv6). Single-host addresses may be expressed as `/32` (IPv4) or `/128` (IPv6); there is no special syntax for them.

When `sourceAddressFilter` is present, at least one of `allow` or `deny` must contain at least one entry. An empty filter block is rejected at startup as a configuration error, since its intent is ambiguous. Malformed CIDR strings are also rejected at startup.

### Evaluation semantics

Rules are evaluated in the following order for every new connection:

1. **Deny check**: if the source address falls within any `deny` entry, the connection is rejected.
2. **Allow check**: if the source address falls within any `allow` entry, the connection is accepted.
3. **Default**: if neither check matched:
   - When `allow` is non-empty → reject (implicit deny; the allow list acts as a whitelist).
   - When `allow` is empty or absent → accept (the deny list acts as a pure blacklist).

Deny always takes priority. An address that matches both a `deny` entry and an `allow` entry (e.g. a specific host inside an allowed CIDR) is rejected.

| `allow` configured | `deny` configured | Unmatched address |
|--------------------|-------------------|-------------------|
| Yes                | No                | Rejected          |
| No                 | Yes               | Accepted          |
| Yes                | Yes               | Rejected          |

### Sequencing constraint for SNI-based gateways

For **port-based gateways** (`portIdentifiesNode`): the gateway is known at TCP accept time. Source address filtering is applied immediately — before TLS, before any Kafka protocol exchange. This is the fastest rejection path.

For **SNI-based gateways** (`sniHostIdentifiesNode`) where multiple gateways share a listening port: the source IP is known at TCP accept time, but the gateway is only identified after the SNI name is extracted from the TLS `ClientHello`. Source address filtering is therefore deferred until after SNI resolution but before the TLS handshake completes. A rejected connection receives a TCP close without completing the handshake.

This is the same sequencing constraint described in [Proposal 147](147-per-gateway-proxy-protocol.md) for PROXY protocol. The implementation will apply source filtering at the same pipeline stage as PROXY protocol enforcement for SNI-based gateways.

### Observability

When a connection is rejected by source address filtering:

- A WARN-level log entry is emitted including the remote address and the gateway name.
- The existing `kroxylicious_client_to_proxy_disconnects` metric is incremented with a new `cause` label value: `source_address_denied`.

### Interaction with PROXY protocol

Source address filtering operates on the **network-layer source address** (the TCP peer address as reported by the OS). It is not affected by PROXY protocol headers.

When a gateway is configured with both `sourceAddressFilter` and `proxyProtocol: mode: required`, the source filter acts as a guard on which peers are trusted to send PROXY headers. Only peers that pass the source filter reach the PROXY protocol decoding stage. This provides a natural way to restrict PROXY header injection to known load-balancer addresses without any additional configuration.

## Affected/not affected projects

**Affected:**

- `kroxylicious-runtime` — `VirtualClusterGateway` configuration model; Netty pipeline initialisation (new channel handler for source filtering); startup validation (CIDR parsing)

**Not affected:**

- `kroxylicious-api` — no public filter API changes; source address is already planned for exposure via `FilterContext` in [Proposal 139](https://github.com/kroxylicious/design/blob/main/proposals/139-expose-client-address-to-filters.md)
- `kroxylicious-filters` — no filter changes
- `kroxylicious-kubernetes/*` — Kubernetes CRD changes are out of scope for this proposal

## Compatibility

`sourceAddressFilter` is a new optional field. Existing configurations without it continue to behave as today (all connections accepted). No migration is required.

The new `cause=source_address_denied` metric label value is additive and does not affect existing dashboards that do not reference it.

## Rejected alternatives

### Hostname / DNS-based rules

Rules based on reverse-DNS lookup of the source address were considered. DNS resolution at connection time introduces latency, external failure modes, and the possibility of DNS-based spoofing. CIDR ranges are sufficient for the target use cases.

### Global (non-per-gateway) filter

A global filter applied to all gateways would be simpler to configure, but it cannot express the per-gateway differentiation that is the primary motivation for this feature. Per-gateway is the only design that enables the SNI-based use case described in the motivation.

### Kubernetes CRD

Deferred to a follow-up proposal. The plain configuration API is sufficient to validate the design; operator support can follow once the runtime implementation is stable.
