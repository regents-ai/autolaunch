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

<!-- slither-result-count: 3 -->

| Check | Impact | Confidence | Where | Disposition |
| --- | --- | --- | --- | --- |
| pragma | Informational | High | lib/continuous-clearing-auction/lib/liquidity-launcher/src/interfaces/IDistributor.sol#L2; lib/continuous-clearing-auction/lib/liquidity-launcher/src/interfaces/IDistributorFactory.sol#L2; lib/continuous-clearing-auction/lib/liquidity-launcher/src/interfaces/ILBPInitializer.sol#L2; lib/continuous-clearing-auction/lib/liquidity-launcher/src/interfaces/IProtocolFeeController.sol#L2; lib/continuous-clearing-auction/lib/liquidity-launcher/src/libraries/PositionPlanner.sol#L2; lib/continuous-clearing-auction/lib/liquidity-launcher/src/libraries/TickCalculations.sol#L2; lib/continuous-clearing-auction/lib/liquidity-launcher/src/libraries/TokenPricing.sol#L2; lib/continuous-clearing-auction/lib/liquidity-launcher/src/types/PositionPlannerTypes.sol#L2; lib/continuous-clearing-auction/lib/openzeppelin-contracts/contracts/utils/Panic.sol#L4; lib/continuous-clearing-auction/lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol#L4; lib/continuous-clearing-auction/lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L4; lib/continuous-clearing-auction/lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol#L5; lib/continuous-clearing-auction/src/interfaces/IAuctionStorage.sol#L2; lib/continuous-clearing-auction/src/interfaces/IBidStorage.sol#L2; lib/continuous-clearing-auction/src/interfaces/ICheckpointStorage.sol#L2; lib/continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol#L2; lib/continuous-clearing-auction/src/interfaces/IContinuousClearingAuctionFactory.sol#L2; lib/continuous-clearing-auction/src/interfaces/IStepStorage.sol#L2; lib/continuous-clearing-auction/src/interfaces/ITickStorage.sol#L2; lib/continuous-clearing-auction/src/interfaces/IValidationHook.sol#L2; lib/continuous-clearing-auction/src/libraries/BidLib.sol#L2; lib/continuous-clearing-auction/src/libraries/CheckpointLib.sol#L2; lib/continuous-clearing-auction/src/libraries/ConstantsLib.sol#L2; lib/continuous-clearing-auction/src/libraries/StepLib.sol#L2; lib/continuous-clearing-auction/src/libraries/ValueX7Lib.sol#L2; lib/liquidity-launcher/lib/solady/src/utils/FixedPointMathLib.sol#L2; lib/liquidity-launcher/lib/solady/src/utils/Initializable.sol#L2; lib/liquidity-launcher/lib/solady/src/utils/LibClone.sol#L2; lib/liquidity-launcher/lib/solady/src/utils/ReentrancyGuard.sol#L2; lib/liquidity-launcher/lib/solady/src/utils/ReentrancyGuardTransient.sol#L2; lib/liquidity-launcher/lib/solady/src/utils/SafeCastLib.sol#L2; lib/liquidity-launcher/lib/solady/src/utils/SafeTransferLib.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/permit2/src/interfaces/IEIP712.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/interfaces/IExtsload.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/interfaces/IExttload.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/interfaces/IProtocolFees.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/interfaces/external/IERC20Minimal.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/interfaces/external/IERC6909Claims.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/BitMath.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/CustomRevert.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/FixedPoint96.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/FullMath.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/LPFeeLibrary.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/LiquidityMath.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/ParseBytes.sol#L3; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/Position.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/ProtocolFeeLibrary.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/SafeCast.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/SqrtPriceMath.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/SwapMath.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/TickBitmap.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/TickMath.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/libraries/UnsafeMath.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/types/BalanceDelta.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/types/Currency.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/types/PoolId.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol#L2; lib/liquidity-launcher/lib/v4-periphery/lib/v4-core/src/types/Slot0.sol#L2; lib/liquidity-launcher/lib/v4-periphery/src/base/ImmutableState.sol#L2; lib/liquidity-launcher/lib/v4-periphery/src/interfaces/IEIP712_v4.sol#L2; lib/liquidity-launcher/lib/v4-periphery/src/interfaces/IERC721Permit_v4.sol#L2; lib/liquidity-launcher/lib/v4-periphery/src/interfaces/IImmutableState.sol#L2; lib/liquidity-launcher/lib/v4-periphery/src/interfaces/IMulticall_v4.sol#L2; lib/liquidity-launcher/lib/v4-periphery/src/interfaces/INotifier.sol#L2; lib/liquidity-launcher/lib/v4-periphery/src/interfaces/IPermit2Forwarder.sol#L2; lib/liquidity-launcher/lib/v4-periphery/src/interfaces/IPoolInitializer_v4.sol#L2; lib/liquidity-launcher/lib/v4-periphery/src/interfaces/IPositionManager.sol#L2; lib/liquidity-launcher/lib/v4-periphery/src/interfaces/ISubscriber.sol#L2; lib/liquidity-launcher/lib/v4-periphery/src/interfaces/IUnorderedNonce.sol#L2; lib/liquidity-launcher/lib/v4-periphery/src/libraries/ActionConstants.sol#L2; lib/liquidity-launcher/lib/v4-periphery/src/libraries/Actions.sol#L2; lib/liquidity-launcher/lib/v4-periphery/src/libraries/PositionInfoLibrary.sol#L2; lib/liquidity-launcher/lib/v4-periphery/src/utils/BaseHook.sol#L2; src/bindings/BaseBindings.sol#L2; src/bindings/FrozenIdentity.sol#L2; src/escrow/ConditionalVestingEscrowV1.sol#L2; src/hook/RegentFeeHook.sol#L2; src/interfaces/IERC20Minimal.sol#L2; src/interfaces/IRegentRevenueStakingMinimal.sol#L2; src/revenue/PaymentReceiverV1.sol#L2; src/revenue/SubjectSplitterV1.sol#L2; src/strategy/RegentLBPStrategy.sol#L2 | Accepted, unavoidable, and correctly visible; unchanged in kind from C1 and now wider only because C2 compiles the pinned v4 closure as well. It reports that the compiled closure spans five pragma constraints: every file this repository owns pins exactly `0.8.26`, while pinned Solady, CCA, liquidity-launcher, OpenZeppelin, v4-core, and v4-periphery sources carry the floating `^0.8.0`, `^0.8.4`, `^0.8.20`, and `^0.8.24` constraints their upstream authors wrote. The result's elements span production and dependency files together, so dependency exclusion correctly leaves it visible rather than hiding it. It is not a defect: the whole closure is compiled by the single frozen `0.8.26` compiler `DEP-009` reconciles against the governing `SPEC.md` build line, so no second compiler version is ever used, and rewriting a pinned submodule's pragma to silence it would break the frozen dependency identity `DEP-005` proves. |
| reentrancy-events | Low | Medium | src/hook/RegentFeeHook.sol#L223,L224,L225,L226,L227,L228,L229,L230,L231,L232,L233,L234,L235,L236,L237,L238,L239,L240,L241,L242,L243,L244,L245,L246,L247,L248,L249,L250,L251,L252; src/hook/RegentFeeHook.sol#L241; src/hook/RegentFeeHook.sol#L242; src/hook/RegentFeeHook.sol#L245; src/hook/RegentFeeHook.sol#L250 | Accepted, and it is a true observation of the ordering rather than a defect. `_chargeLanes` emits `SwapFeeSettled` after its three external calls — the two `PoolManager.take` calls and the splitter's `depositRecognizedRevenue` — because the event's contract is that a settlement *completed*, and the hook's attributable-balance check on the line above is the last thing that can reject it. The ordering is safe for three independent reasons. The hook keeps no per-swap state for a re-entrant call to observe or corrupt: every value in the event is a local derived from this call's own parameters, so a re-entrant frame cannot change what this frame emits. The event is observability only and is never authority — nothing on chain reads it. And a revert discards logs, so emitting before the calls would produce exactly the same observable log set while asserting a settlement that had not yet been verified. Re-entering the hook at that moment is proved to reach nothing: `test_HOK_018_*` re-enters from inside `depositRecognizedRevenue` and shows a re-entrant caller is neither the strategy nor the PoolManager, and that a nested swap on the same pool fails the whole transaction closed with no movement. |
| unimplemented-functions | Informational | High | lib/liquidity-launcher/lib/v4-periphery/src/utils/BaseHook.sol#L25; src/hook/RegentFeeHook.sol#L42,L43,L44,L45,L46,L47,L48,L49,L50,L51,L52,L53,L54,L55,L56,L57,L58,L59,L60,L61,L62,L63,L64,L65,L66,L67,L68,L69,L70,L71,L72,L73,L74,L75,L76,L77,L78,L79,L80,L81,L82,L83,L84,L85,L86,L87,L88,L89,L90,L91,L92,L93,L94,L95,L96,L97,L98,L99,L100,L101,L102,L103,L104,L105,L106,L107,L108,L109,L110,L111,L112,L113,L114,L115,L116,L117,L118,L119,L120,L121,L122,L123,L124,L125,L126,L127,L128,L129,L130,L131,L132,L133,L134,L135,L136,L137,L138,L139,L140,L141,L142,L143,L144,L145,L146,L147,L148,L149,L150,L151,L152,L153,L154,L155,L156,L157,L158,L159,L160,L161,L162,L163,L164,L165,L166,L167,L168,L169,L170,L171,L172,L173,L174,L175,L176,L177,L178,L179,L180,L181,L182,L183,L184,L185,L186,L187,L188,L189,L190,L191,L192,L193,L194,L195,L196,L197,L198,L199,L200,L201,L202,L203,L204,L205,L206,L207,L208,L209,L210,L211,L212,L213,L214,L215,L216,L217,L218,L219,L220,L221,L222,L223,L224,L225,L226,L227,L228,L229,L230,L231,L232,L233,L234,L235,L236,L237,L238,L239,L240,L241,L242,L243,L244,L245,L246,L247,L248,L249,L250,L251,L252,L253,L254,L255,L256,L257 | Accepted false positive, with the exact mechanism understood. `RegentFeeHook.getHookPermissions()` is declared with a body and is genuinely implemented. The detector iterates `contract.all_functions_called` and reports any entry whose `is_implemented` is false; `BaseHook`'s constructor calls `validateHookAddress(this)`, which calls `getHookPermissions()`, and Slither resolves that call to `BaseHook`'s bodyless `virtual` declaration instead of to the derived override, so the base declaration enters the called set unimplemented. Solidity's own dispatch does resolve it, which is why the hook cannot even be constructed unless the override returns a permission set matching the deployed address: `test_HOK_004_*` reads all fourteen fields from the deployed hook, confirms the address carries exactly the five declared bits, deploys once more through the pinned `HookMiner` and CREATE2, and shows an address without those bits is rejected by `Hooks.HookAddressNotValid`. |

