#!/bin/sh
# Required gate for the Base Memestake package (contracts/stocks-v2). This is the sole required
# entrypoint; the body is shared with contracts/robinhood-v2 in bin/memestake-gate.sh.
set -eu

cd "$(dirname "$0")/.."

component=contracts/stocks-v2
bindings=src/StocksBindings.sol
slither_root=.
analyzed_sources=src

# The Base package is self-contained: Slither analyzes the package root itself.
prepare_slither_root() {
    :
}

. ./bin/memestake-gate.sh
