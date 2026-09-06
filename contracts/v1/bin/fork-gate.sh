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
#   - that alias is proved live and on chain 8453 by one read-only chain-id probe before any fork
#     test runs, so a dead, unreachable, malformed or wrong-chain endpoint stops the gate instead
#     of surfacing as a harness failure. `selftest-dead-endpoint` is that refusal's own regression;
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
#             It closes no claim and it is not part of the ledger reconciliation. It runs the same
#             way whether or not a reviewed observation is already committed — a replacement
#             candidate is still only scratch until a human installs it, and this pass proves it
#             changed no committed file before it exits.
#
#   check     Compare-only. It refuses to start unless a human has already reviewed the candidate,
#             installed it as reports/frozen/fork-observations.json, activated the `fork` gate in
#             requirements/ledger.toml, and committed both — and it proves those files are clean
#             both before it touches the provider and after it finishes, so a check run cannot
#             have written the record it is checking against. The record names the production
#             authority commit and src/ tree it was observed against, and both are proved against
#             Git and against this checkout before any fork test can run.
#
# A failure of this gate is a stop-report. Never relax a pinned identity or a threshold to pass.
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
        printf 'FORK GATE FAIL: ambient Git context override %s is set\n' "$git_context" >&2
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
    printf 'FORK GATE FAIL: git is not on PATH\n' >&2
    exit 1
}
git_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    printf 'FORK GATE FAIL: the physical script root is not inside a Git worktree\n' >&2
    exit 1
}
git_root=$(cd "$git_root" && pwd -P)
[ "$git_root/$component" = "$physical_root" ] || {
    printf 'FORK GATE FAIL: the physical script root is not %s under the Git top level\n' "$component" >&2
    exit 1
}
cd "$physical_root"

GIT_TERMINAL_PROMPT=0
PYTHONDONTWRITEBYTECODE=1
export GIT_TERMINAL_PROMPT PYTHONDONTWRITEBYTECODE

# The gate this entrypoint proves, and the only one. A hermetic or invariant claim can never
# close here, and a fork claim can never close in bin/gate.sh.
GATES=fork

RPC_ALIAS=base
RPC_ENV=REGENT_BASE_RPC_URL

# The one chain this gate is about. The endpoint boundary below refuses everything else.
CHAIN_ID=8453
PROBE_REFUSAL="the configured $RPC_ALIAS endpoint did not answer a read-only chain-id probe with exactly $CHAIN_ID"

# A closed loopback port, and the only endpoint the dead-endpoint regression uses. Nothing listens
# on the discard port, so the refusal it produces is deterministic and reaches no network.
DEAD_ENDPOINT=http://127.0.0.1:9

# The discovery pass is one contract and closes nothing. Every other fork contract carries the
# mapped claim selectors, so the two are separated by name in both directions below.
DISCOVERY_CONTRACT=ForkDiscoveryTest

frozen=requirements/frozen-identity.json
ledger=requirements/ledger.toml
observations=reports/frozen/fork-observations.json
checker=bin/check-requirements.py

generated=reports/generated/fork
offline_receipt=reports/generated/dependency-receipt.txt
check_receipt="$generated/fork-check-receipt.json"
check_receipt_tmp="$generated/.fork-check-receipt.tmp"
receipt_published=false

