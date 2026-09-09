#!/usr/bin/env bash
# Put both contract graphs on the preview chain and write the website's two fork documents.
#
# Run from a developer machine AFTER the Fly app is up, with the private door brought here:
#
#   fly proxy 8547:8547 -a autolaunch-fork-preview        # another terminal, keep it open
#   ops/fork-preview/bin/bootstrap.sh [--dry-run] [--force]
#
# Steps
#   1. the private door answers as chain 31337 and carries Base (frozen contracts have code)
#   2. Agent graph:  bin/deploy-agent-graph.py            -> generated/state.json, generated/site-config.json
#   3. Stocks graph: contracts/stocks/bin/local-stocks-lab.py deploy
#                                                         -> generated/stocks-state.json, generated/stocks-site-config.json
#   4. bin/write-fork-configs.py                          -> generated/fork/site-config.json, generated/fork/stocks-site-config.json
#      with rpc_url = FORK_INTERNAL_RPC_URL, public_rpc_url = FORK_PUBLIC_RPC_URL
#
# --dry-run prints every command and runs none of them. --force redeploys over recorded graphs.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRY_RUN=0
FORCE=0
for argument in "$@"; do
  case "$argument" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    -h | --help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown argument: $argument" ;;
  esac
done

STOCKS_ROOT=$REPO_ROOT/contracts/stocks
AGENT_DEPLOY=("python3" "$OPS_ROOT/bin/deploy-agent-graph.py" "--rpc-url" "$FORK_PRIVATE_RPC_URL" "--out" "$GENERATED")
STOCKS_DEPLOY=("python3" "$STOCKS_ROOT/bin/local-stocks-lab.py" "--agent-lab-dir" "$GENERATED" "--rpc-url" "$FORK_PRIVATE_RPC_URL" "deploy")
if [[ "$FORCE" == 1 ]]; then
  AGENT_DEPLOY+=("--force")
  STOCKS_DEPLOY+=("--force")
fi
WRITE_FORK=("python3" "$OPS_ROOT/bin/write-fork-configs.py" "--generated" "$GENERATED" "--rpc-url" "$FORK_INTERNAL_RPC_URL" "--public-rpc-url" "$FORK_PUBLIC_RPC_URL")

show() { printf '+ %s\n' "$*"; }

if [[ "$DRY_RUN" == 1 ]]; then
  note "dry run: nothing below is executed"
  note "# 1. private door ($FORK_PRIVATE_RPC_URL) must answer eth_chainId 0x7a69 and carry Base"
  show "curl -sS -X POST -H 'content-type: application/json' --data '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]}' $FORK_PRIVATE_RPC_URL"
  for address in "$REGENT" "$CCA_FACTORY" "$POOL_MANAGER" "$GOVERNANCE_SAFE"; do
    show "curl ... eth_getCode [\"$address\",\"latest\"]   # must not be 0x"
  done
  show "curl ... anvil_nodeInfo   # reports the pinned fork block (the upstream URL is never printed)"
  note "# 2. Agent graph (cwd $REPO_ROOT/contracts/v1 inside the controller)"
  show "${AGENT_DEPLOY[*]}"
  "${AGENT_DEPLOY[@]}" --dry-run | sed 's/^/    /'
  note "# 3. Stocks graph (cwd $STOCKS_ROOT; needs lib/ from bootstrap-deps.py)"
  show "cd $STOCKS_ROOT && ${STOCKS_DEPLOY[*]}"
  note "# 4. fork documents"
  show "${WRITE_FORK[*]}"
  note "#    -> $GENERATED/fork/site-config.json        rpc_url=$FORK_INTERNAL_RPC_URL public_rpc_url=$FORK_PUBLIC_RPC_URL"
  note "#    -> $GENERATED/fork/stocks-site-config.json rpc_url=$FORK_INTERNAL_RPC_URL public_rpc_url=$FORK_PUBLIC_RPC_URL agent_lab_config=$GENERATED/fork/site-config.json"
  exit 0
fi

for tool in forge cast python3 curl; do
  command -v "$tool" > /dev/null || fail "$tool is required on this machine"
done
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' || fail "Python 3.12+ is required"
[[ -d "$STOCKS_ROOT/lib/forge-std" ]] || fail "$STOCKS_ROOT/lib is empty; run: cd $STOCKS_ROOT && python3 bootstrap-deps.py <hydrated autolaunch checkout>"

note "1/4 checking the private door at $FORK_PRIVATE_RPC_URL"
require_private_door
require_base_fork
note "    chain 31337, Base contracts present, fork block $(fork_block_number), head $(hex_to_dec "$(rpc "$FORK_PRIVATE_RPC_URL" eth_blockNumber)")"

note "2/4 deploying the Agent graph"
show "${AGENT_DEPLOY[*]}"
"${AGENT_DEPLOY[@]}"

note "3/4 deploying the Stocks graph"
show "cd $STOCKS_ROOT && ${STOCKS_DEPLOY[*]}"
(cd "$STOCKS_ROOT" && "${STOCKS_DEPLOY[@]}")

note "4/4 writing the fork documents"
show "${WRITE_FORK[*]}"
"${WRITE_FORK[@]}"

note ""
note "done. Hand the website these two files (AUTOLAUNCH_CHAIN_MODE=fork):"
note "  $GENERATED/fork/site-config.json"
note "  $GENERATED/fork/stocks-site-config.json"
note "The loopback originals in $GENERATED/ stay for the controllers (fund, status, advance ...) through fly proxy."
