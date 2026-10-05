# Creator fees: evidence for decisions 80 and 82 (5 Oct 2026)

Supports [creator-fee-proposal-2026-10-05.md](creator-fee-proposal-2026-10-05.md). Docs only. Nothing
is deployed: the deployer is still at nonce 28. Every figure below is from the source on
feat/contracts-v2 at 93b5d9c, the 1 Oct founder terms in `docs/launch-profiles.md`, and the
4 Oct Base rehearsal.

## What "sells out" means here

Both products use the lowest floor the auction allows, and the minimum raise is the whole sale at
that floor. That is about 0.000000001 of the payment token (`REQUIRED_REGENT_RAISED`,
`REQUIRED_STOCK_RAISED`). So an auction that graduates sells its entire allocation, apart from
rounding. An auction that does not sell out does not graduate: bidders are refunded, the whole
supply goes to the dead address, and the creator gets nothing, with or without these changes.
The useful contrast is therefore a strong auction against a thin one that still graduates.

---

## 80 a: Revstake creator trading lane, 0.3% on top, paid to the treasury

**Question.** Should every Revstake trade pay 0.3% to the launch's treasury, on top of today's 3%?

**Existing founder decision.** 1 Oct: "1% to Regent and 2% to the launch's splitter, plus the 0.3%
Uniswap LP fee" (`docs/launch-profiles.md`). There is no creator lane.

**Code today.** `RegentFeeHook` has two lanes (`REGENT_LANE_BPS = 100`, `STAKER_LANE_BPS = 200`).
The hook is created by `RegentsAutolaunchFactoryV2`, which is send 5 of 5 (nonce 32).
**Deployed state:** nothing.

**Alternatives.** a) 0.3% on top (3.3%). b) 0.3% taken from the stakers' 2% (3% total). c) None.

### Auction and pool at graduation: unchanged by 80

The creator lane is charged on trades only. The raise split and pool depth are identical before
and after.

| Auction | Raise | Average price | To the pool | To the treasury |
| --- | --- | --- | --- | --- |
| Strong | 50,000 REGENT for 20B tokens | 0.0000025 REGENT | 25,000 REGENT + matching tokens (up to the 10B reserve) | 25,000 REGENT + 70% of supply vesting over 365 days |
| Thin | 1,000 REGENT | 0.00000005 REGENT | 500 REGENT + matching tokens | 500 REGENT + 70% vesting |
| No bids | none | none | none | none; the supply goes to the dead address |

### Worked example: trading

A buyer spends the equivalent of $1,000 on a Revstake token.

| | Today | 80 a | 80 b |
| --- | --- | --- | --- |
| Pool fee | $3.00 | $3.00 | $3.00 |
| Regent | $10.00 | $10.00 | $10.00 |
| Stakers' lane (the splitter) | $20.00 | $20.00 | $17.00 |
| Creator lane (the treasury) | none | $3.00 | $3.00 |
| **Buyer pays in fees** | **$33.00** | **$36.00** | **$33.00** |

The treasury already gets the unstaked share of the stakers' lane, after Regent's 2% skim. The new
lane matters most when most of the supply is staked:

| Share of supply staked | Treasury income today (share of volume) | With 80 a |
| --- | --- | --- |
| 30% | 1.372% (2% × 98% × 70%) | 1.672% |
| 90% | 0.196% (2% × 98% × 10%) | 0.496% |

These figures leave out the treasury's share of the 0.3% pool fee, which follows the same split.
At $100,000 of daily volume, 80 a pays the treasury $300 a day, whatever share is staked.

### Bounded cost

- **Buyers and sellers:** exactly 0.3 points more per trade ($3 per $1,000). It is fixed in code and
  can never rise.
- **Stakers:** nothing under 80 a. Under 80 b their lane shrinks by 15% (from 2% to 1.7%).
- **Regent:** nothing.
- **Gas:** one more token transfer per swap, about 30,000 gas. That is about 0.0000002 ETH at the
  4 Oct gas price of 0.006 gwei.
- The lane pays in whichever token the swap leaves unspecified, so the treasury will receive some
  of the launch's own token as well as REGENT. The Regent lane works the same way today.

### Reversibility

- **Before deployment:** free. Only send 5 changes, but the packet is rehearsed again and a new
  hook address is mined. That replaces digest
  0xea59e17dfba46987fd75b3d9f8d937783a4324234e03bbbabf01bc47d124cfba.
- **After deployment:** the contracts cannot be changed. A later change means a new hook and
  factory, a new rehearsal, Sean's signed go and a new send. That costs about 0.00005 ETH in gas
  (the factory used 7,824,234 gas in rehearsal). Every launch made on the first factory keeps its
  terms for good.

