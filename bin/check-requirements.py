#!/usr/bin/env python3
"""Structured reconciliation for the autolaunch-contracts required gate.

`bin/gate.sh` runs the external tools; this script performs every structured comparison and
is the only place that decides whether frozen material still equals its authority. Every
check fails closed, and every expectation is compared against an authority that is not the
candidate's own restatement of it.

Subcommands, in the order the gate runs them:

  preflight  Reconcile `requirements/frozen-identity.json` against SPEC.md, the real
             recursive Git metadata, the installed tool identities, the effective Foundry
             configuration, the chain manifest, the compiled binding source, and the pinned
             CCA implementation source. Derive the frozen build from SPEC.md and reconcile
             both the fixture and the effective configuration against it. Validate the
             ledger's static shape. Write the dependency receipt that the ledger
             reconciliation later consumes.
  artifacts  Assert the compiler identity and settings recorded in the produced artifacts.
  ledger     Reconcile Foundry's own compiled test listing against the executed test report
             as multisets, then reconcile both against the ledger.
  security   Reconcile the Slither run: an unnarrowed configuration and command line, the
             pinned binary's whole registered detector portfolio, fresh and well-formed
             evidence, one visible disposition per exact result fingerprint at every
             severity, and a complete record for every inline suppression.

Counts printed here are informational gate output, never acceptance literals.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tomllib
from collections import Counter
from pathlib import Path

# --- ledger vocabulary -------------------------------------------------------

GATES = ("hermetic", "invariant", "fork", "deployment")

EVIDENCE_GATES = {
    "gate-dependency": "hermetic",
    "solidity-hermetic": "hermetic",
    "solidity-invariant": "invariant",
    "fork-execution": "fork",
    "deployment-ceremony": "deployment",
}

REQUIRED_FIELDS = ("id", "statement", "owner", "contract", "evidence_class", "gate", "status", "selectors")

REQUIREMENT_ID_RE = re.compile(r"^[A-Z]+-\d{3}$")
SELECTOR_RE = re.compile(r"^(?:test|testFuzz|invariant)_([A-Z]+)_(\d{3})_[A-Za-z0-9]\w*$")

# --- SPEC.md vocabulary ------------------------------------------------------

SPEC_PIN_RE = re.compile(r"^- (?P<label>[^:]+): `(?P<commit>[0-9a-f]{40})`$")
SPEC_BINDING_RE = re.compile(r"^\| (?P<label>[^|]+?) \| `(?P<address>0x[0-9a-fA-F]{40})` \|$")
SPEC_GROUP_RE = re.compile(r"^\| `(?P<group>[A-Z]+)-\*` \|")
SPEC_CODE_HASH_RE = re.compile(r"runtime code hash `(0x[0-9a-f]{64})`")

# The single SPEC.md line that governs the build. Every field the gate reconciles against
# `foundry.toml`, the frozen fixture, and the produced artifacts is read from here, so a
# build setting cannot drift without the controlling specification changing with it.
SPEC_BUILD_RE = re.compile(
    r"^- Solidity `(?P<solc_version>\d+\.\d+\.\d+)`, "
    r"(?P<evm_version>\w+) EVM target, "
    r"optimizer `(?P<optimizer_runs>\d+)`, "
    r"via-IR, bytecode metadata disabled$"
)

# --- source vocabulary -------------------------------------------------------

SOL_ADDRESS_CONST_RE = re.compile(r"^\s*address internal constant (\w+) = (0x[0-9a-fA-F]{40});\s*$")
SOL_UINT_CONST_RE = re.compile(r"^\s*uint256 internal constant (\w+) = (\d+);\s*$")
SOL_BYTES32_CONST_RE = re.compile(r"bytes32 internal constant (\w+) =\s*(0x[0-9a-fA-F]{64});")
ADDRESS_LITERAL_RE = re.compile(r"0x[0-9a-fA-F]{40}(?![0-9a-fA-F])")

SLITHER_DISABLE_RE = re.compile(r"slither-disable(?:-next-line|-start|-end)?\s+([\w,\- ]+)")
SLITHER_SUMMARY_RE = re.compile(
    r"analyzed \((?P<contracts>\d+) contracts with (?P<detectors>\d+) detectors\), "
    r"(?P<results>\d+) result\(s\) found"
)
SLITHER_CONFIG_COMPLAINT_RE = re.compile(
    r"(?i)(unknown key|unsupported key|invalid .{0,20}config|cannot parse .{0,20}config|error in config)"
)
SOL_DECLARATION_RE = re.compile(r"^\s*(?:abstract\s+)?(?:contract|library|interface)\s+\w+")


class Problems:
    """Collects every failure so one run reports the whole picture, then fails closed."""

    def __init__(self) -> None:
        self.messages: list[str] = []

    def add(self, message: str) -> None:
        self.messages.append(message)

    def expect(self, label: str, expected: object, found: object) -> bool:
        if expected == found:
            return True
        self.add(f"{label}: expected [{expected}], found [{found}]")
        return False

    def report(self, stage: str) -> int:
        if not self.messages:
            return 0
        print(f"\n{stage.upper()} RECONCILIATION FAILED", file=sys.stderr)
        for message in self.messages:
            print(f"  - {message}", file=sys.stderr)
        return 1


# =============================================================================
# shared loading
# =============================================================================


def load_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def constant_name(label: str) -> str:
    """The mechanical CONSTANT_CASE form of a SPEC.md binding label."""
    spaced = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", label)
    return re.sub(r"[^A-Za-z0-9]+", "_", spaced).strip("_").upper()


def read_spec(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    pins, bindings, groups, build = {}, [], [], None
    for line in text.splitlines():
        pin = SPEC_PIN_RE.match(line)
        if pin:
            pins[pin.group("label")] = pin.group("commit")
        binding = SPEC_BINDING_RE.match(line)
        if binding:
            bindings.append((binding.group("label").strip(), binding.group("address")))
        group = SPEC_GROUP_RE.match(line)
        if group:
            groups.append(group.group("group"))
        frozen_build = SPEC_BUILD_RE.match(line)
        if frozen_build:
            # "bytecode metadata disabled" is one specification decision with two Solidity
            # settings behind it; both are derived here rather than written down twice.
            build = {
                "solc_version": frozen_build.group("solc_version"),
                "evm_version": frozen_build.group("evm_version").lower(),
                "optimizer": True,
                "optimizer_runs": int(frozen_build.group("optimizer_runs")),
                "via_ir": True,
                "bytecode_hash": "none",
                "append_cbor": False,
            }
    code_hash = SPEC_CODE_HASH_RE.search(text)
    return {
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "pins": pins,
        "bindings": bindings,
        "groups": groups,
        "build": build,
        "code_hash": code_hash.group(1) if code_hash else None,
    }


def git(*args: str, cwd: str = ".") -> str | None:
    """Run git and return its stdout, or None if it failed.

    Only the trailing newline is removed: `git submodule status` and `git status
    --porcelain` both encode meaning in a line's leading character.
    """
    result = subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, text=True, check=False
    )
    return result.stdout.rstrip("\n") if result.returncode == 0 else None


# =============================================================================
# ledger: static shape
# =============================================================================


def load_ledger(path: Path) -> dict:
    with path.open("rb") as handle:
        return tomllib.load(handle)


def expected_status(entry: dict, activated_tickets: set[str], activated_gates: set[str]) -> str:
    both_on = entry.get("owner") in activated_tickets and entry.get("gate") in activated_gates
    return "active" if both_on else "pending"


def validate_ledger(ledger: dict, spec_groups: list[str], problems: Problems) -> dict[str, dict]:
    meta = ledger.get("ledger", {})
    groups = list(meta.get("groups", []))
    activated_tickets = set(meta.get("activated_tickets", []))
    activated_gates = set(meta.get("activated_gates", []))

    problems.expect("ledger requirement groups", spec_groups, groups)
    if not activated_tickets:
        problems.add("the ledger activates no ticket")
    if not activated_gates:
        problems.add("the ledger activates no gate")
    for gate in sorted(activated_gates - set(GATES)):
        problems.add(f"activated_gates names '{gate}', which is not a recorded gate")

    requirements: dict[str, dict] = {}
    selector_owner: dict[str, str] = {}

    for entry in ledger.get("requirement", []):
        identifier = str(entry.get("id", "<missing id>"))
        for field in REQUIRED_FIELDS:
            if field not in entry:
                problems.add(f"{identifier}: missing field '{field}'")
        if not REQUIREMENT_ID_RE.match(identifier):
            problems.add(f"{identifier}: malformed requirement id")
            continue
        if identifier in requirements:
            problems.add(f"{identifier}: duplicate requirement id")
            continue
        requirements[identifier] = entry

        group = identifier.split("-", 1)[0]
        if group not in groups:
            problems.add(f"{identifier}: group '{group}' is not a declared requirement group")
        if not str(entry.get("statement", "")).strip():
            problems.add(f"{identifier}: empty normative statement")
        if not str(entry.get("contract", "")).strip():
            problems.add(f"{identifier}: no owning contract")
        if not str(entry.get("owner", "")).strip():
            problems.add(f"{identifier}: no owning ticket")

        gate = entry.get("gate")
        if gate not in GATES:
            problems.add(f"{identifier}: gate '{gate}' is not a recorded gate")
        evidence_class = entry.get("evidence_class")
        if evidence_class not in EVIDENCE_GATES:
            problems.add(f"{identifier}: evidence class '{evidence_class}' is not recognized")
        elif EVIDENCE_GATES[evidence_class] != gate:
            problems.add(
                f"{identifier}: evidence class '{evidence_class}' cannot be closed by the '{gate}' gate"
            )

        # A gate-dependency claim is a repository fact the gate itself proves. Nothing else
        # may borrow that evidence class to escape needing real product evidence.
        if evidence_class == "gate-dependency":
            if not identifier.startswith("DEP-"):
                problems.add(f"{identifier}: only DEP-* claims may use the gate-dependency evidence class")
            if entry.get("contract") != "repository":
                problems.add(
                    f"{identifier}: gate-dependency claims must be owned by contract 'repository', "
                    f"not '{entry.get('contract')}'"
                )

        selectors = entry.get("selectors")
        if not isinstance(selectors, list) or not selectors:
            problems.add(f"{identifier}: carries no planned Foundry selector")
            selectors = []
        for selector in selectors:
            match = SELECTOR_RE.match(str(selector))
            if not match:
                problems.add(f"{identifier}: selector '{selector}' is not a well-formed Foundry test identity")
                continue
            if f"{match.group(1)}-{match.group(2)}" != identifier:
                problems.add(f"{identifier}: selector '{selector}' does not begin with its requirement id")
            if selector in selector_owner:
                problems.add(
                    f"{identifier}: selector '{selector}' is already planned by {selector_owner[selector]}"
                )
            else:
                selector_owner[selector] = identifier

        wanted = expected_status(entry, activated_tickets, activated_gates)
        if entry.get("status") not in {"active", "pending"}:
            problems.add(f"{identifier}: status '{entry.get('status')}' is not active or pending")
        elif entry.get("status") != wanted:
            reason = (
                "its owning ticket and its gate are both activated"
                if wanted == "active"
                else f"owner activated={entry.get('owner') in activated_tickets}, "
                f"gate activated={entry.get('gate') in activated_gates}"
            )
            problems.add(f"{identifier}: status must be '{wanted}' ({reason})")

    for group in groups:
        if not any(identifier.startswith(f"{group}-") for identifier in requirements):
            problems.add(f"required requirement group {group} has no entry")

    return requirements


# =============================================================================
# preflight
# =============================================================================


def parse_binding_source(path: Path, problems: Problems) -> dict:
    text = path.read_text(encoding="utf-8")
    addresses: dict[str, str] = {}
    for line in text.splitlines():
        match = SOL_ADDRESS_CONST_RE.match(line)
        if match:
            if match.group(1) in addresses:
                problems.add(f"{path}: address constant {match.group(1)} is declared twice")
            addresses[match.group(1)] = match.group(2)

    # Nothing that looks like an address may hide in this file outside a declared binding.
    declared = set(addresses.values())
    for literal in ADDRESS_LITERAL_RE.findall(text):
        if literal not in declared:
            problems.add(f"{path}: carries the address literal {literal} outside a declared binding")

    uints = {m.group(1): int(m.group(2)) for m in map(SOL_UINT_CONST_RE.match, text.splitlines()) if m}
    bytes32 = {m.group(1): m.group(2) for m in SOL_BYTES32_CONST_RE.finditer(text)}
    return {"addresses": addresses, "uints": uints, "bytes32": bytes32}


def parse_manifest(path: Path) -> dict:
    """Read the chain manifest without a YAML dependency, by exact line shape."""
    scalars: dict[str, str] = {}
    bindings: list[dict[str, str]] = []
    admission: dict[str, str] = {}
    section = None
    current: dict[str, str] | None = None

    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if not raw.startswith(" ") and raw.rstrip().endswith(":"):
            section = raw.rstrip()[:-1]
            current = None
            continue
        top = re.match(r"^([a-z_]+):\s*(.+?)\s*$", raw)
        if top and not raw.startswith(" "):
            scalars[top.group(1)] = top.group(2).strip('"')
            section = None
            continue
        item = re.match(r"^\s+- ([a-z_]+):\s*(.+?)\s*$", raw)
        if item and section == "bindings":
            current = {item.group(1): item.group(2).strip('"')}
            bindings.append(current)
            continue
        field = re.match(r"^\s+([a-z_]+):\s*(.+?)\s*$", raw)
        if field:
            if section == "bindings" and current is not None:
                current[field.group(1)] = field.group(2).strip('"')
            elif section == "admission":
                admission.setdefault(field.group(1), field.group(2).strip('"'))
    return {"scalars": scalars, "bindings": bindings, "admission": admission}


def walk_closure(problems: Problems) -> list[tuple[str, str, str, str]]:
    """Enumerate the complete recursive gitlink closure from committed Git trees.

    Returns `(display_path, parent_repository, path_inside_that_parent, recorded_commit)`.

    The enumeration reads each repository's own committed tree, so it depends on no
    `.gitmodules` declaration and on none of git's submodule bookkeeping. The parent is
    discovered rather than guessed from the path text, because a dependency may nest its
    own submodules anywhere in its tree — the pinned Optimism monorepo, for example, keeps
    them under `packages/contracts-bedrock/lib/`, not under `lib/`.
    """
    entries: list[tuple[str, str, str, str]] = []
    seen: set[str] = set()
    pending = ["."]

    while pending:
        repo = pending.pop()
        listing = git("ls-tree", "-r", "HEAD", cwd=repo)
        if listing is None:
            problems.add(f"cannot read the committed tree of {repo}")
            continue
        for line in listing.splitlines():
            meta, _, path = line.partition("\t")
            fields = meta.split()
            if len(fields) < 3 or fields[1] != "commit":
                continue
            display = path if repo == "." else f"{repo}/{path}"
            if display in seen:
                problems.add(f"gitlink {display} is enumerated more than once")
                continue
            seen.add(display)
            entries.append((display, repo, path, fields[2]))
            if (Path(display) / ".git").exists():
                pending.append(display)

    return entries


def name_dirty_submodule(path: str, problems: Problems) -> None:
    """Walk down a modified submodule until the change that made it dirty is named."""
    for _ in range(16):
        porcelain = git("status", "--porcelain", cwd=path)
        if not porcelain:
            problems.add(f"submodule {path} reports modified but shows no change of its own")
            return
        first = porcelain.splitlines()[0]
        child = f"{path}/{first[3:].strip()}"
        if not Path(child).is_dir() or not (Path(child) / ".git").exists():
            problems.add(f"submodule tree is dirty: {path} ({first})")
            return
        path = child
    problems.add(f"submodule tree is dirty below {path}")


def check_recursive_closure(frozen: dict, problems: Problems) -> None:
    """Prove the complete recursive gitlink closure from real Git metadata only.

    The gate never invents an expected commit for a nested dependency: the authority for
    each one is the tree of the pinned parent that records it.
    """
    entries = walk_closure(problems)
    observed = [display for display, _, _, _ in entries]

    frozen_paths = list(frozen["recursive_closure"])
    if frozen_paths != sorted(frozen_paths):
        problems.add("the frozen recursive closure is not sorted")
    for path in sorted(set(frozen_paths) - set(observed)):
        problems.add(f"frozen closure path is absent from the materialized tree: {path}")
    for path in sorted(set(observed) - set(frozen_paths)):
        problems.add(f"the tree carries a submodule the frozen closure does not declare: {path}")

    # The authority for a nested commit is the committed tree of the parent that records
    # it, never a value written down in this repository.
    for display, parent, _, recorded in entries:
        if not (Path(display) / ".git").exists():
            problems.add(f"recursive submodule is not initialized: {display}")
            continue
        found = git("rev-parse", "HEAD", cwd=display)
        if found is None:
            problems.add(f"cannot read HEAD of {display}; its material is absent")
        elif found != recorded:
            problems.add(f"{display}: {parent} records {recorded}, tree carries {found}")

    # git's own recursive view, as a second and independent implementation of the same
    # claim: every entry initialized and at the gitlink its parent records.
    native = git("submodule", "status", "--recursive")
    if native is None:
        problems.add("unable to read the recursive submodule status")
    else:
        for line in native.splitlines():
            if not line.strip():
                continue
            prefix, fields = line[0], line[1:].split()
            path = fields[1] if len(fields) > 1 else line
            if prefix == "-":
                problems.add(f"recursive submodule status reports {path} uninitialized")
            elif prefix == "+":
                problems.add(f"recursive submodule status reports {path} off its parent's gitlink")
            elif prefix != " ":
                problems.add(f"recursive submodule status reports {path} unresolved ('{prefix}')")

    # Cleanliness propagates: an uncommitted change anywhere in the closure makes every
    # repository above it report its child as modified, so one root walk reaches all of it.
    roots = list(frozen["root_submodules"])
    for line in (git("status", "--porcelain") or "").splitlines():
        entry = line[3:].split(" -> ")[-1].strip().strip('"')
        if any(entry == root or entry.startswith(f"{root}/") for root in roots):
            name_dirty_submodule(entry, problems)


def preflight(args: argparse.Namespace) -> int:
    problems = Problems()
    frozen = load_json(Path(args.frozen))
    spec = read_spec(Path(args.spec))
    receipt: list[tuple[str, str]] = []

    def record(requirement: str, detail: str) -> None:
        receipt.append((requirement, detail))

    # --- controlling authority ------------------------------------------------
    if problems.expect("SPEC.md digest", frozen["spec_sha256"], spec["sha256"]):
        record("DEP-011", f"SPEC.md hashes to the frozen authority digest {spec['sha256']}")

    # --- founder pins ---------------------------------------------------------
    for key, pin in frozen["pins"].items():
        label, path, commit = pin["spec_label"], pin["path"], pin["commit"]
        spec_commit = spec["pins"].get(label)
        if spec_commit is None:
            problems.add(f"SPEC.md pins no commit under the bullet label [{label}]")
            continue
        ok = problems.expect(f"founder pin {key} against SPEC.md", spec_commit, commit)
        ok &= problems.expect(f"materialized pin {key}", commit, git("rev-parse", "HEAD", cwd=path))
        if ok:
            record(pin["requirement"], f"{path} is at the SPEC.md literal for [{label}] ({commit})")

    # --- gitlinks the pinned parents themselves record ------------------------
    relations = frozen["relations"]
    cca_path = frozen["pins"]["cca"]["path"]
    launcher_path = frozen["pins"]["liquidity_launcher"]["path"]

    recorded_launcher = git("rev-parse", "HEAD:lib/liquidity-launcher", cwd=cca_path)
    ok = problems.expect(
        "launcher gitlink recorded by the pinned CCA tree",
        relations["cca_recorded_launcher"],
        recorded_launcher,
    )
    ok &= problems.expect(
        "pinned CCA agrees with the founder launcher pin",
        frozen["pins"]["liquidity_launcher"]["commit"],
        recorded_launcher,
    )
    if ok:
        record("DEP-004", f"the pinned CCA tree records the founder launcher commit {recorded_launcher}")

    recorded_forge_std = git("rev-parse", "HEAD:lib/forge-std", cwd=launcher_path)
    ok = problems.expect(
        "forge-std gitlink recorded by the pinned launcher tree",
        relations["launcher_recorded_forge_std"],
        recorded_forge_std,
    )
    ok &= problems.expect(
        "this repository's forge-std mirrors the launcher's",
        recorded_forge_std,
        git("rev-parse", "HEAD", cwd="lib/forge-std"),
    )
    if ok:
        record("DEP-006", f"lib/forge-std mirrors the launcher's forge-std gitlink {recorded_forge_std}")

    recorded_uerc20 = git("rev-parse", "HEAD:lib/uerc20-factory", cwd=launcher_path)
    ok = problems.expect(
        "UERC20 gitlink recorded by the pinned launcher tree",
        relations["launcher_recorded_uerc20"],
        recorded_uerc20,
    )
    founder_uerc20 = frozen["pins"]["uerc20_factory"]["commit"]
    if recorded_uerc20 == founder_uerc20:
        problems.add(
            "the founder UERC20 factory pin and the launcher's nested UERC20 dependency have "
            f"converged on {founder_uerc20}; they must stay distinct"
        )
        ok = False
    if ok:
        record(
            "DEP-007",
            f"founder UERC20 {founder_uerc20} stays distinct from the launcher's nested {recorded_uerc20}",
        )

    # --- complete recursive closure -------------------------------------------
    before = len(problems.messages)
    check_recursive_closure(frozen, problems)
    if len(problems.messages) == before:
        record(
            "DEP-005",
            f"{len(frozen['recursive_closure'])} recursive submodules are initialized, clean, and "
            "each at the gitlink its own parent records",
        )

    declared_roots = git("config", "--file", ".gitmodules", "--get-regexp", r"\.path$")
    root_paths = sorted(line.split()[1] for line in (declared_roots or "").splitlines() if line.strip())
    if problems.expect(".gitmodules root submodule set", sorted(frozen["root_submodules"]), root_paths):
        record("DEP-008", f".gitmodules declares exactly the frozen root set: {', '.join(root_paths)}")

    # --- tool identity --------------------------------------------------------
    tools = dict(
        line.split(" ", 1) for line in Path(args.tool_identity).read_text(encoding="utf-8").splitlines() if line
    )
    tools = {key: value.strip() for key, value in tools.items()}
    if all(
        problems.expect(f"{key} identity", frozen["toolchain"][key], tools.get(key))
        for key in sorted(frozen["toolchain"])
    ):
        record(
            "DEP-010",
            "forge {forge_version} ({forge_commit_sha}); slither {slither_version}; "
            "python {python_version}".format(**tools),
        )

    # --- effective Foundry configuration --------------------------------------
    config = load_json(Path(args.forge_config))

    # --- specification-governed build -----------------------------------------
    # SPEC.md is the authority for the build, not `foundry.toml` and not the frozen fixture.
    # Each spec-governed field is compared against both, so changing the two repository
    # copies together still fails while the specification says something else.
    spec_build = spec["build"]
    if spec_build is None:
        problems.add(f"{args.spec} declares no parsable frozen build line")
    else:
        frozen_build = frozen["build"]
        effective = {
            "solc_version": config.get("solc"),
            "evm_version": config.get("evm_version"),
            "optimizer": config.get("optimizer"),
            "optimizer_runs": config.get("optimizer_runs"),
            "via_ir": config.get("via_ir"),
            "bytecode_hash": config.get("bytecode_hash"),
            "append_cbor": config.get("cbor_metadata"),
        }
        ok = True
        for field, wanted in spec_build.items():
            # The optimizer is enabled by SPEC.md but is not a separately frozen fixture
            # field; the fixture records only the settings that reach an artifact.
            if field in frozen_build:
                ok &= problems.expect(f"frozen {field} against SPEC.md", wanted, frozen_build[field])
            ok &= problems.expect(f"effective {field} against SPEC.md", wanted, effective[field])

        # The full compiler build suffix is tool-owned identity, not a specification
        # literal; SPEC.md governs only the semantic version it must begin with.
        identity = str(frozen_build["solc_identity"])
        if not identity.startswith(f"{spec_build['solc_version']}+"):
            problems.add(
                f"frozen compiler identity [{identity}] does not begin with the SPEC.md "
                f"semantic version [{spec_build['solc_version']}]"
            )
            ok = False
        if ok:
            record(
                "DEP-009",
                f"SPEC.md governs Solidity {spec_build['solc_version']}, {spec_build['evm_version']}, "
                f"optimizer {spec_build['optimizer_runs']}, via-IR {spec_build['via_ir']}, bytecode hash "
                f"{spec_build['bytecode_hash']}, appendCBOR {spec_build['append_cbor']}, and the frozen "
                f"and effective build settings equal it",
            )

    # --- gate posture and test portfolio --------------------------------------
    ok = problems.expect("effective offline setting", frozen["foundry"]["offline"], config.get("offline"))
    ok &= problems.expect("effective ffi setting", frozen["foundry"]["ffi"], config.get("ffi"))
    if ok:
        record("DEP-014", "the effective Foundry configuration is offline with FFI disabled")

    ok = True
    for name in ("fuzz", "invariant"):
        effective = config.get(name, {})
        for key, want in frozen[name].items():
            found = effective.get(key)
            if key == "seed":
                want, found = int(str(want), 16), int(str(found), 16) if found is not None else None
            ok &= problems.expect(f"effective {name}.{key}", want, found)
    if ok:
        record(
            "DEP-015",
            "the effective fuzz and invariant seed, run, depth, rejection, revert, and shrink "
            "settings equal the frozen values",
        )

    # --- bindings -------------------------------------------------------------
    before = len(problems.messages)
    source = parse_binding_source(Path(args.bindings), problems)
    manifest = parse_manifest(Path(args.manifest))
    manifest_bindings = {entry.get("id"): entry for entry in manifest["bindings"]}
    frozen_bindings = {entry["key"]: entry for entry in frozen["bindings"]}

    spec_keys: list[str] = []
    for label, address in spec["bindings"]:
        constant = constant_name(label)
        key = constant.lower()
        spec_keys.append(key)

        entry = frozen_bindings.get(key)
        if entry is None:
            problems.add(f"the frozen identity binds no '{key}' for the SPEC.md row [{label}]")
        else:
            problems.expect(f"frozen binding {key} label", label, entry.get("label"))
            problems.expect(f"frozen binding {key} constant", constant, entry.get("constant"))
            problems.expect(f"frozen binding {key} address", address, entry.get("address"))

        entry = manifest_bindings.get(key)
        if entry is None:
            problems.add(f"the chain manifest declares no binding id '{key}' for the SPEC.md row [{label}]")
        else:
            problems.expect(f"manifest binding {key} label", label, entry.get("label"))
            problems.expect(f"manifest binding {key} constant", constant, entry.get("constant"))
            problems.expect(f"manifest binding {key} address", address, entry.get("address"))

        if constant not in source["addresses"]:
            problems.add(f"{args.bindings} declares no constant {constant} for the SPEC.md row [{label}]")
        else:
            problems.expect(f"binding source {constant}", address, source["addresses"][constant])

    problems.expect("frozen binding key set", spec_keys, [entry["key"] for entry in frozen["bindings"]])
    problems.expect("manifest binding id set", spec_keys, [entry.get("id") for entry in manifest["bindings"]])
    problems.expect(
        "binding source constant set",
        [constant_name(label) for label, _ in spec["bindings"]],
        list(source["addresses"]),
    )

    code_hash = spec["code_hash"]
    if code_hash is None:
        problems.add("SPEC.md declares no CCA runtime code hash")
    else:
        problems.expect("frozen CCA runtime code hash", code_hash, frozen["admission"]["runtime_code_hash"])
        problems.expect("manifest CCA runtime code hash", code_hash, manifest["admission"].get("runtime_code_hash"))
        problems.expect(
            "binding source CCA runtime code hash",
            code_hash,
            source["bytes32"].get("CCA_FACTORY_RUNTIME_CODE_HASH"),
        )

    chain_id = frozen["chain"]["id"]
    problems.expect("manifest chain name", frozen["chain"]["name"], manifest["scalars"].get("chain"))
    problems.expect("manifest chain id", str(chain_id), manifest["scalars"].get("chain_id"))
    problems.expect("binding source chain id", chain_id, source["uints"].get("BASE_CHAIN_ID"))

    if len(problems.messages) == before:
        record(
            "DEP-012",
            f"the manifest, the frozen identity, and {args.bindings} bind the same "
            f"{len(spec_keys)} SPEC.md bindings under the same SPEC.md names, plus the chain "
            f"id {chain_id} and the SPEC.md CCA runtime code hash",
        )

    # --- CCA admission provenance ---------------------------------------------
    admission = frozen["admission"]
    problems.expect(
        "admission provenance commit",
        frozen["pins"]["cca"]["commit"],
        admission["provenance_commit"],
    )
    implementation = Path(cca_path) / admission["provenance_path"]
    if not implementation.is_file():
        problems.add(f"the pinned CCA source has no file at {admission['provenance_path']}")
    else:
        signature = admission["signature"]
        name = signature[: signature.index("(")]
        definition = re.compile(
            r"^\s*function\s+"
            + re.escape(name)
            + r"\(\s*\)\s+external\s+"
            + re.escape(admission["state_mutability"])
            + r"\s+returns\s*\(\s*"
            + re.escape(admission["returns"])
            + r"\s*\)\s*\{",
            re.MULTILINE,
        )
        body = implementation.read_text(encoding="utf-8")
        found = definition.findall(body)
        if len(found) != 1:
            problems.add(
                f"{implementation} does not define exactly one body-bearing "
                f"`function {signature} external {admission['state_mutability']} "
                f"returns ({admission['returns']})`"
            )
        elif "/interfaces/" in admission["provenance_path"]:
            problems.add(f"the admitted signature's provenance path {implementation} is an interface path")
        else:
            record(
                "DEP-013",
                f"{signature} is defined with the exact admitted shape by the pinned implementation "
                f"{implementation}",
            )
        problems.expect(
            "manifest admission signature", signature, manifest["admission"].get("signature")
        )
        problems.expect(
            "manifest admission selector", admission["selector"], manifest["admission"].get("selector")
        )

    # --- ledger static shape ---------------------------------------------------
    requirements = validate_ledger(load_ledger(Path(args.ledger)), spec["groups"], problems)

    # --- threat-model references ----------------------------------------------
    # C0-I12: every mitigation the threat model names must be a real ledger claim, so a
    # renumbered or deleted requirement cannot leave a dangling promise behind.
    threat_model = Path(args.threat_model).read_text(encoding="utf-8")
    referenced = sorted(set(re.findall(r"`([A-Z]+-\d{3})`", threat_model)))
    if not referenced:
        problems.add(f"{args.threat_model} names no requirement as a mitigation")
    for identifier in referenced:
        if identifier not in requirements:
            problems.add(f"{args.threat_model} names {identifier}, which the ledger does not define")

    Path(args.receipt).write_text(
        "".join(f"{requirement} verified: {detail}\n" for requirement, detail in sorted(receipt)),
        encoding="utf-8",
    )

    print(f"SPEC.md groups: {', '.join(spec['groups'])}")
    print(f"SPEC.md bindings reconciled: {len(spec_keys)}")
    print(f"recursive submodule closure: {len(frozen['recursive_closure'])} paths")
    print(f"threat-model mitigations referenced: {len(referenced)}")
    print(f"dependency receipts written: {len(receipt)}")
    return problems.report("preflight")


# =============================================================================
# artifacts
# =============================================================================


def artifacts(args: argparse.Namespace) -> int:
    problems = Problems()
    frozen = load_json(Path(args.frozen))["build"]

    seen: Counter[tuple] = Counter()
    for path in sorted(Path(args.out).rglob("*.json")):
        if "build-info" in path.parts:
            continue
        metadata = load_json(path).get("metadata")
        if metadata is None:
            continue
        settings = metadata.get("settings", {})
        optimizer = settings.get("optimizer", {})
        recorded = (
            metadata.get("compiler", {}).get("version"),
            optimizer.get("enabled"),
            optimizer.get("runs"),
            settings.get("viaIR"),
            settings.get("evmVersion"),
            settings.get("metadata", {}).get("bytecodeHash"),
            settings.get("metadata", {}).get("appendCBOR"),
        )
        seen[recorded] += 1

    expected = (
        frozen["solc_identity"],
        True,
        frozen["optimizer_runs"],
        frozen["via_ir"],
        frozen["evm_version"],
        frozen["bytecode_hash"],
        frozen["append_cbor"],
    )
    if not seen:
        problems.add(f"{args.out} contains no compiled artifact to inspect")
    for recorded, count in seen.items():
        if recorded != expected:
            problems.add(f"{count} artifact(s) record the build identity {recorded}, expected {expected}")

    if not problems.messages:
        with Path(args.receipt).open("a", encoding="utf-8") as handle:
            handle.write(
                f"DEP-009 verified: all {sum(seen.values())} artifacts record "
                f"{frozen['solc_identity']}, optimizer {frozen['optimizer_runs']}, via-IR "
                f"{frozen['via_ir']}, {frozen['evm_version']}, bytecode hash "
                f"{frozen['bytecode_hash']}, appendCBOR {frozen['append_cbor']}\n"
            )
    print(f"artifacts inspected: {sum(seen.values())}")
    return problems.report("artifacts")


# =============================================================================
# ledger reconciliation
# =============================================================================


def read_listing(path: Path) -> Counter:
    """Foundry's own compiled listing, kept as a multiset so overloads cannot collapse."""
    listing: Counter = Counter()
    for file_path, contracts in load_json(path).items():
        for contract, names in contracts.items():
            for name in names:
                listing[(file_path, contract, name)] += 1
    return listing


