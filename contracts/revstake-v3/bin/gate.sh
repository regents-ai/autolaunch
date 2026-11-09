#!/bin/sh
# Required gate for the Base Revstake version 3 package (contracts/revstake-v3). This is the sole
# required entrypoint; the body is shared with the other version 3 package in
# ../stocks-v3/bin/memestake-gate.sh.
set -eu

cd "$(dirname "$0")/.."

component=contracts/revstake-v3
bindings=src/bindings/BaseBindings.sol
slither_root=reports/generated/slither-copy
analyzed_sources=src

# Slither's Foundry driver cannot follow `libs = ["../stocks-v3/lib"]` and `allow_paths` outside the
# package root, so the gate builds a self-contained copy of this package under reports/generated:
# the same sources, the same compiler settings, and the exported dependency snapshot reached through
# relative symlinks. Every remapping is rewritten by exact prefix so the copy compiles the same
# bytes; the frozen identity above already proved the real package does.
prepare_slither_root() {
    mkdir -p "$slither_root/lib"
    cp -R src "$slither_root/src"
    cp slither.config.json "$slither_root/slither.config.json"
    for dependency in ../stocks-v3/lib/*; do
        ln -s "../../../../../stocks-v3/lib/$(basename "$dependency")" "$slither_root/lib/$(basename "$dependency")"
    done
    sed -e 's|^libs = \["\.\./stocks-v3/lib"\]$|libs = ["lib"]|' -e '/^allow_paths = /d' foundry.toml >"$slither_root/foundry.toml"
    grep -q '^libs = \["lib"\]$' "$slither_root/foundry.toml" || fail "the Slither copy did not rewrite libs"
    sed -e 's|=\.\./stocks-v3/lib/|=lib/|' remappings.txt >"$slither_root/remappings.txt"
    ! grep -q '\.\./stocks-v3' "$slither_root/remappings.txt" || fail "the Slither copy still remaps into ../stocks-v3"
}

. ../stocks-v3/bin/memestake-gate.sh
