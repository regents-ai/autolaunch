#!/usr/bin/env python3
"""Deterministic freezer for a Memestake contracts package (Base `contracts/stocks`, Robinhood
`contracts/robinhood`).

Every committed file under `abi/` and every document under `reports/frozen/` is *generated* from
the exact compiler artifacts in `out/`, the pinned dependency snapshot and Foundry's own compiled
test listing. Nothing here is hand written, and nothing here restates a value the compiler already
decided. The package's `requirements/freeze.json` names what is frozen: the production contracts,
the clone targets, the hook and its permission bits, the admitted dependency builds, and the
dependency snapshot.

Two modes:

  write  Run `forge clean`, `forge build` and `forge test --list --json`, then regenerate every
         frozen output from that build.
  check  Regenerate into memory from the build the gate just made and the test listing the gate
         just took, and compare byte for byte with the committed files. Any drift — a changed
         runtime byte, a hand-edited ABI, a renamed event, a changed integer width, a deleted or
         renamed test, a changed dependency file — fails closed. Check mode appends its own verified
         receipt line so the gate's report carries what was reconciled.

The keccak-256 used for selectors and event topics is implemented here rather than imported, so the
gate needs no package. It is not trusted on its word: every function selector it derives is
reconciled against solc's own `methodIdentifiers` for the same artifact before any output is
produced, so a wrong hash cannot reach a frozen file.
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

EIP170_RUNTIME_LIMIT = 24_576
EIP3860_INITCODE_LIMIT = 49_152

# Uniswap v4 hook permission bits, as `lib/v4-core/src/libraries/Hooks.sol` declares them. A hook's
# address must carry exactly the bits its permissions declare, which is why every hook here is
# deployed with a mined CREATE2 salt. The frozen record names the bits by name and reconciles them
# against the deploy script's own `HOOK_FLAGS` expression, so the two cannot drift apart.
HOOK_FLAG_BITS = {
    "BEFORE_INITIALIZE": 1 << 13,
    "AFTER_INITIALIZE": 1 << 12,
    "BEFORE_ADD_LIQUIDITY": 1 << 11,
    "AFTER_ADD_LIQUIDITY": 1 << 10,
    "BEFORE_REMOVE_LIQUIDITY": 1 << 9,
    "AFTER_REMOVE_LIQUIDITY": 1 << 8,
    "BEFORE_SWAP": 1 << 7,
    "AFTER_SWAP": 1 << 6,
    "BEFORE_DONATE": 1 << 5,
    "AFTER_DONATE": 1 << 4,
    "BEFORE_SWAP_RETURNS_DELTA": 1 << 3,
    "AFTER_SWAP_RETURNS_DELTA": 1 << 2,
    "AFTER_ADD_LIQUIDITY_RETURNS_DELTA": 1 << 1,
    "AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA": 1 << 0,
}
HOOK_FLAGS_SOURCE_RE = re.compile(r"HOOK_FLAGS\s*=\s*uint160\((?P<body>[^;]*)\);", re.S)
HOOK_FLAG_NAME_RE = re.compile(r"Hooks\.(\w+)_FLAG")

# Solady's `LibClone.clone(address)` minimal-proxy runtime, read out of the pinned library source
# rather than transcribed here: the initcode constant carries the 10-byte runtime prefix after its
# own 11-byte creation prologue, and the 15-byte suffix sits in the next word. The runtime a clone
# presents is `prefix ++ <20-byte implementation> ++ suffix`, 45 bytes.
CLONE_PREFIX_RE = re.compile(r"0xfe61002d3d81600a3d39f3(?P<prefix>363d3d373d3d3d363d73)\b")
CLONE_SUFFIX_RE = re.compile(r"0x(?P<suffix>5af43d82803e903d91602b57fd5bf3)\)")

LINK_PLACEHOLDER_RE = re.compile(r"__\$[0-9a-f]{34}\$__")


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

    out = b"".join(state[index % 5][index // 5].to_bytes(8, "little") for index in range(4))
    return "0x" + out.hex()


# =============================================================================
# ABI vocabulary
# =============================================================================


def canonical_type(entry: dict) -> str:
    """The canonical ABI type of one input or output, expanding tuples in place."""
    kind = entry["type"]
    if not kind.startswith("tuple"):
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
    """`<type>[ indexed] <name>` for every event argument, in declaration order, so moving
    `indexed` from one argument to another changes the frozen record even though the topic and
    the indexed count are unchanged."""
    return [
        f"{canonical_type(item)}{' indexed' if item.get('indexed') else ''} {item.get('name', '')}".strip()
        for item in members
    ]


def static_words(entry: dict) -> int:
    """How many 32-byte head words one static ABI value occupies; a dynamic value fails closed."""
    kind = entry["type"]
    if kind.startswith("tuple"):
        if kind != "tuple":
            raise SystemExit(f"freeze: constructor argument type {canonical_type(entry)} needs a real ABI encoder")
        return sum(static_words(component) for component in entry.get("components", []))
    if kind.startswith(("address", "bool", "bytes32", "uint", "int")) and not kind.endswith("]"):
        return 1
    raise SystemExit(f"freeze: constructor argument type {kind} needs a real ABI encoder")


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
            # solc records a source reached through `allow_paths` outside the package root by its
            # absolute path. The freeze is machine-independent, so every source is keyed relative
            # to the package root, which is where the gate runs.
            if os.path.isabs(source):
                source = Path(os.path.relpath(source, Path.cwd())).as_posix()
            artifacts[f"{source}:{name}"] = artifact
    return artifacts


def owned(artifacts: dict[str, dict], prefixes: tuple[str, ...]) -> dict[str, dict]:
    """The artifacts compiled from this package's own source roots, keyed by contract name."""
    found: dict[str, dict] = {}
    for key, artifact in artifacts.items():
        source, _, name = key.rpartition(":")
        if not source.startswith(prefixes):
            continue
        if name in found:
            raise SystemExit(f"freeze: two owned artifacts are both named {name}")
        found[name] = {"source": source, "artifact": artifact}
    return found


