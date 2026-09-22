#!/usr/bin/env python3
"""The post-ceremony tool for the Autolaunch Base contracts, run from `contracts/v1`.

`bin/deployment-gate.sh` renders, prepares and rehearses the packet and never touches a receipt.
This tool is the other half, after the founder has sent the five creations by hand:

  record       Verifies the five confirmed Base transaction hashes against the installed packet —
               sender, nonce, order, zero value, the exact initcode, the created address, success —
               proves every one of the eight created contracts carries the frozen build's runtime,
               reads every constructor binding back, and writes a deployed-manifest candidate to
               reports/generated/deployment/. A human installs it.
  site-config  Renders the website's production site-config from the installed packet and deployed
               manifest, the frozen ABIs and the two endpoints passed on the command line, to
               reports/generated/deployment/. The endpoints are never printed and the file is never
               committed; the gate wipes that directory on every run.

The chain is read through `cast` with the endpoint under `REGENT_BASE_RPC_URL`, the same variable
the `base` alias in `foundry.toml` resolves. Its value is never printed or written. Nothing here
signs, broadcasts, funds or moves value, and the tool refuses to run beside signing authority.

The gate imports `verify_manifest` from here, so the manifest's two admitted states — the empty
record, or a deployed record of the installed packet — are defined once.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def _load_freeze():
    path = Path(__file__).resolve().parent / "freeze-artifacts.py"
    spec = importlib.util.spec_from_file_location("freeze_artifacts", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


freeze = _load_freeze()  # keccak256, load_artifacts, code, render

GENERATED = Path("reports/generated/deployment")
PACKET = Path("deployments/base-mainnet/mainnet-no-go-packet.json")
MANIFEST = Path("deployments/base-mainnet/deployed-manifest.json")
RELEASE_MANIFEST = Path("contracts/autolaunch-release-manifest.json")
FORK_OBSERVATIONS = Path("reports/frozen/fork-observations.json")
BINDINGS_SOURCE = Path("src/bindings/BaseBindings.sol")
MANIFEST_NAME = "deployed-manifest.json"
SITE_CONFIG_NAME = "site-config.json"

RPC_ALIAS = "base"
RPC_ENV = "REGENT_BASE_RPC_URL"
CHAIN_ID = 8453

# Never run beside signing authority; this tool only ever reads.
FORBIDDEN_ENV = (
    "PRIVATE_KEY", "ETH_PRIVATE_KEY", "DEPLOYER_PRIVATE_KEY", "MNEMONIC", "MNEMONIC_INDEX",
    "ETH_KEYSTORE", "ETH_KEYSTORE_ACCOUNT", "ETH_PASSWORD", "ETH_FROM", "FOUNDRY_SENDER",
    "ETHERSCAN_API_KEY", "LEDGER", "TREZOR", "AWS_KMS_KEY_ID", "GCP_KEY_NAME",
)
DOTENV_FILES = (".env", ".env.local", ".envrc")

# The five creation transactions, in ceremony order, then the three creations made inside
# constructors, in temporal order. Names are the packet's; keys are the manifest's and the
# website's.
CREATIONS = (
    ("UERC20Factory", "uerc20_factory"),
    ("ConditionalVestingEscrowV1", "escrow_implementation"),
    ("SubjectSplitterV1", "splitter_implementation"),
    ("PaymentReceiverV1", "receiver_implementation"),
    ("RegentsAutolaunchFactoryV1", "factory"),
)
INTERNAL = (
    ("RegentLBPStrategy", "strategy", "RegentsAutolaunchFactoryV1"),
    ("RevstakeLPLocker", "lp_locker", "RegentLBPStrategy"),
    ("RegentFeeHook", "hook", "RegentsAutolaunchFactoryV1"),
)
CONTRACT_KEYS = {name: key for name, key, *_ in CREATIONS + INTERNAL}

# The website's ABI set: the same artifact choices `bin/local-base-lab.py` makes for the lab,
# plus the locker, each named by its exact compilation target in the frozen build.
ABI_TARGETS = {
    "auction": "lib/continuous-clearing-auction/src/ContinuousClearingAuction.sol:ContinuousClearingAuction",
    "escrow": "src/escrow/ConditionalVestingEscrowV1.sol:ConditionalVestingEscrowV1",
    "factory": "src/factory/RegentsAutolaunchFactoryV1.sol:RegentsAutolaunchFactoryV1",
    "hook": "src/hook/RegentFeeHook.sol:RegentFeeHook",
    "lp_locker": "src/revenue/RevstakeLPLocker.sol:RevstakeLPLocker",
    "permit2": "lib/liquidity-launcher/lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol:IAllowanceTransfer",
    "receiver": "src/revenue/PaymentReceiverV1.sol:PaymentReceiverV1",
    "splitter": "src/revenue/SubjectSplitterV1.sol:SubjectSplitterV1",
    "strategy": "src/strategy/RegentLBPStrategy.sol:RegentLBPStrategy",
    "token": "lib/uerc20-factory/src/tokens/UERC20.sol:UERC20",
}
# The frozen Base bindings the website needs beside the eight created contracts.
SITE_BINDINGS = {
    "regent": "REGENT",
    "cca_factory": "CCA_FACTORY",
    "pool_manager": "POOL_MANAGER",
    "position_manager": "POSITION_MANAGER",
    "governance_safe": "GOVERNANCE_AND_REGENT_SAFE",
}

ADDRESS_RE = re.compile(r"0x[0-9a-fA-F]{40}")
HASH32_RE = re.compile(r"^0x[0-9a-fA-F]{64}$")
URL_RE = re.compile(r"(?:https?|wss?)://[^\s\"'`)>\]]+")
SOL_ADDRESS_CONST_RE = re.compile(r"^\s*address internal constant (\w+) = (0x[0-9a-fA-F]{40});\s*$")


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
    """EIP-55 form, so the manifest carries one spelling of every address."""
    lower = address.lower().removeprefix("0x")
    if not re.fullmatch(r"[0-9a-f]{40}", lower):
        raise CeremonyError(f"not a 20-byte address: {address}")
    digest = freeze.keccak256(lower.encode()).removeprefix("0x")
    return "0x" + "".join(c.upper() if int(digest[i], 16) >= 8 else c for i, c in enumerate(lower))


def same_address(a: str, b: str) -> bool:
    return a.lower() == b.lower()


def quantity(value) -> int:
    return int(value, 16) if isinstance(value, str) else int(value)


def run(args: list[str], env: dict | None = None) -> str:
    result = subprocess.run(args, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise CeremonyError(f"{args[0]} {args[1]} exited {result.returncode}:\n{result.stderr.strip()}")
    return result.stdout


def refuse_signing_authority() -> None:
    for name in FORBIDDEN_ENV:
        if os.environ.get(name):
            raise CeremonyError(f"{name} is set; this tool never signs and refuses to run beside signing authority")
    for dotenv in DOTENV_FILES:
        if Path(dotenv).exists():
            raise CeremonyError(f"{dotenv} exists in the package; this tool never reads one and refuses to run beside one")
    print("no signing, keystore, sender or hardware-wallet variable is present; no dotenv file exists")


def require_component_root() -> None:
    top = run(["git", "rev-parse", "--show-toplevel"]).strip()
    if Path.cwd().resolve() != (Path(top) / "contracts/v1").resolve():
        raise CeremonyError(f"run from contracts/v1; the current directory is {Path.cwd()}")


# =============================================================================
# The chain, read-only
# =============================================================================


class Chain:
    """Read-only access to Base through `cast`, by the endpoint under one environment name."""

    def endpoint(self) -> str:
        value = os.environ.get(RPC_ENV, "")
        if not value:
            raise CeremonyError(f"no read-only endpoint is injected under {RPC_ENV}")
        if not re.match(r"^(https?|wss?)://.+", value):
            raise CeremonyError(f"the value under {RPC_ENV} is not an http(s) or ws(s) endpoint; its value is never printed")
        return value

    def cast(self, *args: str) -> str:
        return run(["cast", *args, "--rpc-url", self.endpoint()]).strip()

    def probe(self) -> None:
        found = int(self.cast("chain-id"))
        if found != CHAIN_ID:
            raise CeremonyError(f"the endpoint under {RPC_ENV} serves chain {found}, not {CHAIN_ID}")
        print(f"{RPC_ALIAS}: a read-only endpoint is injected under {RPC_ENV}; chain id {CHAIN_ID} confirmed")

    def nonce(self, account: str) -> int:
        return int(self.cast("nonce", account))

    def code(self, account: str) -> bytes:
        return bytes.fromhex(self.cast("code", account).removeprefix("0x"))

    def call(self, to: str, signature: str) -> str:
        return self.cast("call", to, signature)

    def call_address(self, to: str, signature: str) -> str:
        found = ADDRESS_RE.findall(self.call(to, signature))
        if len(found) != 1:
            raise CeremonyError(f"{signature} on {to} did not return one address")
        return checksum(found[0])

    def call_uint(self, to: str, signature: str) -> int:
        return int(self.call(to, signature).split()[0])

    def call_bool(self, to: str, signature: str) -> bool:
        value = self.call(to, signature)
        if value not in ("true", "false"):
            raise CeremonyError(f"{signature} on {to} did not return a bool")
        return value == "true"

    def receipt(self, tx_hash: str) -> dict:
        return json.loads(self.cast("receipt", tx_hash, "--json"))

    def transaction(self, tx_hash: str) -> dict:
        return json.loads(self.cast("tx", tx_hash, "--json"))


# =============================================================================
# The committed authorities
# =============================================================================


def installed_packet() -> dict:
    packet = load_json(PACKET)
    if not packet.get("selection", {}).get("deployer"):
        raise CeremonyError(f"{PACKET} pins no deployer; a ceremony has nothing to be recorded against")
    return packet


def bindings() -> dict[str, str]:
    """Every `BaseBindings` address constant, read from the frozen source."""
    found = {}
    for line in BINDINGS_SOURCE.read_text(encoding="utf-8").splitlines():
        match = SOL_ADDRESS_CONST_RE.match(line)
        if match:
            found[match.group(1)] = checksum(match.group(2))
    for constant in SITE_BINDINGS.values():
        if constant not in found:
            raise CeremonyError(f"{BINDINGS_SOURCE} declares no address constant {constant}")
    return found


def permit2() -> str:
    """The canonical Permit2 the website drives, as the frozen fork observation records it."""
    return checksum(load_json(FORK_OBSERVATIONS)["permit2"]["address"])


def frozen_artifacts() -> tuple[dict, dict[str, dict]]:
    """The default-profile build, proved to be the frozen release build object by object."""
    run(["forge", "build"], env=dict(os.environ, FOUNDRY_PROFILE="default", FOUNDRY_OFFLINE="true",
                                    FOUNDRY_LINT_LINT_ON_BUILD="false"))
    release = load_json(RELEASE_MANIFEST)
    artifacts = freeze.load_artifacts(Path("out"))
    found = {}
    for name, _ in CREATIONS + tuple((n, k) for n, k, _ in INTERNAL):
        record = release["contracts"][name]
        artifact = artifacts.get(f"{record['source']}:{name}")
        if artifact is None:
            raise CeremonyError(f"the build carries no artifact {record['source']}:{name}")
        runtime = freeze.code(artifact, "deployedBytecode")
        if hashlib.sha256(runtime).hexdigest() != record["runtime_sha256"]:
            raise CeremonyError(f"the built {name} runtime is not the frozen release runtime")
        if freeze.keccak256(freeze.code(artifact, "bytecode")) != record["creation_keccak256"]:
            raise CeremonyError(f"the built {name} creation code is not the frozen release creation code")
        found[name] = artifact
    print(f"frozen build: {len(found)} artifacts match {RELEASE_MANIFEST} exactly")
    return release, found


# =============================================================================
# The deployed manifest's two admitted states
# =============================================================================


def empty_manifest() -> dict:
    return {
        "artifact": "regents-autolaunch-base-mainnet-deployed-manifest",
        "version": 1,
        "status": "not deployed",
        "populated_by": "confirmed Base receipts, and nothing else",
        "note": (
            "This file is the only record of deployed facts, and it is deliberately empty. It is not "
            "the packet: the packet is a proposal about what a ceremony would do, rendered from an "
            "offline or read-only run. Nothing simulated may be written here. Every field is populated "
            "once, by `bin/ceremony.py record` from confirmed Base receipts, after the founder has named "
            "the approved packet digest and sent the ceremony by hand; a human installs the candidate it "
            "writes, and bin/deployment-gate.sh admits exactly that record or this empty one."
        ),
        "approved_packet_digest": None,
        "selection": None,
        "transactions": [],
        "contracts": [],
        "readbacks": None,
    }


def verify_manifest(manifest: dict, packet: dict) -> str:
    """Exactly two states are admitted: the empty record, or a deployed record of this packet."""
    if manifest == empty_manifest():
        return "the deployed manifest is the empty record: no address, no hash, no number"
    problems = []
    if list(manifest) != list(empty_manifest()):
        problems.append(f"keys are {list(manifest)}, expected {list(empty_manifest())}")
    if manifest.get("status") != "deployed":
        problems.append(f"status is [{manifest.get('status')}], expected [deployed]")
    digest = packet.get("digest", {}).get("value")
    if not digest or manifest.get("approved_packet_digest") != digest:
        problems.append("approved_packet_digest is not the installed packet's digest")
    selection = packet.get("selection") or {}
    if manifest.get("selection") != selection:
        problems.append("selection is not the installed packet's selection")
    predicted = selection.get("predicted_addresses") or {}
    starting = selection.get("starting_nonce")
    transactions = manifest.get("transactions")
    if not isinstance(transactions, list) or len(transactions) != len(CREATIONS):
        problems.append(f"expected exactly {len(CREATIONS)} transactions")
    else:
        for index, ((name, key), entry) in enumerate(zip(CREATIONS, transactions)):
            wanted = {"index": index, "nonce": starting + index, "contract": name, "contract_key": key,
                      "address": predicted.get(key)}
            for field, value in wanted.items():
                if entry.get(field) != value:
                    problems.append(f"transactions[{index}].{field} is {entry.get(field)!r}, expected {value!r}")
            if not isinstance(entry.get("hash"), str) or not HASH32_RE.match(entry["hash"]):
                problems.append(f"transactions[{index}].hash is not a 32-byte hash")
            if not isinstance(entry.get("block_number"), int) or entry["block_number"] <= 0:
                problems.append(f"transactions[{index}].block_number is not a positive block number")
    contracts = manifest.get("contracts")
    expected = [(name, key) for name, key in CREATIONS] + [(name, key) for name, key, _ in INTERNAL]
    if not isinstance(contracts, list) or len(contracts) != len(expected):
        problems.append(f"expected exactly {len(expected)} contracts")
    else:
        for index, ((name, key), entry) in enumerate(zip(expected, contracts)):
            wanted = {"contract": name, "contract_key": key, "address": predicted.get(key)}
            for field, value in wanted.items():
                if entry.get(field) != value:
                    problems.append(f"contracts[{index}].{field} is {entry.get(field)!r}, expected {value!r}")
    if not isinstance(manifest.get("readbacks"), dict) or not manifest["readbacks"]:
        problems.append("readbacks is not a populated record")
    if problems:
        raise CeremonyError("the deployed manifest is neither the empty record nor a deployed record of "
                            "the installed packet:\n  " + "\n  ".join(problems))
    return f"the deployed manifest is a deployed record of packet digest {digest}"


# =============================================================================
# record
# =============================================================================


def verify_code(chain: Chain, release: dict, artifacts: dict, name: str, address: str, block: int,
                created_by: str, mechanism: str, problems: list[str]) -> dict:
    record = release["contracts"][name]
    onchain = chain.code(address)
    entry = {"contract": name, "contract_key": CONTRACT_KEYS[name], "address": address, "created_by": created_by,
             "mechanism": mechanism, "block_number": block, "codehash": freeze.keccak256(onchain),
             "runtime_bytes": len(onchain)}
    if len(onchain) != record["runtime_bytes"]:
        problems.append(f"{name} at {address}: {len(onchain)} runtime bytes, the frozen build has {record['runtime_bytes']}")
        return entry
    if record["runtime_keccak256_is_deployed_codehash"]:
        entry["verification"] = "codehash equals the frozen runtime keccak256"
        if entry["codehash"] != record["runtime_keccak256"].lower():
            problems.append(f"{name} at {address}: codehash {entry['codehash']} is not the frozen {record['runtime_keccak256']}")
        return entry
    compiled = bytearray(freeze.code(artifacts[name], "deployedBytecode"))
    masked = bytearray(onchain)
    for references in (artifacts[name]["deployedBytecode"].get("immutableReferences") or {}).values():
        for reference in references:
            start, length = reference["start"], reference["length"]
            compiled[start:start + length] = b"\0" * length
            masked[start:start + length] = b"\0" * length
    entry["verification"] = "deployed code equals the frozen runtime with immutables masked"
    if bytes(compiled) != bytes(masked):
        problems.append(f"{name} at {address}: deployed code differs from the frozen runtime outside its immutables")
    return entry


def readbacks(chain: Chain, predicted: dict, problems: list[str]) -> dict:
    factory, strategy, hook, locker = predicted["factory"], predicted["strategy"], predicted["hook"], predicted["lp_locker"]
    found = {
        "factory.uerc20Factory": chain.call_address(factory, "uerc20Factory()(address)"),
        "factory.strategy": chain.call_address(factory, "strategy()(address)"),
        "factory.hook": chain.call_address(factory, "hook()(address)"),
        "factory.launchesPaused": chain.call_bool(factory, "launchesPaused()(bool)"),
        "factory.nextLaunchId": chain.call_uint(factory, "nextLaunchId()(uint256)"),
        "strategy.factory": chain.call_address(strategy, "factory()(address)"),
        "strategy.escrowImplementation": chain.call_address(strategy, "escrowImplementation()(address)"),
        "strategy.splitterImplementation": chain.call_address(strategy, "splitterImplementation()(address)"),
        "strategy.receiverImplementation": chain.call_address(strategy, "receiverImplementation()(address)"),
        "strategy.hook": chain.call_address(strategy, "hook()(address)"),
        "strategy.lpLocker": chain.call_address(strategy, "lpLocker()(address)"),
        "hook.poolManager": chain.call_address(hook, "poolManager()(address)"),
        "hook.strategy": chain.call_address(hook, "strategy()(address)"),
        "lpLocker.strategy": chain.call_address(locker, "strategy()(address)"),
    }
    expected = {
        "factory.uerc20Factory": predicted["uerc20_factory"],
        "factory.strategy": strategy,
        "factory.hook": hook,
        "factory.launchesPaused": True,
        "factory.nextLaunchId": 1,
        "strategy.factory": factory,
        "strategy.escrowImplementation": predicted["escrow_implementation"],
        "strategy.splitterImplementation": predicted["splitter_implementation"],
        "strategy.receiverImplementation": predicted["receiver_implementation"],
        "strategy.hook": hook,
        "strategy.lpLocker": locker,
        "hook.poolManager": bindings()["POOL_MANAGER"],
        "hook.strategy": strategy,
        "lpLocker.strategy": strategy,
    }
    for key, wanted in expected.items():
        if found[key] != wanted:
            problems.append(f"readback {key}: expected {wanted}, found {found[key]}")
    return found


def mode_record(args: argparse.Namespace) -> int:
    packet = installed_packet()
    if args.approved_digest != packet["digest"]["value"]:
        raise CeremonyError("the approved digest passed does not name the installed packet")
    selection = packet["selection"]
    predicted = selection["predicted_addresses"]
    creation_order = packet["topology"]["creation_order"]
    hashes = load_json(Path(args.receipts)).get("transactions")
    if not isinstance(hashes, list) or len(hashes) != len(CREATIONS):
        raise CeremonyError(f"{args.receipts} must list exactly {len(CREATIONS)} transaction hashes in ceremony order")
    for index, tx_hash in enumerate(hashes):
        if not isinstance(tx_hash, str) or not HASH32_RE.match(tx_hash):
            raise CeremonyError(f"transaction {index} is not a 32-byte hash")

    chain = Chain()
    chain.probe()
    release, artifacts = frozen_artifacts()
    problems: list[str] = []
    transactions, contracts = [], []
    for index, ((name, key), tx_hash) in enumerate(zip(CREATIONS, hashes)):
        receipt = chain.receipt(tx_hash)
        transaction = chain.transaction(tx_hash)
        created = receipt.get("contractAddress") or ""
        initcode = bytes.fromhex(transaction["input"].removeprefix("0x"))
        identity = creation_order[index]
        creation_code = initcode[: identity["creation_code_bytes"]]
        facts = {
            "status": quantity(receipt.get("status", "0x0")) == 1,
            "from": same_address(receipt["from"], selection["deployer"]),
            "to": receipt.get("to") in (None, ""),
            "value": quantity(transaction.get("value", "0x0")) == 0,
            "nonce": quantity(transaction["nonce"]) == selection["starting_nonce"] + index,
            "initcode_bytes": len(initcode) == identity["initcode_bytes"],
            "creation_code_keccak256": freeze.keccak256(creation_code) == identity["creation_code_keccak256"].lower(),
            "created": bool(created) and same_address(created, predicted[key]),
        }
        for fact, ok in facts.items():
            if not ok:
                problems.append(f"transaction {index} ({name}): {fact} does not match the packet")
        block = quantity(receipt["blockNumber"])
        transactions.append({"index": index, "hash": tx_hash, "nonce": quantity(transaction["nonce"]),
                             "block_number": block, "gas_used": quantity(receipt["gasUsed"]),
                             "contract": name, "contract_key": key, "address": predicted[key]})
        contracts.append(verify_code(chain, release, artifacts, name, predicted[key], block, "deployer", "transaction", problems))
    factory_block = transactions[-1]["block_number"]
    for name, key, created_by in INTERNAL:
        mechanism = "CREATE2" if name == "RegentFeeHook" else "CREATE"
        contracts.append(verify_code(chain, release, artifacts, name, predicted[key], factory_block, created_by, mechanism, problems))
    found = readbacks(chain, predicted, problems)
    nonce = chain.nonce(selection["deployer"])
    if nonce != selection["starting_nonce"] + len(CREATIONS):
        problems.append(f"the deployer is at nonce {nonce}, not {selection['starting_nonce'] + len(CREATIONS)}: it sent something other than the five creations")
    if problems:
        raise CeremonyError("the receipts do not record the committed ceremony:\n  " + "\n  ".join(problems))
    manifest = {
        **empty_manifest(),
        "status": "deployed",
        "approved_packet_digest": packet["digest"]["value"],
        "selection": selection,
        "transactions": transactions,
        "contracts": contracts,
        "readbacks": found,
    }
    print(verify_manifest(manifest, packet))
    candidate = write_candidate(MANIFEST_NAME, manifest)
    print(f"every receipt matches the packet; deployed-manifest candidate written to {candidate}")
    print(f"install it at {MANIFEST} and commit on the founder's word")
    return 0


# =============================================================================
# site-config
# =============================================================================


def endpoint_argument(value: str, flag: str) -> str:
    if not re.match(r"^(https?|wss?)://.+", value):
        raise CeremonyError(f"{flag} is not an http(s) or ws(s) endpoint; its value is never printed")
    return value


def mode_site_config(args: argparse.Namespace) -> int:
    packet = installed_packet()
    manifest = load_json(MANIFEST)
    if manifest == empty_manifest():
        raise CeremonyError(f"{MANIFEST} is the empty record; the site-config is rendered from confirmed receipts only")
    print(verify_manifest(manifest, packet))
    _, artifacts = frozen_artifacts()
    built = freeze.load_artifacts(Path("out"))
    abis = {}
    for key, target in ABI_TARGETS.items():
        try:
            abis[key] = built[target]["abi"]
        except KeyError:
            raise CeremonyError(f"the build carries no artifact {target}")
    created = {entry["contract_key"]: entry["address"] for entry in manifest["contracts"]}
    frozen = bindings()
    addresses = {**created, **{key: frozen[constant] for key, constant in SITE_BINDINGS.items()}, "permit2": permit2()}
    factory_block = next(entry["block_number"] for entry in manifest["transactions"] if entry["contract_key"] == "factory")
    document = {
        "chain_id": CHAIN_ID,
        "rpc_url": endpoint_argument(args.rpc_url, "--rpc-url"),
        "public_rpc_url": endpoint_argument(args.public_rpc_url, "--public-rpc-url"),
        "addresses": {key: addresses[key].lower() for key in sorted(addresses)},
        "abis": abis,
        "start_blocks": {"factory": factory_block},
    }
    candidate = write_candidate(SITE_CONFIG_NAME, document)
    print(f"site-config written to {candidate}: {len(document['addresses'])} addresses, {len(abis)} ABIs, "
          f"factory start block {factory_block}; it carries the endpoints you passed and is never committed")
    return 0


# =============================================================================


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    modes = parser.add_subparsers(dest="mode", required=True)
    record = modes.add_parser("record")
    record.add_argument("--receipts", required=True, help="a JSON file {\"transactions\": [hash, ...]} in ceremony order")
    record.add_argument("--approved-digest", required=True, help="the packet digest the founder approved")
    site = modes.add_parser("site-config")
    site.add_argument("--rpc-url", required=True, help="the endpoint the website's server reads through")
    site.add_argument("--public-rpc-url", required=True, help="the endpoint wallets in the browser use")
    args = parser.parse_args()

    refuse_signing_authority()
    require_component_root()
    return {"record": mode_record, "site-config": mode_site_config}[args.mode](args)


if __name__ == "__main__":
    sys.exit(main())
