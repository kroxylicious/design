# 147 - Per-Gateway PROXY Protocol Configuration

Proposal to allow PROXY protocol acceptance to be configured individually per gateway, replacing the existing global setting.

## Current situation

Kroxylicious has top-level support for the [HAProxy PROXY protocol](https://www.haproxy.org/download/3.1/doc/proxy-protocol.txt) via a `proxyProtocol` block in the root configuration:

```yaml
proxyProtocol:
  mode: required   # or: allowed, disabled
```

This applies a single mode across every gateway of every virtual cluster in the proxy instance.

The Kubernetes `KafkaProxyIngress` CRD has no equivalent field; there is no way to configure PROXY protocol acceptance via the operator.

The proxy already decodes PROXY protocol headers from the wire when the mode is `required` or `allowed`, but currently makes **no programmatic use** of the decoded information — it is discarded. [Proposal 139](https://github.com/kroxylicious/design/blob/main/proposals/139-expose-client-address-to-filters.md) (recently approved, not yet implemented) will change this by exposing the client address to filters via `FilterContext`.

## Motivation

The existing global setting is too coarse for real deployments. A virtual cluster may be accessible via more than one gateway, where each gateway has a different trust relationship with its upstream.

A common scenario is a virtual cluster with two gateways:

- A **LoadBalancer** gateway for external clients routed through a cloud load balancer that supports PROXY protocol v2 (e.g., AWS NLB with the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.2/guide/service/annotations/#proxy-protocol-v2)). PROXY protocol headers arriving on this gateway are expected and trustworthy.
- A **ClusterIP** gateway for on-cluster clients connecting directly to the proxy. PROXY protocol headers on this gateway are _not_ expected — if accepted, they would allow a malicious on-cluster client to forge its apparent network origin.

With the current global setting, an administrator cannot achieve this split. Enabling PROXY protocol globally creates an injection risk on the ClusterIP gateway; disabling it means the real client address is lost on the LoadBalancer gateway.

The [PROXY protocol specification](https://www.haproxy.org/download/3.1/doc/proxy-protocol.txt) is explicit on this point:

> Implementers should be very careful about not trying to automatically detect whether they have to decode the header or not, but rather they must only rely on a configuration parameter. Indeed, if the opportunity is left to a normal client to use the protocol, it will be able to hide its activities or make them appear as coming from somewhere else.

This means PROXY protocol must be **on or off**, with no auto-detection. A gateway that requires PROXY protocol must reject connections that do not carry the header; a gateway that does not require it must reject connections that do.

## Out of scope

### Source address filtering

Even with per-gateway control, an administrator may want to restrict which sources are trusted to send PROXY protocol headers — accepting them only from a known intermediary rather than from any connecting host. This is a general source-address filtering concern that applies beyond PROXY protocol and will be addressed in a separate proposal.

### Propagating PROXY protocol to the upstream

This proposal covers only the acceptance of PROXY protocol headers from downstream clients. Propagating the header onward to the upstream is not in scope. Kafka brokers do not support PROXY protocol, so there is no upstream consumer for such a header today. If Kroxylicious proxies were ever chained, propagation could become relevant, but that scenario is not a current requirement.

## Proposal

### Plain configuration — `VirtualClusterGateway`

Add an optional `proxyProtocol` block to `VirtualClusterGateway`. When absent the gateway behaves as `disabled`. The `allowed` (auto-detect) mode is not supported.

```yaml
virtualClusters:
  - name: my-cluster
    gateways:
      - name: external
        sniHostIdentifiesNode:
          # ... SNI config ...
        tls:
          # ... TLS config ...
        proxyProtocol:
          mode: required   # load balancer sends PROXY headers; require them

      - name: internal
        portIdentifiesNode:
          # ... port config ...
        # no proxyProtocol block — defaults to disabled
```

**Mode semantics:**

| Mode | Behaviour |
|------|-----------|
| `required` | Every connection must begin with a valid PROXY v1 or v2 header. Connections that do not carry the header are rejected. |
| `disabled` | No PROXY protocol handling. Connections that carry a PROXY header are rejected to prevent injection. This is the default when `proxyProtocol` is omitted. |

### Kubernetes API — `KafkaProxyIngress`

Add an optional `proxyProtocol` block under `spec.loadBalancer` in the `KafkaProxyIngress` CRD. The field is placed here because cloud load balancers are the primary consumers of PROXY protocol in Kubernetes (see [Rejected alternatives](#rejected-alternatives) for why `clusterIP` and `openShiftRoute` are excluded).

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: KafkaProxyIngress
metadata:
  name: public
spec:
  proxyRef:
    name: my-proxy
  loadBalancer:
    proxyProtocol:
      mode: required
```

The operator translates this to a `proxyProtocol` block on the corresponding `VirtualClusterGateway` in the generated proxy configuration.

> **Note:** Setting `mode: required` configures Kroxylicious to expect and enforce PROXY protocol headers on this gateway. It does **not** automatically configure the cloud load balancer to send them. The administrator is responsible for enabling PROXY protocol on the load balancer separately. For example, when using the AWS Load Balancer Controller, the annotation `service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: proxy_protocol_v2.enabled=true` must be applied to the Kubernetes Service — this can be done via the `spec.infrastructure.annotations` field on the `KafkaProxyIngress`.

### Implementation note — port sharing under TLS/SNI

When multiple gateways share a listening port and are distinguished by SNI hostname, there is a sequencing constraint: the PROXY protocol header arrives before the TLS `ClientHello`, and therefore before SNI resolution identifies which gateway is being targeted.

The proxy will resolve this by operating speculatively at the port level: if any gateway bound to a port has `mode: required`, the proxy will attempt to decode a PROXY header on that port. Once SNI resolution has identified the gateway, the per-gateway mode is enforced:

- Gateway is `required` and a header was received → accepted.
- Gateway is `required` and no header was received → connection closed immediately; closure is logged; `kroxylicious_client_to_proxy_disconnects` is incremented with `cause=proxy_protocol_header_missing`.
- Gateway is `disabled` and no header was received → accepted (normal path).
- Gateway is `disabled` and a header was received → connection closed immediately; closure is logged; `kroxylicious_client_to_proxy_disconnects` is incremented with `cause=proxy_protocol_header_unexpected`.

This is an implementation detail. The user-visible API remains binary: `required` or `disabled`, per gateway.

### Migration from the global `proxyProtocol` field

The top-level `proxyProtocol` field in the plain configuration is superseded by this proposal. When the field is present, the proxy will log a startup warning and **ignore the value**. Administrators should migrate to per-gateway configuration.

The `allowed` mode present in the legacy global field is also ignored when encountered. No equivalent is provided in the per-gateway API.

## Affected/not affected projects

**Affected:**
- `kroxylicious-runtime` — configuration model (`VirtualClusterGateway`), Netty pipeline initialisation, startup validation
- `kroxylicious-kubernetes/kroxylicious-kubernetes-api` — `KafkaProxyIngress` CRD schema (`spec.loadBalancer`)
- `kroxylicious-kubernetes/kroxylicious-operator` — reconciler generating proxy configuration from `KafkaProxyIngress`

**Not affected:**
- `kroxylicious-api` — no public filter API changes
- `kroxylicious-filters` — no filter changes; client address exposure is tracked in proposal 139

## Compatibility

- The existing global `proxyProtocol` field is deprecated and ignored. This is a **behavioural breaking change** for any deployment that relied on it; those deployments must migrate to per-gateway configuration.
- The `allowed` mode is removed. Any configuration using it falls back to the deprecation behaviour above (ignored, warned).
- The per-gateway `proxyProtocol` field is new and additive; existing configurations without it continue to work with `disabled` semantics.
- The `KafkaProxyIngress` CRD change is additive (new optional field under `spec.loadBalancer`). Existing resources without the field retain `disabled` behaviour.

## Rejected alternatives

### Top-level `spec.proxyProtocol` on `KafkaProxyIngress`

Placing the field at the top level of `KafkaProxyIngress.spec` would imply it is meaningful regardless of ingress type, but the field would be inert or counterproductive for both `clusterIP` and `openShiftRoute` ingress types (see those sections below). Nesting it under `spec.loadBalancer` makes it explicit that PROXY protocol is a concern of the load balancer type only.

### `spec.clusterIP.proxyProtocol`

On-cluster clients connect directly to the proxy without an intermediate load balancer. Their network address is already accurate and directly observable. Accepting PROXY headers from on-cluster clients would allow any workload to claim an arbitrary source address, undermining the security model that this feature is designed to enforce.

### `spec.openShiftRoute.proxyProtocol`

OpenShift's ingress (HAProxy-based) is capable of consuming PROXY protocol headers from an upstream load balancer, but it cannot propagate the original client address to backend services using the PROXY protocol. It can propagate the address via HTTP headers such as `X-Forwarded-For`, but those are not accessible to Kroxylicious, which operates at the TCP/Kafka protocol layer. The field would therefore be inert.

### Keeping the `allowed` (auto-detect) mode

The PROXY protocol specification explicitly warns against automatic detection:

> [I]f the opportunity is left to a normal client to use the protocol, it will be able to hide its activities or make them appear as coming from somewhere else.

Auto-detection allows any client to inject a PROXY header and spoof its origin. The mode is therefore not included in the per-gateway API.

### Retaining the global `proxyProtocol` field as a default fallback

A global default (analogous to `defaultFilters`) might seem convenient during migration, but it would undermine the security guarantee this feature is designed to provide. An administrator who intends only the LoadBalancer gateway to accept PROXY headers could accidentally leave the global default active, enabling injection on all other gateways. Explicit per-gateway configuration is safer.

### Restricting accepted PROXY protocol versions

PROXY protocol v1 (text-based) and v2 (binary) are both widely deployed and accepted by the underlying Netty decoder without distinction. Restricting acceptance to a specific version — for example, requiring v2 only — was considered but is not included in this proposal. There is no pressing operational reason to exclude either format today; most modern load balancers that support PROXY protocol offer v2. The `proxyProtocol` configuration node is intentionally structured to accommodate a version constraint in a future proposal without a breaking API change.

