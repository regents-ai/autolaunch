"""Run scripts/deploy.sh and scripts/rollback.sh on a fixture repository.

Each test builds a git repository with its own origin in a fresh temporary folder,
holding copies of the scripts and three commits on main: `first`, `second` (which
adds a migration) and `third`. Fly, the site's health address, the locks and the
wait between health reads are stand-ins: `fly` records each call and serves the
release list from a file, `curl` answers from a file, `lockf` runs its command
without taking a lock, and `sleep` returns at once. The fixtures stay in the
system's temporary folder, which the system clears; the tests delete nothing.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
COPIED = ["deploy.sh", "rollback.sh", "release-lib.sh"]
APP = "autolaunch-sh"

GIT_ENV = {
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_SYSTEM": os.devnull,
    "GIT_AUTHOR_NAME": "Fixture",
    "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
    "GIT_COMMITTER_NAME": "Fixture",
    "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
}

FAKE_FLY = r"""#!/usr/bin/env bash
# Records every call in $FAKE/fly.log. `fly releases` answers $FAKE/releases.json.
# A switch (`fly deploy --image`) makes the site answer $FAKE/health-after, when
# that file exists.
set -euo pipefail
echo "$*" >> "$FAKE/fly.log"
case "$1" in
  releases) cat "$FAKE/releases.json" ;;
  deploy)
    if [[ " $* " == *" --image "* && -f "$FAKE/health-after" ]]; then
      cp "$FAKE/health-after" "$FAKE/health"
    fi
    ;;
  *) exit 2 ;;
esac
"""

FAKE_CURL = r"""#!/usr/bin/env bash
# curl ... <url>, answered from $FAKE/health; a missing file is a failed read.
set -euo pipefail
cat "$FAKE/health" 2>/dev/null || exit 22
"""

FAKE_LOCKF = r"""#!/usr/bin/env bash
# lockf [-k] [-s] [-t <seconds>] <file> <command...>: runs the command, takes no lock.
set -euo pipefail
while [[ "$1" == -* ]]; do
  if [[ "$1" == -t ]]; then shift; fi
  shift
