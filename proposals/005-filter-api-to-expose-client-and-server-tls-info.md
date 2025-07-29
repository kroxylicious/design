
# Authentication APIs

This proposal describes a set of public APIs to expose client identity to plugin implementations.
It makes use of [proposal-004](proposal-004) for the terminology used.


## Current situation

The `Filter` and `FilterContext` APIs currently don't directly expose any authenticated client identity information.
Specifically if clients are authenticating using SASL, the only way a `Filter` can know about that is by intercepting those frames.
* identity-using filters in the chain must _each_ implement SASL passthrough inspection. 
* but this is usually incompatible with use of a filter performing SASL Termination or SASL Initiation.

## Motivation

The lack of API support makes implementing client identity aware plugins difficult, or impossible.

Goals: 

* Allow the possibility for new kinds of KRPC intercepting plugins in the future by not assuming that `Filters` are the only kind of KRPC intercepting plugin. We'll use the term **plugin**, unless saying something specifically about `Filters`.
* Allow access to TLS-specific details by plugins should they need them.
* Provide a flexible API to make serving niche use cases possible (though perhaps not simple).

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


