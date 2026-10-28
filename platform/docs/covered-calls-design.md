# Covered Calls — design note

**Status:** Building · 28 October 2026 · builds the product in
[yield-borrow-spec.md](yield-borrow-spec.md) ("Simple Covered Calls").
**Founder answers in force (28 Oct 14:38Z):** Base only. Weekly expiry on Friday at the US
close with a 24-hour exercise window. Seller listings with a minimum premium, filled by any
buyer. Fee 1% of premiums actually paid. No early close in v1. Corporate actions follow
Base's B20 multiplier. Physical settlement; premium and strike in USDC. Aave is not in v1.

## 1. The stock

**AMZNc** (`0xb200000000000000000000d9192b6B456483C2E8`), the deepest of the ten admitted Base
stocks by both measures below. It also pays no cash dividend: its multiplier is exactly 1.0.

Measured 28 October 2026, Base block about 53,204,600, during US market hours.

| Stock | Largest USDC pool (GeckoTerminal) | Pool size | 24h volume | Buy $25k | Buy $100k | Buy $250k |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| **AMZNc** | Aerodrome 0.087% `0x532e0f46…bddf6` | $1.85M | $6.16M | −0.10% | +0.06% | **+0.36%** |
| AAPLc | Aerodrome 0.036% `0xf5fcb9cd…46ba6` | $0.70M | $4.63M | −0.09% | +0.04% | +0.46% |
| GOOGLc | Aerodrome 0.015% `0x16c70f04…f47c3` | $0.97M | $8.32M | −0.07% | +0.13% | +0.53% |
| MSTRc | Aerodrome 0.003% `0x66dcd42e…cc153` | $0.91M | $16.29M | +0.21% | +0.44% | +0.86% |
| METAc | Aerodrome `0xd072410f…5dc96` | $0.81M | $9.82M | −0.03% | +0.21% | +1.22% |
| NVDAc | Aerodrome 0.014% `0xf668e219…3c8ec` | $0.81M | $4.79M | +0.30% | +0.60% | +1.24% |
| SPCXc | Aerodrome 0.034% `0x880db7dd…7cfe` | $0.58M | $5.89M | −0.02% | +0.26% | +1.64% |
| MSFTc | Aerodrome 0.047% `0x2740c0fa…01ee7` | $0.47M | $3.40M | +0.15% | +0.37% | +6.10% |
| SNDKc | Aerodrome 0.004% `0x2836e062…14e75` | $0.66M | $11.98M | +0.16% | +1.38% | +16.58% |
| TSLAc | Aerodrome 0.027% `0x7a330003…bf920` | $0.39M | $6.19M | +0.32% | +0.63% | +44.62% |

"Buy" is the average price paid for that many USDC of stock in the pool, against the Chainlink
price, measured by actually buying on a Base fork (`anvil --network base`, Foundry 1.8.6) and
undoing it. Pool size counts the whole pool, much of it far from the price; the buy columns are
the depth that matters. AMZN's second pool (Aerodrome 0.124%, `0xd03bc8c7…e9b`, $71k) costs
+1.37% at $25k and +201% at $100k.

**Finding for the Memestake lane:** the admitted AMZNc launch route
(`0xa851eb9bb6455b3C243B7ad0a3bAF026C76b2F4e`) swaps in that thin second pool, not the deep one.
Noted in the Autolaunch backlog; not changed here.

## 2. What Base stock tokens are, measured

Base stock tokens are B20 Asset tokens: native Rust precompiles, not contracts. Every fact
below was read from Base mainnet at block 53,204,5xx or proved on a Base fork, not taken
from documentation alone.