fail() {
    printf 'FORK GATE FAIL: %s\n' "$*" >&2
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

cleanup_unpublished_receipt() {
    if [ "${receipt_published:-false}" != true ]; then
        rm -f "$check_receipt" "$check_receipt_tmp"
    fi
}

assert_physical_git_identity() {
    found_root=$(git rev-parse --show-toplevel 2>/dev/null) ||
        fail "the physical script root is no longer a Git worktree"
    found_root=$(cd "$found_root" && pwd -P)
    [ "$found_root/$component" = "$physical_root" ] ||
        fail "Git no longer resolves the physical script root as $component under its top level"
    [ "$(pwd -P)" = "$physical_root" ] ||
        fail "the execution directory no longer equals the physical script root"
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

# The committed state of the two files a discovery run must not be able to author. Any difference
# between the reading taken before provider access and the one taken after is a write.
committed_state() {
    git status --porcelain -- "$observations" "$ledger"
}

# Check evidence names one exact physical Git object. Ordinary status is only one input: direct
# tracked-byte comparison, hidden index flags and recursive ignored submodule dirt also fail.
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

flagged = []
for entry in run(["git", "ls-files", "-v", "-z"]).split(b"\0"):
    if entry and (entry[:1] == b"S" or entry[:1].islower()):
        flagged.append(entry.decode("utf-8", errors="backslashreplace"))
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

# Foundry's profile-specific clean is the compilation boundary: no object or compiler-cache byte
# from an earlier run survives to the one build whose tests this gate may execute.
clean_fork_profile_build_state() {
    clean_profile=$1
    FOUNDRY_PROFILE="$clean_profile" FOUNDRY_OFFLINE=true forge clean
    # `forge clean` removes the artifact root but deliberately leaves unknown cache entries.
    # These are the two profile roots already reconciled against foundry.toml by this gate.
    rm -rf "$physical_root/out-fork" "$physical_root/cache-fork"
}

verify_offline_receipt_identity() {
    receipt_path=$1
    expected_commit=$2
    expected_tree=$3
    expected_src=$4
    python3 - "$receipt_path" "$expected_commit" "$expected_tree" "$expected_src" <<'PYTHON'
import os
import stat
import sys

path, expected_commit, expected_tree, expected_src = sys.argv[1:]
try:
    metadata = os.lstat(path)
except FileNotFoundError:
    raise SystemExit(f"the offline gate dependency receipt is absent: {path}")
if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
    raise SystemExit(f"the offline gate dependency receipt is not a regular non-symlink file: {path}")

values = {}
for line in open(path, encoding="utf-8"):
    parts = line.rstrip("\n").split(" ", 1)
    if parts[0] in {"offline-tested-commit", "offline-tested-tree", "offline-tested-src"}:
        if parts[0] in values or len(parts) != 2:
            raise SystemExit(f"the offline gate dependency receipt has a duplicate or malformed {parts[0]} line")
        values[parts[0]] = parts[1]
expected = {
    "offline-tested-commit": expected_commit,
    "offline-tested-tree": expected_tree,
    "offline-tested-src": expected_src,
}
if values != expected:
    raise SystemExit(f"stale dependency receipt identity: expected {expected}, found {values}")
print(f"offline dependency receipt: commit {expected_commit}, tree {expected_tree}, src {expected_src}")
PYTHON
}

# One read-only `eth_chainId` read through the configured `$RPC_ALIAS` alias, and the whole
# endpoint boundary. Without it a dead, unreachable, malformed or wrong-chain endpoint surfaces
# only as a Forge failure deep inside the harness, where a run that never opened a fork is hard to
# tell from one that observed something.
#
# The endpoint is never exposed. `cast` names the URL in its own diagnostics, so the capture is
# scanned before anything is displayed and dropped unread if the scan finds it, and neither capture
# survives the probe. The answer itself is printed only when it is plain digits, and every failure
# — dead, unreachable, malformed, or another chain — is the same refusal.
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

# The recorded production authority predates the contracts/v1 layout and carries src/ at the root
# of its own tree. It is read there, as a historical Git object, for this verification only; the
# checkout is always read at $component/src, and the two must be one tree identity.
RECORDED_AUTHORITY_SRC_PATH=src
verify_named_source_authority() {
    identity=$(python3 -c 'import json,sys
record = json.load(open(sys.argv[1], encoding="utf-8"))["source_authority"]
print(record["production_authority_commit"], record["production_source_tree"])' "$observations")
    recorded_commit=${identity% *}
    recorded_src_tree=${identity#* }

    git cat-file -e "${recorded_commit}^{commit}" 2>/dev/null ||
        fail "the record names production authority commit $recorded_commit, which is not an object in this repository"
    authority_src_tree=$(git rev-parse "${recorded_commit}:$RECORDED_AUTHORITY_SRC_PATH")
    [ "$authority_src_tree" = "$recorded_src_tree" ] ||
        fail "the record names production source tree $recorded_src_tree, but commit $recorded_commit carries $authority_src_tree at $RECORDED_AUTHORITY_SRC_PATH"

    [ "$checkout_src_tree" = "$recorded_src_tree" ] ||
        fail "this checkout's $component/src tree is $checkout_src_tree, not the $recorded_src_tree the record was observed against"

    printf 'tested commit: %s\n' "$checkout_commit"
    printf 'tested tree:   %s\n' "$checkout_tree"
    printf 'tested src:    %s\n' "$checkout_src_tree"
    printf 'the record names production authority %s carrying that exact src/ tree at %s\n' "$recorded_commit" "$RECORDED_AUTHORITY_SRC_PATH"
}

mode=${1:-check}
case "$mode" in
    discover)
        FOUNDRY_PROFILE=fork-discovery
        ;;
    check)
        FOUNDRY_PROFILE=fork
        ;;
    selftest-dead-endpoint)
        # The regression for that boundary, and the only mode that reaches no network at all. It
        # re-runs this same script in `check` mode with the `$RPC_ALIAS` alias pointed at a closed
        # loopback port, so the production probe above is the code under test and the real endpoint
        # is neither read nor passed on. It cannot stand in for a check run: it reaches no fork
        # test, closes no claim, and this gate's pass marker never appears in it.
        section "Dead-endpoint regression"
        selftest_status=0
        selftest_output=$(REGENT_BASE_RPC_URL="$DEAD_ENDPOINT" "$0" check 2>&1) || selftest_status=$?
        printf '%s\n' "$selftest_output"

        [ "$selftest_status" -ne 0 ] || fail "a dead endpoint exited 0; the boundary does not hold"
        case "$selftest_output" in
            *'FORK GATE PASS'*) fail "a dead endpoint printed this gate's pass marker" ;;
        esac
        case "$selftest_output" in
            *"$PROBE_REFUSAL"*) : ;;
            *) fail "the dead-endpoint run stopped before the chain-id probe, so it proves nothing" ;;
        esac

        printf '\nthe dead-endpoint run exited %s at the %s chain-id probe and printed no FORK GATE PASS\n' \
            "$selftest_status" "$RPC_ALIAS"
        printf 'DEAD-ENDPOINT REGRESSION PASS\n'
        exit 0
        ;;
    selftest-dirty-worktree)
        # Prove that an arbitrary ignored file is still dirt. The entire miniature repository lives
        # under generated scratch; no tracked ticket path is changed and no provider is reachable.
        section "Dirty-worktree regression"
        sandbox="$generated/dirty-worktree-selftest"
        rm -rf "$generated"
        mkdir -p "$sandbox"
        selftest_status=0
        selftest_output=$(
            {
                cd "$sandbox"
                printf '*.log\n' >.gitignore
                git init -q
                git add .gitignore
                git -c user.name=Regent -c user.email=regent.invalid commit -qm baseline
                printf 'ignored but not authorized scratch\n' >arbitrary.log
                require_clean_worktree
            } 2>&1
        ) || selftest_status=$?
        printf '%s\n' "$selftest_output"

        [ "$selftest_status" -ne 0 ] || fail "an arbitrary ignored file exited 0; the clean-tree boundary does not hold"
        case "$selftest_output" in
            *arbitrary.log*) : ;;
            *) fail "the dirty-worktree run did not name the arbitrary ignored file" ;;
        esac
        case "$selftest_output" in
            *'FORK GATE PASS'*) fail "an arbitrary ignored file printed this gate's pass marker" ;;
        esac
        rm -rf "$generated"
        printf '\nan arbitrary ignored file failed closed and printed no FORK GATE PASS\n'
        printf 'DIRTY-WORKTREE REGRESSION PASS\n'
        exit 0
        ;;
    selftest-python-cache-worktree)
        section "Python-cache worktree regression"
        sandbox="$generated/python-cache-selftest"
        rm -rf "$generated"
        mkdir -p "$sandbox/bin"
        printf '__pycache__/\nreports/generated/\n' >"$sandbox/.gitignore"
        printf 'VALUE = 1\n' >"$sandbox/bin/check-requirements.py"
        (
            cd "$sandbox"
            git init -q
            git add .gitignore bin/check-requirements.py
            git -c user.name=Regent -c user.email=regent.invalid commit -qm baseline
            require_clean_worktree
        )

        cache_relative=$(python3 -c 'import importlib.util; print(importlib.util.cache_from_source("bin/check-requirements.py"))')
        cache_tag=$(python3 -c 'import sys; print(sys.implementation.cache_tag)')

        expect_cache_dirt() {
            expected_path=$1
            cache_case=$2
            selftest_status=0
            selftest_output=$(
                {
                    cd "$sandbox"
                    require_clean_worktree
                } 2>&1
            ) || selftest_status=$?
            printf '%s\n' "$selftest_output"
            [ "$selftest_status" -ne 0 ] || fail "$cache_case cache entry exited 0"
            case "$selftest_output" in
                *"$expected_path"*) : ;;
                *) fail "$cache_case cache run did not name the rejected entry" ;;
            esac
            case "$selftest_output" in
                *'FORK GATE PASS'*) fail "$cache_case cache entry printed this gate's pass marker" ;;
            esac
        }

        (
            cd "$sandbox"
            PYTHONDONTWRITEBYTECODE=1 python3 bin/check-requirements.py
            [ ! -e "$cache_relative" ]
            require_clean_worktree
        )

        (
            cd "$sandbox"
            PYTHONDONTWRITEBYTECODE= PYTHONPYCACHEPREFIX= python3 -m py_compile bin/check-requirements.py
        )
        expect_cache_dirt "$cache_relative" forged-executable-bytecode
        rm -f "$sandbox/$cache_relative"

        printf 'not Python bytecode\n' >"$sandbox/bin/__pycache__/arbitrary.txt"
        expect_cache_dirt bin/__pycache__/arbitrary.txt arbitrary-file
        rm -f "$sandbox/bin/__pycache__/arbitrary.txt"

        wrong_name="bin/__pycache__/other.$cache_tag.pyc"
        printf 'wrong checker\n' >"$sandbox/$wrong_name"
        expect_cache_dirt "$wrong_name" wrong-checker
        rm -f "$sandbox/$wrong_name"

        wrong_tag=bin/__pycache__/check-requirements.cpython-000.pyc
        printf 'wrong cache tag\n' >"$sandbox/$wrong_tag"
        expect_cache_dirt "$wrong_tag" wrong-tag
        rm -f "$sandbox/$wrong_tag"

        printf 'malformed\n' >"$sandbox/$cache_relative"
        expect_cache_dirt "$cache_relative" malformed-bytecode
        rm -f "$sandbox/$cache_relative"

        mkdir -p "$sandbox/reports/generated"
        printf 'target\n' >"$sandbox/reports/generated/target.pyc"
        rm -f "$sandbox/$cache_relative"
        ln -s ../../reports/generated/target.pyc "$sandbox/$cache_relative"
        expect_cache_dirt "$cache_relative" symlink
        rm -f "$sandbox/$cache_relative"

        mkdir "$sandbox/$cache_relative"
        printf 'nested\n' >"$sandbox/$cache_relative/member"
        expect_cache_dirt "$cache_relative/member" directory

        rm -rf "$generated"
        printf '\nbytecode-disabled checker execution left no cache; forged executable, arbitrary, malformed, '
        printf 'wrong-name, wrong-tag, symlink and directory cache entries all failed closed\n'
        printf 'PYTHON-CACHE WORKTREE REGRESSION PASS\n'
        exit 0
        ;;
    selftest-hidden-worktree)
        section "Hidden tracked and recursive submodule dirt regression"
        sandbox="$physical_root/$generated/hidden-worktree-selftest"
        source_repo="$physical_root/$generated/hidden-worktree-submodule-source"
        rm -rf "$generated"
        mkdir -p "$sandbox" "$source_repo"
        cleanup_hidden_selftest() {
            rm -rf "$sandbox" "$source_repo"
        }
        trap cleanup_hidden_selftest EXIT
        trap 'cleanup_hidden_selftest; exit 1' HUP INT TERM

        init_sandbox() {
            rm -rf "$sandbox"
            mkdir -p "$sandbox"
            (
                cd "$sandbox"
                git init -q
                printf 'tracked\n' >tracked.txt
                git add tracked.txt
                git -c user.name=Regent -c user.email=regent.invalid commit -qm baseline
            )
        }
        expect_hidden_dirt() {
            hidden_case=$1
            expected_message=$2
            hidden_status=0
            hidden_output=$(
                {
                    cd "$sandbox"
                    require_clean_worktree
                } 2>&1
            ) || hidden_status=$?
            printf '%s\n' "$hidden_output"
            [ "$hidden_status" -ne 0 ] || fail "$hidden_case hidden dirt exited 0"
            case "$hidden_output" in
                *"$expected_message"*) : ;;
                *) fail "$hidden_case stopped outside the hidden-filesystem boundary" ;;
            esac
            case "$hidden_output" in
                *'FORK GATE PASS'*) fail "$hidden_case printed this gate's pass marker" ;;
            esac
        }

        init_sandbox
        (
            cd "$sandbox"
            git update-index --assume-unchanged tracked.txt
            printf 'hidden edit\n' >tracked.txt
        )
        expect_hidden_dirt assume-unchanged 'special index flags:'

        init_sandbox
        (
            cd "$sandbox"
            git update-index --skip-worktree tracked.txt
        )
        expect_hidden_dirt skip-worktree 'special index flags:'

        rm -rf "$source_repo"
        mkdir -p "$source_repo"
        (
            cd "$source_repo"
            git init -q
            printf 'ignored.tmp\n' >.gitignore
            printf 'dependency\n' >dependency.txt
            git add .gitignore dependency.txt
            git -c user.name=Regent -c user.email=regent.invalid commit -qm baseline
        )
        init_sandbox
        (
            cd "$sandbox"
            git -c protocol.file.allow=always submodule add -q "$source_repo" dependency
            git -c user.name=Regent -c user.email=regent.invalid commit -qam submodule
            printf 'ignored recursive dirt\n' >dependency/ignored.tmp
        )
        expect_hidden_dirt recursive-submodule 'recursive submodule dirt in dependency:'

        cleanup_hidden_selftest
        trap - EXIT HUP INT TERM
        printf '\nassume-unchanged, skip-worktree, and ignored recursive submodule dirt all failed closed\n'
        printf 'HIDDEN-WORKTREE REGRESSION PASS\n'
        exit 0
        ;;
    selftest-stale-dependency-receipt)
        section "Stale offline dependency receipt regression"
        rm -rf "$generated"
        mkdir -p "$generated"
        stale_dependency_receipt="$generated/stale-dependency-receipt.txt"
        {
            printf 'offline-tested-commit %040d\n' 0
            printf 'offline-tested-tree %040d\n' 0
            printf 'offline-tested-src %040d\n' 0
        } >"$stale_dependency_receipt"
        current_commit=$(git rev-parse HEAD)
        current_tree=$(git rev-parse 'HEAD^{tree}')
        current_src=$(git rev-parse "HEAD:$component/src")
        selftest_status=0
        selftest_output=$(verify_offline_receipt_identity "$stale_dependency_receipt" \
            "$current_commit" "$current_tree" "$current_src" 2>&1) || selftest_status=$?
        printf '%s\n' "$selftest_output"
        [ "$selftest_status" -ne 0 ] || fail "a stale dependency receipt exited 0"
        case "$selftest_output" in
            *'stale dependency receipt identity'*) : ;;
            *) fail "the stale dependency receipt stopped outside the commit/tree/src comparison" ;;
        esac
        case "$selftest_output" in
            *'FORK GATE PASS'*) fail "a stale dependency receipt printed this gate's pass marker" ;;
        esac
        rm -rf "$generated"
        printf '\nthe cross-commit dependency receipt failed closed and printed no FORK GATE PASS\n'
        printf 'STALE-DEPENDENCY-RECEIPT REGRESSION PASS\n'
        exit 0
        ;;
    selftest-source-authority)
        # The record's authority commit is read at its own recorded src path and this checkout at
        # $component/src; the two trees must be one identity, and a checkout carrying another src
        # tree must stop at that comparison. No provider is reached.
        section "Named source-authority regression"
        [ -f "$observations" ] || fail "the committed fork observation record is absent: $observations"
        checkout_commit=$(git rev-parse HEAD)
        checkout_tree=$(git rev-parse 'HEAD^{tree}')
        checkout_src_tree=$(git rev-parse "HEAD:$component/src")
        verify_named_source_authority

        selftest_status=0
        selftest_output=$(
            (
                checkout_src_tree=0000000000000000000000000000000000000000
                verify_named_source_authority
            ) 2>&1
        ) || selftest_status=$?
        printf '%s\n' "$selftest_output"
        [ "$selftest_status" -ne 0 ] || fail "a checkout carrying another src tree exited 0; the authority boundary does not hold"
        case "$selftest_output" in
            *"not the $recorded_src_tree the record was observed against"*) : ;;
            *) fail "the other-src run stopped outside the checkout comparison" ;;
        esac
        case "$selftest_output" in
            *'FORK GATE PASS'*) fail "a checkout carrying another src tree printed this gate's pass marker" ;;
        esac

        printf '\nthe recorded authority was read at %s, this checkout at %s/src, and another src tree failed closed\n' \
            "$RECORDED_AUTHORITY_SRC_PATH" "$component"
        printf 'SOURCE-AUTHORITY REGRESSION PASS\n'
        exit 0
        ;;
    selftest-git-context)
        section "Git-context regression"
        sandbox="$generated/git-context-selftest"
        rm -rf "$generated"
        mkdir -p "$sandbox"
        printf 'dirty execution tree\n' >"$sandbox/uncommitted.txt"
        clean_git_dir=$(git rev-parse --absolute-git-dir)
        selftest_status=0
        selftest_output=$(GIT_DIR="$clean_git_dir" GIT_WORK_TREE="$sandbox" "$0" check 2>&1) || selftest_status=$?
        printf '%s\n' "$selftest_output"

        [ "$selftest_status" -ne 0 ] || fail "a clean Git identity redirected to a dirty execution tree exited 0"
        case "$selftest_output" in
            *'ambient Git context override GIT_DIR is set'*) : ;;
            *) fail "the Git-context run stopped outside the pre-Git identity boundary" ;;
        esac
        case "$selftest_output" in
            *'FORK GATE PASS'*) fail "a redirected dirty execution tree printed this gate's pass marker" ;;
        esac
        rm -rf "$generated"
        printf '\nthe clean Git identity could not be redirected to a dirty execution tree; no FORK GATE PASS\n'
        printf 'GIT-CONTEXT REGRESSION PASS\n'
        exit 0
        ;;
    selftest-replacement-refs)
        section "Git replacement-ref regression"
        sandbox="$physical_root/$generated/replacement-ref-selftest"
        source_repo="$physical_root/$generated/replacement-ref-source"
        rm -rf "$generated"
        mkdir -p "$sandbox/$component/bin" "$source_repo"
        cleanup_replacement_ref_selftest() {
            rm -rf "$sandbox" "$source_repo"
        }
        trap cleanup_replacement_ref_selftest EXIT
        trap 'cleanup_replacement_ref_selftest; exit 1' HUP INT TERM

        (
            cd "$source_repo"
            git init -q
            printf 'first\n' >dependency.txt
            git add dependency.txt
            git -c user.name=Regent -c user.email=regent.invalid commit -qm first
            printf 'second\n' >dependency.txt
            git add dependency.txt
            git -c user.name=Regent -c user.email=regent.invalid commit -qm second
        )
        cp "$physical_root/bin/gate.sh" "$sandbox/$component/bin/gate.sh"
        cp "$physical_root/bin/fork-gate.sh" "$sandbox/$component/bin/fork-gate.sh"
        cp "$physical_root/bin/deployment-gate.sh" "$sandbox/$component/bin/deployment-gate.sh"
        (
            cd "$sandbox"
            git init -q
            printf 'first\n' >root.txt
            git add "$component" root.txt
            git -c user.name=Regent -c user.email=regent.invalid commit -qm first
            printf 'second\n' >root.txt
            git add root.txt
            git -c user.name=Regent -c user.email=regent.invalid commit -qm second
            git -c protocol.file.allow=always submodule add -q "$source_repo" dependency
            git -c user.name=Regent -c user.email=regent.invalid commit -qam submodule
        )

        expect_replacement_ref_rejection() {
            replacement_case=$1
            for gate_script in gate.sh fork-gate.sh deployment-gate.sh; do
                selftest_status=0
                selftest_output=$(
                    cd "$sandbox/$component"
                    GIT_NO_REPLACE_OBJECTS=0 "./bin/$gate_script" check 2>&1
                ) || selftest_status=$?
                printf '%s\n' "$selftest_output"
                [ "$selftest_status" -ne 0 ] ||
                    fail "$replacement_case replacement ref exited 0 through $gate_script"
                case "$selftest_output" in
                    *'Git replacement refs are forbidden:'*'refs/replace/'*) : ;;
                    *) fail "$replacement_case replacement ref stopped outside the replacement-ref boundary in $gate_script" ;;
                esac
                case "$selftest_output" in
                    *'GATE PASS'*) fail "$replacement_case replacement ref printed a gate pass marker in $gate_script" ;;
                esac
                [ ! -e "$sandbox/$component/reports" ] ||
                    fail "$replacement_case replacement ref left a gate receipt path through $gate_script"
            done
        }

        root_target=$(git -C "$sandbox" rev-parse HEAD)
        root_replacement=$(git -C "$sandbox" rev-parse HEAD^)
        git -C "$sandbox" replace "$root_target" "$root_replacement"
        expect_replacement_ref_rejection root
        git -C "$sandbox" replace -d "$root_target" >/dev/null

        submodule_target=$(git -C "$sandbox/dependency" rev-parse HEAD)
        submodule_replacement=$(git -C "$sandbox/dependency" rev-parse HEAD^)
        git -C "$sandbox/dependency" replace "$submodule_target" "$submodule_replacement"
        expect_replacement_ref_rejection recursive-submodule

        cleanup_replacement_ref_selftest
        trap - EXIT HUP INT TERM
        printf '\nroot and initialized recursive-submodule replacement refs failed closed in all three gates\n'
        printf 'hostile ambient replacement processing could not yield a receipt or gate pass marker\n'
        printf 'REPLACEMENT-REF REGRESSION PASS\n'
        exit 0
        ;;
    selftest-post-render-receipt)
        section "Post-render receipt regression"
        rm -rf "$generated"
        mkdir -p "$generated"
        selftest_status=0
        selftest_output=$(
            {
                receipt_published=false
                trap cleanup_unpublished_receipt EXIT
                trap 'cleanup_unpublished_receipt; exit 1' HUP INT TERM
                printf '{"status":"passed"}\n' >"$check_receipt_tmp"
                fail "forced post-render failure"
            } 2>&1
        ) || selftest_status=$?
        printf '%s\n' "$selftest_output"

        [ "$selftest_status" -ne 0 ] || fail "the forced post-render failure exited 0"
        [ ! -e "$check_receipt" ] || fail "the forced post-render failure left a consumable receipt"
        [ ! -e "$check_receipt_tmp" ] || fail "the forced post-render failure left a temporary receipt"
        case "$selftest_output" in
            *'forced post-render failure'*) : ;;
            *) fail "the receipt regression did not reach its forced post-render failure" ;;
        esac
        case "$selftest_output" in
            *'FORK GATE PASS'*) fail "the forced post-render failure printed this gate's pass marker" ;;
        esac
        rm -rf "$generated"
        printf '\nthe post-render failure left no temporary or consumable receipt and printed no FORK GATE PASS\n'
        printf 'ATOMIC RECEIPT REGRESSION PASS\n'
        exit 0
        ;;
    selftest-fork-clean-build)
        section "Fork-profile clean-build regression"
        command -v forge >/dev/null 2>&1 || fail "forge is not on PATH"
        rm -rf "$generated"
        mkdir -p "$generated" out-fork/regent-stale-selftest cache-fork/regent-stale-selftest
        artifact_marker=out-fork/regent-stale-selftest/forged-pass-artifact
        cache_marker=cache-fork/regent-stale-selftest/forged-compiler-cache
        printf 'altered artifact that must never execute\n' >"$artifact_marker"
        printf 'altered compiler cache that must never be reused\n' >"$cache_marker"
        cleanup_clean_build_selftest() {
            rm -f "$artifact_marker" "$cache_marker"
            rm -rf "$generated"
        }
        trap cleanup_clean_build_selftest EXIT
        trap 'cleanup_clean_build_selftest; exit 1' HUP INT TERM

        clean_fork_profile_build_state fork
        [ ! -e "$artifact_marker" ] || fail "fork-profile clean retained the altered artifact"
        [ ! -e "$cache_marker" ] || fail "fork-profile clean retained the altered compiler cache"
        FOUNDRY_PROFILE=fork FOUNDRY_OFFLINE=true forge build
        [ ! -e "$artifact_marker" ] || fail "the clean build restored the altered artifact"
        [ ! -e "$cache_marker" ] || fail "the clean build restored the altered compiler cache"

        cleanup_clean_build_selftest
        trap - EXIT HUP INT TERM
        printf '\naltered fork artifacts and compiler cache were removed before one offline source build\n'
        printf 'the no-provider regression printed no FORK GATE PASS\n'
        printf 'FORK CLEAN-BUILD REGRESSION PASS\n'
        exit 0
        ;;
    selftest-submodule-byte-integrity)
        section "Recursive submodule byte-integrity regression"
        sandbox="$physical_root/$generated/submodule-byte-selftest"
        source_repo="$physical_root/$generated/submodule-byte-source"
        rm -rf "$generated"
        mkdir -p "$sandbox" "$source_repo"
        cleanup_submodule_byte_selftest() {
            rm -rf "$sandbox" "$source_repo"
        }
        trap cleanup_submodule_byte_selftest EXIT
        trap 'cleanup_submodule_byte_selftest; exit 1' HUP INT TERM

        (
            cd "$source_repo"
            git init -q
            printf 'filtered.txt filter=conceal\n' >.gitattributes
            printf 'canonical\n' >filtered.txt
            git config filter.conceal.clean 'cat >/dev/null; printf "canonical\\n"'
            git config filter.conceal.smudge cat
            git add .gitattributes filtered.txt
            git -c user.name=Regent -c user.email=regent.invalid commit -qm baseline
        )
        (
            cd "$sandbox"
            git init -q
            printf 'parent\n' >parent.txt
            git add parent.txt
            git -c user.name=Regent -c user.email=regent.invalid commit -qm baseline
            git -c protocol.file.allow=always submodule add -q "$source_repo" dependency
            git -c user.name=Regent -c user.email=regent.invalid commit -qam submodule
            git -C dependency config filter.conceal.clean 'cat >/dev/null; printf "canonical\\n"'
            git -C dependency config filter.conceal.smudge cat
            indexed_before=$(git -C dependency rev-parse :filtered.txt)
            printf 'concealed raw bytes\n' >dependency/filtered.txt
            git -C dependency add filtered.txt
            [ "$(git -C dependency rev-parse :filtered.txt)" = "$indexed_before" ] ||
                fail "the synthetic clean filter changed the indexed blob"
            [ -z "$(git -C dependency status --porcelain=v1 --untracked-files=all --ignored=matching)" ] ||
                fail "the synthetic clean filter did not conceal its tracked edit from Git status"
        )

        selftest_status=0
        selftest_output=$(
            {
                cd "$sandbox"
                require_clean_worktree
            } 2>&1
        ) || selftest_status=$?
        printf '%s\n' "$selftest_output"
        [ "$selftest_status" -ne 0 ] || fail "clean-filter-concealed recursive submodule bytes exited 0"
        case "$selftest_output" in
            *'tracked filesystem mismatch in recursive submodule dependency: filtered.txt: bytes differ from the indexed blob'*) : ;;
            *) fail "the recursive submodule regression stopped outside the raw indexed-byte boundary" ;;
        esac
        case "$selftest_output" in
            *'FORK GATE PASS'*) fail "concealed recursive submodule bytes printed this gate's pass marker" ;;
        esac

        cleanup_submodule_byte_selftest
        trap - EXIT HUP INT TERM
        printf '\na clean-filter-concealed recursive submodule edit failed raw indexed-byte verification\n'
        printf 'the no-provider regression printed no FORK GATE PASS\n'
        printf 'SUBMODULE BYTE-INTEGRITY REGRESSION PASS\n'
        exit 0
        ;;
    *) fail "unknown mode '$mode'; use discover, check, selftest-dead-endpoint, selftest-dirty-worktree, selftest-python-cache-worktree, selftest-hidden-worktree, selftest-stale-dependency-receipt, selftest-source-authority, selftest-git-context, selftest-replacement-refs, selftest-post-render-receipt, selftest-fork-clean-build, or selftest-submodule-byte-integrity" ;;
