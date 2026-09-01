# Regents Autolaunch Contracts

[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)
[![Solidity 0.8.26](https://img.shields.io/badge/solidity-0.8.26-lightgrey)](https://soliditylang.org)
[![Foundry 1.5.1](https://img.shields.io/badge/foundry-1.5.1--stable-lightgrey)](https://getfoundry.sh)
[![Slither 0.11.5](https://img.shields.io/badge/slither-0.11.5-lightgrey)](https://github.com/crytic/slither)
[![Status: not deployed](https://img.shields.io/badge/status-not%20deployed-lightgrey)](#the-deployment-ceremony-gate)

Clean Solidity implementation of the founder-frozen Autolaunch V1 system, written and
maintained by Regents Labs. Autolaunch is the Regent token-launch system; this repository
holds its contracts, its proofs, and the gates that decide whether those proofs still hold.

The current candidate adds a non-enumerable factory lookup from payment receiver to launch ID and
removes caller-authored references from aggregate receiver sweeps and splitter surplus recognition.
The strategy distribution and `LaunchGraduated` remain the canonical-receiver authority; atomic
payments and direct recognized deposits still preserve their exact references.

The controlling specification is [SPEC.md](SPEC.md). The prior implementation in
`regent-contracts` is historical reference only. This repository contains no deployed
release until the complete claim-level test, static-analysis, fork, review, and founder
audit gates pass.

> [!WARNING]
> No deployment, signature, provider write, or value movement is authorized by this
> repository. Nothing here has been deployed. A deployment packet and deployer have been
> selected, but only a later founder instruction naming the packet's exact digest may
> authorize a signature or a broadcast. Every factory is also born paused, so even a
> completed ceremony admits no launch: opening one is a separate Governance and Regent Safe
> transaction that needs its own founder instruction, and nothing here is that instruction.

> [!IMPORTANT]
> Evidence here is local by construction. `.github/workflows/test.yml` runs the same required
> `bin/gate.sh`, materializing the pinned toolchain over the network first so the gate itself
> stays offline. Until a hosted run has been observed and reviewed, a local `bin/gate.sh` is
> the whole evidence, and no CI-green claim is made anywhere in this repository.

## Where this sits

```text
  client surfaces
    ios                               mobile app, wallet, action signing
    regents-cli                       operator control surface
    regents-techtree-hermes-plugin    Hermes mission-control tab
                    │
                    ▼
  platform
    ash-platform                      Phoenix, LiveView, Ash: web, API, product domains
                    │
                    ▼
  services and chain
    siwa-server                       agent request signing, nonce and replay state
    media-web                         hosted card images and video
    fly-sentinel                      operator health checks
    regent-contracts                  canonical Solidity, ABIs, deployment records
    autolaunch-contracts              frozen Autolaunch V1 Solidity   ◀ this repository

  shared libraries and standalone tools
    elixir-utils                      SIWA, ENS, XMTP, cache, Credo checks
    design-system                     tokens and regent_ui components
    python-cli                        offline Techtree skill-tree inspection
    videocontrol                      video project and timeline workflows
```

## The three gates

| Gate | Command | Authorization | What it proves |
| --- | --- | --- | --- |
| Required | `bin/gate.sh` | none needed; fully offline | The `hermetic` and `invariant` claims, and only those. This is the one command that must pass before a change is proposed. |
| Fork | `bin/fork-gate.sh` | the founder's separate read-only Base authority | The `fork` claims, against real Base state. Never runs inside the required gate. |
| Deployment ceremony | `bin/deployment-gate.sh` | founder authority for its provider modes | The five zero-value creation transactions of the ceremony. Every mode ends at mainnet NO-GO. |

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
| `script/` | the one deployment script: five direct, zero-value creation transactions and nothing else. It imports no miner, holds no key, and is never invoked with `--broadcast` by any gate |
| `test-deployment/` | the deployment-ceremony harness, the external-state preflight, and the selection derivation; outside both other test roots, so only the deployment gate can execute or close its claims |
| `deployments/base-mainnet/` | the mainnet-NO-GO packet, which is a proposal and the sole ceremony authority, and the deployed manifest, which is an empty record. Nothing here has been deployed |
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
  names the production authority commit and `src/` tree it was observed against, installs it as
  `reports/frozen/fork-observations.json`, activates the `fork` gate, and commits.
- `bin/fork-gate.sh check` runs under a profile with no write permission at all. It refuses to start
  until that record and that activation are committed and clean, proves the authority the record
  names against Git and against this checkout, runs all eighteen fork claims at the pinned header
  and the focused nine-claim drift subset at the later head, reconciles both runs against one
  compiled listing, and proves both files unchanged afterwards.

Before either mode runs a fork test it makes one read-only chain-id probe through the configured
`base` alias and requires exactly chain 8453, so a dead, unreachable, malformed or wrong-chain
endpoint stops the gate rather than surfacing as a harness failure. That refusal has its own
regression: `bin/fork-gate.sh selftest-dead-endpoint` re-runs the gate against a closed loopback
port and requires a nonzero exit with no pass marker. It reaches no network.

Both fork profiles build into `out-fork`, so fork artifacts can never reach the `out/` the required
gate reconciles.

A gate is added to the ledger's `activated_gates` only in the candidate that already carries that
gate's committed evidence. `fork` is active with the separately reviewed observation record. This
candidate executed all eighteen claims at Base block `50541328` and the focused nine-claim subset at
block `50541628` against its own receiver-provenance source authority; all twenty-seven mapped
selectors passed. The record's observed values did not move — the same reviewed headers, bindings,
proxies and gas schedule were re-checked live and matched — so only the `source_authority` it names
moved, which is what makes the run evidence about these bytes rather than an earlier candidate's.
Those selectors remain outside the offline test root, so only the read-only fork gate can execute or
close them; the offline gate neither runs nor claims them.

## The deployment-ceremony gate

`bin/deployment-gate.sh` is not part of the required check either. It proves the `deployment` gate
alone: the five direct, zero-value creation transactions a founder-selected disposable deployer
would send to put the Autolaunch graph on Base, and nothing else. It has four modes.

- `--offline` is the writer's mode and carries `DEP-070..075`. It runs with `FOUNDRY_OFFLINE=true`
  and with the Base endpoint variable cleared from the child environment, so no network can be
  reached even by accident. The whole ceremony is decidable that way: the five creations call no
  external contract at all.
- `--prepare <deployer>` is the only mode that derives a ceremony's free parameters. Under the
  founder's separate read-only Base authority it reads that public account's live nonce, mines the
  hook salt once, snapshots the live control surface, and writes one complete packet candidate into
  gitignored scratch. It closes no claim, installs nothing, and prints no pass marker.
- `--rehearse` is the chief's mode, run under the same authority and only after independent review.
  It is compare-only: it runs the ceremony selectors against a read-only fork, holds every frozen
  binding's runtime and proxy identity to `reports/frozen/fork-observations.json` and the live
  control surface to the committed packet, re-derives the seven predicted addresses, and simulates
  the exact deployment script with no `--broadcast` and no signer. It refuses to run while the
  committed packet pins no deployer.
- `--selftest-dead-endpoint` is the regression for the chain-id boundary the two provider modes
  cross before any build, Forge test or script: one read-only probe through the `base` alias must
  answer exactly 8453. It reaches no network.

Every mode refuses to run beside signing authority or beside a `.env`, `.env.local` or `.envrc`
file, and none invokes `forge script --broadcast`. Every mode ends at mainnet NO-GO. The deployment
profile builds into gitignored scratch under `reports/generated/`, separate from both `out/` and
`out-fork/`, and its Solidity has no filesystem permission at all — so the packet under
`deployments/base-mainnet/` is rendered and compared by the shell, and no test can author one for
itself. [docs/audit/deployment-ceremony.md](docs/audit/deployment-ceremony.md) is the full account.

**Nothing in this repository has been deployed.** The frozen packet under
`deployments/base-mainnet/` now pins a disposable deployer, a pre-mined hook salt, and the seven
predicted addresses, and it records the external state observed at Base block `50754918`. Its
authorization state is still `not authorized`: no founder has granted a `GO_TO_DEPLOY`, no
signing method is named, and only a later founder instruction naming the packet's exact digest
may authorize a signature or a broadcast.

**And a completed ceremony would still admit no launch.** Every factory is born paused, so the fifth
receipt leaves launches closed and the disposable deployer has no say in that. `DEP-072` reads the
paused state back off the ceremony graph, and `DEP-073` proves that graph admits the frozen
Governance and Regent Safe address — and only it — as the account a later activation would come
from, by impersonating that address on a local fork and calling the real `unpauseLaunches()`. That
proves what the graph admits; it is not a Safe signature, says nothing about that Safe's signers,
and authorizes nothing. Opening a deployed factory is a separate Safe transaction requiring its own
founder instruction, and anything downstream reads `launchesPaused()` rather than inferring the
initial state from an event that was never emitted.

### The production authority and the fork-evidence commit are named apart

The production authority is commit `f4114f5276386f48bf8dc53ee344189d98c8896e`, tree
`bb660324bb1d5cc322adeb243b0bd51779821fcb`, carrying `src/` tree
`91a741e417b75706a4071f7bdac2c5e13548c0fc`. The fork-evidence commit is
`ea8c81b2a5724213d3aeb4b0d81885b932f7d1aa`, which sits on it and shares that same `src/` tree,
because it changes no production byte: its whole diff is the two `source_authority` fields inside
`reports/frozen/fork-observations.json` — the naming step the fork gate proves against Git and
against the checkout before any fork test opens — and one whitespace-only `forge fmt` of
`test-fork/ProductionLifecycleFork.t.sol`. `docs/audit/README.md` carries the same table, and states
there — as here — that the identities earlier proofs named belong to pre-`regent-alv1.16` bytecode
and certify nothing about this candidate.

The packet under `deployments/base-mainnet/` was re-rendered from this authority. Four contracts'
compiled bytes moved with the receiver-provenance lookup and the reference-free aggregate paths — the
splitter, the receiver, the factory and the strategy — so their code identity, sizes and margins and
the packet digest all moved with them. The packet's `selection` and `external_observation` sections
were then re-derived live: `--prepare` under the founder's separate read-only Base authority read
the deployer's nonce (`0`), mined the salt, re-derived the seven predicted addresses and snapshotted
the control surface at block `50754918`, all byte-identical to the prior packet, and `--rehearse`
held them and simulated the exact script against a read-only fork with nothing broadcast. Status
stays mainnet NO-GO.

## The other repositories

| Repository | What it is | What it deliberately does not do |
| --- | --- | --- |
| `ash-platform` | The Phoenix, LiveView, and Ash application: public web pages, the HTTP API, product domains, human identity, billing, and the Techtree and Autolaunch product areas. | It does not hold Solidity source or user signing keys; wallet actions remain browser-signed. |
| `design-system` | The shared Regent visual language: the style guide, design tokens, logos, fonts, and the `regent_ui` Phoenix component library. | Shared components never own product workflow state, authorisation decisions, money movement, or product database behaviour. |
| `elixir-utils` | A collection of standalone Elixir libraries used across the family: SIWA, ENS, XMTP, a cache, agentbook helpers, and the in-house `credo_ash` lint checks. | Each package is a library only; none of them runs a service or holds product behaviour. |
| `fly-sentinel` | A small Phoenix service that reports Fly.io observability and operator preview checks. | It observes and reports; it does not deploy, scale, or change any other application. |
| `ios` | The Expo and React Native mobile app: the mobile wallet, action signing, and mobile Regent records. | It consumes the platform HTTP contracts and owns no server-side product logic. |
| `media-web` | A standalone Phoenix service that serves hosted Regents card images and video files from `media.regents.sh`. | It only serves bytes over HTTP; it holds no identity, database, or product logic. |
| `python-cli` | The installable `regents-techtree` Python package, whose shipped surface is a deterministic offline inspection of one champion/challenger skill-tree pair. | It does not evaluate or execute an agent, and it makes no network calls once its locked dependencies are installed. |
| `regent-contracts` | The canonical home for Regent Solidity source, Foundry tests, deployment scripts, verified deployment records, ABIs, and the chain-contract manifest. | It holds no HTTP or CLI contracts, Ash resources, workflow logic, UI, or projection workers. |
| `regents-cli` | The operator control surface: the `regents` command line tool, its generated bindings, and its local runtime. | It drives the platform over published contracts and owns no product database or on-chain authority. |
| `regents-techtree-hermes-plugin` | The Hermes plugin that presents Techtree mission control across Forge, Techtree Verify, and Uplift. | It is presentation only: no second task store, no private Verify database, no identity model, no payment system, and no Hermes runtime of its own. |
| `siwa-server` | The shared Sign-In With Anything service for signed agent requests, nonce and replay state, and internal keyring endpoints. | It owns no product data or product authorization policy. |
| `videocontrol` | A separate product: video project workflows, timeline editing, preview rendering, and Codex plugin media control. | It shares the house style but no runtime, database, or contract with the Regent platform. |

## License

MIT — see [LICENSE](LICENSE). Dependencies under `lib/` keep their own licenses.
