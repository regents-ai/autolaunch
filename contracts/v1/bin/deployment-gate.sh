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
#   --selftest-stale-source   The production-source authority regression. It reaches no network.
#   --selftest-stale-receipt  The absent/stale fork-check receipt regression. It reaches no network.
#   --selftest-receipt-paths  The exact retained-report path boundary's regression. It reaches no network.
#   --selftest-receipt-substitution  The single-snapshot continuity regression. It reaches no network.
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

GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_REPLACE_OBJECTS

for git_context in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_CEILING_DIRECTORIES \
    GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_QUARANTINE_PATH GIT_SHALLOW_FILE GIT_GRAFT_FILE \
    GIT_REPLACE_REF_BASE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG_SYSTEM \
    GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_EXEC_PATH GIT_PREFIX; do
    eval "git_context_value=\${$git_context:-}"
    [ -z "$git_context_value" ] || {
        printf 'DEPLOYMENT GATE FAIL: ambient Git context override %s is set\n' "$git_context" >&2
        exit 1
    }
done
unset git_context_value

# The V1 project is the contracts/v1 component of the Autolaunch repository. The script root is
# proved to be exactly that directory under the Git top level. Nothing is discovered from the
# layout: a repository rooted at the component, a copy of this tree at the top level, or any other
# directory is rejected here, before Git is consulted for anything else.
component=contracts/v1
cd "$(dirname "$0")/.."
physical_root=$(pwd -P)
command -v git >/dev/null 2>&1 || {
    printf 'DEPLOYMENT GATE FAIL: git is not on PATH\n' >&2
    exit 1
}
git_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    printf 'DEPLOYMENT GATE FAIL: the physical script root is not inside a Git worktree\n' >&2
    exit 1
}
git_root=$(cd "$git_root" && pwd -P)
[ "$git_root/$component" = "$physical_root" ] || {
    printf 'DEPLOYMENT GATE FAIL: the physical script root is not %s under the Git top level\n' "$component" >&2
    exit 1
}
cd "$physical_root"

FOUNDRY_PROFILE=deployment
GIT_TERMINAL_PROMPT=0
PYTHONDONTWRITEBYTECODE=1
export FOUNDRY_PROFILE GIT_TERMINAL_PROMPT PYTHONDONTWRITEBYTECODE

# The only gate this entrypoint proves.
GATES=deployment

RPC_ALIAS=base
RPC_ENV=REGENT_BASE_RPC_URL
CHAIN_ID=8453
PROBE_REFUSAL="the configured $RPC_ALIAS endpoint did not answer a read-only chain-id probe with exactly $CHAIN_ID"

PRODUCTION_AUTHORITY_COMMIT=f4114f5276386f48bf8dc53ee344189d98c8896e
PRODUCTION_AUTHORITY_TREE=bb660324bb1d5cc322adeb243b0bd51779821fcb
PRODUCTION_AUTHORITY_SRC_TREE=91a741e417b75706a4071f7bdac2c5e13548c0fc
# Filled with the exact clean B' commit only after the founder's fork check writes a successful
# receipt for it. A preparation run cannot proceed while this sentinel remains.
FORK_EVIDENCE_COMMIT=ea8c81b2a5724213d3aeb4b0d81885b932f7d1aa
# Both authorities predate the contracts/v1 layout and carry src/ at the root of their own trees.
# They are historical Git objects read at their recorded path for evidence verification only; the
# candidate checkout is always read at $component/src.
PRODUCTION_AUTHORITY_SRC_PATH=src
FORK_EVIDENCE_SRC_PATH=src

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
fork_receipt=reports/generated/fork/fork-check-receipt.json
fork_pinned_report=reports/generated/fork/forge-test-pinned.json
fork_later_report=reports/generated/fork/forge-test-later.json
fork_test_list=reports/generated/fork/forge-test-list.json
offline_receipt=reports/generated/dependency-receipt.txt

fail() {
    printf 'DEPLOYMENT GATE FAIL: %s\n' "$*" >&2
    exit 1
}

reject_replace_refs() {
    replacement_refs=$(
        {
            git for-each-ref --format='ticket repository: %(refname)' refs/replace/
            git submodule foreach --quiet --recursive \
                'git for-each-ref --format="recursive submodule $displaypath: %(refname)" refs/replace/'
        }
    ) || fail "could not inspect replacement refs in the ticket repository and initialized recursive submodules"
    [ -z "$replacement_refs" ] || fail "Git replacement refs are forbidden:
$replacement_refs"
}

reject_replace_refs

fork_receipt_snapshot=
cleanup_receipt_snapshot() {
    [ -z "${fork_receipt_snapshot:-}" ] || rm -f "$fork_receipt_snapshot"
}
trap cleanup_receipt_snapshot EXIT
trap 'cleanup_receipt_snapshot; exit 1' HUP INT TERM

snapshot_receipt() {
    source_path=$1
    snapshot_path=$2
    python3 - "$source_path" "$snapshot_path" <<'PYTHON'
import hashlib
import os
import stat
import sys

source, destination = sys.argv[1:]
try:
    metadata = os.lstat(source)
except FileNotFoundError:
    raise SystemExit(f"the successful fork-check receipt is absent: {source}")
if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
    raise SystemExit(f"fork-check receipt must be a regular non-symlink file: {source}")
source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    chunks = []
    while True:
        block = os.read(source_fd, 1024 * 1024)
        if not block:
            break
        chunks.append(block)
finally:
    os.close(source_fd)
data = b"".join(chunks)
destination_fd = os.open(destination, os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0))
try:
    os.write(destination_fd, data)
finally:
    os.close(destination_fd)
os.chmod(destination, stat.S_IRUSR)
print(hashlib.sha256(data).hexdigest())
PYTHON
}

