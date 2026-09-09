#!/usr/bin/env python3
"""Deploy the Agent contract graph onto an already-running Anvil fork (the preview chain).

`contracts/v1/bin/local-base-lab.py start` always launches its own Anvil. This thin controller imports
that module unchanged and reuses its steps against an existing RPC: compile with the `local-base-lab`
Forge profile, broadcast `DeployLocalAutolaunchLab`, prove every address has code, check the Governance
Safe runtime against the pinned clean baseline, unpause the factory from the impersonated Safe, and
write `state.json` + `site-config.json` in the shapes the Stocks controller and the website read.

The RPC must be a loopback URL answering as chain 31337 (the lab's own rule); in practice that is the
private door brought to this machine by `fly proxy 8547:8547 -a autolaunch-fork-preview`.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import shlex
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

if sys.version_info < (3, 12):
    raise SystemExit("Python 3.12+ is required")

OPS_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = OPS_ROOT.parents[1]
AGENT_LAB_CONTROLLER = REPOSITORY_ROOT / "contracts" / "v1" / "bin" / "local-base-lab.py"
DEFAULT_OUT = OPS_ROOT / "generated"
DEFAULT_RPC_URL = "http://127.0.0.1:8547"


def load_agent_lab() -> ModuleType:
    sys.dont_write_bytecode = True  # leave no __pycache__ beside the frozen controller
    spec = importlib.util.spec_from_file_location("local_base_lab", AGENT_LAB_CONTROLLER)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot import {AGENT_LAB_CONTROLLER}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--rpc-url", default=DEFAULT_RPC_URL, help=f"loopback URL of the private door (default {DEFAULT_RPC_URL})")
    parser.add_argument("--out", default=str(DEFAULT_OUT), help=f"folder for state.json and site-config.json (default {DEFAULT_OUT})")
    parser.add_argument("--force", action="store_true", help="deploy even if an active state.json is already recorded there")
    parser.add_argument("--dry-run", action="store_true", help="print the steps and commands without contacting anything")
    return parser


def site_config(lab: ModuleType, rpc_url: str, graph: dict[str, str], abis: dict[str, Any]) -> dict[str, Any]:
    addresses = {key: value for key, value in graph.items() if key != "hook_salt"}
    addresses.update(
        {
            "regent": lab.REGENT,
            "permit2": lab.PERMIT2,
            "cca_factory": lab.CCA_FACTORY,
            "pool_manager": lab.POOL_MANAGER,
            "position_manager": lab.POSITION_MANAGER,
            "governance_safe": lab.GOVERNANCE_SAFE,
        }
    )
    return {
        "rpc_url": lab.validate_loopback_rpc_url(rpc_url),
        "chain_id": lab.LOCAL_CHAIN_ID,
        "addresses": addresses,
        "abis": dict(abis),
    }


def dry_run(lab: ModuleType, rpc_url: str, out: Path) -> None:
    root = lab.repository_root()
    steps = [
        f"# cwd {root}",
        "forge build --offline --skip test --skip '**/*.t.sol'   # FOUNDRY_PROFILE=local-base-lab FOUNDRY_OFFLINE=true",
        "forge inspect <each ABI target> abi --json            # " + ", ".join(sorted(lab.ABI_TARGETS)),
        f"rpc {rpc_url} eth_chainId                             # must be 31337",
        f"rpc {rpc_url} eth_accounts                            # accounts[0] is the deployer",
        shlex.join(
            [
                "forge", "script",
                "tools/local-base-lab/DeployLocalAutolaunchLab.s.sol:DeployLocalAutolaunchLab",
                "--rpc-url", rpc_url, "--broadcast", "--unlocked", "--sender", "<accounts[0]>", "--slow", "-vv",
            ]
        )
        + "   # REGENT_LOCAL_LAB_DEPLOYER=<accounts[0]>",
        f"rpc {rpc_url} eth_getCode <each deployed address>     # every one must have runtime code",
        f"rpc {rpc_url} eth_getCode {lab.GOVERNANCE_SAFE}   # keccak must equal {lab.PINNED_SAFE_RUNTIME_HASH}",
        f"rpc {rpc_url} anvil_setBalance {lab.GOVERNANCE_SAFE} 1 ETH; anvil_impersonateAccount; eth_sendTransaction factory.unpauseLaunches(); anvil_stopImpersonatingAccount",
        f"write {out / 'state.json'}",
        f"write {out / 'site-config.json'}",
    ]
    for step in steps:
        print(f"+ {step}")


def deploy(lab: ModuleType, rpc_url: str, out: Path, force: bool) -> None:
    root = lab.repository_root()
    lab.require_no_dotenv(root)
    state_path = out / "state.json"
    if state_path.exists() and not force:
        recorded = lab.load_json(state_path)
        if recorded.get("status") == "active":
            raise lab.LabError(f"{state_path} records an active graph; pass --force to deploy another")

    lab.validate_loopback_rpc_url(rpc_url)
    client = lab.RpcClient(rpc_url, timeout=120.0)
    client.assert_local()

    lab.compile_lab(root)
    abis = lab.load_abis(root)

    accounts = client.read("eth_accounts")
    if not isinstance(accounts, list) or not accounts:
        raise lab.LabError("the fork did not expose a deployment account")
    deployer = lab.normalize_address(str(accounts[0]), "deployer")

    graph = lab.deploy_graph(root, client, deployer)
    addresses = {key: value for key, value in graph.items() if key != "hook_salt"}
    lab.require_deployed_code(client, addresses)
    safe_runtime = lab.require_clean_safe_runtime(root, lab.runtime_code(client, lab.GOVERNANCE_SAFE))
    lab.unpause_factory(client, graph["factory"])

    state = {
        "status": "active",
        "host": "fork-preview",
        "rpc_url": rpc_url,
        "chain_id": lab.LOCAL_CHAIN_ID,
        "deployer": deployer,
        "block_number_at_start": lab.parse_quantity(client.read("eth_blockNumber")),
        "addresses": addresses,
        "hook_salt": graph["hook_salt"],
        "governance_safe_original_runtime": safe_runtime,
    }
    lab.atomic_write_json(state_path, state)
    lab.atomic_write_json(out / "site-config.json", site_config(lab, rpc_url, graph, abis))
    print(
        json.dumps(
            {
                "rpc_url": rpc_url,
                "chain_id": lab.LOCAL_CHAIN_ID,
                "state": str(state_path),
                "site_config": str(out / "site-config.json"),
                "addresses": addresses,
            },
            indent=2,
            sort_keys=True,
        )
    )


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    out = Path(args.out).resolve()
    lab = load_agent_lab()
    if args.dry_run:
        dry_run(lab, args.rpc_url, out)
        return 0
    try:
        with lab.termination_unwinds():
            deploy(lab, args.rpc_url, out, args.force)
        return 0
    except (lab.LabError, lab.TerminationSignal) as exc:
        print(f"fork preview Agent deploy failed: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("fork preview Agent deploy failed: interrupted", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
