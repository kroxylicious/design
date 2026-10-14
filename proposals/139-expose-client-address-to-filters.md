# 139 - API to expose the client's address to Filters

Filters often need the client's network address — for authorization, audit logging, or rate
limiting — but `FilterContext` has no accessor for it.

The purpose of this proposal is to allow the filter to obtain client address information:
the direct peer address when the client connects directly, and the original client address
carried in the PROXY protocol header when a load balancer that speaks the PROXY protocol sits
in front.

## Current situation

Two gaps leave the client's address out of reach of filters:

1. **No accessor for the peer address.** `FilterContext` exposes no way for a filter to read the
   address of the connection at all — not even the immediate TCP peer.
2. **The decoded PROXY header is stored but never exposed.** When PROXY protocol is in use
   (`proxyProtocol` mode `required` or `allowed`), the proxy already detects and decodes the
   header on the incoming connection and stores the source/destination address, port, and any
   TLV extensions in an internal `haProxyContext`. But no API surfaces it, so outside the
   runtime's own tests the decoded data is discarded.

## Motivation

Filters need the client's address for:

* **Authorization** — controlling access by the client's address.
* **Audit logging** — recording the real client IP for compliance.
* **Rate limiting** — throttling requests per client address.
* **Subject building** — including the client address in the `Subject` built by an authenticating filter.

When PROXY protocol is in use, "the client's address" is the header's source address, not the
load balancer's — which is exactly why the accessor must account for the header.

## Proposal

The client address is already decoded in the runtime before any Kafka handling, so this is
purely an API to expose it.

### 1. Three new accessors on `FilterContext`

Three methods are added to `FilterContext`:

```java
    /**
     * The client's address for this connection: the source address from a supported PROXY protocol
     * header, otherwise the immediate transport peer (which, with no intermediary, is the client
     * itself).
     * <p>
     * For the TCP connections currently supported by Kroxylicious, the returned value is an
     * {@link java.net.InetSocketAddress}, including the IP address and port.
     * <p>
     * The value is stable for the life of the connection, so a filter may cache it.
     * <p>
     * <strong>This address is not authenticated by Kroxylicious.</strong> When it is derived from a
     * PROXY protocol header (see {@link #clientProxyProtocolContext()}), an untrusted client can forge
     * it if it can connect directly to the listener and send a syntactically valid header. Rely on the
     * address for authorization or audit decisions only when the immediate peer is a trusted PROXY
     * protocol sender and untrusted clients cannot reach the listener directly.
     * <p>
     * <strong>Do not call {@code getHostName()} or {@code getCanonicalHostName()}</strong> on the
     * returned address (or on its {@link java.net.InetAddress}): for a literal IP either may trigger a
     * blocking reverse-DNS lookup on the event-loop thread, which filters must never do. Read the IP via
     * {@link java.net.InetSocketAddress#getAddress()} and the port via
     * {@link java.net.InetSocketAddress#getPort()}; when a string is needed, use
     * {@link java.net.InetSocketAddress#getHostString()} or {@link java.net.InetAddress#getHostAddress()}
     * (the safe equivalents of {@code getHostName()}).
     * @return the client's address
     */
    SocketAddress clientAddress();

    /**
     * The immediate transport peer's address for this connection. This is simply the remote
     * address of the client-facing connection; it does not distinguish whether that
     * peer is the actual client or an intermediary (e.g. a load balancer). For the
     * client's address prefer {@link #clientAddress()}.
     * <p>
     * For the TCP connections currently supported by Kroxylicious, the returned value is an
     * {@link java.net.InetSocketAddress}, including the IP address and port. The value is cacheable
     * for the life of the connection, and the {@code getHostName()} caveat on {@link #clientAddress()}
     * applies to this address too.
     * @return the immediate transport peer's address
     */
    SocketAddress peerAddress();

    /**
     * The PROXY protocol context for this connection. When present,
     * {@link ClientProxyProtocolContext#sourceAddress()} is the value returned by {@link #clientAddress()}.
     * @return the PROXY protocol context when a PROXY command carrying a TCP4 or TCP6 proxied protocol
     * was received; otherwise empty (including when PROXY protocol support is disabled)
     */
    Optional<ClientProxyProtocolContext> clientProxyProtocolContext();
```

`clientAddress()` is what a filter reaches for by default: it is the client whether or not a
load balancer sits in front. `peerAddress()` and `clientProxyProtocolContext()` exist for the minority
of filters that must reason about the load balancer hop or read the full header (e.g. the
destination address the client connected to).

| Accessor                       | No usable PROXY header | PROXY header (TCP4/TCP6)                |
|--------------------------------|------------------------|-----------------------------------------|
| `clientAddress()`              | client address         | header's source address                 |
| `peerAddress()`                | = `clientAddress()`    | immediate peer (e.g. the load balancer) |
| `clientProxyProtocolContext()` | empty                  | present                                 |

