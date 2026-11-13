#!/usr/bin/env python3
"""The deployment ceremony tool for an Autolaunch version 3 contracts package (Base Revstake
`contracts/revstake-v3`, Base Memestake `contracts/stocks-v3`), run from the package directory. A
version 3 package builds on version 2's deployment: its inputs are read from version 2's committed
deployed manifest, and what it reuses is observed on the chain, never created again.

The package's production script (`script/Deploy*.s.sol`) consumes ceremony values and creates the
graph; it has no filesystem permission and writes nothing. This tool is the other half: it turns the
frozen release surface and the founder's selection into one deterministic packet, checks the live
external state the constructors depend on, rehearses the exact creations unsigned, verifies confirmed
receipts into the deployed manifest, and renders the website's production site-config. Every value
it handles is public; no key, keystore path or endpoint is read here, and the provider endpoint it
consumes from the environment is never printed or written.

Modes:

  render      Offline. Runs the hermetic ceremony suite under the `deployment` profile. While the
              deployed manifest is the empty record, re-derives the committed selection (when one
              is installed) through the selection suite, renders the packet candidate from the
              frozen manifest and compares it byte for byte with
              `deployments/<network>/mainnet-no-go-packet.json`. Once the manifest is a deployed
              record the chain is the authority: the installed packet is proved from its own
              content (its digest recomputes, the source tree it names exists in the repository)
              and the manifest names it; nothing is re-derived from HEAD. Reaches no network.
  prepare     Reads the selected deployer's nonce, the head block, every binding's code hash and
              the control surface through `cast` (read-only), mines the hook salt offline through
              the selection suite, and writes a packet candidate carrying the selection and the
              external observation to reports/generated/deployment/. A human installs it.
  rehearse    Re-observes the committed external state and compares it exactly, proves the deployer
              nonce still equals the committed one, and simulates the ceremony against the live
              chain with no signer and no broadcast. It simulates the exact creation transactions
              in sequence on the node itself (`eth_simulateV1`), because Base's stock tokens carry
              a one-byte `0xef` code that only a Base node executes, each offered the gas limit of
              the latest block, read off the node at that run, and writes those transactions to
              reports/generated/deployment/ for the founder to send. Base Memestake also simulates
              the Safe's admissions afterwards and writes them as an unsigned Safe batch.
  preflight   Run right before sending creation N (counting from 0): proves the installed packet is
              the committed one, that the deployer's confirmed and pending nonces both equal that
              creation's nonce, and that its predicted address holds no code yet. Sends nothing.
  record      Verifies the founder's confirmed transaction hashes against the committed packet
              (sender, nonce, order, created address, status, code identity, and the readbacks at
              the last creation's block, before the Safe's switch-on) and writes a deployed-manifest
              candidate to reports/generated/deployment/. A human installs it. Its `cast --json`
              reads take Foundry 1.5.1's plain answers.
  site-config Renders the production site-config from the installed deployed manifest, the frozen
              ABIs, the server endpoint injected under `REGENT_BASE_RPC_URL` and the
              `--public-rpc-url` the founder passes, to reports/generated/deployment/, with a
              section per earlier version (Revstake `v2`, Memestake `v1` and `v2`) from that
              version's committed deployed manifest and ABIs, for the launches made on it. It
              names no stocks: the site reads the stocks a launchpad admits from the chain.

Endpoints come from the environment only (`REGENT_BASE_RPC_URL`), matching the `[rpc_endpoints]`
alias in `foundry.toml`, so a private one never appears on a command line; site-config reads no
chain and only writes that endpoint into the document, as the server's `rpc_url`. A diagnostic
that would echo an endpoint is redacted before it is shown.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
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
REHEARSED_TRANSACTIONS_NAME = "rehearsed-transactions.json"
SAFE_BATCH_NAME = "safe-batch.json"
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


def run(args: list[str], env: dict | None = None, stdin: str | None = None) -> str:
    result = subprocess.run(args, capture_output=True, text=True, env=env, input=stdin)
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
        """What `--rpc-url` receives: the foundry.toml alias, so the injected address never appears
        on a command line or in the process list."""
        self.injected()
        return self.alias

    def injected(self) -> str:
        """The endpoint injected under `env_name` itself, which is never printed."""
        value = os.environ.get(self.env_name, "")
        if not value:
            raise CeremonyError(f"no read-only endpoint is injected under {self.env_name}")
        if not re.match(r"^(https?|wss?)://.+", value):
            raise CeremonyError(f"the value under {self.env_name} is not an http(s) or ws(s) endpoint; its value is never printed")
        return value

    def cast(self, *args: str) -> str:
        return run(["cast", *args, "--rpc-url", self.endpoint()]).strip()

    def rpc(self, method: str, params: list):
        """One raw JSON-RPC request; the parameters travel on stdin, never on the command line."""
        return json.loads(run(["cast", "rpc", method, "--raw", "--rpc-url", self.endpoint()], stdin=json.dumps(params)))

    def probe(self) -> None:
        found = int(self.cast("chain-id"))
        if found != self.chain_id:
            raise CeremonyError(f"the endpoint under {self.env_name} serves chain {found}, not {self.chain_id}")
        print(f"{self.alias}: a read-only endpoint is injected under {self.env_name}; chain id {self.chain_id} confirmed")

    def nonce(self, account: str) -> int:
        """The account's next nonce, read at the latest block and with the pending pool; a transaction
        still waiting means the next free nonce is not settled yet, so the two reads must agree."""
        confirmed = int(self.rpc("eth_getTransactionCount", [account, "latest"]), 16)
        pending = int(self.rpc("eth_getTransactionCount", [account, "pending"]), 16)
        if pending != confirmed:
            raise CeremonyError(f"{account} has a transaction waiting on {self.alias}: confirmed nonce {confirmed}, "
                                f"pending nonce {pending}; let it land or replace it before any ceremony step")
        return confirmed

    def block_number(self) -> int:
        return int(self.cast("block-number"))

    def code(self, account: str) -> bytes:
        return bytes.fromhex(self.cast("code", account).removeprefix("0x"))

    def codehash(self, account: str) -> str:
        return freeze.keccak256(self.code(account))

    def call(self, to: str, signature: str, *arguments: str, block: int | str = "latest") -> str:
        return self.cast("call", "--block", str(block), to, signature, *arguments)

    def call_address(self, to: str, signature: str, *arguments: str, block: int | str = "latest") -> str:
        found = ADDRESS_RE.findall(self.call(to, signature, *arguments, block=block))
        if len(found) != 1:
            raise CeremonyError(f"{signature} on {to} did not return one address")
        return checksum(found[0])

    def call_addresses(self, to: str, signature: str) -> list[str]:
        return [checksum(a) for a in ADDRESS_RE.findall(self.call(to, signature))]

    def call_uint(self, to: str, signature: str, *arguments: str) -> int:
        return int(self.call(to, signature, *arguments).split()[0])

    def call_bool(self, to: str, signature: str, block: int | str = "latest") -> bool:
        value = self.call(to, signature, block=block)
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


def source_identity(frozen: Frozen) -> dict:
    top = git("rev-parse", "--show-toplevel")
    cwd = Path.cwd().resolve()
    if cwd != (Path(top) / frozen.component).resolve():
        raise CeremonyError(f"run from {frozen.component}; the current directory is {cwd}")
    return {"src_tree": git("rev-parse", f"HEAD:{frozen.component}/src")}


# =============================================================================
# Package profiles
# =============================================================================


class Package:
    """What differs between the two ceremonies, stated once per package."""

    CREATIONS: tuple[str, ...]
    PREDICTED: tuple[str, ...]
    # The founder-sent creation whose constructor makes the internal creations.
    constructor_creator: str
    component: str
    network: str
    chain: Chain
    hook_salt_env = "REGENT_DEPLOYMENT_HOOK_SALT"
    deployer_env = "REGENT_DEPLOYMENT_DEPLOYER"
    starting_nonce_env = "REGENT_DEPLOYMENT_STARTING_NONCE"

    def __init__(self, frozen: Frozen) -> None:
        self.frozen = frozen

    # --- selection ---------------------------------------------------------------------------

    def version_two_inputs(self) -> dict:
        raise NotImplementedError

    def selection_environment(self, selection: dict, salt: str | None) -> dict:
        raise NotImplementedError

    def selection_from_logs(self, inputs: dict, logs: dict[str, str]) -> dict:
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

    def rehearse(self, packet: dict) -> None:
        """Simulates the exact creation transactions, in order and at their nonces, on the chain's
        own node (`eth_simulateV1`), then the wiring readbacks against the simulated state, and
        writes the transactions out. forge cannot run the Base Memestake rehearsal, whose Safe
        admissions read stock tokens carrying a one-byte `0xef` code only a Base node executes,
        and Revstake shares the one path.

        Each creation is offered the latest block's gas limit, read off the node at this run, and
        sits in its own simulated block, since one block's transactions share that limit. A
        creation that needs more gas than one Base block holds fails the rehearsal. The calls the
        Governance and Regent Safe makes afterwards, when the package has any, are simulated from
        the Safe after the readbacks and written out as a Safe batch."""
        selection = packet["selection"]
        artifacts = frozen_artifacts(self.frozen)
        transactions = []
        for entry in self.topology(selection)[0]["creation_order"]:
            contract = entry["contract"]
            record = self.frozen.contract(contract)
            creation = bytes.fromhex(freeze.code_object(artifacts[contract], "bytecode"))
            if freeze.keccak256(creation) != record["creation_keccak256"].lower():
                raise CeremonyError(f"the build's {contract} creation code is not the frozen one")
            types = ",".join(parameter.split()[0] for parameter in record["constructor"])
            names = [parameter.split()[1] for parameter in record["constructor"]]
            arguments = run(["cast", "abi-encode", f"constructor({types})",
                             *(str(entry["constructor_arguments"][name]) for name in names)]).strip()
            transactions.append({"index": entry["index"], "nonce": entry["deployer_nonce"], "contract": contract,
                                 "address": entry["address"], "data": "0x" + creation.hex() + arguments.removeprefix("0x")})

        head = self.chain.rpc("eth_getBlockByNumber", ["latest", False])
        head_number, gas_limit = quantity(head["number"]), quantity(head["gasLimit"])
        print(f"{self.chain.alias}: block {head_number} carries a gas limit of {gas_limit}; each creation is offered all of it")
        fee = hex(2 * quantity(head["baseFeePerGas"]))
        creations = [{"calls": [{"from": selection["deployer"], "nonce": hex(t["nonce"]), "data": t["data"],
                                 "gas": hex(gas_limit), "maxFeePerGas": fee, "maxPriorityFeePerGas": "0x0"}]}
                     for t in transactions]
        plan = self.readback_plan(selection)
        readbacks = [{"to": to, "data": freeze.keccak256(signature.partition(")")[0].encode() + b")")[:10],
                      "maxFeePerGas": "0x0", "maxPriorityFeePerGas": "0x0"} for _, to, signature, _ in plan]
        governance = self.governance_plan(packet)
        safe = self.frozen.binding("GOVERNANCE_AND_REGENT_SAFE")
        free = {"blockOverrides": {"baseFeePerGas": "0x0"}}
        governance_blocks = [
            {**free, "calls": [{"from": safe, "to": c["to"], "data": c["data"], "maxFeePerGas": "0x0",
                                "maxPriorityFeePerGas": "0x0"} for c in governance]},
            {**free, "calls": [{"to": c["readback"][0], "data": c["readback"][1], "maxFeePerGas": "0x0",
                                "maxPriorityFeePerGas": "0x0"} for c in governance]},
        ] if governance else []
        blocks = self.chain.rpc("eth_simulateV1", [{
            "blockStateCalls": [*creations, {**free, "calls": readbacks}, *governance_blocks],
            "validation": True,
        }, hex(head_number)])

        problems: list[str] = []
        for transaction, block in zip(transactions, blocks):
            call = block["calls"][0]
            label = f"transaction {transaction['index']} ({transaction['contract']}, nonce {transaction['nonce']})"
            transaction["gas_used"] = quantity(call["gasUsed"])
            if quantity(call["status"]) != 1 and transaction["gas_used"] == gas_limit:
                problems.append(f"{label} needs more gas than the {gas_limit} one Base block holds (read at block {head_number})")
                continue
            if quantity(call["status"]) != 1:
                problems.append(f"{label} reverted: {call.get('error') or call['returnData']}")
                continue
            runtime = bytes.fromhex(call["returnData"].removeprefix("0x"))
            verification, matches = compare_runtime(self.frozen.contract(transaction["contract"]),
                                                    artifacts[transaction["contract"]], runtime)
            if not matches:
                problems.append(f"{label}: the created code does not match ({verification})")
        for (key, _, signature, wanted), call in zip(plan, blocks[len(transactions)]["calls"]):
            word = call["returnData"].removeprefix("0x")
            if quantity(call["status"]) != 1 or len(word) != 64:
                problems.append(f"readback {key} did not answer one word")
                continue
            found = int(word, 16) == 1 if signature.endswith("(bool)") else checksum(word[24:])
            if found != wanted:
                problems.append(f"readback {key}: expected {wanted}, found {found}")
        if governance:
            calls, answers = blocks[len(transactions) + 1]["calls"], blocks[len(transactions) + 2]["calls"]
            for entry, call, answer in zip(governance, calls, answers):
                if quantity(call["status"]) != 1:
                    problems.append(f"Safe call {entry['label']} reverted: {call.get('error') or call['returnData']}")
                elif answer["returnData"].lower() != entry["readback"][2].lower():
                    problems.append(f"after Safe call {entry['label']}: expected {entry['readback'][2]}, found {answer['returnData']}")
        if problems:
            raise CeremonyError("the simulated ceremony does not match the packet:\n  " + "\n  ".join(problems))

        document = {
            "artifact": f"regents-autolaunch-{self.network}-rehearsed-transactions",
            "packet_digest": packet["digest"]["value"],
            "chain_id": self.chain.chain_id,
            "deployer": selection["deployer"],
            "simulated_after_block": head_number,
            "block_gas_limit": gas_limit,
            "gas_used_total": sum(t["gas_used"] for t in transactions),
            "transactions": transactions,
        }
        candidate = write_candidate(REHEARSED_TRANSACTIONS_NAME, document)
        for transaction in transactions:
            print(f"transaction {transaction['index']} ({transaction['contract']}) at {transaction['address']}: "
                  f"{transaction['gas_used']} gas of the {gas_limit} block gas limit")
        print(f"{len(transactions)} creations simulated in order on {self.chain.alias} after block {head_number}, "
              f"every created code matches the frozen build and all {len(plan)} readbacks match; "
              f"{document['gas_used_total']} gas; nothing was broadcast")
        print(f"the exact transactions are written to {candidate}")
        if governance:
            batch = safe_batch(self.governance_batch_meta(packet), self.chain.chain_id, safe, governance,
                               quantity(head["timestamp"]))
            batch = write_candidate(SAFE_BATCH_NAME, batch)
            print(f"{len(governance)} Safe calls simulated from {safe} after the ceremony, each with its readback; "
                  f"the unsigned Safe batch is written to {batch} for the Safe's owners; nothing was sent")

    # --- record and site-config --------------------------------------------------------------

    def transaction_plan(self, selection: dict) -> list[tuple[str, str]]:
        """(contract, predicted address) per founder-sent transaction, in order."""
        raise NotImplementedError

    def internal_plan(self, selection: dict) -> list[tuple[str, str, str]]:
        """(contract, predicted address, created_by) per creation inside a constructor."""
        raise NotImplementedError

    def readback_plan(self, selection: dict) -> list[tuple[str, str, str, object]]:
        """(key, contract, view, expected value) for every wiring fact of the deployed graph."""
        raise NotImplementedError

    def governance_plan(self, packet: dict) -> list[dict]:
        """The calls the Governance and Regent Safe makes once the ceremony has landed, each
        {"label", "to", "data", "readback": (to, data, expected return data)}. None by default."""
        return []

    def governance_batch_meta(self, packet: dict) -> dict:
        """The Safe batch's name and description, for a package whose governance plan has calls."""
        raise NotImplementedError

    def readbacks(self, selection: dict, block: int, problems: list[str]) -> dict:
        """The wiring as the ceremony left it: read at the block of its last creation, so a later
        governance call (the Safe opening launches) is not taken for a different ceremony."""
        found = {}
        for key, to, signature, wanted in self.readback_plan(selection):
            read = self.chain.call_bool if signature.endswith("(bool)") else self.chain.call_address
            found[key] = read(to, signature, block=block)
            if found[key] != wanted:
                problems.append(f"readback {key}: expected {wanted}, found {found[key]}")
        return found

    def site_config(self, manifest: dict, args: argparse.Namespace, abis: dict) -> dict:
        raise NotImplementedError

    def add_site_config_arguments(self, parser: argparse.ArgumentParser) -> None:
        parser.add_argument("--public-rpc-url", required=True, help="the endpoint wallets in the browser use")

    def abi_artifacts(self) -> dict[str, str]:
        raise NotImplementedError


