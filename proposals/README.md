# Kroxylicious Proposals

This repository lists proposals for the Kroxylicious project.

## For Proposal Authors

When creating a new proposal:

1. Create your proposal PR with a temporary filename (e.g. `proposals/nnn-my-proposal.md`) based on the [template](./000-template.md).
2. After your proposal PR is created, raise a **separate PR** updating this README file to:
   - Allocate your proposal the next sequential number
   - Add an entry in the "Open Proposals" table below
   - Link to your proposal PR
   - Announce your proposal on the mailing list (https://kroxylicious.io/join-us/mailing-lists/)
3. Once the REAME PRs is merged, rename your proposal file to use the allocated number
4. When your proposal is approved and about to to be merged:
   - Move your proposal from the "Open Proposals" table to the "Accepted Proposals" table
   - Update the link to point to the merged file instead of the PR

This process ensures proposal numbers are allocated in chronological order and avoids conflicts.

## Open Proposals (Pull Requests)

Proposals are numbered in chronological order by PR creation date.

⚠️ **Note:** Some proposals have number collisions with accepted proposals and need to be renumbered:
- PR #70 (currently 004) → should be 016
- PR #82 (currently 007) → should be 017
- PR #83 (currently 012) → should be 018
- PR #85 (currently nnn) → should be 019
- PR #88 (currently 014) → should be 020
- PR #89 (currently 016) → should be 021
- PR #92 (currently xxx) → should be 022
- PR #93 (currently xxx) → should be 023
- PR #94 (currently nnn) → should be 024

| #  | Title                                                                 | PR |
|:--:|:----------------------------------------------------------------------|:--:|
| 24 | [Cleaning up TLS configurations](https://github.com/kroxylicious/design/pull/94) | [#94](https://github.com/kroxylicious/design/pull/94) |
| 23 | [Request/Response Contextual Data API](https://github.com/kroxylicious/design/pull/93) | [#93](https://github.com/kroxylicious/design/pull/93) |
| 22 | [Migrate Kroxylicious Operator to Strimzi v1 API](https://github.com/kroxylicious/design/pull/92) | [#92](https://github.com/kroxylicious/design/pull/92) |
| 21 | [Virtual Cluster Lifecycle](https://github.com/kroxylicious/design/pull/89) | [#89](https://github.com/kroxylicious/design/pull/89) ⚠️ |
| 20 | [Frontend Handler Refactoring & Client Session Context](https://github.com/kroxylicious/design/pull/88) | [#88](https://github.com/kroxylicious/design/pull/88) ⚠️ |
| 19 | [Audit logging](https://github.com/kroxylicious/design/pull/85) | [#85](https://github.com/kroxylicious/design/pull/85) |
| 18 | [Changing Active Proxy Configuration (Hot Reload)](https://github.com/kroxylicious/design/pull/83) | [#83](https://github.com/kroxylicious/design/pull/83) ⚠️ |
| 17 | [Kroxylicious 1.0 and patch releases](https://github.com/kroxylicious/design/pull/82) | [#82](https://github.com/kroxylicious/design/pull/82) ⚠️ |
| 16 | [A Routing API](https://github.com/kroxylicious/design/pull/70) | [#70](https://github.com/kroxylicious/design/pull/70) ⚠️ |

## Accepted Proposals

| #  | Title                                                                 |
|:--:|:----------------------------------------------------------------------|
| 15 | [Entity Isolation Filter](./015-entity-isolation.md) |
| 14 | [Restrict Operator to a Configurable Set of Namespaces](./014-operator-namespace-restriction.md) |
| 13 | [Upgrade Project JDK to Java 21](./013-upgrade-project-jdk-to-java-21.md) |
| 11 | [Plugin API for selecting TLS client credentials for proxy-to-server connection](./011-plugin-api-to-select-tls-credentials-for-server-connection.md) |
| 10 | [Extend the automatic discovery of bootstrap address feature to handle TLS listeners](./010-automatic-discovery-of-strimzi-bootstrap-server-tls.md) |
| 9  | [Authorization Filter](./009-authorizer.md) |
| 8  | [Resolve Topic Names from Topic IDs in the Filter Framework](./008-topic-name-lookup-facility.md) |
| 7  | [Azure KMS Implementation](./007-azure-kms.md) |
| 6  | [API to expose client SASL information to Filters](./006-filter-api-to-expose-client-sasl-info.md) |
| 5  | [Filter API to expose client and server TLS info](./005-filter-api-to-expose-client-and-server-tls-info.md) |
| 4  | [Terminology for Authentication](./004-terminology-for-authentication.md) |
| 3  | [Improvements to Kroxylicious (Proxy) Metrics](./003-metric-improvements.md) |
| 2  | [Automatically trigger a deployment rollout of affected proxies on Kubernetes config change](./002-Automaticly-reload-on-Kubernetes-config-change.md) |
| 1  | [Kroxylicious Operator API (v1alpha)](./001-kroxylicious-operator-api-v1alpha.md) |
