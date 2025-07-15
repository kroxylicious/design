
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
  For a given client and server pairing a proxy might have _two_ of these: the Kafka client's TLS client certificate, and the proxy's own TLS client certificate for its connection to the server.
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
* A **public credential**, such as a TLS certificate, need not be kept a secret.
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
     * @return The TLS context for the client connection, or empty if the client connection is not TLS.
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
     * @return the client's certificate, or empty if no TLS client certificate was presented during TLS handshake.
     */
    Optional<X509Certificate> clientCertificate();

}
```

Having a distinct type, `ClientTlsContext`, means we can easily expose the same information to future plugins that are not filters (and thus do not have access to a `FilterContext`).


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
     * Filters should use {@link #clientPrincipal()} in preference to this method, unless they require SASL-specific functionality.
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

    /**
     * The server identity that the proxy presented to the client using SASL authentication.
     * @return the proxy's identity with the client. This will be null
     * if the proxy did not supply an identity because the SASL mechanism used
     * does not support mutual authentication.
     */
    Optional<String> proxyServerId();
}
```

### APIs for using client principals in a generic way

Most `Filters` don't need to be opinionated about how the client is identified. They only need to know:

* that the client _is_ authenticated, somehow
* the name of the client's identity

We want to avoid making `Filter` developers pick a source of authentication information (`clientTlsContext()` or `clientSaslContext()`) in order to maximise the reusabilty of `Filter` implementations. 
For this purpose we will make use of `java.security.Principal` by providing the following method on `FilterContext`:

```java
    /**
     * <p>Returns the authenticated principal for the client connection.</p>
     * 
     * <p>The concrete type of principal returned depends on the proxy configuration.
     * For example,
     * it may be a {@link javax.security.auth.x500.X500Principal} if client identity is TLS-based,
     * or it may be a {@link SaslPrincipal} if client identity is SASL based.</p>
     *
     * <p>Callers should not:</p>
     * <ul>
     *   <li>assume any particular type of principal.
     *   <li>assume the principal does not change during the lifetime of a filter (due to reauthentication)
     * </ul>
     *
     * @return The authenticated principal for the client connection, or empty if the client
     * has not successfully authenticated.
     */
    Optional<? extends Principal> clientPrincipal();
```

The choice about what concrete type of `Principal` this method returns will be left to the person configuring the proxy.
They will do this using a new `principalType` property in the `VirtualCluster` configuration YAML.
This will support the values `X500` or `SASL`.
When configured with `X500`, the `Principal` returned by `FilterContext.clientPrincipal()` will be the `javax.security.auth.x500.X500Principal` from the client's `java.security.cert.X509Certificate`.
When configured with `SASL`, the `principal` returned by `FilterContext.clientPrincipal()` will be an instance of `SaslPrincipal`, defined as follows:

```java
package io.kroxylicious.proxy.authentication;

import java.security.Principal;
import java.util.Objects;

/**
 * A principal established using SASL.
 */
public record SaslPrincipal(String name) implements Principal {
    @Override
    public String getName() {
        return this.name;
    }
}
```

The `name` will be the `authorizationId` argument from the SASL Terminator or Inspector's call to `FilterContext.clientSaslAuthenticationSuccess()`.

### API for Filters to access server TLS information

So far we've only covered authentication on the _client-to-proxy connection_.
To cater for "client-side" proxy deployment topologies we must also consider authentication on the _proxy-to-server connection_.
Both TLS and SASL can provide for mutual authentication, so there may be a server identity which, logically a filter could make use of.

The API for exposing the proxy-to-broker TLS information to `Filters` is very similar to the client one. The following method will be added to `FilterContext`:

```java
    /**
     * @return The TLS context for the server connection, or empty if the server connection is not TLS.
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
     * @return the server's TLS certificate.
     */
    X509Certificate serverCertificate();
}
```

### APIs for Filters to produce server SASL information

A SASL Initiator will be able to use the follow methods on `FilterContext` to announce a successful, or failed, authentication with a Kafka server:

```java
    /**
     * Allows a filter
     * to announce a successful authentication outcome with the Kafka server to other plugins.
     * After calling this method the result of {@link #serverSaslContext()} will
     * be non-empty for this and other filters.
     * This method may be called multiple times over the lifetime of
     * a session if reauthentication is required.
     * TODO define the semantics around reauth
     * @param saslPrincipal The authenticated principal.
     */
    void serverSaslAuthenticationSuccess(String mechanism, String serverName);

    /**
     * Allows a filter
     * to announce a failed authentication outcome with the Kafka server.
     * @param exception An exception describing the authentication failure.
     */
    void serverSaslAuthenticationFailure(String mechanism, String serverName, Exception exception);
```

### APIs for Filters to consume server SASL information

```java
    /**
     * @return The SASL context for the server connection, or empty if the server
     * has not successfully authenticated using SASL.
     */
    Optional<ServerSaslContext> serverSaslContext();
```

Where:

```java
package io.kroxylicious.proxy.authentication;

import java.util.Optional;

import io.kroxylicious.proxy.filter.FilterContext;

/**
 * Exposes SASL authentication information to plugins, for example using {@link FilterContext#serverSaslContext()} ()}.
 * This is implemented by the runtime for use by plugins.
 */
public interface ServerSaslContext {

    /**
     * The name of the SASL mechanism used.
     * @return The name of the SASL mechanism used.
     */
    String mechanismName();

    /**
     * Returns the principal returned by the server.
     * @return the principal returned by the server,
     * or empty if the SASL mechanism used does not support mutual authentication.
     */
    String serverId();

}
```

### APIs for using server principals in a generic way

This works similarly to the client-facing equivalent:

```java
    /**
     * Returns the authenticated principal for the server connection, or empty if the server
     * has not successfully authenticated, or if the server authentication was not mutual.
     * The concrete type of principal returned depends on the proxy configuration.
     * For example,
     * it may be a {@link javax.security.auth.x500.X500Principal} if server identity is TLS-based,
     * or it may be a {@link SaslPrincipal} is client identity is SASL based.
     * @return The authenticated principal for the server connection, or empty if the server
     * has not successfully authenticated.
     */
    Optional<? extends Principal> serverPrincipal();
```


### API for selecting target cluster TLS credentials

The APIs presented so far are sufficient to write plugins which:

* Propagate SASL, letting a client's SASL identity reach the server unchanged
* Initiate SASL, injecting mechanism-specific credentials prior to letting client-originated requests reach the server. 
  The selection of the server-facing SASL credentials to use could be based on the client's identity 
  (e.g. SASL termination and SASL initiation in the same virtual cluster)

What's missing is an API where the server-facing TLS client certificate is chosen based on the client's identity. 
For this purpose we will add a new plugin interface, `ServerTlsCredentialSupplierFactory`.
It will use the usual Kroxylicious plugin mechanism, leveraging `java.util.Service`-based discovery.
However, this plugin is not the same thing as a `FilterFactory`.
Rather, an implementation class will be defined on the TargetCluster configuration object, and instantiated once for each target cluster.
The TargetCluster's `tls` object will gain a `tlsCredentialSupplier` property, supporting `type` and `config` properties (similarly to how filters are configured).
The interface itself is declared like this:

```java
package io.kroxylicious.proxy.tls;

/**
 * <p>A pluggable source of {@link ServerTlsCredentialSupplier} instances.</p>
 * <p>ServerTlsCredentialSupplierFactories are:</p>
 * <ul>
 * <li>{@linkplain java.util.ServiceLoader service} implementations provided by plugin authors</li>
 * <li>called by the proxy runtime to {@linkplain #create(Context, Object) create} instances</li>
 * </ul>
 * @param <C> The type of configuration.
 * @param <I> The type of initialization data.
 */
public interface ServerTlsCredentialSupplierFactory<C, I> {
    I initialize(Context context, C config) throws PluginConfigurationException;
    ServerTlsCredentialSupplier create(Context context, I initializationData);
    default void close(I initializationData) {
    }
}
```

`ServerTlsCredentialSupplierFactory` is following the convention established by `FilterFactory`, and the `Context` referenced above is similar to the `FilterFactoryContext`:

