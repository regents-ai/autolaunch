# Autolaunch on the Robinhood chain: security posture and invariant proofs

Status: version 2, unit-proven against fixtures, not deployed. Version 1 in `contracts/robinhood`
stays live on Robinhood Chain and Base for the launches made on it. The version 2 terms are the ones
`contracts/stocks-v2` documents in its own `SECURITY.md`; this file names the Robinhood proofs.

## Design rules applied everywhere

- Checks-effects-interactions in every state-changing function; terminal lifecycles are written
  before the first external call (`_graduate`, `_retire`), lanes are debited before any token moves
  (`settleCreatorLane`, `settleProtocolLane`, `settleStakerLane`), and the splitter writes its accounting before it
  routes the protocol share.
- Explicit reentrancy guard on `launch`, `migrate`, all three hook settlements, `bidWithUsdg`, the
  route's `swapExactIn`, the inbox's deposit, bridging and recovery, the Base receiver's deposits,
  the locker's `collect` and every state-changing splitter function. Hook callbacks are additionally bounded by `BaseHook`'s PoolManager-only check and by v4's own lock.
- No `tx.origin`, no `delegatecall`, no caller-supplied calldata or router. Every external call goes
  to a pinned binding, to a contract this component created, to the Safe-admitted route of the
  STOCK in question, or to the splitter the launchpad itself cloned for that launch.
- Every transfer is verified by a balance delta; every temporary allowance is proved back at zero.
- Pinned `pragma solidity 0.8.26`, custom errors only, an event for every state change.
- Administrative mutators are admin-Safe-only; no launch has an administrator; the hook executor has
  exactly one power (`settleProtocolLane`, with `minUsdgOut`). `settleCreatorLane`, `settleStakerLane`,
  the locker's `collect` and the splitter's revenue recognition are permissionless because none of them chooses
  an amount, a price or a destination.
- No function anywhere can move LP principal, the reserve or bidder funds: the launchpad has no
  transfer, sweep, rescue or approve surface for NEW or STOCK, and graduation retires every unit of
  the launch's NEW it still holds to the dead address, so it keeps none; the one position NFT is
  minted to the `MemestockLPLocker`, which has no transfer, approve or burn surface, only ever decreases liquidity
  by exactly zero, and sends what it collects to the splitter registered once for that position;
  bidder STOCK sits only in the CCA and leaves only through the CCA's own `exitBid`/`claimTokens`.
  A launch costs nothing and the launchpad never holds USDG.
- The launchpad's runtime is 16,099 bytes against the EIP-170 limit of 24,576, with the position
  planner in the linked `RobinhoodPositionsLib` and the hook creation code in
  `RobinhoodFeeHookFactory`; additions must still be weighed in size.
- Hook callbacks are authenticated three ways: `onlyPoolManager` (BaseHook), the registered pool
  record, and `beforeInitialize`'s `sender == launchpad`. The hook declares the same permission set
  as the Base hook, for the reason `contracts/stocks-v2/SECURITY.md` gives (an `afterSwap`-only hook
  could not charge STOCK on the two swap forms that specify it).

## Invariants and their proofs