# The production commit, its full tree, its src tree, and this checkout's src tree are one authority
# comparison. The stale-source regression calls this exact function with a mismatched recorded src
# tree and must stop before any pass marker.
verify_source_authority() {
    recorded_src=$1
    git cat-file -e "$PRODUCTION_AUTHORITY_COMMIT^{commit}" 2>/dev/null ||
        fail "production authority commit $PRODUCTION_AUTHORITY_COMMIT does not exist locally"

    found_tree=$(git rev-parse "$PRODUCTION_AUTHORITY_COMMIT^{tree}")
    [ "$found_tree" = "$PRODUCTION_AUTHORITY_TREE" ] ||
        fail "production authority tree mismatch: expected $PRODUCTION_AUTHORITY_TREE, found $found_tree"

    found_src=$(git rev-parse "$PRODUCTION_AUTHORITY_COMMIT:$PRODUCTION_AUTHORITY_SRC_PATH")
    [ "$found_src" = "$recorded_src" ] ||
        fail "production source tree mismatch: recorded $recorded_src, found $found_src"

    checkout_src=$(git rev-parse "HEAD:$component/src")
    [ "$checkout_src" = "$recorded_src" ] ||
        fail "candidate source tree mismatch: recorded $recorded_src, found $checkout_src"
}