def code_object(artifact: dict, field: str) -> str:
    obj = artifact[field]["object"]
    if not obj.startswith("0x"):
        raise SystemExit(f"freeze: {field} is not 0x-prefixed")
    return obj[2:]


def link_references(artifact: dict, field: str) -> list[dict]:
    """The libraries a code object is linked against at deployment, with every placeholder offset."""
    found = []
    for source, libraries in sorted((artifact[field].get("linkReferences") or {}).items()):
        for name, positions in sorted(libraries.items()):
            found.append({
                "library": name,
                "source": source,
                "offsets": sorted(position["start"] for position in positions),
            })
    return found


def code_bytes(artifact: dict, field: str) -> bytes | None:
    """The exact code bytes, or None when the object still carries link placeholders."""
    obj = code_object(artifact, field)
    if LINK_PLACEHOLDER_RE.search(obj):
        return None
    return bytes.fromhex(obj)


def code_length(artifact: dict, field: str) -> int:
    return len(code_object(artifact, field)) // 2


def verify_keccak(entries: dict[str, dict]) -> int:
    """Reconcile this file's keccak against solc's own `methodIdentifiers`."""
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
                structs[f"{entry['name']}_{item.get('name', '')}"] = declared_shape(item["components"])
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


def abi_surface_document(freeze: dict, entries: dict[str, dict]) -> dict:
    return {
        "purpose": (
            "The frozen external surface of every production contract in this package, derived from "
            "the compiler artifacts. Selectors and event topics are keccak over the canonical "
            "signature, so a changed integer width, a renamed field, a reordered tuple, or a changed "
            "indexed flag all change the recorded line. bin/gate.sh regenerates this file from the "
            "build it just made and fails on any byte of difference."
        ),
        "contracts": {name: surface_entry(name, entries[name]) for name in freeze["production_contracts"]},
    }


def constructor_args_bytes(record: dict) -> int:
    """The exact ABI-encoded head length of a constructor's arguments (static words only)."""
    constructor = next((e for e in record["artifact"]["abi"] if e.get("type") == "constructor"), None)
    if constructor is None:
        return 0
    return 32 * sum(static_words(item) for item in constructor["inputs"])


def clone_template(source: Path) -> dict:
    """The exact minimal-proxy runtime `LibClone.clone(address)` deploys, read from the pinned library."""
    text = source.read_text(encoding="utf-8")
    prefix = CLONE_PREFIX_RE.search(text)
    suffix = CLONE_SUFFIX_RE.search(text)
    if prefix is None or suffix is None:
        raise SystemExit(f"freeze: {source} no longer carries the clone runtime constants this record derives from")
    return {
        "library": "solady/utils/LibClone.sol",
        "function": "clone(address)",
        "prefix": prefix.group("prefix"),
        "suffix": suffix.group("suffix"),
        "runtime_bytes": len(prefix.group("prefix")) // 2 + 20 + len(suffix.group("suffix")) // 2,
        "template": f"0x{prefix.group('prefix')}<20-byte implementation>{suffix.group('suffix')}",
        "derived_from": source.as_posix(),
    }


