# 154 - Metrics for negotiated TLS parameters

Administrators can configure which TLS protocols, cipher suites and named groups the proxy allows, but they cannot see what is actually negotiated on each connection.
This proposal adds two counters that record the TLS parameters of every TLS connection, on the client side per gateway and on the server side per target cluster, and a log line that identifies the connection behind each count.
It addresses [kroxylicious#5197](https://github.com/kroxylicious/kroxylicious/issues/5197).

## Current situation

A client's traffic through the proxy passes over two separate connections, and each can use its own TLS settings:

- **Client to proxy:** the client connects to a *gateway*, a network entry point of a virtual cluster.
  The proxy acts as the TLS server.
  The settings come from the gateway's `tls`.
- **Proxy to server:** the proxy connects to the real Kafka cluster named in the virtual cluster's `target.cluster`.
  The proxy acts as the TLS client.
  The settings come from that cluster's `tls`.

```yaml
clusters:
  - name: demo-cluster
    bootstrapServers: kafka:9093
    tls: ...          # connection 2 (proxy → server)
virtualClusters:
  - name: demo
    target:
      cluster: demo-cluster
    gateways:
      - name: external
        sniHostIdentifiesNode: ...
        tls: ...      # connection 1 (client → proxy)
```

A virtual cluster can have several gateways, for example a plain-text one for internal clients and a TLS one for external clients, each with its own TLS settings.

The existing connection metrics, `kroxylicious_client_to_proxy_connections_total` and `kroxylicious_proxy_to_server_connections_total`, count connections by `virtual_cluster` and `node_id` (the broker the connection is for, or `bootstrap`).
They record nothing about TLS and nothing about the gateway.

The proxy does not log the negotiated TLS parameters either.
Today, the only way to see them is to raise the TLS debug level and read the trace output.

## Motivation

Administrators need to confirm that their TLS configuration has taken effect, for example:

- Are all connections using TLS 1.3?
- Are all connections using the cipher suites I allowed?

When the answer is no, they need to find the clients responsible, so that the owners of those applications can upgrade them.

A misconfigured gateway or cluster is easy to miss without this.
[Proposal 144](https://github.com/kroxylicious/design/blob/main/proposals/144-pqc-support.md) (post-quantum cryptography support) makes this more important, as administrators tighten protocols, cipher suites and named groups and need to see that clients and brokers comply.
Metrics make this visible on a dashboard or in an alert, without debug logging.

## Proposal

### Metrics

Two counters, each incremented once per successful TLS handshake:

| Metric | Labels |
|---|---|
| `kroxylicious_client_to_proxy_tls_connections_total` | `virtual_cluster`, `gateway`, `tls_protocol`, `tls_ciphersuite`, `tls_named_group` |
| `kroxylicious_proxy_to_server_tls_connections_total` | `virtual_cluster`, `target_cluster`, `tls_protocol`, `tls_ciphersuite`, `tls_named_group` |

The names follow the existing `kroxylicious_*_connections_total` counters.

`tls_protocol`, `tls_ciphersuite` and `tls_named_group` use the standard JDK names, such as `TLSv1.3`, `TLS_AES_256_GCM_SHA384` and `X25519MLKEM768`.
These are the same names administrators use in the proxy's TLS configuration, so a value can be compared directly with the configured one.

### Label choices

Each metric is labelled with where its TLS settings come from.

- `gateway` (client side): TLS is configured per gateway, so this points to the configuration that produced the result.
- `target_cluster` (server side): upstream TLS comes from the `clusters` entry, not from the gateway.
  The value is the cluster's `name`.
  This also covers a virtual cluster that uses a router to reach several clusters with different TLS settings, and a cluster shared by several virtual clusters.
- `virtual_cluster` (both): matches every existing proxy metric and lets administrators filter by virtual cluster.

`node_id` is not used.
All brokers behind one gateway or cluster share the same TLS settings, so a per-broker breakdown adds series without adding information.
The existing connection metrics are unchanged and keep `node_id`.

### What is counted

Only successful handshakes are counted.
This proposal is about what was negotiated, and a failed handshake negotiated nothing.

Plain-text connections are not counted.
TLS is either on or off for a whole gateway or cluster, so the configuration already shows which connections are unencrypted.

Cardinality stays low.
Label values come from configured names and from a small set of protocol, cipher suite and named group names.
As in the issue, the client address and the authenticated subject are deliberately left out of the metrics.
The log line below provides them instead.

### Named group

The named group is the key exchange algorithm of the handshake, such as `X25519MLKEM768`.
Reading it needs `ExtendedSSLSession.getNamedGroup()`, which JDK 28 adds ([JDK-8388519](https://bugs.openjdk.org/browse/JDK-8388519)) and which is currently in the JDK 28 early-access builds.
The project's runtime baseline is OpenJDK 21, with 25 preferred (see proposal 144), and neither has it.

So the proxy checks once, at startup, whether the running JDK provides this method:

- If it does, both metrics and the log line include the named group.
  If a handshake negotiated no named group, the value is `none`.
- If it does not, the `tls_named_group` label and the log field are left out.

The labels of a metric therefore never change while the proxy is running.

The named group is part of this design, but its implementation is deferred.
The first implementation delivers protocol and cipher suite; the named group can be added later, by any contributor, without a new proposal.

### Finding the clients behind a count

The metrics show that some connections use, say, TLS 1.2, but not which clients made them.
For that, the proxy logs one line for every successful TLS handshake:

- Logger: `io.kroxylicious.proxy.tls.handshake`.
- Level: `INFO`.
- Client side fields: `sessionId`, `virtualCluster`, `gateway`, `clientAddress`, `clientCertificateSubject` (when the client presents a certificate), `tlsProtocol`, `tlsCipherSuite`, and `tlsNamedGroup` when available.
- Server side fields: `sessionId`, `virtualCluster`, `targetCluster`, `serverAddress`, `tlsProtocol`, `tlsCipherSuite`, and `tlsNamedGroup` when available.

Example, using the default text log format:

```
INFO  io.kroxylicious.proxy.tls.handshake - Client TLS handshake completed {clientAddress=10.0.4.17:51432, gateway=external, sessionId=7f3c..., tlsCipherSuite=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, tlsProtocol=TLSv1.2, virtualCluster=demo}
```

`clientAddress` is the client's own address: when the gateway uses the PROXY protocol, it is the source address reported by the load balancer, which the proxy receives before the TLS handshake.

The level is `INFO` because Kafka client connections are long-lived.
By the time an administrator sees an unexpected value in the metrics, the handshake has usually already happened, so a line logged at a lower level would be missed until the client reconnects.
A dedicated logger lets administrators turn these lines off without affecting other proxy logs.

Other details that identify a client only become known later in the connection.
The `sessionId` field links the handshake line to the proxy's later log lines for the same connection, such as the SASL identity logged when a SASL filter is configured.
The proxy does not currently log the Kafka client ID.
The documentation will explain how to trace a connection back to the application that made it.

## Future extensions

Once the project's minimum Java version provides `ExtendedSSLSession.getNamedGroup()`, the startup check can be removed and the named group always reported.

## Testing

- Unit tests for the new metrics and the log line.
- Integration tests that make TLS connections with known protocol and cipher suite settings on both sides, and check the reported metric values, labels and log fields.
- Named group tests run only on JDKs that provide the API, and are skipped elsewhere.

## Affected/not affected projects

**Affected:**

- `kroxylicious` proxy runtime: the two new metrics and the handshake log line.
- Proxy documentation: the metrics reference, and how to find the clients behind a metric using the log line.

**Not affected:**

- The proxy configuration format.
- The Kubernetes Operator and its custom resources.
- The filter API.
- Existing metrics.

## Compatibility

The change is purely additive: two new metrics, one new log line, no configuration changes, and no change to existing metrics or labels.
The `tls_named_group` label is only present when the proxy runs on a JDK that provides the API, so dashboards should not assume it is always there.

## Rejected alternatives

### A `node_id` label

This would match the existing connection metrics.
It was rejected because every broker behind a gateway or cluster uses the same TLS settings, so it adds series without adding information.

### A `gateway` label on the proxy-to-server metric

The issue suggests `virtual_cluster` and `gateway` on both metrics.
It was rejected for the server side because the gateway does not determine upstream TLS settings; the target cluster does.

### Counting plain-text connections with `tls_protocol="none"`

This would let administrators check for unencrypted traffic with a single query.
It was rejected because plain text is already clear from the configuration, and a TLS metric would then carry non-TLS data.

### `_info` metric names

The issue names the metrics `kroxylicious_client_to_proxy_tls_connection_info` and `kroxylicious_proxy_to_server_tls_connection_info`.
By convention, an `_info` metric has a constant value of 1, but these are counters, so they follow the `_total` naming of the existing connection counters.

### Client identity as metric labels

Labelling the metrics with the client address, client ID or authenticated subject would identify clients directly.
It was rejected because these values are unbounded and would cause a cardinality explosion; the log line provides them instead.

### Logging the handshake at `DEBUG`

This would keep the default logs quieter.
It was rejected because handshakes of long-lived connections would already have happened before an administrator raised the level, so the clients to upgrade would not appear.

### Always reporting `tls_named_group`, as `unknown` when unavailable

This would give the metrics the same labels on every JDK.
It was rejected because the label would be `unknown` on every runtime the project supports today, adding a label that carries no information.

### Other ways to get the named group on Java 21

- **Read the group from the handshake bytes** (the ServerHello `key_share` in TLS 1.3, or the ServerKeyExchange in TLS 1.2): possible, but it adds TLS-parsing code the project must maintain, on the setup path of every TLS connection.
- **Reflection into JDK internals (`sun.security.ssl`):** needs `--add-opens` and may break with any JDK update.
- **JDK Flight Recorder (`jdk.TLSHandshake` event):** on JDK 21 the event has no named group field.
  JDK 28 adds one, but the event is off by default, cannot be linked to a gateway or virtual cluster, and is a diagnostics tool rather than a metrics source.
- **Switching to the OpenSSL TLS provider:** OpenSSL can report the group, but changing the proxy's TLS provider is far too large a change for a metrics feature.
