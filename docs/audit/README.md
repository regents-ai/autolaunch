# Founder audit packet — C5 as corrected by regent-alv1.6.1, regent-alv1.7, regent-alv1.7.1, regent-alv1.10 and regent-alv1.11

**Release posture: mainnet NO-GO.** Nothing in this repository is deployed, no Regent address
exists, and no deployment instruction has been given. This packet exists to be audited, not acted
on.

The C5 candidate was stopped by its own final audit: one terminal-path custody defect in production
code and two overstated pieces of fork evidence. `regent-alv1.6.1` corrects all three and adds the
exact-production fork lifecycle suite. What changed, and why, is in
[claim-corrections.md](claim-corrections.md) section 4.

`regent-alv1.7` is the next successor. It deletes the recovery administrator outright, makes both
recovery calls permissionless and whole-balance to the immutable treasury, and adds one closed
launch-time treasury admission in the strategy. Section 5 of
[claim-corrections.md](claim-corrections.md) carries that delta, including the exact ABI change for
the downstream Ash lane.

`regent-alv1.7.1` restores the pinned upstream ordinary `CREATE` clones for the per-launch splitter
and canonical receiver, deletes C6's CREATE2 salts, address prediction, future-slot refusal and
clone-runtime fingerprint rule, and narrows launch-time treasury admission to exactly six
shared-system addresses. It changes **no public ABI**; the strategy's compiled runtime shrinks. The
consequences it deliberately admits — a treasury that is another launch's artifact, and a treasury
that collides with the strategy's next clone address — are named and driven end to end rather than
prevented. Section 6 of [claim-corrections.md](claim-corrections.md) carries the whole delta.

`regent-alv1.10` changes how a recognized net is divided. The 2% skim and its
two destinations are untouched; the 98% net is now divided by fixed total-supply coverage, so current
stakers collectively receive the floored fraction of it that the staked share of the complete 100
billion SUBJECT supply represents and the launch treasury immediately receives the exact remainder in
the same transaction. An account staking a tenth of the supply therefore earns a tenth of the net
whether it is the only staker or one of many. It also requires a later block than an account's own
latest stake before that account may unstake, which makes an atomic stake, recognize, claim and exit
round trip fail entirely. Section 7 of [claim-corrections.md](claim-corrections.md) carries that
delta.

`regent-alv1.11` is this candidate, and it closes the three things review found open in that one.
The denominator is no longer an assumption: initialization now executes the bare precondition
`require(IERC20Minimal(subject_).totalSupply() == SUBJECT_TOTAL_SUPPLY)` after the duplicate-token
refusal and before the first binding write, so a clone binds only a SUBJECT that actually reports the
supply its net is divided by, and it stores no copy, adds no getter and never reads the supply again.
The exit delay now covers every value exit rather than only principal: `unstake`, `claim` and
`claimAll` share one private check, so a top-up locks the caller's complete position *and* its
already accrued claims until the next block. And `RevenueRecognized` stops answering a yes/no
question — its `bool paidToStakers` becomes the exact `uint256 stakerShare` and `uint256
treasuryShare`, so an indexer reads the whole split off one event and `gross` is exactly
`skim + stakerShare + treasuryShare`. Stake, recognition, accrual and the `claimable` views stay
immediate. The only ABI additions across both tickets are the renamed
`error SameBlockStakeExit(address account, uint256 stakeBlock)` and that event's moved topic0; no
function selector, other event topic, indexed field or integer width moves. Section 8 of
[claim-corrections.md](claim-corrections.md) carries the whole delta.

The four production contracts whose bytes differ from the pre-edit C4 baseline are unchanged as a
set. `regent-4wx` executed the separately authorized fork proof once against this final C10 source
authority: all eighteen fork claims at Base block `50495491`, followed by exactly the nine
drift-sensitive claims at block `50495791`. All twenty-seven mapped selectors passed.

## The production authority and the evidence candidate are two different identities

They are named apart because they are separately auditable, and because conflating them is exactly
how an evidence-only change would come to read as a production change.

