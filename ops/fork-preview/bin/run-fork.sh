#!/usr/bin/env bash
# Container entrypoint: one Anvil fork of Base on localhost, then the two-door proxy in front of it.
#
#   FORK_UPSTREAM_RPC_URL  required; the paid Base RPC (Fly secret). Never printed.
#   FORK_BLOCK_NUMBER      optional; pins the fork block on the FIRST boot only. Later boots reuse the
#                          block recorded on the volume so the saved state always sits on the same
#                          upstream snapshot.
#   FORK_BLOCK_TIME        seconds per block (default 2, like Base)
#   FORK_DATA_DIR          volume mount (default /data)
set -euo pipefail

: "${FORK_UPSTREAM_RPC_URL:?FORK_UPSTREAM_RPC_URL is required (set it as a Fly secret)}"
APP_DIR=${FORK_APP_DIR:-/app}
DATA_DIR=${FORK_DATA_DIR:-/data}
STATE_FILE=$DATA_DIR/state.json
BLOCK_FILE=$DATA_DIR/fork-block-number
ANVIL_HOST=127.0.0.1
ANVIL_PORT=8546
ANVIL_URL="http://$ANVIL_HOST:$ANVIL_PORT"

log() { printf '{"t":"%s","event":"%s"%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-}"; }

mkdir -p "$DATA_DIR"

# Decide the fork block. A saved state without its recorded block is refused rather than layered on
# a different upstream snapshot; bin/reset.sh clears both files together.
if [[ -s "$BLOCK_FILE" ]]; then
  FORK_BLOCK_NUMBER=$(tr -d '[:space:]' < "$BLOCK_FILE")
  log fork_block ",\"source\":\"volume\",\"block\":$FORK_BLOCK_NUMBER"
elif [[ -s "$STATE_FILE" ]]; then
  log fatal ",\"error\":\"$STATE_FILE exists without $BLOCK_FILE; reset the volume\""
  exit 1
else
  if [[ -z "${FORK_BLOCK_NUMBER:-}" ]]; then
    FORK_BLOCK_NUMBER=$(node "$APP_DIR/bin/upstream-check.mjs")
    log fork_block ",\"source\":\"upstream_head\",\"block\":$FORK_BLOCK_NUMBER"
  else
    node "$APP_DIR/bin/upstream-check.mjs" > /dev/null
    log fork_block ",\"source\":\"env\",\"block\":$FORK_BLOCK_NUMBER"
  fi
  printf '%s\n' "$FORK_BLOCK_NUMBER" > "$BLOCK_FILE"
fi

if [[ ! "$FORK_BLOCK_NUMBER" =~ ^[0-9]+$ ]]; then
  log fatal ",\"error\":\"fork block is not a decimal number\""
  exit 1
fi

if [[ -s "$STATE_FILE" ]]; then
  log state ",\"action\":\"load\",\"file\":\"$STATE_FILE\""
else
  log state ",\"action\":\"fresh\",\"file\":\"$STATE_FILE\""
fi

anvil \
  --host "$ANVIL_HOST" \
  --port "$ANVIL_PORT" \
  --chain-id 31337 \
  --fork-url "$FORK_UPSTREAM_RPC_URL" \
  --fork-block-number "$FORK_BLOCK_NUMBER" \
  --block-time "${FORK_BLOCK_TIME:-2}" \
  --state "$STATE_FILE" \
  --state-interval 60 \
  --silent &
ANVIL_PID=$!

# Wait (up to five minutes; a large saved state takes a while to load) for Anvil to answer as 31337
# before opening either door.
ready=0
for _ in $(seq 1 600); do
  if ! kill -0 "$ANVIL_PID" 2> /dev/null; then
    log fatal ",\"error\":\"anvil exited during startup\""
    exit 1
  fi
  if node -e '
    const [url] = process.argv.slice(1);
    fetch(url, { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
      signal: AbortSignal.timeout(2000) })
      .then((r) => r.json()).then((d) => process.exit(d.result === "0x7a69" ? 0 : 1))
      .catch(() => process.exit(1));' "$ANVIL_URL"; then
    ready=1
    break
  fi
  sleep 0.5
done
if [[ "$ready" != 1 ]]; then
  log fatal ",\"error\":\"anvil did not answer as chain 31337 within five minutes\""
  kill -TERM "$ANVIL_PID" 2> /dev/null || true
  wait "$ANVIL_PID" 2> /dev/null || true
  exit 1
fi
log anvil_ready ",\"url\":\"$ANVIL_URL\",\"fork_block\":$FORK_BLOCK_NUMBER"

FORK_ANVIL_URL="$ANVIL_URL" \
FORK_PUBLIC_HOST="${FORK_PUBLIC_HOST:-0.0.0.0}" \
FORK_PUBLIC_PORT="${FORK_PUBLIC_PORT:-8545}" \
FORK_PRIVATE_HOST="${FORK_PRIVATE_HOST:-fly-local-6pn}" \
FORK_PRIVATE_PORT="${FORK_PRIVATE_PORT:-8547}" \
  node "$APP_DIR/proxy/server.mjs" &
PROXY_PID=$!

# Stop in order: proxy first so no request lands mid-dump, then Anvil, which writes its state on exit.
shutdown() {
  trap - TERM INT
  log shutdown
  kill -TERM "$PROXY_PID" 2> /dev/null || true
  kill -TERM "$ANVIL_PID" 2> /dev/null || true
  wait "$ANVIL_PID" 2> /dev/null || true
  wait "$PROXY_PID" 2> /dev/null || true
  log stopped
  exit 0
}
trap shutdown TERM INT

# If either process dies, stop the other and exit non-zero so Fly restarts the machine.
wait -n "$ANVIL_PID" "$PROXY_PID" || true
trap - TERM INT
log child_exited
kill -TERM "$PROXY_PID" "$ANVIL_PID" 2> /dev/null || true
wait "$ANVIL_PID" 2> /dev/null || true
wait "$PROXY_PID" 2> /dev/null || true
exit 1
