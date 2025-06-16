<!-- This template is provided as an example with sections you may wish to comment on with respect to your proposal. Add or remove sections as required to best articulate the proposal. -->

# A Routing API

This proposal discusses an API for routing requests to Kafka clusters.

## Current situation

Kroxylicious currently supports `Filter` plugins as the top-level mechanism for adding behaviour to a proxy.
`Filters` can manipulate Kafka protocol requests and responses being sent by/to the Kafka client. 
They can also originate requests of their own (for example to obtain metadata that's necessary for them to function).

However, `Filters` cannot influence which Kafka cluster will receive the requests which it forwards or makes for itself.

## Motivation

There are use cases for a Kafka proxy which cannot be served with the `Filter` API alone.

Here are some examples:

* **Union clusters**. 
Multiple backing Kafka clusters can be presented to clients as a single cluster. 
Broker-side entities, such as topics, get bijectively mapped (for example using a per-backing cluster prefix) to the
virtual entities presented to clients. 
`Filters` cannot easily do this because they're always hooked up to a single backing Kafka cluster.

* **Topic splicing**.
Multiple separate topics in distinct backing clusters are presented to clients as a single topic.
Only one backing topic is writable at any given logical time.

* **Principal-aware routing**.
A natural variation on basic SASL termination is to use the identity of the authenticated client to drive the decision about which backing cluster to route requests to.
 
Kroxylicious is currently unable to address use cases like these.

## Proposal

### Concepts

To enable the use cases above we need a few new concepts:

* A _receiver_ is something that can handle requests, and which will return at most one response. 
* A _route_ represents a possible pathway from an incoming request towards a receiver.
* A _router_ is a thing which decides which route should be used for a given request.

Routers and backing Kafka clusters are both examples of receivers. 
Slightly more generally, a receiver is anything that speaks the full Kafka procotol. 
We don't consider a `Filter` to be a receiver, even though it can make short-circuit responses. 
`Filters` usually rely on having a backing Kafka cluster to forward requests to.
Generally speaking, a `Filter` might only handle a subset of the `ApiKeys` of the Kafka protocol.
Routers and backing clusters necessarily handle the whole protocol.

### Plugin API

`Router` will be a top level plugin analogous to the `Filter` plugin interface, using the same `ServiceLoader`-based mechanism for runtime discovery.
Each `Router` implementation will support 0 or more named routes.
The available and required route names will depend on the implementation, which might ascribe different behaviour to different named routes.
For example a `Router` implementing the 'union cluster' use case might simply use the route names as prefixes for names of the broker-side entities 
it will expose (such as topics or consumer groups), and as such impose no restriction on the supported route names. 
In contrast, a `Router` implementing the 'topic splicing' use case might require configuration about each of the clusters being used in the splice, which 
would required the route names to be referenced in the `Router`'s configuration.

```java
interface Router {
    CompletionStage<RoutingResult> onClientRequest(short apiVersion,
                                                   ApiKeys apiKey,
                                                   RequestHeaderData header,
                                                   ApiMessage request,
                                                   RoutingContext context);
}
```

For a given incoming request a `Router` implementation can decide which route(s) to make a request to.
We want to allow a router to potentially make multiple requests (e.g. to multiple clusters) and to have control over their processing (e.g. sequential or concurrent).
For this reason the `RoutingContext` does not follow the builder pattern used in the `FilterContext`, but simply
exposes methods to asynchronously send requests down a given route.
This allows the `Router` author to make use of the `CompletionStage` API when issuing multiple requests. 

```java
interface RoutingContext {

  CompletionStage<Response> sendRequest(String route, ...)
  void sendResponse(Resonse)
  void disconnect()

}
```


### Configuration

Routers are configured at the top level of the proxy configuration, similarly to `filterDefinitions`:
In addition to the `name`, `type` and `config` (which serve the same purpose for `Routers` as they do for `Filters`), a `routerDefinition` also supports a `routes` property.
The `routes` property is optional, though any given implementation may have its own particular requirements for its `routes`.

```yaml
routerDefinitions:
  - name: my-router
    type: MyRouter
    config: ...
    routes:
      - name: foo
        filters: 
          - my-first-filter
          - my-second-filter
        cluster: my-backing-cluster
      - name: bar
        filters: 
          - my-third-filter
        router: my-other-router
  - name: my-other-router
    # ...
```

A route object has a `name`, an optional list of `filters` (being the names of the filters to be applied to requests/responses that traverse this route) and either a 
`cluster` or a `router` property, which names the receiver which will handle requests after any filters have been applied. 
Exactly one of `cluster` or `router` must be specified.

Because routers can refer to other routers they form a graph. 

```
                           my-backing-cluster
                          ^
                         /
                        / foo
     requests          /
    ---------> my-router
                       \
                        \ bar              
                         \                ...
                          v              /
                           my-other-router --- ...
                                         \
                                          ...
```

All _possible_ routes through the graph can be determined statically from the proxy configuration, but the routing of any individual incoming request is determined at runtime.
It may involve multiple outgoing requests to one or more clusters or routers.
Validation performed at proxy startup will reject cyclic graphs.
This will prevent the possibility of a request getting stuck in a router loop. 

In order for non-trivial router graphs to be useful, `Router` authors will need to follow the same principle of composition as `Filter` authors.
That is, a `Router` implementation should only talk to its receivers, and not, for example, make direct connections of its own to a backing cluster.
To do so would prevent use of that router implementation in a larger graph. 

The `cluster` propety names a network-reachable backing cluster that speaks the Kafka procotol. It has the same schema as the `targetCluster` property of a virtual cluster.

The existing virtual cluster schema will be modified to support top level `clusters` and to make use of `routers`.

Specifically:

* the existing `targetCluster` property will be made optional, and deprecated
* a new `cluster` property will support referencing a target cluster by name (using a distict property name seems slightly nicer than overloading the allowed type of the existing `targetCluster` to support `string` or `object`).
* support for new `router` property will be added. This is a reference to a router defined in `routerDefinitions`. 
* exactly one of `router`, `cluster` or `targetCluster` will be required.
* `router` is mutually exclusive with `filters`. 

For example the old-style:

```yaml
virtualClusters:
  - name: my-vc
    portIdentifiesNode: ...
    filters: 
      ...
    targetCluster: 
      bootstrapServer: ...
      tls: ...
``` 

would be rewritten:

```yaml
clusters:
  - name: my-backing-cluster
    bootstrapServer: ...
    tls: ...
virtualClusters:
  - name: my-vc
    portIdentifiesNode: ...
    filters: 
      ...
    cluster: my-backing-cluster
``` 

An example of the `router` functionality:

```yaml
clusters:
  - name: my-backing-cluster
    bootstrapServer: ...
    tls: ...
routerDefinitions:
  - name: my-router
    type: MyRouter
    config: 
      ...
    routes:
    - name: to-backing-cluster
      filters: # a list of filter names
        ...
      cluster: my-backing-cluster
virtualClusters:
  - name: my-vc
    portIdentifiesNode: ...

    router: my-router
``` 

(note how the `filters` have moved from the virtual cluster to the route).

There are some design choices inherent in the above rendering of the concepts into a configuration API. 
Let's call some of them out explicitly:

* The names of filter, router, and cluster definitions are each global to the configuration, but in their own namespace (e.g. a filter and a router may each be called 'foo' without this being ambiguous).
* A route is not a top-level entity, but belongs to a router. 
* The names of routes must be unique within the scope of the containing router.
* A route may have filters in addition to a receiver. In this way a route embodies and generalizes the concept of a 'filter chain', which has never really been formalised in the proxy.


### Runtime

**TODO** Api versions. All `ApiKeys`.
**TODO** Flow control & state machine.


### Metrics

Routers would benefit dedicated metrics, implemented in the runtime. 
They would be broadly similar to the existing metrics for Filters.

## Affected/not affected projects

The proxy.

## Compatibility

These changes would be fully backwards compatible:
* There would be no impact on the `Filter` API: All existing filters would continue to work.
* The changes to proxy configuration are backwards compatible. 

The choice to deprecate `targetCluster` in a virtual cluster, replacing it with `cluster` as a reference to a cluster defined at the top level, is made simply to try to reduce different ways of expressing the same configuration ("There should be one way to do it").

## Rejected alternatives

* One alternative is simply to not do this (or not right now).
* `NetFilter` is an existing attempt at an abstraction for SASL Auth and cluster selection. It was never completed, and the interface never made it into the `kroxylicious-api` module. This proposal is more flexible since it allows routing decisions to happen after authentication. 