def read_execution(path: Path) -> tuple[Counter, dict[tuple, list[str]]]:
    executed: Counter = Counter()
    statuses: dict[tuple, list[str]] = {}
    for suite, result in load_json(path).items():
        file_path, _, contract = suite.partition(":")
        for signature, outcome in result.get("test_results", {}).items():
            identity = (file_path, contract, signature.split("(", 1)[0])
            executed[identity] += 1
            statuses.setdefault(identity, []).append(outcome.get("status", "Unknown"))
    return executed, statuses


def ledger_stage(args: argparse.Namespace) -> int:
    problems = Problems()
    ledger = load_ledger(Path(args.ledger))
    spec = read_spec(Path(args.spec))
    requirements = validate_ledger(ledger, spec["groups"], problems)
    running_gates = set(args.gates.split(","))

    listing = read_listing(Path(args.test_list))
    executed, statuses = read_execution(Path(args.test_report))

    if not listing:
        problems.add("Foundry's compiled listing enumerates no test identity")

    # Multiset equality: identity AND multiplicity must agree in both directions.
    for identity, count in sorted((listing - executed).items()):
        problems.add(f"{identity[0]}:{identity[1]}.{identity[2]}: listed {count} more time(s) than executed")
    for identity, count in sorted((executed - listing).items()):
        problems.add(f"{identity[0]}:{identity[1]}.{identity[2]}: executed {count} more time(s) than listed")
    for identity, outcomes in sorted(statuses.items()):
        for outcome in outcomes:
            if outcome != "Success":
                problems.add(f"{identity[0]}:{identity[1]}.{identity[2]}: reported {outcome}")

    selector_sites: dict[str, list[tuple]] = {}
    for (file_path, contract, name), count in listing.items():
        selector_sites.setdefault(name, []).extend([(file_path, contract)] * count)

    receipt_ids = {
        line.split(" ", 1)[0]
        for line in Path(args.receipt).read_text(encoding="utf-8").splitlines()
        if " verified: " in line
    }

    due, deferred = set(), set()
    for identifier, entry in sorted(requirements.items()):
        active = entry.get("status") == "active"
        if active and entry.get("gate") in running_gates:
            due.add(identifier)
        elif active:
            deferred.add(identifier)

        for selector in entry.get("selectors", []):
            sites = selector_sites.get(selector, [])
            if identifier in due:
                if not sites:
                    problems.add(f"{identifier}: due selector '{selector}' does not exist")
                elif len(sites) > 1:
                    where = ", ".join(f"{path}:{contract}" for path, contract in sites)
                    problems.add(f"{identifier}: due selector '{selector}' is not unique; declared at {where}")
            elif sites:
                where = ", ".join(f"{path}:{contract}" for path, contract in sites)
                problems.add(
                    f"{identifier}: selector '{selector}' exists at {where} but the claim is not due "
                    f"under the {sorted(running_gates)} gate(s); it can close nothing"
                )

        if identifier in due and entry.get("evidence_class") == "gate-dependency" and identifier not in receipt_ids:
            problems.add(f"{identifier}: the gate recorded no verified dependency check for it")

    for name, sites in sorted(selector_sites.items()):
        match = SELECTOR_RE.match(name)
        if not match:
            problems.add(f"{sites[0][0]}:{sites[0][1]}.{name}: test name does not begin with a requirement id")
            continue
        claimed = f"{match.group(1)}-{match.group(2)}"
        entry = requirements.get(claimed)
        if entry is None:
            problems.add(f"{name}: claims requirement {claimed}, which the ledger does not define")
        elif name not in entry.get("selectors", []):
            problems.add(f"{name}: claims {claimed}, which does not plan this selector")
        elif claimed not in due:
            problems.add(
                f"{name}: claims {claimed}, which is not due under the {sorted(running_gates)} gate(s)"
            )

    active = {i for i, e in requirements.items() if e.get("status") == "active"}
    meta = ledger["ledger"]
    print(f"activated tickets: {', '.join(sorted(meta['activated_tickets']))}")
    print(f"activated gates: {', '.join(sorted(meta['activated_gates']))}")
    print(f"gates this entrypoint runs: {', '.join(sorted(running_gates))}")
    print(
        f"requirements: {len(requirements)} recorded, {len(active)} active "
        f"({len(due)} due here, {len(deferred)} deferred to another gate), "
        f"{len(requirements) - len(active)} pending"
    )
    print(f"planned selectors: {sum(len(e['selectors']) for e in requirements.values())}")
    print(f"test identities listed by forge: {sum(listing.values())}")
    print(f"test identities executed: {sum(executed.values())}")
    for group in meta["groups"]:
        ids = [i for i in requirements if i.startswith(f"{group}-")]
        print(f"  {group}: {len(ids)} recorded, {len([i for i in ids if i in due])} due here")
    return problems.report("ledger")


