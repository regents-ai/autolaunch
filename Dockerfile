# syntax = docker/dockerfile:1
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.4
ARG UBUNTU_VERSION=noble-20260210.1

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-ubuntu-${UBUNTU_VERSION}"
ARG RUNNER_IMAGE="ubuntu:${UBUNTU_VERSION}"

FROM ghcr.io/foundry-rs/foundry:stable AS foundry

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y --no-install-recommends \
  build-essential \
  git \
  ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY autolaunch/mix.exs autolaunch/mix.lock autolaunch/
COPY elixir-utils elixir-utils
COPY design-system design-system

WORKDIR /workspace/autolaunch

RUN mix deps.get --only $MIX_ENV

COPY autolaunch/config config
RUN mix deps.compile

COPY autolaunch/assets assets
COPY autolaunch/lib lib
COPY autolaunch/priv priv
COPY autolaunch/contracts contracts
COPY autolaunch/rel rel

RUN mix assets.deploy
RUN mix compile
RUN mix release

FROM ${RUNNER_IMAGE} AS runner

RUN apt-get update -y && apt-get install -y --no-install-recommends \
  ca-certificates \
  git \
  libncurses6 \
  libstdc++6 \
  locales \
  openssl \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

COPY --from=foundry /usr/local/bin/forge /usr/local/bin/forge
COPY --from=foundry /usr/local/bin/cast /usr/local/bin/cast

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV HOME=/app

WORKDIR /app

RUN useradd --create-home app

COPY --from=builder --chown=app:app /workspace/autolaunch/_build/prod/rel/autolaunch ./
COPY --from=builder --chown=app:app /workspace/autolaunch/contracts /app/contracts

USER app

CMD ["/app/bin/server"]