# The deployment packet may consume only a successful fork check against the exact evidence commit
# its renderer names. The receipt lives in ignored scratch, but its commit/tree/src identity and all
# retained report hashes are independently re-derived here, and the current checkout must separately
# be clean before this function is called.
verify_fork_receipt() {
    receipt_path=$1
    # The fork evidence commit is read at its own recorded src path. A caller naming another commit
    # names that commit's src path with it; the regressions below name this checkout's component.
    expected_commit=${2:-$FORK_EVIDENCE_COMMIT}
    expected_src_path=${3:-$FORK_EVIDENCE_SRC_PATH}
    [ $# -ne 2 ] || fail "verify_fork_receipt: a caller-named commit needs its src path"

    [ -e "$receipt_path" ] || fail "the successful fork-check receipt is absent: $receipt_path"
    git cat-file -e "$expected_commit^{commit}" 2>/dev/null ||
        fail "the renderer's fork evidence authority is not a commit in this repository: $expected_commit"
    expected_tree=$(git rev-parse "$expected_commit^{tree}")
    expected_src=$(git rev-parse "$expected_commit:$expected_src_path")

    python3 - "$receipt_path" "$expected_commit" "$expected_tree" "$expected_src" \
        "$physical_root" "$fork_pinned_report" "$fork_later_report" "$fork_test_list" \
        "$ledger" "$observations" <<'PYTHON'
import hashlib
import json
import os
import stat
import sys
import tomllib

(
    path,
    expected_commit,
    expected_tree,
    expected_src,
    repo_root,
    pinned_path,
    later_path,
    list_path,
    ledger_path,
    observations_path,
) = sys.argv[1:]
problems = []


def regular_not_symlink(candidate, label):
    try:
        metadata = os.lstat(candidate)
    except FileNotFoundError:
        problems.append(f"{label} is absent: {candidate}")
        return False
    if stat.S_ISLNK(metadata.st_mode):
        problems.append(f"{label} must not be a symlink: {candidate}")
        return False
    if not stat.S_ISREG(metadata.st_mode):
        problems.append(f"{label} is not a regular file: {candidate}")
        return False
    return True


if not regular_not_symlink(path, "fork-check receipt"):
    receipt = {}
else:
    receipt = json.load(open(path, encoding="utf-8"))
identity = receipt.get("tested_identity") or {}
counts = receipt.get("executed_selectors") or {}

expected = {
    "artifact": "regent-fork-check-receipt",
    "version": 1,
    "status": "passed",
    "worktree": "clean",
}
for key, wanted in expected.items():
    if receipt.get(key) != wanted:
        problems.append(f"receipt {key}: expected [{wanted}], found [{receipt.get(key)}]")
for key, wanted in (("commit", expected_commit), ("tree", expected_tree), ("src_tree", expected_src)):
    if identity.get(key) != wanted:
        problems.append(f"receipt {key} mismatch: expected [{wanted}], found [{identity.get(key)}]")

# Do not touch paths named by a receipt until its authority and fixed shape are exact.
if problems:
    print("FORK RECEIPT RECONCILIATION FAILED", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    raise SystemExit(1)

reports = receipt.get("reports") or {}
expected_reports = {
    "pinned": pinned_path,
    "later": later_path,
    "compiled_test_list": list_path,
}
if set(reports) != set(expected_reports):
    problems.append(
        f"receipt report keys: expected {sorted(expected_reports)}, found {sorted(reports)}"
    )

canonical_repo = os.path.realpath(repo_root)
declared_canonical_targets = []
for label, exact_path in expected_reports.items():
    row = reports.get(label) or {}
    report_path = row.get("path")
    wanted_hash = row.get("sha256")
    if isinstance(report_path, str):
        declared_canonical_targets.append(os.path.realpath(report_path))
    if report_path != exact_path:
        problems.append(f"receipt report {label} path: expected [{exact_path}], found [{report_path}]")
        continue
    if not regular_not_symlink(report_path, f"receipt report {label}"):
        continue
    canonical = os.path.realpath(report_path)
    canonical_expected = os.path.join(canonical_repo, exact_path)
    if canonical != canonical_expected:
        problems.append(
            f"receipt report {label} canonical target: expected [{canonical_expected}], found [{canonical}]"
        )
        continue
    found_hash = hashlib.sha256(open(report_path, "rb").read()).hexdigest()
    if found_hash != wanted_hash:
        problems.append(f"receipt report {label} hash mismatch: expected [{wanted_hash}], found [{found_hash}]")

if len(declared_canonical_targets) != len(set(declared_canonical_targets)):
    problems.append("receipt report paths resolve to duplicate canonical targets")

if problems:
    print("FORK RECEIPT RECONCILIATION FAILED", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    raise SystemExit(1)


def listed_selectors(candidate):
    found = []
    for contracts in json.load(open(candidate, encoding="utf-8")).values():
        for names in contracts.values():
            found.extend(names)
    return found


def executed_selectors(candidate):
    found = {}
    for suite in json.load(open(candidate, encoding="utf-8")).values():
        for signature, outcome in suite.get("test_results", {}).items():
            selector = signature.split("(", 1)[0]
            if selector in found:
                problems.append(f"{candidate}: selector executed more than once: {selector}")
            found[selector] = outcome
    return found


ledger_document = tomllib.load(open(ledger_path, "rb"))
fork_claims = [
    row for row in ledger_document["requirement"]
    if row.get("gate") == "fork" and row.get("status") == "active"
]
claim_keys = [row.get("id") for row in fork_claims]
if len(claim_keys) != 18 or len(set(claim_keys)) != 18:
    problems.append(f"local ledger fork claim keys: expected 18 unique, found {len(set(claim_keys))}")

expected_pinned = set()
expected_later = set()
for row in fork_claims:
    selectors = row.get("selectors") or []
    if not selectors:
        problems.append(f"local ledger fork claim {row.get('id')} has no selector")
    for selector in selectors:
        if "ForkPinned" in selector:
            expected_pinned.add(selector)
        elif "ForkLatest" in selector:
            expected_later.add(selector)
        else:
            problems.append(f"local ledger fork selector names neither header: {selector}")

pinned = executed_selectors(pinned_path)
later = executed_selectors(later_path)
listed = listed_selectors(list_path)
if len(listed) != len(set(listed)):
    problems.append("compiled fork test list contains duplicate selectors")
if set(pinned) != expected_pinned:
    problems.append(
        f"pinned report selectors differ from the local ledger: expected {len(expected_pinned)}, found {len(pinned)}"
    )
if set(later) != expected_later:
    problems.append(
        f"later report selectors differ from the local ledger: expected {len(expected_later)}, found {len(later)}"
    )
if set(listed) != expected_pinned | expected_later:
    problems.append(
        f"compiled fork test list differs from the local ledger: expected {len(expected_pinned | expected_later)}, "
        f"found {len(set(listed))}"
    )
for report_path, outcomes in ((pinned_path, pinned), (later_path, later)):
    for selector, outcome in outcomes.items():
        if outcome.get("status") != "Success":
            problems.append(f"{report_path}: {selector} reported {outcome.get('status')}")

derived_counts = {
    "pinned": len(pinned),
    "later": len(later),
    "total": len(pinned) + len(later),
}
if derived_counts != {"pinned": 18, "later": 9, "total": 27}:
    problems.append(f"retained report selector counts: expected 18+9=27, found {derived_counts}")
if counts != derived_counts:
    problems.append(f"receipt-declared selector counts {counts} differ from rederived {derived_counts}")

observation = json.load(open(observations_path, encoding="utf-8"))
binding_identities = dict(observation.get("bindings") or {})
if "permit2" in binding_identities:
    problems.append("frozen observation duplicates the permit2 binding identity")
binding_identities["permit2"] = observation.get("permit2")
required_identity_fields = {
    "address",
    "runtime_bytes",
    "runtime_code_hash",
    "proxy_family",
    "implementation",
    "implementation_code_hash",
    "implementation_runtime_bytes",
}
if len(binding_identities) != 9:
    problems.append(f"frozen observation binding identities: expected 9, found {len(binding_identities)}")
for binding, facts in binding_identities.items():
    if not isinstance(facts, dict):
        problems.append(f"frozen observation binding {binding} is not an identity object")
        continue
    missing = required_identity_fields - set(facts)
    if missing:
        problems.append(f"frozen observation binding {binding} lacks {sorted(missing)}")


def verdicts(outcomes, header):
    found = {}
    for outcome in outcomes.values():
        for entry in outcome.get("decoded_logs") or []:
            if not entry.startswith("verdict "):
                continue
            label, _, decision = entry.partition(": ")
            parts = label.split(" ")
            if len(parts) != 3 or parts[2] != header:
                continue
            claim = parts[1]
            if claim in found and found[claim] != decision:
                problems.append(f"{header} verdict {claim} has conflicting decisions")
            found[claim] = decision
    return found


pinned_verdicts = verdicts(pinned, "pinned")
later_verdicts = verdicts(later, "later")
required_later = {"DEP-040", "DEP-041", "DEP-042", "DEP-043", "DEP-047", "DEP-051", "DEP-052", "GAS-006"}
expected_dep_050 = {
    "DEP-050.chain": "chain-id=base",
    "DEP-050.cca-code": "cca-runtime=frozen",
    "DEP-050.cca-controller": "controller=zero",
}
empty_bindings = []
for binding, facts in (observation.get("bindings") or {}).items():
    expected_dep_050[f"DEP-050.binding.{binding}"] = "code-presence=expected"
    if facts.get("runtime_bytes") == 0:
        empty_bindings.append(binding)
        continue
    expected_dep_050[f"DEP-050.codehash.{binding}"] = "codehash=committed"
    expected_dep_050[f"DEP-050.proxy.{binding}"] = f"family={facts.get('proxy_family')}"
    expected_dep_050[f"DEP-050.implementation.{binding}"] = "implementation=committed"
    expected_dep_050[f"DEP-050.implementation-code.{binding}"] = "implementation-codehash=committed"
if empty_bindings != ["dead_address"]:
    problems.append(f"frozen dead-address exception: expected ['dead_address'], found {empty_bindings}")

pinned_dep_050 = {key: value for key, value in pinned_verdicts.items() if key.startswith("DEP-050.")}
later_dep_050 = {key: value for key, value in later_verdicts.items() if key.startswith("DEP-050.")}
if pinned_dep_050 != expected_dep_050:
    missing = sorted(set(expected_dep_050) - set(pinned_dep_050))
    extra = sorted(set(pinned_dep_050) - set(expected_dep_050))
    wrong = sorted(
        key for key in set(expected_dep_050) & set(pinned_dep_050)
        if expected_dep_050[key] != pinned_dep_050[key]
    )
    problems.append(f"pinned DEP-050 schema/decisions differ: missing={missing}, extra={extra}, wrong={wrong}")
if later_dep_050 != expected_dep_050:
    missing = sorted(set(expected_dep_050) - set(later_dep_050))
    extra = sorted(set(later_dep_050) - set(expected_dep_050))
    wrong = sorted(
        key for key in set(expected_dep_050) & set(later_dep_050)
        if expected_dep_050[key] != later_dep_050[key]
    )
    problems.append(f"later DEP-050 schema/decisions differ: missing={missing}, extra={extra}, wrong={wrong}")

expected_later_verdicts = required_later | set(expected_dep_050)
if set(later_verdicts) != expected_later_verdicts:
    problems.append(
        f"later normalized verdict keys differ: expected {len(expected_later_verdicts)}, found {len(later_verdicts)}"
    )
for claim in required_later - set(pinned_verdicts):
    problems.append(f"pinned normalized verdict is absent for {claim}")
for claim in expected_later_verdicts & set(pinned_verdicts) & set(later_verdicts):
    if pinned_verdicts[claim] != later_verdicts[claim]:
        problems.append(f"normalized verdict disagreement for {claim}")

observed_binding_ids = set(observation.get("bindings") or {})
verdict_binding_ids = {
    claim.removeprefix("DEP-050.binding.")
    for claim in pinned_dep_050
    if claim.startswith("DEP-050.binding.")
}
if verdict_binding_ids != observed_binding_ids:
    problems.append(
        f"DEP-050 verdict binding ids differ from the eight ordinary frozen bindings: "
        f"expected {sorted(observed_binding_ids)}, found {sorted(verdict_binding_ids)}"
    )

if problems:
    print("FORK RECEIPT EVIDENCE RECONCILIATION FAILED", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    raise SystemExit(1)

print(
    f"fork-check receipt: commit {expected_commit}, tree {expected_tree}, src {expected_src}; "
    f"three exact regular report paths and hashes; {len(claim_keys)} claim keys; "
    f"{len(binding_identities)} binding identities; selectors 18+9=27; normalized verdicts agree"
)
PYTHON

    python3 "$checker" ledger \
        --ledger "$ledger" \
        --spec SPEC.md \
        --gates fork \
        --test-list "$fork_test_list" \
        --test-report "$fork_pinned_report" "$fork_later_report" \
        --receipt "$offline_receipt"
}

# A passing mode also binds the committed packet and this run's render to the same A/B authority.
# Preparation has no pass marker and checks only its new render; offline and rehearsal check both.
verify_packet_authority() {
    receipt_path=$1
    receipt_sha=$2
    shift 2
    python3 - "$PRODUCTION_AUTHORITY_COMMIT" "$PRODUCTION_AUTHORITY_TREE" \
        "$PRODUCTION_AUTHORITY_SRC_TREE" "$FORK_EVIDENCE_COMMIT" "$receipt_path" "$receipt_sha" "$@" <<'PYTHON'
import hashlib
import json
import sys

production_commit, production_tree, source_tree, fork_commit, receipt_path, receipt_sha, *paths = sys.argv[1:]
receipt_bytes = open(receipt_path, "rb").read()
found_receipt_sha = hashlib.sha256(receipt_bytes).hexdigest()
receipt = json.loads(receipt_bytes)
problems = []
if found_receipt_sha != receipt_sha:
    problems.append(f"fork receipt snapshot digest expected [{receipt_sha}], found [{found_receipt_sha}]")
for path in paths:
    document = json.load(open(path, encoding="utf-8"))
    identities = document.get("immutable_identities", {})
    expected = {
        "production_authority_commit": production_commit,
        "production_authority_tree": production_tree,
        "shared_src_tree": source_tree,
        "fork_evidence_commit": fork_commit,
    }
    for key, wanted in expected.items():
        found = identities.get(key)
        if found != wanted:
            problems.append(f"{path}: {key} expected [{wanted}], found [{found}]")
    if document.get("fork_check_receipt") != receipt:
        problems.append(f"{path}: embedded fork-check receipt does not equal {receipt_path}")
    if document.get("fork_check_receipt_sha256") != receipt_sha:
        problems.append(f"{path}: embedded fork-check receipt digest does not equal the private snapshot")

if problems:
    print("PACKET AUTHORITY RECONCILIATION FAILED", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    raise SystemExit(1)

print(f"packet authority: {len(paths)} document(s) name the exact production and fork evidence identities")
PYTHON
}

section() {
    printf '\n=== %s ===\n' "$*"
}

# Git status is not the filesystem authority. This also compares tracked bytes directly, rejects
# hidden index flags and forces ignored recursive submodule dirt into the result.
repository_snapshot() {
    python3 - "$component" <<'PYTHON'
import hashlib
import os
import stat
import subprocess
import sys

# The proof covers the whole repository that contains the current directory, from its Git top
# level. Only the named component's generated roots are excluded from worktree state.
component = sys.argv[1]
os.chdir(subprocess.run(["git", "rev-parse", "--show-toplevel"], check=True, capture_output=True, text=True).stdout.rstrip("\n"))


def run(args, cwd=".", text=False):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=text).stdout


def read_indexed_blobs(repo, oids):
    ordered = list(dict.fromkeys(oids))
    if not ordered:
        return {}
    batch = subprocess.run(
        ["git", "cat-file", "--batch"],
        cwd=repo,
        input=("\n".join(ordered) + "\n").encode(),
        check=True,
        capture_output=True,
    ).stdout
    cursor = 0
    blobs = {}
    for wanted in ordered:
        line_end = batch.find(b"\n", cursor)
        if line_end < 0:
            raise ValueError(f"truncated indexed blob header for {wanted}")
        header = batch[cursor:line_end].decode().split()
        if len(header) != 3 or header[0] != wanted or header[1] != "blob":
            raise ValueError(f"unexpected indexed blob header for {wanted}")
        size = int(header[2])
        start = line_end + 1
        end = start + size
        if end >= len(batch) or batch[end:end + 1] != b"\n":
            raise ValueError(f"truncated indexed blob body for {wanted}")
        blobs[wanted] = batch[start:end]
        cursor = end + 1
    if cursor != len(batch):
        raise ValueError("unexpected trailing indexed blob data")
    return blobs


def verify_tracked_bytes(repo, label, digest):
    entries = []
    seen = set()
    for entry in run(["git", "ls-files", "-s", "-z"], cwd=repo).split(b"\0"):
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        mode, oid, stage = metadata.decode().split()
        path = os.fsdecode(raw_path)
        if stage != "0" or path in seen:
            problems.append(f"non-stage-zero index entry in {label}: {path}")
            continue
        seen.add(path)
        if mode != "160000":
            entries.append((mode, oid, raw_path, path))
    try:
        indexed_blobs = read_indexed_blobs(repo, [entry[1] for entry in entries])
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        problems.append(f"could not read raw indexed blobs in {label}: {error}")
        return
    for mode, oid, raw_path, path in entries:
        try:
            full_path = os.path.join(repo, path)
            found = os.lstat(full_path)
            if mode == "120000":
                if not stat.S_ISLNK(found.st_mode):
                    raise ValueError("expected a symbolic link")
                data = os.fsencode(os.readlink(full_path))
            else:
                if mode not in {"100644", "100755"}:
                    raise ValueError(f"unexpected indexed mode {mode}")
                if not stat.S_ISREG(found.st_mode) or stat.S_ISLNK(found.st_mode):
                    raise ValueError("expected a regular file")
                descriptor = os.open(full_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                try:
                    chunks = []
                    while True:
                        block = os.read(descriptor, 1024 * 1024)
                        if not block:
                            break
                        chunks.append(block)
                    data = b"".join(chunks)
                finally:
                    os.close(descriptor)
                executable = bool(found.st_mode & 0o111)
                if executable != (mode == "100755"):
                    raise ValueError("executable bits differ from the index")
            if data != indexed_blobs[oid]:
                raise ValueError("bytes differ from the indexed blob")
            digest.update(
                label.encode() + b"\0" + mode.encode() + b"\0" + raw_path + b"\0"
                + hashlib.sha256(data).digest()
            )
        except (FileNotFoundError, OSError, ValueError) as error:
            problems.append(f"tracked filesystem mismatch in {label}: {path}: {error}")


problems = []
ordinary = run(["git", "status", "--porcelain=v1", "--untracked-files=all"], text=True)
if ordinary:
    problems.extend(ordinary.rstrip("\n").splitlines())
scratch_roots = tuple(
    component.encode() + b"/" + root
    for root in (
        b"reports/generated/",
        b"cache/",
        b"cache-fork/",
        b"out/",
        b"out-fork/",
        b"artifacts/",
        b"broadcast/",
    )
)
ignored = run(["git", "ls-files", "-z", "--others", "--ignored", "--exclude-standard"]).split(b"\0")
for path in ignored:
    if path and not path.startswith(scratch_roots):
        problems.append("!! " + os.fsdecode(path))

flagged = [
    entry.decode("utf-8", errors="backslashreplace")
    for entry in run(["git", "ls-files", "-v", "-z"]).split(b"\0")
    if entry and (entry[:1] == b"S" or entry[:1].islower())
]
if flagged:
    problems.append("special index flags: " + ", ".join(flagged))

digest = hashlib.sha256()
verify_tracked_bytes(".", "ticket repository", digest)

for line in run(["git", "submodule", "status", "--recursive"], text=True).splitlines():
    if not line or line[0] != " ":
        problems.append("recursive submodule identity mismatch: " + line)
        continue
    parts = line[1:].split()
    if len(parts) < 2:
        problems.append("unparseable recursive submodule status: " + line)
        continue
    path = parts[1]
    state = run(
        ["git", "status", "--porcelain=v1", "--untracked-files=all", "--ignored=matching"],
        cwd=path,
        text=True,
    )
    if state:
        problems.append(f"recursive submodule dirt in {path}:\n{state.rstrip()}")
    sub_flags = [
        entry.decode("utf-8", errors="backslashreplace")
        for entry in run(["git", "ls-files", "-v", "-z"], cwd=path).split(b"\0")
        if entry and (entry[:1] == b"S" or entry[:1].islower())
    ]
    if sub_flags:
        problems.append(f"special index flags in recursive submodule {path}: " + ", ".join(sub_flags))
    verify_tracked_bytes(path, f"recursive submodule {path}", digest)
    digest.update(path.encode() + b"\0" + parts[0].encode())

if problems:
    print("\n".join(problems), file=sys.stderr)
    raise SystemExit(1)
print(digest.hexdigest())
PYTHON
}

require_clean_worktree() {
    repository_identity=$(repository_snapshot 2>&1) ||
        fail "the working tree is not one clean physical Git object:\n$repository_identity"
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
        # Exercise the production probe directly with the alias pointed at a closed loopback port.
        # The real endpoint is never read or passed on, no receipt is consumed, and no pass marker
        # can appear.
        section "Dead-endpoint regression"
        command -v cast >/dev/null 2>&1 || fail "cast is not on PATH; the chain-id probe cannot run"
        command -v python3 >/dev/null 2>&1 || fail "python3 is not on PATH"
        rm -rf "$generated"
        mkdir -p "$generated"
        probe_out="$generated/chain-id-probe.out"
        probe_err="$generated/chain-id-probe.err"
        selftest_status=0
        selftest_output=$(REGENT_BASE_RPC_URL="$DEAD_ENDPOINT" probe_base_chain_id 2>&1) || selftest_status=$?
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
    --selftest-stale-source)
        section "Stale-source regression"
        # First the exact authority: the production commit read at its recorded src path and this
        # checkout read at $component/src must carry one src tree. Then a stale recorded tree.
        verify_source_authority "$PRODUCTION_AUTHORITY_SRC_TREE"
        printf 'the production authority at %s and this checkout at %s/src carry one src tree\n' \
            "$PRODUCTION_AUTHORITY_SRC_PATH" "$component"
        stale_source=0000000000000000000000000000000000000000
        selftest_status=0
        selftest_output=$(verify_source_authority "$stale_source" 2>&1) || selftest_status=$?
        printf '%s\n' "$selftest_output"

        [ "$selftest_status" -ne 0 ] || fail "a stale recorded source tree exited 0; the boundary does not hold"
        case "$selftest_output" in
            *'DEPLOYMENT GATE PASS'*) fail "a stale recorded source tree printed this gate's pass marker" ;;
        esac
        case "$selftest_output" in
            *'production source tree mismatch'*) : ;;
            *) fail "the stale-source run stopped outside the production-source comparison" ;;
        esac

        printf '\nthe stale-source run exited %s at the production-source comparison and printed no pass marker\n' \
            "$selftest_status"
        printf 'DEPLOYMENT STALE-SOURCE REGRESSION PASS\n'
        exit 0
        ;;
    --selftest-stale-receipt)
        section "Absent/stale fork-check receipt regression"
        command -v git >/dev/null 2>&1 || fail "git is not on PATH"
        command -v python3 >/dev/null 2>&1 || fail "python3 is not on PATH"
        rm -rf "$generated"
        mkdir -p "$generated"

        absent_status=0
        absent_output=$(verify_fork_receipt "$generated/absent-fork-check-receipt.json" "$(git rev-parse HEAD)" "$component/src" 2>&1) || absent_status=$?
        printf '%s\n' "$absent_output"
        [ "$absent_status" -ne 0 ] || fail "an absent fork-check receipt exited 0"
        case "$absent_output" in
            *'successful fork-check receipt is absent'*) : ;;
            *) fail "the absent-receipt run stopped outside the receipt-presence comparison" ;;
        esac

        stale_receipt="$generated/stale-fork-check-receipt.json"
        python3 - "$stale_receipt" <<'PYTHON'