# =============================================================================
# security
# =============================================================================


def parse_disposition_rows(text: str, heading: str) -> list[list[str]]:
    """Table rows under exactly one `## heading`, and under no other.

    Scoping matters: the dispositions document carries several tables, and a row from the
    narrative table must never be able to stand in for a Slither result or a suppression.
    """
    rows: list[list[str]] = []
    inside = False
    for line in text.splitlines():
        if line.startswith("#"):
            inside = line.strip() == f"## {heading}"
            continue
        stripped = line.strip()
        if not inside or not stripped.startswith("|") or not stripped.endswith("|"):
            continue
        cells = [cell.strip().strip("`") for cell in stripped.strip("|").split("|")]
        if all(set(cell) <= {"-", ":"} for cell in cells if cell):
            # A separator row; the row above it was this table's column headings.
            if rows:
                rows.pop()
            continue
        rows.append(cells)
    return rows


def result_location(result: dict) -> str:
    """The portable, normalized source mapping of one Slither result.

    Built from the repository-relative filenames and exact line numbers Slither reports, so
    the fingerprint is identical on any machine and two results from the same detector at
    different places can never share one disposition row.
    """
    parts = set()
    for element in result.get("elements", []):
        mapping = element.get("source_mapping") or {}
        filename, lines = mapping.get("filename_relative"), mapping.get("lines") or []
        if filename and lines:
            parts.add(f"{filename}#" + ",".join(f"L{number}" for number in sorted(set(lines))))
    return "; ".join(sorted(parts)) if parts else "(no source mapping)"


