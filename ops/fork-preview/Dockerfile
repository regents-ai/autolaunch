# Autolaunch fork preview: Foundry's anvil (pinned release) + the two-door JSON-RPC proxy (Node 22).
# Build context is ops/fork-preview/.

FROM docker.io/library/node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5 AS base

# Foundry v1.5.1 (2025-12-19), the release the local labs run. Digests are the ones GitHub
# publishes for the release assets; the build stops if a tarball ever differs.
ARG FOUNDRY_VERSION=v1.5.1
ARG FOUNDRY_SHA256_AMD64=73640b01bd9ed29fdb4965085099371f8cf0dbbec3e2086cf54564efc4dcfe88
ARG FOUNDRY_SHA256_ARM64=cccf28bdf202289e837a9e21ed213b2b80dc1e806e12f1717bc98a44315c331e
ARG TARGETARCH

FROM base AS foundry
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*
ARG FOUNDRY_VERSION
ARG FOUNDRY_SHA256_AMD64
ARG FOUNDRY_SHA256_ARM64
ARG TARGETARCH
RUN set -eu; \
  case "$TARGETARCH" in \
    amd64) sha="$FOUNDRY_SHA256_AMD64" ;; \
    arm64) sha="$FOUNDRY_SHA256_ARM64" ;; \
    *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  asset="foundry_${FOUNDRY_VERSION}_linux_${TARGETARCH}.tar.gz"; \
  curl -fsSL -o /tmp/foundry.tar.gz \
    "https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_VERSION}/${asset}"; \
  echo "${sha}  /tmp/foundry.tar.gz" | sha256sum -c -; \
  mkdir -p /foundry; \
  tar -xzf /tmp/foundry.tar.gz -C /foundry anvil; \
  /foundry/anvil --version

FROM base AS app
ENV LANG=C.UTF-8
ENV HOME=/app
WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /data

COPY --from=foundry /foundry/anvil /usr/local/bin/anvil
COPY proxy/server.mjs proxy/server.mjs
COPY bin/run-fork.sh bin/upstream-check.mjs bin/
RUN chmod 0755 bin/run-fork.sh

# Runs as root: Fly mounts the volume at /data owned by root, and this single-purpose machine
# holds nothing but a throwaway chain. Anvil itself binds only to 127.0.0.1.
VOLUME ["/data"]
EXPOSE 8545 8547

CMD ["/app/bin/run-fork.sh"]