| Object | Identity |
| --- | --- |
| Production authority commit | `7e70077d66b7a1a511806a68f086583c733c812a` |
| Production authority tree | `23f26023216ec93f9014b3c0295588b5aede6ee0` |
| Production source tree (`src/`) | `314889bcc6cabd5ceff336af93082d009df86205` |
| Evidence candidate | the linear, evidence-only `regent-4wx` stack rooted at the production authority commit, on branch `regent/regent-4wx-final-base-fork-proof-c10`. Its exact final commit and tree are recorded verbatim in the ticket's candidate record. |

The evidence candidate changes no production byte. Its `src/` tree is the same
`314889bcc6cabd5ceff336af93082d009df86205`, and its whole diff is confined to `README.md`,
`bin/fork-gate.sh`, `test-fork/`, `requirements/ledger.toml`,
`reports/frozen/fork-observations.json`, `docs/audit/` and `docs/security/threat-model.md`.
`bin/gate.sh` regenerates the frozen ABI, size and runtime-identity documents from the compiled
artifacts on either tree and gets the same bytes.

**The earlier C9 evidence candidate certifies nothing about this one.** Commit
`49b7458e5c93f502247905201352074ef5b5c409` carried an earlier version of this same harness on top of
the C9 production commit `5cf4a6b48388d54593b83230342542fee7c0f131`. It predates the C10 splitter
outright — the exact-supply binding, the explicit `stakerShare` and `treasuryShare` amounts, and the
delayed `claim` and `claimAll` did not exist when it was written — so no statement about it is a
statement about this candidate, and this packet makes none.

## What is in the packet

| Document | What it carries |
| --- | --- |
| this file | posture, gate order, evidence map, what is proved and what is not |
| [claim-corrections.md](claim-corrections.md) | every correction C5 made to an already-closed C2/C3/C4 claim, and the inherited obligations it closed |
| [fork-authority-and-state-inventory.md](fork-authority-and-state-inventory.md) | the founder fork authority text and its digest, the read-only boundary, the staged-state inventory, and the named hermetic-double limits |
| [gas-and-size.md](gas-and-size.md) | deployable byte margins, EVM code identity, the hook callback measurement recorded without an invented limit, and the complete-transaction gas figures. Every figure on that page is re-proved by the gate against the artifact or the executed measurement it came from |
| [deployment-ceremony.md](deployment-ceremony.md) | the five-transaction Base ceremony, the three values it consumes, what stops a wrong one, the two deployment-gate modes, the external-state preflight, and the approval boundary that keeps the repository mainnet NO-GO |
| `../security/threat-model.md` | the threat model and the requirement each mitigation maps to |
| `../security/slither-dispositions.md` | one disposition row per Slither result and one record per inline suppression |
| `../../contracts/autolaunch-release-manifest.json` | the generated release manifest: surface allowlist, code identity, clone derivation, bindings, and deployment-pending discipline |
| `../../abi/` | the generated per-contract ABI, one file per production contract |
| `../../reports/frozen/` | the generated frozen surface, deployable sizes, the pre-edit C4 runtime baseline, and the fork observation record |
| `../../requirements/ledger.toml` | every normative claim, its owner, evidence class, gate, status, and exact selectors |

## The two gates, in the order they actually run

`bin/gate.sh` is the sole required entrypoint. It is offline and proves the `hermetic` and
`invariant` gates, in this order:

1. required material and tool identity, then the effective Foundry configuration;
2. recursive dependency closure — every root and nested gitlink at the commit its own parent records;
3. frozen identity: `SPEC.md`'s digest, the bindings, the chain id, the CCA admission provenance;
4. specification-governed build, effective fuzz and invariant portfolio, threat-model integrity;
5. `forge fmt --check`;
6. `forge build --sizes`, then the compiler settings recorded in every produced artifact;
7. **the frozen release surface** — `bin/freeze-artifacts.py check` regenerates every committed ABI,
   surface, size and manifest document from these artifacts and compares byte for byte, then proves
   that exactly the `src/**` contracts the frozen `final_source_delta` record names differ from the
   pre-edit C4 baseline, that each of them really differs, and that every other one still matches;
