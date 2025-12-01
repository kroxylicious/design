# Proposal 007: Resolve Topic Names from Topic IDs in the Filter Framework

<!-- TOC -->
* [Proposal 007: Resolve Topic Names from Topic IDs in the Filter Framework](#proposal-007-resolve-topic-names-from-topic-ids-in-the-filter-framework)
  * [Summary](#summary)
  * [Current Situation](#current-situation)
  * [Motivation](#motivation)
  * [Proposal](#proposal)
    * [1. API Addition](#1-api-addition)
    * [2. Metadata Request](#2-metadata-request)
    * [3. Composability](#3-composability)
  * [Affected Projects](#affected-projects)
  * [Compatibility](#compatibility)
  * [Rejected Alternatives](#rejected-alternatives)
    * [Name-to-id lookup API](#name-to-id-lookup-api)
    * [Separate Resource Request API for obtaining metadata](#separate-resource-request-api-for-obtaining-metadata)
  * [Future Extension](#future-extension)
<!-- TOC -->

## Summary

This proposal outlines a new feature for the Kroxylicious filter framework: a mechanism to map topic names from
their corresponding topic IDs. This will give Filter Authors a simple API that composes neatly with other Filters.

## Current Situation

Apache Kafka increasingly uses **Topic IDs** as unique and stable identifiers for topics, especially in newer RPCs. This
approach robustly handles edge cases, such as when a topic is deleted and later recreated with the same name. You can
find more details
in [KIP-516: Topic Identifiers](https://cwiki.apache.org/confluence/display/KAFKA/KIP-516%3A+Topic+Identifiers). In
Kafka 4.1.0 Produce Requests have begun using topic ids when the client supports it, impacting multiple Filters offered
by the Kroxylicious project.

Currently, the Kroxylicious framework does not provide a direct way for filters to translate a topic ID back into its
topic name. We have worked around this by intercepting the Api Versions response in those filters, and downgrading the
maximum Produce version to 12, before the introduction of topic ids to that RPC. Meaning clients will send topic names.

## Motivation

Numerous Proxy Filters are topic-oriented, they need to select which topics to operate on and apply logic per topic.
Currently they identify topics by their names, so if they receive topic ids in the RPCS they will need to convert them
to names. This would require each individual Filter to make out-of-band Metadata requests, or intercept
downstream-client-initiated Metadata responses to obtain the names, and likely implement their own caching strategy to
reduce load on the upstream cluster.

Theoretically, in future Filters could have the opposite problem if they are configured in terms of topic id, but
receive messages containing the name.

Filters in the chain are able to modify topic names and identifiers, therefore the names/identifiers visible to a Filter
instance depend on the manipulations of these other Filters.

To bridge this gap and allow filters to operate effectively, the framework must provide a reliable way to map topic
IDs back to their corresponding names, that composes with other Filters that manipulate the topic identifiers.

## Proposal

I propose:

1. adding a [new method](#1-api-addition) to the `FilterContext` interface that allows filters to look up topic names
   for a given set of topic IDs.
2. This will drive a [Metadata request](#2-metadata-request) to the upstream to learn the topic names.
3. If upstream Filters mutate the topic names and or errors, these mutations [will be reflected](#3-composability) in 
   the topic names and errors returned by the new API

### 1. API Addition

The following members will be added to the `io.kroxylicious.proxy.filter`:

```java
/**
 * Indicates there was some problem obtaining a name for a topic id
 */
public class TopicNameMappingException extends RuntimeException {
    private final Errors error;

    public TopicNameMappingException(Errors error) {
        this(error, error.message(), error.exception());
    }

    public TopicNameMappingException(Errors error, String message) {
        this(error, message, error.exception());
    }

    public TopicNameMappingException(Errors error, String message, Throwable cause) {
        super(message, cause);
        this.error = Objects.requireNonNull(error);
    }

    public Errors getError() {
        return error;
    }
}

/**
 * The result of discovering the topic names for a collection of topic ids
 */
public interface TopicNameMapping {
    /**
     * @return true if there are any failures
     */
    boolean anyFailures();

    /**
     * @return immutable map from topic id to successfully mapped topic name
     */
    Map<Uuid, String> topicNames();

    /**
     * Describes the reason for every failed mapping. Expected exception types are:
     * <ul>
     *     <li>{@link TopLevelMetadataErrorException} indicates that we attempted to obtain Metadata from upstream, but received a top-level error in the response</li>
     *     <li>{@link TopicLevelMetadataErrorException} indicates that we attempted to obtain Metadata from upstream, but received a topic-level error in the response</li>
     *     <li>{@link TopicNameMappingException} can be used to convey any other exception</li>
     * </ul>
     * All the exception types offer {@link TopicNameMappingException#getError()} for conveniently determining the cause. Unhandled
     * exceptions will be mapped to an {@link Errors#UNKNOWN_SERVER_ERROR}. Callers will be able to use this to detect expected
     * cases like {@link Errors#UNKNOWN_TOPIC_ID}.
     * @return immutable map from topic id to kafka server error
     */
    Map<Uuid, TopicNameMappingException> failures();
}
```
The following method will be added to the `io.kroxylicious.proxy.filter.FilterContext`:

```java
     /**
     * Attempts to map all the given {@code topicIds} to the current corresponding topic names.
     * @param topicIds topic ids to map to names
     * @return a CompletionStage that will be completed with a complete mapping, with every requested topic id mapped to either an
     * {@link TopicNameMappingException} or a name. All failure modes should complete the stage with a TopicNameMapping, with the
     * TopicNameMapping used to convey the reason for failure, rather than failing the Stage.
     * <h4>Chained Computation stages</h4>
     * <p>Default and asynchronous default computation stages chained to the returned
     * {@link java.util.concurrent.CompletionStage} are guaranteed to be executed by the thread
     * associated with the connection. See {@link io.kroxylicious.proxy.filter} for more details.
     * </p>
     */
    CompletionStage<TopicNameMapping> topicNames(Collection<Uuid> topicIds);
```

### 2. Metadata Request

This method will internally send a `Metadata` request to the upstream Kafka cluster to fetch the required topic
information. We will send the highest version supported by both the proxy and upstream broker. Ideally we would send
the same version that the downstream client would pick, but the proxy may not have observed a Metadata request from 
a client on any given channel, in which case the Proxy must pick a version to use.

The TopicNameMapping will contain either a name or a kafka `TopicNameMappingException` for each requested topic id.
We strive to always provide a `TopicNameMapping` under the various failure scenarios, preferring to Map every
id to an exception, rather than fail the stage. The TopicNameMappingException offers a Kafka Errors enum for conveniently
detecting expected cases like `UNKNOWN_TOPIC_ID`, internal exceptions will be mapped to `UNKNOWN_SERVER_ERROR`.

### 3. Composability

A core value of Kroxylicious is filter composability. Other filters with virtualization capabilities (e.g., a
multitenancy filter) may need to alter the topic names or ids presented to downstream filters.

To support this, the underlying `Metadata` request generated by this new method will flow through the standard filter
chain. This allows any filter to intercept and mutate the `MetadataResponse`, ensuring seamless composition with
existing filters like `Multitenant` without requiring any changes to them.

## Affected Projects

* **kroxylicious-api**: Affected by the addition of the new method to the `FilterContext` interface.
* **kroxylicious-runtime**: Affected by the implementation of the topic name resolution logic

## Compatibility

The change to `FilterContext` is **backwards compatible**, as it involves adding a new default method and result class

## Rejected Alternatives

### Name-to-id lookup API

We considered also implementing the inverse, looking up topic IDs when we only know the topic names. However, this
direction has more consistency issues, the topic id for a topic name can change if that topic is deleted and re-created.
Filters caching topic ids may not be exposed to the RPCs that could drive cache invalidation and could continue
operating with old topic ids. So we think starting with topic id -> topic name has fewer risks around cache
invalidation.

### Separate Resource Request API for obtaining metadata

An alternative considered was to introduce a new, specialized API for these resource requests instead of using the
existing `Metadata` RPC flow. Filters like `Multitenant` would then need to implement this new API to intercept and
modify the name lookup.

* **Downside**: This approach complicates development for plugin authors by requiring them to implement an additional
  API. The existing filter chain is already well-suited for intercepting Kafka RPCs, and the short-circuiting logic for
  caching is already in place.
* **Upside**: A custom API could potentially be more optimized, as it would avoid the overhead of creating Kafka RPC
  objects.

Ultimately, reusing the existing, familiar `Metadata` filter mechanism was chosen as it provides better composability
and a simpler developer experience, which outweighs the minor potential for optimization.

## Future Extension

In the future we could add Framework level caching. We could consider options like:

1. caching the response from target cluster, so that all Filters for a given channel would use a single cache. Their
   requests would still traverse the Filter change, but a component could short-circuit if it knows all the the names
   for the desired topic ids.
2. caching per FilterHandler, we could cache per Filter instance that wants to learn topic names.
3. caching across channels, this would be complex if we wanted to ensure that users ACLs are honoured so that a user
   cannot learn the names of topics they are not allowed to access. It is more achievable if the proxy is also 100%
   responsible for authorization.