import json
import sys

document = {
    "artifact": "regent-fork-check-receipt",
    "version": 1,
    "status": "passed",
    "worktree": "clean",
    "tested_identity": {
        "commit": "0000000000000000000000000000000000000000",
        "tree": "0000000000000000000000000000000000000000",
        "src_tree": "0000000000000000000000000000000000000000",
    },
    "executed_selectors": {"pinned": 18, "later": 9, "total": 27},
    "reports": {},
}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(document, indent=2, sort_keys=True) + "\n")
PYTHON
        stale_status=0
        stale_output=$(verify_fork_receipt "$stale_receipt" "$(git rev-parse HEAD)" "$component/src" 2>&1) || stale_status=$?
        printf '%s\n' "$stale_output"
        [ "$stale_status" -ne 0 ] || fail "a stale fork-check receipt exited 0"
        case "$stale_output" in
            *'receipt commit mismatch'*) : ;;
            *) fail "the stale-receipt run stopped outside the receipt-identity comparison" ;;
        esac
        case "$absent_output$stale_output" in
            *'DEPLOYMENT GATE PASS'*) fail "an absent/stale receipt printed this gate's pass marker" ;;
        esac

        printf '\nabsent and stale receipts both failed closed and printed no pass marker\n'
        printf 'DEPLOYMENT STALE-RECEIPT REGRESSION PASS\n'
        exit 0
        ;;
    --selftest-receipt-paths)
        section "Fork-check receipt path regression"
        command -v python3 >/dev/null 2>&1 || fail "python3 is not on PATH"
        rm -rf "$generated" reports/generated/fork
        mkdir -p "$generated" reports/generated/fork
        current_commit=$(git rev-parse HEAD)
        current_tree=$(git rev-parse 'HEAD^{tree}')
        current_src=$(git rev-parse "HEAD:$component/src")

        valid_receipt="$generated/valid-fork-check-receipt.json"
        python3 - "$valid_receipt" "$current_commit" "$current_tree" "$current_src" \
            "$ledger" "$observations" "$fork_pinned_report" "$fork_later_report" "$fork_test_list" <<'PYTHON'