`Where` is not prose: it is the exact normalized source mapping of the result, built from
the repository-relative filenames and line numbers in Slither's JSON, in the form
`src/Path.sol#L12,L13; src/Other.sol#L40`. The gate reconciles the four fingerprint columns
against the real run as a multiset in both directions, so a missing row, an extra row, a
mistyped location, and two same-detector findings sharing one row all fail.

The three rows above are the whole run. Every other result the analysis produced lives
entirely inside pinned dependency source, which this repository does not own, and is excluded
before dispositioning; the `pragma` result survives that exclusion precisely because its
elements span the pinned sources and this repository's own files together. After C2, the
production contracts this repository owns produce no medium or high result and no
undispositioned result of any severity.

## Inline suppressions

<!-- slither-suppression-count: 20 -->

| File | Detector | Rationale | Protecting test |
| --- | --- | --- | --- |
| src/escrow/ConditionalVestingEscrowV1.sol | incorrect-equality | `releasable == 0` is a zero test on a computed schedule amount, not a strict equality against a manipulable balance. It exists so a zero-value release is an exact no-op rather than a revert. | test_ESC_012_VestingReleasesLinearlyOverThreeSixtyFiveDays |
| src/escrow/ConditionalVestingEscrowV1.sol | timestamp | The vesting schedule is defined in `SPEC.md` as 365 days of wall-clock time from the graduation timestamp, so `block.timestamp` is the specified input. A validator can only move the boundary by seconds, which shifts a linear release by a proportional amount and can never over-release: `totalReleased` is the cap. | test_ESC_012_VestingReleasesLinearlyOverThreeSixtyFiveDays |
| src/escrow/ConditionalVestingEscrowV1.sol | unused-return | `IContinuousClearingAuction.checkpoint()` returns the terminal `Checkpoint` struct. Escrow calls it only to force the auction to finalize that block before it reads `isGraduated()` and `remainingSupply()`; it needs none of the struct's fields, and binding the return value would copy it into memory for nothing. | test_ESC_014_GraduatedUnsoldSubjectIsSweptBeforeVesting |
| src/revenue/PaymentReceiverV1.sol | missing-zero-check | `splitter_` is zero-checked and self-checked by `_requireBindable` before any assignment, and the derived bindings are then read from that splitter. Slither's detector does not follow the private helper. | test_RCV_013_BeneficiaryAndSplitterBindingsAreImmutable |
| src/revenue/SubjectSplitterV1.sol | missing-zero-check | Every one of the seven bindings is zero-checked and self-checked by `_requireBindable` before any assignment. Slither's detector does not follow the private helper, so it reports the assignments it cannot see guarded. | test_SPL_001_RecognizedAssetsAreExactlyUsdcRegentAndSubject |
| src/strategy/RegentLBPStrategy.sol | missing-zero-check | All four constructor bindings are zero-checked and self-checked by `_requireBindable`, and the three implementations additionally by `_requireImplementation`, before any assignment. Slither's detector does not follow either private helper, so it reports the four assignments it cannot see guarded. | test_STR_001_ImmutableBindingsAreFixedAtConstruction |
| src/strategy/RegentLBPStrategy.sol | incorrect-equality | `auction.code.length == 0` is a code-presence test on the contract the frozen CCA factory just created, not a strict equality against a manipulable balance or timestamp. It is the first line of the readback that proves the created auction is real before any value moves. | test_STR_013_CanonicalInitializationAdmitsOnlyTheFrozenParameterSet |
| src/strategy/RegentLBPStrategy.sol | unused-return | Three deliberate discards. `IContinuousClearingAuction.checkpoint()` returns the terminal `Checkpoint` struct, which migration forces only so classification reads a finalized auction. `IPoolManager.initialize` returns the opening tick, which the strategy re-derives from the price it supplied. `PositionPlanner.resolve` returns the unconsumed budgets, which the strategy deliberately ignores because it routes residues by exact balance delta — every remaining SUBJECT unit to escrow and every raised-REGENT unit to treasury — rather than by the planner's arithmetic. | test_STR_015_ActualLpConsumptionIsRecorded |
| src/strategy/RegentLBPStrategy.sol | reentrancy-no-eth | Both entry points carry the pinned transient `nonReentrant` guard, which Slither does not recognize, so it reports the terminal record `_graduate` writes after its external calls and the classification `migrate` can only make once the auction is checkpointed. The ordering is forced and safe: the terminal lifecycle is written before the first state-changing external call of each terminal path, so a re-entrant dependency meets a launch that is no longer active, and the trailing record is pure observation of calls that already succeeded. | test_STR_004_ReentrantDependencyCannotEnterASecondMutation |
| src/strategy/RegentLBPStrategy.sol | reentrancy-benign | The same transient guard covers `initializeDistribution`; the write Slither sees after the CCA factory's `create` is this launch's own record, written before any token moves, and a re-entrant call is refused by the guard before it can observe it. | test_STR_004_ReentrantDependencyCannotEnterASecondMutation |

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
| 2026-08-20 | regent-alv1.3 (C2) | `src/hook/RegentFeeHook.sol` and, for the first time, every pinned v4-core and v4-periphery source its imports reach through the periphery-owned tree, on top of the whole C0/C1 scope | Slither analyzed 44 contracts with 101 detectors and reported 3 results, dispositioned above. C2's first draft additionally produced two medium results against its own production Solidity, and both were fixed rather than suppressed: `registerPool` no longer declares `subject` before assigning it, and `_chargeLanes` now sums the two lanes as `lane + lane` instead of scaling one by two, which is also the literal form the specification uses. Nothing was triaged, no path filter was configured, no detector or severity was excluded, and C2 added no inline suppression. |
| 2026-08-20 | regent-alv1.2 (C1) | `src/escrow/ConditionalVestingEscrowV1.sol`, `src/revenue/SubjectSplitterV1.sol`, `src/revenue/PaymentReceiverV1.sol`, `src/interfaces/**`, the two C0 binding units, and — for the first time — every pinned Solady and CCA source those production imports reach | Slither analyzed 25 contracts with 101 detectors and reported 1 result, dispositioned above. Dependency-only results are excluded because this repository does not own those sources; the surviving `pragma` result spans production and dependency files together and therefore stays visible. C1's own production Solidity contributes no medium or high result: two were fixed by moving the terminal-state write ahead of every state-changing external call, and eight annotations covering five file-and-detector pairs are recorded with their rationale and protecting test. Nothing was triaged, no path filter was configured, and no detector or severity was excluded. |
| 2026-08-21 | regent-alv1.4 (C3) | `src/strategy/RegentLBPStrategy.sol` and, for the first time, the pinned `PositionPlanner`, `TokenPricing`, `TickCalculations`, Solady `LibClone`/`ReentrancyGuardTransient`/`SafeCastLib`, the v4-core pool and tick libraries, the v4-periphery `IPositionManager` surface, and the periphery-owned Permit2 interfaces its imports reach, on top of the whole C0/C1/C2 scope | Slither analyzed the enlarged closure with 101 detectors and reported the same 3 results dispositioned above; only the `pragma` result's element set grew, because the compiled closure is now wider. C3's own production Solidity contributes no undispositioned result. Twelve annotations covering five new file-and-detector pairs are recorded above with their rationale and protecting test; each one is a detector that cannot see through a private validation helper, a deliberate discard of a return value the strategy re-derives or routes by balance delta, or the pinned transient reentrancy guard Slither does not recognize. Nothing was triaged, no path filter was configured, and no detector or severity was excluded. |

Every later ticket adds production Solidity to the same run, and every result it produces
gets a dated row here.
