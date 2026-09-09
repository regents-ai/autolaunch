#!/usr/bin/env python3
"""Extend a running Agent local Base-fork lab with the Autolaunch Stocks graph.

Modelled on `contracts/v1/bin/local-base-lab.py`. It reads that controller's run record to find the
loopback Anvil node and the deployed Agent graph, installs the fixture stock tokens at the catalog
addresses, deploys the Stocks graph as an impersonated deployer, admits every fixture route from the
impersonated Governance Safe, funds the routes, sets the Agent factory's launch fee to the lab's
500,000 REGENT from the same impersonated Safe, and writes `stocks-site-config.json` next to the
Agent lab's `site-config.json`. It never writes the Agent run record and never mutates anything but
the local chain and its own two generated documents.

LAB ONLY. Nothing here is B20-verified: the catalog addresses carry `0xef` code on Base and on the
fork, and the fixture replaces that code.
"""

from __future__ import annotations

import argparse
import contextlib
import decimal
import functools
import ipaddress
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Mapping, Sequence

if sys.version_info < (3, 12):
    raise SystemExit("Python 3.12+ is required")

USER_AGENT = "autolaunch-local-stocks-lab/1"
LOCAL_CHAIN_ID = 31_337

USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
REGENT = "0x6f89bca4ea5931edfcb09786267b251dee752b07"
PERMIT2 = "0x000000000022d473030f116ddee9f6b43ac78ba3"
CCA_FACTORY = "0x000000001f26a0044baa66024e7b6599c61963f8"
POOL_MANAGER = "0x498581ff718922c3f8e6a244956af099b2652b2b"
POSITION_MANAGER = "0x7c5f5a4bbd8fd63184577525326123b519429bdc"
LIVE_STAKING = "0xb027dc261636e30cbc0fe25b2f8e1ed273354ab5"
GOVERNANCE_SAFE = "0x9fa152b0eadbfe9a7c5c0a8e1d11784f22669a3e"

# A dedicated impersonated lab deployer: no key exists, Anvil signs for it.
STOCKS_LAB_DEPLOYER = "0x5700000000000000000000000000000000000001"
# Founder decision for the lab: the frozen Agent factory's launch fee is set to 500,000 REGENT from the
# impersonated Governance Safe. The Stocks launchpad is born at its own preset fee (100,000 REGENT).
AGENT_LAUNCH_FEE_REGENT = 500_000
# One faucet grant that covers either launch fee.
FAUCET_LAUNCH_FEE_REGENT = 500_000 * 10**18
# Morpho Blue on Base holds a large forked USDC balance; overridable with --usdc-holder.
DEFAULT_USDC_HOLDER = "0xbbbbbbbbbb9cc5e90e3b3af64bdaf62c37eeffcb"

STOCK_DECIMALS = 8
# Mirrors src/fixtures/FixtureStockCatalog.sol; `deploy` cross-checks every symbol against the
# installed fixture so the two cannot drift silently.
CATALOG: tuple[tuple[str, str], ...] = (
    ("AAPLc", "0xb200000000000000000000c2e324d24d7eecd1fb"),
    ("AMZNc", "0xb200000000000000000000d9192b6b456483c2e8"),
    ("COINc", "0xb200000000000000000000c85a31389d71f3ecfb"),
    ("CRCLc", "0xb20000000000000000000019f6e7c675b73c2e4d"),
    ("GOOGLc", "0xb2000000000000000000002d0ba3164cc74f58b7"),
    ("INTCc", "0xb2000000000000000000004aff16039ba04bdfbc"),
    ("METAc", "0xb2000000000000000000008bc8786b856e61707c"),
    ("MSFTc", "0xb200000000000000000000ab99cfa739e253872b"),
    ("MSTRc", "0xb2000000000000000000004884b426556b92883d"),
    ("NVDAc", "0xb20000000000000000000078ee7ce2fe4908108c"),
    ("SNDKc", "0xb200000000000000000000397293cb8cda9a10c5"),
    ("SPCXc", "0xb2000000000000000000007b9fcbd005511acbd5"),
    ("TSLAc", "0xb2000000000000000000001e800a7f5189430cd0"),
)

AGENT_STATE_NAME = "state.json"
AGENT_SITE_CONFIG_NAME = "site-config.json"
STOCKS_STATE_NAME = "stocks-state.json"
STOCKS_SITE_CONFIG_NAME = "stocks-site-config.json"

DOTENV_NAMES = (".env", ".env.local", ".envrc")
ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
GRAPH_LOG_RE = re.compile(r"REGENT_STOCKS_LAB_([A-Z0-9_]+)\s*:?\s*(0x[0-9a-fA-F]+)")
FIXED_GRAPH_LABELS = {"hook_salt", "launchpad", "hook", "bid_adapter"}

