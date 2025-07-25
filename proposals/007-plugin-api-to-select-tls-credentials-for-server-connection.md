# Plugin API for selecting TLS client credentials for proxy-to-server connection

This proposal a new plugin API for allowing the selection of the TLS client credentials to be used for the connection between the proxy and a Kafka server.
It makes use of [proposal-004](proposal-004) for the terminology used.

## Current situation

Currently the end user configures the client TLS information to be used for connections between the proxy and a target cluster.
This means that the client TLS certificate used cannot depend on information known at runtime. 
This includes, in particular information about the client, such as the TLS client certificate that it provided to the proxy.

## Motivation

The lack of API support means all proxied clients have the same TLS identity from the broker's point of view. 
This means a broker using the `TLS` value for `security.protocol` cannot distinguish between those clients.

Goals: 

* Enable the selection of TLS client certificates at runtime.

## Proposal


### API for selecting target cluster TLS credentials

We will add a new plugin interface, `ServerTlsCredentialSupplierFactory`.
It will use the usual Kroxylicious plugin mechanism, leveraging `java.util.Service`-based discovery.
However, this plugin is not the same thing as a `FilterFactory`.
Rather, an implementation class will be defined on the `TargetCluster` configuration object, and instantiated once for each target cluster.
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

The `Context` is intentionally quite narrow in terms of the information it exposes to plugin implementations, but it is extensible in the future as use cases emerge for exposing more runtime information to implementations.

And `TlsCredentials` looks like this:

```java
package io.kroxylicious.proxy.authentication;

interface TlsCredentials {
  /* Intentionally empty: implemented and accessed only in the runtime */
}
```

// TODO Why not use the JDK's `X500PrivateCredential`?


## Affected/not affected projects

The `kroxylicous` repo.

## Compatibility

This change would be backwards compatible for `Filter` developers and proxy users (i.e. all existing proxy configurations files would still be valid).


