<!--
PROPOSAL WORKFLOW:
1. Copy this template to: proposals/000-<descriptive-name>.md
2. Fill in your proposal content
3. Open a PR on GitHub
4. Rename the file to use your PR number: proposals/<PR#>-<descriptive-name>.md
   Example: git mv proposals/000-my-feature.md proposals/105-my-feature.md
5. Update the heading below to include your PR number: # <PR#> - <Title>
6. Push the rename and updated title to your PR

See proposals/README.md for complete instructions.
-->

# 000 - Granular Timer Metrics for SASL Termination

This proposal adds component-level latency timers and outcome tagging to the SASL Termination filter so operators can isolate slow external dependencies during authentication.

## Current situation

[Proposal 124](124-sasl-termination.md) introduced SASL Termination with a single latency timer:

* `kroxylicious_filter_sasl_termination_auth_duration_seconds` (tagged with `virtual_cluster` and `mechanism`).

In `SaslTerminationFilter`, `accumulatedAuthWorkNanos` currently sums only the durations from `stateMachine.evaluateRound(...)`, excluding `subjectBuilder.buildSaslSubject(...)`. The timer also has no `outcome` tag, so failed authentications (such as remote timeouts) are recorded into the same histogram as successful handshakes.

## Motivation

SASL authentication relies on three external integration boundaries:

1. **SCRAM credential store lookup** (`ScramCredentialStore.lookupCredential`) against Vault, LDAP, or databases.
2. **OAUTHBEARER token validation** (`OAuthBearerValidatorCallbackHandler`) against JWKS endpoints or token introspection services.
3. **Subject building** (`SaslSubjectBuilder.buildSaslSubject`) against external directory services.

A single aggregate timer hides which dependency caused a latency spike, omits `SaslSubjectBuilder` latency completely, and mixes failure timeouts into success SLO histograms.

## Proposal

### Metric Definitions

Following [Proposal 003](003-metric-improvements.md) Prometheus naming conventions, we propose updating the aggregate timer and introducing three component timers:

| Metric Name | Type | Tags | Description |
| :--- | :--- | :--- | :--- |
| `kroxylicious_filter_sasl_termination_auth_duration_seconds` | Timer | `virtual_cluster`, `mechanism`, `outcome` | Total real authentication work across handshake rounds and subject building, excluding the fixed anti-timing delay. |
| `kroxylicious_filter_sasl_termination_scram_credential_lookup_seconds` | Timer | `virtual_cluster`, `mechanism`, `outcome` | Duration of `ScramCredentialStore.lookupCredential(...)`. |
| `kroxylicious_filter_sasl_termination_oauthbearer_token_validation_seconds` | Timer | `virtual_cluster`, `mechanism`, `outcome` | Duration of OAUTHBEARER token validation. |
| `kroxylicious_filter_sasl_termination_subject_building_seconds` | Timer | `virtual_cluster`, `mechanism`, `outcome` | Duration of `SaslSubjectBuilder.buildSaslSubject(...)`. |

### Tag Values

* `virtual_cluster`: Configured virtual cluster name.
* `mechanism`: SASL mechanism name (`SCRAM-SHA-256`, `SCRAM-SHA-512`, `OAUTHBEARER`).
* `outcome`: `"success"` or `"failure"`.

### Timing Isolation

The configured fixed authentication delay (`applyFixedAuthDelay`) remains excluded from all four timers. Metrics are exposed only on the administrative Prometheus endpoint, preserving SCRAM phantom-user side-channel protection.

## Affected/not affected projects

* **Affected:** `kroxylicious` (`kroxylicious-filters/kroxylicious-sasl-termination` and observability documentation).
* **Not affected:** `kroxylicious-operator`, `kroxylicious-junit5-extension`.

## Compatibility

Existing queries on `kroxylicious_filter_sasl_termination_auth_duration_seconds` continue to match. Adding the `outcome` tag increases time-series cardinality by a factor of 2 (`success` / `failure`), which is bounded.

## Rejected alternatives

* **Keep a single timer with a phase tag:** Rejected because Prometheus histograms and summary percentiles are clearer and easier to alert on per dependency with distinct metric names matching the component boundaries.
