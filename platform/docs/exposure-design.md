# After-hours Exposure — design note

**Status:** contracts written and tested, not deployed; site not built · 28 October 2026
**Source:** "Isolated Exposure Tokens" (The Standard Reserve, October 2026), Sean's notes and decisions of 28 October 2026
**Contracts:** [`contracts/exposure`](../../contracts/exposure/README.md)
**First series plan:** [`contracts/exposure/series/amznc-2026-11-06.json`](../../contracts/exposure/series/amznc-2026-11-06.json)

## 1. The product

After-hours Exposure splits a stock token into two tokens: one that earns the stock's moves while the
market is closed, and one that earns its moves during the trading day. Hold one for a levered
position on just that window, with no loan and no liquidation; hold both and you simply own the stock.

A series takes one Base stock token (B20, for example AMZNc) for a fixed term and issues two ordinary
tokens:

| Customer name | Contract name | Gains or loses one share's dollar move |
| --- | --- | --- |
| **After-hours** | OVERNIGHT | from each close to the next open, weekends included |
| **Market-hours** | SESSION | from each open to the same day's close |

One of each always mints from, and redeems for, exactly one stock token, so the pair is the stock.
Each leg alone is about 2× its window at the start. At the end of the term each leg redeems for its
ledger's share of the stock.

The paper's worked example runs unchanged in the contract:

| Print | Price | After-hours | Market-hours |
| --- | --- | --- | --- |
| Series start (close) | $160 | $80 | $80 |
| Friday open | $172 | $92 | $80 |
| Friday close | $166 | $92 | $74 |
| Monday open | $178 | $104 | $74 |
| Monday close | $170 | $104 | $66 |

At the end one After-hours token redeems for 104/170 of a stock token and one Market-hours token for
66/170. These are claims on stock, not on dollars.

## 2. Where the contract departs from the paper

| Rule | Paper | Contract | Why |
| --- | --- | --- | --- |
| A ledger reaches zero or below | Ledgers go negative | The series ends at that print; the other leg owns all the stock | A negative ledger means the other leg claims more stock than exists. Example: start $100 (50/50), open at $40. Paper: After-hours −10, Market-hours 50, i.e. 1.25 tokens per pair backed by 1. Contract: After-hours 0, Market-hours 40 = the whole token. |
| A print never arrives | Not covered | After its deadline, anyone ends the series at the last applied ledgers | Funds can never be stuck waiting on the oracle. A print recorded in time blocks this however late it is applied. |
| Single legs before the end | Sold in a pool | Same; only equal pairs redeem before the end | Keeps both supplies equal to the stock held, so the vault never rebalances. |
| Issuer takes stock from the vault | Not covered | Every later redemption is cut by the same fraction; minting stops until the stock is back; legs worth something are never burned for nothing | Nobody can race the others out, and new money never fills an old hole. A cut taken while short is final for that holder. |
| Where redeemed stock goes | Not covered | Only to the account redeeming | The issuer's blocklist and pauses then apply to every payout. |
| Size | Unbounded | Each series has a deposit cap | Limits the stock at risk while the product is new. |

Near zero a leg is a knock-out, not purely isolated: in the worked example's last state (104/66 at
$170), a trading-day fall to $100 ends the series with After-hours at $100, so After-hours loses $4 to
a trading-day move. Holders must be told this, and that leverage moves with the price path (price ÷
ledger) and the ledgers add dollar moves rather than compounding.

The series has no owner, admin, upgrade, pause or fee. The factory owner (the governance Safe) only
decides which series exist.

## 3. Prices: Chainlink (Sean, 28 Oct 2026)

`ChainlinkPrintOracleV1` takes each open and close from the stock's Coinbase Chainlink feed on Base
(AMZN: `0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295`). The print for a scheduled time is the feed's
value **in force at that moment**: the last round updated at or before it. An hour after the moment,
anyone records it by naming that round; the oracle checks the round was in force (the next round
came later, or there is none) and keeps the value for good. No owner and no reporters. The series
reads it through `IFinalizedPrintOracle`, with a fixed gas budget and reply size, and accepts a print
only if it was recorded within `maxReportDelay` of its time.

Measured on the AMZN feed (rounds 300 to 481, 29 Sep to 28 Oct 2026):

