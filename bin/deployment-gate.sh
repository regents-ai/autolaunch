#!/bin/sh
# Deployment-ceremony gate for autolaunch-contracts.
#
# This entrypoint is NOT the required gate. `bin/gate.sh` is. This one proves the `deployment`
# gate alone: the five direct, zero-value creation transactions a founder-selected disposable
# deployer would send to put the Autolaunch graph on Base, and nothing else.
#
# It has four modes.
#
#   --offline    The writer's mode, and the one that carries this candidate's evidence. It runs
#                with `FOUNDRY_OFFLINE=true` and with the Base endpoint variable cleared from the
#                child environment, so no network can be reached even by accident. The whole
#                ceremony is decidable this way: the five creations call no external contract, and
#                the one frozen address the graph binds is compared rather than called.
#
#   --prepare <deployer>
#                The only mode that derives a ceremony's free parameters. Under the founder's
#                separate read-only Base authority it reads that public account's live nonce, mines
#                the hook salt once, snapshots the live control surface, and writes one reviewable
#                candidate into gitignored scratch. It closes no claim, renders no packet, and
#                prints no pass marker: installing what it wrote is a deliberate human step.
#
#   --rehearse   The chief's mode, run under the same read-only authority and only after this
#                candidate has been independently reviewed. It is compare-only, it authors nothing,
#                and it refuses to run while the selection is still pending, because a rehearsal
#                that cannot compare the selected deployer is not the ceremony.
#
#   --selftest-dead-endpoint
#                The regression for the chain-id boundary below. It reaches no network.
#
# Before any provider mode runs a Forge test or the deployment script, one read-only `cast chain-id`
# probe through the configured alias must answer exactly 8453, so a dead, unreachable, malformed or
# wrong-chain endpoint stops the gate instead of surfacing as a harness failure. This is the same
# boundary `bin/fork-gate.sh` enforces, and it has the same closed-loopback regression.
#
# The boundary is hard in every mode. Nothing here signs, broadcasts, deploys, funds, requests a
# wallet, writes to a provider, or moves value. The deployment script is invoked in exactly one
# place, in rehearsal only, with no `--broadcast` flag and no signer of any kind; the authorized
# broadcast command shape is recorded in the packet as text and is never run from this repository.
# A signing variable in the environment is a stop, not a warning. A dotenv file in the worktree is a
# stop too, because Foundry would load it into the process environment and the ceremony reads three
# of its parameters from there — so this gate refuses to run beside one rather than reading one.
#
# Every mode ends at mainnet NO-GO. The packet this renders is a proposal: only a later founder
# instruction naming its exact digest can authorize a signature or a broadcast, and only confirmed
# Base receipts may populate the separate deployed manifest.
#
# A failure of this gate is a stop-report. Never relax a pinned identity, limit, or configuration
# value to make it pass.
set -eu

cd "$(dirname "$0")/.."

FOUNDRY_PROFILE=deployment
GIT_TERMINAL_PROMPT=0
export FOUNDRY_PROFILE GIT_TERMINAL_PROMPT

# The gate this entrypoint proves, and the only one. A hermetic, invariant, or fork claim can
# never close here, and a deployment claim can never close in the other two entrypoints.
GATES=deployment

RPC_ALIAS=base
RPC_ENV=REGENT_BASE_RPC_URL

# The one chain this gate is about, and the refusal every endpoint failure shares.
CHAIN_ID=8453
PROBE_REFUSAL="the configured $RPC_ALIAS endpoint did not answer a read-only chain-id probe with exactly $CHAIN_ID"

# A closed loopback port, and the only endpoint the dead-endpoint regression uses. Nothing listens
# on the discard port, so the refusal it produces is deterministic and reaches no network.
DEAD_ENDPOINT=http://127.0.0.1:9

# Neither of these two contracts carries a requirement id and neither closes anything, so both are
# excluded by name from the compiled listing and from the ledger reconciliation in every mode,
# exactly as `bin/fork-gate.sh` excludes its discovery pass.
PREFLIGHT_CONTRACT=DeploymentPreflightTest
SELECTION_CONTRACT=DeploymentSelectionTest
UNMAPPED_CONTRACTS="$PREFLIGHT_CONTRACT|$SELECTION_CONTRACT"

frozen=requirements/frozen-identity.json
ledger=requirements/ledger.toml
sizes=reports/frozen/deployable-sizes.json
observations=reports/frozen/fork-observations.json
checker=bin/check-requirements.py
script=script/DeployAutolaunchV1.s.sol

packet=deployments/base-mainnet/mainnet-no-go-packet.json
manifest=deployments/base-mainnet/deployed-manifest.json
selection=deployments/base-mainnet/ceremony-selection.json

generated=reports/generated/deployment

fail() {
    printf 'DEPLOYMENT GATE FAIL: %s\n' "$*" >&2
    exit 1
}

section() {
    printf '\n=== %s ===\n' "$*"
}

# Nothing a provider produced is displayed before it has been scanned. A scan failure is the only
# reason scratch is destroyed, and it is destroyed unread; an ordinary run failure keeps its
# already-scanned diagnostics so the stop-report can name what actually broke.
scan_then_display() {
    if ! python3 "$checker" sanitize --scan "$generated"; then
        rm -rf "$generated"
        fail "captured output failed the secret scan; $generated was deleted unread and unlogged"
    fi
    for shown in "$@"; do
        [ -f "$shown" ] && cat "$shown"
    done
    return 0
}

# One read-only `eth_chainId` read through the configured `$RPC_ALIAS` alias, and the whole endpoint
# boundary. It is `bin/fork-gate.sh`'s probe, applied to this gate's provider modes: without it a
# dead, unreachable, malformed or wrong-chain endpoint surfaces only as a Forge failure deep inside
# the harness, where a run that never opened a fork is hard to tell from one that observed Base.
#
# The endpoint is never exposed. `cast` names the URL in its own diagnostics, so the capture is
# scanned before anything is displayed and dropped unread if the scan finds it, and neither capture
# survives the probe. The answer is printed only when it is plain digits, and every failure — dead,
# unreachable, malformed, or another chain — is the same refusal.
probe_base_chain_id() {
    probe_status=0
    cast chain-id --rpc-url "$RPC_ALIAS" >"$probe_out" 2>"$probe_err" || probe_status=$?

    if python3 "$checker" sanitize --scan "$probe_err"; then
        if [ -s "$probe_err" ]; then cat "$probe_err" >&2; fi
    else
        printf 'the probe diagnostics named the endpoint and were dropped unread\n' >&2
    fi

    observed=$(tr -d '[:space:]' <"$probe_out")
    rm -f "$probe_out" "$probe_err"

    [ "$probe_status" -eq 0 ] || fail "$PROBE_REFUSAL (cast exited $probe_status)"
    case "$observed" in
        '' | *[!0-9]*) fail "$PROBE_REFUSAL (its answer was not a plain chain id and is not printed)" ;;
    esac
    [ "$observed" = "$CHAIN_ID" ] || fail "$PROBE_REFUSAL (it answered chain $observed)"
    printf 'the configured %s alias answers a read-only chain-id probe with exactly %s\n' "$RPC_ALIAS" "$CHAIN_ID"
}