| # | Rule | Where enforced | Proved by |
| --- | --- | --- | --- |
| 1 | Exactly `S0` minted, to the launchpad, once; the sale allocation and the reserve are each half of it; the launchpad holds only the reserve after `launch` | `_create` (supply and balance read-back, exact inventory delivery) | `test_stock_launch_requires_admission_and_records_the_launch`, `RobinhoodPresetTest.*` |
| 2 | CCA `currency == stock`, both recipients the launchpad, the Robinhood schedule, the required raise | `_createAuction` reads back every binding | `test_stock_launch_requires_admission_and_records_the_launch`, `test_auction_opens_exactly_ten_minutes_after_the_creation_block` |
| 3 | The required raise is the whole sale allocation at the floor, rounded up, never zero; the launcher chooses only the floor; an auction nobody bid in never graduates | `_requiredRaiseFor` in `_create`; `requiredStockRaisedFor` | `test_required_raise_is_the_sale_allocation_at_the_floor_rounded_up`, `testFuzz_required_raise_is_never_zero_and_never_below_the_floor_value`, `test_minimum_met_exactly_graduates_and_one_unit_below_fails`, `testFuzz_minimum_plus_one_unit_graduates_in_any_block`, `test_minimum_bid_after_the_first_block_is_counted_one_unit_short_and_fails`, `test_launch_nobody_bid_in_never_graduates` |
| 4 | `migrate` classifies with the final checkpoint; graduation clones the splitter, sweeps, opens the pool at the raise divided by the sale allocation (never above the final clearing price), mints one full-range position to the locker from the whole reserve and the whole raise and registers it to that splitter, so `lpCurrencyUsed + dust == raised` with `dust` the planner's rounding, credited to the protocol lane; every unit of the launch's NEW still held afterwards (the auction's unsold rounding, the reserve the position did not pair and anything sent to the launchpad) is retired to the dead address and recorded as `retiredNew`, so NEW kept by the auction `+ lpNewUsed + retiredNew == S0` and the launchpad keeps no NEW; failure retires reserve and inventory and never touches bidder STOCK | `migrate`, `_graduate`, `_mintLockedPosition`, `_finishGraduation`, `_retire` | `RobinhoodLaunchpadMigrateTest` sole-bidder cases (`test_sole_bidder_at_the_start_receives_the_whole_sale_allocation_both_orderings`, `test_sole_bidder_in_the_last_eligible_block_receives_the_whole_sale_allocation`, `test_sole_bidder_partly_filled_at_its_limit_receives_the_whole_sale_allocation`, `testFuzz_sole_bidder_receives_the_whole_sale_allocation`) and `test_several_bidders_each_way_a_bid_ends_receive_the_whole_sale_allocation_both_orderings`, each through `_migrateAndAssertGraduation` (pool price, one position owned by the locker and registered to the launch's splitter, the reserve placed within `_newCrumbs`, dust within one part in a billion of the raise and held by the hook, PositionManager balances unchanged, the auction holds only refunds, `retiredNew` is exactly the swept NEW plus the unpaired reserve, at the dead address and within `_newCrumbs` (the supply divided by the floor price), the supply reconciles exactly, the launchpad keeps no NEW); `test_new_sent_to_the_launchpad_before_migration_is_retired`, `test_eight_decimal_stock_graduates_and_sells_the_whole_sale_allocation`, `test_graduation_emits_the_record`, `test_stock_graduation_creates_the_splitter_and_locks_one_position_in_the_locker`, `test_failed_minimum_retires_inventory_and_reserve_and_refunds_through_the_cca`, `test_stock_launch_that_misses_the_raise_retires_every_new`, `test_migration_waits_for_the_migration_block`, `test_no_principal_path_exists_for_the_locked_position`, `test_launchpad_never_exposes_a_token_or_stock_withdrawal`, `test_each_graduation_gets_its_own_splitter`, `RobinhoodEighteenDecimalLifecycleTest.*` |
| 5 | Refunds and claims go through the CCA and depend on nothing here; once every bid of a graduated launch has exited and claimed at the auction, the bids hold the whole sale allocation but for crumbs | The launchpad never calls `exitBid`/`claimTokens` and never holds bidder STOCK | `test_failed_minimum_retires_inventory_and_reserve_and_refunds_through_the_cca` (bidder refunded by `exitBid` after `migrate`), the sole-bidder cases, `test_several_bidders_each_way_a_bid_ends_receive_the_whole_sale_allocation_both_orderings` (outbid, partly filled and fully filled bids), `testFuzz_minimum_plus_one_unit_graduates_in_any_block` and `test_eight_decimal_stock_graduates_and_sells_the_whole_sale_allocation`, each through `_assertWholeAllocationSold` (the bids received the sale allocation within `_newCrumbs`, never more, and the bids, the auction, the pool and the dead address hold the whole supply exactly), `RobinhoodEighteenDecimalLifecycleTest.*` |
| 6 | The hook only accrues; the creator lane leaves only through `settleCreatorLane` (anyone, whole lane, STOCK in kind, to the pool's fixed launcher), the protocol lane only through `settleProtocolLane` (executor-only, admitted route, `minUsdgOut`, USDG into the inbox) and the staker lane only through `settleStakerLane` (anyone, whole lane, STOCK in kind, into the pool's fixed splitter) | `_afterSwap` only takes to itself and increments the three lanes; each settlement debits first and measures deltas | `RobinhoodFeeHookTest.*` |
| 7 | A pool's splitter and launcher are fixed at registration; the splitter pays out exactly what it recognized (2% to the protocol route, 98% to stakers, everything to the protocol route while nothing is staked); staked principal is never revenue; the locker never moves liquidity | `registerPool`, `MemestockSplitterCore`, `MemestockLPLocker` | `RobinhoodMemestockSplitterTest.*`, `RobinhoodLockedLiquidityTest.*`, `test_each_graduation_gets_its_own_splitter` |
| 8 | The adapter uses invocation deltas only, restores every allowance to zero, bids as `owner = msg.sender` | `bidWithUsdg` | `RobinhoodStockBidAdapterTest.*` |
| 9 | A launch costs nothing beyond gas and opens exactly 6,000 Robinhood blocks after its creation block | `launch` has no fee path; `_createAuction` binds the start and end blocks | `test_launch_costs_no_usdg_and_needs_no_allowance`, `test_auction_opens_exactly_ten_minutes_after_the_creation_block` |
| 10 | Protocol USDG is held in the inbox and leaves only through a Safe-configured bridge adapter, in recorded batches; the Base receiver deposits exactly what arrived | `RobinhoodProtocolRevenueInboxV1`, `RobinhoodBaseRevenueReceiverV1` | `RobinhoodInboxTest.*`, `RobinhoodBaseReceiverTest.*` |

