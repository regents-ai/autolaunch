#!/usr/bin/env bash
# DESTRUCTIVE: throw the preview chain away and start a fresh one.
#
# Every launch, bid and balance on the fork is lost. Anvil rewrites its state file on exit, so the
# saved state cannot be deleted from inside a running machine; the honest reset destroys the machine
# and its volume, creates a new volume, deploys one machine onto it, and runs bootstrap.sh again.
#
#   ops/fork-preview/bin/reset.sh          prints the steps, executes nothing
#   ops/fork-preview/bin/reset.sh --yes    executes them (needs `fly` logged in with rights on the app)
#
# Env: FORK_APP (autolaunch-fork-preview), FORK_REGION (iad), FORK_VOLUME (fork_state),
#      FORK_VOLUME_SIZE_GB (10). The new chain forks at the upstream head unless the app carries a
#      FORK_BLOCK_NUMBER secret (see README, "Pinning the fork block").
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

YES=0
for argument in "$@"; do
  case "$argument" in
    --yes) YES=1 ;;
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown argument: $argument" ;;
  esac
done
FORK_VOLUME_SIZE_GB=${FORK_VOLUME_SIZE_GB:-10}

run() {
  printf '+ %s\n' "$*"
  if [[ "$YES" == 1 ]]; then "$@"; fi
}

note "reset of $FORK_APP ($FORK_REGION): destroys the chain state, the machine and the volume"
if [[ "$YES" != 1 ]]; then
  note "dry run: the steps below are printed only; add --yes to execute them"
fi

note "# 1. stop and destroy the machine (the volume then has no attachment)"
if [[ "$YES" == 1 ]]; then
  machines=($(fly machine list -a "$FORK_APP" -q))
else
  machines=("<machine id from: fly machine list -a $FORK_APP -q>")
fi
for machine in "${machines[@]}"; do
  run fly machine stop "$machine" -a "$FORK_APP"
  run fly machine destroy "$machine" -a "$FORK_APP" --force
done

note "# 2. destroy the volume holding /data (state.json and fork-block-number)"
if [[ "$YES" == 1 ]]; then
  volumes=($(fly volumes list -a "$FORK_APP" --json | python3 -c '
import json, sys
for volume in json.load(sys.stdin):
    if volume.get("name") == sys.argv[1]:
        print(volume["id"])' "$FORK_VOLUME"))
else
  volumes=("<volume id from: fly volumes list -a $FORK_APP>")
fi
for volume in "${volumes[@]}"; do
  run fly volumes destroy "$volume" -a "$FORK_APP" -y
done

note "# 3. a fresh volume, then one machine on it (fly deploy runs from ops/fork-preview)"
run fly volumes create "$FORK_VOLUME" -a "$FORK_APP" -r "$FORK_REGION" -s "$FORK_VOLUME_SIZE_GB" -y
run bash -c "cd '$OPS_ROOT' && fly deploy --ha=false -a '$FORK_APP'"

note "# 4. forget the old graphs locally, then bootstrap the new chain"
run rm -f "$GENERATED/state.json" "$GENERATED/site-config.json" "$GENERATED/stocks-state.json" "$GENERATED/stocks-site-config.json" \
  "$GENERATED/fork/site-config.json" "$GENERATED/fork/stocks-site-config.json"
note "+ fly proxy 8547:8547 -a $FORK_APP        # in another terminal, keep it open"
note "+ $OPS_ROOT/bin/bootstrap.sh"
if [[ "$YES" == 1 ]]; then
  note ""
  note "machine and volume replaced. Start the proxy in another terminal and run bootstrap.sh; the website's"
  note "fork documents in $GENERATED/fork/ are rewritten by that run and need redeploying with the site."
fi