- It runs 24/5: it updates overnight and before the open, restarts Sunday 20:00 New York time, and
  holds its last value over weekends. About six updates a day.
- It updates on a 0.5% move (or a 24-hour heartbeat), so the value in force at 09:30 or 16:00 can
  differ from the exchange's official price by up to about 0.5%. On 28 Oct the last update before
  the close was at 10:38. Any such gap is not lost: it lands in the next window instead. Customer
  copy says the prints are Chainlink's values at the open and close, not the official auction prices.
- The value is total return (price times the token's multiplier), so splits and dividends need no
  adjustment and show no jump.
- During a corporate action the feed freezes and holds its value; an unscheduled market closure
  simply records no move. Neither ends a series.
- When Chainlink moves the proxy to a new feed it runs both side by side for a while (AMZN's old and
  new feeds both published for nine days in August 2026). Only the newest feed that had reported by
  a moment counts for it, so each moment has exactly one print; in the days before the switch this
  can differ slightly from what the proxy itself showed.

## 4. Running continuously

A single series cannot safely run forever:

1. A single leg can only be turned back into stock when its series ends (before that only pairs
   redeem). With no end, a lone leg's price would rest only on what traders expect, with nothing it
   converges to.
2. Leverage drifts with the price. Over months one ledger gets small, that leg becomes highly levered,
   and an ordinary gap knocks it out, which ends the series anyway.

So the product runs continuously as **back-to-back weekly series**: each one starts at Friday's close
as the previous one ends. Holders redeem the finished week and mint into the next in one review
("Roll to next week"); legs held through a roll start the new week at 50/50 again. Each week needs a
`createSeries` call from the Safe, prepared by the site from the exchange calendar.

## 5. First series (planned, not created)

[`amznc-2026-11-06.json`](../../contracts/exposure/series/amznc-2026-11-06.json): AMZNc from Friday
30 October 16:00 to Friday 6 November 16:00 New York time, 11 prints. US clocks go back on Sunday 1
November, so Friday's close is 20:00 UTC and the following week's opens and closes are 14:30 and
21:00 UTC; no market holidays that week. Proposed cap 40 AMZNc (about $10,000) and a two-day
recording window (it must be well over the oracle's one-hour wait, or no print can ever count;
the factory does not check this). Creating it needs the oracle deployed first; both are contract deployments and
wait for Sean's go naming them.

## 6. The site (`Autolaunch.Exposure`, not built)

Behind `config :autolaunch, :exposure_enabled`, off by default. Same patterns as Covered Calls.

| Place | Purpose |
| --- | --- |
| `/after-hours` | This week's series per stock: next print, both ledgers, each leg's pool price, minted against the cap. |
| `/after-hours/:series` | One series: prices so far, Mint pair, Redeem pair, Buy or sell either leg, Roll to next week, and after the end Redeem at the final split. Shows each leg's current leverage (price ÷ ledger), not a fixed 2×. |
| `/stock-listing/:symbol` | A link to the stock's live series. |
| `/portfolio` | An "After-hours Exposure" section: legs held, their value in stock and dollars, and what they redeem for. |

Ash domain `Autolaunch.Exposure`:

- `Series` — one row per factory `SeriesCreated`, with the schedule and terms text it commits to.
- `Event` — one row per contract log under the existing chain-events rules, read by the indexer
  cursor (`Autolaunch.Indexer`); `Holding` and `Ledger` read models rebuilt from events.
- `Steps` — server-built wallet steps for `AutolaunchWeb.OnchainSteps`: approve stock, mint, redeem,
  roll, record print, settle, end on missing print. A press certain to fail from the chain's own
  state (series not live, cap reached, stock short after a seizure) shows the button disabled with
  the reason; nothing else blocks a press.
- Oban job `SettleSeries`: an hour after each open and close, finds the feed round in force, calls
  `record`, then `settle` on every series due. It holds no customer key and chooses no price; anyone
  can make the same calls.

Agent surfaces, one Ash action each, same inputs, results and refusals everywhere:

| Action | WebMCP | HTTP | Hosted MCP | CLI |
| --- | --- | --- | --- | --- |
| List series | `autolaunch_after_hours_series` | `GET /api/v1/after-hours` | via `/mcp` | `regents autolaunch after-hours list` |
| One series with ledgers and next print | `autolaunch_after_hours_series_detail` | `GET /api/v1/after-hours/:series` | via `/mcp` | `regents autolaunch after-hours show` |
| My legs | `autolaunch_my_after_hours` | `GET /api/v1/me/after-hours` | via `/mcp` | `regents autolaunch after-hours mine` |
| Prepare a step (mint, redeem, roll, record, settle, end on missing print) | `autolaunch_after_hours_prepare` | `POST /api/v1/me/after-hours/steps` | via `/mcp` | `regents autolaunch after-hours prepare` |

The owner's own key signs every step; the site prepares and never signs.

## 7. Trading the legs

The vault makes pairs; it does not make a market in single legs. Each leg needs its own pool against
USDC with liquidity someone provides and can withdraw, because both legs expire and one can end at
zero. The forever-locked Memestake liquidity pattern does not fit here. Any trading fee goes to
REGENT staking through the existing `depositUSDC` path; the vault itself takes nothing.

## 8. Tests and evidence (28 October 2026)

- `contracts/exposure/bin/gate.sh` (Foundry 1.5.1): 54 tests pass.
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
  - 12 Chainlink oracle tests (the round in force, rounds superseded, later or missing, a round
    exactly at the moment, the latest round over a quiet weekend, a feed phase change, overlapping
    old and new feeds, a new feed with no rounds yet, missing rounds read as zeros, the one-hour
    wait, record once, bad answers, a series settling end to end) and 1 factory test.
  - Six deliberate bugs planted one at a time in the series (overdrawn depletion, skipped
    depletion, oversized oracle reply accepted, no seizure cut, single legs before the end, late
    print accepted): each made at least one test fail.
- Base fork (Foundry 1.8.6, `anvil --network base --fork-block-number 53209576`): 6 tests pass on the
  real AMZNc token and the real AMZN Chainlink feed, through the factory:
  - This week for real: Friday 23 Oct close $247.93375 to Wednesday 28 Oct close $252.9275, seven
    prints found and recorded from the live feed's rounds. After-hours ends at $126.31992499 and
    Market-hours at $126.60757501, and each redeems apart for exactly its share of the stock.
  - A real 2-for-1 multiplier change leaves the raw backing intact; a real blocklisting stops the
    holder redeeming until unblocked and burns nothing; a real transfer pause delays mint and
    redeem while prints keep applying.
  - The feed's own August overlap: an old-feed round that would have priced a moment at $275.13 is
    refused, and the new feed's $274.475 is the only print.
- Three independent reviews (code, economics against the paper, and the Chainlink reader). Fixed
  from them, each with a lasting test: stock goes only to the redeeming account; a failing balance
  read or a total seizure can no longer burn legs for nothing; the legs give Permit2 no standing
  allowance; overlapping Chainlink feeds give one print, not two to choose from; a proxy moved to a
  feed with no rounds yet no longer stalls recording. No
  critical or high finding reproduces. Left as known behaviour: dust-sized claims cannot redeem
  during a shortfall; donations, rounding dust and a cut taken during a shortfall stay in the
  series; one holder can fill a series' cap (they can redeem it at any time).
- Gas: `settle` about 50,000; `redeem` about 59,000; `mint` about 203,000 for a first-time holder.

## 9. Open items

1. **Leg liquidity**: who seeds the two pools each week, and the trading fee.
2. **Eligibility.** Coinbase's tokenized stocks are only for persons in eligible jurisdictions
   outside the United States, and levered legs on them need their own review. Base notes a listing
   is not an endorsement.
3. **Issuer blocklist on the legs** (Sean: leave it, disclose it). Redeemed stock goes only to the
   redeeming account, so a blocklisted holder cannot redeem; but the legs are ordinary tokens, so a
   blocklisted holder can still move or sell them and the new holder can redeem.
4. **Disclosures** on every page and tool: the knock-out at zero, leverage that moves with the
   price, prints are Chainlink's values (within about 0.5% of the official price), the end on a
   missing print, the blocklist point above, and that an issuer blocklist on the series itself
   would freeze every holder. The paper's SPY history is not a return claim for any stock.
