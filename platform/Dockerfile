FROM docker.io/library/gcc@sha256:9ca91b05c7b07d2979f16413e8b2cd6ec8a7c80ffca4121ccab0aeba33f90460 AS native
FROM docker.io/hexpm/elixir@sha256:d21e3b8bab8bc2e8d51eb4bb03b1d73aad6b91c5c90b3ecc778eb5d136c2e3e6 AS elixir
FROM docker.io/library/node@sha256:5aea649bacdc35e8e20571131c4f3547477dfe66e677d45c005af6dbd1edfaa7 AS node
FROM docker.io/library/debian@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241 AS slim

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
COPY --from=runtime-support /runtime-support/ca-certificates.crt /etc/ssl/certs/

# The share videos' ffmpeg and its one library. The build stops here unless it
# encodes a clip exactly the way the site does.
COPY --from=ffmpeg /src/ffmpeg/ffmpeg /usr/local/bin/ffmpeg
RUN apt-get update \
  && apt-get install -y --no-install-recommends libx264-164 \
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
