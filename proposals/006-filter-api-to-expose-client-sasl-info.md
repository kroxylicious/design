# API to expose client SASL information to Filters

This proposal describes APIs for filters wishing to authenticate clients using SASL,
and/or consume the SASL identity extablished by other filters.
It makes use of [proposal-004](proposal-004) for the terminology used.

## Current situation

The `Filter` and `FilterContext` APIs currently don't directly expose any SASL information to filters.
Specifically, if clients are authenticating using SASL, the only way a `Filter` can know about that is by intercepting those frames.
* identity-using filters in the chain must _each_ implement SASL passthrough inspection. 
* but this is usually incompatible with use of a filter performing SASL Termination or SASL Initiation.

## Motivation

The lack of API support makes SASL aware plugins difficult, or impossible.

Goals: 

* Allow the possibility for new kinds of KRPC intercepting plugins in the future by not assuming that `Filters` are the only kind of KRPC intercepting plugin. We'll use the term **plugin**, unless saying something specifically about `Filters`.
* Allow access to SASL-specific details by plugins should they need them.
* Don't require a plugin to handle `SaslAuthenticate` request unless it is performing SASL termination or initiation.
* Drop support for the "raw" (i.e. not encapsulated within the Kafka protocol) support for SASL, as [Kafka itself has does from Kafka 4.0](https://cwiki.apache.org/confluence/display/KAFKA/KIP-896%3A+Remove+old+client+protocol+API+versions+in+Kafka+4.0)

## Proposal

### APIs for Filters to produce client SASL information

SASL (in contrast to TLS) is embedded in the Kafka protocol (the `SaslHandshake` and `SaslAuthentication` messages), and therefore can be handled by `Filter` implementations.
The goals require decoupling the production and consumption of SASL information by plugins.
Let's consider the production side first: SASL terminators and inspectors require a way of announcing the outcome of a SASL authentication.
For this purpose we will add the following methods to the existing `FilterContext` interface:

```java
    /**
     * Allows a filter (typically one which implements {@link SaslAuthenticateRequestFilter})
     * to announce a successful authentication outcome with the Kafka client to other plugins.
     * After calling this method the result of {@link #clientSaslContext()} will
     * be non-empty for this and other filters.
     * 
     * In order to support reauthentication, calls to this method and 
     * {@link #clientSaslAuthenticationFailure(String, String, Exception)}
     * may be arbitrarily interleaved during the lifetime of a given filter instance.
     *
     * This method can only be called by filters created from {@link FilterFactory FilterFactories} which 
     * have been annotated with {@link ClientSaslProducer @ClientSaslProducer}. 
     * Calls from filters where this is not the case will be logged but otherwise ignored.
     *
     * @param mechanism The SASL mechanism used.
     * @param authorizationId The authorization ID.
     */
    void clientSaslAuthenticationSuccess(String mechanism, String authorizationId);

    /**
     * Allows a filter (typically one which implements {@link SaslAuthenticateRequestFilter})
     * to announce a failed authentication outcome with the Kafka client.
     * It is the filter's responsilbity to return the right error response to a client, and/or disconnect.
     * 
     * In order to support reauthentication, calls to this method and 
     * {@link #clientSaslAuthenticationSuccess(String, String)}
     * may be arbitrarily interleaved during the lifetime of a given filter instance.
     *
     * This method can only be called by filters created from {@link FilterFactory FilterFactories} which 
     * have been annotated with {@link ClientSaslProducer @ClientSaslProducer}. 
     * Calls from filters where this is not the case will be logged but otherwise ignored.
     *
     * @param mechanism The SASL mechanism used, or null if this is not known.
     * @param authorizationId The authorization ID, or null if this is not known.
     * @param exception An exception describing the authentication failure.
     */
    void clientSaslAuthenticationFailure(String mechanism, String authorizationId, Exception exception);
```

Note that [RFC 4422][RFC4422] defines the "authorization identity" as one of pieces of information transferred via the challenges and responses defined by a mechanism. 
In SASL this need not be the same thing as a client's username or other identity, though it usually is in Apache Kafka's use of SASL.
We're sticking with the SASL terminology in this part of the API.

### APIs for Filters to consume client SASL information

Some filters, such as audit loggers, may need to use SASL authentication information specifically.
For such filters we will add the following methods to `FilterContext`:

```java
    /**
     * Returns the SASL context for the client connection, or empty if the client
     * has not successfully authenticated using SASL.
     * @return The SASL context for the client connection, or empty if the client
     * has not successfully authenticated using SASL.
     */
    Optional<ClientSaslContext> clientSaslContext();
```

Where

```java
package io.kroxylicious.proxy.authentication;

import java.util.Optional;

import io.kroxylicious.proxy.filter.FilterContext;

/**
 * Exposes SASL authentication information to plugins, for example using {@link FilterContext#clientSaslContext()}.
 * This is implemented by the runtime for use by plugins.
 */
public interface ClientSaslContext {

    /**
     * The name of the SASL mechanism used by the client.
     * @return The name of the SASL mechanism used by the client.
     */
    String mechanismName();

    /**
     * Returns the client's authorizationId that resulted from the SASL exchange.
     * @return the client's authorizationId.
     */
    String authorizationId();
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


# References

SASL was initially defined in [RFC 4422][RFC4422]. 
Apache Kafka has built-in support for a number of mechanisms.
Apache Kafka also supports plugging-in custom mechanisms on both the server and the client.

| Mechanism           | Definition          | Kafka implementation KIP |
|---------------------|---------------------|--------------------------|
| PLAIN               | [RFC 4616][RFC4616] | [KIP-43][KIP43]          |
| GSSAPI (Kerberos v5)| [RFC 4752][RFC4752] | [KIP-12][KIP12]          |
| SCRAM               | [RFC 5802][RFC5802] | [KIP-84][KIP84]          |
| OAUTHBEARER         | [RFC 6750][RFC6750] | [KIP-255][KIP255]        |

Note that the above list of KIPs is not exhaustive: Other KIPs have further refined some mechanisms, and defined reauthentication.

[RFC4422]:https://www.rfc-editor.org/rfc/rfc4422
[RFC4616]:https://www.rfc-editor.org/rfc/rfc4616
[RFC4752]:https://www.rfc-editor.org/rfc/rfc4752
[RFC5802]:https://www.rfc-editor.org/rfc/rfc5802
[RFC6750]:https://www.rfc-editor.org/rfc/rfc6750
[KIP12]:https://cwiki.apache.org/confluence/pages/viewpage.action?pageId=51809888
[KIP43]:https://cwiki.apache.org/confluence/display/KAFKA/KIP-43%3A+Kafka+SASL+enhancements
[KIP84]:https://cwiki.apache.org/confluence/display/KAFKA/KIP-84%3A+Support+SASL+SCRAM+mechanisms
[KIP255]:https://cwiki.apache.org/confluence/pages/viewpage.action?pageId=75968876


