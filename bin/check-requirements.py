#!/usr/bin/env python3
"""Reconcile the requirement ledger against the executed test set.

Enforces the standing acceptance predicate:

  * every test identity enumerated from the pinned source tree executed exactly once,
    with zero failures and zero skips;
  * every activated requirement maps to an existing executed selector, or to a dependency
    check the gate itself verified;
  * every future requirement stays pending, carries no selector, and cannot be claimed by
    any test until its owning ticket is activated.

Counts printed here are informational gate output, never acceptance literals.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path

CONTRACT_RE = re.compile(r"^\s*(?:abstract\s+)?contract\s+([A-Za-z_]\w*)")
TEST_FUNCTION_RE = re.compile(r"^\s*function\s+((?:test|testFuzz|invariant)_\w+)\s*\(")
REQUIREMENT_ID_RE = re.compile(r"^[A-Z]+-\d{3}$")
SELECTOR_ID_RE = re.compile(r"^(?:test|testFuzz|invariant)_([A-Z]+)_(\d{3})_\w+$")

GATES = {"hermetic", "invariant", "fork", "deployment"}
EVIDENCE_GATES = {
    "gate-dependency": "hermetic",
    "solidity-hermetic": "hermetic",
    "solidity-invariant": "invariant",
    "fork-execution": "fork",
    "deployment-ceremony": "deployment",
}
ACTIVATABLE_GATES = {"hermetic", "invariant"}
REQUIRED_FIELDS = ("id", "statement", "owner", "contract", "evidence_class", "gate", "status", "selectors")


class Problems:
    def __init__(self) -> None:
        self.messages: list[str] = []

    def add(self, message: str) -> None:
        self.messages.append(message)

    def report(self) -> int:
        if not self.messages:
            return 0
        print("\nREQUIREMENT RECONCILIATION FAILED", file=sys.stderr)
        for message in self.messages:
            print(f"  - {message}", file=sys.stderr)
        return 1


def enumerate_source_tests(test_dir: Path) -> dict[str, str]:
    """Map every test identity in the pinned source tree to its declaring file."""
    identities: dict[str, str] = {}
    for path in sorted(test_dir.rglob("*.sol")):
        contract = None
        for line in path.read_text(encoding="utf-8").splitlines():
            contract_match = CONTRACT_RE.match(line)
            if contract_match:
                contract = contract_match.group(1)
                continue
            function_match = TEST_FUNCTION_RE.match(line)
            if function_match and contract is not None:
                identities[f"{path.as_posix()}:{contract}.{function_match.group(1)}"] = function_match.group(1)
    return identities


def read_executed_tests(report_path: Path) -> dict[str, str]:
    """Map every executed test identity to its reported status."""
    report = json.loads(report_path.read_text(encoding="utf-8"))
    executed: dict[str, str] = {}
    for suite, suite_result in report.items():
        file_path, _, contract = suite.partition(":")
        for signature, result in suite_result.get("test_results", {}).items():
            name = signature.split("(", 1)[0]
            executed[f"{file_path}:{contract}.{name}"] = result.get("status", "Unknown")
    return executed


def selector_requirement(selector: str) -> str | None:
    match = SELECTOR_ID_RE.match(selector)
    return f"{match.group(1)}-{match.group(2)}" if match else None


def check_ledger_shape(ledger: dict, problems: Problems) -> tuple[dict[str, dict], set[str], set[str]]:
    meta = ledger.get("ledger", {})
    groups = set(meta.get("groups", []))
    activated = set(meta.get("activated_tickets", []))
    if not groups:
        problems.add("the ledger declares no requirement groups")
    if not activated:
        problems.add("the ledger activates no ticket")

    requirements: dict[str, dict] = {}
    for entry in ledger.get("requirement", []):
        identifier = entry.get("id", "<missing id>")
        for field in REQUIRED_FIELDS:
            if field not in entry:
                problems.add(f"{identifier}: missing field '{field}'")
        if not REQUIREMENT_ID_RE.match(str(identifier)):
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
        if entry.get("gate") not in GATES:
            problems.add(f"{identifier}: gate '{entry.get('gate')}' is not a recorded gate")
        evidence_class = entry.get("evidence_class")
        if evidence_class not in EVIDENCE_GATES:
            problems.add(f"{identifier}: evidence class '{evidence_class}' is not recognized")
        elif EVIDENCE_GATES[evidence_class] != entry.get("gate"):
            problems.add(
                f"{identifier}: evidence class '{evidence_class}' cannot be closed by the "
                f"'{entry.get('gate')}' gate"
            )
        if entry.get("status") not in {"active", "pending"}:
            problems.add(f"{identifier}: status '{entry.get('status')}' is not active or pending")

    for group in sorted(groups):
        if not any(identifier.startswith(f"{group}-") for identifier in requirements):
            problems.add(f"required requirement group {group} has no entry")

    return requirements, groups, activated


def check_activation(requirements: dict[str, dict], activated: set[str], problems: Problems) -> None:
    for identifier, entry in requirements.items():
        owner = entry.get("owner")
        status = entry.get("status")
        selectors = entry.get("selectors", [])
        if status == "active":
            if owner not in activated:
                problems.add(f"{identifier}: active while its owning ticket {owner} is not activated")
            if entry.get("gate") not in ACTIVATABLE_GATES:
                problems.add(
                    f"{identifier}: the '{entry.get('gate')}' gate cannot activate under the hermetic gate"
                )
        elif owner in activated:
            problems.add(f"{identifier}: owned by activated ticket {owner} but still pending")
        if status == "pending" and selectors:
            problems.add(f"{identifier}: pending requirements carry no selector")
        if entry.get("evidence_class") == "gate-dependency" and selectors:
            problems.add(f"{identifier}: dependency checks are proven by the gate, not by a selector")


def check_coverage(
    requirements: dict[str, dict],
    source_tests: dict[str, str],
    executed: dict[str, str],
    receipt_ids: set[str],
    problems: Problems,
) -> None:
    selector_identities: dict[str, list[str]] = {}
    for identity, selector in source_tests.items():
        selector_identities.setdefault(selector, []).append(identity)

    for identifier, entry in requirements.items():
        status = entry.get("status")
        evidence_class = entry.get("evidence_class")
        selectors = entry.get("selectors", [])

        if status == "active" and evidence_class == "gate-dependency":
            if identifier not in receipt_ids:
                problems.add(f"{identifier}: the gate recorded no verified dependency check for it")
            continue

        if status == "active" and not selectors:
            problems.add(f"{identifier}: active without a Solidity selector")

        for selector in selectors:
            if selector_requirement(selector) != identifier:
                problems.add(f"{identifier}: selector '{selector}' does not begin with its requirement id")
            identities = selector_identities.get(selector, [])
            if not identities:
                problems.add(f"{identifier}: selector '{selector}' does not exist in the source tree")
                continue
            if len(identities) > 1:
                problems.add(f"{identifier}: selector '{selector}' is declared by more than one contract")
            for identity in identities:
                result = executed.get(identity)
                if result is None:
                    problems.add(f"{identifier}: selector '{selector}' did not execute")
                elif result != "Success":
                    problems.add(f"{identifier}: selector '{selector}' reported {result}")

    for identity, selector in source_tests.items():
        claimed = selector_requirement(selector)
        if claimed is None:
            problems.add(f"{identity}: test name does not begin with a requirement id")
            continue
        entry = requirements.get(claimed)
        if entry is None:
            problems.add(f"{identity}: claims requirement {claimed}, which the ledger does not define")
            continue
        if entry.get("status") != "active":
            problems.add(f"{identity}: claims {claimed}, which is pending and cannot be satisfied yet")
        elif selector not in entry.get("selectors", []):
            problems.add(f"{identity}: claims {claimed}, which does not list this selector")


def check_execution(source_tests: dict[str, str], executed: dict[str, str], problems: Problems) -> None:
    if not source_tests:
        problems.add("the pinned source tree enumerates no test identity")

    for identity in sorted(set(source_tests) - set(executed)):
        problems.add(f"{identity}: enumerated from source but never executed")
    for identity in sorted(set(executed) - set(source_tests)):
        problems.add(f"{identity}: executed but not enumerated from the pinned source tree")
    for identity, status in sorted(executed.items()):
        if status != "Success":
            problems.add(f"{identity}: reported {status}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", type=Path, required=True)
    parser.add_argument("--test-dir", type=Path, required=True)
    parser.add_argument("--test-report", type=Path, required=True)
    parser.add_argument("--dependency-receipt", type=Path, required=True)
    args = parser.parse_args()

    problems = Problems()

    with args.ledger.open("rb") as handle:
        ledger = tomllib.load(handle)

    source_tests = enumerate_source_tests(args.test_dir)
    executed = read_executed_tests(args.test_report)
    receipt_ids = {
        line.split(" ", 1)[0]
        for line in args.dependency_receipt.read_text(encoding="utf-8").splitlines()
        if " verified: " in line
    }

    requirements, groups, activated = check_ledger_shape(ledger, problems)
    check_activation(requirements, activated, problems)
    check_execution(source_tests, executed, problems)
    check_coverage(requirements, source_tests, executed, receipt_ids, problems)

    active = {identifier for identifier, entry in requirements.items() if entry.get("status") == "active"}
    print(f"activated tickets: {', '.join(sorted(activated))}")
    print(f"requirements: {len(requirements)} recorded, {len(active)} active, {len(requirements) - len(active)} pending")
    print(f"requirement groups: {len(groups)}")
    print(f"test identities enumerated from source: {len(source_tests)}")
    print(f"test identities executed: {len(executed)}")
    for group in sorted(groups):
        group_ids = [identifier for identifier in requirements if identifier.startswith(f"{group}-")]
        group_active = [identifier for identifier in group_ids if identifier in active]
        print(f"  {group}: {len(group_ids)} recorded, {len(group_active)} active")

    return problems.report()


if __name__ == "__main__":
    sys.exit(main())
