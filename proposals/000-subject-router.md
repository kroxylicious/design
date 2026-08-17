# 000 - Subject Router

A concrete `Router` implementation that routes all Kafka traffic for a connection to a
single upstream cluster based on the authenticated subject's identity and the Kafka client ID.

## Current situation

[Proposal #70](070-routing-api.md) defined the Router API and the runtime infrastructure for
multi-cluster routing. The project does not yet ship any concrete `Router` implementations.
Test routers (`PassThroughRouterFactory`, `PrincipalRouterFactory`, `ClientIdRouterFactory`)
exist in the integration test tree but are not part of the distribution.

Subject-based routing is referenced in Proposal #70 as a motivating use case
("principal-aware routing") but was left for a subsequent proposal.

## Motivation

Two deployment patterns need a way to pin client connections to clusters based on identity:

**Centralised authentication and authorisation.** Large organisations with multiple Kafka
clusters run by separate teams want a single proxy entry point that authenticates clients
(via SASL termination) and routes them to the correct cluster. Combined with the
authorisation filter, this gives a centralised control plane without requiring each team to
manage their own authentication infrastructure.

**Phased cluster migration.** When migrating applications from one cluster to another
(assuming offset-preserving topic mirroring such as KIP-1279), the cluster administrator
can re-route individual subjects to the new cluster incrementally, without requiring
application configuration changes. Remaining subjects continue on the old cluster.
Note, however, that Subject-based routing does not address the cluster migration use case _in general_: When client applications with different Subjects have topic(s) in common they cannot be migrated individually. In the worst case, all the applications are connected by such topics and phased migration using a Subject-based approach cannot work.

Both patterns share a common property: the routing decision is per-connection (not
per-request) and is determined by the authenticated identity of the client. The subject
router is a relatively simple concrete router — apart from `API_VERSIONS`, it does not decompose requests, fan out, or recompose responses. Every other request on a connection follows the route established once authentication has succeeded.

### Why (Subject, clientId) pairs

Apache Kafka's quota system uses the (user, client-id) pair as its matching key, with
an 8-level precedence hierarchy from most specific to least. This is a natural fit for
routing too: an organisation might route most traffic for a user to one cluster, but
redirect specific client IDs (e.g. batch processors, monitoring tools) to a different
cluster.

The Kroxylicious `Subject` is more general than the Kafka model. Where Kafka has a 
single principal, Kroxylicious's `Subject` contains a set of `Principal` instances of different types. The subject router generalises the Kafka user to match on any 
principal type — the `java.lang.Class` of the principal is a parameter of the selector. 
This is the same model that was used for the ACL authorizer.
Assuming a suitable `SubjectBuilder` which populates `Subjects` with a `Team` 
principal in addition to per-applications `User` principels, it would allow for 
convenient `Team`-based routing, rather than forcing routing policies to be 
always expressed in tersmf of `Users`.

## Proposal

### Matching model

A routing rule specifies zero or more **principal selectors** and an optional **clientId**
constraint. All principal selectors must match (AND semantics) for the rule to apply.

```yaml
principals: 
  - type: User
    name: alice
  - type: com.example.Role
    name: admin
clientId: producer-1
route: cluster-a
```

Each principal selector has:
- A **type** — the `java.lang.Class<? extends Principal>` to match against, specified as a
  class name in configuration. For built-in principals (currently only `User`), it's 
  allowed to use an unqualified name which is resolved in package
  `io.kroxylicious.proxy.authentication`; custom principal types use their
  fully-qualified name.
- An optional **name** — an exact string to match against `Principal.name()`. If omitted,
  the selector matches any principal of the given type.

The set of principal types is open. The router has no compile-time dependency on specific
principal types. At `initialize()` time, type strings are resolved via `Class.forName()` and
validated to implement `Principal`. At runtime, `subject.principals()` are checked with
`principalClass.isInstance(p)`.

#### First-match-wins evaluation

Rules are evaluated in **configuration order**. The first matching rule wins.
Typical convention is to place more specific rules before broader ones:

```yaml
rules:
  # Most specific first
  - principals: [{type: User, name: alice}, {type: com.example.Role, name: admin}]
    clientId: producer-1
    route: cluster-a

  # Then broader rules
  - principals: [{type: User, name: alice}]
    route: cluster-a

  # Then catch-all
  - route: cluster-default
```

A broader rule listed before a narrower one will shadow it — this is deliberate and
expected, not an error. The administrator may want exactly this behaviour.

#### Relationship to the Kafka 8-level model

Kafka quotas use an implicit specificity-based precedence over (user, client-id) pairs.
The subject router does not replicate this implicit ordering. Instead, the administrator
expresses their intended precedence directly through rule ordering. This is simpler to
reason about and avoids the need to understand a scoring system.

### Configuration

```yaml
routerDefinitions:
  - name: identity-router
    type: SubjectRouter
    config:
      rules:
        - principals:
            - type: User
              name: alice
            - type: com.example.Role
              name: admin
          clientId: producer-1
          route: cluster-a

        - principals:
            - type: User
              name: alice
          route: cluster-a

        - principals:
            - type: com.example.Role
              name: batch-ops
          route: cluster-batch

        - clientId: monitoring-client
          route: cluster-monitoring

        - route: cluster-default               # catch-all
      defaultRoute: cluster-default
    routes:
      - name: cluster-a
        id: 0
        target: { cluster: kafka-a }
      - name: cluster-batch
        id: 1
        target: { cluster: kafka-batch }
      - name: cluster-monitoring
        id: 2
        target: { cluster: kafka-monitoring }
      - name: cluster-default
        id: 3
        target: { cluster: kafka-default }
```

#### Config records

```java
record Config(List<ConfigRule> rules, @Nullable String defaultRoute)
record ConfigRule(@Nullable List<PrincipalRef> principals,
                  @Nullable String clientId,
                  String route)
record PrincipalRef(String type, @Nullable String name)
```

#### Validation (at `initialize()` time)

- Every `route` referenced in rules must exist in `context.routeNames()`.
- `defaultRoute`, if specified, must also exist in `context.routeNames()`.
- Each `PrincipalRef.type` must resolve via `Class.forName()` to a class that
  implements `Principal`.

### Runtime behaviour

#### Per-connection caching

The subject router is designed to be used with a SASL termination filter on the virtual
cluster filter chain. Once authentication completes, the `Subject` is stable for the
lifetime of the connection. The resolved route is cached on the per-connection `Router`
instance after first resolution, and reused for all subsequent requests without
re-evaluation.

Note that the assumption that the whole set of `Principals` in each `Subject` is 
stable, even after reauthentication, is in conflict with the contract currently 
offered by `FilterContext#clientSaslAuthenticationSuccess()`.

#### `API_VERSIONS` handling

The Kafka protocol sends an `API_VERSIONS` request before SASL authentication begins.
At this point the `Subject` is anonymous, so the router does not yet know which route the
client will be assigned to.

Forwarding `API_VERSIONS` to a single arbitrary route would be incorrect: the client would
learn the version ranges of that cluster, but might later be routed to a different cluster
with different version support. The client would then use an unsupported version, causing
failures.

To avoid this, the router fans out the `API_VERSIONS` request to all routes
concurrently, collects the responses, and computes the intersection of supported
version ranges for each API key. For each API key present in every response, the
intersected range is `[max(minVersions), min(maxVersions)]`. API keys with no common
range, or absent from any response, are excluded from the result.
This guarantees that the client negotiates versions compatible with every cluster it could
be routed to.

For any non-`API_VERSIONS` request that arrives before authentication (which should not
happen in normal protocol flow), the router forwards to the first available route without
caching. Note that this situation is not possible when the `SaslTermination` filter is configured on the VC filter chain.

#### Static vs dynamic routing

The subject router does not use `staticRoutes()`. All API keys are dynamically routed
through `onRequest()` because the route is not known until the `Subject` is inspected,
and `API_VERSIONS` requires fan-out.
Since the route is cached per connection, the cost is a single field read after the
first resolution.

#### No-match behaviour

If no rule matches and no `defaultRoute` is configured, the router responds with
`ClusterAuthorizationException` and closes the connection. This is a fail-closed default
consistent with the security model.

### Lookup data structure

The `RoutingTable` is built once at `initialize()` time, is immutable and thread-safe
(shared across all per-connection `Router` instances via the `RouterFactory`'s
initialisation data parameter `I`).

Rules are stored in configuration order. At runtime, `resolve(Subject, clientId)` performs
a linear scan, returning the first match. For each rule, matching checks that every
principal selector finds a
corresponding principal in the `Subject` (via `Class.isInstance()` and optional
`name.equals()`) and that the clientId matches if specified.

Since the resolved route is cached per connection, the linear scan cost is paid only once.
For typical configurations (tens of rules, 1-4 principals per Subject), this is fast.

### Module structure

The router lives in `kroxylicious-routers/kroxylicious-router-subject`, under a new
`kroxylicious-routers` aggregator module (following the pattern of `kroxylicious-filters`).
The package is `io.kroxylicious.proxy.router.subject`.

The module depends on `kroxylicious-api` (for `Router`, `RouterFactory`, `Subject`,
`Principal`) and has no additional runtime dependencies.

## Affected/not affected projects

**Affected:**

- `kroxylicious/kroxylicious` — a new module under `kroxylicious-routers`, included in
  the distribution via `kroxylicious-app` and `kroxylicious-bom`.

**Not affected:**

- `kroxylicious-api` — no changes. The router uses the existing `Router`, `RouterFactory`,
  `Subject`, and `Principal` interfaces. No new principal types are introduced to the API.
- `kroxylicious-runtime` — no changes. The router is a plugin; the runtime already
  provides everything it needs.
- `kroxylicious-operator` — the router is configured like any other via
  `KafkaProtocolFilter`-style mechanisms. No operator awareness is needed beyond the
  existing `RouterDefinition` support.
- Existing filters, KMS, authoriser — no changes.

## Compatibility

The router plugin configuration YAML introduced here becomes public API. The surface is
deliberately small: `rules` (a list of rule objects) and `defaultRoute` (a string).

Configuration changes that add or remove rules can be applied via the existing hot-reload
mechanism.

## Rejected alternatives

**Hardcoded principal types (Role, Group, ServiceAccount).** An early design defined
concrete principal types in the router module. This was rejected because the set of
principal types is inherently open — organisations use their own principal types for
directory-service integration. Using `java.lang.Class` as the selector parameter,
following the ACL authorizer's model, keeps the router agnostic to specific types.

**Specificity scoring.** An early design computed a specificity score for each rule
(+2 per named principal, +1 per type-only principal, +1 per clientId) and evaluated
rules in score order rather than configuration order. This was rejected because it
introduces implicit reordering — the administrator writes rules in one order, but the
router silently evaluates them in another. This makes the configuration harder to
reason about and debug. First-match-wins is the standard model for ordered rule lists
and requires no understanding of a scoring system.

**Fixed 8-level precedence (Kafka quota model).** The Kafka quota model uses an
implicit specificity hierarchy over (user, client-id) pairs. For a YAML rule list,
explicit ordering is simpler and more flexible — the administrator expresses their
intended precedence directly rather than relying on implicit rules.

**Tiered hash map lookup.** An early design used per-level `HashMap` structures (one map
per specificity level) for O(1) lookups. This was rejected in favour of a sorted list
with linear scan because: (a) multi-principal AND-semantics selectors do not decompose
cleanly into hash keys, (b) the scan runs once per connection (cached), so the
performance difference is negligible, and (c) the simpler implementation is easier to
reason about and extend.

**Caching on first request regardless of authentication state.** The initial
implementation cached the resolved route on the first `onRequest()` call. This caused
pre-authentication requests (`API_VERSIONS`, sent before SASL completes) to cache the
wrong route. The fix — skipping cache for anonymous subjects — follows the pattern
established by `PrincipalRouterFactory`.

**Forwarding `API_VERSIONS` to a single route.** An early implementation forwarded
pre-authentication `API_VERSIONS` to an arbitrary route (the default or the first
configured). This is incorrect when different routes target clusters with different
Kafka versions — the client would negotiate versions based on one cluster's
capabilities and then fail when routed to another. Fan-out with intersection is the
correct approach.

**Concise YAML syntax (`- User: alice`).** A more compact syntax using single-key maps
was considered. It reads well for simple cases but limits extensibility — adding a match
mode (prefix, regex) later would require a format change. The `{type, name}` object
form accommodates future extensions without breaking existing configurations.

## Design choices

- **Open principal type set via `Class.forName()`** keeps the router decoupled from
  specific principal implementations and allows organisations to use custom principal
  types without modifying the router.
- **First-match-wins rule evaluation** rather than implicit specificity ordering. The
  administrator controls precedence directly through rule ordering — no scoring system
  to learn, no implicit reordering to debug. This is the standard model for ordered
  rule lists (firewalls, nginx, etc.).
- **Per-connection route caching** avoids per-request overhead. The assumption that
  principals do not change during reauthentication is currently a simplification; if
  SASL termination gains reauthentication support, the router would need a cache
  invalidation mechanism.
- **`API_VERSIONS` fan-out and intersection** ensures the client negotiates versions
  compatible with every cluster it could be routed to, regardless of which cluster it
  actually reaches after authentication. The intersection is computed per connection
  by fanning out to all routes and taking the common version range for each API key.
- **Exact matching only** in this initial implementation. Prefix and regex matching
  (following the ACL authorizer's `ResourceMatcherNameStarts` and
  `ResourceMatcherNameMatches` patterns) can be added to the `RoutingRule` matching
  logic without restructuring the `RoutingTable`.

## Future work

- **Prefix and regex matching** for principal names and client IDs. The ACL authorizer's
  existing matcher types (`ResourceMatcherNameStarts`, `ResourceMatcherNameMatches` with
  RE2J) provide a proven pattern.
- **Configurable principal-type priority** for tiebreaking when multiple principals match
  at the same specificity level.
- **Metrics** — Micrometer counters for route selections, no-match rejections, and
  per-rule hit counts.
- **Reauthentication support** — cache invalidation when SASL termination supports
  reauthentication and the Subject changes mid-connection.
