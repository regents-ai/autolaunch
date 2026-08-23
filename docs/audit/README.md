# Founder audit packet — C5 as corrected by regent-alv1.6.1

**Release posture: mainnet NO-GO.** Nothing in this repository is deployed, no Regent address
exists, and no deployment instruction has been given. This packet exists to be audited, not acted
on.

The C5 candidate was stopped by its own final audit: one terminal-path custody defect in production
code and two overstated pieces of fork evidence. `regent-alv1.6.1` corrects all three and adds the
exact-production fork lifecycle suite. What changed, and why, is in
[claim-corrections.md](claim-corrections.md) section 4.

## What is in the packet

| Document | What it carries |
| --- | --- |
| this file | posture, gate order, evidence map, what is proved and what is not |
| [claim-corrections.md](claim-corrections.md) | every correction C5 made to an already-closed C2/C3/C4 claim, and the inherited obligations it closed |
| [fork-authority-and-state-inventory.md](fork-authority-and-state-inventory.md) | the founder fork authority text and its digest, the read-only boundary, the staged-state inventory, and the named hermetic-double limits |
| [gas-and-size.md](gas-and-size.md) | deployable byte margins, EVM code identity, the hook callback measurement recorded without an invented limit, and the both-header complete-transaction gas figures. Every figure on that page is re-proved by the gate against the artifact or the executed measurement it came from |
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

## Two different objects: the reviewed offline candidate and the later evidence-activation commit

This distinction is load-bearing and easy to lose, so it is stated once, plainly.

**The earlier review object was the offline C5 candidate.** Its fork record was
`discovery_pending`, `fork` was absent from the ledger, and the offline gate proved only the
hermetic and invariant claims in that tree.

**This candidate is the later evidence-activation object.** Under the founder's separate read-only
Base authority, discovery produced a candidate observation; its values were checked against an
independent provider, the Base gas schedule was supplied from the active protocol rules, and the
reviewed record was committed before check mode could run. The ledger now activates `fork`, and the
compare-only gate executed all eighteen fork claims once at each of the two committed headers. The
gate also proved the observation record and ledger stayed byte-identical to their committed state.

The two objects remain distinct: the earlier offline pass did not prove a fork claim, while this
activation candidate carries and checks the separately reviewed fork authority.

## Evidence map

| Group | Gate | Status in this candidate |
| --- | --- | --- |
| `DEP-001..016`, `DEP-020..029`, `DEP-060` | hermetic | active, executed, passing |
| `FAC-*`, `TOK-*`, `STR-*`, `ESC-*`, `HOK-*`, `SPL-*`, `RCV-*`, `MIG-*`, `FAIL-*` | hermetic | active, executed, passing |
| `GAS-001`, `GAS-002`, `GAS-007` | hermetic | active, executed, passing |
| `ABI-001..012` | hermetic | active, executed, passing |
| `INV-001..010` | invariant | active, executed, passing |
| `DEP-040..053` | fork | active, executed at both committed headers, passing |
| `GAS-003..006` | fork | active, executed at both committed headers, passing |

## What is not proved

- **A deployment or signed ceremony.** The fork gate is read-only; it deployed nothing to Base,
  signed nothing, and moved no value outside isolated local fork state.
- **Workflow review and custody state.** Independent review, the Solidity Auditor, integration, and
  ticket closure are Control evidence rather than Solidity claims proved by this packet.
