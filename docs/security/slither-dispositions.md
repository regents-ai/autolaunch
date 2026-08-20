# Slither dispositions

## How Slither runs

`bin/gate.sh` runs Slither only after the recursive dependency closure, the frozen identity,
the build identity, the compiled test listing, the executed test set, and the requirement
ledger are all green:

```
slither . --fail-medium --json reports/generated/slither.json --checklist
```

Slither drives the repository's own Foundry build, so the compiler and settings it analyzes
under are the frozen ones the gate already proved. That build is
`forge build --build-info --skip ./test/** ./script/** --force`, so tests and scripts are
outside the analyzed scope. Everything the production sources under `src/` import is compiled
into it, including the pinned dependency source those imports reach. Results whose source
elements are all pinned dependencies are excluded because this repository does not own those
sources. A result that touches both production code and a dependency remains visible.

`slither.config.json` disables nothing else. No detector is turned off, no severity is
excluded, and no triage database is used. Slither can be narrowed two entirely valid ways — a
well-formed configuration key, or a well-formed command-line flag — so the gate pins both:

- **The configuration.** `slither.config.json` must equal one exact allowed shape:
  `exclude_dependencies` true, all six severity exclusions false, no path filter, and
  `compile_force_framework` foundry. Slither excludes a result only when every source
  element is a dependency; mixed production/dependency findings remain visible. An added
  key, a changed value, a path filter, or a detector exclusion list all fail, whether or
  not the key is spelled correctly. A typo such as `exclude_lowww` fails as an
  unrecognized key, and a correct `"exclude_low": true` fails as a narrowing.
- **The command line.** `bin/gate.sh` records the exact argv it is about to run and then
  runs that argv, and the gate compares the recording against the one allowed invocation.
  `--detect`, `--exclude`, `--exclude-low`, `--filter-paths`, and `--triage-mode` are all
  rejected because none of them is in the allowed argv.
- **The detector portfolio.** The expected portfolio comes from the pinned Slither binary's
  own registered detector classes, read through the binary's own interpreter, and the gate
  requires the analyzed run to report exactly that many detectors. `--list-detectors` is
  **not** the authority: it omits hidden detectors and under-reports the set that actually
  runs. Any narrowing, from the configuration or the command line, shrinks the reported
  count and fails here.
- `--fail-medium` fails the run on medium and high findings;
- every result at **any** severity, including low, informational, and optimization, gets its
  own row in the disposition table below. Each row is matched against an exact fingerprint —
  detector, impact, confidence, and the repository-relative source mapping Slither reported
  — as a multiset in both directions. Two findings from the same detector at two locations
  are two fingerprints and need two rows; a row whose location is wrong or missing matches
  nothing and fails;
- the gate fails closed if a `*slither.db.json` triage database appears anywhere outside
  `lib/`, so findings cannot be silently retired;
- the gate fails closed if Slither complains about its own configuration;
- the gate compares the number of contracts Slither says it analyzed against the number of
  contracts, libraries, and interfaces declared under `src/`, so a narrowed source list
  cannot produce a quiet pass.

## Generated evidence

`reports/generated/slither.json`, `reports/generated/slither-checklist.md`,
`reports/generated/slither.stderr.log`, `reports/generated/slither-command.txt`, and
`reports/generated/slither-detectors.txt` are regenerated on every gate run and stay
uncommitted until the C5 freeze, when the release packet fixes them as recorded artifacts.
Until then the reproducible command above, not a stored file, is the evidence. The gate
deletes the whole generated directory before each run and fails if any piece of that
evidence is missing, empty, or malformed, so a stale artifact cannot survive into a later
run.

No path filter is configured. Pinned dependency-only results are omitted; every result that
touches production code remains subject to the exact disposition rules below.

## Results

<!-- slither-result-count: 1 -->