def safe_batch(meta: dict, chain_id: int, safe: str, calls: list[dict], created_at: int) -> dict:
    """A Safe Transaction Builder batch, unsigned; `created_at` is the rehearsed block's time."""
    return {
        "version": "1.0",
        "chainId": str(chain_id),
        "createdAt": created_at * 1000,
        "meta": {**meta, "txBuilderVersion": "1.16.5", "createdFromSafeAddress": safe, "createdFromOwnerAddress": ""},
        "transactions": [{"to": c["to"], "value": "0", "data": c["data"], "contractMethod": None,
                          "contractInputsValues": None} for c in calls],
    }


def mined_salt_bits(salt_hex: str) -> None:
    if not HASH32_RE.match(salt_hex):
        raise CeremonyError(f"the mined hook salt is not 32 bytes: {salt_hex}")


def version_two_record(path: Path) -> dict:
    """A version 2 package's committed deployed manifest, which a version 3 ceremony builds on."""
    manifest = load_json(path)
    if manifest.get("status") != "deployed":
        raise CeremonyError(f"{path} is not a deployed record; version 3 builds on version 2's deployment")
    return manifest


def earlier_section(manifest_path: Path, abi_dir: Path, address_keys: tuple[str, ...],
                    abi_contracts: dict[str, str]) -> dict:
    """An earlier version's section of the site-config: the contracts the website keeps reading
    for the launches made on them, from that version's committed deployed manifest and its
    committed ABIs."""
    manifest = load_json(manifest_path)
    if manifest.get("status") != "deployed":
        raise CeremonyError(f"{manifest_path} is not a deployed record")
    deployed = {entry["contract_key"]: entry["address"] for entry in manifest["contracts"]}
    return {
        "addresses": {key: deployed[key].lower() for key in sorted(address_keys)},
        "abis": {key: load_json(abi_dir / f"{contract}.json")["abi"] for key, contract in sorted(abi_contracts.items())},
    }