# The external-state preflight, and the only thing in this repository that reads live Base state.
# It carries no requirement id, so its report never reaches the ledger reconciliation; a report with
# no executed result means no fork was opened, which is a stop rather than an empty observation.
run_preflight() {
    preflight_status=0
    RUST_LOG=error forge test --json -vv --match-contract "$PREFLIGHT_CONTRACT" --fork-url "$RPC_ALIAS" \
        >"$preflight_report" 2>"$preflight_log" || preflight_status=$?
    scan_then_display "$preflight_log"
    [ "$preflight_status" -eq 0 ] ||
        fail "the external-state preflight exited $preflight_status; a ceremony against this chain state is a stop"

    python3 - "$preflight_report" "$PREFLIGHT_CONTRACT" <<'PYTHON'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
executed = sum(len(result.get("test_results", {})) for result in report.values())
if executed == 0:
    raise SystemExit(f"the preflight report contains no executed {sys.argv[2]} result; no fork was observed")
print(f"external-state preflight: {executed} live Base observation(s), all passing")
PYTHON
}

# One selection selector, with the three public ceremony parameters in its environment under the
# exact names `script/DeployAutolaunchV1.s.sol` consumes. None of them is a credential, and the two
# unused ones stay empty in preparation because preparation is what derives them.
run_selection() {
    selection_run_status=0
    REGENT_DEPLOYMENT_DEPLOYER="$pinned_deployer" \
        REGENT_DEPLOYMENT_STARTING_NONCE="$pinned_nonce" \
        REGENT_DEPLOYMENT_HOOK_SALT="$pinned_salt" \
        RUST_LOG=error forge test --json -vv --match-contract "$SELECTION_CONTRACT" --match-test "$1" \
        --fork-url "$RPC_ALIAS" >"$selection_report" 2>"$selection_log" || selection_run_status=$?
    scan_then_display "$selection_log"
    [ "$selection_run_status" -eq 0 ] ||
        fail "the ceremony-selection run exited $selection_run_status; its scanned diagnostics are retained under $generated"
}

# Everything a provider mode measured, held to committed authority. The deployment profile has no
# filesystem permission at all, so the preflight and the selection selectors emit their measurements
# as decoded logs and this is where they are compared — or, in preparation, written out as one
# reviewable candidate. `reports/frozen/fork-observations.json` is the sole frozen runtime and proxy
# identity authority in both modes; the committed ceremony selection is the authority for the
# mutable control surface and for the selected deployer, and a rehearsal only ever compares to it.
compare_external_state() {
    python3 - "$1" "$preflight_report" "$selection_report" "$observations" "$selection" "$selection_candidate" <<'PYTHON'
import json
import re
import sys

mode, preflight_path, selection_path, observations_path, committed_path, candidate_path = sys.argv[1:7]

BINDING_FACTS = [
    "address",
    "runtime_bytes",
    "runtime_code_hash",
    "proxy_family",
    "implementation",
    "implementation_code_hash",
    "implementation_runtime_bytes",
]
BYTE_COUNTS = {"runtime_bytes", "implementation_runtime_bytes"}
PREDICTED = [
    "uerc20_factory",
    "escrow_implementation",
    "splitter_implementation",
    "receiver_implementation",
    "factory",
    "strategy",
    "hook",
]
ADDRESS_LIST_RE = re.compile(r"0x[0-9a-fA-F]{40}")

REQUIRED_PREFLIGHT = [
    "block_number",
    "live_staking_owner",
    "live_staking_paused",
    "live_staking_usdc",
    "safe_owners",
    "safe_threshold",
    "safe_guard",
    "safe_modules",
    "safe_module_next_page",
    "safe_fallback_handler",
    "safe_singleton",
    "safe_version",
]
REQUIRED_SELECTION = ["deployer", "starting_nonce", "hook_salt"] + [f"predicted_{name}" for name in PREDICTED]

problems = []


def decoded_logs(path):
    lines = []
    for result in json.load(open(path, encoding="utf-8")).values():
        for outcome in result.get("test_results", {}).values():
            lines.extend(outcome.get("decoded_logs") or [])
    return lines


def emitted(lines, prefix, ignore=()):
    """Every `<prefix> <key>: <value>` line, by key, except the group markers named in `ignore`. A
    repeated key is a stop: it would mean two observations disagreed about one fact and the last one
    silently won."""
    found = {}
    for line in lines:
        key, _, value = line.partition(": ")
        key = key.strip()
        if not key.startswith(f"{prefix} "):
            continue
        key = key[len(prefix) + 1 :]
        if key in ignore:
            continue
        if key in found:
            problems.append(f"the run emitted '{prefix} {key}' more than once")
        found[key] = value
    return found


def normalize(value):
    return value.lower() if isinstance(value, str) and value.startswith("0x") else value


def compare(label, wanted, found):
    if normalize(wanted) != normalize(found):
        problems.append(f"{label}: committed [{wanted}], observed [{found}]")


# --- what the preflight and the selection selector measured ---------------------
preflight_lines = decoded_logs(preflight_path)
bindings, current = {}, None
for line in preflight_lines:
    key, _, value = line.partition(": ")
    key = key.strip()
    if key == "preflight binding_id":
        current = value
        bindings[current] = {}
    elif current is not None and key.startswith("binding_"):
        bindings[current][key[len("binding_") :]] = value

preflight = emitted(preflight_lines, "preflight", ignore={"binding_id"})
selection = emitted(decoded_logs(selection_path), "selection")

# A run that emitted nothing observed nothing, and a missing fact must be named rather than crashed
# on further down. Every key below is emitted unconditionally by a passing selector, so an absence
# here means the harness did not do what this comparison assumes it did.
missing = [key for key in REQUIRED_PREFLIGHT if key not in preflight]
missing += [f"selection {key}" for key in REQUIRED_SELECTION if key not in selection]
if missing:
    raise SystemExit(f"the run emitted no {', '.join(missing)}; no external state was observed")

# --- runtime and proxy identity, against the frozen observation record ----------
observation = json.load(open(observations_path, encoding="utf-8"))
frozen = dict(observation["bindings"])
frozen["permit2"] = observation["permit2"]
if sorted(bindings) != sorted(frozen):
    problems.append(f"the preflight observed bindings {sorted(bindings)}, the frozen record names {sorted(frozen)}")

for name in sorted(set(bindings) & set(frozen)):
    for fact in BINDING_FACTS:
        wanted, found = frozen[name][fact], bindings[name].get(fact)
        if fact in BYTE_COUNTS:
            found = int(found) if found is not None and found.isdigit() else found
        compare(f"binding {name}.{fact}", wanted, found)

# --- the mutable control surface, and the selected deployer --------------------
committed = json.load(open(committed_path, encoding="utf-8"))

observed_control = {
    "observed_at_block": int(preflight["block_number"]),
    "live_staking": {
        "owner": preflight["live_staking_owner"],
        "paused": preflight["live_staking_paused"] == "true",
        "usdc": preflight["live_staking_usdc"],
    },
    "governance_and_regent_safe": {
        "owners": ADDRESS_LIST_RE.findall(preflight["safe_owners"]),
        "threshold": int(preflight["safe_threshold"]),
        "guard": preflight["safe_guard"],
        "modules": ADDRESS_LIST_RE.findall(preflight["safe_modules"]),
        "module_next_page": preflight["safe_module_next_page"],
        "fallback_handler": preflight["safe_fallback_handler"],
        "singleton": preflight["safe_singleton"],
        "version": preflight["safe_version"],
    },
}
observed_selection = {
    "deployer": selection["deployer"],
    "starting_nonce": int(selection["starting_nonce"]),
    "hook_salt": selection["hook_salt"],
    "predicted_addresses": {name: selection[f"predicted_{name}"] for name in PREDICTED},
}

if mode == "--rehearse":
    # The observation block moves with the head and is provenance rather than a comparison; every
    # other fact below is exact, and a difference is drift to account for rather than to absorb.
    frozen_control = committed["control_snapshot"]
    for group in ("live_staking", "governance_and_regent_safe"):
        for fact, wanted in frozen_control[group].items():
            found = observed_control[group][fact]
            if isinstance(wanted, list):
                compare(f"{group}.{fact}", [normalize(v) for v in wanted], [normalize(v) for v in found])
            else:
                compare(f"{group}.{fact}", wanted, found)

    frozen_selection = committed["selection"]
    for fact in ("deployer", "starting_nonce", "hook_salt"):
        compare(f"selection.{fact}", frozen_selection[fact], observed_selection[fact])
    for name in PREDICTED:
        compare(
            f"selection.predicted_addresses.{name}",
            frozen_selection["predicted_addresses"][name],
            observed_selection["predicted_addresses"][name],
        )

if problems:
    print("EXTERNAL STATE RECONCILIATION FAILED", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    raise SystemExit(1)

print(f"binding identity: all {len(bindings)} frozen bindings match their runtime and proxy identity exactly")

if mode == "--rehearse":
    print("control surface: the live staking and Safe facts match the committed snapshot exactly")
    print("selection: the seven predicted addresses re-derive from the committed selection exactly")
else:
    candidate = {
        "artifact": "regents-autolaunch-base-mainnet-ceremony-selection",
        "version": 1,
        "status": "selection_installed",
        "note": (
            "The founder's public deployer selection and the snapshot of the mutable external "
            "control surface a deployment depends on. Every value here is public: no key, mnemonic, "
            "keystore path, endpoint or credential belongs in this file. bin/deployment-gate.sh "
            "--rehearse only ever compares against it and never writes it."
        ),
        "selection": dict(
            observed_selection,
            note=(
                "The founder-selected disposable deployer, the starting nonce read from Base at the "
                "snapshot's observation block, the hook salt mined once against the predicted factory "
                "and strategy, and the seven addresses those three determine. A completed ceremony moves "
                "the deployer five nonces past this number, which is what makes this selection "
                "single-use: a partial ceremony is terminal and is never resumed."
            ),
        ),
        "control_snapshot": observed_control,
        "control_snapshot_note": (
            "Observed live and frozen here so every later rehearsal compares against it: the live "
            "staking owner, pause state and USDC binding, and the Governance/Regent Safe's exact "
            "owners, threshold, guard, enabled modules, module page terminator, fallback handler, "
            "singleton and version. observed_at_block is provenance and is not compared, because the "
            "head moves. reports/frozen/fork-observations.json stays the sole frozen runtime and "
            "proxy identity authority and is never restated here."
        ),
    }
    open(candidate_path, "w", encoding="utf-8").write(json.dumps(candidate, indent=2, sort_keys=True) + "\n")
    print(f"preparation candidate written to {candidate_path}; nothing reads it until a human installs it")
PYTHON
}

mode=${1:-}
pinned_deployer=
pinned_nonce=
pinned_salt=
case "$mode" in
    --offline)
        FOUNDRY_OFFLINE=true
        export FOUNDRY_OFFLINE
        # Cleared rather than merely unused: an offline run must be incapable of reaching Base,
        # not merely uninterested in it.
        unset "$RPC_ENV" 2>/dev/null || :
        expect_offline=true
        ;;
    --prepare)
        # The founder's public deployer address, and the only value this repository cannot derive,
        # observe or invent. It is an argument rather than an environment variable so that it is
        # visible in the command that produced a candidate.
        pinned_deployer=${2:-}
        [ -n "$pinned_deployer" ] ||
            fail "--prepare requires the founder-selected deployer address: $0 --prepare 0x...
