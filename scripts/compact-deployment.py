"""Writes the deployment descriptions a release ships without whitespace, and refuses them when too big.

  uv run --no-project python scripts/compact-deployment.py [--into <folder>] <description.json>...

Fly carries the files fly.toml's [[files]] place on the machine inside the machine's own
configuration, whose size it limits: on 13 Nov 2026 640,000 bytes of files went through and
850,000 were refused with "request body too large", after a release had already been built. This
refuses, before anything is built or switched, when the descriptions together come to more than
LIMIT bytes once their whitespace is gone. Otherwise, with --into, it writes each one without
whitespace into that folder under its own name. The descriptions hold the site's private RPC
address, so it prints only sizes, never a value. Exits 1 when over the limit.
"""

import argparse
import json
import sys
from pathlib import Path

LIMIT = 700_000


def compact(path):
    return json.dumps(json.loads(path.read_text(encoding="utf-8")), separators=(",", ":"))


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--into", type=Path)
    parser.add_argument("descriptions", nargs="+", type=Path)
    args = parser.parse_args(argv)

    documents = {path.name: compact(path) for path in args.descriptions}
    total = sum(len(text.encode("utf-8")) for text in documents.values())
    if total > LIMIT:
        print(
            f"Refusing: the deployment descriptions come to {total:,} bytes without whitespace, over the "
            f"{LIMIT:,} Fly's machine configuration can carry. Take out of them what the site no longer "
            "reads, then release again.",
            file=sys.stderr,
        )
        return 1
    print(f"==> The deployment descriptions come to {total:,} bytes without whitespace, within {LIMIT:,}")
    if args.into:
        args.into.mkdir(parents=True, exist_ok=True)
        for name, text in documents.items():
            (args.into / name).write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
