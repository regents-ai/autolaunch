# After-hours Exposure — technical specification

**Status (29 Oct 2026):** series factory deployed on Base; the pinned-phase price oracle (V2) is ready
to deploy; the first series (a capped ~$100 live demonstration on AMZNc) is prepared for the Governance
and Regent Safe to create once the oracle is deployed and the revised terms are approved; website and
CLI not built.
**Code:** `contracts/exposure/` in `regents-ai/autolaunch`, branch `claude/project-thread-0cczxg`.
**Source idea:** "Isolated Exposure Tokens", The Standard Reserve, October 2026.

This document is written for an independent reviewer. Section 9 lists the questions we most want a
second opinion on. The complete Solidity source (contracts, deploy scripts, tests and test doubles)
is reproduced in the appendix exactly as it is in the repository.

---

## 1. Product

A Base stock token (a Coinbase "B20" tokenized stock such as AMZNc) earns its return in two windows:
from one close to the next open (nights and weekends), and from the open to the close (the trading
day). After-hours Exposure splits one stock token, for a fixed term, into two ordinary ERC-20 tokens:

| Customer name | Contract name | Earns one share's dollar move over |
| --- | --- | --- |
| After-hours | OVERNIGHT | each close → next open |
| Market-hours | SESSION | each open → same day's close |

- Depositing `q` raw stock units mints `q` of each leg. One of each always redeems for exactly one raw
  stock unit, so the pair *is* the stock.
- Each leg alone is a leveraged position on one window (≈2× at the start), with no lender, margin call
  or liquidation.
- At the end of the term, each leg redeems on its own for its ledger's fraction of the stock.

The paper's worked example runs unchanged in the contract (`test_WorkedExample`):

| Print | Price P | OVERNIGHT N | SESSION S |
| --- | --- | --- | --- |
| Start (close) | 160 | 80 | 80 |
| Open | 172 | 92 | 80 |
| Close | 166 | 92 | 74 |
| Open | 178 | 104 | 74 |
| Close | 170 | 104 | 66 |

At maturity one OVERNIGHT redeems for 104/170 of a stock token and one SESSION for 66/170.

## 2. Mechanism and arithmetic

### 2.1 State

Per series, on chain:

- `lastPriceWad` P (uint128): last applied print, USD per whole raw token, 18 decimals.
- `overnightLedgerWad` N (uint128): OVERNIGHT's ledger. SESSION's ledger is derived: `S = P − N`.
- `status` ∈ {Pending, Active, Ended}, `endReason`, `settled` (number of prints applied).
- `accountedAssets` A: raw stock owed to outstanding legs.
- Immutable: asset, legs, oracle, feedId, termsHash, maxReportDelay, depositCap, and the schedule
  `boundaries[]` (initial close, then open/close pairs, ending on a close; strictly increasing; odd
  length 3…505).

Storing only P and N makes `N + S = P` true by construction; `0 ≤ N ≤ P` is maintained by every
transition (2.2).

### 2.2 Transitions (`settle`)

Prints are applied strictly in schedule order, one per call, by anyone. With new price p:

- **Initial close** (index 0): `N = ⌊p/2⌋`, `S = p − N`; status → Active (minting opens).
- **Open** (odd index): SESSION is fixed. `day = P − N`. If `p ≤ day`: N = 0, end (OvernightDepleted).
  Else `N = p − day`. (Equivalently N += p − P.)
- **Close** (even index > 0): OVERNIGHT is fixed. If `p ≤ N`: N = p (S = 0), end (SessionDepleted).
  Else N unchanged (S = p − N, equivalently S += p − P).
- After the last boundary: end (Maturity).

No signed arithmetic is needed: depletion is detected before any subtraction could go negative.

**Departure from the paper (depletion).** The paper's ledgers can go negative. Example: P=100 (50/50),
next open p=40 → paper gives N=−10, S=50, i.e. SESSION would claim 50/40 = 1.25 tokens per pair while
only 1 backs it. The contract instead ends the series at that print with N=0 and S=p: the surviving
leg receives all the stock. A zero ledger never revives. Near zero a leg is therefore a knock-out:
the other window's move can cost it (from 104/66 at 170, a session fall to 100 ends with N=100, so
OVERNIGHT loses 4 to a session move).

