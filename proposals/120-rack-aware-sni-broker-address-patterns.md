# 120 - Rack-aware SNI broker address patterns

This proposal adds optional rack-aware broker address generation to the SNI node identification strategy.
It allows an advertised broker address pattern to include broker rack metadata learned from Kafka metadata responses.

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
client -> network load balancer endpoint in zone-a
       -> Kroxylicious pod in zone-b
       -> Kafka broker or partition leader in zone-c
```

When traffic crosses zone boundaries between these hops, operators may pay inter-zone data transfer charges and may also see additional latency.
This is especially relevant for Kafka because produce and fetch traffic can be high-volume.
If broker-specific advertised hostnames include a rack or zone label, operators can configure DNS, load balancer targets, ingress policy, or deployment topology so that clients prefer a Kroxylicious endpoint in the same zone as the broker rack or failure domain where possible.

Kroxylicious does not need to implement the network placement policy itself.
It only needs to advertise broker hostnames that contain enough topology information for the surrounding DNS and load-balancing infrastructure to make zone-aware routing decisions.
This does not guarantee that all traffic is zone-local; rather, it gives operators a stable naming mechanism they can use to reduce avoidable cross-zone hops in their own network design.

This proposal deliberately treats the value as generic Kafka rack metadata, not as a cloud-provider-specific availability zone.
Different Kafka deployments may use rack values to represent physical racks, cloud availability zones, failure domains, or provider-specific placement identifiers.
Kroxylicious should not call cloud-provider APIs to interpret those values.
Instead, it should use the rack value that Kafka already exposes and let operators optionally map raw rack values to DNS-friendly labels.

## Proposal

Extend the SNI node identification strategy so `advertisedBrokerAddressPattern` may use these additional tokens:

```text
$(rackId)
$(rackId:<default>)
```

When Kroxylicious rewrites a metadata response, it uses the broker rack value from the metadata response for `$(rackId)`.
When a mapping is configured, the raw rack value is first translated through that mapping before being substituted into the advertised hostname.

Example configuration:

```yaml
sniHostIdentifiesNode:
  bootstrapAddress: "cluster.example.net:9192"
  advertisedBrokerAddressPattern: "broker-$(nodeId)-$(rackId:az1).example.net:9192"
  rackIdMappings:
    euc1-az1: az1
    euc1-az2: az2
    euc1-az3: az3
```

If broker `0` has rack value `euc1-az1`, Kroxylicious advertises:

```text
broker-0-az1.example.net:9192
```

That advertised hostname can then be backed by operator-managed DNS or load-balancer policy.
For example, `az1` can resolve to proxy endpoints in zone `az1`, while `az2` resolves to proxy endpoints in zone `az2`.
The exact DNS and networking implementation remains outside Kroxylicious.

If the broker rack value is unavailable and the token has a default, the default is used:

```text
$(rackId:az1)
```

If the broker rack value is unavailable and the token has no default, address generation fails.
This makes misconfiguration visible rather than silently advertising an incomplete or incorrect hostname.

### Rack ID mappings

`rackIdMappings` is an optional map on the SNI node identification strategy.
Keys are raw Kafka rack values.
Values are replacement labels used in the advertised broker address.

For example:

```yaml
rackIdMappings:
  euc1-az1: az1
```

This lets operators keep stable DNS labels even when raw Kafka rack values differ between environments or providers.
It also avoids making Kroxylicious aware of cloud-provider-specific naming rules.

If no mapping exists for a non-empty rack value, the raw rack value is used as-is.
Operators should configure mappings when raw rack values are not suitable for use in DNS hostnames, or when they want stable DNS labels that differ from the values exposed by Kafka.

### Usage model

This feature is intended to compose with infrastructure that already supports zone-aware routing.
For example, an operator might:

* configure Kafka broker rack values to represent broker failure domains,
* configure Kroxylicious pods or services in the same failure domains,
* advertise broker hostnames containing `$(rackId)` or a mapped rack label,
* configure DNS or load-balancer policy so each rack label resolves to the appropriate Kroxylicious endpoint.

Kroxylicious remains responsible for producing consistent advertised broker hostnames and reverse-mapping those hostnames back to broker node IDs.
The surrounding infrastructure remains responsible for resolving and routing those hostnames.

### Metadata response rewriting

When handling Kafka metadata responses, Kroxylicious already rewrites upstream broker host and port values into client-facing broker addresses.
This proposal extends that path to pass the broker rack value to the node identification strategy when generating the advertised broker address.

The rack value is only available in responses that carry broker rack metadata.
Other response types that contain broker endpoints continue to use the existing node-ID-only behavior unless rack metadata is available.

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
* Cloud-provider KMS providers and other unrelated integrations.

## Compatibility

This is a backward-compatible configuration extension.
Existing configurations remain valid and keep their existing behavior.

The new behavior is opt-in:

* If `advertisedBrokerAddressPattern` does not contain `$(rackId)` or `$(rackId:<default>)`, rack metadata is ignored.
* Existing tokens retain their current meaning.
* Strategies that do not use rack metadata continue to generate broker addresses from node ID alone.

There are compatibility considerations for `$(rackId)` without a default.
If the upstream Kafka cluster does not expose broker rack metadata, a pattern using `$(rackId)` cannot be resolved.
Operators can avoid that by using `$(rackId:<default>)`.

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

### Making rack ID required

Making rack metadata mandatory was rejected because many Kafka clusters either do not configure broker rack values or do not need rack-aware DNS names.
The feature should be opt-in and compatible with existing deployments.
