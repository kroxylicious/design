# 140 - Subject Router

This proposal describes a `Router` implementation that selects a single upstream route based on the client's authenticated identity, its `client.id`, or both. All traffic from a given client reaches one upstream cluster (and one filter chain), so operators can steer different clients to different backends, or apply different per-route filters per client, without the client being aware of it.

## Current situation

Proposal [070][proposal-070] introduced the `Router` API: a top-level plugin that decides which route a request traverses on its way to an upstream cluster. The API is merged, but the project ships no `Router` implementation, so the routing use cases the API was designed for are not yet available to users.

Today a `Filter` cannot influence which upstream cluster receives a request; it can only observe and transform requests and responses on a fixed path to a single cluster. Selecting the upstream by client identity is therefore impossible with the current plugin surface.

Subject routing is a self-contained use case for the new API: it needs only the authenticated `Subject` and a static mapping from subject to route, with no request decomposition, fan-out, or protocol rewriting.

## Motivation

Selecting an upstream by client identity is a common requirement that the `Filter` API cannot serve, because a filter cannot change which cluster receives a request.

Concrete use cases:

* **Tenant isolation by identity.** Each tenant authenticates as a distinct principal and is pinned to that tenant's dedicated cluster. One virtual cluster address serves all tenants; the proxy fans them out to separate backends by identity.
* **Locality routing.** Route a client to a cluster local to it, chosen from identity metadata rather than network address.
* **Blue/green and migration.** Move a subset of clients to a new cluster by changing their mapping, without touching client configuration.
* **Per-identity policy.** Point two subjects at the *same* cluster but through *different* per-route filter chains, applying different encryption, auditing, or rate-limiting policy per client.
* **Demoable routing without authentication.** Route by `client.id` alone, with no mTLS or SASL termination configured, for quickstarts and trusted-network deployments that want per-client routing without standing up identity infrastructure. `client.id` is a client-supplied, unverified value, so this gives no isolation guarantee: any client can present any `client.id`. It is a convenience, not a security control.

A dedicated Subject Router delivers these with a small implementation that is easy to security-review, and gives the project its first production-oriented `Router`. It also exercises the `Router` API end to end against a realistic use case, which helps validate proposal [070][proposal-070] before more complex routers land.

## Proposal

### Overview

The Subject Router is a `@Plugin`-annotated `RouterFactory` in a new `kroxylicious-router-subject` module. It maps the client's authenticated `Subject`, its `client.id`, or both, to exactly one route and forwards every request to that route unchanged. Its one matching strategy, `ruleMatch`, evaluates an ordered list of rules against the subject's principals and the connection's `client.id`, selecting the first rule's route that matches. It performs no request decomposition, no fan-out, no response recomposition, and no protocol rewriting.

```
                                         route "team-a"  (subject: alice, carol)
                                 .------[filters...]------> cluster-a
                                /
  client --> virtual cluster --> subject-router
   (alice)      (my-vc)         \
                                 '------[filters...]------> cluster-b
                                         route "team-b"  (subject: bob)
```

