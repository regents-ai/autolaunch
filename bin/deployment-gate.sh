#!/bin/sh
# Deployment-ceremony gate for autolaunch-contracts.
#
# Not the required gate; `bin/gate.sh` is. This proves the `deployment` gate alone: the five direct,
# zero-value creation transactions a founder-selected disposable deployer would send to put the
# Autolaunch graph on Base, and nothing else. Four modes:
#
#   --offline                 Carries this candidate's evidence. `FOUNDRY_OFFLINE=true` with the
#                             endpoint variable cleared, so no network is reachable. The five
#                             creations call no external contract, so this decides the ceremony.
#   --prepare <deployer>      The only mode that derives a ceremony's free parameters: it reads that
#                             public account's live Base nonce, mines the hook salt once, snapshots
#                             the live control surface, and writes one complete packet candidate
#                             into gitignored scratch. It installs nothing and prints no pass marker.
#   --rehearse                Compare-only, against the committed packet. It authors nothing.
#   --selftest-dead-endpoint  The chain-id boundary's regression. It reaches no network.
#
# Provider modes probe `cast chain-id` through the configured alias before any build, Forge run or
# script, so a dead, unreachable, malformed or wrong-chain endpoint stops here rather than surfacing
# as a harness failure. `bin/fork-gate.sh` carries the same boundary and regression.
#
# Nothing here signs, broadcasts, deploys, funds, requests a wallet, writes to a provider, or moves
# value. `script/DeployAutolaunchV1.s.sol` is invoked in exactly one place, in rehearsal, with no
# `--broadcast`, no signer and no sender. A signing variable in the environment is a stop, and so is
# a dotenv file in the worktree: Foundry would load it into the process environment and this ceremony
# reads three of its parameters from there.
#
# Every mode ends at mainnet NO-GO. The packet is a proposal; only a later founder instruction naming
# its exact digest can authorize a signature or a broadcast, and only confirmed Base receipts may
# populate the separate deployed manifest.
#
# A failure of this gate is a stop-report. Never relax a pinned identity, limit, or configuration
# value to make it pass.
set -eu

cd "$(dirname "$0")/.."

FOUNDRY_PROFILE=deployment
GIT_TERMINAL_PROMPT=0
export FOUNDRY_PROFILE GIT_TERMINAL_PROMPT

# The only gate this entrypoint proves.
GATES=deployment

RPC_ALIAS=base
RPC_ENV=REGENT_BASE_RPC_URL
CHAIN_ID=8453
PROBE_REFUSAL="the configured $RPC_ALIAS endpoint did not answer a read-only chain-id probe with exactly $CHAIN_ID"

# The discard port. Nothing listens on it, so the dead-endpoint regression is deterministic.
DEAD_ENDPOINT=http://127.0.0.1:9

# Neither contract carries a requirement id, so both are excluded by name from the compiled listing
# and from the ledger reconciliation, exactly as `bin/fork-gate.sh` excludes its discovery pass.
UNMAPPED_CONTRACTS='DeploymentPreflightTest|DeploymentSelectionTest'

frozen=requirements/frozen-identity.json
ledger=requirements/ledger.toml
sizes=reports/frozen/deployable-sizes.json
observations=reports/frozen/fork-observations.json
checker=bin/check-requirements.py
script=script/DeployAutolaunchV1.s.sol

packet=deployments/base-mainnet/mainnet-no-go-packet.json
manifest=deployments/base-mainnet/deployed-manifest.json

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

# One read-only `eth_chainId` read through the configured alias, and the whole endpoint boundary.
# `cast` names the URL in its own diagnostics, so the capture is scanned before anything is
# displayed and dropped unread if the scan finds it. The answer is printed only when it is plain
# digits, and every failure — dead, unreachable, malformed, or another chain — is one refusal.
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