import hashlib
import json
import sys
import tomllib

receipt_path, commit, tree, src, ledger_path, observations_path, pinned_path, later_path, list_path = sys.argv[1:]
ledger = tomllib.load(open(ledger_path, "rb"))
claims = [row for row in ledger["requirement"] if row.get("gate") == "fork" and row.get("status") == "active"]
pinned = [selector for row in claims for selector in row["selectors"] if "ForkPinned" in selector]
later = [selector for row in claims for selector in row["selectors"] if "ForkLatest" in selector]

observation = json.load(open(observations_path, encoding="utf-8"))
required = ["DEP-040", "DEP-041", "DEP-042", "DEP-043", "DEP-047", "DEP-051", "DEP-052", "GAS-006"]
decisions = {
    "DEP-050.chain": "chain-id=base",
    "DEP-050.cca-code": "cca-runtime=frozen",
    "DEP-050.cca-controller": "controller=zero",
}
for binding, facts in observation["bindings"].items():
    decisions[f"DEP-050.binding.{binding}"] = "code-presence=expected"
    if facts["runtime_bytes"] == 0:
        continue
    decisions[f"DEP-050.codehash.{binding}"] = "codehash=committed"
    decisions[f"DEP-050.proxy.{binding}"] = f"family={facts['proxy_family']}"
    decisions[f"DEP-050.implementation.{binding}"] = "implementation=committed"
    decisions[f"DEP-050.implementation-code.{binding}"] = "implementation-codehash=committed"


