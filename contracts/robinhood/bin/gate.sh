#!/bin/sh
# Required gate for the Robinhood Memestake package (contracts/robinhood). This is the sole required
# entrypoint; the body is shared with contracts/stocks in ../stocks/bin/memestake-gate.sh.
set -eu

cd "$(dirname "$0")/.."

component=contracts/robinhood
bindings=
slither_root=reports/generated/slither-copy
analyzed_sources="src ../stocks/src"

# Slither's Foundry driver cannot follow `libs = ["../stocks/lib"]` and `allow_paths` outside the
# package root, so the gate builds a self-contained copy of this package under reports/generated:
# the same sources, the same compiler settings, the Base sources it imports under stocks-src/, and
# the exported dependency snapshot reached through relative symlinks. Every remapping is rewritten
# by exact prefix so the copy compiles the same bytes; the frozen identity above already proved the
# real package does.
prepare_slither_root() {
    mkdir -p "$slither_root/lib" "$slither_root/stocks-src"
    cp -R src "$slither_root/src"
    cp -R ../stocks/src "$slither_root/stocks-src/src"
    cp slither.config.json "$slither_root/slither.config.json"
    for dependency in ../stocks/lib/*; do
        ln -s "../../../../../stocks/lib/$(basename "$dependency")" "$slither_root/lib/$(basename "$dependency")"
    done
    sed -e 's|^libs = \["\.\./stocks/lib"\]$|libs = ["lib"]|' -e '/^allow_paths = /d' foundry.toml >"$slither_root/foundry.toml"
    grep -q '^libs = \["lib"\]$' "$slither_root/foundry.toml" || fail "the Slither copy did not rewrite libs"
    sed -e 's|=\.\./stocks/lib/|=lib/|' -e 's|=\.\./stocks/src/|=stocks-src/src/|' -e 's|=\.\./stocks/test/|=stocks-src/test/|' \
        remappings.txt >"$slither_root/remappings.txt"
    ! grep -q '\.\./stocks' "$slither_root/remappings.txt" || fail "the Slither copy still remaps into ../stocks"
}

. ../stocks/bin/memestake-gate.sh