8. `forge test --list --json` and `forge test --json -vv`, reconciled as multisets;
9. ledger reconciliation: every due claim maps to an executed selector, and every gate-dependency
   claim additionally needs the gate's own verified receipt;
10. **published-evidence reconciliation** — every deployable-size row and every hook-callback figure
    this packet publishes is compared against the frozen record and against the measurement
    `GAS-007` actually emitted in this run, so a stale published number fails rather than survives;
11. `slither . --fail-medium` and its evidence reconciliation;
12. **the provider-output scan tooling tests** — the fork gate's two failure orders, proved
    deterministically against the real scanner without a provider;
13. **the provider-secret scan**, recursively over the regenerated evidence, every committed frozen
    artifact, this audit packet, the security docs, and the fork harness — plus every nested leaf of
    the effective Foundry configuration.

`bin/fork-gate.sh` is the separately authorized read-only Base fork entrypoint and proves only the
`fork` gate. It is not part of the required gate and never runs inside it, and it has two modes:

- `discover` observes Base under the one profile that may write anything, and writes a single
  reviewable candidate into gitignored scratch. It reads no committed observation, closes no claim,
  and is excluded by name from every ledger reconciliation.
- `check` is compare-only under a profile with no write permission at all. It refuses to start
  until a human has reviewed that candidate, installed it, activated the `fork` gate, and committed
  both — and it proves those files unchanged afterwards.

[fork-authority-and-state-inventory.md](fork-authority-and-state-inventory.md) carries the full
transition and the staged-state inventory.

## `reports/generated/` versus `reports/frozen/`

These are two different things and the distinction is load-bearing:

- **`reports/generated/`** is scratch evidence. `bin/gate.sh` deletes and rewrites it on every run,
  and `.gitignore` keeps it out of the tree. It is never committed and is never an authority.
- **`reports/frozen/`** is committed authority. Every file in it is either generated by
  `bin/freeze-artifacts.py` from the compiler artifacts and re-checked byte for byte on every gate
  run, or — for `c4-runtime-baseline.json` and `fork-observations.json` — installed through a separate
  reviewed pass and explicit versioned commits. Neither of those two is taken on its word: the C4 baseline
  is proved against Git to be byte-identical to the blob its capture commit committed directly on
  integrated C4. The fork observation record was installed from a separately reviewed discovery
  candidate; discovery did not read it, and the gate proves the committed record stayed unchanged
  throughout both compare-only executions.

## Evidence history: the offline candidate, activation, and later corrections

This distinction is load-bearing and easy to lose, so it is stated once, plainly.

**The earlier review object was the offline C5 candidate.** Its fork record was
`discovery_pending`, `fork` was absent from the ledger, and the offline gate proved only the
hermetic and invariant claims in that tree.

**The activation candidate was a second object.** Under the founder's separate read-only
Base authority, discovery produced a candidate observation; its values were checked against an
independent provider, the Base gas schedule was supplied from the active protocol rules, and the
reviewed record was committed before check mode could run. The ledger now activates `fork`, and the
compare-only gate executed all eighteen fork claims once at each of the two committed headers — that
was the earlier portfolio, before `regent-4wx` narrowed the fresh-head repetition to the nine-claim
subset described below. The gate also proved the observation record and ledger stayed
byte-identical to their committed state.

The two objects remain distinct: the earlier offline pass did not prove a fork claim, while the
activation candidate carries and checks the separately reviewed fork authority.

**The C6 correction was a third object: `regent-alv1.7` as further corrected by
`regent-alv1.7.1`.** Its offline gate was complete and green, and it changed the compiled bytes of the
factory, the strategy, the splitter and the receiver — which the enumerated source-delta record names
and the freezer proves. The committed observation record is chain truth and is unaffected by that,
but the fork *execution* is not: it ran against an earlier candidate's bytecode.

**The C9 supply-coverage correction was a fourth object.** Its offline gate was complete and green,
and it changed the splitter plus the factory's matching implementation hash.