def report(selectors, header):
    outcomes = {selector + "()": {"status": "Success", "decoded_logs": []} for selector in selectors}
    dep_selector = next(selector for selector in selectors if selector.startswith("test_DEP_050_"))
    outcomes[dep_selector + "()"]["decoded_logs"] = [
        *[f"verdict {key} {header}: decision={key}" for key in required],
        *[f"verdict {key} {header}: {value}" for key, value in decisions.items()],
    ]
    return {"test-fork/Synthetic.t.sol:SyntheticForkTest": {"test_results": outcomes}}


listing = {"test-fork/Synthetic.t.sol": {"SyntheticForkTest": pinned + later}}
for path, document in (
    (pinned_path, report(pinned, "pinned")),
    (later_path, report(later, "later")),
    (list_path, listing),
):
    open(path, "w", encoding="utf-8").write(json.dumps(document, sort_keys=True) + "\n")


def digest(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


receipt = {
    "artifact": "regent-fork-check-receipt",
    "version": 1,
    "status": "passed",
    "worktree": "clean",
    "tested_identity": {"commit": commit, "tree": tree, "src_tree": src},
    "executed_selectors": {"pinned": len(pinned), "later": len(later), "total": len(pinned) + len(later)},
    "reports": {
        "pinned": {"path": pinned_path, "sha256": digest(pinned_path)},
        "later": {"path": later_path, "sha256": digest(later_path)},
        "compiled_test_list": {"path": list_path, "sha256": digest(list_path)},
    },
}
open(receipt_path, "w", encoding="utf-8").write(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
PYTHON
        valid_output=$(verify_fork_receipt "$valid_receipt" "$current_commit" "$component/src" 2>&1) ||
            fail "a structurally valid retained-report fixture did not reconcile"
        printf '%s\n' "$valid_output"
        case "$valid_output" in
            *'18 claim keys; 9 binding identities; selectors 18+9=27; normalized verdicts agree'*) : ;;
            *) fail "the valid receipt fixture did not rederive every evidence fact" ;;
        esac

        python3 - "$valid_receipt" "$fork_pinned_report" <<'PYTHON'
import hashlib
import json
import sys

