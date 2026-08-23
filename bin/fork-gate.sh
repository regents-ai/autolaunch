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
#     local fork state and is inventoried in docs/audit/fork-authority-and-state-inventory.md;
#   - nothing a provider produced is displayed before it has been scanned. Every pass writes its
#     stdout and stderr to files, the scan runs on both outcomes, and only then is anything shown.
#     A scan failure is the one and only reason scratch is destroyed, and it is destroyed unread;
#     an ordinary provider or test failure keeps its already-scanned diagnostics for diagnosis.
#
# Evidence is two-phase, and the two phases are different programs run under different profiles:
#
#   discover  Observes Base and writes ONE reviewable candidate under reports/generated/fork/,
#             which is gitignored scratch. It reads no committed observation and it cannot write
#             one: the `fork-discovery` profile's only write permission is that scratch directory.
#             It closes no claim and it is not part of the ledger reconciliation.
#
#   check     Compare-only. It refuses to start unless a human has already reviewed the candidate,
#             installed it as reports/frozen/fork-observations.json, activated the `fork` gate in
#             requirements/ledger.toml, and committed both — and it proves those files are clean
#             both before it touches the provider and after it finishes, so a check run cannot
#             have written the record it is checking against.
#
# A failure of this gate is a stop-report. Never relax a pinned identity or a threshold to pass.
set -eu

cd "$(dirname "$0")/.."

GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT

# The gate this entrypoint proves, and the only one. A hermetic or invariant claim can never
# close here, and a fork claim can never close in bin/gate.sh.
GATES=fork

RPC_ALIAS=base
RPC_ENV=REGENT_BASE_RPC_URL

# The discovery pass is one contract and closes nothing. Every other fork contract carries the
# mapped claim selectors, so the two are separated by name in both directions below.
DISCOVERY_CONTRACT=ForkDiscoveryTest

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

# Nothing a provider produced is displayed before it has been scanned, and the two failure modes
# are kept apart on purpose.
#
#   - Scan failure is the only reason scratch is destroyed. The provider's output has not been
#     shown, so it cannot be shown now; the checker prints a redacted report naming the local
#     paths, this deletes them, and the run stops.
#   - An ordinary provider or test failure is not a secret. Its output has already passed the
#     scan by the time this returns, so it is displayed and the whole scratch directory is kept
#     for diagnosis. The caller decides what to do with the exit status afterwards.
scan_then_display() {
    if ! python3 "$checker" sanitize --scan "$generated"; then
        rm -rf "$generated"
        fail "provider output failed the secret scan; $generated was deleted unread and unlogged"
    fi
    for shown in "$@"; do
        if [ -f "$shown" ]; then
            cat "$shown"
        fi
    done
    return 0
}

# The committed state of the two files a check run must not be able to author. Any difference
# between the reading taken before provider access and the one taken after is a write.
committed_state() {
    git status --porcelain -- "$observations" "$ledger"
}

mode=${1:-check}
case "$mode" in
    discover)
        FOUNDRY_PROFILE=fork-discovery
        ;;
    check)
        FOUNDRY_PROFILE=fork
        ;;
    *) fail "unknown mode '$mode'; use discover or check" ;;
esac
export FOUNDRY_PROFILE

# ---------------------------------------------------------------------------
section "Authority and read-only boundary"
# ---------------------------------------------------------------------------

command -v git >/dev/null 2>&1 || fail "git is not on PATH"
command -v forge >/dev/null 2>&1 || fail "forge is not on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 is not on PATH"

# The offline gate must have already passed on this exact tree. Its receipt is reused rather
# than recomputed, so the two gates cannot disagree about the dependency closure.
[ -f "$offline_receipt" ] ||
    fail "the offline gate's dependency receipt is absent; run bin/gate.sh on this tree first"

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

# ---------------------------------------------------------------------------
section "Phase preconditions"
# ---------------------------------------------------------------------------

status=discovery_pending
[ -f "$observations" ] &&
    status=$(python3 -c "import json;print(json.load(open('$observations'))['status'])")

if [ "$mode" = discover ]; then
    [ "$status" != observed_and_committed ] ||
        fail "the observation record is already committed; re-observing it would overwrite reviewed evidence"
    printf 'discovery: no committed observation is read, and none can be written\n'
else
    [ -f "$observations" ] || fail "the committed fork observation record is absent: $observations"
    [ "$status" = observed_and_committed ] ||
        fail "the observation record is '$status'; run '$0 discover', review the candidate, install it, and commit it"

    # The record and the activation must both already be committed and clean. A check run that
    # could edit either of them would be observing and checking in one breath.
    baseline_state=$(committed_state)
    [ -z "$baseline_state" ] ||
        fail "the observation record or the ledger has uncommitted changes; commit the reviewed evidence first:
