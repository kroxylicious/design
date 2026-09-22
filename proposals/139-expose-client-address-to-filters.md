# 139 - API to expose the client's address to Filters

Filters often need the client's network address — for authorization, audit logging, rate
limiting, or routing — but `FilterContext` has no accessor for it.

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
* **Routing** — selecting a route from the client's network or location.
* **Subject building** — including the client address in an authenticated subject.

When PROXY protocol is in use, "the client's address" is the header's source address, not the
load balancer's — which is exactly why the accessor must account for the header.

## Proposal

The client address is already decoded in the runtime before any Kafka handling, so this is
purely an API to expose it.

### 1. Three new accessors on `FilterContext`

Three methods are added to `FilterContext`:

```java
    /**
     * The client's address for this connection: the PROXY header's source address if
     * one was received, otherwise the immediate TCP peer (which, with no intermediary,
     * is the client itself).
     * @return the client's address
     */
    InetAddress clientAddress();

    /**
     * The immediate TCP peer's address for this connection. This is simply the remote
     * address of the client-facing connection; it does not distinguish whether that
     * peer is the actual client or an intermediary (e.g. a load balancer). For the
     * client's address prefer {@link #clientAddress()}.
     * @return the direct TCP peer address
     */
    InetAddress peerAddress();

    /**
     * The PROXY protocol (HAProxy) context for this connection.
     * @return the PROXY protocol context, or empty if no PROXY protocol header was received
     * on this connection (including when PROXY protocol support is disabled)
     */
    Optional<ClientHaProxyContext> clientHaProxyContext();
```

`clientAddress()` is what a filter reaches for by default: it is the client whether or not a
load balancer sits in front. `peerAddress()` and `clientHaProxyContext()` exist for the minority
of filters that must reason about the load balancer hop or read the full header (e.g. the
destination address the client connected to).

| Accessor                 | No PROXY header        | PROXY header received     |
|--------------------------|------------------------|---------------------------|
| `clientAddress()`        | client address         | header's source address   |
| `peerAddress()`          | = `clientAddress()`    | load balancer address     |
| `clientHaProxyContext()` | empty                  | present                   |

### 2. A new `ClientHaProxyContext` interface

`ClientHaProxyContext` is a new interface in a new package `io.kroxylicious.proxy.haproxy`,
mirroring `ClientTlsContext` and `ClientSaslContext` so the same data can later be offered to
non-filter plugins:

```java
package io.kroxylicious.proxy.haproxy;

import java.net.InetAddress;

public interface ClientHaProxyContext {
    /** The original client address reported by the header. */
    InetAddress sourceAddress();
    /** The original client port reported by the header. */
    int sourcePort();
    /** The destination address the client connected to. */
    InetAddress destinationAddress();
    /** The destination port the client connected to. */
    int destinationPort();
}
```

Two deliberate limits on the exposed data:

* **INET addresses only.** `TCP4`/`TCP6` headers populate the fields above. A non-INET family
  (`UNIX` sockets) or the `UNKNOWN` transport has no meaningful `InetAddress`, so
  `clientHaProxyContext()` returns empty and `clientAddress()` falls back to the peer
  address — as if no header had arrived.
* **No TLVs.** PROXY v2 TLV extensions stay internal. A raw `Map<String, byte[]>` keyed by TLV
  type is a poor public surface, no motivating use case needs it, and copying it per access
  would sit on the connection hot path. A structured TLV API can be proposed later if needed.

## Affected/not affected projects

Affected: the `kroxylicious` repo — `kroxylicious-api`, `kroxylicious-runtime`, and the filter
test-support modules that provide `FilterContext` test doubles.

Not affected: `kroxylicious-operator`, the KMS modules, and the authorizer API module (though a
future authorizer could consume `clientAddress()` through a filter).

## Compatibility

Purely additive: three new `FilterContext` methods and one new interface/package. No existing
configuration or API changes, and filters that ignore PROXY protocol are unaffected.

## Rejected alternatives

* **Reuse `clientAddress()` for the immediate TCP peer.** - The peer address is worth exposing in
  its own right (to reason about the network hop), so it gets a dedicated accessor named
  `peerAddress()`. Exposing it as `clientAddress()` would make the accessor whose name says
  "client" return a non-client address (the load balancer) in exactly the scenario this proposal
  exists for.
* **Name the client's address `clientSourceAddress()`.** - Once `peerAddress()` names the hop
  separately, there is no other address to distinguish the client's from, so the `source`
  qualifier adds nothing — the client's address is simply `clientAddress()`.
* **Expose TLVs as `Map<String, byte[]>`.** - see "No TLVs" above.
