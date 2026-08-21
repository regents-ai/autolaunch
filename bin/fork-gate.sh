#!/bin/sh
# Separately authorized read-only Base fork gate for autolaunch-contracts.
#
# This entrypoint is NOT the required gate. `bin/gate.sh` is, and it never touches a network.
# This one exists only because a handful of claims are about deployed chain truth, which no
# hermetic double can satisfy. It runs under the founder's separate fork authority and under a
# hard read-only boundary:
#
#   - reads only; no broadcast, no deployment to Base, no signature, no wallet request, no
#     value movement, and no production-data access;
#   - the endpoint is reached only through the `base` alias, whose value stays an unresolved
#     environment reference in every committed file and every artifact this run produces;
#   - every mutation, impersonation, block movement, and staged balance happens in Forge's own
#     local fork state and is inventoried in docs/audit/fork-state-inventory.md.
#
# Evidence is two-phase. `discover` observes and records; the values are reviewed and committed;
# `check` then compares the chain against that committed record. A gate that observed a value and
# compared it to itself would prove nothing, so `check` refuses to run until the record is
# committed.
#
# A failure of this gate is a stop-report. Never relax a pinned identity or a threshold to pass.
set -eu

cd "$(dirname "$0")/.."

FOUNDRY_PROFILE=fork
GIT_TERMINAL_PROMPT=0
export FOUNDRY_PROFILE GIT_TERMINAL_PROMPT

# The gate this entrypoint proves, and the only one. A hermetic or invariant claim can never
# close here, and a fork claim can never close in bin/gate.sh.
GATES=fork

RPC_ALIAS=base
RPC_ENV=REGENT_BASE_RPC_URL

frozen=requirements/frozen-identity.json
ledger=requirements/ledger.toml
observations=reports/frozen/fork-observations.json
checker=bin/check-requirements.py

generated=reports/generated/fork
offline_receipt=reports/generated/dependency-receipt.txt

fail() {
    printf 'FORK GATE FAIL: %s\n' "$*" >&2
    exit 1
}

section() {
    printf '\n=== %s ===\n' "$*"
}

# ---------------------------------------------------------------------------
section "Authority and read-only boundary"
# ---------------------------------------------------------------------------

# The offline gate must have already passed on this exact tree. Its receipt is reused rather
# than recomputed, so the two gates cannot disagree about the dependency closure.
[ -f "$offline_receipt" ] ||
    fail "the offline gate's dependency receipt is absent; run bin/gate.sh on this tree first"
[ -f "$observations" ] || fail "the committed fork observation record is absent: $observations"

# Nothing here may carry signing authority. A key in the environment is a stop, not a warning.
for forbidden in PRIVATE_KEY ETH_PRIVATE_KEY MNEMONIC ETH_KEYSTORE ETH_FROM ETHERSCAN_API_KEY; do
    eval "value=\${$forbidden:-}"
    [ -z "$value" ] || fail "$forbidden is set; this gate is read-only and refuses to run beside signing authority"
done

# The endpoint is consumed, never printed. Only its presence is ever reported.
eval "endpoint=\${$RPC_ENV:-}"
[ -n "$endpoint" ] ||
    fail "no read-only Base provider is injected under $RPC_ENV; fork claims stay pending and C5 cannot close"
unset endpoint
printf 'a read-only Base endpoint is injected under %s and is never printed or persisted\n' "$RPC_ENV"

mode=${1:-check}
case "$mode" in
    discover | check) ;;
    *) fail "unknown mode '$mode'; use discover or check" ;;
esac

status=$(python3 -c "import json,sys;print(json.load(open('$observations'))['status'])")
if [ "$mode" = check ] && [ "$status" != observed_and_committed ]; then
    fail "the observation record is '$status'; run '$0 discover', review it, and commit it before checking"
fi
if [ "$mode" = discover ] && [ "$status" = observed_and_committed ]; then
    fail "the observation record is already committed; re-observing it would overwrite reviewed evidence"
fi

rm -rf "$generated"
mkdir -p "$generated"

forge_config="$generated/forge-config.json"
pinned_report="$generated/forge-test-pinned.json"
later_report="$generated/forge-test-later.json"
pinned_log="$generated/forge-test-pinned.log"
later_log="$generated/forge-test-later.log"
test_list="$generated/forge-test-list.json"

# ---------------------------------------------------------------------------
section "Effective fork-profile configuration"
# ---------------------------------------------------------------------------

command -v forge >/dev/null 2>&1 || fail "forge is not on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 is not on PATH"

# The effective configuration, not the committed file. The fork profile must differ from the
# required gate in exactly two ways — its test root and its network posture — and in no other.
forge config --json >"$forge_config"

python3 - "$forge_config" "$frozen" <<'PYTHON'
import json
import sys

config = json.load(open(sys.argv[1], encoding="utf-8"))
frozen = json.load(open(sys.argv[2], encoding="utf-8"))
problems = []


def expect(label, wanted, found):
    if wanted != found:
        problems.append(f"{label}: expected [{wanted}], found [{found}]")


# Test root: fork tests live outside the offline test root, so they can never be listed by, or
# execute against, a hermetic or invariant claim.
expect("fork profile test root", "test-fork", config.get("test"))
expect("fork profile src root", "src", config.get("src"))

# Network posture: online for the provider, and FFI still disabled. A fork gate that could shell
# out would be a different authority than the one the founder granted.
expect("fork profile offline", False, config.get("offline"))
expect("fork profile ffi", False, config.get("ffi"))

