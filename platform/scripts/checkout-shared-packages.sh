#!/usr/bin/env bash
# Check out every shared package at the revision release-inputs.json selects and
# print the REGENT_*_PATH and REGENT_*_REVISION assignments that mix.exs and
# build-release-context.sh read, one NAME=value per line.
set -euo pipefail

die() { printf 'refusing: %s\n' "$1" >&2; exit 1; }
[ "$#" -eq 1 ] || die 'usage: checkout-shared-packages.sh <new-destination>'
destination="$1"
[ ! -e "$destination" ] && [ ! -L "$destination" ] || die 'destination already exists; choose a new directory'
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$destination"
destination="$(cd -- "$destination" && pwd)"

jq -r '.shared_packages | to_entries[] | [.key, .value.repository, .value.revision, .value.path] | @tsv' \
  "$repo_root/release-inputs.json" |
  while IFS=$'\t' read -r package repository revision path; do
    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "$package needs an exact revision"
    # Packages selected at the same repository revision share one checkout.
    checkout="$destination/$revision/$(basename -- "$repository")"
    if [ ! -d "$checkout" ]; then
      git init --quiet "$checkout"
      git -C "$checkout" fetch --quiet --depth 1 "$repository" "$revision"
      git -C "$checkout" checkout --quiet --detach FETCH_HEAD
    fi
    [ -f "$checkout/$path/mix.exs" ] || die "$package is not at $path in $repository at $revision"
    name="$(printf '%s' "${package#regent_}" | tr '[:lower:]' '[:upper:]')"
    printf 'REGENT_%s_PATH=%s\nREGENT_%s_REVISION=%s\n' "$name" "$checkout/$path" "$name" "$revision"
  done
