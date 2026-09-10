# 120 - Rack-aware SNI broker address patterns

This proposal adds rack-derived broker address generation to the SNI node identification strategy.
When `$(rackAddress)` is used, it requires `rackAddressMappings` and `defaultRackAddress` to build advertised broker addresses from learned Kafka broker rack metadata without changing Kafka protocol rack metadata.

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

Kafka brokers can expose rack metadata in responses such as `MetadataResponse` and `DescribeClusterResponse`.
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
client -> Network Load Balancer (NLB) endpoint in Zone A
       -> Kroxylicious pod in Zone A
       -> Kafka broker or partition leader in Zone C
```

This example assumes cross-zone load balancing is disabled between the NLB and Kroxylicious pods.
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

Extend the SNI node identification strategy so `advertisedBrokerAddressPattern` may use this additional token:

```text
$(rackAddress)
```

When Kroxylicious rewrites a complete broker-topology response that carries rack metadata, it uses each broker's Kafka `rackId` from that response to resolve `$(rackAddress)`.
If `rackAddressMappings` contains an entry whose `rackId` matches the upstream Kafka rack ID, Kroxylicious substitutes the corresponding `rackAddress` label.
If learned metadata reports no Kafka rack ID, or the reported rack ID does not have a mapping, Kroxylicious substitutes `defaultRackAddress`.
The default is not used when broker topology has not yet been learned; that case uses metadata discovery.

Example configuration:

```yaml
sniHostIdentifiesNode:
  bootstrapAddress: "cluster.example.net:9192"
  advertisedBrokerAddressPattern: "broker-$(nodeId)-$(rackAddress).example.net:9192"
  defaultRackAddress: az1
  rackAddressMappings:
    - rackId: euc1-az1
      rackAddress: az1
    - rackId: euc1-az2
      rackAddress: az2
    - rackId: euc1-az3
      rackAddress: az3