### 2.3 Minting and redemption

- `mint(assets)`: only while Active, `assets > 0`, within `depositCap − A`, and only if the vault is
  not short (`balance ≥ A`). Pulls `assets` raw stock from the caller, requires the vault's balance
  rose by exactly `assets`, then mints `assets` of each leg to the caller. A pair is always worth
  exactly its stock, so minting at any point is value-neutral to existing holders.
- `redeem(o, s)`: burns the caller's legs and sends the caller the stock owed.
  - Before the end: `o == s` required (pairs only); owed = `o`.
  - After the end: matched amounts redeem exactly, only the unmatched remainder rounds down:
    `owed = min(o,s) + ⌊(o−min)·N/P⌋` if `o > s`, else `min(o,s) + ⌊(s−min)·S/P⌋` (full-precision
    `mulDiv`).
  - Shortfall: if the issuer has taken stock from the vault (`balance < A`), `paid = ⌊owed·balance/A⌋`,
    otherwise `paid = owed`. `A −= owed` either way. A redemption whose `owed > 0` but `paid == 0`
    reverts, so legs with value are never burned for nothing.
  - Stock is only ever sent to `msg.sender` (no receiver parameter), so the issuer's blocklist and
    pause apply to every payout.
- `previewRedeem(o, s)` returns exactly what `redeem` would pay now.

### 2.4 Missing prints (`endOnMissingPrint`)

A print counts only if the oracle recorded it no earlier than its scheduled time and no later than
`scheduledAt + maxReportDelay` (and not in the future, and labelled for exactly that time). Once that
deadline has passed with no such print, anyone may end the series at the last applied ledgers. A
print recorded in time blocks this forever, however late `settle` is called, so a slow keeper cannot
choose an older allocation.

### 2.5 Reading the oracle

`_eligiblePrice` calls `getPrint(feedId, scheduledAt, isOpen)` with `staticcall`, a fixed
100,000-gas budget and a fixed 96-byte output buffer, and accepts the reply only if the call
succeeded and returned exactly 96 bytes. A reverting, short, long, gas-burning or oversized
("return bomb") oracle therefore counts as "no print". Before the call the caller must leave at least
105,000 gas (`OracleGasTooLow` otherwise), so that under the 63/64 rule the oracle always receives its
full 100,000: a caller cannot starve the read to fake an outage. Dirty high bits in any word fail the
range/equality checks.

### 2.6 Raw units, splits and dividends

The vault only ever counts raw B20 units: one raw token backs one OVERNIGHT plus one SESSION, for the
whole term. A split or dividend changes the multiplier (shares per raw token), not raw balances. The
oracle price is the USD value of one raw token (equity price × multiplier), which Coinbase's Chainlink
feeds already publish as a total-return value, so corporate actions need no handling in the vault.

## 3. Contracts

All Solidity 0.8.26, Cancun, via-IR, optimizer 200, metadata hash off — the same build identity as the
other Autolaunch packages. Dependencies: Solady (ERC20, SafeTransferLib, FixedPointMathLib,
ReentrancyGuard, Ownable) and forge-std, from the pinned `contracts/stocks-v2/lib` snapshot.

| Contract | Role | Owner/admin |
| --- | --- | --- |
| `ExposureSeriesV1` | One stock, one term: holds the stock, mints/burns legs, applies prints, pays redemptions. ~5.1 KB runtime. | None. No pause, upgrade, fee, sweep. |
| `ExposureLegV1` | OVERNIGHT or SESSION: plain transferable ERC-20; only its series can mint/burn, and it burns only from the series' caller (holders never approve the series). Permit2 standing allowance disabled. | None (series is immutable). |
| `ExposureFactoryV1` | Creates and lists series (`isSeries`), emits `SeriesCreated`. | Governance and Regent Safe; it has no power over a series after creation. |
| `ChainlinkPrintOracleV2` | Turns one fixed phase of one Chainlink feed into append-only open/close prints, with each print's source round. | None. |
| `IFinalizedPrintOracle` | The narrow interface the series reads: `getPrint(feedId, scheduledAt, isOpen) → (priceWad, observedAt, finalizedAt)`. | — |

