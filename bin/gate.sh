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
release_manifest=contracts/autolaunch-release-manifest.json
bindings=src/bindings/BaseBindings.sol
dispositions=docs/security/slither-dispositions.md
threat_model=docs/security/threat-model.md
gas_doc=docs/audit/gas-and-size.md
sizes=reports/frozen/deployable-sizes.json
slither_config=slither.config.json
checker=bin/check-requirements.py
freezer=bin/freeze-artifacts.py
tooling_test=test/tooling/provider_output_scan_test.py

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
slither_command="$generated/slither-command.txt"
detector_inventory="$generated/slither-detectors.txt"

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
    "$threat_model" "$gas_doc" "$slither_config" "$checker" "$freezer" "$tooling_test" \
    src/bindings/FrozenIdentity.sol \
    SPEC.md .gitmodules foundry.toml reports/frozen/c4-runtime-baseline.json; do
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
section "Frozen release surface"
# ---------------------------------------------------------------------------

# Check mode only. The freezer regenerates every committed ABI, surface, size and manifest
# document from these artifacts and compares byte for byte, then compares the whole src/**
# compiled byte string against the pre-edit C4 baseline captured before this ticket touched
# any file. It writes DEP-016's verified receipt, so deleting this invocation does not
# quietly stop checking the freeze — it fails the ledger reconciliation below.
python3 "$freezer" check \
    --out out \
    --frozen "$frozen" \
    --manifest "$release_manifest" \
    --baseline reports/frozen/c4-runtime-baseline.json \
    --receipt "$receipt"

# ---------------------------------------------------------------------------
section "Compiled test listing, execution, and requirement reconciliation"
# ---------------------------------------------------------------------------

# Foundry's own compiled listing, regenerated on every run. It is the authority for which
# test identities exist: a source scan cannot tell inherited, overloaded, or duplicated
# identities apart, and this can.
forge test --list --json >"$test_list"

test_status=0
# `-vv` is load-bearing rather than cosmetic: Foundry only populates each result's
# `decoded_logs` at that verbosity, and the published-evidence reconciliation below reads
# GAS-007's own emitted measurements out of exactly that field.
forge test --json -vv >"$test_report" 2>"$test_stderr" || test_status=$?
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
section "Published-evidence reconciliation"
# ---------------------------------------------------------------------------

# The audit packet publishes figures a founder is asked to read rather than rerun. Every one of
# them is compared here against the artifact or the executed measurement it came from, so a stale
# published number fails the gate instead of surviving review.
python3 "$checker" evidence \
    --test-report "$test_report" \
    --sizes "$sizes" \
    --gas-doc "$gas_doc"

# ---------------------------------------------------------------------------
section "Static analysis"
# ---------------------------------------------------------------------------

hidden_triage=$(find . -name '*slither.db.json' -not -path './lib/*' -not -path './out/*' || true)
[ -z "$hidden_triage" ] || fail "hidden Slither triage database present: $hidden_triage"

# The detector portfolio the pinned binary actually registers, read from the binary's own
# interpreter. `--list-detectors` hides some detectors, so it under-reports the set that
# runs and cannot be the authority for how many detectors a green run must carry.
slither_interpreter=$(sed -n '1s|^#! *||p' "$(command -v slither)")
[ -n "$slither_interpreter" ] && [ -x "$slither_interpreter" ] ||
    fail "cannot resolve the pinned Slither interpreter from $(command -v slither)"

"$slither_interpreter" -c 'import inspect
from slither.detectors import all_detectors
from slither.detectors.abstract_detector import AbstractDetector

print("\n".join(sorted({
    detector.ARGUMENT
    for _, detector in inspect.getmembers(all_detectors, inspect.isclass)
    if issubclass(detector, AbstractDetector) and detector is not AbstractDetector
})))' >"$detector_inventory" ||
    fail "the pinned Slither binary did not enumerate its registered detectors"

# Record the exact argv, then run exactly that argv. The recording is the invocation, so
# the reconciliation below sees the real command line and not a restatement of it.
set -- slither . --fail-medium --json "$slither_json" --checklist
printf '%s\n' "$@" >"$slither_command"

slither_status=0
"$@" >"$slither_checklist" 2>"$slither_stderr" || slither_status=$?
cat "$slither_stderr"
cat "$slither_checklist"

python3 "$checker" security \
    --slither-json "$slither_json" \
    --slither-checklist "$slither_checklist" \
    --slither-stderr "$slither_stderr" \
    --slither-config "$slither_config" \
    --slither-command "$slither_command" \
    --detector-inventory "$detector_inventory" \
    --dispositions "$dispositions" \
    --test-list "$test_list" \
    --analyzed-sources src \
    --suppression-sources src test script

[ "$slither_status" -eq 0 ] || fail "slither exited $slither_status"

# ---------------------------------------------------------------------------
section "Provider-output scan tooling"
# ---------------------------------------------------------------------------

# The fork gate's two failure orders — a clean run that failed, and dirty output whatever the
# run's status — are shell control flow around a Python scanner, so no Solidity test can reach
# them. They are proved here instead, deterministically and without a provider, against the real
# `sanitize` implementation. A failure is a gate failure.
python3 "$tooling_test"

# ---------------------------------------------------------------------------
section "Provider-secret scan"
# ---------------------------------------------------------------------------

# Nothing this gate produces, and nothing it commits, may carry a resolved provider endpoint.
# The scan covers every evidence location recursively: the regenerated evidence — the effective
# Foundry configuration included, so a resolved RPC alias would show up — every committed frozen
# artifact, the whole audit packet, and the fork harness itself. The effective configuration is
# additionally walked to every nested leaf, because a credential one level down is still a
# credential.
python3 "$checker" secrets \
    --forge-config "$forge_config" \
    --scan "$generated" reports/frozen abi contracts requirements docs/audit docs/security test-fork

# ---------------------------------------------------------------------------
section "Gate report"
# ---------------------------------------------------------------------------

printf 'dependency receipt:\n'
cat "$receipt"
printf '\nGATE PASS\n'
