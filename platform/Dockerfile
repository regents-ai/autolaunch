FROM docker.io/library/gcc@sha256:9ca91b05c7b07d2979f16413e8b2cd6ec8a7c80ffca4121ccab0aeba33f90460 AS native
FROM docker.io/hexpm/elixir@sha256:d21e3b8bab8bc2e8d51eb4bb03b1d73aad6b91c5c90b3ecc778eb5d136c2e3e6 AS elixir
FROM docker.io/library/node@sha256:5aea649bacdc35e8e20571131c4f3547477dfe66e677d45c005af6dbd1edfaa7 AS node
FROM docker.io/library/debian@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241 AS slim

FROM native AS assets

ENV npm_config_nodedir=/usr/local
WORKDIR /workspace/platform
COPY --from=node /usr/local /usr/local
COPY npm-cache/_cacache /root/.npm/_cacache
COPY platform/package.json platform/package-lock.json ./
RUN npm ci --offline --omit=dev --ignore-scripts --no-audit --no-fund

# The C toolchain in this stage is what builds the SAT solver Ash resolves its
# policies with; the rest of the dependency tree is pure Elixir. The bundler is
# the standalone esbuild executable the context carries; Node is present so the
# asset stage can install the browser packages the Privy bridge needs.
FROM native AS build

ENV MIX_ENV=prod
ENV REGENT_DEPS_ROOT=/workspace
ENV HOME=/root
WORKDIR /workspace/platform

COPY --from=elixir /usr/local /usr/local
COPY --from=assets /usr/local/bin/node /usr/local/bin/node
COPY --from=assets /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm

COPY mix-cache /root/.mix
# The context carries exactly one bundler executable, the one for the target
# it was assembled for, and Mix looks it up by that architecture-specific name.
COPY esbuild-linux-* _build/
COPY platform/deps deps
COPY platform/mix.exs platform/mix.lock ./
COPY elixir-utils/privy /workspace/elixir-utils/privy
COPY design-system/regent_ui /workspace/design-system/regent_ui
COPY platform/config config
RUN mix deps.compile

COPY platform/lib lib
COPY platform/priv priv
COPY platform/rel rel
COPY platform/assets assets
COPY platform/contracts contracts
COPY --from=assets /workspace/platform/node_modules node_modules
RUN mix compile && mix assets.deploy && mix release

# The release carries its own ERTS, so the runtime image needs no Elixir and no
# Erlang install. Two things it does still need are absent from the slim base:
# the OpenSSL library the crypto NIF links against, and the CA bundle outbound
# TLS verifies against. Both are lifted from the builder image, which is only
# sound while the two images are the same Debian release, so this stage asserts
# that first and the build stops here if a base ever moves. Lifting to a fixed
# path also keeps the runtime stage from naming a library directory that
# differs per architecture.
FROM elixir AS runtime-support

COPY --from=slim /etc/os-release /slim-os-release
RUN set -eu; \
  builder="$(. /etc/os-release; printf '%s' "$VERSION_CODENAME")"; \
  runtime="$(. /slim-os-release; printf '%s' "$VERSION_CODENAME")"; \
  if [ "$builder" != "$runtime" ]; then \
    echo "runtime base is Debian $runtime but the builder is Debian $builder;" \
      "the OpenSSL library and CA bundle may not be lifted across releases" >&2; \
    exit 1; \
  fi; \
  mkdir /runtime-support; \
  cp /usr/lib/*-linux-gnu/libcrypto.so.3 /runtime-support/; \
  cp /etc/ssl/certs/ca-certificates.crt /runtime-support/

FROM slim AS app

# The builder image sets this and the slim base does not. Without it the VM
# runs with latin1 name encoding, which Elixir warns about at boot.
ENV LANG=C.UTF-8
ENV HOME=/app
WORKDIR /app

COPY --from=runtime-support /runtime-support/libcrypto.so.3 /usr/lib/
COPY --from=runtime-support /runtime-support/ca-certificates.crt /etc/ssl/certs/

RUN groupadd --system --gid 1001 app \
  && useradd --system --uid 1001 --gid app --home-dir /app app

COPY --from=build --chown=app:app /workspace/platform/_build/prod/rel/autolaunch ./

USER app

EXPOSE 4000

CMD ["/app/bin/autolaunch", "start"]
