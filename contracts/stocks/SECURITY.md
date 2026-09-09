# Autolaunch Stocks: security posture and invariant proofs

Status: `implemented-unverified` (unit-proven and fork-proven against fixtures; nothing here is
B20-verified or release-admitted). No public-chain deployment exists.

## Design rules applied everywhere

- Checks-effects-interactions in every state-changing function; terminal lifecycles are written
  before the first external call (`_graduate`, `_retire`), buckets are debited before any token moves
  (`settle`).
- Explicit reentrancy guard (Solady `ReentrancyGuardTransient`) on `launch`, `migrate`, `settle` and
  `bidWithUsdc`. Hook callbacks are additionally bounded by `BaseHook`'s PoolManager-only check and by
  v4's own lock.
- No `tx.origin`, no `delegatecall`, no caller-supplied calldata or router. Every external call goes
  to a pinned binding, to a contract this component created, to the governance-admitted route of the
  STOCK in question, or to a splitter whose provenance the deployed Agent strategy attests.
- Every transfer is verified by a balance delta; every temporary allowance is proved back at zero.
- Pinned `pragma solidity 0.8.26`, custom errors only, an event for every state change.
- Governance mutators are `GOVERNANCE_AND_REGENT_SAFE`-only; the fee administrator has exactly two
  powers (its launch's subject lane, its own two-step transfer); the hook executor has exactly one
  (`settle`, per bucket, with `minUsdcOut`).
- No function anywhere can move LP principal, the reserve, or bidder funds: the launchpad has no
  transfer, sweep, rescue or approve surface for NEW or STOCK; both position NFTs are minted to the
  dead address; bidder STOCK sits only in the CCA and leaves only through the CCA's own `exitBid`/
  `claimTokens`. REGENT touches the launchpad only as the launch fee in transit within `launch`; the
  launchpad's REGENT delta is proved zero before the call goes on.
- The launchpad exposes the cross-component interface (`IStocksLaunchpadV1`) and nothing else: no
  helper views, no binding getters. Its runtime is within about a hundred bytes of the EIP-170 limit
  (24,576); any addition must be paid for in size.
- Hook callbacks are authenticated three ways: `onlyPoolManager` (BaseHook), the registered pool
  record, and `beforeInitialize`'s `sender == launchpad`.

### Hook permission set (deviation from the brief's "afterSwap only")

Uniswap v4 lets an `afterSwap` return delta charge only the *unspecified* currency. Two of the four
swap forms specify STOCK (exact-input STOCK→NEW, exact-output NEW→STOCK), so an afterSwap-only hook
could not charge STOCK on them at all — a 100% fee bypass on the most common trade. The interface's
requirement ("STOCK-side hook fees on every swap") therefore needs `beforeSwap` +
`beforeSwapReturnDelta` as well. The hook declares `beforeInitialize, beforeSwap, afterSwap,
beforeSwapReturnDelta, afterSwapReturnDelta`; the address is CREATE2-mined for exactly those bits.
STOCK-specified swaps whose fill is cut short by the trader's own price limit revert
(`PartialFillNotSupported`) rather than charging an inexact pre-committed fee; STOCK-unspecified swaps
fill partially as usual. `test_fee_matrix_charges_stock_on_every_swap_form_with_conservation`
proves all 16 (ordering × form × subject) cases.

## Invariants (numbered as in README "Money and custody rules") and their proofs

| # | Rule | Where enforced | Proved by |
| --- | --- | --- | --- |
| 1 | Exactly `S0` minted, to the launchpad, once; `inventory + reserve == S0`; launchpad holds only the reserve after `launch` | `_createNew` (supply and balance read-back), `launch` (exact inventory delivery, `ReserveMismatch`) | `StocksPresetTest.test_allocation_splits_the_initial_supply_exactly`, `StocksLaunchpadLaunchTest.test_launch_mints_exactly_S0_once_and_keeps_only_the_reserve`, `test_launch_is_atomic_when_the_auction_creation_fails` |
| 2 | CCA `currency == stock`, both recipients the launchpad, `protocolFeeController == 0` | `_createAuction` reads back 11 bindings; `launch` refuses a nonzero controller | `test_auction_is_bound_to_stock_and_to_the_launchpad_as_both_recipients`; fork: `test_fork_full_lifecycle_*` against the real factory |
| 3 | `migrate` classifies with the final checkpoint; graduation sweeps, registers, initializes, mints two positions to dead in one PositionManager call — the full range from the whole reserve and the STOCK it pairs, then a one-sided STOCK position from every remaining unit of net STOCK — with exact settlement amounts, so `lpStockUsed + lpStockOnlyUsed + dust == netStock` and `dust` is the planner's rounding residue (`< sqrt(clearingPrice)` base units; zero at every fixture price); retires unsold NEW; routes the residue; failure retires reserve and inventory and never touches bidder STOCK | `migrate`, `_graduate`, `_retire`, `_mintLockedPositions`, `_stockOnlyDefinition`, `_exactlyFundedPlan`; geometry in `StocksPreset.STOCK_ONLY_*` | `StocksLaunchpadMigrateTest.test_graduation_both_orderings` (sell-out: both NFTs at dead and consecutive, one-sided range adjacent to the initial tick on the STOCK side, raised == placed + dust, dust within the derived bound, reserve placed up to rounding, PositionManager balances unchanged, launchpad holds nothing), `test_graduation_with_less_than_a_quarter_sold_both_orderings` (STOCK-bound full range), `testFuzz_graduation_locks_all_net_stock_at_any_clearing_price` (every bid-grid price, both orderings), `test_graduation_emits_the_record`, `test_failed_minimum_*`, `test_failed_launch_with_no_bids`, `test_migrate_guards`, `test_nobody_can_initialize_the_official_pool_before_migration`, `test_no_principal_path_exists_for_either_locked_position`; fork: `_assertAllNetStockLocked` in both graduated lifecycles against the real PositionManager |
| 4 | Refunds and claims go through the CCA and depend on nothing here | The launchpad never calls `exitBid`/`claimTokens`; it never holds bidder STOCK | `test_failed_minimum_retires_inventory_and_reserve_and_refunds_through_the_cca` (bidder refunded by `exitBid` after `migrate`), `StockBidAdapterTest.test_the_bid_settles_through_the_cca_for_the_caller_alone`; fork: `test_fork_failed_minimum_*` |
| 5 | The hook only accrues; `settle` is the only path out, executor-only, per bucket, via the admitted route, with `minUsdcOut`; a failing settle reverts only itself | `_afterSwap` only `take`s to itself and increments buckets; `settle` debits first, measures deltas, requires `received == usdcOut` and allowance zero | `StocksFeeHookTest.test_settle_regent_bucket_*`, `test_settle_subject_bucket_*`, `test_settle_guards`, `test_settle_refuses_a_misbehaving_staking_or_splitter_and_reverts_only_itself` (swaps still work while settlement fails), `test_settle_re_credits_route_residue`; fork: REGENT bucket into the real live staking, subject bucket into a real Agent splitter |
| 6 | Each accrual belongs to `(poolId, destination)` at swap time; disabling the subject lane charges nothing afterwards and never re-attributes old buckets | `PoolRecord.subject` is read per swap; `setSubject` only changes future accruals | `test_buckets_are_attributed_at_swap_time_and_never_redirected`, `test_accrual_event_names_the_destination_in_effect`, `StocksLaunchpadMigrateTest.test_configureSubject_after_graduation_reaches_the_hook` |
| 7 | The adapter uses invocation deltas only, restores every allowance to zero, bids as `owner = msg.sender` | `bidWithUsdc`: before/after balances, exact allowance consumption, ERC-20 and Permit2 allowances asserted zero, residue returned | `StockBidAdapterTest.*` (owner, exact pull, larger allowance consumed exactly, foreign auction, deadline, zero output, `minStockOut`, donated balances untouched, residue returned, atomic reverts); fork: adapter path with the real Permit2 |
| 8 | The launch fee is collected exactly and funded exactly into REGENT staking as staker rewards, before NEW or the auction exist, and is never refunded: `expectedLaunchFee == launchFee()` (`StaleLaunchFee`), launcher allowance `== fee` exactly (`LaunchFeeAllowanceMismatch`; zero fee moves nothing and still requires zero allowance), pull proved by the launchpad's delta, launcher allowance back at zero, `fundRegentRewards` `received == fee`, launchpad REGENT delta zero afterwards, staking allowance back at zero | `_collectAndFundLaunchFee`, called from `launch` before `_createNew`; `setLaunchFee` is `onlyGovernance`; no path in `migrate`, `_graduate` or `_retire` touches REGENT | `StocksLaunchpadLaunchTest.test_launch_collects_the_exact_fee_and_funds_it_into_staking` (deltas, `totalFundedRegent`, both allowances zero, event), `test_launch_refuses_a_stale_fee_before_anything_moves`, `test_launch_refuses_an_allowance_below_or_above_the_fee`, `test_launch_refuses_a_launcher_who_cannot_pay`, `test_launch_refuses_a_staking_that_does_not_take_the_whole_fee` (wrong `received`, paused staking; whole launch rolls back), `test_zero_fee_moves_nothing_and_still_requires_a_zero_allowance`, `test_launch_fee_changes_apply_to_later_launches_only`, `test_launch_fee_is_never_refunded` (staking keeps both fees through a failed-minimum `migrate` and a graduation), `test_launch_is_atomic_when_the_auction_creation_fails` (fee rolls back with the launch), `test_governance_only_mutators` (`setLaunchFee`), `test_launch_fee_is_born_at_the_preset`, `StocksPresetTest.test_launch_fee_is_the_founder_decided_hundred_thousand_regent`; fork: `test_fork_launch_fee_is_funded_into_the_real_live_staking_as_rewards` against the real live staking's `stakeToken()` and `totalFundedRegent()` delta, with a stale fee and an inexact allowance refused and the fee retained through a failed minimum |

### Additional proofs

- Hook address permission bits and mined salt: `test_hook_address_carries_exactly_the_declared_permission_bits`, `test_a_fresh_launchpad_is_born_paused` (each launchpad mines its own hook).
- Callback authentication: `test_callbacks_are_pool_manager_only`, `test_swaps_on_an_unregistered_pool_with_this_hook_cannot_exist`, `test_registration_validates_the_whole_key`.
- Authority surface: `test_governance_only_mutators`, `test_launchpad_only_surface`, `test_administrator_cannot_reach_anything_else`, `test_fee_administrator_transfer_is_two_step`, `test_configureSubject_is_administrator_only_and_versioned`.
- Splitter provenance: `test_inauthentic_splitters_are_refused` (codeless, unrecorded subject, impostor for a recorded subject); fork: a splitter the real Agent strategy graduated.
- Arithmetic: `testFuzz_grossLane_is_the_smallest_fixed_point`, `testFuzz_bidTickSpacingFor_is_one_hundredth_of_an_on_grid_floor`, `StocksPresetTest.test_schedule_has_thirteen_steps_summing_to_the_duration_and_to_mps`.

## Known limits (not defects, but not proofs either)

- The fixture STOCK (`FixtureStockToken`) stands in for Base-native `0xb2…` tokens whose `0xef` code
  Anvil cannot run. Transfer policy, Permit2 compatibility and the real acquisition route of the live
  tokens are unproven (AT04, AT48).
- `FixtureStockRoute` is a fixed-price lab fixture; a production `IStockRoute` is a separate admission.
- The one-sided STOCK position's width (adjacent tick-spacing boundary out to the last usable tick on
  the STOCK side) and the destination of the rounding residue (REGENT bucket) are PROVISIONAL. The
  residue bound is a property of the pinned planner's arithmetic, derived in
  `StocksLaunchpadMigrateTest._roundingBound` and asserted at every fuzzed clearing price; it is not
  a guarantee about a different planner or tick spacing. Per-tick liquidity is not checked in code:
  the CCA's own maximum bid price keeps each position's liquidity under 2^107, and the spacing-60 cap is
  about 2^113 (observed: ~2^61 to ~2^68 per position at the fixture prices).
- `depositUSDC` and `fundRegentRewards` on the live staking contract are permissionless on the fork
  at block 50984591 (`fundRegentRewards` is also `whenNotPaused`: a paused staking contract makes
  `launch` revert until governance sets a zero fee or staking resumes); the fork proof records that,
  not a guarantee about future upgrades.
