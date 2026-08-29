#!/usr/bin/env python3
"""Practical local Base-fork lab for the Regent Autolaunch website."""

from __future__ import annotations

import argparse
import contextlib
import decimal
import ipaddress
import json
import os
import re
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Mapping, Sequence

BASE_CHAIN_ID = 8_453
LOCAL_CHAIN_ID = 31_337
AUCTION_BLOCKS = 86_401
COUNTDOWN_BLOCKS = 30
REGENT_BASE_RPC_ENV = "REGENT_BASE_RPC_URL"
REGENT = "0x6f89bca4ea5931edfcb09786267b251dee752b07"
PERMIT2 = "0x000000000022d473030f116ddee9f6b43ac78ba3"
CCA_FACTORY = "0x000000001f26a0044baa66024e7b6599c61963f8"
POOL_MANAGER = "0x498581ff718922c3f8e6a244956af099b2652b2b"
POSITION_MANAGER = "0x7c5f5a4bbd8fd63184577525326123b519429bdc"
GOVERNANCE_SAFE = "0x9fa152b0eadbfe9a7c5c0a8e1d11784f22669a3e"

GENERATED = Path("reports/generated/local-base-lab")
STATE_PATH = GENERATED / "state.json"
SITE_CONFIG_PATH = GENERATED / "site-config.json"

ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
GRAPH_LOG_RE = re.compile(r"REGENT_LOCAL_LAB_([A-Z0-9_]+)\s*:?\s*(0x[0-9a-fA-F]+)")
GRAPH_LABELS = {
    "hook_salt",
    "uerc20_factory",
    "escrow_implementation",
    "splitter_implementation",
    "receiver_implementation",
    "factory",
    "strategy",
    "hook",
}
ABI_TARGETS = {
    "factory": "src/factory/RegentsAutolaunchFactoryV1.sol:RegentsAutolaunchFactoryV1",
    "strategy": "src/strategy/RegentLBPStrategy.sol:RegentLBPStrategy",
    "hook": "src/hook/RegentFeeHook.sol:RegentFeeHook",
    "escrow": "src/escrow/ConditionalVestingEscrowV1.sol:ConditionalVestingEscrowV1",
    "splitter": "src/revenue/SubjectSplitterV1.sol:SubjectSplitterV1",
    "receiver": "src/revenue/PaymentReceiverV1.sol:PaymentReceiverV1",
    "auction": "ContinuousClearingAuction",
    "token": "UERC20",
    "permit2": "IAllowanceTransfer",
}

# Fixed selectors from repository-pinned ABIs.
TRANSFER = "0xa9059cbb"
UNPAUSE_LAUNCHES = "0x5af02677"
LAUNCHES_PAUSED = "0x3bc340c2"
START_BLOCK = "0x48cd4cb1"
END_BLOCK = "0x083c6323"
CLAIM_BLOCK = "0x37dfbc4b"
FUNDS_RECIPIENT = "0x3b6fd2cf"
DISTRIBUTION = "0xc2db09c1"


class LabError(RuntimeError):
    """An expected local-lab failure."""


def repository_root() -> Path:
    return Path(__file__).resolve().parents[1]


def normalize_address(value: str, label: str = "address") -> str:
    if not ADDRESS_RE.fullmatch(value):
        raise LabError(f"{label} must be a 20-byte hex address")
    return value.lower()


def parse_quantity(value: str | int) -> int:
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


def parse_token_amount(value: str, decimals: int = 18) -> int:
    try:
        amount = decimal.Decimal(value)
    except decimal.InvalidOperation as exc:
        raise LabError("amount must be a decimal number") from exc
    units = amount * decimal.Decimal(10**decimals)
    if amount <= 0 or units != units.to_integral_value() or units >= 1 << 256:
        raise LabError(f"amount must be positive with at most {decimals} decimals")
    return int(units)


def validate_upstream_url(value: str) -> str:
    if not value:
        raise LabError(f"{REGENT_BASE_RPC_ENV} is required for start")
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise LabError(f"{REGENT_BASE_RPC_ENV} must be an HTTP(S) URL")
    if parsed.username or parsed.password:
        raise LabError(f"{REGENT_BASE_RPC_ENV} must not contain URL credentials")
    return value


