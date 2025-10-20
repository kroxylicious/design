# Kroxylicious 1.0 and patch releases

This proposal is for a Kroxylicious 1.0 release, and an improved commitment to making patch releases.

## Current situation

Kroxylicious already uses [Semantic Versioning][semver], but so far all releases have been `0.x.y` versions.

The project currently promises API compatibilty covering at "least 3 releases, and at least 3 months".

So far, we have done patch releases (i.e. releases like `0.x.1`) only when a new minor release with a fix is not already released, and not imminent.

## Motivation

Under semantic versioning, releases with a major number of 0 are allowed to break compatibility with previous releases.
The software released by project is maturing, and existing users would benefit from having a stronger guarantee about when compatibility between releases might be broken.

At this time there are already a number of users using Kroxylicious in production, however, some potential users might be put off from adopting Kroxylicious by the `0.` version number. 
A 1.0 release would be a signal that we believe Kroxylicious is production-ready.

## Proposal

### What will have a compatibility guarantee?

We propose that the release that was going to be called `0.18.0` instead be called `1.0`.
By implication of Semantic Versioning, that means we would be committing to not breaking compatibilty until some future `2.0` release.
The time of such a `2.0` release is currently neither known nor planned.

For the avoidance of doubt, this compatibilty guarantee would cover:

1. Binary compatibility of the Java APIs of the following modules:
    * `kroxylicious-api`
    * `kroxylicious-kms`
2. The format of the proxy configuration file, including the configuration of certain plugins provided by the project. Compatibility here means that a released version `1.y` would accept any configuration file that was accepted as valid in any released `1.x` version, where `y > x`. "Valid" means the proxy starts up cleanly.
3. The plugins covered under item 2. are:
    * `kroxylicious-record-encryption`
    * `kroxylicious-kms-provider-aws-kms`
    * `kroxylicious-kms-provider-fortanix-dsm`
    * `kroxylicious-kms-provider-hashicorp-vault`
4. The Kubernetes custom resource APIs defined by the kroxylicious-operator.

If the compatibility guarantee is broken we will treat that as a bug.

### Minor and patch branches

The project needs to strike a balance between:

* what the community can sustainably deliver to end users, 
* what users would like.

The use of the term "the community" in the above is important.
The promises being made here are somewhat contingent on support from the community: 
If you want a bug fixed, but the maintainers do not think it's a priority, you will need to fix it and backport it yourself if you want to see a fix in an official release.

We expect the process to work similarly to the Kafka project itself:

Fixes should always be made to the tip-most branch that is affected by the bug, and subsequently back-ported to the branches for other affected versions. Often, this will mean PRs should be opened against `main`, and back ported to the `1.x` minor branch.

Under semver, patch releases only contain bug fixes. They do not contain new features.
We interpret "bug fixes" to include:

* Bug fixes in Kroxylicious itself, where the bug has been fixed, and back ported to the relevant patch branch.
* exploitable CVEs in dependencies and transitive dependencies, where a fixed version of the dependency has been released.
* exploitable CVEs in Docker images, including in a base image, where a fixed version of the base image has been released.

Note that if a bug is fixed by a new feature merged to `main` then it won't be eligable to be merged to a patch release branch.

# Patch releases

We propose to provide patch releases for current `1.x`, plus up to the previous two minor releases. I.e. If the current release is `1.x.y` then we are prepared to release a `1.x.(y+1)`, `1.(x-1).z` and `1.(x-2).z`.
However, the "up to" is limited to 6 months after the initial minor release. 
So if `1.(x-2).0` was released more than 6 months ago, there is no promise to release a `1.(x-2).z`; it will be at the maintainers' discretion.
This is not a commitment to either:
* fix any particular bug found in `1.x` 
* nor to release back-ported fixes immediately, because releases have a cost. 

When enough bugs have been fixed to justify the effort of doing a release, we will start a release process, creating a patch branch from the tip of the minor branch.

Just because some fixes have been merged to a given patch branch does not imply a patch release needs to be made. For example, if it's been more than 6 months since the initial release from that minor branch.

Users, or potential users, for whom the above commitments are insufficient are advised to find a commercial software vendor who can provide the necessary level of support for Kroxylicious.

## Affected/not affected projects

This proposal concerns the kroxylicious/kroxylicious github projects, and the releases that originate from it.

## Compatibility

This the subject of this proposal and has already been described, above.

## Rejected alternatives

The only alternative is to stick with `0.x` numbering for some amount time.
At the end of the day, the move to 1.0 is more of a subject judgement call than something based on objective criteria.

[semver]: https://semver.org/
