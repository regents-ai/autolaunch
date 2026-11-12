#!/usr/bin/env bash
# Deploys the committed tree to one Fly app, and nothing else.
#
#   scripts/deploy.sh <fly-app>        # the live site: scripts/deploy.sh autolaunch-sh
#
# It refuses a working tree with any change, and a commit that is not on
# origin/main, so what runs is always what the repository holds. The app is named
# here, never in fly.toml. The image is labelled with the short commit it was
# built from and carries the full commit, which /healthz names. The build runs on
# Fly's builders from a `git archive` export of the commit in the temporary
# folder, so no local build output reaches it (a checkout's generated assets
# would); .dockerignore admits only platform/ and blog/. Before any machine
# changes, fly.toml's release_command runs the image's migrations; a failed
# migration stops the deploy.
#
# The three deployment descriptions fly.toml places on the machine carry the
# site's private RPC door, so they never enter git or the image: copy them into
# platform/deployment/ (git ignores that folder) before deploying.
set -euo pipefail

if [[ $# -ne 1 || -z $1 ]]; then
  echo "Usage: scripts/deploy.sh <fly-app>" >&2
  exit 2
fi
app="$1"

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

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

export_dir="${TMPDIR:-/tmp}/autolaunch-deploy-$commit"
mkdir -p "$export_dir/deployment"
git archive "$commit" | tar -x -C "$export_dir"
# fly deploy reads fly.toml's [[files]] local_path from the folder it runs in.
cp platform/deployment/*.json "$export_dir/deployment/"
cd "$export_dir"

tag="${commit:0:7}"

# Every site shares one production database, and a switch to a new image briefly
# doubles a site's connections. Two switches fit at once across all sites, so the
# switch takes the first shared place if it is free and otherwise waits for the
# second. It runs in the export folder too, for the [[files]] above.
switch() {
  local place=/tmp/regent-shared-db-release.lock
  lockf -k -s -t 0 "$place" true || place=/tmp/regent-shared-db-release-2.lock
  echo "==> Deploying registry.fly.io/$app:$tag (waits for $place if it is taken)"
  lockf -k "$place" fly deploy \
    --config platform/fly.toml \
    --app "$app" \
    --ha=false \
    --image "registry.fly.io/$app:$tag"
}

# The build takes no shared place.
release() {
  echo "==> Building registry.fly.io/$app:$tag from commit $commit"
  fly deploy . \
    --config platform/fly.toml \
    --app "$app" \
    --build-only --push \
    --remote-only \
    --build-arg SOURCE_COMMIT="$commit" \
    --image-label "$tag"
  switch
}

# One deploy of this site at a time; other sites' deploys never wait on it.
lock="/tmp/regent-release-$app.lock"
echo "==> Waiting for any other $app deploy holding $lock"
export app commit tag
export -f release switch
exec lockf -k "$lock" bash -euo pipefail -c release
