#!/bin/sh
# The agent journeys: a person pairs their agent, the agent fills in a Memestock
# launch, and the person reviews and signs it, end to end on this machine.
#
#   scripts/agent-journeys.sh          start the stack, run every journey, stop it
#   scripts/agent-journeys.sh up       start the stack and leave it running
#   scripts/agent-journeys.sh test     run the journeys against a running stack
#   scripts/agent-journeys.sh site     restart only the site of a running stack, after a code change
#   scripts/agent-journeys.sh down     stop the stack and drop its databases
#
# The stack, all on this machine and all started here:
#   - a copy of Base (Anvil, chain 31337) carrying the version 3 contracts as deployed,
#     with stand-in stock tokens, launches switched on and AMZNc covered calls
#     and the Isolated Exposure to After-hours Stocks weekly factory deployed, on the copy only (test/journeys/support/base_fork.py);
#   - a sign-in service (siwa-server at SIWA_SERVER_REV) with a throwaway key store
#     and its own database;
#   - Autolaunch in the test environment on its own database, open for launches,
#     checking agent requests with that sign-in service, and served at
#     https://autolaunch.localhost with a throwaway certificate, the one address that
#     sign-in service lists for it (the command line signs for no other); the Mac
#     opens port 443 only on every address, so it answers on the network while it runs;
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
#   AUTOLAUNCH_JOURNEYS_PORT the site's plain port, for its health check (default 4050, else a free one)
# Foundry first on PATH must be 1.5.1-stable, the build contracts/stocks-v2 pins (see contracts()).
# Every process it starts is stopped by its recorded pid, once that pid is checked to be
# still the process it started. Its two databases are named after this checkout
# (autolaunch_agents_<id>_test, siwa_agent_journeys_<id>), so two checkouts never
# share one, and they are dropped by those names on the way down.
set -eu

SIWA_SERVER_REV=567b7c4b376b87c237a1bbe1a3108d60b04bb4fd
REGENTS_CLI_REV=1608c83572425ff17dc535c01351b68ee5337e96

# Physical paths, as the system reports a running server's folder.
root=$(cd "$(dirname "$0")/.." && pwd -P)
platform=$root/platform
work=$platform/tmp/agent-journeys
state=$work/run
out=${AGENT_JOURNEYS_OUT:-$work/out}
id=$(printf '%s' "$root" | shasum | cut -c1-6)
siwa_db=siwa_agent_journeys_$id
site_db=autolaunch_agents_${id}_test
siwa_dir=$work/siwa-server-$SIWA_SERVER_REV
regents_dir=$work/regents-cli-$REGENTS_CLI_REV
fork="uv run --no-project python $platform/test/journeys/support/base_fork.py"
main_checkout=$(cd "$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)/.." && pwd -P)
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

