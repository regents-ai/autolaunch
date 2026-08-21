# C5 claim corrections and inherited obligations

Every change C5 made to a claim that a closed ticket already owned, and every inherited obligation
it discharged. C5 changed no contract behaviour: the only production edit is one comment range in
`src/bindings/BaseBindings.sol`, and `bin/gate.sh` proves every `src/**` compiled byte string is
byte-identical to the pre-edit C4 baseline captured before that edit.

## 1. Corrections to closed claims

| Claim | Owner | What was wrong | What C5 did |
| --- | --- | --- | --- |
| `FAC-023` | C4 | The statement admitted the raise interval without saying what a launch at either end settles on, which let the maximum *bid* price be read as a clearing price. | Statement corrected. `test_FAC_023_*` now asserts that a one-wei raise clears at the fixed floor — at both the lowest and the highest admitted bid tick — and records the LP amounts the position actually consumed: **1 wei REGENT and 981 wei SUBJECT**. |
| `STR-014` | C3 | The zero-liquidity fuzz derived its minimum raise from a claim the pinned CCA does not make: that a graduating checkpoint clears the whole remaining supply in one step. It does not. | Statement corrected and `testFuzz_STR_014_GraduatedDistributionNeverPlansZeroLiquidity` rewritten around the relation the CCA does prove — one uniform clearing price over whatever supply actually sold. Rewriting it surfaced a real constraint the overstatement had hidden: supply is indivisible, so a reachable raise is at least the price of one whole SUBJECT unit. The corrected fuzz passes across the whole genuinely reachable set. |
| `MIG-017` | C4 | Rollback was enumerated for graduation only, and the claim implied a `TAKE_PAIR` residue shape nobody had measured. | Statement corrected. The test now enumerates the retirement path's own five external calls as well, and records the residue: the strategy funds the position with exactly the amounts v4 charges, so the pinned planner's refund has nothing to return and the residue is **exactly zero in both currencies**. The claim now states that zero-only proof rather than a shape that cannot occur. |
| `HOK-006` | C2 | The statement did not name the boundaries that actually matter for a specified-currency charge taken before the swap resolves. | Statement narrowed to the partial-fill and zero-fill boundaries the existing test already drives. No test change. |
| `HOK-016` | C2 | "Settlement failure reverts the swap" did not distinguish the two insufficient-settlement branches. | Statement narrowed to name both: a splitter that reverts, and a splitter that returns without consuming the exact approved lane. Both were already exercised. No test change. |
| `HOK-018` | C2 | The statement was broader than the exercised evidence, and the nested sub-lane shapes were never driven. | Statement corrected to name exactly what is driven, and `test_HOK_018_*` **extended with the mandatory nested zero-lane sub-case**: a nested swap issued from inside the hook's settlement call, too small for either 1% lane to floor above zero. The hook's zero-lane branch returns before it takes, approves, or calls anything, leaves the outer swap's live approval untouched, and the outer swap settles exactly as an uninterrupted one would. The claim also now records that the nested attacker's own failure mode is an arithmetic panic in its outer settlement, not a hook-authored revert. |
| `FAC-002` | C4 | "No user salts" read as though the launcher had no influence on the created address at all. | Statement corrected: name and symbol *do* move the pinned UERC20 CREATE2 address, because the pinned factory hashes them into its own salt. That is upstream identity derivation, it confers no authority, and Autolaunch itself still exposes no public or creator-selected salt. |
| `FAC-015` | C4 | "The treasury is immutable" said nothing about the blast radius of a launcher-chosen one. | Statement corrected to name the radius: a hostile or broken treasury can break or strand only its own launch's value, while every other registered pool keeps settling. No denylist was added. |
| `STR-012` / `STR-018` | C3 | Both overlapped with `INV-009` and `MIG-018` on who owns cross-launch and repeated-call behaviour. | **Statement-only disambiguation.** `STR-012` and `STR-018` now own single-operation behaviour, `INV-009` owns sequence-level cross-launch isolation, and `MIG-018` owns repeated terminal calls. No selector and no test moved. |
| `INV-003` / `INV-005` / `INV-006` / `INV-009` / `INV-010` | C5 | Several were phrased loosely enough to be satisfied by one shared model. | Each given its own independent accounting model and a statement that says which question it answers. Principal, remainder, per-launch reserve conservation, cross-launch isolation, and attribution are five separate models. |
| `DEP-050` | C5 | "the latest Base head" left the comparison open-ended. | Narrowed to the pinned header recorded for *this candidate* and the later head captured for the same candidate. The ceremony-time fresh-head recheck stays with `regent-4wx`. |
| `ABI-007` | C5 | "exactly as the product watcher consumes them" made a claim about a downstream consumer this repository has no evidence about. | Narrowed to compiler and frozen-artifact truth only. The Ash watcher's own coverage is separate product work under `490.8.2/.3`. |

## 2. Known limitation carried, not fixed

`test_STR_012_ReserveIsIsolatedPerAuction` in `test/strategy/RegentLBPStrategy.t.sol` drives two
launches and, after retiring the first, rolls the block height *backwards* to the second launch's
start in order to bid on it. No chain can do that. The property it asserts is real and the test
passes, but the sequence it uses is not one production can produce.

That file is outside C5's allowed paths, so this is recorded rather than repaired. The same defect
was present in `test/factory/AutolaunchFactoryReceivers.t.sol`, which *is* inside the allowlist, and
there it was corrected: `test_FAC_024_*` now bids inside the launch's own open window before the
shared migration block, so its timeline only ever moves forward. `INV-009`'s handler is monotone by
construction for the same reason, so the sequence-level version of this property does have
production-reachable evidence.

**Proposed follow-up:** one narrow Tier-1 successor to make
`test_STR_012_ReserveIsIsolatedPerAuction` monotone, with no statement change.

## 3. Inherited obligations discharged

| Obligation | Disposition |
| --- | --- |
| C0R: `README.md` must describe the gate's actual order and layout | Corrected. The README's numbered gate order now matches `bin/gate.sh` exactly, including the frozen-surface check and the secret scan, and the layout table distinguishes `reports/generated/` from `reports/frozen/`. |
| C0R: the exact `BaseBindings` range correction | Applied. `DEP-040` through `DEP-050` became `DEP-040` through `DEP-051`, which is the whole production diff. Byte identity against the pre-edit C4 baseline is proved by the gate. |
| Freezer deletion must fail the ledger | `DEP-016` is a gate-dependency claim whose verified receipt only `bin/freeze-artifacts.py check` writes. Deleting the invocation from `bin/gate.sh` leaves the receipt absent and fails the ledger reconciliation. |
| Provider secret material must not reach evidence | `bin/check-requirements.py secrets` runs in both gates. It proves the configured `base` alias is still the unresolved `${REGENT_BASE_RPC_URL}` in the *effective* configuration, that no credential field carries a value, and that no scanned artifact names a host outside a documentation and provenance allowlist. |
| Cold/warm hook callback cost must be recorded separately | New claim `GAS-007`. See [gas-and-size.md](gas-and-size.md). |