ABI_ARTIFACTS = {
    "launchpad": "out/StocksLaunchpadV1.sol/StocksLaunchpadV1.json",
    "hook": "out/StocksFeeHookV1.sol/StocksFeeHookV1.json",
    "bid_adapter": "out/StockBidAdapterV1.sol/StockBidAdapterV1.json",
    "route": "out/FixtureStockRoute.sol/FixtureStockRoute.json",
    "auction": "out/ContinuousClearingAuction.sol/ContinuousClearingAuction.json",
    "erc20": "out/IERC20Standard.sol/IERC20Standard.json",
    "permit2": "out/IAllowanceTransfer.sol/IAllowanceTransfer.json",
}
FIXTURE_ARTIFACT = "out/FixtureStockToken.sol/FixtureStockToken.json"
DEPLOY_SCRIPT = "script/DeployStocksLab.s.sol:DeployStocksLab"


class LabError(RuntimeError):
    """An expected local-lab failure."""


class RpcError(LabError):
    def __init__(self, method: str, message: str, data: Any):
        super().__init__(f"local RPC {method} failed: {message}")
        self.data = data


# -----------------------------------------------------------------------------
# paths and documents
# -----------------------------------------------------------------------------


def component_root() -> Path:
    return Path(__file__).resolve().parents[1]


def default_agent_lab_dir() -> Path:
    return component_root().parents[1] / "contracts" / "v1" / "reports" / "generated" / "local-base-lab"


def require_no_dotenv(root: Path) -> None:
    for name in DOTENV_NAMES:
        if (root / name).exists():
            raise LabError(f"{name} exists in {root}; the lab never reads one and refuses to run beside one")


def load_json(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text())
    except (FileNotFoundError, OSError, json.JSONDecodeError) as exc:
        raise LabError(f"document is unavailable or invalid: {path}") from exc
    if not isinstance(document, dict):
        raise LabError(f"document is not an object: {path}")
    return document


def atomic_write_json(path: Path, document: Mapping[str, Any]) -> None:
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
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()


def normalize_address(value: str, label: str = "address") -> str:
    if not isinstance(value, str) or not ADDRESS_RE.fullmatch(value):
        raise LabError(f"{label} must be a 20-byte hex address")
    return value.lower()