def abi_word(value: str | int) -> str:
    """One static ABI word: an address, a bool or an unsigned integer."""
    return format(int(value, 16) if isinstance(value, str) else int(value), "064x")


class RevstakeV3(Package):
    """Base Revstake version 3: one founder-sent creation. The factory's constructor checks the
    runtime code hashes of the UERC20 factory and of version 2's deployed escrow, splitter and
    payment receiver implementations, creates the strategy, whose own constructor creates the LP
    locker, and then the hook at its mined salt. Nothing version 2 deployed is created again; the
    bindings, the Safe and the staking contract are observed as in version 2."""

    constructor_creator = "RegentsAutolaunchFactoryV3"
    component = "contracts/revstake-v3"
    network = "base-mainnet"
    chain = Chain("base", "REGENT_BASE_RPC_URL", 8453)
    PREDICTED = ("factory", "strategy", "lp_locker", "hook")
    # (contract, selection key) per version 2 address the factory binds, read from version 2's
    # deployed manifest by contract name.
    REUSED = (("UERC20Factory", "uerc20_factory"), ("ConditionalVestingEscrowV2", "escrow_implementation"),
              ("SubjectSplitterV1", "splitter_implementation"), ("PaymentReceiverV1", "receiver_implementation"))
    VERSION_TWO = Path("../revstake-v2") / DEPLOYMENTS / "base-mainnet" / MANIFEST_NAME
    # Version 2's own contracts, which its launches keep running on: site key and contract.
    VERSION_TWO_OWN = {"factory": "RegentsAutolaunchFactoryV2", "strategy": "RegentLBPStrategyV2",
                       "lp_locker": "RevstakeLPLocker", "hook": "RegentFeeHook"}
    CREATIONS = ("RegentsAutolaunchFactoryV3", "RegentLBPStrategyV3", "RevstakeLPLocker", "RegentFeeHook")
    BINDINGS = ("REGENT", "USDC", "CCA_FACTORY", "POOL_MANAGER", "POSITION_MANAGER", "LIVE_STAKING",
                "GOVERNANCE_AND_REGENT_SAFE")
    # The website drives the one Permit2 the Base Memestake build pins; Revstake binds none of its own.
    PERMIT2_IDENTITY = Path("../stocks-v3") / FROZEN_IDENTITY

    def version_two_inputs(self) -> dict:
        deployed = {entry["contract"]: entry["address"] for entry in version_two_record(self.VERSION_TWO)["contracts"]}
        return {"reused": {key: checksum(deployed[contract]) for contract, key in self.REUSED}}

    def selection_environment(self, selection: dict, salt: str | None) -> dict:
        env = {
            self.deployer_env: selection["deployer"],
            self.starting_nonce_env: str(selection["starting_nonce"]),
            **{f"REGENT_DEPLOYMENT_{key.upper()}": address for key, address in selection["reused"].items()},
        }
        if salt:
            env[self.hook_salt_env] = salt
        return env

    def selection_from_logs(self, inputs: dict, logs: dict[str, str]) -> dict:
        for key, address in inputs["reused"].items():
            if not same_address(logs[key], address):
                raise CeremonyError(f"the selection suite derived from a different {key}: {logs[key]}, not {address}")
        mined_salt_bits(logs["hook_salt"])
        return {
            "deployer": checksum(logs["deployer"]),
            "starting_nonce": int(logs["starting_nonce"]),
            "hook_salt": logs["hook_salt"],
            "predicted_addresses": {name: checksum(logs[f"predicted_{name}"]) for name in self.PREDICTED},
            "reused": inputs["reused"],
        }

    def observe(self, selection: dict) -> dict:
        chain = self.chain
        block = chain.block_number()
        bindings = {}
        for constant in self.BINDINGS:
            address = self.frozen.binding(constant)
            bindings[constant.lower()] = {"address": address, "codehash": chain.codehash(address)}
            if bindings[constant.lower()]["codehash"] == freeze.keccak256(b""):
                raise CeremonyError(f"binding {constant} at {address} has no code on Base")
        reused = {}
        for contract, key in self.REUSED:
            address = selection["reused"][key]
            frozen_hash = self.frozen.contract(contract)["runtime_keccak256"].lower()
            reused[key] = {"address": address, "codehash": chain.codehash(address)}
            if reused[key]["codehash"] != frozen_hash:
                raise CeremonyError(f"version 2's {contract} at {address} does not carry the frozen runtime hash {frozen_hash}")
        safe = self.frozen.binding("GOVERNANCE_AND_REGENT_SAFE")
        staking = self.frozen.binding("LIVE_STAKING")
        return {
            "observed_at_block": block,
            "bindings": bindings,
            "governance_and_regent_safe": chain.safe_surface(safe),
            "live_staking": {
                "owner": chain.call_address(staking, "owner()(address)"),
                "paused": chain.call_bool(staking, "paused()(bool)"),
            },
            "reused": reused,
        }

    def topology(self, selection: dict) -> list[dict]:
        p, r = selection["predicted_addresses"], selection["reused"]
        implementations = {"escrowImplementation_": r["escrow_implementation"],
                           "splitterImplementation_": r["splitter_implementation"],
                           "receiverImplementation_": r["receiver_implementation"]}
        order = [{"index": 0, "contract": "RegentsAutolaunchFactoryV3", "mechanism": "transaction", "created_by": "deployer",
                  "deployer_nonce": selection["starting_nonce"], "address": p["factory"],
                  "constructor_arguments": {"uerc20Factory_": r["uerc20_factory"], **implementations,
                                            "hookSalt": selection["hook_salt"]}}]
        internal = [
            {"contract": "RegentLBPStrategyV3", "mechanism": "CREATE", "created_by": "RegentsAutolaunchFactoryV3 constructor",
             "creator_nonce": 1, "address": p["strategy"], "constructor_arguments": {"factory_": p["factory"], **implementations}},
            {"contract": "RevstakeLPLocker", "mechanism": "CREATE", "created_by": "RegentLBPStrategyV3 constructor",
             "creator_nonce": 1, "address": p["lp_locker"], "constructor_arguments": {"strategy_": p["strategy"]}},
            {"contract": "RegentFeeHook", "mechanism": "CREATE2", "created_by": "RegentsAutolaunchFactoryV3 constructor",
             "salt": selection["hook_salt"], "address": p["hook"],
             "constructor_arguments": {"manager_": self.frozen.binding("POOL_MANAGER"), "strategy_": p["strategy"]}},
        ]
        return [{"chain_id": self.chain.chain_id, "creation_order": order, "internal_creations": internal}]

    def transaction_plan(self, selection: dict) -> list[tuple[str, str]]:
        return [("RegentsAutolaunchFactoryV3", selection["predicted_addresses"]["factory"])]

    def internal_plan(self, selection: dict) -> list[tuple[str, str, str]]:
        p = selection["predicted_addresses"]
        return [
            ("RegentLBPStrategyV3", p["strategy"], "RegentsAutolaunchFactoryV3 constructor"),
            ("RevstakeLPLocker", p["lp_locker"], "RegentLBPStrategyV3 constructor"),
            ("RegentFeeHook", p["hook"], "RegentsAutolaunchFactoryV3 constructor"),
        ]

    def readback_plan(self, selection: dict) -> list[tuple[str, str, str, object]]:
        p = {**selection["predicted_addresses"], **selection["reused"]}
        factory, strategy = p["factory"], p["strategy"]
        return [
            ("factory.uerc20Factory", factory, "uerc20Factory()(address)", p["uerc20_factory"]),
            ("factory.strategy", factory, "strategy()(address)", strategy),
            ("factory.hook", factory, "hook()(address)", p["hook"]),
            ("factory.launchesPaused", factory, "launchesPaused()(bool)", True),
            ("strategy.factory", strategy, "factory()(address)", factory),
            ("strategy.escrowImplementation", strategy, "escrowImplementation()(address)", p["escrow_implementation"]),
            ("strategy.splitterImplementation", strategy, "splitterImplementation()(address)", p["splitter_implementation"]),
            ("strategy.receiverImplementation", strategy, "receiverImplementation()(address)", p["receiver_implementation"]),
            ("strategy.lpLocker", strategy, "lpLocker()(address)", p["lp_locker"]),
            ("strategy.hook", strategy, "hook()(address)", p["hook"]),
            ("lpLocker.strategy", p["lp_locker"], "strategy()(address)", strategy),
            ("hook.strategy", p["hook"], "strategy()(address)", strategy),
        ]

    def abi_artifacts(self) -> dict[str, str]:
        return {
            "auction": "../stocks-v3/lib/continuous-clearing-auction/src/ContinuousClearingAuction.sol:ContinuousClearingAuction",
            "escrow": "src/escrow/ConditionalVestingEscrowV2.sol:ConditionalVestingEscrowV2",
            "factory": "src/factory/RegentsAutolaunchFactoryV3.sol:RegentsAutolaunchFactoryV3",
            "hook": "src/hook/RegentFeeHook.sol:RegentFeeHook",
            "lp_locker": "src/revenue/RevstakeLPLocker.sol:RevstakeLPLocker",
            "permit2": "../stocks-v3/lib/permit2/src/interfaces/IAllowanceTransfer.sol:IAllowanceTransfer",
            "receiver": "src/revenue/PaymentReceiverV1.sol:PaymentReceiverV1",
            "splitter": "src/revenue/SubjectSplitterV1.sol:SubjectSplitterV1",
            "strategy": "src/strategy/RegentLBPStrategyV3.sol:RegentLBPStrategyV3",
            "token": "../stocks-v3/lib/uerc20-factory/src/tokens/UERC20.sol:UERC20",
        }

    def site_config(self, manifest: dict, args: argparse.Namespace, abis: dict) -> dict:
        """Revstake launches are found by the factory's `nextLaunchId`, so no start block is written.
        The `v2` section names version 2's factory, strategy, LP locker and hook, which the website
        keeps reading for the launches made on them."""
        addresses = {
            **{entry["contract_key"]: entry["address"] for entry in manifest["contracts"]},
            **manifest["selection"]["reused"],
            "regent": self.frozen.binding("REGENT"),
            "cca_factory": self.frozen.binding("CCA_FACTORY"),
            "pool_manager": self.frozen.binding("POOL_MANAGER"),
            "position_manager": self.frozen.binding("POSITION_MANAGER"),
            "governance_safe": self.frozen.binding("GOVERNANCE_AND_REGENT_SAFE"),
            "permit2": self.frozen.binding("PERMIT2", self.PERMIT2_IDENTITY),
        }
        return {
            "chain_id": self.chain.chain_id,
            "rpc_url": self.chain.injected(),
            "public_rpc_url": args.public_rpc_url,
            "addresses": {key: addresses[key].lower() for key in sorted(addresses)},
            "abis": abis,
            "v2": earlier_section(self.VERSION_TWO, Path("../revstake-v2/abi"), tuple(self.VERSION_TWO_OWN),
                                  self.VERSION_TWO_OWN),
        }