def result_fingerprint(result: dict) -> tuple[str, str, str, str]:
    return (
        str(result.get("check")),
        str(result.get("impact")),
        str(result.get("confidence")),
        result_location(result),
    )


def check_slither_scope(args: argparse.Namespace, problems: Problems) -> list[str]:
    """Prove nobody narrowed the analysis, in the configuration or on the command line.

    Slither can be shrunk two ways with entirely valid input: a well-formed configuration
    key, or a well-formed command-line flag. Both are compared against an exact allowed
    shape here, so a *correct* narrowing fails just as a misspelled one does.
    """
    allowed_config = {
        # Slither's path filter discards an entire result when any source element matches.
        # Dependency mode is narrower: it discards only results whose elements are all
        # dependencies, so a mixed production/dependency finding remains visible.
        "exclude_dependencies": True,
        "exclude_informational": False,
        "exclude_optimization": False,
        "exclude_low": False,
        "exclude_medium": False,
        "exclude_high": False,
        "compile_force_framework": "foundry",
    }
    try:
        configured = load_json(Path(args.slither_config))
    except json.JSONDecodeError as error:
        problems.add(f"{args.slither_config} is not well-formed JSON: {error}")
    else:
        problems.expect(f"{args.slither_config} contents", allowed_config, configured)

    invocation = [line for line in Path(args.slither_command).read_text(encoding="utf-8").splitlines() if line]
    allowed_invocation = ["slither", ".", "--fail-medium", "--json", args.slither_json, "--checklist"]
    problems.expect("effective Slither invocation", allowed_invocation, invocation)

    # The detector portfolio's authority is the pinned binary's own registered detector
    # classes. `--list-detectors` omits hidden detectors, so it under-reports the set that
    # actually runs and can never be the expectation.
    inventory = [line for line in Path(args.detector_inventory).read_text(encoding="utf-8").splitlines() if line]
    if not inventory:
        problems.add(f"{args.detector_inventory} enumerates no registered Slither detector")
    if len(inventory) != len(set(inventory)):
        problems.add(f"{args.detector_inventory} enumerates a detector more than once")
    return inventory


