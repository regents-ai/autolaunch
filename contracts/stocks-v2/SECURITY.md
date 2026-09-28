# Autolaunch Stocks: security posture and invariant proofs

Status: version 2, unit-proven against fixtures, not deployed. The fork suite is written for it but
has not been run against Base for version 2. Version 1 in `contracts/stocks` stays live on Base with
ten stocks admitted through `AerodromeStockRouteV2` routes, which carry no execution price guard.

## Design rules applied everywhere

- Checks-effects-interactions in every state-changing function; terminal lifecycles are written
  before the first external call (`_graduate`, `_retire`), lanes are debited before any token moves
  (`settleRegentLane`, `settleStakerLane`), and the splitter writes its accounting before it routes
  the protocol share.
- Explicit reentrancy guard (Solady `ReentrancyGuardTransient`) on `launch`, `migrate`, both hook
  settlements, `bidWithUsdc`, the locker's `collect` and every state-changing splitter function. Hook callbacks are additionally bounded by `BaseHook`'s PoolManager-only check and by
  v4's own lock.
- No `tx.origin`, no `delegatecall`, no caller-supplied calldata or router. Every external call goes
  to a pinned binding, to a contract this component created, to the governance-admitted route of the
  STOCK in question, or to the splitter the launchpad itself cloned for that launch.
- Every transfer is verified by a balance delta; every temporary allowance is proved back at zero.
- Pinned `pragma solidity 0.8.26`, custom errors only, an event for every state change.
- Governance mutators are `GOVERNANCE_AND_REGENT_SAFE`-only; no launch has an administrator; the
  hook executor has exactly one power (`settleRegentLane`, with `minUsdcOut`). `settleStakerLane`,
  the locker's `collect` and the splitter's revenue recognition are permissionless because none of
  them chooses an amount, a price or a destination.
- The splitter has no owner, no pause, no upgrade path and no parameter: tokens are bound once at
  `initialize`, the implementation itself can never be initialized, the 2% protocol share and its
  destinations (live REGENT staking for USDC, the Safe for MEMESTOCK and STOCK) are constants.
  Staked principal and owed revenue are never counted as new revenue; only tokens outside the three
  recognized assets can be swept, and only to the Safe.
- No function anywhere can move LP principal, the reserve, or bidder funds: the launchpad has no
  transfer, sweep, rescue or approve surface for NEW or STOCK; both position NFTs are minted to the
  `MemestockLPLocker`, which has no transfer, approve or burn surface, only ever decreases liquidity
  by exactly zero, and sends what it collects to the splitter registered once for that position;
  bidder STOCK sits only in the CCA and leaves only through the CCA's own `exitBid`/
  `claimTokens`. REGENT never touches the launchpad: a launch costs nothing and `launch` makes no
  call to the staking contract.
- The launchpad exposes the cross-component interface (`IStocksLaunchpadV2`) and nothing else: no
  helper views, no binding getters. Its runtime is 22,976 bytes against the EIP-170 limit of 24,576;
  additions must still be weighed in size.
- Hook callbacks are authenticated three ways: `onlyPoolManager` (BaseHook), the registered pool
  record, and `beforeInitialize`'s `sender == launchpad`.
- The production route (`AerodromeStockRouteV2`) is pinned at construction to one Slipstream pool
  (`token0 == USDC`, `token1 == STOCK` read back) and one Chainlink feed, has no owner and no
  parameter, and calls the pool directly with the widest price limit. The price control is the
  minimum each caller sets: `swapExactIn` never reads the feed, and `quoteExactIn` (the feed price,
  refused when the answer is not positive or older than 7 days) is the review quote a caller
  chooses that minimum from. Its pull callback accepts the pinned pool only; `swapExactIn` is
  `nonReentrant`; unconsumed input goes back to the recipient in the same call, so the route holds
  nothing between calls.

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
proves all 8 (ordering × form) cases.

## Invariants (numbered as in README "Money and custody rules") and their proofs

