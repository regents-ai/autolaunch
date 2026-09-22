#!/usr/bin/env python3
"""Structured reconciliation for the Memestake required gates (`contracts/stocks/bin/gate.sh` and
`contracts/robinhood/bin/gate.sh`).

The gate scripts run the external tools; this script performs every structured comparison and is
the only place that decides whether frozen material still equals its authority. Every check fails
closed, and every expectation is compared against an authority that is not the candidate's own
restatement of it.

Subcommands, in the order a gate runs them:

  preflight  Reconcile `requirements/frozen-identity.json` against the installed tool identities,
             the effective Foundry configuration (`forge config --json`, so an environment
             override shows up), the compiled binding constants, and the dependency lock. Start the
             dependency receipt.
  artifacts  Assert the compiler identity and settings recorded in every produced artifact.
  tests      Reconcile Foundry's own compiled test listing against the frozen listing and against
             the executed report as multisets: every frozen identity listed, every listed identity
             executed exactly once, every execution a pass.
  security   Reconcile the Slither run: an unnarrowed configuration and command line, the pinned
             binary's whole registered detector portfolio, fresh and well-formed evidence, one
             visible disposition per exact result fingerprint at every severity, and a complete
             record for every inline suppression.
  secrets    Prove no evidence, frozen artifact or effective configuration carries a resolved
             provider endpoint or credential.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter
from pathlib import Path

SLITHER_DISABLE_RE = re.compile(r"slither-disable(?:-next-line|-start|-end)?\s+([\w,\- ]+)")
SLITHER_SUMMARY_RE = re.compile(
    r"analyzed \((?P<contracts>\d+) contracts with (?P<detectors>\d+) detectors\), "
    r"(?P<results>\d+) result\(s\) found"
)
SLITHER_CONFIG_COMPLAINT_RE = re.compile(
    r"(?i)(unknown key|unsupported key|invalid .{0,20}config|cannot parse .{0,20}config|error in config)"
)
SOL_DECLARATION_RE = re.compile(r"^\s*(?:abstract\s+)?(?:contract|library|interface)\s+\w+")
SOL_ADDRESS_CONST_RE = re.compile(r"^\s*address internal constant (\w+) = (0x[0-9a-fA-F]{40});\s*$")
SOL_UINT_CONST_RE = re.compile(r"^\s*uint256 internal constant (\w+) = ([\d_]+);\s*$")

# The only hosts an artifact may name. All are documentation or provenance, never an endpoint.
ALLOWED_URL_HOSTS = frozenset({
    "github.com",
    "raw.githubusercontent.com",
    "book.getfoundry.sh",
    "docs.soliditylang.org",
})
URL_RE = re.compile(r"(?:https?|wss?)://([^\s\"'\\,)\]}/]+)")
KEY_SHAPE_RE = re.compile(r"(?i)(alchemy|infura|quiknode|quicknode|drpc\.org|ankr\.com|blastapi|x-api-key)")
CREDENTIAL_FIELD_RE = re.compile(r"(?i)(api_?key|secret|password|token)$")


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


def load_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


# =============================================================================
# preflight
# =============================================================================


def parse_binding_source(path: Path, problems: Problems) -> dict[str, str]:
    """Every `address internal constant` and `uint256 internal constant` in a bindings library."""
    found: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        address = SOL_ADDRESS_CONST_RE.match(line)
        if address:
            found[address.group(1)] = address.group(2)
            continue
        number = SOL_UINT_CONST_RE.match(line)
        if number:
            found[number.group(1)] = str(int(number.group(2).replace("_", "")))
    if not found:
        problems.add(f"{path} declares no binding constant")
    return found


def preflight(args: argparse.Namespace) -> int:
    problems = Problems()
    frozen = load_json(Path(args.frozen))
    receipt_lines: list[str] = []

    # --- tool identity --------------------------------------------------------
    tools = dict(
        line.split(" ", 1) for line in Path(args.tool_identity).read_text(encoding="utf-8").splitlines() if line
    )
    tools = {key: value.strip() for key, value in tools.items()}
    if all(
        problems.expect(f"{key} identity", frozen["toolchain"][key], tools.get(key))
        for key in sorted(frozen["toolchain"])
    ):
        receipt_lines.append(
            "toolchain verified: forge {forge_version} ({forge_commit_sha}); slither {slither_version}; "
            "python {python_version}".format(**tools)
        )

    # --- effective Foundry configuration --------------------------------------
    config = load_json(Path(args.forge_config))
    build = frozen["build"]
    effective = {
        "solc_version": config.get("solc"),
        "evm_version": config.get("evm_version"),
        "optimizer_runs": config.get("optimizer_runs"),
        "via_ir": config.get("via_ir"),
        "bytecode_hash": config.get("bytecode_hash"),
        "append_cbor": config.get("cbor_metadata"),
    }
    ok = problems.expect("effective optimizer setting", True, config.get("optimizer"))
    for field, wanted in build.items():
        if field == "solc_identity":
            if not str(wanted).startswith(f"{build['solc_version']}+"):
                problems.add(f"frozen compiler identity [{wanted}] does not begin with [{build['solc_version']}]")
                ok = False
            continue
        ok &= problems.expect(f"effective {field}", wanted, effective[field])
    if ok:
        receipt_lines.append(
            f"build verified: the effective Foundry configuration compiles Solidity {build['solc_version']}, "
            f"{build['evm_version']}, optimizer {build['optimizer_runs']}, via-IR {build['via_ir']}, bytecode "
            f"hash {build['bytecode_hash']}, appendCBOR {build['append_cbor']}"
        )

    foundry = frozen["foundry"]
    ok = problems.expect("effective offline setting", foundry["offline"], config.get("offline"))
    ok &= problems.expect("effective ffi setting", foundry["ffi"], config.get("ffi"))
    ok &= problems.expect("effective fs_permissions", foundry["fs_permissions"], config.get("fs_permissions"))
    ok &= problems.expect("effective libs", foundry["libs"], config.get("libs"))
    ok &= problems.expect("effective src", foundry["src"], config.get("src"))
    ok &= problems.expect("effective test", foundry["test"], config.get("test"))
    ok &= problems.expect("effective no_match_path", foundry["no_match_path"], config.get("no_match_path"))
    ok &= problems.expect("effective remappings", foundry["remappings"], config.get("remappings"))
    if ok:
        receipt_lines.append(
            "posture verified: the effective Foundry configuration is offline with FFI disabled, no filesystem "
            "permissions, and the frozen source, test, library and remapping roots"
        )

    ok = True
    for name in ("fuzz", "invariant"):
        if name not in frozen:
            continue
        section = config.get(name, {})
        for key, want in frozen[name].items():
            found = section.get(key)
            if key == "seed":
                want, found = int(str(want), 16), int(str(found), 16) if found is not None else None
            ok &= problems.expect(f"effective {name}.{key}", want, found)
    if ok:
        receipt_lines.append("portfolio verified: the effective fuzz and invariant settings equal the frozen values")

    # --- compiled bindings ----------------------------------------------------
    if args.bindings:
        source = parse_binding_source(Path(args.bindings), problems)
        frozen_bindings = {entry["constant"]: str(entry["value"]) for entry in frozen["bindings"]}
        if problems.expect("frozen binding constant set", sorted(frozen_bindings), sorted(source)):
            for constant, value in sorted(frozen_bindings.items()):
                problems.expect(f"binding {constant}", value, source[constant])
            receipt_lines.append(
                f"bindings verified: {len(frozen_bindings)} compiled constants in {args.bindings} equal the frozen record"
            )

    # --- dependency lock ------------------------------------------------------
    lock = load_json(Path(args.dependency_lock))
    pinned = {name: pin["revision"] for name, pin in lock.items() if not name.startswith("_")}
    if problems.expect("frozen dependency revisions", frozen["dependencies"], pinned):
        receipt_lines.append(
            f"dependency lock verified: {len(pinned)} pinned revisions in {args.dependency_lock} equal the frozen record"
        )

    if not problems.messages:
        with Path(args.receipt).open("a", encoding="utf-8") as handle:
            handle.write("\n".join(receipt_lines) + "\n")
    print(f"toolchain: {tools}")
    print(f"frozen dependency revisions: {len(pinned)}")
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
        seen[(
            metadata.get("compiler", {}).get("version"),
            optimizer.get("enabled"),
            optimizer.get("runs"),
            settings.get("viaIR"),
            settings.get("evmVersion"),
            settings.get("metadata", {}).get("bytecodeHash"),
            settings.get("metadata", {}).get("appendCBOR"),
        )] += 1

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
                f"artifacts verified: all {sum(seen.values())} artifacts record {frozen['solc_identity']}, "
                f"optimizer {frozen['optimizer_runs']}, via-IR {frozen['via_ir']}, {frozen['evm_version']}, "
                f"bytecode hash {frozen['bytecode_hash']}, appendCBOR {frozen['append_cbor']}\n"
            )
    print(f"artifacts inspected: {sum(seen.values())}")
    return problems.report("artifacts")


# =============================================================================
# tests
# =============================================================================


def read_listing(path: Path) -> Counter:
    """Foundry's own compiled listing, kept as a multiset so overloads cannot collapse."""
    listing: Counter = Counter()
    for file_path, contracts in load_json(path).items():
        for contract, names in contracts.items():
            for name in names:
                listing[(file_path, contract, name)] += 1
    return listing


