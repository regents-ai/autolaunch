# Autolaunch Stocks: security posture and invariants

Status: version 2 deployed on Base. Deployment receipts and code checks are in
`deployments/base-mainnet/`. The verification record does not establish a complete v2
launch-to-claim run on Base. Version 1 in
`contracts/stocks` remains available for existing launches, with new creation paused.
The `AerodromeStockRouteV2` routes carry no execution price guard.

## Design rules applied everywhere

- Checks-effects-interactions in every state-changing function; terminal lifecycles are written
  before the first external call (`_graduate`, `_retire`), lanes are debited before any token moves
  (`settleCreatorLane`, `settleRegentLane`, `settleStakerLane`), and the splitter writes its accounting before it routes
  the protocol share.
- Explicit reentrancy guard (Solady `ReentrancyGuardTransient`) on `launch`, `migrate`,
  `releaseCreatorVesting`, all three hook
  settlements, `bidWithUsdc`, the locker's `collect` and every state-changing splitter function. Hook callbacks are additionally bounded by `BaseHook`'s PoolManager-only check and by
  v4's own lock.
- No `tx.origin`, no `delegatecall`, no caller-supplied calldata or router. Every external call goes
  to a pinned binding, to a contract this component created, to the governance-admitted route of the
  STOCK in question, or to the splitter the launchpad itself cloned for that launch.
- Every transfer is verified by a balance delta; every temporary allowance is proved back at zero.
- Pinned `pragma solidity 0.8.26`, custom errors only, an event for every state change.
- Governance mutators are `GOVERNANCE_AND_REGENT_SAFE`-only; no launch has an administrator; the
  hook executor has exactly one power (`settleRegentLane`, with `minUsdcOut`). `settleCreatorLane`,
  `settleStakerLane`, the locker's `collect` and the splitter's revenue recognition are permissionless
  because none of them chooses an amount, a price or a destination.
- The splitter has no owner, no pause, no upgrade path and no parameter: tokens are bound once at
  `initialize`, the implementation itself can never be initialized, the 2% protocol share and its
  destinations (live REGENT staking for USDC, the Safe for MEMESTOCK and STOCK) are constants.
  Staked principal and owed revenue are never counted as new revenue; only tokens outside the three
  recognized assets can be swept, and only to the Safe.
- No function anywhere can move LP principal, the reserve, or bidder funds: the launchpad has no
  transfer, sweep, rescue or approve surface for NEW or STOCK beyond `releaseCreatorVesting`, which
  pays only the vested part of the creator vesting and only to the launch's launcher; both position
  NFTs are minted to the
  `MemestockLPLocker`, which has no transfer, approve or burn surface, only ever decreases liquidity
  by exactly zero, and sends what it collects to the splitter registered once for that position;
  bidder STOCK sits only in the CCA and leaves only through the CCA's own `exitBid`/
  `claimTokens`. REGENT never touches the launchpad: a launch costs nothing and `launch` makes no
  call to the staking contract.
- The launchpad exposes the cross-component interface (`IStocksLaunchpadV2`) and nothing else: no
  helper views, no binding getters. Its runtime is 21,577 bytes against the EIP-170 limit of 24,576;
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
fill partially as usual.

## Invariants (numbered as in README "Money and custody rules")

