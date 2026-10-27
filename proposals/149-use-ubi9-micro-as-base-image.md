# 149 - use ubi9-micro as a base image

This proposal suggests changing our base image from `ubi9-minimal` to `ubi9-micro`, using a three-stage build pattern that preserves the RPM database in the final image.

## Current situation

Current Kroxylicious images are based on [`ubi9-minimal`](https://catalog.redhat.com/en/software/containers/ubi9/ubi-minimal/615bd9b4075b022acc111bf5).
UBI 9 is based on Red Hat Enterprise Linux 9.
Its minimal variant reduces the security footprint by using `microdnf` instead of full `dnf` and by removing many common packages that are present in the standard UBI image.
The image is published by Red Hat and is available to users without any needed subscriptions.

## Motivation

With the current situation around AI and security where basically every day a new CVE is opened we should aim to have a minimal security surface in our images.
As security is one of our goals we should make sure that images we provide to users are always up-to-date and have minimal CVEs that could affect the users.
Our existing security scans also show a lot of base CVEs that are not directly influencing Kroxylicious, but we can get rid of them to make the scans cleaner and users less worried about potential security issues.

## Proposal

To follow security standards and harden our images, Kroxylicious should migrate to `ubi9-micro`.
The key goal is switching from the `minimal` image to the `micro` variant.
The `micro` image does not contain a package manager and the security surface is much smaller than UBI's minimal version.

### Minimal vs Micro

The key difference is that `ubi-micro` excludes the package manager (`microdnf`) and all of its dependencies.
This makes it Red Hat's [distroless](https://www.redhat.com/en/blog/introduction-ubi-micro) container image — built from the same RHEL packages but without the packaging tools.

| Feature                      |        `ubi-minimal`         |              `ubi-micro`               |
|------------------------------|:----------------------------:|:--------------------------------------:|
| Package manager              |          `microdnf`          |                  None                  |
| Shell (`bash`)               |             Yes              |                   No                   |
| Base image size (compressed) |            ~33 MB            |                ~7.5 MB                 |
| Pre-installed packages       |             ~100             |                  ~15                   |
| Package installation         |  `RUN microdnf install ...`  | Multi-stage build with `--installroot` |
| Freely redistributable       |             Yes              |                  Yes                   |
| Architecture support         | amd64, arm64, ppc64le, s390x |      amd64, arm64, ppc64le, s390x      |
| FIPS support                 |     Inherited from host      |          Inherited from host           |

More details can be found in the following sources: [RHEL 9 — Types of container images](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/building_running_and_managing_containers/types-of-container-images), [Introduction to UBI Micro](https://www.redhat.com/en/blog/introduction-ubi-micro), [UBI 9 Micro catalog](https://catalog.redhat.com/en/software/containers/ubi9-micro/61832888ef29c53a494d2771)

### General migration approach

General approach to migrating from current base images to `ubi9-micro` is the same for every project within the Kroxylicious org.

Because `micro` does not contain `microdnf` we need to handle the package installation in a builder stage and then copy the installed packages to the runtime image.
The critical detail is that the RPM database must be preserved in the final image so that vulnerability scanners (e.g. Quay, Clair, Trivy) can correctly attribute packages to their CVE records.
This is achieved by a three-stage build:

1. Start with `ubi9-micro` and copy its entire rootfs (including its RPM database) as the `--installroot` for the builder stage.
2. Use `ubi9-minimal` as the builder: run `microdnf --installroot /mnt/rootfs` to install packages into that copy of the `ubi9-micro` rootfs.
   Because the RPM database was already present in the rootfs before installation, every installed package is recorded in it correctly.
3. Use a fresh `ubi9-micro` as the final stage and copy `/mnt/rootfs` into it.
   The final image has no package manager but retains a fully accurate RPM database for scanner queries.

The mechanism will then consist of a multi-stage build, structured as follows:

- use `ubi9-micro` as a named stage (`base`) — this establishes the clean rootfs with RPM database
- use `ubi9-minimal` as a builder stage — copy the `base` rootfs to `/mnt/rootfs`, then install all required packages with `--installroot /mnt/rootfs --releasever 9`
- download tini (if used) directly into `/mnt/rootfs/usr/bin` in the builder stage
- use `ubi9-micro` again as the final image — copy `/mnt/rootfs` in

### Detailed examples

#### `kroxylicious-operator`

**Current base/Dockerfile (ubi9-minimal):**
```dockerfile
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.8-1788166357@sha256:7fbeae18dc9476399f565e68255f602a3374ea8614ba3d14843565131a13ff93

ARG TARGETOS=linux
ARG TARGETARCH
ARG JAVA_VERSION=21
ARG KROXYLICIOUS_VERSION
ARG CONTAINER_USER=kroxylicious
ARG CONTAINER_USER_UID=185

USER root
WORKDIR /opt/kroxylicious-operator

# Download Tini
ARG TINI_VERSION=v0.19.0
ARG TINI_SHA256_AMD64=93dcc18adc78c65a028a84799ecf8ad40c936fdfc5f2a57b1acda5a8117fa82c
ARG TINI_SHA256_ARM64=07952557df20bfd2a95f9bef198b445e006171969499a1d361bd9e6f8e5e0e81
ARG TINI_SHA256_PPC64LE=3f658420974768e40810001a038c29d003728c5fe86da211cff5059e48cfdfde
ARG TINI_SHA256_S390X=931b70a182af879ca249ae9de87ef68423121b38d235c78997fafc680ceab32d
ARG TINI_DEST=/usr/bin/tini

RUN set -ex; \
    mkdir -p /opt/tini/bin/; \
    if [[ "${TARGETOS}/${TARGETARCH}" = "linux/ppc64le" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-ppc64le -o ${TINI_DEST}; \
        echo "${TINI_SHA256_PPC64LE} *${TINI_DEST}" | sha256sum -c; \
    elif [[ "${TARGETOS}/${TARGETARCH}" = "linux/arm64" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-arm64 -o ${TINI_DEST}; \
        echo "${TINI_SHA256_ARM64} *${TINI_DEST}" | sha256sum -c; \
    elif [[ "${TARGETOS}/${TARGETARCH}" = "linux/s390x" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-s390x -o ${TINI_DEST}; \
        echo "${TINI_SHA256_S390X} *${TINI_DEST}" | sha256sum -c; \
    else \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini -o ${TINI_DEST}; \
        echo "${TINI_SHA256_AMD64} *${TINI_DEST}" | sha256sum -c; \
    fi; \
    chmod +x ${TINI_DEST}

RUN microdnf --setopt=install_weak_deps=0 --setopt=tsflags=nodocs install -y \
                java-${JAVA_VERSION}-openjdk-headless \
                openssl \
                shadow-utils \
    && if [[ -n "${CONTAINER_USER}" && "${CONTAINER_USER}" != "root" ]] ; then groupadd -r -g "${CONTAINER_USER_UID}" "${CONTAINER_USER}" && useradd -m -r -u "${CONTAINER_USER_UID}" -g "${CONTAINER_USER}" "${CONTAINER_USER}"; fi \
    && microdnf remove -y shadow-utils \
    && microdnf clean all

ENV JAVA_HOME=/usr/lib/jvm/jre-${JAVA_VERSION}

COPY target/kroxylicious-operator-${KROXYLICIOUS_VERSION}-app/kroxylicious-operator-${KROXYLICIOUS_VERSION}/ .

USER ${CONTAINER_USER_UID}

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/kroxylicious-operator/bin/operator-start.sh" ]

LABEL url="https://kroxylicious.io/"
LABEL vendor="The Kroxylicious Project"
LABEL maintainer="Kroxylicious Maintainers"
```

**Proposed base/Dockerfile (ubi9-micro, 3-stage):**
```dockerfile
#####
# Stage 1: Establish clean ubi9-micro rootfs with its own RPM database
#####
FROM registry.access.redhat.com/ubi9/ubi-micro:9.8-1791895366@sha256:5be877a2a280ae36eb9ab80ca4efb28bbf77c57abbba38137cdc37a03b8465e6 AS base

#####
# Stage 2: Install runtime dependencies into the ubi9-micro rootfs using dnf --installroot
#####
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.8-1788166357@sha256:7fbeae18dc9476399f565e68255f602a3374ea8614ba3d14843565131a13ff93 AS builder

ARG JAVA_VERSION=21
ARG TARGETOS=linux
ARG TARGETARCH
ARG KROXYLICIOUS_VERSION
ARG CONTAINER_USER=kroxylicious
ARG CONTAINER_USER_UID=185

USER root

# Copy the ubi9-micro rootfs (including its RPM database) as the install root
COPY --from=base / /mnt/rootfs/

RUN microdnf install \
        --installroot /mnt/rootfs \
        --noplugins \
        --config /etc/dnf/dnf.conf \
        --setopt=cachedir=/var/cache/microdnf \
        --setopt=reposdir=/etc/yum.repos.d \
        --setopt=varsdir=/etc/dnf \
        --setopt=install_weak_deps=0 \
        --setopt=tsflags=nodocs \
        --releasever 9 \
        -y \
        java-${JAVA_VERSION}-openjdk-headless \
        openssl \
        shadow-utils \
    && if [[ -n "${CONTAINER_USER}" && "${CONTAINER_USER}" != "root" ]] ; then groupadd -r -g "${CONTAINER_USER_UID}" "${CONTAINER_USER}" && useradd -m -r -u "${CONTAINER_USER_UID}" -g "${CONTAINER_USER}" "${CONTAINER_USER}"; fi \
    && microdnf remove  \
        --installroot /mnt/rootfs \
        --noplugins \
        --config /etc/dnf/dnf.conf \
        --setopt=cachedir=/var/cache/microdnf \
        --setopt=reposdir=/etc/yum.repos.d \
        --setopt=varsdir=/etc/dnf \
        -y shadow-utils \
    && microdnf \
        --installroot /mnt/rootfs \
        --noplugins \
        --config /etc/dnf/dnf.conf \
        --setopt=cachedir=/var/cache/microdnf \
        --setopt=reposdir=/etc/yum.repos.d \
        --setopt=varsdir=/etc/dnf \
        clean all

# Download Tini directly into the rootfs
ARG TINI_VERSION=v0.19.0
ARG TINI_SHA256_AMD64=93dcc18adc78c65a028a84799ecf8ad40c936fdfc5f2a57b1acda5a8117fa82c
ARG TINI_SHA256_ARM64=07952557df20bfd2a95f9bef198b445e006171969499a1d361bd9e6f8e5e0e81
ARG TINI_SHA256_PPC64LE=3f658420974768e40810001a038c29d003728c5fe86da211cff5059e48cfdfde
ARG TINI_SHA256_S390X=931b70a182af879ca249ae9de87ef68423121b38d235c78997fafc680ceab32d
ARG TINI_DEST=/mnt/rootfs/usr/bin/tini

RUN set -ex; \
    mkdir -p /mnt/rootfs/opt/tini/bin/; \
    if [[ "${TARGETOS}/${TARGETARCH}" = "linux/ppc64le" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-ppc64le -o ${TINI_DEST}; \
        echo "${TINI_SHA256_PPC64LE} *${TINI_DEST}" | sha256sum -c; \
    elif [[ "${TARGETOS}/${TARGETARCH}" = "linux/arm64" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-arm64 -o ${TINI_DEST}; \
        echo "${TINI_SHA256_ARM64} *${TINI_DEST}" | sha256sum -c; \
    elif [[ "${TARGETOS}/${TARGETARCH}" = "linux/s390x" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-s390x -o ${TINI_DEST}; \
        echo "${TINI_SHA256_S390X} *${TINI_DEST}" | sha256sum -c; \
    else \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini -o ${TINI_DEST}; \
        echo "${TINI_SHA256_AMD64} *${TINI_DEST}" | sha256sum -c; \
    fi; \
    chmod +x ${TINI_DEST}

#####
# Stage 3: Build the final container image on ubi9-micro base
#####
FROM registry.access.redhat.com/ubi9/ubi-micro:9.8-1791895366@sha256:5be877a2a280ae36eb9ab80ca4efb28bbf77c57abbba38137cdc37a03b8465e6

ARG KROXYLICIOUS_VERSION
ARG CONTAINER_USER_UID=185
ARG JAVA_VERSION=21

ENV JAVA_HOME=/usr/lib/jvm/jre-${JAVA_VERSION}

COPY --from=builder /mnt/rootfs /
COPY target/kroxylicious-operator-${KROXYLICIOUS_VERSION}-app/kroxylicious-operator-${KROXYLICIOUS_VERSION}/ /opt/kroxylicious-operator

USER ${CONTAINER_USER_UID}

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/kroxylicious-operator/bin/operator-start.sh" ]

LABEL url="https://kroxylicious.io/"
LABEL vendor="The Kroxylicious Project"
LABEL maintainer="Kroxylicious Maintainers"
```

#### `kroxylicious-admission`

**Current base/Dockerfile (ubi9-minimal):**
```dockerfile
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.8-1788166357@sha256:7fbeae18dc9476399f565e68255f602a3374ea8614ba3d14843565131a13ff93

ARG TARGETOS=linux
ARG TARGETARCH
ARG JAVA_VERSION=21
ARG KROXYLICIOUS_VERSION
ARG CONTAINER_USER=kroxylicious
ARG CONTAINER_USER_UID=185

USER root
WORKDIR /opt/kroxylicious-webhook

# Download Tini
ARG TINI_VERSION=v0.19.0
ARG TINI_SHA256_AMD64=93dcc18adc78c65a028a84799ecf8ad40c936fdfc5f2a57b1acda5a8117fa82c
ARG TINI_SHA256_ARM64=07952557df20bfd2a95f9bef198b445e006171969499a1d361bd9e6f8e5e0e81
ARG TINI_SHA256_PPC64LE=3f658420974768e40810001a038c29d003728c5fe86da211cff5059e48cfdfde
ARG TINI_SHA256_S390X=931b70a182af879ca249ae9de87ef68423121b38d235c78997fafc680ceab32d
ARG TINI_DEST=/usr/bin/tini

RUN set -ex; \
    mkdir -p /opt/tini/bin/; \
    if [[ "${TARGETOS}/${TARGETARCH}" = "linux/ppc64le" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-ppc64le -o ${TINI_DEST}; \
        echo "${TINI_SHA256_PPC64LE} *${TINI_DEST}" | sha256sum -c; \
    elif [[ "${TARGETOS}/${TARGETARCH}" = "linux/arm64" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-arm64 -o ${TINI_DEST}; \
        echo "${TINI_SHA256_ARM64} *${TINI_DEST}" | sha256sum -c; \
    elif [[ "${TARGETOS}/${TARGETARCH}" = "linux/s390x" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-s390x -o ${TINI_DEST}; \
        echo "${TINI_SHA256_S390X} *${TINI_DEST}" | sha256sum -c; \
    else \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini -o ${TINI_DEST}; \
        echo "${TINI_SHA256_AMD64} *${TINI_DEST}" | sha256sum -c; \
    fi; \
    chmod +x ${TINI_DEST}

RUN microdnf --setopt=install_weak_deps=0 --setopt=tsflags=nodocs install -y \
                java-${JAVA_VERSION}-openjdk-headless \
                openssl \
                shadow-utils \
    && if [[ -n "${CONTAINER_USER}" && "${CONTAINER_USER}" != "root" ]] ; then groupadd -r -g "${CONTAINER_USER_UID}" "${CONTAINER_USER}" && useradd -m -r -u "${CONTAINER_USER_UID}" -g "${CONTAINER_USER}" "${CONTAINER_USER}"; fi \
    && microdnf remove -y shadow-utils \
    && microdnf clean all

ENV JAVA_HOME=/usr/lib/jvm/jre-${JAVA_VERSION}

COPY target/kroxylicious-admission-${KROXYLICIOUS_VERSION}-app/kroxylicious-admission-${KROXYLICIOUS_VERSION}/ .

USER ${CONTAINER_USER_UID}

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/kroxylicious-webhook/bin/webhook-start.sh" ]

LABEL url="https://kroxylicious.io/"
LABEL vendor="The Kroxylicious Project"
LABEL maintainer="Kroxylicious Maintainers"
```

**Proposed base/Dockerfile (ubi9-micro, 3-stage):**
```dockerfile
#####
# Stage 1: Establish clean ubi9-micro rootfs with its own RPM database
#####
FROM registry.access.redhat.com/ubi9/ubi-micro:9.8-1791895366@sha256:5be877a2a280ae36eb9ab80ca4efb28bbf77c57abbba38137cdc37a03b8465e6 AS base

#####
# Stage 2: Install runtime dependencies into the ubi9-micro rootfs using dnf --installroot
#####
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.8-1788166357@sha256:7fbeae18dc9476399f565e68255f602a3374ea8614ba3d14843565131a13ff93 AS builder

ARG TARGETOS=linux
ARG TARGETARCH
ARG JAVA_VERSION=21
ARG CONTAINER_USER=kroxylicious
ARG CONTAINER_USER_UID=185

USER root

# Copy the ubi9-micro rootfs (including its RPM database) as the install root
COPY --from=base / /mnt/rootfs/

RUN microdnf install \
        --installroot /mnt/rootfs \
        --noplugins \
        --config /etc/dnf/dnf.conf \
        --setopt=cachedir=/var/cache/microdnf \
        --setopt=reposdir=/etc/yum.repos.d \
        --setopt=varsdir=/etc/dnf \
        --setopt=install_weak_deps=0 \
        --setopt=tsflags=nodocs \
        --releasever 9 \
        -y \
        java-${JAVA_VERSION}-openjdk-headless \
        openssl \
        shadow-utils \
    && if [[ -n "${CONTAINER_USER}" && "${CONTAINER_USER}" != "root" ]] ; then groupadd -r -g "${CONTAINER_USER_UID}" "${CONTAINER_USER}" && useradd -m -r -u "${CONTAINER_USER_UID}" -g "${CONTAINER_USER}" "${CONTAINER_USER}"; fi \
    && microdnf remove  \
        --installroot /mnt/rootfs \
        --noplugins \
        --config /etc/dnf/dnf.conf \
        --setopt=cachedir=/var/cache/microdnf \
        --setopt=reposdir=/etc/yum.repos.d \
        --setopt=varsdir=/etc/dnf \
        -y shadow-utils \
    && microdnf \
        --installroot /mnt/rootfs \
        --noplugins \
        --config /etc/dnf/dnf.conf \
        --setopt=cachedir=/var/cache/microdnf \
        --setopt=reposdir=/etc/yum.repos.d \
        --setopt=varsdir=/etc/dnf \
        clean all

# Download Tini directly into the rootfs
ARG TINI_VERSION=v0.19.0
ARG TINI_SHA256_AMD64=93dcc18adc78c65a028a84799ecf8ad40c936fdfc5f2a57b1acda5a8117fa82c
ARG TINI_SHA256_ARM64=07952557df20bfd2a95f9bef198b445e006171969499a1d361bd9e6f8e5e0e81
ARG TINI_SHA256_PPC64LE=3f658420974768e40810001a038c29d003728c5fe86da211cff5059e48cfdfde
ARG TINI_SHA256_S390X=931b70a182af879ca249ae9de87ef68423121b38d235c78997fafc680ceab32d
ARG TINI_DEST=/mnt/rootfs/usr/bin/tini

RUN set -ex; \
    mkdir -p /mnt/rootfs/opt/tini/bin/; \
    if [[ "${TARGETOS}/${TARGETARCH}" = "linux/ppc64le" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-ppc64le -o ${TINI_DEST}; \
        echo "${TINI_SHA256_PPC64LE} *${TINI_DEST}" | sha256sum -c; \
    elif [[ "${TARGETOS}/${TARGETARCH}" = "linux/arm64" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-arm64 -o ${TINI_DEST}; \
        echo "${TINI_SHA256_ARM64} *${TINI_DEST}" | sha256sum -c; \
    elif [[ "${TARGETOS}/${TARGETARCH}" = "linux/s390x" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-s390x -o ${TINI_DEST}; \
        echo "${TINI_SHA256_S390X} *${TINI_DEST}" | sha256sum -c; \
    else \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini -o ${TINI_DEST}; \
        echo "${TINI_SHA256_AMD64} *${TINI_DEST}" | sha256sum -c; \
    fi; \
    chmod +x ${TINI_DEST}

#####
# Stage 3: Build the final container image on ubi9-micro base
#####
FROM registry.access.redhat.com/ubi9/ubi-micro:9.8-1791895366@sha256:5be877a2a280ae36eb9ab80ca4efb28bbf77c57abbba38137cdc37a03b8465e6

ARG KROXYLICIOUS_VERSION
ARG CONTAINER_USER_UID=185
ARG JAVA_VERSION=21

ENV JAVA_HOME=/usr/lib/jvm/jre-${JAVA_VERSION}

COPY --from=builder /mnt/rootfs /
COPY target/kroxylicious-admission-${KROXYLICIOUS_VERSION}-app/kroxylicious-admission-${KROXYLICIOUS_VERSION}/ /opt/kroxylicious-webhook

USER ${CONTAINER_USER_UID}

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/kroxylicious-webhook/bin/webhook-start.sh" ]

LABEL url="https://kroxylicious.io/"
LABEL vendor="The Kroxylicious Project"
LABEL maintainer="Kroxylicious Maintainers"
```

#### `kroxylicious-app`

**Current base/Dockerfile (ubi9-minimal):**
```dockerfile
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.8-1788166357@sha256:7fbeae18dc9476399f565e68255f602a3374ea8614ba3d14843565131a13ff93

ARG TARGETOS
ARG TARGETARCH
ARG JAVA_VERSION=21
ARG KROXYLICIOUS_VERSION
ARG CONTAINER_USER=kroxylicious
ARG CONTAINER_USER_UID=185

USER root
WORKDIR /opt/kroxylicious

# Download Tini
ARG TINI_VERSION=v0.19.0
ARG TINI_SHA256_AMD64=93dcc18adc78c65a028a84799ecf8ad40c936fdfc5f2a57b1acda5a8117fa82c
ARG TINI_SHA256_ARM64=07952557df20bfd2a95f9bef198b445e006171969499a1d361bd9e6f8e5e0e81
ARG TINI_SHA256_PPC64LE=3f658420974768e40810001a038c29d003728c5fe86da211cff5059e48cfdfde
ARG TINI_SHA256_S390X=931b70a182af879ca249ae9de87ef68423121b38d235c78997fafc680ceab32d
ARG TINI_DEST=/usr/bin/tini

RUN set -ex; \
    mkdir -p /opt/tini/bin/; \
    if [[ "${TARGETOS}/${TARGETARCH}" = "linux/ppc64le" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-ppc64le -o ${TINI_DEST}; \
        echo "${TINI_SHA256_PPC64LE} *${TINI_DEST}" | sha256sum -c; \
    elif [[ "${TARGETOS}/${TARGETARCH}" = "linux/arm64" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-arm64 -o ${TINI_DEST}; \
        echo "${TINI_SHA256_ARM64} *${TINI_DEST}" | sha256sum -c; \
    elif [[ "${TARGETOS}/${TARGETARCH}" = "linux/s390x" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-s390x -o ${TINI_DEST}; \
        echo "${TINI_SHA256_S390X} *${TINI_DEST}" | sha256sum -c; \
    else \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini -o ${TINI_DEST}; \
        echo "${TINI_SHA256_AMD64} *${TINI_DEST}" | sha256sum -c; \
    fi; \
    chmod +x ${TINI_DEST}

RUN microdnf --setopt=install_weak_deps=0 --setopt=tsflags=nodocs install -y \
                java-${JAVA_VERSION}-openjdk-headless \
                openssl \
                shadow-utils \
    && if [[ -n "${CONTAINER_USER}" && "${CONTAINER_USER}" != "root" ]] ; then groupadd -r -g "${CONTAINER_USER_UID}" "${CONTAINER_USER}" && useradd -m -r -u "${CONTAINER_USER_UID}" -g "${CONTAINER_USER}" "${CONTAINER_USER}"; fi \
    && microdnf remove -y shadow-utils \
    && microdnf clean all

ENV JAVA_HOME=/usr/lib/jvm/jre-${JAVA_VERSION}

COPY target/kroxylicious-app-${KROXYLICIOUS_VERSION}-bin/kroxylicious-app-${KROXYLICIOUS_VERSION}/ .

RUN mkdir -p /opt/kroxylicious/classpath-plugins && chown ${CONTAINER_USER_UID}:${CONTAINER_USER_UID} /opt/kroxylicious/classpath-plugins

USER ${CONTAINER_USER_UID}

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/kroxylicious/bin/kroxylicious-start.sh" ]

LABEL url="https://kroxylicious.io/"
LABEL vendor="The Kroxylicious Project"
LABEL maintainer="Kroxylicious Maintainers"
```

**Proposed base/Dockerfile (ubi9-micro, 3-stage):**
```dockerfile
#####
# Stage 1: Establish clean ubi9-micro rootfs with its own RPM database
#####
FROM registry.access.redhat.com/ubi9/ubi-micro:9.8-1791895366@sha256:5be877a2a280ae36eb9ab80ca4efb28bbf77c57abbba38137cdc37a03b8465e6 AS base

#####
# Stage 2: Install runtime dependencies into the ubi9-micro rootfs using dnf --installroot
#####
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.8-1788166357@sha256:7fbeae18dc9476399f565e68255f602a3374ea8614ba3d14843565131a13ff93 AS builder

ARG JAVA_VERSION=21
ARG TARGETOS
ARG TARGETARCH
ARG CONTAINER_USER=kroxylicious
ARG CONTAINER_USER_UID=185

USER root

# Copy the ubi9-micro rootfs (including its RPM database) as the install root
COPY --from=base / /mnt/rootfs/

RUN microdnf install \
        --installroot /mnt/rootfs \
        --noplugins \
        --config /etc/dnf/dnf.conf \
        --setopt=cachedir=/var/cache/microdnf \
        --setopt=reposdir=/etc/yum.repos.d \
        --setopt=varsdir=/etc/dnf \
        --setopt=install_weak_deps=0 \
        --setopt=tsflags=nodocs \
        --releasever 9 \
        -y \
        java-${JAVA_VERSION}-openjdk-headless \
        openssl \
        shadow-utils \
    && if [[ -n "${CONTAINER_USER}" && "${CONTAINER_USER}" != "root" ]] ; then groupadd -r -g "${CONTAINER_USER_UID}" "${CONTAINER_USER}" && useradd -m -r -u "${CONTAINER_USER_UID}" -g "${CONTAINER_USER}" "${CONTAINER_USER}"; fi \
    && microdnf remove  \
        --installroot /mnt/rootfs \
        --noplugins \
        --config /etc/dnf/dnf.conf \
        --setopt=cachedir=/var/cache/microdnf \
        --setopt=reposdir=/etc/yum.repos.d \
        --setopt=varsdir=/etc/dnf \
        -y shadow-utils \
    && microdnf \
        --installroot /mnt/rootfs \
        --noplugins \
        --config /etc/dnf/dnf.conf \
        --setopt=cachedir=/var/cache/microdnf \
        --setopt=reposdir=/etc/yum.repos.d \
        --setopt=varsdir=/etc/dnf \
        clean all

# Download Tini directly into the rootfs
ARG TINI_VERSION=v0.19.0
ARG TINI_SHA256_AMD64=93dcc18adc78c65a028a84799ecf8ad40c936fdfc5f2a57b1acda5a8117fa82c
ARG TINI_SHA256_ARM64=07952557df20bfd2a95f9bef198b445e006171969499a1d361bd9e6f8e5e0e81
ARG TINI_SHA256_PPC64LE=3f658420974768e40810001a038c29d003728c5fe86da211cff5059e48cfdfde
ARG TINI_SHA256_S390X=931b70a182af879ca249ae9de87ef68423121b38d235c78997fafc680ceab32d
ARG TINI_DEST=/mnt/rootfs/usr/bin/tini

RUN set -ex; \
    mkdir -p /mnt/rootfs/opt/tini/bin/; \
    if [[ "${TARGETOS}/${TARGETARCH}" = "linux/ppc64le" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-ppc64le -o ${TINI_DEST}; \
        echo "${TINI_SHA256_PPC64LE} *${TINI_DEST}" | sha256sum -c; \
    elif [[ "${TARGETOS}/${TARGETARCH}" = "linux/arm64" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-arm64 -o ${TINI_DEST}; \
        echo "${TINI_SHA256_ARM64} *${TINI_DEST}" | sha256sum -c; \
    elif [[ "${TARGETOS}/${TARGETARCH}" = "linux/s390x" ]]; then \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-s390x -o ${TINI_DEST}; \
        echo "${TINI_SHA256_S390X} *${TINI_DEST}" | sha256sum -c; \
    else \
        curl -s -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini -o ${TINI_DEST}; \
        echo "${TINI_SHA256_AMD64} *${TINI_DEST}" | sha256sum -c; \
    fi; \
    chmod +x ${TINI_DEST} \
    && mkdir -p /mnt/rootfs/opt/kroxylicious/classpath-plugins && chown ${CONTAINER_USER_UID}:${CONTAINER_USER_UID} /mnt/rootfs/opt/kroxylicious/classpath-plugins

#####
# Stage 3: Build the final container image on ubi9-micro base
#####
FROM registry.access.redhat.com/ubi9/ubi-micro:9.8-1791895366@sha256:5be877a2a280ae36eb9ab80ca4efb28bbf77c57abbba38137cdc37a03b8465e6

ARG KROXYLICIOUS_VERSION
ARG CONTAINER_USER_UID=185
ARG JAVA_VERSION=21

ENV JAVA_HOME=/usr/lib/jvm/jre-${JAVA_VERSION}

COPY --from=builder /mnt/rootfs /
COPY target/kroxylicious-app-${KROXYLICIOUS_VERSION}-bin/kroxylicious-app-${KROXYLICIOUS_VERSION}/ /opt/kroxylicious

USER ${CONTAINER_USER_UID}

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/kroxylicious/bin/kroxylicious-start.sh" ]

LABEL url="https://kroxylicious.io/"
LABEL vendor="The Kroxylicious Project"
LABEL maintainer="Kroxylicious Maintainers"
```

### Quay scan differences

We can compare scans from Quay.io for `0.26.0-SNAPSHOT` images and the ones based on ubi9-micro (built on 23rd October 2026).

- [0.26.0-SNAPSHOT images](https://quay.io/repository/kroxylicious/operator/manifest/sha256:47ff45a249c88e9753e49b07f5315bb631237241890d7ffc7e8ce856830d8b2e?tab=vulnerabilities) - 340 vulnerabilities (23 fixable)
- [ubi9-micro based](https://quay.io/repository/fvila/operator/manifest/sha256:a3f94f28083ca38fd9897eb3dc241357c00965b1528fa8ee7394558f10b333a7?tab=vulnerabilities) - 208 vulnerabilities

### Testing

This is quite a big change that could behave differently on different clusters.
As a minimal set of testing I would consider the following:
- check that images for all architectures are working fine
- running all our systemtests workflows on GitHub Actions
- running all our systemtests workflows on OpenShift

## Affected/not affected projects

This proposal covers mostly the `kroxyliicious` repository.

The projects within Kroxylicious that produce images are:
- `kroxylicious-operator`
- `kroxylicious-app`
- `kroxylicious-admission`

## Compatibility

This proposal is fully backward compatible.