def validate_loopback_rpc_url(value: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    if (
        parsed.scheme != "http"
        or not parsed.hostname
        or parsed.username
        or parsed.password
    ):
        raise LabError("local RPC must be an unauthenticated HTTP loopback URL")
    try:
        address = ipaddress.ip_address(parsed.hostname)
    except ValueError as exc:
        raise LabError("local RPC host must be a literal loopback address") from exc
    if not address.is_loopback:
        raise LabError("local RPC host must be a literal loopback address")
    if parsed.query or parsed.fragment or parsed.port is None:
        raise LabError("local RPC URL must include a port and no query or fragment")
    return value


class RpcClient:
    def __init__(self, url: str, timeout: float = 10.0):
        self.url = url
        self.timeout = timeout
        self._request_id = 0

    def _request(self, method: str, params: Sequence[Any] = ()) -> Any:
        self._request_id += 1
        payload = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": self._request_id,
                "method": method,
                "params": list(params),
            }
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
            message = document["error"].get("message", "unknown RPC error")
            raise LabError(f"local RPC {method} failed: {message}")
        if "result" not in document:
            raise LabError(f"local RPC omitted the result for {method}")
        return document["result"]

    def read(self, method: str, params: Sequence[Any] = ()) -> Any:
        return self._request(method, params)

    def assert_local(self) -> None:
        validate_loopback_rpc_url(self.url)
        found = parse_quantity(self._request("eth_chainId"))
        if found != LOCAL_CHAIN_ID:
            raise LabError(
                f"refusing mutation: expected local chain {LOCAL_CHAIN_ID}, found {found}"
            )

    def mutate(self, method: str, params: Sequence[Any] = ()) -> Any:
        self.assert_local()
        return self._request(method, params)


def require_base_upstream(url: str) -> None:
    found = parse_quantity(RpcClient(url).read("eth_chainId"))
    if found != BASE_CHAIN_ID:
        raise LabError(
            f"upstream RPC must be Base chain {BASE_CHAIN_ID}, found {found}"
        )


def atomic_write_json(path: Path, document: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, delete=False
    )
    temporary = Path(handle.name)
    try:
        with handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()


def load_json(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text())
    except (FileNotFoundError, OSError, json.JSONDecodeError) as exc:
        raise LabError(f"local lab state is unavailable: {path}") from exc
    if not isinstance(document, dict):
        raise LabError(f"local lab state is invalid: {path}")
    return document


def load_active_state(root: Path) -> dict[str, Any]:
    state = load_json(root / STATE_PATH)
    if state.get("status") != "active":
        raise LabError("no active local lab; run start first")
    if state.get("chain_id") != LOCAL_CHAIN_ID:
        raise LabError("recorded local lab has the wrong chain ID")
    validate_loopback_rpc_url(str(state.get("rpc_url", "")))
    return state


def child_environment() -> dict[str, str]:
    environment = dict(os.environ)
    environment.pop(REGENT_BASE_RPC_ENV, None)
    return environment


def forge_environment(extra: Mapping[str, str] | None = None) -> dict[str, str]:
    environment = child_environment()
    environment.update({"FOUNDRY_PROFILE": "local-base-lab", "FOUNDRY_OFFLINE": "true"})
    if extra:
        environment.update(extra)
    return environment


