# Regents Autolaunch Contracts

Clean Solidity implementation of the founder-frozen Autolaunch V1 system.

The controlling specification is [SPEC.md](SPEC.md). The prior implementation in `regent-contracts` is historical reference only. This repository contains no deployed release until the complete claim-level test, static-analysis, fork, review, and founder audit gates pass.

No deployment, signature, provider write, or value movement is authorized by this repository.

## The required gate

`bin/gate.sh` is the sole required check. It is offline: it downloads nothing, consults no
package registry, and never fetches from a remote. It verifies, in order:

1. the Foundry, Slither, and ledger-check tool identities against `requirements/toolchain.lock`;
2. that Foundry is configured offline with FFI disabled, and that `SPEC.md` still hashes to the
   frozen authority digest in `requirements/authority.lock`;
3. the pinned recursive dependency closure — founder pins against the `SPEC.md` literals, and
   every recursive pin against the commit its own pinned parent records;
4. that the chain manifest, the test fixture, and the binding source carry exactly the `SPEC.md`
   address set and runtime code hash, and that the admitted CCA signature is defined by the
   pinned CCA implementation source rather than an interface file;
5. `forge fmt --check` and `forge build --sizes`, then the compiler, optimizer, via-IR, EVM
   version, and metadata settings actually recorded in the produced artifacts;
6. `forge test`, reconciled by `bin/check-requirements.py` so that the executed test identities
   equal the identities enumerated from the pinned source tree, each exactly once, with zero
   failures and zero skips, and every activated requirement maps to an executed selector;
7. `slither . --fail-medium`, with dependency sources filtered and nothing else.

Anything missing, drifted, or unproven fails closed. A gate failure is a stop-report: never
relax a pinned identity, threshold, or configuration value to make it pass.

## Setup

Materialization uses the network and happens before the gate, never inside it.

```sh
# 1. The pinned Foundry, on PATH ahead of any other install.
foundryup --install "$(awk '$1 == "forge_version" { print $2 }' requirements/toolchain.lock | sed 's/-stable$//')"
export PATH="$HOME/.foundry/bin:$PATH"

# 2. Slither and the ledger-check interpreter, at the locked versions.
uv tool install "slither-analyzer==$(awk '$1 == "slither_version" { print $2 }' requirements/toolchain.lock)"

# 3. The pinned Solidity compiler, materialized outside this repository so the gate stays offline.
scratch=$(mktemp -d) && mkdir -p "$scratch/src" \
  && printf '[profile.default]\nsolc = "0.8.26"\n' >"$scratch/foundry.toml" \
  && printf '// SPDX-License-Identifier: UNLICENSED\npragma solidity 0.8.26;\ncontract M {}\n' >"$scratch/src/M.sol" \
  && (cd "$scratch" && forge build)

# 4. The pinned dependency closure, with real git metadata (never a copied lib/ tree).
awk '/^[[:space:]]*#/ { next } $1 == "pin" || $1 == "mirror" { print $2 }' requirements/dependency-closure.txt \
  | xargs git submodule update --init --
awk '/^[[:space:]]*#/ { next } $1 == "derived" { print $3, substr($2, length($3) + 2) }' requirements/dependency-closure.txt \
  | while read -r parent child; do git -C "$parent" submodule update --init -- "$child"; done
```

Then run the gate:

```sh
bin/gate.sh
```

## Repository layout

| Path | Purpose |
| --- | --- |
| `SPEC.md` | the founder-frozen specification; the only source of pins, addresses, and the CCA runtime code hash |
| `requirements/ledger.toml` | every frozen normative claim, its owning ticket, evidence class, gate, and selectors |
| `requirements/dependency-closure.txt` | the source-required recursive submodule closure and how each expected commit is derived |
| `requirements/toolchain.lock`, `requirements/authority.lock` | frozen tool, build, and authority identities |
| `contracts/chain-contracts.yaml` | the Base binding manifest and the CCA admission entry |
| `src/bindings/` | immutable Base binding constants — no behavior |
| `test/bindings/`, `test/fixtures/` | binding and ABI proofs, and the fixture the gate reconciles against `SPEC.md` |
| `docs/security/` | threat model and Slither dispositions |
| `reports/generated/` | regenerated gate evidence; never committed before the C5 freeze |

## Requirement ledger

Every normative claim in `SPEC.md` has an entry in `requirements/ledger.toml`. A claim is
`active` only when its owning ticket appears in `activated_tickets`; until then it is `pending`,
carries no selector, and no test may claim its ID — a placeholder or mock cannot satisfy a future
ticket's claim. Claims that need deployed runtime, proxy shape, getter, or complete-transaction
gas evidence are bound to the authorized fork gate and can never close hermetically.

C0 activates only its own dependency, binding, and ABI-provenance claims. C1 through C5 add
their contracts and activate their own claims.