| # | Rule | Where enforced |
| --- | --- | --- |
| 1 | Exactly `S0` minted, to the launchpad, once; `inventory + reserve + vesting == S0`; launchpad holds only the reserve and the vesting after `launch` | `_createNew` (supply and balance read-back), `launch` (exact inventory delivery, `ReserveMismatch`) |
| 2 | CCA `currency == stock`, both recipients the launchpad, `protocolFeeController == 0` | `_createAuction` reads back 11 bindings; `launch` refuses a nonzero controller |
| 3 | `migrate` classifies with the final checkpoint; graduation sweeps, registers, initializes at the final clearing price, clones the splitter, mints to the locker one full-range position from the whole raise and the reserve it takes there and, when any reserve is left, one NEW-only position just past the opening price from the rest, and registers both to that splitter, with exact settlement amounts, so `lpStockUsed + dust == raised` and `dust` is the planner's rounding residue, accrued to the REGENT lane; the creator vesting starts at the graduation block; every other unit of the launch's NEW still held afterwards (the auction's unsold rounding, the planner's rounding and anything sent to the launchpad) is retired to the dead address and recorded as `retiredNew`, so NEW kept by the auction `+ lpNewUsed + newOnlyUsed + retiredNew + vesting == S0` and the launchpad keeps only the vesting; failure retires reserve, vesting and inventory and never touches bidder STOCK | `migrate`, `_graduate`, `_retire`, `_mintLockedPositions`, `_exactlyFundedPlan` |
| 4 | Refunds and claims go through the CCA and depend on nothing here; once every bid of a graduated launch has exited and claimed at the auction, the bids hold the whole sale allocation but for crumbs | The launchpad never calls `exitBid`/`claimTokens` and never holds bidder STOCK |
| 5 | The hook only accrues; the creator lane leaves only through `settleCreatorLane` (anyone, whole lane, STOCK in kind, to the pool's fixed launcher), the REGENT lane only through `settleRegentLane` (executor-only, admitted route, `minUsdcOut`) and the staker lane only through `settleStakerLane` (anyone, whole lane, STOCK in kind, into the pool's fixed splitter); a failing settlement reverts only itself | `_afterSwap` only `take`s to itself and increments the three lanes; each settlement debits first, measures deltas, requires the reported amount to equal the measured one and the allowance back at zero |
| 6 | A pool's splitter and launcher are fixed at registration and nothing redirects any lane; the splitter pays out exactly what it recognized (`gross == protocolShare + stakerShare`, 2% to the protocol route, 98% wholly to stakers, everything to the protocol route while nothing is staked); staked principal is never revenue; the locker never moves liquidity | `registerPool` (launchpad-only, write-once, zero splitter or launcher refused); `MemestockSplitterCore._recognize`, `_routeProtocolShare`, the one-block exit rule; `MemestockLPLocker.register` (launchpad-only, write-once, ownership/pool/splitter checked) and `collect` (zero-liquidity decrease, invocation deltas only) |
| 7 | The adapter uses invocation deltas only, restores every allowance to zero, bids as `owner = msg.sender` | `bidWithUsdc`: before/after balances, exact allowance consumption, ERC-20 and Permit2 allowances asserted zero, residue returned |
| 8 | A launch costs nothing beyond gas and opens on a fixed clock: no REGENT is pulled, no allowance is needed, the staking contract is not called at creation (a paused staking contract cannot stop a launch) and the launchpad never holds REGENT; the start block is the creation block plus `START_LEAD_BLOCKS` (300), read back from the created auction and carried by the event; every auction uses the same lowest floor and the required raise is the whole sale allocation at that floor rounded up, never zero, so an auction nobody bid in never graduates | `launch` has no fee path and no staking call; `_createAuction` binds `startBlock` (field 5) and `endBlock` (field 6) to the created auction; `_createAuction` passes the preset floor, bid tick spacing and required raise and reads back the floor (field 9) and tick spacing (field 10) |

### Additional properties

- Each launchpad mines its own hook, and a fresh launchpad is born paused.
- Splitter provenance: every splitter is a clone the launchpad made inside `migrate`; the hook and
  the locker accept a splitter only from the launchpad.
- Creator vesting: nothing vests before graduation; it vests linearly per block from the graduation
  block and is whole after 1,296,000 blocks; anyone may call `releaseCreatorVesting` and only the
  launcher is paid; a failed launch releases nothing.

## Known limits (not defects)

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
  Anvil cannot run, so the lab never runs the live tokens (AT04, AT48). They were exercised on a
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
- The creator lane is paid to the launcher in STOCK and is never paid inside a swap, so a STOCK whose
  transfer policy refused the launcher stalls only `settleCreatorLane` for that launch; swaps, the
  REGENT lane and the staker lane are unaffected, and the lane stays in the hook until the transfer
  succeeds (founder decision 2026-09-28).
- `FixtureStockRoute` is a fixed-price lab fixture; the lab uses it. The production route is
  `AerodromeStockRouteV2`. Admitting a route is still a governance call.
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
  arithmetic; they are not guarantees about a different auction, planner or tick spacing. Per-tick liquidity is not checked in code: the CCA's own
  maximum bid price keeps the position's liquidity under 2^107, and the spacing-60 cap is about 2^113.
- A graduated auction sells its whole sale allocation but for rounding, because the pinned auction
  never lowers its clearing price, carries unsold supply into later blocks, and the required raise is
  that allocation at the floor. Bidders therefore receive the whole sale allocation from the auction
  itself, and graduation retires only crumbs plus anything sent to the launchpad. The crumbs come
  from prices kept to one unit of 2^-96 and never below the floor, so they stay below the supply
  divided by the floor price (about 0.23 NEW at the fixed floor).
- The pinned auction may count a bid placed after its first block up to one STOCK base unit short, so
  a bid of exactly the minimum graduates only in the first block. The website should show the
  minimum plus one base unit.
- `depositUSDC` on the live staking contract was permissionless at Base block 50984591; that reading
  is not a guarantee about future upgrades. Nothing at creation depends on the
  staking contract; only settlement of the REGENT lane and the splitter's USDC share reach it.
