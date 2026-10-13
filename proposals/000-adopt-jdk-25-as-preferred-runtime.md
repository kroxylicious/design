# 000 - Adopt JDK 25 as the Preferred Runtime

Kroxylicious targets Java 21 as its language level and runs on JDK 21 in CI and container images, following the two-stage upgrade in [proposal 013](013-upgrade-project-jdk-to-java-21.md). This proposal suggests running Kroxylicious on JDK 25 as the preferred runtime, while keeping the Java 21 language level and JDK 21 test coverage in place for a prolonged period.

## Current situation

Kroxylicious compiles to Java 21 bytecode (`maven.compiler.release=21`); the floor moved from 17 to 21 on 3 July 2026, completing stage 2 of proposal 013.

CI builds and runs the unit test suite against JDK 21. Container images for `kroxylicious` and `kroxylicious-operator` run on JDK 21.

## Motivation

### Post-quantum cryptography

[Proposal #141](https://github.com/kroxylicious/design/pull/141) proposes support for post-quantum key exchange. A JDK with JEP 527 (post-quantum ML-KEM key exchange) built in avoids a dependency on Bouncy Castle, which proposal #141 already rejects as an alternative. JEP 527 ships in JDK 25. OpenJDK 25.0.5, the first JDK 25 update release, is due 20 October 2026. Moving the preferred runtime to JDK 25 gives proposal #141 a path to ML-KEM support without an external crypto library.

### A more current LTS

JDK 21 is now one LTS release behind JDK 25. Newer LTS releases get garbage collector improvements and bug fixes faster than older ones, since vendor attention shifts to the latest release first.

## Proposal

This proposal separates the *preferred runtime* (the JDK the project builds containers with and recommends to operators) from the *language level* (the bytecode target and minimum supported JDK).

1. Once OpenJDK 25.0.5 reaches general availability on 20 October 2026, update the container images for `kroxylicious` and `kroxylicious-operator` to use a JDK 25 base image, and update CI workflows to build with JDK 25.
2. Keep `maven.compiler.release` at 21. No bytecode or language-level change. Users running Kroxylicious on bare-metal JDK 21 see no breaking change.
3. Continue running the unit test suite against JDK 21, as happens today, so the minimum supported JDK stays verified. Do not run integration/system-tests against 21. JDK25 has all test automation ran against it.
4. Document JDK 25 as the recommended runtime for production deployments, while JDK 21 remains the documented minimum.

## Affected/not affected projects

### Affected

- `kroxylicious` — container base image, CI build JDK, documentation.
- `kroxylicious-operator` — container base image, CI build JDK, documentation.

### Not affected

- Public APIs and language level. `maven.compiler.release` stays at 21, so code already running on JDK 21 bytecode needs no change to run on a JDK 25 runtime.
- `kroxylicious-junit5-extension` — out of scope for this proposal; its JDK target was addressed separately in [proposal 126](126-upgrade-junit5-extension-jdk-to-java-21.md).

## Compatibility

This is not a breaking change. JDK 21 remains the minimum supported and tested version, so users running Kroxylicious on bare-metal JDK 21 are unaffected. Moving the container images and CI to JDK 25 changes what the project ships and recommends, not what it requires.

Container images should move to JDK 25 only once OpenJDK 25.0.5 is generally available (20 October 2026); the project should not ship containers built on a beta JDK build.

## Rejected alternatives

### Raise the language level to 25 now

Raising the floor to 25 so soon after moving it to 21 on 3 July 2026 would be a breaking change for users on bare-metal JDK 21, and would conflict with the project's [deprecation policy](https://github.com/kroxylicious/kroxylicious/blob/main/DEV_GUIDE.md#deprecation-policy). To support Plugin developers we should upgrade the minimum language level at a slower cadence.

### Wait for the next planned LTS review before moving to JDK 25

Deferring this decision would delay proposal #141's access to JEP 527, and value is derived from running on a JDK 25 JVM, not from a change to the build's language level. There is no reason to wait.
