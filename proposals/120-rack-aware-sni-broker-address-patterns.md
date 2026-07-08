# 120 - Rack-aware SNI broker address patterns

This proposal adds rack-derived broker address generation to the SNI node identification strategy.
It uses broker rack metadata learned from Kafka metadata responses and configured DNS label mappings to build advertised broker addresses without changing Kafka protocol rack metadata.

## Current situation

Kroxylicious supports SNI-based node identification through `sniHostIdentifiesNode`.
In this mode, a virtual cluster has a bootstrap address and an `advertisedBrokerAddressPattern`.
The pattern is used when Kroxylicious rewrites broker addresses in Kafka protocol responses, and also when it creates broker-specific endpoints that can later be reverse-mapped from SNI hostnames back to Kafka node IDs.

The existing advertised broker address pattern supports tokens such as:

```text
$(nodeId)
$(virtualClusterName)
$(unresolvedRouteHost)
```

This is enough when broker-specific advertised DNS names only need to vary by Kafka node ID.
It is not enough when operators need advertised broker names to include topology information such as a rack or availability-zone label.

Kafka brokers can expose rack metadata in metadata responses.
Kroxylicious currently does not make that value available to the SNI node identification strategy when generating advertised broker addresses.

## Motivation

Some deployments need broker-specific advertised addresses that include a topology label.
For example, a deployment may require DNS names with both node ID and rack-like placement:

```text
broker-0-az1.example.net
broker-1-az2.example.net
broker-2-az3.example.net
```

This can be useful when DNS, certificates, routing policy, or operational conventions require addresses to encode placement information.
The common source of that placement information in Kafka is the broker rack metadata.

One important use case is reducing avoidable cross-zone traffic.
In a multi-zone deployment, the client-facing load balancer, the Kroxylicious pod handling the connection, and the Kafka broker that leads a partition may all be placed in different zones.
For example:

```text
Client → Network Load Balancer (NLB) endpoint in Zone A
*(assuming cross-zone load balancing is disabled between the NLB and Kroxylicious pods)*
→ Kroxylicious pod in Zone A
→ Kafka broker or partition leader in Zone C
```
When traffic crosses zone boundaries between these hops, operators may pay inter-zone data transfer charges and may also see additional latency.
This is especially relevant for Kafka because produce and fetch traffic can be high-volume.
If broker-specific advertised hostnames include a rack or zone label, operators can configure DNS, load balancer targets, ingress policy, or deployment topology so that clients prefer a Kroxylicious endpoint in the same zone as the broker rack or failure domain where possible.

Kroxylicious does not need to implement the network placement policy itself.
It only needs to advertise broker hostnames that contain enough topology information for the surrounding DNS and load-balancing infrastructure to make zone-aware routing decisions.
This does not guarantee that all traffic is zone-local; rather, it gives operators a stable naming mechanism they can use to reduce avoidable cross-zone hops in their own network design.

This proposal deliberately treats the value as generic Kafka rack metadata, not as a cloud-provider-specific availability zone.
Different Kafka deployments may use rack values to represent physical racks, cloud availability zones, failure domains, or provider-specific placement identifiers.
For example, in a managed Kafka deployment the broker rack value might be a physical availability-zone ID, a subnet-like placement value, or another provider/operator-defined string.
Kroxylicious should not call cloud-provider APIs to interpret those values.
Instead, it should use the rack value that Kafka already exposes.

## Proposal

Extend the SNI node identification strategy so `advertisedBrokerAddressPattern` may use these additional tokens:

```text
$(rackId)
```

When Kroxylicious rewrites a metadata response, it uses the broker rack value from the metadata response for `$(rackId)`.
If `rackIdMappings` is configured, Kroxylicious first translates the upstream rack value into an advertised address label.
If the upstream rack value is missing or does not have a mapping, Kroxylicious uses `rackIdDefault` if configured.

Example configuration:

```yaml
sniHostIdentifiesNode:
  bootstrapAddress: "cluster.example.net:9192"
  advertisedBrokerAddressPattern: "broker-$(nodeId)-$(rackId).example.net:9192"
  rackIdDefault: az1
  rackIdMappings:
    euc1-az1: az1
    euc1-az2: az2
    euc1-az3: az3
```

If broker `0` has upstream rack value `euc1-az1`, Kroxylicious advertises:

```text
broker-0-az1.example.net:9192
```

That advertised hostname can then be backed by operator-managed DNS or load-balancer policy.
For example, `az1` can resolve to proxy endpoints in zone `az1`, while `az2` resolves to proxy endpoints in zone `az2`.
The exact DNS and networking implementation remains outside Kroxylicious.

If the broker rack value is unavailable or unmapped and no `rackIdDefault` is configured, address generation fails.
This makes misconfiguration visible rather than silently advertising an incomplete or incorrect hostname.

### Protocol-level consistency