## Known limits (not defects, but not proofs either)

- A graduated auction sells its whole sale allocation but for rounding, because the pinned auction
  never lowers its clearing price, carries unsold supply into later blocks, and the required raise is
  that allocation at the floor. Bidders therefore receive the whole sale allocation from the auction
  itself, and graduation retires only crumbs plus anything sent to the launchpad (founder decision,
  27 September 2026). The crumbs come from prices kept to one unit of 2^-96 and never below the
  floor, so the tests assert them below the supply divided by the floor price: about 1.26 × 10^6
  base units of NEW at the 18-decimal test floor, where the largest measured is about 2.7 × 10^5,
  and about 1.26 × 10^16 for the eight-decimal case, where it measured about 4.35 × 10^14.
- The pinned auction may count a bid placed after its first block up to one STOCK base unit short, so
  a bid of exactly the minimum graduates only in the first block. The website should show the
  minimum plus one base unit.
- The residue and crumb bounds are properties of the pinned auction's and planner's arithmetic,
  asserted at every fuzzed bid, price and block; they are not guarantees about a different auction,
  planner or tick spacing.
- Revenue is shared among whoever is staked when it is recognized, and both the staker lane and the
  locked position's LP fees arrive in lumps. The splitter's exit rule reads the chain's native
  `block.number`, which on the Robinhood chain is the Ethereum block the rollup last observed, so a
  staker waits about twelve seconds, not one Robinhood block, before claiming or unstaking.
- The stock tokens are the issuer's upgradeable contracts: one issuer key can pause, block, burn or
  replace them. Used against any contract here it would stall bids, settlements and fee collection
  for that stock until reversed (README decision 14).
- The route has no price guard of its own; the price control is the minimum each caller sets, and
  several USDG pools are thin (README decisions 13 and 15). The executor's `minUsdgOut` is what
  protects the protocol's share, so the executor key must be kept safe.