receipt_path, report_path = sys.argv[1:]
report = json.load(open(report_path, encoding="utf-8"))
removed = False
for suite in report.values():
    for outcome in suite.get("test_results", {}).values():
        logs = outcome.get("decoded_logs") or []
        kept = [line for line in logs if not line.startswith("verdict DEP-050.chain pinned:")]
        if len(kept) != len(logs):
            outcome["decoded_logs"] = kept
            removed = True
if not removed:
    raise SystemExit("synthetic fixture had no DEP-050.chain verdict to remove")
open(report_path, "w", encoding="utf-8").write(json.dumps(report, sort_keys=True) + "\n")
receipt = json.load(open(receipt_path, encoding="utf-8"))
receipt["reports"]["pinned"]["sha256"] = hashlib.sha256(open(report_path, "rb").read()).hexdigest()
open(receipt_path, "w", encoding="utf-8").write(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
PYTHON
        omitted_status=0
        omitted_output=$(verify_fork_receipt "$valid_receipt" "$current_commit" "$component/src" 2>&1) || omitted_status=$?
        printf '%s\n' "$omitted_output"
        [ "$omitted_status" -ne 0 ] || fail "an omitted DEP-050 verdict key exited 0"
        case "$omitted_output" in
            *'pinned DEP-050 schema/decisions differ: missing='*DEP-050.chain*) : ;;
            *) fail "the omitted DEP-050 key stopped outside the exact normalized-verdict schema" ;;
        esac
        case "$omitted_output" in
            *'DEPLOYMENT GATE PASS'*) fail "an omitted DEP-050 key printed this gate's pass marker" ;;
        esac
        printf 'omitted DEP-050 normalized-verdict key failed closed\n'

        run_path_case() {
            case_name=$1
            expected_message=$2
            candidate_receipt="$generated/$case_name.json"
            rm -rf reports/generated/fork
            mkdir -p reports/generated/fork

            case "$case_name" in
                traversal)
                    pinned_name=reports/generated/fork/../fork/forge-test-pinned.json
                    later_name=$fork_later_report
                    list_name=$fork_test_list
                    ;;
                duplicate)
                    pinned_name=$fork_pinned_report
                    later_name=$fork_pinned_report
                    list_name=$fork_test_list
                    ;;
                symlink)
                    printf '{}\n' >"$generated/symlink-target.json"
                    ln -s ../deployment/symlink-target.json "$fork_pinned_report"
                    printf '{}\n' >"$fork_later_report"
                    printf '{}\n' >"$fork_test_list"
                    pinned_name=$fork_pinned_report
                    later_name=$fork_later_report
                    list_name=$fork_test_list
                    ;;
                nonregular)
                    mkdir "$fork_pinned_report"
                    printf '{}\n' >"$fork_later_report"
                    printf '{}\n' >"$fork_test_list"
                    pinned_name=$fork_pinned_report
                    later_name=$fork_later_report
                    list_name=$fork_test_list
                    ;;
            esac

            python3 - "$candidate_receipt" "$current_commit" "$current_tree" "$current_src" \
                "$pinned_name" "$later_name" "$list_name" <<'PYTHON'
import json
import sys

path, commit, tree, src, pinned, later, listing = sys.argv[1:]
document = {
    "artifact": "regent-fork-check-receipt",
    "version": 1,
    "status": "passed",
    "worktree": "clean",
    "tested_identity": {"commit": commit, "tree": tree, "src_tree": src},
    "executed_selectors": {"pinned": 18, "later": 9, "total": 27},
    "reports": {
        "pinned": {"path": pinned, "sha256": "0" * 64},
        "later": {"path": later, "sha256": "0" * 64},
        "compiled_test_list": {"path": listing, "sha256": "0" * 64},
    },
}
open(path, "w", encoding="utf-8").write(json.dumps(document, indent=2, sort_keys=True) + "\n")
PYTHON
            path_status=0
            path_output=$(verify_fork_receipt "$candidate_receipt" "$current_commit" "$component/src" 2>&1) || path_status=$?
            printf '%s\n' "$path_output"
            [ "$path_status" -ne 0 ] || fail "$case_name receipt path exited 0"
            case "$path_output" in
                *"$expected_message"*) : ;;
                *) fail "$case_name receipt stopped outside its exact path boundary" ;;
            esac
            case "$path_output" in
                *'DEPLOYMENT GATE PASS'*) fail "$case_name receipt printed this gate's pass marker" ;;
            esac
        }

        run_path_case traversal 'receipt report pinned path:'
        run_path_case duplicate 'receipt report paths resolve to duplicate canonical targets'
        run_path_case symlink 'receipt report pinned must not be a symlink'
        run_path_case nonregular 'receipt report pinned is not a regular file'
        rm -rf "$generated" reports/generated/fork
        printf '\ntraversal, duplicate, symlink and nonregular receipt paths all failed closed\n'
        printf 'DEPLOYMENT RECEIPT-PATH REGRESSION PASS\n'
        exit 0
        ;;
    --selftest-receipt-substitution)
        section "Fork receipt single-snapshot regression"
        rm -rf "$generated"
        mkdir -p "$generated"
        source_receipt="$generated/mutable-source-receipt.json"
        synthetic_packet="$generated/snapshot-packet.json"
        printf '{"generation":1}\n' >"$source_receipt"
        fork_receipt_snapshot=$(mktemp "$generated/.snapshot.XXXXXX")
        fork_receipt_snapshot_sha=$(snapshot_receipt "$source_receipt" "$fork_receipt_snapshot")
        python3 - "$fork_receipt_snapshot" "$fork_receipt_snapshot_sha" "$synthetic_packet" \
            "$PRODUCTION_AUTHORITY_COMMIT" "$PRODUCTION_AUTHORITY_TREE" \
            "$PRODUCTION_AUTHORITY_SRC_TREE" "$FORK_EVIDENCE_COMMIT" <<'PYTHON'
import json
import sys