| # | Rule | Where enforced | Proved by |
| --- | --- | --- | --- |
| 1 | Exactly `S0` minted, to the launchpad, once; `inventory + reserve == S0`; launchpad holds only the reserve after `launch` | `_createNew` (supply and balance read-back), `launch` (exact inventory delivery, `ReserveMismatch`) | `StocksPresetTest.test_allocation_splits_the_initial_supply_exactly`, `StocksLaunchpadLaunchTest.test_launch_mints_exactly_S0_once_and_keeps_only_the_reserve`, `test_launch_is_atomic_when_the_auction_creation_fails` |
| 2 | CCA `currency == stock`, both recipients the launchpad, `protocolFeeController == 0` | `_createAuction` reads back 11 bindings; `launch` refuses a nonzero controller | `test_auction_is_bound_to_stock_and_to_the_launchpad_as_both_recipients`; fork: `test_fork_full_lifecycle_*` against the real factory |
| 3 | `migrate` classifies with the final checkpoint; graduation sweeps, registers, initializes at the raise divided by the sale allocation, clones the splitter, mints one full-range position to the locker from the whole reserve and the whole raise and registers it to that splitter, with exact settlement amounts, so `lpStockUsed + dust == raised` and `dust` is the planner's rounding residue, accrued to the REGENT lane; every unit of the launch's NEW still held afterwards (the auction's unsold rounding, the reserve the position did not pair and anything sent to the launchpad) is retired to the dead address and recorded as `retiredNew`, so NEW kept by the auction `+ lpNewUsed + retiredNew == S0` and the launchpad keeps no NEW; failure retires reserve and inventory and never touches bidder STOCK | `migrate`, `_graduate`, `_retire`, `_mintLockedPosition`, `_exactlyFundedPlan` | `StocksLaunchpadMigrateTest` sole-bidder cases (`test_sole_bidder_at_the_start_receives_the_whole_sale_allocation_both_orderings`, `test_sole_bidder_in_the_last_eligible_block_receives_the_whole_sale_allocation`, `test_sole_bidder_partly_filled_at_its_limit_receives_the_whole_sale_allocation`, `testFuzz_sole_bidder_receives_the_whole_sale_allocation`) and `test_several_bidders_each_way_a_bid_ends_receive_the_whole_sale_allocation_both_orderings`, each through `_migrateAndAssertGraduation` (pool price == raise × 2^96 / sale allocation and never above the final clearing price, one position in the locker registered to the launch's splitter, dust within one part in a billion of the raise, PositionManager balances unchanged, the auction holds only refunds, `retiredNew` is exactly the swept NEW plus the unpaired reserve, at the dead address and within `_newCrumbs` (the supply divided by the floor price, about 0.0126 NEW at the test floor), the supply reconciles exactly, the launchpad keeps no NEW), `test_new_sent_to_the_launchpad_before_migration_is_retired`, `test_eighteen_decimal_stock_graduates_and_sells_the_whole_sale_allocation`, `test_graduation_emits_the_record`, `test_failed_minimum_retires_inventory_and_reserve_and_refunds_through_the_cca`, `test_launch_nobody_bid_in_never_graduates`, `test_migrate_guards`, `test_nobody_can_initialize_the_official_pool_before_migration`, `test_no_principal_path_exists_for_the_locked_position`, `test_each_graduation_gets_its_own_splitter`, `test_launchpad_never_exposes_a_token_or_stock_withdrawal`; fork: `_assertLocked` in both graduated lifecycles against the real PositionManager |
| 4 | Refunds and claims go through the CCA and depend on nothing here; once every bid of a graduated launch has exited and claimed at the auction, the bids hold the whole sale allocation but for crumbs | The launchpad never calls `exitBid`/`claimTokens` and never holds bidder STOCK | `test_failed_minimum_retires_inventory_and_reserve_and_refunds_through_the_cca` (bidder refunded by `exitBid` after `migrate`), the sole-bidder cases, `test_several_bidders_each_way_a_bid_ends_receive_the_whole_sale_allocation_both_orderings` (outbid, partly filled and fully filled bids), `testFuzz_minimum_plus_one_unit_graduates_in_any_block` and `test_eighteen_decimal_stock_graduates_and_sells_the_whole_sale_allocation`, each through `_assertWholeAllocationSold` (the bids received the sale allocation within `_newCrumbs`, never more, and the bids, the auction, the pool and the dead address hold the whole supply exactly), `StockBidAdapterTest.test_the_bid_settles_through_the_cca_for_the_caller_alone`; fork: `test_fork_failed_minimum_*`, every bidder settled through the CCA in both graduated lifecycles |
| 5 | The hook only accrues; the REGENT lane leaves only through `settleRegentLane` (executor-only, admitted route, `minUsdcOut`) and the staker lane only through `settleStakerLane` (anyone, whole lane, STOCK in kind, into the pool's fixed splitter); a failing settlement reverts only itself | `_afterSwap` only `take`s to itself and increments the two lanes; each settlement debits first, measures deltas, requires the reported amount to equal the measured one and the allowance back at zero | `StocksFeeHookTest.test_settle_regent_lane_deposits_usdc_into_live_staking`, `test_settle_regent_lane_re_credits_route_residue`, `test_settle_regent_lane_guards`, `test_settle_regent_lane_refuses_a_misbehaving_staking_and_reverts_only_itself` (swaps still work while settlement fails), `test_settle_staker_lane_is_permissionless_and_deposits_stock_in_kind_into_the_splitter`, `test_settle_staker_lane_guards`, `test_the_hooks_stock_balance_is_exactly_the_sum_of_both_lanes`, `test_accrual_event_reports_both_lanes`; fork: `test_fork_full_lifecycle_graduates_and_settles_the_regent_lane_into_live_staking`, `test_fork_stakers_receive_the_staker_lane_and_the_locked_positions_fees` |
| 6 | A pool's splitter is fixed at registration and nothing redirects either lane; the splitter pays out exactly what it recognized (`gross == protocolShare + stakerShare`, 2% to the protocol route, 98% wholly to stakers, everything to the protocol route while nothing is staked); staked principal is never revenue; the locker never moves liquidity | `registerPool` (launchpad-only, write-once, zero splitter refused); `MemestockSplitterCore._recognize`, `_routeProtocolShare`, the one-block exit rule; `MemestockLPLocker.register` (launchpad-only, write-once, ownership/pool/splitter checked) and `collect` (zero-liquidity decrease, invocation deltas only) | `MemestockSplitterTest.*` (binding and no administrator, USDC share into live staking, MEMESTOCK and STOCK shares to the Safe, pro rata with nothing held back, later stakers, unstaking keeps earnings, nothing staked, same-block exit refused, surplus recognition excludes principal and owed revenue, stray tokens and ETH to the Safe, failing staking fails only USDC recognition, `testFuzz_every_recognized_unit_is_the_protocols_or_a_stakers`), `MemestockLPLockerTest.*` (both currency orders, tagged deposit, pre-existing balances untouched, nothing staked, unregistered positions refused, write-once launchpad-only registration, ownership/pool/splitter checks), `StocksLaunchpadMigrateTest.test_each_graduation_gets_its_own_splitter` |
| 7 | The adapter uses invocation deltas only, restores every allowance to zero, bids as `owner = msg.sender` | `bidWithUsdc`: before/after balances, exact allowance consumption, ERC-20 and Permit2 allowances asserted zero, residue returned | `StockBidAdapterTest.*` (owner, exact pull, larger allowance consumed exactly, foreign auction, deadline, zero output, `minStockOut`, donated balances untouched, residue returned, atomic reverts); fork: adapter path with the real Permit2 |
| 8 | A launch costs nothing beyond gas and opens on a fixed clock: no REGENT is pulled, no allowance is needed, the staking contract is not called at creation (a paused staking contract cannot stop a launch) and the launchpad never holds REGENT; the start block is the creation block plus `START_LEAD_BLOCKS` (300), read back from the created auction and carried by the event; the required raise is the whole sale allocation at the floor price rounded up, never zero, so an auction nobody bid in never graduates | `launch` has no fee path and no staking call; `_createAuction` binds `startBlock` (field 5) and `endBlock` (field 6) to the created auction; `requiredStockRaisedFor` in `launch` | `StocksLaunchpadLaunchTest.test_launch_costs_no_regent_and_needs_no_allowance` (penniless launcher, no allowance, `depositCalls() == 0`, launch while staking is paused, no REGENT moves through graduation), `test_auction_opens_exactly_ten_minutes_after_the_creation_block` (event, record and `auction.startBlock()` all equal creation + 300, a bid refused one block early and accepted on the block, a later creation opens later), `test_required_raise_is_the_sale_allocation_at_the_floor_rounded_up`, `testFuzz_required_raise_is_never_zero_and_never_below_the_floor_value`, `StocksLaunchpadMigrateTest.test_minimum_met_exactly_graduates_and_one_unit_below_fails`, `testFuzz_minimum_plus_one_unit_graduates_in_any_block`, `test_minimum_bid_after_the_first_block_is_counted_one_unit_short_and_fails`, `StocksPresetTest.test_timing_constants`; fork: `test_fork_launch_costs_nothing_and_opens_three_hundred_blocks_after_creation` (launcher holds no REGENT, record and real auction start equal creation + 300, a failed raise moves no REGENT) |

### Additional proofs

- Hook address permission bits and mined salt: `test_hook_address_carries_exactly_the_declared_permission_bits`, `test_a_fresh_launchpad_is_born_paused` (each launchpad mines its own hook).
- Callback authentication: `test_callbacks_are_pool_manager_only`, `test_swaps_on_an_unregistered_pool_with_this_hook_cannot_exist`, `test_registration_validates_the_whole_key`.
- Authority surface: `test_governance_only_mutators`, `test_launchpad_only_surface`, `test_clone_is_bound_once_to_the_launch_and_has_no_administrator`, `test_bindings_and_the_launchpad_only_write_once_registration`.
- Splitter provenance: every splitter is a clone the launchpad made inside `migrate` (`test_each_graduation_gets_its_own_splitter`); the hook and the locker accept a splitter only from the launchpad.
- Route: `AerodromeStockRouteTest.*` (pinned pool and feed with orientation and code checks, feed-price quotes both ways, stopped or non-positive feed refused, output under `minAmountOut` refused, executions far under the feed executed when the caller's minimum allows and refused by that minimum alone, in both directions and for short fills, a swap executed while the feed is stale and the quote reverts, unconsumed input returned, nothing left on the route, reentry from the pool callback refused, callback from anyone but the pool refused); `AerodromeStockRouteForkTest.*` on Base (all ten admitted pool and feed bindings quote and round-trip, live AAPLc swaps both ways land within 1% of the feed, a purchase beyond the pool's depth is refused by a 95%-of-quote minimum and executes at a zero minimum).
- Arithmetic: `testFuzz_grossLane_is_the_smallest_fixed_point`, `testFuzz_bidTickSpacingFor_is_one_hundredth_of_an_on_grid_floor`, `StocksPresetTest.test_schedule_has_thirteen_steps_summing_to_the_duration_and_to_mps`.

## Known limits (not defects, but not proofs either)

- Revenue is shared among whoever is staked when it is recognized, and both the staker lane and the
  locked position's LP fees arrive in lumps (when someone calls `settleStakerLane` or `collect`). A
  holder can therefore stake just before a large settlement. The one-block exit rule removes the
  same-block version of this; frequent settlement keeps the lumps small. The rule reads the chain's
  native `block.number`; on the Robinhood chain (an Arbitrum Orbit rollup) that is the Ethereum
  block the rollup last observed, so the wait there is until the next Ethereum block, about twelve
  seconds, not one 0.1-second Robinhood block (verified read-only on chain 4663, 21 September 2026). No contract rule removes
  it entirely. The same applies to the "everything to the protocol route while nothing is staked"
  rule: it holds only until anyone stakes any amount, so a one-unit stake placed just before a
  settlement of an unstaked market's accrual takes the 98% share of that lump (independent review
  2026-09-19, L-1).
