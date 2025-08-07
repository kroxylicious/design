# Terminology for Authentication

This proposal defines terminology for describing authentication in the proxy. 
It doesn't propose any changes to any code. 
It is the first of a number of proposals which will use this terminology.

For the purposes of this proposal we consider TLS and SASL as the only authentication mechanisms we care about.
In the following, the word "component" is generalising over filters, other plugins, and a proxy virtual cluster as a whole.

## Definitions

### Mutual authentication

Usually 'authentication' is the process by which a client proves their identity to a server. A **mutual authentication mechanism** is one which proves the identity of each party to the other.

### TLS Termination

When the proxy is configured to accept TLS connections from clients it is performing **TLS Termination**, which does not imply mutual authentication. 
(For the avoidance of doubt, Kroxylicious does not support TLS passthrough; the alternative to TLS Termination is simply using TCP as the application transport).

### TLS client certificate

A **TLS client certificate** is a TLS certificate for the client-side of a TLS Handshake. 
  For a given client and server pairing, a proxy might have _two_ of these: the Kafka client's TLS client certificate, and the proxy's own TLS client certificate for its connection to the server.
  
### Client mutual TLS authentication
When the proxy is configured to require TLS client certificates from clients and validates these against a set of trusted signing certificates (CA certificate) it is performing **client mutual TLS authentication** ("client mTLS").

### TLS server certificate
A **TLS server certificate** is a TLS certificate for the server-side of a TLS Handshake. 
As above, there could be two of these for a given connection through a proxy.

### Server mutual TLS authentication

When the proxy is configured to use a TLS client certificate when making a TLS connection to a server, we will use the term **server mutual TLS authentication_** ("server mTLS").

### SASL Passthrough

A component which forwards a client's `SaslAuthenticate` requests to the server, and conveys the responses back to the client, is performing **SASL Passthrough**.

### SASL Passthrough Inspection

A component performing SASL Passthrough and looking at the requests and responses to infer the client's identity is performing **SASL Passthrough Inspection**. 
Note that this technique does not work with all SASL mechanisms. 
An example would be a mechanism which passes an opaque token issued by some authentication service that will be authenticated by the broker, but which cannot be introspected by the proxy.

### SASL Termination

a component that responds to a client's `SaslAuthenticate` requests _itself_, without forwarding those requests to the server, is performing **SASL Termination**.

### SASL Initiation

a component that injects its own `SaslAuthenticate` requests into a SASL exchange with the server is performing **SASL Initiation**.

## General remarks

When _all_ the filters/plugins on the path between client and server are performing "SASL passthrough" (or don't intercept SASL messages at all) then the virtual cluster as a whole is performing "SASL passthrough". 
Alternatively, if any filters/plugins on the path between client and server is performing "SASL Termination", then we might say that the virtual cluster as a whole is performing "SASL Termination".

It is possible for a proxy to be perform neither, one, or both, of SASL Termination and SASL Initiation.

<!--

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
-->

## Affected/not affected projects

None.

## Compatibility

None.

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