receipt_path, receipt_sha, packet_path, production_commit, production_tree, source_tree, fork_commit = sys.argv[1:]
document = {
    "immutable_identities": {
        "production_authority_commit": production_commit,
        "production_authority_tree": production_tree,
        "shared_src_tree": source_tree,
        "fork_evidence_commit": fork_commit,
    },
    "fork_check_receipt": json.load(open(receipt_path, encoding="utf-8")),
    "fork_check_receipt_sha256": receipt_sha,
}
open(packet_path, "w", encoding="utf-8").write(json.dumps(document, sort_keys=True) + "\n")
PYTHON
        printf '{"generation":2}\n' >"$source_receipt"
        verify_packet_authority "$fork_receipt_snapshot" "$fork_receipt_snapshot_sha" "$synthetic_packet"
        substitution_status=0
        substitution_output=$(verify_packet_authority "$source_receipt" "$fork_receipt_snapshot_sha" \
            "$synthetic_packet" 2>&1) || substitution_status=$?
        printf '%s\n' "$substitution_output"
        [ "$substitution_status" -ne 0 ] || fail "replacement receipt bytes were accepted after validation"
        case "$substitution_output" in
            *'fork receipt snapshot digest expected'* | *'embedded fork-check receipt does not equal'*) : ;;
            *) fail "the replacement receipt stopped outside the snapshot continuity boundary" ;;
        esac
        case "$substitution_output" in
            *'DEPLOYMENT GATE PASS'*) fail "receipt substitution printed this gate's pass marker" ;;
        esac
        cleanup_receipt_snapshot
        fork_receipt_snapshot=
        rm -rf "$generated"
        printf '\nreplacement bytes could not change the validated receipt snapshot or packet input\n'
        printf 'DEPLOYMENT RECEIPT-SUBSTITUTION REGRESSION PASS\n'
        exit 0
        ;;
    *) fail "a mode is required; use --offline, --prepare <deployer>, --rehearse, --selftest-dead-endpoint, --selftest-stale-source, --selftest-stale-receipt, --selftest-receipt-paths, or --selftest-receipt-substitution" ;;
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

# A run is packet evidence only if its tracked bytes, index flags and recursive dependency state
# are one exact clean object. Generated scratch is the only excluded filesystem state.
require_clean_worktree
initial_repository_identity=$repository_identity

candidate_commit=$(git rev-parse HEAD)
candidate_tree=$(git rev-parse 'HEAD^{tree}')
candidate_src_tree=$(git rev-parse "HEAD:$component/src")
printf 'candidate commit: %s\n' "$candidate_commit"
printf 'candidate tree:   %s\n' "$candidate_tree"
printf 'candidate src:    %s\n' "$candidate_src_tree"

verify_source_authority "$PRODUCTION_AUTHORITY_SRC_TREE"
printf 'production authority: commit, full tree, production src, and candidate src are exact\n'

# A successful deployment mode cannot precede the fork check that authorizes its chain evidence.
# Preparation therefore fails here, before its first provider access, if the receipt is absent,
# stale, names another commit/tree/src, or no longer hashes the retained reports.
mkdir -p reports/generated
fork_receipt_snapshot=$(mktemp reports/generated/.fork-receipt-snapshot.XXXXXX)
fork_receipt_snapshot_sha=$(snapshot_receipt "$fork_receipt" "$fork_receipt_snapshot") ||
    fail "the fork-check receipt could not be copied into one private snapshot"
verify_fork_receipt "$fork_receipt_snapshot"

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
rendered_tmp="$generated/.mainnet-no-go-packet.tmp"

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

python3 - "$mode" "$ceremony_report" "$sizes" "$frozen" "$state_source" "$rendered_tmp" "$packet" \
    "$fork_receipt_snapshot" "$fork_receipt_snapshot_sha" <<'PYTHON'
import hashlib
import json
import sys

(
    mode,
    report_path,
    sizes_path,
    frozen_path,
    state_path,
    rendered_path,
    packet_path,
    receipt_path,
    expected_receipt_sha,
) = sys.argv[1:10]

EIP170 = 24_576
EIP3860 = 49_152

# A guardrail on the in-EVM creation gas DEP-074 measures. The packet's own gas note explains why
# that figure is a floor rather than a transaction cost.
IN_EVM_CREATION_GAS_GUARDRAIL = 14_000_000

# The two immutable identities the packet names apart, from README.md's own record.
PRODUCTION_AUTHORITY_COMMIT = "f4114f5276386f48bf8dc53ee344189d98c8896e"
PRODUCTION_AUTHORITY_TREE = "bb660324bb1d5cc322adeb243b0bd51779821fcb"
SHARED_SRC_TREE = "91a741e417b75706a4071f7bdac2c5e13548c0fc"
FORK_EVIDENCE_COMMIT = "ea8c81b2a5724213d3aeb4b0d81885b932f7d1aa"

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
receipt_bytes = open(receipt_path, "rb").read()
receipt_sha = hashlib.sha256(receipt_bytes).hexdigest()
if receipt_sha != expected_receipt_sha:
    raise SystemExit(
        f"fork receipt snapshot changed before rendering: expected {expected_receipt_sha}, found {receipt_sha}"
    )
fork_check_receipt = json.loads(receipt_bytes)

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
    "fork_check_receipt": fork_check_receipt,
    "fork_check_receipt_sha256": receipt_sha,
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
    print("packet candidate passed rendering and awaits atomic publication")
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

if [ "$mode" = --prepare ]; then
    verify_packet_authority "$fork_receipt_snapshot" "$fork_receipt_snapshot_sha" "$rendered_tmp"
else
    verify_packet_authority "$fork_receipt_snapshot" "$fork_receipt_snapshot_sha" "$packet" "$rendered_tmp"
fi
mv "$rendered_tmp" "$rendered"
if [ "$mode" = --prepare ]; then
    printf 'packet candidate: %s\n' "$rendered"
fi

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
    --scan "$generated" "$fork_receipt_snapshot" script test-deployment deployments/base-mainnet docs/audit/deployment-ceremony.md

require_clean_worktree
[ "$repository_identity" = "$initial_repository_identity" ] ||
    fail "tracked repository bytes changed during the deployment gate"
[ "$(git rev-parse HEAD)" = "$candidate_commit" ] || fail "HEAD changed during the deployment gate"
[ "$(git rev-parse 'HEAD^{tree}')" = "$candidate_tree" ] || fail "the candidate tree changed during the deployment gate"
[ "$(git rev-parse "HEAD:$component/src")" = "$candidate_src_tree" ] || fail "the candidate src tree changed during the deployment gate"

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