esac
export FOUNDRY_PROFILE

if [ "$mode" = check ]; then
    rm -f "$check_receipt" "$check_receipt_tmp"
    trap cleanup_unpublished_receipt EXIT
    trap 'cleanup_unpublished_receipt; exit 1' HUP INT TERM
fi

# ---------------------------------------------------------------------------
section "Authority and read-only boundary"
# ---------------------------------------------------------------------------

command -v git >/dev/null 2>&1 || fail "git is not on PATH"
command -v forge >/dev/null 2>&1 || fail "forge is not on PATH"
command -v cast >/dev/null 2>&1 || fail "cast is not on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 is not on PATH"

# The offline gate must have already passed on this exact tree. Its receipt is reused rather
# than recomputed, so the two gates cannot disagree about the dependency closure.
[ -f "$offline_receipt" ] ||
    fail "the offline gate's dependency receipt is absent; run bin/gate.sh on this tree first"
checkout_commit=$(git rev-parse HEAD)
checkout_tree=$(git rev-parse 'HEAD^{tree}')
checkout_src_tree=$(git rev-parse "HEAD:$component/src")
verify_offline_receipt_identity "$offline_receipt" "$checkout_commit" "$checkout_tree" "$checkout_src_tree" ||
    fail "the offline dependency receipt does not bind this checkout"

