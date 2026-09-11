# 137 - Configurable upstream connect timeout

Add a `connectTimeout` key to `ClusterDefinition` that governs how long the proxy waits for the
TCP connect to an upstream broker to complete, defaulting to 10 seconds in place of Netty's
current 30-second default.

## Current situation

`ServerConnectionStateMachine#configureBootstrap` builds the Netty `Bootstrap` used for every
upstream connection. It sets `ChannelOption.AUTO_READ` and `ChannelOption.TCP_NODELAY` and nothing
else — `ChannelOption.CONNECT_TIMEOUT_MILLIS` does not appear anywhere in the codebase. In its
absence, Netty applies `DefaultChannelConfig.DEFAULT_CONNECT_TIMEOUT`, which is 30000ms in the
netty 4.2.17.Final used by the project. This is not a considered choice by Kroxylicious; it is
whatever Netty ships with, and it applies invisibly to every proxy deployment. This proposal is
about giving operators control over a timeout that already governs behaviour, not about
introducing a bound where none existed.

`configureBootstrap` has exactly one call site, inside `ServerConnectionStateMachine#connect`, so
the same 30-second bound governs both places the proxy dials upstream: the bootstrap connection
(address chosen from `TargetCluster#bootstrapServer()` via the configured selection strategy, round
robin by default) and per-broker connections, where `ClientConnectionStateMachine` resolves a
`BrokerEndpointBinding` to the broker's address and opens the server connection through the same
path.

## Non-goals

**DNS resolution is out of scope.** `ServerConnectionStateMachine#initConnection` calls
`bootstrap.connect(host, port)` with a hostname; Netty resolves the address before connecting, and
no custom `AddressResolverGroup` is configured anywhere in kroxylicious-runtime. The option this
proposal adds bounds the TCP connect only. A slow or hanging resolver is a separate failure mode
with its own remedy (a resolver timeout, or a different `AddressResolverGroup`), and folding it
into "connect timeout" would make the one number mean two different things depending on what is
slow.

**No operator/CRD exposure.** This proposal is scoped to `kroxylicious-runtime` configuration. The
operator constructs `TargetCluster` via its existing two-argument constructor and has no awareness
of the new key; exposing it through the CRD, if wanted, is a separate change with its own API
surface to design.

**No Kafka-style escalation.** Kafka's client escalates `socket.connection.setup.timeout.ms`
exponentially per node, backed by `ClusterConnectionStates`, a `Map<String, NodeConnectionState>`
owned by the long-lived `NetworkClient` that survives across connection attempts and accumulates a
failure count per node. Nothing in Kroxylicious plays that role. Every object involved in a
connection attempt — the `ServerConnectionStateMachine`, its `Bootstrap`, its outbound channel —
is torn down and discarded on failure via `onServerException` → `toClosed()` →
`ccsm.onServerConnectionException(cause)`. The only piece of state that survives a failed attempt
is the round-robin counter in the bootstrap selection strategy, and it counts connections handed
out, not failures. Escalation would require introducing a new per-address failure map with a
lifetime tied to `UpstreamClusterModel`, plus rules for when entries reset and expire — that is a
feature in its own right, not a parameter on this one.

**No jitter.** Not proposed, rather than judged inapplicable. The proxy itself does not retry
failed connects, so the exposure jitter would address is downstream, not proxy-side: many Kafka
clients connected through the same proxy, all stalling against the same blackholed address for the
same duration because the proxy applies one `connectTimeout` to every upstream dial, then
reconnecting on the same cadence. That is most visible right after a proxy restart, when every
client is on the cold path at once. Jitter on the value would spread that reconnect storm out; it
is simply not addressed here.

## Motivation

The problem only appears when an upstream address **silently drops** packets
rather than refusing the connection — a firewall or security group configured to
drop, a `NetworkPolicy` that does the same, or a dead host whose address still
routes. A refused connection returns in about one round trip and never comes
near the timeout. Silence is the only case that reaches it, which is why a
30-second wait buried in a networking library has gone this long without anyone
needing to configure it.

When it does happen, the proxy makes no attempt to recover. There is no retry
and no failover: the connect fails, the exception handling above tears the
attempt down, and the downstream connection goes with it. Progress past a bad
address depends entirely on the *client* reconnecting, which advances the shared
round-robin counter to the next address. The counter advances once per
downstream connection, not once per upstream attempt, so each bad address costs
a full timeout and a client reconnect before the next one is tried.

That makes the total cost scale with the number of bad addresses, and a client
has its own patience to spend. Measured with an `AdminClient` on default
timeouts, against a bootstrap list of one working broker behind unreachable RFC
5737 TEST-NET-1 addresses:

