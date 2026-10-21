# 000 - Configure the TLS subject builder through the Kubernetes Operator

When clients authenticate with TLS client certificates, the proxy needs rules for turning a certificate into a user identity.
The standalone proxy supports these rules, but the Kubernetes Operator gives users no way to set them.
This proposal adds an optional `tlsSubjectBuilder` field to the `VirtualKafkaCluster` custom resource, which the Operator passes to the proxy unchanged.

## Current situation

When a client connects, the proxy works out who it is.
This identity is called the *subject*, and the names inside it, such as a user name, are called *principals*.
Filters such as Authorization use the subject to decide what a client may do.

For clients that authenticate with SASL, the SASL filters build the subject from the login.

For clients that authenticate with a TLS client certificate, the proxy needs rules saying which part of the certificate becomes the user name.
These rules are called the *subject builder*.
In the standalone proxy, each virtual cluster can configure one:

```yaml
virtualClusters:
  - name: my-cluster
    # ...
    subjectBuilder:
      type: DefaultTransportSubjectBuilderService
      config:
        addPrincipals:
          - from: clientTlsSubject
            map:
              - replaceMatch: "/CN=([^,]+),.*/$1/"
              - else: anonymous
            principalFactory: UserFactory
```

With these rules, a client whose certificate subject is `CN=myapp,OU=dev,O=example` becomes the user `myapp`.

When the proxy runs under the Operator, users don't write this configuration themselves.
The Operator generates it from custom resources, and `VirtualKafkaCluster` has no field for a subject builder, so the Operator always leaves it unset.

## Motivation

Users who deploy with the Operator and authenticate clients with TLS certificates can't give those clients meaningful principals.
Without principals, Authorization rules can't refer to these clients, so this combination doesn't work today.
SASL users aren't affected.