- A holder's entitlement can be one base unit short per recognition when the stake does not divide
  the amount evenly; the remainder is carried forward to the next recognition, never lost and never
  paid to anyone else.

- The fixture STOCK (`FixtureStockToken`) stands in for Base-native `0xb2…` tokens whose `0xef` code
  Anvil cannot run, so no local test exercises the live tokens (AT04, AT48). They were exercised on a
  Base node instead (read-only simulation, 23 September 2026, all ten admitted stocks): each moved
  through the bid adapter's exact Permit2 allowance path (ERC-20 allowance to Permit2, Permit2
  allowance to a puller, `transferFrom`) with both allowances back at zero, and each deployed route
  bought and sold it against its live pool near the Chainlink price. Every STOCK recognition transfers the protocol share to the Safe in the same call,
  and `collect` deposits both currencies of a position together, so a STOCK whose transfer policy
  refused the Safe would stall `collect` and `settleStakerLane` for every market on that STOCK
  (funds stay in the hook and the position; nothing is lost) with no recipient change or partial
  collect available (independent review 2026-09-19, M-1). A live-token observation on 2026-09-19
  showed ordinary and contract addresses transferring AAPLc around the clock, and a read-only
  simulation on Base the same day (`eth_call` of `transfer` from each stock's Slipstream pool, two
  independent RPCs) delivered all ten admittable stocks to the Safe and to a never-used address,
  while an over-balance control reverted. No recipient allowlist blocks the Safe today; the issuer
  changing the policy later is not ruled out. Accepted as a known limit (founder decision
  2026-09-19).