# Nothing here may carry signing authority. A key in the environment is a stop, not a warning.
for forbidden in PRIVATE_KEY ETH_PRIVATE_KEY MNEMONIC ETH_KEYSTORE ETH_FROM ETHERSCAN_API_KEY; do
    eval "value=\${$forbidden:-}"
    [ -z "$value" ] || fail "$forbidden is set; this gate is read-only and refuses to run beside signing authority"
done

# The endpoint is consumed, never printed. Only its presence and its shape are ever reported.
#
# Presence alone is not enough. An authorized attempt has already been made where the value injected
# here was not an endpoint at all: it created no fork, installed no observation, closed no claim and
# certified nothing, and the failure only surfaced once Forge tried to open a fork with it. The shape
# test below moves that refusal to the boundary, before any provider access and before the harness
# can start. It is a refusal, not a probe — nothing is dialled, and the value itself is neither
# printed nor persisted in either branch.
eval "endpoint=\${$RPC_ENV:-}"
[ -n "$endpoint" ] ||
    fail "no read-only Base provider is injected under $RPC_ENV; fork claims stay pending and C5 cannot close"
case "$endpoint" in
    http://?* | https://?* | ws://?* | wss://?*) : ;;
    *) fail "the value injected under $RPC_ENV is not an http(s) or ws(s) endpoint; its value is never printed" ;;
