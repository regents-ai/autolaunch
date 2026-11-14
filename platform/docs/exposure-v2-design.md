# Isolated Exposure to After-hours Stocks, version 2: design note

**Status:** candidate only, 14 November 2026. Nothing deployed, broadcast or signed. Version 1
(`contracts/exposure`) and the site are unchanged.
**Decision it implements:** Sean, 14 November 2026. Version 2 runs itself: prices record themselves
from Chainlink when anyone trades or redeems, and each week's series opens with no Safe signature.
**Contracts:** [`contracts/exposure-v2`](../../contracts/exposure-v2/README.md) (branch
`al/exposure-v2-1114`).
**Version 1 design:** [exposure-design.md](exposure-design.md) and
[after-hours-exposure-spec.md](after-hours-exposure-spec.md).

## 1. What changes

For a holder, nothing about the product changes. One stock token still splits into an After-hours
leg (OVERNIGHT, close-to-open moves) and a Market-hours leg (SESSION, open-to-close moves). A pair
still mints from and redeems for exactly one stock token, and each leg redeems alone at the end of
its week.

What goes away is our weekly work:

- Nobody records prices. A series reads them from Chainlink's history when it needs them.
- Nobody creates series. Each week's series opens on its first deposit, and anyone may open it.

After the governance Safe deploys and configures the factory once, no wallet of ours has to sign
anything for the product to keep running.

## 2. Mechanism

### 2.1 A week

`ExposureFactoryV2` opens one `ExposureSeriesV2` per week `w` (Monday is day `7w − 3` counted from
1 January 1970). The series boundaries are:

1. the close of the last trading day before that Monday (normally Friday 16:00 New York);
2. then each trading day's 09:30 open and 16:00 close (13:00 on an early close).

A normal week has 11 boundaries; a holiday week has 9 or 7. One week's last boundary is the next
week's first, so consecutive series join with no gap and no overlap.

The factory works out the calendar on chain:

| | How | Exact or approximate |
| --- | --- | --- |
| Session times | 09:30 and 16:00 New York, 13:00 on listed early closes | Exact |
| Daylight saving time | From the federal rule: second Sunday of March to first Sunday of November. Trading never falls on the Sundays the clocks change, so the date decides the UTC offset. | Exact under current law; checked against Python's `America/New_York` for 26 Oct 2026 to 19 Mar 2027 and against the rule for every year to 2100 |
| Market holidays and early closes | A list the Safe keeps (`setDays`). The deploy script carries every NYSE closure and early close from 26 Nov 2026 through 2027. | Exact for listed days |
| Unlisted or unscheduled closure (a national day of mourning, a storm) | Treated as a trading day. Whatever the feed shows between 09:30 and 16:00 goes to SESSION; if the feed is frozen, nothing moves. | Approximate |
| Missing early-close entry | Moves between 13:00 and 16:00 go to SESSION instead of OVERNIGHT | Approximate |
| A change to daylight-saving law | Not handled; needs a new factory | Not covered |

The Safe can change days only in weeks after the current one, so a running series, and where the
next one starts, never change under holders. A whole closed week is skipped: the next series starts
from the last close before it.

### 2.2 Prices

The price for a boundary at time T is the Chainlink round of the series' pinned feed phase that was
in force at T: the highest-numbered round updated at or before T. This is version 1's rule.

- **No recorder.** Rounds stay readable on the proxy for ever (`getRoundData(phase << 64 | n)`), so
  the series looks the round up itself, whenever it needs it. Applying a boundary late gives the
  same price as applying it on time.
