# Launch profiles: v1 today and v2

**Status (27 September 2026): decided for all three launch types. Every value is fixed; the
only value a creator picks is the floor price, and a Revstake creator may also set a higher
minimum raise. The v2 contracts are `contracts/revstake-v2`, `contracts/stocks-v2` and
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

- **Minimum raise.** The whole sale allocation at the floor price, rounded up:
  `ceil(sale allocation × floorPriceQ96 / 2^96)`. A Revstake creator may set a higher minimum;
  Memestake has none. The minimum is never zero, so an auction nobody bid in never graduates.
- **Bidders receive the whole sale allocation.** After graduation each bid claims what the auction
  sold it plus a share of what the auction did not sell and of the reserve the pool did not pair:
  `shared × tokens the bid won / tokens the auction sold`. It is a claim anyone can send for a
  bid; the tokens always go to the bid's owner, once. Nothing is burned.
- **Pool price.** The raise divided by the whole sale allocation.
- **Failure.** Below the minimum the auction fails, every bidder is refunded by the auction, and
  the unsold supply is retired as in v1.
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
| Floor price | fixed 0.001 REGENT | creator picks; site default 0.000001 REGENT |
| Bid tick | floor ÷ 100 | same rule |
| Minimum raise | creator's | the larger of the floor minimum and the creator's minimum |
| Raise into the pool | whole raise | three quarters; the other quarter to the treasury |
| Pool price | the final clearing price | raise ÷ 20B, whole reserve in one full-range position |
| Auction length | 86,401 blocks, 13-step schedule | same |

Unchanged from v1: start delay 300 blocks; claim delay 64; migration delay 128; pool fee 0.30%;
pool tick spacing 60; two equal swap hook lanes; 2% splitter skim; 2.5% referral cap; name,
symbol, description, website and image limits of 64, 16, 512, 256 and 256 bytes.

## Memestake (Base)

Source: `stocks-v2/src/StocksPreset.sol`.

| Parameter | v1 (deployed) | v2 |
| --- | --- | --- |
| Total supply | 1,000,000,000 | same |
| Auction share | 80% | 50% |
| Pool reserve | 20% | 50% |
| Floor price | creator picks | same |
| Minimum raise | creator's | the floor minimum only |
| Raise into the pool | whole raise | whole raise |
| Pool price | the final clearing price | raise ÷ 500M, one full-range position, locked |
| Auction length | 43,200 blocks, 13-step schedule | same |

Unchanged from v1: start delay 300 blocks; claim delay 64; migration delay 128; pool fee 0.30%;
pool tick spacing 60; 1% REGENT lane and 1% staker lane; 2% splitter skim.

## Memestake (Robinhood Chain)

Source: `robinhood-v2/src/RobinhoodPreset.sol`. The same terms as Memestake on Base, in USDG,
with Robinhood's block counts: start delay 6,000; auction 864,000; claim delay 1,280; migration
delay 2,560. Stock the pool position cannot pair goes to the protocol lane.

## Founder decisions, 27 September 2026

These replace the earlier ranges, Safe-adjustable bounds and hard ceilings, which no v2
contract carries ("no more of the variable ranges").

1. Revstake sells 20%, pools 15% and vests 65%; Memestake sells 50% and pools 50%.
2. Keep the pinned auction and add the share-out after it.
3. Unsold tokens go to the bidders pro rata to what each won, as a claim; nothing is burned.
4. The pool opens at the raise divided by the whole sale allocation. Revstake puts three quarters
   of the raise in the pool and the rest in the treasury; Memestake puts all of it in the pool.
5. The minimum raise is the sale allocation at the floor, or a Revstake creator's higher
   minimum. The Revstake default floor is 0.000001 REGENT.
6. Rounding crumbs left with the strategy are acceptable.
7. Our bot sends graduation.