def code_identity(artifact: dict) -> dict:
    """Every byte-level identity one artifact has, EVM-native first.

    `runtime_keccak256` is the EVM `EXTCODEHASH` of a deployed instance whenever the artifact carries
    no immutable references and no link placeholders; otherwise the deployed runtime differs per
    deployment and the record says so instead of pretending. A linked object is digested as the
    exact placeholder-bearing text solc emitted, which is deterministic for a given source.
    """
    runtime = code_bytes(artifact, "deployedBytecode")
    creation = code_bytes(artifact, "bytecode")
    immutables = len(artifact["deployedBytecode"].get("immutableReferences") or {})
    runtime_links = link_references(artifact, "deployedBytecode")
    creation_links = link_references(artifact, "bytecode")
    return {
        "compiler": artifact["metadata"]["compiler"]["version"],
        "runtime_bytes": code_length(artifact, "deployedBytecode"),
        "runtime_keccak256": keccak256(runtime) if runtime is not None else None,
        "runtime_sha256": hashlib.sha256(runtime).hexdigest() if runtime is not None else None,
        "runtime_object_sha256": hashlib.sha256(code_object(artifact, "deployedBytecode").encode()).hexdigest(),
        "runtime_immutable_references": immutables,
        "runtime_linked_libraries": runtime_links,
        "runtime_keccak256_is_deployed_codehash": immutables == 0 and not runtime_links,
        "creation_bytes": code_length(artifact, "bytecode"),
        "creation_keccak256": keccak256(creation) if creation is not None else None,
        "creation_sha256": hashlib.sha256(creation).hexdigest() if creation is not None else None,
        "creation_object_sha256": hashlib.sha256(code_object(artifact, "bytecode").encode()).hexdigest(),
        "creation_linked_libraries": creation_links,
    }


def dependency_entries(freeze: dict, artifacts: dict[str, dict]) -> dict[str, dict]:
    """The pinned dependency builds this package admits or creates, keyed by exact source path."""
    found = {}
    for name, wanted in freeze["dependency_contracts"].items():
        key = f"{wanted['source']}:{name}"
        artifact = artifacts.get(key)
        if artifact is None:
            raise SystemExit(f"freeze: the pinned build produced no artifact at {key}")
        found[name] = {"source": wanted["source"], "artifact": artifact}
    return found


def dependency_document(freeze: dict, dependencies: dict[str, dict]) -> list[dict]:
    rows = []
    for name, wanted in freeze["dependency_contracts"].items():
        record = dependencies[name]
        identity = code_identity(record["artifact"])
        rows.append({
            "contract": name,
            "source": record["source"],
            "role": wanted["role"],
            "deployed_by": wanted["deployed_by"],
            **identity,
            "runtime_margin_bytes": EIP170_RUNTIME_LIMIT - identity["runtime_bytes"],
            "initcode_margin_bytes": EIP3860_INITCODE_LIMIT - identity["creation_bytes"],
            "constructor": surface_entry(name, record)["constructor"],
        })
    return rows


def sizes_document(freeze: dict, entries: dict[str, dict], dependencies: dict[str, dict], template: dict) -> dict:
    contracts = []
    for name in freeze["production_contracts"]:
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

    clones = [{
        "clone_of": name,
        "implementation_runtime_keccak256": code_identity(entries[name]["artifact"])["runtime_keccak256"],
        "runtime_bytes": template["runtime_bytes"],
        "runtime_margin_bytes": EIP170_RUNTIME_LIMIT - template["runtime_bytes"],
    } for name in freeze["clone_targets"]]

    return {
        "purpose": (
            "Deployable byte margins and EVM code identity for every production contract. Runtime and "
            "creation lengths and hashes come from the compiler artifacts; the constructor-argument "
            "length is the exact ABI head the deployment appends, which the compiler's size report "
            "excludes. A clone's EVM codehash is keccak over the 45-byte Solady runtime its own "
            "implementation address completes, so it exists only once that implementation is deployed. "
            "A linked contract's runtime is completed by the library address at deployment, so its "
            "deployed codehash is recorded as per-deployment rather than frozen."
        ),
        "limits": {
            "eip170_runtime_bytes": EIP170_RUNTIME_LIMIT,
            "eip3860_initcode_bytes": EIP3860_INITCODE_LIMIT,
        },
        "contracts": contracts,
        "dependency_contracts": dependency_document(freeze, dependencies),
        "clone_runtime_template": template,
        "clones": clones,
    }