This was reported in [kroxylicious#3032](https://github.com/kroxylicious/kroxylicious/issues/3032), and it's likely to come up more often as users combine the Operator with certificate-based authentication.

## Proposal

### API

Add an optional `tlsSubjectBuilder` field to the `VirtualKafkaCluster` spec.
It has two parts:

- `type` (required): the subject builder plugin to use.
- `config` (optional): that plugin's settings, accepted as-is.

The Operator copies the field, unchanged, into the `subjectBuilder` of the matching virtual cluster in the proxy configuration it generates.

```yaml
apiVersion: kroxylicious.io/v1alpha1
kind: VirtualKafkaCluster
metadata:
  name: my-cluster
spec:
  proxyRef:
    name: my-proxy
  targetKafkaServiceRef:
    name: my-kafka
  ingresses:
    - ingressRef:
        name: cluster-ip
      tls:
        certificateRef:
          name: server-cert
        trustAnchorRef:
          kind: ConfigMap
          name: client-ca
          key: ca.pem
        tlsClientAuthentication: REQUIRED
  tlsSubjectBuilder:
    type: DefaultTransportSubjectBuilderService
    config:
      addPrincipals:
        - from: clientTlsSubject
          map:
            - replaceMatch: "/CN=([^,]+),.*/$1/"
            - else: anonymous
          principalFactory: UserFactory
```

### Where the field lives

The field is set once per virtual cluster, directly in the `VirtualKafkaCluster` resource.
In the custom resource, TLS settings sit on each ingress, but the proxy applies one set of subject builder rules to every connection to a virtual cluster, so the field sits at the cluster level to match.
This needs no change to the proxy.
The rules are usually a few lines and belong to a single cluster.
Keeping them in the cluster resource gives users one place to read and change them, and a change to one cluster's rules can't affect another cluster's identities.

### Field shape and name

`type` and `config` mirror the proxy's own `subjectBuilder`, in the same way filter resources mirror the proxy's filter configuration.
Existing proxy documentation and examples apply directly, and custom subject builder plugins work without any change to the custom resource definition.

`config` holds the plugin's rules: which certificate field to read, how to turn it into a name, and what kind of principal to create.
The Operator passes it to the proxy exactly as written.

The field is named `tlsSubjectBuilder` to make clear it only applies to TLS client certificates, following the naming of the existing `tlsClientAuthentication` setting.

### Validation

As with filter configuration today, the Operator doesn't check the contents of `config`.
The proxy checks it at startup and refuses to start if it's invalid.
For the built-in subject builder, that includes unknown keys and badly formed rules.
So a mistake shows up as proxy pods failing to start, with the reason in the pod logs, rather than as a condition on the custom resource.
One proxy serves all the virtual clusters assigned to it, so a mistake in one cluster's rules stops the proxy for all of them.

### Behaviour

- If the field isn't set, nothing changes.
- If the ingress requires a certificate and the client doesn't send one, the connection is rejected.
- If a client presents no certificate, the client is anonymous.
  This happens when the ingress doesn't ask for a certificate, or when a certificate is optional and the client doesn't send one.
  The built-in authorizer denies anonymous clients by default.
- If SASL is also configured on the cluster, a successful SASL login replaces the certificate-based subject.
  A failed SASL login makes the client anonymous.

These are all existing proxy behaviours, and the Operator documentation will describe them.

## Out of scope

Sidecar mode, where a proxy is injected into each application pod, isn't covered.
The application talks to its sidecar in plain text over localhost, so there's never a client certificate to build a subject from.

## Future work

If the Operator validated plugin configuration itself, it could report mistakes as a condition on the custom resource, and one cluster's mistake would no longer stop the proxy for the others.
This applies equally to filter configuration, so it's better handled as a separate change covering all plugin configuration.

## Affected/not affected projects

**Affected:**

- `kroxylicious-kubernetes-api`: new optional field on the `VirtualKafkaCluster` custom resource definition.
- `kroxylicious-operator`: copies the field into the generated proxy configuration.
- Operator documentation: describes the field, how it maps to the proxy's subject builder, and the behaviour when no certificate is presented or SASL is also used.
- Operator examples: a TLS client certificate version of the existing authorization example.

**Not affected:**

- The proxy and its configuration format.
- Sidecar mode (the admission webhook).
- Filters and authorizer plugins.

## Compatibility

### Backwards compatibility

The field is optional and is added to the existing `v1alpha1` API.
Existing resources remain valid and behave exactly as before.

### Forwards compatibility

The field follows the proxy's current subject builder configuration.
If the proxy configuration format changes (see [design #96](https://github.com/kroxylicious/design/pull/96)), the Operator would translate this field into the new format, and the field itself would only change if the new format required it.

## Rejected alternatives

### A subject builder per ingress

This would allow different rules on each ingress of the same cluster.
The proxy supports only one subject builder per virtual cluster, so this would need changes to the proxy configuration as well.
No use case for it has come up.

### A separate, shared resource

The rules would live in a new custom resource, referenced by name from each `VirtualKafkaCluster`, in the same way filters are.
This would allow clusters to share rules, and Kubernetes permissions could protect the rules separately from the cluster.
It was rejected because it adds a whole new resource type for the Operator to watch and report on, for rules that are typically a few lines long.
Sharing also means a single bad edit changes client identities in every cluster that uses it.

### A fully described schema for the rules

Describing every rule field in the custom resource definition would let Kubernetes reject typos when the resource is applied.
It was rejected because it would only cover the built-in subject builder, so custom plugins would need a separate way to be configured, and the schema would have to be kept in step with the proxy.

### Naming the field `subjectBuilder`

This would match the proxy configuration exactly.
It was rejected because the SASL filters already use `subjectBuilder` for something different: naming a plugin that builds subjects from SASL logins.
On a `VirtualKafkaCluster`, the name would also suggest the field controls all client identity, when it only handles TLS certificates.

### Supporting Secret substitution (`configTemplate`)

Filter resources can pull values from Kubernetes Secrets into their configuration.
It was rejected because the subject builder's settings contain nothing secret.
Supporting it would mean the Operator mounting and watching Secrets for no benefit.
