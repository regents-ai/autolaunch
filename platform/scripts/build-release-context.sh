#!/usr/bin/env bash
# Assemble source selected by regentctl worktree-run. Docker installs locked
# Linux dependencies itself; host caches and native binaries never enter.
set -euo pipefail

die() { printf 'refusing: %s\n' "$1" >&2; exit 1; }
[ "$#" -eq 2 ] || die 'usage: build-release-context.sh <new-destination> <arm64|amd64>'
destination="$1"
arch="$2"
case "$arch" in arm64|amd64) ;; *) die 'arch must be arm64 or amd64' ;; esac
[ ! -e "$destination" ] && [ ! -L "$destination" ] || die 'destination already exists; choose a new directory'
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
privy_source="${REGENT_PRIVY_PATH:?run through the prepared worktree runner}"
identity_source="${REGENT_IDENTITY_PATH:?run through the prepared worktree runner}"
regent_ui_source="${REGENT_UI_PATH:?run through the prepared worktree runner}"
for source in "$privy_source" "$identity_source" "$regent_ui_source"; do
  [ -f "$source/mix.exs" ] || die "missing selected package: $source"
done
for revision in "${REGENT_PRIVY_REVISION:-}" "${REGENT_IDENTITY_REVISION:-}" "${REGENT_UI_REVISION:-}"; do
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'each selected package needs its exact revision'
done
mkdir -p "$(dirname -- "$destination")"
destination="$(cd -- "$(dirname -- "$destination")" && pwd)/$(basename -- "$destination")"
for source in "$repo_root" "$privy_source" "$identity_source" "$regent_ui_source"; do
  source="$(cd -- "$source" && pwd)"
  case "$destination" in "$source"|"$source"/*) die 'destination must be outside every source tree' ;; esac
done
staging="$(mktemp -d "${destination%/}.staging.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
mkdir -p "$staging/platform" "$staging/elixir-utils/privy" "$staging/regents/identity" "$staging/design-system/regent_ui"
# Case-insensitive env-shaped names are excluded before reading any file.
# Omit symlinks rather than copying references outside the selected source.
filters=(--exclude '.[eE][nN][vV]*' --exclude '.git' --exclude '_build/' --exclude 'deps/' --exclude 'node_modules/' --exclude 'test-results/' --exclude 'playwright-report/')
rsync -a --no-links "${filters[@]}" "$repo_root/" "$staging/platform/"
rsync -a --no-links "${filters[@]}" "$privy_source/" "$staging/elixir-utils/privy/"
rsync -a --no-links "${filters[@]}" "$identity_source/" "$staging/regents/identity/"
rsync -a --no-links "${filters[@]}" "$regent_ui_source/" "$staging/design-system/regent_ui/"
install -m 0644 "$repo_root/Dockerfile" "$staging/Dockerfile"
install -m 0644 "$repo_root/Dockerfile.dockerignore" "$staging/Dockerfile.dockerignore"
printf 'arch=%s\nregent_privy=%s\nregent_identity=%s\nregent_ui=%s\n' "$arch" "$REGENT_PRIVY_REVISION" "$REGENT_IDENTITY_REVISION" "$REGENT_UI_REVISION" > "$staging/BUILD-INPUTS.txt"
(cd "$staging" && shasum -a 256 platform/mix.lock platform/package-lock.json) >> "$staging/BUILD-INPUTS.txt"
# An atomic rename publishes only a complete context. Existing destinations
# are never removed, so interruption and retries cannot destroy unrelated work.
[ ! -e "$destination" ] && [ ! -L "$destination" ] || die 'destination appeared during assembly'
mv "$staging" "$destination"
trap - EXIT
printf 'context ready: %s\n' "$destination"
printf 'build with: docker build --platform linux/%s -f %q/Dockerfile -t <tag> %q\n' "$arch" "$destination" "$destination"