That address is founder input. Nothing here may choose, derive, or invent one."
        case "$pinned_deployer" in
            0x[0-9a-fA-F]*)
                [ "${#pinned_deployer}" -eq 42 ] ||
                    fail "the deployer argument is not a 20-byte address: $pinned_deployer" ;;
            *) fail "the deployer argument is not a 0x-prefixed address: $pinned_deployer" ;;
        esac
        expect_offline=false
        ;;
    --rehearse)
        expect_offline=false
        ;;
    --selftest-dead-endpoint)
        # The regression for the boundary above, and the only mode that reaches no network at all.
        # It re-runs this same script in `--rehearse` with the `$RPC_ALIAS` alias pointed at a closed
        # loopback port, so the production probe is the code under test and the real endpoint is
        # neither read nor passed on. It cannot stand in for a rehearsal: it reaches no Forge test,
        # closes no claim, renders no packet, and this gate's pass marker never appears in it.
        section "Dead-endpoint regression"
        selftest_status=0
        selftest_output=$(REGENT_BASE_RPC_URL="$DEAD_ENDPOINT" "$0" --rehearse 2>&1) || selftest_status=$?
        printf '%s\n' "$selftest_output"

        [ "$selftest_status" -ne 0 ] || fail "a dead endpoint exited 0; the boundary does not hold"
        case "$selftest_output" in
            *'DEPLOYMENT GATE PASS'*) fail "a dead endpoint printed this gate's pass marker" ;;
        esac
        case "$selftest_output" in
            *"$PROBE_REFUSAL"*) : ;;
            *) fail "the dead-endpoint run stopped before the chain-id probe, so it proves nothing" ;;
        esac

        # The marker itself is never written here, so this summary cannot be mistaken for a pass
        # by anything that greps the output.
        printf '\nthe dead-endpoint run exited %s at the %s chain-id probe and printed no pass marker\n' \
            "$selftest_status" "$RPC_ALIAS"
        printf 'DEPLOYMENT DEAD-ENDPOINT REGRESSION PASS\n'
        exit 0
        ;;
    *) fail "a mode is required; use --offline, --prepare <deployer>, --rehearse, or --selftest-dead-endpoint" ;;
esac

# ---------------------------------------------------------------------------
section "Authority and signing boundary"
# ---------------------------------------------------------------------------

command -v git >/dev/null 2>&1 || fail "git is not on PATH"
command -v forge >/dev/null 2>&1 || fail "forge is not on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 is not on PATH"

for required_file in "$frozen" "$ledger" "$sizes" "$observations" "$checker" "$script" "$packet" \
    "$manifest" "$selection" test-deployment/DeploymentCeremony.t.sol \
    test-deployment/DeploymentPreflight.t.sol test-deployment/DeploymentSelection.t.sol; do
    [ -f "$required_file" ] || fail "required deployment material is missing: $required_file"
done

# No signing authority may be anywhere near this run, in any mode. This is a superset of the
# fork gate's refusal list: it also covers the keystore, account and interactive-signer variables
# `forge script` would otherwise pick up.
for forbidden in PRIVATE_KEY ETH_PRIVATE_KEY DEPLOYER_PRIVATE_KEY MNEMONIC MNEMONIC_INDEX \
    ETH_KEYSTORE ETH_KEYSTORE_ACCOUNT ETH_PASSWORD ETH_FROM FOUNDRY_SENDER ETHERSCAN_API_KEY \
    LEDGER TREZOR AWS_KMS_KEY_ID GCP_KEY_NAME; do
    eval "value=\${$forbidden:-}"
    [ -z "$value" ] ||
        fail "$forbidden is set; this gate never signs and refuses to run beside signing authority"
