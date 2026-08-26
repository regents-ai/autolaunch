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
package registry, and never fetches from a remote. It proves the `hermetic` and `invariant`
gates, and only those. It runs the external tools and hands every structured comparison to
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
8. **Frozen release surface.** `bin/freeze-artifacts.py check` regenerates every committed file
   under `abi/`, `reports/frozen/abi-surface.json`, `reports/frozen/deployable-sizes.json`, and
   `contracts/autolaunch-release-manifest.json` from those artifacts and compares them byte for
   byte, so a hand-edited ABI or a stale manifest cannot pass. It then compares every `src/**`
   compiled runtime and creation byte string against the independently captured pre-edit C4
   baseline in `reports/frozen/c4-runtime-baseline.json`: exactly the contracts the frozen
   `final_source_delta` record names may differ, each of them must really differ, and every other
   contract must still match byte for byte. It writes `DEP-016`'s verified receipt, so deleting
   this step fails the ledger rather than silently stopping the check.
9. **Tests.** `forge test --list --json` is the authority for which test identities exist;
   `forge test --json -vv` is what ran — `-vv` because Foundry only populates each result's
   decoded logs at that verbosity, and step 11 reads a measurement out of exactly that field.
   The two are compared as multisets, so an overloaded, inherited, or duplicated identity
   cannot collapse into one entry. Every due selector must be globally unique, must execute
   exactly once, and must pass; zero failures, zero skips.
10. **Ledger.** Every due claim maps to an executed selector, every gate-dependency claim
    additionally requires the gate's own verified receipt, and no test may claim an ID that
    is not due under the gates this entrypoint runs.
11. **Published-evidence reconciliation.** Every figure the audit packet publishes is compared
    against what produced it: each deployable-size row against the frozen size record, and each
    hook-callback figure against the exact value `GAS-007` emitted in this run. A stale published
    number fails the gate rather than surviving review.
12. `slither . --fail-medium`, then a reconciliation of its evidence. The configuration and
    the exact argv are both pinned to one allowed shape, the run must carry the pinned
    binary's whole registered detector portfolio, and every finding needs its own visible
    disposition row matched by detector, impact, confidence, and source mapping: see
    [docs/security/slither-dispositions.md](docs/security/slither-dispositions.md).
13. **Provider-output scan tooling.** The fork gate's two failure orders — a run that failed
    while its output was clean, and output that was dirty whatever the run's status — are shell
    control flow around a Python scanner, so no Solidity test can reach them. They are proved
    here instead, deterministically and without a provider, against the real scanner.
14. **Provider-secret scan.** The configured `base` RPC alias must still be the unresolved
    `${REGENT_BASE_RPC_URL}` in the *effective* configuration, no credential field at any nesting
    depth may carry a value, and no regenerated or committed evidence — the frozen reports, the
    ABI, the manifests, the audit packet, the security docs, or the fork harness — may name a host
    outside a documentation and provenance allowlist. The required gate never reads the alias; it
    only proves it stayed unresolved.

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
| `contracts/autolaunch-release-manifest.json` | the generated release manifest: surface allowlist, code identity, clone derivation, and deployment-pending discipline |
| `abi/` | the generated canonical ABI, one committed file per production contract |
| `src/bindings/` | the compiled copies of the frozen bindings and identity — constants only, no behavior |
| `test/bindings/` | the proofs that those compiled copies equal the independently verified frozen identity |
| `test/abi/`, `test/gas/`, `test/invariant/` | the frozen-surface, deployable-size, hook-cost, and stateful accounting proofs |
| `test-fork/` | the read-only Base fork harness; outside the offline test root, so it can never execute against a hermetic or invariant claim |
| `docs/security/` | threat model and Slither dispositions |
| `docs/audit/` | the founder audit packet: posture, claim corrections, fork authority and staged-state inventory, gas and size |
| `reports/generated/` | scratch gate evidence. `bin/gate.sh` deletes and rewrites it on every run and `.gitignore` keeps it out of the tree. Never committed, never an authority. |
| `reports/frozen/` | committed authority. Generated by `bin/freeze-artifacts.py` and re-checked byte for byte on every run, except the pre-edit C4 runtime baseline and the fork observation record, which are captured once by a reviewed pass and thereafter only read. |

## Requirement ledger

Every normative claim in `SPEC.md` has an entry in `requirements/ledger.toml`, and every
entry carries at least one exact planned Foundry selector. The selector namespace is fixed
now, so a later ticket implements the claim its predecessor named instead of inventing one.

Activation is two-dimensional. A claim is `active` only when its owning ticket appears in
`activated_tickets` **and** its designated gate appears in `activated_gates`. An activated
ticket may therefore still hold claims pending while its gate is unauthorized; that was the
state of the earlier offline C5 object. In this evidence-activation candidate, `fork` and C5 are
both activated, so every fork claim is active.

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
C5 add their contracts and activate their own, C6 activates the launch-time treasury
admission claims its correction added, and C6.1 takes ownership of the two of them its own
correction rewrote.

## The separately authorized fork gate

`bin/fork-gate.sh` is not part of the required check and never runs inside it. It proves the `fork`
gate alone, under the founder's separate read-only Base authority. Its evidence is two-phase on
purpose: a gate that observed a value and then compared it to itself would prove nothing.

- `bin/fork-gate.sh discover` runs under the one profile in this repository that may write anything,
  and its only writable path is gitignored scratch. It observes Base, writes a single reviewable
  candidate, reads no committed observation, and closes no claim.
- A human reviews that candidate, supplies the transaction gas schedule the chain does not expose,
  installs it as `reports/frozen/fork-observations.json`, activates the `fork` gate, and commits.
- `bin/fork-gate.sh check` runs under a profile with no write permission at all. It refuses to start
  until that record and that activation are committed and clean, runs the mapped selectors once per
  committed header, reconciles both runs against one compiled listing, and proves both files
  unchanged afterwards.

Both fork profiles build into `out-fork`, so fork artifacts can never reach the `out/` the required
gate reconciles.

A gate is added to the ledger's `activated_gates` only in the candidate that already carries that
gate's committed evidence. `fork` is active with the separately reviewed observation record, and its
eighteen claims executed once at each committed Base header and passed **against the production
bytecode of an earlier candidate**. `regent-alv1.7`, `regent-alv1.7.1` and `regent-alv1.10` all
changed production bytes, so that fork execution has to be repeated under the same separate authority before those
claims carry evidence. `regent-4wx` owns that repetition: it runs once, against the final candidate
— after this correction and every later one is integrated — rather than once per intermediate
candidate. The observation record itself is chain truth and is unaffected.
Their thirty-six selectors remain outside the offline test root, so only the read-only fork gate can
execute or close them, and this candidate's offline gate neither ran nor claimed any of them.