def validate_loopback_rpc_url(value: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme != "http" or not parsed.hostname or parsed.username or parsed.password:
        raise LabError("local RPC must be an unauthenticated HTTP loopback URL")
    try:
        address = ipaddress.ip_address(parsed.hostname)
    except ValueError as exc:
        raise LabError("local RPC host must be a literal loopback address") from exc
    if not address.is_loopback or parsed.port is None or parsed.query or parsed.fragment:
        raise LabError("local RPC URL must be loopback with a port and no query or fragment")
    return value


def parse_quantity(value: Any) -> int:
    if isinstance(value, bool):
        raise LabError("RPC quantity must be an integer")
    if isinstance(value, int):
        return value
    try:
        return int(value, 16)
    except (TypeError, ValueError) as exc:
        raise LabError("RPC returned an invalid quantity") from exc


def quantity(value: int) -> str:
    if value < 0:
        raise LabError("quantity cannot be negative")
    return hex(value)


def parse_token_amount(value: str, decimals: int) -> int:
    try:
        amount = decimal.Decimal(value)
    except decimal.InvalidOperation as exc:
        raise LabError("amount must be a decimal number") from exc
    units = amount * decimal.Decimal(10**decimals)
    if amount <= 0 or units != units.to_integral_value() or units >= 1 << 256:
        raise LabError(f"amount must be positive with at most {decimals} decimals")
    return int(units)


# -----------------------------------------------------------------------------
# RPC
# -----------------------------------------------------------------------------


class RpcClient:
    def __init__(self, url: str, timeout: float = 30.0):
        self.url = validate_loopback_rpc_url(url)
        self.timeout = timeout
        self._request_id = 0

    def _request(self, method: str, params: Sequence[Any] = ()) -> Any:
        self._request_id += 1
        payload = json.dumps({"jsonrpc": "2.0", "id": self._request_id, "method": method, "params": list(params)})
        request = urllib.request.Request(
            self.url, data=payload.encode(), headers={"Content-Type": "application/json", "User-Agent": USER_AGENT}
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                document = json.load(response)
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
            raise LabError(f"local RPC request failed for {method}") from exc
        if "error" in document:
            error = document["error"]
            raise RpcError(method, error.get("message", "unknown RPC error"), error.get("data"))
        if "result" not in document:
            raise LabError(f"local RPC omitted the result for {method}")
        return document["result"]

    def read(self, method: str, params: Sequence[Any] = ()) -> Any:
        return self._request(method, params)

    def assert_local(self) -> None:
        found = parse_quantity(self._request("eth_chainId"))
        if found != LOCAL_CHAIN_ID:
            raise LabError(f"refusing mutation: expected local chain {LOCAL_CHAIN_ID}, found {found}")

    def mutate(self, method: str, params: Sequence[Any] = ()) -> Any:
        self.assert_local()
        return self._request(method, params)


def rpc_call(client: RpcClient, target: str, data: str, sender: str | None = None) -> str:
    call: dict[str, str] = {"to": normalize_address(target), "data": data}
    if sender is not None:
        call["from"] = normalize_address(sender)
    result = client.read("eth_call", [call, "latest"])
    if not isinstance(result, str) or not result.startswith("0x"):
        raise LabError("eth_call returned invalid data")
    return result


def runtime_code(client: RpcClient, target: str) -> str:
    result = client.read("eth_getCode", [normalize_address(target), "latest"])
    if not isinstance(result, str) or not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", result):
        raise LabError("eth_getCode returned invalid runtime code")
    return result.lower()


def wait_receipt(client: RpcClient, transaction_hash: str, timeout: float = 60) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        receipt = client.read("eth_getTransactionReceipt", [transaction_hash])
        if receipt is not None:
            if parse_quantity(receipt.get("status", "0x0")) != 1:
                raise LabError(f"local transaction reverted: {transaction_hash}")
            return dict(receipt)
        time.sleep(0.1)
    raise LabError("local transaction receipt timed out")


def send_and_wait(client: RpcClient, sender: str, target: str, data: str) -> str:
    transaction_hash = client.mutate(
        "eth_sendTransaction",
        [{"from": normalize_address(sender), "to": normalize_address(target), "data": data, "gas": quantity(15_000_000), "value": "0x0"}],
    )
    if not isinstance(transaction_hash, str):
        raise LabError("local transaction did not return a hash")
    wait_receipt(client, transaction_hash)
    return transaction_hash


@contextlib.contextmanager
def impersonated(client: RpcClient, account: str, gas_wei: int = 10**18):
    account = normalize_address(account)
    if parse_quantity(client.read("eth_getBalance", [account, "latest"])) < gas_wei:
        client.mutate("anvil_setBalance", [account, quantity(gas_wei)])
    client.mutate("anvil_impersonateAccount", [account])
    try:
        yield
    finally:
        client.mutate("anvil_stopImpersonatingAccount", [account])


# -----------------------------------------------------------------------------
# ABI helpers (selectors come from `cast sig`; the standard library has no keccak)
# -----------------------------------------------------------------------------


def run_checked(arguments: Sequence[str], cwd: Path, environment: Mapping[str, str] | None = None) -> str:
    completed = subprocess.run(
        list(arguments), cwd=cwd, env=dict(environment) if environment else None, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
    )
    if completed.returncode:
        raise LabError(f"command failed: {' '.join(arguments[:3])}\n{completed.stdout[-4000:]}")
    return completed.stdout


@functools.cache
def selector(signature: str) -> str:
    digest = run_checked(["cast", "sig", signature], component_root()).strip()
    if not re.fullmatch(r"0x[0-9a-fA-F]{8}", digest):
        raise LabError(f"cast sig returned an invalid selector for {signature}")
    return digest.lower()


def abi_address(value: str) -> str:
    return normalize_address(value)[2:].rjust(64, "0")


def abi_uint(value: int) -> str:
    if value < 0 or value >= 1 << 256:
        raise LabError("integer is outside uint256")
    return f"{value:064x}"


def abi_bytes32(value: str) -> str:
    if not re.fullmatch(r"0x[0-9a-fA-F]{64}", value):
        raise LabError("bytes32 must be 32 bytes of hex")
    return value[2:].lower()


def words(data: str) -> list[int]:
    raw = bytes.fromhex(data.removeprefix("0x"))
    if len(raw) % 32:
        raise LabError("readback is not word aligned")
    return [int.from_bytes(raw[i : i + 32], "big") for i in range(0, len(raw), 32)]


def decode_uint(data: str) -> int:
    values = words(data)
    if len(values) != 1:
        raise LabError("readback has the wrong ABI length")
    return values[0]


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
    return decode_uint(rpc_call(client, target, selector(signature) + "".join(args)))


def call_address(client: RpcClient, target: str, signature: str, *args: str) -> str:
    return decode_address_word(call_uint(client, target, signature, *args))


def balance_of(client: RpcClient, token: str, account: str) -> int:
    return call_uint(client, token, "balanceOf(address)", abi_address(account))


# -----------------------------------------------------------------------------
# forge
# -----------------------------------------------------------------------------


def forge_environment(extra: Mapping[str, str] | None = None) -> dict[str, str]:
    environment = dict(os.environ)
    environment.pop("REGENT_BASE_RPC_URL", None)
    environment.update({"FOUNDRY_PROFILE": "default", "FOUNDRY_OFFLINE": "true", "RUST_LOG": "error"})
    if extra:
        environment.update(extra)
    return environment


def forge_build(root: Path) -> None:
    run_checked(["forge", "build", "--offline"], root, forge_environment())


def load_artifact(root: Path, relative: str) -> dict[str, Any]:
    return load_json(root / relative)


def fixture_runtime(root: Path) -> str:
    artifact = load_artifact(root, FIXTURE_ARTIFACT)
    deployed = artifact.get("deployedBytecode", {})
    code = deployed.get("object")
    if not isinstance(code, str) or not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})+", code):
        raise LabError("fixture runtime bytecode is invalid")
    if deployed.get("immutableReferences"):
        raise LabError("fixture runtime has immutables; it must be address-independent")
    return code.lower()


def load_abis(root: Path) -> dict[str, Any]:
    abis: dict[str, Any] = {}
    for label, relative in ABI_ARTIFACTS.items():
        abi = load_artifact(root, relative).get("abi")
        if not isinstance(abi, list) or not abi:
            raise LabError(f"artifact has no ABI: {relative}")
        abis[label] = abi
    return abis


