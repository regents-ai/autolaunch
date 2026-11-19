## Autolaunch V1 contracts

[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)](../../LICENSE)
[![Solidity 0.8.26](https://img.shields.io/badge/solidity-0.8.26-lightgrey)](https://soliditylang.org)
[![Foundry 1.5.1](https://img.shields.io/badge/foundry-1.5.1--stable-lightgrey)](https://getfoundry.sh)
[![Slither 0.11.5](https://img.shields.io/badge/slither-0.11.5-lightgrey)](https://github.com/crytic/slither)
[![Status: deployed on Base, launches open](https://img.shields.io/badge/status-deployed%20on%20Base%2C%20launches%20open-lightgrey)](deployments/base-mainnet/README.md)

Clean Solidity implementation of the founder-frozen Autolaunch V1 system, written and
maintained by Regents Labs. Autolaunch is the Regent token-launch system; this directory is the
`contracts/v1` component of the [Autolaunch repository](https://github.com/regents-ai/autolaunch)
and holds the V1 contracts and the required gate that checks them.

Every command below runs from this directory. The gate proves that its script root is exactly
`contracts/v1` under the repository's Git top level and that the whole repository, not only this
directory, is one clean Git object; a copy of this tree at another path, a repository rooted here,
or build output elsewhere in the checkout fails the gate before anything else runs.

The current candidate adds a non-enumerable factory lookup from payment receiver to launch ID and
removes caller-authored references from aggregate receiver sweeps and splitter surplus recognition.
The strategy distribution and `LaunchGraduated` remain the canonical-receiver authority; atomic
payments and direct recognized deposits still preserve their exact references.

The controlling specification is [SPEC.md](SPEC.md). The prior implementation in
`regent-contracts` is historical reference only. This component is deployed on Base (see the
note below and [deployments/base-mainnet/](deployments/base-mainnet/README.md)); its release
posture is otherwise governed by the required gate and the review described in this file.

> [!NOTE]
> Deployed on Base on 22 September 2026 by the ceremony of packet digest
> `0x5ba245ed0af9de1c1749f0b50cd54919a8084faf580d92282ef0592144f35327`; the eight addresses, all
> verified on Basescan, are in [deployments/base-mainnet/](deployments/base-mainnet/README.md). The
> factory was born paused: opening launches is a separate Governance and Regent Safe transaction.
> Nothing in this component signs, broadcasts, or moves value.

> [!IMPORTANT]
> Evidence here is local by construction. A local `bin/gate.sh` is the whole evidence; the
> repository runs no hosted checks, and no CI-green claim is made anywhere in this repository.

## The required gate

`bin/gate.sh` is the sole required check and the one command that must pass before a change is
proposed. It is offline: it downloads nothing, consults no package registry, and never fetches
from a remote. It runs the external tools and hands every structured comparison to
`bin/check-requirements.py` and `bin/freeze-artifacts.py`, in this order:

1. **Tool identity.** Foundry, Slither, and the ledger-check interpreter must match the
   frozen identities in `requirements/frozen-identity.json`.
2. **Recursive dependency closure.** Materialize offline, then prove that every root and
   nested submodule — 254 of them — is initialized, clean, and at exactly the commit its
   own parent's committed tree records. The three founder pins are compared to the `SPEC.md`
   literals; the launcher gitlink inside the pinned CCA tree must equal the founder launcher
   pin; this repository's forge-std must mirror the launcher's; and the founder UERC20
   factory must stay a different commit from the launcher's own nested UERC20. No nested
   commit is ever written down here — the parent that records it is the authority.
3. **Frozen identity.** `SPEC.md` must still hash to the frozen authority digest. The chain
   manifest, the frozen-identity file, and the compiled binding source must bind the same
   `SPEC.md` bindings under the same `SPEC.md` names — matched by name, not merely by
   literal value — plus the chain id and the CCA runtime code hash. The admitted CCA
   admission function must be defined in the pinned CCA implementation source with exactly
   the recorded signature, state mutability, and return type, as a body-bearing definition
   rather than an interface declaration.
4. **Effective configuration.** Foundry must report offline with FFI disabled. This reads
   `forge config --json`, not the committed file, so an environment override fails the gate
   instead of silently changing the build.
5. **Specification-governed build.** The Solidity version, EVM target, optimizer runs,
   via-IR, and disabled bytecode metadata are parsed out of the one `SPEC.md` line that
   governs them and compared against `foundry.toml`'s effective configuration *and* the
   frozen fixture. Editing both repository copies together still fails while the
   specification says something else. The full compiler build suffix is separately frozen
   tool identity and only has to begin with the `SPEC.md` semantic version.
6. **Threat-model integrity.** Every requirement the threat model names as a mitigation must
   exist in the ledger.
7. `forge fmt --check`, then `forge build --sizes` over the paths `bin/freeze-artifacts.py paths`
   lists (the package's own roots and the pinned upstream sources the freezer reads), then the
   compiler, optimizer, via-IR, EVM version, and metadata settings actually recorded in every
   produced artifact.
8. **Frozen release surface.** `bin/freeze-artifacts.py check` regenerates every committed file
   under `abi/`, `reports/frozen/abi-surface.json`, `reports/frozen/deployable-sizes.json`, and
   `contracts/autolaunch-release-manifest.json` from those artifacts and compares them byte for
   byte, so a hand-edited ABI or a stale manifest cannot pass. It then compares every `src/**`
   compiled runtime and creation byte string against the independently captured pre-edit C4
   baseline in `reports/frozen/c4-runtime-baseline.json`: exactly the contracts the frozen
   `final_source_delta` record names may differ, each of them must really differ, and every other
   contract the baseline records must still match byte for byte. A contract written after the
   capture is never inserted into it: the record's `added` list names it with a reason, and any
   other contract the baseline does not record fails. It writes `DEP-016`'s verified receipt line.
9. **Published-evidence reconciliation.** Every deployable-size row the audit packet publishes
   is compared against the frozen size record. A stale published number fails the gate rather
   than surviving review.
10. `slither . --fail-medium`, then a reconciliation of its evidence. The configuration and
    the exact argv are both pinned to one allowed shape, the run must carry the pinned
    binary's whole registered detector portfolio, and every finding needs its own visible
    disposition row matched by detector, impact, confidence, and source mapping: see
    [docs/security/slither-dispositions.md](docs/security/slither-dispositions.md).
11. **Provider-secret scan.** The configured `base` RPC alias must still be the unresolved
    `${REGENT_BASE_RPC_URL}` in the *effective* configuration, no credential field at any nesting
    depth may carry a value, and no regenerated or committed evidence — the frozen reports, the
    ABI, the manifests, the requirements, the audit packet, or the security docs — may name a host
    outside a documentation and provenance allowlist. The required gate never reads the alias; it
    only proves it stayed unresolved.

Anything missing, drifted, or unproven fails closed. A gate failure is a stop-report: never
relax a pinned identity, threshold, or configuration value to make it pass.

## Setup

Materialization uses the network and happens before the gate, never inside it. Each step
reads its version from `requirements/frozen-identity.json` rather than repeating it.

```sh
frozen() { python3 -c "import json,sys;print(json.load(open('requirements/frozen-identity.json'))$1)"; }

# 1. The pinned Foundry, on PATH ahead of any other install.
foundryup --install "$(frozen "['toolchain']['forge_version']" | sed 's/-stable$//')"
export PATH="$HOME/.foundry/bin:$PATH"

# 2. The pinned ledger-check interpreter and the pinned Slither running on it.
uv python install "$(frozen "['toolchain']['python_version']")"
uv tool install --python "$(frozen "['toolchain']['python_version']")" \
  "slither-analyzer==$(frozen "['toolchain']['slither_version']")"

# 3. The pinned Solidity compiler, materialized outside this repository so the gate stays
#    offline. Foundry caches it in ~/.svm, where the gate's build then finds it.
solc=$(frozen "['build']['solc_version']")
scratch=$(mktemp -d) && mkdir -p "$scratch/src" \
  && printf '[profile.default]\nsolc = "%s"\n' "$solc" >"$scratch/foundry.toml" \
  && printf '// SPDX-License-Identifier: UNLICENSED\npragma solidity %s;\ncontract M {}\n' \
       "$solc" >"$scratch/src/M.sol" \
  && (cd "$scratch" && forge build)

# 4. The complete recursive dependency closure, with real git metadata — never a copied
#    lib/ tree, which leaves the files present but the submodule metadata absent. The roots
#    are declared in the repository's top-level .gitmodules at contracts/v1/lib/...; this
#    command may run from any directory in the repository. The URL rewrite is required: one
#    pinned upstream declares an SSH remote for OpenZeppelin.
git -c url."https://github.com/".insteadOf="git@github.com:" \
    submodule update --init --recursive
```

Step 4 fetches roughly 6 GB of git history and leaves about 1 GB checked out, because the
frozen closure includes the Optimism monorepo three times over — once under each pinned
upstream that depends on it. That cost is the price of freezing the full recursive gitlink
closure, and it is paid before the gate, not by it.

Then run the gate from this directory:

```sh
cd contracts/v1 && bin/gate.sh
```

## Component layout

Paths are relative to this directory.

| Path | Purpose |
| --- | --- |
| `lib/` | the pinned dependency closure as Git submodules, declared in the repository's top-level `.gitmodules` at `contracts/v1/lib/...` |
| `SPEC.md` | the founder-frozen specification; the only source of pins, addresses, and the CCA runtime code hash |
| `requirements/ledger.toml` | every frozen normative claim, its owning ticket, evidence class, gate, status, and planned selectors |
| `requirements/frozen-identity.json` | the frozen dependency closure, toolchain, build, authority, and binding identity the gate reconciles |
| `contracts/chain-contracts.yaml` | the Base binding manifest and the CCA admission entry |
| `contracts/autolaunch-release-manifest.json` | the generated release manifest: surface allowlist, code identity, clone derivation, and deployment-pending discipline |
| `abi/` | the generated canonical ABI, one committed file per production contract |
| `src/bindings/` | the compiled copies of the frozen bindings and identity — constants only, no behavior |
| `script/` | the one deployment script: five direct, zero-value creation transactions and nothing else. It imports no miner, holds no key, and is never invoked with `--broadcast` by the gate |
| `deployments/base-mainnet/` | the packet the founder approved, and the deployed manifest recording the Base deployment from its five confirmed receipts |
| `docs/security/` | threat model and Slither dispositions |
| `docs/audit/` | the founder audit packet: posture, claim corrections, fork authority and staged-state inventory, gas and size |
| `reports/generated/` | scratch gate evidence. `bin/gate.sh` deletes and rewrites it on every run and `.gitignore` keeps it out of the tree. Never committed, never an authority. |
| `reports/frozen/` | committed authority. Generated by `bin/freeze-artifacts.py` and re-checked byte for byte on every run, except the pre-edit C4 runtime baseline and the fork observation record, which are captured once by a reviewed pass and thereafter only read. |

## Requirement ledger

Every normative claim in `SPEC.md` has an entry in `requirements/ledger.toml`: its statement,
owning ticket and contract, evidence class, gate, status, and named selectors. The required gate
validates that shape — well-formed and unique identifiers in the declared groups, an owner and a
contract for every claim, an evidence class that matches its gate, and selector names that begin
with their own requirement identifier — and the threat model may name as a mitigation only a
claim the ledger defines.

## The deployment ceremony

[docs/audit/deployment-ceremony.md](docs/audit/deployment-ceremony.md) is the full account of how
the packet was rendered, prepared and rehearsed.

`bin/ceremony.py` runs after the founder has sent the five creations by hand:
`record` proves five confirmed Base transaction hashes against the installed packet and writes the
deployed-manifest candidate, and `site-config` renders the website's production file from the
installed packet and manifest. Both refuse to run beside signing authority, sign nothing, and write
only under `reports/generated/deployment/`.
[deployments/base-mainnet/README.md](deployments/base-mainnet/README.md) has the usage.

**The ceremony ran on Base on 22 September 2026.** The packet under `deployments/base-mainnet/`
pins the deployer, a pre-mined hook salt and the eight predicted addresses, and records the
external state observed at Base block `51657720`. The founder approved its digest
`0x5ba245ed0af9de1c1749f0b50cd54919a8084faf580d92282ef0592144f35327` and sent the five creations from
`0x9b2C414614aEE294202c1219520955EF3B596031` at nonces 0–4, in Base blocks `51660956`–`51661052`.
`bin/ceremony.py record` proved every receipt, code identity and readback against the packet and
wrote `deployments/base-mainnet/deployed-manifest.json`.

**And the deployed factory still admits no launch.** Every factory is born paused, so the fifth
receipt left launches closed and the deployer has no say in that. Opening a deployed factory is a
separate Safe transaction requiring its own
founder instruction, and anything downstream reads `launchesPaused()` rather than inferring the
initial state from an event that was never emitted.

### The production authority and the fork-evidence commit are named apart

The production authority is commit `7d564cec735c3b1b928ec4e2ede0b244682d105b`, tree
`97ea43cbf2e6625889b64deefcea406ea11ccdc5`, carrying `contracts/v1/src` tree
`eeeb1cedb315c97bf1a22658c02a5210a9c517c9`. The fork-evidence commit is
`4451c776f84fa904dd02b0c4360d360a45a945cb`, which sits on it and shares that same source tree,
because it changes no production byte: its whole diff is the two `source_authority` fields inside
`reports/frozen/fork-observations.json` and the record that the authority carries its sources at
`contracts/v1/src`. `docs/audit/README.md` carries the same table, and states
there — as here — that the identities earlier proofs named belong to pre-Revstake bytecode and
certify nothing about this candidate.

The packet under `deployments/base-mainnet/` was re-rendered from this authority. Two contracts'
compiled bytes moved with the Revstake terms — the factory, which collects no launch fee, and the
strategy, which admits a creator-chosen raise and mints to the fee-only LP locker — so their code
identity, sizes and margins and the packet digest all moved with them. The packet's `selection` and
`external_observation` sections were then re-derived live under the founder's separate read-only
Base authority: the deployer's nonce (`0`) was read, the salt mined, the eight predicted addresses
re-derived — the seven the prior packet predicted, byte-identical, plus the LP locker the strategy
constructor creates at strategy nonce 1 — and the control surface snapshotted at block `51657720`;
the exact script was then simulated against a read-only fork with nothing broadcast. The ceremony
then ran exactly this packet.

## License

MIT — see [LICENSE](../../LICENSE). Dependencies under `lib/` keep their own licenses.

