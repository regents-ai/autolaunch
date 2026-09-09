#!/usr/bin/env bash
# Read the preview chain through the private door: chain id, blocks, fees, launch counts.
#
#   fly proxy 8547:8547 -a autolaunch-fork-preview        # another terminal
#   ops/fork-preview/bin/status.sh
#
# FORK_PRIVATE_RPC_URL overrides the door (default http://127.0.0.1:8547). Launch counts come from the
# graph addresses recorded in generated/site-config.json and generated/stocks-site-config.json when
# those files exist.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_private_door

head_hex=$(rpc "$FORK_PRIVATE_RPC_URL" eth_blockNumber)
gas_price=$(rpc "$FORK_PRIVATE_RPC_URL" eth_gasPrice)
priority_fee=$(rpc "$FORK_PRIVATE_RPC_URL" eth_maxPriorityFeePerGas)
latest=$(rpc "$FORK_PRIVATE_RPC_URL" eth_getBlockByNumber '["latest",false]')
base_fee=$(printf '%s' "$latest" | python3 -c 'import json,sys; b=json.load(sys.stdin); print(int(b.get("baseFeePerGas","0x0"),16))')
timestamp=$(printf '%s' "$latest" | python3 -c 'import json,sys,datetime; b=json.load(sys.stdin); print(datetime.datetime.fromtimestamp(int(b["timestamp"],16), datetime.UTC).isoformat())')

note "door            $FORK_PRIVATE_RPC_URL"
note "chain id        31337"
note "fork block      $(fork_block_number)"
note "head block      $(hex_to_dec "$head_hex")  ($timestamp)"
note "base fee        $base_fee wei"
note "gas price       $(hex_to_dec "$gas_price") wei"
note "priority fee    $(hex_to_dec "$priority_fee") wei"

address_of() {
  # address_of FILE KEY -> address or empty
  python3 -c '
import json, sys
from pathlib import Path
path, key = sys.argv[1:]
try:
    print(json.loads(Path(path).read_text())["addresses"][key])
except (OSError, KeyError, ValueError):
    print("")' "$1" "$2"
}

report_factory() {
  # report_factory LABEL ADDRESS
  local label=$1 address=$2 next paused fee fee_regent paused_word=no
  next=$(hex_to_dec "$(eth_call "$FORK_PRIVATE_RPC_URL" "$address" "$SEL_NEXT_LAUNCH_ID")")
  paused=$(hex_to_dec "$(eth_call "$FORK_PRIVATE_RPC_URL" "$address" "$SEL_LAUNCHES_PAUSED")")
  fee=$(hex_to_dec "$(eth_call "$FORK_PRIVATE_RPC_URL" "$address" "$SEL_LAUNCH_FEE")")
  fee_regent=$(python3 -c 'import sys; print(format(int(sys.argv[1]) // 10**18, ","))' "$fee")
  [[ "$paused" == 1 ]] && paused_word=yes
  note "$label"
  note "  address       $address"
  note "  launches      $((next - 1))"
  note "  paused        $paused_word"
  note "  launch fee    $fee_regent REGENT"
}

agent_factory=$(address_of "$GENERATED/site-config.json" factory)
if [[ -n "$agent_factory" ]]; then
  report_factory "agent factory" "$agent_factory"
else
  note "agent factory   not recorded in $GENERATED/site-config.json (run bootstrap.sh)"
fi

stocks_launchpad=$(address_of "$GENERATED/stocks-site-config.json" launchpad)
if [[ -n "$stocks_launchpad" ]]; then
  report_factory "stocks launchpad" "$stocks_launchpad"
else
  note "stocks launchpad not recorded in $GENERATED/stocks-site-config.json (run bootstrap.sh)"
fi
