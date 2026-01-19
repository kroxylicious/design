# Upgrade Project JDK to Java 21

Kroylicious is currently developed, built, and distributed as a Java 17 project. Java 17 has been used since early 2023, for almost three years.

This proposal suggests moving the Kroylicious build, compilation, and container runtime to Java 21 in two stages.

## Current situation

Kroylicious uses the Red Hat builds of OpenJDK 17 in its Dockerfiles.

Kroxylicious uses the Eclipse Temurin builds of OpenJDK 17 in its GitHub Actions workflows.

## Motivation

Red Hat’s current plan is to support Java 17 until mid-2027. However, Java 17 appears to be getting less attention than the newer LTS versions, and backporting of bugfixes takes longer. An example of this is the long waiting time for bug fixes in the support for running in containers (see https://github.com/orgs/strimzi/discussions/11966 as an example).

Eclipse's current plan is to support Java 17 until late-2027.

In addition, Java 17 is superseded by two newer LTS releases (21 and 25). Moving to a newer Java version helps keep the project up to date.

## Proposal

This proposal suggests that the Kroxylicious repository should move to Java 21 in two stages. This should include the runtime in the container images as well as the language level of all the modules.

In order to comply with the project's [deprecation policy](https://github.com/kroxylicious/kroxylicious/blob/main/DEV_GUIDE.md#deprecation-policy), the upgrade should be staged as so:

1. Kroxylicious running on JDK 17 should be deprecated and a warning should be emitted to users doing so. Kroxylicious should be built/compiled with JDK 21, but produce a JDK 17 compatible jar. The containers should be upgraded to JDK 21.

2. A subsequent release should remove support for JDK 17 and move the target release to Java 21. **This will be a breaking change for users running on bare metal with JDK 17 (see [Compatibility](#compatibility) section).** This will have to be done before adopting a Strimzi `api` release that switches to JDK 21.

## Affected/not affected projects

### Affected

- `kroxylicious`
- `kroxylicious-operator`

## Compatibility

After Step 2 in the [Proposal](#proposal) section is completed, users running Kroxylicious on bare metal will need to upgrade to JDK 21 or above. So this will be a breaking change for those users.

Kroxylicious has Strimzi as a production dependency in the `kroxylicious-operators` module. Strimzi is planned to move to Java 21 in the 0.50.0 release. Strimzi's `api` module is planned to move to Java 21 after Strimzi 0.51 but before Strimzi 1.0.0.

## Rejected alternatives

### Move directly to Java 25

Java 25 is currently the latest available Java LTS release. Moving directly to Java 25 would let us to use the newest and most up-to-date Java version and Java features. Given the minimal effort required to move to Java 21, the proposal recommends adopting Java 21 first. This will allow experience to be gathered before considering a move to Java 25 in the future.
