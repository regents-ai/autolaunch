#!/bin/sh
# Rehearses deploy/packet.json on a local copy of Base, never on Base itself: starts
# `anvil --network base` forked from Base, sends the packet's exact transaction from the Safe
# (impersonated on the copy only), checks the contract lands at the predicted address with the
# promised code and reads, then runs test/rehearsal on that copy: a whole call's life with the real
# AMZNc, Base USDC and live REGENT staking. Nothing is signed with a real key and nothing reaches
# Base.
#
#   FOUNDRY_BIN   folder holding Foundry 1.8.4 or later (B20 stock tokens need it); default: PATH
#   BASE_RPC_URL  Base to fork from; default https://mainnet.base.org
set -eu
cd "$(dirname "$0")/.."
bin=${FOUNDRY_BIN:-$(dirname "$(command -v anvil)")}
rpc=${BASE_RPC_URL:-https://mainnet.base.org}
packet=deploy/packet.json
field() { python3 -c "import json,sys; print(eval('json.load(open(\"$packet\"))' + sys.argv[1]))" "$1"; }

port=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])")
copy=http://127.0.0.1:$port
"$bin/anvil" --network base --fork-url "$rpc" --port "$port" --silent &
anvil=$!
trap 'kill "$anvil"' EXIT
until "$bin/cast" block-number --rpc-url "$copy" >/dev/null 2>&1; do sleep 1; done
echo "rehearse: Base copy at block $("$bin/cast" block-number --rpc-url "$copy"), chain $("$bin/cast" chain-id --rpc-url "$copy")"

predicted=$(field "['create2']['predicted_address']")
sender=$(field "['signer']['alternative_safe']")
[ "$("$bin/cast" code "$predicted" --rpc-url "$copy")" = "0x" ] || { echo "rehearse: $predicted already has code" >&2; exit 1; }
[ "$("$bin/cast" keccak "$("$bin/cast" code "$(field "['create2']['deployer']")" --rpc-url "$copy")")" = "$(field "['create2']['deployer_code_keccak']")" ] \
  || { echo "rehearse: the deterministic deployer's code is not the expected one" >&2; exit 1; }

"$bin/cast" rpc anvil_impersonateAccount "$sender" --rpc-url "$copy" >/dev/null
"$bin/cast" rpc anvil_setBalance "$sender" 0xde0b6b3a7640000 --rpc-url "$copy" >/dev/null
receipt=$("$bin/cast" send --unlocked --from "$sender" --rpc-url "$copy" --json \
  "$(field "['transaction']['to']")" "$(field "['transaction']['data']")" --value "$(field "['transaction']['value']")")
echo "$receipt" | python3 -c "import json,sys; r=json.load(sys.stdin); print('rehearse: sent', r['transactionHash'], 'status', r['status'], 'gas', int(r['gasUsed'], 16)); sys.exit(r['status'] != '0x1')"

code=$("$bin/cast" keccak "$("$bin/cast" code "$predicted" --rpc-url "$copy")")
[ "$code" = "$(field "['post_deploy']['runtime_code_keccak']")" ] || { echo "rehearse: runtime code $code is not the packet's" >&2; exit 1; }
echo "rehearse: $predicted holds the packet's runtime code ($code)"
for read in "stock()(address)" "usdc()(address)" "staking()(address)" "unit()(uint256)" "FEE_BPS()(uint256)" "EXERCISE_WINDOW()(uint256)"; do
  got=$("$bin/cast" call "$predicted" "$read" --rpc-url "$copy" | cut -d' ' -f1)
  want=$(field "['post_deploy']['reads']['${read%%)*})']")
  [ "$(echo "$got" | tr A-F a-f)" = "$(echo "$want" | tr A-F a-f)" ] || { echo "rehearse: $read is $got, not $want" >&2; exit 1; }
  echo "rehearse: $read = $got"
done

FOUNDRY_PROFILE=rehearsal "$bin/forge" test --network base --fork-url "$copy" -vv