# Filesystem: read-only, and only the committed authorities the fork tests read.
for permission in config.get("fs_permissions") or []:
    if permission.get("access") != "read":
        problems.append(f"fork profile grants {permission.get('access')} access to {permission.get('path')}")

# Compiler: the frozen build, unchanged. Fork evidence must be about the same bytes the required
# gate proved.
build = frozen["build"]
expect("fork profile solc", build["solc_version"], config.get("solc"))
expect("fork profile evm version", build["evm_version"], config.get("evm_version"))
expect("fork profile optimizer runs", build["optimizer_runs"], config.get("optimizer_runs"))
expect("fork profile via-IR", build["via_ir"], config.get("via_ir"))
expect("fork profile bytecode hash", build["bytecode_hash"], config.get("bytecode_hash"))
expect("fork profile appendCBOR", build["append_cbor"], config.get("cbor_metadata"))

# The endpoint alias must still be an unresolved environment reference here too.
endpoints = config.get("rpc_endpoints") or {}
if list(endpoints) != ["base"]:
    problems.append(f"the fork profile declares RPC aliases {sorted(endpoints)}, expected only ['base']")
for alias, value in endpoints.items():
    if not str(value).startswith("${"):
        problems.append(f"RPC alias '{alias}' is resolved in the effective fork configuration")

if problems:
    print("FORK PROFILE RECONCILIATION FAILED", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    raise SystemExit(1)

print("fork profile: test root test-fork, online, FFI disabled, read-only filesystem, frozen build")
PYTHON

# ---------------------------------------------------------------------------
section "Formatting and build, before any provider access"
# ---------------------------------------------------------------------------

# Both happen offline. Nothing reaches the provider until the fork sources compile clean.
FOUNDRY_OFFLINE=true forge fmt --check
FOUNDRY_OFFLINE=true forge build

FOUNDRY_OFFLINE=true forge test --list --json >"$test_list"

# ---------------------------------------------------------------------------
section "Pinned header"
# ---------------------------------------------------------------------------

pinned_status=0
forge test --json --match-test 'ForkPinned' --fork-url "$RPC_ALIAS" \
    >"$pinned_report" 2>"$pinned_log" || pinned_status=$?
cat "$pinned_log"
[ "$pinned_status" -eq 0 ] || fail "the pinned-header fork run exited $pinned_status"

# ---------------------------------------------------------------------------
section "Later header"
# ---------------------------------------------------------------------------

later_status=0
forge test --json --match-test 'ForkLatest' --fork-url "$RPC_ALIAS" \
    >"$later_report" 2>"$later_log" || later_status=$?
cat "$later_log"
[ "$later_status" -eq 0 ] || fail "the later-header fork run exited $later_status"

# ---------------------------------------------------------------------------
section "Ledger reconciliation"
# ---------------------------------------------------------------------------

# Both runs together are this gate's execution evidence: every fork claim maps to exactly two
# selectors, one per header, and each executes exactly once.
python3 "$checker" ledger \
    --ledger "$ledger" \
    --spec SPEC.md \
    --gates "$GATES" \
    --test-list "$test_list" \
    --test-report "$pinned_report" \
    --receipt "$offline_receipt"

# ---------------------------------------------------------------------------
section "Normalized verdict agreement (DEP-050)"
# ---------------------------------------------------------------------------

python3 - "$pinned_report" "$later_report" <<'PYTHON'
import json
import sys


def verdicts(path, header):
    """Every `verdict <claim> <header>` line one run emitted, as claim -> decision."""
    found = {}
    report = json.load(open(path, encoding="utf-8"))
    for result in report.values():
        for outcome in result.get("test_results", {}).values():
            for entry in outcome.get("decoded_logs", []) or []:
                if not entry.startswith("verdict "):
                    continue
                label, _, decision = entry.partition(": ")
                parts = label.split(" ")
                if len(parts) != 3 or parts[2] != header:
                    continue
                claim = parts[1]
                if claim in found and found[claim] != decision:
                    raise SystemExit(f"{path}: claim {claim} emitted two different verdicts at {header}")
                found[claim] = decision
    return found


pinned = verdicts(sys.argv[1], "pinned")
later = verdicts(sys.argv[2], "later")

problems = []
if not pinned:
    problems.append("the pinned run emitted no normalized verdict")
for claim in sorted(set(pinned) - set(later)):
    problems.append(f"claim {claim} reached a verdict at the pinned header but not at the later head")
for claim in sorted(set(later) - set(pinned)):
    problems.append(f"claim {claim} reached a verdict at the later head but not at the pinned header")
for claim in sorted(set(pinned) & set(later)):
    if pinned[claim] != later[claim]:
        problems.append(f"claim {claim}: pinned says [{pinned[claim]}], later head says [{later[claim]}]")

if problems:
    print("VERDICT RECONCILIATION FAILED", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    raise SystemExit(1)

print(f"normalized verdicts reconciled across both headers: {len(pinned)}")
PYTHON

# ---------------------------------------------------------------------------
section "Provider-secret scan"
# ---------------------------------------------------------------------------

# Everything this run produced — both JSON reports, both stderr logs, and the effective fork
# configuration — plus every committed frozen artifact. A resolved endpoint anywhere fails here.
python3 "$checker" secrets \
    --forge-config "$forge_config" \
    --scan "$generated" reports/frozen abi contracts requirements

printf '\nFORK GATE PASS\n'
