# 126 - Upgrade Kroxylicious JUnit5 Extension JDK to Java 21

The Kroxylicious JUnit5 Extension is currently developed, built, and distributed as a Java 17 project.

This proposal suggests moving the build and compilation target to Java 21 in a single step.

## Current situation

The Kroxylicious JUnit5 Extension uses Java 17 as its compilation target (`maven.compiler.release`). The project's CI workflows use Eclipse Temurin builds of OpenJDK 17. The Maven Enforcer plugin requires JDK 17 or above at build time.

The published artifacts (`testing-api`, `testing-junit5-extension`, `testing-impl`) are Java 17 bytecode, used in test scope by consuming projects.

## Motivation

### Alignment with the main Kroxylicious repository

The main Kroxylicious repository has already upgraded to Java 21 (see [proposal 013](013-upgrade-project-jdk-to-java-21.md)). That repository is the primary consumer of the JUnit5 Extension and already requires Java 21 to build and run. Keeping the JUnit5 Extension on Java 17 provides no practical benefit to the main Kroxylicious project.

### Limited impact as a test-scoped dependency

The JUnit5 Extension is a test-scoped dependency. Upgrading it to Java 21 does not affect the production runtime of any consuming project. It only requires that consumers use JDK 21 or above to compile and run their tests, which the main Kroxylicious repository already does.

### Java 17 support is winding down

Red Hat's current plan is to support Java 17 until mid-2027. Eclipse's current plan is to support Java 17 until late-2027. However, Java 17 is receiving less attention than newer LTS versions, and backporting of bugfixes takes longer. 

Java 17 is now superseded by two newer LTS releases (21 and 25).

## Proposal

The Kroxylicious JUnit5 Extension repository should move both the build and compilation target to Java 21 in a single step. Specifically:

1. Update the `java.version` and `java.test.version` Maven properties from `17` to `21` in the root `pom.xml`. This changes the `maven.compiler.release` and `maven.compiler.testRelease` values, so all modules produce Java 21 bytecode.

2. Update the GitHub Actions CI workflows to use JDK 21 as the default Java version for building and testing.

3. Update the Maven Enforcer plugin rule (`requireJavaVersion`) so that builds fail when attempted with a JDK older than 21.

4. Update `DEV_GUIDE.md` to reflect the Java 21 requirement.

This is a single-step change. Unlike the main Kroxylicious repository, the JUnit5 Extension project does not have a formal deprecation policy requiring features to be deprecated before removal. Furthermore, as a test-scoped library, the impact on consumers is limited to their test compilation and execution environments, not their production deployments.

## Affected/not affected projects

### Affected

- `kroxylicious-junit5-extension` — the subject of this proposal.
- `kroxylicious` — primary consumer. Already on Java 21, so no action required.
- `kroxylicious-operator` — consumer. Will need to use JDK 21 or above to compile and run tests that depend on the JUnit5 Extension.

### Not affected

- Projects that depend on Kroxylicious at runtime but do not use the JUnit5 Extension in their test suites.

## Compatibility

**This is a breaking change for consumers still using JDK 17 to compile and run their tests.**

After this change, any project that depends on the JUnit5 Extension will need JDK 21 or above in its test compilation and execution environment. This does not affect production runtime requirements of consuming projects, since the extension is a test-scoped dependency.

The main Kroxylicious repository already requires Java 21, so it is unaffected. Other consumers (such as `kroxylicious-operator` or external users) will need to ensure their build environments use JDK 21 or above before upgrading to the new version of the extension.

## Rejected alternatives

### Move directly to Java 25

Java 25 is currently the latest available Java LTS release. Moving directly to Java 25 would let us use the newest and most up-to-date Java version and features. Given the minimal effort required to move to Java 21 and the fact that the main Kroxylicious repository has already standardised on Java 21, the proposal recommends adopting Java 21 to maintain alignment. This will allow experience to be gathered before considering a move to Java 25 across the project in the future.

### Two-stage deprecation approach

The main Kroxylicious repository used a two-stage approach in [proposal 013](013-upgrade-project-jdk-to-java-21.md): first building with JDK 21 but producing JDK 17 compatible jars with a deprecation warning, then moving the compilation target to Java 21 in a subsequent release. This was necessary because the main repository has a formal [deprecation policy](https://github.com/kroxylicious/kroxylicious/blob/main/DEV_GUIDE.md#deprecation-policy) requiring features to be deprecated before removal.

The JUnit5 Extension project does not have such a deprecation policy. Furthermore, the extension is a test-scoped dependency, making the impact of a direct upgrade lower than for a production runtime dependency. A two-stage approach would add unnecessary complexity and delay for minimal benefit.