- `FixtureStockRoute` is a fixed-price lab fixture; the lab and the hermetic suite still use it. The
  production route is `AerodromeStockRouteV2` (`AerodromeStockRouteTest` hermetically over a v3-
  semantics pool double; `AerodromeStockRouteForkTest` against Base itself, with the fixture ERC-20
  installed over the `0xef` precompile so the live pool's liquidity and USDC are real but the stock
  token's transfer policy is not exercised). Admitting a route is still a governance call.
- The route has no price guard of its own. The Chainlink feeds hold the last close outside market
  hours while the pools trade around the clock, so the feed quote and the pool price drift apart
  over a weekend or holiday; the price control is the minimum each caller sets, and nothing else
  refuses an execution under the feed. The executor's `minUsdcOut` is what protects REGENT's share
  of every REGENT-lane settlement, so the executor key must be kept safe and sales should be split
  into pieces small enough for the pool at hand in a thin market; the website offers bidders a
  minimum at 95% of the Chainlink price. The staker lane settles in kind and never prices. `launch`
  does not quote: the required raise follows from the floor in STOCK and the CCA's raise test never
  reads the dollar.
- The destination of the rounding residue (REGENT lane) is the founder's decision of 9 September
  2026; the pool price, the single position and retiring the NEW left over at graduation are the
  founder's decisions of 27 September 2026. The residue and crumb bounds are properties of the pinned auction's and planner's
  arithmetic, asserted at every fuzzed bid, price and block; they are not guarantees about a
  different auction, planner or tick spacing. Per-tick liquidity is not checked in code: the CCA's own
  maximum bid price keeps the position's liquidity under 2^107, and the spacing-60 cap is about 2^113.
- A graduated auction sells its whole sale allocation but for rounding, because the pinned auction
  never lowers its clearing price, carries unsold supply into later blocks, and the required raise is
  that allocation at the floor. Bidders therefore receive the whole sale allocation from the auction
  itself, and graduation retires only crumbs plus anything sent to the launchpad. The crumbs come
  from prices kept to one unit of 2^-96 and never below the floor, so the tests assert them below the
  supply divided by the floor price (about 1.26 × 10^16 base units of NEW at the test floor); the
  largest measured is about 2.36 × 10^15.
- The pinned auction may count a bid placed after its first block up to one STOCK base unit short, so
  a bid of exactly the minimum graduates only in the first block. The website should show the
  minimum plus one base unit.
- `depositUSDC` on the live staking contract is permissionless on the fork at block 50984591; the
  fork proof records that, not a guarantee about future upgrades. Nothing at creation depends on the
  staking contract; only settlement of the REGENT lane and the splitter's USDC share reach it.
