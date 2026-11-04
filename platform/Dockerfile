# gcc:16.2.0-trixie
FROM docker.io/library/gcc@sha256:07280eb2e744f1b7a2d8d4a3894c089ea07266c109758afc388a634bd098e4eb AS native
# hexpm/elixir:1.20.5-erlang-29.1.2-debian-trixie-20261027-slim
FROM docker.io/hexpm/elixir@sha256:bb266918bb26de22fb02ff19430f47e76331001601df0fc820806c21cd4164e0 AS elixir
# node:26.13.0-trixie-slim
FROM docker.io/library/node@sha256:e4db4c914bf8ad241bd24804fc25d272d89bad97e68cdc8a1414862790a02c39 AS node
# debian:trixie-20261027-slim
FROM docker.io/library/debian@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS slim

FROM native AS assets

ENV npm_config_nodedir=/usr/local
WORKDIR /workspace/platform
COPY --from=node /usr/local /usr/local
COPY platform/package.json platform/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund

# Compile native dependencies for the selected Linux architecture. Resolve
# dependencies from mix.lock; no host build output or sealed cache is required.
FROM native AS build

ENV MIX_ENV=prod
ENV HOME=/root
WORKDIR /workspace/platform

COPY --from=elixir /usr/local /usr/local
COPY --from=assets /usr/local/bin/node /usr/local/bin/node
COPY --from=assets /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm

# Hex and rebar3 at fixed versions; rebar3 is the build Mix itself would pick
# for this Elixir and OTP, checked against its published SHA-512.
RUN mix local.hex 2.6.0 --force && \
  mix local.rebar rebar3 https://builds.hex.pm/installs/1.18.4/rebar3-3.28.0-otp-29 \
    --sha512 b51946058fbe4aa823185bfe27204be59be439982ac3a3e1dbd9f8260b9af046fcfdfbd9066283c3fbba5a2a45dc3570550c12a9a548daf223b80cac222a6d0f \
    --force

# Shared Regent libraries arrive here from GitHub at the commits mix.lock pins;
# a mix.lock that no longer matches mix.exs stops the build.
COPY platform/mix.exs platform/mix.lock ./
COPY platform/config config
RUN mix deps.get --only prod --check-locked && mix deps.compile

COPY platform/lib lib
COPY blog /workspace/blog
COPY platform/priv priv
COPY platform/rel rel
COPY platform/assets assets
COPY platform/contracts contracts
COPY --from=assets /workspace/platform/node_modules node_modules
RUN mix compile && mix assets.deploy && mix release

# The release carries its own ERTS, so the runtime image needs no Elixir and no
# Erlang install. It does still need the OpenSSL library the crypto NIF links
# against, which the slim base lacks. It is lifted from the builder image, which
# is only sound while the two images are the same Debian release, so this stage
# asserts that first and the build stops here if a base ever moves. Lifting to a
# fixed path also keeps the runtime stage from naming a library directory that
# differs per architecture. Outbound TLS needs no CA bundle from the image: the
# release trusts castore's list (`Autolaunch.Application`).
FROM elixir AS runtime-support

COPY --from=slim /etc/os-release /slim-os-release
RUN set -eu; \
  builder="$(. /etc/os-release; printf '%s' "$VERSION_CODENAME")"; \
  runtime="$(. /slim-os-release; printf '%s' "$VERSION_CODENAME")"; \
  if [ "$builder" != "$runtime" ]; then \
    echo "runtime base is Debian $runtime but the builder is Debian $builder;" \
      "the OpenSSL library may not be lifted across releases" >&2; \
    exit 1; \
  fi; \
  mkdir /runtime-support; \
  cp /usr/lib/*-linux-gnu/libcrypto.so.3 /runtime-support/

# The share videos (AutolaunchWeb.ShareVideo.Film) need an ffmpeg that takes
# raw frames in and writes H.264 in MP4, and nothing else. It is built from
# Debian's own signed source for the runtime's release, against that
# release's libx264, so the runtime adds only that one library.
FROM slim AS ffmpeg

WORKDIR /src
RUN sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources \
  && apt-get update \
  && apt-get install -y --no-install-recommends build-essential dpkg-dev nasm pkg-config libx264-dev \
  && apt-get source --download-only ffmpeg \
  && dpkg-source -x ffmpeg_*.dsc ffmpeg
WORKDIR /src/ffmpeg
RUN ./configure --disable-everything --disable-autodetect --disable-doc --disable-network \
    --disable-ffplay --disable-ffprobe --enable-gpl --enable-libx264 \
    --enable-protocol=file,pipe --enable-demuxer=rawvideo --enable-decoder=rawvideo \
    --enable-encoder=libx264 --enable-muxer=mp4 --enable-swscale \
    --enable-filter=scale,format,null,buffer,buffersink \
  && make -j"$(nproc)" ffmpeg \
  && strip ffmpeg

FROM slim AS app

# The builder image sets this and the slim base does not. Without it the VM
# runs with latin1 name encoding, which Elixir warns about at boot.
ENV LANG=C.UTF-8
ENV HOME=/app
WORKDIR /app

COPY --from=runtime-support /runtime-support/libcrypto.so.3 /usr/lib/

# The share videos' ffmpeg and its one library (libx264-164). The build stops
# here unless it encodes a clip exactly the way the site does.
# libsctp1: OTP opens it when it starts and prints a warning on every boot,
# every `bin/autolaunch rpc` and every release command without it.
COPY --from=ffmpeg /src/ffmpeg/ffmpeg /usr/local/bin/ffmpeg
RUN apt-get update \
  && apt-get install -y --no-install-recommends libx264-164 libsctp1 \
  && rm -rf /var/lib/apt/lists/* \
  && head -c 13122000 /dev/zero \
    | ffmpeg -hide_banner -loglevel error -f rawvideo -pix_fmt rgb24 -s 1080x1350 -r 30 \
      -i pipe:0 -c:v libx264 -preset veryfast -crf 21 -pix_fmt yuv420p -movflags +faststart \
      -threads 1 -y /tmp/check.mp4 \
  && rm /tmp/check.mp4

RUN groupadd --system --gid 1001 app \
  && useradd --system --uid 1001 --gid app --home-dir /app app

COPY --from=build --chown=app:app /workspace/platform/_build/prod/rel/autolaunch ./

# The commit this image is built from, as ash-template stamps it. The release
# build passes it (--build-arg SOURCE_COMMIT=<full sha>); a build without it stops here.
ARG SOURCE_COMMIT
RUN test -n "$SOURCE_COMMIT"
ENV SOURCE_COMMIT=$SOURCE_COMMIT
LABEL org.opencontainers.image.revision=$SOURCE_COMMIT

USER app

EXPOSE 4000

CMD ["/app/bin/autolaunch", "start"]