done
unset value
printf 'no signing, keystore, sender, or hardware-wallet variable is present\n'

# Foundry loads a dotenv file from the project root into the process environment, and this
# ceremony reads three of its parameters from that environment. A dotenv file is therefore refused
# rather than read: its presence is detected, its contents never are.
for dotenv in .env .env.local .envrc; do
    [ -e "$dotenv" ] &&
        fail "$dotenv exists in the worktree; this gate never reads one and refuses to run beside one"
done
printf 'no .env, .env.local or .envrc exists in the worktree; none is read\n'

if [ "$expect_offline" = true ]; then
    printf 'no provider is reachable: FOUNDRY_OFFLINE is true and %s is cleared from this run\n' "$RPC_ENV"
else
    command -v cast >/dev/null 2>&1 || fail "cast is not on PATH; the chain-id probe cannot run"

    # The endpoint is consumed, never printed. Only its presence and its shape are ever reported,
    # and the refusal happens here, before any harness can start and before anything is dialled.
    eval "endpoint=\${$RPC_ENV:-}"
    [ -n "$endpoint" ] ||
        fail "no read-only Base provider is injected under $RPC_ENV; a $mode run cannot claim a fork"
    case "$endpoint" in
        http://?* | https://?* | ws://?* | wss://?*) : ;;
        *) fail "the value injected under $RPC_ENV is not an http(s) or ws(s) endpoint; its value is never printed" ;;
    esac
    unset endpoint
    printf 'a read-only Base endpoint is injected under %s and is never printed or persisted\n' "$RPC_ENV"
fi

# ---------------------------------------------------------------------------
section "Candidate identity"
# ---------------------------------------------------------------------------

# A run is packet evidence only if it can name the exact object it ran against. A dirty tree means
# the thing that was tested is not the thing that was committed, so it is a stop rather than a
# caveat. The gate's own scratch lives under the gitignored `reports/generated/` prefix and
# therefore cannot make this dirty.
dirty=$(git status --porcelain)
[ -z "$dirty" ] || fail "the working tree is not clean, so this run cannot be packet evidence:
$dirty"

candidate_commit=$(git rev-parse HEAD)
candidate_tree=$(git rev-parse 'HEAD^{tree}')
candidate_src_tree=$(git rev-parse 'HEAD:src')
printf 'candidate commit: %s\n' "$candidate_commit"
printf 'candidate tree:   %s\n' "$candidate_tree"
printf 'candidate src:    %s\n' "$candidate_src_tree"

rm -rf "$generated"
mkdir -p "$generated"

forge_config="$generated/forge-config.json"
probe_out="$generated/chain-id-probe.out"
probe_err="$generated/chain-id-probe.err"
test_list="$generated/forge-test-list.json"
ceremony_report="$generated/forge-test-ceremony.json"
ceremony_log="$generated/forge-test-ceremony.log"
preflight_report="$generated/forge-test-preflight.json"
preflight_log="$generated/forge-test-preflight.log"
selection_report="$generated/forge-test-selection.json"
selection_log="$generated/forge-test-selection.log"
selection_candidate="$generated/ceremony-selection-candidate.json"
dry_run_log="$generated/forge-script-dry-run.log"
receipt="$generated/receipt.txt"
rendered="$generated/mainnet-no-go-packet.json"

printf 'candidate commit %s tree %s src %s\n' "$candidate_commit" "$candidate_tree" "$candidate_src_tree" >"$receipt"

# ---------------------------------------------------------------------------
section "Effective deployment-profile configuration"
# ---------------------------------------------------------------------------

# The effective configuration, not the committed file, and proved here — before any build, any
# provider access, and before the hook address is derived from `type(RegentFeeHook).creationCode`.
# A hook address is a function of the compiler settings, so a graph derived under a drifted build
# would be a confident prediction of the wrong address.
forge config --json >"$forge_config"

python3 - "$forge_config" "$frozen" "$expect_offline" <<'PYTHON'
import json
import sys

config = json.load(open(sys.argv[1], encoding="utf-8"))
frozen = json.load(open(sys.argv[2], encoding="utf-8"))
expect_offline = sys.argv[3] == "true"
problems = []


def expect(label, wanted, found):
    if wanted != found:
        problems.append(f"{label}: expected [{wanted}], found [{found}]")


# Test root: ceremony selectors live outside both the offline test root and the fork test root, so
# no gate can execute or close another gate's claims.
expect("deployment profile test root", "test-deployment", config.get("test"))
expect("deployment profile src root", "src", config.get("src"))

# Build directory: isolated from the required gate's `out/` and from the fork gate's `out-fork/`,
# so ceremony artifacts can never change the artifact set either of them reconciles.
for key, found in (("out", config.get("out")), ("cache_path", config.get("cache_path"))):
    if found in ("out", "out-fork", "cache", "cache-fork"):
        problems.append(f"deployment profile {key} [{found}] is shared with another gate")
    if not str(found).startswith("reports/generated/"):
        problems.append(f"deployment profile {key} [{found}] is not gitignored build scratch")

# Network posture: exactly the mode this run was asked for, and FFI disabled in both.
expect("deployment profile offline", expect_offline, config.get("offline"))
expect("deployment profile ffi", False, config.get("ffi"))

# Filesystem: none at all. This profile's Solidity can neither read a committed authority nor
# write an observation, which is what keeps packet rendering a reviewed shell step.
permissions = config.get("fs_permissions") or []
if permissions:
    problems.append(f"the deployment profile grants filesystem permissions: {permissions}")

# Compiler: the frozen C10 build, field for field. The hook's CREATE2 address is derived from the
# initcode this build produces, so this must be proved before any derivation happens.
build = frozen["build"]
expect("deployment profile solc", build["solc_version"], config.get("solc"))
expect("deployment profile evm version", build["evm_version"], config.get("evm_version"))
expect("deployment profile optimizer", True, config.get("optimizer"))
expect("deployment profile optimizer runs", build["optimizer_runs"], config.get("optimizer_runs"))
expect("deployment profile via-IR", build["via_ir"], config.get("via_ir"))
expect("deployment profile bytecode hash", build["bytecode_hash"], config.get("bytecode_hash"))
expect("deployment profile appendCBOR", build["append_cbor"], config.get("cbor_metadata"))

# The frozen fuzz portfolio, so the ceremony's own fuzzed derivation runs the reviewed seed,
# count and rejection budget rather than whatever a default happens to be.
for key, want in frozen["fuzz"].items():
    found = config.get("fuzz", {}).get(key)
    if key == "seed":
        want, found = int(str(want), 16), int(str(found), 16) if found is not None else None
    expect(f"deployment profile fuzz.{key}", want, found)

# The endpoint alias must still be an unresolved environment reference here too.
endpoints = config.get("rpc_endpoints") or {}
if list(endpoints) != ["base"]:
    problems.append(f"the deployment profile declares RPC aliases {sorted(endpoints)}, expected only ['base']")
for alias, value in endpoints.items():
    if not str(value).startswith("${"):
        problems.append(f"RPC alias '{alias}' is resolved in the effective deployment configuration")

