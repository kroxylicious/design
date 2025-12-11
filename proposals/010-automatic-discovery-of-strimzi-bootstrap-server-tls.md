# Extend the automatic discovery of bootstrap address feature to handle TLS listeners

This proposal aims to extend the automatic discovery of bootstrap address feature to handle TLS listeners. This will reduce manual configuration, create a tighter, more declarative integration with the Strimzi ecosystem.

## Current situation

Currently, with the integration of automatic discovery of bootstrap address of a Strimzi Kafka cluster [feature](https://github.com/kroxylicious/kroxylicious/pull/2693), we are able to retrieve the bootstrap address of the plain listeners by using `strimziKafkaRef` section in the KafkaService, but currently it doesn't support `tls`. When dealing with tls protected Strimzi Kafka cluster, the user will still need to use the old approach of manually setting the bootstrap address and then using the `trustAnchorRef` field to configure trust for the Kafka cluster.

## Motivation

The current process is manual and any errors while configuring TLS in the Kroxylicious operator can result in the operator not working properly.

Adding this feature help us get rid of the manual configuration and would also increase the integration of the Strimzi ecosystem with Kroxylicious.
It will also open doors for closer integration with other operators.

## Proposal

This proposal aims to extend the already existing boostrap address discovery feature for plain listeners for TLS.
If a user uses the `strimziKafkaRef` field in their Kafka CR, then the Kroxylicious operator should be able to proxy it without needing to explicitly configure trust.

### Algorithm

#### Initial process

The initial process will be similar to what we have for discovery of bootstrap address the plain listeners:

1. The user will make use of the `strimziKafkaRef` field to make use of the automated bootstrap discovery process
2. Then they should set the `listener` as `tls` and mention the `group`, `kind`, `name`, `namespace` of the cluster.
  
   Example of the KafkaService CR:
    ```yaml
    apiVersion: kroxylicious.io/v1alpha1
    kind: KafkaService
    metadata:
      name: my-cluster
      namespace: my-proxy
    spec:
      strimziKafkaRef:
        group: kafka.strimzi.io
        kind: Kafka
        name: my-cluster         # Name of the Kafka CR
        namespace: kafka        # Namespace of the Kafka CR
        listenerName: tls       # The specific listener to use from the Kafka CR status
    ```

3. The operator would then look at the specified Strimzi Kafka resource, find the listener named `tls` in its status, and extract the `bootstrapServers` from there and add it to `bootstrapServers` field in the `KafkaService` status.

4. Once the above steps are complete, we can then start to look for the Strimzi generated certificate and key.

#### Process for looking up for certificate and key.

It is possible even when using Strimzi cluster, the users can provide certificate signed by real CA (Verisign etc), then we (as a client) don't need a trust anchor. In these case we should be using system trust anchor. Taking the trust anchor from Strimzi in this situation is harmful. 

To tackle this issue, we can create a `trustStrimziCaCertificate` flag which will control whether we want to retrieve the trust anchor from Strimzi or we want the user to configure the trust anchor themselves.

We will be making use of the below algorithm to discover the cert and key for the trust.

```text
if `trustStrimziCaCertificate` is true:
   if `brokerCertChainAndKey` set on listener:
      use ref to the cert from `brokerCertChainAndKey`
   else:
      use ref to the cert from <cluster_name>-cluster-ca-cert
   end if
end if
else 
    use `trustAnchorRef` field
```

In case the `trustStrimziCaCertificate` is set to true, then it means that we can trust the certificates generated since the user is making use of Strimzi for the certificates and key.
The `brokerCertChainAndKey` in Strimzi allows the users to use a specific certificate for a specific listener. 
Therefore, if the user are providing their own certificates though Strimzi, then we should refer to the certificates from `brokerCertChainAndKey`.
In case the user are dependent on Strimzi generated certificates then we will refer to certificate from `<cluster_name>-cluster-ca-cert`.

If the user decides not to trust the certificates coming from Strimzi, then they can just use the `trustAnchorRef` to mention their own certificates.

Once the certificate and key lookup is complete, the status of the KafkaService should reflect the cert name, kind and key of the Strimzi Kafka Cluster.

```yaml
kind: KafkaService
apiVersion: kroxylicious.io/v1alpha1
metadata:
  name: fooref
  namespace: proxy-ns
  generation: 6
spec:
   strimziKafkaRef:
     group: kafka.strimzi.io
     kind: Kafka
     name: my-cluster        
     namespace: kafka     
     listenerName: tls      
status:
   bootstrapServers: my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9093
   trustAnchorRef:
      name: <Name of the cert>
      kind: <Kind of the cert>
      key: <Key of the cert>
```

#### What happens if the secret/key doesn't exist

In case the operator is not able to find the expected secret, then the operator would throw `ReferencedResourceNotReconciled` exception in the status of the `KafkaService` CR.

In case the key doesn't exist, then the operator would throw `InvalidReferencedResource` exception in the status of the `KafkaService` CR.

## Affected/not affected projects
 
The `kroxylicious-operator` module will be affected by the logic changes required for the above feature

## Compatibility

This feature will not affect backwards compatibility.
