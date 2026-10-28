#!/bin/sh
# Required offline gate for contracts/covered-calls: format, build and every suite except the Base
# fork suite (unit, recovery, invariant). Needs ../stocks-v2/lib, filled by stocks-v2/bootstrap-deps.py.
set -eu
cd "$(dirname "$0")/.."
[ -d ../stocks-v2/lib/forge-std ] && [ -d ../stocks-v2/lib/solady ] || {
  echo "covered-calls gate: ../stocks-v2/lib is empty; run stocks-v2/bootstrap-deps.py first" >&2
  exit 1
}
forge fmt --check
forge build
forge test
