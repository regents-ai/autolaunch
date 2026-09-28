# Autolaunch on the Robinhood chain: security posture and invariant proofs

Status: version 2, unit-proven against fixtures, not deployed. Version 1 in `contracts/robinhood`
stays live on Robinhood Chain and Base for the launches made on it. The version 2 terms are the ones
`contracts/stocks-v2` documents in its own `SECURITY.md`; this file names the Robinhood proofs.

## Design rules applied everywhere

- Checks-effects-interactions in every state-changing function; terminal lifecycles are written
  before the first external call (`_graduate`, `_retire`), a bid's share is marked paid before it is
  transferred (`claimUnsoldShare`), lanes are debited before any token moves (`settleProtocolLane`,
  `settleStakerLane`), and the splitter writes its accounting before it routes the protocol share.
- Explicit reentrancy guard on `launch`, `migrate`, `claimUnsoldShare`, both hook settlements,
  `bidWithUsdg`, the route's `swapExactIn`, the inbox's deposit, bridging and recovery, the Base
  receiver's deposits, the locker's `collect` and every state-changing splitter function. Hook
  callbacks are additionally bounded by `BaseHook`'s PoolManager-only check and by v4's own lock.
- No `tx.origin`, no `delegatecall`, no caller-supplied calldata or router. Every external call goes
  to a pinned binding, to a contract this component created, to the Safe-admitted route of the
  STOCK in question, or to the splitter the launchpad itself cloned for that launch.
- Every transfer is verified by a balance delta; every temporary allowance is proved back at zero.
- Pinned `pragma solidity 0.8.26`, custom errors only, an event for every state change.
- Administrative mutators are admin-Safe-only; no launch has an administrator; the hook executor has
  exactly one power (`settleProtocolLane`, with `minUsdgOut`). `settleStakerLane`, the locker's
  `collect`, the splitter's revenue recognition and `claimUnsoldShare` are permissionless because
  none of them chooses an amount, a price or a destination.
- No function anywhere can move LP principal, the reserve, the NEW held for the share-out, or bidder
  funds: the launchpad has no transfer, sweep, rescue or approve surface for NEW or STOCK and pays NEW
  only to a bid's owner through `claimUnsoldShare`; the one position NFT is minted to the
  `MemestockLPLocker`, which has no transfer, approve or burn surface, only ever decreases liquidity
  by exactly zero, and sends what it collects to the splitter registered once for that position;
  bidder STOCK sits only in the CCA and leaves only through the CCA's own `exitBid`/`claimTokens`.
  A launch costs nothing and the launchpad never holds USDG.