esac
unset endpoint
printf 'a read-only Base endpoint is injected under %s and is never printed or persisted\n' "$RPC_ENV"

# ---------------------------------------------------------------------------
section "Phase preconditions"
# ---------------------------------------------------------------------------

status=discovery_pending
[ -f "$observations" ] &&
    status=$(python3 -c "import json;print(json.load(open('$observations'))['status'])")

if [ "$mode" = discover ]; then
    # An already-committed record is not a reason to refuse. A later candidate has to be observable
    # while the current one is still installed, or a re-observation would mean deleting reviewed
    # evidence first. Nothing about that is a write: this pass reads no committed observation, the
    # `fork-discovery` profile can write only gitignored scratch, and the committed state is proved
    # unchanged below before this mode exits.
    baseline_state=$(committed_state)
    if [ "$status" = observed_and_committed ]; then
        printf 'discovery: a reviewed observation is already committed; this pass neither reads nor '
        printf 'replaces it, and the candidate it writes stays ignored scratch until a human installs it\n'
    else
        printf 'discovery: no committed observation is read, and none can be written\n'
    fi
else
    [ -f "$observations" ] || fail "the committed fork observation record is absent: $observations"
    [ "$status" = observed_and_committed ] ||
        fail "the observation record is '$status'; run '$0 discover', review the candidate, install it, and commit it"

    # Every non-generated difference must already be committed. This is deliberately wider than
    # the observation and ledger: the fork harness, gate, docs and any arbitrary untracked file can
    # all change what was actually tested.
    require_clean_worktree
    initial_repository_identity=$repository_identity

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
    printf 'check: every tracked and untracked non-generated path is committed and clean\n'