| Bad addresses ahead of the working one | `CONNECT_TIMEOUT_MILLIS` | Result | Elapsed |
|---|---|---|---|
| 1 | unset (30000) | success | 30702ms |
| 3 | unset (30000) | **failed** — `TimeoutException: Timed out waiting for a node assignment` | 60368ms |
| 1 | 2000 | success | 2652ms |
| 3 | 2000 | success | 7082ms |

The non-default rows were produced by hardcoding the option in
`configureBootstrap` on a scratch branch, since no configuration for it exists
yet — they show what the timings look like at a given value, not that the
mechanism proposed below works.

The three-address row is the important one: at today's default this is not
merely slow, it does not work at all. The client's own budget runs out before
the round robin reaches a broker that would have answered.

Total time tracks roughly the number of bad addresses multiplied by the timeout
in force, but not exactly — each address cost somewhat more than the configured
timeout (~650ms extra at one address, ~1080ms at three). That excess is too
large to explain by `reconnect.backoff.ms`, which defaults to 50ms, and is not
fully accounted for here.

The 30 seconds is the proxy's, not the client's. With the option unset the proxy
logs `connection timed out after 30000 ms`
(`io.netty.channel.ConnectTimeoutException`) at t+30009ms; raising the option to
50000 moved that log line to t+50010ms and total elapsed time to 50695ms, both
following the configured value rather than staying pinned at 30000ms. The
distinction is easy to miss because Kafka's `request.timeout.ms` also defaults
to 30000, putting the two timers in a race at today's default — one observed run
had the proxy's exception fire 9ms ahead of the client's, though that is a
single observation well inside ordinary scheduling jitter and not a claim that
the proxy reliably wins. A materially lower default removes the race rather than
resolving it in either direction.

Per-broker connections have it worse, because there is nothing to fall back to.
That address comes from cluster metadata via `BrokerEndpointBinding`, not from a
list, so a blackholed broker is a flat stall with no next address to advance to,
whatever the timeout is set to.

One caveat on the measurements: they all used `AdminClient`. A producer would
not fail the same way — it resends on `request.timeout.ms` with retries
effectively unbounded rather than raising that exception — so the "budget
exhausted, bootstrap fails" outcome is specific to what was tested and should
not be assumed to hold for producers or consumers.

## Proposal

### Where the configuration lives

The new key is added to `ClusterDefinition`, the config-time record that already carries
`bootstrapServers` and `tls`:

```yaml
clusterDefinitions:
  - name: my-cluster
    bootstrapServers: broker1.example.com:9092,broker2.example.com:9092
    connectTimeout: 10s
```

| Key | Type | Default | Purpose |
|---|---|---|---|
| `connectTimeout` | duration | `10s` | Maximum time to wait for the upstream TCP connect to complete, for both the bootstrap connection and per-broker connections to this cluster |

`connectTimeout` is a provisional name; a clearer one is welcome if reviewers have a better
suggestion.

`connectTimeout` is parsed with the project's existing `DurationSerde`, which already accepts
compact strings using d/h/m/s/ms/μs(us)/ns units, so `10s` and `500ms` are both valid without any
new parsing code.

`ClusterDefinition#toTargetCluster()` carries the value into `TargetCluster`, which remains the
runtime carrier for upstream connection details — the same role it already plays for
`bootstrapServers` and `tls`.

The value is deliberately **not** exposed on `VirtualCluster#targetCluster`, the inline,
`@Deprecated(since = "0.22.0", forRemoval = true)` alternative to a named `ClusterDefinition`,
which is tracked for removal by #4462 in the 0.25.0 milestone. Adding configuration to a form that
is scheduled to disappear in the same release means adding something that is immediately removed
again, and gives users configuring `targetCluster` today one more reason to put off migrating to
`clusterDefinitions` rather than one less.

This follows the shape of an existing, still-open gap: #4840 notes that `ClusterDefinition` has no
equivalent of `TargetCluster`'s `bootstrapServerSelection` YAML key, backed by the `selectionStrategy`
record component (`TargetCluster.java`). `ClusterDefinition#toTargetCluster()`
(`ClusterDefinition.java`) only ever calls the
two-argument `TargetCluster` constructor, so a `ClusterDefinition` has no way to set a non-default
selection strategy. A candidate fix is up as PR #4800, unmerged at time of writing. That change is
the same shape as this one — a new component added to `ClusterDefinition` and threaded through
`toTargetCluster()` — so it is precedent for the approach here rather than a dependency on it. This
is separate, ongoing work tracked under #4840.

### Reading the value

`ServerConnectionStateMachine` already holds an `UpstreamClusterModel`, whose first record
component is the `TargetCluster` for the connection. `configureBootstrap` can read
`upstreamClusterModel.targetCluster().resolveConnectTimeout()` directly and add:

```java
.option(ChannelOption.CONNECT_TIMEOUT_MILLIS, (int) upstreamClusterModel.targetCluster().resolveConnectTimeout().toMillis())
```

alongside the existing `AUTO_READ` and `TCP_NODELAY` options. No constructor or method signature
in the connect path needs to change to plumb the value through — it is already reachable from
where it is needed. The alternative of threading it through `ServerConnectionFactory#create`,
which already takes ten parameters behind a `@SuppressWarnings("java:S107")`, is avoided.

The `connectTimeout` field on `ClusterDefinition` and `TargetCluster` is `@Nullable`, not a
non-null `Duration` defaulted at construction. This follows the pattern `TargetCluster` already
uses for `selectionStrategy` (`TargetCluster.java`): the field carries no default itself, and a
`resolveConnectTimeout()` method — mirroring the existing `resolveSelectionStrategy()`
(`TargetCluster.java`), which applies `Objects.requireNonNullElse(selectionStrategy,
DEFAULT_SELECTION_STRATEGY)` — supplies the default at read time. `TargetCluster.java` explains
why the default isn't baked into the field itself: doing so would break fidelity between the
fluent-API and YAML-deserialized forms, so that a `ClusterDefinition` built in code and one parsed
from a config file that simply omits `connectTimeout` remain equal and round-trip the same way.
`resolveSelectionStrategy()` is private because its only callers, `bootstrapServer()` and
`toString()`, live inside `TargetCluster` itself; `resolveConnectTimeout()` needs to be visible to
`ServerConnectionStateMachine` in a different package, so it should be public rather than private.

`connectTimeout` should also be validated: negative durations are rejected, following the pattern
`NettySettings` already applies to its own duration fields. Its compact constructor calls a
`requireNonNegative` helper against each of `shutdownQuietPeriod`, `shutdownTimeout`,
`authenticatedIdleTimeout` and `unauthenticatedIdleTimeout` (`NettySettings.java`), throwing
`IllegalArgumentException` for a negative value. `TargetCluster` is the record that should carry
this check, in its own compact constructor: unlike `ClusterDefinition`, it is directly constructible
by the operator, so validating only in `ClusterDefinition`'s compact constructor would leave a
`connectTimeout` set that way unchecked. Because `ClusterDefinition#toTargetCluster()` always
constructs a `TargetCluster`, validating there covers configuration arriving through either route.

The cast in the option-setting code above is also worth bounding, not just performing:
`Duration#toMillis()` returns a `long`, while `ChannelOption.CONNECT_TIMEOUT_MILLIS` takes an
`int`, so reading the value requires a narrowing cast. Validating only non-negativity would let a
duration whose millisecond value overflows `int` (`Integer.MAX_VALUE` milliseconds is only about
24.8 days) silently wrap into a nonsensical timeout rather than fail at config load; the accepted
range should be capped well inside that bound.

### Choosing the default

The proposed default is **10 seconds**, down from Netty's 30. This is reasoned from Kafka's own
client defaults, not measured: none of the measurements above tested a 10-second bound end to end,
and the figure should be read as an argument from first principles rather than an empirically
tuned value.

The anchor is `socket.connection.setup.timeout.ms`, which Kafka clients default to 10000 before
escalating to 20000 then to a ceiling of 30000 (`socket.connection.setup.timeout.max.ms`) with ±20%
jitter on each step. A flat 10-second proxy-side timeout adopts Kafka's *opening* value, not its
escalation behaviour — deliberately, per Non-goals above. Kafka escalates to give a struggling
broker more time on successive attempts; the proxy's connect timeout instead guards against an
address that is not merely struggling but unreachable, where waiting longer on a second attempt
buys nothing.

Ten seconds also leaves room for the TCP stack to attempt more than one SYN before giving up —
Linux's default SYN retransmission schedule retries at roughly 1s and 3s after the initial attempt
— so a single lost SYN does not immediately read as a hard failure, while still sitting well clear
of every client-side bound this proposal has cited (`request.timeout.ms` at 30000 across
`AdminClientConfig`, `ProducerConfig` and `ConsumerConfig`; `default.api.timeout.ms`/`max.block.ms`
at 60000). At today's 30-second default the proxy's own timeout and the client's `request.timeout.ms`
can race, as noted in Motivation; a 10-second default removes that race rather than trying to win
it.

### Testing

`ServerConnectionStateMachineTest` currently overrides `configureBootstrap` in four anonymous
subclasses to stub out real bootstrap construction. A test asserting on the new option cannot use
those subclasses — overriding the method is exactly what would hide a regression in it. New tests
need to exercise the real `configureBootstrap` and assert on the `Bootstrap`'s configured
`ChannelOption.CONNECT_TIMEOUT_MILLIS`, covering both the default (absent config) and an explicit
override.

