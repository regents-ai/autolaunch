# /// script
# requires-python = ">=3.11"
# ///
"""Builds deploy/packet.json (and deploy/transaction-data.txt, its data alone): the one transaction that deploys CoveredCallsV1 for AMZNc on Base.

Run from anywhere: `uv run contracts/covered-calls/deploy/build-packet.py`. It needs `forge`, `cast`
and `git`, and reads nothing from the network. Every value comes from a file in this repository:

- AMZNc: the Base Memestake v2 deployment record (stocks-v2/deployments/base-mainnet/deployed-manifest.json),
  the admission whose symbol is AMZNc, with its decimals.
- USDC and live REGENT staking: stocks-v2/src/StocksBindings.sol, the bindings the live Memestock fee
  hook was built with.
- The creation code: `forge build` of this package with its foundry.toml (the gate's build).

The deployment goes through the deterministic deployer at 0x4e59b448…956C (CREATE2), so the
address depends only on the salt and the creation code with its arguments, never on who sends it.
"""

import json
import re
import subprocess
from pathlib import Path

PACKAGE = Path(__file__).resolve().parent.parent
CONTRACTS = PACKAGE.parent
REPO = CONTRACTS.parent
STOCKS = CONTRACTS / "stocks-v2"

CHAIN_ID = 8453
SYMBOL = "AMZNc"
DEPLOYER = "0x4e59b44847b379578588920cA78FbF26c0B4956C"
# The deterministic deployer's code, the same on every chain it is on.
DEPLOYER_CODE = (
    "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f5"
    "8015156039578182fd5b8082525050506014600cf3"
)
SALT_TEXT = "autolaunch.covered-calls.v1.AMZNc"
SAFE = "0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e"


def run(*args: str, cwd: Path = PACKAGE) -> str:
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def keccak(hex_data: str) -> str:
    return run("cast", "keccak", hex_data)


def word(value: int) -> str:
    return f"{value:064x}"


def binding(name: str) -> str:
    source = (STOCKS / "src/StocksBindings.sol").read_text()
    return re.search(rf"address internal constant {name} = (0x[0-9a-fA-F]{{40}});", source)[1]


def stock() -> dict:
    manifest = json.loads((STOCKS / "deployments/base-mainnet/deployed-manifest.json").read_text())
    [admission] = [a for a in manifest["admissions"] if a["symbol"] == SYMBOL]
    return admission


def immutables(artifact: dict) -> dict[str, list[dict]]:
    """The immutables' places in the runtime code, by name."""
    names = {}

    def walk(node):
        if isinstance(node, dict):
            if node.get("nodeType") == "VariableDeclaration" and node.get("mutability") == "immutable":
                names[str(node["id"])] = node["name"]
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(artifact["ast"])
    return {names[ref]: places for ref, places in artifact["deployedBytecode"]["immutableReferences"].items()}


def runtime(artifact: dict, values: dict[str, int]) -> str:
    """The runtime code the constructor leaves: the compiled runtime with each immutable filled in."""
    code = bytearray.fromhex(artifact["deployedBytecode"]["object"][2:])
    for name, places in immutables(artifact).items():
        for place in places:
            code[place["start"] : place["start"] + place["length"]] = bytes.fromhex(word(values[name]))
    return "0x" + code.hex()