# One read-only Forge run against the Base fork, carrying the three public ceremony parameters under
# the exact names `script/DeployAutolaunchV1.s.sol` consumes. None is a credential, and the two
# derived ones stay empty in preparation because preparation is what derives them.
observe() {
    observe_report=$1
    observe_log=$2
    shift 2
    observe_status=0
    REGENT_DEPLOYMENT_DEPLOYER="$pinned_deployer" \
        REGENT_DEPLOYMENT_STARTING_NONCE="$pinned_nonce" \
        REGENT_DEPLOYMENT_HOOK_SALT="$pinned_salt" \
        RUST_LOG=error forge test --json -vv --fork-url "$RPC_ALIAS" "$@" \
        >"$observe_report" 2>"$observe_log" || observe_status=$?
    scan_then_display "$observe_log"
    [ "$observe_status" -eq 0 ] ||
        fail "a read-only Base observation exited $observe_status; its scanned diagnostics are under $generated"
}

mode=${1:-}
pinned_deployer=
pinned_nonce=
pinned_salt=
case "$mode" in
    --offline)
        FOUNDRY_OFFLINE=true
        export FOUNDRY_OFFLINE
        # Cleared rather than merely unused: an offline run must be incapable of reaching Base.
        unset "$RPC_ENV" 2>/dev/null || :
        expect_offline=true
        ;;
    --prepare)
        # The founder's public deployer address, and the only value this repository cannot derive,
        # observe or invent. It is an argument so it is visible in the command that produced a
        # candidate.
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
        selection_selector=test_SelectionPrepareCandidate
        expect_offline=false
        ;;
    --rehearse)
        selection_selector=test_SelectionMatchesTheCommittedValues
        expect_offline=false
        ;;
    --selftest-dead-endpoint)
        # Re-runs this script in `--rehearse` with the alias pointed at a closed loopback port, so
        # the production probe is the code under test and the real endpoint is never passed on. It
        # reaches no Forge test, closes no claim, and never prints the pass marker.
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
    "$manifest" test-deployment/DeploymentCeremony.t.sol test-deployment/DeploymentPreflight.t.sol \
    test-deployment/DeploymentSelection.t.sol; do
    [ -f "$required_file" ] || fail "required deployment material is missing: $required_file"
done

# No signing authority may be anywhere near this run, in any mode. This is a superset of the fork
# gate's refusal list: it also covers the keystore, account and interactive-signer variables
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

# Foundry loads a dotenv file from the project root into the process environment, and this ceremony
# reads three of its parameters from that environment. Such a file's presence is detected; its
# contents never are.
for dotenv in .env .env.local .envrc; do
    [ -e "$dotenv" ] &&
        fail "$dotenv exists in the worktree; this gate never reads one and refuses to run beside one"
done
printf 'no .env, .env.local or .envrc exists in the worktree; none is read\n'

if [ "$expect_offline" = true ]; then
    printf 'no provider is reachable: FOUNDRY_OFFLINE is true and %s is cleared from this run\n' "$RPC_ENV"
else
    command -v cast >/dev/null 2>&1 || fail "cast is not on PATH; the chain-id probe cannot run"

    # The endpoint is consumed, never printed. Only its presence and its shape are reported.
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
# the thing that was tested is not the thing that was committed. The gate's own scratch lives under
# the gitignored `reports/generated/` prefix and therefore cannot make this dirty.
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
observed_state="$generated/observed-state.json"
dry_run_log="$generated/forge-script-dry-run.log"
receipt="$generated/receipt.txt"
rendered="$generated/mainnet-no-go-packet.json"

printf 'candidate commit %s tree %s src %s\n' "$candidate_commit" "$candidate_tree" "$candidate_src_tree" >"$receipt"

# ---------------------------------------------------------------------------
section "Effective deployment-profile configuration"
# ---------------------------------------------------------------------------

# The effective configuration, not the committed file, and proved before any provider access, any
# build, and before the hook address is derived from `type(RegentFeeHook).creationCode`. A hook
# address is a function of the compiler settings, so a graph derived under a drifted build would be
# a confident prediction of the wrong address.
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

# Build directory: isolated from the required gate's `out/` and from the fork gate's `out-fork/`.
for key, found in (("out", config.get("out")), ("cache_path", config.get("cache_path"))):
    if found in ("out", "out-fork", "cache", "cache-fork"):
        problems.append(f"deployment profile {key} [{found}] is shared with another gate")
    if not str(found).startswith("reports/generated/"):
        problems.append(f"deployment profile {key} [{found}] is not gitignored build scratch")