class StocksV3(Package):
    """Base Memestake version 3: two founder-sent creations, the launchpad and the bid adapter bound
    to it. The launchpad's constructor creates the splitter implementation, the LP locker and the
    hook at its mined salt. No route is created: after the ceremony the Governance and Regent Safe
    admits each stock with the route version 2 deployed for it, one `admitStock(stock, route)` per
    stock, from a Safe batch the rehearsal simulates and writes out."""

    constructor_creator = "StocksLaunchpadV3"
    component = "contracts/stocks-v3"
    network = "base-mainnet"
    chain = Chain("base", "REGENT_BASE_RPC_URL", 8453)
    PREDICTED = ("launchpad", "splitter_implementation", "locker", "hook", "bid_adapter")
    CREATIONS = ("StocksLaunchpadV3", "StockBidAdapterV1", "MemestockSplitterV1", "MemestockLPLocker", "StocksFeeHookV1")
    BINDINGS = ("REGENT", "USDC", "CCA_FACTORY", "POOL_MANAGER", "POSITION_MANAGER", "LIVE_STAKING",
                "GOVERNANCE_AND_REGENT_SAFE", "PERMIT2")
    VERSION_TWO = Path("../stocks-v2") / DEPLOYMENTS / "base-mainnet" / MANIFEST_NAME
    # The earlier launchpads, which their launches keep running on: the site-config section, the
    # package, and the contracts of each whose ABIs the website reads. Each section also names the
    # bid adapter its USDC bids went through.
    EARLIER = (("v1", Path("../stocks"), {"launchpad": "StocksLaunchpadV1", "hook": "StocksFeeHookV1",
                                          "locker": "MemestockLPLocker"}),
               ("v2", Path("../stocks-v2"), {"launchpad": "StocksLaunchpadV2", "hook": "StocksFeeHookV1",
                                             "locker": "MemestockLPLocker"}))

    def version_two_inputs(self) -> dict:
        """The UERC20 factory version 2's launchpad binds and the stocks it admits with their routes."""
        manifest = version_two_record(self.VERSION_TWO)
        return {
            "uerc20_factory": checksum(manifest["selection"]["uerc20_factory"]),
            "admissions": [{"symbol": a["symbol"], "stock": checksum(a["stock"]), "route": checksum(a["route"])}
                           for a in manifest["admissions"]],
        }

    def selection_environment(self, selection: dict, salt: str | None) -> dict:
        env = {
            self.deployer_env: selection["deployer"],
            self.starting_nonce_env: str(selection["starting_nonce"]),
            "REGENT_DEPLOYMENT_UERC20_FACTORY": selection["uerc20_factory"],
        }
        if salt:
            env[self.hook_salt_env] = salt
        return env

    def selection_from_logs(self, inputs: dict, logs: dict[str, str]) -> dict:
        mined_salt_bits(logs["hook_salt"])
        if not same_address(logs["uerc20_factory"], inputs["uerc20_factory"]):
            raise CeremonyError("the selection suite derived from a different UERC20 factory")
        return {
            "deployer": checksum(logs["deployer"]),
            "starting_nonce": int(logs["starting_nonce"]),
            "hook_salt": logs["hook_salt"],
            "uerc20_factory": inputs["uerc20_factory"],
            "admissions": inputs["admissions"],
            "predicted_addresses": {name: checksum(logs[f"predicted_{name}"]) for name in self.PREDICTED},
        }

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
            stock, route = admission["stock"], admission["route"]
            if not same_address(chain.call_address(route, "stock()(address)"), stock):
                raise CeremonyError(f"version 2's route {route} for {admission['symbol']} is not bound to {stock}")
            if not same_address(chain.call_address(route, "usdc()(address)"), usdc):
                raise CeremonyError(f"version 2's route {route} for {admission['symbol']} is not bound to USDC")
            admissions.append({
                "stock": stock,
                "symbol": chain.call_string(stock, "symbol()(string)"),
                "decimals": chain.call_uint(stock, "decimals()(uint8)"),
                "stock_codehash": chain.codehash(stock),
                "route": route,
                "route_codehash": chain.codehash(route),
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
            {"index": 0, "contract": "StocksLaunchpadV3", "mechanism": "transaction", "created_by": "deployer",
             "deployer_nonce": nonce, "address": predicted["launchpad"],
             "constructor_arguments": {"uerc20Factory_": selection["uerc20_factory"], "hookSalt": selection["hook_salt"]}},
            {"index": 1, "contract": "StockBidAdapterV1", "mechanism": "transaction", "created_by": "deployer",
             "deployer_nonce": nonce + 1, "address": predicted["bid_adapter"],
             "constructor_arguments": {"launchpad_": predicted["launchpad"]}},
        ]
        internal = [
            {"contract": "MemestockSplitterV1", "mechanism": "CREATE", "created_by": "StocksLaunchpadV3 constructor",
             "creator_nonce": 1, "address": predicted["splitter_implementation"]},
            {"contract": "MemestockLPLocker", "mechanism": "CREATE", "created_by": "StocksLaunchpadV3 constructor",
             "creator_nonce": 2, "address": predicted["locker"]},
            {"contract": "StocksFeeHookV1", "mechanism": "CREATE2", "created_by": "StocksLaunchpadV3 constructor",
             "salt": selection["hook_salt"], "address": predicted["hook"],
             "constructor_arguments": {"manager_": self.frozen.binding("POOL_MANAGER"), "launchpad_": predicted["launchpad"]}},
        ]
        return [{"chain_id": self.chain.chain_id, "creation_order": order, "internal_creations": internal}]

    def transaction_plan(self, selection: dict) -> list[tuple[str, str]]:
        predicted = selection["predicted_addresses"]
        return [("StocksLaunchpadV3", predicted["launchpad"]), ("StockBidAdapterV1", predicted["bid_adapter"])]

    def internal_plan(self, selection: dict) -> list[tuple[str, str, str]]:
        predicted = selection["predicted_addresses"]
        return [
            ("MemestockSplitterV1", predicted["splitter_implementation"], "StocksLaunchpadV3 constructor"),
            ("MemestockLPLocker", predicted["locker"], "StocksLaunchpadV3 constructor"),
            ("StocksFeeHookV1", predicted["hook"], "StocksLaunchpadV3 constructor"),
        ]

    def readback_plan(self, selection: dict) -> list[tuple[str, str, str, object]]:
        predicted = selection["predicted_addresses"]
        launchpad = predicted["launchpad"]
        return [
            ("launchpad.hook", launchpad, "hook()(address)", predicted["hook"]),
            ("launchpad.locker", launchpad, "locker()(address)", predicted["locker"]),
            ("launchpad.splitterImplementation", launchpad, "splitterImplementation()(address)", predicted["splitter_implementation"]),
            ("launchpad.launchesPaused", launchpad, "launchesPaused()(bool)", True),
            ("bidAdapter.launchpad", predicted["bid_adapter"], "launchpad()(address)", launchpad),
        ]

    def governance_plan(self, packet: dict) -> list[dict]:
        """One `admitStock(stock, route)` per stock version 2 admits, each read back through
        `stockAdmission(stock)` as (admitted, the stock's observed decimals, the route)."""
        launchpad = packet["selection"]["predicted_addresses"]["launchpad"]
        admit = freeze.keccak256(b"admitStock(address,address)")[:10]
        query = freeze.keccak256(b"stockAdmission(address)")[:10]
        return [{
            "label": f"admitStock({a['symbol']})",
            "to": launchpad,
            "data": admit + abi_word(a["stock"]) + abi_word(a["route"]),
            "readback": (launchpad, query + abi_word(a["stock"]), "0x" + abi_word(1) + abi_word(a["decimals"]) + abi_word(a["route"])),
        } for a in packet["external_observation"]["admissions"]]

    def governance_batch_meta(self, packet: dict) -> dict:
        launchpad = packet["selection"]["predicted_addresses"]["launchpad"]
        symbols = ", ".join(a["symbol"] for a in packet["selection"]["admissions"])
        return {
            "name": "Autolaunch: admit the stocks to StocksLaunchpadV3",
            "description": (f"admitStock(stock, route) on StocksLaunchpadV3 {launchpad} for {symbols}, each with the "
                            f"AerodromeStockRouteV2 version 2 deployed for it. Sign only after both version 3 creations "
                            f"have landed, from the rehearsal of packet {packet['digest']['value']}."),
        }

    def abi_artifacts(self) -> dict[str, str]:
        return {
            "launchpad": "src/StocksLaunchpadV3.sol:StocksLaunchpadV3",
            "hook": "src/StocksFeeHookV1.sol:StocksFeeHookV1",
            "locker": "src/MemestockLPLocker.sol:MemestockLPLocker",
            "splitter": "src/MemestockSplitterV1.sol:MemestockSplitterV1",
            "bid_adapter": "src/StockBidAdapterV1.sol:StockBidAdapterV1",
            "route": "src/routes/AerodromeStockRouteV2.sol:AerodromeStockRouteV2",
            "auction": "lib/continuous-clearing-auction/src/ContinuousClearingAuction.sol:ContinuousClearingAuction",
            "erc20": "src/interfaces/IERC20Standard.sol:IERC20Standard",
            "permit2": "lib/permit2/src/interfaces/IAllowanceTransfer.sol:IAllowanceTransfer",
        }

    def add_site_config_arguments(self, parser: argparse.ArgumentParser) -> None:
        super().add_site_config_arguments(parser)
        parser.add_argument("--agent-factory", required=True, help="the deployed Base Revstake factory, from contracts/revstake-v3/deployments/base-mainnet/deployed-manifest.json")

    def site_config(self, manifest: dict, args: argparse.Namespace, abis: dict) -> dict:
        """The `v1` and `v2` sections name the earlier launchpads, which the website keeps reading
        for the launches made on them."""
        created = {entry["contract_key"]: entry["address"] for entry in manifest["contracts"]}
        addresses = {
            **created,
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
        return {
            "rpc_url": self.chain.injected(),
            "public_rpc_url": args.public_rpc_url,
            "chain_id": self.chain.chain_id,
            "addresses": {key: value.lower() for key, value in addresses.items()},
            "abis": abis,
            **{section: earlier_section(package / DEPLOYMENTS / "base-mainnet" / MANIFEST_NAME, package / "abi",
                                        ("bid_adapter", *contracts), contracts)
               for section, package, contracts in self.EARLIER},
        }


PACKAGES = {package.component: package for package in (RevstakeV3, StocksV3)}


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
        "source_identity": source_identity(frozen),
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
    for name in package.PREDICTED:
        if rederived["predicted_addresses"][name] != selection["predicted_addresses"][name]:
            raise CeremonyError(f"predicted {name} re-derives to {rederived['predicted_addresses'][name]}, not the committed {selection['predicted_addresses'][name]}")
    if rederived["hook_salt"].lower() != selection["hook_salt"].lower():
        raise CeremonyError("the committed hook salt did not round-trip")
    print("selection: every predicted address re-derives from the committed values exactly")


def is_deployed_record(package: Package) -> bool:
    path = DEPLOYMENTS / package.network / MANIFEST_NAME
    return path.exists() and load_json(path).get("status") == "deployed"


def verify_deployed_packet(packet: dict | None) -> None:
    """A deployed package's packet is the record of what the chain carries: it is proved from its
    own content and the source tree it names, never re-derived from HEAD."""
    if packet is None:
        raise CeremonyError("the deployed manifest is a deployed record but no packet is installed")
    digest = packet["digest"]["value"]
    if digest_of(packet) != digest:
        raise CeremonyError("the installed packet's digest does not recompute from its content")
    src_tree = packet["source_identity"]["src_tree"]
    try:
        kind = git("cat-file", "-t", src_tree)
    except CeremonyError:
        kind = "absent"
    if kind != "tree":
        raise CeremonyError(f"src_tree {src_tree} is not a tree object in this repository")
    print(f"render: the installed packet is a deployed record; digest {digest} recomputes and its source tree exists")


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
    print("offline: no endpoint variable survives into this run")
    verify_hermetic_suite()
    packet = installed_packet(package)
    if is_deployed_record(package):
        verify_deployed_packet(packet)
    else:
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
    inputs = package.version_two_inputs()
    package.chain.probe()
    nonce = package.chain.nonce(deployer)
    print(f"deployer {deployer} is at nonce {nonce} on {package.chain.alias}")
    seed = {"deployer": deployer, "starting_nonce": nonce, **inputs}
    env = forge_env(offline=True, extra=package.selection_environment(seed, None))
    logs = selection_logs("test_SelectionPrepareCandidate", env)
    selection = package.selection_from_logs(inputs, logs)
    if selection["deployer"] != deployer or selection["starting_nonce"] != nonce:
        raise CeremonyError("the selection suite did not derive from the selected deployer and its live nonce")
    print(f"hook salt mined: {selection['hook_salt']}")
    for name in package.PREDICTED:
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
    nonce = package.chain.nonce(selection["deployer"])
    if nonce != selection["starting_nonce"]:
        raise CeremonyError(f"the deployer is at nonce {nonce} on {package.chain.alias}, not the committed {selection['starting_nonce']}; the packet is terminal")
    observed = package.observe(selection)
    problems: list[str] = []
    package.compare_observation(committed, observed, problems)
    if problems:
        raise CeremonyError("external state moved since the packet was prepared:\n  " + "\n  ".join(problems))
    print("external observation: every committed fact matches the live chain exactly")
    verify_selection_rederives(package, selection)
    package.rehearse(packet)
    print("CEREMONY REHEARSE PASS: mainnet-NO-GO, not authorized")
    return 0


def mode_preflight(package: Package, frozen: Frozen, args: argparse.Namespace) -> int:
    packet, selection, committed = require_selection(package)
    compare_bytes(render_packet(package, frozen, selection, committed), packet, "preflight")
    plan = package.transaction_plan(selection)
    if not 0 <= args.index < len(plan):
        raise CeremonyError(f"there is no creation {args.index}; this packet has creations 0 to {len(plan) - 1}")
    contract, predicted = plan[args.index]
    chain = package.chain
    chain.probe()
    expected = selection["starting_nonce"] + args.index
    nonce = chain.nonce(selection["deployer"])
    if nonce != expected:
        raise CeremonyError(f"the deployer's confirmed and pending nonces are both {nonce} on {chain.alias}, but creation "
                            f"{args.index} ({contract}) is sent at nonce {expected}; do not send it")
    if chain.code(predicted):
        raise CeremonyError(f"{predicted} already holds code on {chain.alias}; creation {args.index} ({contract}) is not sent again")
    print(f"PREFLIGHT PASS: send creation {args.index} ({contract}) at nonce {expected} on {chain.alias}; "
          f"it creates {predicted}; confirmed and pending nonces are both {nonce}")
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
    chain = package.chain
    chain.probe()

    artifacts = frozen_artifacts(frozen)
    problems: list[str] = []
    transactions = []
    contracts = []
    for index, ((contract, predicted), tx_hash) in enumerate(zip(plan, hashes)):
        if not HASH32_RE.match(tx_hash):
            raise CeremonyError(f"transaction {index} is not a 32-byte hash: {tx_hash}")
        receipt = chain.receipt(tx_hash)
        transaction = chain.transaction(tx_hash)
        created = receipt.get("contractAddress")
        expected_nonce = selection["starting_nonce"] + index
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
        contracts.append(verify_code(chain, frozen, artifacts, contract, predicted, block, "deployer", problems))
    creator_index = next(i for i, (name, _) in enumerate(plan) if name == package.constructor_creator)
    for contract, predicted, created_by in package.internal_plan(selection):
        block = transactions[creator_index]["block_number"]
        contracts.append(verify_code(chain, frozen, artifacts, contract, predicted, block, created_by, problems))
    readbacks = package.readbacks(selection, transactions[-1]["block_number"], problems)
    if problems:
        raise CeremonyError("the receipts do not record the committed ceremony:\n  " + "\n  ".join(problems))
    manifest = {
        **empty_manifest(package),
        "status": "deployed",
        "note": (
            "This file is the only record of deployed facts. It is not the packet: the packet is a "
            "proposal about what a ceremony would do, rendered from an offline or read-only run. "
            "`bin/ceremony.py record` wrote every field from confirmed receipts, after the founder had "
            "named the approved packet digest and sent the ceremony by hand; nothing simulated is "
            "written here."
        ),
        "approved_packet_digest": packet["digest"]["value"],
        "selection": selection,
        "transactions": transactions,
        "contracts": contracts,
        "readbacks": readbacks,
    }
    candidate = write_candidate(MANIFEST_NAME, manifest)
    print(f"every receipt matches the packet; deployed-manifest candidate written to {candidate}")
    print(f"install it at deployments/{package.network}/{MANIFEST_NAME} and commit on the founder's word")
    return 0


CONTRACT_KEYS = {
    "StocksLaunchpadV3": "launchpad", "StocksFeeHookV1": "hook", "MemestockLPLocker": "locker",
    "MemestockSplitterV1": "splitter_implementation", "StockBidAdapterV1": "bid_adapter",
    "RegentsAutolaunchFactoryV3": "factory", "RegentLBPStrategyV3": "strategy", "RevstakeLPLocker": "lp_locker",
    "RegentFeeHook": "hook",
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


def compare_runtime(record: dict, artifact: dict, code: bytes) -> tuple[str, bool]:
    """How a created runtime is compared with the frozen one, and whether it matches."""
    if record["runtime_keccak256_is_deployed_codehash"]:
        return "codehash equals the frozen runtime keccak256", freeze.keccak256(code) == record["runtime_keccak256"].lower()
    compiled_bytes = bytearray(bytes.fromhex(freeze.code_object(artifact, "deployedBytecode")))
    masked = bytearray(code)
    for references in (artifact["deployedBytecode"].get("immutableReferences") or {}).values():
        for reference in references:
            start, length = reference["start"], reference["length"]
            compiled_bytes[start:start + length] = b"\0" * length
            masked[start:start + length] = b"\0" * length
    return "deployed code equals the frozen runtime with immutables masked", bytes(compiled_bytes) == bytes(masked)


def verify_code(chain: Chain, frozen: Frozen, artifacts: dict, contract: str, address: str, block: int,
                created_by: str, problems: list[str]) -> dict:
    onchain = chain.code(address)
    codehash = freeze.keccak256(onchain)
    entry = {"contract": contract, "contract_key": CONTRACT_KEYS[contract], "chain_id": chain.chain_id, "address": address,
             "created_by": created_by, "block_number": block, "codehash": codehash, "runtime_bytes": len(onchain)}
    if len(onchain) == 0:
        problems.append(f"{contract} at {address} has no code")
        return entry
    entry["verification"], matches = compare_runtime(frozen.contract(contract), artifacts[contract], onchain)
    if not matches:
        problems.append(f"{contract} at {address}: the deployed code does not match ({entry['verification']})")
    return entry


def mode_site_config(package: Package, frozen: Frozen, args: argparse.Namespace) -> int:
    manifest = installed_manifest(package)
    if manifest.get("status") != "deployed":
        raise CeremonyError("no deployed manifest is installed; the site-config is rendered from confirmed receipts only")
    artifacts = freeze.load_artifacts(Path("out"))
    abis = {}
    for key, target in package.abi_artifacts().items():
        try:
            abis[key] = artifacts[target]["abi"]
        except KeyError:
            raise CeremonyError(f"out carries no artifact {target}; run forge build first")
    document = package.site_config(manifest, args, abis)
    candidate = write_candidate(SITE_CONFIG_NAME, document)
    print(f"site-config written to {candidate}; it carries both endpoints and is never committed")
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
    modes.add_parser("rehearse")
    preflight = modes.add_parser("preflight")
    preflight.add_argument("index", type=int, help="the creation about to be sent, counting from 0 in nonce order")
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
        "preflight": mode_preflight,
        "record": mode_record,
        "site-config": mode_site_config,
    }[args.mode](package, frozen, args)


if __name__ == "__main__":
    sys.exit(main())