fi

# ---------------------------------------------------------------------------
section "Evidence identity"
# ---------------------------------------------------------------------------

# The record names the production authority it was observed against, and both of those values are
# proved here — against Git and against this checkout — before any fork test can run. Otherwise a
# reviewed record is only self-describing prose: it would compare live Base against numbers taken
# from some other source tree without anything noticing.
if [ -f "$observations" ]; then
    verify_named_source_authority
else
    printf 'no observation record is installed yet, so there is no named source authority to prove\n'
fi

rm -rf "$generated"
mkdir -p "$generated"

forge_config="$generated/forge-config.json"
probe_out="$generated/chain-id-probe.out"
probe_err="$generated/chain-id-probe.err"
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

# Both happen offline. The profile-specific clean destroys every prior fork artifact and compiler
# cache entry before this single explicit build from the physically verified source checkout.
FOUNDRY_OFFLINE=true forge fmt --check
clean_fork_profile_build_state "$FOUNDRY_PROFILE"
FOUNDRY_OFFLINE=true forge build

# ---------------------------------------------------------------------------
section "Base endpoint boundary"
# ---------------------------------------------------------------------------

# The first provider contact this gate makes, and it happens before any Forge fork test in either
# mode. `bin/fork-gate.sh selftest-dead-endpoint` is this refusal's regression.
probe_base_chain_id

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

    # Discovery may not have touched the committed record or the ledger, even indirectly. The
    # comparison is against this run's own baseline rather than against emptiness, so a candidate
    # observed beside an already-committed record still proves the exact thing that matters: nothing
    # about those two files moved while the provider was reachable.
    after_state=$(committed_state)
    [ "$after_state" = "$baseline_state" ] ||
        fail "the discovery pass changed a committed file, which it must never do:
