# Routing Design Insights

Working notes from the analysis of PR #70 and the scatter-gather alternative.
These insights hold regardless of which proposal shape wins. They are intended
as pre-draft material toward a review comment on PR #70.

---

## 1. The existing model is a 1:1 router

The current non-routed pipeline:

```
Client -> [VC filters] -> [BrokerAddressFilter] -> [ApiVersionsIntersectFilter] -> Cluster
```

This is already a degenerate single-route router. The "scatter" is trivial (one
route), the "gather" is trivial (one response), and namespace translation
(addresses, API versions) is handled by implicit filters. The identity node ID
mapping (`V = t`) is a special case of the general formula.

Routing = breaking the 1:1 constraint to 1:N. That is the irreducible addition.
Everything else the existing model already does.

## 2. Three distinct concerns with different coupling requirements

PR #70's `onRequest()` conflates three concerns that differ in a critical way:

1. **Per-route namespace translation** — rewriting content within a single
   route's response (node IDs, broker addresses, topic names, partition IDs).
   No cross-route knowledge needed.

2. **Scatter-gather composition** — deciding which routes receive the request
   and composing their responses into a single client response. This _requires_
   cross-route knowledge: only the Router knows which routes it scattered to,
   and therefore what it needs to gather.

3. **Per-route predicates** — selection logic determining which routes
   participate in the scatter. Per-route state, not cross-route coordination.

Concerns 1 and 3 are per-route — they can be handled by the existing filter
chain machinery. Only concern 2 is irreducibly the Router's job.

## 3. Per-route downstream/upstream ID spaces

Each route has two distinct ID spaces: **downstream** (what the layer above
sees) and **upstream** (what the next layer down sees). The downstream space is
not necessarily client-facing — in a nested topology (`Client -> Router A ->
route ra1 -> Router B -> route rb2 -> Cluster X`), ra1's upstream IDs are
Router B's downstream IDs, not Cluster X's real broker IDs.

The mapping is always between adjacent layers. Each route maintains its own
bidirectional downstream-upstream mapping. There is no global ID space across
routes. Per-route filters must operate wholly in one space — downstream for
request-path filters, with implicit filters at the end of the chain translating
to upstream.

This is the vocabulary that makes the filter model precise: a filter that strips
partitions compares downstream partition IDs against downstream topology. It
never mixes spaces.

## 4. Union-topic decomposition via per-route filters

For union topics, a single PRODUCE or FETCH can contain partitions spanning
multiple routes. This happens because the Router's METADATA scatter-gather
merged partition leaders from multiple upstream clusters onto shared virtual
nodes. The client groups partitions by leader and sends a single request to a
virtual node that spans routes.

The Router can stay dumb: scatter the entire request to all relevant routes. A
per-route filter (`PartitionRoutingFilter`) strips partitions that don't belong
to its route using cached topology, then forwards a trimmed request upstream.
The Router's gather merges partition-level results.

**Correctness concern:** downstream-to-upstream ID mapping means a misrouted
partition may map to a valid upstream partition on the wrong cluster — the
broker cannot tell. This makes the topology cache load-bearing: it must be
correct, not merely eventually-consistent. The gather side provides a second
check — every partition in the original request should receive exactly one
acknowledgment.

The complexity budget for protocol-level decomposition lives in filters on the
route's chain — the same model as all other per-route transformations.

## 5. Lean into the existing filter machinery

Per-route protocol concerns (partition filtering, ID mapping, topic rewriting)
are best handled as filters on the route's chain. This preserves one processing
model rather than introducing a parallel mechanism in `onRequest()`.

The existing model already works this way: `BrokerAddressFilter` and
`ApiVersionsIntersectFilter` are per-route protocol filters that handle
namespace translation. Multi-cluster routing adds more of the same kind of
concern — the natural home is the same kind of solution.

The complexity budget must live somewhere. Filters on a chain give isolated
points where each concern is handled independently. The same `Filter` API, the
same testing model, the same configuration model. A Router author who needs
custom decomposition or mapping logic writes a filter, not a monolithic
`onRequest()` method that mixes scatter-gather coordination with protocol
traversal.

## 6. Scatter-gather can't be a filter

The scatter decision determines the gather shape. If the Router scatters a
METADATA request to routes A and B, only the Router knows it needs to merge
two METADATA responses into one. A filter — which sees only its own route's
traffic — cannot perform this merge because it doesn't know whether other
routes were also queried.

This is the irreducible contribution that justifies a `Router` abstraction
separate from `Filter`. Filters transform traffic within a single path; the
Router coordinates across paths.

---

## Open questions

- **`sendToNode` vs request-embedded node IDs.** For leader-directed requests,
  the destination node ID is already in the request header. Does an explicit
  `sendToNode(route, nodeId)` add value over `sendToRoute` with the runtime
  extracting the target from the request? The answer may depend on APIs like
  transactions where the Router needs to target a coordinator.

- **Correctness bar for runtime-shipped vs Router-authored protocol filters.**
  Runtime reference implementations centralise correctness but create a
  systemic single point of failure. Router-authored filters distribute the risk
  but repeat the work. Where is the right line?

- **Uniform dispatch vs optimisation paths.** Calling `scatter()` on every
  request is the simplest model. Is it the right default, or should
  topology-directed forwarding and opaque-frame bypass exist from the start?

- **How much of the protocol does the runtime need to understand?** Each
  reference filter (PID mapping, fetch session mapping, partition filtering)
  couples the runtime to specific protocol fields. Is this coupling acceptable,
  or does it grow unsustainably as the Kafka protocol evolves?
