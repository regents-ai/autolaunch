# Launch profiles: v1 today, v2 defaults and bounds

**Status: decisions 1–4 are made (27 September 2026). The hard ceilings in
[Hard ceilings](#hard-ceilings) are proposed and await Sean's approval. No v2 contract code
is authorised yet; a new session will own the v2 contracts.**

Founder decision (27 September 2026, "1a"): in v2, the creator sets each launch's
parameters within bounds the founder sets. The defaults are written down here before any
code. v1 keeps running beside v2; whether v1 launch creation closes when v2 opens is a
separate founder decision with its own Safe transaction.

How to read the tables:

- **v1 (deployed)** is the value in the deployed source today, with its file. Every timing
  value is counted in **blocks**, not seconds. Base makes a block every 2 seconds and
  Robinhood Chain every 0.1 seconds.
- **v2 default** is what a launch gets when the creator leaves the value alone. Each
  default is the v1 value, so a creator who changes nothing gets a v1 launch.
- **v2 bounds** is the range a creator may choose from. "Fixed" means the creator cannot
  change it (the lowest and highest allowed value are both the default).
- **Already chosen by the creator in v1** marks values the creator already picks today.

## Limits the auction contract sets on every launch

These come from the pinned Continuous Clearing Auction library (`ConstantsLib`,
`StepStorage`). No bound can go beyond them:

- The floor price is at least `MIN_FLOOR_PRICE` = 2^32 + 1 in Q96, and the floor plus one
  tick must stay under the auction's highest allowed bid price.
- The bid tick spacing is at least `MIN_TICK_SPACING` = 2.
- The auction's token supply is at most `MAX_TOTAL_SUPPLY` = 2^100.
- The step schedule's block counts sum to the auction duration, and each step's rate
  multiplied by its block count sums to exactly 1e7.
- Claiming opens at or after the auction's end.

## Revstake (Base)

Sources: `v1/src/strategy/RegentLBPStrategy.sol`, `v1/src/escrow/ConditionalVestingEscrowV1.sol`,
`v1/src/factory/RegentsAutolaunchFactoryV1.sol`, `v1/src/hook/RegentFeeHook.sol`,
`v1/src/revenue/SubjectSplitterV1.sol` and `v1/src/revenue/PaymentReceiverV1.sol`.

| Parameter | v1 (deployed) | v2 default | v2 bounds (min–max) |
| --- | --- | --- | --- |
| Total supply | 100,000,000,000 tokens (`TOTAL_SUPPLY`) | 100,000,000,000 | Fixed |
| Auction share | 10% (`AUCTION_ALLOCATION` 10B) | 10% | 5%–50% |
| LP reserve share | 5% (`RESERVE_ALLOCATION` 5B) | 5% | 5%–50% |
| Vesting share (held while the launch is pending) | 85% (`PENDING_ALLOCATION` 85B) | 85% | What remains; auction + reserve + vesting = 100% |
| Pulled from the factory at start | 15B (`DISTRIBUTION_PULL`, auction + reserve) | Auction + reserve | Follows the two shares |
| Vesting length | 365 days (`VESTING_DURATION`) | 365 days | 90–730 days |
| Start delay | 300 blocks, 10 minutes (`START_DELAY_BLOCKS`) | 300 blocks | Fixed. This matches Memestake, where a founder decision on 21 September fixed the start at ten minutes |
| Auction length | 86,401 blocks, about 48 hours (`AUCTION_DURATION_BLOCKS`) | 86,401 blocks | 21,601 blocks (12 hours) to 302,401 blocks (7 days) |
| Claim delay after the end | 64 blocks (`CLAIM_DELAY_BLOCKS`) | 64 blocks | Fixed |
| Migration delay after the end | 128 blocks (`MIGRATION_DELAY_BLOCKS`) | 128 blocks | Fixed |
| Floor price | 0.001 REGENT per token, Q96 79,228,162,514,264,337,593,543,900 (`FLOOR_PRICE_Q96`) | 0.001 REGENT | Creator chooses at or above the auction contract's minimum, dividing exactly by 100 |
| Bid tick spacing | Floor ÷ 100, Q96 792,281,625,142,643,375,935,439 (`BID_TICK_Q96`) | Floor ÷ 100 | Fixed rule: always floor ÷ 100 (the floor must divide exactly) |
| Release schedule | 13 steps: 12 windows from 10,894 blocks at 54 mps down to 6,043 blocks at 97 mps, each releasing about 5.8%, then one final block releasing the remaining 2,988,006 mps (`AUCTION_STEPS`) | Same shape | Fixed shape, recomputed from the chosen length (see decision 2) |
| Required raise | **Already chosen by the creator in v1**: above zero and at most the most the auction can reach (`MAX_REACHABLE_RAISE`) | No default | Above zero, at most what the chosen supply, floor and schedule can reach |
| Pool fee | 0.30% (`POOL_FEE` 3000) | 0.30% | Fixed |
| Pool tick spacing | 60 (`POOL_TICK_SPACING`) | 60 | Fixed |
| Swap hook lanes | Two equal lanes, each fee base ÷ 100 (`LANE_DIVISOR`) | Same | Fixed (standing rule: keep the swap hook and every lane) |
| Splitter skim | 2% (`SKIM_BPS` 200) | 2% | Fixed (standing rule: keep the 2% skim) |
| Most a referral can take | 2.5% (`MAX_REFERRAL_BPS` 250) | 2.5% | Fixed |
| Name, symbol, description, website, image limits | 64, 16, 512, 256, 256 bytes | Same | Fixed |

## Memestake (Base)

Source: `stocks/src/StocksPreset.sol` and `stocks/src/MemestockSplitterCore.sol`.

| Parameter | v1 (deployed) | v2 default | v2 bounds (min–max) |
| --- | --- | --- | --- |
| Total supply | 1,000,000,000 tokens, 18 decimals (`INITIAL_SUPPLY`) | 1,000,000,000 | Fixed |
| Auction share | 80% (`AUCTION_INVENTORY`, 4/5) | 80% | 50%–90% |
| LP reserve share | 20% (`MIGRATION_RESERVE`, 1/5) | 20% | What remains; auction + reserve = 100% |
| Start delay | 300 blocks, 10 minutes (`START_LEAD_BLOCKS`; founder decision 21 September: "The launcher does not choose it") | 300 blocks | Fixed |
| Auction length | 43,200 blocks, 24 hours (`AUCTION_DURATION_BLOCKS`) | 43,200 blocks | 21,600 blocks (12 hours) to 302,400 blocks (7 days) |
| Claim delay after the end | 64 blocks | 64 blocks | Fixed |
| Migration delay after the end | 128 blocks | 128 blocks | Fixed |
| Floor price | **Already chosen by the creator in v1**: at or above the auction contract's minimum, dividing exactly by 100 | No default | Same as v1 |
| Bid tick spacing | Floor ÷ 100 (`BID_TICK_DIVISOR`) | Floor ÷ 100 | Fixed rule |
| Release schedule | 13 steps: 12 windows from 5,445 blocks at 108 mps down to 3,022 blocks at 194 mps, each releasing about 5.8%, then one final block releasing the remaining 2,988,024 mps (`AUCTION_STEPS`) | Same shape | Fixed shape, recomputed from the chosen length (see decision 2) |
| Required raise | **Already chosen by the creator in v1**: above zero and within what the auction can reach | No default | Same as v1 |
| Pool fee | 0.30% (`POOL_FEE` 3000) | 0.30% | Fixed |
| Pool tick spacing | 60 | 60 | Fixed |
| Swap hook lanes | 1% REGENT lane and 1% staker lane (`REGENT_LANE_BPS`, `STAKER_LANE_BPS` 100 each; `LANE_DIVISOR` 100) | Same | Fixed (standing rule) |
| Splitter skim | 2% (`SKIM_BPS` 200) | 2% | Fixed (standing rule) |
| Unsold tokens when the raise fails | Retired (`RETIRE_FAILED_INVENTORY`) | Same | Fixed |
| Leftover stock from the pool position | Goes to the REGENT share (`LP_STOCK_DUST_TO_REGENT_BUCKET`) | Same | Fixed |
| Name, symbol, description, website, image limits | 64, 16, 512, 256, 256 bytes | Same | Fixed |

## Memestake (Robinhood Chain)

Source: `robinhood/src/RobinhoodPreset.sol`. Everything not listed matches Memestake on
Base: supply, shares, tick rule, pool fee, pool tick spacing, limits and skim. Robinhood
blocks come every 0.1 seconds, so each block count is twenty times the Base count.

| Parameter | v1 (deployed) | v2 default | v2 bounds (min–max) |
| --- | --- | --- | --- |
| Dollar token | USDG, 6 decimals (`USDG_DECIMALS`) | USDG | Fixed |
| Auction share | 80% | 80% | 50%–90%, same as Base |
| Start delay | 6,000 blocks, 10 minutes (`START_LEAD_BLOCKS`) | 6,000 blocks | Fixed |
| Auction length | 864,000 blocks, 24 hours (`AUCTION_DURATION_BLOCKS`) | 864,000 blocks | 432,000 blocks (12 hours) to 6,048,000 blocks (7 days) |
| Claim delay after the end | 1,280 blocks (`CLAIM_DELAY_BLOCKS`) | 1,280 blocks | Fixed |
| Migration delay after the end | 2,560 blocks (`MIGRATION_DELAY_BLOCKS`) | 2,560 blocks | Fixed |
| Release schedule | The Base schedule with each window 20× as long and each rate ÷ 20, rounded; final block releases 2,930,550 mps (`AUCTION_STEPS`; rounding accepted by the founder on 21 September) | Same shape | Fixed shape, recomputed from the chosen length |
| Swap hook lanes | 1% protocol lane and 1% staker lane (`PROTOCOL_LANE_BPS`, `STAKER_LANE_BPS` 100 each) | Same | Fixed (standing rule) |
| Revenue sent to Base | Chain 8453 (`BASE_CHAIN_ID`) | Same | Fixed |

## Who may change the bounds later

Each v2 factory is administered by the Safe that administers its v1 counterpart. On Base
that is the Governance and Regent Safe for both Revstake and Memestake. On Robinhood Chain
it is the admin Safe. No other address can change a bound. A launch keeps the parameters
it was created with, whatever happens to the bounds afterwards. The Safe changes a bound
with one transaction on the live factory, for launches created afterwards, and the change
is announced on chain (decision 1). It can never move a bound past the hard ceilings below.

## Hard ceilings

**Proposed, awaiting Sean's approval.** These limits are written into the v2 contracts
and no Safe transaction can pass them. Each one sits outside the approved range, so the
Safe has room to adjust without a new deployment. The fixed rows above are fixed in the
contracts and have no range to adjust.

| Adjustable row | Approved range | Hard ceiling (lowest–highest the Safe can ever set) |
| --- | --- | --- |
| Revstake auction share | 5%–50% | 1%–60% |
| Revstake LP reserve share | 5%–50% | 1%–60%; auction + reserve never above 100% |
| Revstake vesting share | What remains | What remains; never below 0% |
| Revstake vesting length | 90–730 days | 30–1,460 days (1 month to 4 years) |
| Revstake auction length (Base) | 21,601–302,401 blocks (12 hours to 7 days) | 10,801–604,801 blocks (6 hours to 14 days) |
| Memestake auction share (Base and Robinhood) | 50%–90% | 20%–95%; the LP reserve is what remains, so never below 5% |
| Memestake auction length (Base) | 21,600–302,400 blocks (12 hours to 7 days) | 10,800–604,800 blocks (6 hours to 14 days) |
| Memestake auction length (Robinhood) | 432,000–6,048,000 blocks (12 hours to 7 days) | 216,000–12,096,000 blocks (6 hours to 14 days) |
| Floor price rule (all three) | Creator chooses; at or above the auction contract's minimum; divides exactly by 100 | The Safe may raise the lowest allowed floor but never below the auction contract's minimum (2^32 + 1 in Q96). The bid tick stays floor ÷ 100 and the Safe cannot change it |

## Decisions

1. **How bounds change later.**
   - (a) The Safe changes a bound on the live factory with one transaction. The change
     applies only to launches created afterwards and is announced on chain.
   - (b) Bounds are fixed when a factory is deployed. Changing one means the Safe deploys a
     new factory, and the site moves to it.

   Recommendation: (a). A bound is only checked when a launch is created, so changing it
   cannot touch a running launch. Option (b) turns every adjustment into a new deployment
   ceremony and a site release. The HQL-H03 handoff describes the bounds as "immutable"
   in step 1 and as changeable by the admin Safe in step 0; this decision settles it.

   **Decided: (c), the Safe changes a bound on the live factory, and hard ceilings written
   into the contracts limit how far.** Sean, 27 September 2026, relayed by HQ: "all as
   recommended". The ceilings are in [Hard ceilings](#hard-ceilings).

2. **Release schedule.**
   - (a) Keep the v1 shape (twelve windows of about 5.8% each, then a final block) and
     compute it from whatever length the creator picks.
   - (b) Let the creator supply the whole schedule within limits.

   Recommendation: (a). The shape is founder-frozen economics today, and (b) makes every
   launch's release a separate thing to explain and check.

   **Decided: (a).** Sean, 27 September 2026, relayed by HQ: "1a 2 explain these differences 3a 4a 5a" (this decision is his "3a").

3. **The fixed rows.** The start delay, claim and migration delays, pool fee, tick
   spacing, supply, hook lanes, skim, referral cap and name limits.
   - (a) Keep them fixed.
   - (b) Open any of them to the creator.

   Recommendation: (a). The hook lanes and skim are fixed by standing rule. The start delay
   is a 21 September founder decision. The rest are safety margins or plumbing rather
   than launch choices.

   **Decided: (a).** Sean, 27 September 2026, relayed by HQ: "1a 2 explain these differences 3a 4a 5a" (this decision is his "4a").

4. **The defaults and ranges.** These are the shares, lengths, vesting and
   Revstake floor price in the tables.
   - (a) Approve them as written.
   - (b) Edit them in this file.
   - (c) Paste the 25 September study, and its splits become the defaults.

   Recommendation: (c) if the study is the intended plan, otherwise (a).

   **Decided: (a), approved as written.** Sean, 27 September 2026, relayed by HQ: "1a 2 explain these differences 3a 4a 5a" (this decision is his "5a"). The
   25 September study (50/50 and 15/15/70 splits) is not used.
