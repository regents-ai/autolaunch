# Isolated Exposure to After-hours Stocks — design note

**Status:** contracts deployed on Base; first series created 29 October 2026; site built, switched off · 29 October 2026
**Source:** "Isolated Exposure Tokens" (The Standard Reserve, October 2026), Sean's notes and decisions of 28 October 2026
**Contracts:** [`contracts/exposure`](../../contracts/exposure/README.md)
**First series:** [`contracts/exposure/script/DeployAfterHours.s.sol`](../../contracts/exposure/script/DeployAfterHours.s.sol) · approved terms [`0x5f67343b39277939aea7613c578fa3931b8b89da7a65eb36dd7217c81a5a2e8f.md`](../priv/exposure_terms/0x5f67343b39277939aea7613c578fa3931b8b89da7a65eb36dd7217c81a5a2e8f.md)

## 1. The product

Isolated Exposure to After-hours Stocks splits a stock token into two tokens: one that earns the stock's moves while the
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

`ChainlinkPrintOracleV2` takes each open and close from the stock's Coinbase Chainlink feed on Base
(AMZN: `0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295`), pinned to the feed version (Chainlink "phase")
in use when the oracle is deployed. The print for a scheduled time is that version's latest value at
the moment, if it is at most 84 hours old. An hour after the moment, anyone records it by naming the
round; the oracle checks it and keeps the value and its source round for good. No owner and no
reporters. Full rules and the reasons for them: [after-hours-exposure-spec.md](after-hours-exposure-spec.md), section 4.

Measured on the AMZN feed (29 Sep to 28 Oct 2026):

- It runs 24/5: it updates overnight and before the open, restarts Sunday 20:00 New York time, and
  holds its last value over weekends. About six updates a day; the oldest value in force at any open
  or close was 17.6 hours.
- It updates on a 0.5% move or a 24-hour heartbeat and can lag, so a print is not the exchange's
  official price and can differ from it by more than 0.5%. A move the feed has not shown yet lands in
  whichever window it appears, which can shift value between the two tokens. The product is
  described as exposure to scheduled Chainlink values, and the demo week measures the divergence.