done
shift
exec "$@"
"""

FAKE_SLEEP = "#!/usr/bin/env bash\n"


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="autolaunch-release-test-"))
        self.fake = self.tmp / "fake"
        self.bin = self.tmp / "bin"
        self.fake.mkdir()
        self.bin.mkdir()
        for name, body in [
            ("fly", FAKE_FLY),
            ("curl", FAKE_CURL),
            ("lockf", FAKE_LOCKF),
            ("sleep", FAKE_SLEEP),
        ]:
            path = self.bin / name
            path.write_text(body)
            path.chmod(0o755)
        self.env = {
            **os.environ,
            **GIT_ENV,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "FAKE": str(self.fake),
            "TMPDIR": str(self.tmp),
        }

        origin = self.tmp / "origin.git"
        self.repo = self.tmp / "repo"
        self.git(self.tmp, "init", "--quiet", "--bare", "--initial-branch=main", str(origin))
        self.git(self.tmp, "clone", "--quiet", str(origin), str(self.repo))
        (self.repo / "scripts").mkdir()
        for name in COPIED:
            shutil.copy(SCRIPTS / name, self.repo / "scripts" / name)
        self.write("platform/fly.toml", "# fixture\n")
        self.write("platform/.gitignore", "/deployment/\n")
        self.write("platform/deployment/base.json", "{}\n")
        self.write("platform/priv/repo/migrations/1_first.exs", "")
        self.first = self.commit("first")
        self.write("platform/priv/repo/migrations/2_second.exs", "")
        self.second = self.commit("second")
        self.write("platform/page.txt", "third\n")
        self.third = self.commit("third")
        self.git(self.repo, "push", "--quiet", "origin", "main")

    def git(self, cwd, *args):
        result = subprocess.run(
            ["git", *args], cwd=cwd, env=self.env, capture_output=True, text=True, check=True
        )
        return result.stdout.strip()

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message):
        self.git(self.repo, "add", "--all")
        self.git(self.repo, "commit", "--quiet", "-m", message)
        return self.git(self.repo, "rev-parse", "HEAD")

    def live(self, answer):
        (self.fake / "health").write_text(answer)

    def releases(self, *rows):
        """Each row is (version, status, commit the image was built from)."""
        (self.fake / "releases.json").write_text(
            json.dumps(
                [
                    {
                        "Version": version,
                        "Status": status,
                        "ImageRef": f"registry.fly.io/{APP}:{commit[:7]}",
                    }
                    for version, status, commit in rows
                ]
            )
        )

    def run_script(self, name, *args):
        return subprocess.run(
            [str(self.repo / "scripts" / name), *args],
            cwd=self.tmp,
            env=self.env,
            capture_output=True,
            text=True,
        )

    def fly_calls(self):
        log = self.fake / "fly.log"
        return log.read_text().splitlines() if log.exists() else []

    def changes(self):
        """The calls that would change the app: every `fly deploy`."""
        return [call for call in self.fly_calls() if call.startswith("deploy")]


class DeployTest(Fixture):
    def test_releases_a_commit_that_contains_the_live_one(self):
        self.live(f"ok {self.first}")
        result = self.run_script("deploy.sh", APP)
        self.assertEqual(result.returncode, 0, result.stderr)
        build, switch = self.changes()
        self.assertIn("--build-only", build)
        self.assertIn(f"SOURCE_COMMIT={self.third}", build)
        self.assertIn(f"--image registry.fly.io/{APP}:{self.third[:7]}", switch)

    def test_releases_the_live_commit_again(self):
        self.live(f"ok {self.third}")
        result = self.run_script("deploy.sh", APP)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.changes()), 2)

    def test_refuses_an_older_commit_than_the_live_one(self):
        self.git(self.repo, "checkout", "--quiet", self.second)
        self.live(f"ok {self.third}")
        for args in ([APP], [APP, "--dry-run"]):
            result = self.run_script("deploy.sh", *args)
            self.assertEqual(result.returncode, 1)
            self.assertIn(self.second, result.stderr)
            self.assertIn(self.third, result.stderr)
        self.assertEqual(self.fly_calls(), [])

    def test_refuses_when_the_health_address_cannot_be_read(self):
        result = self.run_script("deploy.sh", APP)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.fly_calls(), [])

    def test_refuses_a_health_answer_that_names_no_commit(self):
        for answer in ["", "ok", "<html>Bad gateway</html>", f"ok {self.first[:7]}"]:
            self.live(answer)
            result = self.run_script("deploy.sh", APP)
            self.assertEqual(result.returncode, 1, answer)
        self.assertEqual(self.fly_calls(), [])

    def test_refuses_a_live_commit_the_checkout_does_not_hold(self):
        self.live("ok " + "ab" * 20)
        result = self.run_script("deploy.sh", APP)
        self.assertEqual(result.returncode, 1)
        self.assertIn("ab" * 20, result.stderr)
        self.assertEqual(self.fly_calls(), [])

    def test_refuses_an_app_with_no_health_address(self):
        self.live(f"ok {self.first}")
        result = self.run_script("deploy.sh", "another-app")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.fly_calls(), [])

    def test_dry_run_prints_both_commands_and_changes_nothing(self):
        self.live(f"ok {self.first}")
        result = self.run_script("deploy.sh", APP, "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fly_calls(), [])
        self.assertFalse((self.tmp / f"autolaunch-deploy-{self.third}").exists())
        printed = [line for line in result.stdout.splitlines() if line.startswith("Would run:")]
        self.assertEqual(len(printed), 2)
        self.assertIn("--build-only", printed[0])
        self.assertIn(f"--image registry.fly.io/{APP}:{self.third[:7]}", printed[1])

    def test_rejects_an_unknown_flag(self):
        self.live(f"ok {self.first}")
        result = self.run_script("deploy.sh", APP, "--force")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.fly_calls(), [])


class RollbackTest(Fixture):
    def setUp(self):
        super().setUp()
        # v1 ran `first`, v2 `second` (a new migration), v3 failed, v4 runs `third`.
        self.releases(
            (4, "complete", self.third),
            (3, "failed", self.second),
            (2, "complete", self.second),
            (1, "complete", self.first),
        )
        self.live(f"ok {self.third}")

    def test_goes_back_to_a_release_with_the_same_migrations(self):
        (self.fake / "health-after").write_text(f"ok {self.second}")
        result = self.run_script("rollback.sh", APP, "v2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.second, result.stdout)
        (switch,) = self.changes()
        self.assertIn(f"--image registry.fly.io/{APP}:{self.second[:7]}", switch)
        self.assertNotIn("--build-only", switch)

    def test_fails_when_the_site_never_names_the_older_commit(self):
        result = self.run_script("rollback.sh", APP, "v2")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(self.changes()), 1)
        self.assertIn(self.second, result.stderr)

    def test_refuses_a_release_across_a_migration(self):
        for args in (["v1"], ["v1", "--dry-run"]):
            result = self.run_script("rollback.sh", APP, *args)
            self.assertEqual(result.returncode, 1)
            self.assertIn("2_second.exs", result.stderr)
        self.assertEqual(self.changes(), [])

    def test_refuses_a_release_that_did_not_complete(self):
        result = self.run_script("rollback.sh", APP, "v3")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.changes(), [])

    def test_refuses_a_release_the_app_never_had(self):
        result = self.run_script("rollback.sh", APP, "v9")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.changes(), [])

    def test_refuses_an_image_that_names_no_known_commit(self):
        self.releases((2, "complete", "cd" * 20))
        result = self.run_script("rollback.sh", APP, "v2")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.changes(), [])

    def test_refuses_when_the_health_address_cannot_be_read(self):
        (self.fake / "health").unlink()
        result = self.run_script("rollback.sh", APP, "v2")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.changes(), [])

    def test_dry_run_prints_the_switch_and_changes_nothing(self):
        result = self.run_script("rollback.sh", APP, "v2", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.changes(), [])
        (printed,) = [line for line in result.stdout.splitlines() if line.startswith("Would run:")]
        self.assertIn(f"--image registry.fly.io/{APP}:{self.second[:7]}", printed)

    def test_rejects_a_release_that_is_not_a_version(self):
        for args in (["269"], ["v2", "--force"], []):
            result = self.run_script("rollback.sh", APP, *args)
            self.assertEqual(result.returncode, 2)
        self.assertEqual(self.fly_calls(), [])


if __name__ == "__main__":
    unittest.main()
