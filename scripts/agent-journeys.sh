#!/bin/sh
# The agent journeys: a person pairs their agent, the agent fills in a Memestock
# launch, and the person reviews and signs it, end to end on this machine.
#
#   scripts/agent-journeys.sh          start the stack, run every journey, stop it
#   scripts/agent-journeys.sh up       start the stack and leave it running
#   scripts/agent-journeys.sh test     run the journeys against a running stack
#   scripts/agent-journeys.sh site     restart only the site, after a code change
#   scripts/agent-journeys.sh down     stop the stack and drop its databases
#
# The stack, all on 127.0.0.1 and all started here:
#   - a copy of Base (Anvil, chain 31337) carrying the v2 contracts as deployed,
#     with stand-in stock tokens and launches switched on, on the copy only
#     (test/journeys/support/base_fork.py);
#   - a sign-in service (siwa-server at SIWA_SERVER_REV) with a throwaway key store
#     and its own database;
#   - Autolaunch in the test environment on its own database, in fork chain mode,
#     checking agent requests with that sign-in service;
#   - the regents command line at REGENTS_CLI_REV, which the journeys run as the agent.
# The journeys are test/journeys (Playwright at 390 with touch and at 1280). Each
# journey's agent gets a fresh key folder. Nothing here reaches autolaunch.sh or
# siwa.regents.sh; the copy reads Base from REGENT_BASE_RPC_URL (default the public
# https://mainnet.base.org) and never sends to it.
#
# Inputs (all optional):
#   AGENT_JOURNEYS_OUT       where logs and results go (default platform/tmp/agent-journeys/out)
#   AGENT_JOURNEYS_CONTRACTS a checkout whose contracts/v1/lib submodules are filled in, at the
#                            revisions this one pins (default the repository's main checkout)
#   SIWA_SERVER_REPO         a siwa-server checkout holding SIWA_SERVER_REV (default beside it)
#   AUTOLAUNCH_JOURNEYS_PORT the site's port (default 4050, else a free one)
# Every process it starts is stopped by its recorded pid, and its two databases
# (autolaunch_agents_test, siwa_agent_journeys) are dropped by name on the way down.
set -eu

SIWA_SERVER_REV=2ba5df09f5cb54abf28e96d39ad0b6fb45fa0347
REGENTS_CLI_REV=02f89615c4d8ceaf4c6f597f07112e41f001adc6