# Network posture: exactly the mode this run was asked for, and FFI disabled in both.
expect("deployment profile offline", expect_offline, config.get("offline"))
expect("deployment profile ffi", False, config.get("ffi"))

# Filesystem: none at all. This profile's Solidity can neither read a committed authority nor write
# an observation, which is what keeps packet rendering a reviewed shell step.
permissions = config.get("fs_permissions") or []
if permissions:
    problems.append(f"the deployment profile grants filesystem permissions: {permissions}")

# Compiler: the frozen C10 build, field for field, because the hook's CREATE2 address is derived
# from the initcode this build produces.
build = frozen["build"]
expect("deployment profile solc", build["solc_version"], config.get("solc"))
expect("deployment profile evm version", build["evm_version"], config.get("evm_version"))
expect("deployment profile optimizer", True, config.get("optimizer"))
expect("deployment profile optimizer runs", build["optimizer_runs"], config.get("optimizer_runs"))
expect("deployment profile via-IR", build["via_ir"], config.get("via_ir"))
expect("deployment profile bytecode hash", build["bytecode_hash"], config.get("bytecode_hash"))
expect("deployment profile appendCBOR", build["append_cbor"], config.get("cbor_metadata"))

# The frozen fuzz portfolio, so the ceremony's own fuzzed derivation runs the reviewed seed, count
# and rejection budget rather than whatever a default happens to be.
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

if [ "$expect_offline" = false ]; then
    # ---------------------------------------------------------------------------
    section "Base endpoint boundary"
    # ---------------------------------------------------------------------------

    # The first provider contact any mode makes, and it happens before the build, before every Forge
    # test and before the deployment script. `$0 --selftest-dead-endpoint` is its regression.
    probe_base_chain_id
fi

if [ "$mode" = --rehearse ]; then
    # A rehearsal consumes the committed packet's three public ceremony values and nothing else.
    # Without them there is no exact ceremony to compare against, so the rehearsal refuses rather
    # than pretending to be one.
    read_selection() {
        python3 -c 'import json,sys;v=json.load(open(sys.argv[1]))["selection"][sys.argv[2]];print("" if v is None else v)' \
            "$packet" "$1"
    }
    pinned_deployer=$(read_selection deployer)
    pinned_nonce=$(read_selection starting_nonce)
    pinned_salt=$(read_selection hook_salt)
    [ -n "$pinned_deployer" ] && [ -n "$pinned_nonce" ] && [ -n "$pinned_salt" ] ||
        fail "$packet pins no deployer, starting nonce, or hook salt, so this rehearsal has no exact
ceremony to compare against. Remaining founder input: one public disposable deployer address. Then
run $0 --prepare <deployer>, review the packet candidate it writes, install and commit it."
    printf 'committed packet selection: deployer %s at starting nonce %s\n' "$pinned_deployer" "$pinned_nonce"
fi

# ---------------------------------------------------------------------------
section "Source secret scan, before anything is built or run"
# ---------------------------------------------------------------------------

python3 "$checker" secrets \
    --forge-config "$forge_config" \
    --scan script test-deployment deployments/base-mainnet

# ---------------------------------------------------------------------------
section "Formatting and build"
# ---------------------------------------------------------------------------

FOUNDRY_OFFLINE=true forge fmt --check
FOUNDRY_OFFLINE=true forge build

# ---------------------------------------------------------------------------
section "Compiled listing of the mapped ceremony selectors"
# ---------------------------------------------------------------------------

FOUNDRY_OFFLINE=true forge test --list --json --no-match-contract "$UNMAPPED_CONTRACTS" >"$test_list"

# ---------------------------------------------------------------------------
section "The five-creation ceremony"
# ---------------------------------------------------------------------------

# `-vv` is load-bearing rather than cosmetic: Foundry only populates each result's `decoded_logs` at
# that verbosity, and the packet below is rendered from exactly that field.
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

