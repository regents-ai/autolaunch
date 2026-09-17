#!/usr/bin/env python3
"""The local Robinhood lab: a blank Anvil chain (31338) carrying the Revshare and Stocks graphs.

`start` boots Anvil, installs Permit2's runtime at its canonical address, runs
`script/DeployRobinhoodLab.s.sol` from Anvil's first unlocked account, reads every
fixture stock and its route back from the chain, and writes
`reports/generated/local-robinhood-lab/site-config.json` for the site plus
`state.json` for this controller. `fund` gives a wallet test ETH, USDG and optionally
fixture STOCK. `status` reports both launchpads and every admitted stock. `advance`
mines to an auction's start, end, claim or migration block; `migrate` graduates or
fails a launch once its migration block has passed. `stop` ends the recorded Anvil.

Every mutation and `stop` first proves the recorded run is this controller's own: the recorded
process is alive, is Anvil, is the one process listening on the recorded loopback port, and the
chain there carries the recorded genesis hash and both launchpads. Chain id 31338 alone identifies
nothing, because other labs on this machine use it too.
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
STOCK_DECIMALS = 8
DEPLOY_SCRIPT = "script/DeployRobinhoodLab.s.sol:DeployRobinhoodLab"
DEPLOYER_ENV = "REGENT_ROBINHOOD_LAB_DEPLOYER"
PERMIT2_SOURCE = Path("../stocks/lib/permit2/test/utils/DeployPermit2.sol")
GENERATED = Path("reports/generated/local-robinhood-lab")
STATE_PATH = GENERATED / "state.json"
SITE_CONFIG_PATH = GENERATED / "site-config.json"
ABI_ARTIFACTS = {
    "launchpad": Path("out/RobinhoodRevshareLaunchpadV1.sol/RobinhoodRevshareLaunchpadV1.json"),
    "stocks_launchpad": Path("out/RobinhoodStocksLaunchpadV1.sol/RobinhoodStocksLaunchpadV1.json"),
    "bid_adapter": Path("out/RobinhoodStockBidAdapterV1.sol/RobinhoodStockBidAdapterV1.json"),
    "stock_route": Path("out/FixtureUsdgStockRoute.sol/FixtureUsdgStockRoute.json"),
    "auction": Path("out/ContinuousClearingAuction.sol/ContinuousClearingAuction.json"),
    "erc20": Path("out/mocks/MockERC20.sol/MockERC20.json"),
}
GRAPH_LABELS = {
    "hook_salt",
    "launchpad",
    "hook",
    "stocks_hook_salt",
    "stocks_launchpad",
    "stocks_hook",
    "bid_adapter",
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
STOCK_LABEL_RE = re.compile(r"^(stock|route)_([a-z0-9]+)$")
LAUNCH_FIELDS = (
    "launcher", "newToken", "currency", "auction", "startBlock", "endBlock", "claimBlock", "migrationBlock",
    "requiredRaise", "floorPriceQ96", "lifecycle", "poolId", "finalSqrtPriceX96", "lpTokenId", "lpCurrencyUsed",
    "lpNewUsed", "retiredNew",
)
LIFECYCLES = ("None", "Active", "Graduated", "Failed")
LAUNCHPAD_KINDS = {"revshare": "launchpad", "stocks": "stocks_launchpad"}
MINE_CHUNK_BLOCKS = 200
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
    # forge 1.4's lint pre-pass cannot follow the `../stocks/lib` imports and fails the build; the
    # compiler itself resolves them. Lint is not part of the lab.
    environment.update(
        {"FOUNDRY_PROFILE": "default", "FOUNDRY_OFFLINE": "true", "FOUNDRY_LINT_LINT_ON_BUILD": "false", "RUST_LOG": "error"}
    )
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


def parse_graph(output: str) -> tuple[dict[str, str], dict[str, dict[str, str]]]:
    """Split the deployment log into the fixed graph and the per-stock `{symbol: {stock, route}}` pairs."""
    graph: dict[str, str] = {}
    stocks: dict[str, dict[str, str]] = {}
    for match in GRAPH_LOG_RE.finditer(output):
        label, value = match.group(1).lower(), match.group(2)
        stock_label = STOCK_LABEL_RE.match(label)
        if stock_label:
            role, symbol = stock_label.groups()
            entry = stocks.setdefault(symbol, {})
            if role in entry:
                raise LabError(f"deployment reported a duplicate label: {label}")
            entry[role] = normalize_address(value, label)
        elif label in graph:
            raise LabError(f"deployment reported a duplicate label: {label}")
        elif label.endswith("hook_salt"):
            if not re.fullmatch(r"0x[0-9a-fA-F]{64}", value):
                raise LabError(f"deployment reported an invalid {label}")
            graph[label] = value.lower()
        else:
            graph[label] = normalize_address(value, label)
    if set(graph) != GRAPH_LABELS:
        raise LabError(f"deployment did not report the complete graph; missing {sorted(GRAPH_LABELS - set(graph))}")
    if not stocks:
        raise LabError("deployment reported no fixture stocks")
    for symbol, entry in stocks.items():
        if set(entry) != {"stock", "route"}:
            raise LabError(f"deployment reported an incomplete stock pair for {symbol}")
    return graph, stocks


def deploy_graph(root: Path, client: RpcClient, deployer: str) -> tuple[dict[str, str], dict[str, dict[str, str]]]:
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


def listening_pid(port: int) -> int | None:
    """The one process listening on this loopback TCP port, or None when nothing (or several) does."""
    completed = subprocess.run(
        ["lsof", "-nP", "-a", f"-iTCP@127.0.0.1:{port}", "-sTCP:LISTEN", "-Fp"],
        capture_output=True,
        text=True,
        check=False,
    )
    pids = {int(line[1:]) for line in completed.stdout.splitlines() if line.startswith("p")}
    return pids.pop() if len(pids) == 1 else None


def process_name(pid: int) -> str:
    completed = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True, check=False)
    return Path(completed.stdout.strip()).name


def genesis_hash(client: RpcClient) -> str:
    block = client.request("eth_getBlockByNumber", ["0x0", False])
    if not isinstance(block, dict) or not isinstance(block.get("hash"), str):
        raise LabError("local RPC returned no genesis block")
    return str(block["hash"]).lower()


def loopback_port(rpc_url: str) -> int:
    match = re.fullmatch(r"http://127\.0\.0\.1:(\d+)", rpc_url)
    if match is None:
        raise LabError("recorded endpoint is not a loopback Anvil; refusing to touch it")
    return int(match.group(1))


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


def eth_call(client: RpcClient, target: str, signature: str, *args: str) -> str:
    data = keccak_selector(signature) + "".join(args)
    return str(client.request("eth_call", [{"to": target, "data": data}, "latest"]))


def words(data: str) -> list[int]:
    raw = bytes.fromhex(data.removeprefix("0x"))
    if len(raw) % 32:
        raise LabError("readback is not word aligned")
    return [int.from_bytes(raw[i : i + 32], "big") for i in range(0, len(raw), 32)]


def decode_address_word(value: int) -> str:
    if value >> 160:
        raise LabError("address readback has high bits set")
    return "0x" + f"{value:040x}"


def decode_string(data: str) -> str:
    raw = bytes.fromhex(data.removeprefix("0x"))
    if len(raw) < 64:
        raise LabError("string readback too short")
    offset = int.from_bytes(raw[:32], "big")
    length = int.from_bytes(raw[offset : offset + 32], "big")
    return raw[offset + 32 : offset + 32 + length].decode("utf-8")


def call_uint(client: RpcClient, target: str, signature: str, *args: str) -> int:
    values = words(eth_call(client, target, signature, *args))
    if len(values) != 1:
        raise LabError(f"{signature} readback has the wrong ABI length")
    return values[0]


def call_address(client: RpcClient, target: str, signature: str, *args: str) -> str:
    return decode_address_word(call_uint(client, target, signature, *args))


def call_string(client: RpcClient, target: str, signature: str, *args: str) -> str:
    return decode_string(eth_call(client, target, signature, *args))


def balance_of(client: RpcClient, token: str, holder: str) -> int:
    return call_uint(client, token, "balanceOf(address)", abi_address(holder))


def send_and_wait(client: RpcClient, sender: str, target: str, data: str) -> str:
    transaction_hash = str(client.request("eth_sendTransaction", [{"from": sender, "to": target, "data": data}]))
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        receipt = client.request("eth_getTransactionReceipt", [transaction_hash])
        if receipt is not None:
            if parse_quantity(receipt["status"]) != 1:
                raise LabError(f"transaction {transaction_hash} reverted")
            return transaction_hash
        time.sleep(0.1)
    raise LabError(f"transaction {transaction_hash} was not mined")


def describe_stocks(client: RpcClient, graph: Mapping[str, str], pairs: Mapping[str, Mapping[str, str]]) -> list[dict[str, Any]]:
    """Read every fixture stock back from the chain and confirm its admission on the Stocks launchpad."""
    launchpad = graph["stocks_launchpad"]
    stocks: list[dict[str, Any]] = []
    for label in sorted(pairs):
        stock, route = pairs[label]["stock"], pairs[label]["route"]
        symbol = call_string(client, stock, "symbol()")
        if symbol.lower() != label:
            raise LabError(f"fixture stock at {stock} reports {symbol!r}, the deployment log says {label!r}")
        decimals = call_uint(client, stock, "decimals()")
        if decimals != STOCK_DECIMALS:
            raise LabError(f"fixture stock {symbol} does not report {STOCK_DECIMALS} decimals")
        if call_address(client, route, "stock()") != stock or call_address(client, route, "usdg()") != graph["usdg"]:
            raise LabError(f"route for {symbol} is not bound to its stock and USDG")
        admitted, recorded_decimals, recorded_route = words(eth_call(client, launchpad, "stockAdmission(address)", abi_address(stock)))
        if admitted != 1 or recorded_decimals != STOCK_DECIMALS or decode_address_word(recorded_route) != route:
            raise LabError(f"admission readback mismatch for {symbol}")
        stocks.append(
            {
                "symbol": symbol,
                "name": call_string(client, stock, "name()"),
                "address": stock,
                "decimals": STOCK_DECIMALS,
                "route": route,
                "usdg_per_share": str(call_uint(client, route, "usdgPerShare()")),
                "fixture": True,
                "launch_admission": "fixture_admitted",
            }
        )
    return stocks


def stock_entry(state: Mapping[str, Any], symbol: str) -> dict[str, Any]:
    for entry in state["stocks"]:
        if entry["symbol"].lower() == symbol.lower():
            return dict(entry)
    raise LabError(f"unknown stock symbol {symbol}; catalog: {', '.join(e['symbol'] for e in state['stocks'])}")


def launch_record(client: RpcClient, launchpad: str, launch_id: int) -> dict[str, Any]:
    values = words(eth_call(client, launchpad, "launches(uint256)", abi_uint(launch_id)))
    if len(values) != len(LAUNCH_FIELDS):
        raise LabError("launches(uint256) returned the wrong ABI length")
    record: dict[str, Any] = {}
    for name, value in zip(LAUNCH_FIELDS, values):
        if name in {"launcher", "newToken", "currency", "auction"}:
            record[name] = decode_address_word(value)
        elif name == "lifecycle":
            record[name] = LIFECYCLES[value]
        elif name == "poolId":
            record[name] = "0x" + f"{value:064x}"
        else:
            record[name] = value
    if record["auction"] == "0x" + "0" * 40:
        raise LabError(f"unknown launch {launch_id}")
    return record


def auction_timing(client: RpcClient, launchpad: str, auction: str) -> dict[str, Any]:
    auction = normalize_address(auction, "auction")
    launch_id = call_uint(client, launchpad, "launchIdOfAuction(address)", abi_address(auction))
    if launch_id == 0:
        raise LabError("that auction was not created by the chosen launchpad")
    record = launch_record(client, launchpad, launch_id)
    return {
        "auction": auction,
        "launch_id": launch_id,
        "start": call_uint(client, auction, "startBlock()"),
        "end": call_uint(client, auction, "endBlock()"),
        "claim": call_uint(client, auction, "claimBlock()"),
        "migration": record["migrationBlock"],
        "lifecycle": record["lifecycle"],
    }


def mine_to(client: RpcClient, target: int) -> int:
    """Mine to `target` in chunks of 200 blocks: Anvil mines about 100 blocks a second, and the client waits 10."""
    head = parse_quantity(client.request("eth_blockNumber"))
    if head > target:
        raise LabError(f"current block {head} is already past target {target}")
    while head < target:
        client.request("anvil_mine", [quantity(min(MINE_CHUNK_BLOCKS, target - head))])
        head = parse_quantity(client.request("eth_blockNumber"))
    return head


def launchpad_of(state: Mapping[str, Any], kind: str) -> str:
    return str(state["addresses"][LAUNCHPAD_KINDS[kind]])


def owned_run(state: Mapping[str, Any]) -> RpcClient:
    """The recorded run must be this controller's own loopback Anvil, still alive, still carrying its graph.

    Chain id 31338 alone identifies nothing: another lab on this machine runs the same id. The
    recorded process must be alive, must be Anvil, and must be the one process listening on the
    recorded loopback port; the chain there must carry the recorded genesis hash and both recorded
    launchpads. Every check fails closed before any mutation or stop touches the endpoint.
    """
    if state.get("status") != "active":
        raise LabError("no active local Robinhood lab; run start")
    pid = int(state["pid"])
    port = loopback_port(str(state["rpc_url"]))
    if not alive(pid):
        raise LabError("no active local Robinhood lab; run start")
    if listening_pid(port) != pid:
        raise LabError(f"recorded process {pid} is not the process listening on loopback port {port}; refusing to touch it")
    if process_name(pid) != "anvil":
        raise LabError(f"recorded process {pid} is not Anvil; refusing to touch it")
    client = RpcClient(f"http://127.0.0.1:{port}")
    client.assert_local()
    if genesis_hash(client) != state["genesis_hash"]:
        raise LabError(f"the chain on loopback port {port} is not this run's Anvil instance; refusing to touch it")
    for label in ("launchpad", "stocks_launchpad"):
        if client.request("eth_getCode", [state["addresses"][label], "latest"]) == "0x":
            raise LabError(f"the chain on loopback port {port} does not carry this run's {label}; refusing to touch it")
    return client


def active_state(root: Path) -> tuple[dict[str, Any], RpcClient]:
    state = load_json(root / STATE_PATH)
    return state, owned_run(state)


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
        if listening_pid(port) != process.pid:
            raise LabError("the started Anvil is not the process listening on its port")
        client = RpcClient(rpc_url)
        genesis = genesis_hash(client)
        accounts = client.request("eth_accounts")
        if not isinstance(accounts, list) or not accounts:
            raise LabError("Anvil did not expose a local deployment account")
        deployer = normalize_address(str(accounts[0]), "local deployer")
        client.request("anvil_setCode", [PERMIT2, runtime])
        graph, pairs = deploy_graph(root, client, deployer)
        for label, address in graph.items():
            if not label.endswith("hook_salt") and label != "admin_safe" and client.request("eth_getCode", [address, "latest"]) == "0x":
                raise LabError(f"deployed {label} has no runtime code")
        stocks = describe_stocks(client, graph, pairs)
        if call_address(client, graph["stocks_hook"], "executor()") != deployer:
            raise LabError("stocks hook executor readback mismatch")
        addresses = {label: value for label, value in graph.items() if not label.endswith("hook_salt")}
        run_id = f"robinhood-lab-{int(time.time())}-{process.pid}"
        atomic_write_json(
            state_path,
            {
                "status": "active",
                "pid": process.pid,
                "rpc_url": rpc_url,
                "chain_id": LOCAL_CHAIN_ID,
                "run_id": run_id,
                "genesis_hash": genesis,
                "deployer": deployer,
                "executor": deployer,
                "hook_salt": graph["hook_salt"],
                "stocks_hook_salt": graph["stocks_hook_salt"],
                "addresses": addresses,
                "stocks": stocks,
            },
        )
        atomic_write_json(
            root / SITE_CONFIG_PATH,
            {
                "rpc_url": rpc_url,
                "chain_id": LOCAL_CHAIN_ID,
                "run_id": run_id,
                "addresses": addresses,
                "stocks": stocks,
                "abis": abis,
            },
        )
    except BaseException:
        terminate(process.pid)
        raise
    print(
        json.dumps(
            {
                "rpc_url": rpc_url,
                "chain_id": LOCAL_CHAIN_ID,
                "site_config": str(root / SITE_CONFIG_PATH),
                "addresses": addresses,
                "stocks": [entry["symbol"] for entry in stocks],
            },
            indent=2,
            sort_keys=True,
        )
    )


def command_fund(args: argparse.Namespace) -> None:
    root = component_root()
    state, client = active_state(root)
    # Every input is resolved before the first mutation, so a refused input funds nothing.
    wallet = normalize_address(args.wallet, "wallet")
    usdg = state["addresses"]["usdg"]
    amount = parse_units(args.usdg, USDG_DECIMALS)
    stock = (stock_entry(state, args.stock), parse_units(args.shares, STOCK_DECIMALS)) if args.stock else None
    client.request("anvil_setBalance", [wallet, quantity(10**20)])
    send_and_wait(client, state["deployer"], usdg, keccak_selector("mint(address,uint256)") + abi_address(wallet) + abi_uint(amount))
    response: dict[str, Any] = {"wallet": wallet, "usdg_balance": str(balance_of(client, usdg, wallet)), "eth_wei": str(10**20)}
    if stock:
        entry, shares = stock
        send_and_wait(client, state["deployer"], entry["address"], keccak_selector("mint(address,uint256)") + abi_address(wallet) + abi_uint(shares))
        response["stock"] = {"symbol": entry["symbol"], "address": entry["address"], "balance": str(balance_of(client, entry["address"], wallet))}
    print(json.dumps(response, indent=2, sort_keys=True))


def launchpad_status(client: RpcClient, launchpad: str) -> dict[str, Any]:
    return {
        "launches_paused": bool(call_uint(client, launchpad, "launchesPaused()")),
        "launch_fee_usdg_atomic": str(call_uint(client, launchpad, "launchFee()")),
        "minimum_raise_usdg_atomic": str(call_uint(client, launchpad, "minimumRaiseUsdg()")),
        "next_launch_id": str(call_uint(client, launchpad, "nextLaunchId()")),
    }


def command_status(args: argparse.Namespace) -> None:
    root = component_root()
    state, client = active_state(root)
    usdg = state["addresses"]["usdg"]
    stocks_launchpad = state["addresses"]["stocks_launchpad"]
    stocks = []
    for entry in state["stocks"]:
        admitted, _decimals, _route = words(eth_call(client, stocks_launchpad, "stockAdmission(address)", abi_address(entry["address"])))
        stocks.append(
            {
                **entry,
                "admitted": admitted == 1,
                "route_stock_units": str(balance_of(client, entry["address"], entry["route"])),
                "route_usdg_units": str(balance_of(client, usdg, entry["route"])),
            }
        )
    response: dict[str, Any] = {
        "rpc_url": state["rpc_url"],
        "chain_id": LOCAL_CHAIN_ID,
        "block_number": parse_quantity(client.request("eth_blockNumber")),
        "revshare": launchpad_status(client, state["addresses"]["launchpad"]),
        "stocks_launchpad": {
            **launchpad_status(client, stocks_launchpad),
            "executor": call_address(client, state["addresses"]["stocks_hook"], "executor()"),
        },
        "stocks": stocks,
        "addresses": state["addresses"],
    }
    if args.launch:
        response["launch"] = launch_record(client, launchpad_of(state, args.kind), args.launch)
    if args.auction:
        response["auction"] = auction_timing(client, launchpad_of(state, args.kind), args.auction)
    print(json.dumps(response, indent=2, sort_keys=True))


def command_advance(args: argparse.Namespace) -> None:
    root = component_root()
    state, client = active_state(root)
    timing = auction_timing(client, launchpad_of(state, args.kind), args.auction)
    block_number = mine_to(client, int(timing[args.to]))
    print(json.dumps({"block_number": block_number, "target": args.to, "timing": timing}, indent=2, sort_keys=True))


def command_migrate(args: argparse.Namespace) -> None:
    root = component_root()
    state, client = active_state(root)
    launchpad = launchpad_of(state, args.kind)
    before = launch_record(client, launchpad, args.launch)
    transaction_hash = send_and_wait(client, state["deployer"], launchpad, keccak_selector("migrate(uint256)") + abi_uint(args.launch))
    after = launch_record(client, launchpad, args.launch)
    print(
        json.dumps(
            {"launch": args.launch, "transaction_hash": transaction_hash, "before": before["lifecycle"], "after": after["lifecycle"], "record": after},
            indent=2,
            sort_keys=True,
        )
    )


def command_stop(_args: argparse.Namespace) -> None:
    root = component_root()
    state = load_json(root / STATE_PATH)
    if state.get("status") == "active" and alive(int(state["pid"])):
        owned_run(state)
        terminate(int(state["pid"]))
    atomic_write_json(root / STATE_PATH, {**state, "status": "stopped"})
    with contextlib.suppress(FileNotFoundError):
        (root / SITE_CONFIG_PATH).unlink()
    print(json.dumps({"status": "stopped"}))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("start", help="boot Anvil on chain 31338 and deploy the Revshare and Stocks graphs").set_defaults(run=command_start)
    fund = commands.add_parser("fund", help="give a wallet 100 test ETH, minted USDG and optionally fixture STOCK")
    fund.add_argument("wallet")
    fund.add_argument("--usdg", default="100000", help="whole USDG to mint (default 100000)")
    fund.add_argument("--stock", help="catalog symbol of a fixture stock to mint as well")
    fund.add_argument("--shares", default="1000", help="whole shares of --stock to mint (default 1000)")
    fund.set_defaults(run=command_fund)
    status = commands.add_parser("status", help="report both launchpads and every admitted stock")
    status.add_argument("--kind", choices=sorted(LAUNCHPAD_KINDS), default="stocks", help="launchpad --launch and --auction refer to")
    status.add_argument("--launch", type=int, help="also print this launch id's record")
    status.add_argument("--auction", help="also print this auction's block timing")
    status.set_defaults(run=command_status)
    advance = commands.add_parser("advance", help="mine to an auction's start, end, claim or migration block")
    advance.add_argument("auction")
    advance.add_argument("--kind", choices=sorted(LAUNCHPAD_KINDS), default="stocks", help="launchpad that created the auction")
    advance.add_argument("--to", choices=("start", "end", "claim", "migration"), required=True)
    advance.set_defaults(run=command_advance)
    migrate = commands.add_parser("migrate", help="call migrate(launchId) from the deployer")
    migrate.add_argument("launch", type=int)
    migrate.add_argument("--kind", choices=sorted(LAUNCHPAD_KINDS), default="stocks", help="launchpad that owns the launch")
    migrate.set_defaults(run=command_migrate)
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
