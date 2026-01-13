# Upgrade Project JDK to Java 21

Kroylicious is currently developed, built, and distributed as a Java 17 project. Java 17 has been used since early 2023, for almost three years.

This proposal suggests fully moving the Kroylicious build, compilation, and container runtime to Java 21.

## Current situation

Kroylicious uses the Red Hat builds of OpenJDK 17 in its Dockerfiles.

Kroxylicious uses the Eclipse Temurin builds of OpenJDK 17 in its GitHub Actions workflows.

## Motivation

Red Hat’s current plan is to support Java 17 until mid-2027. However, Java 17 appears to be getting less attention than the newer LTS versions, and backporting of bugfixes takes longer. An example of this is the long waiting time for bug fixes in the support for running in containers (see https://github.com/orgs/strimzi/discussions/11966 as an example).

Eclipse's current plan is to support Java 17 until late-2027.

In addition, Java 17 is superseded by two newer LTS releases (21 and 25). Moving to a newer Java version helps keep the project up to date.

## Proposal

This proposal suggests that the Kroxylicious repository moves to Java 21 with immediate effect. This should include the runtime in the container images as well as the language level of all the modules.

## Affected/not affected projects

### Affected

- `kroxylicious`

## Compatibility

Considering that the Kroxylicious documentation has listed JDK version 21 or newer as a prerequisite since late 2024, the compatibility impact for users should hopefully be minimal.

Kroxylicious has Strimzi as a production dependency in the `kroxylicious-operators` module. Strimzi is planned to move to Java 21 in the 0.50.0 release. Strimzi's `api` module is planned to move to Java 21 after Strimzi 0.51 but before Strimzi 1.0.0.

## Rejected alternatives

### Move directly to Java 25

Java 25 is currently the latest available Java LTS release. Moving directly to Java 25 would let us to use the newest and most up-to-date Java version and Java features. Given the minimal effort required to move to Java 21, the proposal recommends adopting Java 21 first. This will allow experience to be gathered before considering a move to Java 25 in the future.
