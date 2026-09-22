#!/usr/bin/env python3
"""The deployment ceremony tool for a Memestake contracts package (Base `contracts/stocks`,
Robinhood `contracts/robinhood`), run from the package directory.

The package's production script (`script/Deploy*.s.sol`) consumes ceremony values and creates the
graph; it has no filesystem permission and writes nothing. This tool is the other half: it turns the
frozen release surface and the founder's selection into one deterministic packet, checks the live
external state the constructors depend on, rehearses the exact script unsigned, verifies confirmed
receipts into the deployed manifest, and renders the website's production site-config. Every value
it handles is public; no key, keystore path or endpoint is read here, and the provider endpoint it
consumes from the environment is never printed or written.

Modes:

  render      Offline. Runs the hermetic ceremony suite under the `deployment` profile, re-derives
              the committed selection (when one is installed) through the selection suite, renders
              the packet candidate from the frozen manifest and compares it byte for byte with
              `deployments/<network>/mainnet-no-go-packet.json`. Proves the deployed manifest is
              the empty record. Reaches no network.
  prepare     Reads the selected deployer's nonce, the head block, every binding's code hash and
              the control surface through `cast` (read-only), mines the hook salt offline through
              the selection suite, and writes a packet candidate carrying the selection and the
              external observation to reports/generated/deployment/. A human installs it.
  rehearse    Re-observes the committed external state and compares it exactly, proves the deployer
              nonce still equals the committed one, and simulates the exact deployment script
              against the live chain with no signer and no broadcast.
  record      Verifies the founder's confirmed transaction hashes against the committed packet
              (sender, nonce, order, created address, status, code identity, readbacks) and writes
              a deployed-manifest candidate to reports/generated/deployment/. A human installs it.
  site-config Renders the production site-config from the installed deployed manifest, the frozen
              ABIs and the endpoint the founder passes, to reports/generated/deployment/.

Endpoints come from the environment only (`REGENT_BASE_RPC_URL`, `REGENT_ROBINHOOD_RPC_URL`),
matching the `[rpc_endpoints]` aliases in `foundry.toml`. A diagnostic that would echo one is
redacted before it is shown.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import freeze  # noqa: E402  (keccak256, load_artifacts, code_object, render)

GENERATED = Path("reports/generated/deployment")
DEPLOYMENTS = Path("deployments")
FREEZE_REQUIREMENTS = Path("requirements/freeze.json")
FROZEN_MANIFEST = Path("reports/frozen/release-manifest.json")
FROZEN_IDENTITY = Path("requirements/frozen-identity.json")
PACKET_NAME = "mainnet-no-go-packet.json"
MANIFEST_NAME = "deployed-manifest.json"
SITE_CONFIG_NAME = "site-config.json"
DEPLOYMENT_PROFILE = "deployment"
SELECTION_CONTRACT = "DeploymentSelectionTest"
CEREMONY_CONTRACT = "DeploymentCeremonyTest"

# Never run beside signing authority; the script and the tool only ever simulate and read.
FORBIDDEN_ENV = (
    "PRIVATE_KEY", "ETH_PRIVATE_KEY", "DEPLOYER_PRIVATE_KEY", "MNEMONIC", "MNEMONIC_INDEX",
    "ETH_KEYSTORE", "ETH_KEYSTORE_ACCOUNT", "ETH_PASSWORD", "ETH_FROM", "FOUNDRY_SENDER",
    "ETHERSCAN_API_KEY", "LEDGER", "TREZOR", "AWS_KMS_KEY_ID", "GCP_KEY_NAME",
)
DOTENV_FILES = (".env", ".env.local", ".envrc")

ADDRESS_RE = re.compile(r"0x[0-9a-fA-F]{40}")
HASH32_RE = re.compile(r"^0x[0-9a-fA-F]{64}$")
URL_RE = re.compile(r"(?:https?|wss?)://[^\s\"'`)>\]]+")
SELECTION_LOG_RE = re.compile(r"^selection (\S+): (.+)$")
ZERO_ADDRESS = "0x" + "0" * 40


class CeremonyError(SystemExit):
    def __init__(self, message: str) -> None:
        super().__init__(f"ceremony: {redact(message)}")


def redact(text: str) -> str:
    return URL_RE.sub("<endpoint redacted>", text)


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise CeremonyError(f"{path} is absent")
    except json.JSONDecodeError as error:
        raise CeremonyError(f"{path} is not JSON: {error}")


def write_candidate(name: str, document: dict) -> Path:
    GENERATED.mkdir(parents=True, exist_ok=True)
    path = GENERATED / name
    path.write_text(freeze.render(document), encoding="utf-8")
    return path


def checksum(address: str) -> str:
    """EIP-55 form, so packets and manifests carry one spelling of every address."""
    lower = address.lower().removeprefix("0x")
    if len(lower) != 40 or not re.fullmatch(r"[0-9a-f]{40}", lower):
        raise CeremonyError(f"not a 20-byte address: {address}")
    digest = freeze.keccak256(lower.encode()).removeprefix("0x")
    return "0x" + "".join(c.upper() if int(digest[i], 16) >= 8 else c for i, c in enumerate(lower))


def same_address(a: str, b: str) -> bool:
    return a.lower() == b.lower()


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def digest_of(document: dict) -> str:
    undigested = json.loads(json.dumps(document))
    undigested["digest"]["value"] = None
    return "0x" + sha256_hex(json.dumps(undigested, indent=2, sort_keys=True).encode())


def run(args: list[str], env: dict | None = None) -> str:
    result = subprocess.run(args, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise CeremonyError(f"{args[0]} {args[1]} exited {result.returncode}:\n{result.stderr.strip()}")
    return result.stdout


def git(*args: str) -> str:
    return run(["git", *args]).strip()


# =============================================================================
# Preconditions
# =============================================================================


def refuse_signing_authority() -> None:
    for name in FORBIDDEN_ENV:
        if os.environ.get(name):
            raise CeremonyError(f"{name} is set; this tool never signs and refuses to run beside signing authority")
    for dotenv in DOTENV_FILES:
        if Path(dotenv).exists():
            raise CeremonyError(f"{dotenv} exists in the package; this tool never reads one and refuses to run beside one")
    print("no signing, keystore, sender or hardware-wallet variable is present; no dotenv file exists")


# =============================================================================
# Forge and cast
# =============================================================================


def forge_env(offline: bool, extra: dict | None = None) -> dict:
    env = dict(os.environ)
    env.update({
        "FOUNDRY_PROFILE": DEPLOYMENT_PROFILE,
        "FOUNDRY_LINT_LINT_ON_BUILD": "false",
        "RUST_LOG": "error",
        "FOUNDRY_OFFLINE": "true" if offline else "false",
    })
    if extra:
        env.update(extra)
    return env


def forge_test(match_contract: str, match_test: str | None, env: dict) -> dict:
    args = ["forge", "test", "--json", "-vv", "--match-contract", match_contract]
    if match_test:
        args += ["--match-test", match_test]
    report = json.loads(run(args, env=env))
    results = {}
    for suite in report.values():
        for selector, outcome in (suite.get("test_results") or {}).items():
            if outcome.get("status") != "Success":
                raise CeremonyError(f"{match_contract}::{selector} did not pass: {outcome.get('reason')}")
            results[selector] = outcome.get("decoded_logs") or []
    if not results:
        raise CeremonyError(f"no test of {match_contract} ran")
    return results


def selection_logs(match_test: str, env: dict) -> dict[str, str]:
    results = forge_test(SELECTION_CONTRACT, match_test, env)
    found: dict[str, str] = {}
    for logs in results.values():
        for line in logs:
            match = SELECTION_LOG_RE.match(line)
            if match:
                found[match.group(1)] = match.group(2).strip()
    if not found:
        raise CeremonyError(f"{SELECTION_CONTRACT}::{match_test} emitted no selection")
    return found


class Chain:
    """Read-only access to one chain through `cast`, by endpoint alias and environment name."""

    def __init__(self, alias: str, env_name: str, chain_id: int) -> None:
        self.alias = alias
        self.env_name = env_name
        self.chain_id = chain_id

    def endpoint(self) -> str:
        value = os.environ.get(self.env_name, "")
        if not value:
            raise CeremonyError(f"no read-only endpoint is injected under {self.env_name}")
        if not re.match(r"^(https?|wss?)://.+", value):
            raise CeremonyError(f"the value under {self.env_name} is not an http(s) or ws(s) endpoint; its value is never printed")
        return value

    def cast(self, *args: str) -> str:
        return run(["cast", *args, "--rpc-url", self.endpoint()]).strip()

    def probe(self) -> None:
        found = int(self.cast("chain-id"))
        if found != self.chain_id:
            raise CeremonyError(f"the endpoint under {self.env_name} serves chain {found}, not {self.chain_id}")
        print(f"{self.alias}: a read-only endpoint is injected under {self.env_name}; chain id {self.chain_id} confirmed")

    def nonce(self, account: str) -> int:
        return int(self.cast("nonce", account))

    def block_number(self) -> int:
        return int(self.cast("block-number"))

    def code(self, account: str) -> bytes:
        return bytes.fromhex(self.cast("code", account).removeprefix("0x"))

    def codehash(self, account: str) -> str:
        return self.cast("codehash", account).lower()

    def call(self, to: str, signature: str, *arguments: str) -> str:
        return self.cast("call", to, signature, *arguments)

    def call_address(self, to: str, signature: str, *arguments: str) -> str:
        found = ADDRESS_RE.findall(self.call(to, signature, *arguments))
        if len(found) != 1:
            raise CeremonyError(f"{signature} on {to} did not return one address")
        return checksum(found[0])

    def call_addresses(self, to: str, signature: str) -> list[str]:
        return [checksum(a) for a in ADDRESS_RE.findall(self.call(to, signature))]

    def call_uint(self, to: str, signature: str, *arguments: str) -> int:
        return int(self.call(to, signature, *arguments).split()[0])

    def call_bool(self, to: str, signature: str) -> bool:
        value = self.call(to, signature)
        if value not in ("true", "false"):
            raise CeremonyError(f"{signature} on {to} did not return a bool")
        return value == "true"

    def call_string(self, to: str, signature: str) -> str:
        return self.call(to, signature).strip().strip('"')

    def receipt(self, tx_hash: str) -> dict:
        return json.loads(self.cast("receipt", tx_hash, "--json"))

    def transaction(self, tx_hash: str) -> dict:
        return json.loads(self.cast("tx", tx_hash, "--json"))

    def safe_surface(self, safe: str) -> dict:
        """The exact owners and threshold of a Safe; a contract that answers neither is not a Safe."""
        return {
            "owners": self.call_addresses(safe, "getOwners()(address[])"),
            "threshold": self.call_uint(safe, "getThreshold()(uint256)"),
        }


def quantity(value) -> int:
    return int(value, 16) if isinstance(value, str) else int(value)


# =============================================================================
# The frozen surface
# =============================================================================


class Frozen:
    def __init__(self) -> None:
        self.requirements = load_json(FREEZE_REQUIREMENTS)
        self.manifest = load_json(FROZEN_MANIFEST)
        self.identity = load_json(FROZEN_IDENTITY)
        self.component = self.requirements["component"]

    def contract(self, name: str) -> dict:
        try:
            return self.manifest["contracts"][name]
        except KeyError:
            raise CeremonyError(f"{name} is not a frozen contract of {self.component}")

    def binding(self, constant: str, identity_path: Path = FROZEN_IDENTITY) -> str:
        """A `StocksBindings` constant as the named frozen identity pins it."""
        for entry in load_json(identity_path).get("bindings", []):
            if entry["constant"] == constant:
                return checksum(entry["value"])
        raise CeremonyError(f"{constant} is not a frozen binding in {identity_path}")

    def code_identity(self, name: str) -> dict:
        record = self.contract(name)
        return {
            "contract": name,
            "source": record["source"],
            "constructor": record["constructor"],
            "runtime_bytes": record["runtime_bytes"],
            "runtime_keccak256": record["runtime_keccak256"],
            "runtime_immutable_references": record["runtime_immutable_references"],
            "runtime_linked_libraries": record["runtime_linked_libraries"],
            "runtime_keccak256_is_deployed_codehash": record["runtime_keccak256_is_deployed_codehash"],
            "creation_bytes": record["creation_bytes"],
            "creation_keccak256": record["creation_keccak256"],
        }

    def hook_permission_bits(self) -> str:
        return self.manifest["hook_deployment"]["permissions"]["address_bits"]


def source_identity(frozen: Frozen, shared: str | None) -> dict:
    top = git("rev-parse", "--show-toplevel")
    cwd = Path.cwd().resolve()
    if cwd != (Path(top) / frozen.component).resolve():
        raise CeremonyError(f"run from {frozen.component}; the current directory is {cwd}")
    identity = {"src_tree": git("rev-parse", f"HEAD:{frozen.component}/src")}
    if shared:
        identity["shared_src_tree"] = git("rev-parse", f"HEAD:{shared}/src")
        identity["shared_component"] = shared
    return identity


# =============================================================================
# Package profiles
# =============================================================================


class Package:
    """What differs between the two Memestake ceremonies, stated once per package."""

    CREATIONS: tuple[str, ...]
    component: str
    network: str
    chain: Chain
    script: str
    shared_component: str | None
    hook_salt_env = "REGENT_DEPLOYMENT_HOOK_SALT"
    deployer_env = "REGENT_DEPLOYMENT_DEPLOYER"
    starting_nonce_env = "REGENT_DEPLOYMENT_STARTING_NONCE"

    def __init__(self, frozen: Frozen) -> None:
        self.frozen = frozen

    # --- selection ---------------------------------------------------------------------------

    def add_prepare_arguments(self, parser: argparse.ArgumentParser) -> None:
        raise NotImplementedError

    def inputs_from_arguments(self, args: argparse.Namespace) -> dict:
        raise NotImplementedError

    def selection_environment(self, selection: dict, salt: str | None) -> dict:
        raise NotImplementedError

    def selection_from_logs(self, inputs: dict, logs: dict[str, str]) -> dict:
        raise NotImplementedError

    def predicted_names(self) -> list[str]:
        raise NotImplementedError

    # --- observation -------------------------------------------------------------------------

    def observe(self, selection: dict) -> dict:
        raise NotImplementedError

    def compare_observation(self, committed: dict, observed: dict, problems: list[str]) -> None:
        for group, wanted in committed.items():
            if group == "observed_at_block":
                continue
            if observed.get(group) != wanted:
                problems.append(f"external_observation.{group} moved: committed {wanted}, observed {observed.get(group)}")

    # --- topology and rehearsal --------------------------------------------------------------

    def topology(self, selection: dict) -> list[dict]:
        raise NotImplementedError

    def rehearsals(self, selection: dict) -> list[tuple[Chain, list[str], dict]]:
        raise NotImplementedError

    # --- record and site-config --------------------------------------------------------------

    def transaction_plan(self, selection: dict) -> list[tuple[Chain, str, str]]:
        """(chain, contract, predicted address) per founder-sent transaction, in order."""
        raise NotImplementedError

    def internal_plan(self, selection: dict) -> list[tuple[Chain, str, str, str]]:
        """(chain, contract, predicted address, created_by) per creation inside a constructor."""
        raise NotImplementedError

    def readbacks(self, selection: dict, problems: list[str]) -> dict:
        raise NotImplementedError

    def link_addresses(self, selection: dict) -> dict[str, str]:
        return {}

    def site_config(self, manifest: dict, args: argparse.Namespace, abis: dict) -> dict:
        raise NotImplementedError

    def add_site_config_arguments(self, parser: argparse.ArgumentParser) -> None:
        parser.add_argument("--rpc-url", required=True, help="the endpoint the website's server reads through")
        parser.add_argument("--public-rpc-url", required=True, help="the endpoint wallets in the browser use")

    def abi_artifacts(self) -> dict[str, str]:
        raise NotImplementedError


def mined_salt_bits(salt_hex: str) -> None:
    if not HASH32_RE.match(salt_hex):
        raise CeremonyError(f"the mined hook salt is not 32 bytes: {salt_hex}")


class Stocks(Package):
    component = "contracts/stocks"
    network = "base-mainnet"
    chain = Chain("base", "REGENT_BASE_RPC_URL", 8453)
    script = "script/DeployStocksBase.s.sol:DeployStocksBase"
    shared_component = None
    PREDICTED = ("launchpad", "splitter_implementation", "locker", "hook", "bid_adapter")
    # Every contract a ceremony creates, in creation order, transactions first and then the
    # launchpad constructor's own creations.
    CREATIONS = ("StocksLaunchpadV1", "StockBidAdapterV1", "AerodromeStockRouteV1", "MemestockSplitterV1",
                 "MemestockLPLocker", "StocksFeeHookV1")
    BINDINGS = ("REGENT", "USDC", "CCA_FACTORY", "POOL_MANAGER", "POSITION_MANAGER", "LIVE_STAKING",
                "GOVERNANCE_AND_REGENT_SAFE", "PERMIT2")

    def add_prepare_arguments(self, parser: argparse.ArgumentParser) -> None:
        parser.add_argument("--uerc20-factory", required=True, help="the UERC20 factory the launchpad binds; its runtime hash must equal the frozen constant")
        parser.add_argument("--admission", action="append", required=True, metavar="STOCK:POOL:FEED",
                            help="one admitted stock with its Aerodrome Slipstream USDC/STOCK pool and Chainlink feed; repeatable, in ceremony order")

    def inputs_from_arguments(self, args: argparse.Namespace) -> dict:
        admissions = []
        for entry in args.admission:
            parts = entry.split(":")
            if len(parts) != 3:
                raise CeremonyError(f"--admission wants STOCK:POOL:FEED, got {entry}")
            admissions.append({"stock": checksum(parts[0]), "pool": checksum(parts[1]), "feed": checksum(parts[2])})
        return {"uerc20_factory": checksum(args.uerc20_factory), "admissions": admissions}

    def selection_environment(self, selection: dict, salt: str | None) -> dict:
        env = {
            self.deployer_env: selection["deployer"],
            self.starting_nonce_env: str(selection["starting_nonce"]),
            "REGENT_DEPLOYMENT_UERC20_FACTORY": selection["uerc20_factory"],
            "REGENT_DEPLOYMENT_STOCKS": ",".join(a["stock"] for a in selection["admissions"]),
            "REGENT_DEPLOYMENT_POOLS": ",".join(a["pool"] for a in selection["admissions"]),
            "REGENT_DEPLOYMENT_FEEDS": ",".join(a["feed"] for a in selection["admissions"]),
        }
        if salt:
            env[self.hook_salt_env] = salt
        return env

    def selection_from_logs(self, inputs: dict, logs: dict[str, str]) -> dict:
        mined_salt_bits(logs["hook_salt"])
        predicted = {name: checksum(logs[f"predicted_{name}"]) for name in self.PREDICTED}
        predicted["routes"] = [checksum(logs[f"predicted_route_{i}"]) for i in range(len(inputs["admissions"]))]
        for i, admission in enumerate(inputs["admissions"]):
            for field in ("stock", "pool", "feed"):
                if not same_address(logs[f"{field}_{i}"], admission[field]):
                    raise CeremonyError(f"the selection suite derived admission {i} from a different {field}")
        return {
            "deployer": checksum(logs["deployer"]),
            "starting_nonce": int(logs["starting_nonce"]),
            "hook_salt": logs["hook_salt"],
            "uerc20_factory": checksum(logs["uerc20_factory"]),
            "admissions": inputs["admissions"],
            "predicted_addresses": predicted,
        }

    def predicted_names(self) -> list[str]:
        return [*self.PREDICTED, "routes"]

    def observe(self, selection: dict) -> dict:
        chain = self.chain
        block = chain.block_number()
        bindings = {}
        for constant in self.BINDINGS:
            address = self.frozen.binding(constant)
            bindings[constant.lower()] = {"address": address, "codehash": chain.codehash(address)}
        factory = selection["uerc20_factory"]
        bindings["uerc20_factory"] = {"address": factory, "codehash": chain.codehash(factory)}
        frozen_factory = self.frozen.contract("UERC20Factory")["runtime_keccak256"]
        if bindings["uerc20_factory"]["codehash"] != frozen_factory.lower():
            raise CeremonyError(f"the UERC20 factory at {factory} does not carry the frozen runtime hash {frozen_factory}")
        for name, entry in bindings.items():
            if entry["codehash"] == freeze.keccak256(b""):
                raise CeremonyError(f"binding {name} at {entry['address']} has no code on Base")
        usdc = self.frozen.binding("USDC")
        admissions = []
        for admission in selection["admissions"]:
            stock, pool, feed = admission["stock"], admission["pool"], admission["feed"]
            token0 = chain.call_address(pool, "token0()(address)")
            token1 = chain.call_address(pool, "token1()(address)")
            if not same_address(token0, usdc) or not same_address(token1, stock):
                raise CeremonyError(f"pool {pool} is not USDC/{stock} in that order (token0 {token0}, token1 {token1})")
            admissions.append({
                "stock": stock,
                "symbol": chain.call_string(stock, "symbol()(string)"),
                "decimals": chain.call_uint(stock, "decimals()(uint8)"),
                "stock_codehash": chain.codehash(stock),
                "pool": pool,
                "pool_codehash": chain.codehash(pool),
                "feed": feed,
                "feed_codehash": chain.codehash(feed),
                "feed_decimals": chain.call_uint(feed, "decimals()(uint8)"),
            })
        safe = self.frozen.binding("GOVERNANCE_AND_REGENT_SAFE")
        staking = self.frozen.binding("LIVE_STAKING")
        return {
            "observed_at_block": block,
            "bindings": bindings,
            "admissions": admissions,
            "governance_and_regent_safe": chain.safe_surface(safe),
            "live_staking": {
                "owner": chain.call_address(staking, "owner()(address)"),
                "paused": chain.call_bool(staking, "paused()(bool)"),
            },
        }

    def topology(self, selection: dict) -> list[dict]:
        predicted = selection["predicted_addresses"]
        nonce = selection["starting_nonce"]
        order = [
            {"index": 0, "contract": "StocksLaunchpadV1", "mechanism": "transaction", "created_by": "deployer",
             "deployer_nonce": nonce, "address": predicted["launchpad"],
             "constructor_arguments": {"uerc20Factory_": selection["uerc20_factory"], "hookSalt": selection["hook_salt"]}},
            {"index": 1, "contract": "StockBidAdapterV1", "mechanism": "transaction", "created_by": "deployer",
             "deployer_nonce": nonce + 1, "address": predicted["bid_adapter"],
             "constructor_arguments": {"launchpad_": predicted["launchpad"]}},
        ]
        for i, admission in enumerate(selection["admissions"]):
            order.append({"index": 2 + i, "contract": "AerodromeStockRouteV1", "mechanism": "transaction",
                          "created_by": "deployer", "deployer_nonce": nonce + 2 + i, "address": predicted["routes"][i],
                          "constructor_arguments": {"stock_": admission["stock"], "pool_": admission["pool"], "feed_": admission["feed"]}})
        internal = [
            {"contract": "MemestockSplitterV1", "mechanism": "CREATE", "created_by": "StocksLaunchpadV1 constructor",
             "creator_nonce": 1, "address": predicted["splitter_implementation"]},
            {"contract": "MemestockLPLocker", "mechanism": "CREATE", "created_by": "StocksLaunchpadV1 constructor",
             "creator_nonce": 2, "address": predicted["locker"]},
            {"contract": "StocksFeeHookV1", "mechanism": "CREATE2", "created_by": "StocksLaunchpadV1 constructor",
             "salt": selection["hook_salt"], "address": predicted["hook"],
             "constructor_arguments": {"manager_": self.frozen.binding("POOL_MANAGER"), "launchpad_": predicted["launchpad"]}},
        ]
        return [{"chain_id": self.chain.chain_id, "creation_order": order, "internal_creations": internal}]

    def rehearsals(self, selection: dict) -> list[tuple[Chain, list[str], dict]]:
        env = self.selection_environment(selection, selection["hook_salt"])
        return [(self.chain, ["forge", "script", self.script, "--rpc-url", self.chain.alias], env)]

    def transaction_plan(self, selection: dict) -> list[tuple[Chain, str, str]]:
        predicted = selection["predicted_addresses"]
        plan = [(self.chain, "StocksLaunchpadV1", predicted["launchpad"]), (self.chain, "StockBidAdapterV1", predicted["bid_adapter"])]
        plan += [(self.chain, "AerodromeStockRouteV1", route) for route in predicted["routes"]]
        return plan

    def internal_plan(self, selection: dict) -> list[tuple[Chain, str, str, str]]:
        predicted = selection["predicted_addresses"]
        return [
            (self.chain, "MemestockSplitterV1", predicted["splitter_implementation"], "StocksLaunchpadV1 constructor"),
            (self.chain, "MemestockLPLocker", predicted["locker"], "StocksLaunchpadV1 constructor"),
            (self.chain, "StocksFeeHookV1", predicted["hook"], "StocksLaunchpadV1 constructor"),
        ]

    def readbacks(self, selection: dict, problems: list[str]) -> dict:
        chain = self.chain
        predicted = selection["predicted_addresses"]
        launchpad = predicted["launchpad"]
        found = {
            "launchpad.hook": chain.call_address(launchpad, "hook()(address)"),
            "launchpad.locker": chain.call_address(launchpad, "locker()(address)"),
            "launchpad.splitterImplementation": chain.call_address(launchpad, "splitterImplementation()(address)"),
            "launchpad.launchesPaused": chain.call_bool(launchpad, "launchesPaused()(bool)"),
            "bidAdapter.launchpad": chain.call_address(predicted["bid_adapter"], "launchpad()(address)"),
        }
        expected = {
            "launchpad.hook": predicted["hook"],
            "launchpad.locker": predicted["locker"],
            "launchpad.splitterImplementation": predicted["splitter_implementation"],
            "launchpad.launchesPaused": True,
            "bidAdapter.launchpad": launchpad,
        }
        for i, route in enumerate(predicted["routes"]):
            admission = selection["admissions"][i]
            for view, wanted in (("stock", admission["stock"]), ("pool", admission["pool"]), ("feed", admission["feed"])):
                found[f"route[{i}].{view}"] = chain.call_address(route, f"{view}()(address)")
                expected[f"route[{i}].{view}"] = wanted
        for key, wanted in expected.items():
            if found[key] != wanted:
                problems.append(f"readback {key}: expected {wanted}, found {found[key]}")
        return found

    def abi_artifacts(self) -> dict[str, tuple[str, str]]:
        return {
            "launchpad": ("out", "src/StocksLaunchpadV1.sol:StocksLaunchpadV1"),
            "hook": ("out", "src/StocksFeeHookV1.sol:StocksFeeHookV1"),
            "locker": ("out", "src/MemestockLPLocker.sol:MemestockLPLocker"),
            "splitter": ("out", "src/MemestockSplitterV1.sol:MemestockSplitterV1"),
            "bid_adapter": ("out", "src/StockBidAdapterV1.sol:StockBidAdapterV1"),
            "route": ("out", "src/routes/AerodromeStockRouteV1.sol:AerodromeStockRouteV1"),
            "auction": ("out", "lib/continuous-clearing-auction/src/ContinuousClearingAuction.sol:ContinuousClearingAuction"),
            "erc20": ("out", "src/interfaces/IERC20Standard.sol:IERC20Standard"),
            "permit2": ("out", "lib/permit2/src/interfaces/IAllowanceTransfer.sol:IAllowanceTransfer"),
        }

    def add_site_config_arguments(self, parser: argparse.ArgumentParser) -> None:
        super().add_site_config_arguments(parser)
        parser.add_argument("--agent-factory", required=True, help="the deployed Base Revstake factory, from contracts/v1/deployments/base-mainnet/deployed-manifest.json")

    def site_config(self, manifest: dict, args: argparse.Namespace, abis: dict) -> dict:
        created = {entry["contract_key"]: entry["address"] for entry in manifest["contracts"]}
        addresses = {
            "launchpad": created["launchpad"],
            "hook": created["hook"],
            "locker": created["locker"],
            "splitter_implementation": created["splitter_implementation"],
            "bid_adapter": created["bid_adapter"],
            "usdc": self.frozen.binding("USDC"),
            "regent": self.frozen.binding("REGENT"),
            "permit2": self.frozen.binding("PERMIT2"),
            "cca_factory": self.frozen.binding("CCA_FACTORY"),
            "pool_manager": self.frozen.binding("POOL_MANAGER"),
            "position_manager": self.frozen.binding("POSITION_MANAGER"),
            "live_staking": self.frozen.binding("LIVE_STAKING"),
            "governance_safe": self.frozen.binding("GOVERNANCE_AND_REGENT_SAFE"),
            "agent_factory": checksum(args.agent_factory),
        }
        stocks = [
            {
                "symbol": admission["symbol"],
                "address": admission["stock"].lower(),
                "decimals": admission["decimals"],
                "route": admission["route"].lower(),
                "fixture": False,
                "launch_admission": "admitted",
            }
            for admission in manifest["admissions"]
        ]
        return {
            "rpc_url": args.rpc_url,
            "public_rpc_url": args.public_rpc_url,
            "chain_id": self.chain.chain_id,
            "addresses": {key: value.lower() for key, value in addresses.items()},
            "stocks": stocks,
            "abis": abis,
        }


class Robinhood(Package):
    component = "contracts/robinhood"
    network = "robinhood-mainnet"
    chain = Chain("robinhood", "REGENT_ROBINHOOD_RPC_URL", 4663)
    base = Chain("base", "REGENT_BASE_RPC_URL", 8453)
    script = "script/DeployRobinhood.s.sol:DeployRobinhood"
    receiver_script = "script/DeployRobinhoodBaseReceiver.s.sol:DeployRobinhoodBaseReceiver"
    shared_component = "contracts/stocks"
    # The Base receiver binds `StocksBindings` constants, frozen by the shared Base package.
    BASE_IDENTITY = Path("../stocks") / FROZEN_IDENTITY
    PREDICTED = ("uerc20_factory", "inbox", "positions_lib", "hook_factory", "launchpad", "bid_adapter",
                 "hook", "splitter_implementation", "locker")
    EXTERNAL = ("usdg", "cca_factory", "pool_manager", "position_manager", "permit2", "admin_safe")
    # Uniswap's own router and quoter on Robinhood Chain: the website trades through them, the
    # graph never touches them. Recorded and observed so the site-config carries verified addresses.
    SITE_BINDINGS = ("swap_router", "quoter")
    CREATIONS = ("UERC20Factory", "RobinhoodProtocolRevenueInboxV1", "RobinhoodPositionsLib", "RobinhoodFeeHookFactory",
                 "RobinhoodStocksLaunchpadV1", "RobinhoodStockBidAdapterV1", "RobinhoodFeeHookV1",
                 "RobinhoodMemestockSplitterV1", "MemestockLPLocker", "RobinhoodBaseRevenueReceiverV1")
    LIBRARY = "src/libraries/RobinhoodPositionsLib.sol:RobinhoodPositionsLib"

    def add_prepare_arguments(self, parser: argparse.ArgumentParser) -> None:
        for name in self.EXTERNAL:
            parser.add_argument(f"--{name.replace('_', '-')}", required=True, help=f"the {name} binding on Robinhood Chain")
        for name in self.SITE_BINDINGS:
            parser.add_argument(f"--{name.replace('_', '-')}", required=True, help=f"Uniswap's {name} on Robinhood Chain, for the website's swaps")
        parser.add_argument("--base-safe", required=True, help="the Base Safe that attests deliveries to the Base receiver")

    def inputs_from_arguments(self, args: argparse.Namespace) -> dict:
        return {
            "external": {name: checksum(getattr(args, name)) for name in self.EXTERNAL},
            "site_bindings": {name: checksum(getattr(args, name)) for name in self.SITE_BINDINGS},
            "base_safe": checksum(args.base_safe),
        }

    def selection_environment(self, selection: dict, salt: str | None) -> dict:
        env = {
            self.deployer_env: selection["deployer"],
            self.starting_nonce_env: str(selection["starting_nonce"]),
            "REGENT_DEPLOYMENT_BASE_SAFE": selection["base_receiver"]["base_safe"],
        }
        for name in self.EXTERNAL:
            env[f"REGENT_DEPLOYMENT_{name.upper()}"] = selection["external"][name]
        if salt:
            env[self.hook_salt_env] = salt
        return env

    def selection_from_logs(self, inputs: dict, logs: dict[str, str]) -> dict:
        mined_salt_bits(logs["hook_salt"])
        for name in self.EXTERNAL:
            if not same_address(logs[name], inputs["external"][name]):
                raise CeremonyError(f"the selection suite derived the graph from a different {name}")
        return {
            "deployer": checksum(logs["deployer"]),
            "starting_nonce": int(logs["starting_nonce"]),
            "hook_salt": logs["hook_salt"],
            "external": inputs["external"],
            "site_bindings": inputs["site_bindings"],
            "predicted_addresses": {name: checksum(logs[f"predicted_{name}"]) for name in self.PREDICTED},
            "base_receiver": inputs["base_receiver"],
        }

    def predicted_names(self) -> list[str]:
        return list(self.PREDICTED)

    def base_receiver_selection(self, deployer: str, base_nonce: int, base_safe: str) -> dict:
        env = {
            self.deployer_env: deployer,
            self.starting_nonce_env: str(base_nonce),
            "REGENT_DEPLOYMENT_BASE_SAFE": base_safe,
        }
        logs = selection_logs("test_BaseReceiverSelection", forge_env(offline=True, extra=env))
        return {
            "chain_id": self.base.chain_id,
            "deployer": deployer,
            "starting_nonce": base_nonce,
            "base_safe": base_safe,
            "predicted_address": checksum(logs["predicted_base_receiver"]),
        }

    def observe(self, selection: dict) -> dict:
        chain, base = self.chain, self.base
        block = chain.block_number()
        bindings = {}
        for name in self.EXTERNAL:
            address = selection["external"][name]
            bindings[name] = {"address": address, "codehash": chain.codehash(address)}
            if name != "admin_safe" and bindings[name]["codehash"] == freeze.keccak256(b""):
                raise CeremonyError(f"binding {name} at {address} has no code on Robinhood Chain")
        usdg = selection["external"]["usdg"]
        decimals = chain.call_uint(usdg, "decimals()(uint8)")
        if decimals != 6:
            raise CeremonyError(f"USDG at {usdg} reports {decimals} decimals, not 6")
        site_bindings = {}
        for name in self.SITE_BINDINGS:
            address = selection["site_bindings"][name]
            site_bindings[name] = {"address": address, "codehash": chain.codehash(address)}
            bound = chain.call_address(address, "poolManager()(address)")
            if bound != selection["external"]["pool_manager"]:
                raise CeremonyError(f"{name} at {address} is bound to pool manager {bound}, not the selected one")
        frozen_cca = self.frozen.contract("ContinuousClearingAuctionFactory")
        receiver = selection["base_receiver"]
        base_block = base.block_number()
        usdc = self.frozen.binding("USDC", self.BASE_IDENTITY)
        staking = self.frozen.binding("LIVE_STAKING", self.BASE_IDENTITY)
        return {
            "observed_at_block": block,
            "bindings": bindings,
            "usdg_decimals": decimals,
            "site_bindings": site_bindings,
            "cca_factory_frozen_runtime_bytes": frozen_cca["runtime_bytes"],
            "admin_safe": chain.safe_surface(selection["external"]["admin_safe"]),
            "base": {
                "observed_at_block": base_block,
                "bindings": {
                    "usdc": {"address": usdc, "codehash": base.codehash(usdc)},
                    "live_staking": {"address": staking, "codehash": base.codehash(staking)},
                },
                "live_staking": {
                    "owner": base.call_address(staking, "owner()(address)"),
                    "paused": base.call_bool(staking, "paused()(bool)"),
                },
                "base_safe": base.safe_surface(receiver["base_safe"]),
            },
        }

    def compare_observation(self, committed: dict, observed: dict, problems: list[str]) -> None:
        for group, wanted in committed.items():
            if group == "observed_at_block":
                continue
            if group == "base":
                for fact, base_wanted in wanted.items():
                    if fact != "observed_at_block" and observed["base"].get(fact) != base_wanted:
                        problems.append(f"external_observation.base.{fact} moved: committed {base_wanted}, observed {observed['base'].get(fact)}")
                continue
            if observed.get(group) != wanted:
                problems.append(f"external_observation.{group} moved: committed {wanted}, observed {observed.get(group)}")

    def topology(self, selection: dict) -> list[dict]:
        p = selection["predicted_addresses"]
        e = selection["external"]
        n = selection["starting_nonce"]
        bindings = {"uerc20Factory": p["uerc20_factory"], "ccaFactory": e["cca_factory"], "poolManager": e["pool_manager"],
                    "positionManager": e["position_manager"], "hookFactory": p["hook_factory"], "usdg": e["usdg"],
                    "inbox": p["inbox"], "adminSafe": e["admin_safe"]}
        order = [
            {"index": 0, "contract": "UERC20Factory", "mechanism": "transaction", "created_by": "deployer", "deployer_nonce": n,
             "address": p["uerc20_factory"], "constructor_arguments": {}},
            {"index": 1, "contract": "RobinhoodProtocolRevenueInboxV1", "mechanism": "transaction", "created_by": "deployer",
             "deployer_nonce": n + 1, "address": p["inbox"], "constructor_arguments": {"usdg_": e["usdg"], "adminSafe_": e["admin_safe"]}},
            {"index": 2, "contract": "RobinhoodPositionsLib", "mechanism": "transaction", "created_by": "deployer",
             "deployer_nonce": n + 2, "address": p["positions_lib"], "constructor_arguments": {}},
            {"index": 3, "contract": "RobinhoodFeeHookFactory", "mechanism": "transaction", "created_by": "deployer",
             "deployer_nonce": n + 3, "address": p["hook_factory"], "constructor_arguments": {"poolManager_": e["pool_manager"]}},
            {"index": 4, "contract": "RobinhoodStocksLaunchpadV1", "mechanism": "transaction", "created_by": "deployer",
             "deployer_nonce": n + 4, "address": p["launchpad"], "linked_library": {"RobinhoodPositionsLib": p["positions_lib"]},
             "constructor_arguments": {"bindings": bindings, "hookSalt": selection["hook_salt"]}},
            {"index": 5, "contract": "RobinhoodStockBidAdapterV1", "mechanism": "transaction", "created_by": "deployer",
             "deployer_nonce": n + 5, "address": p["bid_adapter"], "constructor_arguments": {"launchpad_": p["launchpad"], "permit2_": e["permit2"]}},
        ]
        internal = [
            {"contract": "RobinhoodFeeHookV1", "mechanism": "CREATE2", "created_by": "RobinhoodFeeHookFactory.deploy from the launchpad constructor",
             "salt": selection["hook_salt"], "address": p["hook"],
             "constructor_arguments": {"manager_": e["pool_manager"], "launchpad_": p["launchpad"], "usdg_": e["usdg"], "inbox_": p["inbox"], "adminSafe_": e["admin_safe"]}},
            {"contract": "RobinhoodMemestockSplitterV1", "mechanism": "CREATE", "created_by": "RobinhoodStocksLaunchpadV1 constructor",
             "creator_nonce": 1, "address": p["splitter_implementation"]},
            {"contract": "MemestockLPLocker", "mechanism": "CREATE", "created_by": "RobinhoodStocksLaunchpadV1 constructor",
             "creator_nonce": 2, "address": p["locker"]},
        ]
        r = selection["base_receiver"]
        base_order = [{"index": 0, "contract": "RobinhoodBaseRevenueReceiverV1", "mechanism": "transaction", "created_by": "deployer",
                       "deployer_nonce": r["starting_nonce"], "address": r["predicted_address"],
                       "constructor_arguments": {"usdc_": self.frozen.binding("USDC", self.BASE_IDENTITY), "liveStaking_": self.frozen.binding("LIVE_STAKING", self.BASE_IDENTITY), "baseSafe_": r["base_safe"]}}]
        return [
            {"chain_id": self.chain.chain_id, "creation_order": order, "internal_creations": internal},
            {"chain_id": self.base.chain_id, "creation_order": base_order, "internal_creations": []},
        ]

    def library_pin(self, selection: dict) -> str:
        return f"{self.LIBRARY}:{selection['predicted_addresses']['positions_lib']}"

    def rehearsals(self, selection: dict) -> list[tuple[Chain, list[str], dict]]:
        env = self.selection_environment(selection, selection["hook_salt"])
        return [
            (self.chain, ["forge", "script", self.script, "--rpc-url", self.chain.alias, "--libraries", self.library_pin(selection)], env),
            (self.base, ["forge", "script", self.receiver_script, "--rpc-url", self.base.alias], env),
        ]

    def transaction_plan(self, selection: dict) -> list[tuple[Chain, str, str]]:
        p = selection["predicted_addresses"]
        return [
            (self.chain, "UERC20Factory", p["uerc20_factory"]),
            (self.chain, "RobinhoodProtocolRevenueInboxV1", p["inbox"]),
            (self.chain, "RobinhoodPositionsLib", p["positions_lib"]),
            (self.chain, "RobinhoodFeeHookFactory", p["hook_factory"]),
            (self.chain, "RobinhoodStocksLaunchpadV1", p["launchpad"]),
            (self.chain, "RobinhoodStockBidAdapterV1", p["bid_adapter"]),
            (self.base, "RobinhoodBaseRevenueReceiverV1", selection["base_receiver"]["predicted_address"]),
        ]

    def internal_plan(self, selection: dict) -> list[tuple[Chain, str, str, str]]:
        p = selection["predicted_addresses"]
        return [
            (self.chain, "RobinhoodFeeHookV1", p["hook"], "RobinhoodFeeHookFactory.deploy from the launchpad constructor"),
            (self.chain, "RobinhoodMemestockSplitterV1", p["splitter_implementation"], "RobinhoodStocksLaunchpadV1 constructor"),
            (self.chain, "MemestockLPLocker", p["locker"], "RobinhoodStocksLaunchpadV1 constructor"),
        ]

    def link_addresses(self, selection: dict) -> dict[str, str]:
        return {"RobinhoodPositionsLib": selection["predicted_addresses"]["positions_lib"]}

    def readbacks(self, selection: dict, problems: list[str]) -> dict:
        chain, base = self.chain, self.base
        p, e, r = selection["predicted_addresses"], selection["external"], selection["base_receiver"]
        found = {
            "launchpad.hook": chain.call_address(p["launchpad"], "hook()(address)"),
            "launchpad.locker": chain.call_address(p["launchpad"], "locker()(address)"),
            "launchpad.splitterImplementation": chain.call_address(p["launchpad"], "splitterImplementation()(address)"),
            "launchpad.adminSafe": chain.call_address(p["launchpad"], "adminSafe()(address)"),
            "launchpad.uerc20Factory": chain.call_address(p["launchpad"], "uerc20Factory()(address)"),
            "launchpad.launchesPaused": chain.call_bool(p["launchpad"], "launchesPaused()(bool)"),
            "hookFactory.poolManager": chain.call_address(p["hook_factory"], "poolManager()(address)"),
            "inbox.usdg": chain.call_address(p["inbox"], "usdg()(address)"),
            "inbox.adminSafe": chain.call_address(p["inbox"], "adminSafe()(address)"),
            "hook.inbox": chain.call_address(p["hook"], "inbox()(address)"),
            "bidAdapter.launchpad": chain.call_address(p["bid_adapter"], "launchpad()(address)"),
            "receiver.usdc": base.call_address(r["predicted_address"], "usdc()(address)"),
            "receiver.liveStaking": base.call_address(r["predicted_address"], "liveStaking()(address)"),
            "receiver.baseSafe": base.call_address(r["predicted_address"], "baseSafe()(address)"),
        }
        expected = {
            "launchpad.hook": p["hook"], "launchpad.locker": p["locker"],
            "launchpad.splitterImplementation": p["splitter_implementation"], "launchpad.adminSafe": e["admin_safe"],
            "launchpad.uerc20Factory": p["uerc20_factory"], "launchpad.launchesPaused": True,
            "hookFactory.poolManager": e["pool_manager"], "inbox.usdg": e["usdg"], "inbox.adminSafe": e["admin_safe"],
            "hook.inbox": p["inbox"], "bidAdapter.launchpad": p["launchpad"],
            "receiver.usdc": self.frozen.binding("USDC", self.BASE_IDENTITY), "receiver.liveStaking": self.frozen.binding("LIVE_STAKING", self.BASE_IDENTITY),
            "receiver.baseSafe": r["base_safe"],
        }
        for key, wanted in expected.items():
            if found[key] != wanted:
                problems.append(f"readback {key}: expected {wanted}, found {found[key]}")
        return found

    def abi_artifacts(self) -> dict[str, tuple[str, str]]:
        return {
            "stocks_launchpad": ("out", "src/RobinhoodStocksLaunchpadV1.sol:RobinhoodStocksLaunchpadV1"),
            "stocks_hook": ("out", "src/RobinhoodFeeHookV1.sol:RobinhoodFeeHookV1"),
            "stocks_locker": ("out", "../stocks/src/MemestockLPLocker.sol:MemestockLPLocker"),
            "splitter": ("out", "src/RobinhoodMemestockSplitterV1.sol:RobinhoodMemestockSplitterV1"),
            "bid_adapter": ("out", "src/RobinhoodStockBidAdapterV1.sol:RobinhoodStockBidAdapterV1"),
            "stock_route": ("out", "src/interfaces/IRobinhoodStockRoute.sol:IRobinhoodStockRoute"),
            "auction": ("out", "../stocks/lib/continuous-clearing-auction/src/ContinuousClearingAuction.sol:ContinuousClearingAuction"),
            # The shared ERC-20 surface is compiled only in the Base package's build.
            "erc20": ("../stocks/out", "src/interfaces/IERC20Standard.sol:IERC20Standard"),
        }

    def add_site_config_arguments(self, parser: argparse.ArgumentParser) -> None:
        super().add_site_config_arguments(parser)
        parser.add_argument("--run-id", required=True, help="the non-empty deployment label the website shows for this graph")
        parser.add_argument("--stock", action="append", required=True, metavar="SYMBOL:NAME:ADDRESS:ROUTE:USDG_PER_SHARE",
                            help="one stock the admin Safe admitted on the launchpad with its route and its USDG price per share in atomic units; repeatable")

    def site_config(self, manifest: dict, args: argparse.Namespace, abis: dict) -> dict:
        created = {entry["contract_key"]: entry["address"] for entry in manifest["contracts"] if entry["chain_id"] == self.chain.chain_id}
        external = manifest["external"]
        addresses = {
            "stocks_launchpad": created["launchpad"],
            "stocks_hook": created["hook"],
            "stocks_locker": created["locker"],
            "stocks_splitter_implementation": created["splitter_implementation"],
            "bid_adapter": created["bid_adapter"],
            "usdg": external["usdg"],
            "inbox": created["inbox"],
            "hook_factory": created["hook_factory"],
            "pool_manager": external["pool_manager"],
            "position_manager": external["position_manager"],
            "cca_factory": external["cca_factory"],
            "uerc20_factory": created["uerc20_factory"],
            "permit2": external["permit2"],
            "admin_safe": external["admin_safe"],
            "swap_router": manifest["selection"]["site_bindings"]["swap_router"],
            "quoter": manifest["selection"]["site_bindings"]["quoter"],
        }
        stocks = []
        for entry in args.stock:
            parts = entry.split(":")
            if len(parts) != 5:
                raise CeremonyError(f"--stock wants SYMBOL:NAME:ADDRESS:ROUTE:USDG_PER_SHARE, got {entry}")
            symbol, name, address, route, usdg_per_share = parts
            if not symbol or not name or not usdg_per_share.isdigit() or int(usdg_per_share) == 0:
                raise CeremonyError(f"--stock {entry}: the symbol and name are non-empty and the price is a positive integer of USDG atomic units")
            stocks.append({
                "symbol": symbol,
                "name": name,
                "address": checksum(address).lower(),
                "decimals": 8,
                "route": checksum(route).lower(),
                "usdg_per_share": usdg_per_share,
                "fixture": False,
                "launch_admission": "admitted",
            })
        return {
            "rpc_url": args.rpc_url,
            "public_rpc_url": args.public_rpc_url,
            "chain_id": self.chain.chain_id,
            "run_id": args.run_id,
            "addresses": {key: value.lower() for key, value in addresses.items()},
            "stocks": stocks,
            "abis": abis,
        }


PACKAGES = {Stocks.component: Stocks, Robinhood.component: Robinhood}


# =============================================================================
# The packet
# =============================================================================


def empty_manifest(package: Package) -> dict:
    return {
        "artifact": f"regents-autolaunch-{package.network}-deployed-manifest",
        "version": 1,
        "status": "not deployed",
        "populated_by": "confirmed receipts, and nothing else",
        "note": (
            "This file is the only record of deployed facts, and it is deliberately empty. It is not the "
            "packet: the packet is a proposal about what a ceremony would do, rendered from an offline or "
            "read-only run. Nothing simulated may be written here. Every field is populated once, by "
            "`bin/ceremony.py record` from confirmed receipts, after the founder has named the approved "
            "packet digest and sent the ceremony by hand; a human installs the candidate it writes."
        ),
        "approved_packet_digest": None,
        "selection": None,
        "transactions": [],
        "contracts": [],
        "readbacks": None,
    }


def render_packet(package: Package, frozen: Frozen, selection: dict | None, observation: dict | None) -> dict:
    seen = list(package.CREATIONS)
    document = {
        "artifact": f"regents-autolaunch-{package.network}-deployment-packet",
        "version": 1,
        "status": "mainnet-NO-GO",
        "authorization": {
            "state": "not authorized",
            "instrument": "the founder's separate word naming this packet's exact digest",
            "granted_by": None,
            "signing_method": None,
            "note": (
                "Nothing in this repository may be signed, broadcast, funded or deployed until the founder "
                "separately approves this exact digest. The founder sends every transaction by hand from a "
                "signer of his own; no credential appears in this packet or anywhere in this repository."
            ),
        },
        "chain": {"id": package.chain.chain_id, "name": package.chain.alias},
        "build": frozen.manifest["build"],
        "source_identity": source_identity(frozen, package.shared_component),
        "frozen_manifest_sha256": sha256_hex(FROZEN_MANIFEST.read_bytes()),
        "code_identity": [frozen.code_identity(name) for name in seen],
        "hook_permission_bits": frozen.hook_permission_bits(),
        "selection": selection,
        "external_observation": observation,
        "topology": package.topology(selection) if selection else None,
        "selection_note": (
            "Null until `bin/ceremony.py prepare` derives the selection from the founder's inputs and a "
            "human installs the candidate it writes. A completed ceremony moves the deployer past its "
            "starting nonce, so an installed selection is single-use."
        ),
        "digest": {
            "algorithm": "sha256",
            "over": "this document rendered with digest.value set to null, json.dumps(indent=2, sort_keys=True)",
            "value": None,
        },
    }
    document["digest"]["value"] = digest_of(document)
    return document


def installed_packet(package: Package) -> dict | None:
    path = DEPLOYMENTS / package.network / PACKET_NAME
    return load_json(path) if path.exists() else None


def installed_manifest(package: Package) -> dict:
    return load_json(DEPLOYMENTS / package.network / MANIFEST_NAME)


def require_selection(package: Package) -> tuple[dict, dict, dict]:
    packet = installed_packet(package)
    if not packet or not packet.get("selection"):
        raise CeremonyError(f"no selection is installed in deployments/{package.network}/{PACKET_NAME}; run prepare first and install its candidate")
    return packet, packet["selection"], packet["external_observation"]


def compare_bytes(rendered: dict, installed: dict | None, label: str) -> None:
    rendered_text = freeze.render(rendered)
    candidate = write_candidate(PACKET_NAME, rendered)
    if installed is None:
        print(f"no packet is installed; candidate written to {candidate}")
        return
    if freeze.render(installed) != rendered_text:
        raise CeremonyError(f"{label}: the installed packet differs from the rendered candidate at {candidate}")
    print(f"{label}: the installed packet renders byte for byte; digest {rendered['digest']['value']}")


def verify_hermetic_suite() -> None:
    results = forge_test(CEREMONY_CONTRACT, None, forge_env(offline=True))
    print(f"hermetic ceremony suite: {len(results)} tests passed under the deployment profile, offline")


def verify_selection_rederives(package: Package, selection: dict) -> None:
    env = forge_env(offline=True, extra=package.selection_environment(selection, selection["hook_salt"]))
    logs = selection_logs("test_SelectionMatchesTheCommittedValues", env)
    rederived = package.selection_from_logs(selection, logs)
    for name in package.predicted_names():
        if rederived["predicted_addresses"][name] != selection["predicted_addresses"][name]:
            raise CeremonyError(f"predicted {name} re-derives to {rederived['predicted_addresses'][name]}, not the committed {selection['predicted_addresses'][name]}")
    if rederived["hook_salt"].lower() != selection["hook_salt"].lower():
        raise CeremonyError("the committed hook salt did not round-trip")
    print("selection: every predicted address re-derives from the committed values exactly")


def verify_manifest_shape(package: Package, packet: dict | None) -> None:
    path = DEPLOYMENTS / package.network / MANIFEST_NAME
    if not path.exists():
        candidate = write_candidate(MANIFEST_NAME, empty_manifest(package))
        raise CeremonyError(f"{path} is absent; the empty record was written to {candidate} for a human to install")
    manifest = load_json(path)
    if manifest == empty_manifest(package):
        print("deployed manifest: the empty record, carrying no address, no hash and no number")
        return
    if manifest.get("status") != "deployed" or not packet:
        raise CeremonyError("the deployed manifest is neither the empty record nor a deployed record")
    if manifest["approved_packet_digest"] != packet["digest"]["value"]:
        raise CeremonyError("the deployed manifest names a packet digest other than the installed packet's")
    if manifest["selection"] != packet["selection"]:
        raise CeremonyError("the deployed manifest's selection differs from the installed packet's")
    print(f"deployed manifest: a deployed record for packet digest {manifest['approved_packet_digest']}")


# =============================================================================
# Modes
# =============================================================================


def mode_render(package: Package, frozen: Frozen, args: argparse.Namespace) -> int:
    os.environ.pop(package.chain.env_name, None)
    if isinstance(package, Robinhood):
        os.environ.pop(package.base.env_name, None)
    print("offline: no endpoint variable survives into this run")
    verify_hermetic_suite()
    packet = installed_packet(package)
    selection = packet.get("selection") if packet else None
    observation = packet.get("external_observation") if packet else None
    if selection:
        verify_selection_rederives(package, selection)
    compare_bytes(render_packet(package, frozen, selection, observation), packet, "render")
    verify_manifest_shape(package, packet)
    print("CEREMONY RENDER PASS: mainnet-NO-GO, not authorized")
    return 0


def mode_prepare(package: Package, frozen: Frozen, args: argparse.Namespace) -> int:
    deployer = checksum(args.deployer)
    inputs = package.inputs_from_arguments(args)
    package.chain.probe()
    nonce = package.chain.nonce(deployer)
    print(f"deployer {deployer} is at nonce {nonce} on {package.chain.alias}")
    if isinstance(package, Robinhood):
        package.base.probe()
        base_nonce = package.base.nonce(deployer)
        print(f"deployer {deployer} is at nonce {base_nonce} on base")
        inputs["base_receiver"] = package.base_receiver_selection(deployer, base_nonce, inputs.pop("base_safe"))
    seed = {"deployer": deployer, "starting_nonce": nonce, **inputs}
    env = forge_env(offline=True, extra=package.selection_environment(seed, None))
    logs = selection_logs("test_SelectionPrepareCandidate", env)
    selection = package.selection_from_logs(inputs, logs)
    if selection["deployer"] != deployer or selection["starting_nonce"] != nonce:
        raise CeremonyError("the selection suite did not derive from the selected deployer and its live nonce")
    print(f"hook salt mined: {selection['hook_salt']}")
    for name in package.predicted_names():
        print(f"predicted {name}: {selection['predicted_addresses'][name]}")
    observation = package.observe(selection)
    print(f"external state observed at block {observation['observed_at_block']}")
    verify_hermetic_suite()
    candidate = write_candidate(PACKET_NAME, render_packet(package, frozen, selection, observation))
    print(f"packet candidate written to {candidate}; review it, install it at deployments/{package.network}/{PACKET_NAME} and commit on the founder's word")
    print("CEREMONY PREPARE PASS: mainnet-NO-GO, not authorized")
    return 0


def mode_rehearse(package: Package, frozen: Frozen, args: argparse.Namespace) -> int:
    packet, selection, committed = require_selection(package)
    compare_bytes(render_packet(package, frozen, selection, committed), packet, "rehearse")
    package.chain.probe()
    if isinstance(package, Robinhood):
        package.base.probe()
    nonce = package.chain.nonce(selection["deployer"])
    if nonce != selection["starting_nonce"]:
        raise CeremonyError(f"the deployer is at nonce {nonce} on {package.chain.alias}, not the committed {selection['starting_nonce']}; the packet is terminal")
    if isinstance(package, Robinhood):
        base_nonce = package.base.nonce(selection["deployer"])
        if base_nonce != selection["base_receiver"]["starting_nonce"]:
            raise CeremonyError(f"the deployer is at nonce {base_nonce} on base, not the committed {selection['base_receiver']['starting_nonce']}; the packet is terminal")
    observed = package.observe(selection)
    problems: list[str] = []
    package.compare_observation(committed, observed, problems)
    if problems:
        raise CeremonyError("external state moved since the packet was prepared:\n  " + "\n  ".join(problems))
    print("external observation: every committed fact matches the live chain exactly")
    verify_selection_rederives(package, selection)
    for chain, command, env in package.rehearsals(selection):
        chain.endpoint()
        run(command, env=forge_env(offline=False, extra=env))
        print(f"{command[2]}: simulated cleanly against {chain.alias} with no signer; nothing was broadcast")
    print("CEREMONY REHEARSE PASS: mainnet-NO-GO, not authorized")
    return 0


def mode_record(package: Package, frozen: Frozen, args: argparse.Namespace) -> int:
    packet, selection, _ = require_selection(package)
    if args.approved_digest != packet["digest"]["value"]:
        raise CeremonyError("the approved digest passed does not name the installed packet")
    receipts = load_json(Path(args.receipts))
    hashes = receipts.get("transactions")
    plan = package.transaction_plan(selection)
    if not isinstance(hashes, list) or len(hashes) != len(plan):
        raise CeremonyError(f"{args.receipts} must list exactly {len(plan)} transaction hashes in ceremony order")
    package.chain.probe()
    if isinstance(package, Robinhood):
        package.base.probe()

    artifacts = frozen_artifacts(frozen)
    links = package.link_addresses(selection)
    problems: list[str] = []
    transactions = []
    contracts = []
    for index, ((chain, contract, predicted), tx_hash) in enumerate(zip(plan, hashes)):
        if not HASH32_RE.match(tx_hash):
            raise CeremonyError(f"transaction {index} is not a 32-byte hash: {tx_hash}")
        receipt = chain.receipt(tx_hash)
        transaction = chain.transaction(tx_hash)
        created = receipt.get("contractAddress")
        expected_nonce = selection["starting_nonce"] + index if chain is package.chain else selection["base_receiver"]["starting_nonce"]
        facts = {
            "status": quantity(receipt.get("status", "0x0")) == 1,
            "from": same_address(receipt["from"], selection["deployer"]),
            "to": receipt.get("to") in (None, ""),
            "nonce": quantity(transaction["nonce"]) == expected_nonce,
            "created": bool(created) and same_address(created, predicted),
        }
        for fact, ok in facts.items():
            if not ok:
                problems.append(f"transaction {index} ({contract}): {fact} does not match the packet")
        block = quantity(receipt["blockNumber"])
        transactions.append({"index": index, "chain_id": chain.chain_id, "hash": tx_hash, "block_number": block,
                             "nonce": quantity(transaction["nonce"]), "contract": contract, "address": predicted})
        contracts.append(verify_code(chain, frozen, artifacts, links, contract, predicted, block, "deployer", problems))
    for chain, contract, predicted, created_by in package.internal_plan(selection):
        creator_index = next(i for i, (c, name, _) in enumerate(plan) if name.endswith("LaunchpadV1") and c is chain)
        block = transactions[creator_index]["block_number"]
        contracts.append(verify_code(chain, frozen, artifacts, links, contract, predicted, block, created_by, problems))
    readbacks = package.readbacks(selection, problems)
    admissions = None
    if isinstance(package, Stocks):
        admissions = [{**a, "route": selection["predicted_addresses"]["routes"][i]}
                      for i, a in enumerate(packet["external_observation"]["admissions"])]
    if problems:
        raise CeremonyError("the receipts do not record the committed ceremony:\n  " + "\n  ".join(problems))
    manifest = {
        **empty_manifest(package),
        "status": "deployed",
        "approved_packet_digest": packet["digest"]["value"],
        "selection": selection,
        "external": selection.get("external"),
        "admissions": admissions,
        "transactions": transactions,
        "contracts": contracts,
        "readbacks": readbacks,
    }
    if admissions is None:
        manifest.pop("admissions")
    if manifest["external"] is None:
        manifest.pop("external")
    candidate = write_candidate(MANIFEST_NAME, manifest)
    print(f"every receipt matches the packet; deployed-manifest candidate written to {candidate}")
    print(f"install it at deployments/{package.network}/{MANIFEST_NAME} and commit on the founder's word")
    return 0


CONTRACT_KEYS = {
    "StocksLaunchpadV1": "launchpad", "StocksFeeHookV1": "hook", "MemestockLPLocker": "locker",
    "MemestockSplitterV1": "splitter_implementation", "StockBidAdapterV1": "bid_adapter", "AerodromeStockRouteV1": "route",
    "UERC20Factory": "uerc20_factory", "RobinhoodProtocolRevenueInboxV1": "inbox", "RobinhoodPositionsLib": "positions_lib",
    "RobinhoodFeeHookFactory": "hook_factory", "RobinhoodStocksLaunchpadV1": "launchpad", "RobinhoodStockBidAdapterV1": "bid_adapter",
    "RobinhoodFeeHookV1": "hook", "RobinhoodMemestockSplitterV1": "splitter_implementation", "RobinhoodBaseRevenueReceiverV1": "base_receiver",
}


def frozen_artifacts(frozen: Frozen) -> dict[str, dict]:
    """The default-profile build, proved to be the frozen one object by object."""
    run(["forge", "build"], env=dict(os.environ, FOUNDRY_PROFILE="default", FOUNDRY_OFFLINE="true", FOUNDRY_LINT_LINT_ON_BUILD="false"))
    artifacts = freeze.load_artifacts(Path("out"))
    by_name: dict[str, dict] = {}
    for key, artifact in artifacts.items():
        by_name.setdefault(key.rpartition(":")[2], []).append(artifact)
    found: dict[str, dict] = {}
    for name, record in frozen.manifest["contracts"].items():
        matches = [a for a in by_name.get(name, []) if sha256_hex(freeze.code_object(a, "deployedBytecode").encode()) == record["runtime_object_sha256"]]
        if len(matches) != 1:
            raise CeremonyError(f"the build does not carry exactly one artifact whose runtime object is the frozen {name}")
        found[name] = matches[0]
    return found


def verify_code(chain: Chain, frozen: Frozen, artifacts: dict, links: dict[str, str], contract: str,
                address: str, block: int, created_by: str, problems: list[str]) -> dict:
    record = frozen.contract(contract)
    artifact = artifacts[contract]
    onchain = chain.code(address)
    codehash = freeze.keccak256(onchain)
    entry = {"contract": contract, "contract_key": CONTRACT_KEYS[contract], "chain_id": chain.chain_id, "address": address,
             "created_by": created_by, "block_number": block, "codehash": codehash, "runtime_bytes": len(onchain)}
    if len(onchain) == 0:
        problems.append(f"{contract} at {address} has no code")
        return entry
    if record["runtime_keccak256_is_deployed_codehash"]:
        entry["verification"] = "codehash equals the frozen runtime keccak256"
        if codehash != record["runtime_keccak256"].lower():
            problems.append(f"{contract} at {address}: codehash {codehash} is not the frozen {record['runtime_keccak256']}")
        return entry
    compiled = freeze.code_object(artifact, "deployedBytecode")
    for _, libraries in (artifact["deployedBytecode"].get("linkReferences") or {}).items():
        for library, positions in libraries.items():
            for position in positions:
                start = position["start"] * 2
                compiled = compiled[:start] + links[library].lower().removeprefix("0x") + compiled[start + 40:]
    compiled_bytes = bytearray(bytes.fromhex(compiled))
    masked = bytearray(onchain)
    for references in (artifact["deployedBytecode"].get("immutableReferences") or {}).values():
        for reference in references:
            start, length = reference["start"], reference["length"]
            compiled_bytes[start:start + length] = b"\0" * length
            masked[start:start + length] = b"\0" * length
    entry["verification"] = "deployed code equals the frozen runtime with immutables masked and libraries linked"
    if bytes(compiled_bytes) != bytes(masked):
        problems.append(f"{contract} at {address}: deployed code differs from the frozen runtime outside its immutables")
    return entry


def mode_site_config(package: Package, frozen: Frozen, args: argparse.Namespace) -> int:
    manifest = installed_manifest(package)
    if manifest.get("status") != "deployed":
        raise CeremonyError("no deployed manifest is installed; the site-config is rendered from confirmed receipts only")
    builds: dict[str, dict] = {}
    abis = {}
    for key, (out, target) in package.abi_artifacts().items():
        if out not in builds:
            builds[out] = freeze.load_artifacts(Path(out))
        try:
            abis[key] = builds[out][target]["abi"]
        except KeyError:
            raise CeremonyError(f"{out} carries no artifact {target}; run forge build there first")
    document = package.site_config(manifest, args, abis)
    candidate = write_candidate(SITE_CONFIG_NAME, document)
    print(f"site-config written to {candidate}; it carries the endpoints you passed and is never committed")
    return 0


# =============================================================================


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    modes = parser.add_subparsers(dest="mode", required=True)
    frozen = Frozen()
    try:
        package = PACKAGES[frozen.component](frozen)
    except KeyError:
        raise CeremonyError(f"{frozen.component} has no ceremony profile")
    modes.add_parser("render")
    prepare = modes.add_parser("prepare")
    prepare.add_argument("--deployer", required=True, help="the founder-selected deployer; its live nonce becomes the starting nonce")
    package.add_prepare_arguments(prepare)
    modes.add_parser("rehearse")
    record = modes.add_parser("record")
    record.add_argument("--receipts", required=True, help="a JSON file {\"transactions\": [hash, ...]} in ceremony order")
    record.add_argument("--approved-digest", required=True, help="the packet digest the founder approved")
    site = modes.add_parser("site-config")
    package.add_site_config_arguments(site)
    args = parser.parse_args()

    refuse_signing_authority()
    return {
        "render": mode_render,
        "prepare": mode_prepare,
        "rehearse": mode_rehearse,
        "record": mode_record,
        "site-config": mode_site_config,
    }[args.mode](package, frozen, args)


if __name__ == "__main__":
    sys.exit(main())
