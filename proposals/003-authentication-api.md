
# Authentication API

This proposal describes a public API to expose client identity to `Filter` implementations.

## Current situation

The `Filter` and `FilterContext` APIs currently don't directly expose any authenticated client identity information.
Specifically:

* If clients are authenticating to the proxy using mTLS then filters don't have access to a `Subject` or `Principal` corresponding to the client TLS certificate.
* If clients are authenticating using the `SaslAuthenticate` KRPC the only way a `Filter` can know about that is by intercepting those frames.
    - For "SASL passthrough", a `Filter` implementation could try to _infer_ the client's identity by watching for a successful `SaslAuthenticateResponse` 
      returned by the broker. This is a technique that each identity-dependent filter in the chain could use, but each needs to reimplement the logic.
    - For "SASL termination", a `Filter` implementation could handle the `SaslAuthenticateRequest` frames itself 
        - If it makes its own `SaslAuthenticateRequests` (with different credentials, and/or a different mechanism) to the server then subsequent filters in the chain need to use the "SASL passthrough" technique to be aware of the broker-facing identity, and there's no way for them to know the original identity.
        - If it doesn't (so that there is no `SaslAuthenticate` intersection with the broker) then subsequent filters in the chain have no way of knowing the client's identity.

## Motivation

The lack of this API makes implementing client identity aware plugins difficult, or impossible.

Goals: 

* Enable `Filters` to access a client's identity using a single, consistent API, irrespective of what authentication mechanism is implemented, TLS or SASL, and whether it's implemented by the proxy runtime (in the TLS case), or a prior Filter in the chain (in the SASL termination case).
* Don't require a `Filter` to handle `SaslAuthenticate` unless it is performing SASL termination. 

Non-goals:

* Defining an API for exposing the identity of a _broker_ to `Filters` (in cases where the proxy mututally authenticates the broker).

## Proposal

### Public API changes

Add the following interface to the `kroxylicious-api` module to allow a `Filter` implementation to opt into consuming authentication outcomes:

```java
package io.kroxylicious.proxy.filter;

import javax.security.auth.Subject;
import javax.security.auth.login.LoginException;

// This is a new interface in the api module
interface ClientSubjectAwareFilter extends Filter {
    // Called when a client authenticates, or reauthenticates
    void onClientAuthentication(Subject clientSubject, FilterContext context);
    // Called when a client fails authentication, or reauthentication
    default void onClientAuthenticationFailure(LoginException exception, FilterContext context) { 
    }
}
```

Add the following two methods to `FilterContext` to allow SASL terminating `Filter` implementations to propagate their authentication outcomes to upstream filters:

```java
public interface FilterContext {

    void clientAuthenticationSuccess(Subject subject);

    void clientAuthenticationFailure(LoginException e);
    
}
```

### Runtime changes

1. Change the `kroxylicious-runtime` module so a `Subject` gets instantiated on initial connection.
2. On successful completion of a TLS handshake, associate a `javax.security.auth.x500.X500Principal` with that `Subject`.
3. On construction of the filter chain fire an internal message down the pipeline.
4. Change the `FilterHandler` and `FilterContext` to supply the subject from such a message to the `Filter` implementation.

### An example identity-consuming `Filter`

This section sketches how a Filter implementation would consume client identity:

```java
    public class ExampleIdentityConsumingFilter implements ProduceRequestFilter, ClientSubjectAwareFilter {
        private Subject subject;

        public void onClientAuthentication(Subject clientSubject, FilterContext context) {
            // Store the subject for use later
            this.subject = clientSubject;
        }

        @Override
        public CompletionStage<RequestFilterResult> onProduceRequest(short apiVersion, RequestHeaderData header, ProduceRequestData request, FilterContext context) {
            if (subject == null) {
                return null; // TODO return an error reponse, e.g. Errors.SASL_AUTHENTICATION_FAILED, or Errors.UNKNOWN_SERVER_ERROR
            }
            else if (authorized(subject)) {
                // TODO do something and forward the request
                return null;
            }
            else {
                return null; // TODO return an error reponse: Errors.TOPIC_AUTHORIZATION_FAILED
            }
        }

        private static boolean authorized(Subject subject) {
            // TODO this is not abstracted from the type of Principal
            //   We really want a model like Kafka's org.apache.kafka.server.authorizer.Authorizer
            //   See org.apache.kafka.server.authorizer.AuthorizableRequestContext for what gets exposed to Authorizer.
            //   I guess this is why KafkaPrincipal#principalType exists
            //   so that authorizers can just query without knowing about disparate types
            return subject.getPrincipals().contains(new X500Principal("dn=admin,org=whatever")) 
                || subject.getPrincipals().contains(new RolePrincipal("admin"));
        }
    }
```