def parse_deployment_graph(output: str) -> dict[str, str]:
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
    expected = FIXED_GRAPH_LABELS | {f"route_{symbol.lower()}" for symbol, _ in CATALOG}
    if set(graph) != expected:
        raise LabError(f"deployment did not report the complete graph; missing {sorted(expected - set(graph))}")
    return graph


def deploy_graph(root: Path, client: RpcClient, deployer: str, uerc20_factory: str, agent_strategy: str) -> dict[str, str]:
    output = run_checked(
        [
            "forge", "script", DEPLOY_SCRIPT, "--rpc-url", client.url, "--broadcast", "--unlocked",
            "--sender", deployer, "--slow", "-vv",
        ],
        root,
        forge_environment(
            {
                "REGENT_STOCKS_LAB_DEPLOYER": deployer,
                "REGENT_STOCKS_LAB_UERC20_FACTORY": uerc20_factory,
                "REGENT_STOCKS_LAB_AGENT_STRATEGY": agent_strategy,
            }
        ),
    )
    return parse_deployment_graph(output)


# -----------------------------------------------------------------------------
# lab context
# -----------------------------------------------------------------------------


class Lab:
    def __init__(self, agent_lab_dir: Path, rpc_override: str | None):
        self.agent_lab_dir = agent_lab_dir.resolve()
        self.agent_state = load_json(self.agent_lab_dir / AGENT_STATE_NAME)
        if self.agent_state.get("status") != "active":
            raise LabError("the Agent lab run record is not active; start contracts/v1/bin/local-base-lab.py first")
        self.agent_config = load_json(self.agent_lab_dir / AGENT_SITE_CONFIG_NAME)
        rpc_url = rpc_override or str(self.agent_state.get("rpc_url", ""))
        self.client = RpcClient(rpc_url)
        self.client.assert_local()
        addresses = self.agent_config.get("addresses", {})
        try:
            self.uerc20_factory = normalize_address(addresses["uerc20_factory"], "uerc20_factory")
            self.agent_strategy = normalize_address(addresses["strategy"], "strategy")
            self.agent_factory = normalize_address(addresses["factory"], "factory")
        except KeyError as exc:
            raise LabError("Agent site-config.json omits required addresses") from exc

    @property
    def state_path(self) -> Path:
        return self.agent_lab_dir / STOCKS_STATE_NAME

    @property
    def config_path(self) -> Path:
        return self.agent_lab_dir / STOCKS_SITE_CONFIG_NAME

    def load_state(self) -> dict[str, Any]:
        state = load_json(self.state_path)
        if state.get("rpc_url") != self.client.url:
            raise LabError("stocks-state.json belongs to a different local RPC; run deploy again")
        return state


# -----------------------------------------------------------------------------
# deploy
# -----------------------------------------------------------------------------


def install_fixtures(lab: Lab, runtime: str) -> None:
    for symbol, address in CATALOG:
        lab.client.mutate("anvil_setCode", [address, runtime])
        if runtime_code(lab.client, address) != runtime:
            raise LabError(f"Anvil did not install the fixture at {symbol} {address}")
        found = decode_string(rpc_call(lab.client, address, selector("symbol()")))
        if found != symbol:
            raise LabError(f"fixture at {address} reports {found!r}, catalog says {symbol!r}; update one of them")
        if call_uint(lab.client, address, "decimals()") != STOCK_DECIMALS:
            raise LabError(f"fixture at {address} does not report {STOCK_DECIMALS} decimals")


def admit_routes(lab: Lab, graph: Mapping[str, str]) -> None:
    launchpad = graph["launchpad"]
    with impersonated(lab.client, GOVERNANCE_SAFE):
        for symbol, stock in CATALOG:
            route = graph[f"route_{symbol.lower()}"]
            send_and_wait(lab.client, GOVERNANCE_SAFE, launchpad, selector("admitStock(address,address)") + abi_address(stock) + abi_address(route))
            admitted, decimals, recorded = words(rpc_call(lab.client, launchpad, selector("stockAdmission(address)") + abi_address(stock)))
            if admitted != 1 or decimals != STOCK_DECIMALS or decode_address_word(recorded) != route:
                raise LabError(f"admission readback mismatch for {symbol}")
        send_and_wait(lab.client, GOVERNANCE_SAFE, graph["hook"], selector("setExecutor(address)") + abi_address(STOCKS_LAB_DEPLOYER))
        if call_address(lab.client, graph["hook"], "executor()") != STOCKS_LAB_DEPLOYER:
            raise LabError("hook executor readback mismatch")
        if call_uint(lab.client, launchpad, "launchesPaused()") == 1:
            send_and_wait(lab.client, GOVERNANCE_SAFE, launchpad, selector("unpauseLaunches()"))
        if call_uint(lab.client, launchpad, "launchesPaused()") != 0:
            raise LabError("launchpad remained paused")