This proposal does not introduce Kafka rack identity translation.
It uses Kafka broker rack metadata only as input for advertised broker address generation.
The value substituted for `$(rackId)` is an address label used by DNS, certificates, or load-balancer policy.
It is not a replacement for the broker rack identity in the Kafka protocol.

When `rackIdMappings` is configured, the mapping applies only to advertised broker addresses.
Kroxylicious should not rewrite Kafka protocol rack fields in responses such as `MetadataResponse` or `DescribeClusterResponse`.
It should also not rewrite client request fields that carry rack identity, such as the rack ID used by KIP-392 rack-aware fetching.
Those protocol fields remain in the upstream cluster's rack namespace.

For example, if upstream metadata says broker `0` has rack `euc1-az1`, and `rackIdMappings` maps `euc1-az1` to address label `az1`, the client may see:

```text
advertised hostname: broker-0-az1.example.net
metadata rack:       euc1-az1
```

This is intentional.
The hostname label controls the network path to Kroxylicious.
The Kafka protocol rack value continues to control Kafka features that depend on rack identity.
Because Kroxylicious does not rewrite protocol rack values, features such as KIP-392 rack-aware fetching continue to use the upstream Kafka rack values and do not require reverse mapping by the proxy.

If no `rackIdMappings` is configured, Kroxylicious uses the upstream Kafka rack value directly as the advertised address label.
Operators should only use this mode when their broker rack values are already suitable for their advertised hostname pattern.

If `rackIdMappings` is configured and the upstream rack value is missing or unmapped, Kroxylicious uses `rackIdDefault` if configured.
The default is an advertised address fallback label.
It should be used for cases where the operator prefers deterministic DNS behavior over failing address generation for unknown rack values.
This means that, when mappings are configured, an unmapped upstream rack value is not passed directly into the advertised hostname.

### DNS validity

Kafka broker rack values are arbitrary strings.
Not every legal Kafka rack value is valid inside a DNS hostname.
For example, `rack/shelf-3:unit_7` may be a legal broker rack value, but it is not a valid DNS label.
Provider-specific values such as availability-zone IDs or subnet-derived placement labels may also be unsuitable for the operator's desired DNS naming scheme.

Today the existing node identification strategies perform basic pattern, token, port, and URI-style checks.
They do not perform full DNS label validation for generated advertised broker hostnames.
This proposal does not change that validation model.
If an advertised address fails the existing validation checks, address generation fails.
Otherwise, Kroxylicious treats hostname suitability as an operator responsibility, as it does for existing advertised broker address patterns.
Operators should use `rackIdMappings` to translate arbitrary upstream rack values into advertised address labels that are suitable for their DNS, certificate, and load-balancer conventions.

### Usage model

This feature is intended to compose with infrastructure that already supports zone-aware routing.
For example, an operator might:

* configure Kafka broker rack values to represent broker failure domains,
* configure Kroxylicious pods or services in the same failure domains,
* configure rack mappings from upstream provider-specific rack values to stable DNS labels,
* advertise broker hostnames containing `$(rackId)`,
* configure DNS or load-balancer policy so each rack label resolves to the appropriate Kroxylicious endpoint.

Kroxylicious remains responsible for producing consistent advertised broker hostnames and reverse-mapping those hostnames back to broker node IDs.
The surrounding infrastructure remains responsible for resolving and routing those hostnames.

### Metadata response rewriting

When handling Kafka metadata responses, Kroxylicious already rewrites upstream broker host and port values into client-facing broker addresses.
This proposal extends that path to pass the broker rack value to the node identification strategy when generating the advertised broker address.

The rack value is only available in responses that carry broker rack metadata, such as metadata responses.
Other response types can contain broker endpoints without rack metadata.
For example, `FindCoordinatorResponse` identifies the coordinator by node ID, host, and port, but does not include broker rack information.

For responses that contain broker endpoints but do not include rack metadata, Kroxylicious should use a rack value previously learned from metadata for the same node ID.
If no learned rack value is available, Kroxylicious uses `rackIdDefault` if configured.
If no learned rack value is available and no default is configured, address generation fails.
Using `rackIdDefault` can cause an early control-plane response to use the default rack label before metadata has been observed, but it preserves routing correctness because SNI reverse mapping remains based on node ID.

### Lifecycle

Rack-aware address generation depends on upstream metadata.
For metadata responses, the rack value is available in the response being rewritten.
For other responses that contain broker endpoints, Kroxylicious can only generate a rack-aware address after it has previously learned the broker's rack from metadata.

This has implications for SNI endpoint lifecycle.
Configurations that eagerly create broker endpoints from configured node ID ranges cannot generate rack-aware broker endpoints before upstream metadata has been observed.
For a SNI configuration using `$(rackId)`, eager endpoint creation can only use `rackIdDefault`.
If no default is configured, rack-aware endpoints should be created by metadata-driven endpoint reconciliation once upstream metadata has been observed.

