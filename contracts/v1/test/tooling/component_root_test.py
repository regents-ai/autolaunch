#!/usr/bin/env python3
"""Deterministic tooling tests for the contracts/v1 component root, run without a provider.

The three gates accept exactly one script root: the directory `contracts/v1` under the Git top
level of the repository that contains it. The requirement checker reads one shared file from
outside that directory, the top-level `.gitmodules`, whose paths are repository-relative and
must map onto the component-relative frozen root set. Both boundaries are shell and Python
control flow around Git, so the offline gate's Solidity suite cannot exercise them.

Every gate case below copies the real scripts into a throwaway repository laid out one way,
runs the gate there with the ambient Git context removed, and checks two things:

  a wrong root — the top level itself, another directory, or a repository rooted at the
      component inside a larger one — stops at the root proof, exits nonzero, and never prints
      a pass marker;

  the canonical root — `contracts/v1` in a clean committed repository — passes the root proof
      and stops later, at the first missing piece of committed material.

The checker cases call the real mapping functions. Run by `bin/gate.sh`; a failure here fails
the gate.
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

COMPONENT = "contracts/v1"
COMPONENT_ROOT = Path(__file__).resolve().parents[2]
CHECKER_PATH = COMPONENT_ROOT / "bin" / "check-requirements.py"
GATE_SCRIPTS = ("gate.sh", "fork-gate.sh", "deployment-gate.sh")

ROOT_REJECTION = f"the physical script root is not {COMPONENT} under the Git top level"
NO_WORKTREE_REJECTION = "the physical script root is not inside a Git worktree"

# The mode each gate is run in, and the first failure a canonical bare repository must reach
# once the root proof has passed. The bare repository carries only the scripts, so the gate
# stops at its first committed-material requirement.
GATE_MODES = {
    "gate.sh": ([], "required repository file is missing"),
    "fork-gate.sh": (["check"], "the offline gate's dependency receipt is absent"),
    "deployment-gate.sh": (["--offline"], "required deployment material is missing"),
}


def load_checker():
    spec = importlib.util.spec_from_file_location("regent_check_requirements", CHECKER_PATH)
    if spec is None or spec.loader is None:
        raise SystemExit(f"tooling test cannot load {CHECKER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Failures:
    def __init__(self) -> None:
        self.messages: list[str] = []

    def check(self, condition: bool, message: str) -> None:
        if not condition:
            self.messages.append(message)


def clean_env() -> dict[str, str]:
    """The gates reject every ambient GIT_* override themselves; these cases test the root proof."""
    return {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}


def git(cwd: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.name=tooling", "-c", "user.email=tooling@example.invalid", *args],
        cwd=cwd,
        env=clean_env(),
        check=True,
        capture_output=True,
    )


def sandbox_repository(base: Path, layout: str) -> Path:
    """A committed repository carrying copies of the three gates under `layout`/bin."""
    repo = base / "repo"
    script_root = repo / layout
    (script_root / "bin").mkdir(parents=True)
    for script in GATE_SCRIPTS:
        target = script_root / "bin" / script
        target.write_bytes((COMPONENT_ROOT / "bin" / script).read_bytes())
        target.chmod(0o755)
    (repo / "root.txt").write_text("root\n", encoding="utf-8")
    git(repo, "init", "-q")
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "sandbox")
    return script_root


def run_gate(script_root: Path, script: str) -> tuple[int, str]:
    mode, _ = GATE_MODES[script]
    result = subprocess.run(
        [f"./bin/{script}", *mode],
        cwd=script_root,
        env=clean_env(),
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode, result.stdout + result.stderr


def expect_rejected(failures: Failures, case: str, script: str, status: int, output: str, marker: str) -> None:
    failures.check(status != 0, f"{case}: {script} exited 0 from a rejected root")
    failures.check(marker in output, f"{case}: {script} did not stop at the root proof; said {output[-400:]!r}")
    failures.check("GATE PASS" not in output, f"{case}: {script} printed a pass marker from a rejected root")


def wrong_roots_are_rejected(failures: Failures) -> None:
    for layout, case in (
        (".", "top level"),
        ("components/v1", "another directory"),
        ("contracts", "the parent of the component"),
        ("contracts/v1/nested", "a directory below the component"),
    ):
        with tempfile.TemporaryDirectory() as raw:
            script_root = sandbox_repository(Path(raw), layout)
            for script in GATE_SCRIPTS:
                status, output = run_gate(script_root, script)
                expect_rejected(failures, case, script, status, output, ROOT_REJECTION)


def a_repository_rooted_at_the_component_is_rejected(failures: Failures) -> None:
    """The layout is right but Git is not: a nested repository makes the top level the component."""
    with tempfile.TemporaryDirectory() as raw:
        script_root = sandbox_repository(Path(raw), COMPONENT)
        git(script_root, "init", "-q")
        for script in GATE_SCRIPTS:
            status, output = run_gate(script_root, script)
            expect_rejected(failures, "nested repository", script, status, output, ROOT_REJECTION)


def a_directory_outside_any_repository_is_rejected(failures: Failures) -> None:
    with tempfile.TemporaryDirectory() as raw:
        script_root = Path(raw) / COMPONENT
        (script_root / "bin").mkdir(parents=True)
        for script in GATE_SCRIPTS:
            target = script_root / "bin" / script
            target.write_bytes((COMPONENT_ROOT / "bin" / script).read_bytes())
            target.chmod(0o755)
        for script in GATE_SCRIPTS:
            status, output = run_gate(script_root, script)
            expect_rejected(failures, "no repository", script, status, output, NO_WORKTREE_REJECTION)


def the_canonical_root_passes_the_root_proof(failures: Failures) -> None:
    with tempfile.TemporaryDirectory() as raw:
        script_root = sandbox_repository(Path(raw), COMPONENT)
        for script in GATE_SCRIPTS:
            status, output = run_gate(script_root, script)
            _, later_failure = GATE_MODES[script]
            failures.check(status != 0, f"canonical: {script} exited 0 in a repository with no committed material")
            failures.check(
                ROOT_REJECTION not in output and NO_WORKTREE_REJECTION not in output,
                f"canonical: {script} rejected the canonical root; said {output[-400:]!r}",
            )
            failures.check(
                later_failure in output,
                f"canonical: {script} did not reach its first material requirement; said {output[-400:]!r}",
            )


def checker_maps_the_top_level_gitmodules_onto_the_component(checker, failures: Failures) -> None:
    problems = checker.Problems()
    mapped = checker.component_relative(
        [f"{COMPONENT}/lib/forge-std", f"{COMPONENT}/lib/uerc20-factory"], problems, "the top-level .gitmodules"
    )
    failures.check(mapped == ["lib/forge-std", "lib/uerc20-factory"], f"checker: component paths mapped to {mapped!r}")
    failures.check(problems.messages == [], f"checker: component paths raised {problems.messages!r}")

    problems = checker.Problems()
    mapped = checker.component_relative(
        ["lib/forge-std", "contracts/revenue-mesh/lib/solady", f"{COMPONENT}/lib/forge-std"],
        problems,
        "the top-level .gitmodules",
    )
    failures.check(mapped == ["lib/forge-std"], f"checker: paths outside the component were kept: {mapped!r}")
    failures.check(
        len(problems.messages) == 2 and all("outside contracts/v1/" in message for message in problems.messages),
        f"checker: paths outside the component were not each reported: {problems.messages!r}",
    )


def checker_requires_the_component_prefix(checker, failures: Failures) -> None:
    """The top level is returned only when the checker runs at exactly the component prefix."""
    with tempfile.TemporaryDirectory() as raw:
        script_root = sandbox_repository(Path(raw), COMPONENT)
        repo = script_root.parents[1]
        previous = Path.cwd()
        try:
            os.chdir(script_root)
            problems = checker.Problems()
            toplevel = checker.component_toplevel(problems)
            failures.check(
                toplevel is not None and Path(toplevel).resolve() == repo.resolve(),
                f"checker: the component root resolved to {toplevel!r}, not the sandbox top level",
            )
            failures.check(problems.messages == [], f"checker: the component root raised {problems.messages!r}")

            os.chdir(repo)
            problems = checker.Problems()
            toplevel = checker.component_toplevel(problems)
            failures.check(toplevel is None, "checker: the top level itself was accepted as the component root")
            failures.check(
                any("not the contracts/v1/ component" in message for message in problems.messages),
                f"checker: the wrong prefix was not named: {problems.messages!r}",
            )
        finally:
            os.chdir(previous)


def main() -> int:
    checker = load_checker()
    failures = Failures()

    wrong_roots_are_rejected(failures)
    a_repository_rooted_at_the_component_is_rejected(failures)
    a_directory_outside_any_repository_is_rejected(failures)
    the_canonical_root_passes_the_root_proof(failures)
    checker_maps_the_top_level_gitmodules_onto_the_component(checker, failures)
    checker_requires_the_component_prefix(checker, failures)

    if failures.messages:
        print("\nCOMPONENT-ROOT TOOLING TESTS FAILED", file=sys.stderr)
        for message in failures.messages:
            print(f"  - {message}", file=sys.stderr)
        return 1

    print(
        "component-root tooling tests: three gates reject every root but contracts/v1, "
        "and the checker maps the top-level .gitmodules onto the component"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