Gas (mock suite, indicative): `settle` ≈ 50k, `redeem` ≈ 59k, first `mint` for a new holder ≈ 203k,
`createSeries` ≈ 2.4M (simulated on Base for the 11-print series).

## 4. Prices: `ChainlinkPrintOracleV2`

**Rule.** The oracle is pinned to the feed phase (the underlying Chainlink aggregator) the proxy pointed
at when it was deployed. The print for moment T is that phase's value in force at T: its last round
with `updatedAt ≤ T`, provided `T − updatedAt ≤ 84 hours`.

**Recording.** Anyone calls `record(T, isOpen, n)` at least one hour after T, naming round `n` of the
pinned phase. Rounds are read through the proxy as `getRoundData(phase << 64 | n)` (the aggregators
themselves only answer the proxy: a direct read from a contract reverts "No access"). The oracle checks:

1. round `n` exists and `updatedAt ≤ T`;
2. round `n + 1` does not exist yet or was updated after T (rounds within a phase are numbered in time
   order, and a round created later than T + 1 hour cannot carry an earlier `updatedAt`, which is its
   publication block time);
3. `T − updatedAt ≤ 84 hours`;
4. the answer is positive and fits uint128 once scaled from 8 to 18 decimals.

It stores `{price, observedAt = T, finalizedAt = block.timestamp}` once, forever, and the source
`{roundId, updatedAt}` (`sourceOf`). `getPrint` answers only for its own
`feedId = keccak256(abi.encode(chainid, proxy, phase))`.

**Why the phase is pinned** (found by the second review). Chainlink migrates a feed by running a new
aggregator beside the old one and later pointing the proxy at it; the switch time is not recorded on
chain, and the new aggregator can already hold rounds from before the switch. If the oracle followed
the proxy, the print for a 09:30 open could be the old aggregator's value when recorded at 10:31 and
the new one's when recorded after an 11:00 switch, whichever came first. With the phase pinned, a
print is a pure function of one aggregator's history (`test_ProxySwitchDoesNotChangeAPrint`). On the
real feed, phase 1 and phase 2 both published for nine days in August 2026; the fork suite records a
moment in that overlap from phase 2 only (`test_fork_overlapGivesOnePrintOnThePinnedPhase`).