# Stops one recorded process by its pid, and only while that pid is still the
# server this script started in folder $2: after a restart the number may belong
# to anything else.
stop_pid() {
  file=$state/$1.pid
  [ -f "$file" ] || return 0
  pid=$(cat "$file")
  if [ "$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" = "$2" ]; then
    kill "$pid" 2>/dev/null || true
    tries=0
    while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 60 ]; do
      sleep 0.5
      tries=$((tries + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
    say "stopped $1 (pid $pid)"
  else
    say "did not stop $1: pid $pid is no longer the server this script started in $2"
  fi
  rm -f "$file"
}

already_up() {
  for piece in site siwa base-fork; do
    if [ -f "$state/$piece.pid" ]; then
      say "a stack is already up; run scripts/agent-journeys.sh down first"
      return 0
    fi
  done
  return 1
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

# The version 3 contract packages, built once, beside this checkout's own copy of them, with
# the earlier packages whose deployed manifests and ABIs the settings files name.
contracts() {
  from=${AGENT_JOURNEYS_CONTRACTS:-$main_checkout}
  git -C "$root" ls-tree -r HEAD contracts/v1/lib | while read -r _mode _type rev lib; do
    have=$(git -C "$from/$lib" rev-parse HEAD 2>/dev/null || echo missing)
    if [ "$rev" != "$have" ]; then
      say "$from/$lib is at $have; this checkout pins $rev"
      exit 1
    fi
  done
  # The copy runs on Foundry 1.5.1, the build the v2 contracts are pinned to, though version 3
  # pins 1.8.6: Anvil 1.8 answers Base's stock addresses itself, so a stand-in stock installed
  # there cannot be minted. Forge 1.5.1 builds version 3's sources to the same ABIs.
  pin=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["toolchain"]["forge_commit_sha"])' \
    "$root/contracts/stocks-v2/requirements/frozen-identity.json")
  for tool in anvil cast forge; do
    if ! "$tool" --version | grep -qx "Commit SHA: $pin"; then
      say "$tool on PATH is not the Foundry build stocks-v2 pins ($pin); put that Foundry first on PATH"
      exit 1
    fi
  done
  mkdir -p "$work"
  git -C "$root" archive HEAD contracts/stocks-v3 contracts/revstake-v3 contracts/stocks-v2 contracts/revstake-v2 \
    contracts/stocks contracts/covered-calls-v2 contracts/exposure-v2 | tar -x -C "$work"
  [ -d "$work/contracts/stocks-v3/lib" ] || (cd "$work/contracts/stocks-v3" && python3 bootstrap-deps.py "$from")
  # Covered calls and exposure build against stocks-v2's forge-std and solady.
  [ -d "$work/contracts/stocks-v2/lib" ] || (cd "$work/contracts/stocks-v2" && python3 bootstrap-deps.py "$from")
  (cd "$work/contracts/stocks-v3" && forge build) >"$out/contracts-build.log" 2>&1
  (cd "$work/contracts/revstake-v3" && forge build) >>"$out/contracts-build.log" 2>&1
  (cd "$work/contracts/covered-calls-v2" && forge build) >>"$out/contracts-build.log" 2>&1
  (cd "$work/contracts/exposure-v2" && forge build) >>"$out/contracts-build.log" 2>&1
}

up() {
  mkdir -p "$state" "$out"

  say "the version 3 contracts and a copy of Base"
  contracts
  $fork start "$state" "$work/contracts" >"$out/base-fork.log" 2>&1
  $fork prepare "$state" "$work/contracts" >>"$out/base-fork.log" 2>&1
  $fork configs "$state" "$work/contracts" >>"$out/base-fork.log" 2>&1
  $fork covered-calls "$state" "$work/contracts" >>"$out/base-fork.log" 2>&1
  $fork exposure "$state" "$work/contracts" >>"$out/base-fork.log" 2>&1
  rpc=http://127.0.0.1:$(cat "$state/base-fork.port")

  say "the sign-in service at $SIWA_SERVER_REV"
  if [ ! -f "$siwa_dir/.built" ]; then
    repo=${SIWA_SERVER_REPO:-$(dirname "$main_checkout")/siwa-server}
    git -C "$repo" cat-file -e "$SIWA_SERVER_REV^{commit}" 2>/dev/null || git -C "$repo" fetch -q origin "$SIWA_SERVER_REV"
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
  if lsof -nP -iTCP:443 -sTCP:LISTEN >/dev/null 2>&1; then
    say "something already answers on port 443; https://autolaunch.localhost needs it"
    return 1
  fi
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
    -subj /CN=autolaunch.localhost -addext subjectAltName=DNS:autolaunch.localhost \
    -keyout "$state/site-key.pem" -out "$state/site-cert.pem" >"$out/site-cert.log" 2>&1
  site_port=${AUTOLAUNCH_JOURNEYS_PORT:-4050}
  if lsof -nP -iTCP:"$site_port" -sTCP:LISTEN >/dev/null 2>&1; then site_port=$(free_port); fi
  cat >"$state/site.env" <<EOF
MIX_ENV=test
MIX_TEST_PARTITION=_agents_$id
AUTOLAUNCH_BROWSER_TEST=1
AUTOLAUNCH_LAUNCHES_OPEN=true
AUTOLAUNCH_DB_POOL_SIZE=3
PORT=$site_port
PRIVY_APP_ID=autolaunch-fixture
AUTOLAUNCH_BASE_DEPLOYMENT=$state/base-revstake.json
AUTOLAUNCH_BASE_STOCKS_DEPLOYMENT=$state/base-memestock.json
AUTOLAUNCH_BASE_DEPLOYMENT_ID=agent-journeys
AUTOLAUNCH_COVERED_CALLS=true
AUTOLAUNCH_BASE_COVERED_CALLS_DEPLOYMENT=$state/covered-calls.json
AUTOLAUNCH_EXPOSURE=true
AUTOLAUNCH_BASE_EXPOSURE_DEPLOYMENT=$state/exposure.json
AUTOLAUNCH_SIWA_URL=http://127.0.0.1:$siwa_port
AUTOLAUNCH_JOURNEYS_CERT=$state/site-cert.pem
AUTOLAUNCH_JOURNEYS_KEY=$state/site-key.pem
EOF
  (cd "$platform" && site_env sh -c 'mix run --no-start test/journeys/support/drop.exs && mix db.setup') \
    >"$out/site-setup.log" 2>&1
  start_site
  # The site learns which stocks the launchpad admits by reading its admission
  # history, which on the copy goes back to the real deployment; the journeys
  # start once it has every stock version 2's deployed manifest admits, which
  # the Safe admitted to version 3 with the same routes.
  say "waiting for the site to read the launchpad's admitted stocks"
  wanted=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['admissions']))" \
    "$work/contracts/stocks-v2/deployments/base-mainnet/deployed-manifest.json")
  tries=0
  until [ "$(psql -h 127.0.0.1 -U postgres -d "$site_db" -Atc \
    'select count(*) from autolaunch_app.stocks where admitted' 2>/dev/null || echo 0)" -ge "$wanted" ]; do
    tries=$((tries + 1))
    if [ "$tries" -gt 300 ]; then
      say "the site did not read the admitted stocks; its log is in $out"
      return 1
    fi
    sleep 1
  done

  cat >"$state/stack.env" <<EOF
