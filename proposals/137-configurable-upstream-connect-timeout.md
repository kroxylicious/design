# 137 - Configurable upstream connect timeout

Add a `connectTimeout` key to `ClusterDefinition` that governs how long the proxy waits for the
TCP connect to an upstream broker to complete. Netty's existing 30-second default is retained when
the key is unset; setting it changes behaviour only for the clusters that opt in.

## Current situation

The proxy sets no connect timeout on its upstream connections — `ServerConnectionStateMachine`,
which builds the Netty bootstrap for each one, configures only auto-read and TCP no-delay. Netty's
own default of 30 seconds therefore applies. That is not a considered choice by Kroxylicious; it is
whatever Netty ships with, and it governs every deployment today, invisibly and with no way to
change it. This proposal is about taking control of a bound already in force, not introducing one.

It applies to both places the proxy dials upstream: the bootstrap connection, whose address is
chosen from the cluster's `bootstrapServers` by the configured selection strategy (round robin by
default), and per-broker connections, whose addresses come from cluster metadata.

## Non-goals

**DNS resolution.** The proxy connects by hostname and Netty resolves the name before the connect
begins, so this bounds the TCP connect only. A slow or hanging resolver is a separate failure mode
with its own remedy; folding it in would make one number mean two different things depending on
which part was slow.

**Operator/CRD exposure.** Scoped to proxy configuration. The operator has no path to the new key;
surfacing it through the CRD is a separate change with its own API surface to design.

**Kafka-style escalation.** Kafka clients lengthen their connect timeout on each successive failure
against a node, because a long-lived client object holds a per-node failure count. The proxy has no
equivalent: everything involved in an upstream connection attempt is discarded when the attempt
fails, and the only state outliving it is the round-robin counter, which counts connections handed
out rather than failures. Escalation would mean introducing per-address failure state with its own
lifetime and reset rules — a feature in its own right.

**Jitter.** Not proposed, rather than judged inapplicable. Every client behind the proxy stalls for
the same duration against a blackholed address and reconnects on the same cadence, most visibly
after a proxy restart. Jitter would spread that out; it is simply not addressed here.

## Motivation

The problem only appears when an upstream address **silently drops** packets rather than refusing
the connection — a firewall or security group configured to drop, a `NetworkPolicy` that does the
same, or a dead host whose address still routes. A refused connection returns in about one round
trip and never comes near the timeout. Silence is the only case that reaches it, which is why a
30-second wait buried in a networking library has gone this long without anyone needing to
configure it.

When it does happen, the proxy makes no attempt to recover. There is no retry and no failover: the
connect fails, the attempt is torn down, and the downstream connection goes with it. Progress past
a bad address depends entirely on the client reconnecting, which advances the shared round-robin
counter to the next address. That counter advances once per downstream connection, not once per
upstream attempt, so each bad address costs a full timeout and a client reconnect before the next
is tried.

Total cost therefore scales with the number of bad addresses, and the client has its own patience
to spend. Measured with an `AdminClient` on default timeouts, against a bootstrap list of one
working broker behind unreachable RFC 5737 TEST-NET-1 addresses:

| Bad addresses ahead of the working one | Connect timeout | Result | Elapsed |
|---|---|---|---|
| 1 | unset (30s) | success | 30702ms |
| 3 | unset (30s) | **failed** — `TimeoutException: Timed out waiting for a node assignment` | 60368ms |
| 1 | 2s | success | 2652ms |
| 3 | 2s | success | 7082ms |

The non-default rows were produced by hardcoding the option on a scratch branch, since no
configuration for it exists yet — they show what the timings look like at a given value, not that
the mechanism proposed below works.

The three-address row is the important one: at today's default this is not merely slow, it does not
work at all. The client's own budget runs out before the round robin reaches a broker that would
have answered.

Total time tracks roughly the number of bad addresses multiplied by the timeout in force, but not
exactly — each address cost somewhat more than the configured timeout (~650ms extra at one address,
~1080ms at three), which is not fully accounted for here. All runs used an `AdminClient`; a producer
resends rather than failing, so the outright-failure outcome should not be assumed to generalise.

The 30 seconds is the proxy's bound, not the client's. On the same scratch branch, raising the
option to 50 seconds moved both the proxy's connect-timeout exception and the total elapsed time
with it, confirming the proxy gives up rather than the client. The distinction is easy to miss
because Kafka's `request.timeout.ms` also defaults to 30 seconds, putting the two timers in a race
at today's default.

Per-broker connections have it worse, because there is nothing to fall back to. That address comes
from cluster metadata rather than a list, so a blackholed broker is a flat stall with no next
address to advance to, whatever the timeout is set to.

The same key serves the opposite need. Operators on high-latency links or in test environments have
hit the reverse problem, where 30 seconds is too *short*, and today have no way to raise it.

## Proposal

### Configuration

```yaml
clusterDefinitions:
  - name: my-cluster
    bootstrapServers: broker1.example.com:9092,broker2.example.com:9092
    connectTimeout: 10s
```

