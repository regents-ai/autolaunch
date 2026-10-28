# Exposure — design note

**Status:** contracts written and tested, not deployed; site not built · 28 October 2026
**Source:** "Isolated Exposure Tokens" (The Standard Reserve, October 2026), Sean's notes of 28 October 2026
**Contracts:** [`contracts/exposure`](../../contracts/exposure/README.md)

## 1. The product

A Base stock token (B20, for example AMZNc) earns its return in two windows: overnight, from one
close to the next open, and in session, from the open to the close. An exposure series splits one
stock token, for a fixed term, into two ordinary tokens:

- **OVERNIGHT** gains or loses one share's dollar move over each overnight window.
- **SESSION** gains or loses one share's dollar move over each regular session.

One of each always mints from, and redeems for, exactly one stock token, so the pair is the stock.
Each leg alone is a position on one window, about 2× at the start, with no lender, margin or
liquidation. At the end of the term each leg redeems for its ledger's share of the stock.

The paper's worked example runs unchanged in the contract (and on the real AMZNc token in the fork
suite):

| Print | Price | OVERNIGHT | SESSION |
| --- | --- | --- | --- |
| Series start (close) | $160 | $80 | $80 |
| Friday open | $172 | $92 | $80 |
| Friday close | $166 | $92 | $74 |
| Monday open | $178 | $104 | $74 |
| Monday close | $170 | $104 | $66 |

At the end one OVERNIGHT redeems for 104/170 of a stock token and one SESSION for 66/170. These are
claims on stock, not on dollars.

## 2. Where the contract departs from the paper

| Rule | Paper | Contract | Why |
| --- | --- | --- | --- |
| A ledger reaches zero or below | Ledgers go negative | The series ends at that print; the other leg owns all the stock | A negative ledger means the other leg claims more stock than exists. Example: start $100 (50/50), open at $40. Paper: OVERNIGHT −10, SESSION 50, i.e. 1.25 tokens per pair backed by 1. Contract: OVERNIGHT 0, SESSION 40 = the whole token. |
| A print never arrives | Not covered | After its deadline, anyone ends the series at the last applied ledgers | Funds can never be stuck waiting on the oracle. A print made final in time blocks this however late it is applied, so a slow keeper cannot pick an older allocation. |
| Single legs before the end | Sold in a pool | Same; only equal pairs redeem before the end | Keeps both supplies equal to the stock held, so the vault never rebalances. |
| Issuer takes stock from the vault | Not covered | Every later redemption is cut by the same fraction; minting stops until the stock is back; legs worth something are never burned for nothing | Nobody can race the others out, and new money never fills an old hole. A cut taken while short is final for that holder: stock returned later stays in the vault. |
| Where redeemed stock goes | Not covered | Only to the account redeeming | The issuer's blocklist and pauses then apply to every payout. |
| Size | Unbounded | Each series has a deposit cap | Limits the stock that depends on the oracle while it is new. |

Near zero a leg is a knock-out, not purely isolated: in the worked example's last state (104/66 at
$170), a session fall to $100 ends the series with OVERNIGHT at $100, so OVERNIGHT loses $4 to a
session move. Holders must be told this, and that leverage moves with the price path (price ÷
ledger) and the ledgers add dollar moves rather than compounding.

The contract has no owner, admin, upgrade, pause or fee. The factory owner (the governance Safe)
only decides which series exist.

## 3. Prints: what is on chain and what is not

`ExposureSeriesV1` reads one interface, `IFinalizedPrintOracle.getPrint(feed, scheduledAt, isOpen)`,
which returns the price of **one raw token** in USD (the official equity print times the token's
multiplier at that moment), the scheduled time it is for, and when it became final. The series
accepts a print only for exactly that boundary, positive, and made final no earlier than the
boundary and no later than `scheduledAt + maxReportDelay`. It reads the oracle with a fixed 100,000
gas budget and a fixed three-word reply: a broken oracle counts as a missing print, and a caller
cannot fake an outage by sending too little gas (fuzzed from 25,000 to 400,000 gas).