"No usable PROXY header" means no header at all, or a `LOCAL` / `UNKNOWN` / `UDP` / `UNIX` header.

### 2. A new `ClientProxyProtocolContext` interface

`ClientProxyProtocolContext` is a new interface in a new package
`io.kroxylicious.proxy.proxyprotocol`, mirroring `ClientTlsContext` and `ClientSaslContext` so
the same data can later be offered to non-filter plugins:

```java
package io.kroxylicious.proxy.proxyprotocol;

import java.net.SocketAddress;

public interface ClientProxyProtocolContext {
    /**
     * The original client (source) address reported by a TCP4 or TCP6 PROXY protocol header. The
     * returned {@link java.net.InetSocketAddress} includes the IP address and port. The
     * {@code getHostName()} caveat on {@link FilterContext#clientAddress()} applies to this address too.
     * <p>
     * <strong>This is an unauthenticated value claimed by the immediate peer.</strong> Kroxylicious
     * does not verify that it reflects the true origin of the connection; it is trustworthy only when
     * the immediate peer is a trusted PROXY protocol sender and untrusted clients cannot reach the
     * listener directly. See {@link FilterContext#clientAddress()} for the full trust discussion.
     * @return the original client source address
     */
    SocketAddress sourceAddress();

    /**
     * The destination address the client connected to, as reported by a TCP4 or TCP6 PROXY protocol
     * header. The returned {@link java.net.InetSocketAddress} includes the IP address and port. The
     * {@code getHostName()} caveat on {@link FilterContext#clientAddress()} applies to this address too.
     * @return the destination address
     */
    SocketAddress destinationAddress();
}
```

Notes on the exposed data:

* **Address families.** A `PROXY` command carrying `TCP4` or `TCP6` is exposed as an
  `InetSocketAddress`, with source and destination exposed together or not at all, so a present
  `ClientProxyProtocolContext` always contains a complete, non-null pair. The other proxied protocols
  are not exposed:
    * `UNIX_STREAM` is a stream transport, out of scope here but a candidate for future exposure as a
      `UnixDomainSocketAddress` (see [Future work](#future-work)) — which is why the accessors return `SocketAddress`.
    * `UDP4`, `UDP6`, and `UNIX_DGRAM` are datagram transports; Kafka is stream-based and never uses them.
    * `UNKNOWN` leaves the proxied protocol unspecified, so there is no usable address.

  A `LOCAL` command (a locally established, non-proxied connection such as a health check) is also not
  exposed. Whenever nothing is exposed, `clientProxyProtocolContext()` is empty and `clientAddress()`
  falls back to the immediate transport peer.
* **No TLVs.** PROXY v2 TLV extensions stay internal. A raw `Map<String, byte[]>` keyed by TLV
  type is a poor public surface, no motivating use case needs it, and copying it per access
  would sit on the connection hot path. A structured TLV API can be proposed later if needed.

## Security considerations

`clientAddress()` is connection metadata, not an authenticated client identity.

Without PROXY protocol, it returns the immediate transport peer reported by the
operating system. With PROXY protocol, it returns the source address claimed by the
header, which Kroxylicious does not verify: an untrusted client that can connect
directly to the listener and send a syntactically valid PROXY header can forge it.
This holds in both `allowed` and `required` modes — `required` only rejects
connections that carry no header, not forged ones.

Filters should use `clientAddress()` for authorization or auditing only when the
immediate peer is a trusted PROXY protocol sender and untrusted clients cannot reach
the listener directly. Otherwise, treat it as untrusted metadata and use
`peerAddress()` when the immediate peer's address is needed.

## Affected/not affected projects

Affected: the `kroxylicious` repo — `kroxylicious-api`, `kroxylicious-runtime`, `kroxylicious-docs`
(a note on the client-address trust boundary in the PROXY protocol documentation), and every in-repo
`FilterContext` implementation, updated in lock-step: `kroxylicious-filter-test-support`,
`kroxylicious-microbenchmarks`, `kroxylicious-authorization`, and `kroxylicious-entity-isolation`.

Not affected: `kroxylicious-operator`, the KMS modules, and `kroxylicious-authorizer-api` (an
`Authorizer` sees only the `Subject`, so it can use the client address only through a principal added
by a filter; see [Future work](#future-work)).

`RouterContext` parity is out of scope for this proposal; see [Future work](#future-work).

## Compatibility

There are no configuration or YAML changes. Filters that only *consume* a `FilterContext` — the
vast majority — are both source- and binary-compatible, need no changes, and may use the three new
accessors when needed.

The accessors are abstract methods on `FilterContext`, so the change is additive but
source-incompatible for the few types that *implement* the interface:

* **Code that implements `FilterContext` itself** (for example a hand-rolled test double) must add
  the three methods before it will recompile. A pre-existing binary that omits them would throw
  `AbstractMethodError` if the new methods were invoked on that implementation.
* The official `FilterContext` mock in `kroxylicious-filter-test-support` is updated in lock-step
  with the API, so downstream tests built on it need no changes.

A new `ClientProxyProtocolContext` interface and its `io.kroxylicious.proxy.proxyprotocol` package
are added; nothing existing is removed or has its signature changed.

## Rejected alternatives

* **Reuse `clientAddress()` for the immediate peer.** - The peer address is worth exposing in
  its own right (to reason about the network hop), so it gets a dedicated accessor named
  `peerAddress()`. Exposing it as `clientAddress()` would make the accessor whose name says
  "client" return a non-client address (the load balancer) in exactly the scenario this proposal
  exists for.
* **Name the client's address `clientSourceAddress()`.** - Once `peerAddress()` names the hop
  separately, there is no other address to distinguish the client's from, so the `source`
  qualifier adds nothing — the client's address is simply `clientAddress()`.
* **Expose TLVs as `Map<String, byte[]>`.** - see "No TLVs" above.
* **Address type.** - Three options were weighed; `SocketAddress` was chosen.
    * **`InetAddress`.** Directly usable when a filter only needs the client IP, but it drops the port
      and cannot carry a non-INET (Unix-domain) address.
    * **A Kroxylicious domain type.** Either a sealed `Address` (`permits Inet, Unix`) for exhaustive
      matching and explicit Unix modelling, or a hand-rolled `ipAddress()`/`port()` interface that hides
      the blocking `getHostName()` — a public type tree to design, document, and maintain.
    * **`SocketAddress` (chosen).** Both it and a domain type need one cast or accessor call to reach an
      `InetAddress`, so ergonomics do not decide it. `SocketAddress` wins because it is what Netty's
      `Channel.remoteAddress()` already returns (nothing to wrap), there is no type tree to maintain, and
      it already represents Unix-domain and test endpoints such as Netty's `EmbeddedSocketAddress`. The
      `getHostName()` footgun is handled by a Javadoc caveat (see [Future work](#future-work) for
      static enforcement).
    * **Residual cost.** A `default` branch in any exhaustive `switch` — not free, since it is either
      untested or bakes in the assumption that the value is always an `InetSocketAddress`. That
      assumption is made explicit in the Javadoc, and introducing any other subtype would be a contract
      change requiring its own proposal, so it is a documented invariant rather than a silent one.
* **Name the interface and package after HAProxy.** - The runtime decodes the header with Netty's
  HAProxy codec and the internal snapshot is `HaProxyContext`, so an HAProxy-based name would
  match the implementation. But the public type is named for the PROXY protocol
  (`ClientProxyProtocolContext`, package `io.kroxylicious.proxy.proxyprotocol`) because the
  protocol has many implementors and HAProxy is only one of them.
* **Group the connection accessors under a context object.** - Considered and deferred rather than
  rejected; see [Future work](#future-work) for the grouping discussion.

## Future work

These are intentionally out of scope here, each left to separate future work:

* **UNIX domain sockets.** A `PROXY` command carrying `UNIX_STREAM` could be exposed as a
  `java.net.UnixDomainSocketAddress`. It is omitted for now (Kafka connections are TCP), but the
  accessors already return `SocketAddress` so this can be added without changing any method signature
  (still a contract change, so it needs its own proposal).
* **`RouterContext` parity.** Routing plugins could also use the client address, for example to
  select a route from the client's network or location. They see the connection through
  `RouterContext` rather than `FilterContext`, so offering them the same metadata is a separate
  change.
* **Subject-builder context parity.** An `Authorizer` sees only the `Subject`, so the client address
  reaches it only as a principal. With this proposal only a filter that builds its own `Subject` can
  add one; the subject-builder plugins (used by the first-party SASL filters and transport
  authentication) cannot, because their `Context` does not expose the address. A next step would be to
  add it to `TransportSubjectBuilder.Context` and `SaslSubjectBuilder.Context`, populated by the
  default subject builder.
* **Grouping the connection accessors under a context object.** The three new accessors, with the
  existing `clientTlsContext()` and `clientSaslContext()`, could later sit behind one context object
  (e.g. a `DownstreamContext` or `ClientConnectionContext`) instead of flat methods on
  `FilterContext`. The flat shape is kept here because it matches how those existing accessors are
  already exposed; regrouping them is a focused refactor better done on its own, and would also make
  the `RouterContext` parity above cheaper to deliver.
* **Static enforcement of the blocking-call caveat.** The prohibition on `getHostName()` /
  `getCanonicalHostName()` is carried only by Javadoc today. A future ErrorProne or SpotBugs rule could
  flag these calls at build time, enforcing the caveat within Kroxylicious's own filter modules rather
  than leaving it a convention. It is build tooling rather than an API change, and would not reach
  third-party filters without a shipped mechanism of its own.
