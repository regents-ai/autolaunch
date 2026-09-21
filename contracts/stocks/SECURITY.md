# Autolaunch Stocks: security posture and invariant proofs

Status: `implemented-unverified` (unit-proven and fork-proven against fixtures; nothing here is
B20-verified or release-admitted). No public-chain deployment exists.

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
- The launchpad exposes the cross-component interface (`IStocksLaunchpadV1`) and nothing else: no
  helper views, no binding getters. Its runtime is 22,976 bytes against the EIP-170 limit of 24,576;
  additions must still be weighed in size.
- Hook callbacks are authenticated three ways: `onlyPoolManager` (BaseHook), the registered pool
  record, and `beforeInitialize`'s `sender == launchpad`.
- The production route (`AerodromeStockRouteV1`) is pinned at construction to one Slipstream pool
  (`token0 == USDC`, `token1 == STOCK` read back) and one Chainlink feed, has no owner and no
  parameter, calls the pool directly with the widest price limit, and bounds every execution by the
  feed: at most 5% under the feed quote, feed answer positive and at most 7 days old. Its pull
  callback accepts the pinned pool only; `swapExactIn` is `nonReentrant`; unconsumed input goes back
  to the recipient in the same call, so the route holds nothing between calls.

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
| 3 | `migrate` classifies with the final checkpoint; graduation sweeps, registers, initializes, clones the splitter, mints two positions to the locker in one PositionManager call and registers both to that splitter — the full range from the whole reserve and the STOCK it pairs, then a one-sided STOCK position from every remaining unit of net STOCK — with exact settlement amounts, so `lpStockUsed + lpStockOnlyUsed + dust == netStock` and `dust` is the planner's rounding residue (`< sqrt(clearingPrice)` base units; zero at every fixture price); retires unsold NEW; routes the residue; failure retires reserve and inventory and never touches bidder STOCK | `migrate`, `_graduate`, `_retire`, `_mintLockedPositions`, `_stockOnlyDefinition`, `_exactlyFundedPlan`; geometry in `StocksPreset.STOCK_ONLY_*` | `StocksLaunchpadMigrateTest.test_graduation_both_orderings` (sell-out: both NFTs in the locker, consecutive and registered to the launch's splitter, one-sided range adjacent to the initial tick on the STOCK side, raised == placed + dust, dust within the derived bound, reserve placed up to rounding, PositionManager balances unchanged, launchpad holds nothing), `test_graduation_with_less_than_a_quarter_sold_both_orderings` (STOCK-bound full range), `testFuzz_graduation_locks_all_net_stock_at_any_clearing_price` (every bid-grid price, both orderings), `test_graduation_emits_the_record`, `test_failed_minimum_*`, `test_failed_launch_with_no_bids`, `test_migrate_guards`, `test_nobody_can_initialize_the_official_pool_before_migration`, `test_no_principal_path_exists_for_either_locked_position`, `test_each_graduation_gets_its_own_splitter`, `test_launchpad_never_exposes_a_token_or_stock_withdrawal`; fork: `_assertAllNetStockLocked` in both graduated lifecycles against the real PositionManager |
| 4 | Refunds and claims go through the CCA and depend on nothing here | The launchpad never calls `exitBid`/`claimTokens`; it never holds bidder STOCK | `test_failed_minimum_retires_inventory_and_reserve_and_refunds_through_the_cca` (bidder refunded by `exitBid` after `migrate`), `StockBidAdapterTest.test_the_bid_settles_through_the_cca_for_the_caller_alone`; fork: `test_fork_failed_minimum_*` |
| 5 | The hook only accrues; the REGENT lane leaves only through `settleRegentLane` (executor-only, admitted route, `minUsdcOut`) and the staker lane only through `settleStakerLane` (anyone, whole lane, STOCK in kind, into the pool's fixed splitter); a failing settlement reverts only itself | `_afterSwap` only `take`s to itself and increments the two lanes; each settlement debits first, measures deltas, requires the reported amount to equal the measured one and the allowance back at zero | `StocksFeeHookTest.test_settle_regent_lane_deposits_usdc_into_live_staking`, `test_settle_regent_lane_re_credits_route_residue`, `test_settle_regent_lane_guards`, `test_settle_regent_lane_refuses_a_misbehaving_staking_and_reverts_only_itself` (swaps still work while settlement fails), `test_settle_staker_lane_is_permissionless_and_deposits_stock_in_kind_into_the_splitter`, `test_settle_staker_lane_guards`, `test_the_hooks_stock_balance_is_exactly_the_sum_of_both_lanes`, `test_accrual_event_reports_both_lanes`; fork: `test_fork_full_lifecycle_graduates_and_settles_the_regent_lane_into_live_staking`, `test_fork_stakers_receive_the_staker_lane_and_the_locked_positions_fees` |
| 6 | A pool's splitter is fixed at registration and nothing redirects either lane; the splitter pays out exactly what it recognized (`gross == protocolShare + stakerShare`, 2% to the protocol route, 98% wholly to stakers, everything to the protocol route while nothing is staked); staked principal is never revenue; the locker never moves liquidity | `registerPool` (launchpad-only, write-once, zero splitter refused); `MemestockSplitterCore._recognize`, `_routeProtocolShare`, the one-block exit rule; `MemestockLPLocker.register` (launchpad-only, write-once, ownership/pool/splitter checked) and `collect` (zero-liquidity decrease, invocation deltas only) | `MemestockSplitterTest.*` (binding and no administrator, USDC share into live staking, MEMESTOCK and STOCK shares to the Safe, pro rata with nothing held back, later stakers, unstaking keeps earnings, nothing staked, same-block exit refused, surplus recognition excludes principal and owed revenue, stray tokens and ETH to the Safe, failing staking fails only USDC recognition, `testFuzz_every_recognized_unit_is_the_protocols_or_a_stakers`), `MemestockLPLockerTest.*` (both currency orders, tagged deposit, pre-existing balances untouched, nothing staked, unregistered positions refused, write-once launchpad-only registration, ownership/pool/splitter checks), `StocksLaunchpadMigrateTest.test_each_graduation_gets_its_own_splitter` |
| 7 | The adapter uses invocation deltas only, restores every allowance to zero, bids as `owner = msg.sender` | `bidWithUsdc`: before/after balances, exact allowance consumption, ERC-20 and Permit2 allowances asserted zero, residue returned | `StockBidAdapterTest.*` (owner, exact pull, larger allowance consumed exactly, foreign auction, deadline, zero output, `minStockOut`, donated balances untouched, residue returned, atomic reverts); fork: adapter path with the real Permit2 |
| 8 | A launch costs nothing beyond gas and opens on a fixed clock: no REGENT is pulled, no allowance is needed, the staking contract is not called at creation (a paused staking contract cannot stop a launch) and the launchpad never holds REGENT; the start block is the creation block plus `START_LEAD_BLOCKS` (300), read back from the created auction and carried by the event; the required raise is the launcher's STOCK amount, refused at zero or above what the inventory can settle on | `launch` has no fee path and no staking call; `_createAuction` binds `startBlock` (field 5) and `endBlock` (field 6) to the created auction; `UnreachableRequiredRaise` in `launch` | `StocksLaunchpadLaunchTest.test_launch_costs_no_regent_and_needs_no_allowance` (penniless launcher, no allowance, `depositCalls() == 0`, launch while staking is paused, no REGENT moves through graduation), `test_auction_opens_exactly_ten_minutes_after_the_creation_block` (event, record and `auction.startBlock()` all equal creation + 300, a bid refused one block early and accepted on the block, a later creation opens later), `test_required_raise_is_chosen_by_the_launcher_above_zero_and_within_reach` (one base unit accepted, zero refused, `reachable + 1` refused, `reachable` accepted), `StocksPresetTest.test_timing_constants`; fork: `test_fork_launch_costs_nothing_and_opens_three_hundred_blocks_after_creation` (launcher holds no REGENT, record and real auction start equal creation + 300, a failed raise moves no REGENT) |

### Additional proofs

- Hook address permission bits and mined salt: `test_hook_address_carries_exactly_the_declared_permission_bits`, `test_a_fresh_launchpad_is_born_paused` (each launchpad mines its own hook).
- Callback authentication: `test_callbacks_are_pool_manager_only`, `test_swaps_on_an_unregistered_pool_with_this_hook_cannot_exist`, `test_registration_validates_the_whole_key`.
- Authority surface: `test_governance_only_mutators`, `test_launchpad_only_surface`, `test_clone_is_bound_once_to_the_launch_and_has_no_administrator`, `test_bindings_and_the_launchpad_only_write_once_registration`.
- Splitter provenance: every splitter is a clone the launchpad made inside `migrate` (`test_each_graduation_gets_its_own_splitter`); the hook and the locker accept a splitter only from the launchpad.
- Route: `AerodromeStockRouteTest.*` (pinned pool and feed with orientation and code checks, feed-price quotes both ways, stopped or non-positive feed refused, output under `minAmountOut` refused, executions more than 5% under the feed refused in both directions and for short fills, executions within 5% accepted, unconsumed input returned, nothing left on the route, reentry from the pool callback refused, callback from anyone but the pool refused); `AerodromeStockRouteForkTest.*` on Base (all ten admitted pool and feed bindings quote and round-trip, live AAPLc swaps both ways land within 1% of the feed, a swap beyond the pool's depth is refused by the bound).
- Arithmetic: `testFuzz_grossLane_is_the_smallest_fixed_point`, `testFuzz_bidTickSpacingFor_is_one_hundredth_of_an_on_grid_floor`, `StocksPresetTest.test_schedule_has_thirteen_steps_summing_to_the_duration_and_to_mps`.

## Known limits (not defects, but not proofs either)

- Revenue is shared among whoever is staked when it is recognized, and both the staker lane and the
  locked positions' LP fees arrive in lumps (when someone calls `settleStakerLane` or `collect`). A
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
  Anvil cannot run. Transfer policy and Permit2 compatibility of the live tokens are unproven
  (AT04, AT48). Every STOCK recognition transfers the protocol share to the Safe in the same call,
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
  production route is `AerodromeStockRouteV1` (`AerodromeStockRouteTest` hermetically over a v3-
  semantics pool double; `AerodromeStockRouteForkTest` against Base itself, with the fixture ERC-20
  installed over the `0xef` precompile so the live pool's liquidity and USDC are real but the stock
  token's transfer policy is not exercised). Admitting a route is still a governance call.
- The route's feed bound cuts both ways. The Chainlink feeds hold the last close outside market
  hours while the pools trade around the clock, so after a move of more than 5% over a weekend or
  holiday every bid and every REGENT-lane settlement for that stock reverts (`PriceDeviation`) until
  the feed reopens; the staker lane, which settles in kind, is unaffected. Conversely, within the 5%
  the caller's `minAmountOut` is the only slippage control. `launch` does not quote: the required
  raise is the launcher's STOCK amount and the CCA's raise test never reads the dollar.
- The one-sided STOCK position's width (adjacent tick-spacing boundary out to the last usable tick on
  the STOCK side) and the destination of the rounding residue (REGENT lane) are PROVISIONAL. The
  residue bound is a property of the pinned planner's arithmetic, derived in
  `StocksLaunchpadMigrateTest._roundingBound` and asserted at every fuzzed clearing price; it is not
  a guarantee about a different planner or tick spacing. Per-tick liquidity is not checked in code:
  the CCA's own maximum bid price keeps each position's liquidity under 2^107, and the spacing-60 cap is
  about 2^113 (observed: ~2^61 to ~2^68 per position at the fixture prices).
- `depositUSDC` on the live staking contract is permissionless on the fork at block 50984591; the
  fork proof records that, not a guarantee about future upgrades. Nothing at creation depends on the
  staking contract; only settlement of the REGENT lane and the splitter's USDC share reach it.