def set_agent_launch_fee(lab: Lab, amount_regent: int) -> int:
    """Set the frozen Agent factory's launch fee from the impersonated Governance Safe when it differs.

    Returns the fee the factory reports afterwards, in REGENT base units. The Agent sources and the
    Agent run record are untouched: this is one governance call on the fork the Safe could make on Base.
    """
    target = amount_regent * 10**18
    current = call_uint(lab.client, lab.agent_factory, "launchFee()")
    if current != target:
        with impersonated(lab.client, GOVERNANCE_SAFE):
            send_and_wait(lab.client, GOVERNANCE_SAFE, lab.agent_factory, selector("setLaunchFee(uint256)") + abi_uint(target))
    found = call_uint(lab.client, lab.agent_factory, "launchFee()")
    if found != target:
        raise LabError(f"Agent factory launchFee readback is {found}, expected {target}")
    return found


def fund_routes(lab: Lab, graph: Mapping[str, str], usdc_holder: str, route_stock: int, route_usdc: int) -> None:
    with impersonated(lab.client, STOCKS_LAB_DEPLOYER), impersonated(lab.client, usdc_holder):
        for symbol, stock in CATALOG:
            route = graph[f"route_{symbol.lower()}"]
            stock_before = balance_of(lab.client, stock, route)
            send_and_wait(lab.client, STOCKS_LAB_DEPLOYER, stock, selector("mint(address,uint256)") + abi_address(route) + abi_uint(route_stock))
            if balance_of(lab.client, stock, route) != stock_before + route_stock:
                raise LabError(f"route {symbol} did not receive the minted STOCK")
            usdc_before = balance_of(lab.client, USDC, route)
            send_and_wait(lab.client, usdc_holder, USDC, selector("transfer(address,uint256)") + abi_address(route) + abi_uint(route_usdc))
            if balance_of(lab.client, USDC, route) != usdc_before + route_usdc:
                raise LabError(f"route {symbol} did not receive USDC")


def write_documents(
    lab: Lab,
    graph: Mapping[str, str],
    abis: Mapping[str, Any],
    usdc_holder: str,
    faucet: Mapping[str, str],
    stocks_launch_fee: int,
    agent_launch_fee: int,
) -> None:
    addresses = {
        "launchpad": graph["launchpad"],
        "hook": graph["hook"],
        "bid_adapter": graph["bid_adapter"],
        "usdc": USDC,
        "regent": REGENT,
        "permit2": PERMIT2,
        "cca_factory": CCA_FACTORY,
        "pool_manager": POOL_MANAGER,
        "position_manager": POSITION_MANAGER,
        "live_staking": LIVE_STAKING,
        "governance_safe": GOVERNANCE_SAFE,
        "agent_factory": lab.agent_factory,
        "agent_strategy": lab.agent_strategy,
    }
    stocks = [
        {
            "symbol": symbol,
            "address": stock,
            "decimals": STOCK_DECIMALS,
            "route": graph[f"route_{symbol.lower()}"],
            "fixture": True,
            "launch_admission": "fixture_admitted",
        }
        for symbol, stock in CATALOG
    ]
    atomic_write_json(
        lab.state_path,
        {
            "status": "active",
            "rpc_url": lab.client.url,
            "chain_id": LOCAL_CHAIN_ID,
            "agent_lab_config": str(lab.agent_lab_dir / AGENT_SITE_CONFIG_NAME),
            "deployer": STOCKS_LAB_DEPLOYER,
            "executor": STOCKS_LAB_DEPLOYER,
            "usdc_holder": usdc_holder,
            "hook_salt": graph["hook_salt"],
            "addresses": addresses,
            "stocks": stocks,
            "block_number_at_deploy": parse_quantity(lab.client.read("eth_blockNumber")),
        },
    )
    atomic_write_json(
        lab.config_path,
        {
            "rpc_url": lab.client.url,
            "chain_id": LOCAL_CHAIN_ID,
            "agent_lab_config": str(lab.agent_lab_dir / AGENT_SITE_CONFIG_NAME),
            "addresses": addresses,
            "stocks_launch_fee_regent": str(stocks_launch_fee),
            "agent_launch_fee_regent": str(agent_launch_fee),
            "faucet": dict(faucet),
            "stocks": stocks,
            "abis": dict(abis),
        },
    )


