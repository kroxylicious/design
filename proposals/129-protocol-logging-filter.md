# 129 - Protocol logging filter

Add a first-party filter that logs Kafka requests and responses passing through the proxy as a
readable, wire-level protocol trace, for use in debugging and demonstrations.

## Current situation

Kroxylicious decodes the Kafka protocol in order to run filters, but offers no way to observe
that traffic. When a client misbehaves, or when someone wants to understand what a consumer
group rebalance actually looks like on the wire, there is nothing in the distribution that shows
it.

A proof of concept exists outside the project in the form of the
[kroxylicious-connect-filter](https://github.com/katheris/kroxylicious-connect-filter), which
observes interactions between Kafka Connect workers and the broker. It handles four API keys —
`FindCoordinator`, `JoinGroup`, `SyncGroup` and `Heartbeat` — with formatting written by hand for
each. Kafka defines around ninety API keys, most with several protocol versions whose field sets
differ, so this approach does not extend to general use.

Kafka's generated message classes do provide `toString()`, but the output is a single dense line
per message, does not distinguish a request from a response, and is not machine-parseable.

Kafka brokers have their own request logging. That is a different vantage point: it does not see
traffic as the proxy sees it, before or after other filters in the chain have transformed it, and
it is not available to someone running the proxy who does not administer the broker.

## Motivation

Three audiences benefit:

- **Debugging.** Seeing the exact requests a client sends, the versions it negotiates, and the
  errors it receives is often the fastest route to a diagnosis. This is particularly true for
  problems that only appear in the presence of the proxy.
- **Filter development.** Contributors writing filters currently have no convenient way to see
  what the messages they are handling actually contain.
- **Demonstration and learning.** The Kafka protocol is not widely understood in detail. A trace
  showing a client connecting, negotiating versions, authenticating, joining a group and fetching
  makes the protocol concrete in a way documentation does not.

The proxy is unusually well placed to provide this. It already decodes the protocol, it sits
between client and broker, and it sees traffic at a point in the filter chain that the operator
controls.

## Proposal

Add a `ProtocolLogging` filter to `kroxylicious-filters`, shipped in the distribution.

### Scope: a wire-level trace, not a curated view

The filter emits what was on the wire for the configured API keys, rather than a summarised or
interpreted view of client behaviour. This is a deliberate choice. A curated view — of the kind
the Connect filter proof of concept produces — is more readable but requires per-API code and
editorial judgement about which fields matter. A trace is complete, generic, and useful for
problems nobody anticipated.

A consequence is that the filter should be version-aware: a field that did not exist at the
negotiated API version must not appear in the output. For a tool whose purpose is showing what
was actually transmitted, a field appearing at a default value when the client never sent it is
misleading, and version negotiation problems are exactly the kind of thing someone would use this
filter to investigate.

### Implementation approach

The filter implements the catch-all `RequestFilter` and `ResponseFilter` interfaces and forwards
every message unchanged. It is purely an observer; it never mutates traffic.

Message bodies are serialised by dispatching to Kafka's generated `*DataJsonConverter` classes,
which are version-aware and cover every message type without per-API code. Dispatch can reuse the
existing generated `KafkaApiMessageConverter`, which already maps `ApiMessageType` to the
appropriate converter for requests and responses separately.

That class currently lives in `kroxylicious-filter-test-support`. Depending on a test-support
module from a shipped filter is not ideal; the longer-term home for this generation is expected
to be settled as part of proposal 116, and the initial implementation can be repointed when that
lands.

### Output format

Each entry is a human-readable envelope line followed by the message body as indented JSON:

```
REQUEST  METADATA v13  corr=1  client=producer-1
{
  "topics" : [ {
    "topicId" : "AAAAAAAAAAAAAAAAAAAAAA",
    "name" : "test-logging"
  } ],
  "allowAutoTopicCreation" : true,
  "includeTopicAuthorizedOperations" : false
}
```

The envelope comes first so that the output can be scanned and grepped by API key. Proxy-side
context — notably the session identifier — is emitted as structured key-values rather than in the
envelope, since it is proxy state rather than protocol. Requests are paired with responses on
session identifier plus correlation identifier; correlation identifiers are only unique within a
connection, so the session is required to pair correctly.

### Configuration

```yaml
- type: ProtocolLogging
  config:
    logLevel: DEBUG                                        # default
    apiKeyNames: [METADATA, FIND_COORDINATOR, JOIN_GROUP]  # absent or empty = all
    maxBodyChars: 8192                                     # default, must be > 0
```

| Key | Type | Default | Purpose |
|---|---|---|---|
| `logLevel` | SLF4J level | `DEBUG` | Level at which entries are emitted, and the level the backend must be enabled at |
| `apiKeyNames` | list of `ApiKeys` names | all | Which API keys to log |
| `maxBodyChars` | integer | 8192 | Truncation limit for the body; the envelope is never truncated |

Invalid API key names and a non-positive `maxBodyChars` are rejected at startup rather than
discovered at log time.

### Enabling and disabling at runtime

The filter emits nothing unless the logging backend is also enabled at `logLevel` for the
filter's logger. Because `shouldHandleRequest` and `shouldHandleResponse` are consulted per
message, this check is live: an operator can deploy the same configuration everywhere and switch
tracing on or off by changing the logging backend on a running proxy, without a restart and
without a configuration change. With Log4j 2 this requires `monitorInterval` in the logging
configuration.

Defaulting `logLevel` to `DEBUG` means the filter is quiet unless deliberately enabled.

### Cost

Implementing the catch-all filter interfaces would ordinarily force full decoding of all traffic.
Gating `shouldHandleRequest` and `shouldHandleResponse` on the configured API key set and the log
level avoids this: messages the filter is not interested in are never deserialised, and are
forwarded as opaque frames as they are today.

Note that decoding is shared across the chain, so this only avoids cost for API keys that no
other filter in the chain requires.

### Security

Bodies of credential-bearing API keys are never logged. The exclusion list is hardcoded and
deliberately not configurable:

- `SaslAuthenticate` — carries credential material for PLAIN and SCRAM
- `CreateDelegationToken` — the response carries the token HMAC, which is itself a credential
- `AlterUserScramCredentials` — carries salt and salted password material
- `DescribeDelegationToken`

For these keys the converter is not invoked at all; the body is structurally withheld rather than
filtered after the fact. The envelope is still emitted, so an operator can see that a handshake
occurred and correlate it, without the credential material appearing:

```
REQUEST  SASL_AUTHENTICATE v2  corr=2147483642  client=producer-1
<body withheld: credential-bearing API>
```

Making this list configurable was considered and rejected. A user with a concrete need can raise
an issue; the default should not be something an operator can accidentally weaken.

Record payloads are not logged. Kafka's generated JSON converters emit an empty byte array for
records-typed fields regardless of their contents, so the payload does not reach the output at
all. This is the desired behaviour independently: record contents are user data, potentially
personal or regulated, and the value of this filter lies in showing message flow rather than
message content.

## Affected/not affected projects

**Affected:**

- `kroxylicious/kroxylicious` — a new module under `kroxylicious-filters`, included in the
  distribution, and new plugin configuration YAML.

**Not affected:**

- `kroxylicious/kroxylicious-operator` — the filter is configured like any other and needs no
  operator awareness beyond the existing `KafkaProtocolFilter` mechanism.
- `kroxylicious/design` proposal 116 — this proposal depends on the outcome of that work for the
  eventual home of the generated converters, but does not constrain it.
- Existing filters — the filter is an observer and forwards messages unchanged. Its presence
  changes what is decoded, not what is transmitted.

## Compatibility

The plugin configuration YAML introduced here becomes public API and must remain compatible with
existing configurations. The surface is deliberately small: three keys, all optional, all with
defaults, so a configuration specifying only `type: ProtocolLogging` is valid and remains so.

The output format is not proposed as a compatibility surface. It is intended for human reading
and ad-hoc grepping, not for machine parsing, and should be free to improve. If a stable
machine-readable format is wanted later, that should be a separate proposal with its own
guarantees.

The hardcoded credential exclusion list is expected to grow as Kafka adds APIs. Adding to it is
not a breaking change.

The proposed `logLevel` default of `DEBUG` means adding the filter to an existing configuration
produces no output until the logging backend is also configured, which avoids surprising volume
on upgrade.

## Rejected alternatives

**Hand-written formatting per API key.** The approach taken by the Connect filter proof of
concept. Produces the most readable output, but does not scale to ninety API keys across multiple
protocol versions, and the field sets change between Kafka releases.

**Kafka's `toString()`.** Available at no cost, but emits one dense line, does not distinguish
requests from responses, and cannot be piped into tooling.

**Jackson `ObjectMapper` over the message POJOs.** Serialising the generated classes by field
rather than by getter was investigated as a way to avoid depending on Kafka's generated converter
classes, given ongoing work to keep Kafka internal classes out of the public API. It works
mechanically, but it is not version-aware: it emits every field the class declares, including
fields that did not exist at the negotiated version, at their default values. For a filter whose
purpose is showing what was on the wire, that is a material loss. `JsonInclude.NON_DEFAULT` does
not recover it, because Jackson compares against Java defaults rather than Kafka protocol
defaults — for instance `preferredReadReplica` defaults to `-1`, meaning "not present", which
Jackson would treat as non-default and include.

**Configurable field-level redaction.** Allowing operators to name fields to scrub was
considered as a safety net beyond the hardcoded API key list. Rejected for now: it requires users
to know field names from generated classes, its value is speculative if the exclusion list is
correct, and a model-driven approach — annotating sensitive fields — would be a better shape if
this becomes necessary.

**An option to log record payloads.** Rejected. Beyond the data protection concerns, the result
depends on the filter's position in the chain: placed before a record encryption filter it would
log plaintext, placed after it would log ciphertext. An option whose meaning varies with
configuration in a way its name does not convey is misleading.

**Computing request/response latency.** Deferred. It would require the filter to hold state
across calls — a bounded map from correlation identifier to timestamp — which is the only part of
the design that could leak memory. Log timestamps and the correlation identifier already allow
latency to be derived. This can be added later if there is demand.

**Relying on broker request logging.** Does not require any change to Kroxylicious, but does not
serve the same purpose: it is unavailable to proxy operators who do not administer the broker,
and does not show traffic as the proxy sees it relative to other filters in the chain.

**Always-on audit logging.** A filter continuously recording all traffic for compliance purposes
would need sampling, back-pressure handling, structured output and retention design. That is a
substantially larger piece of work with different requirements, and is not proposed here.