`ResilienceIT#shouldBeAbleToBootstrapIfMultipleBootstrapUnavailable` is not a useful regression
test for this change as it stands: it uses `ImmediateCloseSocketServer`, which accepts the TCP
connection before closing it, so the connect itself succeeds and the test never reaches
`CONNECT_TIMEOUT_MILLIS` at all — it exercises rejection, not the silent-drop case this proposal
addresses. A regression test for the silent-drop scenario needs an address that accepts no
connection at all (a non-routable or firewalled address), which is a different fixture from the
one already in that suite.

## Affected/not affected projects

**Affected:**

- `kroxylicious/kroxylicious` — `ClusterDefinition` and `TargetCluster` in kroxylicious-runtime gain
  the new field; `ServerConnectionStateMachine#configureBootstrap` reads it. Documentation and the
  changelog need an entry for the new key and the changed effective default.

**Not affected:**

- `kroxylicious/kroxylicious-operator` — constructs `TargetCluster` via the existing two-argument
  constructor and has no path to the new field; it is unaffected until and unless a future change
  exposes it through the CRD (see Non-goals).
- Existing configurations — `connectTimeout` is optional and additive; a `ClusterDefinition` that
  does not set it keeps loading exactly as before.

## Compatibility

`connectTimeout` is an additive, optional key on `ClusterDefinition`; existing configurations parse
unchanged. The *effective* default does change, from Netty's 30 seconds to this proposal's 10, which
is an observable behaviour change for anyone relying on the old figure, even though nothing in their
configuration file changes.

The new key is only reachable through `clusterDefinitions` / `ClusterDefinition`, not through the
deprecated inline `targetCluster` form, so a user still on `targetCluster` gets the new 10-second
default and cannot override it without migrating to `clusterDefinitions` — which is available
today, just a change of config shape rather than an added key. That is judged acceptable on the
assumption that `targetCluster` is removed in the same release this ships in, per #4462's 0.25.0
milestone; if that removal slips past this proposal's release, the fallback is to either expose
`connectTimeout` on `targetCluster` after all, or hold the default change until #4462 lands, rather
than ship a changed default to a config form with no in-place opt-out.

## Future extensions

**Intra-connection failover across the bootstrap list.** Today, a failed connect to one bootstrap
address is not retried by the proxy itself — the attempt is torn down and it is left to the
downstream client to reconnect and, via the shared round-robin counter, eventually land on a
different address. A natural complement to a shorter, configurable timeout is having the proxy try
the next address in the list itself before giving up, rather than relying on the client's own retry
behaviour to make progress. This is deferred rather than folded into this proposal because it needs
design of its own: where the iteration state over the address list would live and how long it
persists, how it interacts with the configured `BootstrapSelectionStrategy` (round robin today, per
`TargetCluster#selectionStrategy`), and what happens to the downstream connection while the
proxy is still working through the list. It is the other half of making bootstrap resilient to a
partially unavailable list — this proposal shortens the wait per address, that work would reduce how
many addresses a client has to force the proxy through — and likely warrants its own issue rather
than an addendum here.

## Rejected alternatives

**A `NettySettings` field.** `NettySettings` already exists and is documented as tuning "a Netty
event loop group"; `NetworkDefinition` uses it to configure the management and proxy event loop
groups, both of which are downstream-facing. Putting a connect timeout there would apply it
proxy-wide rather than per upstream cluster, is the wrong semantic axis (it configures listener-side
event loops, not an upstream dial), does not reach `ServerConnectionStateMachine` without new
plumbing, and would still need routing through the ten-parameter `ServerConnectionFactory#create`
that `ClusterDefinition` avoids by being already reachable via `UpstreamClusterModel`.

**A `network.upstream` sibling to `NettySettings`.** More semantically honest than reusing
`NettySettings`, since it would be scoped to upstream connections rather than downstream listeners,
but it is a new top-level config concept with no more precedent in the codebase than
`ClusterDefinition` already has, and would cost the same plumbing to reach `configureBootstrap`
while adding a place to look up rather than reusing one that is already the natural home for
per-cluster upstream settings.

**An overall connection deadline instead of a per-attempt timeout.** Kafka's own
`default.api.timeout.ms`/`max.block.ms` model an overall deadline across multiple retried attempts.
That model does not map onto the proxy: there is no multi-attempt loop inside
`ServerConnectionStateMachine` to put a deadline around — a failed connect is torn down immediately,
and any retrying happens above the proxy, in the client's own reconnect logic. A per-attempt timeout
is the only quantity the proxy actually controls today.

**Leaving the 30-second default and only adding configurability.** Adds control without changing
behaviour for anyone who does not act on it, and the motivation above shows the current default is
a source of surprise precisely because nobody previously had reason to look for it. A default that
requires an operator to already know about the problem to fix it helps only the users who have
already diagnosed it themselves.
