#!/bin/sh
# Required gate for autolaunch-contracts.
#
# This is the sole required entrypoint. It is offline: it performs no download, no package
# or registry lookup, and no git fetch. Dependencies and the Solidity compiler are
# materialized before the gate, never by it; anything missing or drifted fails closed here.
#
# The gate runs the external tools and hands every structured comparison to
# bin/check-requirements.py, which is the only place an expectation is compared to its
# authority.
#
# A failure of this gate is a stop-report. Never relax a pinned identity, threshold, or
# configuration value to make it pass.
set -eu

cd "$(dirname "$0")/.."

FOUNDRY_OFFLINE=true
FOUNDRY_PROFILE=default
GIT_TERMINAL_PROMPT=0
export FOUNDRY_OFFLINE FOUNDRY_PROFILE GIT_TERMINAL_PROMPT

# The gates this entrypoint proves. A claim designated for any other gate can be activated,
# but it is never closed here and its selectors may not run here.
GATES=hermetic,invariant

frozen=requirements/frozen-identity.json
ledger=requirements/ledger.toml
manifest=contracts/chain-contracts.yaml
bindings=src/bindings/BaseBindings.sol
dispositions=docs/security/slither-dispositions.md
threat_model=docs/security/threat-model.md
checker=bin/check-requirements.py

generated=reports/generated
rm -rf "$generated"
mkdir -p "$generated"

receipt="$generated/dependency-receipt.txt"
tool_identity="$generated/tool-identity.txt"
forge_config="$generated/forge-config.json"
test_list="$generated/forge-test-list.json"
test_report="$generated/forge-test.json"
test_stderr="$generated/forge-test.stderr.log"
slither_json="$generated/slither.json"
slither_checklist="$generated/slither-checklist.md"
slither_stderr="$generated/slither.stderr.log"

fail() {
    printf 'GATE FAIL: %s\n' "$*" >&2
    exit 1
}

section() {
    printf '\n=== %s ===\n' "$*"
}

# ---------------------------------------------------------------------------
section "Required material and tools"
# ---------------------------------------------------------------------------

for required_file in "$frozen" "$ledger" "$manifest" "$bindings" "$dispositions" \
    "$threat_model" "$checker" src/bindings/FrozenIdentity.sol SPEC.md .gitmodules \
    foundry.toml slither.config.json; do
    [ -f "$required_file" ] || fail "required repository file is missing: $required_file"
done

command -v git >/dev/null 2>&1 || fail "git is not on PATH"
command -v forge >/dev/null 2>&1 || fail "forge is not on PATH"
command -v slither >/dev/null 2>&1 || fail "slither is not on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 is not on PATH"

{
    forge --version | awk '/^forge Version:/ { print "forge_version", $3 }'
    forge --version | awk '/^Commit SHA:/ { print "forge_commit_sha", $3 }'
    slither --version 2>&1 | tail -n 1 | awk '{ print "slither_version", $1 }'
    python3 --version 2>&1 | awk '{ print "python_version", $2 }'
} >"$tool_identity"
cat "$tool_identity"

# The effective configuration, not the committed file: an environment override that changes
# the build or the fuzz portfolio shows up here and fails the reconciliation.
forge config --json >"$forge_config"

# ---------------------------------------------------------------------------
section "Recursive dependency closure"
# ---------------------------------------------------------------------------

# Offline materialization only. Anything not already present fails closed; nothing is
# fetched, and no expected commit is invented here — each one comes from the pinned parent
# that records it.
git submodule update --init --recursive --no-fetch >/dev/null 2>&1 ||
    fail "the pinned recursive closure is not materialized offline; materialize it before the gate"

# ---------------------------------------------------------------------------
section "Frozen identity reconciliation"
# ---------------------------------------------------------------------------

python3 "$checker" preflight \
    --frozen "$frozen" \
    --spec SPEC.md \
    --ledger "$ledger" \
    --manifest "$manifest" \
    --bindings "$bindings" \
    --threat-model "$threat_model" \
    --tool-identity "$tool_identity" \
    --forge-config "$forge_config" \
    --receipt "$receipt"

# ---------------------------------------------------------------------------
section "Formatting"
# ---------------------------------------------------------------------------

forge fmt --check

# ---------------------------------------------------------------------------
section "Build and compiled build identity"
# ---------------------------------------------------------------------------

forge build --sizes

python3 "$checker" artifacts --frozen "$frozen" --out out --receipt "$receipt"

# ---------------------------------------------------------------------------
section "Compiled test listing, execution, and requirement reconciliation"
# ---------------------------------------------------------------------------

# Foundry's own compiled listing, regenerated on every run. It is the authority for which
# test identities exist: a source scan cannot tell inherited, overloaded, or duplicated
# identities apart, and this can.
forge test --list --json >"$test_list"

test_status=0
forge test --json >"$test_report" 2>"$test_stderr" || test_status=$?
cat "$test_stderr"

python3 "$checker" ledger \
    --ledger "$ledger" \
    --spec SPEC.md \
    --gates "$GATES" \
    --test-list "$test_list" \
    --test-report "$test_report" \
    --receipt "$receipt"

[ "$test_status" -eq 0 ] || fail "forge test exited $test_status"

# ---------------------------------------------------------------------------
section "Static analysis"
# ---------------------------------------------------------------------------

hidden_triage=$(find . -name '*slither.db.json' -not -path './lib/*' -not -path './out/*' || true)
[ -z "$hidden_triage" ] || fail "hidden Slither triage database present: $hidden_triage"

slither_status=0
slither . --fail-medium --json "$slither_json" --checklist \
    >"$slither_checklist" 2>"$slither_stderr" || slither_status=$?
cat "$slither_stderr"
cat "$slither_checklist"

python3 "$checker" security \
    --slither-json "$slither_json" \
    --slither-checklist "$slither_checklist" \
    --slither-stderr "$slither_stderr" \
    --dispositions "$dispositions" \
    --test-list "$test_list" \
    --analyzed-sources src \
    --suppression-sources src test

[ "$slither_status" -eq 0 ] || fail "slither exited $slither_status"

# ---------------------------------------------------------------------------
section "Gate report"
# ---------------------------------------------------------------------------

printf 'dependency receipt:\n'
cat "$receipt"
printf '\nGATE PASS\n'
