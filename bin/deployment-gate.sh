#!/bin/sh
# Deployment-ceremony gate for autolaunch-contracts.
#
# This entrypoint is NOT the required gate. `bin/gate.sh` is. This one proves the `deployment`
# gate alone: the five direct, zero-value creation transactions a founder-selected disposable
# deployer would send to put the Autolaunch graph on Base, and nothing else.
#
# It has exactly two modes, and the difference between them is a provider and nothing else.
#
#   --offline    The writer's mode, and the one that carries this candidate's evidence. It runs
#                with `FOUNDRY_OFFLINE=true` and with the Base endpoint variable cleared from the
#                child environment, so no network can be reached even by accident. The whole
#                ceremony is decidable this way: the five creations call no external contract, and
#                the one frozen address the graph binds is compared rather than called.
#
#   --rehearse   The chief's mode, run only under the founder's separate read-only Base authority
#                and only after this candidate has been independently reviewed. It runs the same
#                ceremony selectors against a read-only Base fork and adds the external-state
#                preflight, which re-reads the frozen identities, the CCA fee controller, the live
#                staking and USDC policy, and the exact Regent Safe control surface.
#
# The boundary is hard in both modes. Nothing here signs, broadcasts, deploys, funds, requests a
# wallet, writes to a provider, or moves value; `forge script --broadcast` is never invoked and
# this file contains no such invocation. A signing variable in the environment is a stop, not a
# warning. A dotenv file in the worktree is a stop too, because Foundry would load it into the
# process environment and the ceremony reads three of its parameters from there — so this gate
# refuses to run beside one rather than reading one.
#
# Both modes end at mainnet NO-GO. The packet this renders is a proposal: only a later founder
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

# The preflight carries no requirement id and closes nothing, so it is excluded by name from the
# compiled listing and from the ledger reconciliation in both modes, exactly as `bin/fork-gate.sh`
# excludes its discovery pass.
PREFLIGHT_CONTRACT=DeploymentPreflightTest

frozen=requirements/frozen-identity.json
ledger=requirements/ledger.toml
sizes=reports/frozen/deployable-sizes.json
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

mode=${1:-}
case "$mode" in
    --offline)
        FOUNDRY_OFFLINE=true
        export FOUNDRY_OFFLINE
        # Cleared rather than merely unused: an offline run must be incapable of reaching Base,
        # not merely uninterested in it.
        unset "$RPC_ENV" 2>/dev/null || :
        expect_offline=true
        ;;
    --rehearse)
        expect_offline=false
        ;;
    *) fail "a mode is required; use --offline or --rehearse" ;;
esac

# ---------------------------------------------------------------------------
section "Authority and signing boundary"
# ---------------------------------------------------------------------------

command -v git >/dev/null 2>&1 || fail "git is not on PATH"
command -v forge >/dev/null 2>&1 || fail "forge is not on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 is not on PATH"

for required_file in "$frozen" "$ledger" "$sizes" "$checker" "$script" "$packet" "$manifest" \
    test-deployment/DeploymentCeremony.t.sol test-deployment/DeploymentPreflight.t.sol; do
    [ -f "$required_file" ] || fail "required deployment material is missing: $required_file"
done

# No signing authority may be anywhere near this run, in either mode. This is a superset of the
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

if [ "$mode" = --rehearse ]; then
    # The endpoint is consumed, never printed. Only its presence and its shape are ever reported,
    # and the refusal happens here, before any harness can start and before anything is dialled.
    eval "endpoint=\${$RPC_ENV:-}"
    [ -n "$endpoint" ] ||
        fail "no read-only Base provider is injected under $RPC_ENV; the rehearsal cannot claim a fork"
    case "$endpoint" in
        http://?* | https://?* | ws://?* | wss://?*) : ;;
        *) fail "the value injected under $RPC_ENV is not an http(s) or ws(s) endpoint; its value is never printed" ;;
    esac
    unset endpoint
    printf 'a read-only Base endpoint is injected under %s and is never printed or persisted\n' "$RPC_ENV"
else
    printf 'no provider is reachable: FOUNDRY_OFFLINE is true and %s is cleared from this run\n' "$RPC_ENV"
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
test_list="$generated/forge-test-list.json"
ceremony_report="$generated/forge-test-ceremony.json"
ceremony_log="$generated/forge-test-ceremony.log"
preflight_report="$generated/forge-test-preflight.json"
preflight_log="$generated/forge-test-preflight.log"
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

