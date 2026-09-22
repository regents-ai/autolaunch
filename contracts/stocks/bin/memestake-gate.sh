#!/bin/sh
# The shared body of the Memestake required gates. It is not an entrypoint: `contracts/stocks/bin/gate.sh`
# and `contracts/robinhood/bin/gate.sh` each set their component and source this file.
#
# The gate is offline: it performs no download, no package or registry lookup, and no git fetch.
# The dependency snapshot and the Solidity compiler are materialized before the gate, never by it;
# anything missing or drifted fails closed here.
#
# The gate runs the external tools and hands every structured comparison to
# contracts/stocks/bin/check-gate.py and contracts/stocks/bin/freeze.py, which are the only places an
# expectation is compared to its authority.
#
# A failure of this gate is a stop-report. Never relax a pinned identity, threshold, or
# configuration value to make it pass.
#
# Variables the entrypoint sets before sourcing:
#   component        the package path under the Git top level, e.g. contracts/stocks
#   bindings         a compiled bindings library to reconcile, or empty
#   slither_root     the directory Slither analyzes: "." or a self-contained copy the entrypoint
#                    builds with prepare_slither_root
#   analyzed_sources the source roots whose declarations Slither must have analyzed
#   prepare_slither_root  a function that builds $slither_root (a no-op for ".")
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

# The script root is proved to be exactly the component directory under the Git top level. Nothing
# is discovered from the layout: a repository rooted at the component, a copy of this tree at the
# top level, or any other directory is rejected here, before Git is consulted for anything else.
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
FOUNDRY_LINT_LINT_ON_BUILD=false
GIT_TERMINAL_PROMPT=0
PYTHONDONTWRITEBYTECODE=1
export FOUNDRY_OFFLINE FOUNDRY_PROFILE FOUNDRY_LINT_LINT_ON_BUILD GIT_TERMINAL_PROMPT PYTHONDONTWRITEBYTECODE

tooling=$git_root/contracts/stocks/bin
checker=$tooling/check-gate.py
freezer=$tooling/freeze.py
frozen=requirements/frozen-identity.json
freeze=requirements/freeze.json
dispositions=docs/security/slither-dispositions.md
slither_config=slither.config.json
frozen_listing=reports/frozen/test-listing.json

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

replacement_refs=$(git for-each-ref --format='%(refname)' refs/replace/) ||
    fail "could not inspect replacement refs"
[ -z "$replacement_refs" ] || fail "Git replacement refs are forbidden:
$replacement_refs"

receipt_published=false
cleanup_unpublished_receipt() {
    if [ "${receipt_published:-false}" != true ]; then
        rm -f "$receipt" "$receipt_final"
    fi
}
trap cleanup_unpublished_receipt EXIT
trap 'cleanup_unpublished_receipt; exit 1' HUP INT TERM

