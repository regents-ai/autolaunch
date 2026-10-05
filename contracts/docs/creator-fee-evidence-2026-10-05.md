# Creator fees: evidence for decisions 80 and 82 (5 Oct 2026)

**Decided 5 Oct:** 80 a (Revstake 0.3% creator lane on top, 3.3% in all, paid to the treasury) and
82 (Memestake 49.75% auction, 49.75% pool, 0.5% to the launcher over 30 days; no share of the raise).

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

## 82: Memestake creator share (decided 5 Oct)

Sean's answer: "I said they get 0.5% vested over 30 days, where did 5% and 10% come from? no it is
only 0.5%, and 49.75% is for auction, and 49.75% for liquidity." The raise-share options (5%, 10%)
are withdrawn: the whole raise still goes to the pool.

**Change.** `StocksPreset` (shared by Base and Robinhood) now holds 497,500,000 NEW for the auction,
497,500,000 NEW for the pool and 5,000,000 NEW for the launcher. The vesting itself was already what
Sean asked for: linear per block from graduation over 30 days (1,296,000 Base blocks; 25,920,000
Robinhood blocks). Only the amount changed, from 1% to 0.5%.

**Derived change.** The minimum raise is the whole sale at the floor, so it moves from 26,834,004 to
26,969,530 STOCK base units (about 0.27 of a share at 8 decimals; 0.00000000002696953 of an
18-decimal Robinhood stock). Nothing else in the 1 Oct profile moves.

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
- The sweep files stay in the suite (Sean, 5 Oct, AL-03 a):
  `revstake-v2/test/integration/AutolaunchSelloutSweep.t.sol`,
  `stocks-v2/test/StocksSelloutSweep.t.sol` and `robinhood-v2/test/RobinhoodSelloutSweep.t.sol`.
