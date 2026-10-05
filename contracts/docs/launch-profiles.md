# Launch profiles: v1 today and v2

**Status (1 October 2026, amended 5 October): decided for all three launch types. Every value is fixed in the
contracts, including the floor price: no launch takes a floor or a minimum raise from its creator.
The v2 contracts are `contracts/revstake-v2`, `contracts/stocks-v2` and `contracts/robinhood-v2`,
none deployed.**

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

- **Floor.** Every launch uses the lowest floor the auction accepts, rounded up to the bid grid:
  `floorPriceQ96` 4,294,967,300 (2^32 + 1 rounded up to a multiple of 100), with a bid tick of
  42,949,673 (the floor ÷ 100).
- **Minimum raise.** The whole sale allocation at that floor, rounded up:
  `ceil(sale allocation × floorPriceQ96 / 2^96)`. It is tiny but never zero, so an auction nobody
  bid in never graduates, and in practice any real bid graduates a launch.
- **Bidders receive the whole sale allocation.** The pinned auction carries unsold supply forward
  and never lowers its price, so an auction that reaches the minimum sells its whole sale
  allocation; bidders claim it from the auction as in v1.
- **Pool price.** The auction's final clearing price.
- **Failure.** Below the minimum the auction fails, every bidder is refunded by the auction, and
  the launch's whole supply is retired to the dead address, as in v1 (including the share held for
  vesting).
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
| Pool reserve | 5% | at most 10% (10,000,000,000) |
| Vesting to the treasury | 85% | 70% (70,000,000,000) plus the reserve the pool did not take, over 365 days |
| Floor price | fixed 0.001 REGENT | the lowest floor above, for every launch |
| Bid tick | floor ÷ 100 | same rule |
| Minimum raise | creator's | the floor minimum only: 1,084,202,174 REGENT base units (about a billionth of a REGENT) |
| Raise into the pool | whole raise | at most half; the treasury receives the rest (at least half) |
| Pool price | the final clearing price | the final clearing price, one full-range position, locked |
| Auction length | 86,401 blocks, 13-step schedule | same (about 48 hours) |
| Swap hook fee | 1% Regent lane and 1% staker lane | 3.3%: a 0.3% creator lane paid to the launch's treasury, a 1% Regent lane and 2% to the launch's splitter |

Unchanged from v1: start delay 300 blocks; claim delay 64; migration delay 128; pool fee 0.30%;
pool tick spacing 60; 2% splitter skim; 2.5% referral cap; name,
symbol, description, website and image limits of 64, 16, 512, 256 and 256 bytes.

## Memestake (Base)

Source: `stocks-v2/src/StocksPreset.sol`.

| Parameter | v1 (deployed) | v2 |
| --- | --- | --- |
| Total supply | 1,000,000,000 | same |
| Auction share | 80% | 49.75% (497,500,000) |
| Pool reserve | 20% | 49.75% (497,500,000) |
| Creator vesting | none | 0.5% (5,000,000) to the launcher, linearly per block over 1,296,000 blocks (30 days) from graduation |
| Floor price | creator picks | the lowest floor above, for every launch |
| Minimum raise | creator's | the floor minimum only: 26,969,530 STOCK base units (about 0.27 of a share at 8 decimals) |
| Raise into the pool | whole raise | whole raise |
| Pool price | the final clearing price | the final clearing price; a full-range position pairs the whole raise and a second, NEW-only position holds the rest of the reserve just past the opening price; both locked |
| Auction length | 43,200 blocks, 13-step schedule | same (24 hours) |
| Swap hook fee | 1% REGENT lane and 1% staker lane | 4.3%, all in STOCK: a 0.3% creator lane paid to the launcher, a 1% REGENT lane sold for USDC into REGENT staking, and a 3% staker lane into the splitter |

Unchanged from v1: start delay 300 blocks; claim delay 64; migration delay 128; pool fee 0.30%;
pool tick spacing 60; 2% splitter skim.

## Memestake (Robinhood Chain)

Source: `robinhood-v2/src/RobinhoodPreset.sol`. The same terms as Memestake on Base, priced in the
stock itself (a bidder may pay in USDG, which is bought into the stock on the way in), with
Robinhood's block counts: start delay 6,000; auction 864,000 (24 hours); claim delay 1,280;
migration delay 2,560; creator vesting 25,920,000 (30 days). With the stock's 18 decimals the
minimum raise is 0.00000000002696953 STOCK. The 1% lane is the protocol lane, sold for USDG into
the Robinhood protocol inbox. Stock the full-range position cannot pair goes to the protocol lane.

## Founder decisions, 27 September 2026

Items 1, 4 and 5 are replaced by the 1 October decisions below.

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
2. Revstake swap fees: a 1% staker lane and 1% to Regent, plus the 0.3% Uniswap LP fee. The
   staker lane goes to the launch's splitter, which skims 2% for Regent and pays stakers the share
   of the rest that matches the share of all 100 billion tokens they have staked; the launch's
   treasury receives the remainder. Regent's 1%
   goes to the REGENT staking contract when the fee is in REGENT and to the Regent Safe when it is
   in the launch's token.
3. Regent's Memestake share is not sold inside the trade. It waits in the hook and is sold for USDC
   into REGENT staking on Base, or for USDG into the protocol inbox on Robinhood, in a separate step.
4. Creators set no floor price and no minimum raise on the site. Memestake (Base and Robinhood)
   uses the lowest floor the auction accepts, so its minimum raise is the smallest the math allows.
   Revstake keeps the 0.000001 REGENT floor and its minimum of just under 20,000 REGENT.
5. Revstake's REGENT fee stays a plain transfer into REGENT staking's reward pool, and Memestake
   stakers keep 98% of their lane however much is staked.

## Founder decisions, 1 October 2026

Items 1 and 5 are amended by the 5 October decisions below.

1. Memestake (Base and Robinhood) sells 49.5%, locks 49.5% in the pool and vests 1% to the
   launcher over 30 days, linearly per block from graduation.
2. Revstake sells 20%, keeps at most 10% for the pool and vests 70% to the treasury over 365
   days; the reserve the pool does not take vests with it.
3. Every launch uses the lowest floor; the minimum raise comes from the floor alone.
4. The pool opens at the auction's final clearing price. Memestake puts the whole raise in a
   full-range position and the rest of the reserve in a second, NEW-only position above the
   opening price, both locked forever. Revstake puts at most half the raise in the pool and the
   rest goes to the treasury.
5. Revstake swap fees: 1% to Regent and 2% to the launch's splitter, plus the 0.3% Uniswap LP fee.
   Memestake fees are unchanged from 28 September.

## Founder decisions, 5 October 2026

1. Memestake (Base and Robinhood) sells 49.75%, locks 49.75% in the pool and vests 0.5% to the
   launcher over 30 days, linearly per block from graduation. The launcher takes no share of the
   raise; the whole raise still goes to the pool. Nothing else in the 1 October terms moves; the
   minimum raise follows from the new sale allocation.
2. Revstake adds a 0.3% creator lane on top of its 3%, paid to the launch's treasury: 3.3% in all,
   plus the 0.3% Uniswap LP fee.
3. Memestake's creator lane stays 0.3%.
