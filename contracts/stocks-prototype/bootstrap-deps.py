#!/usr/bin/env python3
"""Export pinned, already available dependencies; never update frozen V1."""
import argparse
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile

if sys.version_info < (3, 12):
    raise SystemExit("Python 3.12+ is required for safe tar extraction")

parser = argparse.ArgumentParser()
parser.add_argument("source_root", type=Path, help="Autolaunch checkout with materialized V1 dependencies")
args = parser.parse_args()
root = Path(__file__).resolve().parent
lock = json.loads((root / "dependencies.json").read_text())
for name, pin in lock.items():
    source = args.source_root.resolve() / pin["source"]
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != pin["revision"]:
        raise SystemExit(f"Refusing unexpected {name} revision")
    destination = root / "lib" / name
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit(f"Refusing to overwrite existing dependency {name}")
    entries = subprocess.check_output(["git", "ls-tree", "--name-only", revision], cwd=source, text=True).splitlines()
    included = [entry for entry in entries if entry in ("src", "test", "LICENSE", "LICENSE.md", "README.md")]
    archive = subprocess.check_output(["git", "archive", revision, *included], cwd=source)
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tf:
        tf.extractall(destination, filter="data")
    print(f"{name}: {revision}")
