#!/usr/bin/env python3
"""Rewrite the two lab documents for the website's fork mode.

Reads `site-config.json` and `stocks-site-config.json` from the generated folder (written by
`deploy-agent-graph.py` and `contracts/stocks/bin/local-stocks-lab.py deploy` against the loopback
private door) and writes them into `<generated>/fork/` with:

  rpc_url          the PRIVATE door as the website reaches it on Fly's private network
  public_rpc_url   the PUBLIC door visitors' wallets use (https)
  agent_lab_config (stocks file only) the path the website will read the fork `site-config.json`
                   from once the two files are copied into its image (default `/app/fork`, the
                   folder `platform/Dockerfile.preview` copies to), because the website checks that
                   the two documents belong together

Every other key is copied unchanged.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import urllib.parse
from pathlib import Path
from typing import Any

if sys.version_info < (3, 12):
    raise SystemExit("Python 3.12+ is required")

OPS_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_GENERATED = OPS_ROOT / "generated"
DEFAULT_APP = "autolaunch-fork-preview"

AGENT_NAME = "site-config.json"
STOCKS_NAME = "stocks-site-config.json"
LOCAL_CHAIN_ID = 31_337


class ConfigError(RuntimeError):
    """An expected failure while rewriting the documents."""


def load_object(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text())
    except (FileNotFoundError, OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"document is unavailable or invalid: {path}") from exc
    if not isinstance(document, dict):
        raise ConfigError(f"document is not an object: {path}")
    return document


def atomic_write_json(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False)
    temporary = Path(handle.name)
    try:
        with handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def require_url(value: str, label: str, schemes: set[str]) -> str:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in schemes or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ConfigError(f"{label} must be a plain {'/'.join(sorted(schemes))} URL without credentials, query or fragment: {value!r}")
    return value


def rewrite(generated: Path, rpc_url: str, public_rpc_url: str, mount_dir: str) -> dict[str, Path]:
    agent = load_object(generated / AGENT_NAME)
    stocks = load_object(generated / STOCKS_NAME)
    for name, document in ((AGENT_NAME, agent), (STOCKS_NAME, stocks)):
        if document.get("chain_id") != LOCAL_CHAIN_ID:
            raise ConfigError(f"{name} does not describe chain {LOCAL_CHAIN_ID}")
        if not isinstance(document.get("addresses"), dict) or not isinstance(document.get("abis"), dict):
            raise ConfigError(f"{name} lacks its addresses or abis")
    if agent.get("rpc_url") != stocks.get("rpc_url"):
        raise ConfigError("the two documents were written against different RPC URLs; redeploy the Stocks graph")

    fork_dir = generated / "fork"
    agent_out = fork_dir / AGENT_NAME
    stocks_out = fork_dir / STOCKS_NAME

    fork_agent = dict(agent)
    fork_agent["rpc_url"] = rpc_url
    fork_agent["public_rpc_url"] = public_rpc_url

    fork_stocks = dict(stocks)
    fork_stocks["rpc_url"] = rpc_url
    fork_stocks["public_rpc_url"] = public_rpc_url
    fork_stocks["agent_lab_config"] = mount_dir.rstrip("/") + "/" + AGENT_NAME

    atomic_write_json(agent_out, fork_agent)
    atomic_write_json(stocks_out, fork_stocks)
    return {"site_config": agent_out, "stocks_site_config": stocks_out}


def summary(paths: dict[str, Path]) -> dict[str, Any]:
    agent = load_object(paths["site_config"])
    stocks = load_object(paths["stocks_site_config"])
    return {
        "site_config": str(paths["site_config"]),
        "stocks_site_config": str(paths["stocks_site_config"]),
        "rpc_url": agent["rpc_url"],
        "public_rpc_url": agent["public_rpc_url"],
        "chain_id": agent["chain_id"],
        "agent_addresses": agent["addresses"],
        "stocks_addresses": {key: stocks["addresses"][key] for key in ("launchpad", "hook", "bid_adapter")},
        "stocks": [entry["symbol"] for entry in stocks["stocks"]],
        "agent_launch_fee_regent": stocks["agent_launch_fee_regent"],
        "stocks_launch_fee_regent": stocks["stocks_launch_fee_regent"],
    }


def build_parser() -> argparse.ArgumentParser:
    app = os.environ.get("FORK_APP", DEFAULT_APP)
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--generated", default=str(DEFAULT_GENERATED), help=f"folder holding the loopback documents (default {DEFAULT_GENERATED})")
    parser.add_argument("--rpc-url", default=os.environ.get("FORK_INTERNAL_RPC_URL", f"http://{app}.internal:8547"), help="private door URL the website uses (env FORK_INTERNAL_RPC_URL)")
    parser.add_argument("--mount-dir", default=os.environ.get("FORK_CONFIG_MOUNT_DIR", "/app/fork"), help="folder the website image holds both documents in (env FORK_CONFIG_MOUNT_DIR)")
    parser.add_argument("--public-rpc-url", default=os.environ.get("FORK_PUBLIC_RPC_URL", f"https://{app}.fly.dev"), help="public door URL for wallets (env FORK_PUBLIC_RPC_URL)")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        rpc_url = require_url(args.rpc_url, "--rpc-url", {"http", "https"})
        public_rpc_url = require_url(args.public_rpc_url, "--public-rpc-url", {"https"})
        paths = rewrite(Path(args.generated).resolve(), rpc_url, public_rpc_url, args.mount_dir)
        print(json.dumps(summary(paths), indent=2, sort_keys=True))
        return 0
    except ConfigError as exc:
        print(f"fork config rewrite failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