| Key | Type | Default | Purpose |
|---|---|---|---|
| `connectTimeout` | duration | 30s (Netty's default, applied when the key is unset) | Maximum time to wait for the upstream TCP connect to complete, for both the bootstrap connection and per-broker connections to this cluster |

`connectTimeout` is a provisional name and a clearer one is welcome. It uses the proxy's existing
duration format, so `10s` and `500ms` are both valid.

The behaviour this implies:

- The value is per-cluster. Each cluster definition carries its own, and clusters that do not set
  one keep the 30-second default.
- The default is applied when the value is read, not stored on the field. A cluster built through
  the fluent API and one parsed from YAML that omits the key therefore remain equal.
- Negative durations are rejected at configuration load.
- The accepted range is bounded, so a value cannot overflow the millisecond `int` that the
  underlying channel option takes.

`ClusterDefinition` carries the key and hands it to `TargetCluster`, which stays the runtime carrier
for upstream connection details and is where resolution and validation belong. This is the same
shape as the change that added `bootstrapServerSelection` to `ClusterDefinition` (#4840).

The value is deliberately **not** exposed on the deprecated inline `targetCluster` form, tracked for
removal by #4462 in the 0.25.0 milestone. Adding configuration to a form scheduled to disappear in
the same release means adding something that is immediately removed again.

### Retaining Netty's default

The default stays at 30 seconds. Keeping it makes the change purely additive: no deployment behaves
differently on upgrade until an operator sets the key on a cluster.

A lower default would trade a known, already-survivable problem for a silent regression in
deployments that work today. A healthy connect can legitimately take longer than 10 seconds — Linux
retransmits a lost SYN at roughly 1s, 3s, 7s and 15s, so a connect dropping four SYNs still succeeds
at around 15 seconds under the current bound, and a broker whose accept backlog is full under load
behaves the same way. A 10-second default would abort both, even though nothing about them was
broken. The 15-second retransmission in particular is what rules out a flat 10 seconds: a bound
clearing only the 1s and 3s retries would kill connections that were always going to succeed.

Kafka's own client defaults remain useful as guidance for an operator choosing a value, rather than
as justification for changing this default. Kafka defaults `socket.connection.setup.timeout.ms` to
10 seconds, escalating to a 30-second ceiling, which makes 10 seconds a sensible starting point for
an operator tuning downward — reasoned from Kafka's defaults, not measured against this proxy.

### Testing

The existing `ResilienceIT` bootstrap test does not cover this path: its fake servers accept the TCP
connection before closing it, so the connect succeeds and the timeout is never reached. A regression
test needs an address that accepts no connection at all — a non-routable or firewalled address —
which is a different fixture from the one in that suite. Unit coverage needs to exercise the real
bootstrap construction rather than the stubs used today, asserting the configured option for both
the default and an explicit override.

## Affected/not affected projects

**Affected:**

- `kroxylicious/kroxylicious` — `ClusterDefinition` and `TargetCluster` gain the new field, and the
  upstream bootstrap reads it. Documentation and a changelog entry for the new key.

**Not affected:**

- `kroxylicious/kroxylicious-operator` — has no path to the new field; unaffected until and unless a
  future change exposes it through the CRD (see Non-goals).
- Existing configurations — the key is optional and additive, and the default is unchanged.

## Compatibility

`connectTimeout` is an additive, optional key on `ClusterDefinition`. Existing configurations parse
unchanged, and because the default is unchanged they behave identically too — nothing is observable
on upgrade unless an operator explicitly sets the key.

## Future extensions

**Intra-connection failover across the bootstrap list.** A failed connect is not retried by the
proxy; progress depends on the client reconnecting. A natural complement to a configurable timeout
is having the proxy try the next address itself before giving up. Deferred because it needs design
of its own — where the iteration state lives and how long it persists, how it interacts with the
configured selection strategy, and what happens to the downstream connection meanwhile. It is the
other half of making bootstrap resilient to a partially unavailable list, and warrants its own
issue.

## Rejected alternatives

**A `NettySettings` field.** `NettySettings` tunes Netty event loop groups, and `NetworkDefinition`
applies it to the management and proxy listeners — both downstream-facing. A connect timeout there
would be proxy-wide rather than per upstream cluster, and on the wrong semantic axis: it configures
listener-side event loops, not an upstream dial.

**A `network.upstream` sibling to `NettySettings`.** More semantically honest, since it would be
scoped to upstream connections, but it introduces a new top-level config concept and a second place
to look, rather than reusing the record that is already the natural home for per-cluster upstream
settings.

**An overall connection deadline instead of a per-attempt timeout.** Kafka's `default.api.timeout.ms`
and `max.block.ms` model a deadline across multiple retried attempts. That does not map onto the
proxy: there is no multi-attempt loop to put a deadline around, since a failed connect is torn down
immediately and any retrying happens above the proxy in the client's reconnect logic. A per-attempt
timeout is the only quantity the proxy controls.

**Lowering the default below 30 seconds.** Considered and rejected on review — existing deployments
may depend on the current bound in slow-network environments, and some test environments need
*longer* rather than shorter.
