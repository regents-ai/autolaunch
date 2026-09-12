#!/usr/bin/env python3
"""The local Robinhood lab: a blank Anvil chain (31338) carrying the Revshare graph.

`start` boots Anvil, installs Permit2's runtime at its canonical address, runs
`script/DeployRobinhoodLab.s.sol` from Anvil's first unlocked account and writes
`reports/generated/local-robinhood-lab/site-config.json` for the site plus
`state.json` for this controller. `fund` gives a wallet test ETH and USDG.
`status` reports the chain; `stop` ends the recorded Anvil.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Mapping, Sequence

LOCAL_CHAIN_ID = 31_338
PERMIT2 = "0x000000000022d473030f116ddee9f6b43ac78ba3"
USDG_DECIMALS = 6
DEPLOY_SCRIPT = "script/DeployRobinhoodLab.s.sol:DeployRobinhoodLab"
DEPLOYER_ENV = "REGENT_ROBINHOOD_LAB_DEPLOYER"
PERMIT2_SOURCE = Path("../stocks/lib/permit2/test/utils/DeployPermit2.sol")
GENERATED = Path("reports/generated/local-robinhood-lab")
STATE_PATH = GENERATED / "state.json"
SITE_CONFIG_PATH = GENERATED / "site-config.json"
ABI_ARTIFACTS = {
    "launchpad": Path("out/RobinhoodRevshareLaunchpadV1.sol/RobinhoodRevshareLaunchpadV1.json"),
    "erc20": Path("out/mocks/MockERC20.sol/MockERC20.json"),
}
GRAPH_LABELS = {
    "hook_salt",
    "launchpad",
    "hook",
    "usdg",
    "inbox",
    "hook_factory",
    "pool_manager",
    "position_manager",
    "cca_factory",
    "uerc20_factory",
    "permit2",
    "admin_safe",
}
GRAPH_LOG_RE = re.compile(r"REGENT_ROBINHOOD_LAB_([A-Z0-9_]+)\s*:?\s*(0x[0-9a-fA-F]+)")
ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
DOTENV_NAMES = (".env", ".env.local", ".envrc")


class LabError(RuntimeError):
    pass


def component_root() -> Path:
    root = Path(__file__).resolve().parent.parent
    for name in DOTENV_NAMES:
        if (root / name).exists():
            raise LabError(f"{name} is present in {root}; this controller never reads it")
    return root


def normalize_address(value: str, label: str = "address") -> str:
    if not ADDRESS_RE.fullmatch(value):
        raise LabError(f"invalid {label}: {value}")
    return value.lower()


def parse_quantity(value: Any) -> int:
    if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]+", value):
        raise LabError(f"invalid quantity: {value!r}")
    return int(value, 16)


def quantity(value: int) -> str:
    return hex(value)


def parse_units(value: str, decimals: int) -> int:
    match = re.fullmatch(r"([0-9]+)(?:\.([0-9]{1,%d}))?" % decimals, value)
    if not match:
        raise LabError(f"amount must be a plain decimal with at most {decimals} places: {value}")
    whole, fraction = match.group(1), (match.group(2) or "").ljust(decimals, "0")
    return int(whole) * 10**decimals + int(fraction)


def load_json(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise LabError(f"missing {path}") from exc
    except json.JSONDecodeError as exc:
        raise LabError(f"invalid JSON in {path}") from exc
    if not isinstance(document, dict):
        raise LabError(f"{path} is not a JSON object")
    return document


def atomic_write_json(path: Path, document: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=path.parent, prefix=path.name, suffix=".tmp")
    try:
        with os.fdopen(handle, "w") as stream:
            json.dump(document, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            Path(temporary).unlink()
        raise


class RpcClient:
    def __init__(self, url: str, timeout: float = 10.0):
        self.url = url
        self.timeout = timeout
        self._request_id = 0

    def request(self, method: str, params: Sequence[Any] = ()) -> Any:
        self._request_id += 1
        payload = json.dumps(
            {"jsonrpc": "2.0", "id": self._request_id, "method": method, "params": list(params)}
        ).encode()
        request = urllib.request.Request(
            self.url, data=payload, headers={"Content-Type": "application/json"}
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                document = json.load(response)
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
            raise LabError(f"local RPC request failed for {method}") from exc
        if "error" in document:
            raise LabError(f"{method}: {document['error'].get('message', 'unknown RPC error')}")
        if "result" not in document:
            raise LabError(f"local RPC omitted the result for {method}")
        return document["result"]

    def assert_local(self) -> None:
        found = parse_quantity(self.request("eth_chainId"))
        if found != LOCAL_CHAIN_ID:
            raise LabError(f"expected local chain {LOCAL_CHAIN_ID}, found {found}")


def run_checked(arguments: Sequence[str], cwd: Path, environment: Mapping[str, str]) -> str:
    completed = subprocess.run(
        list(arguments), cwd=cwd, env=dict(environment), capture_output=True, text=True
    )
    if completed.returncode != 0:
        raise LabError(
            f"{arguments[0]} failed ({completed.returncode}):\n{completed.stdout}\n{completed.stderr}"
        )
    return completed.stdout


def forge_environment(extra: Mapping[str, str] | None = None) -> dict[str, str]:
    environment = dict(os.environ)
    environment.update({"FOUNDRY_PROFILE": "default", "FOUNDRY_OFFLINE": "true", "RUST_LOG": "error"})
    if extra:
        environment.update(extra)
    return environment


def load_abis(root: Path) -> dict[str, Any]:
    abis: dict[str, Any] = {}
    for label, relative in ABI_ARTIFACTS.items():
        abi = load_json(root / relative).get("abi")
        if not isinstance(abi, list) or not abi:
            raise LabError(f"artifact has no ABI: {relative}")
        abis[label] = abi
    return abis


def permit2_runtime(root: Path) -> str:
    source = (root / PERMIT2_SOURCE).read_text()
    match = re.search(r'hex"([0-9a-fA-F]+)"', source)
    if not match:
        raise LabError("the pinned DeployPermit2 helper carries no runtime bytecode")
    return "0x" + match.group(1).lower()


def parse_graph(output: str) -> dict[str, str]:
    graph: dict[str, str] = {}
    for match in GRAPH_LOG_RE.finditer(output):
        label, value = match.group(1).lower(), match.group(2)
        if label in graph:
            raise LabError(f"deployment reported a duplicate label: {label}")
        if label == "hook_salt":
            if not re.fullmatch(r"0x[0-9a-fA-F]{64}", value):
                raise LabError("deployment reported an invalid hook salt")
            graph[label] = value.lower()
        else:
            graph[label] = normalize_address(value, label)
    if set(graph) != GRAPH_LABELS:
        raise LabError(f"deployment did not report the complete graph; missing {sorted(GRAPH_LABELS - set(graph))}")
    return graph


def deploy_graph(root: Path, client: RpcClient, deployer: str) -> dict[str, str]:
    output = run_checked(
        [
            "forge", "script", DEPLOY_SCRIPT, "--rpc-url", client.url, "--broadcast", "--unlocked",
            "--sender", deployer, "--slow", "-vv",
        ],
        root,
        forge_environment({DEPLOYER_ENV: deployer}),
    )
    return parse_graph(output)


def reserve_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as candidate:
        candidate.bind(("127.0.0.1", 0))
        return int(candidate.getsockname()[1])


def start_anvil(port: int) -> subprocess.Popen[bytes]:
    process = subprocess.Popen(
        ["anvil", "--host", "127.0.0.1", "--port", str(port), "--chain-id", str(LOCAL_CHAIN_ID), "--silent"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    client = RpcClient(f"http://127.0.0.1:{port}", timeout=1.0)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise LabError("Anvil exited during startup")
        try:
            client.assert_local()
            return process
        except LabError:
            time.sleep(0.1)
    terminate(process.pid)
    raise LabError("Anvil did not become ready")


def terminate(pid: int) -> None:
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(pid, signal.SIGTERM)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and alive(pid):
        time.sleep(0.05)
    if alive(pid):
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(pid, signal.SIGKILL)


def alive(pid: int) -> bool:
    # A child that has exited is reaped here so it never reads as alive.
    with contextlib.suppress(ChildProcessError):
        if os.waitpid(pid, os.WNOHANG)[0] == pid:
            return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def keccak_selector(signature: str) -> str:
    output = run_checked(["cast", "sig", signature], Path.cwd(), dict(os.environ)).strip()
    if not re.fullmatch(r"0x[0-9a-fA-F]{8}", output):
        raise LabError(f"cast sig returned an unexpected selector for {signature}")
    return output.lower()


def abi_address(value: str) -> str:
    return normalize_address(value)[2:].rjust(64, "0")


def abi_uint(value: int) -> str:
    return format(value, "x").rjust(64, "0")


def call_uint(client: RpcClient, target: str, signature: str, *args: str) -> int:
    data = keccak_selector(signature) + "".join(args)
    return parse_quantity(client.request("eth_call", [{"to": target, "data": data}, "latest"]))


def send_and_wait(client: RpcClient, sender: str, target: str, data: str) -> None:
    transaction_hash = client.request("eth_sendTransaction", [{"from": sender, "to": target, "data": data}])
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        receipt = client.request("eth_getTransactionReceipt", [transaction_hash])
        if receipt is not None:
            if parse_quantity(receipt["status"]) != 1:
                raise LabError(f"transaction {transaction_hash} reverted")
            return
        time.sleep(0.1)
    raise LabError(f"transaction {transaction_hash} was not mined")


def active_state(root: Path) -> tuple[dict[str, Any], RpcClient]:
    state = load_json(root / STATE_PATH)
    if state.get("status") != "active" or not alive(int(state["pid"])):
        raise LabError("no active local Robinhood lab; run start")
    client = RpcClient(str(state["rpc_url"]))
    client.assert_local()
    return state, client


def command_start(_args: argparse.Namespace) -> None:
    root = component_root()
    state_path = root / STATE_PATH
    if state_path.exists():
        old = load_json(state_path)
        if old.get("status") == "active" and alive(int(old["pid"])):
            raise LabError("a local Robinhood lab is already active; stop it first")

    run_checked(["forge", "build"], root, forge_environment())
    abis = load_abis(root)
    runtime = permit2_runtime(root)
    port = reserve_port()
    rpc_url = f"http://127.0.0.1:{port}"
    process = start_anvil(port)
    try:
        client = RpcClient(rpc_url)
        accounts = client.request("eth_accounts")
        if not isinstance(accounts, list) or not accounts:
            raise LabError("Anvil did not expose a local deployment account")
        deployer = normalize_address(str(accounts[0]), "local deployer")
        client.request("anvil_setCode", [PERMIT2, runtime])
        graph = deploy_graph(root, client, deployer)
        for label, address in graph.items():
            if label not in ("hook_salt", "admin_safe") and client.request("eth_getCode", [address, "latest"]) == "0x":
                raise LabError(f"deployed {label} has no runtime code")
        addresses = {label: value for label, value in graph.items() if label != "hook_salt"}
        run_id = f"robinhood-lab-{int(time.time())}-{process.pid}"
        atomic_write_json(
            state_path,
            {
                "status": "active",
                "pid": process.pid,
                "rpc_url": rpc_url,
                "chain_id": LOCAL_CHAIN_ID,
                "run_id": run_id,
                "deployer": deployer,
                "hook_salt": graph["hook_salt"],
                "addresses": addresses,
            },
        )
        atomic_write_json(
            root / SITE_CONFIG_PATH,
            {"rpc_url": rpc_url, "chain_id": LOCAL_CHAIN_ID, "run_id": run_id, "addresses": addresses, "abis": abis},
        )
    except BaseException:
        terminate(process.pid)
        raise
    print(
        json.dumps(
            {"rpc_url": rpc_url, "chain_id": LOCAL_CHAIN_ID, "site_config": str(root / SITE_CONFIG_PATH), "addresses": addresses},
            indent=2,
            sort_keys=True,
        )
    )


def command_fund(args: argparse.Namespace) -> None:
    root = component_root()
    state, client = active_state(root)
    wallet = normalize_address(args.wallet, "wallet")
    usdg = state["addresses"]["usdg"]
    amount = parse_units(args.usdg, USDG_DECIMALS)
    client.request("anvil_setBalance", [wallet, quantity(10**20)])
    send_and_wait(client, state["deployer"], usdg, keccak_selector("mint(address,uint256)") + abi_address(wallet) + abi_uint(amount))
    balance = call_uint(client, usdg, "balanceOf(address)", abi_address(wallet))
    print(json.dumps({"wallet": wallet, "usdg_balance": str(balance), "eth_wei": str(10**20)}, indent=2, sort_keys=True))


def command_status(_args: argparse.Namespace) -> None:
    root = component_root()
    state, client = active_state(root)
    launchpad = state["addresses"]["launchpad"]
    print(
        json.dumps(
            {
                "rpc_url": state["rpc_url"],
                "chain_id": LOCAL_CHAIN_ID,
                "block_number": parse_quantity(client.request("eth_blockNumber")),
                "launches_paused": bool(call_uint(client, launchpad, "launchesPaused()")),
                "launch_fee_usdg_atomic": str(call_uint(client, launchpad, "launchFee()")),
                "minimum_raise_usdg_atomic": str(call_uint(client, launchpad, "minimumRaiseUsdg()")),
                "next_launch_id": str(call_uint(client, launchpad, "nextLaunchId()")),
                "addresses": state["addresses"],
            },
            indent=2,
            sort_keys=True,
        )
    )


def command_stop(_args: argparse.Namespace) -> None:
    root = component_root()
    state = load_json(root / STATE_PATH)
    if state.get("status") == "active" and alive(int(state["pid"])):
        terminate(int(state["pid"]))
    atomic_write_json(root / STATE_PATH, {**state, "status": "stopped"})
    with contextlib.suppress(FileNotFoundError):
        (root / SITE_CONFIG_PATH).unlink()
    print(json.dumps({"status": "stopped"}))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("start", help="boot Anvil on chain 31338 and deploy the Revshare graph").set_defaults(run=command_start)
    fund = commands.add_parser("fund", help="give a wallet 100 test ETH and minted USDG")
    fund.add_argument("wallet")
    fund.add_argument("--usdg", default="100000", help="whole USDG to mint (default 100000)")
    fund.set_defaults(run=command_fund)
    commands.add_parser("status", help="report the active lab").set_defaults(run=command_status)
    commands.add_parser("stop", help="end the recorded Anvil and remove the site config").set_defaults(run=command_stop)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        args.run(args)
    except LabError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