root=$(cd "$(dirname "$0")/.." && pwd)
platform=$root/platform
work=$platform/tmp/agent-journeys
state=$work/run
out=${AGENT_JOURNEYS_OUT:-$work/out}
siwa_db=siwa_agent_journeys
siwa_dir=$work/siwa-server-$SIWA_SERVER_REV
regents_dir=$work/regents-cli-$REGENTS_CLI_REV
fork="python3 $platform/test/journeys/support/base_fork.py"
main_checkout=$(cd "$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)
export REGENT_BASE_RPC_URL="${REGENT_BASE_RPC_URL:-https://mainnet.base.org}"

say() { printf '%s\n' "agent-journeys: $*"; }

free_port() {
  python3 -c "import socket; s = socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])"
}

wait_for() {
  tries=0
  until curl -sf -o /dev/null "$1"; do
    tries=$((tries + 1))
    if [ "$tries" -gt 180 ]; then
      say "$2 did not answer at $1; its log is in $out"
      return 1
    fi
    sleep 1
  done
}

# Stops one recorded process by its pid, and nothing else.
stop_pid() {
  file=$state/$1.pid
  [ -f "$file" ] || return 0
  pid=$(cat "$file")
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    tries=0
    while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 20 ]; do
      sleep 0.5
      tries=$((tries + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid"; fi
    say "stopped $1 (pid $pid)"
  fi
  rm -f "$file"
}

siwa_env() {
  port=$1
  shift
  env MIX_ENV=dev PORT="$port" \
    DATABASE_URL="postgres://postgres@127.0.0.1:5432/$siwa_db?pool_size=2" \
    KEYSTORE_PATH="$state/siwa-keystore.bin" \
    KEYSTORE_PASSWORD=agent-journeys-throwaway \
    SIWA_RECEIPT_SECRET=agent-journeys-throwaway-receipt-secret \
    SIWA_WALLET_ORIGINS=autolaunch=https://autolaunch.localhost "$@"
}

# The servers replace the shell that starts them, so the pid recorded for each
# is the server's own.
exec_siwa() {
  port=$1
  exec env MIX_ENV=dev PORT="$port" \
    DATABASE_URL="postgres://postgres@127.0.0.1:5432/$siwa_db?pool_size=2" \
    KEYSTORE_PATH="$state/siwa-keystore.bin" \
    KEYSTORE_PASSWORD=agent-journeys-throwaway \
    SIWA_RECEIPT_SECRET=agent-journeys-throwaway-receipt-secret \
    SIWA_WALLET_ORIGINS=autolaunch=https://autolaunch.localhost mix phx.server
}

exec_site() {
  # shellcheck disable=SC2046
  exec env -u DATABASE_URL -u DATABASE_DIRECT_URL -u AUTOLAUNCH_LAB_AUTH $(cat "$state/site.env") mix phx.server
}

site_env() {
  # shellcheck disable=SC2046
  env -u DATABASE_URL -u DATABASE_DIRECT_URL -u AUTOLAUNCH_LAB_AUTH $(cat "$state/site.env") "$@"
}

# The v2 contract packages, built once, beside this checkout's own copy of them.
contracts() {
  from=${AGENT_JOURNEYS_CONTRACTS:-$main_checkout}
  git -C "$root" ls-tree -r HEAD contracts/v1/lib | while read -r _mode _type rev lib; do
    have=$(git -C "$from/$lib" rev-parse HEAD 2>/dev/null || echo missing)
    if [ "$rev" != "$have" ]; then
      say "$from/$lib is at $have; this checkout pins $rev"
      exit 1
    fi
  done
  mkdir -p "$work"
  git -C "$root" archive HEAD contracts/stocks-v2 contracts/revstake-v2 | tar -x -C "$work"
  [ -d "$work/contracts/stocks-v2/lib" ] || (cd "$work/contracts/stocks-v2" && python3 bootstrap-deps.py "$from")
  (cd "$work/contracts/stocks-v2" && forge build) >"$out/contracts-build.log" 2>&1
  (cd "$work/contracts/revstake-v2" && forge build) >>"$out/contracts-build.log" 2>&1
}

up() {
  mkdir -p "$state" "$out"
  for piece in site siwa base-fork; do
    if [ -f "$state/$piece.pid" ]; then
      say "a stack is already up; run scripts/agent-journeys.sh down first"
      exit 1
    fi
  done

  say "the v2 contracts and a copy of Base"
  contracts
  $fork start "$state" "$work/contracts" >"$out/base-fork.log" 2>&1
  $fork prepare "$state" "$work/contracts" >>"$out/base-fork.log" 2>&1
  $fork configs "$state" "$work/contracts" >>"$out/base-fork.log" 2>&1
  rpc=http://127.0.0.1:$(cat "$state/base-fork.port")

  say "the sign-in service at $SIWA_SERVER_REV"
  if [ ! -f "$siwa_dir/.built" ]; then
    repo=${SIWA_SERVER_REPO:-$(dirname "$main_checkout")/siwa-server}
    mkdir -p "$siwa_dir"
    git -C "$repo" archive "$SIWA_SERVER_REV" | tar -x -C "$siwa_dir"
    (cd "$siwa_dir" && MIX_ENV=dev mix deps.get && MIX_ENV=dev mix compile) >"$out/siwa-build.log" 2>&1
    touch "$siwa_dir/.built"
  fi
  siwa_port=$(free_port)
  (cd "$siwa_dir" && siwa_env "$siwa_port" sh -c 'mix ecto.create && mix ecto.migrate') >"$out/siwa-setup.log" 2>&1
  (cd "$siwa_dir" && exec_siwa "$siwa_port") >"$out/siwa.log" 2>&1 &
  echo $! >"$state/siwa.pid"
  wait_for "http://127.0.0.1:$siwa_port/healthz" "the sign-in service"

  say "the regents command line at $REGENTS_CLI_REV"
  if [ ! -x "$regents_dir/bin/regents" ]; then
    uv venv -q "$regents_dir"
    uv pip install -q --python "$regents_dir/bin/python" \
      "regents-cli @ git+https://github.com/regents-ai/regents-cli@$REGENTS_CLI_REV"
  fi

  say "Autolaunch on its own database"
  site_port=${AUTOLAUNCH_JOURNEYS_PORT:-4050}
  if lsof -nP -iTCP:"$site_port" -sTCP:LISTEN >/dev/null 2>&1; then site_port=$(free_port); fi
  cat >"$state/site.env" <<EOF
MIX_ENV=test
MIX_TEST_PARTITION=_agents
AUTOLAUNCH_BROWSER_TEST=1
AUTOLAUNCH_CHAIN_MODE=fork
AUTOLAUNCH_DB_POOL_SIZE=3
PORT=$site_port
PRIVY_APP_ID=autolaunch-fixture
AUTOLAUNCH_BASE_DEPLOYMENT=$state/base-revstake.json
AUTOLAUNCH_BASE_STOCKS_DEPLOYMENT=$state/base-memestock.json
AUTOLAUNCH_BASE_DEPLOYMENT_ID=agent-journeys
AUTOLAUNCH_SIWA_URL=http://127.0.0.1:$siwa_port
EOF
  (cd "$platform" && site_env sh -c 'mix run --no-start test/journeys/support/drop.exs && mix db.setup') \
    >"$out/site-setup.log" 2>&1
  start_site

  cat >"$state/stack.env" <<EOF
AUTOLAUNCH_URL=http://127.0.0.1:$site_port
SIWA_URL=http://127.0.0.1:$siwa_port
ANVIL_RPC=$rpc
REGENTS=$regents_dir/bin/regents
STACK_STATE=$state
AGENT_JOURNEYS_OUT=$out
EOF
  say "up: Autolaunch http://127.0.0.1:$site_port, sign-in http://127.0.0.1:$siwa_port, Base copy $rpc"
}

start_site() {
  (cd "$platform" && site_env mix assets.build) >>"$out/site.log" 2>&1
  (cd "$platform" && exec_site) >>"$out/site.log" 2>&1 &
  echo $! >"$state/site.pid"
  wait_for "http://127.0.0.1:$(sed -n 's/^PORT=//p' "$state/site.env")/healthz" "Autolaunch"
}

journeys() {
  [ -f "$state/stack.env" ] || { say "no stack is up; run scripts/agent-journeys.sh up"; exit 1; }
  # shellcheck disable=SC2046
  (cd "$platform" && env $(cat "$state/stack.env") npx playwright test -c test/journeys/playwright.config.ts "$@")
}

down() {
  stop_pid site
  stop_pid siwa
  if [ -f "$state/base-fork.pid" ]; then $fork stop "$state" "$work/contracts" >>"$out/base-fork.log" 2>&1; fi
  if [ -f "$state/site.env" ]; then
    (cd "$platform" && site_env mix run --no-start test/journeys/support/drop.exs) >>"$out/site-setup.log" 2>&1
  fi
  if [ -f "$siwa_dir/.built" ]; then
    (cd "$siwa_dir" && siwa_env 0 mix ecto.drop --force-drop) >>"$out/siwa-setup.log" 2>&1
  fi
  rm -f "$state/stack.env" "$state/site.env" "$state/siwa-keystore.bin"
  say "down; autolaunch_agents_test and $siwa_db are dropped"
}

case "${1:-all}" in
  up) up ;;
  test) shift; journeys "$@" ;;
  site) stop_pid site; start_site ;;
  down) mkdir -p "$out"; down ;;
  all)
    trap 'down' EXIT
    trap 'exit 130' INT TERM
    up
    journeys
    ;;
  *) say "usage: scripts/agent-journeys.sh [up|test|down]"; exit 2 ;;
esac