**Retirement and staleness.** When Chainlink retires the pinned aggregator it stops updating but
stays readable. For up to 84 hours its frozen last value is still used, so moves in that time are not
counted (found in review on the feed's own history: phase 1 stopped on Friday 14 August at 264.4296,
and an oracle pinned to it would have priced the next Monday's open and close at that value).
After 84 hours prints are refused and the series ends at its last applied values through its own
missing-print rule (`maxReportDelay` after the refused print); the keeper script makes that call
itself once the deadline passes. 84 hours clears the longest normal gap in all 492 rounds of the
current phase, 75.9 hours (Friday evening to Tuesday after Labor Day); over 30 Sep–28 Oct the oldest
in-force value at any 09:30 or 16:00 was 17.6 hours. A corporate-action freeze longer than 84 hours
also ends the series. Fully closing the frozen window would need a staleness rule that knows the
market calendar; for a one-week series we accept it. Later series use a new oracle on the
then-current phase; the deploy script refuses to prepare a series on an oracle whose phase is no
longer the proxy's. The website shows each print's source round and its age.

**What a print means.** A print is the feed's latest value at 09:30 or 16:00, not the exchange's
official auction price. The feed (8 decimals, total-return: equity price × token multiplier) updates
when its own price moves by 0.5% or more, or at least every 24 hours while the market trades, and
holds over weekends, holidays and corporate-action pauses; it can also lag. So a print can differ
from the official open or close by more than 0.5%, and any move the feed has not yet shown is counted
in whichever window it appears. Total backing is unaffected, but returns can move between the two
legs, and the error can accumulate for one leg over a term. The product is therefore described as
exposure to scheduled Chainlink values. During the demo week we record, for every print, the official
open or close next to the feed value and report the per-leg divergence.

## 5. Security argument

### 5.1 Invariants and why they hold

| # | Invariant | Why it holds | Evidence |
| --- | --- | --- | --- |
| I1 | `N + S = P` and `0 ≤ N ≤ P` | S is derived; every transition sets N ∈ [0, p] (2.2). | `testFuzz_LedgersAlwaysSumToPrice`, `invariant_LedgersStayWithinPrice` |
| I2 | While not ended: `supply(OVERNIGHT) = supply(SESSION) = A` | Mint adds `assets` to all three; pre-end redemption is pairs only and subtracts `o` from all three. | `invariant_PairsMatchBackingWhileLive` |
| I3 | After the end: `supplyN·N + supplyS·S ≤ A·P` | At the end both supplies equal A and `N+S=P`, so equality; each redemption reduces A by its exact-or-rounded-down claim, so the inequality is preserved. | `invariant_ClaimsNeverExceedAccounted`, `testFuzz_ClaimsNeverExceedBacking` |
| I4 | Without issuer seizure: `balance ≥ A` | Deposits must arrive exactly; payouts never exceed owed; donations only add. | `invariant_FullyBackedUnlessSeized`, `invariant_StockConserved` |
| I5 | Splitting a redemption never pays more | Floor on each piece; pairs exact. | `testFuzz_SplittingNeverPaysMore` |
| I6 | A print cannot be skipped, replayed, reordered or chosen | `settle` takes no input; index is `settled`; oracle keyed by exact (T, isOpen); oracle records once. | `test_PrintsApplyOnlyInOrder`, oracle `test_TooEarlyAndOnlyOnce` |
| I7 | An available timely print can never be overridden by the timeout | `endOnMissingPrint` reverts if the eligible print exists; the gas floor prevents starving the read. | `test_TimelyPrintBlocksTimeoutHoweverLateItIsApplied`, `testFuzz_LowGasCannotFakeAnOutage` (25k–400k gas) |
| I8 | One moment has exactly one recordable Chainlink print, whenever it is recorded | One pinned phase; rules 1–2 of section 4. | `test_ProxySwitchDoesNotChangeAPrint`, `test_RefusesARoundThatWasNotInForce`, fork `test_fork_overlapGivesOnePrintOnThePinnedPhase` |

### 5.2 Threats considered

| Threat | Handling |
| --- | --- |
| Front-running a known print by minting/redeeming | Pairs are value-neutral at every moment; single-leg redemption only after the end. No value leaks through the vault (only through external pools, by design). |
| Keeper choosing an allocation by delay | Prints are deterministic from Chainlink history; recording is permissionless and once-only; the timeout cannot override a timely print. |
| Griefing with low gas | 105k floor before a 100k-budget read; fuzzed. |
| Malicious/broken oracle reply | Fixed-size buffer, exact-length check, bounded gas; treated as missing. |
| Reentrancy | `mint`/`redeem` are `nonReentrant`, effects before the external transfer; oracle read is `staticcall`; legs have no hooks. |
| Rounding drain | Pairs exact; remainders floor; claims never use remaining supply as a denominator. Dust stays in the vault. |
| Donations / balance games | Donations create no claims; deposit must arrive exactly (`DepositMismatch` for fee-taking tokens). |
| Failing token transfers | Solady SafeTransferLib reverts on false/failed; burns and accounting revert with the payout. A failing `balanceOf` reverts (plain interface call), never reads as an empty vault. |
| Issuer seizure from the vault | Pro-rata cut on every later redemption; minting blocked while short; no race. A holder who redeems during a shortfall keeps the cut even if stock is later returned (disclosed). |
| Issuer pause / blocklist | Payout only to `msg.sender`, so a blocklisted holder cannot redeem until unblocked; nothing is burned on a refused transfer. Legs remain transferable (accepted and disclosed by Sean). An issuer blocklist on the vault itself freezes all exits (disclosed). |
| Oversupply / bad factory input | Constructor validates schedule shape, report delay (0 < d ≤ 7 days) and nonzero cap. Calendar correctness (holidays, DST) is the Safe's responsibility; the first series' times were generated from the New York calendar and are asserted in the fork rehearsal. |
| Factory owner | Can only list new series; cannot touch existing ones. |
| Permit2 default allowance | Disabled on legs. |
| Feed migration or proxy switch | Phase pinned at deploy (section 4). |
| Stopped or retired feed | Values older than 84 hours are refused and the keeper ends the series at its last values once the deadline passes (`test_RefusesARoundOlderThanTheStalenessLimit`, `test_KeeperEndsTheSeriesOnADeadFeed`); a holiday weekend still prices (`test_HolidayWeekendGapStillPrices`). |
| Keeper picking the wrong round | The oracle verifies the round; the keeper's search is fuzzed against a linear scan (`testFuzz_KeeperFindsTheRoundInForce`) and runs on the real feed in the fork suite. |

### 5.3 Accepted limits

- Prices are Chainlink's scheduled values, not official auction prints; differences move returns
  between the legs (section 4).
- A feed stop or a corporate-action freeze longer than 84 hours ends the series at its last values;
  within 84 hours of a stop, its frozen value is used and moves are not counted.
- Knock-out at zero (2.2); leverage varies with the path (P/N, P/S); ledgers add dollar moves, they do
  not compound.
- `maxReportDelay` must be well above the oracle's one-hour wait or no print can ever count; the
  factory does not enforce this (the first series uses seven days).
- Dust-sized claims cannot redeem during a shortfall; dust, donations and shortfall cuts remain in the
  vault (no sweep).
- One holder can fill a series' cap (and can exit at any time).

### 5.4 Verification performed

- Offline gate (`contracts/exposure/bin/gate.sh`, Foundry 1.5.1): 56 checks — 36 series unit/fuzz,
  5 invariants (256 runs × 128 calls over mint, redeem, transfers, prints, missed prints, donations,
  seizures), 14 oracle and keeper, 1 factory. Fuzz runs 1,024 per property.
- Mutation check (re-run 29 Oct on the final code): seven deliberate bugs planted one at a time in
  the series (overdrawn depletion, skipped depletion, oversized oracle reply accepted, no seizure
  cut, single legs before the end, late print accepted, legs burned for nothing); each made at least
  one test fail.
- Base fork (Foundry 1.8.6 `anvil --network base`, block 53,209,576), 7 tests on the real AMZNc B20
  token and real AMZN Chainlink feed: a series over 23–28 Oct 2026 real prices (ends 126.31992499 /
  126.60757501 at 252.9275; each leg redeems for exactly its share); real 2-for-1 multiplier change;
  real issuer blocklisting and transfer pause; a moment in the August feed overlap priced from the
  pinned phase only; and a full rehearsal of deployment, the Safe's `createSeries` call as printed,
  the Friday sitting (first print, minting, both Aerodrome pools landing 50 minutes after simulation,
  and Aerodrome refusing them after the deadline), and the closing sitting through maturity, with the
  week's feed rounds stood in on the pinned phase.
- Independent reviews: three agent reviews (code; economics against the paper; the Chainlink reader),
  an outside second look at the full bundle, and an agent review of the pinned-phase oracle (which
  set the 84-hour limit, the keeper's dead-feed handling and the deploy-time phase check). Every
  finding acted on has a lasting test.
- Deployed bytecode checked against the build: factory byte-for-byte.

## 6. Deployment and the first series

| Item | Value |
| --- | --- |
| Chain | Base (8453) |
| Price oracle | `ChainlinkPrintOracleV2` on phase 2 of the AMZN feed `0x06A8…B295`: **to be deployed** (replaces `ChainlinkPrintOracleV1` at `0x6e80e0b65F50666E230276FD5bEf61059aC65f98`, deployed 28 Oct and never used by a series) |
| `ExposureFactoryV1` | `0xAECE72c94CaC843f9Ecd54aC6Ca833bF4CFED048`, owner Safe `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e` (2 of 3) |
| Deployer | `0x9b2C414614aEE294202c1219520955EF3B596031` (factory block 53,219,733) |
| First series | AMZNc `0xb200000000000000000000d9192b6B456483C2E8`; Fri 30 Oct 2026 16:00 → Fri 6 Nov 2026 16:00 New York (11 prints; 20:00 UTC first close, then 14:30/21:00 UTC after the 1 Nov clock change); cap 0.4 AMZNc (~$100); recording window 7 days; legs "AMZNc After-hours to 6 Nov 2026" (AMZNc-AH-1106) and "AMZNc Market-hours to 6 Nov 2026" (AMZNc-MH-1106); termsHash = keccak256 of `platform/docs/after-hours-terms-amznc-2026-11-06.md` (revised after the second review; awaiting approval). Not yet created. |
| Demo | After the first close: record + settle, mint a 0.2 AMZNc pair, open two Aerodrome volatile pools (each leg vs USDC at its ledger value) with a one-hour deadline. After the last close: record and settle the remaining ten prints. Scripts: `script/AfterHoursDemo.s.sol`. The pools only show the mechanics working; they are far too small to be useful trading liquidity. |

## 7. Website (planned; `Autolaunch.Exposure`, behind `config :autolaunch, :exposure_enabled`)

Autolaunch is Phoenix LiveView + Ash. Wallet actions are prepared on the server as unsigned steps and
sent by the person's (or agent's) own wallet through the existing `AutolaunchWeb.OnchainSteps`
component. The site never holds keys and never stores pending transactions; it reads chain state and
receipts. On-chain buttons are never blocked by page state; a press is disabled only when the chain's
current state makes it certain to fail, with the reason beside it.

### 7.1 Pages

| Route | LiveView | Shows | Actions |
| --- | --- | --- | --- |
| `/after-hours` | `AfterHoursLive :index` | One card per live series: stock, term, next print time, minted vs cap, and for each leg its ledger value and its pool price, labelled separately. | — |
| `/after-hours/:series` | `AfterHoursLive :series` | Price path so far (each print with its source round and age, which leg moved), current leverage (P/N, P/S), terms link. For each leg three values, never merged: ledger (its dollar allocation now), pool quote (what it sells for), and stock amount (AMZNc it redeems for: before the end only as a pair; after the end its fixed share, e.g. 104/170 AMZNc, whose dollar value moves with AMZNc). | Mint pair, Redeem pair, Buy/Sell either leg (Aerodrome), Redeem after the end, Record/Settle when due. No Roll in v1: rolling one leg means redeeming, minting a new pair and selling the unwanted leg, which is left until that trade is specified. |
| `/stock-listing/:symbol` | existing `StockLive` | Link to the stock's live series. | — |
| `/portfolio` | existing `PortfolioLive` | "After-hours" section: legs held with the same three values, and whether each can be redeemed now. | Same steps as the series page. |

Disabled-only-when-certain-to-fail cases: series not Active (mint), cap reached, vault short after a
seizure (mint), unequal amounts before the end (redeem), no approval on chain yet (mint shows the
approval step first).

### 7.2 HTTP API (OpenAPI-published, mirrored by WebMCP tools and CLI commands)

| Method and path | Pipeline | Operation | Returns |
| --- | --- | --- | --- |
| `GET /api/v1/after-hours` | `:api, :public_read` | `listAfterHoursSeries` | Series with stock, term, status, next print, ledgers, cap use, leg addresses and pool prices. |
| `GET /api/v1/after-hours/{series}` | `:api, :public_read` | `getAfterHoursSeries` | One series with every applied print and the terms text and hash. |
| `GET /api/v1/me/after-hours` | `:session_api` | `myAfterHours` | Signed-in account's legs per series and what they redeem for. |
| `GET /api/agent/v1/after-hours` | paired agent | `agentAfterHours` | The same for a paired agent's owner. |
| `POST /api/agent/v1/after-hours/{series}/steps` | paired agent | `prepareAfterHoursSteps` | Unsigned steps (`chain_id`, `to`, `data`, `value`, plain description) for `mint`, `redeem`, `record`, `settle` or `end`, bound to the owner's verified wallet. |

The website's own buttons call the same Ash actions as these routes. Every route answers with the
same words and refusals across the page, WebMCP, hosted MCP and CLI.

### 7.3 Ash domain and jobs

- `Series` (from factory `SeriesCreated` logs), `Event` (every series and oracle log, written once by
  the existing indexer cursor), `Holding` and `Ledger` read models rebuilt from events; balances are
  always read from chain.
- `Steps`: builds the unsigned calls above (approve exact amount → `mint`; `redeem`; `record` with
  the round of the pinned phase in force, found by binary search exactly as `AfterHoursDemo.roundInForce`;
  `settle`; `endOnMissingPrint`).
- Oban cron job `RecordPrints`: an hour after each scheduled open/close of every live series, finds
  the round in force, calls `record` then `settle`, using a dedicated keeper wallet with gas only.
  It holds no customer key and chooses nothing; anyone can make the same calls.

## 8. CLI (`regents autolaunch after-hours …`, added to `cli/commands.json` and regents-cli)

The CLI is a thin client of the HTTP API: JSON out, SIWA-signed requests for private commands, private
inputs on JSON stdin. It never signs or sends a wallet transaction; `steps` returns unsigned calls for
the agent to sign with its own key. The catalogue's note "No wallet … commands" becomes "Wallet
commands only prepare unsigned steps; no command signs or sends a transaction."

| Command | Authority | Effect | Route | WebMCP |
| --- | --- | --- | --- | --- |
| `after-hours list` | public | read | `GET /api/v1/after-hours` (`--stock`, `--status`, `--limit`, `--after`) | `autolaunch_after_hours_series` |
| `after-hours show <series>` | public | read | `GET /api/v1/after-hours/{series}` | `autolaunch_after_hours_series_detail` |
| `after-hours mine` | paired_agent | read | `GET /api/agent/v1/after-hours` | `autolaunch_my_after_hours` |
| `after-hours steps <series>` | paired_agent | prepare | `POST /api/agent/v1/after-hours/{series}/steps`, stdin `{"action": "mint" \| "redeem" \| "record" \| "settle" \| "end", "overnight": "<raw>", "session": "<raw>", "amount": "<raw>"}` | `autolaunch_after_hours_steps` |

Amounts are raw integer strings (never floats). A typical agent flow: `after-hours list` → `after-hours
show` → `after-hours steps --action mint` → sign and send each step with its own wallet → `after-hours
mine` to confirm from chain.

## 9. Questions for the reviewer

1. Is ending the series at the depleting print (surviving leg takes all) the right economic rule, and
   is anything better that still never over-claims the stock?
2. Is the "value in force at T" rule on a 0.5%-deviation Chainlink feed acceptable for attributing
   moves between windows, or is there a better on-chain-only rule with the same feed?
3. Is pinning one feed phase, with an 84-hour staleness limit, the right answer to aggregator
   migrations for a one-week series?
4. Any path by which `endOnMissingPrint` can fire while a valid print exists, or by which `settle` can
   apply a wrong print?
5. Any rounding, shortfall or reentrancy path that pays more than owed or locks value?
6. Is pro-rata on seizure (with the cut final for those who redeem while short) the right policy?
7. Should legs check the issuer's blocklist on transfer (currently they do not, by decision)?
8. Anything in the scripts or the Safe call that would create the series with wrong parameters?

---

## Source

The complete Solidity source is in `contracts/exposure/` (`src/`, `script/`, `test/`). The review
bundle sent outside the repository appends every file verbatim.
