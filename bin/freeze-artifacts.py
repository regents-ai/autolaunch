#!/usr/bin/env python3
"""Deterministic freezer for the autolaunch-contracts release surface.

Every committed file under `abi/`, every frozen report the Solidity ABI tests read, and
`contracts/autolaunch-release-manifest.json` is *generated* from the exact compiler
artifacts in `out/`. Nothing here is hand written, and nothing here restates a value the
compiler already decided.

Two modes:

  write  Regenerate every frozen output from the current build.
  check  Regenerate into memory and compare byte for byte with the committed files. Any
         drift — a hand-edited ABI, a stale manifest, a recompiled contract, a renamed
         event, a changed integer width — fails closed. Check mode additionally compares
         the whole `src/**` compiled byte string against the independently captured
         pre-edit C4 baseline in `reports/frozen/c4-runtime-baseline.json`, and appends its
         own verified receipt line so deleting the gate's freezer invocation makes the
         ledger reconciliation fail for `DEP-016`.

The keccak-256 used for selectors and event topics is implemented here rather than
imported, so the gate needs no package. It is not trusted on its word: every function
selector it derives is reconciled against solc's own `methodIdentifiers` for the same
artifact before any output is produced, so a wrong hash cannot reach a frozen file.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

# The six contracts this repository deploys. This list is the manifest's complete-surface
# allowlist: a production contract that is not named here is not frozen, and a name here
# that the build does not produce fails closed.
PRODUCTION_CONTRACTS = (
    "RegentsAutolaunchFactoryV1",
    "RegentLBPStrategy",
    "RegentFeeHook",
    "ConditionalVestingEscrowV1",
    "SubjectSplitterV1",
    "PaymentReceiverV1",
)

# The three C1 implementations the factory and the strategy clone with Solady's minimal proxy.
CLONE_TARGETS = ("ConditionalVestingEscrowV1", "SubjectSplitterV1", "PaymentReceiverV1")

# The clone runtime template is read out of the production strategy's own `escrowCloneCodehash`
# derivation rather than transcribed here, so the frozen record cannot drift from the code that
# admits an authentic clone.
CLONE_TEMPLATE_SOURCE = "src/strategy/RegentLBPStrategy.sol"
CLONE_TEMPLATE_RE = r'hex"([0-9a-f]+)",\s*escrowImplementation_,\s*hex"([0-9a-f]+)"'

EIP170_RUNTIME_LIMIT = 24_576
EIP3860_INITCODE_LIMIT = 49_152

# The pinned upstreams this repository consumes as a caller. Recording the exact call and
# event surface it depends on is what makes an upstream change visible: these signatures
# are reconciled against the pinned dependency artifacts, never written down by hand.
CONSUMED_SURFACES = {
    "ContinuousClearingAuctionFactory": {
        "repository": "https://github.com/Uniswap/continuous-clearing-auction",
        "functions": ("create(address,uint256,bytes,bytes32)", "protocolFeeController()"),
        "events": ("AuctionCreated(address,address,uint256,bytes)",),
    },
    "ContinuousClearingAuction": {
        "repository": "https://github.com/Uniswap/continuous-clearing-auction",
        # Everything the strategy, the escrow, and a product bidder actually call. A rename
        # upstream fails the freeze instead of surfacing as a runtime revert.
        "functions": (
            "checkpoint()",
            "claimBlock()",
            "claimTokens(uint256)",
            "clearingPrice()",
            "currency()",
            "currencyRaised()",
            "endBlock()",
            "exitBid(uint256)",
            "exitPartiallyFilledBid(uint256,uint64,uint64)",
            "floorPrice()",
            "fundsRecipient()",
            "isGraduated()",
            "lbpInitializationParams()",
            "onTokensReceived()",
            "remainingSupply()",
            "startBlock()",
            "submitBid(uint256,uint128,address,uint256,bytes)",
            "sweepCurrency()",
            "sweepUnsoldTokens()",
            "tickSpacing()",
            "token()",
            "tokensRecipient()",
            "totalSupply()",
            "validationHook()",
        ),
        "events": (
            "BidExited(uint256,address,uint256,uint256)",
            "BidSubmitted(uint256,address,uint256,uint128)",
            "CurrencySwept(address,uint256)",
            "TokensClaimed(uint256,address,uint256)",
            "TokensSwept(address,uint256)",
        ),
    },
    # The real Permit2 pins `=0.8.17` and cannot be built under the frozen 0.8.26 compiler,
    # so its bidder surface is frozen from the pinned `IAllowanceTransfer` interface that
    # v4-periphery compiles. The interface is the ABI authority; the deployed runtime at the
    # canonical Permit2 address stays a fork claim.
    "IAllowanceTransfer": {
        "repository": "https://github.com/Uniswap/permit2",
        "functions": (
            "allowance(address,address,address)",
            "approve(address,address,uint160,uint48)",
            "permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)",
        ),
        "events": (),
    },
}


# =============================================================================
# keccak-256
# =============================================================================

_ROUND_CONSTANTS = (
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
)

_ROTATION_OFFSETS = (
    (0, 36, 3, 41, 18),
    (1, 44, 10, 45, 2),
    (62, 6, 43, 15, 61),
    (28, 55, 25, 21, 56),
    (27, 20, 39, 8, 14),
)

_MASK = (1 << 64) - 1


def _rotl(value: int, shift: int) -> int:
    return ((value << shift) | (value >> (64 - shift))) & _MASK


def _keccak_f(state: list[list[int]]) -> None:
    for round_constant in _ROUND_CONSTANTS:
        parity = [state[x][0] ^ state[x][1] ^ state[x][2] ^ state[x][3] ^ state[x][4] for x in range(5)]
        for x in range(5):
            spread = parity[(x - 1) % 5] ^ _rotl(parity[(x + 1) % 5], 1)
            for y in range(5):
                state[x][y] ^= spread

        rotated = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                rotated[y][(2 * x + 3 * y) % 5] = _rotl(state[x][y], _ROTATION_OFFSETS[x][y])

        for x in range(5):
            for y in range(5):
                state[x][y] = rotated[x][y] ^ ((~rotated[(x + 1) % 5][y] & _MASK) & rotated[(x + 2) % 5][y])

        state[0][0] ^= round_constant


def keccak256(data: bytes) -> str:
    """Ethereum's keccak-256: Keccak-f[1600], rate 136, padding byte 0x01."""
    rate = 136
    state = [[0] * 5 for _ in range(5)]

    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % rate != 0:
        padded.append(0x00)
    padded[-1] ^= 0x80

    for offset in range(0, len(padded), rate):
        block = padded[offset : offset + rate]
        for index in range(rate // 8):
            lane = int.from_bytes(block[index * 8 : index * 8 + 8], "little")
            state[index % 5][index // 5] ^= lane
        _keccak_f(state)

    # The digest is 32 bytes and the rate is 136, so one squeeze always suffices.
    out = b"".join(state[index % 5][index // 5].to_bytes(8, "little") for index in range(4))
    return "0x" + out.hex()


# =============================================================================
# ABI vocabulary
# =============================================================================


def canonical_type(entry: dict) -> str:
    """The canonical ABI type of one input or output, expanding tuples in place."""
    kind = entry["type"]
    if not kind.startswith("tuple"):
        # A solc ABI type is already canonical; only tuples need expanding.
        return kind
    inner = ",".join(canonical_type(component) for component in entry.get("components", []))
    return f"({inner}){kind[len('tuple'):]}"


def signature(entry: dict) -> str:
    inner = ",".join(canonical_type(item) for item in entry.get("inputs", []))
    return f"{entry['name']}({inner})"


def declared_shape(members: list[dict]) -> list[str]:
    """`<type> <name>` for every member, so a renamed or reordered field is visible."""
    return [f"{canonical_type(item)} {item.get('name', '')}".strip() for item in members]


# =============================================================================
# artifacts
# =============================================================================


def load_artifacts(out: Path) -> dict[str, dict]:
    """Every compiled artifact, keyed by `source:ContractName`."""
    artifacts: dict[str, dict] = {}
    for path in sorted(out.rglob("*.json")):
        if "build-info" in path.parts:
            continue
        try:
            artifact = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        target = (artifact.get("metadata") or {}).get("settings", {}).get("compilationTarget") or {}
        for source, name in target.items():
            artifacts[f"{source}:{name}"] = artifact
    return artifacts


def owned(artifacts: dict[str, dict]) -> dict[str, dict]:
    """The `src/**` artifacts, keyed by contract name; a duplicate name fails closed."""
    found: dict[str, dict] = {}
    for key, artifact in artifacts.items():
        source, _, name = key.rpartition(":")
        if not source.startswith("src/"):
            continue
        if name in found:
            raise SystemExit(f"freeze: two src/ artifacts are both named {name}")
        found[name] = {"source": source, "artifact": artifact}
    return found


def code(artifact: dict, field: str) -> bytes:
    obj = artifact[field]["object"]
    if not obj.startswith("0x"):
        raise SystemExit(f"freeze: {field} is not 0x-prefixed")
    return bytes.fromhex(obj[2:])


def verify_keccak(entries: dict[str, dict]) -> int:
    """Reconcile this file's keccak against solc's own `methodIdentifiers`.

    Every function selector solc recorded must equal the one derived here. That makes the
    hash implementation itself gate-checked evidence rather than an assumption.
    """
    checked = 0
    for name, record in sorted(entries.items()):
        identifiers = record["artifact"].get("methodIdentifiers") or {}
        for solc_signature, solc_selector in sorted(identifiers.items()):
            derived = keccak256(solc_signature.encode())[2:10]
            if derived != solc_selector:
                raise SystemExit(
                    f"freeze: keccak mismatch for {name}.{solc_signature}: "
                    f"solc says {solc_selector}, this file derives {derived}"
                )
            checked += 1
    if checked == 0:
        raise SystemExit("freeze: no solc method identifier was available to reconcile keccak against")
    return checked


# =============================================================================
# generated documents
# =============================================================================


def contract_abi_document(name: str, record: dict) -> dict:
    artifact = record["artifact"]
    return {
        "contract": name,
        "source": record["source"],
        "compiler": artifact["metadata"]["compiler"]["version"],
        "abi": artifact["abi"],
        "method_identifiers": dict(sorted((artifact.get("methodIdentifiers") or {}).items())),
    }


def surface_entry(name: str, record: dict) -> dict:
    abi = record["artifact"]["abi"]

    functions, mutating, views = [], [], []
    for entry in abi:
        if entry.get("type") != "function":
            continue
        line = f"{keccak256(signature(entry).encode())[:10]} {signature(entry)}"
        functions.append(line)
        (views if entry.get("stateMutability") in ("view", "pure") else mutating).append(line)

    events = []
    for entry in abi:
        if entry.get("type") != "event":
            continue
        indexed = sum(1 for item in entry["inputs"] if item.get("indexed"))
        events.append(f"{keccak256(signature(entry).encode())} {signature(entry)} indexed={indexed}")

    errors = [
        f"{keccak256(signature(entry).encode())[:10]} {signature(entry)}"
        for entry in abi
        if entry.get("type") == "error"
    ]

    structs = {}
    for entry in abi:
        if entry.get("type") != "function":
            continue
        for item in entry.get("inputs", []):
            if item.get("type", "").startswith("tuple"):
                # `_`-joined, never `.`-joined: a dot would be a path separator to every
                # JSON reader that later has to address this key.
                structs[f"{entry['name']}_{item.get('name', '')}"] = declared_shape(item["components"])

    constructor = next((entry for entry in abi if entry.get("type") == "constructor"), None)
    return {
        "source": record["source"],
        "constructor": declared_shape(constructor["inputs"]) if constructor else [],
        "functions": sorted(functions),
        "mutating_functions": sorted(mutating),
        "view_functions": sorted(views),
        "events": sorted(events),
        "errors": sorted(errors),
        "input_structs": dict(sorted(structs.items())),
    }


def abi_surface_document(entries: dict[str, dict], consumed: dict[str, dict]) -> dict:
    return {
        "purpose": (
            "The frozen external surface of every Regent production contract, derived from the "
            "compiler artifacts. Selectors and event topics are keccak over the canonical "
            "signature, so a changed integer width, a renamed field, a reordered tuple, or a "
            "changed indexed flag all change the recorded line. test/abi/** reads this file as "
            "its authority and reconciles every line against compiler truth."
        ),
        "contracts": {name: surface_entry(name, entries[name]) for name in PRODUCTION_CONTRACTS},
        "consumed": consumed,
    }


def constructor_args_bytes(record: dict) -> int:
    """The exact ABI-encoded head length of a constructor's arguments.

    Every production constructor takes only 32-byte static words, so the head is the whole
    encoding. A dynamic argument would need a real encoder and fails closed here instead.
    """
    constructor = next((e for e in record["artifact"]["abi"] if e.get("type") == "constructor"), None)
    if constructor is None:
        return 0
    total = 0
    for item in constructor["inputs"]:
        kind = canonical_type(item)
        if kind.startswith(("address", "bool", "bytes32", "uint", "int")) and not kind.endswith("]"):
            total += 32
        else:
            raise SystemExit(f"freeze: constructor argument type {kind} needs a real ABI encoder")
    return total


def clone_template() -> dict:
    """The exact minimal-proxy runtime the production strategy admits, read from its source."""
    match = re.search(CLONE_TEMPLATE_RE, Path(CLONE_TEMPLATE_SOURCE).read_text(encoding="utf-8"))
    if match is None:
        raise SystemExit(f"freeze: {CLONE_TEMPLATE_SOURCE} no longer derives a clone code hash inline")
    prefix, suffix = match.group(1), match.group(2)
    return {
        "prefix": prefix,
        "suffix": suffix,
        "runtime_bytes": len(prefix) // 2 + 20 + len(suffix) // 2,
        "template": f"0x{prefix}<20-byte implementation>{suffix}",
        "derived_from": CLONE_TEMPLATE_SOURCE,
    }


def sizes_document(entries: dict[str, dict]) -> dict:
    contracts = []
    for name in PRODUCTION_CONTRACTS:
        record = entries[name]
        runtime = code(record["artifact"], "deployedBytecode")
        creation = code(record["artifact"], "bytecode")
        args = constructor_args_bytes(record)
        contracts.append({
            "contract": name,
            "source": record["source"],
            "runtime_bytes": len(runtime),
            "runtime_margin_bytes": EIP170_RUNTIME_LIMIT - len(runtime),
            "creation_bytes": len(creation),
            "constructor_args_bytes": args,
            "initcode_bytes": len(creation) + args,
            "initcode_margin_bytes": EIP3860_INITCODE_LIMIT - len(creation) - args,
        })

    template = clone_template()
    clones = [{
        "clone_of": name,
        "runtime_bytes": template["runtime_bytes"],
        "runtime_margin_bytes": EIP170_RUNTIME_LIMIT - template["runtime_bytes"],
    } for name in CLONE_TARGETS]

    return {
        "purpose": (
            "Deployable byte margins for GAS-001 and GAS-002. Runtime and creation lengths come "
            "from the compiler artifacts; the constructor-argument length is the exact ABI head "
            "the deployment packet will append, which the compiler's size report excludes. A "
            "clone's own deployment initcode is Solady's and is measured directly by GAS-002."
        ),
        "limits": {
            "eip170_runtime_bytes": EIP170_RUNTIME_LIMIT,
            "eip3860_initcode_bytes": EIP3860_INITCODE_LIMIT,
        },
        "contracts": contracts,
        "clone_runtime_template": template,
        "clones": clones,
    }


def consumed_document(artifacts: dict[str, dict]) -> dict:
    """The pinned upstream call and event surface this repository depends on.

    Each recorded signature must exist in the pinned dependency's own compiled artifact, so
    an upstream rename cannot pass unnoticed.
    """
    by_name: dict[str, list[dict]] = {}
    for key, artifact in artifacts.items():
        source, _, name = key.rpartition(":")
        if source.startswith("src/"):
            continue
        by_name.setdefault(name, []).append(artifact)

    document = {}
    for name, wanted in sorted(CONSUMED_SURFACES.items()):
        candidates = by_name.get(name) or []
        available_functions: set[str] = set()
        available_events: set[str] = set()
        for artifact in candidates:
            available_functions |= set((artifact.get("methodIdentifiers") or {}).keys())
            available_events |= {
                signature(entry) for entry in artifact.get("abi", []) if entry.get("type") == "event"
            }
        if not candidates:
            raise SystemExit(f"freeze: the pinned build produced no artifact named {name}")

        functions = []
        for item in wanted["functions"]:
            if item not in available_functions:
                raise SystemExit(f"freeze: pinned {name} no longer declares {item}")
            functions.append(f"{keccak256(item.encode())[:10]} {item}")
        events = []
        for item in wanted["events"]:
            if item not in available_events:
                raise SystemExit(f"freeze: pinned {name} no longer declares event {item}")
            events.append(f"{keccak256(item.encode())} {item}")

        document[name] = {
            "repository": wanted["repository"],
            "functions": sorted(functions),
            "events": sorted(events),
        }
    return document


def manifest_document(entries: dict[str, dict], frozen: dict, chain: dict, consumed: dict) -> dict:
    contracts = {}
    for name in PRODUCTION_CONTRACTS:
        record = entries[name]
        runtime = code(record["artifact"], "deployedBytecode")
        creation = code(record["artifact"], "bytecode")
        contracts[name] = {
            "source": record["source"],
            "compiler": record["artifact"]["metadata"]["compiler"]["version"],
            "runtime_bytes": len(runtime),
            "runtime_sha256": hashlib.sha256(runtime).hexdigest(),
            "creation_bytes": len(creation),
            "creation_sha256": hashlib.sha256(creation).hexdigest(),
            "constructor": surface_entry(name, record)["constructor"],
            "abi_file": f"abi/{name}.json",
            "deployment": {"address": None, "status": "deployment_pending"},
        }

    template = clone_template()
    clones = {
        name: {
            "implementation": {"address": None, "status": "deployment_pending"},
            "library": "solady/utils/LibClone.sol",
            "runtime_template": template["template"],
            "runtime_bytes": template["runtime_bytes"],
            "derived_from": template["derived_from"],
            "authority": "DEP-060 proves this derivation against a real clone and the frozen artifacts",
        }
        for name in CLONE_TARGETS
    }

    bindings = {}
    for entry in frozen["bindings"]:
        bindings[entry["key"]] = {
            "label": entry["label"],
            "constant": entry["constant"],
            "address": entry["address"],
            "runtime_code_hash": None,
            "proxy": None,
            "implementation": None,
            "status": "fork_pending",
        }
    bindings["cca_factory"]["runtime_code_hash"] = frozen["admission"]["runtime_code_hash"]
    bindings["cca_factory"]["status"] = "frozen_expectation_fork_pending"

    return {
        "version": 1,
        "repository": "autolaunch-contracts",
        "authority": "SPEC.md",
        "generated_by": "bin/freeze-artifacts.py",
        "release_posture": "local implementation and proof only; mainnet remains NO-GO",
        "chain": {"name": chain["name"], "id": chain["id"]},
        "build": {
            "solc_identity": frozen["build"]["solc_identity"],
            "evm_version": frozen["build"]["evm_version"],
            "optimizer_runs": frozen["build"]["optimizer_runs"],
            "via_ir": frozen["build"]["via_ir"],
            "bytecode_hash": frozen["build"]["bytecode_hash"],
            "append_cbor": frozen["build"]["append_cbor"],
        },
        "surface_allowlist": list(PRODUCTION_CONTRACTS),
        "contracts": contracts,
        "clones": clones,
        "bindings": bindings,
        "consumed": consumed,
        "hook_deployment": {
            "contract": "RegentFeeHook",
            "create2_deployer": "RegentsAutolaunchFactoryV1",
            "constructor": surface_entry("RegentFeeHook", entries["RegentFeeHook"])["constructor"],
            "salt": {"value": None, "status": "deployment_pending"},
            "permission_authority": (
                "BaseHook.validateHookAddress at construction; HOK-004 proves the mined address "
                "carries exactly the declared permission bits"
            ),
        },
        "deployment_pending_note": (
            "No Regent contract is deployed. Every Regent address in this manifest is null with "
            "status deployment_pending, and every external binding's runtime fact is null with "
            "status fork_pending until the separately authorized fork gate records it."
        ),
    }


def render(document: object) -> str:
    return json.dumps(document, indent=2, ensure_ascii=False) + "\n"


# =============================================================================
# baseline reconciliation
# =============================================================================


def check_runtime_baseline(entries: dict[str, dict], artifacts: dict[str, dict], baseline_path: Path) -> str:
    """Prove the C5 build's `src/**` bytes are the exact pre-edit C4 bytes.

    The baseline was captured from the pristine C4 build before this ticket edited any file,
    so it is an authority this candidate cannot have produced.
    """
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    recorded = baseline["contracts"]

    found = {}
    for key, artifact in artifacts.items():
        source, _, name = key.rpartition(":")
        if not source.startswith("src/"):
            continue
        runtime = code(artifact, "deployedBytecode")
        creation = code(artifact, "bytecode")
        found[key] = {
            "runtime_bytes": len(runtime),
            "runtime_sha256": hashlib.sha256(runtime).hexdigest(),
            "creation_bytes": len(creation),
            "creation_sha256": hashlib.sha256(creation).hexdigest(),
        }

    problems = []
    for key in sorted(set(recorded) - set(found)):
        problems.append(f"the C4 baseline records {key}, which this build does not produce")
    for key in sorted(set(found) - set(recorded)):
        problems.append(f"this build produces {key}, which the C4 baseline does not record")
    for key in sorted(set(found) & set(recorded)):
        for field in ("runtime_bytes", "runtime_sha256", "creation_bytes", "creation_sha256"):
            if recorded[key][field] != found[key][field]:
                problems.append(
                    f"{key}: {field} is {found[key][field]}, the C4 baseline records {recorded[key][field]}"
                )
    if problems:
        print("FREEZE RECONCILIATION FAILED", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        raise SystemExit(1)

    for name in PRODUCTION_CONTRACTS:
        if f"{entries[name]['source']}:{name}" not in recorded:
            raise SystemExit(f"freeze: the C4 baseline does not cover the production contract {name}")

    return (
        f"all {len(found)} src/** contracts compile to the exact runtime and creation byte strings "
        f"captured from C4 {baseline['captured_from_commit'][:12]} before any C5 edit"
    )


# =============================================================================


def run(args: argparse.Namespace) -> int:
    out = Path(args.out)
    artifacts = load_artifacts(out)
    entries = owned(artifacts)

    missing = [name for name in PRODUCTION_CONTRACTS if name not in entries]
    if missing:
        raise SystemExit(f"freeze: the build produced no artifact for {', '.join(missing)}")

    selectors_checked = verify_keccak(entries)

    frozen = json.loads(Path(args.frozen).read_text(encoding="utf-8"))
    consumed = consumed_document(artifacts)

    documents: dict[Path, str] = {
        Path("reports/frozen/abi-surface.json"): render(abi_surface_document(entries, consumed)),
        Path("reports/frozen/deployable-sizes.json"): render(sizes_document(entries)),
        Path(args.manifest): render(manifest_document(entries, frozen, frozen["chain"], consumed)),
    }
    for name in PRODUCTION_CONTRACTS:
        documents[Path(f"abi/{name}.json")] = render(contract_abi_document(name, entries[name]))

    if args.mode == "write":
        for path, body in documents.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body, encoding="utf-8")
            print(f"wrote {path}")
        return 0

    problems = []
    for path, body in sorted(documents.items()):
        if not path.is_file():
            problems.append(f"{path} is missing; the freezer generates it")
        elif path.read_text(encoding="utf-8") != body:
            problems.append(f"{path} differs from what the current build generates")
    if problems:
        print("FREEZE RECONCILIATION FAILED", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    baseline_detail = check_runtime_baseline(entries, artifacts, Path(args.baseline))

    with Path(args.receipt).open("a", encoding="utf-8") as handle:
        handle.write(
            f"DEP-016 verified: bin/freeze-artifacts.py check regenerated {len(documents)} frozen "
            f"documents byte for byte from {len(artifacts)} compiled artifacts, reconciled "
            f"{selectors_checked} solc method identifiers against its own keccak, and proved "
            f"{baseline_detail}\n"
        )

    print(f"frozen documents reconciled: {len(documents)}")
    print(f"solc method identifiers reconciled against derived keccak: {selectors_checked}")
    print(f"C4 runtime baseline: {baseline_detail}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("write", "check"))
    parser.add_argument("--out", default="out")
    parser.add_argument("--frozen", default="requirements/frozen-identity.json")
    parser.add_argument("--manifest", default="contracts/autolaunch-release-manifest.json")
    parser.add_argument("--baseline", default="reports/frozen/c4-runtime-baseline.json")
    parser.add_argument("--receipt", default="reports/generated/dependency-receipt.txt")
    return run(parser.parse_args())


if __name__ == "__main__":
    sys.exit(main())
