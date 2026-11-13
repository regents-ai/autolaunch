#!/usr/bin/env bash
# Deploys the committed tree to one Fly app, and nothing else.
#
#   scripts/deploy.sh <fly-app>             # the live site: scripts/deploy.sh autolaunch-sh
#   scripts/deploy.sh <fly-app> --dry-run   # every check, then the commands it would run
#
# It refuses a working tree with any change, a commit that is not on
# origin/main, and a commit that does not contain the one already live, so what
# runs is always what the repository holds and never takes live work out. The
# live commit is the one the site's /healthz names; when that cannot be read the
# deploy is refused. The app is named here, never in fly.toml. The image is
# labelled with the short commit it was built from and carries the full commit,
# which /healthz names. The build runs on Fly's builders from a `git archive`
# export of the commit in the temporary folder, so no local build output reaches
# it (a checkout's generated assets would); .dockerignore admits only platform/
# and blog/. Before any machine changes, fly.toml's release_command runs the
# image's migrations; a failed migration stops the deploy.
#
# The deployment descriptions fly.toml places on the machine carry the site's
# private RPC door, so they never enter git or the image: copy them into
# platform/deployment/ (git ignores that folder) before deploying. Before
# anything is built, the two Base descriptions must name the launchers the
# tracked deployed manifests record (scripts/check-deployment.py), dry run
# included. Once the switch is done, the descriptions it shipped are kept in
# platform/deployment/releases/<commit>/, which a rollback to that commit ships.
#
# Run it as it is, never inside lockf: it takes its own locks. To go back to an
# earlier release, use scripts/rollback.sh.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || -z $1 || ($# -eq 2 && $2 != --dry-run) ]]; then
  echo "Usage: scripts/deploy.sh <fly-app> [--dry-run]" >&2
  exit 2
fi
app="$1"
dry_run="${2:-}"

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
# shellcheck source=scripts/release-lib.sh
source scripts/release-lib.sh
health="$(health_address "$app")"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to deploy: commit or remove every change first." >&2
  exit 1
fi

git fetch --quiet origin main
commit="$(git rev-parse HEAD)"
if ! git merge-base --is-ancestor "$commit" origin/main; then
  echo "Refusing to deploy: ${commit:0:7} is not on origin/main. Push it to main first." >&2
  exit 1
fi

check_deployment

tag="${commit:0:7}"
export_dir="${TMPDIR:-/tmp}/autolaunch-deploy-$commit"

# A commit that does not contain the live one would take live work back out,
# which happens when an older main commit is released or two releases cross.
# This is read under the site's own lock, so the second of two deploys reads
# what the first made live. The build takes no shared place.
release() {
  local live
  live="$(live_commit "$health")"
  if ! git -C "$root" merge-base --is-ancestor "$live" "$commit"; then
    echo "Refusing to deploy: $commit does not contain $live, which is live. Update to origin/main first." >&2
    exit 1
  fi
  echo "==> Live is $live, which $commit contains"

  echo "==> Building registry.fly.io/$app:$tag from commit $commit"
  run fly deploy . \
    --config platform/fly.toml \
    --app "$app" \
    --build-only --push \
    --remote-only \
    --build-arg SOURCE_COMMIT="$commit" \
    --image-label "$tag"
  switch_to "registry.fly.io/$app:$tag"

  # A rollback to this commit ships the descriptions it runs with.
  run mkdir -p "$root/platform/deployment/releases/$commit"
  run cp deployment/*.json "$root/platform/deployment/releases/$commit/"
}

export app root dry_run health commit tag
export -f release live_commit run switch_to

if [[ -n $dry_run ]]; then
  echo "==> Dry run: nothing is built or switched. The commands would run in $export_dir, an export of commit $commit."
  release
  exit
fi

mkdir -p "$export_dir/deployment"
git archive "$commit" | tar -x -C "$export_dir"
# fly deploy reads fly.toml's [[files]] local_path from the folder it runs in.
cp platform/deployment/*.json "$export_dir/deployment/"
cd "$export_dir"

# One deploy of this site at a time; other sites' deploys never wait on it.
lock="/tmp/regent-release-$app.lock"
echo "==> Waiting for any other $app deploy holding $lock"
exec lockf -k "$lock" bash -euo pipefail -c release