before: $baseline_state
after:  $after_state"

    # ---------------------------------------------------------------------------
    section "Provider-secret scan"
    # ---------------------------------------------------------------------------

    python3 "$checker" secrets \
        --forge-config "$forge_config" \
        --scan "$generated" reports/frozen abi contracts requirements docs/audit docs/security test-fork

    # ---------------------------------------------------------------------------
    section "Operator transition"
    # ---------------------------------------------------------------------------

    if [ "$status" = observed_and_committed ]; then
        cat <<TRANSITION

A reviewable REPLACEMENT candidate is at:

    $candidate

The record now at $observations is unchanged, and the fork claims in
$ledger are already active. Nothing about this candidate has been
blessed and nothing reads it. To make it the evidence instead, deliberately:

  1. read every observed value and check it against an independent source;
  2. diff this candidate against the record now at $observations and
     explain every difference outside the two headers before accepting it — a moved runtime hash,
     proxy family, implementation or fee controller is chain drift to account for, not drift to
     absorb silently;
  3. fill in transaction_gas_schedule — the chain does not expose those rules, so discovery
     leaves them zero and the reviewer supplies the ones active at the newly recorded headers;
  4. fill in source_authority with the production authority commit and the src/ tree it carries;
     discovery cannot know either, and check mode proves both against Git and this checkout;
  5. set "status" to "observed_and_committed";
  6. overwrite $observations with it;
  7. leave $ledger alone unless a claim's activation actually changed —
     "fork" is already an activated gate and every fork claim is already active, so there is
     normally nothing to flip;
  8. commit whichever of the two files changed;
  9. run: $0 check

Until step 8 lands, '$0 check' still checks against the OLD committed record, and this
candidate is scratch that closes nothing.

TRANSITION
    else
        cat <<TRANSITION

A reviewable candidate is at:

    $candidate

Nothing has been blessed. To turn it into evidence, deliberately:

  1. read every observed value and check it against an independent source;
  2. fill in transaction_gas_schedule — the chain does not expose those rules, so discovery
     leaves them zero and the reviewer supplies the ones active at the recorded headers;
  3. fill in source_authority with the production authority commit and the src/ tree it carries;
     discovery cannot know either, and check mode proves both against Git and this checkout;
  4. set "status" to "observed_and_committed";
  5. install it as $observations;
  6. add "fork" to activated_gates in $ledger and flip every fork claim to active;
  7. commit both files;
  8. run: $0 check

Until step 7 lands, '$0 check' refuses to run, and every fork claim stays pending.

TRANSITION
    fi
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

# Every remaining ForkPinned selector — the complete portfolio, including the one full production
# lifecycle and the three complete-transaction envelopes.
pinned_status=0
RUST_LOG=error forge test --json -vv --no-match-contract "$DISCOVERY_CONTRACT" --match-test 'ForkPinned' --fork-url "$RPC_ALIAS" \
    >"$pinned_report" 2>"$pinned_log" || pinned_status=$?
scan_then_display "$pinned_log"
[ "$pinned_status" -eq 0 ] ||
    fail "the pinned-header fork run exited $pinned_status; its scanned diagnostics are retained under $generated"

# ---------------------------------------------------------------------------
section "Later header"
# ---------------------------------------------------------------------------

# Only the remaining ForkLatest selectors, which are the focused fresh-head subset the harness now
# carries: DEP-040, DEP-041, DEP-042, DEP-043, DEP-047, DEP-050, DEP-051, DEP-052 and GAS-006. The
# selectors are the enumeration — no claim can be quietly added to or dropped from this run without
# the compiled listing and the ledger reconciliation below disagreeing about it.
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
# twenty-seven mapped selectors — eighteen claims at the pinned header and the focused nine-claim
# subset at the later head — and the two reports are reconciled against it as one merged multiset,
# so every mapped selector executes exactly once across the whole gate. A selector that exists but
# runs at neither header, or one that runs but is not mapped, fails here.
python3 "$checker" ledger \
    --ledger "$ledger" \
    --spec SPEC.md \
    --gates "$GATES" \
    --test-list "$test_list" \
    --test-report "$pinned_report" "$later_report" \
    --receipt "$offline_receipt"