def command_deploy(args: argparse.Namespace) -> None:
    root = component_root()
    lab = Lab(Path(args.agent_lab_dir), args.rpc_url)
    if lab.state_path.exists() and not args.force:
        raise LabError(f"{lab.state_path} exists; pass --force to deploy a fresh graph beside it")
    usdc_holder = normalize_address(args.usdc_holder, "USDC holder")
    route_stock = parse_token_amount(args.route_stock, STOCK_DECIMALS)
    route_usdc = parse_token_amount(args.route_usdc, 6)
    if balance_of(lab.client, USDC, usdc_holder) < route_usdc * len(CATALOG):
        raise LabError("the USDC holder cannot fund every route; choose another with --usdc-holder")

    forge_build(root)
    snapshot_id = lab.client.mutate("evm_snapshot")
    try:
        install_fixtures(lab, fixture_runtime(root))
        with impersonated(lab.client, STOCKS_LAB_DEPLOYER, gas_wei=10**20):
            graph = deploy_graph(root, lab.client, STOCKS_LAB_DEPLOYER, lab.uerc20_factory, lab.agent_strategy)
        for label, address in graph.items():
            if label != "hook_salt" and runtime_code(lab.client, address) == "0x":
                raise LabError(f"deployed {label} has no runtime code")
        admit_routes(lab, graph)
        fund_routes(lab, graph, usdc_holder, route_stock, route_usdc)
        agent_launch_fee = set_agent_launch_fee(lab, AGENT_LAUNCH_FEE_REGENT)
        stocks_launch_fee = call_uint(lab.client, graph["launchpad"], "launchFee()")
    except BaseException as exc:
        # A half-installed graph is worse than none: roll the chain back to before the fixtures.
        with contextlib.suppress(LabError):
            lab.client.mutate("evm_revert", [snapshot_id])
        raise LabError(f"deploy failed and the chain was rolled back: {exc}") from exc
    faucet = {
        "regent_holder": GOVERNANCE_SAFE,
        "regent_amount": str(1_000 * 10**18),
        "regent_launch_fee_amount": str(FAUCET_LAUNCH_FEE_REGENT),
        "stock_amount_units": "100",
        "usdc_holder": usdc_holder,
        "usdc_amount": str(1_000 * 10**6),
    }
    write_documents(lab, graph, load_abis(root), usdc_holder, faucet, stocks_launch_fee, agent_launch_fee)
    print(
        json.dumps(
            {
                "rpc_url": lab.client.url,
                "stocks_site_config": str(lab.config_path),
                "addresses": {k: v for k, v in graph.items() if k != "hook_salt"},
                "stocks_launch_fee_regent": str(stocks_launch_fee),
                "agent_launch_fee_regent": str(agent_launch_fee),
            },
            indent=2,
            sort_keys=True,
        )
    )


def command_set_agent_fee(args: argparse.Namespace) -> None:
    lab = Lab(Path(args.agent_lab_dir), args.rpc_url)
    amount_regent = int(args.amount)
    if amount_regent < 0:
        raise LabError("--amount must be a whole, non-negative number of REGENT")
    before = call_uint(lab.client, lab.agent_factory, "launchFee()")
    after = set_agent_launch_fee(lab, amount_regent)
    if lab.config_path.exists():
        config = load_json(lab.config_path)
        config["agent_launch_fee_regent"] = str(after)
        atomic_write_json(lab.config_path, config)
    print(json.dumps({"agent_factory": lab.agent_factory, "launch_fee_before": str(before), "launch_fee_after": str(after)}, sort_keys=True))


# -----------------------------------------------------------------------------
# fund, status, advance, migrate, settle
# -----------------------------------------------------------------------------


def stock_by_symbol(symbol: str) -> str:
    for candidate, address in CATALOG:
        if candidate.lower() == symbol.lower():
            return address
    raise LabError(f"unknown stock symbol {symbol}; catalog: {', '.join(s for s, _ in CATALOG)}")


def command_fund(args: argparse.Namespace) -> None:
    lab = Lab(Path(args.agent_lab_dir), args.rpc_url)
    state = lab.load_state()
    wallet = normalize_address(args.wallet, "wallet")
    result: dict[str, Any] = {"wallet": wallet}
    wallet_gas = parse_token_amount(args.wallet_eth, 18)
    if parse_quantity(lab.client.read("eth_getBalance", [wallet, "latest"])) < wallet_gas:
        lab.client.mutate("anvil_setBalance", [wallet, quantity(wallet_gas)])
    if args.regent:
        amount = parse_token_amount(args.regent, 18)
        safe_balance = balance_of(lab.client, REGENT, GOVERNANCE_SAFE)
        if safe_balance < amount:
            raise LabError(f"the Governance Safe holds {safe_balance} REGENT base units, fewer than the {amount} requested")
        before = balance_of(lab.client, REGENT, wallet)
        with impersonated(lab.client, GOVERNANCE_SAFE):
            result["regent_tx"] = send_and_wait(lab.client, GOVERNANCE_SAFE, REGENT, selector("transfer(address,uint256)") + abi_address(wallet) + abi_uint(amount))
        if balance_of(lab.client, REGENT, wallet) != before + amount:
            raise LabError("wallet REGENT balance did not increase by the requested amount")
        result["regent_wei"] = amount
    if args.stock:
        if not args.amount:
            raise LabError("--stock requires --amount")
        stock = stock_by_symbol(args.stock)
        amount = parse_token_amount(args.amount, STOCK_DECIMALS)
        before = balance_of(lab.client, stock, wallet)
        with impersonated(lab.client, STOCKS_LAB_DEPLOYER):
            result["stock_tx"] = send_and_wait(lab.client, STOCKS_LAB_DEPLOYER, stock, selector("mint(address,uint256)") + abi_address(wallet) + abi_uint(amount))
        if balance_of(lab.client, stock, wallet) != before + amount:
            raise LabError("wallet STOCK balance did not increase by the requested amount")
        result["stock"] = {"symbol": args.stock, "address": stock, "units": amount}
    if args.usdc:
        amount = parse_token_amount(args.usdc, 6)
        holder = normalize_address(state["usdc_holder"], "USDC holder")
        before = balance_of(lab.client, USDC, wallet)
        with impersonated(lab.client, holder):
            result["usdc_tx"] = send_and_wait(lab.client, holder, USDC, selector("transfer(address,uint256)") + abi_address(wallet) + abi_uint(amount))
        if balance_of(lab.client, USDC, wallet) != before + amount:
            raise LabError("wallet USDC balance did not increase by the requested amount")
        result["usdc_units"] = amount
    print(json.dumps(result, sort_keys=True))


