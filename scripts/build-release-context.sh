#!/usr/bin/env bash
#
# Assemble the parent build context that Dockerfile.dockerignore describes.
#
#   <context>/
#     autolaunch-web/          this checkout
#     design-system/regent_ui/ the sibling source mix.exs resolves by path
#     elixir-utils/privy/      the sibling source mix.exs resolves by path
#     mix-cache/               Mix, Hex and rebar3, extracted from the sealed archive
#     esbuild-linux-arm64      the bundler executable for the target, under the
#       or esbuild-linux-x64   architecture-specific name Mix looks it up by
#
# Every input comes from the sealed supply directory named on the command line
# and is checked against that directory's manifest first. The script refuses
# rather than assemble a context it cannot vouch for, and it never reaches the
# network. Re-running it against the same destination is safe: the destination
# is rebuilt from scratch each time.
#
# The bundler executable is architecture-specific, so the context is built for
# one target architecture: arm64 or amd64. It is checked to be for that
# architecture and not merely present. The assembled context is what binds the
# build to an architecture; the Dockerfile reads whichever bundler it finds.
#
# The sealed supply directory holds:
#
#   SUPPLY-MANIFEST.txt   mix_lock_sha256, mix_cache_sha256,
#                         esbuild-linux-<arch>.sha256, esbuild-linux-<arch>.file
#   MIX-CACHE.tar         the Mix, Hex and rebar3 caches, under a mix-cache/ prefix
#   esbuild-linux-arm64   the bundler executables, one per architecture
#   esbuild-linux-x64
#
# Usage: scripts/build-release-context.sh <destination> <arch> <supply-directory>

set -euo pipefail

usage() {
  printf 'usage: %s <destination> <arch> <supply-directory>\n' "${0##*/}" >&2
  printf '       arch is arm64 or amd64\n' >&2
  exit 2
}

die() {
  printf 'refusing: %s\n' "$1" >&2
  exit 1
}

[ $# -eq 3 ] || usage

destination="$1"
arch="$2"
supply="$3"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
siblings="$(cd -- "$repo_root/.." && pwd)"
privy_source="$siblings/elixir-utils/privy"
regent_ui_source="$siblings/design-system/regent_ui"

# The machine name is what the manifest is held to, so a supply that names the
# wrong architecture is refused rather than staged.
case "$arch" in
  arm64)
    esbuild_binary="esbuild-linux-arm64"
    esbuild_machine="ARM aarch64"
    ;;
  amd64)
    esbuild_binary="esbuild-linux-x64"
    esbuild_machine="x86-64"
    ;;
  *) usage ;;
esac

manifest="$supply/SUPPLY-MANIFEST.txt"

for required in "$manifest" "$supply/MIX-CACHE.tar" \
  "$privy_source" "$regent_ui_source"; do
  [ -e "$required" ] || die "missing supply input: $required"
done

sha256_of() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

# Reads a manifest key into a named variable rather than returning it, so that
# a missing or empty key stops the script instead of a subshell.
read_manifest_value() {
  local target="$1" file="$2" key="$3" value
  value="$(awk -v key="$key" \
    'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$file")"
  [ -n "$value" ] || die "manifest $file has no $key"
  printf -v "$target" '%s' "$value"
}

expect_contains() {
  local label="$1" value="$2" needle="$3"
  case "$value" in
    *"$needle"*) printf '  verified %s\n' "$label" ;;
    *) die "$label -- the manifest disagrees
  expected to name: $needle
  manifest says:    $value" ;;
  esac
}

expect_sha256() {
  local label="$1" path="$2" expected="$3" actual
  [ -f "$path" ] || die "missing supply input: $path"
  actual="$(sha256_of "$path")"
  [ "$actual" = "$expected" ] ||
    die "$label does not match its manifest
  path:     $path
  expected: $expected
  actual:   $actual"
  printf '  verified %s\n' "$label"
}

printf 'verifying sealed supply\n'