- The value is total return (price times the token's multiplier), so splits and dividends need no
  adjustment and show no jump.
- During a corporate action or an unscheduled closure the feed holds its value and no move is
  counted. A stop longer than 84 hours ends the series at its last values; within 84 hours of a
  stop, the frozen value is used.
- Chainlink migrates a feed by running a new aggregator beside the old one (AMZN's both published for
  nine days in August 2026) and switching the proxy at a time not recorded on chain. Pinning one
  version keeps each print independent of when it is recorded.

## 4. Running continuously

A single series cannot safely run forever:

1. A single leg can only be turned back into stock when its series ends (before that only pairs
   redeem). With no end, a lone leg's price would rest only on what traders expect, with nothing it
   converges to.
2. Leverage drifts with the price. Over months one ledger gets small, that leg becomes highly levered,
   and an ordinary gap knocks it out, which ends the series anyway.

So the product runs continuously as **back-to-back weekly series**: each one starts at Friday's close
as the previous one ends. Holders redeem the finished week and can mint into the next, which gives
them both new legs at 50/50; keeping only one side means selling the other. A one-press single-leg
roll is left out of v1 until that trade is specified. Each week needs a `createSeries` call from the
Safe, prepared by the site from the exchange calendar.

## 5. First series: a $100 live demo (Sean, 28 Oct 2026)

[`DeployAfterHours.s.sol`](../../contracts/exposure/script/DeployAfterHours.s.sol): AMZNc from Friday
30 October 16:00 to Friday 6 November 16:00 New York time, 11 prints. US clocks go back on Sunday 1
November, so Friday's close is 20:00 UTC and the following week's opens and closes are 14:30 and
21:00 UTC; no market holidays that week. Capped at 0.4 AMZNc (about $100), with a seven-day recording
window so the prices can be recorded in two sittings.

| When | Who | What |
| --- | --- | --- |
| Done 28 Oct | Sean (deployer password) | The factory owned by the Governance and Regent Safe (`0xAECE72c94CaC843f9Ecd54aC6Ca833bF4CFED048`). The first oracle deployed with it (V1, `0x6e80e0b6…5f98`) is superseded by V2 after the second review. |
| Before Fri 30 Oct 16:00 New York | Sean (deployer password) | `DeployAfterHours.run`: `ChainlinkPrintOracleV2` on the AMZN feed's current phase. |
| Before Fri 30 Oct 16:00 New York | Safe (2 of 3) | `createSeries` exactly as `firstSeriesCall` prints it, with the keccak256 of the exact bytes of the [terms](../priv/exposure_terms/0x5f67343b39277939aea7613c578fa3931b8b89da7a65eb36dd7217c81a5a2e8f.md), revised after the second review and awaiting Sean's approval. |
| Fri 30 Oct after 17:00 New York | Sean (deployer password) | With about 0.2 AMZNc and $55 USDC in the deployer: `AfterHoursDemo.recordAndSettle` (first close), then `AfterHoursDemo.seed`: mint a 0.2 AMZNc pair and open an Aerodrome pool for each leg against USDC at its ledger value. |
| Fri 6 Nov after 17:00 New York | Sean (deployer password) | `AfterHoursDemo.recordAndSettle`: the other ten prints; the series ends and every leg redeems. |

The agent prepares and starts each step; the wallet password and the funds are Sean's. The fork
rehearsal (`DeployAfterHours.fork.t.sol`) runs this whole table on a Base fork: deploy, the Safe's
call as printed, the Friday sitting with both pools opened at the right USDC amounts, and the
closing sitting through to maturity.

## 6. The site (`Autolaunch.Exposure`, built 29 October 2026)

Behind `AUTOLAUNCH_EXPOSURE=true` with `AUTOLAUNCH_BASE_EXPOSURE_DEPLOYMENT` naming the series the
site offers (`Autolaunch.Exposure.Deployment`); off, every route below is not found and nothing
advertises them. Same patterns as Covered Calls. Nothing is stored: every figure is read from the
chain at the latest block.

| Place | Purpose |
| --- | --- |
| `/stock/isolated-afters` | The newest series (`?series=<address>` for another listed one): stock, term, status, deposits against the cap, last price; each token's value, share of the stock, how much it moves in its window and its pool price; Mint and Return tabs; every applied price and the next, with Record price and Apply price; the terms and their fingerprint. |
| `/stock/isolated-afters/terms/{hash}` | A series' terms, the exact bytes whose keccak256 it holds (`platform/priv/exposure_terms`). |

Ash domain `Autolaunch.Exposure`, resource `Series` with four generic actions every surface calls:
`list`, `series`, `holdings` (the acting account's own wallet) and `prepare` (steps for `mint`,
`redeem`, `update` = record then settle, `end`). A press certain to fail from the chain's own state
(not open yet, ended, past the cap, short after a seizure, not enough stock, approval missing,
unequal amounts before the end, more than held, a price not yet recordable or too old, the
recording window still open) shows the button disabled with the reason; nothing else blocks a
press. There is no keeper job yet: anyone can record and apply a price from the page.

Agent surfaces, one Ash action each, same inputs, results and refusals everywhere
(`docs/agent-parity.md`):

| Action | WebMCP | HTTP | Hosted MCP | CLI |
| --- | --- | --- | --- | --- |
| List series | `autolaunch_after_hour_stocks_list` | `GET /api/v1/after-hour-stocks` | gap | gap |
| One series | `autolaunch_after_hour_stocks_series` | `GET /api/v1/after-hour-stocks/{series}` | gap | gap |
| My holding | `autolaunch_my_after_hour_stocks` | `GET /api/agent/v1/after-hour-stocks/{series}/holdings` (`GET /api/v1/me/after-hour-stocks/{series}` signed in) | gap | gap |
| Prepare a step (mint, redeem, update, end) | `autolaunch_after_hour_stocks_prepare` | `POST /api/agent/v1/after-hour-stocks/{series}/steps` | gap | gap |

The owner's own key signs every step; the site prepares and never signs.

## 7. Trading the legs

The vault makes pairs; it does not make a market in single legs. Each leg needs its own pool against
USDC with liquidity someone provides and can withdraw, because both legs expire and one can end at
zero. The forever-locked Memestake liquidity pattern does not fit here. Any trading fee goes to
REGENT staking through the existing `depositUSDC` path; the vault itself takes nothing.

## 8. Tests and evidence (28 October 2026)

- `contracts/exposure/bin/gate.sh` (Foundry 1.5.1): 56 checks pass.
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
  - 14 Chainlink oracle and keeper tests (the pinned phase, the round in force and its source, rounds
    superseded, later or missing, a round exactly at the moment, a quiet weekend, a proxy switch not
    changing a print, the 84-hour staleness limit and a holiday weekend, the keeper on a dead feed, the one-hour wait, record once, bad answers, the
    keeper's round search fuzzed, a series settling end to end) and 1 factory test.
  - Six deliberate bugs planted one at a time in the series (overdrawn depletion, skipped
    depletion, oversized oracle reply accepted, no seizure cut, single legs before the end, late
    print accepted): each made at least one test fail.
- Base fork (Foundry 1.8.6, `anvil --network base --fork-block-number 53209576`): 7 tests pass on the
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
   price, prints are scheduled Chainlink values that can differ from the official price, the end on a
   missing print, the blocklist point above, and that an issuer blocklist on the series itself
   would freeze every holder. The paper's SPY history is not a return claim for any stock.