if [ "$expect_offline" = false ]; then
    # ---------------------------------------------------------------------------
    section "Authorized read-only external state"
    # ---------------------------------------------------------------------------

    # The only two things here that read live Base state. Every read in them is a hard `staticcall`,
    # so a run that cannot reach Base fails loudly instead of reporting an empty observation.
    observe "$preflight_report" "$preflight_log" --match-contract DeploymentPreflightTest
    observe "$selection_report" "$selection_log" \
        --match-contract DeploymentSelectionTest --match-test "$selection_selector"

    # The deployment profile has no filesystem permission, so both emit their measurements as
    # decoded logs and this is the one place they are compared. A rehearsal compares; a preparation
    # run captures what the packet candidate below is rendered from.
    python3 - "$mode" "$preflight_report" "$selection_report" "$observations" "$packet" "$observed_state" <<'PYTHON'
import json
import re
import sys

mode, preflight_path, selection_path, observations_path, packet_path, observed_path = sys.argv[1:7]

FACTS = [
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
ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}")

problems = []


def compare(label, wanted, found):
    def normalize(value):
        if isinstance(value, list):
            return [normalize(item) for item in value]
        return value.lower() if isinstance(value, str) and value.startswith("0x") else value

    if normalize(wanted) != normalize(found):
        problems.append(f"{label}: committed [{wanted}], observed [{found}]")


def decoded_logs(path):
    return [
        line
        for result in json.load(open(path, encoding="utf-8")).values()
        for outcome in result.get("test_results", {}).values()
        for line in outcome.get("decoded_logs") or []
    ]


def parse(path, prefix):
    """Every `<prefix> <key>: <value>` line by key, plus the binding blocks a `binding_id` opens."""
    facts, bindings, current = {}, {}, None
    for line in decoded_logs(path):
        key, _, value = line.partition(": ")
        key = key.strip()
        if key == f"{prefix} binding_id":
            current = value
            bindings[current] = {}
        elif key.startswith(f"{prefix} "):
            facts[key[len(prefix) + 1 :]] = value
        elif current is not None and key.startswith("binding_"):
            bindings[current][key[len("binding_") :]] = value
    return facts, bindings


# --- one parse of each run -------------------------------------------------------
preflight, bindings = parse(preflight_path, "preflight")
selection, _ = parse(selection_path, "selection")

# --- runtime and proxy identity, against the sole frozen authority for it ---------
observation = json.load(open(observations_path, encoding="utf-8"))
frozen = dict(observation["bindings"], permit2=observation["permit2"])
if sorted(bindings) != sorted(frozen):
    problems.append(f"the preflight observed bindings {sorted(bindings)}, the frozen record names {sorted(frozen)}")

for name in sorted(set(bindings) & set(frozen)):
    for fact in FACTS:
        found = bindings[name].get(fact)
        if fact in BYTE_COUNTS and found is not None and found.isdigit():
            found = int(found)
        compare(f"binding {name}.{fact}", frozen[name][fact], found)

# --- the mutable facts no frozen record can hold ---------------------------------
# Every key below is emitted unconditionally by a passing selector, so a missing one means the
# harness did not do what this comparison assumes it did: a run that emitted nothing observed
# nothing, and that is named here rather than crashed on further down.
try:
    observed = {
        "selection": {
            "deployer": selection["deployer"],
            "starting_nonce": int(selection["starting_nonce"]),
            "hook_salt": selection["hook_salt"],
            "predicted_addresses": {name: selection[f"predicted_{name}"] for name in PREDICTED},
        },
        "external_observation": {
            "observed_at_block": int(preflight["block_number"]),
            "live_staking": {
                "owner": preflight["live_staking_owner"],
                "paused": preflight["live_staking_paused"] == "true",
                "usdc": preflight["live_staking_usdc"],
            },
            "governance_and_regent_safe": {
                "owners": ADDRESS.findall(preflight["safe_owners"]),
                "threshold": int(preflight["safe_threshold"]),
                "guard": preflight["safe_guard"],
                "modules": ADDRESS.findall(preflight["safe_modules"]),
                "module_next_page": preflight["safe_module_next_page"],
                "fallback_handler": preflight["safe_fallback_handler"],
                "singleton": preflight["safe_singleton"],
                "version": preflight["safe_version"],
            },
        },
    }