def read_frozen_listing(path: Path) -> Counter:
    listing: Counter = Counter()
    for file_path, contracts in load_json(path)["tests"].items():
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


def tests(args: argparse.Namespace) -> int:
    problems = Problems()
    listing = read_listing(Path(args.test_list))
    frozen = read_frozen_listing(Path(args.frozen_listing))
    executed, statuses = read_execution(Path(args.test_report))

    if not listing:
        problems.add(f"{args.test_list} lists no test")
    for identity, count in sorted((listing - frozen).items()):
        problems.add(f"{identity} is compiled {count} more time(s) than the frozen listing records; refreeze")
    for identity, count in sorted((frozen - listing).items()):
        problems.add(f"{identity} is frozen but Foundry no longer lists it ({count} missing); refreeze")
    for identity, count in sorted((listing - executed).items()):
        problems.add(f"{identity} is listed but executed {count} fewer time(s) than listed")
    for identity, count in sorted((executed - listing).items()):
        problems.add(f"{identity} executed {count} more time(s) than Foundry lists it")
    for identity, outcomes in sorted(statuses.items()):
        for outcome in outcomes:
            if outcome != "Success":
                problems.add(f"{identity} finished {outcome}")

    if not problems.messages:
        with Path(args.receipt).open("a", encoding="utf-8") as handle:
            handle.write(
                f"tests verified: Foundry lists {sum(listing.values())} test identities, equal to the frozen "
                f"listing, and every one executed exactly once and passed\n"
            )
    print(f"listed tests: {sum(listing.values())}")
    print(f"executed tests: {sum(executed.values())}")
    return problems.report("tests")