Notes:

* The choice of `Principal` implementations is left open. In particular a `Filter` could, but doesn't have to, add a `KafkaPrincipal` to the subject. 
  Likewise a Filter could, but doesn't have to, make use of JDK-defined Principals like `javax.security.auth.x500.X500Principal`, 
  `javax.security.auth.kerberos.KerberosPrincipal`. It should be noted that `Filters` that add principals and `Filters` that query principals (including making authorization decisions) need to use common principal types. It is therefore recommended that `Filters` use `KafkaPrincipal`. 

### An example SASL Terminating `Filter `

This section sketches how a SASL terminating `Filter` might work.

The proxy config would look like this:

```yaml
virtualClusters:
  - name: my-cluster
    filters:
      - my_authn_filter
filterDefinitions:
   - name: my_authn_filter
     type: MyClientAuthnFilter
     config:
       jaasConfigFile: client-jaas.login.config
       jaasContextName: client_auth_stack
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
public class ExampleSaslTerminatingFilter implements SaslAuthenticateRequestFilter, ClientSubjectAwareFilter {
    private Subject subject;

    @Override
    public void onClientAuthentication(Subject clientSubject, FilterContext context) {
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
            LoginContext loginContext = new LoginContext("client_auth_stack", subject, callbackHandler, config);
            loginContext.login();
            // here we propagate the subject along the pipeline
            // using the new clientAuthentication() method which
            // broadcasts the subject to all plugins in the upstream direction
            context.clientAuthenticationSuccess(loginContext.getSubject());
            return null; // TODO return a success response to the client
        }
        catch (LoginException e) {
            // here we propagate the failure along the pipeline
            // using the new clientAuthenticationFailure() method which
            // broadcasts some represnetation of the error
            // to all plugins in the upstream direction
            context.clientAuthenticationFailure(e);
            return null; // TODO return an error response to the client
        }
    }
}
```

Notes:

* by implementing `ClientSubjectAwareFilter` and reusing the `clientSubject`, it's possible to add a username principal to any existing `X500Principal` added to the object by the runtime.
* `org.apache.kafka.common.security.plain.PlainLoginModule` (and probably other Kafka `LoginModule` implementations) don't work with how JASS `LoginModules` were originally designed to support stackable modules. For example it adds the `username` as a _credential_ of the `Subject`, rather than adding it as _principal_, and `login` is hard coded to return `true`.


### Design choices

* Use JAAS because:
    - the Kafka broker and clients already use JAAS
        - we'd rather avoid adding a dependency on those not-publicly-supportewd Kafka classes in kroxylicious-api and kroxylicious-runtime, but
        - we recognise that 3rd part Filter authors might want to make that choice
    - we have no appetite to build-out our own API, nor to pick up a dependency on a 3rd party framework
* Use `Subject` to convey identity information, rather than `Principal` because 
    - this is more sympathetic with the conceptpaul model of JAAS.
    - it allows attaching multiple `Principals` to client `Subjects`, and to be consumed by `ClientSubjectAwareFilter` (e.g. know the client TLS certificate DN _and_ the SASL SCRAM-SHA username).

## Affected/not affected projects

The `kroxylicous` repo.

## Compatibility

This change would be backwards compatible for Filter developers and proxy users (i.e. all existing proxy configurations files would still be valid).

## Rejected alternatives

* Why not just add `public Principal clientPrincipal();` to `FilterContext`?
    - It doesn't support multiple principals.
* OK, so why not just add `public Subject clientSubject();` to `FilterContext`?
    - It makes the `Subject` a property of the connection/Netty channel. The public API presented here allows a `Filter` to change the `Principals` presented to subsequent `Filters` in the chain, enabling Filters to implement use cases like impersonation.