$baseline_state"

    python3 - "$ledger" <<'PYTHON'
import sys
import tomllib

ledger = tomllib.load(open(sys.argv[1], "rb"))
gates = set(ledger["ledger"].get("activated_gates", []))
if "fork" not in gates:
    raise SystemExit(
        "the ledger does not activate the 'fork' gate; install the reviewed observation and "
        "activate it before checking"
    )
pending = [
    entry["id"] for entry in ledger["requirement"] if entry["gate"] == "fork" and entry["status"] != "active"
]
if pending:
    raise SystemExit(f"the fork gate is activated but these fork claims are not active: {', '.join(pending)}")
print(f"the ledger activates 'fork' and every fork claim is active")
PYTHON
    printf 'check: the reviewed observation and the activated ledger are committed and clean\n'
fi

rm -rf "$generated"
mkdir -p "$generated"

forge_config="$generated/forge-config.json"
pinned_report="$generated/forge-test-pinned.json"
later_report="$generated/forge-test-later.json"
pinned_log="$generated/forge-test-pinned.log"
later_log="$generated/forge-test-later.log"
discovery_report="$generated/forge-test-discovery.json"
discovery_log="$generated/forge-test-discovery.log"
test_list="$generated/forge-test-list.json"
candidate="$generated/fork-observations-candidate.json"

# ---------------------------------------------------------------------------
section "Effective fork-profile configuration"
# ---------------------------------------------------------------------------

# The effective configuration, not the committed file. The fork profiles must differ from the
# required gate in exactly the ways this gate needs, and in no other.
forge config --json >"$forge_config"

python3 - "$forge_config" "$frozen" "$mode" <<'PYTHON'
import json
import sys

config = json.load(open(sys.argv[1], encoding="utf-8"))
frozen = json.load(open(sys.argv[2], encoding="utf-8"))
mode = sys.argv[3]
problems = []


def expect(label, wanted, found):
    if wanted != found:
        problems.append(f"{label}: expected [{wanted}], found [{found}]")


# Test root: fork tests live outside the offline test root, so they can never be listed by, or
# execute against, a hermetic or invariant claim.
expect("fork profile test root", "test-fork", config.get("test"))
expect("fork profile src root", "src", config.get("src"))

# Build directory: separate from the required gate's, so fork artifacts can never accumulate in
# `out/` and change the artifact count that gate reconciles.
expect("fork profile out directory", "out-fork", config.get("out"))
expect("fork profile cache directory", "cache-fork", config.get("cache_path"))

# Network posture: online for the provider, and FFI still disabled. A fork gate that could shell
# out would be a different authority than the one the founder granted.
expect("fork profile offline", False, config.get("offline"))
expect("fork profile ffi", False, config.get("ffi"))

# Filesystem. The check profile is read-only, full stop: it is structurally incapable of writing
# an observation. The discovery profile may write exactly one gitignored scratch directory and
# nothing else — in particular it can reach neither reports/frozen nor any committed file.
writable = sorted(
    permission.get("path")
    for permission in config.get("fs_permissions") or []
    if permission.get("access") != "read"
)
if mode == "check":
    if writable:
        problems.append(f"the check profile grants write access to {writable}")
else:
    expect("discovery profile writable paths", ["./reports/generated/fork"], writable)

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

print(
    f"fork profile ({mode}): test root test-fork, build out-fork, online, FFI disabled, "
    f"writable {writable or 'nothing'}, frozen build"
)
PYTHON

# ---------------------------------------------------------------------------
section "Formatting and build, before any provider access"
# ---------------------------------------------------------------------------

# Both happen offline. Nothing reaches the provider until the fork sources compile clean.
FOUNDRY_OFFLINE=true forge fmt --check
FOUNDRY_OFFLINE=true forge build

if [ "$mode" = discover ]; then
    # ---------------------------------------------------------------------------
    section "Authorized read-only discovery"
    # ---------------------------------------------------------------------------

    discovery_status=0
    # Keep Foundry's tracing diagnostics off the JSON stdout channel. A cold RPC cache can emit
    # an otherwise harmless WARN before the JSON object, which makes the evidence unparsable.
    RUST_LOG=error forge test --json -vv --match-contract "$DISCOVERY_CONTRACT" --fork-url "$RPC_ALIAS" \
        >"$discovery_report" 2>"$discovery_log" || discovery_status=$?

    # Scan first, on both outcomes. Only then is anything shown, and the candidate the reviewer
    # will read is inside the scanned set.
    scan_then_display "$discovery_log"
    [ "$discovery_status" -eq 0 ] ||
        fail "the discovery pass exited $discovery_status; its scanned diagnostics are retained under $generated"
    [ -f "$candidate" ] || fail "the discovery pass wrote no candidate at $candidate"

    # Discovery may not have touched the committed record, even indirectly.
    after_state=$(committed_state)
    [ -z "$after_state" ] ||
        fail "the discovery pass changed a committed file, which it must never do:
$after_state"

    # ---------------------------------------------------------------------------
    section "Provider-secret scan"
    # ---------------------------------------------------------------------------

    python3 "$checker" secrets \
        --forge-config "$forge_config" \
        --scan "$generated" reports/frozen abi contracts requirements docs/audit docs/security test-fork

    # ---------------------------------------------------------------------------
    section "Operator transition"
    # ---------------------------------------------------------------------------

    cat <<TRANSITION

A reviewable candidate is at:

    $candidate

Nothing has been blessed. To turn it into evidence, deliberately:

  1. read every observed value and check it against an independent source;
  2. fill in transaction_gas_schedule — the chain does not expose those rules, so discovery
     leaves them zero and the reviewer supplies the ones active at the recorded headers;
  3. set "status" to "observed_and_committed";
  4. install it as $observations;
  5. add "fork" to activated_gates in $ledger and flip the eighteen fork claims to active;
  6. commit both files;
  7. run: $0 check

Until step 6 lands, '$0 check' refuses to run, and every fork claim stays pending.

TRANSITION
    printf 'FORK DISCOVERY PASS\n'
    exit 0
fi

# ---------------------------------------------------------------------------
section "Compiled listing of the mapped claim selectors"
# ---------------------------------------------------------------------------

# The discovery contract is excluded by name: it carries no requirement id, closes nothing, and
# must never appear in the reconciliation that decides whether a claim executed.
FOUNDRY_OFFLINE=true forge test --list --json --no-match-contract "$DISCOVERY_CONTRACT" >"$test_list"

# ---------------------------------------------------------------------------
section "Pinned header"
# ---------------------------------------------------------------------------

pinned_status=0
RUST_LOG=error forge test --json -vv --no-match-contract "$DISCOVERY_CONTRACT" --match-test 'ForkPinned' --fork-url "$RPC_ALIAS" \
    >"$pinned_report" 2>"$pinned_log" || pinned_status=$?
scan_then_display "$pinned_log"
[ "$pinned_status" -eq 0 ] ||
    fail "the pinned-header fork run exited $pinned_status; its scanned diagnostics are retained under $generated"

# ---------------------------------------------------------------------------
section "Later header"
# ---------------------------------------------------------------------------

later_status=0
RUST_LOG=error forge test --json -vv --no-match-contract "$DISCOVERY_CONTRACT" --match-test 'ForkLatest' --fork-url "$RPC_ALIAS" \
    >"$later_report" 2>"$later_log" || later_status=$?
scan_then_display "$later_log"
[ "$later_status" -eq 0 ] ||
    fail "the later-header fork run exited $later_status; its scanned diagnostics are retained under $generated"

# ---------------------------------------------------------------------------
section "Ledger reconciliation"
# ---------------------------------------------------------------------------

# Both runs together are this gate's execution evidence. The compiled listing enumerates all
# thirty-six mapped selectors — eighteen claims, one selector per committed header — and the two
# reports are reconciled against it as one merged multiset, so every claim maps to exactly one
# pinned and one later selector and each of them executes exactly once across the whole gate.
python3 "$checker" ledger \
    --ledger "$ledger" \
    --spec SPEC.md \
    --gates "$GATES" \
    --test-list "$test_list" \
    --test-report "$pinned_report" "$later_report" \
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
section "Check-only proof"
# ---------------------------------------------------------------------------

# The record and the activation are still exactly as committed. Nothing this run did wrote an
# observation, and no candidate was produced under a profile that could not have written one.
after_state=$(committed_state)
[ -z "$after_state" ] ||
    fail "the check run changed a committed file, which it must never do:
$after_state"
[ ! -f "$candidate" ] || fail "the check run produced a discovery candidate; check mode observes nothing"
printf 'the reviewed observation and the activated ledger are byte-identical to what was committed\n'

# ---------------------------------------------------------------------------
section "Provider-secret scan"
# ---------------------------------------------------------------------------

# Everything this run produced — both JSON reports, both stderr logs, and the effective fork
# configuration — plus every committed evidence location, recursively. A resolved endpoint
# anywhere fails here.
python3 "$checker" secrets \
    --forge-config "$forge_config" \
    --scan "$generated" reports/frozen abi contracts requirements docs/audit docs/security test-fork

printf '\nFORK GATE PASS\n'