| Check | Impact | Confidence | Where | Disposition |
| --- | --- | --- | --- | --- |
| pragma | Informational | High | lib/continuous-clearing-auction/lib/liquidity-launcher/src/interfaces/IDistributor.sol#L2; lib/continuous-clearing-auction/lib/liquidity-launcher/src/interfaces/ILBPInitializer.sol#L2; lib/continuous-clearing-auction/lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol#L4; lib/continuous-clearing-auction/src/interfaces/IAuctionStorage.sol#L2; lib/continuous-clearing-auction/src/interfaces/IBidStorage.sol#L2; lib/continuous-clearing-auction/src/interfaces/ICheckpointStorage.sol#L2; lib/continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol#L2; lib/continuous-clearing-auction/src/interfaces/IStepStorage.sol#L2; lib/continuous-clearing-auction/src/interfaces/ITickStorage.sol#L2; lib/continuous-clearing-auction/src/interfaces/IValidationHook.sol#L2; lib/continuous-clearing-auction/src/libraries/BidLib.sol#L2; lib/continuous-clearing-auction/src/libraries/CheckpointLib.sol#L2; lib/continuous-clearing-auction/src/libraries/ConstantsLib.sol#L2; lib/continuous-clearing-auction/src/libraries/StepLib.sol#L2; lib/continuous-clearing-auction/src/libraries/ValueX7Lib.sol#L2; lib/liquidity-launcher/lib/solady/src/utils/FixedPointMathLib.sol#L2; lib/liquidity-launcher/lib/solady/src/utils/Initializable.sol#L2; lib/liquidity-launcher/lib/solady/src/utils/ReentrancyGuard.sol#L2; lib/liquidity-launcher/lib/solady/src/utils/SafeTransferLib.sol#L2; src/bindings/BaseBindings.sol#L2; src/bindings/FrozenIdentity.sol#L2; src/escrow/ConditionalVestingEscrowV1.sol#L2; src/interfaces/IERC20Minimal.sol#L2; src/interfaces/IRegentRevenueStakingMinimal.sol#L2; src/revenue/PaymentReceiverV1.sol#L2; src/revenue/SubjectSplitterV1.sol#L2 | Accepted, unavoidable, and correctly visible. This is the only result the run produces. It reports that the compiled closure spans four pragma constraints: every file this repository owns pins exactly `0.8.26`, while pinned Solady, CCA, liquidity-launcher, and OpenZeppelin sources carry the floating `^0.8.0`, `^0.8.4`, and `^0.8.20` constraints their upstream authors wrote. The result's elements span production and dependency files together, so dependency exclusion correctly leaves it visible rather than hiding it. It is not a defect: the whole closure is compiled by the single frozen `0.8.26` compiler `DEP-009` reconciles against the governing `SPEC.md` build line, so no second compiler version is ever used, and rewriting a pinned submodule's pragma to silence it would break the frozen dependency identity `DEP-005` proves. |

`Where` is not prose: it is the exact normalized source mapping of the result, built from
the repository-relative filenames and line numbers in Slither's JSON, in the form
`src/Path.sol#L12,L13; src/Other.sol#L40`. The gate reconciles the four fingerprint columns
against the real run as a multiset in both directions, so a missing row, an extra row, a
mistyped location, and two same-detector findings sharing one row all fail.

The one row above is the whole run. Every other result the analysis produced lives entirely
inside pinned dependency source, which this repository does not own, and is excluded before
dispositioning; the `pragma` result survives that exclusion precisely because its elements
span the pinned sources and this repository's own files together. After C1, the production
contracts this repository owns produce no medium or high result and no undispositioned
result of any severity.

## Inline suppressions

<!-- slither-suppression-count: 8 -->