def hook_flags(freeze: dict) -> dict:
    """The hook permission bits, named in the freeze record and reconciled against the deploy script."""
    hook = freeze["hook"]
    script = Path(hook["flags_source"]).read_text(encoding="utf-8")
    match = HOOK_FLAGS_SOURCE_RE.search(script)
    if match is None:
        raise SystemExit(f"freeze: {hook['flags_source']} declares no HOOK_FLAGS expression")
    in_source = sorted(HOOK_FLAG_NAME_RE.findall(match.group("body")))
    recorded = sorted(hook["flags"])
    if in_source != recorded:
        raise SystemExit(
            f"freeze: the hook flags in {hook['flags_source']} are {in_source}, the freeze record names {recorded}"
        )
    unknown = [name for name in recorded if name not in HOOK_FLAG_BITS]
    if unknown:
        raise SystemExit(f"freeze: unknown hook flag(s) {unknown}")
    value = 0
    for name in recorded:
        value |= HOOK_FLAG_BITS[name]
    return {"names": recorded, "address_bits": hex(value), "source": hook["flags_source"]}


def manifest_document(
    freeze: dict, entries: dict[str, dict], all_owned: dict[str, dict], dependencies: dict[str, dict], template: dict
) -> dict:
    contracts = {}
    for name, wanted in freeze["production_contracts"].items():
        record = entries[name]
        contracts[name] = {
            "source": record["source"],
            "role": wanted["role"],
            "deployed_by": wanted["deployed_by"],
            **code_identity(record["artifact"]),
            "constructor": surface_entry(name, record)["constructor"],
            "abi_file": f"abi/{name}.json",
            "deployment": {"address": None, "status": "deployment_pending"},
        }
    for name, wanted in freeze["dependency_contracts"].items():
        record = dependencies[name]
        contracts[name] = {
            "source": record["source"],
            "role": wanted["role"],
            "deployed_by": wanted["deployed_by"],
            **code_identity(record["artifact"]),
            "constructor": surface_entry(name, record)["constructor"],
            "abi_file": None,
            "deployment": {"address": None, "status": wanted["deployment_status"]},
        }

    # Every other compiled contract from the owned source roots — fixtures, presets, libraries,
    # bindings — is pinned by its bytes too, so no owned source can change without the freeze
    # noticing. Interfaces and abstract contracts compile to no runtime and are listed as such.
    source_contracts = {}
    for name, record in sorted(all_owned.items()):
        if name in contracts:
            continue
        artifact = record["artifact"]
        source_contracts[name] = {
            "source": record["source"],
            "runtime_bytes": code_length(artifact, "deployedBytecode"),
            "runtime_object_sha256": hashlib.sha256(code_object(artifact, "deployedBytecode").encode()).hexdigest(),
            "creation_bytes": code_length(artifact, "bytecode"),
            "creation_object_sha256": hashlib.sha256(code_object(artifact, "bytecode").encode()).hexdigest(),
        }

    clones = {
        name: {
            "implementation": {"address": None, "status": "deployment_pending"},
            "library": template["library"],
            "runtime_template": template["template"],
            "runtime_bytes": template["runtime_bytes"],
            "derived_from": template["derived_from"],
            "implementation_runtime_keccak256": code_identity(entries[name]["artifact"])["runtime_keccak256"],
            "clone_runtime_keccak256": {
                "value": None,
                "status": "deployment_pending",
                "derivation": (
                    f"keccak256(0x{template['prefix']} ++ <20-byte {name} implementation> ++ "
                    f"0x{template['suffix']}); the implementation address is the only unknown"
                ),
            },
        }
        for name in freeze["clone_targets"]
    }

    hook = freeze["hook"]
    return {
        "version": 1,
        "package": freeze["component"],
        "generated_by": "contracts/stocks/bin/freeze.py",
        "release_posture": "local implementation and proof only; mainnet remains NO-GO",
        "chain": freeze["chain"],
        "build": freeze_build(freeze),
        "surface_allowlist": list(freeze["production_contracts"]),
        "contracts": contracts,
        "source_contracts": source_contracts,
        "clones": clones,
        "hook_deployment": {
            "contract": hook["contract"],
            "create2_deployer": hook["create2_deployer"],
            "constructor": surface_entry(hook["contract"], entries[hook["contract"]])["constructor"],
            "permissions": hook_flags(freeze),
            "salt": {"value": None, "status": "deployment_pending"},
            "permission_authority": (
                "BaseHook.validateHookAddress at construction; a salt whose address lacks exactly these "
                "bits fails construction of the launchpad that deploys the hook"
            ),
        },
        "dependency_snapshot": {
            "lock": freeze["dependencies"]["lock"],
            "root": freeze["dependencies"]["root"],
            "closure": "reports/frozen/dependency-closure.json",
            "note": (
                "Every upstream byte the build reads is pinned by the closure digests, which is the "
                "authority for the consumed upstream surface; no hand-curated call list is kept."
            ),
        },
        "deployment_pending_note": (
            "No contract in this package is deployed. Every address in this manifest is null with "
            "status deployment_pending until a separately authorized deployment records it."
        ),
    }