def security(args: argparse.Namespace) -> int:
    problems = Problems()
    json_path, checklist_path = Path(args.slither_json), Path(args.slither_checklist)

    for path in (json_path, checklist_path, Path(args.slither_stderr)):
        if not path.is_file() or path.stat().st_size == 0:
            problems.add(f"Slither produced no usable evidence at {path}")
    if problems.messages:
        return problems.report("security")

    inventory = check_slither_scope(args, problems)

    try:
        report = load_json(json_path)
    except json.JSONDecodeError as error:
        problems.add(f"{json_path} is not well-formed JSON: {error}")
        return problems.report("security")

    if report.get("success") is not True:
        problems.add(f"Slither reported failure: {report.get('error')}")
    results = report.get("results", {}).get("detectors", [])

    stderr = Path(args.slither_stderr).read_text(encoding="utf-8", errors="replace")
    for line in stderr.splitlines():
        if SLITHER_CONFIG_COMPLAINT_RE.search(line):
            problems.add(f"Slither complained about its configuration: {line.strip()}")

    summary = SLITHER_SUMMARY_RE.search(stderr)
    if summary is None:
        problems.add("Slither printed no analysis summary, so the analyzed scope cannot be proven")
    else:
        analyzed = int(summary.group("contracts"))
        declared = sum(
            len([line for line in path.read_text(encoding="utf-8").splitlines() if SOL_DECLARATION_RE.match(line)])
            for directory in args.analyzed_sources
            for path in Path(directory).rglob("*.sol")
        )
        if analyzed < declared:
            problems.add(
                f"Slither analyzed {analyzed} contracts but {args.analyzed_sources} declare "
                f"{declared}; the analyzed scope is incomplete"
            )
        # The run must have carried the pinned binary's whole registered portfolio. A
        # detector or severity narrowing, from either the configuration or the command
        # line, shrinks this number and fails here.
        problems.expect(
            "detectors the analyzed run carried", len(inventory), int(summary.group("detectors"))
        )
        problems.expect("Slither result count in JSON and summary", int(summary.group("results")), len(results))

    dispositions = Path(args.dispositions).read_text(encoding="utf-8")
    rows = parse_disposition_rows(dispositions, "Results")

    declared = re.search(r"<!-- slither-result-count: (\d+) -->", dispositions)
    if declared is None:
        problems.add(f"{args.dispositions} declares no machine-checked slither-result-count")
    else:
        problems.expect("dispositioned Slither result count", len(results), int(declared.group(1)))

    # Exact multiset reconciliation. Two results from one detector at two locations are two
    # fingerprints and therefore need two rows; a row whose location is wrong or missing
    # matches nothing and fails from both directions.
    reported = Counter(result_fingerprint(result) for result in results)
    dispositioned: Counter[tuple[str, str, str, str]] = Counter()
    for row in rows:
        if len(row) != 5:
            problems.add(f"{args.dispositions}: results row {row} does not have the five recorded columns")
            continue
        if not row[4]:
            problems.add(f"{args.dispositions}: results row for '{row[0]}' at [{row[3]}] carries no disposition")
            continue
        dispositioned[(row[0], row[1], row[2], row[3])] += 1

    for fingerprint, count in sorted((reported - dispositioned).items()):
        problems.add(
            f"Slither result '{fingerprint[0]}' ({fingerprint[1]}/{fingerprint[2]}) at [{fingerprint[3]}] "
            f"occurs {count} more time(s) than it is dispositioned in {args.dispositions}"
        )
    for fingerprint, count in sorted((dispositioned - reported).items()):
        problems.add(
            f"{args.dispositions} dispositions '{fingerprint[0]}' ({fingerprint[1]}/{fingerprint[2]}) at "
            f"[{fingerprint[3]}] {count} more time(s) than Slither reported it"
        )

    # --- inline suppressions ---------------------------------------------------
    listing = read_listing(Path(args.test_list))
    known_selectors = {name for _, _, name in listing}
    suppressions: list[tuple[str, str]] = []
    for directory in args.suppression_sources:
        for path in sorted(Path(directory).rglob("*.sol")):
            for match in SLITHER_DISABLE_RE.finditer(path.read_text(encoding="utf-8")):
                for detector in match.group(1).replace(" ", "").split(","):
                    if detector:
                        suppressions.append((path.as_posix(), detector))

    suppression_rows = parse_disposition_rows(dispositions, "Inline suppressions")
    declared = re.search(r"<!-- slither-suppression-count: (\d+) -->", dispositions)
    if declared is None:
        problems.add(f"{args.dispositions} declares no machine-checked slither-suppression-count")
    else:
        problems.expect("recorded inline suppression count", len(suppressions), int(declared.group(1)))

    for path, detector in suppressions:
        row = next((r for r in suppression_rows if len(r) == 4 and r[0] == path and r[1] == detector), None)
        if row is None:
            problems.add(
                f"inline suppression of '{detector}' in {path} has no record naming its detector, "
                f"rationale, and protecting test in {args.dispositions}"
            )
            continue
        if not row[2]:
            problems.add(f"inline suppression of '{detector}' in {path} records no rationale")
        if row[3] not in known_selectors:
            problems.add(
                f"inline suppression of '{detector}' in {path} names protecting test '{row[3]}', "
                "which Foundry does not list"
            )

    print(f"Slither analyzed scope: {args.analyzed_sources}")
    print(f"Slither suppression scope: {args.suppression_sources}")
    print(f"Slither detector portfolio: {len(inventory)} registered detectors, all of them run")
    print(f"Slither results: {len(results)} (each with its own dispositioned fingerprint)")
    print(f"inline Slither suppressions: {len(suppressions)}")
    return problems.report("security")