| File | Detector | Rationale | Protecting test |
| --- | --- | --- | --- |
| src/escrow/ConditionalVestingEscrowV1.sol | incorrect-equality | `releasable == 0` is a zero test on a computed schedule amount, not a strict equality against a manipulable balance. It exists so a zero-value release is an exact no-op rather than a revert. | test_ESC_012_VestingReleasesLinearlyOverThreeSixtyFiveDays |
| src/escrow/ConditionalVestingEscrowV1.sol | timestamp | The vesting schedule is defined in `SPEC.md` as 365 days of wall-clock time from the graduation timestamp, so `block.timestamp` is the specified input. A validator can only move the boundary by seconds, which shifts a linear release by a proportional amount and can never over-release: `totalReleased` is the cap. | test_ESC_012_VestingReleasesLinearlyOverThreeSixtyFiveDays |
| src/escrow/ConditionalVestingEscrowV1.sol | unused-return | `IContinuousClearingAuction.checkpoint()` returns the terminal `Checkpoint` struct. Escrow calls it only to force the auction to finalize that block before it reads `isGraduated()` and `remainingSupply()`; it needs none of the struct's fields, and binding the return value would copy it into memory for nothing. | test_ESC_014_GraduatedUnsoldSubjectIsSweptBeforeVesting |
| src/revenue/PaymentReceiverV1.sol | missing-zero-check | `splitter_` is zero-checked and self-checked by `_requireBindable` before any assignment, and the derived bindings are then read from that splitter. Slither's detector does not follow the private helper. | test_RCV_013_BeneficiaryAndSplitterBindingsAreImmutable |
| src/revenue/SubjectSplitterV1.sol | missing-zero-check | Every one of the seven bindings is zero-checked and self-checked by `_requireBindable` before any assignment. Slither's detector does not follow the private helper, so it reports the assignments it cannot see guarded. | test_SPL_001_RecognizedAssetsAreExactlyUsdcRegentAndSubject |

A `slither-disable` annotation anywhere under `src/`, `test/`, or `script/` requires a row
above that names the exact detector, the reason the finding is safe, and the Foundry test
that protects the property. The gate scans all three directories unconditionally — a
directory this repository does not have yet simply contributes no rows, so a later ticket
that adds `script/` is covered the moment it exists. It re-derives the annotations from the
source, fails if the recorded count disagrees, fails if any annotation lacks a rationale,
and fails if the named protecting test is not in Foundry's compiled test listing. Naming a
file is not enough. The recorded count is every detector token across every annotation; one
row covers each distinct file-and-detector pair.

Two findings that C0's Slither run would have reported against C1's first draft were not
suppressed but fixed: `resolveFailure` now records `Failed` and
`sweepGraduatedUnsoldSubject` now records its one-shot flag *before* any state-changing
external call, so a re-entrant auction meets an already-resolved launch even before the
reentrancy guard answers. `test_ESC_008_EscrowHoldsNoCustodyAuthorityOutsideResolution`
protects that ordering.

This table and the results table are read only within their own sections, so a row from one
can never stand in for a row in the other, and neither can be satisfied by the narrative
table below.

## Dispositions

| Date | Ticket | Scope analyzed | Disposition |
| --- | --- | --- | --- |
| 2026-08-20 | regent-alv1.1 (C0) | `src/bindings/BaseBindings.sol` and `src/bindings/FrozenIdentity.sol` — the two production Solidity units in the repository | Slither analyzed 2 contracts with 101 detectors and reported 0 results. Nothing was suppressed, filtered, or triaged. |
| 2026-08-20 | regent-alv1.1.1 (C0R) | unchanged: the same two production Solidity units | Same run, now reconciled against the pinned binary's 101 registered detector classes rather than a written-down number, with the configuration and the argv both pinned to their allowed shape. Slither analyzed 2 contracts with 101 detectors and reported 0 results. Nothing was suppressed, filtered, or triaged. |
| 2026-08-20 | regent-alv1.2 (C1) | `src/escrow/ConditionalVestingEscrowV1.sol`, `src/revenue/SubjectSplitterV1.sol`, `src/revenue/PaymentReceiverV1.sol`, `src/interfaces/**`, the two C0 binding units, and — for the first time — every pinned Solady and CCA source those production imports reach | Slither analyzed 25 contracts with 101 detectors and reported 1 result, dispositioned above. Dependency-only results are excluded because this repository does not own those sources; the surviving `pragma` result spans production and dependency files together and therefore stays visible. C1's own production Solidity contributes no medium or high result: two were fixed by moving the terminal-state write ahead of every state-changing external call, and eight annotations covering five file-and-detector pairs are recorded with their rationale and protecting test. Nothing was triaged, no path filter was configured, and no detector or severity was excluded. |

Every later ticket adds production Solidity to the same run, and every result it produces
gets a dated row here.
