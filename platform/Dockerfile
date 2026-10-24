# gcc:15.2.0-bookworm
FROM docker.io/library/gcc@sha256:9ca91b05c7b07d2979f16413e8b2cd6ec8a7c80ffca4121ccab0aeba33f90460 AS native
# hexpm/elixir:1.20.4-erlang-29.1.2-debian-bookworm-20261020-slim
FROM docker.io/hexpm/elixir@sha256:11ab449084960993491cdc3493be292464c5a63e8f753ed2afe351486471b69a AS elixir
# node:26.12.0-bookworm-slim
FROM docker.io/library/node@sha256:298992629d69bbd5b2b03ad57094d8e4fcb3a8eeb7c4e25d29de656519568913 AS node
# debian:bookworm-20261020-slim
FROM docker.io/library/debian@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8 AS slim

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

# Shared Regent libraries arrive here from GitHub at the commits mix.lock pins.
RUN mix local.hex --force && mix local.rebar --force

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