### Smallest remaining choice

On top (3.3%) or taken from the stakers (3%). The payee (treasury, 81) and the size (0.3%, matching
Memestake) follow the existing pattern.

---

## 82 a: Memestake creator share of the raise, 5% at graduation

**Question.** When a Memestake auction graduates, should 5% of the raise go to the launcher in the
stock token, and the rest into the pool?

**Existing founder decision.** 1 Oct: "Memestake puts the whole raise in a full-range position and
the rest of the reserve in a second, NEW-only position above the opening price, both locked forever"
(`docs/launch-profiles.md`).

**Code today.** `StocksLaunchpadV2` pairs the whole raise (`_mintLockedPositions`). The launcher is
already recorded and already paid the 0.3% trading lane. Robinhood does the same in
`RobinhoodStocksLaunchpadV2`.
**Deployed state:** nothing; both packets are trials.

**Alternatives.** a) 5%. b) 10%. c) None.

### How the pool is built

The pool opens at the final clearing price P. The full-range position pairs the stock with
(stock ÷ P) NEW. The rest of the 495M NEW reserve becomes the NEW-only position above the opening
price, where it is sold to buyers. The price can only rise during the auction, so the raise is at
most P × 495M.

### Worked example: strong auction

Raise $100,000 of stock; final price $0.00022 per NEW (P × 495M = $108,900).

| | Today | 82 a (5%) |
| --- | --- | --- |
| Creator receives | none | $5,000 of stock |
| Full-range position | $100,000 stock + 454,545,455 NEW | $95,000 stock + 431,818,182 NEW |
| NEW-only position above the price | 40,454,545 NEW | 63,181,818 NEW |
| Someone sells $10,000 of NEW at the opening price, before fees | gets $9,091 | gets $9,048 (−$43, 0.47%) |

### Worked example: thin auction that still graduates

Raise $2,000; final price $0.0000045 per NEW (P × 495M = $2,227.50).

| | Today | 82 a (5%) |
| --- | --- | --- |
| Creator receives | none | $100 of stock |
| Full-range position | $2,000 stock + 444,444,444 NEW | $1,900 stock + 422,222,222 NEW |
| NEW-only position | 50,555,556 NEW | 72,777,778 NEW |
| Someone sells $200 of NEW, before fees | gets $181.82 | gets $180.95 (−$0.87) |

### Auction that does not graduate

No raise: bidders are refunded and the creator gets nothing. 82 a changes nothing.

### Bounded cost

- **Auction bidders:** nothing. They pay the same clearing price for the same tokens.
- **Holders who sell after graduation:** the stock side of the pool is exactly 5% smaller. A sale
  of 10% of the pool's depth receives about 0.47% less; smaller sales lose proportionally less.
- **Buyers after graduation:** no worse. More NEW sits in the position just above the opening price.
- **Regent and stakers:** their lanes are unchanged. Pool-fee income per trade is unchanged; only
  the depth behind it is 5% smaller.
- **No pressure on the token's price:** the creator is paid in the stock, not NEW, so nothing new
  is sold into the pool.

### Reversibility

- **Before deployment:** free. The launchpad and shared settings change, which changes the
  nonce-33 Memestake transaction and the Robinhood packet. Both are still trials.
- **After deployment:** the contracts cannot be changed. A later change means a new launchpad on
  each chain, rehearsed and sent again with Sean's signed go. Existing launches keep their terms.

### Smallest remaining choice

The percentage: 5% or 10%. A sub-question is whether the share is paid at once or vests with the
creator's 1% over 30 days. We suggest paying at once: it is paid in the stock, not the launch's own
token, so it cannot be sold into the pool.

---

## AL-02: where a trade's fees end up (today's code)

A buyer spends the equivalent of $1,000. The hook takes its lanes; the pool takes its 0.3% LP fee,
which the locker collects for the launch's splitter. The table assumes the locked launch position
is the pool's only liquidity; anyone else who adds liquidity earns their share of the 0.3% instead.

### Revstake

| Step | 30% of supply staked | 90% staked |
| --- | --- | --- |
| Hook, Regent lane (1%) | $10.00 to Regent | $10.00 to Regent |
| Hook, stakers' lane (2%) | $20.00 to the splitter | $20.00 to the splitter |
| LP fee (0.3%), collected by the locker | $3.00 to the splitter | $3.00 to the splitter |
| Splitter skim (2% of $23) | $0.46 to Regent | $0.46 to Regent |
| Stakers (net × staked ÷ 100B supply) | $6.76 | $20.29 |
| Treasury (the unstaked rest) | $15.78 | $2.25 |
| **Total paid by the buyer** | **$33.00** | **$33.00** |