LAUNCH_FIELDS = (
    "launcher", "newToken", "stock", "auction", "feeAdministrator", "startBlock", "endBlock", "claimBlock",
    "migrationBlock", "requiredStockRaised", "floorPriceQ96", "lifecycle", "poolId", "finalSqrtPriceX96",
    "lpTokenId", "lpStockUsed", "lpNewUsed", "retiredNew", "lpStockOnlyTokenId", "lpStockOnlyUsed",
)
LIFECYCLES = ("None", "Active", "Graduated", "Failed")


def launch_record(client: RpcClient, launchpad: str, launch_id: int) -> dict[str, Any]:
    values = words(rpc_call(client, launchpad, selector("launches(uint256)") + abi_uint(launch_id)))
    if len(values) != len(LAUNCH_FIELDS):
        raise LabError("launches(uint256) returned the wrong ABI length")
    record: dict[str, Any] = {}
    for name, value in zip(LAUNCH_FIELDS, values):
        if name in {"launcher", "newToken", "stock", "auction", "feeAdministrator"}:
            record[name] = decode_address_word(value)
        elif name == "lifecycle":
            record[name] = LIFECYCLES[value] if value < len(LIFECYCLES) else value
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
        raise LabError("that auction was not created by the Stocks launchpad")
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


def command_status(args: argparse.Namespace) -> None:
    lab = Lab(Path(args.agent_lab_dir), args.rpc_url)
    state = lab.load_state()
    launchpad = state["addresses"]["launchpad"]
    hook = state["addresses"]["hook"]
    stocks = []
    for entry in state["stocks"]:
        admitted, decimals, route = words(rpc_call(lab.client, launchpad, selector("stockAdmission(address)") + abi_address(entry["address"])))
        stocks.append(
            {
                **entry,
                "admitted": admitted == 1,
                "route_stock_units": balance_of(lab.client, entry["address"], entry["route"]),
                "route_usdc_units": balance_of(lab.client, USDC, entry["route"]),
            }
        )
    response: dict[str, Any] = {
        "status": "active",
        "rpc_url": lab.client.url,
        "chain_id": LOCAL_CHAIN_ID,
        "block": parse_quantity(lab.client.read("eth_blockNumber")),
        "stocks_site_config": str(lab.config_path),
        "addresses": state["addresses"],
        "launches_paused": call_uint(lab.client, launchpad, "launchesPaused()") == 1,
        "next_launch_id": call_uint(lab.client, launchpad, "nextLaunchId()"),
        "stocks_launch_fee_regent": str(call_uint(lab.client, launchpad, "launchFee()")),
        "agent_launch_fee_regent": str(call_uint(lab.client, lab.agent_factory, "launchFee()")),
        "executor": call_address(lab.client, hook, "executor()"),
        "stocks": stocks,
    }
    if args.launch:
        response["launch"] = launch_record(lab.client, launchpad, args.launch)
    if args.auction:
        response["auction"] = auction_timing(lab.client, launchpad, args.auction)
    print(json.dumps(response, indent=2, sort_keys=True))


MINE_CHUNK_BLOCKS = 1_000


def mine_to(client: RpcClient, target: int) -> int:
    """Mine to `target` in bounded chunks: one 43,200-block `anvil_mine` outlives the RPC timeout."""
    head = parse_quantity(client.read("eth_blockNumber"))
    if head > target:
        raise LabError(f"current block {head} is already past target {target}")
    while head < target:
        client.mutate("anvil_mine", [quantity(min(MINE_CHUNK_BLOCKS, target - head))])
        head = parse_quantity(client.read("eth_blockNumber"))
    return head


def command_advance(args: argparse.Namespace) -> None:
    lab = Lab(Path(args.agent_lab_dir), args.rpc_url)
    state = lab.load_state()
    timing = auction_timing(lab.client, state["addresses"]["launchpad"], args.auction)
    block_number = mine_to(lab.client, int(timing[args.to]))
    print(json.dumps({"block": block_number, "target": args.to, "timing": timing}, sort_keys=True))


def command_migrate(args: argparse.Namespace) -> None:
    lab = Lab(Path(args.agent_lab_dir), args.rpc_url)
    state = lab.load_state()
    launchpad = state["addresses"]["launchpad"]
    before = launch_record(lab.client, launchpad, args.launch)
    with impersonated(lab.client, STOCKS_LAB_DEPLOYER):
        transaction_hash = send_and_wait(lab.client, STOCKS_LAB_DEPLOYER, launchpad, selector("migrate(uint256)") + abi_uint(args.launch))
    after = launch_record(lab.client, launchpad, args.launch)
    print(json.dumps({"launch": args.launch, "transaction_hash": transaction_hash, "before": before["lifecycle"], "after": after["lifecycle"], "record": after}, indent=2, sort_keys=True))


