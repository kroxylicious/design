# 132 - More specific timer metrics for `SaslTermination`

More specific timer metrics for the `SaslTermination` filter added by [Proposal 124](124-sasl-termination.md).

## Current situation

Proposal 124 added the `SaslTermination` filter with support for OAUTHBEARER, SCRAM-SHA-256 and SCRAM-SHA-512.
During implementation it became apparent that the `kroxylicious_filter_sasl_termination_auth_duration_seconds` timer metric specified by 124 is not always adequate for identifying latency induced by remote services.

## Motivation

As noted in [#4592](https://github.com/kroxylicious/kroxylicious/issues/4592) we have a single timer metric which, in some configurations, measures an elapsed time covering more than a single high-latency action:

    * for `OAUTHBEARER`: 1) token validation with the Oauth authorization server and also possibly 2) remote dependent SubjectBuilder work (for example retreiving information from a token introspection end point, Active Directory, or directory server).
    * for `SCRAM-*`: 1) possibly remote credential lookup (e.g. from a KMS KV store) and also possibly 2) remote dependent SubjectBuilder work (for example retreiving information from Active Directory or directory server).

If this metric spikes it's not possible to easily determine which high-latency action is causing the problem.

## Proposal

### Metrics

To address the lack of specificity in the metrics we will add individual timers 

| Metric name                                     | Tags                           | 
|-------------------------------------------------|--------------------------------|
|`${prefix}_oauthbearer_token_validation_seconds` | `virtual_cluster`              |
|`${prefix}_scram_credential_lookup_seconds`      | `virtual_cluster`              |
|`${prefix}_subject_building_seconds`             | `mechanism`, `virtual_cluster` |

Where `${prefix}` is `kroxylicious_filter_sasl_termination`. 
Note that the metrics which embed the SASL mechanism in their name do not have a `mechanism` tag.
When a mechanism is not enabled the corresponding metric will not be published.
When the default subject builder is used the `subject_building_seconds` metric will not be published, since there's no point in timing, collecting and storing a metric that is measuring the cost of a simple object instantiation.

We will deprecate the existing timer `kroxylicious_filter_sasl_termination_auth_duration_seconds` for removal in a future release. 

## Affected/not affected projects

This affects only the `SaslTermination` filter in the `kroxylicious` project.

## Compatibility

This change is backwards compatible, until the eventual removal of the `kroxylicious_filter_sasl_termination_auth_duration_seconds` metric after the usual deprecation period.

## Rejected alternatives


