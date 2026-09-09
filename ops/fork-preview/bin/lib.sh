# Shared by the developer-side scripts (bootstrap.sh, status.sh, reset.sh). Source, do not run.
# Needs bash, curl and python3.

OPS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_ROOT=$(cd "$OPS_ROOT/../.." && pwd)

FORK_APP=${FORK_APP:-autolaunch-fork-preview}
FORK_REGION=${FORK_REGION:-iad}
FORK_VOLUME=${FORK_VOLUME:-fork_state}
# The private door, brought to this machine by `fly proxy 8547:8547 -a $FORK_APP`.
FORK_PRIVATE_RPC_URL=${FORK_PRIVATE_RPC_URL:-http://127.0.0.1:8547}
# What the generated documents carry: the private door as the website reaches it, and the public door.
FORK_INTERNAL_RPC_URL=${FORK_INTERNAL_RPC_URL:-http://$FORK_APP.internal:8547}
FORK_PUBLIC_RPC_URL=${FORK_PUBLIC_RPC_URL:-https://$FORK_APP.fly.dev}
GENERATED=$OPS_ROOT/generated

# Well-known Base addresses the fork must carry (mirrors contracts/v1/bin/local-base-lab.py).
REGENT=0x6f89bca4ea5931edfcb09786267b251dee752b07
CCA_FACTORY=0x000000001f26a0044baa66024e7b6599c61963f8
POOL_MANAGER=0x498581ff718922c3f8e6a244956af099b2652b2b
GOVERNANCE_SAFE=0x9fa152b0eadbfe9a7c5c0a8e1d11784f22669a3e
SEL_NEXT_LAUNCH_ID=0x979bd9cc   # nextLaunchId()
SEL_LAUNCH_FEE=0xcf3cf573       # launchFee()
SEL_LAUNCHES_PAUSED=0x3bc340c2  # launchesPaused()

fail() { printf 'fork preview: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

# rpc URL METHOD [PARAMS_JSON]  -> prints the JSON `result`, fails on a JSON-RPC error.
rpc() {
  local url=$1 method=$2 params=${3:-[]} body
  body=$(curl -sS --max-time 30 -X POST -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" "$url") \
    || fail "no answer from $url for $method"
  printf '%s' "$body" | python3 -c '
import json, sys
document = json.load(sys.stdin)
if "error" in document:
    sys.stderr.write(sys.argv[1] + " failed: " + str(document["error"].get("message")) + "\n")
    sys.exit(1)
print(json.dumps(document.get("result")))' "$method" || fail "$method was refused by $url"
}

# hex_to_dec '"0x1a"' -> 26
hex_to_dec() { python3 -c 'import json, sys; print(int(json.loads(sys.argv[1]), 16))' "$1"; }

# eth_call URL TO DATA -> JSON string result
eth_call() { rpc "$1" eth_call "[{\"to\":\"$2\",\"data\":\"$3\"},\"latest\"]"; }

require_private_door() {
  local chain
  chain=$(rpc "$FORK_PRIVATE_RPC_URL" eth_chainId 2> /dev/null) \
    || fail "nothing answers at $FORK_PRIVATE_RPC_URL; in another terminal run: fly proxy 8547:8547 -a $FORK_APP"
  [[ "$chain" == '"0x7a69"' ]] || fail "$FORK_PRIVATE_RPC_URL answers as chain $chain, not 31337"
}

# The fork carries Base: the frozen contracts the graphs bind to must have code.
require_base_fork() {
  local label address code
  for entry in "REGENT:$REGENT" "CCA factory:$CCA_FACTORY" "PoolManager:$POOL_MANAGER" "Governance Safe:$GOVERNANCE_SAFE"; do
    label=${entry%%:*}
    address=${entry#*:}
    code=$(rpc "$FORK_PRIVATE_RPC_URL" eth_getCode "[\"$address\",\"latest\"]")
    [[ "$code" != '"0x"' ]] || fail "$label ($address) has no code on the fork; the upstream is not Base"
  done
}

fork_block_number() {
  rpc "$FORK_PRIVATE_RPC_URL" anvil_nodeInfo | python3 -c '
import json, sys
info = json.load(sys.stdin)
fork = info.get("forkConfig") or {}
print(fork.get("forkBlockNumber", "unknown"))'
}
