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

GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_REPLACE_OBJECTS

for git_context in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_CEILING_DIRECTORIES \
    GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_QUARANTINE_PATH GIT_SHALLOW_FILE GIT_GRAFT_FILE \
    GIT_REPLACE_REF_BASE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG_SYSTEM \
    GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_EXEC_PATH GIT_PREFIX; do
    eval "git_context_value=\${$git_context:-}"
    [ -z "$git_context_value" ] || {
        printf 'GATE FAIL: ambient Git context override %s is set\n' "$git_context" >&2
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
git_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    printf 'GATE FAIL: the physical script root is not inside a Git worktree\n' >&2
    exit 1
}
git_root=$(cd "$git_root" && pwd -P)
[ "$git_root/$component" = "$physical_root" ] || {
    printf 'GATE FAIL: the physical script root is not %s under the Git top level\n' "$component" >&2
    exit 1
}
cd "$physical_root"

FOUNDRY_OFFLINE=true
FOUNDRY_PROFILE=default
GIT_TERMINAL_PROMPT=0
PYTHONDONTWRITEBYTECODE=1
export FOUNDRY_OFFLINE FOUNDRY_PROFILE GIT_TERMINAL_PROMPT PYTHONDONTWRITEBYTECODE

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
component_root_test=test/tooling/component_root_test.py

generated=reports/generated
receipt_final="$generated/dependency-receipt.txt"
receipt="$generated/.dependency-receipt.tmp"
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

receipt_published=false
cleanup_unpublished_receipt() {
    if [ "${receipt_published:-false}" != true ]; then
        rm -f "$receipt" "$receipt_final"
    fi
}
trap cleanup_unpublished_receipt EXIT
trap 'cleanup_unpublished_receipt; exit 1' HUP INT TERM

# Compare every tracked file in the ticket repository directly with its indexed blob, reject
# hidden index flags, and force every recursive submodule to expose ordinary and ignored dirt.
# Generated Foundry/report roots are the only worktree-state exclusions.
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

scratch = tuple(
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
    if path and not path.startswith(scratch):
        problems.append("!! " + os.fsdecode(path))

flagged = []
for entry in run(["git", "ls-files", "-v", "-z"]).split(b"\0"):
    if not entry:
        continue
    marker, path = entry[:1], entry[2:]
    if marker == b"S" or marker.islower():
        flagged.append(f"{marker.decode()} {os.fsdecode(path)}")
if flagged:
    problems.append("special index flags: " + ", ".join(flagged))

digest = hashlib.sha256()
verify_tracked_bytes(".", "ticket repository", digest)

submodule_status = run(["git", "submodule", "status", "--recursive"], text=True)
for line in submodule_status.splitlines():
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
    sub_flags = []
    for entry in run(["git", "ls-files", "-v", "-z"], cwd=path).split(b"\0"):
        if entry and (entry[:1] == b"S" or entry[:1].islower()):
            sub_flags.append(entry.decode("utf-8", errors="backslashreplace"))
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

require_clean_repository() {
    repository_identity=$(repository_snapshot 2>&1) ||
        fail "the repository is not one clean physical Git object:\n$repository_identity"
}

# Python's bytecode path is runtime-derived, but cleanup is deliberately limited to the checker
# cache file itself. Every other __pycache__ entry remains visible to the strict cleanliness proof.
python3 - "$checker" <<'PYTHON'
import importlib.util
import os
import stat
import sys

source = sys.argv[1]
cache = importlib.util.cache_from_source(source)
expected = os.path.join(os.path.dirname(source), "__pycache__", f"check-requirements.{sys.implementation.cache_tag}.pyc")
if cache != expected:
    raise SystemExit(f"unexpected checker cache path: {cache}")
try:
    metadata = os.lstat(cache)
except FileNotFoundError:
    pass
else:
    if stat.S_ISDIR(metadata.st_mode):
        raise SystemExit(f"refusing to remove directory at checker cache path: {cache}")
    os.unlink(cache)
PYTHON

require_clean_repository
initial_repository_identity=$repository_identity

rm -rf "$generated"
mkdir -p "$generated"

section() {
    printf '\n=== %s ===\n' "$*"
}

# ---------------------------------------------------------------------------
section "Required material and tools"
# ---------------------------------------------------------------------------

for required_file in "$frozen" "$ledger" "$manifest" "$bindings" "$dispositions" \
    "$threat_model" "$gas_doc" "$slither_config" "$checker" "$freezer" "$tooling_test" "$component_root_test" \
    src/bindings/FrozenIdentity.sol \
    SPEC.md "$git_root/.gitmodules" foundry.toml reports/frozen/c4-runtime-baseline.json; do
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

# Stale Foundry artifacts cannot participate in evidence compilation. `forge clean` is bounded by
# the committed Foundry configuration to this ticket's own out/cache roots.
forge clean
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
section "Component-root tooling"
# ---------------------------------------------------------------------------

# The three gates refuse every script root except contracts/v1 under the Git top level, and the
# checker reads the shared top-level .gitmodules as component-relative paths. Both boundaries are
# shell and Python control flow around Git, so they are proved here against copies of the real
# scripts in throwaway repositories. A failure is a gate failure.
python3 "$component_root_test"

# ---------------------------------------------------------------------------
section "Provider-secret scan"
# ---------------------------------------------------------------------------

# Bind the receipt to the exact clean commit only after every compilation, test, evidence and
# static-analysis check has succeeded. It remains temporary until the final scan and repository
# integrity proof below.
tested_commit=$(git rev-parse HEAD)
tested_tree=$(git rev-parse 'HEAD^{tree}')
# The receipt's src identity is this component's src/ tree, read at its one canonical path.
tested_src=$(git rev-parse "HEAD:$component/src")
{
    printf 'offline-tested-commit %s\n' "$tested_commit"
    printf 'offline-tested-tree %s\n' "$tested_tree"
    printf 'offline-tested-src %s\n' "$tested_src"
} >>"$receipt"

# Nothing this gate produces, and nothing it commits, may carry a resolved provider endpoint.
# The scan covers every evidence location recursively: the regenerated evidence — the effective
# Foundry configuration included, so a resolved RPC alias would show up — every committed frozen
# artifact, the whole audit packet, and the fork harness itself. The effective configuration is
# additionally walked to every nested leaf, because a credential one level down is still a
# credential.
python3 "$checker" secrets \
    --forge-config "$forge_config" \
    --scan "$generated" reports/frozen abi contracts requirements docs/audit docs/security test-fork

require_clean_repository
[ "$repository_identity" = "$initial_repository_identity" ] ||
    fail "tracked repository bytes changed during the offline gate"
[ "$(git rev-parse HEAD)" = "$tested_commit" ] || fail "HEAD changed during the offline gate"
[ "$(git rev-parse 'HEAD^{tree}')" = "$tested_tree" ] || fail "the tested tree changed during the offline gate"
[ "$(git rev-parse "HEAD:$component/src")" = "$tested_src" ] || fail "the tested src tree changed during the offline gate"
checker_cache=$(python3 -c 'import importlib.util; print(importlib.util.cache_from_source("bin/check-requirements.py"))')
[ ! -e "$checker_cache" ] || fail "the offline gate left executable checker bytecode: $checker_cache"

# ---------------------------------------------------------------------------
section "Gate report"
# ---------------------------------------------------------------------------

mv "$receipt" "$receipt_final"
printf 'dependency receipt:\n'
cat "$receipt_final"
printf '\nGATE PASS\n'
receipt_published=true