- **No hint.** The series searches. It starts from the round in force at the previous boundary,
  doubles its stride until it passes T, then halves back. The cost grows with the logarithm of the
  rounds between boundaries (90,000 to 112,000 gas a boundary on AMZN). The first boundary starts from
  round 1 (about 20 reads at AMZN's 832 rounds).
- **Equal times.** Rounds updated at exactly T count, and when several rounds share one update time
  the last of them is the price. Both are tested against a linear scan.
- **Due an hour after T.** The aggregator stamps a round with the block time of its transmission,
  so once a block is past T no round stamped at or before T can appear. The hour is margin on top,
  and the week turns over at the same moment.
- **Checks at each boundary.** Each of these ends the series at the ledgers it had (no price is
  applied):
  - no round in force at all;
  - the round in force is more than 84 hours old (version 1's limit; AMZN's longest normal gap is
    75.9 hours);
  - an answer of zero or less, or one too large to hold.
- **A feed that cannot be read.** Every read has a fixed gas budget of 50,000 behind a gas floor.
  That rules out three things:
  - a caller faking a failed read by sending too little gas;
  - an oversized reply ("return bomb");
  - a reply of the wrong size. The size is checked in its own statement because of Yul's
    right-to-left evaluation.

  A real read costs 16,730 gas cold. A failing read applies nothing. The first settle that sees one
  starts a clock, any good read stops it, and a settle that still sees failures 7 days after the
  first ends the series at the ledgers it had.

### 2.3 Settling

The ledger rule is version 1's:

- the first close sets OVERNIGHT to half the price;
- an open moves OVERNIGHT by the change since the close;
- a close moves SESSION by the change since the open;
- the ledgers always add up to the price;
- a price that takes either ledger to zero ends the series, and the other leg owns all the stock.

| Call | Applies due boundaries first? |
| --- | --- |
| `settle()` | It is the call; anyone, any time, no input |
| `mint` (directly or through `factory.deposit`) | Yes |
| `redeem` with unequal amounts | Yes, then pays at the final ledgers if the series has ended |
| `redeem` with equal amounts (whole pairs) | No. A pair is worth one stock token whatever the prices, so this exit never touches the feed |
| Leg transfers | No |
| `previewRedeem`, `previewState` | Simulates, writes nothing |

Each call does all the work that is due, and that work is bounded by the design rather than by a
step count:

- a series has at most 11 boundaries;
- each is found by a logarithmic search;
- a quiet month adds no work.

A call that finds the feed unreadable applies nothing and stays safe: a mint still mints pairs at
par, and a single-leg redemption reverts until the series ends. No holder's redemption needs anyone
else to act first. Pair redemptions need nobody. A single-leg redemption after the end settles in
the same call. If the feed is down, the holder's own second call a week later ends it.

### 2.4 Opening each week

- **`open(week)`.** Anyone can call it. It opens the series for the current week, which is the
  latest week whose first boundary is at least an hour old. Before that, and after the week turns
  over, it refuses.
- **Address.** The series is created with CREATE2 from the factory, salt zero and the week as its
  only constructor argument, so its address (`predictSeries(week)`) depends only on the factory and
  the week. The constructor reads its terms back from the factory once: the template plus that
  week's calendar. A series can be opened only once and only by the factory.
- **`deposit(week, assets)`.** This is the one call a holder makes. It opens the series if needed,
  pulls the stock, and mints both legs to the caller. It names the week the holder was shown, so a
  deposit that lands after the turnover fails instead of entering the next week.
- **Owner powers (the Safe):**
  - `setTemplate`: stock, Chainlink proxy and phase, deposit cap, terms hash, ticker. Applies to
    every series not yet opened.
  - `setDays`: closed days and early closes, for weeks after the current one only.
  - `setPaused`: stops new series opening; open series carry on.

  The owner has no call on a series and never holds stock between transactions.

## 3. Departures

### 3.1 From version 1

| Rule | Version 1 | Version 2 | Why |
| --- | --- | --- | --- |
| Prices | Anyone records a print by naming a round, within a window; a separate oracle keeps it | The series finds the round itself whenever a boundary is applied | Nothing to record, no window to miss, no keeper |
| A price never arrives | After the deadline anyone ends the series | No deadline. The 84-hour staleness limit, a bad answer, or a feed seen failing a week apart ends it | History never expires, so there is nothing to wait for |
| New series | The Safe calls `createSeries` each week | Opens on the first deposit, or anyone calls `open` | Founder decision |
| Calendar | The site works it out and the Safe signs it | On chain: daylight-saving rule plus the Safe's holiday list | No weekly signature |
| Leg names | Fixed per series | "AMZNc After-hours to 20 Nov 2026", "AMZNc-AH-1120" | Each week's legs are different tokens |

These stay as in version 1:

- the ledger rule and depletion ending;
- the pro-rata cut after an issuer seizure, with minting stopped while short;
- stock paid only to the redeeming account;
- the per-series deposit cap;
- raw B20 units as collateral;
- no owner power over funds;
- no upgrades.

### 3.2 From the paper

As in version 1: ledgers stop at zero instead of going negative, single legs redeem only at the end,
a seizure is shared, and stock goes only to the redeemer. Version 2 adds one thing: the term is
always one week, and positions do not carry from one week to the next. Holders redeem the finished
week and deposit into the next. A one-press roll is still not specified.

### 3.3 From the brief's suggested design

| Brief | Built | Why |
| --- | --- | --- |
| `settle(hints, maxSteps)` with round-id hints checked on chain | `settle()` with no input; the series searches | No input to validate, so there is no wrong-hint path. The result is a function of the feed's history alone, even for odd histories. Anyone can settle from a block explorer with no tooling. Measured cost is 90,000 to 112,000 gas a boundary on Base. "Wrong hints rejected" is replaced by "search equals a linear scan", fuzzed, including equal times and T equal to the update time. |
| `maxSteps` to bound a call | No step count | A weekly series has at most 11 boundaries, so the worst call is bounded: 590,000 gas for a deposit that applies 9. |
| Leg transfers might settle | They do not | A price read inside every pool swap would cost gas, and a failing feed would freeze the pools. Values are only realised by redemption, which settles. |
| An 84-hour-style staleness rule | Kept: a round more than 84 hours old ends the series | By construction a stale boundary means the round has not changed since the previous one. The rule still stops a series running for days on a feed that has moved to a new phase. |
| Unreadable feed | Ends only after reads are seen failing 7 days apart with no good read between | Counting the 7 days from the boundary, as first built, let one brief outage end a series nobody had settled for a week (found in the adversarial pass, section 8). |
| Deposits target "the current series" | `deposit(week, …)` names the week | A deposit sent just before the turnover fails rather than landing in a week the holder was not shown. |
| The owner changes the template for future series | For any series not yet opened, including the current week until its first deposit | Lets the Safe fix a phase or a cap before a week's first deposit. The other choice is open question C. |

## 4. Trust

| Who | Can | Cannot |
| --- | --- | --- |
| Anyone | Open the current week's series; settle any series; deposit; redeem their own legs | Choose a price, a round or a calendar; open a past or future week; open a week twice; take anyone's stock |
| The Safe (factory owner) | Change the template for series not yet opened; mark closed days and early closes for later weeks; pause new openings; transfer or renounce ownership | Touch an open series, its stock, its prices or its calendar; change the current week's days; upgrade anything |
| Chainlink | Publish the prices; move the proxy to a new phase; gate reads on the proxy | Change a round already published. Its history is fixed, so a series' prices are fixed once their hour has passed |
| The stock issuer | Blocklist accounts, pause transfers, take stock from any address, change the multiplier | Change the ledgers. A seizure is shared by every holder; a blocklisted holder waits; a split changes nothing the series owes |

A series has no owner, admin, upgrade, pause or fee. The factory is not upgradeable.

## 5. Failure modes

| Event | What happens | Effect on holders |
| --- | --- | --- |
| Nobody touches a series for weeks | The first touch applies every boundary at once, at the same prices (the fork test's 30-day silence) | None |
| Feed stops updating (deprecated phase, long closure) | Rounds older than 84 hours at a boundary end the series at the last ledgers | Single legs redeem at the last applied ledgers; pairs at par |
| Chainlink moves the proxy to a new phase mid-week | The open series stays on its pinned phase. If that phase goes silent, it ends at the staleness limit. The Safe points the next series at the new phase. | That week may end early at its last ledgers |
| Proxy reads fail (access control added, broken upgrade) | Nothing is applied; the first settle that sees it starts a 7-day clock; a settle still failing after that ends the series | Pairs redeem throughout; single legs wait up to 7 days after the first failure is seen |
| Zero or negative answer | The series ends at the last ledgers | As above |
| Price takes a ledger to zero | The series ends; the other leg owns all the stock | The knock-out disclosed in version 1 |
| Issuer pauses transfers | Deposits and redemptions revert; prices keep applying | Delayed, not lost |
| Issuer blocklists a holder | That holder cannot deposit or redeem; the holder can still sell their legs | That holder waits |
| Issuer blocklists the series | Every deposit and redemption reverts | Everyone waits until it is lifted |
| Issuer blocklists the factory | Deposits through the factory fail; `series.mint` directly still works | None |
| Issuer takes stock from the series | Every later redemption is cut by the same fraction; minting stops while short | Shared equally |
| Sequencer down across a boundary | No rounds are transmitted, so the round before the outage is in force, within the 84-hour limit | That boundary uses an older price |
| A closure the Safe did not list | Treated as a trading day (section 2.1) | Moves may land in the other leg |
| The Safe lists days wrongly | Fixed in any later week; the current week cannot be changed | That week's split may be off |
| The Safe closes a whole week | That week has no series; the next one starts from the last close before it | None |
| The Safe pauses | No new series opens; open ones carry on to maturity | No new weeks until unpaused |
| Someone opens the week just before the Safe's template change lands | The week opens on the old template, which the Safe approved | Open question C |
| Friday 16:00 to 17:00 New York | The finished week is past maturity and the next cannot open yet; no deposits that hour | Wait an hour |
| One holder fills the cap | Others cannot deposit that week; the holder can redeem at any time | As in version 1 |

## 6. Gas

Measured on a Base fork at block 57,228,000 with Foundry 1.8.6, the real AMZNc token and the real
AMZN feed, each call as its own transaction (`--isolate`). Figures are the gas the call used; a
transaction adds the base cost and calldata on top.

| Call | Gas |
| --- | --- |
| One cold round read through the proxy (the 50,000 budget) | 16,730 |
| First deposit of a week: opens the series and both legs, applies the first close from round 1 | 3,284,027 |
| Deposit with nothing to apply | 196,477 |
| Deposit after 1 unsettled day (2 boundaries) | 257,336 |
| Deposit after 5 unsettled days, Friday afternoon (9 boundaries, the worst deposit) | 589,810 |
| Single-leg redemption 30 days after the start, applying all 10 remaining boundaries | 512,417 |
| `settle()` for one boundary, each of indexes 3 to 10 | 90,455 / 100,157 / 112,137 / 111,998 / 102,296 / 111,992 / 112,137 / 102,147 |
| Pair redemption | 93,511 |
| Single-leg redemption with nothing to apply | 79,742 |

A deposit 30 days after the start is not possible, because the series matured after 7. The
single-leg redemption above is the 30-day case: the work stops growing after the week. Every round
read first needs 54,793 gas left, so a too-low gas estimate makes the call revert
(`OracleGasTooLow`) rather than count a failure. That means `eth_estimateGas` always finds a working
limit. Version 1's forge-estimate problem, where `settle` reverted with forge's own estimate, came
from forwarding gas to the recorder, and that does not exist here. Version 1's
`--gas-estimate-multiplier` advice still applies to any forge broadcast that moves B20 stock.

## 7. Tests and tools

All in `contracts/exposure-v2`, Foundry 1.8.6, 14 November 2026.

| Check | Command | Result |
| --- | --- | --- |
| Format | `forge fmt --check` | Clean |
| Build and lint | `forge build` | Clean: no compiler or lint warnings. Five lints are switched off with a reason each in `foundry.toml`. |
| Offline suites | `bin/gate.sh` (fmt, build, `forge test`) | 53 pass, 0 fail (52 tests plus one invariant campaign holding four invariants) |
| Base fork | `FOUNDRY_PROFILE=fork forge test --network base --fork-url https://mainnet.base.org --fork-block-number 57228000 --isolate -vv` | 8 pass, 0 fail |
| Slither 0.11.5 | `slither . --filter-paths "stocks-v2/lib\|test/\|script/" --exclude-dependencies` | 14 informational results, all intended (time comparisons, inline assembly, the `paid == 0` check, an ignored date part, long literals); no medium or high |
| Deploy script | `forge script script/DeployExposureV2.s.sol --sig "run(bytes32)" <hash> --network base --fork-url https://mainnet.base.org` | Simulates only: owner is the Safe, phase 2, cap 40 AMZNc, current week 2968, series address printed; no broadcast folder written |

The offline suites:

- **Series (31 tests):**
  - the worked example; ledgers against a reference model for any price path (fuzzed);
  - both depletions;
  - a round exactly at the boundary, and several in the same second;
  - a quiet feed within 84 hours; a stale feed; no round before the start; bad answers;
  - five broken feeds (revert, short reply, long reply, gas burn, return bomb);
  - the 7-day clock, a recovery, a brief outage after a month of silence, a good read resetting the
    clock;
  - low gas never faking a failure, with and without the clock running (fuzzed);
  - settle is idempotent; settle timing does not matter (eager against lazy, fuzzed); previews
    match;
  - pair redemptions with the feed down; single legs need the end;
  - the mint window; zero inputs; the cap; donations;
  - fee-taking, false-returning and unreadable-balance tokens;
  - seizure and total seizure; blocklist and pause;
  - reentrancy from a token hook into settle, redeem, mint and the factory.
- **Factory (17 tests):**
  - the calendar against New York for six weeks across both clock changes, Thanksgiving, Christmas
    and New Year;
  - consecutive weeks joining;
  - the daylight-saving rule to 2100 (fuzzed);
  - when the week turns over;
  - open rules and predicted address; any opener and any moment giving the same series; deposits
    joining;
  - a deposit for the wrong week;
  - owner-only calls; pause; the day lock; a closed week skipped; a three-week closure;
  - template only reaching unopened series; template checks;
  - a Chainlink phase migration;
  - a Thanksgiving week end to end.
- **Round search (4 tests):** the on-chain search against a linear scan over histories up to 300
  rounds with shared update times (fuzzed); boundaries exactly on an update time; histories up to
  2^64 rounds against a closed form; the end of the id space.
- **Invariants (4 invariants, 256 runs × 128 calls, 32,768 calls):** the handler deposits, redeems
  pairs and single legs, transfers legs, settles, publishes rounds (some broken), moves time, seizes
  and donates. A second series sees the same prices but settles only when asked. The invariants:
  - every raw unit accounted for;
  - pairs equal backing while live;
  - claims within backing after the end, with rounding dust bounded;
  - both series' state the same at all times, settle idempotent.

  Each run reached maturity, both depletions, a stale end, and single-leg redemptions with and
  without a seizure. These were checked with temporary probes, since removed.
- **Planted bugs:** six, one at a time, each caught. They were: a round exactly at the boundary
  excluded; no staleness limit; a depletion to exactly zero skipped; a good read not resetting the
  clock; no seizure cut; the week turning at the close instead of an hour later.

The fork suite builds the factory with the deploy script's own `build`, then:

- replays 26–30 October, 2–6 November (the clocks went back on 1 November) and 9–13 November 2026;
- checks the price and round at all 33 boundaries against an independent Python computation over
  the feed's rounds 400–832;
- splits and redeems the legs each week;
- leaves the October series untouched for 30 days;
- runs two factories settled at different times;
- applies the issuer's real blocklist, transfer pause and 2-for-1 multiplier;
- measures gas.

The first six October prices match version 1's fork test exactly. Version 1 showed $252.9275 for
Wednesday 28 October's close because its fork block (17:28 UTC) came before the last round of that
afternoon. Version 2 replays complete history and finds round 482, $254.30625.

## 8. Adversarial pass

This pass followed the solidity-auditor checklist (its attack vectors, adversarial reasoning and
false-positive rules), run by hand rather than by its helper agents.

**Found and fixed:**

1. **A brief outage could end a lazily settled series.**
   - *Before:* the 7-day unreadable grace counted from the boundary. If nobody settled for a week
     and the first settle met a momentary proxy failure, the series ended at stale ledgers. A lazy
     week could lose every move since its start.
   - *Now:* the clock starts at the first failure seen and any good read clears it.
   - *Tests:* `test_briefOutageCannotEndALazySeries`, `test_goodReadResetsTheClock`, and the low-gas
     fuzz with the clock running.
2. **The Safe could jam the calendar.**
   - *Before:* the series start looked back at most 14 days for a trading day. Closing two whole
     weeks made every week lookup revert. That included the Safe's own `setDays`, so the mistake
     could not be undone.
   - *Now:* the look-back has no limit. Each closed day it walks past costs one storage read.
   - *Test:* `test_longClosureKeepsTheCalendarWorking`.
3. **Event order.** The redemption event is now emitted before the stock leaves, so a token with
   hooks cannot reorder logs.

**Checked and holding:**

- **Conservation:** invariants plus the reference model.
- **Settlement griefing:** no input, gas floor, bounded work.
- **Stale ledgers:**
  - mint and single-leg redemption settle first;
  - pair redemption needs no ledger;
  - previews simulate.
- **Round choice:** the search equals a linear scan, including equal times and T equal to the
  update time.
- **Permissionless opening:**
  - the address depends on the factory and the week only, and nobody else can deploy there;
  - a second opening fails;
  - any opener gives the same series.
- **Reentrancy:**
  - every series entry point is locked;
  - the factory holds nothing between transactions;
  - hooks into settle, redeem, mint and deposit all fail.
- **Issuer actions:** pause, blocklist, seizure and split, on the real token.
- **Reply handling:** return bombs and wrong-size replies are rejected.
- **CREATE2 squatting:** not possible.
- **Downcasts:** each one is bounded.

**Known behaviour, left as is:**

- **A long outage is a timing choice.** Whether a long feed outage ends a series depends on someone
  settling during it (twice, a week apart). If nobody does and the feed recovers, the real prices
  apply.
- **Deposit hour.** No deposits are possible in the hour after Friday's close.
- **Template race.** An opener can front-run the Safe's template change for the current week
  (question C).
- **Previews mid-redemption.** A third-party contract that reads `previewRedeem` from inside a stock
  transfer hook during a redemption can see a slightly favourable figure. B20 tokens have no hooks.
- **Look-alike series.** Anyone can deploy a contract that looks like a series from a factory of
  their own. The site and agents must trust only `factory.seriesOf(week)` or `isSeries`.
- **Rounding dust.** Donations, rounding dust and stock sent to the factory by mistake stay where
  they land.

## 9. Not proven

- **The paper's leverage claims** are not re-derived for weekly terms. Version 1's economics review
  is relied on.
- **Daylight saving** after a change in US law (a new factory would be needed) and NYSE's 2027 list.
  The script leaves 2 July 2027 and 23 December 2027 as regular days; check them against NYSE's
  published calendar before deploying.
- **A real split.** That AMZN's Chainlink value stays per raw token across one is taken from version
  1's measurement. The fork test shows the raw backing unchanged under a multiplier change, not the
  feed's behaviour through a real split.
- **Gas.** The 50,000 read budget is about three times today's cost. A future Chainlink proxy or
  aggregator more expensive than that would read as unreadable, and series would end a week after
  that is first seen.
- **Wallet estimates.** The gas figures are forge's, taken with each call isolated. Wallet
  estimates were not measured.
- **The site and agent surfaces** for version 2 (deposit by week, no Record price button, leg names
  by week) are not built. Version 1's site is unchanged.
- **No outside review.** The adversarial pass is the author's own.

## 10. Open questions

A. **Market holidays.**
   - (a) The Safe keeps a list. The deploy script carries late 2026 and 2027; the Safe adds each
     later year in one call.
   - (b) No list: holidays count as trading days and their moves fall into whichever leg the clock
     says.

   Recommendation: (a). Only one Safe call a year, and holidays are then exact.

B. **A feed that cannot be read.**
   - (a) End the series after failures are seen 7 days apart with no good read between.
   - (b) Never end. Pairs still redeem, but single legs wait for the feed for as long as it takes.

   Recommendation: (a). Single legs always reach an end.

C. **When a template change takes effect.**
   - (a) For every series not yet opened, including the current week until its first deposit.
   - (b) From next week only. No opener can race the Safe, but a bad phase stays for a week.

   Recommendation: (a). It lets the Safe repair a Chainlink migration before a week's first deposit,
   and the race can only pick a template the Safe had already approved.

D. **Chainlink phase.**
   - (a) Pinned in the template; the Safe switches it after a migration.
   - (b) Each new series follows the proxy's current phase automatically. No Safe step, but during
     Chainlink's overlap the moment of opening would choose the phase.

   Recommendation: (a).

E. **Settling on leg transfers.**
   - (a) No.
   - (b) Yes. Every pool trade would read the feed and could freeze if the feed failed.

   Recommendation: (a).

F. **Deposit cap.**
   - (a) 40 AMZNc per week, as the deploy script has it.
   - (b) Another figure.

   Recommendation: (a) for the first weeks.

G. **Terms for version 2.**
   - (a) The agent drafts version 2 terms from the approved version 1 terms with these changes, for
     Sean's approval. Their keccak256 becomes the template's terms hash.
   - (b) Sean writes them.

   Recommendation: (a).

H. **Deploy (protected: needs Sean's go).**
   - (a) Deploy the factory with the Safe as owner once G is approved and the site work exists.
   - (b) Hold.

   Recommendation: (b) until G and the site are ready.
