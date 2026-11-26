# 154 - Metrics for negotiated TLS parameters

Administrators can configure which TLS protocols, cipher suites and named groups the proxy allows, but they cannot see what is actually negotiated on each connection.
This proposal adds two counters that record the TLS parameters of every TLS connection, on the client side per gateway and on the server side per target cluster, and a per-connection log line that identifies the clients behind each count.
It addresses [kroxylicious#5197](https://github.com/kroxylicious/kroxylicious/issues/5197).

## Current situation

A client's traffic through the proxy passes over at least two separate connections, and each can use its own TLS settings:

- **Client to proxy:** the client connects to a *gateway*, a network entry point of a virtual cluster.
  The proxy acts as the TLS server.
  The settings come from the gateway's `tls`.
- **Proxy to server:** the proxy connects to the real Kafka cluster named in the virtual cluster's `target.cluster`.
  The proxy acts as the TLS client.
  The settings come from that cluster's `tls`.
  When the virtual cluster uses a router, the proxy may connect to several target clusters, each with its own `tls`.

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

The proxy does not log the negotiated TLS parameters either, and by default it logs nothing for each connection.
Today, the only way to see them is to raise the TLS debug level and read the trace output.

## Motivation

Administrators who plan to tighten their TLS configuration, for example by dropping TLS 1.2 or an old cipher suite, need to know the impact before making the change:

- Which protocols, cipher suites and named groups are clients and brokers actually using?
- Which allowed settings are no longer used, and can be removed?
- Which applications still rely on a setting that is about to be removed, so that their owners can be asked to upgrade?

[Proposal 144](https://github.com/kroxylicious/design/blob/main/proposals/144-pqc-support.md) (post-quantum cryptography support) makes this more important, as administrators move towards stricter protocols, cipher suites and named groups.
Metrics make this visible on a dashboard or in an alert, without debug logging.

The metrics only see connections whose TLS handshake succeeded.
A client rejected because it shares no protocol or cipher suite with the proxy does not appear, so the metrics show what is in use among the allowed settings, not which clients are failing.
Failed connections are out of scope for this proposal.

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

The `tls_named_group` label and the `tlsNamedGroup` log field are always present, so the labels of a metric are the same on every JDK.
The proxy checks once, at startup, whether the running JDK provides this method:

- If it does, the value is the negotiated named group, or `none` if the handshake negotiated no named group.
- If it does not, the value is `unsupported`.

An explicit `unsupported` value is clearer in queries and aggregations than a missing label.

The named group is part of this design, but reading it is deferred.
The first implementation can report `unsupported` for every connection; detecting the API and reporting the real group can be added later, by any contributor, without a new proposal.

### Identifying clients

The metrics show that some connections use, say, TLS 1.2, but not which clients made them.
For that, the proxy logs one line for every connection once it is established, whether or not it uses TLS:

- Logger: `io.kroxylicious.proxy.connection`.
- Level: `INFO`.
- When: after the TLS handshake for a TLS connection, or as soon as the connection is established for a plain-text one.
- Client side fields: `sessionId`, `virtualCluster`, `gateway`, `clientAddress`, and for TLS connections `clientCertificateSubject` (when the client presents a certificate), `tlsProtocol`, `tlsCipherSuite` and `tlsNamedGroup`.
- Server side fields: `sessionId`, `virtualCluster`, `targetCluster`, `serverAddress`, and for TLS connections `tlsProtocol`, `tlsCipherSuite` and `tlsNamedGroup`.

Using one logger for both kinds of connection keeps connection logging consistent; the TLS fields are simply absent when TLS is not used.

Examples, using the default text log format:

```
INFO  io.kroxylicious.proxy.connection - Client connection established {clientAddress=10.0.4.17:51432, gateway=external, sessionId=7f3c..., tlsCipherSuite=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, tlsNamedGroup=unsupported, tlsProtocol=TLSv1.2, virtualCluster=demo}
INFO  io.kroxylicious.proxy.connection - Client connection established {clientAddress=10.0.7.3:40118, gateway=internal, sessionId=9a1e..., virtualCluster=demo}
```

`clientAddress` is the client's own address: when the gateway uses the PROXY protocol, it is the source address reported by the load balancer, which the proxy receives at the start of the connection.

The level is `INFO` because Kafka client connections are long-lived.
By the time an administrator sees an unexpected value in the metrics, the connection has usually already been established, so a line logged at a lower level would be missed until the client reconnects.

The line is written once, when a connection is established, so the logs only show clients that connected within the log retention window.
Metrics are usually kept for longer, and Kafka connections can stay open for weeks, so a counted connection may no longer have a matching log line.
Keeping these lines for longer, for example in their own file, reduces this gap.

By default, the lines go to standard output with the other proxy logs, including on Kubernetes.
On bare metal, setting the `KROXYLICIOUS_CONNECTION_LOG_FILE` environment variable writes them to that file instead, in the style of an nginx `access.log`.
This works like the existing `KROXYLICIOUS_LOG_FORMAT` setting of the proxy's default Log4j2 configuration.
Because the lines have their own logger, they can also be filtered or turned off without affecting other proxy logs.

Other details that identify a client only become known later in the connection.
The `sessionId` field links the connection log line to the proxy's later log lines for the same connection, such as the SASL identity logged when a SASL filter is configured.
The proxy does not currently log the Kafka client ID.
The documentation will explain how to trace a connection back to the application that made it.

This overlaps with the audit logging proposal ([design#85](https://github.com/kroxylicious/design/pull/85)), whose `ClientConnect` and `ServerConnect` actions cover the same events.
This proposal does not depend on it; the connection logging can be revised to fit audit logging when that lands.

## Future extensions

Once the project's minimum Java version provides `ExtendedSSLSession.getNamedGroup()`, the startup check can be removed and `unsupported` will no longer be reported.

## Testing

- Unit tests for the new metrics and the connection log line, for both TLS and plain-text connections.
- Integration tests that make TLS connections with known protocol and cipher suite settings on both sides, and check the reported metric values, labels and log fields.
- Named group tests check for `unsupported` on JDKs without the API, and for the negotiated group on JDKs that provide it.

## Affected/not affected projects

**Affected:**

- `kroxylicious` proxy runtime: the two new metrics, the connection log line, and the opt-in log file setting in the default Log4j2 configuration.
- Proxy documentation: the metrics reference, and how to find the clients behind a metric using the log line.

**Not affected:**

- The proxy configuration format.
- The Kubernetes Operator and its custom resources.
- The filter API.
- Existing metrics.

## Compatibility

The change is purely additive: two new metrics, one new log line, one new optional logging environment variable, no proxy configuration changes, and no change to existing metrics or labels.
The `tls_named_group` label is always present; its value is `unsupported` until the proxy runs on a JDK that provides the API and the named group is implemented.

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

### Logging connections at `DEBUG`

This would keep the default logs quieter.
It was rejected because long-lived connections would already have been established before an administrator raised the level, so the clients to upgrade would not appear.

### Logging only TLS connections

This would keep the log line focused on TLS.
It was rejected because connection logging should be consistent whether or not TLS is used.

### Writing a separate log file by default

Like an nginx `access.log`, this would keep connection lines apart from other logs.
It was rejected as a default because on Kubernetes there is no suitable filesystem to write to.
Bare-metal users can opt in to a separate file instead.

### Omitting `tls_named_group` when the JDK lacks the API

This would avoid a label whose value is `unsupported` on every runtime the project supports today.
It was rejected because a missing label shows up as an empty value in aggregations, and the metric's labels would then differ between JDKs; an explicit `unsupported` is clearer.

### Other ways to get the named group on Java 21

- **Read the group from the handshake bytes** (the ServerHello `key_share` in TLS 1.3, or the ServerKeyExchange in TLS 1.2): possible, but it adds TLS-parsing code the project must maintain, on the setup path of every TLS connection.
- **Reflection into JDK internals (`sun.security.ssl`):** needs `--add-opens` and may break with any JDK update.
- **JDK Flight Recorder (`jdk.TLSHandshake` event):** on JDK 21 the event has no named group field.
  JDK 28 adds one, but the event is off by default, cannot be linked to a gateway or virtual cluster, and is a diagnostics tool rather than a metrics source.
- **Switching to the OpenSSL TLS provider:** OpenSSL can report the group, but changing the proxy's TLS provider is far too large a change for a metrics feature.