# =============================================================================
# security
# =============================================================================


def parse_disposition_rows(text: str, heading: str) -> list[list[str]]:
    """Table rows under exactly one `## heading`, and under no other."""
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
            if rows:
                rows.pop()
            continue
        rows.append(cells)
    return rows


def result_location(result: dict) -> str:
    """The portable, normalized source mapping of one Slither result."""
    parts = set()
    for element in result.get("elements", []):
        mapping = element.get("source_mapping") or {}
        filename, lines = mapping.get("filename_relative"), mapping.get("lines") or []
        if filename and lines:
            parts.add(f"{filename}#" + ",".join(f"L{number}" for number in sorted(set(lines))))
    return "; ".join(sorted(parts)) if parts else "(no source mapping)"


def result_fingerprint(result: dict) -> tuple[str, str, str, str]:
    return (str(result.get("check")), str(result.get("impact")), str(result.get("confidence")), result_location(result))


def check_slither_scope(args: argparse.Namespace, problems: Problems) -> list[str]:
    """Prove nobody narrowed the analysis, in the configuration or on the command line."""
    allowed_config = {
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
    json_from_root = os.path.relpath(args.slither_json, args.slither_cwd)
    allowed_invocation = ["slither", ".", "--fail-medium", "--json", json_from_root, "--checklist"]
    problems.expect("effective Slither invocation", allowed_invocation, invocation)

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
                f"Slither analyzed {analyzed} contracts but {args.analyzed_sources} declare {declared}; "
                "the analyzed scope is incomplete"
            )
        problems.expect("detectors the analyzed run carried", len(inventory), int(summary.group("detectors")))
        problems.expect("Slither result count in JSON and summary", int(summary.group("results")), len(results))

    dispositions = Path(args.dispositions).read_text(encoding="utf-8")
    rows = parse_disposition_rows(dispositions, "Results")

    declared = re.search(r"<!-- slither-result-count: (\d+) -->", dispositions)
    if declared is None:
        problems.add(f"{args.dispositions} declares no machine-checked slither-result-count")
    else:
        problems.expect("dispositioned Slither result count", len(results), int(declared.group(1)))

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

    recorded = Counter((row[0], row[1]) for row in suppression_rows if len(row) == 4)
    for (path, detector), count in sorted((recorded - Counter(suppressions)).items()):
        problems.add(
            f"{args.dispositions} records {count} more suppression(s) of '{detector}' in {path} than the source carries"
        )
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

    if not problems.messages:
        with Path(args.receipt).open("a", encoding="utf-8") as handle:
            handle.write(
                f"static analysis verified: slither {len(inventory)} registered detectors all ran, "
                f"{len(results)} result(s) each dispositioned by exact fingerprint, "
                f"{len(suppressions)} inline suppression(s) each recorded with a listed protecting test\n"
            )
    print(f"Slither analyzed scope: {args.analyzed_sources}")
    print(f"Slither suppression scope: {args.suppression_sources}")
    print(f"Slither detector portfolio: {len(inventory)} registered detectors, all of them run")
    print(f"Slither results: {len(results)} (each with its own dispositioned fingerprint)")
    print(f"inline Slither suppressions: {len(suppressions)}")
    return problems.report("security")