| Question | Finding | Evidence |
| --- | --- | --- |
| Code at the token address | One byte, `0xef`. The logic lives in the Base node. | `cast code` on Base |
| (a) Does a local fork run them? | Not with Foundry 1.5.1 (the Mac's version): every call fails with `OpcodeNotFound`. Yes with Foundry 1.8.6 and `anvil --network base`: reads, transfers, policy refusals and pauses run against live mainnet state. | fork runs below |
| Decimals | 8 for every stock checked. | `decimals()` |
| Multiplier today | AMZNc and MSTRc exactly 1.0; NVDAc 1.000538, GOOGLc 1.000377, METAc 1.000314 (dividends already folded in). No stock has a scheduled change (`effectiveAt()` is 0). | `multiplier()`, `effectiveAt()` |
| (b) Transfer rules | All three transfer scopes (sender, receiver, executor) on every stock point at one shared **blocklist**, policy 5. A fresh address, such as our contract or a new buyer, is allowed. Only a listed address is refused. | `policyId`, `policyExists`, `isAuthorized` |
| (b) A refused transfer | Reverts the whole transaction with `PolicyForbids(TRANSFER_RECEIVER_POLICY, 5)`. Nothing moves. | fork: issuer's policy admin lists an address, transfer to it reverts |
| (c) Pause | A `TRANSFER` pause stops both `transfer` and `transferFrom` with `ContractPaused(TRANSFER)`. `approve` still succeeds. Nothing is paused today. | fork: token admin grants a test pauser, pauses `TRANSFER` |
| Seizure | The issuer can seize from an address that is listed on the seize-exempt blocklist (policy 129). Our contract is exempt unless the issuer lists it. | `policyId(SEIZE_EXEMPT_POLICY)` |
| Token admin | `0x38467bE00970af18076fd08F6b4Cf38Ba91572B1` holds the admin role on AMZNc; policy 5's admin is `0xEC0F05C174e54FBf0Fe16ad930a8AFEbCe612812`. | `hasRole`, `policyAdmin` |

## 3. Corporate actions: the founder's proposal, checked

**Proposal 1. Collateral, deliverable and strike fixed in raw token units.** Agreed. The token
is total-return: its price is the share price times the multiplier, so one raw unit keeps its
value across a split (the price falls tenfold, the multiplier rises tenfold). A series needs
no adjustment for a split.

**Proposal 2. Every page shows share-equivalents.** Agreed, read through `toUIAmount` and the
current multiplier, with the token amount beside it. Today the two differ by under 0.06%.

**Proposal 3. Refuse a listing whose life overlaps a scheduled multiplier change.** Agreed and
moved into the contract, so it holds for agents calling the contract directly too. B20 exposes
the pending change on chain (`effectiveAt()`, `newUIMultiplier()`). `list` and `fill` both
refuse when a change is scheduled after now and before the exercise window closes.
An instant `updateMultiplier` mid-life cannot be refused; because units are raw, it moves the
share count, not the value, so neither side is short-changed. The risk that remains is
pricing: the Chainlink feed freezes during a corporate action, so the suggested premium is
hidden while the feed is older than its bound.

**Proposal 4. Dividends in a raw deliverable.** The choice in plain words:

- *Fixed token amount (recommended).* The seller locks, say, 10 tokens. A cash dividend during
  the week makes each token worth slightly more shares. If the buyer exercises, they get the 10
  tokens, dividend included. If they don't, the seller keeps it. A week of dividends on these
  stocks is about 0.01% of the position (NVDAc's whole multiplier drift to date is 0.05%), and
  AMZNc pays no dividend at all.
- *Fixed share amount.* The seller would lock extra tokens as a buffer and the contract would
  work out the token count at exercise. That needs a price-free buffer rule, partial refunds
  and more ways to get it wrong, to move about one cent per hundred dollars.

**Decided: fixed token amount** (Sean, 28 Oct 2026 15:13Z, "a"). The listing page says
"Dividends during the week stay with the tokens."

## 4. The contract (`contracts/covered-calls`)

Our own small Foundry project in the Greek.fi style: fully collateralized, physically
settled, no oracle, no owner and no upgrade or pause switch. One contract instance per stock;
another stock is another instance.

```solidity
constructor(address stock, address usdc, address staking)

function list(uint256 amount, uint256 strikePerToken, uint256 premiumPerToken, uint64 expiry)
    external returns (uint256 listingId);                 // pulls `amount` raw stock from the seller
function fill(uint256 listingId, uint256 amount) external;      // buyer pays the premium
function cancel(uint256 listingId) external;              // seller: unsold remainder stops selling
function exercise(uint256 listingId, uint256 amount) external;  // holder pays the strike in window
function claim(uint256 listingId) external;               // anyone: the stock it is owed
function collectStrike(uint256 listingId) external;       // seller: the strike USDC paid so far
function claimable(uint256 listingId, address account) external view returns (uint256);
```

- **Prices** are USDC (6 decimals) per whole token (`10**decimals` raw units). A fill pays
  `ceil(amount × premiumPerToken / 10**decimals)`; an exercise pays
  `ceil(amount × strikePerToken / 10**decimals)`. Rounding always favours the seller, so
  splitting a fill or an exercise never pays less.
- **Fee.** 1% (`FEE_BPS = 100`, a constant), rounded up, of each premium paid. The buyer's
  premium goes 99% to the seller and 1% into live REGENT staking through
  `depositUSDC(fee, "autolaunch-covered-calls", listingId)`, the path the Memestake hook already
  uses (fork-proven against the live contract). Nothing else is charged. Rounding up keeps the
  fee exactly 1% in the house's favour, so splitting a fill into dust never avoids it.
- **Times.** Every expiry is a Friday at 21:00 UTC, enforced by the contract
  (`expiry % 1 weeks == 1 days + 21 hours`, since Unix time began on a Thursday). That is the US
  close in winter (16:00 New York) and an hour after it in summer, so a series never expires while
  the market is open, and the contract needs no daylight-saving rule. Every surface, site, WebMCP
  and agents calling the contract directly, meets only weekly series. The exercise window is
  `[expiry, expiry + 24h)`; fills close at expiry. (Coordinator review, 28 Oct: one way on chain so
  agents cannot drift.)
- **Coverage.** Each listing holds exactly the raw stock it may deliver. Fills can never exceed
  `amount − filled`; exercise can never exceed what the caller holds; `cancel` frees only the
  unsold remainder; after the window the seller's `claim` books only `amount − exercised`, once.
- **Each call moves at most one token, and every token leaves by a pull with no deadline.**
  `cancel` and `exercise` move no stock; stock leaves only through `claim`, strike USDC only
  through `collectStrike`. A stock pause or blocklist, or a USDC pause or blacklist, on any
  account therefore only delays that account's own pull of that one token. The premium is paid
  straight to the seller at fill: if the seller cannot receive USDC, the fill fails and nobody is
  harmed.
- **Positions are not transferable** in v1: a holding is (listing, buyer). That keeps the
  contract small and needs no token approvals; transferable options can come later.
- **Events:** `Listed`, `Filled` (premium including fee, and the fee), `Cancelled` (unsold),
  `Exercised`, `StockReturned` (booked to the seller after the window), `Claimed`,
  `StrikeCollected`. The site's record is built only from them.
- **What it refuses:** an unknown listing; zero amounts; a past expiry; a scheduled multiplier
  change before the window closes; a fill after expiry or above the remainder; an exercise
  outside the window or above the holding; a cancel or claim with nothing to give; a strike
  collection or cancel by anyone but the seller.

**Known limits, accepted for v1** (from the adversarial review):

- The 24-hour window is a deadline. A holder who cannot pay USDC for the whole window (a USDC
  pause, a Circle blacklist on them, a Base outage) cannot exercise; the premium stays with the
  seller. The page states the window plainly.
- Every fill carrying a fee calls live REGENT staking. If staking refuses deposits, fills stop;
  listing, cancel, exercise, claim and strike collection never touch it.
- `list` and `fill` read `effectiveAt()` on the stock token, which answers 0 on Base mainnet today.
  If that read ever reverted, `list` and `fill` would stop until it answered again; cancel,
  exercise, claim and strike collection never read it. Raw-unit accounting means a split or a
  dividend never breaks a series anyway, so the check is a second line of defence. A fork test of
  the real read is added once Foundry's local B20 has it (Foundry 1.8.6 implements only the older
  read set).
- An instant (unscheduled) multiplier change cannot be detected. Prices are per raw unit, so the
  terms keep their value; pages show share-equivalents at the current multiplier.
- All listings draw on one balance. If the issuer blocklisted and seized from the contract
  itself, whoever claimed first would be paid. The contract is exempt from seizure unless the
  issuer lists it.

## 5. The site (`Autolaunch.CoveredCalls`)

Behind `AUTOLAUNCH_COVERED_CALLS=true` (`config :autolaunch, :covered_calls, :on`), off by default and in production. With it
off, the routes answer not found and no tool or command is advertised.

| Place | Purpose |
| --- | --- |
| `/covered-calls` | Two tabs, each its own address. **Buy**: the calls for sale with strike, premium, expiry and amount left (share-equivalents shown whenever the multiplier is not 1.0); Buy opens that listing's wallet panel under its row at `?listing=<id>`. **Sell**: one form (amount, strike, expiry from the next four Fridays, premium) beside a guide: the reference price, shares per token, suggested premiums for the next Friday at +1%, +3% and +5% strikes, the result at expiry at three prices, and the terms ("Dividends during the week stay with the tokens."). |
| `/stock-listing/:symbol` | For a stock with a market, while on, a "Covered calls on <symbol>" action. |
| `/portfolio` | A "Covered calls" section: each listing the wallet sold or holds, with the wallet steps it allows now shown directly (Stop selling, Exercise, Collect <symbol>, Collect USDC), so every button there sends. |

Ash domain `Autolaunch.CoveredCalls`:

- **No tables.** The contract is the record: `Chain` reads listings, holdings, balances and
  allowances at the latest block, so every figure matches the chain after a reload, and no
  migration is needed. (The event ledger only runs where the deployment names start blocks, and a
  new table needs Sean's go before production; reading the contract avoids both.)
- `Book` — each market's listings, read once and shared by every visitor for five minutes and
  read again soon after a confirmed press (`ChainRefresh`), as `RegentFacts` does.
- `Market` — the four operations every surface calls: `book`, `quote`, `positions`, `prepare`.
  Positions and steps are only ever for a wallet of the authenticated actor's own account.
- `Steps` — builds each wallet step (approve stock, list, approve USDC, fill, cancel, exercise,
  claim, collect strike) on the server for `AutolaunchWeb.OnchainSteps`. A press that is certain to fail
  from the chain's own state at the latest block (sold out, past expiry, no approval yet) shows
  the button disabled with the reason; nothing else blocks a press.
- `Quote` — the suggested premium: a reference price from the Chainlink feed (hidden when older
  than its bound) and a simple volatility figure, shown as a guide, never enforced.

Agent surfaces, one Ash action each, same inputs and refusals everywhere:

| Action | WebMCP | HTTP | Hosted MCP | CLI |
| --- | --- | --- | --- | --- |
| A stock's listings | `autolaunch_covered_call_listings` | `GET /api/v1/covered-calls/:symbol` | gap (Autolaunch MCP lane) | gap (regents-cli lane) |
| Suggested premium | `autolaunch_covered_call_quote` | `POST /api/v1/covered-calls/:symbol/quote` | gap (Autolaunch MCP lane) | gap (regents-cli lane) |
| My listings and holdings | `autolaunch_my_covered_calls` | `GET /api/agent/v1/covered-calls/:symbol/positions` (signed agent); `GET /api/v1/me/covered-calls/:symbol` (signed-in person) | gap (Autolaunch MCP lane) | gap (regents-cli lane) |
| Prepare a step (list, fill, cancel, exercise, claim, collect strike) | `autolaunch_covered_call_prepare` | `POST /api/agent/v1/covered-calls/:symbol/steps` | gap (Autolaunch MCP lane) | gap (regents-cli lane) |

Off, every one of these routes answers as an unknown address and the site is byte for byte what it
was before covered calls: `/openapi.json` is `contracts/api-contract.openapiv3.yaml` exactly,
`/capabilities`, the agent guides and the tools dialog leave them out, and no page, script or
stylesheet names them. Their parts sit apart and join only while on: the routes in
`contracts/covered-calls.openapiv3.yaml` (`AutolaunchWeb.PublicDocuments`), the tools in
`priv/covered_calls_tools.json` (`AutolaunchWeb.ToolManifest`, which the root layout hands the page
as `#agent-feature-tools`, so `assets/js/public_tools.ts` carries none of them), and the styles in
their own `covered_calls.css`, linked only while on. Before the site opens (prelaunch), the public
quote is taken only while covered calls are on, and preparing wallet steps stays refused like every
other wallet step.

Eligibility is said once, under the page title: "Available to eligible people outside the US." No
part of the site, the agent routes or the contract checks an address against a list or a place. The
only address checks are ownership: the site builds steps only for a wallet the signed-in account (or
the paired agent's account) links, and the contract lets only a listing's seller stop selling it or
collect its strike, so no one can withdraw another person's stock or USDC. The issuer's own blocklist
and pauses on AMZNc still apply, as they do to every transfer of it. `docs/agent-parity.md` at the repository
root has one row per action.

The agent's own key signs every step; the site prepares and never signs. CLI rows are gaps
owned by the regents-cli lane until it adds them.

## 6. Tests and evidence

- Contract (`contracts/covered-calls`, `bin/gate.sh`, passes with the Mac's Foundry 1.5.1):
  - 29 unit tests: every call and refusal, the Friday 21:00 UTC expiry rule, the spec's three
    payoff cases, rounding, the fee, self-dealing, exact window boundaries, events.
  - 9 rules tests from the review's third pass: the Friday 21:00 UTC rule recomputed from the
    calendar, the fee as ceil(1%) never above the premium, and `claimable` equal to what `claim`
    pays in every state.
  - 9 ordering tests from the review's second pass: cancel, claim and the after-window return in
    every order, never paying a unit twice or touching another listing, and `claimable`.
  - 13 recovery tests: every way a token, the issuer, Circle or staking can refuse, and a fuzzed
    many-account scenario in which everyone recovers exactly what is theirs once restrictions lift.
  - 7 invariants over random sequences of every call by four accounts across time, with all those
    restrictions switching on and off: stock held equals stock owed, USDC held equals strike
    uncollected, nothing oversold, every listed unit accounted for, no token created or lost, each
    fee paid exactly once, every claim paying exactly what `claimable` showed; and after each run
    every restriction lifts, everyone collects, and the contract ends holding nothing.
  - 7 fork tests on Base (Foundry 1.8.6, `anvil --network base`) with the real AMZNc token, Base
    USDC and live REGENT staking, staging a real blocklisting, a real transfer pause and a
    multiplier change through the issuer's own admin accounts.
- Adversarial review (independent agent, solidity-security and solidity-auditor skills): first
  pass found two medium findings, both from one call moving two tokens (a seller could not stop
  sales during a stock pause; a block on one token held up the other). Both are fixed by the
  split above; the five tests that failed on the first version are kept as lasting tests in
  `test/CoveredCallsV1.recovery.t.sol`. The fix had its own second review, and the expiry, fee and `claimable` changes a third; neither
  found anything above informational; its
  tests are kept in `test/CoveredCallsV1.ordering.t.sol`. Its main informational point, that a
  seller's `owed` figure omits the after-window return until they claim, is answered by the
  `claimable` read, which every page and tool uses.
- Site, 28 Oct 2026:
  - `test/journeys/covered_calls.spec.ts`, at 390 and 1280 against the journeys' copy of Base with
    `CoveredCallsV1` deployed: list, buy (the seller receives the premium less exactly 1%), stop
    selling, exercise while the issuer has transfers paused, a stock collection refused during
    the pause with the words shown, the strike collected during the pause, both sides' stock
    collected after it. 2 passed.
  - 27 ExUnit cases: `autolaunch/covered_calls/terms_test.exs` (four properties),
    `autolaunch/covered_calls/steps_test.exs`, `autolaunch_web/live/covered_calls_live_test.exs`,
    `autolaunch_web/controllers/covered_calls_routes_test.exs`; `public_tools_features.test.ts`.
  - The journey found one design flaw, fixed: the portfolio row's own "Stop selling" button opened
    a panel holding a second "Stop selling", so the first press sent nothing. Rows now show their
    wallet steps directly.
  - Screenshots at 390 then found the Buy panel inside a sideways-scrolling table, its buttons off
    the screen (the journey's clicks scroll, so it had passed). The panel now sits below the list
    and, on a phone, each listing is a block of labelled figures. The journey now checks every
    wallet button is wholly on screen; that check failed on the old layout ("Approve USDC", "Buy
    calls") and passes on the new.
  - The journey moved the copy's clock and so broke the Memestock auction journey run after it;
    it now restores the copy (snapshot and revert). Full journeys: 14 passed.

## 7. Open items

1. **Eligibility.** Coinbase's tokenized stocks are only for persons in eligible jurisdictions
   outside the United States. This needs Sean's own advice; customer copy says nothing beyond
   the wording he approves.
2. **Foundry for the fork suite.** The offline gate runs on the Mac's Foundry 1.5.1. The Base fork
   suite needs Foundry 1.8.4 or later, because Base stock tokens are precompiles. Base's own build
   (base-anvil) would also cover the newer `effectiveAt()` read. Installing either on the Mac
   changes the shared toolchain, so that waits for the toolchain owner.
3. **Deployment.** A contract deployment is protected and waits for Sean's go naming it.
4. **Follow-ups outside this lane.** The journeys' pinned sign-in service revision
   (`SIWA_SERVER_REV` in `scripts/agent-journeys.sh`) is no longer on GitHub, so a fresh checkout
   cannot start the journeys; the admitted Memestake AMZNc route uses the thin pool (section 1).
5. **Gaps.** Hosted MCP (`/mcp`) and the regents CLI for every covered-call action
   (`docs/agent-parity.md`); the agent route's cancel, exercise, claim and collect strike have no
   test of their own; `/covered-calls` is not in the sitemap while on.
