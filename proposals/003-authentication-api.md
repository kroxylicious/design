
# Authentication APIs

This proposal describes a set of public APIs to expose client identity to plugin implementations.

## Terminology

Let's define some terminology to make discussion easier. For the purposes of this proposal we consider TLS and SASL as the only authentication mechanisms we care about.

Let's first define terms for TLS:

* A **mutual authentication mechanism** is one which proves the identity of a server to a client.
* When the proxy is configured to accept TLS connections from clients it is performing **TLS Termination**, which does not imply mutual authentication.
* A **TLS client certificate** is a TLS certificate for the client-side of a TLS Handshake. For a given client and server pairing a proxy might have _two_ of these the Kafka client's TLS client certificate, and the proxy's own TLS client certificate for its connection to the server.
* When the proxy configured to require TLS client certificates from clients and validates these against a set of trusted signing certificates (CA certificate) it is performing **client mutual TLS authentication** ("client mTLS").
* A **TLS server certificate** is a TLS certificate for the server-side of a TLS Handshake. As above, there could be two of these for a given connection through a proxy.
* When the proxy is configured to use a TLS client certificate when making a TLS connection to a server, we will use the term **server mutual TLS authentication_** ("server mTLS").

Now let's talk about SASL. In the following, the word "component" is generalising over filters, other plugins, and a proxy virtual cluster as a whole:

* a component which forwards a client's `SaslAuthenticate` requests to the server, and conveys the responses back to the client, is performing **SASL Passthrough**.
* SASL Passthrough is one way to for a proxy to be **identity preserving**, which means that, for all client principals in the virtual cluster, each of those principals will have the same name as the corresponding client principal in the broker.
* a component performing SASL Passthrough and looking at the requests and responses to infer the client's principal is performing **SASL Passthrough Sniffing**. Note that this technique does not work with all SASL mechanisms.
* a component that responds to a client's `SaslAuthenticate` requests _itself_, without forwarding those requests to the server, is performing **SASL Termination**.
* a component that injects its own `SaslAuthenticate` requests into a SASL exchange with the server, is performing **SASL Initiation**.

When _all_ the filters/plugins on the path between client and server a performing "SASL passthrough" then the virtual cluster as a whole is performing "SASL passthrough". Alternatively, if any filters/plugins on the path between client and server is performing "SASL Termination", then we might say that the virtual cluster as a whole is performing "SASL Termination".

It is possible for a proxy to be perform neither, one, or both, of SASL Termination and SASL Initiation.

Finally, let's define some ideas that from JAAS:

* A **subject** represents a participant in the protcol (a client or server).
* A **principal** identifies a subject. A subject may have zero or more principals. 
Subjects that haven't authenticated will have no principals.
A subject gains a principal following a successful TLS handshake.
A a subject also gains a principal following a successful `SaslAuthenticate` exchange.
* A **credential** is information used to prove the authenticity of a principal.
* A **public credential**, such as a TLS certificate, need not be kept a secret.
* A **private credential**, such as a TLS private key or a password, must be kept secret, otherwise the authenticity of a principal is compromised.

## Current situation

The `Filter` and `FilterContext` APIs currently don't directly expose any authenticated client identity information.
Specifically:

* If proxy uses client mTLS, then filters don't have access to a `Subject` or `Principal` corresponding to the client's TLS client certificate.
* If clients are authenticating using SASL, the only way a `Filter` can know about that is by intercepting those frames.
    - identity-using filters in the chain must _each_ implement SASL passthrough sniffing. 
    - but this is usually incompatible with use of a filter performing SASL Termination or SASL Initiation.

## Motivation

The lack of API support makes implementing client identity aware plugins difficult, or impossible.

Goals: 