`PrintOracleV1` is the on-chain half of the oracle: a fixed set of up to eight reporters, a strict
majority threshold, one vote per reporter per print, final when the threshold agrees on one price,
stamped with the block time of the deciding vote, never changed afterwards, no owner. A reporter
may change its vote until the print is final, so a typo or a rounding difference does not cost the
print. Agreement is to the wei, so the terms fix one rounding rule for every reporter.

Still to build, off chain (the reporters' side):

1. Official open and close prints for the stock's primary venue, from at least two independent data
   sources, with the reporters' keys held apart.
2. The token's multiplier at each print, from its own history, so a split never looks like a loss.
   Base's Chainlink stock feeds are already multiplier-adjusted and are not official auction
   prints, so they serve only as a cross-check.
3. The exchange calendar (holidays, early closes, daylight saving) turned into each series' UTC
   schedule before creation. The contract checks only order and shape.
4. A written policy for halts, delayed auctions and corrections, committed in `termsHash`. A missed
   deadline is final: the series ends at its last ledgers.
5. **Unscheduled closures** (for example a national day of mourning) must not end the series.
   Rule: for a closed day, reporters publish the last official close as both that day's open and
   close. Both moves are zero, and the next open is measured from the same close, so no value moves
   between legs.
6. **Corporate actions** change value between legs if the price and the multiplier step at
   different times. A dividend lowers the price at the ex-date open, but the token's multiplier may
   step later, at the issuer's effective time; a split's open print must use the post-split
   multiplier or it looks like a 90% overnight loss. Rule: the reporters' price per raw token uses
   the multiplier economically in force at the print (ex-date for dividends, split date for
   splits), and series terms list known action dates. Short terms keep this rare.

## 4. The site (`Autolaunch.Exposure`, not built)

Behind `config :autolaunch, :exposure_enabled`, off by default. Same patterns as Covered Calls.

| Place | Purpose |
| --- | --- |
| `/exposure` | Live series: stock, term, next print, both ledgers, the leg prices in their pools, and how much is minted against the cap. |
| `/exposure/:series` | One series: price path so far, Mint pair, Redeem pair, Buy or sell either leg, and after the end Redeem at the final split. Shows each leg's current leverage (price ÷ ledger), not a fixed 2×. |
| `/stock-listing/:symbol` | A link to the stock's live series. |
| `/portfolio` | An "Exposure" section: legs held, their ledger value in stock and dollars, and what they redeem for. |

Ash domain `Autolaunch.Exposure`:

- `Series` — one row per factory `SeriesCreated`, with the schedule and terms text it commits to.
- `Event` — one row per contract log under the existing chain-events rules, read by the indexer
  cursor (`Autolaunch.Indexer`); `Holding` and `Ledger` read models rebuilt from events.
- `Steps` — server-built wallet steps for `AutolaunchWeb.OnchainSteps`: approve stock, mint, redeem,
  settle, end on missing print. A press certain to fail from the chain's own state (series not live,
  cap reached, stock short after a seizure) shows the button disabled with the reason; nothing
  else blocks a press.
- Oban jobs: `SettleSeries`, a keeper that calls `settle` (or `endOnMissingPrint` after a deadline)
  for every series with a print due. It holds no customer key and chooses no price; anyone can do
  the same call. `CollectPrint` and `ReportPrint` belong to the reporters (section 3) and run with
  their own keys, apart from the site.

Agent surfaces, one Ash action each, same inputs, results and refusals everywhere:

| Action | WebMCP | HTTP | Hosted MCP | CLI |
| --- | --- | --- | --- | --- |
| List series | `autolaunch_exposure_series` | `GET /api/v1/exposure` | via `/mcp` | `regents autolaunch exposure list` |
| One series with ledgers and next print | `autolaunch_exposure_series_detail` | `GET /api/v1/exposure/:series` | via `/mcp` | `regents autolaunch exposure show` |
| My legs | `autolaunch_my_exposure` | `GET /api/v1/me/exposure` | via `/mcp` | `regents autolaunch exposure mine` |
| Prepare a step (mint, redeem, settle, end on missing print) | `autolaunch_exposure_prepare` | `POST /api/v1/me/exposure/steps` | via `/mcp` | `regents autolaunch exposure prepare` |

The owner's own key signs every step; the site prepares and never signs.

## 5. Trading the legs