# =============================================================================
# secrets
# =============================================================================


def walk_config(node: object, path: str = "") -> list[tuple[str, object]]:
    if isinstance(node, dict):
        found = []
        for key, value in node.items():
            found.extend(walk_config(value, f"{path}.{key}" if path else str(key)))
        return found
    if isinstance(node, list):
        found = []
        for index, value in enumerate(node):
            found.extend(walk_config(value, f"{path}[{index}]"))
        return found
    return [(path, node)]


def secrets(args: argparse.Namespace) -> int:
    problems = Problems()

    config = load_json(Path(args.forge_config))
    endpoints = config.get("rpc_endpoints") or {}
    for alias, value in sorted(endpoints.items()):
        if not str(value).startswith("${"):
            problems.add(f"RPC alias '{alias}' is resolved in the effective configuration")

    leaves = walk_config(config)
    for field, value in leaves:
        if value in (None, "", False):
            continue
        leaf = field.rsplit(".", 1)[-1].split("[", 1)[0]
        if CREDENTIAL_FIELD_RE.search(leaf):
            problems.add(f"the effective configuration carries a value in the credential field '{field}'")
        if field.startswith("rpc_endpoints"):
            continue
        for host in set(URL_RE.findall(str(value))):
            if host.lower() not in ALLOWED_URL_HOSTS:
                problems.add(f"the effective configuration names the network host {host} at '{field}'")
        for match in set(KEY_SHAPE_RE.findall(str(value))):
            problems.add(f"the effective configuration carries provider key material shaped like [{match}] at '{field}'")

    scanned = 0
    for root in args.scan:
        base = Path(root)
        if not base.exists():
            problems.add(f"secret-scan target {root} does not exist")
            continue
        for path in sorted(base.rglob("*")) if base.is_dir() else [base]:
            if not path.is_file():
                continue
            scanned += 1
            text = path.read_text(encoding="utf-8", errors="replace")
            for host in set(URL_RE.findall(text)):
                if host.lower() not in ALLOWED_URL_HOSTS:
                    problems.add(f"{path} names the network host {host}")
            for match in set(KEY_SHAPE_RE.findall(text)):
                problems.add(f"{path} carries provider key material shaped like [{match}]")

    print(f"secret-scanned files: {scanned}")
    print(f"effective configuration leaves inspected: {len(leaves)}")
    print(f"RPC aliases declared: {', '.join(sorted(endpoints)) or '(none)'}")
    return problems.report("secrets")


# =============================================================================


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    stages = parser.add_subparsers(dest="stage", required=True)

    stage = stages.add_parser("preflight")
    stage.add_argument("--frozen", required=True)
    stage.add_argument("--tool-identity", required=True)
    stage.add_argument("--forge-config", required=True)
    stage.add_argument("--bindings", default=None)
    stage.add_argument("--dependency-lock", required=True)
    stage.add_argument("--receipt", required=True)
    stage.set_defaults(handler=preflight)

    stage = stages.add_parser("artifacts")
    stage.add_argument("--frozen", required=True)
    stage.add_argument("--out", required=True)
    stage.add_argument("--receipt", required=True)
    stage.set_defaults(handler=artifacts)

    stage = stages.add_parser("tests")
    stage.add_argument("--test-list", required=True)
    stage.add_argument("--frozen-listing", required=True)
    stage.add_argument("--test-report", required=True)
    stage.add_argument("--receipt", required=True)
    stage.set_defaults(handler=tests)

    stage = stages.add_parser("security")
    stage.add_argument("--slither-json", required=True)
    stage.add_argument("--slither-cwd", required=True)
    stage.add_argument("--slither-checklist", required=True)
    stage.add_argument("--slither-stderr", required=True)
    stage.add_argument("--slither-config", required=True)
    stage.add_argument("--slither-command", required=True)
    stage.add_argument("--detector-inventory", required=True)
    stage.add_argument("--dispositions", required=True)
    stage.add_argument("--test-list", required=True)
    stage.add_argument("--analyzed-sources", nargs="+", required=True)
    stage.add_argument("--suppression-sources", nargs="+", required=True)
    stage.add_argument("--receipt", required=True)
    stage.set_defaults(handler=security)

    stage = stages.add_parser("secrets")
    stage.add_argument("--forge-config", required=True)
    stage.add_argument("--scan", nargs="+", required=True)
    stage.set_defaults(handler=secrets)

    args = parser.parse_args()
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main())