```java
    interface Context {

        /**
         * An executor backed by the single Thread responsible for dispatching
         * work to a ServerTlsCredentialSupplier instance for a channel.
         * It is safe to mutate ServerTlsCredentialSupplier members from this executor.
         * @return executor
         * @throws IllegalStateException if the factory is not bound to a channel yet.
         */
        ScheduledExecutorService filterDispatchExecutor();

        /**
         * Gets a plugin instance for the given plugin type and name
         * @param pluginClass The plugin type
         * @param instanceName The plugin instance name
         * @return The plugin instance
         * @param <P> The plugin manager type
         * @throws UnknownPluginInstanceException If the plugin could not be instantiated.
         */
        <P> P pluginInstance(Class<P> pluginClass,
                             String instanceName)
                throws UnknownPluginInstanceException;

         /**
          * Creates some TLS credentials for the given parameters.
          * @param key The key corresponding to the given client certificate.
          * @param certificateChain The client certificate corresponding to the given {@code key}, plus any intermediate certificates forming the certificate chain up to (but not including) the TLS certificate trusted by the peer.
          * @return The TLS credentials instance.
          * @see ServerTlsCredentialSupplier.Context#tlsCredentials(PrivateKey, Certificate[])
          */
         TlsCredentials tlsCredentials(PrivateKey key,
                                       Certificate[] certificateChain);
    }

```

So what is a `ServerTlsCredentialSupplier` that this factory creates?

```java
package io.kroxylicious.proxy.tls;

import java.security.PrivateKey;
import java.security.cert.Certificate;
import java.util.Optional;
import java.util.concurrent.CompletionStage;

import io.kroxylicious.proxy.authentication.ClientSaslContext;

/**
 * Implemented by a {@link io.kroxylicious.proxy.filter.Filter} that provides
 * the credentials for the TLS connection between the proxy and the Kafka server.
 */
public interface ServerTlsCredentialSupplier {
    /**
     * Return the TlsCredentials for the connection.
     * @param context The context.
     * @return the TlsCredentials for the connection.
     */
    CompletionStage<TlsCredentials> tlsCredentials(Context context);
}
```

Where the `Context` will be a inner interface:

```java
    /**
     * The context API for {@link ServerTlsCredentialSupplier}.
     * This is implemented by the runtime for use by plugins.
     */
    interface Context {
        Optional<ClientTlsContext> clientTlsContext();
        Optional<ClientSaslContext> clientSaslContext();

        /**
         * Returns the default credentials for this target cluster (e.g. from the proxy configuration file).
         * Implementations of {@link ServerTlsCredentialSupplier} may use this as a fall-back
         * or default, for example if the apply a certificiate-per-client-principal pattern
         * but are being used with an anonymous principal.
         * @return the default credentials.
         */
        TlsCredentials defaultTlsCredentials();

        /**
         * <p>Factory methods for creating TLS credentials for the given parameters.</p>
         *
         * <p>The equivalent method on {@code FilterFactoryContext} can be used when the credentials
         * are known at plugin configuration time.</p>
         *
         * @param key The key corresponding to the given client certificate.
         * @param certificateChain The client certificate corresponding to the given {@code key}, plus any intermediate certificates forming the certificate chain up to (but not including) the TLS certificate trusted by the peer.
         * @return The TLS credentials instance.
         * see io.kroxylicious.proxy.filter.ServerTlsCredentialSupplierFactory.Context#tlsCredentials(PrivateKey, Certificate[])
         */
        TlsCredentials tlsCredentials(Certificate certificate,
                                      PrivateKey key,
                                      Certificate[] intermediateCertificates);
    }
```

And `TlsCredentials` looks like this:

```java
package io.kroxylicious.proxy.authentication;

interface TlsCredentials {
  /* Intentionally empty: implemented and accessed only in the runtime */
}
```

// TODO Why not use the JDK's `X500PrivateCredential`?

### Protections for those configuring a virtual cluster

So far this proposal has provided a classification of `Filters` consuming the SASL Kafka protocol messages, and described Java APIs to be used by `Filter` developers producing or consumer authenticated identity information.
However, we also need to consider the task of constructing a working proxy (more specifically virtual cluster) from those building blocks.
We would like to make it a startup-time error to configure a virtual cluster in a way that cannot possibly work.
Examples of such illogical configurations include:

* Configuring a virtual cluster with `principalType: SASL` without a SASL terminator or SASL inspector in the virtual cluster's `filters` (because where is the SASL principal going to come from?)
* Configuring a virtual cluster with `principalType: X500` in a virtual cluster not configured for client mTLS (because where is the TLS principal going to come from?)
* Configuring multiple SASL terminators and/or SASL inspectors in the `filters` of a virtual cluster (because there should be a single producer of client identity). Similarly for SASL initiators (becausde there should be a single producer of server identity).

To provide this kind of fail-safe, the proxy runtime needs to know which filters are SASL inspectors, terminators or initiators, and what sort of identity information a filter consumes.
At proxy start up time, the runtime only knows about `FilterFactories`, not about any `Filter` instances or their types, 
The `FilterFactory` service interface doesn't provide a way for the runtime to know what kind of filters it may create.
Therefore we will introduce the following runtime-retained annotation types to be applied to `FilterFactory` implementations:

```java
/**
 * Annotation to be applied to `FilterFactory` implementations indicating that
 * the factory create filters that call {@link FilterContext#clientSaslAuthenticationSuccess()}.
 */
@interface ClientSaslProducer{}

/**
 * Annotation to be applied to `FilterFactory` implementations indicating that
 * the factory create filters that call {@link FilterContext#serverSaslAuthenticationSuccess()}.
 */
@interface ServerSaslProducer{}

/**
 * Annotation to be applied to `FilterFactory` implementations indicating that
 * the factory create filters the call {@link FilterContext#clientPrincipal()},
 * or {@link FilterContext#clientSaslContext()}.
 */
@interface ClientPrincipalConsumer{
    Class<? extends Principal>[] value();
}

/**
 * Annotation to be applied to `FilterFactory` implementations indicating that
 * the factory create filters the call {@link FilterContext#serverPrincipal()},
 * or {@link FilterContext#serverSaslContext()}.
 */
@interface ServerPrincipalConsumer{
    Class<? extends Principal>[] value();
}
```

|--------------------------------|-------------------------------------------------|----------------------------------------------------|
| `VirtualCluster.principalType` | FilterFactory annotation                        | Behaviour                                          |
|--------------------------------|-------------------------------------------------|----------------------------------------------------|
| none                           | `@ClientPrincipalConsumer(Principal.class)`     | Startup error                                      |
| none                           | `@ClientPrincipalConsumer(X500Principal.class)` | Startup error                                      |
| none                           | `@ClientPrincipalConsumer(SaslPrincipal.class)` | Startup error                                      |
| `X500`                         | `@ClientPrincipalConsumer(Principal.class)`     | All good (filter doesn't care about concrete type) |
| `X500`                         | `@ClientPrincipalConsumer(X500Principal.class)` | All good                                           |
| `X500`                         | `@ClientPrincipalConsumer(SaslPrincipal.class)` | Startup error                                      |
| `SASL`                         | `@ClientPrincipalConsumer(Principal.class)`     | All good (filter doesn't care about concrete type) |
| `SASL`                         | `@ClientPrincipalConsumer(X500Principal.class)` | Startup error                                      |
| `SASL`                         | `@ClientPrincipalConsumer(SaslPrincipal.class)` | All good                                           |
|--------------------------------|-------------------------------------------------|----------------------------------------------------|


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


## Rejected alternatives



# References

SASL was initially defined in [RFC 4422][RFC4422]. 
Apache Kafka has built-in support for a number of mechanisms.
Apache Kafka also supports plugging-in custom mechanisms on both the server and the client.

|---------------------|---------------------|--------------------------|
| Mechanism           | Definition          | Kafka implementation KIP |
|---------------------|---------------------|--------------------------|
| PLAIN               | [RFC 4616][RFC4616] | [KIP-42][KIP43]          |
| GSSAPI (Kerberos v5)| [RFC 4752][RFC4752] | [KIP-12][KIP12]          |
| SCRAM               | [RFC 5802][RFC5802] | [KIP-84][KIP84]          |
| OAUTHBEARER         | [RFC 6750][RFC6750] | [KIP-255][KIP255]        |
|---------------------|---------------------|--------------------------|

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


