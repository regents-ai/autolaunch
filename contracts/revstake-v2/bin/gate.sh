#!/bin/sh
# Required gate for the Base Revstake v2 package (contracts/revstake-v2). This is the sole required
# entrypoint; the body is shared with the Memestake packages in ../stocks-v2/bin/memestake-gate.sh.
set -eu

cd "$(dirname "$0")/.."

component=contracts/revstake-v2
bindings=src/bindings/BaseBindings.sol
slither_root=reports/generated/slither-copy
analyzed_sources=src

# Slither's Foundry driver cannot follow `libs = ["../stocks-v2/lib"]` and `allow_paths` outside the
# package root, so the gate builds a self-contained copy of this package under reports/generated:
# the same sources, the same compiler settings, and the exported dependency snapshot reached through
# relative symlinks. Every remapping is rewritten by exact prefix so the copy compiles the same
# bytes; the frozen identity above already proved the real package does.
prepare_slither_root() {
    mkdir -p "$slither_root/lib"
    cp -R src "$slither_root/src"
    cp slither.config.json "$slither_root/slither.config.json"
    for dependency in ../stocks-v2/lib/*; do
        ln -s "../../../../../stocks-v2/lib/$(basename "$dependency")" "$slither_root/lib/$(basename "$dependency")"
    done
    sed -e 's|^libs = \["\.\./stocks-v2/lib"\]$|libs = ["lib"]|' -e '/^allow_paths = /d' foundry.toml >"$slither_root/foundry.toml"
    grep -q '^libs = \["lib"\]$' "$slither_root/foundry.toml" || fail "the Slither copy did not rewrite libs"
    sed -e 's|=\.\./stocks-v2/lib/|=lib/|' remappings.txt >"$slither_root/remappings.txt"
    ! grep -q '\.\./stocks-v2' "$slither_root/remappings.txt" || fail "the Slither copy still remaps into ../stocks-v2"
}

. ../stocks-v2/bin/memestake-gate.sh