```

If broker `0` has upstream rack value `euc1-az1`, Kroxylicious advertises:

```text
broker-0-az1.example.net:9192
```

That advertised hostname can then be backed by operator-managed DNS or load-balancer policy.
For example, `az1` can resolve to proxy endpoints in zone `az1`, while `az2` resolves to proxy endpoints in zone `az2`.
The exact DNS and networking implementation remains outside Kroxylicious.

When `advertisedBrokerAddressPattern` contains `$(rackAddress)`, `rackAddressMappings` is required and must contain at least one entry, and `defaultRackAddress` is also required.
This makes translation from the arbitrary Kafka rack namespace to the operator-controlled address namespace explicit; raw Kafka rack IDs are never substituted into hostnames.
`defaultRackAddress`, and the `rackId` and `rackAddress` of every mapping entry, must be non-null and nonblank.
Each `rackId` may appear only once in `rackAddressMappings`; duplicate keys make the configuration invalid because the lookup would otherwise be ambiguous.
Rack ID lookup is an exact, case-sensitive match.
Multiple rack IDs may map to the same rack address when an operator intentionally wants those racks to share a network path.
Configuring `rackAddressMappings` or `defaultRackAddress` when the pattern does not contain `$(rackAddress)` is invalid rather than silently ignored.

`defaultRackAddress` provides an availability fallback after metadata has been learned when the upstream rack value is missing or unexpectedly unmapped.
Using it may produce non-optimal rack-aware routing until the upstream metadata or mapping is corrected.
It is never used to guess broker placement before metadata has been learned.

The address resolution rules distinguish unknown topology from an unknown rack ID:

| Broker state | Address-generation action |
|---|---|
| The current response contains a complete broker topology with rack metadata | Resolve the rack address from that response, reconcile the endpoint, and then forward the rewritten response. |
| No active topology entry exists for the node ID and the current response does not contain rack metadata | Complete metadata learning before rewriting the broker address. Do not use `defaultRackAddress` merely because the topology is unknown. |
| A topology entry exists and its rack ID has a mapping | Use the mapped `rackAddress`. |
| A topology entry exists but its rack ID is absent or unmapped | Use `defaultRackAddress`. |

Metadata can be learned either from a normal client metadata exchange or through `EagerMetadataLearner` when a gateway configured with `$(rackAddress)` has no active topology before the first non-prelude request is processed.
Topology availability is determined from the active topology shared by the virtual-cluster gateway, not from connection-local state.
`EagerMetadataLearner` permits `ApiVersions`, `SaslHandshake`, and `SaslAuthenticate` requests so that protocol negotiation and authentication can complete, then holds the first other request while metadata is learned and the endpoints are reconciled.
An internally generated Metadata request must use a version in the negotiated upstream version range that carries broker rack information, which means Metadata version 1 or later rather than version 0.
If the triggering request is itself a Metadata request with a rack-capable version, Kroxylicious may use that request for discovery; a lower-version client Metadata request cannot by itself provide the rack-aware topology.
In that case, Kroxylicious must issue a separate rack-capable Metadata request before processing the lower-version client request.
If the proxy and upstream broker cannot negotiate a Metadata version that carries rack information, topology discovery fails and Kroxylicious does not advertise or register rack-derived broker endpoints from that response.
Concurrent connections that observe the same gateway without active topology must share or await the gateway's in-progress metadata-discovery operation rather than independently publishing competing topology snapshots.
On an ordinary connection that remains open, this request gate is one-shot: after topology is successfully established, subsequent requests proceed without repeating eager discovery while the required active topology remains available.

### Protocol-level consistency

This proposal does not introduce Kafka rack identity translation.
It uses Kafka broker rack metadata only as input for advertised broker address generation.
The value substituted for `$(rackAddress)` is an address label used by DNS, certificates, or load-balancer policy.
It is not a replacement for the broker rack identity in the Kafka protocol.

`rackAddressMappings` maps a Kafka `rackId` to an advertised `rackAddress` label and applies only to advertised broker addresses.
Kroxylicious should not rewrite Kafka protocol rack fields in responses such as `MetadataResponse` or `DescribeClusterResponse`.
It should also not rewrite client request fields that carry rack identity, such as the rack ID used by KIP-392 rack-aware fetching.
Those protocol fields remain in the upstream cluster's rack namespace.

For example, if upstream metadata says broker `0` has rack `euc1-az1`, and `rackAddressMappings` maps `euc1-az1` to address label `az1`, the client may see:

```text
advertised hostname: broker-0-az1.example.net
metadata rack:       euc1-az1
```

This is intentional.
The hostname label controls the network path to Kroxylicious.
The Kafka protocol rack value continues to control Kafka features that depend on rack identity.
Because Kroxylicious does not rewrite protocol rack values, features such as KIP-392 rack-aware fetching continue to use the upstream Kafka rack values and do not require reverse mapping by the proxy.

If learned upstream metadata contains a missing or unmapped rack value, Kroxylicious uses `defaultRackAddress`.
The default is an advertised address fallback label.
It provides deterministic address generation for unknown rack values.
This means that an unmapped upstream rack value is not passed directly into the advertised hostname.
An unknown broker topology does not select the default; Kroxylicious first uses metadata discovery to learn the topology.

### DNS validity

Kafka broker rack values are arbitrary strings.
Not every legal Kafka rack value is valid inside a DNS hostname.
For example, `rack/shelf-3:unit_7` may be a legal broker rack value, but it is not a valid DNS label.
Provider-specific values such as availability-zone IDs or subnet-derived placement labels may also be unsuitable for the operator's desired DNS naming scheme.

Today the existing node identification strategies perform basic pattern, token, port, and URI-style checks.
They do not perform full DNS label validation for generated advertised broker hostnames.
This proposal does not change that validation model.
Kroxylicious treats hostname suitability as an operator responsibility, as it does for existing advertised broker address patterns.
Operators must use `rackAddressMappings` and `defaultRackAddress` to provide address values that are suitable for their DNS, certificate, and load-balancer conventions.
Passing Kroxylicious' existing configuration checks does not guarantee that the generated hostname is valid or resolvable in the operator's DNS environment; an unsuitable value can therefore fail later during client DNS resolution, TLS hostname verification, or routing.

### Usage model

This feature is intended to compose with infrastructure that already supports zone-aware routing.
For example, an operator might:

* configure Kafka broker rack values to represent broker failure domains,
* configure Kroxylicious pods or services in the same failure domains,
* configure rack address mappings from upstream provider-specific rack values to stable DNS labels,
* advertise broker hostnames containing `$(rackAddress)`,
* configure DNS or load-balancer policy so each rack label resolves to the appropriate Kroxylicious endpoint.

Kroxylicious remains responsible for producing consistent advertised broker hostnames and reverse-mapping those hostnames back to broker node IDs.
The surrounding infrastructure remains responsible for resolving and routing those hostnames.

### Client connection flow

In the normal flow, the client connects to the virtual-cluster bootstrap address and completes the required Kafka protocol negotiation and authentication.
If a virtual-cluster gateway configured with `$(rackAddress)` does not yet have active topology when the first non-prelude request arrives, Kroxylicious holds that request and obtains metadata containing each broker's node ID, upstream address, and Kafka rack ID.
It maps each rack ID to a rack address, generates the advertised broker address, and reconciles the corresponding SNI endpoint.
Only after reconciliation succeeds does Kroxylicious return the rewritten broker addresses to the client.
The client can then connect to an advertised broker SNI, and Kroxylicious routes that connection to the learned upstream broker.
An ordinary bootstrap connection is already connected according to its advertised semantics, so eager topology learning does not by itself require that connection to be closed.
After successful reconciliation, Kroxylicious resumes processing the held request on that connection, or returns the reconciled response directly when the client's Metadata request was reused for discovery.

A proxy instance might receive a broker SNI that matches `advertisedBrokerAddressPattern` but does not yet have an explicit binding for it.
This can happen after a restart, during a rolling deployment or scale-out, when a client reaches a different proxy replica from the one that returned its metadata, or when bindings have been recreated.

For recovery, Kroxylicious extracts the node ID from the SNI hostname and resolves the connection to a `MetadataDiscoveryBrokerEndpointBinding` that uses the target-cluster bootstrap servers.
`EagerMetadataLearner` permits the Kafka protocol prelude, then holds the first non-prelude client request and obtains metadata from the target cluster.
Kroxylicious resolves rack addresses from the metadata response and reconciles the broker endpoints.
After reconciliation, the client connection is still temporarily routed through bootstrap, and its established upstream TCP connection may terminate at a different broker from the node identified by the client's SNI.
Because that connection cannot be retargeted safely, Kroxylicious must close it.
If the request that triggered eager learning was a metadata request, Kroxylicious returns the reconciled and rewritten metadata response before closing; otherwise, it does not forward the triggering request and closes without a response.
The client then retries, and if the requested hostname is still the address generated from current metadata, the newly registered broker binding accepts the connection and opens an upstream connection to the intended broker.

This recovery is automatic and has no user-facing configuration switch.
The rack-address portion of the incoming SNI is not trusted as broker topology; only the node ID is extracted, and learned metadata determines the effective hostname.
`defaultRackAddress` is not used merely because topology is unknown. It is used only after metadata has been obtained and the broker rack ID is missing or unmapped.

The same topology-before-rewrite ordering applies to an ordinary bootstrap or registered broker connection for a `$(rackAddress)` gateway when it has no active topology.
This requires eager metadata learning to gate the first non-prelude request based on gateway-scoped topology availability, in addition to its existing use with metadata-discovery bindings.
These ordinary connections are not temporarily impersonating a broker-specific endpoint, so they do not need to close solely because eager learning occurred.
Metadata learning remains client-triggered and does not cause an unconditional metadata request during proxy startup.
If eager metadata learning fails, Kroxylicious leaves the previous active topology and endpoint bindings unchanged, does not forward the held request as though discovery succeeded, and fails the affected connection so a later connection can retry discovery.

A separate case occurs when active topology exists but an endpoint-bearing response refers to a node ID that is absent from it, for example after the upstream cluster adds or replaces a broker.
The request gate cannot predict that node ID before receiving the response.
The broker-address rewriting path must therefore pause that response and initiate or await a gateway-scoped metadata refresh before generating its advertised address.

### Broker topology and endpoint response rewriting

When handling Kafka responses containing broker endpoints, Kroxylicious already rewrites upstream broker host and port values into client-facing broker addresses.
This proposal extends that path to pass the broker rack value to the node identification strategy when generating the advertised broker address.

The rack value is available in complete broker-topology responses such as `MetadataResponse` and `DescribeClusterResponse`.
Each such response must build a desired topology snapshot from its broker node IDs, upstream addresses, and unmodified Kafka rack IDs, and must reconcile that snapshot before the rewritten response is forwarded.
Other response types can contain broker endpoints without rack metadata.
For example, `FindCoordinatorResponse` identifies the coordinator by node ID, host, and port, but does not include broker rack information.

For responses that contain broker endpoints but do not include rack metadata, Kroxylicious should use a rack value previously learned from metadata for the same node ID.
On a metadata-discovery broker connection, `EagerMetadataLearner` learns this topology and closes the bootstrap-routed client connection so the retry can open an upstream connection to the intended broker.
On other connection paths, eager learning must establish or await the shared active topology before processing the first non-prelude request when no active topology exists.
If active topology exists but does not contain a node referenced by a later endpoint-bearing response, the response rewriting path must initiate or await a metadata refresh before rewriting that node.
If broker topology has not been learned, Kroxylicious must first complete or await metadata learning rather than treating the topology as a missing rack ID and selecting the default.
After topology has been learned, `defaultRackAddress` is used if the broker has no rack ID or its rack ID has no configured mapping.

The learned broker topology is shared by client connections using the same virtual-cluster gateway within one proxy instance.
It is not distributed between proxy replicas and is not persisted across restarts.
Each proxy instance therefore learns and reconciles topology independently; a new or restarted instance begins without active topology and uses the metadata-discovery behavior described above when necessary.

In runtime terms, `EndpointRegistry` maintains one active topology map for each registered `EndpointGateway`, keyed by Kafka node ID.
The logical topology entry is:

```text
nodeId -> { upstreamAddress, kafkaRackId, advertisedAddress }
```

`nodeId` remains the broker identity, `upstreamAddress` is the target-cluster endpoint, and `kafkaRackId` is the unmodified rack value learned from Kafka metadata.
`advertisedAddress` is derived from the node ID, the mapped rack address or default rack address, and `advertisedBrokerAddressPattern`; it is not a second rack identity.
This topology is available to all client connections using that `EndpointGateway`, allowing a response on one connection, such as `FindCoordinatorResponse`, to use rack information learned while serving another connection.

Complete rack-bearing broker-topology responses build the desired topology and are forwarded only after their endpoint reconciliation has completed.
The active topology is updated only after that reconciliation succeeds, so Kroxylicious does not advertise a new rack-derived hostname before the matching SNI endpoint has been registered.
When an effective advertised address changes, reconciliation must register the replacement SNI binding before removing the currently active binding.
If replacement registration fails, the prior binding and active topology remain in use.
If removal of an obsolete binding fails after its replacement is registered, the replacement remains usable, cleanup of the obsolete binding is retried, and the failure must not result in advertising an unregistered hostname.

Reconciliations are serialized independently for each `EndpointGateway` within a proxy instance.
Equivalent desired topologies submitted while the same reconciliation is in progress may share that reconciliation result.
A different desired topology submitted during an in-progress reconciliation waits and is processed in the order accepted by that gateway's reconciler.
Each broker-topology response waits for the reconciliation associated with its desired topology before it is forwarded.
After the required replacement bindings are successfully registered, that desired topology becomes active and its response can be forwarded; failure to establish a required replacement leaves the previously active topology active and the affected response is not forwarded as a successful rewritten response.
Failure of one reconciliation does not discard a different desired topology already waiting to be processed.
Kafka broker-topology responses do not provide a topology generation that Kroxylicious can use to order concurrent observations globally, so ordering is local to each proxy instance and follows reconciliation submission order.
Proxy replicas can temporarily hold different active topology states while learning independently and converge after they process the same stable upstream topology.

### Lifecycle

Rack-derived address generation depends on upstream metadata.
For `MetadataResponse` and `DescribeClusterResponse`, the rack value is available in the response being rewritten.
For other responses that contain broker endpoints, Kroxylicious can only generate a rack-derived address after it has previously learned the broker's Kafka rack ID from metadata.

This has implications for SNI endpoint lifecycle.
Before broker rack metadata is available, Kroxylicious does not generate explicit rack-derived broker endpoints using `defaultRackAddress`.
Instead, an SNI hostname that matches the broker address pattern but has no registered endpoint uses a temporary metadata-discovery binding.
This binding needs only the node ID extracted from the SNI hostname; it does not need to recover the Kafka rack ID or rack address label from the hostname.
Once broker metadata has been observed, metadata-driven endpoint reconciliation registers the effective rack-derived advertised addresses.

The active broker topology is replaced only after all required replacement bindings have been registered; cleanup of obsolete bindings may continue afterward if necessary.
A complete rack-bearing broker-topology response supplies the current broker rack IDs directly; endpoint-bearing responses without rack metadata reuse rack IDs already learned for the same node ID.
Consequently, broker removals and node-ID reuse do not retain stale rack IDs after a successful metadata-driven reconciliation.

If a broker rack value changes, Kroxylicious should treat that as a change in the generated advertised broker address during normal endpoint reconciliation.
The new hostname should be generated from the updated metadata, and reconciliation must detect this as an endpoint change even though the node ID is unchanged.
This requires rack-derived reconciliation logic; the current node-ID membership reconciliation is not sufficient on its own.
Reconciliation must compare the effective generated broker address as well as node ID.
If the node ID is unchanged but the generated hostname differs, Kroxylicious registers the new explicit SNI binding before removing the old one.
If the Kafka rack ID changes but maps to the same generated hostname, no SNI rebind is necessary, although the active topology is still updated.
Existing client connections can continue using the connection they already established.

After a restart or when a client reaches another proxy replica, metadata discovery recovers a cached broker hostname when that hostname is still the effective address produced by current metadata.
A genuinely stale hostname caused by a broker rack change, or by a mapping change applied during proxy reconfiguration, is different: discovery may register a new canonical hostname that does not match the hostname the client is retrying.
This proposal does not retain old rack-derived hostnames as aliases.
A Kafka client that only retries the stale hostname may therefore remain unable to reconnect until it is made to bootstrap or otherwise refresh metadata.
Retaining temporary stale-hostname aliases is outside this proposal and can be considered separately.

### Endpoint registration and reverse mapping

The same rack-derived address generation must be used when registering broker-specific SNI endpoints.
Otherwise Kroxylicious could advertise one hostname in metadata but bind or route a different hostname internally.

The SNI reverse mapping remains node-ID based.
When the advertised broker address pattern contains `$(rackAddress)`, reverse mapping treats the address-label portion of the hostname as a non-node-ID label and continues to extract the node ID from `$(nodeId)`.
The rack-address portion must exactly match `defaultRackAddress` or one of the configured `rackAddressMappings[*].rackAddress` values, but it is not reverse-mapped to a Kafka rack ID or trusted as topology.

For example, both patterns still resolve node ID correctly:

```text
broker-$(nodeId)-$(rackAddress).example.net
broker-$(rackAddress).$(nodeId).example.net
```

### Scope

This proposal is limited to the SNI node identification strategy.
It does not change the port-based node identification strategy.
Port mode is excluded because this proposal is about hostname/SNI-based routing.
In `portIdentifiesNode`, broker identity is primarily represented by the port number, often using a shared DNS name for all brokers.
Its `nodeIdRanges` configuration eagerly reserves node-specific ports before metadata is available, which has a different endpoint-generation lifecycle from SNI's pattern-based discovery.
For example, broker `0` might be advertised as `cluster.example.net:9193` and broker `1` as `cluster.example.net:9194`.
Embedding rack labels into broker hostnames does not provide the same routing mechanism in that model.
This is a scoping choice rather than a fundamental limitation.
If future work defines a useful rack-derived lifecycle and routing model for port-based listeners, it can be considered separately.
It does not introduce cloud-provider integrations.
It does not introduce full DNS label validation for generated advertised broker hostnames.
It does not require existing users to configure rack-aware patterns.

## Affected/not affected projects

Affected:

* `kroxylicious-runtime`, specifically broker address pattern parsing, broker-topology response rewriting, SNI node identification, metadata-discovery bindings, and endpoint reconciliation.
* Runtime tests covering SNI address generation, `MetadataResponse` and `DescribeClusterResponse` topology updates, endpoint registration, default fallback behavior, rack-capable eager metadata requests, one-shot request gating, missing-node metadata refresh, concurrent discovery and reconciliation, and recovery of recognized but unregistered broker SNI hostnames.
* `kroxylicious-docs`, to document the new SNI token, mapping configuration, default behavior, and lifecycle.

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

* If `advertisedBrokerAddressPattern` does not contain `$(rackAddress)`, Kafka rack metadata is ignored.
* Existing tokens retain their current meaning.
* Strategies that do not use rack metadata continue to generate broker addresses from node ID alone.

There are compatibility considerations for `$(rackAddress)`.
When the token is present, `rackAddressMappings` is required and must be non-empty.
Mapping entries must have unique `rackId` keys.
`defaultRackAddress` is also required.
After topology has been learned from a rack-capable response, the default is used if a broker reports no rack ID or reports a rack ID without a configured mapping.
The default is an explicit availability choice for missing or unmapped rack values and may produce non-optimal rack-aware routing until the topology or mapping is corrected.
It is not used for pre-metadata endpoint registration or as a substitute for metadata discovery.

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

Inline token defaults such as `$(rackAddress:az1)` were also rejected because token-level default syntax would imply that other tokens should support the same form.
Defaults belong to the rack address label configuration rather than the generic address templating language.

### Using the default for pre-metadata endpoints

Using `defaultRackAddress` to eagerly register broker endpoints before metadata is known was rejected.
It would create addresses that are not derived from current broker topology and would conflate an unknown topology with a known broker whose rack ID is missing or unmapped.
The existing metadata-discovery binding and `EagerMetadataLearner` lifecycle provide recovery without guessing broker placement.

### Making rack-derived addressing mandatory

Making Kafka rack metadata mandatory was rejected because many Kafka clusters either do not configure broker rack values or do not need rack-derived DNS names.
The feature should be opt-in and compatible with existing deployments.