# The cache is keyed to one exact lockfile. A drifted lockfile means the cache
# cannot satisfy an offline build, so stop before assembling anything.
read_manifest_value mix_lock_sha256 "$manifest" mix_lock_sha256
expect_sha256 "mix.lock against the Mix cache" "$repo_root/mix.lock" "$mix_lock_sha256"

read_manifest_value mix_cache_sha256 "$manifest" mix_cache_sha256
expect_sha256 "MIX-CACHE.tar" "$supply/MIX-CACHE.tar" "$mix_cache_sha256"

read_manifest_value esbuild_sha256 "$manifest" "$esbuild_binary.sha256"
read_manifest_value esbuild_file "$manifest" "$esbuild_binary.file"
expect_contains "$esbuild_binary is built for $arch" "$esbuild_file" "$esbuild_machine"
expect_sha256 "$esbuild_binary" "$supply/$esbuild_binary" "$esbuild_sha256"

printf 'assembling context at %s\n' "$destination"

mkdir -p "$(dirname -- "$destination")"
staging="$(mktemp -d "${destination%/}.staging.XXXXXX")"
trap 'chmod -R u+w "$staging" 2>/dev/null || true; rm -rf -- "$staging"' EXIT

mkdir -p "$staging/autolaunch-web" "$staging/elixir-utils/privy" \
  "$staging/design-system/regent_ui"

# The checkouts enter whole, minus their own build output and anything shaped
# like a secrets file. This script excludes those itself, so the assembled
# context on disk never carries one; Dockerfile.dockerignore additionally
# narrows what a local build sees, and a proof test holds it to that.
# The pattern has no slash, so it matches at every depth, and it takes a
# directory named .envs/ with it: deliberate, and none exists today.
# rsync offers no portable case-insensitive filter, so an oddly cased name like
# .ENV survives the copy; the guard below is case-insensitive and catches it.
env_filters=(--exclude '.env*')

rsync -a "${env_filters[@]}" --exclude '.git' --exclude '_build/' \
  --exclude 'node_modules/' "$repo_root/" "$staging/autolaunch-web/"
rsync -a "${env_filters[@]}" --exclude '.git' \
  "$privy_source/" "$staging/elixir-utils/privy/"
rsync -a "${env_filters[@]}" --exclude '.git' --exclude '_build/' \
  --exclude 'deps/' --exclude 'node_modules/' \
  "$regent_ui_source/" "$staging/design-system/regent_ui/"

# Only the executable just verified enters, never whatever else the supply holds.
install -m 0755 "$supply/$esbuild_binary" "$staging/$esbuild_binary"

# The archive already carries the mix-cache/ prefix.
tar -xf "$supply/MIX-CACHE.tar" -C "$staging"
[ -d "$staging/mix-cache" ] || die "MIX-CACHE.tar did not yield mix-cache/"

install -m 0644 "$repo_root/Dockerfile" "$staging/Dockerfile"
install -m 0644 "$repo_root/Dockerfile.dockerignore" "$staging/Dockerfile.dockerignore"

# Last look before anything is published, covering the sealed payloads the
# filters above never see and any casing they cannot match. It runs while the
# previous destination is still intact, so a refusal leaves that one in place.
# Paths only, never contents.
offender="$(find "$staging" -iname '.env*' -print -quit)" || die "context scan failed"
[ -z "$offender" ] || die "context contains a secrets-shaped file: $offender"

if [ -e "$destination" ]; then
  chmod -R u+w "$destination"
  rm -rf -- "$destination"
fi
mv "$staging" "$destination"
trap - EXIT

printf 'context ready: %s\n' "$destination"
printf 'build with:\n'
# docker build, not a buildx builder: it uses the daemon's own image store, so
# --pull=false resolves the pinned base images already held there and the build
# stays offline. A container-driver builder keeps a separate store and would
# have nothing to resolve against.
printf '  docker build --network=none --pull=false --platform linux/%s \\\n' "$arch"
printf '    -f %s/Dockerfile -t <tag> %s\n' "$destination" "$destination"
