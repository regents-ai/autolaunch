#!/usr/bin/env python3
"""Export the pinned dependencies from a hydrated Autolaunch checkout into lib/.

The frozen contracts/v1 project owns the submodule pins; this component never fetches, never
updates them and never writes into that checkout. Each entry in dependencies.json names the
submodule path relative to the hydrated checkout, the exact revision it must be at, and the tree
entries to archive. A revision mismatch or an already-populated lib/<name> aborts.
"""

from __future__ import annotations

import argparse
import io
import json
import subprocess
import sys
import tarfile
from pathlib import Path

if sys.version_info < (3, 12):
    raise SystemExit("Python 3.12+ is required for safe tar extraction")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "source_root", type=Path, help="Autolaunch checkout whose contracts/v1/lib submodules are hydrated"
    )
    args = parser.parse_args()

    root = Path(__file__).resolve().parent
    lock = json.loads((root / "dependencies.json").read_text())
    for name, pin in lock.items():
        if name.startswith("_"):
            continue
        source = args.source_root.resolve() / pin["source"]
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
        if revision != pin["revision"]:
            raise SystemExit(f"refusing unexpected {name} revision {revision} (pinned {pin['revision']})")
        destination = root / "lib" / name
        if destination.exists() and any(destination.iterdir()):
            raise SystemExit(f"refusing to overwrite existing dependency lib/{name}")
        archive = subprocess.check_output(["git", "archive", revision, *pin["paths"]], cwd=source)
        destination.mkdir(parents=True, exist_ok=True)
        with tarfile.open(fileobj=io.BytesIO(archive)) as archived:
            archived.extractall(destination, filter="data")
        print(f"{name}: {revision}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