# ---------------------------------------------------------------------------
section "Normalized verdict agreement across the cross-header subset (DEP-050)"
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

# The exact cross-header claim set, written out rather than derived from whatever the later run
# happened to emit. Reconciling the intersection would pass a later run that had silently shrunk to
# one claim, so the later key set is held to an equality against this instead: a key missing from it
# and a key beyond it are both failures.
REQUIRED_LATER = {
    "DEP-040",
    "DEP-041",
    "DEP-042",
    "DEP-043",
    "DEP-047",
    "DEP-051",
    "DEP-052",
    "GAS-006",
}

# DEP-050's own verdicts are per-binding and per-measurement, so their exact keys come from the
# pinned verdict test rather than from a literal list that would have to be edited in step with it.
# The later head must carry every one of them and no other.
dep_050 = {claim for claim in pinned if claim.startswith("DEP-050.")}
expected_later = REQUIRED_LATER | dep_050

problems = []
if not pinned:
    problems.append("the pinned run emitted no normalized verdict")
if not dep_050:
    problems.append("the pinned run emitted no DEP-050 verdict, so the cross-header set is undefined")
for claim in sorted(REQUIRED_LATER - set(pinned)):
    problems.append(f"claim {claim} is a cross-header claim but reached no verdict at the pinned header")
for claim in sorted(expected_later - set(later)):
    problems.append(f"claim {claim} is a cross-header claim but reached no verdict at the later head")
for claim in sorted(set(later) - expected_later):
    problems.append(f"claim {claim} reached a verdict at the later head but is not a cross-header claim")
for claim in sorted(expected_later & set(later) & set(pinned)):
    if pinned[claim] != later[claim]:
        problems.append(f"claim {claim}: pinned says [{pinned[claim]}], later head says [{later[claim]}]")

if problems:
    print("VERDICT RECONCILIATION FAILED", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    raise SystemExit(1)

print(
    f"normalized verdicts: {len(pinned)} recorded at the pinned header; the later head carries "
    f"exactly the {len(expected_later)} cross-header keys and agrees with every one"
)
PYTHON

# ---------------------------------------------------------------------------
section "Check-only proof"
# ---------------------------------------------------------------------------

# The entire non-generated worktree is still clean. Nothing this run did wrote a tracked file or
# left arbitrary untracked state, and no candidate was produced under the read-only check profile.
require_clean_worktree
[ "$repository_identity" = "$initial_repository_identity" ] ||
    fail "tracked repository bytes changed during the fork check"
[ ! -f "$candidate" ] || fail "the check run produced a discovery candidate; check mode observes nothing"
printf 'the entire non-generated worktree is still byte-identical to the tested commit\n'

# ---------------------------------------------------------------------------
section "Commit-bound fork-check receipt"
# ---------------------------------------------------------------------------

# This receipt is the handoff to the deployment packet renderer. It stays at a temporary path until
# every remaining fallible scan and identity proof succeeds, then one same-directory rename publishes
# it atomically. The exit trap removes both names on every earlier failure.
python3 - "$check_receipt_tmp" "$checkout_commit" "$checkout_tree" "$checkout_src_tree" \
    "$pinned_report" "$later_report" "$test_list" <<'PYTHON'
import hashlib
import json
import sys

receipt_path, commit, tree, src_tree, pinned_path, later_path, list_path = sys.argv[1:]


def sha256(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def successful_selector_count(path):
    count = 0
    failures = []
    for suite in json.load(open(path, encoding="utf-8")).values():
        for selector, outcome in suite.get("test_results", {}).items():
            count += 1
            if outcome.get("status") != "Success":
                failures.append(selector)
    if failures:
        raise SystemExit(f"{path}: non-success selectors reached receipt rendering: {', '.join(failures)}")
    return count


pinned_count = successful_selector_count(pinned_path)
later_count = successful_selector_count(later_path)
if (pinned_count, later_count) != (18, 9):
    raise SystemExit(
        f"fork selector count mismatch: expected pinned/later 18/9, found {pinned_count}/{later_count}"
    )

receipt = {
    "artifact": "regent-fork-check-receipt",
    "version": 1,
    "status": "passed",
    "worktree": "clean",
    "tested_identity": {"commit": commit, "tree": tree, "src_tree": src_tree},
    "executed_selectors": {
        "pinned": pinned_count,
        "later": later_count,
        "total": pinned_count + later_count,
    },
    "reports": {
        "pinned": {"path": pinned_path, "sha256": sha256(pinned_path)},
        "later": {"path": later_path, "sha256": sha256(later_path)},
        "compiled_test_list": {"path": list_path, "sha256": sha256(list_path)},
    },
}
open(receipt_path, "w", encoding="utf-8").write(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
print(
    f"receipt: commit {commit}, tree {tree}, src {src_tree}; "
    f"selectors {pinned_count}+{later_count}={pinned_count + later_count}"
)
PYTHON

# ---------------------------------------------------------------------------
section "Provider-secret scan"
# ---------------------------------------------------------------------------

# Everything this run produced — both JSON reports, both stderr logs, and the effective fork
# configuration — plus every committed evidence location, recursively. A resolved endpoint
# anywhere fails here.
python3 "$checker" secrets \
    --forge-config "$forge_config" \
    --scan "$generated" reports/frozen abi contracts requirements docs/audit docs/security test-fork

# The temporary receipt was inside the scanned generated tree. Re-prove the physical repository,
# canonical Git identity and cleanliness after its write. Nothing fallible remains after publication.
assert_physical_git_identity
require_clean_worktree
[ "$(git rev-parse HEAD)" = "$checkout_commit" ] || fail "HEAD changed during the fork check"
[ "$(git rev-parse 'HEAD^{tree}')" = "$checkout_tree" ] || fail "the tested tree changed during the fork check"
[ "$(git rev-parse "HEAD:$component/src")" = "$checkout_src_tree" ] || fail "the tested src tree changed during the fork check"
mv "$check_receipt_tmp" "$check_receipt"
printf 'fork-check receipt: %s\n' "$check_receipt"

printf '\nFORK GATE PASS\n'
receipt_published=true