# Compare every tracked file in the repository directly with its indexed blob and reject hidden
# index flags. The Foundry and report roots of every contracts package, and the exported dependency
# snapshot under contracts/stocks/lib, are the only worktree-state exclusions. Submodules are not
# walked: no Memestake package reads a submodule; the dependency bytes the build reads are pinned
# by content in reports/frozen/dependency-closure.json, which the freezer reconciles.
repository_snapshot() {
    python3 - <<'PYTHON'
import hashlib
import os
import stat
import subprocess
import sys

os.chdir(subprocess.run(["git", "rev-parse", "--show-toplevel"], check=True, capture_output=True, text=True).stdout.rstrip("\n"))


def run(args, text=False):
    return subprocess.run(args, check=True, capture_output=True, text=text).stdout


def read_indexed_blobs(oids):
    ordered = list(dict.fromkeys(oids))
    if not ordered:
        return {}
    batch = subprocess.run(
        ["git", "cat-file", "--batch"],
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


problems = []
ordinary = run(["git", "status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=all"], text=True)
if ordinary:
    problems.extend(ordinary.rstrip("\n").splitlines())

scratch_roots = (b"reports/generated/", b"cache/", b"cache-fork/", b"out/", b"out-fork/", b"artifacts/", b"broadcast/")
ignored = run(["git", "ls-files", "-z", "--others", "--ignored", "--exclude-standard"]).split(b"\0")
for path in ignored:
    if not path:
        continue
    parts = path.split(b"/", 3)
    scratch = (
        len(parts) >= 3
        and parts[0] == b"contracts"
        and (
            (parts[2] + b"/") in scratch_roots
            or (len(parts) == 4 and parts[2] == b"reports" and parts[3].startswith(b"generated/"))
            or (parts[1] == b"stocks" and parts[2] == b"lib")
        )
    )
    if not scratch:
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

entries = []
seen = set()
for entry in run(["git", "ls-files", "-s", "-z"]).split(b"\0"):
    if not entry:
        continue
    metadata, raw_path = entry.split(b"\t", 1)
    mode, oid, stage = metadata.decode().split()
    path = os.fsdecode(raw_path)
    if stage != "0" or path in seen:
        problems.append(f"non-stage-zero index entry: {path}")
        continue
    seen.add(path)
    if mode != "160000":
        entries.append((mode, oid, raw_path, path))

digest = hashlib.sha256()
try:
    indexed_blobs = read_indexed_blobs([entry[1] for entry in entries])
except (OSError, subprocess.SubprocessError, ValueError) as error:
    problems.append(f"could not read raw indexed blobs: {error}")
    indexed_blobs = {}
for mode, oid, raw_path, path in entries:
    if not indexed_blobs:
        break
    try:
        found = os.lstat(path)
        if mode == "120000":
            if not stat.S_ISLNK(found.st_mode):
                raise ValueError("expected a symbolic link")
            data = os.fsencode(os.readlink(path))
        else:
            if mode not in {"100644", "100755"}:
                raise ValueError(f"unexpected indexed mode {mode}")
            if not stat.S_ISREG(found.st_mode) or stat.S_ISLNK(found.st_mode):
                raise ValueError("expected a regular file")
            descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
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
        digest.update(mode.encode() + b"\0" + raw_path + b"\0" + hashlib.sha256(data).digest())
    except (FileNotFoundError, OSError, ValueError) as error:
        problems.append(f"tracked filesystem mismatch: {path}: {error}")

if problems:
    print("\n".join(problems), file=sys.stderr)
    raise SystemExit(1)
print(digest.hexdigest())
PYTHON
}

require_clean_repository() {
    repository_identity=$(repository_snapshot 2>&1) ||
        fail "the repository is not one clean physical Git object:
$repository_identity"
}

require_clean_repository
initial_repository_identity=$repository_identity

[ -n "$generated" ] && rm -rf "./$generated"
mkdir -p "$generated"

section() {
    printf '\n=== %s ===\n' "$*"
}

# ---------------------------------------------------------------------------
section "Required material and tools"
# ---------------------------------------------------------------------------

for required_file in "$frozen" "$freeze" "$dispositions" "$slither_config" "$checker" "$freezer" \
    "$frozen_listing" foundry.toml remappings.txt; do
    [ -f "$required_file" ] || fail "required repository file is missing: $required_file"
done
[ -z "$bindings" ] || [ -f "$bindings" ] || fail "required repository file is missing: $bindings"

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

# The effective configuration, not the committed file: an environment override that changes the
# build or the fuzz portfolio shows up here and fails the reconciliation.
forge config --json >"$forge_config"

# ---------------------------------------------------------------------------
section "Frozen identity reconciliation"
# ---------------------------------------------------------------------------

dependency_lock=$(python3 -c 'import json; print(json.load(open("requirements/freeze.json"))["dependencies"]["lock"])')
set -- python3 "$checker" preflight \
    --frozen "$frozen" \
    --tool-identity "$tool_identity" \
    --forge-config "$forge_config" \
    --dependency-lock "$dependency_lock" \
    --receipt "$receipt"
[ -z "$bindings" ] || set -- "$@" --bindings "$bindings"
"$@"

# ---------------------------------------------------------------------------
section "Formatting"
# ---------------------------------------------------------------------------

forge fmt --check

# ---------------------------------------------------------------------------
section "Build and compiled build identity"
# ---------------------------------------------------------------------------

forge clean
forge build --sizes

python3 "$checker" artifacts --frozen "$frozen" --out out --receipt "$receipt"

# ---------------------------------------------------------------------------
section "Compiled test listing and frozen release surface"
# ---------------------------------------------------------------------------

# Foundry's own compiled listing, regenerated on every run. It is the authority for which test
# identities exist: a source scan cannot tell inherited, overloaded, or duplicated identities apart.
forge test --list --json >"$test_list"

# Check mode only. The freezer regenerates every committed ABI, surface, size, manifest, dependency
# closure and test listing document from these artifacts and compares byte for byte.
python3 "$freezer" check --freeze "$freeze" --out out --test-list "$test_list" --receipt "$receipt"

# ---------------------------------------------------------------------------
section "Test execution"
# ---------------------------------------------------------------------------

test_status=0
forge test --json >"$test_report" 2>"$test_stderr" || test_status=$?
cat "$test_stderr"

python3 "$checker" tests \
    --test-list "$test_list" \
    --frozen-listing "$frozen_listing" \
    --test-report "$test_report" \
    --receipt "$receipt"

[ "$test_status" -eq 0 ] || fail "forge test exited $test_status"

# ---------------------------------------------------------------------------
section "Static analysis"
# ---------------------------------------------------------------------------

hidden_triage=$(find . -name '*slither.db.json' -not -path './lib/*' -not -path './out/*' -not -path "./$generated/*" || true)
[ -z "$hidden_triage" ] || fail "hidden Slither triage database present: $hidden_triage"

# The detector portfolio the pinned binary actually registers, read from the binary's own
# interpreter: the python3 installed beside the resolved slither entrypoint in its environment.
# `--list-detectors` hides some detectors, so it under-reports the set that runs.
slither_entrypoint=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$(command -v slither)")
slither_interpreter=$(dirname "$slither_entrypoint")/python3
[ -x "$slither_interpreter" ] ||
    fail "cannot resolve the pinned Slither interpreter beside $slither_entrypoint"
slither_module_version=$("$slither_interpreter" -c 'import importlib.metadata; print(importlib.metadata.version("slither-analyzer"))') ||
    fail "the interpreter beside $slither_entrypoint does not carry slither-analyzer"
[ "$slither_module_version" = "$(awk '/^slither_version/ { print $2 }' "$tool_identity")" ] ||
    fail "the Slither interpreter's module version $slither_module_version differs from the slither binary on PATH"

"$slither_interpreter" -c 'import inspect
from slither.detectors import all_detectors
from slither.detectors.abstract_detector import AbstractDetector

print("\n".join(sorted({
    detector.ARGUMENT
    for _, detector in inspect.getmembers(all_detectors, inspect.isclass)
    if issubclass(detector, AbstractDetector) and detector is not AbstractDetector
})))' >"$detector_inventory" ||
    fail "the pinned Slither binary did not enumerate its registered detectors"

prepare_slither_root

# Record the exact argv, then run exactly that argv from the analyzed root. The recording is the
# invocation, so the reconciliation below sees the real command line and not a restatement of it.
slither_json_from_root=$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$slither_json" "$slither_root")
set -- slither . --fail-medium --json "$slither_json_from_root" --checklist
printf '%s\n' "$@" >"$slither_command"

slither_status=0
(cd "$slither_root" && "$@") >"$slither_checklist" 2>"$slither_stderr" || slither_status=$?
cat "$slither_stderr"
cat "$slither_checklist"

python3 "$checker" security \
    --slither-json "$slither_json" \
    --slither-cwd "$slither_root" \
    --slither-checklist "$slither_checklist" \
    --slither-stderr "$slither_stderr" \
    --slither-config "$slither_config" \
    --slither-command "$slither_command" \
    --detector-inventory "$detector_inventory" \
    --dispositions "$dispositions" \
    --test-list "$test_list" \
    --analyzed-sources $analyzed_sources \
    --suppression-sources src test script \
    --receipt "$receipt"

[ "$slither_status" -eq 0 ] || fail "slither exited $slither_status"

# ---------------------------------------------------------------------------
section "Provider-secret scan"
# ---------------------------------------------------------------------------

# Bind the receipt to the exact clean commit only after every compilation, test and static-analysis
# check has succeeded. It remains temporary until the final scan and repository integrity proof.
tested_commit=$(git rev-parse HEAD)
tested_tree=$(git rev-parse 'HEAD^{tree}')
tested_src=$(git rev-parse "HEAD:$component/src")
{
    printf 'offline-tested-commit %s\n' "$tested_commit"
    printf 'offline-tested-tree %s\n' "$tested_tree"
    printf 'offline-tested-src %s\n' "$tested_src"
} >>"$receipt"

# Nothing this gate produces, and nothing it commits, may carry a resolved provider endpoint. The
# scan covers the regenerated evidence (the Slither copy excluded: it is a copy of scanned sources
# and symlinks into the dependency snapshot), every committed frozen artifact, and the requirements.
python3 "$checker" secrets \
    --forge-config "$forge_config" \
    --scan "$generated"/*.json "$generated"/*.txt "$generated"/*.md "$generated"/*.log reports/frozen abi requirements docs/security

require_clean_repository
[ "$repository_identity" = "$initial_repository_identity" ] ||
    fail "tracked repository bytes changed during the offline gate"
[ "$(git rev-parse HEAD)" = "$tested_commit" ] || fail "HEAD changed during the offline gate"
[ "$(git rev-parse 'HEAD^{tree}')" = "$tested_tree" ] || fail "the tested tree changed during the offline gate"
[ "$(git rev-parse "HEAD:$component/src")" = "$tested_src" ] || fail "the tested src tree changed during the offline gate"

# ---------------------------------------------------------------------------
section "Gate report"
# ---------------------------------------------------------------------------

mv "$receipt" "$receipt_final"
printf 'dependency receipt:\n'
cat "$receipt_final"
printf '\nGATE PASS\n'
receipt_published=true