def main() -> None:
    run("forge", "build", "--force", "--ast")
    artifact = json.loads((PACKAGE / "out/CoveredCallsV1.sol/CoveredCallsV1.json").read_text())
    settings = artifact["metadata"]["settings"]

    amznc = stock()
    usdc = binding("USDC")
    staking = binding("LIVE_STAKING")
    arguments = [amznc["stock"], usdc, staking]

    creation = artifact["bytecode"]["object"]
    encoded = "".join(word(int(address, 16)) for address in arguments)
    init_code = creation + encoded
    salt = keccak(run("cast", "from-utf8", SALT_TEXT))
    predicted = run("cast", "create2", "--deployer", DEPLOYER, "--salt", salt, "--init-code", init_code)
    code = runtime(
        artifact,
        {
            "stock": int(amznc["stock"], 16),
            "usdc": int(usdc, 16),
            "staking": int(staking, 16),
            "unit": 10 ** amznc["decimals"],
        },
    )
    source_paths = ["contracts/covered-calls/src", "contracts/covered-calls/foundry.toml", "contracts/covered-calls/remappings.txt"]
    dependencies = json.loads((STOCKS / "dependencies.json").read_text())

    packet = {
        "contract": "CoveredCallsV1",
        "market": SYMBOL,
        "chain_id": CHAIN_ID,
        "status": "prepared, not sent",
        "source": {
            "repository": "regents-ai/autolaunch",
            "commit": run("git", "log", "-1", "--format=%H", "--", *source_paths, cwd=REPO),
            "file": "contracts/covered-calls/src/CoveredCallsV1.sol",
            "solady_revision": dependencies["solady"]["revision"],
            "forge_std_revision": dependencies["forge-std"]["revision"],
        },
        "compiler": {
            "solc": artifact["metadata"]["compiler"]["version"],
            "evm_version": settings["evmVersion"],
            "optimizer": settings["optimizer"],
            "via_ir": settings["viaIR"],
            "bytecode_hash": settings["metadata"]["bytecodeHash"],
            "cbor_metadata": settings["metadata"].get("appendCBOR", True),
        },
        "creation_code_keccak": keccak(creation),
        "constructor": [
            {
                "name": "stock_",
                "value": amznc["stock"],
                "is": f"{SYMBOL}, the Base stock token, {amznc['decimals']} decimals",
                "source": "contracts/stocks-v2/deployments/base-mainnet/deployed-manifest.json, admissions, symbol AMZNc",
            },
            {
                "name": "usdc_",
                "value": usdc,
                "is": "USDC on Base",
                "source": "contracts/stocks-v2/src/StocksBindings.sol, USDC (built into the live Memestock fee hook)",
            },
            {
                "name": "staking_",
                "value": staking,
                "is": "live REGENT staking, which the Memestock fee hook pays into",
                "source": "contracts/stocks-v2/src/StocksBindings.sol, LIVE_STAKING (built into the live Memestock fee hook)",
            },
        ],
        "constructor_args_encoded": "0x" + encoded,
        "init_code_keccak": keccak(init_code),
        "create2": {
            "deployer": DEPLOYER,
            "deployer_code_keccak": keccak(DEPLOYER_CODE),
            "salt_text": SALT_TEXT,
            "salt": salt,
            "predicted_address": predicted,
        },
        "transaction": {
            "chain_id": CHAIN_ID,
            "to": DEPLOYER,
            "value": "0",
            "data": salt + init_code[2:],
            # Base estimated 1,103,368 and the rehearsal used 1,083,828 (28 Oct 2026).
            "gas_limit_at_least": 1_200_000,
        },
        "signer": {
            "recommended": "your own wallet",
            "alternative_safe": SAFE,
            "safe_operation": "Call (never delegatecall)",
            "why": (
                "CoveredCallsV1 has no owner, admin, pause or upgrade, so whoever sends this transaction "
                "gains no power over it, and the address is the same whoever sends it. One signature from "
                "your wallet is the simplest; the Safe adds approvals and nothing else."
            ),
        },
        "before_signing": (
            f"Check {predicted} still has no code. Anyone may send this same transaction; if the "
            "address already holds runtime_code_keccak, the contract is deployed and nothing needs sending."
        ),
        "post_deploy": {
            "receipt_status": "1",
            "runtime_code_keccak": keccak(code),
            "reads": {
                "stock()": amznc["stock"],
                "usdc()": usdc,
                "staking()": staking,
                "unit()": str(10 ** amznc["decimals"]),
                "FEE_BPS()": "100",
                "EXERCISE_WINDOW()": "86400",
            },
            "basescan_verify_needs": (
                "ETHERSCAN_API_KEY (an Etherscan key works for Base) and ../stocks-v2/lib filled by "
                "contracts/stocks-v2/bootstrap-deps.py; run from contracts/covered-calls"
            ),
            "basescan_verify": (
                f"forge verify-contract {predicted} src/CoveredCallsV1.sol:CoveredCallsV1 --chain base "
                f"--compiler-version v{artifact['metadata']['compiler']['version']} "
                f"--constructor-args 0x{encoded} --watch"
            ),
        },
    }
    (PACKAGE / "deploy/packet.json").write_text(json.dumps(packet, indent=2) + "\n")
    (PACKAGE / "deploy/transaction-data.txt").write_text(packet["transaction"]["data"] + "\n")
    print(f"deploy/packet.json: {predicted}")


main()
