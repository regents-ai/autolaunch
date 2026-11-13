"""Checks the deployment descriptions a release ships against the tracked deployment records.

  uv run --no-project python scripts/check-deployment.py <base-revstake.json> <base-memestock.json> <covered-calls.json>

Each Base description must name, at the top, the version 3 launchers the tracked version 3
manifests record, and, in its earlier-version sections, the launchers of those versions:
Revstake's `v2`, Memestock's `v1` and `v2`. A description rendered for an earlier version names
other launchers or lacks a section, and is refused. The covered-calls description must name, for
each market a tracked covered-calls deployment record holds, the contract that record says landed
on Base. The descriptions hold the site's private RPC address, so this prints only description
and key names, each with "match" or "does not match", and never a value. Exits 1 unless every key
matches.
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def manifest(package, contract_key):
    """The address a tracked Base deployed manifest records for one contract."""
    path = ROOT / "contracts" / package / "deployments/base-mainnet/deployed-manifest.json"
    contracts = json.loads(path.read_text())["contracts"]
    (address,) = [entry["address"] for entry in contracts if entry["contract_key"] == contract_key]
    return address.lower()


def deployed(package):
    """The address a tracked covered-calls deployment record says landed on Base."""
    return json.loads((ROOT / "contracts" / package / "deploy/deployed.json").read_text())["address"].lower()


# For each description, in argument order: the key it names an address under, and where the
# tracked records keep that address. A key part that meets a list picks the entry of that symbol.
CHECKS = (
    ("base-revstake.json", [
        ("addresses.factory", manifest, ("revstake-v3", "factory")),
        ("v2.addresses.factory", manifest, ("revstake-v2", "factory")),
    ]),
    ("base-memestock.json", [
        ("addresses.launchpad", manifest, ("stocks-v3", "launchpad")),
        ("addresses.bid_adapter", manifest, ("stocks-v3", "bid_adapter")),
        ("addresses.agent_factory", manifest, ("revstake-v3", "factory")),
        ("v1.addresses.launchpad", manifest, ("stocks", "launchpad")),
        ("v1.addresses.bid_adapter", manifest, ("stocks", "bid_adapter")),
        ("v2.addresses.launchpad", manifest, ("stocks-v2", "launchpad")),
        ("v2.addresses.bid_adapter", manifest, ("stocks-v2", "bid_adapter")),
    ]),
    ("covered-calls.json", [
        ("markets.AMZNc.contract", deployed, ("covered-calls-v2",)),
    ]),
)


def named(description, key):
    """The address a description names under a dotted key, or None when it names none."""
    value = description
    for part in key.split("."):
        if isinstance(value, list):
            value = next((entry for entry in value if isinstance(entry, dict) and entry.get("symbol") == part), None)
        else:
            value = value.get(part) if isinstance(value, dict) else None
    return value.lower() if isinstance(value, str) else None


def read(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def main(paths):
    if len(paths) != len(CHECKS):
        print(
            "Usage: check-deployment.py <base-revstake.json> <base-memestock.json> <covered-calls.json>",
            file=sys.stderr,
        )
        return 2
    matched = True
    for path, (label, checks) in zip(map(Path, paths), CHECKS):
        description = read(path)
        for key, record, args in checks:
            ok = named(description, key) == record(*args)
            matched = matched and ok
            print(f"{label} {key}: {'match' if ok else 'does not match'}")
    return 0 if matched else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
