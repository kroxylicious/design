# 150 - Long Kubernetes names

Support long `metadata.name` in the Kroxylicious custom resources

## Current situation

The Kubernetes API Server imposes rules on the `metadata.name` allowed for different resources:
* Most resource names must be DNS Subdomain Names: Max 253 characters. Allowed characters are lowercase alphanumeric, hyphens (-), and dots (.). Must start and end with an alphanumeric character.
* `Service` must be a RFC 1035 Label Name\*: Max 253 characters. Allowed characters are lowercase alphanumeric, hyphens (-), and dots (.). Must start and end with an alphanumeric character.
* A few other resources, such as `Namespace` and `Node` must use RFC 1123 Label Names: Max 63 characters. Allowed characters are lowercase alphanumeric and hyphens (-). No dots (.). Can start and end with any alphanumeric character (meaning they can start with a number).

\* Kubernetes v1.31+ introduced a RelaxedServiceNameValidation feature gate that allows Service names to start with a digit, effectively bringing them in line with RFC 1123 Labels.

The operator must give names to the derived resources it manages, and the names must be acceptable to the Kubernetes API Server.
In several cases the names of derived resources are computed from the names of the custom resources the operator consumes.
The CustomResourceDefinitions use schema constraints (`maxLength` and `x-kubernetes-validations`) to limit the lenths of the names of the consumed resources so as to avoid generating a derived resource name that would be unacceptable to the Kubernetes API Server.
For example the bootstrap `Service` used for `clusterIP` with TCP networking is constructed using the pattern `{clusterName}-{ingressName}-bootstrap`. 
Because that name must be less than 63 characters it follows that the sum of the lengths of the names of a `VirtualKafkaCluster` and a `KafkaProxyIngress` cannot be more than 52 characters (accounting for the intermediate `-` and the `-bootstrap` suffix.

## Motivation

The limits we have in place work but:

* Some of them are smaller than might be expected.
* They might seem arbitrary (as the example shows, they're not always the familiar length limits inherited from DNS RFCs) and the reasons for the limits are opaque (even in the operator source code). 
* They're easily overlooked (for example when adding new resources).

## Proposal

It is proposed that we change how we compute names. When a generated name would be too long we will compute a hash of the full name, encode it as a short string, truncate the full name by the length of that encoded hash, and concatenate the two. For example if a cluster was called `cluster-9012345678901234567890` (30 chars) and an ingress was called `ingress-9012345678901234567890` (30 chars) the aforementioned `Service`'s name would be constructed as follows:

1. Apply the existing pattern to get the full name `cluster-9012345678901234567890-ingress-9012345678901234567890-bootstrap`.
2. Because this is longer than the 63 characters allowed for a `Service`, we apply the trunction algorithm.
3. The encoded hash is computed as `6c664889f9`.
4. The `metadata.name` is computed as `cluster-9012345678901234567890-ingress-9012345678901-6c664889f9`.

In constrast for a cluster called `cluster` and an ingress called `ingress`:
1. Full name would be `cluster-ingress-bootstrap`.
2. Because this is not longer than the 63 characters allowed for a `Service`, we do **not** apply the trunction algorithm.
4. The `metadata.name` is computed as `cluster-ingress-bootstrap`.

It is proposed to use the `String.hashCode()` method to compute the hash:
* The exact algorithm used for `String.hashCode()` is described in its Javadoc. 
* It seems unlikely that is would ever be changed in the future.
* It offers a execellent uniformity over the characters allowed (a-z, 0-9 and -).
* This hash is 32 bits

It should be noted that Kubernetes itself uses 32 bit hashes for naming things like `Deployments` (though it uses a different hash algorithm).
Of course hash collision of two distinct strings is still possible. 
The hash is over a string that's at least 64 characters long (and for non-`Service` resources at least 254 characters long), so collisions are less likely than for short (=common) strings.
For this to be a problem two strings would need to differ only in characters at indexes beyond N (where N is >=63-10=53, since up to 10 characters may be used the hash), and to have the same hash.
This seems very unlikely to happen in real world situations.
This proposal asserts that this risk is accepted by the project.

A consequence of this is that in those cases where we were using a disambiguating suffix in the name (the `-bootstrap` in the running example), there is a loss of clarity in what role the resource is playing. This could be addressed by using a label to hold the role, for example `kroxylicious.io/role=bootstrap`.

The table below shows the resources which this change would currently apply to, but this is proposed as the general mechanism to handle derived names in the operator going forward.

  ┌─────────────────┬────────────────────────────────────────────────────────┬────────────────────────────────────────────────┬─────────────────────────────────────────┐
  │    Resource     │                          File                          │                    Pattern                     │                  Limit                  │
  ├─────────────────┼────────────────────────────────────────────────────────┼────────────────────────────────────────────────┼─────────────────────────────────────────┤
  │ Deployment      │ ProxyDeploymentDependentResource.java:92               │ {proxyName}                                    │ 63                                      │
  ├─────────────────┼────────────────────────────────────────────────────────┼────────────────────────────────────────────────┼─────────────────────────────────────────┤
  │ ConfigMap       │ ProxyConfigDependentResource.java:50                   │ {proxyName}-proxy-config                       │ 253                                     │
  ├─────────────────┼────────────────────────────────────────────────────────┼────────────────────────────────────────────────┼─────────────────────────────────────────┤
  │ ConfigMap       │ ProxyConfigStateDependentResource.java:52              │ {proxyName}-config-state                       │ 253                                     │
  ├─────────────────┼────────────────────────────────────────────────────────┼────────────────────────────────────────────────┼─────────────────────────────────────────┤
  │ Label value     │ Labels.java:33                                         │ {proxyName} (app.kubernetes.io/instance)       │ 63                                      │
  ├─────────────────┼────────────────────────────────────────────────────────┼────────────────────────────────────────────────┼─────────────────────────────────────────┤
  │ Service         │ ClusterServiceDependentResource.java:49                │ {clusterName}                                  │ 63                                      │
  ├─────────────────┼────────────────────────────────────────────────────────┼────────────────────────────────────────────────┼─────────────────────────────────────────┤
  │ Service         │ TcpClusterIPClusterIngressNetworkingModel.java:89      │ {clusterName}-{ingressName}-bootstrap          │ 63                                      │
  ├─────────────────┼────────────────────────────────────────────────────────┼────────────────────────────────────────────────┼─────────────────────────────────────────┤
  │ Service         │ RouteClusterIngressNetworkingModel.java:215            │ {clusterName}-{ingressName}-service            │ 63                                      │
  ├─────────────────┼────────────────────────────────────────────────────────┼────────────────────────────────────────────────┼─────────────────────────────────────────┤
  │ Service         │ TlsClusterIPClusterIngressNetworkingModel.java:97      │ {clusterName}-{ingressName}-{bootstrap|nodeId} │ 63                                      │
  │                 │ (bootstrap + per-node)                                 │                                                │                                         │
  ├─────────────────┼────────────────────────────────────────────────────────┼────────────────────────────────────────────────┼─────────────────────────────────────────┤
  │ Service         │ ProxyNetworkingModel.java:135                          │ {ingressName}                                  │ 63                                      │
  │ (LoadBalancer)  │                                                        │                                                │                                         │
  ├─────────────────┼────────────────────────────────────────────────────────┼────────────────────────────────────────────────┼─────────────────────────────────────────┤
  │                 │                                                        │                                                │ 253 (but note: Route's auto-generated   │
  │ Route           │ RouteClusterIngressNetworkingModel.java:198            │ {clusterName}-{bootstrap|nodeId}               │ host also embeds this as a DNS label —  │
  │                 │                                                        │                                                │ worth checking separately before        │
  │                 │                                                        │                                                │ relaxing)                               │
  └─────────────────┴────────────────────────────────────────────────────────┴────────────────────────────────────────────────┴─────────────────────────────────────────┘


## Affected/not affected projects

This proposal affects the operator in the kroxylicious project.

## Compatibility

Because all existing generated names are, by construction, shorter than the relevant limit for their kind, and because the algorthim does not change names which are shorter than the relevant limit for their kind, not existing resource names can be changed by this proposal. This means it's backwards compatible.

Once resources have been created which use hashed names then changing the hash algorthim in any way could change the names of existing resources, which is not a compatible change.

## Rejected alternatives

* "No change" suffers from all the problems mentioned in the motivation section.