AUTOLAUNCH_URL=https://autolaunch.localhost
SITE_CERT=$state/site-cert.pem
NODE_EXTRA_CA_CERTS=$state/site-cert.pem
SIWA_URL=http://127.0.0.1:$siwa_port
ANVIL_RPC=$rpc
REGENTS=$regents_dir/bin/regents
STACK_STATE=$state
AGENT_JOURNEYS_OUT=$out
EOF
  say "up: Autolaunch https://autolaunch.localhost, sign-in http://127.0.0.1:$siwa_port, Base copy $rpc"
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
  stop_pid site "$platform"
  stop_pid siwa "$siwa_dir"
  if [ -f "$state/base-fork.pid" ]; then $fork stop "$state" "$work/contracts" >>"$out/base-fork.log" 2>&1; fi
  if [ -f "$state/site.env" ]; then
    (cd "$platform" && site_env mix run --no-start test/journeys/support/drop.exs) >>"$out/site-setup.log" 2>&1
  fi
  if [ -f "$siwa_dir/.built" ]; then
    (cd "$siwa_dir" && siwa_env 0 mix ecto.drop --force-drop) >>"$out/siwa-setup.log" 2>&1
  fi
  rm -f "$state/stack.env" "$state/site.env" "$state/siwa-keystore.bin" "$state/site-cert.pem" "$state/site-key.pem"
  say "down; $site_db and $siwa_db are dropped"
}

case "${1:-all}" in
  up) if already_up; then exit 1; fi; up ;;
  test) shift; journeys "$@" ;;
  site)
    [ -f "$state/site.env" ] || { say "no stack is up; run scripts/agent-journeys.sh up"; exit 1; }
    stop_pid site "$platform"
    start_site
    ;;
  down) mkdir -p "$out"; down ;;
  all)
    if already_up; then exit 1; fi
    trap 'down' EXIT
    trap 'exit 130' INT TERM
    up
    journeys
    ;;
  *) say "usage: scripts/agent-journeys.sh [all|up|test|site|down]"; exit 2 ;;
esac
