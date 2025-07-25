
# Authentication APIs

This proposal describes a set of public APIs to expose client identity to plugin implementations.

## Terminology

Let's define some terminology to make discussion easier. 
For the purposes of this proposal we consider TLS and SASL as the only authentication mechanisms we care about.

Let's first define terms for TLS:

* A **mutual authentication mechanism** is one which proves the identity of a server to a client.
* When the proxy is configured to accept TLS connections from clients it is performing **TLS Termination**, which does not imply mutual authentication. 
  (For the avoidance of doubt, Kroxylicious does not support TLS passthrough; the alternative to TLS Termination is simply using TCP as the application transport).
* A **TLS client certificate** is a TLS certificate for the client-side of a TLS Handshake. 
  For a given client and server pairing, a proxy might have _two_ of these: the Kafka client's TLS client certificate, and the proxy's own TLS client certificate for its connection to the server.
* When the proxy is configured to require TLS client certificates from clients and validates these against a set of trusted signing certificates (CA certificate) it is performing **client mutual TLS authentication** ("client mTLS").
* A **TLS server certificate** is a TLS certificate for the server-side of a TLS Handshake. 
  As above, there could be two of these for a given connection through a proxy.
* When the proxy is configured to use a TLS client certificate when making a TLS connection to a server, we will use the term **server mutual TLS authentication_** ("server mTLS").

Now let's talk about SASL. In the following, the word "component" is generalising over filters, other plugins, and a proxy virtual cluster as a whole:

* a component which forwards a client's `SaslAuthenticate` requests to the server, and conveys the responses back to the client, is performing **SASL Passthrough**.
* SASL Passthrough is one way to for a proxy to be **identity preserving**, which means that, for all client principals in the virtual cluster, each of those principals will have the same name as the corresponding client principal in the broker.
* a component performing SASL Passthrough and looking at the requests and responses to infer the client's principal is performing **SASL Passthrough Inspection**. 
  Note that this technique does not work with all SASL mechanisms.
* a component that responds to a client's `SaslAuthenticate` requests _itself_, without forwarding those requests to the server, is performing **SASL Termination**.
* a component that injects its own `SaslAuthenticate` requests into a SASL exchange with the server is performing **SASL Initiation**.

When _all_ the filters/plugins on the path between client and server are performing "SASL passthrough" (or don't intercept SASL messages at all) then the virtual cluster as a whole is performing "SASL passthrough". 
Alternatively, if any filters/plugins on the path between client and server is performing "SASL Termination", then we might say that the virtual cluster as a whole is performing "SASL Termination".

It is possible for a proxy to be perform neither, one, or both, of SASL Termination and SASL Initiation.

Finally, let's define some concepts from JAAS:

* A **subject** represents a participant in the protcol (a client or server).
* A **principal** identifies a subject. 
  A subject may have zero or more principals. 
  Subjects that haven't authenticated will have no principals.
  A subject gains a principal following a successful TLS handshake.
  A subject also gains a principal following a successful `SaslAuthenticate` exchange.
* A **credential** is information used to prove the authenticity of a principal.
* A **public credential**, such as a TLS certificate, does not need not be kept secret.
* A **private credential**, such as a TLS private key or a password, must be kept secret, otherwise the authenticity of a principal is compromised.

## Current situation

The `Filter` and `FilterContext` APIs currently don't directly expose any authenticated client identity information.
Specifically:

* If proxy uses client mTLS, then filters don't have access to a `Subject` or `Principal` corresponding to the client's TLS client certificate.
* If clients are authenticating using SASL, the only way a `Filter` can know about that is by intercepting those frames.
    - identity-using filters in the chain must _each_ implement SASL passthrough inspection. 
    - but this is usually incompatible with use of a filter performing SASL Termination or SASL Initiation.

## Motivation

The lack of API support makes implementing client identity aware plugins difficult, or impossible.

Goals: 

* Allow the possibility for new kinds of KRPC intercepting plugins in the future by not assuming that `Filters` are the only kind of KRPC intercepting plugin. We'll use the term **plugin**, unless saying something specifically about `Filters`.
* Enable plugins to access a client's identity using a single, consistent API, irrespective of which authentication mechanism(s) are being used, TLS or SASL, and whether they're implemented by the proxy runtime (in the TLS case), or a prior plugin in the chain (in the SASL termination case).
* Allow access to TLS- or SASL-specific details by plugins should they need them.
* Don't require a plugin to handle `SaslAuthenticate` unless it is performing SASL termination or initiation.
* Provide a flexible API to make serving niche use cases possible (though perhaps not simple).
* Drop support for the "raw" (i.e. not encapsulated within the Kafka protocol) support for SASL, as [Kafka itself has does from Kafka 4.0](https://cwiki.apache.org/confluence/display/KAFKA/KIP-896%3A+Remove+old+client+protocol+API+versions+in+Kafka+4.0)

## Proposal

### API for Filters to access client TLS information

TLS (in contrast to SASL) is handled entirely by the proxy runtime. 
By the time a `Filter` is instantiated the proxy already has an established TLS connection.
All that's required is an API for exposing appropriate details to `Filters`.

The following method will be added to the existing `FilterContext` interface:

```java
    /**
     * @return The TLS context for the connection between the Kafka client and the proxy, 
     * or empty if the client connection is not TLS.
     */
    Optional<ClientTlsContext> clientTlsContext();
```

Where `ClientTlsContext` is a new interface in the new package `io.kroxylicious.proxy.tls`:

```
package io.kroxylicious.proxy.tls;

import java.security.cert.X509Certificate;
import java.util.Optional;

public interface ClientTlsContext {
    /**
     * @return The TLS server certificate that the proxy presented to the client during TLS handshake.
     */
    X509Certificate proxyServerCertificate();

    /**
     * @return the TLS client certificate was presented by the Kafka client to the proxy during TLS handshake, 
     * or empty if no TLS client certificate was presented.
     */
    Optional<X509Certificate> clientCertificate();

}
```

Having a distinct type, `ClientTlsContext`, means we can easily expose the same information to future plugins that are not filters (and thus do not have access to a `FilterContext`).


### API for Filters to access server TLS information

The API for exposing the proxy-to-broker TLS information to `Filters` is very similar to the client one. The following method will be added to `FilterContext`:

```java
    /**
     * @return The TLS context for the connection between the proxy and the Kafka server, 
     * or empty if the server connection is not TLS.
     */
    Optional<ServerTlsContext> serverTlsContext();
```

Where

```java
package io.kroxylicious.proxy.tls;

import java.security.cert.X509Certificate;
import java.util.Optional;

public interface ServerTlsContext {
    /**
     * @return The TLS server certificate that the proxy presented to the server during TLS handshake,
     * or empty if no TLS client certificate was presented during TLS handshake.
     */
    Optional<X509Certificate> proxyClientCertificate();

    /**
     * @return the TLS server certificate was presented by the Kafka server to the proxy during TLS handshake.
     */
    X509Certificate serverCertificate();
}
```

## Affected/not affected projects

The `kroxylicous` repo.

## Compatibility

This change would be backwards compatible for `Filter` developers and proxy users (i.e. all existing proxy configurations files would still be valid).


# Future work

* Implement a 1st party `SaslInspector` filter.
* Implement a 1st party `SaslTerminator` filter.
* Implement a 1st party `SaslInitiator` filter.
* A `PrincipalBuilder` API for customizing the concrete type of `Principal` exposed to `Filters` using `FilterContext.clientPrincipal()`
* A common authorization API.