With 80 a, the treasury gets $3.00 more in both columns and the buyer pays $36.00.

### Memestake

| Step | Something staked | Nothing staked |
| --- | --- | --- |
| Hook, creator lane (0.3%) | $3.00 to the launcher | $3.00 to the launcher |
| Hook, Regent lane (1%) | $10.00 to Regent | $10.00 to Regent |
| Hook, stakers' lane (3%) | $30.00 to the splitter | $30.00 to the splitter |
| LP fee (0.3%), collected by the locker | $3.00 to the splitter | $3.00 to the splitter |
| Splitter: Regent's share | $0.66 (2% of $33) | $33.00 (all of it) |
| Splitter: stakers | $32.34, by stake | none |
| **Total paid by the buyer** | **$46.00** | **$46.00** |

So 4.3% is the hook fee alone; with the LP fee a buyer pays 4.6%. There is no treasury in
Memestake. The referral cut of 0–2.5% applies only to payments into a Revstake payment receiver,
not to trades.

### Executable examples (all run and succeeded on 5 Oct)

- Revstake hook lanes: `test_HOK_002_FA07_I2_BothAssetsRouteInKindWithExactCleanLanes`
  (`revstake-v2/test/hook/RegentFeeHook.t.sol`).
- Revstake splitter: `test_SPL_002_EveryRecognizedInflowIsSkimmedExactlyOnce`,
  `test_SPL_005_NetSplitsByFixedSupplyCoverage` and
  `test_SPL_006_UncoveredNetGoesImmediatelyToTheImmutableTreasury`
  (`revstake-v2/test/revenue/SubjectSplitterV1.t.sol`).
- Revstake referral: `test_RCV_014_ReferralPaymentIsExactlyFlooredToTheImmutableBeneficiary`
  (`revstake-v2/test/revenue/PaymentReceiverV1.t.sol`).
- Memestake hook lanes: `test_fee_matrix_charges_stock_on_every_swap_form_with_conservation`,
  `test_the_hooks_stock_balance_is_exactly_the_sum_of_the_three_lanes` and
  `test_settle_creator_lane_is_permissionless_and_pays_the_creator_in_stock`
  (`stocks-v2/test/StocksFeeHook.t.sol`).
- Memestake splitter: `test_revenue_is_divided_pro_rata_with_nothing_held_back` and
  `test_with_nothing_staked_the_whole_inflow_is_the_protocols`
  (`stocks-v2/test/MemestockSplitter.t.sol`).

### Mismatches found

- The code, `docs/launch-profiles.md` and both package READMEs agree on every fee and split.
- Comments only: `revstake-v2/src/hook/RegentFeeHook.sol` lines 20–22 and 189 still describe a 2%
  fee with two 1% lanes. The constants charge 3%. The fix goes with the 80 change.
- Site copy: `llms.md` line 91 on the v2 site says the Revstake hook sends 2% to the creator's
  staking contract. It goes to the launch's splitter, which pays stakers and the treasury. This
  belongs to the pages cutover held under 57 b.

## AL-03: does a graduated sale always sell out?

A new fuzz sweep in each package checks every outcome against three rules: a launch graduates
exactly when the auction's counted raise reaches the minimum; a graduated launch opens its pool and
its bidders receive the whole sale allocation, short only by rounding crumbs; a failed launch opens
no pool and refunds every bid in full.

| Package | Bidders | Amounts | Blocks | Runs |
| --- | --- | --- | --- | --- |
| Revstake (Base) | 2–6 | 1 base unit up to 1,000,000 REGENT | gaps up to 20,000 | 20,001 × 2 tests |
| Memestake (Base) | 2–6 | 1 base unit up to 1,000,000 of the stock | gaps up to 10,000 | 20,001 × 2 tests |
| Memestake (Robinhood) | 2–6 | 1 base unit up to 1,000,000 of the stock | gaps up to 200,000 | 20,001 × 2 tests |

- **No counterexample** in 120,006 runs.
- Each package reached all three branches: graduated with three or more bids, failed with two or
  more bids, and bids adding up to the minimum without graduating. The last happens because the
  auction can count a bid placed after its first block one base unit short. Such a launch fails
  and refunds in full, as it should. Graduation and pool availability follow the counted raise,
  never the sum of bids.
- The sweep files are not committed: `revstake-v2/test/integration/AutolaunchSelloutSweep.t.sol`,
  `stocks-v2/test/StocksSelloutSweep.t.sol` and `robinhood-v2/test/RobinhoodSelloutSweep.t.sol`.
  Whether they stay in the suite is Sean's call.