- The launchpad's runtime is 18,719 bytes against the EIP-170 limit of 24,576, with the position
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
| 4 | `migrate` classifies with the final checkpoint; graduation clones the splitter, sweeps, opens the pool at the raise divided by the sale allocation (never above the final clearing price), mints one full-range position to the locker from the whole reserve and the whole raise and registers it to that splitter, so `lpCurrencyUsed + dust == raised` with `dust` the planner's rounding, credited to the protocol lane; the NEW the auction did not keep for its bids and the reserve the position did not pair are held for the share-out, so `newSold + newShared + lpNewUsed == S0` and nothing is retired; failure retires reserve and inventory and never touches bidder STOCK | `migrate`, `_graduate`, `_mintLockedPosition`, `_finishGraduation`, `_retire` | `RobinhoodLaunchpadMigrateTest` sole-bidder cases (`test_sole_bidder_at_the_start_receives_the_whole_sale_allocation_both_orderings`, `test_sole_bidder_in_the_last_eligible_block_receives_the_whole_sale_allocation`, `test_sole_bidder_partly_filled_at_its_limit_receives_the_whole_sale_allocation`, `testFuzz_sole_bidder_receives_the_whole_sale_allocation`) and `test_several_bidders_each_way_a_bid_ends_share_out_both_orderings`, each through `_migrateAndAssertGraduation` (pool price, one position owned by the locker and registered to the launch's splitter, the reserve placed up to one NEW in a billion of the supply, dust within one part in a billion of the raise and held by the hook, PositionManager balances unchanged, the auction holds only refunds, `newShared` within one NEW in a billion of the supply, nothing sent to the dead address); `test_eight_decimal_stock_graduates_and_shares_out`, `test_graduation_emits_the_record`, `test_stock_graduation_creates_the_splitter_and_locks_one_position_in_the_locker`, `test_failed_minimum_retires_inventory_and_reserve_and_refunds_through_the_cca`, `test_stock_launch_that_misses_the_raise_retires_every_new`, `test_migration_waits_for_the_migration_block`, `test_no_principal_path_exists_for_the_locked_position`, `test_launchpad_never_exposes_a_token_or_stock_withdrawal`, `test_each_graduation_gets_its_own_splitter`, `RobinhoodEighteenDecimalLifecycleTest.*` |
| 5 | Refunds and claims go through the CCA and depend on nothing here; the share-out pays each bid of a graduated launch `newShared × tokensFilled / newSold`, rounded down, at most once, to its owner whoever calls, before or after the bid's own exit and claim, and the shares never add up to more than `newShared`; NEW sent to the launchpad before migration joins `newShared` and never inflates a share | The launchpad never calls `exitBid`/`claimTokens`; `claimUnsoldShare` recomputes the fill from the auction's permanent checkpoints with `BidFillLib`, validating the hints `exitPartiallyFilledBid` validates; `newSold` is the sale allocation less what the auction's own sweep delivers, measured as a balance delta | `test_several_bidders_each_way_a_bid_ends_share_out_both_orderings` (outbid, partly filled and fully filled bids; share claimed before the exit, after it and after the claim; wrong hints refused), `test_share_is_paid_once_to_the_owner_whoever_calls`, `test_share_is_refused_until_graduation_and_for_a_failed_launch`, `test_share_is_refused_for_a_bid_the_auction_never_took`, `test_new_sent_to_the_launchpad_before_migration_joins_the_share_out`, `test_failed_minimum_retires_inventory_and_reserve_and_refunds_through_the_cca` |
| 6 | The hook only accrues; the protocol lane leaves only through `settleProtocolLane` (executor-only, admitted route, `minUsdgOut`, USDG into the inbox) and the staker lane only through `settleStakerLane` (anyone, whole lane, STOCK in kind, into the pool's fixed splitter) | `_afterSwap` only takes to itself and increments the two lanes; each settlement debits first and measures deltas | `RobinhoodFeeHookTest.*` |
| 7 | A pool's splitter is fixed at registration; the splitter pays out exactly what it recognized (2% to the protocol route, 98% to stakers, everything to the protocol route while nothing is staked); staked principal is never revenue; the locker never moves liquidity | `registerPool`, `MemestockSplitterCore`, `MemestockLPLocker` | `RobinhoodMemestockSplitterTest.*`, `RobinhoodLockedLiquidityTest.*`, `test_each_graduation_gets_its_own_splitter` |
| 8 | The adapter uses invocation deltas only, restores every allowance to zero, bids as `owner = msg.sender` | `bidWithUsdg` | `RobinhoodStockBidAdapterTest.*` |
| 9 | A launch costs nothing beyond gas and opens exactly 6,000 Robinhood blocks after its creation block | `launch` has no fee path; `_createAuction` binds the start and end blocks | `test_launch_costs_no_usdg_and_needs_no_allowance`, `test_auction_opens_exactly_ten_minutes_after_the_creation_block` |
| 10 | Protocol USDG is held in the inbox and leaves only through a Safe-configured bridge adapter, in recorded batches; the Base receiver deposits exactly what arrived | `RobinhoodProtocolRevenueInboxV1`, `RobinhoodBaseRevenueReceiverV1` | `RobinhoodInboxTest.*`, `RobinhoodBaseReceiverTest.*` |

## Known limits (not defects, but not proofs either)

- A graduated auction sells its whole sale allocation but for rounding, because the pinned auction
  never lowers its clearing price, carries unsold supply into later blocks, and the required raise is
  that allocation at the floor. The share-out therefore pays crumbs. It is kept because the founder
  decided the whole allocation reaches bidders (27 September 2026).
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
