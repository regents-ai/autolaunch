#!/usr/bin/env bash
# Puts one Fly app back on an earlier release's image, and nothing else.
#
#   scripts/rollback.sh <fly-app> <release>             # scripts/rollback.sh autolaunch-sh v269
#   scripts/rollback.sh <fly-app> <release> --dry-run   # every check, then the commands it would run
#
# It refuses a release Fly does not list as complete for the app, and one whose
# commit holds different migrations than the live commit: the database would no
# longer match the older code, so that rollback needs a person. It also refuses
# a release whose deployment descriptions are not kept in
# platform/deployment/releases/<commit>/, where scripts/deploy.sh keeps the ones
# each release ran with: the descriptions in platform/deployment/ belong to the
# live release and may name contracts the older code does not read. Otherwise it
# switches the app to that release's image, with that commit's fly.toml and its
# kept descriptions, then reads /healthz until it names that release's commit.
#
# Run it as it is, never inside lockf: it takes the same locks as
# scripts/deploy.sh, the site's own and a place on the shared database.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 || -z $1 || ! $2 =~ ^v[0-9]+$ || ($# -eq 3 && $3 != --dry-run) ]]; then
  echo "Usage: scripts/rollback.sh <fly-app> <release, such as v269> [--dry-run]" >&2
  exit 2
fi
app="$1"
version="$2"
dry_run="${3:-}"

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
# shellcheck source=scripts/release-lib.sh
source scripts/release-lib.sh
health="$(health_address "$app")"

git fetch --quiet origin main

rollback() {
  local image tag target live changed kept answer
  image="$(fly releases --app "$app" --image --json |
    jq -r --argjson version "${version#v}" \
      '.[] | select(.Version == $version and .Status == "complete") | .ImageRef')"
  if [[ -z $image ]]; then
    echo "Refusing to roll back: $version is not a completed release of $app." >&2
    exit 1
  fi
  tag="${image##*:}"
  if [[ ! $tag =~ ^[0-9a-f]{7,40}$ ]] || ! target="$(git -C "$root" rev-parse --verify --quiet "$tag^{commit}")"; then
    echo "Refusing to roll back: $version ran $image, which names no commit this checkout holds." >&2
    exit 1
  fi

  live="$(live_commit "$health")"
  changed="$(git -C "$root" diff --name-only "$target" "$live" -- platform/priv/repo/migrations)"
  if [[ -n $changed ]]; then
    echo "Refusing to roll back: $version ($target) and the live commit $live hold different migrations:" >&2
    echo "$changed" >&2
    echo "A rollback across a migration is not automatic. It needs a person." >&2
    exit 1
  fi
  kept="$root/platform/deployment/releases/$target"
  if ! compgen -G "$kept/*.json" >/dev/null; then
    echo "Refusing to roll back: no deployment descriptions are kept for $version in $kept. Put the descriptions $version ran with there first." >&2
    exit 1
  fi
  echo "==> Live is $live; $version ran $image, commit $target, with the same migrations"

  if [[ -z $dry_run ]]; then
    folder="$(mktemp -d)"
    trap 'rm -rf -- "$folder"' EXIT
    mkdir "$folder/deployment"
    git -C "$root" archive "$target" platform/fly.toml | tar -x -C "$folder"
    # fly deploy reads fly.toml's [[files]] local_path from the folder it runs in.
    cp "$kept"/*.json "$folder/deployment/"
    cd "$folder"
  fi
  switch_to "$image"

  if [[ -n $dry_run ]]; then
    echo "Would then read $health until it answers: ok $target"
    exit
  fi
  for _ in {1..24}; do
    answer="$(curl -fsS --max-time 20 "$health" || true)"
    if [[ $answer == "ok $target" ]]; then
      echo "==> Rolled back to $version: $health answers \"$answer\""
      exit
    fi
    sleep 5
  done
  echo "The switch to $version finished, but $health still answers \"${answer:0:80}\", not $target." >&2
  exit 1
}

export app root dry_run health version
export -f rollback live_commit run switch_to

if [[ -n $dry_run ]]; then
  echo "==> Dry run: nothing is switched."
  rollback
fi

# One deploy or rollback of this site at a time; other sites never wait on it.
lock="/tmp/regent-release-$app.lock"
echo "==> Waiting for any other $app deploy holding $lock"
exec lockf -k "$lock" bash -euo pipefail -c rollback
