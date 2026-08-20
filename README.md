# Regents Autolaunch Contracts

Clean Solidity implementation of the founder-frozen Autolaunch V1 system.

The controlling specification is [SPEC.md](SPEC.md). The prior implementation in
`regent-contracts` is historical reference only. This repository contains no deployed
release until the complete claim-level test, static-analysis, fork, review, and founder
audit gates pass.

No deployment, signature, provider write, or value movement is authorized by this
repository.

## The required gate

`bin/gate.sh` is the sole required check. It is offline: it downloads nothing, consults no
package registry, and never fetches from a remote. It runs the external tools and hands
every structured comparison to `bin/check-requirements.py`, in this order:

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
4. **Effective configuration.** Foundry must report offline with FFI disabled, and the
   effective fuzz and invariant seed, run, depth, rejection, revert, and shrink settings
   must equal the committed values. This reads `forge config --json`, not the committed
   file, so an environment override fails the gate instead of silently changing the run.
5. **Specification-governed build.** The Solidity version, EVM target, optimizer runs,
   via-IR, and disabled bytecode metadata are parsed out of the one `SPEC.md` line that
   governs them and compared against `foundry.toml`'s effective configuration *and* the
   frozen fixture. Editing both repository copies together still fails while the
   specification says something else. The full compiler build suffix is separately frozen
   tool identity and only has to begin with the `SPEC.md` semantic version.
6. **Threat-model integrity.** Every requirement the threat model names as a mitigation must
   exist in the ledger.
7. `forge fmt --check`, then `forge build --sizes`, then the compiler, optimizer, via-IR,
   EVM version, and metadata settings actually recorded in every produced artifact.
8. **Tests.** `forge test --list --json` is the authority for which test identities exist;
   `forge test --json` is what ran. The two are compared as multisets, so an overloaded,
   inherited, or duplicated identity cannot collapse into one entry. Every due selector must
   be globally unique, must execute exactly once, and must pass; zero failures, zero skips.
9. **Ledger.** Every due claim maps to an executed selector, every gate-dependency claim
   additionally requires the gate's own verified receipt, and no test may claim an ID that
   is not due under the gates this entrypoint runs.
10. `slither . --fail-medium`, then a reconciliation of its evidence. The configuration and
    the exact argv are both pinned to one allowed shape, the run must carry the pinned
    binary's whole registered detector portfolio, and every finding needs its own visible
    disposition row matched by detector, impact, confidence, and source mapping: see
    [docs/security/slither-dispositions.md](docs/security/slither-dispositions.md).

Anything missing, drifted, or unproven fails closed. A gate failure is a stop-report: never
relax a pinned identity, threshold, or configuration value to make it pass.

The repository has no configured Git remote, so `.github/workflows/test.yml` is reviewed
statically and has not been executed on a hosted runner. No CI-green claim is made anywhere
in this repository; `bin/gate.sh` run locally is the whole evidence.

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
#    lib/ tree, which leaves the files present but the submodule metadata absent. The URL
#    rewrite is required: one pinned upstream declares an SSH remote for OpenZeppelin.
git -c url."https://github.com/".insteadOf="git@github.com:" \
    submodule update --init --recursive
```

Step 4 fetches roughly 6 GB of git history and leaves about 1 GB checked out, because the
frozen closure includes the Optimism monorepo three times over — once under each pinned
upstream that depends on it. That cost is the price of freezing the full recursive gitlink
closure, and it is paid before the gate, not by it.

Then run the gate:

```sh
bin/gate.sh
```

## Repository layout

| Path | Purpose |
| --- | --- |
| `SPEC.md` | the founder-frozen specification; the only source of pins, addresses, and the CCA runtime code hash |
| `requirements/ledger.toml` | every frozen normative claim, its owning ticket, evidence class, gate, status, and planned selectors |
| `requirements/frozen-identity.json` | the frozen dependency closure, toolchain, build, authority, binding, and test-portfolio identity the gate reconciles |
| `contracts/chain-contracts.yaml` | the Base binding manifest and the CCA admission entry |
| `src/bindings/` | the compiled copies of the frozen bindings and identity — constants only, no behavior |
| `test/bindings/` | the proofs that those compiled copies equal the independently verified frozen identity |
| `docs/security/` | threat model and Slither dispositions |
| `reports/generated/` | regenerated gate evidence; never committed before the C5 freeze |

## Requirement ledger

Every normative claim in `SPEC.md` has an entry in `requirements/ledger.toml`, and every
entry carries at least one exact planned Foundry selector. The selector namespace is fixed
now, so a later ticket implements the claim its predecessor named instead of inventing one.

Activation is two-dimensional. A claim is `active` only when its owning ticket appears in
`activated_tickets` **and** its designated gate appears in `activated_gates`. An activated
ticket may therefore still hold claims pending, but only when their gate is not yet
authorized — that is how C5 lands its hermetic and invariant work while its fork claims wait
for the separately authorized fork gate. Once a claim's owner and gate are both activated,
the claim must be active.

A pending claim's selectors are reserved names only: they need not exist, they may not be
executed against that ID, and nothing can mark the claim complete. A placeholder or a mock
cannot satisfy a future ticket's claim.

Evidence class follows who owns the code. Claims that need deployed runtime, proxy shape,
implementation identity, external getter results, cold deployed state, intrinsic gas,
calldata gas, or complete-transaction gas are bound to the fork gate and can never close
hermetically — that is why `GAS-003` through `GAS-006` are fork claims while the runtime and
initcode size limits `GAS-001` and `GAS-002` stay hermetic. Code this repository owns is the
other case: the clone implementations and their clones are proved hermetically under
`DEP-060`, because their code identity is a compile-time and local-deployment fact rather
than external chain truth.

C0 activates only its own dependency, binding, chain, and ABI-provenance claims. C1 through
C5 add their contracts and activate their own.
