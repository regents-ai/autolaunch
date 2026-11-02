#!/bin/sh
# Required gate for the Base Memestake version 3 package (contracts/stocks-v3). This is the sole
# required entrypoint; the body is shared with the other version 3 package in
# ../stocks-v3/bin/memestake-gate.sh.
set -eu

cd "$(dirname "$0")/.."

component=contracts/stocks-v3
bindings=src/StocksBindings.sol
slither_root=.
analyzed_sources=src

# The Base package is self-contained: Slither analyzes the package root itself.
prepare_slither_root() {
    :
}

. ../stocks-v3/bin/memestake-gate.sh