# =============================================================================


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="stage", required=True)

    stage = sub.add_parser("preflight")
    stage.add_argument("--frozen", required=True)
    stage.add_argument("--spec", required=True)
    stage.add_argument("--ledger", required=True)
    stage.add_argument("--manifest", required=True)
    stage.add_argument("--bindings", required=True)
    stage.add_argument("--threat-model", required=True)
    stage.add_argument("--tool-identity", required=True)
    stage.add_argument("--forge-config", required=True)
    stage.add_argument("--receipt", required=True)
    stage.set_defaults(run=preflight)

    stage = sub.add_parser("artifacts")
    stage.add_argument("--frozen", required=True)
    stage.add_argument("--out", required=True)
    stage.add_argument("--receipt", required=True)
    stage.set_defaults(run=artifacts)

    stage = sub.add_parser("ledger")
    stage.add_argument("--ledger", required=True)
    stage.add_argument("--spec", required=True)
    stage.add_argument("--gates", required=True)
    stage.add_argument("--test-list", required=True)
    stage.add_argument("--test-report", required=True)
    stage.add_argument("--receipt", required=True)
    stage.set_defaults(run=ledger_stage)

    stage = sub.add_parser("security")
    stage.add_argument("--slither-json", required=True)
    stage.add_argument("--slither-checklist", required=True)
    stage.add_argument("--slither-stderr", required=True)
    stage.add_argument("--slither-config", required=True)
    stage.add_argument("--slither-command", required=True)
    stage.add_argument("--detector-inventory", required=True)
    stage.add_argument("--dispositions", required=True)
    stage.add_argument("--test-list", required=True)
    stage.add_argument("--analyzed-sources", nargs="+", required=True)
    stage.add_argument("--suppression-sources", nargs="+", required=True)
    stage.set_defaults(run=security)

    args = parser.parse_args()
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())
