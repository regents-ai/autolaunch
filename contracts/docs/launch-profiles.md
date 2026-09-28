# Launch profiles: v1 today and v2

**Status (28 September 2026): decided for all three launch types. Every value is fixed. The
contracts take a floor price and, for Revstake, an optional higher minimum raise, but the site
offers neither: it sends the fixed floors below and no creator minimum. The v2 contracts are `contracts/revstake-v2`, `contracts/stocks-v2` and
`contracts/robinhood-v2`, none deployed.**

Every timing value is counted in **blocks**. Base makes a block every 2 seconds and Robinhood
Chain every 0.1 seconds.

## Limits the auction contract sets on every launch

These come from the pinned Continuous Clearing Auction library (`ConstantsLib`, `StepStorage`):

- The floor price is at least `MIN_FLOOR_PRICE` = 2^32 + 1 in Q96, and the floor plus one tick
  must stay under the auction's highest allowed bid price.
- The bid tick spacing is at least `MIN_TICK_SPACING` = 2.
- The auction's token supply is at most `MAX_TOTAL_SUPPLY` = 2^100.
- The step schedule's block counts sum to the auction duration, and each step's rate multiplied
  by its block count sums to exactly 1e7.

## What every v2 launch does

- **Floor grid.** The floor must be a whole number of bid ticks: `floorPriceQ96` divisible by
  100, the bid tick being `floorPriceQ96 / 100`. A site rounds a chosen floor down to that grid.
- **Minimum raise.** The whole sale allocation at the floor price, rounded up:
  `ceil(sale allocation × floorPriceQ96 / 2^96)`. The Revstake contracts accept a higher
  minimum from a direct caller; the site sends none, and Memestake has none. The minimum is never zero, so an auction nobody bid in never graduates.
- **Bidders receive the whole sale allocation.** The pinned auction carries unsold supply forward
  and never lowers its price, so an auction that reaches the minimum below sells its whole sale
  allocation; bidders claim it from the auction as in v1. The pool price below pairs the reserve
  with the raise almost exactly, so what is left of the launch's token after graduation is rounding
  crumbs plus anything someone sent to the launch contract. Revstake sends it to the launch's
  escrow, where it vests to the treasury; Memestake retires it to the dead address, as in v1.
- **Pool price.** The raise divided by the whole sale allocation.
- **Failure.** Below the minimum the auction fails, every bidder is refunded by the auction, and
  the launch's whole supply is retired to the dead address, as in v1 (for Revstake that includes
  the 65% held for vesting).
- **Rounding at the minimum.** The pinned auction counts a bid placed after its first block up to
  one base unit short, so a site should ask for the minimum plus one base unit.
- **Graduation is sent by our bot** after the migration block; anyone may send it.

## Revstake (Base)

Sources: `revstake-v2/src/strategy/RegentLBPStrategyV2.sol`,
`revstake-v2/src/factory/RegentsAutolaunchFactoryV2.sol`,
`revstake-v2/src/escrow/ConditionalVestingEscrowV2.sol`.