**This C10 candidate is the fifth object.** Its offline gate is complete and green, and it changes
the same two production files again: the splitter's supply binding, exit rule and recognition event,
and the factory's matching implementation hash. `regent-4wx` then refreshed and independently
reviewed the observation record and ran `check` once against the final post-correction source
authority — not once per intermediate candidate. The run executed twenty-seven mapped selectors
with zero failures or skips: eighteen claims at block `50495491`, then the approved nine-claim
subset at block `50495791`.

`regent-4wx` also fixed what that run will execute. The complete fork portfolio is proved at the
committed pinned header, and a focused nine-claim subset — `DEP-040`, `DEP-041`, `DEP-042`,
`DEP-043`, `DEP-047`, `DEP-050`, `DEP-051`, `DEP-052`, `GAS-006` — is proved again at the later
head. **One full lifecycle portfolio runs, not two**, and no claim in this packet says every fork
claim runs at both headers.
[fork-authority-and-state-inventory.md](fork-authority-and-state-inventory.md) section 2.1 carries
the shape and the one limitation that follows from it.

## Evidence map

| Group | Gate | Status in this candidate |
| --- | --- | --- |
| `DEP-001..016`, `DEP-020..029`, `DEP-060` | hermetic | active, executed, passing |
| `FAC-*`, `TOK-*`, `STR-*`, `ESC-*`, `HOK-*`, `SPL-*`, `RCV-*`, `MIG-*`, `FAIL-*` | hermetic | active, executed, passing |
| `GAS-001`, `GAS-002`, `GAS-007` | hermetic | active, executed, passing |
| `ABI-001..012` | hermetic | active, executed, passing |
| `INV-001..010` | invariant | active, executed, passing |
| `DEP-040..053` | fork | active, executed and passing against the final C10 source authority at the pinned header; the approved eight `DEP-*` claims run again at the later header |
| `GAS-003..006` | fork | active, executed and passing; the three transaction envelopes run at the pinned header and `GAS-006` runs at both |
| `DEP-070..075` | deployment | active, executed and passing under `bin/deployment-gate.sh --offline`, which reached no provider. They prove the five-transaction ceremony itself, not a deployment: see [deployment-ceremony.md](deployment-ceremony.md) |

## What is not proved

- **A second lifecycle portfolio at the fresh head.** The behaviour claims that drive real launches,
  bids, migrations, payments and swaps run once, at the committed pinned header. The fresh head
  re-derives every binding's deployed code identity, proxy family, implementation identity, the
  chain id, the header binding and the gas-measurement method, and nothing more.
- **The live staking contract's paused state at deployment time.** `DEP-045` proves both the real
  deposit and the owner-driven fail-closed path at the pinned header, but `paused()` is mutable
  deployed state and the reduced fresh-head subset does not re-read it. It must be read again
  immediately before any separately authorized deployment, and a deployed `paused() == true` is a
  stop. [fork-authority-and-state-inventory.md](fork-authority-and-state-inventory.md) section 2.1
  states this in full.
- **A deployment or signed ceremony.** The fork gate is read-only; it deployed nothing to Base,
  signed nothing, and moved no value outside isolated local fork state. The deployment gate is the
  same: `DEP-070..075` prove what the five creation transactions would do and what stops a wrong
  one, and the packet they render is a proposal whose status is `mainnet-NO-GO`. No deployer has
  been selected, no address is predicted, no salt is mined into the packet, and only a later
  founder instruction naming that packet's exact digest may authorize a signature or a broadcast.
- **What the five deployment transactions cost.** `DEP-074` proves the EIP-170 and EIP-3860 size
  margins and measures each creation's in-EVM gas, which is a floor rather than a transaction cost.
  No complete deployment-transaction gas figure exists for these five creations: the full
  per-transaction estimates stay pending the exact selected deployer and salt and an authorized
  rehearsal.
- **Workflow review and custody state.** Independent review, the Solidity Auditor, integration, and
  ticket closure are Control evidence rather than Solidity claims proved by this packet.
