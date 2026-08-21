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
         every `src/**` compiled byte string against the independently captured pre-edit C4
         baseline in `reports/frozen/c4-runtime-baseline.json`, allowing exactly the
         contracts the frozen `final_source_delta` record names — each with a written
         reason, and each of which must really differ — to have moved, and appends its own
         verified receipt line so deleting the gate's freezer invocation makes the ledger
         reconciliation fail for `DEP-016`.

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
import subprocess
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

# Contracts the deployment ceremony deploys that this repository does not own. They are pinned
# dependency builds, but the ceremony still has to deploy them, so their exact build, byte
# lengths, margins and EVM code identity are frozen here beside the production six.
#
# `runtime_immutables` records how many immutable references the compiler left in the artifact
# runtime. A contract with none has an artifact runtime that *is* the deployed runtime, so its
# keccak-256 is the EVM codehash a deployed instance presents; a contract with immutables does
# not, and its per-deployment codehash is recorded as such rather than pretended to be frozen.
DEPENDENCY_CONTRACTS = {
    "UERC20Factory": {
        "source": "lib/uerc20-factory/src/factories/UERC20Factory.sol",
        "role": (
            "the pinned token factory the Autolaunch factory constructor admits by exact runtime "
            "code hash and every launch creates its SUBJECT through"
        ),
        "deployed_by_ceremony": True,
    },
    "UERC20": {
        "source": "lib/uerc20-factory/src/tokens/UERC20.sol",
        "role": (
            "the per-launch SUBJECT build the pinned factory CREATE2-deploys inside every launch "
            "transaction; it is never deployed by the ceremony itself"
        ),
        "deployed_by_ceremony": False,
    },
}

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
    #
    # This is the founder-selected allowance flow and nothing else: a bidder grants an ERC20
    # approval to the canonical Permit2 and then an `approve` allowance to the auction, and the
    # auction reads it with `allowance`. No signature-carrying `permit`, no batched variant and
    # no `permitTransferFrom` is consumed anywhere in this repository, so none is frozen here —
    # recording one would imply a product surface that does not exist.
    "IAllowanceTransfer": {
        "repository": "https://github.com/Uniswap/permit2",
        "functions": (
            "allowance(address,address,address)",
            "approve(address,address,uint160,uint48)",
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


def event_shape(members: list[dict]) -> list[str]:
    """`<type>[ indexed] <name>` for every event argument, in declaration order.

    An indexed *count* cannot tell `Foo(address indexed a, uint256 b)` from
    `Foo(address a, uint256 indexed b)`: both carry one indexed field, and both would occupy
    the same recorded line. This records which field, at which position, under which name and
    at which exact width, so moving `indexed` from one argument to another changes the frozen
    record even though the topic and the count are unchanged.
    """
    return [
        f"{canonical_type(item)}{' indexed' if item.get('indexed') else ''} {item.get('name', '')}".strip()
        for item in members
    ]


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

    # Keyed by event name, not by signature: a JSON path segment has to be addressable, and an
    # event name is. A repeated name would make that key ambiguous, so it fails closed instead.
    events, event_fields = [], {}
    for entry in abi:
        if entry.get("type") != "event":
            continue
        indexed = sum(1 for item in entry["inputs"] if item.get("indexed"))
        events.append(f"{keccak256(signature(entry).encode())} {signature(entry)} indexed={indexed}")
        if entry["name"] in event_fields:
            raise SystemExit(f"freeze: {name} declares two events named {entry['name']}")
        event_fields[entry["name"]] = event_shape(entry["inputs"])

    errors = [
        f"{keccak256(signature(entry).encode())[:10]} {signature(entry)}"
        for entry in abi
        if entry.get("type") == "error"
    ]

    structs, returns = {}, {}
    for entry in abi:
        if entry.get("type") != "function":
            continue
        for item in entry.get("inputs", []):
            if item.get("type", "").startswith("tuple"):
                # `_`-joined, never `.`-joined: a dot would be a path separator to every
                # JSON reader that later has to address this key.
                structs[f"{entry['name']}_{item.get('name', '')}"] = declared_shape(item["components"])
        # Return tuples are frozen exactly as input tuples are. A consumer decodes a returned
        # struct positionally, so a reordered, renamed, added or rewidened return field breaks
        # it just as surely as an input one, and nothing in a function selector records it.
        for index, item in enumerate(entry.get("outputs", [])):
            if item.get("type", "").startswith("tuple"):
                returns[f"{entry['name']}_return{index}"] = declared_shape(item["components"])

    constructor = next((entry for entry in abi if entry.get("type") == "constructor"), None)
    return {
        "source": record["source"],
        "constructor": declared_shape(constructor["inputs"]) if constructor else [],
        "functions": sorted(functions),
        "mutating_functions": sorted(mutating),
        "view_functions": sorted(views),
        "events": sorted(events),
        "event_fields": dict(sorted(event_fields.items())),
        "errors": sorted(errors),
        "input_structs": dict(sorted(structs.items())),
        "return_structs": dict(sorted(returns.items())),
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


def code_identity(artifact: dict) -> dict:
    """Every byte-level identity one artifact has, EVM-native first.

    `runtime_keccak256` is the EVM `EXTCODEHASH` of a deployed instance whenever the artifact
    carries no immutable references, which is exactly the identity the production constructors
    admit by. SHA-256 is kept beside it as a second, non-EVM digest for packet diffing; it is
    never the identity anything is admitted by.
    """
    runtime = code(artifact, "deployedBytecode")
    creation = code(artifact, "bytecode")
    immutables = len(artifact["deployedBytecode"].get("immutableReferences") or {})
    return {
        "compiler": artifact["metadata"]["compiler"]["version"],
        "runtime_bytes": len(runtime),
        "runtime_keccak256": keccak256(runtime),
        "runtime_sha256": hashlib.sha256(runtime).hexdigest(),
        "runtime_immutable_references": immutables,
        "runtime_keccak256_is_deployed_codehash": immutables == 0,
        "creation_bytes": len(creation),
        "creation_keccak256": keccak256(creation),
        "creation_sha256": hashlib.sha256(creation).hexdigest(),
    }


def dependency_entries(artifacts: dict[str, dict]) -> dict[str, dict]:
    """The pinned dependency builds the ceremony needs, keyed by exact source path."""
    found = {}
    for name, wanted in DEPENDENCY_CONTRACTS.items():
        key = f"{wanted['source']}:{name}"
        artifact = artifacts.get(key)
        if artifact is None:
            raise SystemExit(f"freeze: the pinned build produced no artifact at {key}")
        found[name] = {"source": wanted["source"], "artifact": artifact}
    return found


def dependency_document(dependencies: dict[str, dict]) -> list[dict]:
    rows = []
    for name, wanted in DEPENDENCY_CONTRACTS.items():
        record = dependencies[name]
        identity = code_identity(record["artifact"])
        rows.append({
            "contract": name,
            "source": record["source"],
            "role": wanted["role"],
            "deployed_by_ceremony": wanted["deployed_by_ceremony"],
            **identity,
            "runtime_margin_bytes": EIP170_RUNTIME_LIMIT - identity["runtime_bytes"],
            "initcode_margin_bytes": EIP3860_INITCODE_LIMIT - identity["creation_bytes"],
            "constructor": surface_entry(name, record)["constructor"],
        })
    return rows


def sizes_document(entries: dict[str, dict], dependencies: dict[str, dict]) -> dict:
    contracts = []
    for name in PRODUCTION_CONTRACTS:
        record = entries[name]
        identity = code_identity(record["artifact"])
        args = constructor_args_bytes(record)
        contracts.append({
            "contract": name,
            "source": record["source"],
            **identity,
            "runtime_margin_bytes": EIP170_RUNTIME_LIMIT - identity["runtime_bytes"],
            "constructor": surface_entry(name, record)["constructor"],
            "constructor_args_bytes": args,
            "initcode_bytes": identity["creation_bytes"] + args,
            "initcode_margin_bytes": EIP3860_INITCODE_LIMIT - identity["creation_bytes"] - args,
        })

    template = clone_template()
    clones = [{
        "clone_of": name,
        "implementation_runtime_keccak256": keccak256(code(entries[name]["artifact"], "deployedBytecode")),
        "runtime_bytes": template["runtime_bytes"],
        "runtime_margin_bytes": EIP170_RUNTIME_LIMIT - template["runtime_bytes"],
    } for name in CLONE_TARGETS]

    return {
        "purpose": (
            "Deployable byte margins and EVM code identity for GAS-001 and GAS-002. Runtime and "
            "creation lengths and hashes come from the compiler artifacts; the "
            "constructor-argument length is the exact ABI head the deployment packet will "
            "append, which the compiler's size report excludes. A clone's own deployment "
            "initcode is Solady's and is measured directly by GAS-002, and a clone's EVM "
            "codehash is keccak over the 44-byte runtime its own implementation address "
            "completes, so it exists only once that implementation is deployed."
        ),
        "limits": {
            "eip170_runtime_bytes": EIP170_RUNTIME_LIMIT,
            "eip3860_initcode_bytes": EIP3860_INITCODE_LIMIT,
        },
        "contracts": contracts,
        "dependency_contracts": dependency_document(dependencies),
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
        available_events: dict[str, dict] = {}
        for artifact in candidates:
            available_functions |= set((artifact.get("methodIdentifiers") or {}).keys())
            for entry in artifact.get("abi", []):
                if entry.get("type") == "event":
                    available_events.setdefault(signature(entry), entry)
        if not candidates:
            raise SystemExit(f"freeze: the pinned build produced no artifact named {name}")

        functions = []
        for item in wanted["functions"]:
            if item not in available_functions:
                raise SystemExit(f"freeze: pinned {name} no longer declares {item}")
            functions.append(f"{keccak256(item.encode())[:10]} {item}")

        # A consumed event is frozen with the same indexed-field identity a produced one is.
        # Topic position is what a watcher decodes by, so `BidSubmitted`'s two indexed fields
        # are pinned by name, position and width here rather than by a count.
        events, event_fields = [], {}
        for item in wanted["events"]:
            entry = available_events.get(item)
            if entry is None:
                raise SystemExit(f"freeze: pinned {name} no longer declares event {item}")
            indexed = sum(1 for field in entry["inputs"] if field.get("indexed"))
            events.append(f"{keccak256(item.encode())} {item} indexed={indexed}")
            event_fields[entry["name"]] = event_shape(entry["inputs"])

        document[name] = {
            "repository": wanted["repository"],
            "functions": sorted(functions),
            "events": sorted(events),
            "event_fields": dict(sorted(event_fields.items())),
        }
    return document


def manifest_document(
    entries: dict[str, dict], dependencies: dict[str, dict], frozen: dict, chain: dict, consumed: dict
) -> dict:
    contracts = {}
    for name in PRODUCTION_CONTRACTS:
        record = entries[name]
        contracts[name] = {
            "source": record["source"],
            **code_identity(record["artifact"]),
            "constructor": surface_entry(name, record)["constructor"],
            "abi_file": f"abi/{name}.json",
            "deployment": {"address": None, "status": "deployment_pending"},
        }
    for name, wanted in DEPENDENCY_CONTRACTS.items():
        record = dependencies[name]
        contracts[name] = {
            "source": record["source"],
            **code_identity(record["artifact"]),
            "constructor": surface_entry(name, record)["constructor"],
            "abi_file": None,
            "role": wanted["role"],
            "deployment": {
                "address": None,
                "status": "deployment_pending" if wanted["deployed_by_ceremony"] else "created_per_launch",
            },
        }

    template = clone_template()
    clones = {
        name: {
            "implementation": {"address": None, "status": "deployment_pending"},
            "library": "solady/utils/LibClone.sol",
            "runtime_template": template["template"],
            "runtime_bytes": template["runtime_bytes"],
            "derived_from": template["derived_from"],
            "implementation_runtime_keccak256": keccak256(code(entries[name]["artifact"], "deployedBytecode")),
            "clone_runtime_keccak256": {
                "value": None,
                "status": "deployment_pending",
                "derivation": (
                    f"keccak256(0x{template['prefix']} ++ <20-byte {name} implementation> ++ "
                    f"0x{template['suffix']}); the implementation address is the only unknown, so this "
                    "identity exists the moment that address does"
                ),
            },
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
            "implementation_runtime_code_hash": None,
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


def git(*args: str) -> str | None:
    """Run git and return its stdout, or None if it failed."""
    result = subprocess.run(["git", *args], capture_output=True, text=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def check_baseline_provenance(baseline_path: Path, provenance: dict) -> str:
    """Prove the baseline record really is the independent pre-edit capture it claims to be.

    A `captured_from_commit` field inside the record is a self-declaration: the same hand that
    could edit the numbers could edit that string. Git is the authority instead, and all five
    relations below have to hold at once:

      1. the working file is byte-identical to the blob the capture commit committed, so the
         record has not been touched since it was captured;
      2. the capture commit sits *directly* on the integrated C4 commit, so nothing landed in
         between;
      3. the capture commit's whole `src` tree equals integrated C4's, so the capture was taken
         before this ticket's one permitted comment edit rather than after it;
      4. the record's own `captured_from_commit` names that integrated C4 commit; and
      5. the record's own `captured_from_tree` is that commit's real tree.

    Forging this needs a rewritten history, not an edited file.
    """
    capture = provenance["capture_commit"]
    c4 = provenance["integrated_c4_commit"]
    path = provenance["path"]
    problems = []

    committed_blob = git("rev-parse", f"{capture}:{path}")
    working_blob = git("hash-object", str(baseline_path))
    if committed_blob is None:
        problems.append(f"the capture commit {capture[:12]} commits no {path}")
    elif committed_blob != working_blob:
        problems.append(
            f"{path} is {working_blob}, but the capture commit {capture[:12]} committed {committed_blob}"
        )

    parent = git("rev-parse", f"{capture}^")
    if parent != c4:
        problems.append(
            f"the capture commit {capture[:12]} sits on {parent}, not on integrated C4 {c4[:12]}"
        )

    capture_src = git("rev-parse", f"{capture}:src")
    c4_src = git("rev-parse", f"{c4}:src")
    if capture_src is None or c4_src is None:
        problems.append("cannot read the src tree of the capture commit or of integrated C4")
    elif capture_src != c4_src:
        problems.append(
            f"the capture commit's src tree {capture_src} is not integrated C4's {c4_src}; "
            "the baseline was not captured before any src edit"
        )

    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    if baseline.get("captured_from_commit") != c4:
        problems.append(
            f"{path} declares it was captured from {baseline.get('captured_from_commit')}, "
            f"not from integrated C4 {c4}"
        )
    c4_tree = git("rev-parse", f"{c4}^{{tree}}")
    if baseline.get("captured_from_tree") != c4_tree:
        problems.append(
            f"{path} declares C4 tree {baseline.get('captured_from_tree')}, but {c4[:12]} is {c4_tree}"
        )

    if problems:
        print("FREEZE RECONCILIATION FAILED", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        raise SystemExit(1)

    return (
        f"{path} is byte-identical to the blob capture commit {capture[:12]} committed directly on "
        f"integrated C4 {c4[:12]}, whose src tree {c4_src} it shares"
    )


def check_runtime_baseline(
    entries: dict[str, dict], artifacts: dict[str, dict], baseline_path: Path, delta: dict
) -> str:
    """Prove exactly which `src/**` production bytes moved away from the pre-edit C4 capture.

    Through C5 this was an all-or-nothing byte equality, which was the right claim while the only
    production edit was a comment. It is the wrong claim the moment a successor has to change
    production behaviour, and quietly relaxing it would have been worse than replacing it. So the
    claim is now enumerated rather than universal:

      - the historical C4 capture itself is untouched, and `check_baseline_provenance` still proves
        against Git that it is the blob its capture commit committed directly on integrated C4;
      - the frozen identity names an exact, closed set of contracts that are allowed to differ,
        each with a written reason;
      - every named contract must *actually* differ, so the record cannot quietly authorize more
        movement than really happened and cannot survive as a standing exemption;
      - every other `src/**` contract's runtime and creation bytes must still equal C4 exactly.

    What this proves is which bytes moved. It deliberately does not try to prove *why*: the source
    diff and independent review are what establish that, and a gate that claimed to check intent
    would be claiming something it cannot see.
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

    allowed = {entry["key"]: entry for entry in delta["changed"]}
    problems = []

    for key in sorted(set(recorded) - set(found)):
        problems.append(f"the C4 baseline records {key}, which this build does not produce")
    for key in sorted(set(found) - set(recorded)):
        problems.append(f"this build produces {key}, which the C4 baseline does not record")
    for key in sorted(allowed):
        if key not in found:
            problems.append(f"the final-source-delta record names {key}, which this build does not produce")
        if not str(allowed[key].get("reason", "")).strip():
            problems.append(f"the final-source-delta record gives no reason for {key}")

    fields = ("runtime_bytes", "runtime_sha256", "creation_bytes", "creation_sha256")
    moved = []
    for key in sorted(set(found) & set(recorded)):
        differs = [field for field in fields if recorded[key][field] != found[key][field]]
        if key in allowed:
            if not differs:
                problems.append(
                    f"{key} is named in the final-source-delta record but its bytes are identical to "
                    "C4's; the record must name only what actually moved"
                )
            else:
                moved.append(
                    f"{key} runtime {recorded[key]['runtime_sha256'][:12]}->{found[key]['runtime_sha256'][:12]}, "
                    f"creation {recorded[key]['creation_sha256'][:12]}->{found[key]['creation_sha256'][:12]}"
                )
            continue
        for field in differs:
            problems.append(
                f"{key}: {field} is {found[key][field]}, the C4 baseline records {recorded[key][field]}, "
                "and this contract is not in the final-source-delta record"
            )

    if problems:
        print("FREEZE RECONCILIATION FAILED", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        raise SystemExit(1)

    for name in PRODUCTION_CONTRACTS:
        if f"{entries[name]['source']}:{name}" not in recorded:
            raise SystemExit(f"freeze: the C4 baseline does not cover the production contract {name}")

    unchanged = len(found) - len(allowed)
    return (
        f"exactly {len(allowed)} of {len(found)} src/** contracts differ from the C4 "
        f"{baseline['captured_from_commit'][:12]} capture, each named with a reason in the frozen "
        f"final-source-delta record ({'; '.join(moved)}), and the other {unchanged} compile to the "
        "exact runtime and creation byte strings C4 captured"
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
    dependencies = dependency_entries(artifacts)

    documents: dict[Path, str] = {
        Path("reports/frozen/abi-surface.json"): render(abi_surface_document(entries, consumed)),
        Path("reports/frozen/deployable-sizes.json"): render(sizes_document(entries, dependencies)),
        Path(args.manifest): render(
            manifest_document(entries, dependencies, frozen, frozen["chain"], consumed)
        ),
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

    provenance_detail = check_baseline_provenance(Path(args.baseline), frozen["c4_baseline"])
    baseline_detail = check_runtime_baseline(entries, artifacts, Path(args.baseline), frozen["final_source_delta"])

    with Path(args.receipt).open("a", encoding="utf-8") as handle:
        handle.write(
            f"DEP-016 verified: bin/freeze-artifacts.py check regenerated {len(documents)} frozen "
            f"documents byte for byte from {len(artifacts)} compiled artifacts, reconciled "
            f"{selectors_checked} solc method identifiers against its own keccak, proved "
            f"{provenance_detail}, and proved {baseline_detail}\n"
        )

    print(f"frozen documents reconciled: {len(documents)}")
    print(f"solc method identifiers reconciled against derived keccak: {selectors_checked}")
    print(f"C4 baseline provenance: {provenance_detail}")
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