The vault makes pairs; it does not make a market in single legs. Each leg needs its own pool against
USDC (or against the stock) with liquidity someone provides and can withdraw, because both legs
expire and one can end at zero. The forever-locked Memestake liquidity pattern does not fit here.
Any trading fee goes to REGENT staking through the existing `depositUSDC` path; the vault itself
takes nothing.

## 6. Tests and evidence (28 October 2026)

- `contracts/exposure/bin/gate.sh` (Foundry 1.5.1): 50 tests pass.
  - 36 series tests: the worked example, mixed and pair redemptions, minting mid-term, both
    depletion directions and exact zero, maturity, missing first close, missing, late and misdated
    prints, six kinds of broken oracle (revert, short, long, dirty, gas burn, oversized reply), the
    deposit cap, donations, seizure, total seizure and refill, a failing balance read, fee-taking
    and false-returning tokens, stock going only to the redeemer, construction. Fuzz (1,024 runs
    each): ledgers always sum to the price; claims never exceed what was deposited; splitting a
    redemption never pays more; low gas never fakes an outage.
  - 5 invariants over 256 runs × 128 random calls (mint, redeem, transfers, prints, missed prints,
    donations, seizures): pairs equal backing while live; ledgers within price; claims never exceed
    accounted stock after the end; every raw unit accounted for; fully backed unless seized.
  - 8 oracle tests (quorum, disagreement, vote corrections, finality, bad input, a series settling
    from quorum prints) and 1 factory test.
  - Six deliberate bugs planted one at a time (overdrawn session depletion, skipped overnight
    depletion, oversized oracle reply accepted, no seizure cut, single legs before the end, late
    print accepted): each made at least one test fail.
- Base fork (Foundry 1.8.6, `anvil --network base`, block 53,209,576): 5 tests pass on the real AMZNc
  token through the factory and a 2-of-3 `PrintOracleV1`: the worked example, a real 2-for-1
  multiplier change leaving the raw backing intact, a real blocklisting (the holder cannot redeem,
  the refused payout burns nothing, and after unblocking everything redeems), and a real transfer
  pause (mint and redeem wait, prints keep applying, everything redeems after).
- Two independent reviews (code, and economics against the paper and the oracle requirements).
  Fixed from them, each with a lasting test: stock now goes only to the redeeming account; a
  failing balance read or a total seizure can no longer burn legs for nothing; reporters can correct
  a vote before a print is final; the legs give Permit2 no standing allowance. No critical or high
  finding reproduces against the final code. Left as known behaviour: dust-sized claims cannot
  redeem during a shortfall; donations, rounding dust and a cut taken during a shortfall stay in
  the series; one holder can fill a series' cap (they can redeem it at any time).
- Gas: `settle` about 50,000; `redeem` about 59,000; `mint` about 203,000 for a first-time holder.
  Runtime size 5.1 KB (series), 2.7 KB (leg), 1.5 KB (oracle).

## 7. Open items

1. **Who publishes prints**, and from which data (section 3). The series is only as good as this.
2. **First stock, term and cap.** Suggested: AMZNc, one week (11 prints), a small cap. Before
   creating a series, the Safe checks the first close is still ahead and the report delay is
   shorter than the gap between prints; the factory does not.
3. **Leg liquidity**: who seeds the two pools, and the trading fee.
4. **Eligibility.** Coinbase's tokenized stocks are only for persons in eligible jurisdictions
   outside the United States, and levered legs on them need their own review. Base notes a listing
   is not an endorsement.
5. **Issuer blocklist on the legs.** Redeemed stock goes only to the redeeming account, so a
   blocklisted holder cannot redeem. But the legs are ordinary tokens: a blocklisted holder can
   still move or sell them, and the new holder can redeem. Closing that means each leg transfer
   checks the stock's own transfer policy, which first needs proving on a Base fork that B20
   exposes it to contracts.
6. **Disclosures** on every page and tool: the knock-out at zero, leverage that moves with the
   price, the end on a missing print, who the reporters are and that a majority of them decides
   every print (the deposit cap bounds that trust), and that an issuer blocklist on the series
   itself would freeze every holder. The paper's SPY history is not a return claim for any stock.