def run_checked(
    arguments: Sequence[str], root: Path, *, environment: Mapping[str, str]
) -> str:
    completed = subprocess.run(
        list(arguments),
        cwd=root,
        env=dict(environment),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if completed.returncode:
        summary = " ".join(arguments[:2])
        raise LabError(f"command failed: {summary}")
    return completed.stdout


def compile_lab(root: Path) -> None:
    run_checked(
        ["forge", "build", "--offline", "--skip", "test", "--skip", "**/*.t.sol"],
        root,
        environment=forge_environment(),
    )


def load_abis(root: Path) -> dict[str, Any]:
    result: dict[str, Any] = {}
    environment = forge_environment()
    for label, contract in ABI_TARGETS.items():
        raw = run_checked(
            ["forge", "inspect", contract, "abi", "--json"],
            root,
            environment=environment,
        )
        try:
            result[label] = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise LabError(f"Forge returned invalid ABI JSON for {label}") from exc
    return result


def reserve_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as candidate:
        candidate.bind(("127.0.0.1", 0))
        return int(candidate.getsockname()[1])


def build_anvil_command(
    port: int, upstream_url: str, fork_block: int | None
) -> list[str]:
    command = [
        "anvil",
        "--host",
        "127.0.0.1",
        "--port",
        str(port),
        "--chain-id",
        str(LOCAL_CHAIN_ID),
        "--fork-url",
        upstream_url,
        "--silent",
    ]
    if fork_block is not None:
        if fork_block < 0:
            raise LabError("fork block cannot be negative")
        command.extend(["--fork-block-number", str(fork_block)])
    return command


def start_anvil(command: Sequence[str], rpc_url: str) -> subprocess.Popen[bytes]:
    process = subprocess.Popen(
        list(command),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        env=child_environment(),
    )
    client = RpcClient(rpc_url, timeout=1.0)
    try:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise LabError("Anvil exited during startup")
            try:
                client.assert_local()
                return process
            except LabError:
                time.sleep(0.1)
        raise LabError("Anvil did not become ready")
    except BaseException:
        terminate_process(process)
        raise


def terminate_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def parse_deployment_graph(output: str) -> dict[str, str]:
    pairs = [
        (match.group(1).lower(), match.group(2))
        for match in GRAPH_LOG_RE.finditer(output)
    ]
    labels = [label for label, _ in pairs]
    if len(labels) != len(set(labels)):
        raise LabError("deployment wrapper reported a duplicate address label")
    if set(labels) != GRAPH_LABELS:
        raise LabError("deployment wrapper did not report the complete local graph")
    graph: dict[str, str] = {}
    for label, value in pairs:
        if label == "hook_salt":
            if not re.fullmatch(r"0x[0-9a-fA-F]{64}", value):
                raise LabError("deployment wrapper reported an invalid hook salt")
            graph[label] = value.lower()
        else:
            graph[label] = normalize_address(value, label)
    return graph


def deploy_graph(root: Path, client: RpcClient, deployer: str) -> dict[str, str]:
    client.assert_local()
    output = run_checked(
        [
            "forge",
            "script",
            "tools/local-base-lab/DeployLocalAutolaunchLab.s.sol:DeployLocalAutolaunchLab",
            "--rpc-url",
            client.url,
            "--broadcast",
            "--unlocked",
            "--sender",
            deployer,
            "--slow",
            "-vv",
        ],
        root,
        environment=forge_environment(
            {"REGENT_LOCAL_LAB_DEPLOYER": deployer, "RUST_LOG": "error"}
        ),
    )
    return parse_deployment_graph(output)


def rpc_call(client: RpcClient, target: str, data: str) -> str:
    result = client.read(
        "eth_call", [{"to": normalize_address(target), "data": data}, "latest"]
    )
    if not isinstance(result, str) or not result.startswith("0x"):
        raise LabError("eth_call returned invalid data")
    return result


def decode_uint(data: str) -> int:
    raw = bytes.fromhex(data.removeprefix("0x"))
    if len(raw) != 32:
        raise LabError("readback has the wrong ABI length")
    return int.from_bytes(raw, "big")


def decode_address(data: str) -> str:
    raw = bytes.fromhex(data.removeprefix("0x"))
    if len(raw) != 32 or any(raw[:12]):
        raise LabError("address readback has the wrong ABI value")
    return normalize_address("0x" + raw[12:].hex())


def abi_address(value: str) -> str:
    return normalize_address(value)[2:].rjust(64, "0")


def abi_uint(value: int) -> str:
    if value < 0 or value >= 1 << 256:
        raise LabError("integer is outside uint256")
    return f"{value:064x}"


def wait_receipt(
    client: RpcClient, transaction_hash: str, timeout: float = 60
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        receipt = client.read("eth_getTransactionReceipt", [transaction_hash])
        if receipt is not None:
            if parse_quantity(receipt.get("status", "0x0")) != 1:
                raise LabError("local transaction reverted")
            return dict(receipt)
        time.sleep(0.1)
    raise LabError("local transaction receipt timed out")


def send_transaction(client: RpcClient, sender: str, target: str, data: str) -> str:
    transaction_hash = client.mutate(
        "eth_sendTransaction",
        [
            {
                "from": normalize_address(sender),
                "to": normalize_address(target),
                "data": data,
                "gas": quantity(15_000_000),
                "value": "0x0",
            }
        ],
    )
    if not isinstance(transaction_hash, str):
        raise LabError("local transaction did not return a hash")
    return transaction_hash


@contextlib.contextmanager
def impersonated(client: RpcClient, account: str):
    account = normalize_address(account)
    client.mutate("anvil_impersonateAccount", [account])
    try:
        yield
    finally:
        client.mutate("anvil_stopImpersonatingAccount", [account])


def unpause_factory(client: RpcClient, factory: str) -> None:
    if decode_uint(rpc_call(client, factory, LAUNCHES_PAUSED)) == 0:
        return
    client.mutate("anvil_setBalance", [GOVERNANCE_SAFE, quantity(10**18)])
    with impersonated(client, GOVERNANCE_SAFE):
        transaction_hash = send_transaction(
            client, GOVERNANCE_SAFE, factory, UNPAUSE_LAUNCHES
        )
        wait_receipt(client, transaction_hash)
    if decode_uint(rpc_call(client, factory, LAUNCHES_PAUSED)) != 0:
        raise LabError("local factory remained paused")


def write_site_config(
    root: Path, rpc_url: str, graph: Mapping[str, str], abis: Mapping[str, Any]
) -> None:
    addresses = {key: value for key, value in graph.items() if key != "hook_salt"}
    addresses.update(
        {
            "regent": REGENT,
            "permit2": PERMIT2,
            "cca_factory": CCA_FACTORY,
            "pool_manager": POOL_MANAGER,
            "position_manager": POSITION_MANAGER,
            "governance_safe": GOVERNANCE_SAFE,
        }
    )
    atomic_write_json(
        root / SITE_CONFIG_PATH,
        {
            "rpc_url": validate_loopback_rpc_url(rpc_url),
            "chain_id": LOCAL_CHAIN_ID,
            "addresses": addresses,
            "abis": dict(abis),
        },
    )


def process_command(pid: int) -> list[str]:
    completed = subprocess.run(
        ["ps", "-p", str(pid), "-o", "command="],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if completed.returncode or not completed.stdout.strip():
        return []
    try:
        return shlex.split(completed.stdout.strip())
    except ValueError:
        return []


def recorded_anvil_matches(state: Mapping[str, Any]) -> bool:
    try:
        pid = int(state["pid"])
        port = urllib.parse.urlsplit(str(state["rpc_url"])).port
    except (KeyError, TypeError, ValueError):
        return False
    command = process_command(pid)
    if not command or Path(command[0]).name != "anvil" or port is None:
        return False

    def option_value(option: str) -> str | None:
        try:
            return command[command.index(option) + 1]
        except (ValueError, IndexError):
            return None

    return (
        option_value("--host") == "127.0.0.1"
        and option_value("--port") == str(port)
        and option_value("--chain-id") == str(LOCAL_CHAIN_ID)
    )


def mark_stale(root: Path, state: Mapping[str, Any]) -> None:
    updated = dict(state)
    updated["status"] = "stale"
    atomic_write_json(root / STATE_PATH, updated)
    with contextlib.suppress(FileNotFoundError):
        (root / SITE_CONFIG_PATH).unlink()


def command_start(args: argparse.Namespace) -> None:
    root = repository_root()
    state_path = root / STATE_PATH
    if state_path.exists():
        old = load_json(state_path)
        if old.get("status") == "active" and recorded_anvil_matches(old):
            raise LabError("a local lab is already active; stop it first")
        if old.get("status") == "active":
            mark_stale(root, old)

    upstream = validate_upstream_url(os.environ.get(REGENT_BASE_RPC_ENV, ""))
    require_base_upstream(upstream)
    compile_lab(root)
    abis = load_abis(root)
    port = reserve_port()
    rpc_url = validate_loopback_rpc_url(f"http://127.0.0.1:{port}")
    process: subprocess.Popen[bytes] | None = None
    complete = False
    try:
        process = start_anvil(
            build_anvil_command(port, upstream, args.fork_block), rpc_url
        )
        client = RpcClient(rpc_url)
        accounts = client.read("eth_accounts")
        if not isinstance(accounts, list) or not accounts:
            raise LabError("Anvil did not expose a local deployment account")
        deployer = normalize_address(str(accounts[0]), "local deployer")
        graph = deploy_graph(root, client, deployer)
        unpause_factory(client, graph["factory"])
        state = {
            "status": "active",
            "pid": process.pid,
            "rpc_url": rpc_url,
            "chain_id": LOCAL_CHAIN_ID,
            "block_number_at_start": parse_quantity(client.read("eth_blockNumber")),
            "addresses": {
                key: value for key, value in graph.items() if key != "hook_salt"
            },
        }
        atomic_write_json(state_path, state)
        write_site_config(root, rpc_url, graph, abis)
        complete = True
        print(
            json.dumps(
                {
                    "rpc_url": rpc_url,
                    "chain_id": LOCAL_CHAIN_ID,
                    "site_config": str(root / SITE_CONFIG_PATH),
                    "addresses": state["addresses"],
                },
                indent=2,
                sort_keys=True,
            )
        )
    finally:
        if process is not None and not complete:
            terminate_process(process)


def local_client(root: Path) -> tuple[dict[str, Any], RpcClient]:
    state = load_active_state(root)
    if not recorded_anvil_matches(state):
        mark_stale(root, state)
        raise LabError("recorded Anvil process is no longer the active lab")
    client = RpcClient(str(state["rpc_url"]))
    client.assert_local()
    return state, client


def account_balance(client: RpcClient, token: str, account: str) -> int:
    return decode_uint(rpc_call(client, token, "0x70a08231" + abi_address(account)))


def command_fund(args: argparse.Namespace) -> None:
    root = repository_root()
    _state, client = local_client(root)
    wallet = normalize_address(args.wallet, "wallet")
    holder = normalize_address(args.holder, "REGENT holder")
    if wallet == holder:
        raise LabError("wallet and REGENT holder must differ")
    amount = parse_token_amount(args.amount)
    wallet_gas = parse_token_amount(args.wallet_eth)
    if parse_quantity(client.read("eth_getBalance", [wallet, "latest"])) < wallet_gas:
        client.mutate("anvil_setBalance", [wallet, quantity(wallet_gas)])
    if parse_quantity(client.read("eth_getBalance", [holder, "latest"])) < 10**18:
        client.mutate("anvil_setBalance", [holder, quantity(10**18)])
    before_wallet = account_balance(client, REGENT, wallet)
    before_holder = account_balance(client, REGENT, holder)
    with impersonated(client, holder):
        transaction_hash = send_transaction(
            client, holder, REGENT, TRANSFER + abi_address(wallet) + abi_uint(amount)
        )
        wait_receipt(client, transaction_hash)
    if account_balance(client, REGENT, wallet) != before_wallet + amount:
        raise LabError("wallet REGENT balance did not increase by the requested amount")
    if account_balance(client, REGENT, holder) != before_holder - amount:
        raise LabError("holder REGENT balance did not decrease by the requested amount")
    print(
        json.dumps(
            {
                "wallet": wallet,
                "regent_wei": amount,
                "transaction_hash": transaction_hash,
            },
            sort_keys=True,
        )
    )


def auction_timing(client: RpcClient, auction: str) -> dict[str, int | str]:
    auction = normalize_address(auction, "auction")
    start = decode_uint(rpc_call(client, auction, START_BLOCK))
    end = decode_uint(rpc_call(client, auction, END_BLOCK))
    claim = decode_uint(rpc_call(client, auction, CLAIM_BLOCK))
    strategy = decode_address(rpc_call(client, auction, FUNDS_RECIPIENT))
    distribution = rpc_call(client, strategy, DISTRIBUTION + abi_address(auction))
    raw = bytes.fromhex(distribution.removeprefix("0x"))
    if len(raw) != 18 * 32:
        raise LabError("strategy distribution returned the wrong ABI length")
    migration = int.from_bytes(raw[4 * 32 : 5 * 32], "big")
    return {
        "auction": auction,
        "strategy": strategy,
        "start": start,
        "end": end,
        "claim": claim,
        "migration": migration,
    }


def target_block(timing: Mapping[str, int | str], target: str) -> int:
    if target == "countdown":
        return max(0, int(timing["start"]) - COUNTDOWN_BLOCKS)
    if target not in {"start", "end", "claim", "migration"}:
        raise LabError(f"unknown auction target: {target}")
    return int(timing[target])


def mine_to(client: RpcClient, target: int) -> int:
    head = parse_quantity(client.read("eth_blockNumber"))
    if head > target:
        raise LabError(f"current block {head} is already past target {target}")
    if head < target:
        client.mutate("anvil_mine", [quantity(target - head)])
    found = parse_quantity(client.read("eth_blockNumber"))
    if found < target:
        raise LabError("Anvil did not reach the requested block")
    return found


def command_advance(args: argparse.Namespace) -> None:
    _state, client = local_client(repository_root())
    timing = auction_timing(client, args.auction)
    block_number = mine_to(client, target_block(timing, args.target))
    print(
        json.dumps(
            {"block": block_number, "target": args.target, "timing": timing},
            sort_keys=True,
        )
    )


def paced_target(start: int, end: int, elapsed: float, duration: float) -> int:
    if end < start or elapsed < 0 or duration <= 0:
        raise LabError("pacing inputs must be positive and ordered")
    return start + int((end - start) * min(elapsed / duration, 1.0))


def command_pace(args: argparse.Namespace) -> None:
    _state, client = local_client(repository_root())
    timing = auction_timing(client, args.auction)
    start, end = int(timing["start"]), int(timing["end"])
    if end - start != AUCTION_BLOCKS:
        raise LabError(f"auction span is not the expected {AUCTION_BLOCKS} blocks")
    if args.duration_seconds <= 0:
        raise LabError("pace duration must be positive")
    head = parse_quantity(client.read("eth_blockNumber"))
    if head < start:
        mine_to(client, start)
    elif head > end:
        raise LabError("current block is already past the auction end")
    began = time.monotonic()
    while True:
        head = parse_quantity(client.read("eth_blockNumber"))
        if head >= end:
            break
        desired = paced_target(
            start, end, time.monotonic() - began, args.duration_seconds
        )
        if desired > head:
            client.mutate("anvil_mine", [quantity(desired - head)])
        else:
            time.sleep(0.25)
    print(
        json.dumps(
            {
                "block": head,
                "duration_seconds": args.duration_seconds,
                "timing": timing,
            },
            sort_keys=True,
        )
    )


def command_status(args: argparse.Namespace) -> None:
    state, client = local_client(repository_root())
    response: dict[str, Any] = {
        "status": "active",
        "rpc_url": state["rpc_url"],
        "chain_id": LOCAL_CHAIN_ID,
        "block": parse_quantity(client.read("eth_blockNumber")),
        "addresses": state["addresses"],
    }
    if args.auction:
        response["auction"] = auction_timing(client, args.auction)
    print(json.dumps(response, indent=2, sort_keys=True))


def command_stop(_args: argparse.Namespace) -> None:
    root = repository_root()
    state = load_json(root / STATE_PATH)
    if state.get("status") != "active":
        raise LabError("no active local lab")
    if not recorded_anvil_matches(state):
        mark_stale(root, state)
        raise LabError("recorded process was not the local Anvil; state marked stale")
    RpcClient(str(state["rpc_url"])).assert_local()
    pid = int(state["pid"])
    try:
        if os.getpgid(pid) != pid:
            raise LabError("recorded Anvil is not its own process group")
        os.killpg(pid, signal.SIGTERM)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and process_command(pid):
            time.sleep(0.05)
        if process_command(pid):
            if not recorded_anvil_matches(state):
                mark_stale(root, state)
                raise LabError(
                    "recorded process changed during stop; state marked stale"
                )
            os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    stopped = dict(state)
    stopped["status"] = "stopped"
    atomic_write_json(root / STATE_PATH, stopped)
    with contextlib.suppress(FileNotFoundError):
        (root / SITE_CONFIG_PATH).unlink()
    print("local lab stopped")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run the local Base-fork Autolaunch lab"
    )
    commands = parser.add_subparsers(dest="command", required=True)
    start = commands.add_parser(
        "start", help="start Anvil, deploy, and write site config"
    )
    start.add_argument("--fork-block", type=int, help="optional Base block to fork")
    start.set_defaults(handler=command_start)
    fund = commands.add_parser(
        "fund", help="fund a local wallet with gas and forked REGENT"
    )
    fund.add_argument("wallet", help="local website wallet address")
    fund.add_argument("--holder", required=True, help="fork address holding REGENT")
    fund.add_argument("--amount", required=True, help="REGENT amount in token units")
    fund.add_argument(
        "--wallet-eth", default="1", help="minimum local wallet ETH (default: 1)"
    )
    fund.set_defaults(handler=command_fund)
    advance = commands.add_parser("advance", help="mine to an auction lifecycle block")
    advance.add_argument("auction", help="auction address")
    advance.add_argument(
        "target", choices=["countdown", "start", "end", "claim", "migration"]
    )
    advance.set_defaults(handler=command_advance)
    pace = commands.add_parser(
        "pace", help="pace the auction span over local wall time"
    )
    pace.add_argument("auction", help="auction address")
    pace.add_argument("--duration-seconds", type=float, default=1800.0)
    pace.set_defaults(handler=command_pace)
    status = commands.add_parser("status", help="show the active local lab")
    status.add_argument("--auction", help="optional auction address")
    status.set_defaults(handler=command_status)
    stop = commands.add_parser("stop", help="stop only the recorded local Anvil")
    stop.set_defaults(handler=command_stop)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    try:
        args = build_parser().parse_args(argv)
        args.handler(args)
        return 0
    except LabError as exc:
        print(f"local Base lab failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