def command_settle(args: argparse.Namespace) -> None:
    lab = Lab(Path(args.agent_lab_dir), args.rpc_url)
    state = lab.load_state()
    hook = state["addresses"]["hook"]
    destination = normalize_address(args.destination, "destination")
    amount = int(args.amount)
    min_usdc = int(args.min_usdc)
    accrued_before = call_uint(lab.client, hook, "accrued(bytes32,address)", abi_bytes32(args.pool_id), abi_address(destination))
    with impersonated(lab.client, STOCKS_LAB_DEPLOYER):
        transaction_hash = send_and_wait(
            lab.client, STOCKS_LAB_DEPLOYER, hook,
            selector("settle(bytes32,address,uint256,uint256)") + abi_bytes32(args.pool_id) + abi_address(destination) + abi_uint(amount) + abi_uint(min_usdc),
        )
    accrued_after = call_uint(lab.client, hook, "accrued(bytes32,address)", abi_bytes32(args.pool_id), abi_address(destination))
    converted, deposited = words(rpc_call(lab.client, hook, selector("settled(bytes32,address)") + abi_bytes32(args.pool_id) + abi_address(destination)))
    print(json.dumps({"transaction_hash": transaction_hash, "accrued_before": accrued_before, "accrued_after": accrued_after, "settled_stock": converted, "settled_usdc": deposited}, sort_keys=True))


# -----------------------------------------------------------------------------
# entry
# -----------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Extend the local Base-fork Agent lab with the Stocks graph")
    parser.add_argument("--agent-lab-dir", default=str(default_agent_lab_dir()), help="folder holding the Agent lab's state.json and site-config.json")
    parser.add_argument("--rpc-url", help="override the loopback RPC recorded by the Agent lab")
    commands = parser.add_subparsers(dest="command", required=True)

    deploy = commands.add_parser("deploy", help="install fixtures, deploy, admit, fund, write stocks-site-config.json")
    deploy.add_argument("--usdc-holder", default=DEFAULT_USDC_HOLDER, help="forked USDC holder to impersonate")
    deploy.add_argument("--route-stock", default="1000000", help="fixture STOCK minted to each route (shares)")
    deploy.add_argument("--route-usdc", default="1000000", help="USDC moved to each route (whole USDC)")
    deploy.add_argument("--force", action="store_true", help="deploy again even if a Stocks graph is recorded")
    deploy.set_defaults(handler=command_deploy)

    set_agent_fee = commands.add_parser("set-agent-fee", help="set the Agent factory's launch fee from the impersonated Governance Safe")
    set_agent_fee.add_argument("--amount", default=str(AGENT_LAUNCH_FEE_REGENT), help=f"whole REGENT (default: {AGENT_LAUNCH_FEE_REGENT})")
    set_agent_fee.set_defaults(handler=command_set_agent_fee)

    fund = commands.add_parser("fund", help="fund a wallet with gas, REGENT, fixture STOCK and/or USDC")
    fund.add_argument("wallet")
    fund.add_argument("--regent", help="REGENT amount in whole tokens (e.g. 600000 covers one Agent and one Stocks launch fee)")
    fund.add_argument("--stock", help="catalog symbol, e.g. AAPLc")
    fund.add_argument("--amount", help="STOCK amount in whole shares (with --stock)")
    fund.add_argument("--usdc", help="USDC amount in whole USDC")
    fund.add_argument("--wallet-eth", default="1", help="minimum wallet ETH (default: 1)")
    fund.set_defaults(handler=command_fund)

    status = commands.add_parser("status", help="show the Stocks lab")
    status.add_argument("--launch", type=int, help="include one launch record")
    status.add_argument("--auction", help="include one auction's timing")
    status.set_defaults(handler=command_status)

    advance = commands.add_parser("advance", help="mine to an auction lifecycle block")
    advance.add_argument("--auction", required=True)
    advance.add_argument("--to", required=True, choices=["start", "end", "claim", "migration"])
    advance.set_defaults(handler=command_advance)

    migrate = commands.add_parser("migrate", help="drive a launch to its terminal state")
    migrate.add_argument("--launch", type=int, required=True)
    migrate.set_defaults(handler=command_migrate)

    settle = commands.add_parser("settle", help="settle one hook bucket as the lab executor")
    settle.add_argument("--pool-id", required=True)
    settle.add_argument("--destination", required=True, help="REGENT token address for the REGENT bucket, or a splitter")
    settle.add_argument("--amount", required=True, help="STOCK base units")
    settle.add_argument("--min-usdc", default="1", help="minimum USDC base units out")
    settle.set_defaults(handler=command_settle)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    try:
        args = build_parser().parse_args(argv)
        require_no_dotenv(component_root())
        args.handler(args)
        return 0
    except LabError as exc:
        print(f"local Stocks lab failed: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("local Stocks lab failed: interrupted", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