# ---------------------------------------------------------------------------
section "Compiled listing of the mapped ceremony selectors"
# ---------------------------------------------------------------------------

FOUNDRY_OFFLINE=true forge test --list --json --no-match-contract "$PREFLIGHT_CONTRACT" >"$test_list"

# ---------------------------------------------------------------------------
section "The five-creation ceremony"
# ---------------------------------------------------------------------------

# `-vv` is load-bearing rather than cosmetic: Foundry only populates each result's `decoded_logs`
# at that verbosity, and the packet below is rendered from exactly that field.
ceremony_status=0
if [ "$mode" = --rehearse ]; then
    RUST_LOG=error forge test --json -vv --no-match-contract "$PREFLIGHT_CONTRACT" --fork-url "$RPC_ALIAS" \
        >"$ceremony_report" 2>"$ceremony_log" || ceremony_status=$?
else
    RUST_LOG=error forge test --json -vv --no-match-contract "$PREFLIGHT_CONTRACT" \
        >"$ceremony_report" 2>"$ceremony_log" || ceremony_status=$?
fi
scan_then_display "$ceremony_log"
[ "$ceremony_status" -eq 0 ] ||
    fail "the ceremony run exited $ceremony_status; its scanned diagnostics are retained under $generated"

if [ "$mode" = --rehearse ]; then
    # ---------------------------------------------------------------------------
    section "Authorized read-only external-state preflight"
    # ---------------------------------------------------------------------------

    preflight_status=0
    RUST_LOG=error forge test --json -vv --match-contract "$PREFLIGHT_CONTRACT" --fork-url "$RPC_ALIAS" \
        >"$preflight_report" 2>"$preflight_log" || preflight_status=$?
    scan_then_display "$preflight_log"
    [ "$preflight_status" -eq 0 ] ||
        fail "the external-state preflight exited $preflight_status; a ceremony against this chain state is a stop"

    # A preflight that produced no result did not observe Base, and a gate that accepted that
    # would be claiming a fork it never opened.
    python3 - "$preflight_report" "$PREFLIGHT_CONTRACT" <<'PYTHON'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
executed = sum(len(result.get("test_results", {})) for result in report.values())
if executed == 0:
    raise SystemExit(f"the preflight report contains no executed {sys.argv[2]} result; no fork was observed")
print(f"external-state preflight: {executed} live Base observation(s), all passing")
PYTHON
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
python3 - "$ceremony_report" "$sizes" "$frozen" "$rendered" "$packet" <<'PYTHON'
import hashlib
import json
import sys

report_path, sizes_path, frozen_path, rendered_path, packet_path = sys.argv[1:6]

EIP170 = 24_576
EIP3860 = 49_152

# A guardrail on the in-EVM creation gas DEP-074 measures, and deliberately not a transaction-gas
# result: that measurement excludes the intrinsic cost, the initcode calldata cost and EIP-3860's
# per-word charge a real creation transaction carries, so it is only ever a floor.
IN_EVM_CREATION_GAS_GUARDRAIL = 14_000_000

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
            "founder separately approves this exact digest. The signing method is recorded at that "
            "point by name; its credential never appears in this packet or anywhere in this "
            "repository."
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
        "deployer": None,
        "starting_nonce": None,
        "hook_salt": None,
        "predicted_addresses": None,
        "note": (
            "No deployer has been selected. Every address this ceremony produces is a function of "
            "that account and its exact nonce, so the graph is derivable but not yet determined. "
            "Selecting a deployer, reading its live nonce, mining the hook salt once against the "
            "predicted factory and strategy, and re-rendering this packet is the step that fills "
            "this section in."
        ),
    },
    "external_observation": None,
    "external_observation_note": (
        "No provider was accessed while preparing this packet. The external-state preflight — the "
        "frozen binding identities, the CCA zero fee controller, the live staking owner, pause and "
        "USDC binding, the mutable USDC pause and blacklist policy, and the exact Regent Safe "
        "owners, threshold, guard, modules and fallback handler — runs under "
        "`bin/deployment-gate.sh --rehearse` on the founder's separate read-only Base authority."
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
printf '\nMAINNET NO-GO. Nothing was signed, broadcast, deployed, funded, or moved.\n'
printf 'DEPLOYMENT GATE PASS\n'