def freeze_build(freeze: dict) -> dict:
    identity = json.loads(Path(freeze["frozen_identity"]).read_text(encoding="utf-8"))["build"]
    return {
        "solc_identity": identity["solc_identity"],
        "evm_version": identity["evm_version"],
        "optimizer_runs": identity["optimizer_runs"],
        "via_ir": identity["via_ir"],
        "bytecode_hash": identity["bytecode_hash"],
        "append_cbor": identity["append_cbor"],
    }


# =============================================================================
# dependency snapshot
# =============================================================================


def dependency_closure_document(freeze: dict) -> dict:
    """A content digest of every pinned dependency directory under the snapshot root.

    The snapshot is not tracked by Git (it is exported from the frozen contracts/v1 submodules by
    `bootstrap-deps.py`), so the freeze pins it by content: every file's path and SHA-256, in sorted
    order, folded into one digest per dependency. A changed, added or removed upstream file fails
    the check.
    """
    root = Path(freeze["dependencies"]["root"])
    lock = json.loads(Path(freeze["dependencies"]["lock"]).read_text(encoding="utf-8"))
    dependencies = {}
    for name, pin in sorted(lock.items()):
        if name.startswith("_"):
            continue
        directory = root / name
        if not directory.is_dir():
            raise SystemExit(f"freeze: dependency snapshot {directory} is missing; run bootstrap-deps.py first")
        digest = hashlib.sha256()
        count = 0
        for path in sorted(directory.rglob("*")):
            if path.is_dir():
                continue
            relative = path.relative_to(directory).as_posix()
            if path.is_symlink():
                content = os.readlink(path).encode()
                kind = b"link"
            else:
                content = path.read_bytes()
                kind = b"file"
            digest.update(kind + b"\0" + relative.encode() + b"\0" + hashlib.sha256(content).digest() + b"\n")
            count += 1
        if count == 0:
            raise SystemExit(f"freeze: dependency snapshot {directory} is empty")
        dependencies[name] = {
            "revision": pin["revision"],
            "exported_paths": pin["paths"],
            "files": count,
            "content_sha256": digest.hexdigest(),
        }
    return {
        "purpose": (
            "Content identity of the pinned dependency snapshot the build reads. Each digest folds every "
            "file's path and SHA-256 under the dependency's directory, so the exported upstream source "
            "cannot change without this record changing. The revisions are the exact commits "
            "dependencies.json pins; bootstrap-deps.py refuses any other."
        ),
        "root": freeze["dependencies"]["root"],
        "lock": freeze["dependencies"]["lock"],
        "dependencies": dependencies,
    }


# =============================================================================
# test portfolio
# =============================================================================


def test_listing_document(listing: dict) -> dict:
    """Foundry's own compiled test listing, sorted, as the frozen test portfolio.

    The gate compares the listing it takes to this one, so a deleted, renamed or added test is a
    freeze change rather than a silent shrink or growth of the evidence.
    """
    portfolio = {
        path: {contract: sorted(tests) for contract, tests in sorted(contracts.items())}
        for path, contracts in sorted(listing.items())
    }
    total = sum(len(tests) for contracts in portfolio.values() for tests in contracts.values())
    return {
        "purpose": (
            "The frozen hermetic test portfolio: every test identity Foundry lists under the default "
            "profile, by source file and contract. bin/gate.sh takes the listing again and requires "
            "it to equal this, then requires every listed test to execute exactly once and pass."
        ),
        "total": total,
        "tests": portfolio,
    }


def render(document: object) -> str:
    return json.dumps(document, indent=2, ensure_ascii=False) + "\n"