if problems:
    print("DEPLOYMENT PROFILE RECONCILIATION FAILED", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    raise SystemExit(1)

print(
    f"deployment profile: test root test-deployment, isolated build scratch, "
    f"offline={config.get('offline')}, FFI disabled, no filesystem permission, frozen C10 build "
    f"({build['solc_version']}, {build['evm_version']}, optimizer {build['optimizer_runs']}, "
    f"via-IR {build['via_ir']}, bytecode hash {build['bytecode_hash']}, appendCBOR {build['append_cbor']})"
)
PYTHON

# ---------------------------------------------------------------------------
section "Source secret scan, before anything is built or run"
# ---------------------------------------------------------------------------

# Every source, test and packet file this ticket owns, scanned before a single line of it is
# executed or displayed.
python3 "$checker" secrets \
    --forge-config "$forge_config" \
    --scan script test-deployment deployments/base-mainnet

# ---------------------------------------------------------------------------
section "Formatting and build"
# ---------------------------------------------------------------------------

# Both happen offline in both modes. Nothing reaches a provider until the sources compile clean.
FOUNDRY_OFFLINE=true forge fmt --check
FOUNDRY_OFFLINE=true forge build

if [ "$expect_offline" = false ]; then
    # ---------------------------------------------------------------------------
    section "Base endpoint boundary"
    # ---------------------------------------------------------------------------

    # The first provider contact any mode makes, and it happens before every Forge test and before
    # the deployment script. `$0 --selftest-dead-endpoint` is this refusal's regression.
    probe_base_chain_id
fi

# ---------------------------------------------------------------------------
section "Committed ceremony selection"
# ---------------------------------------------------------------------------

# The founder's public deployer selection and the frozen snapshot of the mutable control surface.
# Every mode validates its shape; only a rehearsal requires it to be installed, and no mode writes
# it. A pending selection is honest rather than broken: the packet renders as NO-GO with a null
# selection and a null external observation, and the exact rehearsal is blocked until a human
# installs a reviewed candidate.
python3 - "$selection" "$mode" <<'PYTHON'
import json
import re
import sys

path, mode = sys.argv[1], sys.argv[2]
document = json.load(open(path, encoding="utf-8"))
problems = []

ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")
BYTES32 = re.compile(r"^0x[0-9a-fA-F]{64}$")

PREDICTED = [
    "uerc20_factory",
    "escrow_implementation",
    "splitter_implementation",
    "receiver_implementation",
    "factory",
    "strategy",
    "hook",
]
SAFE_ADDRESS_FACTS = ["guard", "fallback_handler", "singleton", "module_next_page"]

status = document.get("status")
if status not in {"selection_pending", "selection_installed"}:
    raise SystemExit(f"the ceremony selection status is [{status}], expected selection_pending or selection_installed")

selection = document.get("selection") or {}
snapshot = document.get("control_snapshot")
pinned = [selection.get(key) for key in ("deployer", "starting_nonce", "hook_salt", "predicted_addresses")]

if status == "selection_pending":
    if any(value is not None for value in pinned) or snapshot is not None:
        problems.append("a pending ceremony selection carries a value; pending means every field is null")
else:
    if not ADDRESS.match(str(selection.get("deployer"))):
        problems.append(f"the selected deployer is not a 20-byte address: {selection.get('deployer')}")
    if not isinstance(selection.get("starting_nonce"), int) or isinstance(selection.get("starting_nonce"), bool):
        problems.append(f"the starting nonce is not an integer: {selection.get('starting_nonce')}")
    if not BYTES32.match(str(selection.get("hook_salt"))):
        problems.append(f"the hook salt is not a 32-byte value: {selection.get('hook_salt')}")

    predicted = selection.get("predicted_addresses") or {}
    if sorted(predicted) != sorted(PREDICTED):
        problems.append(f"the predicted addresses are {sorted(predicted)}, expected {sorted(PREDICTED)}")
    for key, value in predicted.items():
        if not ADDRESS.match(str(value)):
            problems.append(f"predicted address '{key}' is not a 20-byte address: {value}")

    staking = (snapshot or {}).get("live_staking") or {}
    if not ADDRESS.match(str(staking.get("owner"))):
        problems.append(f"the snapshot live staking owner is not an address: {staking.get('owner')}")
    if staking.get("paused") is not False:
        problems.append(f"the snapshot records live staking paused as [{staking.get('paused')}]")
    if not ADDRESS.match(str(staking.get("usdc"))):
        problems.append(f"the snapshot live staking USDC binding is not an address: {staking.get('usdc')}")

    safe = (snapshot or {}).get("governance_and_regent_safe") or {}
    owners = safe.get("owners")
    if not isinstance(owners, list) or not owners or not all(ADDRESS.match(str(o)) for o in owners):
        problems.append(f"the snapshot Safe owner set is not a nonempty list of addresses: {owners}")
    threshold = safe.get("threshold")
    if not isinstance(threshold, int) or isinstance(threshold, bool) or threshold < 1:
        problems.append(f"the snapshot Safe threshold is not a positive integer: {threshold}")
    elif isinstance(owners, list) and threshold > len(owners):
        problems.append(f"the snapshot Safe threshold {threshold} exceeds its own owner count {len(owners)}")
    modules = safe.get("modules")
    if not isinstance(modules, list) or not all(ADDRESS.match(str(m)) for m in modules):
        problems.append(f"the snapshot Safe module list is not a list of addresses: {modules}")
    for fact in SAFE_ADDRESS_FACTS:
        if not ADDRESS.match(str(safe.get(fact))):
            problems.append(f"the snapshot Safe {fact} is not an address: {safe.get(fact)}")
    if not isinstance(safe.get("version"), str) or not safe.get("version"):
        problems.append(f"the snapshot Safe version is not a string: {safe.get('version')}")
    if not isinstance((snapshot or {}).get("observed_at_block"), int):
        problems.append("the snapshot records no integer observation block")

if problems:
    print("CEREMONY SELECTION RECONCILIATION FAILED", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    raise SystemExit(1)

if status == "selection_pending":
    print("ceremony selection: pending — no deployer is selected and no control surface is frozen")
    if mode == "--rehearse":
        raise SystemExit(
            "the committed ceremony selection is still pending, so this rehearsal cannot compare the "
            "exact selected deployer, the exact predicted addresses, or the exact live control "
            "surface, and it will not pretend to be the ceremony.\n"
            "Remaining founder input: the public disposable deployer address.\n"
            "Then run: bin/deployment-gate.sh --prepare <deployer>, review the candidate it writes, "
            "install it as deployments/base-mainnet/ceremony-selection.json, re-render the packet "
            "with --offline, and commit both."
        )
else:
    print(
        f"ceremony selection: installed for deployer {selection['deployer']} at starting nonce "
        f"{selection['starting_nonce']}, {len(safe['owners'])} Safe owner(s), threshold "
        f"{safe['threshold']}, observed at block {snapshot['observed_at_block']}"
    )
PYTHON

# A rehearsal consumes the three committed values and nothing else. Reaching here in that mode means
# the block above accepted an installed selection, so all three exist and all three are public. A
# preparation run keeps the founder's argument instead: it is what derives the other two.
if [ "$mode" = --rehearse ]; then
    read_selection() {
        python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['selection'][sys.argv[2]])" "$selection" "$1"
    }
    pinned_deployer=$(read_selection deployer)
    pinned_nonce=$(read_selection starting_nonce)
    pinned_salt=$(read_selection hook_salt)
fi

if [ "$mode" = --prepare ]; then
    # ---------------------------------------------------------------------------
    section "Authorized read-only preparation"
    # ---------------------------------------------------------------------------

    # The one mode that derives a ceremony's free parameters, and it derives nothing it may keep.
    run_preflight
    run_selection test_SelectionPrepareCandidate
    compare_external_state "$mode"

    python3 "$checker" secrets \
        --forge-config "$forge_config" \
        --scan "$generated" script test-deployment deployments/base-mainnet

    cat <<TRANSITION

A reviewable ceremony-selection candidate is at:

    $selection_candidate

Nothing has been blessed and nothing reads it. The record now at $selection
is unchanged. To make it authority instead, deliberately:

  1. confirm the deployer address is the account the founder actually selected, and that its
     starting nonce and balance are what an authorized ceremony would send from;
  2. check the seven predicted addresses and the mined hook salt against an independent
     derivation, and confirm the hook address carries exactly the five permission bits;
  3. read every control-surface value against an independent source — a moved Safe owner set,
     threshold, guard, module, fallback handler or singleton is a governance change to account
     for, not drift to absorb;
  4. install it as $selection and commit it;
  5. re-render the packet: bin/deployment-gate.sh --offline, then install and commit the render;
  6. rehearse against the founder's read-only Base authority: bin/deployment-gate.sh --rehearse.

Until step 4 lands, --rehearse still refuses to run and the packet still renders as a pending
selection. This run reached no signing authority, sent no transaction, and moved no value.

TRANSITION
    printf 'MAINNET NO-GO. Nothing was signed, broadcast, deployed, funded, or moved.\n'
    printf 'DEPLOYMENT PREPARATION CANDIDATE\n'
    exit 0
fi

# ---------------------------------------------------------------------------
section "Compiled listing of the mapped ceremony selectors"
# ---------------------------------------------------------------------------

FOUNDRY_OFFLINE=true forge test --list --json --no-match-contract "$UNMAPPED_CONTRACTS" >"$test_list"

# ---------------------------------------------------------------------------
section "The five-creation ceremony"
# ---------------------------------------------------------------------------

# `-vv` is load-bearing rather than cosmetic: Foundry only populates each result's `decoded_logs`
# at that verbosity, and the packet below is rendered from exactly that field.
ceremony_status=0
if [ "$mode" = --rehearse ]; then
    RUST_LOG=error forge test --json -vv --no-match-contract "$UNMAPPED_CONTRACTS" --fork-url "$RPC_ALIAS" \
        >"$ceremony_report" 2>"$ceremony_log" || ceremony_status=$?
else
    RUST_LOG=error forge test --json -vv --no-match-contract "$UNMAPPED_CONTRACTS" \
        >"$ceremony_report" 2>"$ceremony_log" || ceremony_status=$?
fi
scan_then_display "$ceremony_log"
[ "$ceremony_status" -eq 0 ] ||
    fail "the ceremony run exited $ceremony_status; its scanned diagnostics are retained under $generated"

if [ "$mode" = --rehearse ]; then
    # ---------------------------------------------------------------------------
    section "Authorized read-only external-state preflight"
    # ---------------------------------------------------------------------------

    run_preflight
    run_selection test_SelectionMatchesTheCommittedValues
    compare_external_state "$mode"

    # ---------------------------------------------------------------------------
    section "The exact deployment script, simulated and never broadcast"
    # ---------------------------------------------------------------------------

    # The same file an authorized ceremony would run, against the same chain, consuming the same
    # three committed values — and stopping exactly where a signature would begin. There is no
    # `--broadcast` flag, no `--private-key`, no `--account`, no `--ledger`, no `--interactive` and
    # no sender: without them Foundry simulates the transaction sequence and sends nothing. The
    # script's own checks are what this proves: the deployer's live Base nonce still equals the
    # committed starting nonce, the pinned salt still derives a hook address carrying the five
    # permission bits, each simulated creation lands on the committed prediction, and the factory's
    # strategy() and hook() readbacks are the predicted internal addresses. Any mismatch reverts the
    # simulation, which is a stop. The dry run's scratch is written under the gitignored broadcast/
    # prefix and is never evidence.
    dry_run_status=0
    REGENT_DEPLOYMENT_DEPLOYER="$pinned_deployer" \
        REGENT_DEPLOYMENT_STARTING_NONCE="$pinned_nonce" \
        REGENT_DEPLOYMENT_HOOK_SALT="$pinned_salt" \
        RUST_LOG=error forge script "$script:DeployAutolaunchV1" --rpc-url "$RPC_ALIAS" \
        >"$dry_run_log" 2>&1 || dry_run_status=$?
    scan_then_display "$dry_run_log"
    [ "$dry_run_status" -eq 0 ] ||
        fail "the unsigned deployment-script simulation exited $dry_run_status; a ceremony against this chain state is a stop"
    printf 'the exact deployment script simulated cleanly against Base and broadcast nothing\n'
fi

# ---------------------------------------------------------------------------
section "Ledger reconciliation"
# ---------------------------------------------------------------------------

# Every mapped deployment selector must be listed once by Foundry's own compiled listing, must
# have executed exactly once in this run, and must have passed. A selector that exists but is not
# mapped, or a claim that is due but whose selector is absent, fails here.
python3 "$checker" ledger \
    --ledger "$ledger" \
    --spec SPEC.md \
    --gates "$GATES" \
    --test-list "$test_list" \
    --test-report "$ceremony_report" \
    --receipt "$receipt"

# ---------------------------------------------------------------------------
section "Deterministic mainnet-NO-GO packet"
# ---------------------------------------------------------------------------

# The ceremony emits its measured graph as decoded logs; Solidity has no filesystem permission and
# cannot write a packet for itself. This renders one from those measurements, reconciles every
# measured byte count and initcode hash against the committed frozen release surface, and then
# compares the render byte for byte against the committed packet. Rendering and blessing stay
# separate: this gate can fail an installed packet, and it can produce a candidate for review, but
# it can never install one.
python3 - "$ceremony_report" "$sizes" "$frozen" "$rendered" "$packet" "$selection" <<'PYTHON'
import hashlib
import json
import sys

report_path, sizes_path, frozen_path, rendered_path, packet_path, selection_path = sys.argv[1:7]

EIP170 = 24_576
EIP3860 = 49_152

# A guardrail on the in-EVM creation gas DEP-074 measures. The packet's own gas note explains why
# that figure is a floor rather than a transaction cost.
IN_EVM_CREATION_GAS_GUARDRAIL = 14_000_000

# The command an authorized ceremony would eventually run, recorded as text and never invoked from
# this repository. `--slow` is load-bearing: it sends the five creations one at a time and waits for
# each receipt, so no skipped, dropped or replaced nonce can move the factory away from the packet's
# prediction. `--resume` is forbidden — a partial ceremony is terminal, not resumable.
AUTHORIZED_COMMAND_SHAPE = (
    "forge script script/DeployAutolaunchV1.s.sol:DeployAutolaunchV1 --rpc-url base --broadcast --slow"
)

# The two immutable identities the packet names apart, from README.md's own record.
PRODUCTION_AUTHORITY_COMMIT = "7e70077d66b7a1a511806a68f086583c733c812a"
PRODUCTION_AUTHORITY_TREE = "23f26023216ec93f9014b3c0295588b5aede6ee0"
SHARED_SRC_TREE = "314889bcc6cabd5ceff336af93082d009df86205"
FORK_EVIDENCE_COMMIT = "f6bb34087dc16f6edf72e434f30f5e953071a579"

CREATION_ORDER = [
    ("UERC20Factory", "lib/uerc20-factory/src/factories/UERC20Factory.sol"),
    ("ConditionalVestingEscrowV1", "src/escrow/ConditionalVestingEscrowV1.sol"),
    ("SubjectSplitterV1", "src/revenue/SubjectSplitterV1.sol"),
    ("PaymentReceiverV1", "src/revenue/PaymentReceiverV1.sol"),
    ("RegentsAutolaunchFactoryV1", "src/factory/RegentsAutolaunchFactoryV1.sol"),
]
INTERNAL_ORDER = [
    ("RegentLBPStrategy", "src/strategy/RegentLBPStrategy.sol"),
    ("RegentFeeHook", "src/hook/RegentFeeHook.sol"),
]

problems = []


def decoded_logs(path):
    lines = []
    for result in json.load(open(path, encoding="utf-8")).values():
        for outcome in result.get("test_results", {}).values():
            lines.extend(outcome.get("decoded_logs") or [])
    return lines


# --- what the ceremony measured -------------------------------------------------
measured, hook_flags, current = {}, None, None
for line in decoded_logs(report_path):
    key, _, value = line.partition(": ")
    key = key.strip()
    if key == "packet contract":
        current = value
        measured[current] = {}
    elif key == "packet hook_flags":
        hook_flags = int(value)
    elif current is not None and key in {
        "runtime_bytes",
        "runtime_margin_bytes",
        "creation_code_bytes",
        "creation_code_keccak256",
        "constructor_args_bytes",
        "initcode_bytes",
        "initcode_margin_bytes",
    }:
        measured[current][key] = value

expected_names = [name for name, _ in CREATION_ORDER + INTERNAL_ORDER]
if sorted(measured) != sorted(expected_names):
    problems.append(f"the ceremony measured {sorted(measured)}, expected {sorted(expected_names)}")
if hook_flags is None:
    problems.append("the ceremony emitted no hook permission-bit word, so the packet cannot record one")

# --- reconciled against the committed frozen release surface --------------------
sizes = json.load(open(sizes_path, encoding="utf-8"))
frozen_rows = {row["contract"]: row for row in sizes["contracts"] + sizes["dependency_contracts"]}

if sizes["limits"]["eip170_runtime_bytes"] != EIP170 or sizes["limits"]["eip3860_initcode_bytes"] != EIP3860:
    problems.append("the frozen release surface records different EIP-170/EIP-3860 limits than this gate applies")

for name in expected_names:
    row, found = frozen_rows.get(name), measured.get(name, {})
    if row is None:
        problems.append(f"{name}: the frozen release surface records no deployable size row")
        continue
    frozen_args = row.get("constructor_args_bytes", 0)
    for label, wanted in (
        ("runtime_bytes", row["runtime_bytes"]),
        ("creation_code_bytes", row["creation_bytes"]),
        ("constructor_args_bytes", frozen_args),
        ("initcode_bytes", row["creation_bytes"] + frozen_args),
        ("creation_code_keccak256", row["creation_keccak256"]),
    ):
        if str(wanted) != found.get(label):
            problems.append(
                f"{name}: the ceremony measured {label} [{found.get(label)}], the frozen release "
                f"surface records [{wanted}]"
            )

if problems:
    print("PACKET RECONCILIATION FAILED", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    raise SystemExit(1)


def code_identity(name, source, index, mechanism):
    found = measured[name]
    entry = {
        "contract": name,
        "source": source,
        "created_by": "deployer" if mechanism == "transaction" else "RegentsAutolaunchFactoryV1",
        "mechanism": mechanism,
        "runtime_bytes": int(found["runtime_bytes"]),
        "runtime_margin_bytes": int(found["runtime_margin_bytes"]),
        "creation_code_bytes": int(found["creation_code_bytes"]),
        "creation_code_keccak256": found["creation_code_keccak256"],
        "constructor_args_bytes": int(found["constructor_args_bytes"]),
        "initcode_bytes": int(found["initcode_bytes"]),
        "initcode_margin_bytes": int(found["initcode_margin_bytes"]),
    }
    if mechanism == "transaction":
        entry["deployer_nonce_offset"] = index
        entry["value_wei"] = 0
    return entry


frozen = json.load(open(frozen_path, encoding="utf-8"))["build"]
committed_selection = json.load(open(selection_path, encoding="utf-8"))
pending = committed_selection["status"] == "selection_pending"
chosen = {} if pending else committed_selection["selection"]

document = {
    "artifact": "regents-autolaunch-base-mainnet-deployment-packet",
    "version": 1,
    "status": "mainnet-NO-GO",
    "authorization": {
        "state": "not authorized",
        "instrument": "a founder GO_TO_DEPLOY naming this packet's exact digest",
        "granted_by": None,
        "signing_method": None,
        "command_shape": AUTHORIZED_COMMAND_SHAPE,
        "resume_forbidden": True,
        "note": (
            "Nothing in this repository may be signed, broadcast, funded, or deployed until the "
            "founder separately approves this exact digest. The signing method is recorded at that "
            "point by name; its credential never appears in this packet or anywhere in this "
            "repository. `command_shape` is the shape an authorized ceremony would take, recorded "
            "as text: `--slow` sends the five creations one at a time and waits for each receipt. "
            "No gate in this repository invokes it. If any transaction fails or is replaced after "
            "an earlier creation has confirmed, this packet is terminally invalid: `--resume` is "
            "forbidden, the nonce is read again, the graph is recomputed, the gates and the "
            "independent review are repeated, and a new founder-approved digest is required."
        ),
    },
    "chain": {"name": "base", "id": 8453},
    "immutable_identities": {
        "production_authority_commit": PRODUCTION_AUTHORITY_COMMIT,
        "production_authority_tree": PRODUCTION_AUTHORITY_TREE,
        "shared_src_tree": SHARED_SRC_TREE,
        "fork_evidence_commit": FORK_EVIDENCE_COMMIT,
        "note": (
            "The production authority and the evidence candidate are two different identities that "
            "share one src/ tree. The candidate commit this packet was rendered from is proved by "
            "bin/deployment-gate.sh at run time and is deliberately not embedded here: a file "
            "cannot carry the hash of the commit that contains it."
        ),
    },
    "build": {
        "solc": frozen["solc_identity"],
        "evm_version": frozen["evm_version"],
        "optimizer_runs": frozen["optimizer_runs"],
        "via_ir": frozen["via_ir"],
        "bytecode_hash": frozen["bytecode_hash"],
        "append_cbor": frozen["append_cbor"],
    },
    "topology": {
        "top_level_creations": len(CREATION_ORDER),
        "creation_order": [
            code_identity(name, source, index, "transaction")
            for index, (name, source) in enumerate(CREATION_ORDER)
        ],
        "internal_creations": [
            dict(code_identity(INTERNAL_ORDER[0][0], INTERNAL_ORDER[0][1], 0, "CREATE"), factory_nonce=1),
            dict(
                code_identity(INTERNAL_ORDER[1][0], INTERNAL_ORDER[1][1], 0, "CREATE2"),
                salt="the pre-mined hookSalt this packet pins once a deployer is selected",
                required_permission_bits=hook_flags,
            ),
        ],
        "excluded": (
            "no deployment helper, proxy, upgrade path, ownership handoff, role grant, governance "
            "transaction, application admission, liquidity locker, recovery framework, or "
            "post-deployment binding call"
        ),
    },
    "limits": {
        "eip170_runtime_bytes": EIP170,
        "eip3860_initcode_bytes": EIP3860,
        "in_evm_creation_gas_guardrail": IN_EVM_CREATION_GAS_GUARDRAIL,
        "code_identity_note": (
            "`creation_code_keccak256` is the frozen build's own deployer-independent identity for "
            "the contract. It is not the hash of the initcode a real transaction sends: four of "
            "these seven constructors take arguments that are themselves addresses this ceremony "
            "produces, so that hash is only knowable once a deployer is selected. "
            "`initcode_bytes` is the whole creation code plus those encoded arguments, because "
            "that is what EIP-3860 measures."
        ),
        "gas_note": (
            "This packet records no gas figure, and no complete deployment-transaction gas result "
            "exists anywhere in this repository for these five creations. DEP-074 proves the "
            "EIP-170 and EIP-3860 size margins above; the only gas it measures is each creation's "
            "in-EVM cost, held under the guardrail above and printed by the gate. That figure is a "
            "floor, not a transaction cost: an in-EVM CREATE excludes the intrinsic cost, the "
            "initcode calldata cost and EIP-3860's per-word charge a real creation transaction "
            "carries, and it moves with the frame it is taken in. Full per-transaction estimates "
            "stay pending the exact selected deployer and salt and an authorized rehearsal. Fund "
            "the ceremony from a live estimate against that deployer, not from this packet."
        ),
    },
    "selection": {
        "deployer": chosen.get("deployer"),
        "starting_nonce": chosen.get("starting_nonce"),
        "hook_salt": chosen.get("hook_salt"),
        "predicted_addresses": chosen.get("predicted_addresses"),
        "source": "deployments/base-mainnet/ceremony-selection.json",
        "note": (
            (
                "No deployer has been selected. Every address this ceremony produces is a function "
                "of that account and its exact nonce, so the graph is derivable but not yet "
                "determined, and this packet cannot claim that the exact ceremony was rehearsed. "
                "The remaining founder input is one public disposable deployer address; "
                "`bin/deployment-gate.sh --prepare <deployer>` then reads its live nonce, mines the "
                "hook salt once against the predicted factory and strategy, and writes a reviewable "
                "candidate that a human installs."
            )
            if pending
            else (
                "The founder-selected deployer, the starting nonce read from Base, and the hook "
                "salt mined once against the predicted factory and strategy, all consumed from the "
                "committed ceremony selection. `bin/deployment-gate.sh --rehearse` re-derives these "
                "seven addresses from those three values and simulates the exact deployment script "
                "against Base without broadcasting. A completed ceremony moves the deployer five "
                "nonces past this one, which is what makes this packet single-use."
            )
        ),
    },
    "external_observation": None if pending else committed_selection["control_snapshot"],
    "external_observation_note": (
        (
            "No provider was accessed while preparing this packet, and no external observation has "
            "been frozen. The external-state preflight — the frozen binding runtime and proxy "
            "identities, the CCA zero fee controller, the live staking owner, pause and USDC "
            "binding, the mutable USDC pause and blacklist policy, and the exact Regent Safe "
            "owners, threshold, guard, modules, fallback handler, singleton and version — runs "
            "under `bin/deployment-gate.sh --prepare` and `--rehearse` on the founder's separate "
            "read-only Base authority."
        )
        if pending
        else (
            "The mutable control surface frozen by an authorized preparation run and re-read on "
            "every rehearsal, from deployments/base-mainnet/ceremony-selection.json. Every frozen "
            "binding's runtime and proxy identity is compared against "
            "reports/frozen/fork-observations.json instead, which stays the sole authority for "
            "those, and the CCA zero fee controller and the USDC pause and blacklist policy are "
            "asserted by the preflight itself. `observed_at_block` is provenance: the head moves, "
            "so it is recorded rather than compared."
        )
    ),
    "digest": {
        "algorithm": "sha256",
        "over": "this document rendered with digest.value set to null, json.dumps(indent=2, sort_keys=True)",
        "value": None,
    },
}

canonical = json.dumps(document, indent=2, sort_keys=True)
document["digest"]["value"] = "0x" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()
rendered = json.dumps(document, indent=2, sort_keys=True) + "\n"
open(rendered_path, "w", encoding="utf-8").write(rendered)

committed = open(packet_path, encoding="utf-8").read()
if committed != rendered:
    raise SystemExit(
        f"the committed packet at {packet_path} is not what this candidate renders. A reviewable "
        f"candidate is at {rendered_path}; read it, install it deliberately, and commit it. "
        f"Nothing about it is blessed until a human does that."
    )

print(f"packet: {packet_path} is byte-identical to this run's render")
print(f"packet digest: {document['digest']['value']}")
print(f"packet status: {document['status']}")
PYTHON

# ---------------------------------------------------------------------------
section "The deployed manifest stays separate and unpopulated"
# ---------------------------------------------------------------------------

# The packet is a proposal; the manifest is a record of confirmed Base receipts. Keeping them in
# two files is not enough on its own, so the manifest is proved empty here: a simulated address, a
# rehearsal transaction hash, or a fork block number reaching it would fail this gate.
python3 - "$manifest" <<'PYTHON'
import json
import re
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
problems = []

if manifest.get("status") != "not deployed":
    problems.append(f"the deployed manifest status is [{manifest.get('status')}], expected [not deployed]")


def walk(node, path=""):
    if isinstance(node, dict):
        for key, value in node.items():
            walk(value, f"{path}.{key}" if path else key)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            walk(value, f"{path}[{index}]")
    elif isinstance(node, str) and re.fullmatch(r"0x[0-9a-fA-F]{40}|0x[0-9a-fA-F]{64}", node):
        problems.append(f"the deployed manifest carries an address or hash at '{path}'")
    elif isinstance(node, (int, float)) and not isinstance(node, bool) and node != 0:
        problems.append(f"the deployed manifest carries a nonzero number at '{path}'")


for key, value in manifest.items():
    if key in {"status", "artifact", "note", "populated_by", "version"}:
        continue
    walk(value, key)

if problems:
    print("DEPLOYED MANIFEST RECONCILIATION FAILED", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    raise SystemExit(1)

print("the deployed manifest is structurally separate and carries no deployed fact")
PYTHON

# ---------------------------------------------------------------------------
section "Final secret scan"
# ---------------------------------------------------------------------------

# Everything this run produced, plus everything it would have a reviewer read.
python3 "$checker" secrets \
    --forge-config "$forge_config" \
    --scan "$generated" script test-deployment deployments/base-mainnet docs/audit/deployment-ceremony.md

# ---------------------------------------------------------------------------
section "Gate report"
# ---------------------------------------------------------------------------

cat "$receipt"
printf 'mode: %s\n' "$mode"
printf 'ceremony selection: %s\n' "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['status'])" "$selection")"
printf '\nMAINNET NO-GO. Nothing was signed, broadcast, deployed, funded, or moved.\n'
printf 'DEPLOYMENT GATE PASS\n'