The authenticated subject is usually stable for the lifetime of a client connection, but it is not guaranteed to be: a plugin may update it, for example when a client reauthenticates over the existing connection (KIP-368), or when a future component refreshes roles or claims. The router therefore resolves the route from the current subject on every request rather than pinning it at connection start. In the common case the subject does not change, or reauthentication renews the same identity, so the route stays the same and the connection keeps talking to one cluster. The client's `client.id`, by contrast, is treated as fixed for the connection's life: the router reads it once, from the first request, and does not re-read it afterwards (see [Client ID resolution](#client-id-resolution)).

The router keeps a connection on a single cluster by construction: if a subject change would move the connection to a different route, it closes the connection fail-closed (see [Subject changes mid-connection](#subject-changes-mid-connection)) rather than re-routing live. This preserves the property that only one upstream cluster is ever in play for a connection, so none of the cross-cluster problems (topic IDs, producer IDs, coordinator/leader reconciliation, fetch-session merging) can arise, while still honouring identity changes: the client reconnects and is routed by its new identity.

### Routing model

#### Subject resolution

The router reads the client's identity from `RouterContext.authenticatedSubject()`. For each `Principal` type referenced by a `hasPrincipals` entry anywhere in the configuration (see [Rule matching](#rule-matching)), it extracts the subject's unique principal of that type:

```java
subject.uniquePrincipalOfType(principalType).map(Principal::name)
```

The default example in this proposal uses `io.kroxylicious.proxy.authentication.User`, whose name is established upstream of the router by the virtual cluster filter chain:

* **Client mTLS** — the principal derives from the validated client certificate. It is present from the first request, including `API_VERSIONS`.
* **SASL termination** (proposal [124][proposal-124]) — the principal derives from the SASL authorized id, established after the `SASL_HANDSHAKE`/`SASL_AUTHENTICATE` exchange that the `SaslTermination` filter processes on the virtual cluster chain.

The router does not support SASL passthrough (proposal [004][proposal-004]). If it sees a SASL frame it rejects the connection fail-closed, because passthrough leaves the identity unverified by the proxy at routing time. See [Future work](#future-work).

#### Client ID resolution

The router also reads `client.id` from `RequestHeaderData.clientId()`, present on every request header today. It captures the value from the connection's first request, including a pre-authentication `API_VERSIONS`, and pins it for the life of the connection; it does not re-read `header.clientId()` on later requests. This anticipates [KIP-1313][kip-1313], which stops sending `client.id` on requests after the first: pinning now means the router's behaviour does not change once clients adopt it.

A client can technically send a different `client.id` on a later request today. The router ignores that: unlike a reauthenticated `Subject`, a changed `client.id` carries no routing-relevant meaning, because the router places no trust in it. See [Security model](#security-model) for what `client.id` matching does and does not guarantee.

#### Rule matching

`ruleMatch` evaluates an ordered list of `rules` against the current subject and the connection's pinned `client.id`, in declaration order, and uses the route of the first rule that matches. Each rule has:

* `hasPrincipals` (optional) — a map of fully-qualified `Principal` implementation name to required principal name. The rule matches only if the subject carries a principal of *every* listed type, with the exact name given for each. Each referenced type must be annotated `@Unique` or `@SingularPrincipal` (directly, or via meta-annotation), the contract that guarantees a `Subject` carries at most one principal of that type (proposal [119][proposal-119]); the factory checks this reflectively in `initialize()` for every type referenced anywhere in the configuration and refuses to start if any is not singular. A rule with `hasPrincipals` cannot match an anonymous subject: it has no principals to check against.
* `hasClientId` (optional) — a required value for the connection's pinned `client.id`. Because `client.id` is available before authentication, a rule with `hasClientId` and no `hasPrincipals` can match on an anonymous connection; see [Fail-closed by default](#fail-closed-by-default) for what that implies for isolation.
* `useRoute` — the route name, declared in the router's `routes` block, to forward to when the rule matches.

A rule needs at least one of `hasPrincipals` or `hasClientId`; the factory rejects a rule with neither. When a rule has both, the subject must satisfy `hasPrincipals` *and* the pinned `client.id` must equal `hasClientId` for the rule to match.

`defaultRoute` (optional) names the route for a subject/`client.id` pair that no rule matches once the subject is authenticated. If omitted, such a connection is rejected fail-closed; see [Route selection](#route-selection) for why this never applies to an anonymous subject.

At startup the factory validates every `useRoute` and `defaultRoute` against the router's declared routes (`RouterFactoryContext.routeNames()`); a typo surfaces as a boot-time error rather than a per-request rejection. It also rejects two rules with identical predicates (the same `hasPrincipals` map and the same `hasClientId`, where present), since the second could never be reached. Beyond that, overlapping rules are legal: evaluation order is the precedence mechanism, so a more specific rule (for example, one matching both a principal and a `client.id`) should be declared ahead of a more general one it should take priority over.

#### Route selection

The router resolves a request's route against the current subject and the connection's pinned `client.id`:

1. **A rule matches** — forward to that rule's route (see [Rule matching](#rule-matching)). A rule needing only `client.id` can match before, or without, authentication; a rule needing principals can only match once the subject is authenticated.
2. **No rule matches, subject authenticated** — forward to `defaultRoute` if configured, otherwise reject fail-closed.
3. **No rule matches, subject anonymous, request is `API_VERSIONS`** — answered from the cross-route version intersection rather than routed to a single cluster, because the eventual route is still unknown. See [API version negotiation](#api-version-negotiation). This exposes only protocol version ranges, no data.
4. **No rule matches, subject anonymous, any other request** — reject fail-closed. `defaultRoute` never applies to an anonymous subject: an operator wanting to route anonymous traffic must do so with an explicit `hasClientId` rule naming the exact `client.id` values they accept, not a blanket default (see [Rejected alternatives](#rejected-alternatives)).

#### Fail-closed rejection

When a request must be rejected — an anonymous non-`API_VERSIONS` request, or a connection whose subject and `client.id` match no rule and has no `defaultRoute` — the router does not silently fall through to an arbitrary route. It responds with a Kafka error appropriate to the API key and closes the connection:

```java
return context.respondWithError(header, request, Errors.SASL_AUTHENTICATION_FAILED, "not authorized for any route")
              .andCloseConnection()
              .build();
```

Closing the connection prevents a client from probing the mapping by sending requests under different identities on the same connection. This follows the project's fail-closed security guidance: deny by default, allow only what is explicitly permitted.

#### Request forwarding

For a routed request the router forwards to the broker the client is addressing on the selected route:

* If the client connected to a broker-specific endpoint, `RouterContext.virtualNode()` returns that broker's `VirtualNode`; the router forwards there.
* If the client connected to a bootstrap endpoint, `RouterContext.virtualNode()` is empty; the router forwards to `RouterContext.anyNode(route)`.

The runtime translates node IDs in `METADATA` (and other node-bearing) responses into the route's virtual node ID space, exactly as it does for a single-cluster virtual cluster. The client sees a consistent set of virtual node IDs for its route and opens broker-specific connections against them; those connections resolve back through the same route because the subject, and therefore the route, is unchanged.

Every API key is dynamically routed (`staticRoutes()` returns empty), because the route depends on the per-connection subject and cannot be expressed as the connection-independent, per-API-key map that `staticRoutes()` requires. The per-request work is a single map lookup plus one `sendRequest`; there is no decomposition cost. A future runtime optimisation could collapse a connection to a static forwarding path once its route is established, provided it re-evaluates on a subject change; that is out of scope here (see [Future work](#future-work)).

#### API version negotiation

`API_VERSIONS` is negotiated once per broker connection, and the client caches the result for the life of that connection. If a rule has already resolved the route by this point, for example a matching `hasClientId` rule, or an mTLS-established subject, the router negotiates against that route directly: see [Route selection](#route-selection). Otherwise, under SASL termination, the client sends `API_VERSIONS` *before* it authenticates and no `hasClientId` rule has matched, so the router does not yet know the subject, and therefore does not know the eventual route, at negotiation time. This holds even on the per-broker connections a client opens after `METADATA`: each new TCP connection re-runs `API_VERSIONS` before its SASL exchange, though `client.id` is pinned once per connection (see [Client ID resolution](#client-id-resolution)), not re-resolved.

The router cannot negotiate against a single "guess" cluster. If it answered from cluster X but the subject later routed to cluster Y, the client would use X's version ranges against Y for the rest of the connection, and Y would reject any API key whose range is narrower on Y. To stay correct regardless of the eventual route, the router negotiates against the **intersection of all routes**:

* For each API key, the advertised range is `max(minVersion)` to `min(maxVersion)` across every route's cluster (already intersected with the proxy's own maximums by the runtime's `ApiVersionsIntersectFilter`). An API key absent from any route, or one whose ranges leave an empty intersection (`max(minVersion) > min(maxVersion)`), is removed from the response.
* Because every route supports the advertised range, whatever version the client selects is safe on whichever route its subject resolves to. The result is conservative (the lowest common denominator across clusters) but never wrong.

Selection by route state:

* **Route resolved** (a rule already matches, whether from `client.id`, an authenticated subject, or both) — forward `API_VERSIONS` to `virtualNode()` when the client is on a broker-specific endpoint, else `anyNode(route)`. This gives the exact versions of the specific broker, which matters during rolling upgrades where brokers run different Kafka versions (proposal [070][proposal-070]). With client mTLS, or a connection with a matching `hasClientId` rule, this path always applies and no fan-out occurs.
* **Route unresolved** (anonymous subject, no matching `client.id` rule, SASL pre-auth) — fan out `API_VERSIONS` live to every route and intersect the responses.

The intersection is computed live per anonymous negotiation rather than cached. The version a client negotiates governs its whole connection, so a cached intersection that lagged a backend downgrade could advertise a version the eventual cluster no longer supports, and the client would fail for the life of the connection. Computing live keeps the advertised ranges consistent with the clusters' current capability. The cost is that each pre-authentication `API_VERSIONS` opens (via the runtime's connection handling) a connection to each route to obtain its ranges; connections to routes the subject does not ultimately use are left idle and reaped by the normal idle timeout. `API_VERSIONS` responses carry no broker node IDs, so no node-ID translation is involved. The fan-out is the only backend interaction the router performs for an unauthenticated client; see [Security model](#security-model).

### Configuration

The router is configured under `routerDefinitions`, using the structure defined in proposal [070][proposal-070]. Routes are declared in the router's `routes` block (name, id, optional filters, target); the plugin `config` maps subjects, `client.id`s, or both, to those route names.

```yaml
clusterDefinitions:
  - name: cluster-a
    bootstrapServers: kafka-a:9092
  - name: cluster-b
    bootstrapServers: kafka-b:9092

routerDefinitions:
  - name: subject-router
    type: SubjectRouter
    config:
      ruleMatch:
        defaultRoute: team-a         # optional; authenticated-but-unmapped subjects route here
        rules:
          - hasPrincipals:
              io.kroxylicious.proxy.authentication.User: alice
            useRoute: team-a
          - hasPrincipals:
              io.kroxylicious.proxy.authentication.User: carol
            useRoute: team-a
          - hasPrincipals:
              io.kroxylicious.proxy.authentication.User: bob
            useRoute: team-b
          - hasClientId: demo-app    # no principal required; matches before/without authentication
            useRoute: team-a
    routes:
      - name: team-a
        id: 0
        target:
          cluster: cluster-a
      - name: team-b
        id: 1
        filters:
          - record-encryption        # per-route filter chain applied only to bob's traffic
        target:
          cluster: cluster-b

virtualClusters:
  - name: my-vc
    target:
      router: subject-router
    gateways: [...]
    filters:
      - sasl-termination             # establishes the authenticated Subject before routing
```

The `SubjectRouter` `config` takes a single `ruleMatch` block:

| Option | Type | Required | Default | Description |
|--------|------|----------|---------|-------------|
| `ruleMatch.rules` | list\<object\> | Yes | — | Ordered rules, each with an optional `hasPrincipals` map, an optional `hasClientId` string, and a required `useRoute` naming a route declared in the router's `routes`. At least one of `hasPrincipals`/`hasClientId` is required per rule. The first matching rule wins; see [Rule matching](#rule-matching). |
| `ruleMatch.defaultRoute` | string | No | none | Route for an authenticated subject whose principals and `client.id` match no rule. Never applies to an anonymous subject. If omitted, such a subject is rejected fail-closed. |

Pre-authentication `API_VERSIONS` needs no route configuration: it is served from the cross-route version intersection (see [API version negotiation](#api-version-negotiation)), which spans every route in the router.

#### Same cluster, different filters

To support per-identity policy against a shared backend, the factory calls `RouterFactoryContext.allowSharedClusterTargets()` during `initialize()`. This permits two routes to target the same cluster through different per-route filter chains (for example, routing `alice` and `bob` both to `cluster-a`, but `bob` through an extra record-encryption filter). Without this opt-in the runtime rejects overlapping cluster targets by default, per proposal [070][proposal-070].

### Router behaviour in depth

#### Connection lifecycle

A `Router` instance is created per client connection and runs on a single Netty event loop thread, so per-connection state needs no synchronisation. The subject-to-route mapping is immutable and shared across connections; the factory builds it once in `initialize()` and stores it in thread-safe initialisation data. Per-connection state also holds the pinned `client.id` once observed (see [Client ID resolution](#client-id-resolution)).

The connection progresses through phases:

1. **Pre-authentication.** With SASL termination, the first requests are `API_VERSIONS` and the SASL exchange. The SASL exchange is handled by the `SaslTermination` filter on the virtual cluster chain and never reaches the router. `API_VERSIONS` does reach the router while the subject is still anonymous; if a `hasClientId` rule already matches the pinned `client.id`, the router answers directly from that route, otherwise it answers by fanning out live to all routes and intersecting the responses (see [API version negotiation](#api-version-negotiation)). With client mTLS the subject is non-anonymous from the first request and the fan-out case does not occur.
2. **Authenticated steady state.** Once authentication completes, `authenticatedSubject()` returns the client's subject on every subsequent `onRequest`. The router evaluates `ruleMatch` against the authenticated subject and the pinned `client.id`, and forwards each request to the addressed broker on the resolved route.

The router resolves the route per request and caches nothing beyond the pinned `client.id`. The subject is not fixed: it transitions from anonymous to authenticated on a SASL-terminated connection, and a plugin may change it later (reauthentication, role or claim refresh). `client.id`, by contrast, is pinned once (see [Client ID resolution](#client-id-resolution)) and never re-read. Because `ruleMatch` is a synchronous, in-memory rule scan, recomputing it against the current subject on every request is cheap and needs no cache, and an in-place change to the subject's identity is picked up on the next request with no staleness. A future matching strategy that consults a network source could not afford a call per RPC and would need to cache the route for the life of the subject; that path, and its cache-invalidation contract, is deferred (see [Future work](#future-work)).

#### Subject changes mid-connection

The router remembers the route currently in use on a connection (the route it last forwarded to). On each request it re-evaluates `ruleMatch` against the current subject and the pinned `client.id`, and compares:

* **Same route** — forward as normal. This covers the overwhelmingly common cases: the subject is unchanged, or reauthentication renewed the same identity, or a claim changed in a way that does not alter the mapping (`client.id` is pinned and cannot change, so only a change to a matched principal's name can change the resolved route).
* **Different route** — the resolved route no longer matches the route the connection has been using. The router closes the connection fail-closed with a clear error rather than re-routing live.

The router does not follow a route change live because the connection carries state that is specific to the cluster it has been talking to: virtual node IDs the client cached from `METADATA`, in-flight requests, and any consumer-group, transaction, or fetch-session state on that cluster. None of this can be coherently migrated to a different cluster mid-stream. Closing the connection discards that state cleanly; the client reconnects, renegotiates under its new identity, and is routed to the cluster its new identity maps to. This keeps the single-cluster-per-connection guarantee intact and ensures an identity change (including a privilege reduction) takes effect promptly rather than being ignored for the life of the connection.

The transition from anonymous to authenticated is not treated as a route change: while anonymous the connection has forwarded no data-plane request to any route (only `API_VERSIONS`, answered by fan-out), so there is no in-use route to conflict with. The first authenticated request establishes the connection's route.

#### Interaction with the SASL security barrier

Proposal [124][proposal-124] specifies that the `SaslTermination` filter rejects all non-SASL requests until authentication succeeds and closes the connection on failure. So on a correctly configured SASL-terminated virtual cluster, a non-`API_VERSIONS` request never reaches the router while the subject is anonymous. The router's own fail-closed rejection of anonymous requests is defence in depth: it protects deployments that place the router behind weaker or misconfigured authentication, and guarantees the router never forwards unauthenticated data-plane traffic to a backend.

#### Reconfiguration

Adding or removing a route changes the route count `S` in the runtime's node-ID mapping formula, which shifts virtual node IDs (proposal [070][proposal-070]). Virtual cluster reconfiguration already drains client connections before applying a new configuration, so clients reconnect and receive fresh metadata. Changing only `ruleMatch.rules` (moving a subject or `client.id` between existing routes, or adding a rule) does not change `S`; affected clients pick up the new mapping on their next connection.

#### Error and staleness handling

The router forwards backend error responses to the client unchanged. It holds no topology cache, so it has no cache to invalidate on `NOT_LEADER_OR_FOLLOWER` or `NOT_COORDINATOR`; the client's normal `METADATA` refresh flows through to the single backing cluster as it would for a plain single-cluster virtual cluster.

If `onRequest` throws or its `CompletionStage` completes exceptionally, the runtime closes the client connection (proposal [070][proposal-070]). The router avoids this for expected conditions by using `respondWithError` for fail-closed rejections.

### Metrics

The router relies on the runtime's per-route metrics defined in proposal [070][proposal-070] (request counts, latencies, and error counters tagged by route name, API key, and routing mode). It adds one counter for identity-driven rejection:

| Metric | Type | Tags | Description |
|--------|------|------|-------------|
| `kroxylicious_subject_router_rejected_total` | Counter | `virtual_cluster`, `router`, `reason` (`anonymous`, `unmapped`) | Requests rejected because no rule matched. `anonymous`: the subject is still anonymous and no `hasClientId` rule matched. `unmapped`: the subject and `client.id` were evaluated against every rule, none matched, and no `defaultRoute` is configured. |

Route selection itself needs no dedicated metric; the runtime's per-route request counter already attributes traffic to routes, and hence to the subjects mapped there. The router deliberately does not tag metrics with the subject name, to avoid unbounded cardinality and to avoid emitting identities into monitoring systems.

## Security model

Subject routing places client identity in the request path: the destination cluster is a function of who the client is. This section states the trust boundaries and the guarantees the router does and does not provide.

### Authentication is a precondition

The router makes routing decisions from `authenticatedSubject()`. That subject is only trustworthy if a component upstream of the router has authenticated the client. The router must be deployed behind one of:

* **Client mTLS**, which establishes the subject at the TLS handshake, before any Kafka request.
* **SASL termination** (proposal [124][proposal-124]), which establishes the subject at the proxy and rejects unauthenticated traffic.

SASL passthrough (proposal [004][proposal-004]) is out of scope. A passthrough-inferred identity is asserted by the backend rather than verified by the proxy, and does not cover all mechanisms, so the router rejects SASL frames rather than routing on an unverified subject (see [Future work](#future-work)). The router does not enforce which authentication component is present; that composition is the administrator's responsibility, consistent with the SASL placement rules in proposal [070][proposal-070].

This precondition applies to rules with `hasPrincipals`: they can only match an authenticated subject. A rule with `hasClientId` and no `hasPrincipals` is different by design: `client.id` is read from the Kafka request header before any authentication step, so such a rule can match on a fully anonymous connection, with no mTLS or SASL termination configured at all. Configuring such a rule is an explicit choice to route on a client-supplied, unverified value; see [Fail-closed by default](#fail-closed-by-default) and [Strength of isolation equals strength of authentication](#strength-of-isolation-equals-strength-of-authentication) for what that does and does not guarantee.

### Fail-closed by default

The router denies by default:

* An anonymous client cannot send any request that manipulates data unless a `hasClientId` rule matches its pinned `client.id`; absent such a rule, the router denies data-plane requests until it knows the user identity. The only request serviced otherwise while anonymous is `API_VERSIONS`, which is answered from the cross-route version intersection and carries no data.
* A connection whose subject and `client.id` match no rule is rejected once authenticated, unless an admin has explicitly configured a `defaultRoute`. `defaultRoute` never applies to an anonymous subject (see [Route selection](#route-selection)).

There is no configuration in which a client reaches a cluster that no rule or `defaultRoute` names. Every cluster a client can reach is one an admin explicitly configured it for, whether keyed on an authenticated principal, a self-reported `client.id`, or both. This matches the project's security guidance: on the absence of an explicit allow, deny.

A mid-connection identity change is also handled fail-closed. If reauthentication or a claim refresh changes the subject such that it now maps to a different route, the router closes the connection rather than continuing to serve the old route (see [Subject changes mid-connection](#subject-changes-mid-connection)). An identity change that reduces privilege (for example reauthenticating as a lower-privilege principal) therefore cannot keep using the previous identity's cluster; the client must reconnect and is routed by its current identity. `client.id` cannot trigger this case: it is pinned for the connection and never re-evaluated (see [Client ID resolution](#client-id-resolution)).

### Routing isolation is not access control

The router guarantees that a subject's traffic reaches exactly one cluster. It does not authorise operations within that cluster. Authorisation remains the authority of the route's configuration: backend broker ACLs, or an [Authorization Filter][proposal-009] configured on that branch of the DAG. A client routed to `cluster-a` still needs permission there to produce to or consume from its topics. Admins must not treat subject routing as a substitute for that authorisation. It is a routing and isolation control, complementary to, not a replacement for, authorisation.

This distinction matters because the router forwards requests verbatim. It does not filter which topics, groups, or operations a subject may use within its cluster; it only decides which cluster. Where finer control is required, combine subject routing with per-route authorisation filters or broker ACLs.

### Strength of isolation equals strength of authentication

Because the route is chosen from the authenticated identity, the isolation between tenants is exactly as strong as the authentication mechanism that establishes the identity. If an attacker can obtain another subject's credentials or forge its principal, they reach that subject's cluster. mTLS and SASL termination with strong mechanisms (SCRAM, OAUTHBEARER) provide this strength; SASL PLAIN without TLS does not. Admins choosing a Subject Router for tenant isolation should pair it with mutual authentication and TLS on the client-facing gateway.

This does not extend to `client.id`. It is a value the client sets on every request, unverified and unauthenticated; any client can present any `client.id`. A rule with only `hasClientId` therefore provides no isolation at all, only a convenience partition that any client can bypass or impersonate by sending a different `client.id`, and admins should not treat it as an isolation control. A rule combining `hasPrincipals` and `hasClientId` is exactly as strong as its `hasPrincipals` part: the `client.id` only narrows which of that principal's own connections the rule matches, and adds no further guarantee.

### Single-cluster confinement

Each connection addresses exactly one cluster. Because the router forwards requests unmodified to a single backend, it holds no cross-cluster state, so classes of risk that only arise when one connection spans clusters cannot occur here: producer-ID reuse across clusters, coordinator/leader confusion, fetch-session state leakage, and topic-ID collisions. The router cannot leak data between clusters within a connection because only one cluster is ever addressed. The implementation is small and forwards requests unmodified, which keeps the trusted computing base for this feature minimal and easy to review.

### Pre-authentication fan-out

For a connection whose route cannot yet be resolved (no `hasClientId` rule matches and the subject is still anonymous), serving `API_VERSIONS` from a live cross-route intersection means an unauthenticated client causes the proxy to open a connection to every route's cluster and send `API_VERSIONS` before it has authenticated. A flood of anonymous connections, or a client that opens many broker-specific connections (each re-running `API_VERSIONS` before its SASL exchange), multiplies this by the number of routes. This is an accepted cost of keeping negotiation fresh rather than cached (see [Rejected alternatives](#rejected-alternatives)). It is bounded and low-risk:

* The only request the router sends for an unauthenticated client is `API_VERSIONS`. It carries no data and mutates nothing.
* Every other request from an anonymous client is rejected fail-closed, so authentication is still required before any data-plane traffic reaches a backend, unless a `hasClientId` rule matches.
* The client-facing gateway's existing connection and rate limits cap how fast anonymous connections, and therefore fan-outs, can be created.
* A connection with a matching `hasClientId` rule skips this fan-out entirely: its route is already known at `API_VERSIONS` time.

Admins who cannot tolerate this fan-out should prefer client mTLS, or a `hasClientId` rule, under which the route is known immediately and `API_VERSIONS` answers directly with no fan-out.

### Logging

Following the project logging rules, the router logs the authenticated subject under the `subject` key (never individual principals or credentials), the selected `route`, and the `sessionId`, at DEBUG. Rejections are logged at WARN with `reason` and `sessionId`, without echoing request bodies. The router never logs credentials or record data.

## Affected/not affected projects

* **New module `kroxylicious-router-subject`** — the `SubjectRouter` `RouterFactory`, its `Router`, the `ruleMatch` matching strategy, and configuration types. A new top-level module.
* **`kroxylicious-bom`** — version management for the new module.
* **`kroxylicious-integration-tests`** — integration tests exercising subject-to-route selection, fail-closed rejection, and per-route filter application, behind both mTLS and SASL termination.
* **`kroxylicious-docs`** — user documentation for configuring and operating the router.
* **Not affected: `kroxylicious-api`.** The router uses the existing `Router`, `RouterFactory`, `RouterContext`, and `Subject` types from proposal [070][proposal-070] and the authentication API. No API change is required.
* **Not affected: KMS, authoriser API, existing filters.**
* **`kroxylicious-operator`** — a separate future update is needed to expose subject-router configuration in CRDs. Out of scope for this proposal.

## Compatibility

* Purely additive. It introduces a new plugin and a new module; it changes no existing API, configuration schema, or behaviour.
* Depends on the `Router` API from proposal [070][proposal-070] being available in the runtime.
* Composes with, but does not require, SASL termination from proposal [124][proposal-124]. mTLS is a fully supported alternative.
* Forward compatible with the `VirtualNode` addressing rework proposed in [PR 123][pr-123]: the router uses `virtualNode()` and `anyNode(route)` only as opaque forwarding handles and performs no node-ID arithmetic, so it is insulated from changes to the underlying addressing type.

## Rejected alternatives

* **Extend the `Filter` API to select an upstream.** Identity-based upstream selection could be bolted onto the filter chain instead of the `Router` API. This was rejected: the `Router` API (proposal [070][proposal-070]) exists precisely to own upstream selection, node-ID mapping, and per-route filter chains. Reimplementing that in a filter would duplicate the runtime machinery the `Router` API already provides and bypass its addressing guarantees.

* **A pluggable `RouteSelector` SPI.** An earlier draft let operators supply a custom `RouteSelector` plugin for the subject-to-route decision, with `ruleMatch` as one built-in implementation among possibly several. This is rejected for the initial version: a plugin SPI multiplies the surface that needs design and security review before a single concrete strategy has shipped and proven the `Router` API end to end. Shipping `ruleMatch` as the only matching strategy keeps the initial scope small and reviewable. Pluggable selection can be reintroduced later if a second strategy earns its place (see [Future work](#future-work)).

* **Route on group or role principals.** Matching the unique `User` principal covers the stated use cases and keeps the lookup unambiguous (each connection has exactly one `User`). Routing on group or role membership raises questions when a subject belongs to several groups mapped to different routes. This is deferred; it can be added later as an alternative matching strategy without changing the routing engine.

* **Represent `client.id` as a Principal in the `Subject`.** An earlier idea added a `ClientId` principal to the subject, populated by a filter, so routers (and other subject-consuming components) could treat it uniformly with authenticated principals. This is rejected: `client.id` is supplied by the client and the proxy cannot verify it, so putting it in the `Subject` would let it masquerade as something trustworthy to any later consumer, a footgun. `ruleMatch`'s `hasClientId` instead matches on it as a separate, explicitly-unverified predicate, never conflated with `hasPrincipals`.

* **Fall back to a default route for anonymous clients.** Having `defaultRoute` catch every unmatched anonymous connection was rejected because it defeats the isolation the feature exists to provide and violates fail-closed defaults: an admin who wants anonymous traffic routed should name the exact `client.id` values they accept, not get a silent catch-all. `defaultRoute` therefore only ever applies to an authenticated, unmatched subject; an anonymous connection matching no `hasClientId` rule is limited to `API_VERSIONS` for negotiation and otherwise rejected (see [Route selection](#route-selection)).

* **Negotiate `API_VERSIONS` against a single bootstrap route.** An earlier draft forwarded pre-authentication `API_VERSIONS` to a configured `bootstrapRoute`. This is incorrect under SASL termination: the client negotiates and caches versions before it authenticates, so if it negotiated against the bootstrap cluster but its subject later resolved to a different cluster, the client would use version ranges the eventual cluster may not support, and requests would fail. Because `API_VERSIONS` is re-run before the SASL exchange on every per-broker connection too, the bootstrap route would also be used where the client actually intends a specific broker on its real route. Intersecting across all routes is correct regardless of the eventual route.

* **Answer `API_VERSIONS` locally from the proxy's own maximums.** Synthesising the response from the proxy's supported versions alone, with no backend query, avoids the fan-out but reintroduces the mismatch: the proxy maximum can exceed what the subject's cluster supports, so the client could select a version the backend rejects. Producing a safe local answer requires knowing the minimum across all backends, which is exactly the intersection the live fan-out computes.

* **Cache the cross-route intersection.** Caching the intersection in shared state (with a TTL, or with reactive invalidation on `UNSUPPORTED_VERSION`) would remove the per-connection fan-out. It was rejected because the negotiated version governs the whole connection: a cache that lagged a backend downgrade would advertise a version the eventual cluster no longer supports, and every request on that connection would fail until the cache refreshed. Freshness was judged more important than the connection cost, especially since mTLS deployments avoid the fan-out entirely. Caching remains available as a future optimisation if the fan-out cost proves significant in practice.

* **Per-API-key static routing.** `staticRoutes()` returns a connection-independent map, but the Subject Router's route is a function of the per-connection subject. Static routing cannot express this, so all requests are dynamically routed. A runtime optimisation to flatten a connection to a fixed forwarding path once its route is known is noted as future work rather than forced into the plugin API.

* **Caching the route at connection start.** On a SASL-terminated connection the subject is anonymous during `API_VERSIONS` and becomes known only after the SASL exchange, and the subject can change again later (reauthentication, claim refresh). Resolving the route per request (a single map lookup) handles both the anonymous-to-authenticated transition and later changes without special-casing, at negligible cost. Pinning the route at connection start would either miss the initial authentication or silently ignore a later identity change.

## Future work

* **Operator CRD support** for declaring subject routers and their mappings.
* **Pluggable, possibly asynchronous route selection.** Introduce a `RouteSelector` SPI so operators can supply a custom subject-to-route strategy, such as one that consults a network directory or policy service, alongside or instead of `ruleMatch`. An asynchronous contract requires the runtime to handle a request while selection is in flight (hold or reject) and a caching contract, since the proxy cannot call out on every RPC: cache the selected route for the life of the subject and re-resolve only when the subject changes. Detecting a subject change cheaply points to splitting selection into a synchronous `Principal -> Key` extraction and a `Key -> Route` mapping, caching on the extracted key, and tightening the `Principal` contract so a routing-relevant identity change arrives as a new `Subject` rather than an in-place mutation.
* **Group or role-based matching**, as an alternative to per-principal-name mapping, once pluggable selection lands.
* **Startup warnings for shadowed rules** — detecting a rule whose predicate is implied by an earlier one (for example, a `hasClientId`-only rule placed after an identical-but-broader one), beyond the exact-duplicate case `ruleMatch` already rejects at startup.
* **Runtime fast path** that flattens a connection to a static forwarding path once its route is established (re-evaluating if the subject changes), removing per-request deserialisation for a router that only forwards.
* **Regex or claim-based mapping**, instead of exact name matches, for deployments with large or dynamic principal sets, once pluggable selection lands.
* **SASL passthrough.** The initial router rejects SASL frames because a passthrough-inferred identity is asserted by the backend, not verified by the proxy, and does not cover every mechanism. A later iteration could support it where the deployment accepts that routing is only as trustworthy as the inference. One shape, raised in review: a configurable `authRoute` naming the single route that carries the SASL exchange, which only suits deployments where every upstream shares the same authentication infrastructure. In that case terminating SASL (for example OAUTHBEARER) at the proxy achieves a similar effect with a verified subject, so passthrough earns its place only for mechanisms the proxy cannot terminate.

[proposal-004]: 004-terminology-for-authentication.md
[proposal-009]: 009-authorizer.md
[proposal-070]: 070-routing-api.md
[proposal-119]: 119-auth-api-refactor.md
[proposal-124]: 124-sasl-termination.md
[pr-123]: https://github.com/kroxylicious/design/pull/123
[kip-1313]: https://cwiki.apache.org/confluence/spaces/KAFKA/pages/406624038/KIP-1313+Client+instance+ID+in+all+request+headers