* Allow the possibility for new KRPC intercepting plugins in the future by not assuming that `Filters` are the kind of KRPC intercepting plugin. We'll use the term **plugin**, unless saying something specifically about `Filters`.
* Enable plugins to access a client's identity using a single, consistent API, irrespective of which authentication mechanism(s) are being used, TLS or SASL, and whether they're implemented by the proxy runtime (in the TLS case), or a prior plugin in the chain (in the SASL termination case).
* Don't require a plugin to handle `SaslAuthenticate` unless it is performing SASL termination or initiation.
* Provide a flexible API to make serving niche use cases possible (though perhaps not simple).
* Drop support for the "raw" (i.e. not encapsulated within the Kafka protocol) support for SASL, as [Kafka itself has does from Kafka 4.0](https://cwiki.apache.org/confluence/display/KAFKA/KIP-896%3A+Remove+old+client+protocol+API+versions+in+Kafka+4.0)

Non-goals:

* Defining an API for exposing the identity of a _broker_ to plugins (in cases where the proxy mututally authenticates the broker).

## Proposal

### Proposed API for learning about client authentication outcomes

Plugin implementations require an API through which to learn about client authentication outcomes.

For this purpose we will add the following new interface to the new package `io.kroxylicious.proxy.authentication` in the `kroxylicious-api` module:

```java
package io.kroxylicious.proxy.authentication;

import javax.security.auth.Subject;
import javax.security.auth.login.LoginException;

// Allows a plugin to opt-in to being aware of client-facing authentication outcomes
interface ClientSubjectAware {
    
    /**
     * Called when a client authenticates, or reauthenticates, with the proxy.
     */
    void onClientAuthentication(Subject clientSubject, ClientAuthenticationContext context);
    
    /**
     * Called when a client fails authentication, or reauthentication, with the proxy.
     */
    default void onClientAuthenticationFailure(LoginException exception, ClientAuthenticationContext context) { 
    }
}
```

This interface may be implemented by `Filters` to learn about client authentication outcomes.
In the case of client mTLS the runtime will populate the `Subject` with a `X500Principal` corresponding to the TLS client certificate.

The `ClientAuthenticationContext` is implemented by the runtime and may be used by the `ClientSubjectAware` implementation to query information available at that point in time.

```java
package io.kroxylicious.proxy.authentication;

public interface ClientAuthenticationContext {

    /** 
     * The subject that the proxy presented to the client.
     * This may be null of the authentication mechanism does not support 
     * mutual authentication.
     */
    Subject proxySubject();
}
```


### Example: An identity-consuming `Filter`

This shows a filter implementing `ClientSubjectAware` and using the `clientSubject` to drive an authorization decision.

```java
    public class ExampleIdentityConsumingFilter implements ProduceRequestFilter, ClientSubjectAware {
    
        private Subject clientSubject;

        public void onClientAuthentication(Subject clientSubject, ClientAuthenticationContext context) {
            // Store the subject for use later
            this.clientSubject = clientSubject;
        }

        @Override
        public CompletionStage<RequestFilterResult> onProduceRequest(short apiVersion, RequestHeaderData header, ProduceRequestData request, FilterContext context) {
            if (clientSubject == null) {
                return ...; // return an error reponse, e.g. Errors.SASL_AUTHENTICATION_FAILED, or Errors.UNKNOWN_SERVER_ERROR
            }
            else if (authorized(clientSubject)) {
                return ...; // do something and forward the request
            }
            else {
                return ...; // return an error reponse: Errors.TOPIC_AUTHORIZATION_FAILED
            }
        }

        private static boolean authorized(Subject clientSubject) {
            // TODO this is not abstracted from the type of Principal
            //   We really want a model like Kafka's org.apache.kafka.server.authorizer.Authorizer
            //   See org.apache.kafka.server.authorizer.AuthorizableRequestContext for what gets exposed to Authorizer.
            //   I guess this is why KafkaPrincipal#principalType exists
            //   so that authorizers can just query without knowing about disparate types
            return clientSubject.getPrincipals().contains(new X500Principal("dn=admin,org=whatever"));
        }
    }
```


Note a common authorization API is not in scope of this proposal.

The choice of `Principal` implementations is left open. In particular a plugin could, but doesn't have to, add a `KafkaPrincipal` to the subject. 
Likewise a plugin could, but doesn't have to, make use of JDK-defined Principals like `javax.security.auth.x500.X500Principal`, or
  `javax.security.auth.kerberos.KerberosPrincipal`. 
It should be noted that plugins that add principals and plugins that query principals (including making authorization decisions) need to use common principal types. 
It is therefore recommended that plugins use `KafkaPrincipal`. **TODO: Really? Why not just define our own ProxyPrincipal(type, name) and be done with it?**

Audit logging clients is another use case for this API, in addition to this authorization example.


### Proposed API for announcing client authentication outcomes

The existing `SaslAuthenticateRequestFilter` and `SaslAuthenticateResponseFilter` continue to provide the mechanism for protocol-level 
interaction with clients and server. 
However, such SASL terminating plugins require an API through which to anounce their authentication outcomes to filters.

For this purpose we will add the following two methods to the existing `FilterContext` interface in the `io.kroxylicious.proxy.filter` package.

```java
package io.kroxylicious.proxy.filter;

public interface FilterContext {

    // ... existing methods ...

   
    /**
     * Allows a filter (typically one which implements {@link SaslAuthenticateRequestFilter})
     * to announce a successful authentication outcome to subsequent plugins.
     * @param subject The authenticated subject.
     */
    void clientAuthenticationSuccess(Subject subject);

    /**
     * Allows a filter (typically one which implements {@link SaslAuthenticateRequestFilter})
     * to announce a failed authentication outcome to subsequent plugins.
     * @param exception An exception describing the authentication failure. 
     */
    void clientAuthenticationFailure(LoginException exception);
    
}
```

It's worth noting that `LoginException` has a number of subclasses in `javax.security.auth.login`.

This API allows SASL-terminating plugin to announce its authentication outcomes to later filters in the filter chain which have implemented `ClientSubjectAware`.
Note that client authentication outcomes only propagate towards the server, not back towards the client. 
So a `ClientSubjectAware` before a SASL-terminating plugin will not receive the announcement.
**TODO justify this**


### Example: A SASL Terminating `Filter`

This shows how a SASL terminating `Filter` would use the new methods on `FilterContext` to inform other filters, such as `ExampleIdentityConsumingFilter` above, about the client.

The proxy config would look like this:

```yaml
virtualClusters:
  - name: my-cluster
    filters:
      - my_authn_filter
      - my_authz_filter
filterDefinitions:
   - name: my_authn_filter
     type: ExampleSaslTerminatingFilter
     config:
       jaasConfigFile: client-jaas.login.config
       jaasContextName: client_auth_stack
   - name: my_authz_filter
     type: ExampleIdentityConsumingFilter
     config: ...
```

where the `client-jaaas.login.config` file might look like this:

```
client_auth_stack {
  org.apache.kafka.common.security.plain.PlainLoginModule required
     user_alice="pa55word"
     user_bob="changeit"
     ;
};
```

The implementation would look something like this:

```java
public class ExampleSaslTerminatingFilter implements SaslAuthenticateRequestFilter, ClientSubjectAware {

    private Subject subject;

    @Override
    public void onClientAuthentication(Subject clientSubject, FilterContext context) {
        // the clientSubject will have an X500Principal iff the client used mTLS.
        this.subject = clientSubject;
    }

    @Override
    public CompletionStage<RequestFilterResult> onSaslAuthenticateRequest(short apiVersion,
                                                                   RequestHeaderData header,
                                                                   SaslAuthenticateRequestData request,
                                                                   FilterContext context) {
        Configuration config = new ConfigFile(URI.create("client-jaas.login.config"));

        // TODO the callback handler to use depends on the context in the jaas config
        //   so how do we know which handler to instantiate?
        //   Kafka's SaslChannelBuilder basically does its own parsing of the jaas configuration to figure it out.
        CallbackHandler callbackHandler = new PlainServerCallbackHandler();

        try {
            // Note: In general these methods are not guaranteed to be non-blocking, so 
            // use of ThreadPoolExecutor is recommended unless an implementor knows 
            // from other means that blocking is impossible.
            LoginContext loginContext = new LoginContext("client_auth_stack", subject, callbackHandler, config);
            loginContext.login();
            
            // here we propagate the subject along the pipeline
            // using the new clientAuthentication() method which
            // broadcasts the subject to all plugins in the upstream direction
            context.clientAuthenticationSuccess(loginContext.getSubject());
            return ...; // return a success response to the client
        }
        catch (LoginException e) {
            // here we propagate the failure along the pipeline
            // using the new clientAuthenticationFailure() method which
            // broadcasts some represnetation of the error
            // to all plugins in the upstream direction
            context.clientAuthenticationFailure(e);
            return ...; // return an error response to the client
        }
    }
}
```

By implementing `ClientSubjectAware` and reusing the `clientSubject`, we're adding a principal to any existing `X500Principal` of the subject.


### Proposed API for selecting TLS client certificates for server connections

Initiating a connection to a broker is currently entirely the responsilibity of the runtime, using the `NetFilter` interface. 
(note that `NetFilter` is **not** part of the `kroxylicious-api` module.)
This means that the TLS client certificate used is currently always the same, and cannot depend on the client subject.
Adding this new API will allow TLS client certificates for conections to servers to depend on client identity (as learned about using `ClientSubjectAware`).

```java
package io.kroxylicious.proxy.authentication;

interface ServerTlsClientCertificateSupplier {

  TlsCredentials tlsCredentials(ServerCredentialContext context);

}
```

where

```java
package io.kroxylicious.proxy.authentication;

interface TlsCredentials {
  /* Intentionally empty: implemented and accessed only in the runtime */
}

interface ServerCredentialContext {
  /** The default key for this target cluster (e.g. from the proxy configuration file). */
  TlsCredentials defaultTlsCredentials();
  /** Factory for TlsCredentials */
  TlsCredentials tlsCredentials(Certificate certificate, PrivateKey key, Certificate[] intermediateCertificates);
}
```

and adding the following to allow a filter factory to generate `TlsCredentials` at initialization time so as to take work off the hotter path on which `ServerTlsClientCertificateSupplier.tlsCredentials()` is invoked:

```java

public interface FilterFactoryContext {

  // ... existing methods ...

  TlsCredentials tlsCredentials(Certificate certificate, PrivateKey key, Certificate[] intermediateCertificates);
}
```

It is not proposed to allow dynamic selection of a set of trust anchors.
Those should remain under the control of the person configuring the proxy.


#### An Example: TLS-to-TLS identity mapping

This shows how a plugin could choose a TLS client certificate for the broker connection, based on the connected Kafka client's TLS identity.

```java

class ExampleMTlsFilter implements ClientSubjectAware, ServerCredentialSupplier {

    private Map<X500Principal, TlsCredentials> certs;
    
    ExampleMTlsFilter(Map<X500Principal, TlsCredentials> certs) {
          this.certs = certs;
    }

    private Subject clientSubject;

    public void onClientAuthentication(Subject clientSubject, ClientAuthenticationContext context) {
        // Store the subject for use later
        this.clientSubject = clientSubject;
    }

    TlsCredentials certificate(ServerCredentialContext context) {
	if (this.clientSubject == null) {
	    throw new IllegalStateException();
	}
	return certs.getOrDefault(
	    this.clientSubject.getPrincipal(X500Principal.class),
            context.defaultTlsCredentials());
    }
}

class ExampleMTlsFilterFactory implements FilterFactory<, Map<X500Principal, TlsCredentials>> {
    Map<X500Principal, TlsCredentials> certs;
    public Map<X500Principal, TlsCredentials> initialize(FilterFactoryContext context, C config) {
      certs = context.tlsCredentials(...)
    }
    
    ExampleMTlsFilter createFilter(FilterFactoryContext context, I initializationData) {
        return new ExampleMTlsFilter(certs)
    }

```

An almost identical class could be used with the `ExampleSaslTerminatingFilter` from the previous section for SASL-to-TLS identity mapping.

### Proposed API for learning about server authentication outcomes

This is the mirror image of `ClientSubjectAware`, but for cases where the broker is using mTLS and/or a SASL mechanism that supports mutual authentication.
It allows plugin behaviour to depend on the server's identity.

```java
package io.kroxylicious.proxy.authentication;

import javax.security.auth.Subject;
import javax.security.auth.login.LoginException;

// Allows a plugin to opt in to being aware of broker-facing authentication outcomes
interface ServerSubjectAware {
    
    /** 
     * Called when the proxy authenticates, or reauthenticates with a server
     * The given serverSubject may not have a principal for the server corresponding 
     * to the authentication mechanism used if that authentication mechanism does not provide
     * mutual authentication.
     */
    void onServerAuthentication(Subject serverSubject, ServerAuthenticationContext context);
    
    /**
     * Called when the proxy fails authentication, or reauthentication, with a server
     */
    default void onServerAuthenticationFailure(LoginException exception, ServerAuthenticationContext context) { 
    }
}
```

```java
package io.kroxylicious.proxy.authentication;

public interface ServerAuthenticationContext {

    /** 
     * The subject that the proxy presented to the server.
     */
    Subject proxySubject();
}
```

### Proposed API for initiating a SASL exchange with the broker 

There are two mutually exclusive cases to consider for SASL initiation:

1. That a SASL initiator plugin should perform SASL authentication _eagerly_, as soon as the underlying connection to the server is ready. 
This would be driven by the runtime following a successful TCP handshake on the client-to-proxy connection, and after `ClientSubjectAware` plugins have initially been called with any `X500Principal`, but before any SASL exchange on the client side.
2. That the SASL initiator plugin should perform SASL authentication _lazily_, as soon as a KRPC requests propagates along the chain to the initator plugin.
In this case the `ClientSubjectAware` plugins may have been called with a SASL principal.

Supporting the former case would allow the broker's principal (as obtained by a `ServerSubjectAware` implementing plugin) to be used in the client-facing SASL exchange. This could be relevant for Kafka clients which validated or made use of the authenticate server (in this case proxy) principal. However, we're not aware of any clients that actually do this, so we won't consider it further.

Supporting the latter case allows the proxy's server-facing SASL credentials to depend on the client-facing principal.
Because of variation in behaviour of client libraries there is not a single type of request which will always be the first. 
However,the existing `Sasl(Handshake|Authenticate)(Request|Response)Filter` interfaces can be used for the KRPC level implementation.
Such a filter implementation needs to keep some kind of `seenFirstRequest` state if it wants to use `FilterContent.sendRequest()` to insert its own initial requests prior to forwarding requests from the client.

What's missing is a way for the initiator plugin to inform other plugins of the outcome. For this purpose we will add the following two methods to the existing `FilterContext` interface in the `io.kroxylicious.proxy.filter` package.

```java
package io.kroxylicious.proxy.filter;

public interface FilterContext {

    // ... existing methods ...

   
    /**
     * Allows a filter (typically one which implements {@link SaslAuthenticateRequestFilter})
     * to announce a successful authentication outcome to subsequent plugins.
     * @param subject The authenticated subject.
     */
    void serverAuthenticationSuccess(Subject subject);

    /**
     * Allows a filter (typically one which implements {@link SaslAuthenticateRequestFilter})
     * to announce a failed authentication outcome to subsequent plugins.
     * @param exception An exception describing the authentication failure. 
     */
    void serverAuthenticationFailure(LoginException exception);
    
}
```

These are the mirror image of the equivalent client methods, and calling them would similarly result in `ServerSubjectAware`-implememting plugins getting informed of the server's subject.


### Use cases

* SASL-to-SASL identity mapping (in combination with a SASL terminator)
* SASL-to-SASL identity preservation with in-proxy authorization (in combination with a SASL terminator, and an authorizer).
* Audit logging


### Implementation

The preceeding section are intented to lay out a comprehensive API covering a variety of authentication use cases.
This is to encourage review of the proposal that considers all the possible use cases.
However, there is no requirement for them to be implemented in one go/within one release cycle.
Some of the proposed changes will require non-trival changes in the proxy runtime.

### Design choices

* Use JAAS because:
    - the Kafka broker and clients already use JAAS
        - we'd rather avoid adding a dependency on those not-publicly-supported Kafka classes in `kroxylicious-api` and `kroxylicious-runtime`, 
        - but we recognise that 3rd part Filter authors might want to make that choice
    - we have no appetite to build-out our own API, nor to pick up a dependency on a 3rd party framework
* Use `Subject` to convey identity information, rather than `Principal` because 
    - this is more sympathetic with the conceptual model of JAAS.
    - it allows attaching multiple `Principals` to client `Subjects`, and to be consumed by `ClientSubjectAware` instances (e.g. know the client TLS certificate DN _and_ the SASL SCRAM-SHA username).

## Affected/not affected projects

The `kroxylicous` repo.

## Compatibility

This change would be backwards compatible for Filter developers and proxy users (i.e. all existing proxy configurations files would still be valid).

## Future work

This proposal in combination with the proposal on a routing API, would enable client-subject based routing to backing clusters.

## Rejected alternatives

* Why not just add `public Principal clientPrincipal();` to `FilterContext`?
    - It doesn't support multiple principals.
* OK, so why not just add `public Subject clientSubject();` to `FilterContext`?
    - It makes the `Subject` a property of the connection/Netty channel. The public API presented here allows a `Filter` to change the `Principals` presented to subsequent `Filters` in the chain, enabling `Filters` to implement a wider variety of use cases.

