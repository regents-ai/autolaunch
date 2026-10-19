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
mkdir -p "$export_dir/platform/deployment"
git archive "$commit" | tar -x -C "$export_dir"
cp platform/deployment/*.json "$export_dir/platform/deployment/"
cd "$export_dir"

echo "==> Deploying ${commit:0:7} to $app"
exec fly deploy . \
  --config platform/fly.toml \
  --app "$app" \
  --ha=false \
  --remote-only \
  --build-arg SOURCE_COMMIT="$commit" \
  --image-label "${commit:0:7}"