except KeyError as absent:
    raise SystemExit(f"the run emitted no '{absent.args[0]}'; no external state was observed")

if mode == "--rehearse":
    committed = json.load(open(packet_path, encoding="utf-8"))
    for fact in ("deployer", "starting_nonce", "hook_salt"):
        compare(f"selection.{fact}", committed["selection"][fact], observed["selection"][fact])
    for name in PREDICTED:
        compare(
            f"selection.predicted_addresses.{name}",
            committed["selection"]["predicted_addresses"][name],
            observed["selection"]["predicted_addresses"][name],
        )
    # `observed_at_block` is provenance rather than a comparison, because the head moves. Every
    # other fact is exact, and a difference is drift to account for rather than to absorb.
    for group in ("live_staking", "governance_and_regent_safe"):
        for fact, wanted in committed["external_observation"][group].items():
            compare(f"{group}.{fact}", wanted, observed["external_observation"][group][fact])

if problems:
    print("EXTERNAL STATE RECONCILIATION FAILED", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    raise SystemExit(1)

print(f"binding identity: all {len(bindings)} live bindings match {observations_path} exactly")
if mode == "--rehearse":
    print("selection: the seven predicted addresses re-derive from the committed packet exactly")
    print("external observation: the live staking and Safe facts match the committed packet exactly")
else:
    open(observed_path, "w", encoding="utf-8").write(json.dumps(observed, indent=2, sort_keys=True) + "\n")
    print("selection and external observation captured for the packet candidate below")
PYTHON
fi

if [ "$mode" = --rehearse ]; then
    # ---------------------------------------------------------------------------
    section "The exact deployment script, simulated and never broadcast"
    # ---------------------------------------------------------------------------

    # The same file an authorized ceremony would run, against the same chain, consuming the same
    # three committed values — and stopping exactly where a signature would begin. No `--broadcast`,
    # no `--private-key`, no `--account`, no `--ledger`, no `--interactive`, no sender: without them
    # Foundry simulates the sequence and sends nothing. What it proves is the script's own checks
    # against live state — the deployer's nonce, the salt's five permission bits, each creation's
    # predicted address, the factory's strategy()/hook() readbacks. A mismatch reverts, which is a
    # stop.
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

if [ "$mode" != --prepare ]; then
    # ---------------------------------------------------------------------------
    section "Ledger reconciliation"
    # ---------------------------------------------------------------------------

    # Every mapped deployment selector must be listed once by Foundry's own compiled listing, must
    # have executed exactly once in this run, and must have passed. Preparation closes no claim, so
    # it never reaches here.
    python3 "$checker" ledger \
        --ledger "$ledger" \
        --spec SPEC.md \
        --gates "$GATES" \
        --test-list "$test_list" \
        --test-report "$ceremony_report" \
        --receipt "$receipt"
fi

# ---------------------------------------------------------------------------
section "Deterministic mainnet-NO-GO packet"
# ---------------------------------------------------------------------------

# The ceremony emits its measured graph as decoded logs; Solidity has no filesystem permission and
# cannot write a packet for itself. This renders one from those measurements, reconciles every
# measured byte count and initcode hash against the frozen release surface, and then either compares
# the render byte for byte against the committed packet or — in preparation — writes it as a
# candidate. This gate can fail an installed packet and can produce one for review; it can never
# install one.
if [ "$mode" = --prepare ]; then
    state_source=$observed_state
else
    state_source=$packet
fi

python3 - "$mode" "$ceremony_report" "$sizes" "$frozen" "$state_source" "$rendered" "$packet" <<'PYTHON'
import hashlib
import json
import sys

mode, report_path, sizes_path, frozen_path, state_path, rendered_path, packet_path = sys.argv[1:8]

EIP170 = 24_576
EIP3860 = 49_152

# A guardrail on the in-EVM creation gas DEP-074 measures. The packet's own gas note explains why
# that figure is a floor rather than a transaction cost.
IN_EVM_CREATION_GAS_GUARDRAIL = 14_000_000

# The two immutable identities the packet names apart, from README.md's own record.
PRODUCTION_AUTHORITY_COMMIT = "9eb3a7257a96e781b4a3d115e881d50acd496216"
PRODUCTION_AUTHORITY_TREE = "abb3a2894f60e1335a38f38be4902d1d9002a083"
SHARED_SRC_TREE = "2ffbc27e93a7d0fbf46ec8281b8e4b08fc7a4f7b"
FORK_EVIDENCE_COMMIT = "aa97e4189835abdf16c4771513c296adcb4abd95"

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

# The two mutable sections. In preparation they come from what this run observed live; otherwise
# they come from the committed packet, which is the sole committed ceremony authority.
state = json.load(open(state_path, encoding="utf-8"))
chosen = state["selection"] or {}

document = {
    "artifact": "regents-autolaunch-base-mainnet-deployment-packet",
    "version": 1,
    "status": "mainnet-NO-GO",
    "authorization": {
        "state": "not authorized",
        "instrument": "a founder GO_TO_DEPLOY naming this packet's exact digest",
        "granted_by": None,
        "signing_method": None,
        "note": (
            "Nothing in this repository may be signed, broadcast, funded, or deployed until the "
            "founder separately approves this exact digest. That approval is a separate decision "
            "outside this candidate. The signing method is recorded at that point by name; its "
            "credential never appears in this packet or anywhere in this repository."
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
        "note": (
            "The founder-selected disposable deployer, its starting nonce read from Base, the hook "
            "salt mined once against the predicted factory and strategy, and the seven addresses "
            "those three determine. Null until `bin/deployment-gate.sh --prepare <deployer>` "
            "derives them and a human installs the packet candidate it writes; while it is null "
            "this packet cannot claim the exact ceremony was rehearsed. A completed ceremony moves "
            "the deployer five nonces past this one, so this packet is single-use."
        ),
    },
    "external_observation": state["external_observation"],
    "external_observation_note": (
        "The mutable external state a deployment depends on: the live staking owner, pause state "
        "and USDC binding, and the Governance/Regent Safe's exact owners, threshold, guard, "
        "modules, module page terminator, fallback handler, singleton and version. Frozen by "
        "`bin/deployment-gate.sh --prepare` and compared exactly by `--rehearse`, which also holds "
        "every frozen binding's runtime and proxy identity to reports/frozen/fork-observations.json "
        "and re-asserts the CCA zero fee controller and the USDC pause and blacklist policy. "
        "`observed_at_block` is provenance, not a comparison, because the head moves."
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

if mode == "--prepare":
    print(f"packet candidate: {rendered_path}")
    print(f"candidate digest: {document['digest']['value']}")
    print(f"candidate status: {document['status']}")
elif open(packet_path, encoding="utf-8").read() != rendered:
    raise SystemExit(
        f"the committed packet at {packet_path} is not what this candidate renders. A reviewable "
        f"candidate is at {rendered_path}; read it, install it deliberately, and commit it."
    )
else:
    print(f"packet: {packet_path} is byte-identical to this run's render")
    print(f"packet digest: {document['digest']['value']}")
    print(f"packet status: {document['status']}")
PYTHON

# ---------------------------------------------------------------------------
section "The deployed manifest stays separate and unpopulated"
# ---------------------------------------------------------------------------

# The packet is a proposal; the manifest is a record of confirmed Base receipts. Two files is not
# enough on its own, so the manifest is proved empty here: a simulated address, a rehearsal
# transaction hash, or a fork block number reaching it fails this gate.
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
printf '\nMAINNET NO-GO. Nothing was signed, broadcast, deployed, funded, or moved.\n'

if [ "$mode" = --prepare ]; then
    cat <<'TRANSITION'
This run closed no claim and installed nothing. Before the candidate above becomes authority,
check the deployer address, its nonce and balance, the mined salt and the seven predicted
addresses against an independent derivation, and every control-surface value against an
independent source. Then install it as the committed packet, re-render with --offline, commit,
and rehearse with --rehearse.
TRANSITION
    printf 'DEPLOYMENT PREPARATION CANDIDATE\n'
else
    printf 'DEPLOYMENT GATE PASS\n'
fi