| Parameter | v1 (deployed) | v2 |
| --- | --- | --- |
| Total supply | 100,000,000,000 | same |
| Auction share | 10% | 20% (20,000,000,000) |
| Pool reserve | 5% | 15% (15,000,000,000) |
| Vesting to the treasury | 85% | 65% (65,000,000,000), over 365 days |
| Floor price | fixed 0.001 REGENT | the site always sends 0.000001 REGENT, rounded down to the grid (`floorPriceQ96` 79,228,162,514,264,337,593,500), a minimum raise of just under 20,000 REGENT |
| Bid tick | floor ÷ 100 | same rule |
| Minimum raise | creator's | the floor minimum (the site sets no creator minimum) |
| Raise into the pool | whole raise | up to three quarters: the full-range position takes what it can pair from a three-quarter budget; the treasury receives the rest of the raise (at least a quarter) |
| Pool price | the final clearing price | raise ÷ 20B, reserve in one full-range position (any reserve it cannot pair goes to the escrow) |
| Auction length | 86,401 blocks, 13-step schedule | same |
| Swap hook fee | 1% Regent lane and 1% staker lane | 2%: a 1% Regent lane (to REGENT staking when the fee is in REGENT, to the Regent Safe when it is in the launch's token) and a 1% staker lane through the splitter |

Unchanged from v1: start delay 300 blocks; claim delay 64; migration delay 128; pool fee 0.30%;
pool tick spacing 60; 2% splitter skim; 2.5% referral cap; name,
symbol, description, website and image limits of 64, 16, 512, 256 and 256 bytes.

## Memestake (Base)

Source: `stocks-v2/src/StocksPreset.sol`.

| Parameter | v1 (deployed) | v2 |
| --- | --- | --- |
| Total supply | 1,000,000,000 | same |
| Auction share | 80% | 50% |
| Pool reserve | 20% | 50% |
| Floor price | creator picks | the site always sends the lowest floor the auction accepts: `floorPriceQ96` 4,294,967,300 (the auction's minimum, 2^32 + 1, rounded up to the grid), a minimum raise of 0.27105055 STOCK at 8 decimals |
| Minimum raise | creator's | the floor minimum only |
| Raise into the pool | whole raise | whole raise |
| Pool price | the final clearing price | raise ÷ 500M, one full-range position, locked |
| Auction length | 43,200 blocks, 13-step schedule | same |
| Swap hook fee | 1% REGENT lane and 1% staker lane | 4.3%, all in STOCK: a 0.3% creator lane paid to the launcher, a 1% REGENT lane sold for USDC into REGENT staking, and a 3% staker lane into the splitter |

Unchanged from v1: start delay 300 blocks; claim delay 64; migration delay 128; pool fee 0.30%;
pool tick spacing 60; 2% splitter skim.

## Memestake (Robinhood Chain)

Source: `robinhood-v2/src/RobinhoodPreset.sol`. The same terms as Memestake on Base, priced in the
stock itself (a bidder may pay in USDG, which is bought into the stock on the way in), with
Robinhood's block counts: start delay 6,000; auction 864,000; claim delay 1,280; migration
delay 2,560. The site sends the same lowest floor as on Base; with the stock's 18 decimals the
minimum raise is 0.000000000027105055 STOCK. The 1% lane is the protocol lane, sold for USDG into the Robinhood protocol inbox. Stock
the pool position cannot pair goes to the protocol lane.

## Founder decisions, 27 September 2026

These replace the earlier ranges, Safe-adjustable bounds and hard ceilings, which no v2
contract carries ("no more of the variable ranges").

1. Revstake sells 20%, pools 15% and vests 65%; Memestake sells 50% and pools 50%.
2. Keep the pinned auction.
3. First: unsold tokens go to the bidders pro rata to what each won, as a claim. Then (28 September):
   that share only ever pays rounding crumbs, because a successful auction always sells out, so it
   was removed to keep the contracts simple.
4. The pool opens at the raise divided by the whole sale allocation. Revstake puts three quarters
   of the raise in the pool and the rest in the treasury; Memestake puts all of it in the pool.
5. The minimum raise is the sale allocation at the floor, or a Revstake creator's higher
   minimum. The Revstake default floor is 0.000001 REGENT.
6. Rounding crumbs are acceptable.
7. Our bot sends graduation.

## Founder decisions, 28 September 2026

1. Memestake swap fees: 0.3% to the launch's creator, 3% to stakers, 1% to Regent, plus the 0.3%
   Uniswap LP fee. The creator's share is paid in the stock itself and anyone can send it.
2. Revstake swap fees: 1% to stakers and 1% to Regent, plus the 0.3% Uniswap LP fee. Regent's 1%
   goes to the REGENT staking contract when the fee is in REGENT and to the Regent Safe when it is
   in the launch's token.
3. Regent's Memestake share is not sold inside the trade. It waits in the hook and is sold for USDC
   into REGENT staking on Base, or for USDG into the protocol inbox on Robinhood, in a separate step.
4. Creators set no floor price and no minimum raise on the site. Memestake (Base and Robinhood)
   uses the lowest floor the auction accepts, so its minimum raise is the smallest the math allows.
   Revstake keeps the 0.000001 REGENT floor and its minimum of just under 20,000 REGENT.
5. Revstake's REGENT fee stays a plain transfer into REGENT staking's reward pool, and Memestake
   stakers keep 98% of their lane however much is staked.
