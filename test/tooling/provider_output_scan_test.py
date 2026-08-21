#!/usr/bin/env python3
"""Deterministic tooling tests for the provider-output scan, run without a provider.

`bin/fork-gate.sh` has two failure orders that must not be confused with each other, and neither
of them can be exercised by the required offline gate's Solidity suite: one is about a provider's
*output*, and the other is about a provider run's *exit status*.

  order one — the run failed, its output is clean.
      The output is not a secret. It has already passed the scan, so it is displayed and the whole
      scratch directory is kept, because that is the only diagnostic material a stop-report has.

  order two — the output is dirty, whatever the run's exit status was.
      Nothing may be displayed. The scan reports only redacted findings and the caller deletes the
      scratch unread. The redacted report must name the local paths and must not carry the host,
      any other endpoint component, or any key-shaped token.

These are the two orders, proved against the real `bin/check-requirements.py sanitize`
implementation with fabricated files. Nothing here touches a network, reads an environment
variable, or needs a provider.

The fabricated endpoint is assembled from fragments at runtime rather than written out as a
literal, so this file itself never carries a provider host or a key-shaped token. Run by
`bin/gate.sh`; a failure here fails the gate.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import tempfile
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CHECKER_PATH = REPOSITORY_ROOT / "bin" / "check-requirements.py"

# Assembled at runtime. A literal here would put a provider host and a key-shaped token into a
# committed file, which is exactly the thing under test.
FAKE_HOST = "eth-base." + "alch" + "emy" + "api.io"
FAKE_KEY = "S3CRET-PROJECT-ID"
FAKE_ENDPOINT = "https" + "://" + FAKE_HOST + "/v2/" + FAKE_KEY
FAKE_KEY_SHAPE = "x-api" + "-key"


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


def run_sanitize(checker, scratch: Path) -> tuple[int, str, str]:
    """Call the real subcommand exactly as `bin/fork-gate.sh` calls it, capturing both streams."""
    out, err = io.StringIO(), io.StringIO()
    argv = sys.argv
    sys.argv = ["check-requirements.py", "sanitize", "--scan", str(scratch)]
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = checker.main()
    finally:
        sys.argv = argv
    return status, out.getvalue(), err.getvalue()


def order_one_ordinary_failure_keeps_scanned_diagnostics(checker, failures: Failures) -> None:
    """The run failed and said why, in ordinary language. That is diagnosis, not a leak."""
    with tempfile.TemporaryDirectory() as raw:
        scratch = Path(raw)
        (scratch / "forge-test-pinned.log").write_text(
            "Ran 3 tests for test-fork/ProtocolFork.t.sol:ProtocolForkTest\n"
            "[FAIL: the deployed live staking contract is paused] test_DEP_045_ForkPinned...\n"
            "Encountered a total of 1 failing test\n",
            encoding="utf-8",
        )
        (scratch / "forge-config.json").write_text('{"rpc_endpoints":{"base":"${REGENT_BASE_RPC_URL}"}}\n', "utf-8")

        status, out, err = run_sanitize(checker, scratch)

        failures.check(status == 0, "order one: a clean failing run was not allowed to display its diagnostics")
        failures.check("2 file(s) clean" in out, f"order one: the scan did not report both files clean, said [{out!r}]")
        failures.check(err == "", f"order one: a clean scan wrote to stderr: {err!r}")
        failures.check(
            (scratch / "forge-test-pinned.log").is_file(),
            "order one: the tooling under test is expected to leave the scratch in place",
        )


def order_two_dirty_output_is_redacted(checker, failures: Failures) -> None:
    """A resolved endpoint reached the output. Nothing may be displayed, and nothing may leak."""
    with tempfile.TemporaryDirectory() as raw:
        scratch = Path(raw)
        (scratch / "forge-test-later.log").write_text(
            f"error sending request for url ({FAKE_ENDPOINT}): connection closed\n", encoding="utf-8"
        )

        status, out, err = run_sanitize(checker, scratch)

        failures.check(status != 0, "order two: a resolved endpoint in provider output did not fail the scan")
        combined = out + err
        failures.check(FAKE_HOST not in combined, "order two: the scan report named the provider host")
        failures.check(FAKE_KEY not in combined, "order two: the scan report carried the endpoint's key material")
        failures.check("https://" not in combined, "order two: the scan report carried a URL")
        failures.check(
            "forge-test-later.log" in combined,
            "order two: the scan report did not name the local path it would have the caller delete",
        )


def order_two_key_shape_outside_a_url_is_redacted(checker, failures: Failures) -> None:
    """Key material does not have to be inside a URL to be key material."""
    with tempfile.TemporaryDirectory() as raw:
        scratch = Path(raw)
        (scratch / "forge-test-discovery.log").write_text(
            f"request headers: {FAKE_KEY_SHAPE}: {FAKE_KEY}\n", encoding="utf-8"
        )

        status, out, err = run_sanitize(checker, scratch)

        failures.check(status != 0, "order two: a key-shaped token outside a URL did not fail the scan")
        combined = out + err
        failures.check(FAKE_KEY_SHAPE not in combined, "order two: the scan report quoted the key-shaped token")
        failures.check(
            "outside a URL" in combined, "order two: the scan report did not say the finding was outside a URL"
        )


def order_two_wins_when_both_happen(checker, failures: Failures) -> None:
    """A failing run whose output is also dirty is order two, not order one."""
    with tempfile.TemporaryDirectory() as raw:
        scratch = Path(raw)
        (scratch / "forge-test-pinned.log").write_text(
            f"Encountered a total of 1 failing test\nprovider: {FAKE_ENDPOINT}\n", encoding="utf-8"
        )

        status, out, err = run_sanitize(checker, scratch)

        failures.check(status != 0, "a failing run with dirty output was treated as an ordinary failure")
        failures.check(FAKE_HOST not in out + err, "a failing run with dirty output leaked its host anyway")


def redaction_removes_the_whole_endpoint(checker, failures: Failures) -> None:
    """Redaction is not host-only: a project id in a path is a credential too."""
    redacted = checker.redact(f"see {FAKE_ENDPOINT} and {FAKE_KEY_SHAPE}")
    failures.check(FAKE_HOST not in redacted, "redaction left the host in place")
    failures.check(FAKE_KEY not in redacted, "redaction left the endpoint's path credential in place")
    failures.check(FAKE_KEY_SHAPE not in redacted, "redaction left a key-shaped token in place")
    failures.check(checker.REDACTION in redacted, "redaction produced no visible marker")


def main() -> int:
    checker = load_checker()
    failures = Failures()

    order_one_ordinary_failure_keeps_scanned_diagnostics(checker, failures)
    order_two_dirty_output_is_redacted(checker, failures)
    order_two_key_shape_outside_a_url_is_redacted(checker, failures)
    order_two_wins_when_both_happen(checker, failures)
    redaction_removes_the_whole_endpoint(checker, failures)

    if failures.messages:
        print("\nPROVIDER-OUTPUT SCAN TOOLING TESTS FAILED", file=sys.stderr)
        for message in failures.messages:
            print(f"  - {message}", file=sys.stderr)
        return 1

    print("provider-output scan tooling tests: both failure orders proved, without a provider")
    return 0


if __name__ == "__main__":
    sys.exit(main())