If a broker rack value changes, Kroxylicious should treat that as a change in the generated advertised broker address during normal endpoint reconciliation.
The new hostname should be generated from the updated metadata, and stale endpoint bindings generated from the previous rack value should be removed according to the existing reconciliation lifecycle.
Existing client connections can continue using the connection they already established, but a client that tries to open a new connection using a cached stale hostname may need to refresh metadata and retry.

### Endpoint registration and reverse mapping

The same rack-aware address generation must be used when registering broker-specific SNI endpoints.
Otherwise Kroxylicious could advertise one hostname in metadata but bind or route a different hostname internally.

The SNI reverse mapping remains node-ID based.
When the advertised broker address pattern contains a rack token, reverse mapping treats the rack portion of the hostname as a non-node-ID label and continues to extract the node ID from `$(nodeId)`.

For example, both patterns still resolve node ID correctly:

```text
broker-$(nodeId)-$(rackId).example.net
broker-$(rackId).$(nodeId).example.net
```

### Scope

This proposal is limited to the SNI node identification strategy.
It does not change the port-based node identification strategy.
Port mode is excluded because this proposal is about hostname/SNI-based routing.
In `portIdentifiesNode`, broker identity is primarily represented by the port number, often using a shared DNS name for all brokers.
For example, broker `0` might be advertised as `cluster.example.net:9193` and broker `1` as `cluster.example.net:9194`.
Embedding rack labels into broker hostnames does not provide the same routing mechanism in that model.
This is a scoping choice rather than a fundamental limitation.
If future work defines a useful rack-aware lifecycle and routing model for port-based listeners, it can be considered separately.
It does not introduce cloud-provider integrations.
It does not require users to configure rack-aware patterns.

## Affected/not affected projects

Affected:

* `kroxylicious-runtime`, specifically broker address pattern parsing, metadata response rewriting, SNI node identification, and endpoint reconciliation.
* Runtime tests covering SNI address generation, metadata rewrite behavior, and endpoint registration.

Not affected:

* `portIdentifiesNode` behavior.
* Existing SNI configurations that only use `$(nodeId)` and existing supported tokens.
* Kubernetes operator APIs, unless a future proposal chooses to surface validation or documentation through Kubernetes-specific schema changes.
* Filter plugin APIs.
* Kafka protocol rack fields in responses and requests, including rack IDs used by rack-aware fetching.
* Cloud-provider KMS providers and other unrelated integrations.

## Compatibility

This is a backward-compatible configuration extension.
Existing configurations remain valid and keep their existing behavior.

The new behavior is opt-in:

* If `advertisedBrokerAddressPattern` does not contain `$(rackId)`, rack metadata is ignored.
* Existing tokens retain their current meaning.
* Strategies that do not use rack metadata continue to generate broker addresses from node ID alone.

There are compatibility considerations for `$(rackId)`.
If the upstream Kafka cluster does not expose broker rack metadata, a pattern using `$(rackId)` cannot be resolved.
Operators can configure `rackIdDefault` when they need deterministic fallback behavior for missing or unmapped rack values.

The reverse SNI mapping must continue to extract exactly the node ID from the advertised broker hostname.
Rack labels must not become part of the node identity.

## Rejected alternatives

### Cloud-provider-specific lookup

One option was to have Kroxylicious call cloud-provider APIs to discover placement information such as availability zones or subnets.
This was rejected because it would make a generic Kafka proxy depend on provider-specific APIs, credentials, permissions, rate limits, and failure modes.
Kafka already exposes broker rack metadata, and operators can decide what that value means in their environment.

### Implementing this as a filter

This was considered but rejected.
Filters can rewrite protocol responses, but endpoint registration and SNI reverse mapping are owned by the node identification and endpoint reconciliation path.
If a filter rewrote metadata independently, Kroxylicious could advertise hostnames that the SNI routing layer did not know how to bind or reverse-map.

### Adding rack metadata to `HostPort`

This was rejected because `HostPort` represents only an address.
Rack metadata is broker topology metadata, not part of a host/port pair.
Keeping rack metadata separate avoids leaking broker-specific concerns into a generic address type.

### Protocol rack identity mapping

Mapping rack IDs as a full client-facing Kafka rack identity was considered and rejected for this proposal.
That would require Kroxylicious to rewrite protocol rack fields in responses and reverse-map client-supplied rack IDs in requests such as KIP-392 fetch requests.
This proposal is intentionally narrower: it uses broker rack metadata only to derive advertised broker address labels for routing through operator-managed DNS or load-balancer policy.
Kafka protocol rack identity remains unchanged.

Inline token defaults such as `$(rackId:az1)` were also rejected because token-level default syntax would imply that other tokens should support the same form.
Defaults belong to the rack address label configuration rather than the generic address templating language.

### Making rack ID required

Making rack metadata mandatory was rejected because many Kafka clusters either do not configure broker rack values or do not need rack-aware DNS names.
The feature should be opt-in and compatible with existing deployments.