# =============================================================================


def forge(*args: str) -> str:
    env = dict(os.environ, FOUNDRY_OFFLINE="true", FOUNDRY_PROFILE="default", FOUNDRY_LINT_LINT_ON_BUILD="false")
    result = subprocess.run(["forge", *args], capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise SystemExit(f"freeze: forge {' '.join(args)} failed:\n{result.stderr}")
    return result.stdout


def run(args: argparse.Namespace) -> int:
    freeze = json.loads(Path(args.freeze).read_text(encoding="utf-8"))

    if args.mode == "write":
        forge("clean")
        forge("build")
        listing = json.loads(forge("test", "--list", "--json"))
    else:
        listing = json.loads(Path(args.test_list).read_text(encoding="utf-8"))

    artifacts = load_artifacts(Path(args.out))
    all_owned = owned(artifacts, tuple(freeze["owned_source_prefixes"]))
    entries = {name: all_owned[name] for name in freeze["production_contracts"] if name in all_owned}
    missing = [name for name in freeze["production_contracts"] if name not in all_owned]
    if missing:
        raise SystemExit(f"freeze: the build produced no artifact for {', '.join(missing)}")
    for name in freeze["clone_targets"]:
        if name not in entries:
            raise SystemExit(f"freeze: clone target {name} is not a production contract")
    if freeze["hook"]["contract"] not in entries or freeze["hook"]["create2_deployer"] not in entries:
        raise SystemExit("freeze: the hook and its CREATE2 deployer must both be production contracts")

    selectors_checked = verify_keccak(all_owned)
    dependencies = dependency_entries(freeze, artifacts)
    template = clone_template(Path(freeze["clone_library_source"]))

    documents: dict[Path, str] = {
        Path("reports/frozen/abi-surface.json"): render(abi_surface_document(freeze, entries)),
        Path("reports/frozen/deployable-sizes.json"): render(sizes_document(freeze, entries, dependencies, template)),
        Path("reports/frozen/release-manifest.json"): render(
            manifest_document(freeze, entries, all_owned, dependencies, template)
        ),
        Path("reports/frozen/dependency-closure.json"): render(dependency_closure_document(freeze)),
        Path("reports/frozen/test-listing.json"): render(test_listing_document(listing)),
    }
    for name in freeze["production_contracts"]:
        documents[Path(f"abi/{name}.json")] = render(contract_abi_document(name, entries[name]))

    if args.mode == "write":
        for path, body in documents.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body, encoding="utf-8")
            print(f"wrote {path}")
        stale = sorted(set(Path("abi").glob("*.json")) - set(documents))
        for path in stale:
            path.unlink()
            print(f"removed stale {path}")
        return 0

    problems = []
    for path, body in sorted(documents.items()):
        if not path.is_file():
            problems.append(f"{path} is missing; the freezer generates it")
        elif path.read_text(encoding="utf-8") != body:
            problems.append(f"{path} differs from what the current build generates")
    for path in sorted(Path("abi").glob("*.json")):
        if path not in documents:
            problems.append(f"{path} is not generated by the freezer and must not exist")
    if problems:
        print("FREEZE RECONCILIATION FAILED", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    closure = dependency_closure_document(freeze)["dependencies"]
    total_tests = test_listing_document(listing)["total"]
    with Path(args.receipt).open("a", encoding="utf-8") as handle:
        handle.write(
            f"freeze verified: bin/freeze.py check regenerated {len(documents)} frozen documents byte for "
            f"byte from {len(artifacts)} compiled artifacts ({len(all_owned)} owned, "
            f"{len(entries)} production), reconciled {selectors_checked} solc method identifiers against "
            f"its own keccak, pinned {len(closure)} dependency snapshots by content, and froze "
            f"{total_tests} hermetic test identities\n"
        )
    print(f"frozen documents reconciled: {len(documents)}")
    print(f"solc method identifiers reconciled against derived keccak: {selectors_checked}")
    print(f"dependency snapshots pinned by content: {len(closure)}")
    print(f"frozen hermetic test identities: {total_tests}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("write", "check"))
    parser.add_argument("--freeze", default="requirements/freeze.json")
    parser.add_argument("--out", default="out")
    parser.add_argument("--test-list", default="reports/generated/forge-test-list.json")
    parser.add_argument("--receipt", default="reports/generated/dependency-receipt.txt")
    return run(parser.parse_args())


if __name__ == "__main__":
    sys.exit(main())
