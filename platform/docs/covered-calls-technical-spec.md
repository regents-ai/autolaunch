# Autolaunch Covered Calls — technical specification

**Version:** 29 October 2026. **Status:** contract deployed on Base at `0x0B2FE2810F9219bDd5e5e304DC8A1A4c84eA553E` (29 October 2026, block 53,230,752). The
site code is on `main` with covered calls switched off. The CLI commands in section 8 are proposed,
not built.

**What this document is for.** A complete, self-contained description for an independent second
review: every Solidity file in full (appendices A–C), how the contract works, the security argument
and its limits, the website and agent routes, and the proposed CLI commands. Everything a reviewer
needs should be here; where a claim rests on a test or a chain read, the test or read is named.

**Repository:** `regents-ai/autolaunch`. Contract package: `contracts/covered-calls`. Site:
`platform/` (Elixir, Phoenix LiveView, Ash). Standalone CLI: `cli/`.

---

## 1. The product

Simple covered calls on one Base stock token, AMZNc (Amazon), paid in USDC.

- A **seller** who holds AMZNc locks some of it in the contract and lists it as calls: a strike
  price, a premium per token, and an expiry.
- Any **buyer** fills part or all of a listing by paying the premium in USDC, now. The seller gets
  the premium at once, less a 1% fee that goes to REGENT stakers.
- During the **24 hours after expiry**, a holder may **exercise**: pay the strike in USDC and take
  the stock. The seller collects that strike USDC.
- After the window, the seller takes back every token that was not exercised.

Decisions in force (Sean, 28 October 2026):

| Topic | Decision |
| --- | --- |
| Chain | Base only (chain 8453). |
| Stock | AMZNc, `0xb200000000000000000000d9192b6B456483C2E8` — the deepest of the ten Base stocks measured. |
| Expiry | Weekly, Friday 21:00 UTC (the US close in winter, an hour after it in summer), enforced on chain. |
| Exercise | A 24-hour window starting at expiry: `[expiry, expiry + 24h)`. |
| Market | Sellers list with a fixed premium (their minimum); any buyer fills. No order book, no auction. |
| Fee | 1% of each premium actually paid, rounded up, deposited into live REGENT staking. Nothing else. |
| Early close | None in v1: a listing's unsold part can be withdrawn ("stop selling"); sold calls stay to expiry. |
| Settlement | Physical: the holder pays the strike and receives the stock. Premium and strike are USDC. |
| Corporate actions | Amounts are raw token units. Base's B20 multiplier handles splits and dividends; a listing may not span a scheduled change. Dividends during the week stay with the tokens (Sean, "a"). |
| Who may use it | "Available to eligible people outside the US." shown once, under the page title. No wallet gating anywhere: no allowlist, no geofence. Only the token issuer's own on-chain blocklist and pauses can refuse a transfer. |
| Positions | Not transferable in v1: a holding is (listing, buyer address). |

## 2. Base stock tokens (B20), as measured

Base stock tokens are **B20 Asset tokens**: native precompiles in the Base node, not contracts. The
code at the token address is one byte, `0xef`. Facts below were read from Base mainnet or proved on
a Base fork, not taken from documentation alone.

| Property | Finding |
| --- | --- |
| Interface | ERC-20 (`transfer`, `transferFrom`, `approve`, `balanceOf`, `allowance`, `decimals`), plus `multiplier()` and ERC-8056 reads such as `effectiveAt()` (when a scheduled multiplier change takes effect; 0 when none is pending). |
| Decimals | 8. One whole token is `1e8` raw units. |
| Multiplier | AMZNc is exactly 1.0 today; `effectiveAt()` is 0 (nothing scheduled). A split or dividend changes the multiplier, so one raw unit keeps its value: it is a total-return token. |
| Transfer rules | All three transfer scopes (sender, receiver, executor) use one shared blocklist (policy 5). A fresh address — our contract, a new buyer — is allowed; only a listed address is refused, and a refused transfer reverts the whole transaction. |
| Pause | The issuer can pause `TRANSFER`, which stops `transfer` and `transferFrom` (not `approve`). |
| Seizure | The issuer can seize from an address that is not on the seize-exempt list (policy 129). |
| Return values | Standard: `transfer`/`transferFrom` return true or revert. No fee on transfer, no rebasing of raw balances. |
| Tooling | Foundry 1.5.1 cannot execute B20 calls (`OpcodeNotFound`). Foundry 1.8.4+ with `--network base` runs them on a local fork, but only the older ("Beryl") read set: `effectiveAt()` reverts locally although it answers on mainnet, so fork tests stand in its live value (0). |

USDC on Base: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (6 decimals; Circle can pause and blacklist).

## 3. The contract: `CoveredCallsV1`

Full source: appendix A. Solidity 0.8.26, solady (`ReentrancyGuard`, `SafeTransferLib`,
`FixedPointMathLib`). About 265 lines. One instance per stock.

### 3.1 What it is not

No owner, admin, pauser, upgrade, proxy, oracle, `delegatecall`, `selfdestruct` or `tx.origin`. No
function changes any parameter after deployment. The runtime bytecode contains only `CALL` (to the
two tokens and to staking) and one `STATICCALL` (`effectiveAt`) — no `DELEGATECALL`, `CALLCODE`,
`CREATE` or `SELFDESTRUCT` (checked on the compiled runtime by the independent reviewer).

### 3.2 Immutable configuration

| Name | Value | Meaning |
| --- | --- | --- |
| `stock` | AMZNc | The stock token. |
| `usdc` | Base USDC | Premium, strike and fee currency. |
| `staking` | `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5` | Live REGENT staking; receives the fee via `depositUSDC`. |
| `unit` | `10 ** stock.decimals()` = `1e8` | Raw units per whole token, read once in the constructor. |
| `FEE_BPS` | 100 | 1% of each premium. |
| `EXERCISE_WINDOW` | 1 day | Exercise is allowed in `[expiry, expiry + 1 day)`. |
| `WEEKLY_EXPIRY_OFFSET` | 1 day 21 hours | `expiry % 1 weeks` must equal this: Friday 21:00 UTC (Unix time began on a Thursday). |
| `FEE_SOURCE_TAG` | `bytes32("autolaunch-covered-calls")` | Tag on every fee deposit. |

### 3.3 State

```solidity
struct Listing {
    address seller;        // who listed; nonzero for every real listing
    uint64  expiry;        // a Friday 21:00 UTC
    bool    stockReturned; // the seller's after-window return has been booked
    uint256 amount;        // raw stock locked for this listing (lowered by cancel to `filled`)
    uint256 filled;        // raw stock sold as calls
    uint256 exercised;     // raw stock exercised
    uint256 strikePerToken;   // USDC (6 dp) per whole token
    uint256 premiumPerToken;  // USDC (6 dp) per whole token
    uint256 strikePaid;       // strike USDC paid in by holders
    uint256 strikeCollected;  // strike USDC already sent to the seller
}
uint256 public listingCount;                    // ids count from 1
mapping(uint256 => Listing) internal _listings;
mapping(uint256 => mapping(address => uint256)) public held; // calls a buyer may still exercise
mapping(uint256 => mapping(address => uint256)) public owed; // stock an account may claim now
```

### 3.4 Functions

All state-changing functions are `nonReentrant`, update state and emit their event before any
token call (checks–effects–interactions), and move at most one token.

| Function | Who | Checks | Effects | Tokens moved |
| --- | --- | --- | --- | --- |
| `list(amount, strikePerToken, premiumPerToken, expiry)` | anyone holding stock | all three > 0; `expiry % 1 weeks == WEEKLY_EXPIRY_OFFSET`; `expiry > now`; no scheduled multiplier change before the window closes | new listing id `++listingCount`; `Listed` | stock: seller → contract, `amount` |
| `fill(listingId, amount)` | any buyer | listing exists; `amount > 0`; `now < expiry`; `amount ≤ amount − filled`; no scheduled multiplier change before the window closes | `filled += amount`; `held[id][buyer] += amount`; `Filled` | USDC only: buyer → seller `premium − fee`; buyer → contract `fee`; contract approves staking `fee`; staking pulls `fee` via `depositUSDC`, which must report receiving exactly `fee` |
| `cancel(listingId)` | seller only | there is an unsold part and the stock was not returned | `amount = filled`; `owed[id][seller] += unsold`; `Cancelled` | none |
| `exercise(listingId, amount)` | a holder | `expiry ≤ now < expiry + 1 day`; `0 < amount ≤ held` | `held −= amount`; `owed[id][holder] += amount`; `exercised += amount`; `strikePaid += strike`; `Exercised` | USDC: holder → contract, `strike` |
| `claim(listingId)` | anyone owed stock | something is owed (for the seller after the window, the unexercised stock is booked first, once) | for the seller after the window and not yet returned: `stockReturned = true`, `owed[id][seller] += amount − exercised`, `StockReturned`; then `owed = 0`, `Claimed` | stock: contract → caller, all owed |
| `collectStrike(listingId)` | seller only | `strikePaid − strikeCollected > 0` | `strikeCollected = strikePaid`; `StrikeCollected` | USDC: contract → seller |

Views: `claimable(id, account)` (exactly what `claim` would pay now, including the seller's
after-window return before it is booked), `premiumFor(id, amount)`, `strikeFor(id, amount)`,
`listings(id)`, `held`, `owed`, `listingCount`.

### 3.5 Arithmetic

- `premium = ceil(amount × premiumPerToken / unit)` and `strike = ceil(amount × strikePerToken / unit)`
  (solady `mulDivUp`, which reverts if `x × y` overflows 256 bits; with 8-decimal amounts and 6-decimal prices that needs values far beyond any supply). Rounding always favours the seller,
  so splitting one fill or exercise into many small ones never pays less in total.
- `fee = ceil(premium × 100 / 10_000)`; the seller receives `premium − fee`. Since `premium ≥ 1`
  for any nonzero fill (a nonzero amount and price round up to at least 1), `fee ≥ 1` and
  `fee ≤ premium`; splitting a fill into dust never avoids the fee.
- All counters are `uint256` with 0.8 checked arithmetic; `amount − filled`, `amount − exercised`
  and `strikePaid − strikeCollected` cannot underflow by construction (section 4.2).

### 3.6 Lifecycle

```
            list            fill (any buyer, until expiry)
  seller ─────────► OPEN ───────────────────────────────► SOLD OUT
                     │  cancel (seller): unsold part → owed[seller]
                     ▼
   ─────────────── expiry (Friday 21:00 UTC) ───────────────
   EXERCISE WINDOW, 24h: holders exercise (pay strike, stock → owed[holder])
   seller may collectStrike at any time for strike paid so far
   ─────────────── expiry + 24h ───────────────
   CLOSED: seller's claim books amount − exercised once; everyone claims what they are owed
```

Every pull (`claim`, `collectStrike`) has no deadline.

### 3.7 Events

`Listed`, `Filled` (premium including fee, and the fee), `Cancelled` (unsold), `Exercised`,
`StockReturned`, `Claimed`, `StrikeCollected`. The site does not keep its own records; it reads the
contract's state at the latest block.

### 3.8 Errors

`ZeroAddress`, `ZeroAmount`, `ExpiryPassed`, `NotAWeeklyExpiry`, `CorporateActionScheduled`,
`UnknownListing`, `NotSeller`, `FillsClosed`, `ExceedsAvailable`, `OutsideExerciseWindow`,
`NothingToCollect`, `DepositMismatch`.

## 4. Why it should be safe

### 4.1 Threat model

Actors: sellers, buyers/holders, arbitrary third parties, MEV searchers, the stock issuer (pause,
blocklist, seize, multiplier change), Circle (USDC pause/blacklist), the REGENT staking contract
(owned by the Regent Safe; can be paused), and Base itself (sequencer timing). Assets at risk:
locked stock, strike USDC waiting for the seller, and the fee.

### 4.2 Solvency invariants (proved by the invariant suite)

The contract's balances always equal what it owes:

1. **Stock held equals stock owed:** `stock.balanceOf(this)` equals every raw unit listed and not yet
   claimed. Each listed unit is in exactly one place: unsold and still selling, held by a buyer
   (exercisable, or due back to the seller after the window), owed to an account, or claimed.
2. **USDC:** `usdc.balanceOf(this) = Σ (strikePaid − strikeCollected)`. Premiums and fees never rest
   in the contract: the premium goes straight to the seller and the fee is pulled by staking in the
   same call (`DepositMismatch` reverts the fill otherwise).
3. **No overselling:** `filled ≤ amount` and `exercised ≤ filled` for every listing; `Σ held ≤ filled`.
4. **Each unit pays once:** `cancel` moves only `amount − filled` and lowers `amount` to `filled`, so it
   cannot repeat; the seller's after-window return books `amount − exercised` exactly once
   (`stockReturned`); `claim` zeroes `owed` before transferring.
5. **The fee is paid exactly once per fill, and equals `ceil(1%)`.**
6. **`claimable` equals what `claim` pays,** in every state.
7. After every random run, when all restrictions are lifted, everyone collects everything and the
   contract ends holding zero stock and zero USDC.

These run as Foundry invariants over random sequences of every call by four accounts across time,
with token pauses, blocklists, USDC blacklisting and staking failures switching on and off
(`test/CoveredCallsV1.invariant.t.sol`, appendix C).

### 4.3 Attack and failure analysis

| Concern | Why it is handled |
| --- | --- |
| **Reentrancy** | Every state-changing function is `nonReentrant`, and state plus events are written before any external call. B20 and USDC have no transfer hooks; the only callback-capable callee is staking's `depositUSDC`, which runs after all state is final and inside the guard. |
| **Someone else's funds** | Stock leaves only by `claim`, paying only `owed[id][msg.sender]` (plus, for the seller after the window, the unexercised remainder of their own listing). Strike USDC leaves only by `collectStrike`, seller only. No function sends to an address other than `msg.sender`, except the premium sent to the listing's own seller during a fill. |
| **Ownership checks** | `cancel` and `collectStrike` are seller-only; `exercise` is limited to the caller's own `held`. These are the only address checks; there is no allowlist. |
| **Rounding theft** | All USDC amounts round up in the seller's favour; the fee rounds up in staking's favour. A buyer splitting fills or exercises into dust pays more, never less (`test/CoveredCallsV1.rules.t.sol`). |
| **Overflow** | 0.8 checked arithmetic; `mulDivUp` reverts on overflow. A price so large it overflows simply cannot be filled — the seller's own choice. |
| **Fake or zero listing** | `_listing` reverts `UnknownListing` for any id whose seller is zero; ids start at 1. |
| **Expiry games** | Only Friday 21:00 UTC expiries in the future can be listed. Fills close at expiry; exercise is `[expiry, expiry + 1 day)`, boundaries tested exactly. Base block times are set by the sequencer; a timestamp shift of seconds only moves who is inside a 24-hour window by seconds. |
| **Front-running / MEV** | Prices are fixed by the seller; there is no oracle and no price to manipulate. A buyer front-run on the last units gets `ExceedsAvailable` and pays nothing. A seller cannot change terms after listing (no edit function), so a buyer is never surprised. A seller could `cancel` the unsold part just before a fill lands — the fill then reverts and moves nothing. |
| **Self-dealing** | A seller filling their own listing pays the 1% fee and nothing else changes hands; tested. |
| **Issuer pauses stock transfers** | `cancel`, `exercise` and `collectStrike` move no stock and still work. `claim` reverts until the pause lifts; the owed amount stays booked, with no deadline. Proven on a Base fork with the issuer's real admin role. |
| **Issuer blocklists one account** | Only that account's own `claim` (or `list`) fails. Everyone else is unaffected; the seller still collects strike. Fork-proven. |
| **Issuer seizes from the contract** | Not possible unless the issuer adds the contract to the seize-exempt policy's list. If it did, all listings share one balance, so whoever claims first is paid. Accepted; noted as a known limit. |
| **Circle pauses USDC or blacklists an account** | Fills and exercises stop while USDC cannot move; stock claims and seller strike collection on other accounts are unaffected. A blacklisted seller cannot receive a premium, so fills on their listing revert and nobody loses. A holder who cannot pay USDC during the whole 24-hour window cannot exercise — accepted limit, stated on the page. |
| **Staking refuses deposits** | Fills stop (they revert, nothing moves). Listing, cancel, exercise, claim and strike collection never touch staking. The contract approves staking for exactly `fee` and requires `depositUSDC` to report receiving exactly `fee`. |
| **Corporate actions** | Amounts are raw units, so a split or dividend never breaks a listing: the holder still receives exactly the locked raw units, now worth the same in value. A scheduled change (`effectiveAt` in the future and before the window closes) makes `list` and `fill` revert, so no new exposure is opened across it. An instant change cannot be detected, but raw-unit accounting keeps it value-neutral. If `effectiveAt()` itself ever reverted, `list` and `fill` would stop while it did; nothing else calls it. |
| **Approvals** | The site always asks for an exact approval (the exact stock amount, or the exact USDC premium/strike), never unlimited. The contract never holds an approval from users beyond what they grant. |
| **Griefing with many listings** | Listings are independent; nothing iterates over them on chain. |
| **Deployment** | Created through the deterministic CREATE2 deployer: the address depends only on the code and arguments, never on the sender; the sender gains no power. |

### 4.4 Known limits accepted for v1

1. The exercise window is a 24-hour deadline. A holder who cannot pay USDC for the whole window
   (USDC paused, blacklisted, Base down) loses the chance to exercise; the premium stays with the
   seller.
2. Fills depend on live REGENT staking accepting deposits.
3. `list` and `fill` depend on `effectiveAt()` answering.
4. All listings share one stock balance; issuer seizure from the contract (if the issuer ever made
   the contract seizable) would hit whoever claims last.
5. Positions are not transferable.

### 4.5 How it was checked

- **Offline gate** (`bin/gate.sh`, Foundry 1.5.1): `forge fmt --check`, build, and 67 tests —
  29 unit, 9 rules, 9 ordering, 13 recovery (every way a token, the issuer, Circle or staking can
  refuse, plus a fuzzed many-account recovery), 7 invariants (512 fuzz runs, 256 invariant runs ×
  depth 128).
- **Base fork suite** (Foundry 1.8.6, `anvil --network base`): 7 tests with the real AMZNc token,
  Base USDC and live REGENT staking, staging a real blocklisting, a real transfer pause and a
  multiplier change through the issuer's own admin accounts.
- **Three adversarial reviews** (independent agents with solidity-security and solidity-auditor
  playbooks). The first found two medium issues, both from one call moving two tokens (a seller
  could not stop sales during a stock pause; a block on one token held up the other). Fixed by
  splitting every movement into its own pull (`claim`, `collectStrike`); the five tests that failed
  on the first version are kept. The second and third reviews (of the fix, and of expiry, fee and
  `claimable` changes) found nothing above informational.
- **Deploy packet review**: an independent reviewer re-derived every constructor argument from the
  repository's records and live Base reads, rebuilt the creation code three ways (Foundry 1.5.1,
  1.8.6, bare solc with standard JSON), recomputed the salt, address and runtime code hash, and
  found the packet correct. The deploy script had its own review (correct; every guard fires on a
  bad input).

## 5. Deployment

| Item | Value |
| --- | --- |
| Source commit | `bc185c65033ce0c3e72c6fedc21986af4c41438a` |
| Compiler | solc 0.8.26+commit.8a97fa7a, optimizer 200 runs, via-IR, Cancun, no metadata hash, no CBOR |
| Creation code keccak | `0x44d79e5cb60f03b989fa1226fc73a6cff447b60c4b68a3a3264ff799d2ba85c7` |
| Constructor | `(AMZNc, USDC, live REGENT staking)` as in section 3.2 |
| Init code keccak | `0x758462a26cd2e9dc152f89f2c13a335f9255ec811669b94b137ee0c145b24fc2` |
| CREATE2 deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` (the standard deterministic deployer, present on Base) |
| Salt | `keccak256("autolaunch.covered-calls.v1.AMZNc")` = `0x52a9b8f155c1895a8412c0e70f3d431bfc366613b5e2c5d634d227071af13345` |
| Address | **`0x0B2FE2810F9219bDd5e5e304DC8A1A4c84eA553E`** |
| Runtime code keccak | `0x44cf180fcad6f5e1bc1c2e68df260394526edbafc67687ffab49d820fbb5448e` |
| Gas | 1,083,828 (rehearsal and live) |
| Deployed | Block 53,230,752, transaction `0xaa52f5ca91f01533779514b78011ba20e65fd1f0bf6477a2d936aa57a4d6ba3a`, sent from `0x9b2C414614aEE294202c1219520955EF3B596031` |

Sent with `script/DeployCoveredCallsAMZNc.s.sol` (appendix B) from the founder's own terminal and
keystore. Before sending it requires chain 8453, empty code at the address and the packet's init
code; in forge's run-through it then requires the predicted address, runtime code hash and all six
reads. A second run refuses with `AlreadyDeployed`. It needs Foundry ≥ 1.8.4 with `--network base`
because the constructor reads the B20 token's `decimals()`.

Rehearsal (`deploy/rehearse.sh`): on a local Base fork, the script with `--broadcast` sends one
transaction whose recipient, value and data equal the packet's byte for byte; the contract lands at
the predicted address with the promised code and reads; then a whole life (list, buy, exercise,
collect stock, collect strike) runs with real AMZNc and USDC and the 1% fee lands in staking.

## 6. The website

Covered calls sit behind a switch: `AUTOLAUNCH_COVERED_CALLS=true` plus
`AUTOLAUNCH_BASE_COVERED_CALLS_DEPLOYMENT` (a JSON file naming each market's stock, contract and
Chainlink feed). Off — as in production today — the site is byte for byte what it was before:
every covered-call route answers as an unknown address, `/openapi.json` is the base API contract
exactly, and no page, script, stylesheet, agent guide or tool names covered calls. Lasting tests
hold this (`CoveredCallsOffTest`, browser walk `switched_off.spec.ts`).

### 6.1 Pages

| Address | What it shows |
| --- | --- |
| `/covered-calls` | Title "Covered calls on AMZNc", then "Available to eligible people outside the US." A strip of the market's figures (price, next window, for sale, fee), three steps for the tab's side, then two tabs, each its own address. **Sell** (`/covered-calls`, first and the default): amount, strike, exercise window (the next four Fridays), premium; beside it the guide (the result for the trade typed, suggested premiums with Use, the estimate's basis and the terms, folded). **Buy** (`?tab=buy`, with how many are for sale): calls for sale, with strike, premium, exercise window and amount left; a listing's Buy panel opens under its row at `?listing=<id>`. A Contract section at the foot links the verified code on Basescan. |
| `/stock-listing/AMZNc` | While on: a "Covered calls on AMZNc" action. |
| `/portfolio` | A "Covered calls" section: each listing the signed-in wallet sold or holds, with the wallet steps it allows now (Stop selling, Exercise, Collect AMZNc, Collect USDC). |

### 6.2 How a press works (wallet steps)

Each panel works as the token page's Stake and Claim do. Its button (List calls, Buy calls,
Exercise, Stop selling, Collect AMZNc, Collect USDC) reviews the form as it stands: the server
builds every wallet step from the chain at the latest block, and the review opens over the form
with the steps, one wallet button at a time ("Approve USDC", then "Confirm purchase"), showing
"Confirm in wallet" while the wallet has the press. The browser only sends what the server built,
from the person's own wallet (Privy). Approvals are always their own step and exact; one the chain
already holds shows as done. Every press of the wallet button reaches the wallet, and a sent step
moves the button on at once. When the chain confirms the last step the review closes and the page
says what moved. The panel's button is disabled only when the action is certain to fail from the
chain's own state, with the reason beside it:

| Action | Steps | Disabled when (from the chain) |
| --- | --- | --- |
| List | approve exact stock → `list` | a corporate action is scheduled; not enough stock |
| Buy | approve exact USDC → `fill` | fills closed; sold out; not enough USDC |
| Exercise | approve exact USDC → `exercise` | outside the window; more than held; not enough USDC |
| Stop selling | `cancel` | not the seller; nothing left to cancel |
| Collect AMZNc | `claim` | nothing to claim |
| Collect USDC | `collectStrike` | not the seller; nothing to collect |

A review the panel cannot build (the chain unreadable just then, or an amount that does not read)
says why under the button and opens nothing: never a silent press.

### 6.3 Server modules (Ash domain `Autolaunch.CoveredCalls`)

| Module | Role |
| --- | --- |
| `Deployment` | Whether covered calls are on; the markets file. |
| `Chain` | Reads listings, holdings, `claimable`, balances, allowances, multiplier, `effectiveAt` and the Chainlink price at one block. |
| `Book` | Each market's listings, read once and shared by every visitor for five minutes, re-read ten seconds after any landed press. Never disables a button. |
| `Positions` | One wallet's sold listings and holdings, read fresh. |
| `Quote` | Suggested premium: Black-Scholes with a fixed 30% yearly volatility and no interest, from the Chainlink price, counted to the close of the exercise window; hidden when the price is older than four days. A guide only; never enforced. |
| `Steps` | Builds the wallet steps of section 6.2. |
| `Signer` | The wallet a read or step is for: only one of the acting account's own linked wallets. |
| `Market` | The four operations every surface calls (`book`, `quote`, `positions`, `prepare`), with Ash policies. |

There are no database tables: the contract is the record.

### 6.4 HTTP routes

| Method and path | Who | Purpose |
| --- | --- | --- |
| `GET /api/v1/covered-calls/{symbol}` | public | The market's listings with stage and amount left. |
| `POST /api/v1/covered-calls/{symbol}/quote` | public | Body `{strike_per_token, expiry}`; returns the reference price and suggested premium. |
| `GET /api/v1/me/covered-calls/{symbol}` | signed-in person | Their own wallet's listings and holdings. |
| `GET /api/agent/v1/covered-calls/{symbol}/positions` | paired agent (SIWA-signed) | The paired person's listings and holdings. |
| `POST /api/agent/v1/covered-calls/{symbol}/steps` | paired agent (SIWA-signed) | Body `{kind, listing_id?, amount?, strike_per_token?, premium_per_token?, expiry?, signer?}`, `kind` one of `list`, `fill`, `cancel`, `exercise`, `claim`, `collect_strike`; returns unsigned transactions for a wallet of the paired person's account, and `blocked` with the reason when certain to fail. The site never signs. |
| `GET /assets/js/covered_calls.css` | public | The page's styles, served only while on. |

Units in every route: stock amounts in raw units (1e8 per token), USDC in 6-decimal integers,
`expiry` in Unix seconds (a Friday 21:00 UTC). Full schemas: appendix D.

### 6.5 Agent tools (WebMCP, in the browser)

`autolaunch_covered_call_listings`, `autolaunch_covered_call_quote`, `autolaunch_my_covered_calls`,
`autolaunch_covered_call_prepare` (signed through the site's `prepare_agent_request`). The page is
handed these only while covered calls are on (appendix E). Hosted MCP: not yet.

### 6.6 Before the site opens (prelaunch)

While the site is in its preview state, the public book and quote answer; preparing any wallet step
— covered calls included — is refused like every other wallet step.

## 7. Evidence for the site

- 271 server checks (ExUnit: 247 tests and 24 property tests), 14 browser-script tests, 19 browser-walk
  checks (phone and desktop width): `make check-platform`, passing.
- End-to-end journey on a local Base copy with the contract deployed, at phone and desktop width:
  list, buy (seller receives the premium less exactly 1%), stop selling, exercise while the issuer
  has transfers paused, a stock collection refused during the pause with the words shown, the strike
  collected during the pause, both sides' stock collected after it. The buyer is a fresh random
  wallet each run, never seen and never paired.

## 8. CLI: proposed commands

Two CLIs read this site:

- `autolaunch` (this repository's `cli/`, standalone, public reads only, no account), and
- `regents autolaunch …` (the unified Regents CLI, built from this repository's
  `cli/commands.json`; signed commands carry a per-request SIWA proof for audience `autolaunch` and
  need a current pairing).

Existing rule kept: **no CLI command signs a wallet transaction.** The prepare command returns
unsigned transactions; the agent sends them with its own wallet tooling.

| Command | CLI | Authority | Route | Flags |
| --- | --- | --- | --- | --- |
| `covered-calls book <symbol>` | both | public | `GET /api/v1/covered-calls/{symbol}` | — |
| `covered-calls quote <symbol>` | both | public | `POST /api/v1/covered-calls/{symbol}/quote` | `--strike` (USDC per token, decimal), `--expiry` (a Friday, `YYYY-MM-DD`, or Unix seconds) |
| `covered-calls positions <symbol>` | `regents autolaunch` | signed, paired | `GET /api/agent/v1/covered-calls/{symbol}/positions` | — |
| `covered-calls prepare <symbol>` | `regents autolaunch` | signed, paired | `POST /api/agent/v1/covered-calls/{symbol}/steps` | `--kind` (`list`, `fill`, `cancel`, `exercise`, `claim`, `collect_strike`), `--listing`, `--amount` (tokens, decimal), `--strike`, `--premium`, `--expiry`, `--signer` (one of the person's own wallets) |

Behaviour, matching the existing commands:

- JSON on stdout: `{"ok": true, "status": 200, "body": {...}}`; HTTP refusals keep `error.code`,
  `message` and `hint`; exit codes 0 success, 1 HTTP/network failure, 2 invalid input.
- Decimal flags are converted exactly to the API's integers (tokens × 1e8, USDC × 1e6); a value with
  more decimals than the unit allows is invalid input, never rounded.
- `prepare` prints each step (`to`, `data`, `value`, `chain_id`, a plain label such as "Approve
  USDC" or "Buy calls") and `blocked` with its reason. Every step is for the person's own wallet;
  the server refuses any other.
- Each entry goes into `cli/commands.json` with its `operation_id`, `webmcp` tool name, method, path,
  authority and flags, so the parity check (`cli/test/parity.test.js`) holds the CLI, WebMCP and
  OpenAPI to the same operations. The commands appear only once covered calls are switched on in
  production.

Open question for the regents-cli owner: whether `regents` should later gain a separate,
explicitly-confirmed send step for prepared transactions. Today's rule (never sign) is kept here.

## 9. Open items

1. Deployment: done on 29 October 2026 (section 5). Source verified on Basescan (exact match) and Sourcify.
2. Switching covered calls on in production is a separate release after deployment, with the
   deployed address in the markets file.
3. Hosted MCP tools and the CLI commands above are not built.
4. The agent route's cancel, exercise, claim and collect-strike steps share the tested steps module
   but have no route test of their own.
5. A fork test of the real `effectiveAt()` read once Foundry's local B20 supports it.
6. Separate finding for the Memestake lane: the admitted AMZNc launch route swaps in a thin pool.

---

## Appendix A — contract source (complete)

### `contracts/covered-calls/src/CoveredCallsV1.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IB20AssetMinimal} from "./interfaces/IB20AssetMinimal.sol";
import {IRegentRevenueStakingMinimal} from "./interfaces/IRegentRevenueStakingMinimal.sol";

/// @title CoveredCallsV1
/// @notice Fully collateralized, physically settled covered calls on one Base stock token, paid in
///         USDC. A seller locks stock and lists it with a strike, a premium and an expiry; any buyer
///         fills part or all of it by paying the premium; during the 24 hours after expiry a holder
///         may pay the strike to take the stock; afterwards the seller takes back what was not
///         exercised. There is no owner, oracle, upgrade or pause.
/// @dev Amounts of stock are raw B20 units, so a split or a dividend (a multiplier change) never
///      changes what a listing holds or owes. Prices are USDC per whole token (10**decimals raw
///      units) and every USDC amount rounds up, in the seller's favour. Each call moves at most one
///      token, and stock only ever leaves through `claim` and USDC strike through `collectStrike`,
///      both pulls by their own party with no deadline. So a pause or blocklist on one token, or on
///      one party, only ever delays that party's own pull of that token: `cancel` and `exercise`
///      move no stock, and nothing a seller is owed in USDC waits on the stock, or the reverse.
contract CoveredCallsV1 is ReentrancyGuard {
    using SafeTransferLib for address;

    /// @notice The share of each premium paid that goes to REGENT staking, in basis points.
    uint256 public constant FEE_BPS = 100;
    /// @notice How long after expiry a holder may exercise.
    uint256 public constant EXERCISE_WINDOW = 1 days;
    /// @notice Every expiry is a Friday at 21:00 UTC: the US close in winter and an hour after it in
    ///         summer, so a series never expires while the market is open. Unix time began on a
    ///         Thursday, so that is 1 day 21 hours into a week counted from the epoch.
    uint256 public constant WEEKLY_EXPIRY_OFFSET = 1 days + 21 hours;
    /// @notice The tag every fee deposit carries in REGENT staking's events.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant FEE_SOURCE_TAG = bytes32("autolaunch-covered-calls");

    address public immutable stock;
    address public immutable usdc;
    address public immutable staking;
    /// @notice Raw units in one whole stock token.
    uint256 public immutable unit;

    struct Listing {
        address seller;
        uint64 expiry;
        bool stockReturned;
        uint256 amount;
        uint256 filled;
        uint256 exercised;
        uint256 strikePerToken;
        uint256 premiumPerToken;
        uint256 strikePaid;
        uint256 strikeCollected;
    }

    uint256 public listingCount;
    mapping(uint256 listingId => Listing) internal _listings;
    /// @notice Stock a buyer may still exercise, by listing.
    mapping(uint256 listingId => mapping(address holder => uint256)) public held;
    /// @notice Stock an account may `claim` from a listing: a holder's exercised stock, and the
    ///         seller's cancelled remainder and, once booked after the window, unexercised stock.
    mapping(uint256 listingId => mapping(address holder => uint256)) public owed;

    event Listed(
        uint256 indexed listingId,
        address indexed seller,
        uint256 amount,
        uint256 strikePerToken,
        uint256 premiumPerToken,
        uint64 expiry
    );
    event Filled(uint256 indexed listingId, address indexed buyer, uint256 amount, uint256 premium, uint256 fee);
    /// @notice The unsold remainder stopped selling and became the seller's to claim.
    event Cancelled(uint256 indexed listingId, uint256 unsold);
    event Exercised(uint256 indexed listingId, address indexed holder, uint256 amount, uint256 strike);
    /// @notice After the window, the stock not exercised became the seller's to claim.
    event StockReturned(uint256 indexed listingId, uint256 amount);
    event Claimed(uint256 indexed listingId, address indexed account, uint256 amount);
    event StrikeCollected(uint256 indexed listingId, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error ExpiryPassed(uint64 expiry);
    error NotAWeeklyExpiry(uint64 expiry);
    error CorporateActionScheduled(uint256 effectiveAt);
    error UnknownListing(uint256 listingId);
    error NotSeller(address caller);
    error FillsClosed(uint64 expiry);
    error ExceedsAvailable(uint256 requested, uint256 available);
    error OutsideExerciseWindow(uint64 expiry);
    error NothingToCollect();
    error DepositMismatch(uint256 expected, uint256 received);

    constructor(address stock_, address usdc_, address staking_) {
        if (stock_ == address(0) || usdc_ == address(0) || staking_ == address(0)) revert ZeroAddress();
        stock = stock_;
        usdc = usdc_;
        staking = staking_;
        unit = 10 ** IB20AssetMinimal(stock_).decimals();
    }

    /// @notice Locks `amount` raw stock from the caller and lists it as calls.
    function list(uint256 amount, uint256 strikePerToken, uint256 premiumPerToken, uint64 expiry)
        external
        nonReentrant
        returns (uint256 listingId)
    {
        if (amount == 0 || strikePerToken == 0 || premiumPerToken == 0) revert ZeroAmount();
        if (expiry % 1 weeks != WEEKLY_EXPIRY_OFFSET) revert NotAWeeklyExpiry(expiry);
        if (expiry <= block.timestamp) revert ExpiryPassed(expiry);
        _requireNoCorporateActionBefore(expiry);

        listingId = ++listingCount;
        _listings[listingId] = Listing({
            seller: msg.sender,
            expiry: expiry,
            stockReturned: false,
            amount: amount,
            filled: 0,
            exercised: 0,
            strikePerToken: strikePerToken,
            premiumPerToken: premiumPerToken,
            strikePaid: 0,
            strikeCollected: 0
        });
        emit Listed(listingId, msg.sender, amount, strikePerToken, premiumPerToken, expiry);

        stock.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Buys `amount` raw stock's worth of calls from a listing, paying its premium now.
    function fill(uint256 listingId, uint256 amount) external nonReentrant {
        Listing storage listing = _listing(listingId);
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp >= listing.expiry) revert FillsClosed(listing.expiry);
        uint256 available = listing.amount - listing.filled;
        if (amount > available) revert ExceedsAvailable(amount, available);
        _requireNoCorporateActionBefore(listing.expiry);

        uint256 premium = premiumFor(listingId, amount);
        uint256 fee = FixedPointMathLib.mulDivUp(premium, FEE_BPS, 10_000);
        listing.filled += amount;
        held[listingId][msg.sender] += amount;
        emit Filled(listingId, msg.sender, amount, premium, fee);

        usdc.safeTransferFrom(msg.sender, listing.seller, premium - fee);
        if (fee != 0) {
            usdc.safeTransferFrom(msg.sender, address(this), fee);
            usdc.safeApprove(staking, fee);
            uint256 received =
                IRegentRevenueStakingMinimal(staking).depositUSDC(fee, FEE_SOURCE_TAG, bytes32(listingId));
            if (received != fee) revert DepositMismatch(fee, received);
        }
    }

    /// @notice Stops the unsold part of the caller's listing selling, now; it becomes the seller's to
    ///         `claim`. What was sold stays locked for its buyers.
    function cancel(uint256 listingId) external nonReentrant {
        Listing storage listing = _listing(listingId);
        if (msg.sender != listing.seller) revert NotSeller(msg.sender);
        uint256 unsold = listing.amount - listing.filled;
        if (unsold == 0 || listing.stockReturned) revert NothingToCollect();

        listing.amount = listing.filled;
        owed[listingId][msg.sender] += unsold;
        emit Cancelled(listingId, unsold);
    }

    /// @notice During the exercise window, pays the strike for `amount` of the caller's calls. The
    ///         stock is then the caller's to `claim`.
    function exercise(uint256 listingId, uint256 amount) external nonReentrant {
        Listing storage listing = _listing(listingId);
        if (block.timestamp < listing.expiry || block.timestamp >= uint256(listing.expiry) + EXERCISE_WINDOW) {
            revert OutsideExerciseWindow(listing.expiry);
        }
        if (amount == 0) revert ZeroAmount();
        uint256 holding = held[listingId][msg.sender];
        if (amount > holding) revert ExceedsAvailable(amount, holding);

        uint256 strike = strikeFor(listingId, amount);
        held[listingId][msg.sender] = holding - amount;
        owed[listingId][msg.sender] += amount;
        listing.exercised += amount;
        listing.strikePaid += strike;
        emit Exercised(listingId, msg.sender, amount, strike);

        usdc.safeTransferFrom(msg.sender, address(this), strike);
    }

    /// @notice Sends the caller all the stock it is owed on a listing. For the seller, once the
    ///         exercise window has closed, that includes every unit not exercised.
    function claim(uint256 listingId) external nonReentrant {
        Listing storage listing = _listing(listingId);
        if (
            msg.sender == listing.seller && !listing.stockReturned
                && block.timestamp >= uint256(listing.expiry) + EXERCISE_WINDOW
        ) {
            uint256 unexercised = listing.amount - listing.exercised;
            listing.stockReturned = true;
            owed[listingId][msg.sender] += unexercised;
            emit StockReturned(listingId, unexercised);
        }
        uint256 amount = owed[listingId][msg.sender];
        if (amount == 0) revert NothingToCollect();

        owed[listingId][msg.sender] = 0;
        emit Claimed(listingId, msg.sender, amount);

        stock.safeTransfer(msg.sender, amount);
    }

    /// @notice Sends the seller the strike paid on a listing so far.
    function collectStrike(uint256 listingId) external nonReentrant {
        Listing storage listing = _listing(listingId);
        if (msg.sender != listing.seller) revert NotSeller(msg.sender);
        uint256 amount = listing.strikePaid - listing.strikeCollected;
        if (amount == 0) revert NothingToCollect();

        listing.strikeCollected = listing.strikePaid;
        emit StrikeCollected(listingId, amount);

        usdc.safeTransfer(msg.sender, amount);
    }

    /// @notice All the stock `account` may `claim` from a listing right now, including, for the seller
    ///         after the window, the unexercised stock that `claim` books first.
    function claimable(uint256 listingId, address account) external view returns (uint256 amount) {
        Listing storage listing = _listing(listingId);
        amount = owed[listingId][account];
        if (
            account == listing.seller && !listing.stockReturned
                && block.timestamp >= uint256(listing.expiry) + EXERCISE_WINDOW
        ) amount += listing.amount - listing.exercised;
    }

    /// @notice The premium, in USDC, for `amount` raw stock of a listing.
    function premiumFor(uint256 listingId, uint256 amount) public view returns (uint256) {
        return FixedPointMathLib.mulDivUp(amount, _listing(listingId).premiumPerToken, unit);
    }

    /// @notice The strike, in USDC, for `amount` raw stock of a listing.
    function strikeFor(uint256 listingId, uint256 amount) public view returns (uint256) {
        return FixedPointMathLib.mulDivUp(amount, _listing(listingId).strikePerToken, unit);
    }

    function listings(uint256 listingId) external view returns (Listing memory) {
        return _listing(listingId);
    }

    function _listing(uint256 listingId) internal view returns (Listing storage listing_) {
        listing_ = _listings[listingId];
        if (listing_.seller == address(0)) revert UnknownListing(listingId);
    }

    /// @dev A scheduled multiplier change (a split or a dividend) taking effect before the exercise
    ///      window closes would change the share count mid-life, so no listing or fill may span one.
    function _requireNoCorporateActionBefore(uint64 expiry) internal view {
        uint256 effectiveAt = IB20AssetMinimal(stock).effectiveAt();
        if (effectiveAt > block.timestamp && effectiveAt < uint256(expiry) + EXERCISE_WINDOW) {
            revert CorporateActionScheduled(effectiveAt);
        }
    }
}
```

### `contracts/covered-calls/src/interfaces/IB20AssetMinimal.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IB20AssetMinimal
/// @notice The part of Base's B20 Asset precompile (base-std v1.0.0 `IB20` and ERC-8056
///         `IScaledUIAmountNewUIMultiplier`) this component reads.
/// @dev `effectiveAt` is when a scheduled multiplier change takes effect; it is in the past or zero
///      when none is pending.
interface IB20AssetMinimal {
    function decimals() external view returns (uint8);
    function effectiveAt() external view returns (uint256);
}
```

### `contracts/covered-calls/src/interfaces/IRegentRevenueStakingMinimal.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IRegentRevenueStakingMinimal
/// @notice Live REGENT staking's USDC deposit, the path the Memestake hook already settles into
///         (transcribed from `contracts/stocks-v2/src/interfaces/IRegentRevenueStakingMinimal.sol`).
/// @dev `sourceTag` and `sourceRef` are event metadata; covered calls pass
///      `bytes32("autolaunch-covered-calls")` and the listing id.
interface IRegentRevenueStakingMinimal {
    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256 received);
}
```

Build settings (`contracts/covered-calls/foundry.toml`):

### `contracts/covered-calls/foundry.toml`

```toml
[profile.default]
src = "src"
test = "test"
script = "script"
out = "out"
# Covered calls build against the dependency snapshot the Base Memestake v2 package exports
# (contracts/stocks-v2/lib, filled by its bootstrap-deps.py); it uses forge-std and solady only.
libs = ["../stocks-v2/lib"]
allow_paths = ["../stocks-v2"]

# Same build identity as the other Autolaunch contract projects: Solidity 0.8.26, Cancun,
# optimizer 200, via-IR, bytecode metadata disabled.
solc = "0.8.26"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
via_ir = true
bytecode_hash = "none"
cbor_metadata = false
ffi = false
fs_permissions = []

# `test/fork/` runs only under the `fork` profile against a local Base fork (anvil --network base),
# and `test/rehearsal/` only under `deploy/rehearse.sh`.
no_match_path = "test/{fork,rehearsal}/**"

[profile.default.fuzz]
runs = 512
seed = "0x434f564552"

[profile.default.invariant]
runs = 256
depth = 128
fail_on_revert = false

[profile.fork]
test = "test/fork"
out = "out-fork"
cache_path = "cache-fork"
match_path = "test/fork/**"
no_match_path = "none/**"

# The deploy packet's rehearsal (deploy/rehearse.sh), against a Base copy the packet's transaction
# has just been sent on.
[profile.rehearsal]
test = "test/rehearsal"
out = "out-fork"
cache_path = "cache-fork"
match_path = "test/rehearsal/**"
no_match_path = "none/**"
fs_permissions = [{ access = "read", path = "./deploy/packet.json" }]

[lint]
ignore = ["test/**/*.sol", "script/**/*.sol"]
# Expiry and the exercise window are the product, so time comparisons are intended. The only
# external call before an event is the stock's `effectiveAt()` view, and every state-changing
# function is `nonReentrant` and moves tokens after its event.
exclude_lints = ["screaming-snake-case-immutable", "mixed-case-function", "block-timestamp", "reentrancy-events"]
```

## Appendix B — deployment (complete)

### `contracts/covered-calls/script/DeployCoveredCallsAMZNc.s.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {CoveredCallsV1} from "../src/CoveredCallsV1.sol";

/// @title DeployCoveredCallsAMZNc
/// @notice Sends deploy/packet.json's one transaction: CoveredCallsV1 for AMZNc on Base. `new … {salt: …}`
///         in a broadcast goes through the deterministic deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C,
///         so the contract lands at the packet's address whoever sends it. Every constant is the packet's;
///         deploy/rehearse.sh runs this script on a Base copy and checks the transaction it sends has the
///         packet's recipient, value and data, byte for byte. It moves no funds and grants no roles; the contract has no owner.
/// @dev Deploying is a protected action: broadcast only on Sean's go naming it.
contract DeployCoveredCallsAMZNc is Script {
    address internal constant AMZNC = 0xb200000000000000000000d9192b6B456483C2E8;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant LIVE_STAKING = 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5;
    /// @notice keccak256("autolaunch.covered-calls.v1.AMZNc")
    bytes32 internal constant SALT = 0x52a9b8f155c1895a8412c0e70f3d431bfc366613b5e2c5d634d227071af13345;
    bytes32 internal constant INIT_CODE_KECCAK = 0x758462a26cd2e9dc152f89f2c13a335f9255ec811669b94b137ee0c145b24fc2;
    address internal constant PREDICTED = 0x0B2FE2810F9219bDd5e5e304DC8A1A4c84eA553E;
    bytes32 internal constant RUNTIME_CODE_KECCAK = 0x44cf180fcad6f5e1bc1c2e68df260394526edbafc67687ffab49d820fbb5448e;

    error WrongChain(uint256 chainId);
    error AlreadyDeployed(address at);
    error NotThePacketsInitCode(bytes32 initCodeKeccak);
    error NotThePacketsAddress(address deployed);
    error NotThePacketsCode(bytes32 codeKeccak);
    error NotThePacketsReads();

    function run() external returns (CoveredCallsV1 calls) {
        if (block.chainid != 8453) revert WrongChain(block.chainid);
        if (PREDICTED.code.length != 0) revert AlreadyDeployed(PREDICTED);
        bytes32 initCode =
            keccak256(abi.encodePacked(type(CoveredCallsV1).creationCode, abi.encode(AMZNC, USDC, LIVE_STAKING)));
        if (initCode != INIT_CODE_KECCAK) revert NotThePacketsInitCode(initCode);

        vm.broadcast();
        calls = new CoveredCallsV1{salt: SALT}(AMZNC, USDC, LIVE_STAKING);

        if (address(calls) != PREDICTED) revert NotThePacketsAddress(address(calls));
        if (address(calls).codehash != RUNTIME_CODE_KECCAK) revert NotThePacketsCode(address(calls).codehash);
        if (
            calls.stock() != AMZNC || calls.usdc() != USDC || calls.staking() != LIVE_STAKING || calls.unit() != 1e8
                || calls.FEE_BPS() != 100 || calls.EXERCISE_WINDOW() != 1 days
        ) revert NotThePacketsReads();
        console.log("CoveredCallsV1 (AMZNc)", address(calls));
    }
}
```

### `contracts/covered-calls/deploy/packet.json`

```json
{
  "contract": "CoveredCallsV1",
  "market": "AMZNc",
  "chain_id": 8453,
  "status": "prepared, not sent",
  "source": {
    "repository": "regents-ai/autolaunch",
    "commit": "bc185c65033ce0c3e72c6fedc21986af4c41438a",
    "file": "contracts/covered-calls/src/CoveredCallsV1.sol",
    "solady_revision": "33b4b98e350bbcba6aa85642957c313e98b5f911",
    "forge_std_revision": "3b20d60d14b343ee4f908cb8079495c07f5e8981"
  },
  "compiler": {
    "solc": "0.8.26+commit.8a97fa7a",
    "evm_version": "cancun",
    "optimizer": {
      "enabled": true,
      "runs": 200
    },
    "via_ir": true,
    "bytecode_hash": "none",
    "cbor_metadata": false
  },
  "creation_code_keccak": "0x44d79e5cb60f03b989fa1226fc73a6cff447b60c4b68a3a3264ff799d2ba85c7",
  "constructor": [
    {
      "name": "stock_",
      "value": "0xb200000000000000000000d9192b6B456483C2E8",
      "is": "AMZNc, the Base stock token, 8 decimals",
      "source": "contracts/stocks-v2/deployments/base-mainnet/deployed-manifest.json, admissions, symbol AMZNc"
    },
    {
      "name": "usdc_",
      "value": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      "is": "USDC on Base",
      "source": "contracts/stocks-v2/src/StocksBindings.sol, USDC (built into the live Memestock fee hook)"
    },
    {
      "name": "staking_",
      "value": "0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5",
      "is": "live REGENT staking, which the Memestock fee hook pays into",
      "source": "contracts/stocks-v2/src/StocksBindings.sol, LIVE_STAKING (built into the live Memestock fee hook)"
    }
  ],
  "constructor_args_encoded": "0x000000000000000000000000b200000000000000000000d9192b6b456483c2e8000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913000000000000000000000000b027dc261636e30cbc0fe25b2f8e1ed273354ab5",
  "init_code_keccak": "0x758462a26cd2e9dc152f89f2c13a335f9255ec811669b94b137ee0c145b24fc2",
  "create2": {
    "deployer": "0x4e59b44847b379578588920cA78FbF26c0B4956C",
    "deployer_code_keccak": "0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989",
    "salt_text": "autolaunch.covered-calls.v1.AMZNc",
    "salt": "0x52a9b8f155c1895a8412c0e70f3d431bfc366613b5e2c5d634d227071af13345",
    "predicted_address": "0x0B2FE2810F9219bDd5e5e304DC8A1A4c84eA553E"
  },
  "transaction": {
    "chain_id": 8453,
    "to": "0x4e59b44847b379578588920cA78FbF26c0B4956C",
    "value": "0",
    "data": "0x52a9b8f155c1895a8412c0e70f3d431bfc366613b5e2c5d634d227071af1334561010080604052346101675760608161145f803803809161002082856101af565b83398101031261016757610033816101e6565b61004b6040610044602085016101e6565b93016101e6565b6001600160a01b038216908115801561019e575b801561018d575b61017e5760049360209360805260a05260c0526040519283809263313ce56760e01b82525afa8015610173575f90610132575b60ff915016604d811161011e57600a0a60e05260405161126490816101fb82396080518181816102e6015281816104cf01528181610e920152611137015260a0518181816106df015281816108a801528181610ab90152610c0d015260c0518181816109910152610c66015260e0518181816101230152818161062001526109050152f35b634e487b7160e01b5f52601160045260245ffd5b506020813d60201161016b575b8161014c602093836101af565b81010312610167575160ff811681036101675760ff90610099565b5f80fd5b3d915061013f565b6040513d5f823e3d90fd5b63d92e233d60e01b5f5260045ffd5b506001600160a01b03811615610066565b506001600160a01b0384161561005f565b601f909101601f19168101906001600160401b038211908210176101d257604052565b634e487b7160e01b5f52604160045260245ffd5b51906001600160a01b03821682036101675756fe60806040526004361015610011575f80fd5b5f3560e01c80631755ccfc14610fba5780632cfb272e14610f8557806330a4ec7214610f68578063379607f514610dc95780633c29fc4314610ae85780633e413bee14610aa457806340e58ee5146109c05780634cf088d91461097c5780637f74c97d1461095f57806383b1deb014610928578063907af6c0146108ee578063948503fb1461080f578063a0c7f71c1461074f578063a86265bb14610589578063a9b07c261461056d578063bacd5e0e14610315578063bdf3c4ae146102d1578063bf333f2c146102b6578063c2ebdac31461029e578063de74e57b146101545763edc2c27914610100575f80fd5b3461015057602061014861011f600561011836611017565b929061109a565b01547f0000000000000000000000000000000000000000000000000000000000000000916111e8565b604051908152f35b5f80fd5b34610150576020366003190112610150575f61012060405161017581611047565b8281528260208201528260408201528260608201528260808201528260a08201528260c08201528260e08201528261010082015201526101406101b960043561109a565b6040516101c581611047565b81549160018060a01b03831692838352602083019067ffffffffffffffff8160a01c16825260ff604085019160e01c161515815260018301546060850190815260028401546080860190815260038501549160a0870192835260048601549360c0880194855267ffffffffffffffff60058801549660e08a01978852610120600760068b01549a6101008d019b8c5201549a01998a526040519a8b52511660208a015251151560408901525160608801525160808701525160a08601525160c08501525160e08401525161010083015251610120820152f35b3461015057602061014861011f600461011836611017565b34610150575f36600319011261015057602060405160648152f35b34610150575f366003190112610150576040517f00000000000000000000000000000000000000000000000000000000000000006001600160a01b03168152602090f35b3461015057608036600319011261015057600435602435604435906064359267ffffffffffffffff841693848103610150573068929eee149b4bd212685414610560573068929eee149b4bd212685581158015610558575b8015610550575b61054157620278d067ffffffffffffffff62093a808706160361052e574285111561051b576103a290611121565b5f54915f1983146105075760209460016104f3940194855f556040516103c781611047565b338152600787898301858152604084015f815260608501898152608086015f815260a08701905f825260c08801928b845260e08901948a86526101008a01965f88526101208b01985f8a525f5260206001905260405f209a60018060a01b039051168b549167ffffffffffffffff60a01b905160a01b169163ffffffff60e01b1617178a5551151589549060ff60e01b9060e01b169060ff60e01b191617895551600189015551600288015551600387015551600486015551600585015551600684015551910155604051928484528784015260408301526060820152837ff8ba93c6703bb46989d765480c06730c51f757dae686190c8cf982faffda7ef760803393a330337f0000000000000000000000000000000000000000000000000000000000000000611206565b3868929eee149b4bd2126855604051908152f35b634e487b7160e01b5f52601160045260245ffd5b84632721616f60e01b5f5260045260245ffd5b84633fe3d12360e01b5f5260045260245ffd5b631f2a200560e01b5f5260045ffd5b508315610374565b50821561036d565b63ab143c065f526004601cfd5b34610150575f3660031901126101505760205f54604051908152f35b346101505761059736611017565b903068929eee149b4bd212685414610560573068929eee149b4bd21268556105be8161109a565b9167ffffffffffffffff835460a01c168042108015610739575b61072757508015610541575f828152600260209081526040808320338452909152902054918282116107115760066107039461064c84610646600461061c8761109a565b01547f000000000000000000000000000000000000000000000000000000000000000090836111e8565b9661103a565b5f84815260026020908152604080832033808552908352818420949094558683526003825280832093835292905220805461068890869061102d565b90556003810161069985825461102d565b9055016106a784825461102d565b90556040519182528260208301527fbb1ea6614cc25f4c8be774d6b5032cf5afa178192d18e27158bb9c1b9af888c160403393a330337f0000000000000000000000000000000000000000000000000000000000000000611206565b3868929eee149b4bd2126855005b50630428b63760e51b5f5260045260245260445ffd5b63191e5d8f60e01b5f5260045260245ffd5b50620151808101808211610507574210156105d8565b346101505761075d36610ff1565b6107668261109a565b5f9283526003602090815260408085206001600160a01b0394851680875292529093205481549193909282161490816107ff575b816107d7575b50916020926107b3575b50604051908152f35b906107cb82600360016107d19501549101549061103a565b9061102d565b826107aa565b67ffffffffffffffff915060a01c1691620151808301809311610507579142101560206107a0565b905060ff8160e01c16159061079a565b34610150576020366003190112610150576004353068929eee149b4bd212685414610560573068929eee149b4bd21268556108498161109a565b80546001600160a01b031633036108db576007600682015491019161086f83548361103a565b9182156108cc5761070393557f56f6da3dba8bb3b076b447a0f527bdb1efa93232165ca68b56ac15a08330ee9a6020604051848152a2337f00000000000000000000000000000000000000000000000000000000000000006110d0565b637b2c2fef60e01b5f5260045ffd5b6371c6811560e11b5f523360045260245ffd5b34610150575f3660031901126101505760206040517f00000000000000000000000000000000000000000000000000000000000000008152f35b346101505761093636610ff1565b905f52600260205260405f209060018060a01b03165f52602052602060405f2054604051908152f35b34610150575f366003190112610150576020604051620278d08152f35b34610150575f366003190112610150576040517f00000000000000000000000000000000000000000000000000000000000000006001600160a01b03168152602090f35b34610150576020366003190112610150576004353068929eee149b4bd212685414610560573068929eee149b4bd21268556109fa8161109a565b80546001600160a01b03811633036108db576001820190610a2260028354940154809461103a565b908115908115610a96575b506108cc577fa761582a460180d55522f9f5fdc076390a1f48a7a62a8afbd45c1bb797948edb9260209255835f526003825260405f2060018060a01b0333165f52825260405f20610a7f82825461102d565b9055604051908152a23868929eee149b4bd2126855005b60ff915060e01c1685610a2d565b34610150575f366003190112610150576040517f00000000000000000000000000000000000000000000000000000000000000006001600160a01b03168152602090f35b3461015057610af636611017565b3068929eee149b4bd212685414610560573068929eee149b4bd2126855610b1c8261109a565b9181156105415767ffffffffffffffff835460a01c1680421015610db7576001840154926002850191610b518354809661103a565b808311610da15750610b6290611121565b610b70600561061c8561109a565b9060648202926127106064848604148415170215610d9457610ba1828561271080610c45980491061515019761102d565b9055835f52600260205260405f2060018060a01b0333165f5260205260405f20610bcc82825461102d565b9055604051908152816020820152846040820152837fdef4cdb91e8c5e2777b0bf9645ce2c7e0b64a3b3fb94e37c6d78cde1043f80cb60603393a3610c3d847f00000000000000000000000000000000000000000000000000000000000000009660018060a01b039054169261103a565b903386611206565b81610c58573868929eee149b4bd2126855005b610c6482303386611206565b7f000000000000000000000000000000000000000000000000000000000000000092836014528260345263095ea7b360601b5f5260205f6044601082855af1908160015f51141615610d76575b50505f926064602092856034526040519586938492630fb8d77360e31b8452876004850152776175746f6c61756e63682d636f76657265642d63616c6c7360401b6024850152604484015260018060a01b03165af1918215610d6b575f92610d37575b50808203610d225780610703565b633b55508d60e21b5f5260045260245260445ffd5b9091506020813d602011610d63575b81610d5360209383611078565b8101031261015057519082610d14565b3d9150610d46565b6040513d5f823e3d90fd5b3b153d171015610d87578380610cb1565b633e3f8f735f526004601cfd5b63ad251c275f526004601cfd5b82630428b63760e51b5f5260045260245260445ffd5b6313bb4e5160e31b5f5260045260245ffd5b34610150576020366003190112610150576004353068929eee149b4bd212685414610560573068929eee149b4bd212685580610e048161109a565b805490336001600160a01b0383161480610f5a575b80610f31575b610eb6575b50505f90815260036020908152604080832033845290915290205480156108cc575f82815260036020908152604080832033808552908352818420939093555183815261070394917f4ec90e965519d92681267467f775ada5bd214aa92c0dc93d90a5e880ce9ed02691a3337f00000000000000000000000000000000000000000000000000000000000000006110d0565b7feb8d89ea7bd0c2637450692b4986688b4a0544662951ab014d21e7e7e63291839181610eee6001602094015460038301549061103a565b60ff60e01b19909216600160e01b1790555f848152600383526040808220338352845290208054610f2090839061102d565b9055604051908152a2808280610e24565b50915067ffffffffffffffff8160a01c1691620151808301809311610507578392421015610e1f565b5060ff8260e01c1615610e19565b34610150575f366003190112610150576020604051620151808152f35b34610150575f366003190112610150576020604051776175746f6c61756e63682d636f76657265642d63616c6c7360401b8152f35b3461015057610fc836610ff1565b905f52600360205260405f209060018060a01b03165f52602052602060405f2054604051908152f35b604090600319011261015057600435906024356001600160a01b03811681036101505790565b6040906003190112610150576004359060243590565b9190820180921161050757565b9190820391821161050757565b610140810190811067ffffffffffffffff82111761106457604052565b634e487b7160e01b5f52604160045260245ffd5b90601f8019910116810190811067ffffffffffffffff82111761106457604052565b5f8181526001602052604090208054909291906001600160a01b0316156110be5750565b6358a30b2d60e11b5f5260045260245ffd5b919060145260345263a9059cbb60601b5f5260205f6044601082855af1908160015f51141615611103575b50505f603452565b3b153d171015611114575f806110fb565b6390b8ec185f526004601cfd5b6040516397a4064f60e01b8152906020826004817f00000000000000000000000000000000000000000000000000000000000000006001600160a01b03165afa918215610d6b575f926111b4575b504282119081611193575b506111825750565b62b0f18960e81b5f5260045260245ffd5b67ffffffffffffffff9150166201518081018091116105075781105f61117a565b9091506020813d6020116111e0575b816111d060209383611078565b810103126101505751905f61116f565b3d91506111c3565b818102929181159184041417810215610d9457808204910615150190565b916040519360605260405260601b602c526323b872dd60601b600c5260205f6064601c82855af1908160015f51141615611246575b50505f606052604052565b3b153d171015611257575f8061123b565b637939f4245f526004601cfd000000000000000000000000b200000000000000000000d9192b6b456483c2e8000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913000000000000000000000000b027dc261636e30cbc0fe25b2f8e1ed273354ab5",
    "gas_limit_at_least": 1200000
  },
  "signer": {
    "recommended": "your own wallet",
    "alternative_safe": "0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e",
    "safe_operation": "Call (never delegatecall)",
    "why": "CoveredCallsV1 has no owner, admin, pause or upgrade, so whoever sends this transaction gains no power over it, and the address is the same whoever sends it. One signature from your wallet is the simplest; the Safe adds approvals and nothing else."
  },
  "before_signing": "Check 0x0B2FE2810F9219bDd5e5e304DC8A1A4c84eA553E still has no code. Anyone may send this same transaction; if the address already holds runtime_code_keccak, the contract is deployed and nothing needs sending.",
  "post_deploy": {
    "receipt_status": "1",
    "runtime_code_keccak": "0x44cf180fcad6f5e1bc1c2e68df260394526edbafc67687ffab49d820fbb5448e",
    "reads": {
      "stock()": "0xb200000000000000000000d9192b6B456483C2E8",
      "usdc()": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      "staking()": "0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5",
      "unit()": "100000000",
      "FEE_BPS()": "100",
      "EXERCISE_WINDOW()": "86400"
    },
    "basescan_verify_needs": "ETHERSCAN_API_KEY (an Etherscan key works for Base) and ../stocks-v2/lib filled by contracts/stocks-v2/bootstrap-deps.py; run from contracts/covered-calls",
    "basescan_verify": "forge verify-contract 0x0B2FE2810F9219bDd5e5e304DC8A1A4c84eA553E src/CoveredCallsV1.sol:CoveredCallsV1 --chain base --compiler-version v0.8.26+commit.8a97fa7a --constructor-args 0x000000000000000000000000b200000000000000000000d9192b6b456483c2e8000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913000000000000000000000000b027dc261636e30cbc0fe25b2f8e1ed273354ab5 --watch"
  }
}
```

### `contracts/covered-calls/deploy/rehearse.sh`

```sh
#!/bin/sh
# Rehearses deploy/packet.json on a local copy of Base, never on Base itself: starts
# `anvil --network base` forked from Base, runs script/DeployCoveredCallsAMZNc.s.sol with
# --broadcast from the Safe (impersonated on the copy only), checks the one transaction it sent has
# the packet's recipient, value and data, byte for byte and that the contract lands at the predicted address with the promised
# code and reads, then runs test/rehearsal on that copy: a whole call's life with the real AMZNc,
# Base USDC and live REGENT staking. Nothing is signed with a real key and nothing reaches Base.
#
#   FOUNDRY_BIN   folder holding Foundry 1.8.4 or later (B20 stock tokens need it); default: PATH
#   BASE_RPC_URL  Base to fork from; default https://mainnet.base.org
set -eu
cd "$(dirname "$0")/.."
bin=${FOUNDRY_BIN:-$(dirname "$(command -v anvil)")}
[ -x "$bin/anvil" ] || { echo "rehearse: no anvil in $bin" >&2; exit 1; }
rpc=${BASE_RPC_URL:-https://mainnet.base.org}
packet=deploy/packet.json
field() { python3 -c "import json,sys; print(eval('json.load(open(\"$packet\"))' + sys.argv[1]))" "$1"; }

port=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])")
copy=http://127.0.0.1:$port
"$bin/anvil" --network base --fork-url "$rpc" --port "$port" --silent &
anvil=$!
trap 'kill "$anvil"' EXIT
until "$bin/cast" block-number --rpc-url "$copy" >/dev/null 2>&1; do
  kill -0 "$anvil" 2>/dev/null || { echo "rehearse: anvil stopped" >&2; exit 1; }
  sleep 1
done
echo "rehearse: Base copy at block $("$bin/cast" block-number --rpc-url "$copy"), chain $("$bin/cast" chain-id --rpc-url "$copy")"

predicted=$(field "['create2']['predicted_address']")
sender=$(field "['signer']['alternative_safe']")
[ "$("$bin/cast" code "$predicted" --rpc-url "$copy")" = "0x" ] || { echo "rehearse: $predicted already has code" >&2; exit 1; }
[ "$("$bin/cast" keccak "$("$bin/cast" code "$(field "['create2']['deployer']")" --rpc-url "$copy")")" = "$(field "['create2']['deployer_code_keccak']")" ] \
  || { echo "rehearse: the deterministic deployer's code is not the expected one" >&2; exit 1; }

"$bin/cast" rpc anvil_impersonateAccount "$sender" --rpc-url "$copy" >/dev/null
"$bin/cast" rpc anvil_setBalance "$sender" 0xde0b6b3a7640000 --rpc-url "$copy" >/dev/null
sent=$(mktemp -d)
FOUNDRY_BROADCAST="$sent" "$bin/forge" script script/DeployCoveredCallsAMZNc.s.sol --network base \
  --rpc-url "$copy" --unlocked --sender "$sender" --broadcast --slow >/dev/null
python3 - "$sent/DeployCoveredCallsAMZNc.s.sol/8453/run-latest.json" "$packet" <<'CHECK'
import json, sys
run, packet = (json.load(open(path)) for path in sys.argv[1:])
[tx], [receipt] = run["transactions"], run["receipts"]
want = packet["transaction"]
same = (tx["transaction"]["to"].lower() == want["to"].lower() and int(tx["transaction"]["value"], 16) == 0
        and tx["transaction"]["input"].lower() == want["data"].lower())
print("rehearse: forge script sent", receipt["transactionHash"], "status", receipt["status"],
      "gas", int(receipt["gasUsed"], 16), "| the packet's transaction byte for byte:", same)
sys.exit(not (same and receipt["status"] == "0x1"))
CHECK

code=$("$bin/cast" keccak "$("$bin/cast" code "$predicted" --rpc-url "$copy")")
[ "$code" = "$(field "['post_deploy']['runtime_code_keccak']")" ] || { echo "rehearse: runtime code $code is not the packet's" >&2; exit 1; }
echo "rehearse: $predicted holds the packet's runtime code ($code)"
for read in "stock()(address)" "usdc()(address)" "staking()(address)" "unit()(uint256)" "FEE_BPS()(uint256)" "EXERCISE_WINDOW()(uint256)"; do
  got=$("$bin/cast" call "$predicted" "$read" --rpc-url "$copy" | cut -d' ' -f1)
  want=$(field "['post_deploy']['reads']['${read%%)*})']")
  [ "$(echo "$got" | tr A-F a-f)" = "$(echo "$want" | tr A-F a-f)" ] || { echo "rehearse: $read is $got, not $want" >&2; exit 1; }
  echo "rehearse: $read = $got"
done

FOUNDRY_PROFILE=rehearsal "$bin/forge" test --network base --fork-url "$copy" -vv
```

## Appendix C — tests (complete)

### `contracts/covered-calls/test/CoveredCallsV1.t.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {CoveredCallsV1} from "../src/CoveredCallsV1.sol";
import {B20Double, StakingDouble, UsdcDouble} from "./doubles/Doubles.sol";
import {WeeklyExpiry} from "./doubles/WeeklyExpiry.sol";

contract CoveredCallsV1Test is Test {
    uint256 internal constant TOKEN = 1e8; // one whole stock token, raw
    uint256 internal constant USD = 1e6;
    uint64 internal expiry;

    B20Double internal stock;
    UsdcDouble internal usdc;
    StakingDouble internal staking;
    CoveredCallsV1 internal calls;

    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal other = makeAddr("other");

    function setUp() public {
        vm.warp(1_800_000_000);
        expiry = WeeklyExpiry.next(block.timestamp, 0);
        stock = new B20Double();
        usdc = new UsdcDouble();
        staking = new StakingDouble(usdc);
        calls = new CoveredCallsV1(address(stock), address(usdc), address(staking));

        stock.mint(seller, 100 * TOKEN);
        vm.prank(seller);
        stock.approve(address(calls), type(uint256).max);
        for (uint256 i; i < 2; ++i) {
            address account = i == 0 ? buyer : other;
            usdc.mint(account, 1_000_000 * USD);
            vm.prank(account);
            usdc.approve(address(calls), type(uint256).max);
        }
    }

    /// Ten tokens at a 110 strike and a 3 USDC premium per token.
    function _list() internal returns (uint256 id) {
        vm.prank(seller);
        id = calls.list(10 * TOKEN, 110 * USD, 3 * USD, expiry);
    }

    function _fill(address who, uint256 id, uint256 amount) internal {
        vm.prank(who);
        calls.fill(id, amount);
    }

    // ---- list ----

    function test_list_locksTheStockAndRecordsTerms() public {
        uint256 id = _list();
        assertEq(id, 1);
        assertEq(stock.balanceOf(address(calls)), 10 * TOKEN);
        assertEq(stock.balanceOf(seller), 90 * TOKEN);
        CoveredCallsV1.Listing memory l = calls.listings(id);
        assertEq(l.seller, seller);
        assertEq(l.amount, 10 * TOKEN);
        assertEq(l.strikePerToken, 110 * USD);
        assertEq(l.premiumPerToken, 3 * USD);
        assertEq(l.expiry, expiry);
    }

    function test_list_refusesZeroTermsAndPastExpiry() public {
        vm.startPrank(seller);
        vm.expectRevert(CoveredCallsV1.ZeroAmount.selector);
        calls.list(0, 110 * USD, 3 * USD, expiry);
        vm.expectRevert(CoveredCallsV1.ZeroAmount.selector);
        calls.list(TOKEN, 0, 3 * USD, expiry);
        vm.expectRevert(CoveredCallsV1.ZeroAmount.selector);
        calls.list(TOKEN, 110 * USD, 0, expiry);
        uint64 lastWeek = expiry - 1 weeks;
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.ExpiryPassed.selector, lastWeek));
        calls.list(TOKEN, 110 * USD, 3 * USD, lastWeek);
        vm.stopPrank();
    }

    /// Every expiry is a Friday at 21:00 UTC; an hour either side, or a Thursday, is refused.
    function test_list_acceptsOnlyFridayAt2100Utc() public {
        uint64[3] memory wrong = [expiry - 1 hours, expiry + 1 hours, expiry - 1 days];
        for (uint256 i; i < wrong.length; ++i) {
            vm.prank(seller);
            vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.NotAWeeklyExpiry.selector, wrong[i]));
            calls.list(TOKEN, 110 * USD, 3 * USD, wrong[i]);
        }
        vm.prank(seller);
        calls.list(TOKEN, 110 * USD, 3 * USD, expiry + 4 weeks);
        assertEq(expiry % 1 weeks, 1 days + 21 hours);
    }

    function test_list_refusesAScheduledCorporateActionBeforeTheWindowCloses() public {
        uint256 at = uint256(expiry) + 1 days - 1;
        stock.schedule(at);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.CorporateActionScheduled.selector, at));
        calls.list(TOKEN, 110 * USD, 3 * USD, expiry);
    }

    function test_list_allowsACorporateActionAfterTheWindowOrAlreadyInThePast() public {
        stock.schedule(uint256(expiry) + 1 days);
        _list();
        stock.schedule(block.timestamp - 1);
        _list();
    }

    function test_list_failsWhenTheSellersStockCannotMove() public {
        stock.setPaused(true);
        vm.prank(seller);
        vm.expectRevert();
        calls.list(TOKEN, 110 * USD, 3 * USD, expiry);
    }

    // ---- fill ----

    function test_fill_paysThePremiumLessOnePercentToTheSellerAndOnePercentToStaking() public {
        uint256 id = _list();
        _fill(buyer, id, 4 * TOKEN);

        // 4 tokens x 3 USDC = 12 USDC; 1% = 0.12 USDC.
        assertEq(usdc.balanceOf(seller), 12 * USD - 120_000);
        assertEq(staking.deposited(), 120_000);
        assertEq(staking.lastTag(), bytes32("autolaunch-covered-calls"));
        assertEq(staking.lastRef(), bytes32(id));
        assertEq(usdc.balanceOf(buyer), 1_000_000 * USD - 12 * USD);
        assertEq(usdc.balanceOf(address(calls)), 0);
        assertEq(calls.held(id, buyer), 4 * TOKEN);
        assertEq(calls.listings(id).filled, 4 * TOKEN);
    }

    function test_fill_partialFillsAddUpAndCannotOversell() public {
        uint256 id = _list();
        _fill(buyer, id, 6 * TOKEN);
        _fill(other, id, 4 * TOKEN);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.ExceedsAvailable.selector, 1, 0));
        calls.fill(id, 1);
    }

    function test_fill_roundsThePremiumAndTheFeeUp() public {
        uint256 id = _list();
        // One raw unit: 3e6 * 1 / 1e8 rounds up to 1 micro-USDC, and its 1% fee rounds up to all of it.
        _fill(buyer, id, 1);
        assertEq(usdc.balanceOf(seller), 0);
        assertEq(staking.deposited(), 1);
    }

    function test_fill_closesAtExpiry() public {
        uint256 id = _list();
        vm.warp(expiry);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.FillsClosed.selector, expiry));
        calls.fill(id, TOKEN);
    }

    function test_fill_refusesWhenACorporateActionIsScheduledAfterListing() public {
        uint256 id = _list();
        stock.schedule(expiry);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.CorporateActionScheduled.selector, uint256(expiry)));
        calls.fill(id, TOKEN);
    }

    function test_fill_refusesUnknownListingsAndZero() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.UnknownListing.selector, 7));
        calls.fill(7, TOKEN);
        uint256 id = _list();
        vm.prank(buyer);
        vm.expectRevert(CoveredCallsV1.ZeroAmount.selector);
        calls.fill(id, 0);
    }

    function test_fill_worksWhileStockTransfersArePaused() public {
        uint256 id = _list();
        stock.setPaused(true);
        _fill(buyer, id, TOKEN);
        assertEq(calls.held(id, buyer), TOKEN);
    }

    // ---- cancel ----

    function test_cancel_stopsSalesAndOwesOnlyTheUnsoldPartToTheSeller() public {
        uint256 id = _list();
        _fill(buyer, id, 3 * TOKEN);
        vm.expectEmit(address(calls));
        emit CoveredCallsV1.Cancelled(id, 7 * TOKEN);
        vm.prank(seller);
        calls.cancel(id);
        assertEq(calls.listings(id).amount, 3 * TOKEN);
        assertEq(calls.owed(id, seller), 7 * TOKEN);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.ExceedsAvailable.selector, 1, 0));
        calls.fill(id, 1);
        vm.prank(seller);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.cancel(id);

        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 97 * TOKEN);
        assertEq(stock.balanceOf(address(calls)), 3 * TOKEN);
    }

    function test_cancel_isTheSellersAlone() public {
        uint256 id = _list();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.NotSeller.selector, buyer));
        calls.cancel(id);
    }

    function test_cancel_afterTheStockReturnedOwesNothingTwice() public {
        uint256 id = _list();
        _fill(buyer, id, 2 * TOKEN);
        vm.warp(uint256(expiry) + 1 days);
        vm.startPrank(seller);
        calls.claim(id);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.cancel(id);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id);
        vm.stopPrank();
        assertEq(stock.balanceOf(seller), 100 * TOKEN);
    }

    function test_cancel_afterTheWindowThenClaimReturnsEachUnitOnce() public {
        uint256 id = _list();
        _fill(buyer, id, 2 * TOKEN);
        vm.warp(expiry);
        vm.prank(buyer);
        calls.exercise(id, TOKEN);
        vm.warp(uint256(expiry) + 1 days);
        vm.startPrank(seller);
        calls.cancel(id); // 8 unsold
        calls.claim(id); // + 1 unexercised
        vm.stopPrank();
        assertEq(stock.balanceOf(seller), 99 * TOKEN);
        assertEq(stock.balanceOf(address(calls)), TOKEN); // the buyer's exercised token
    }

    // ---- exercise, claim, collectStrike: the spec's payoff cases ----

    /// Stock falls to 80: the call is not exercised; the seller keeps the premium and gets the stock back.
    function test_unexercised_sellerKeepsPremiumAndStock() public {
        uint256 id = _list();
        _fill(buyer, id, TOKEN);
        vm.warp(uint256(expiry) + 1 days);
        vm.expectEmit(address(calls));
        emit CoveredCallsV1.StockReturned(id, 10 * TOKEN);
        vm.expectEmit(address(calls));
        emit CoveredCallsV1.Claimed(id, seller, 10 * TOKEN);
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 100 * TOKEN);
        assertEq(usdc.balanceOf(seller), 3 * USD - 30_000);
        assertEq(stock.balanceOf(address(calls)), 0);
    }

    /// Stock rises to 120: the buyer pays 110 for each token; the seller gets 110 plus the premium.
    function test_exercised_buyerPaysStrikeForTheStock() public {
        uint256 id = _list();
        _fill(buyer, id, TOKEN);
        vm.warp(expiry);
        vm.expectEmit(address(calls));
        emit CoveredCallsV1.Exercised(id, buyer, TOKEN, 110 * USD);
        vm.prank(buyer);
        calls.exercise(id, TOKEN);
        assertEq(calls.owed(id, buyer), TOKEN);
        assertEq(calls.held(id, buyer), 0);

        vm.prank(buyer);
        calls.claim(id);
        assertEq(stock.balanceOf(buyer), TOKEN);

        vm.expectEmit(address(calls));
        emit CoveredCallsV1.StrikeCollected(id, 110 * USD);
        vm.prank(seller);
        calls.collectStrike(id);
        assertEq(usdc.balanceOf(seller), 110 * USD + 3 * USD - 30_000);

        vm.warp(uint256(expiry) + 1 days);
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 99 * TOKEN);
        assertEq(stock.balanceOf(address(calls)), 0);
        assertEq(usdc.balanceOf(address(calls)), 0);
    }

    function test_exercise_onlyInsideTheWindow() public {
        uint256 id = _list();
        _fill(buyer, id, TOKEN);
        vm.warp(uint256(expiry) - 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.OutsideExerciseWindow.selector, expiry));
        calls.exercise(id, TOKEN);
        vm.warp(uint256(expiry) + 1 days - 1);
        vm.prank(buyer);
        calls.exercise(id, 1); // the window's last second
        vm.warp(uint256(expiry) + 1 days);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.OutsideExerciseWindow.selector, expiry));
        calls.exercise(id, 1);
    }

    function test_exercise_cannotExceedTheHolding() public {
        uint256 id = _list();
        _fill(buyer, id, TOKEN);
        vm.warp(expiry);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.ExceedsAvailable.selector, 1, 0));
        calls.exercise(id, 1);
        vm.startPrank(buyer);
        calls.exercise(id, TOKEN / 2);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.ExceedsAvailable.selector, TOKEN, TOKEN / 2));
        calls.exercise(id, TOKEN);
        vm.stopPrank();
    }

    function test_exercise_roundsTheStrikeUpSoSplittingNeverPaysLess() public {
        uint256 id = _list();
        _fill(buyer, id, TOKEN);
        vm.warp(expiry);
        uint256 before = usdc.balanceOf(buyer);
        vm.startPrank(buyer);
        calls.exercise(id, 1);
        calls.exercise(id, TOKEN - 1);
        vm.stopPrank();
        assertGe(before - usdc.balanceOf(buyer), 110 * USD);
    }

    function test_strikeAnyTimeStockOnlyAfterTheWindow() public {
        uint256 id = _list();
        _fill(buyer, id, 2 * TOKEN);
        vm.warp(expiry);
        vm.prank(buyer);
        calls.exercise(id, TOKEN);

        vm.startPrank(seller);
        calls.collectStrike(id);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.collectStrike(id);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id); // nothing owed to the seller inside the window
        assertEq(stock.balanceOf(seller), 90 * TOKEN);

        vm.warp(uint256(expiry) + 1 days);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 99 * TOKEN); // 8 unsold + 1 unexercised back
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id);
        vm.stopPrank();
    }

    function test_collectStrike_isTheSellersAlone() public {
        uint256 id = _list();
        vm.warp(uint256(expiry) + 1 days);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.NotSeller.selector, buyer));
        calls.collectStrike(id);
    }

    function test_claim_refusesNothingOwedAndNeverPaysAnotherAccount() public {
        uint256 id = _list();
        _fill(buyer, id, TOKEN);
        vm.warp(uint256(expiry) + 1 days);
        vm.prank(buyer);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id); // the unexercised stock is the seller's, not the buyer's
    }

    /// A seller who buys and exercises on their own listing keeps exact books and loses only the fee.
    function test_selfDealing_sellerFillingOwnListingLosesOnlyTheFee() public {
        usdc.mint(seller, 1_000 * USD);
        vm.prank(seller);
        usdc.approve(address(calls), type(uint256).max);
        uint256 id = _list();
        _fill(seller, id, TOKEN);
        vm.warp(expiry);
        vm.startPrank(seller);
        calls.exercise(id, TOKEN);
        calls.collectStrike(id);
        vm.warp(uint256(expiry) + 1 days);
        calls.claim(id);
        vm.stopPrank();
        assertEq(stock.balanceOf(seller), 100 * TOKEN);
        assertEq(usdc.balanceOf(seller), 1_000 * USD - 30_000);
    }

    // ---- what the tokens can refuse ----

    /// A transfer pause during the window never takes away the right to exercise; the stock waits.
    function test_pause_exerciseStillWorksAndTheStockWaitsForTheClaim() public {
        uint256 id = _list();
        _fill(buyer, id, TOKEN);
        vm.warp(expiry);
        stock.setPaused(true);
        vm.prank(buyer);
        calls.exercise(id, TOKEN);

        vm.prank(buyer);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        calls.claim(id);

        vm.warp(uint256(expiry) + 30 days);
        stock.setPaused(false);
        vm.prank(buyer);
        calls.claim(id);
        assertEq(stock.balanceOf(buyer), TOKEN);
    }

    /// A blocklisted buyer cannot take stock out, and that never blocks the seller's own collection.
    function test_blocklist_aBlockedHolderDoesNotStopTheSeller() public {
        uint256 id = _list();
        _fill(buyer, id, TOKEN);
        vm.warp(expiry);
        vm.prank(buyer);
        calls.exercise(id, TOKEN);
        stock.setBlocked(buyer, true);

        vm.prank(buyer);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        calls.claim(id);

        vm.warp(uint256(expiry) + 1 days);
        vm.startPrank(seller);
        calls.claim(id);
        calls.collectStrike(id);
        vm.stopPrank();
        assertEq(stock.balanceOf(seller), 99 * TOKEN);
        assertEq(usdc.balanceOf(seller), 110 * USD + 3 * USD - 30_000);
        assertEq(stock.balanceOf(address(calls)), TOKEN); // still owed to the buyer
    }

    // ---- fuzz: amounts ----

    function testFuzz_premiumStrikeAndFeeAllRoundUp(uint256 amount, uint256 premiumPerToken, uint256 strikePerToken)
        public
    {
        amount = bound(amount, 1, 10 * TOKEN);
        premiumPerToken = bound(premiumPerToken, 1, 10_000 * USD);
        strikePerToken = bound(strikePerToken, 1, 100_000 * USD);
        vm.prank(seller);
        uint256 id = calls.list(10 * TOKEN, strikePerToken, premiumPerToken, expiry);
        usdc.mint(buyer, 10_000_000_000 * USD);

        uint256 premium = calls.premiumFor(id, amount);
        assertGe(premium * TOKEN, amount * premiumPerToken);
        assertLt(premium * TOKEN, amount * premiumPerToken + TOKEN);

        _fill(buyer, id, amount);
        uint256 fee = (premium + 99) / 100;
        assertEq(staking.deposited(), fee);
        assertEq(usdc.balanceOf(seller), premium - fee);
        assertGe(fee * 100, premium);
        assertLt(fee * 100, premium + 100);

        uint256 strike = calls.strikeFor(id, amount);
        assertGe(strike * TOKEN, amount * strikePerToken);
        assertLt(strike * TOKEN, amount * strikePerToken + TOKEN);
    }
}
```

### `contracts/covered-calls/test/CoveredCallsV1.rules.t.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {CoveredCallsV1} from "../src/CoveredCallsV1.sol";
import {B20Double, StakingDouble, UsdcDouble} from "./doubles/Doubles.sol";

/// @notice The Friday 21:00 UTC expiry rule, the fee rounding up, and the `claimable` view, from the
///         adversarial review's third pass (28 Oct 2026): attack attempts and independent
///         recomputations, each checked to fail on a deliberately broken contract.
contract CoveredCallsV1RulesTest is Test {
    uint256 internal constant TOKEN = 1e8;
    uint256 internal constant USD = 1e6;
    /// 2026-10-30 21:00:00 UTC, a Friday (checked independently with Python's calendar).
    uint64 internal constant FRI_2026_10_30_2100 = 1_793_394_000;

    B20Double internal stock;
    UsdcDouble internal usdc;
    StakingDouble internal staking;
    CoveredCallsV1 internal calls;

    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_793_000_000); // Sunday 2026-10-26
        stock = new B20Double();
        usdc = new UsdcDouble();
        staking = new StakingDouble(usdc);
        calls = new CoveredCallsV1(address(stock), address(usdc), address(staking));
        stock.mint(seller, 1_000 * TOKEN);
        address[3] memory accounts = [seller, buyer, stranger];
        for (uint256 i; i < 3; ++i) {
            usdc.mint(accounts[i], 1_000_000_000 * USD);
            vm.startPrank(accounts[i]);
            stock.approve(address(calls), type(uint256).max);
            usdc.approve(address(calls), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _list(uint256 amount, uint256 premiumPerToken, uint64 expiry) internal returns (uint256 id) {
        vm.prank(seller);
        id = calls.list(amount, 110 * USD, premiumPerToken, expiry);
    }

    // ---- 1. weekly expiry ----

    /// Calendar weekday (0 = Sunday … 5 = Friday) and second of day, worked out independently.
    function _weekday(uint256 t) internal pure returns (uint256) {
        return (t / 1 days + 4) % 7; // 1970-01-01 was a Thursday (4)
    }

    function test_3p_onlyFridayAt2100UtcIsAccepted() public {
        assertEq(_weekday(FRI_2026_10_30_2100), 5);
        assertEq(FRI_2026_10_30_2100 % 1 days, 21 hours);
        _list(TOKEN, 3 * USD, FRI_2026_10_30_2100);
        _list(TOKEN, 3 * USD, FRI_2026_10_30_2100 + 1 weeks);

        uint64[6] memory refused = [
            FRI_2026_10_30_2100 - 1,
            FRI_2026_10_30_2100 + 1,
            FRI_2026_10_30_2100 - 1 hours, // the US close in summer (20:00 UTC)
            FRI_2026_10_30_2100 - 1 days, // Thursday 21:00
            FRI_2026_10_30_2100 + 1 days, // Saturday 21:00
            FRI_2026_10_30_2100 + 3 days + 12 hours // Monday 09:00
        ];
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(seller);
            vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.NotAWeeklyExpiry.selector, refused[i]));
            calls.list(TOKEN, 110 * USD, 3 * USD, refused[i]);
        }
    }

    /// Any expiry the contract accepts is a future Friday at exactly 21:00:00 UTC, and every future
    /// Friday 21:00 is accepted, up to the largest one a uint64 can hold.
    function testFuzz_3p_acceptedExactlyWhenAFutureFridayAt2100(uint64 expiry, uint8 snap) public {
        // Most draws snap near some week's 1 day 21 hours mark (exact, or off by a second or an
        // hour), so the accepted branch is exercised, not just the 1-in-604,800 random hit.
        if (snap % 4 != 0 && expiry > 2 weeks) {
            uint256 snapped = uint256(expiry) - uint256(expiry) % 1 weeks + 1 days + 21 hours;
            int256[4] memory nudge = [int256(0), int256(-1), int256(1), int256(-1 hours)];
            expiry = uint64(uint256(int256(snapped) + nudge[(snap >> 2) % 4]) - 1 weeks);
        }
        bool friday2100 = _weekday(expiry) == 5 && expiry % 1 days == 21 hours;
        bool future = expiry > block.timestamp;
        vm.prank(seller);
        try calls.list(1, 110 * USD, 3 * USD, expiry) {
            assertTrue(friday2100 && future);
        } catch {
            assertFalse(friday2100 && future);
        }
    }

    function test_3p_largestWeeklyExpiryStillWorksThroughTheWindow() public {
        uint64 last = uint64(type(uint64).max - (type(uint64).max - 1 days - 21 hours) % 1 weeks);
        assertEq(_weekday(last), 5);
        uint256 id = _list(TOKEN, 3 * USD, last);
        vm.prank(buyer);
        calls.fill(id, TOKEN);
        vm.warp(uint256(last) + 1 days);
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 1_000 * TOKEN);
    }

    /// The window is Friday 21:00 to Saturday 21:00 UTC. A corporate action effective Saturday
    /// 20:59:59 is refused; one effective at Saturday 21:00 or Monday's open is allowed.
    function test_3p_corporateActionAgainstTheWeekendWindow() public {
        uint64 e = FRI_2026_10_30_2100;
        stock.schedule(uint256(e) + 1 days - 1);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(CoveredCallsV1.CorporateActionScheduled.selector, uint256(e) + 1 days - 1)
        );
        calls.list(TOKEN, 110 * USD, 3 * USD, e);
        stock.schedule(uint256(e) + 1 days);
        _list(TOKEN, 3 * USD, e);
        stock.schedule(uint256(e) + 2 days + 16 hours + 30 minutes); // Monday 13:30 UTC
        _list(TOKEN, 3 * USD, e);
    }

    // ---- 2. fee rounds up ----

    /// A 1 micro-USDC premium is all fee: the seller gets 0 (a zero-value transfer that succeeds).
    function test_3p_oneMicroPremiumIsAllFee() public {
        uint256 id = _list(10 * TOKEN, 3 * USD, FRI_2026_10_30_2100);
        uint256 before = usdc.balanceOf(seller);
        vm.prank(buyer);
        calls.fill(id, 1); // premium ceil(1 * 3e6 / 1e8) = 1
        assertEq(staking.deposited(), 1);
        assertEq(usdc.balanceOf(seller), before);
        assertEq(calls.held(id, buyer), 1);
    }

    /// Fee is ceil(1%), never more than the premium, and premium = seller + staking exactly, for
    /// every premium from 1 micro-USDC up.
    function testFuzz_3p_feeIsCeilOnePercentAndNeverExceedsThePremium(uint256 amount, uint256 premiumPerToken) public {
        amount = bound(amount, 1, 1_000 * TOKEN);
        premiumPerToken = bound(premiumPerToken, 1, 100_000 * USD);
        uint256 id = _list(1_000 * TOKEN, premiumPerToken, FRI_2026_10_30_2100);
        uint256 premium = calls.premiumFor(id, amount);
        uint256 sellerBefore = usdc.balanceOf(seller);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        calls.fill(id, amount);
        uint256 fee = staking.deposited();
        assertLe(fee, premium);
        assertGe(fee * 100, premium);
        assertLt(fee * 100, premium + 100);
        assertEq(buyerBefore - usdc.balanceOf(buyer), premium);
        assertEq(usdc.balanceOf(seller) - sellerBefore + fee, premium);
        assertEq(usdc.balanceOf(address(calls)), 0);
        assertEq(usdc.allowance(address(calls), address(staking)), 0);
    }

    /// Informational: with the fee never zero, a refusing staking contract now stops every fill,
    /// including the tiny ones that used to carry no fee.
    function test_3p_stakingRefusalNowStopsEvenTinyFills() public {
        uint256 id = _list(10 * TOKEN, 3 * USD, FRI_2026_10_30_2100);
        staking.setRefuses(true);
        vm.prank(buyer);
        vm.expectRevert(bytes("staking paused"));
        calls.fill(id, 1);
    }

    // ---- 3. claimable equals what claim pays ----

    function _checkClaimableMatchesClaim(uint256[] memory ids) internal {
        address[3] memory who = [seller, buyer, stranger];
        uint256[3][] memory shown = new uint256[3][](ids.length);
        for (uint256 j; j < ids.length; ++j) {
            for (uint256 k; k < 3; ++k) {
                shown[j][k] = calls.claimable(ids[j], who[k]);
            }
        }
        for (uint256 j; j < ids.length; ++j) {
            for (uint256 k; k < 3; ++k) {
                uint256 before = stock.balanceOf(who[k]);
                vm.prank(who[k]);
                try calls.claim(ids[j]) {
                    assertEq(stock.balanceOf(who[k]) - before, shown[j][k], "claim paid other than claimable");
                } catch (bytes memory reason) {
                    assertEq(shown[j][k], 0, "claimable showed stock but claim reverted");
                    assertEq(bytes4(reason), CoveredCallsV1.NothingToCollect.selector);
                }
                assertEq(calls.claimable(ids[j], who[k]), 0, "claimable not zero right after a claim");
            }
        }
    }

    /// Two listings (one where the seller is also a holder), random fractional fills, cancels at
    /// random stages, exercises, and claimable checked against claim at five moments.
    function testFuzz_3p_claimableIsWhatClaimPays(uint256 seed) public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = _list(10 * TOKEN + seed % 1e8, 3 * USD, FRI_2026_10_30_2100);
        ids[1] = _list(7 * TOKEN + (seed >> 30) % 1e8, 1, FRI_2026_10_30_2100);
        address[3] memory who = [seller, buyer, stranger];

        for (uint256 i; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 id = ids[seed % 2];
            CoveredCallsV1.Listing memory l = calls.listings(id);
            if (l.amount == l.filled) continue;
            vm.prank(who[(seed >> 4) % 3]);
            calls.fill(id, bound(seed >> 8, 1, l.amount - l.filled));
        }
        if (seed % 3 == 0) _tryCancel(ids[0]);
        _checkClaimableMatchesClaim(ids);

        vm.warp(FRI_2026_10_30_2100 + (seed >> 20) % 1 days);
        if (seed % 3 == 1) _tryCancel(ids[1]);
        for (uint256 j; j < 2; ++j) {
            for (uint256 k; k < 3; ++k) {
                uint256 h = calls.held(ids[j], who[k]);
                uint256 x = h == 0 ? 0 : bound(uint256(keccak256(abi.encode(seed, j, k))), 0, h);
                if (x == 0) continue;
                vm.prank(who[k]);
                calls.exercise(ids[j], x);
            }
        }
        _checkClaimableMatchesClaim(ids);

        vm.warp(uint256(FRI_2026_10_30_2100) + 1 days - 1);
        _checkClaimableMatchesClaim(ids);
        vm.warp(uint256(FRI_2026_10_30_2100) + 1 days);
        if (seed % 3 == 2) _tryCancel(ids[0]);
        _checkClaimableMatchesClaim(ids);
        _tryCancel(ids[1]);
        _checkClaimableMatchesClaim(ids);
        assertEq(stock.balanceOf(address(calls)), 0);
    }

    function _tryCancel(uint256 id) internal {
        vm.prank(seller);
        try calls.cancel(id) {} catch {}
    }

    /// Informational: `claimable` reports what is owed, not whether the transfer can go through
    /// now; while the stock is paused it shows 10 tokens and `claim` reverts.
    function test_3p_claimableShowsOwedEvenWhileTheStockIsPaused() public {
        uint256 id = _list(10 * TOKEN, 3 * USD, FRI_2026_10_30_2100);
        vm.warp(uint256(FRI_2026_10_30_2100) + 1 days);
        stock.setPaused(true);
        assertEq(calls.claimable(id, seller), 10 * TOKEN);
        vm.prank(seller);
        vm.expectRevert();
        calls.claim(id);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.UnknownListing.selector, 99));
        calls.claimable(99, seller);
    }
}
```

### `contracts/covered-calls/test/CoveredCallsV1.ordering.t.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {CoveredCallsV1} from "../src/CoveredCallsV1.sol";
import {B20Double, StakingDouble, UsdcDouble} from "./doubles/Doubles.sol";
import {WeeklyExpiry} from "./doubles/WeeklyExpiry.sol";

/// @notice Cancel, claim and the after-window return in every order, from the adversarial review's
///         second pass (28 Oct 2026). Each test is an attack on paying a unit twice, touching another
///         listing or another account, or blocking a party; each was checked to fail on a
///         deliberately broken contract.
contract CoveredCallsV1OrderingTest is Test {
    uint256 internal constant TOKEN = 1e8;
    uint256 internal constant USD = 1e6;
    uint64 internal expiry;
    uint256 internal windowEnd;

    B20Double internal stock;
    UsdcDouble internal usdc;
    StakingDouble internal staking;
    CoveredCallsV1 internal calls;

    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");
    address internal bystander = makeAddr("bystander");

    function setUp() public {
        vm.warp(1_800_000_000);
        expiry = WeeklyExpiry.next(block.timestamp, 0);
        windowEnd = uint256(expiry) + 1 days;
        stock = new B20Double();
        usdc = new UsdcDouble();
        staking = new StakingDouble(usdc);
        calls = new CoveredCallsV1(address(stock), address(usdc), address(staking));

        stock.mint(seller, 100 * TOKEN);
        // Another seller's listing, so any overpayment to our seller would find stock to take.
        stock.mint(bystander, 50 * TOKEN);
        vm.startPrank(bystander);
        stock.approve(address(calls), type(uint256).max);
        calls.list(50 * TOKEN, 110 * USD, 3 * USD, WeeklyExpiry.next(block.timestamp, 4));
        vm.stopPrank();
        address[3] memory accounts = [seller, buyer, stranger];
        for (uint256 i; i < 3; ++i) {
            usdc.mint(accounts[i], 1_000_000 * USD);
            vm.startPrank(accounts[i]);
            stock.approve(address(calls), type(uint256).max);
            usdc.approve(address(calls), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// The after-window return already includes the never-cancelled remainder, so a cancel after it
    /// must not credit that remainder again (which would pay it out of the bystander's listing).
    function test_2p_cancelAfterTheReturnCannotDrainAnotherListing() public {
        uint256 id = _list(10 * TOKEN);
        _as(buyer);
        calls.fill(id, 4 * TOKEN);
        vm.warp(windowEnd);
        _as(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 100 * TOKEN);
        _as(seller);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.cancel(id);
        assertEq(stock.balanceOf(address(calls)), 50 * TOKEN);
    }

    function _list(uint256 amount) internal returns (uint256 id) {
        vm.prank(seller);
        id = calls.list(amount, 110 * USD, 3 * USD, expiry);
    }

    function _as(address who) internal {
        vm.prank(who);
    }

    /// Cancel, claim the cancelled part inside the window, then the after-window return: each unit
    /// once, and nothing a holder is owed reaches the seller.
    function test_2p_cancelThenClaimThenAfterWindowPaysEachUnitOnce() public {
        uint256 id = _list(10 * TOKEN);
        _as(buyer);
        calls.fill(id, 4 * TOKEN);
        _as(seller);
        calls.cancel(id);
        assertEq(calls.owed(id, seller), 6 * TOKEN);

        vm.warp(expiry);
        _as(seller);
        calls.claim(id); // the cancelled six, inside the window: no after-window booking yet
        assertEq(stock.balanceOf(seller), 96 * TOKEN);
        assertFalse(calls.listings(id).stockReturned);
        _as(buyer);
        calls.exercise(id, 1 * TOKEN);

        vm.warp(windowEnd);
        _as(seller);
        calls.claim(id); // the three sold and not exercised
        assertEq(stock.balanceOf(seller), 99 * TOKEN);

        _as(seller);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.cancel(id);
        _as(seller);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id);
        assertEq(stock.balanceOf(address(calls)), 51 * TOKEN); // still the buyer's
        _as(buyer);
        calls.claim(id);
        assertEq(stock.balanceOf(address(calls)), 50 * TOKEN);
    }

    /// Cancel after the window closes but before the seller's first claim: the uncancelled remainder
    /// is not counted twice (once by cancel, once by the after-window return).
    function test_2p_cancelAfterTheWindowBeforeClaimCountsEachUnitOnce() public {
        uint256 id = _list(10 * TOKEN);
        _as(buyer);
        calls.fill(id, 4 * TOKEN);
        vm.warp(windowEnd + 7 days);
        _as(seller);
        calls.cancel(id);
        _as(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 100 * TOKEN);
        assertEq(stock.balanceOf(address(calls)), 50 * TOKEN);
    }

    /// A seller who is also a holder on its own listing shares one `owed` balance; the sum is exact
    /// and the other holder's stock is untouched.
    function test_2p_sellerWhoIsAlsoAHolderGetsExactlyItsOwn() public {
        uint256 id = _list(10 * TOKEN);
        _as(seller);
        calls.fill(id, 4 * TOKEN);
        _as(buyer);
        calls.fill(id, 3 * TOKEN);
        _as(seller);
        calls.cancel(id); // 3 unsold
        vm.warp(expiry);
        _as(seller);
        calls.exercise(id, 2 * TOKEN);
        _as(buyer);
        calls.exercise(id, 1 * TOKEN);

        _as(seller);
        calls.claim(id); // 3 cancelled + 2 exercised
        assertEq(stock.balanceOf(seller), 95 * TOKEN);

        vm.warp(windowEnd);
        _as(seller);
        calls.claim(id); // 7 listed after cancel - 3 exercised = 4 (2 of the seller's own calls, 2 of the buyer's)
        assertEq(stock.balanceOf(seller), 99 * TOKEN);
        assertEq(calls.owed(id, buyer), 1 * TOKEN);
        assertEq(stock.balanceOf(address(calls)), 51 * TOKEN);
    }

    /// A seller who never claims keeps nobody else waiting: holders claim, the strike is collected,
    /// and the contract holds exactly the seller's unexercised stock, forever claimable.
    function test_2p_sellerWhoNeverClaimsBlocksNobody() public {
        uint256 id = _list(10 * TOKEN);
        _as(buyer);
        calls.fill(id, 5 * TOKEN);
        vm.warp(expiry);
        _as(buyer);
        calls.exercise(id, 2 * TOKEN);
        vm.warp(windowEnd + 3650 days);
        _as(buyer);
        calls.claim(id);
        _as(seller);
        calls.collectStrike(id);
        assertEq(stock.balanceOf(address(calls)), 58 * TOKEN);
        assertEq(usdc.balanceOf(address(calls)), 0);
        _as(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 98 * TOKEN);
    }

    /// Nobody but the seller can trigger the after-window booking, and a stranger's claim changes
    /// nothing.
    function test_2p_strangerClaimCannotTouchTheListing() public {
        uint256 id = _list(10 * TOKEN);
        _as(buyer);
        calls.fill(id, 5 * TOKEN);
        vm.warp(windowEnd);
        _as(stranger);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id);
        _as(buyer);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id); // unexercised calls are worth nothing after the window
        assertFalse(calls.listings(id).stockReturned);
        assertEq(calls.owed(id, seller), 0);
    }

    /// The window boundary is shared exactly: at `expiry + 1 day` exercising is closed and the
    /// return opens, never both in one second.
    function test_2p_returnOpensTheSecondExercisingCloses() public {
        uint256 id = _list(10 * TOKEN);
        _as(buyer);
        calls.fill(id, 10 * TOKEN);
        vm.warp(windowEnd - 1);
        _as(seller);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id);
        vm.warp(windowEnd);
        _as(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.OutsideExerciseWindow.selector, expiry));
        calls.exercise(id, 1);
        _as(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 100 * TOKEN);
    }

    /// Informational for the indexer: when every sold unit was exercised but a cancelled remainder is
    /// still owed, the seller's after-window claim emits `StockReturned(id, 0)` before `Claimed`.
    /// And until that claim, `owed(id, seller)` shows only the cancelled part, not the stock due back.
    function test_2p_indexerSeesAZeroStockReturnedAndALazyOwed() public {
        uint256 id = _list(10 * TOKEN);
        _as(buyer);
        calls.fill(id, 4 * TOKEN);
        _as(seller);
        calls.cancel(id);
        vm.warp(expiry);
        _as(buyer);
        calls.exercise(id, 4 * TOKEN);
        vm.warp(windowEnd);

        vm.expectEmit(address(calls));
        emit CoveredCallsV1.StockReturned(id, 0);
        vm.expectEmit(address(calls));
        emit CoveredCallsV1.Claimed(id, seller, 6 * TOKEN);
        _as(seller);
        calls.claim(id);

        // After its window, `owed` shows 0 for the seller of an unsold listing although 5 tokens are
        // due; `claimable` shows the 5 that `claim` will pay.
        vm.prank(seller);
        uint64 expiry2 = WeeklyExpiry.next(block.timestamp, 0);
        uint256 id2 = calls.list(5 * TOKEN, 110 * USD, 3 * USD, expiry2);
        vm.warp(uint256(expiry2) + calls.EXERCISE_WINDOW());
        assertEq(calls.owed(id2, seller), 0);
        assertEq(calls.claimable(id2, seller), 5 * TOKEN);
        assertEq(calls.claimable(id2, buyer), 0);
        _as(seller);
        calls.claim(id2);
        assertEq(stock.balanceOf(seller), 100 * TOKEN - 4 * TOKEN);
    }

    /// Model check: random fractional fills by the seller and two others, cancel at a random point
    /// (before, during or after the window), exercises, and claims in random order and repetition.
    /// Every account ends with exactly its own stock and the contract ends empty.
    function testFuzz_2p_everyUnitPaidOnceWhateverTheOrder(uint256 seed) public {
        uint256 listed = 10 * TOKEN + (seed % 1e8);
        uint256 id = _list(listed);
        address[3] memory who = [seller, buyer, stranger];
        uint256[3] memory exercisedBy;
        uint256 cancelStage = seed % 4; // 0 none, 1 before expiry, 2 inside window, 3 after window

        for (uint256 i; i < 6; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            CoveredCallsV1.Listing memory l = calls.listings(id);
            if (l.amount == l.filled) break;
            _as(who[seed % 3]);
            calls.fill(id, bound(seed >> 8, 1, l.amount - l.filled));
        }
        if (cancelStage == 1) _tryCancel(id);
        _tryClaimAll(id, seed);

        vm.warp(uint256(expiry) + (seed >> 40) % 1 days);
        if (cancelStage == 2) _tryCancel(id);
        for (uint256 k; k < 3; ++k) {
            uint256 h = calls.held(id, who[k]);
            uint256 x = h == 0 ? 0 : bound(uint256(keccak256(abi.encode(seed, k))), 0, h);
            if (x == 0) continue;
            exercisedBy[k] = x;
            _as(who[k]);
            calls.exercise(id, x);
        }
        _tryClaimAll(id, seed >> 3);

        vm.warp(windowEnd + (seed >> 80) % 30 days);
        if (cancelStage == 3) _tryCancel(id);
        _tryClaimAll(id, seed >> 5);
        _tryClaimAll(id, seed >> 7);
        _tryCancel(id);
        _tryClaimAll(id, seed >> 9);

        uint256 exercisedTotal = exercisedBy[0] + exercisedBy[1] + exercisedBy[2];
        assertEq(stock.balanceOf(seller), 100 * TOKEN - exercisedTotal + exercisedBy[0]);
        assertEq(stock.balanceOf(buyer), exercisedBy[1]);
        assertEq(stock.balanceOf(stranger), exercisedBy[2]);
        assertEq(stock.balanceOf(address(calls)), 50 * TOKEN); // only the bystander's listing
        assertTrue(calls.listings(id).stockReturned || calls.listings(id).amount == calls.listings(id).exercised);
    }

    function _tryCancel(uint256 id) internal {
        _as(seller);
        try calls.cancel(id) {} catch {}
    }

    function _tryClaimAll(uint256 id, uint256 order) internal {
        address[3] memory who = [seller, buyer, stranger];
        for (uint256 k; k < 3; ++k) {
            _as(who[(order + k) % 3]);
            try calls.claim(id) {} catch {}
        }
    }
}
```

### `contracts/covered-calls/test/CoveredCallsV1.recovery.t.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {CoveredCallsV1} from "../src/CoveredCallsV1.sol";
import {B20Double, StakingDouble, UsdcDouble} from "./doubles/Doubles.sol";
import {WeeklyExpiry} from "./doubles/WeeklyExpiry.sol";

/// @notice What the tokens, the issuer, Circle and staking can refuse, and how each party still
///         recovers what is theirs. From the adversarial review of 28 Oct 2026: the five `F1`/`F2`
///         tests failed on the first version, where `cancel` returned stock and `settle` paid USDC
///         and stock in one call, so a block on one token held up the other; the rest pin behaviour
///         the review checked.
contract CoveredCallsV1RecoveryTest is Test {
    uint256 internal constant TOKEN = 1e8;
    uint256 internal constant USD = 1e6;
    uint256 internal constant ACTORS = 5;
    uint64 internal expiry;

    B20Double internal stock;
    UsdcDouble internal usdc;
    StakingDouble internal staking;
    CoveredCallsV1 internal calls;

    address internal seller = makeAddr("seller");
    address internal buyer;
    address[] internal actors;

    function setUp() public {
        vm.warp(1_800_000_000);
        expiry = WeeklyExpiry.next(block.timestamp, 0);
        stock = new B20Double();
        usdc = new UsdcDouble();
        staking = new StakingDouble(usdc);
        calls = new CoveredCallsV1(address(stock), address(usdc), address(staking));

        stock.mint(seller, 1_000 * TOKEN);
        usdc.mint(seller, 1_000_000 * USD);
        vm.startPrank(seller);
        stock.approve(address(calls), type(uint256).max);
        usdc.approve(address(calls), type(uint256).max);
        vm.stopPrank();
        for (uint256 i; i < ACTORS; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            usdc.mint(a, 100_000_000 * USD);
            vm.prank(a);
            usdc.approve(address(calls), type(uint256).max);
        }
        buyer = actors[0];
    }

    /// 110 USDC strike and 3 USDC premium per token.
    function _list(uint256 amount) internal returns (uint256 id) {
        vm.prank(seller);
        id = calls.list(amount, 110 * USD, 3 * USD, expiry);
    }

    // ---- F1: the seller can always stop sales ----

    function test_F1_sellerCancelsWhileStockIsPausedAndBuyersCannotFillAfter() public {
        uint256 id = _list(10 * TOKEN);
        stock.setPaused(true);
        vm.prank(seller);
        calls.cancel(id);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.ExceedsAvailable.selector, 1, 0));
        calls.fill(id, 1);

        stock.setPaused(false);
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 1_000 * TOKEN);
    }

    function test_F1_blocklistedSellerCanStillStopSales() public {
        uint256 id = _list(10 * TOKEN);
        stock.setBlocked(seller, true);
        vm.prank(seller);
        calls.cancel(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.ExceedsAvailable.selector, 1, 0));
        calls.fill(id, 1);
        assertEq(calls.owed(id, seller), 10 * TOKEN);
    }

    // ---- F2: a block on one token never holds up the other ----

    function test_F2_usdcBlacklistedSellerStillRecoversUnexercisedStock() public {
        uint256 id = _list(10 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, 10 * TOKEN);
        vm.warp(expiry);
        vm.prank(buyer);
        calls.exercise(id, TOKEN); // 110 USDC strike waits in the contract

        usdc.setBlacklisted(seller, true);
        vm.warp(uint256(expiry) + calls.EXERCISE_WINDOW());
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 999 * TOKEN);
        assertEq(usdc.balanceOf(address(calls)), 110 * USD);
    }

    function test_F2_stockBlocklistedSellerStillCollectsTheStrike() public {
        uint256 id = _list(10 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, 10 * TOKEN);
        vm.warp(uint256(expiry) + calls.EXERCISE_WINDOW() - 1); // exercised in the last second
        vm.prank(buyer);
        calls.exercise(id, TOKEN);

        stock.setBlocked(seller, true);
        vm.warp(uint256(expiry) + calls.EXERCISE_WINDOW());
        uint256 before = usdc.balanceOf(seller);
        vm.prank(seller);
        calls.collectStrike(id);
        assertEq(usdc.balanceOf(seller) - before, 110 * USD);
    }

    function test_F2_stockPauseAfterTheWindowNeverHoldsTheSellersUsdc() public {
        uint256 id = _list(10 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, 10 * TOKEN);
        vm.warp(expiry);
        vm.prank(buyer);
        calls.exercise(id, TOKEN);

        vm.warp(uint256(expiry) + calls.EXERCISE_WINDOW());
        stock.setPaused(true);
        uint256 before = usdc.balanceOf(seller);
        vm.prank(seller);
        calls.collectStrike(id);
        assertEq(usdc.balanceOf(seller) - before, 110 * USD);
    }

    // ---- time boundaries ----

    function test_boundariesAreDisjointAndExact() public {
        uint256 id = _list(10 * TOKEN);
        uint256 windowEnd = uint256(expiry) + calls.EXERCISE_WINDOW();

        vm.warp(uint256(expiry) - 1);
        vm.prank(buyer);
        calls.fill(id, 2 * TOKEN); // last fill second

        vm.warp(expiry);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.FillsClosed.selector, expiry));
        calls.fill(id, 1);
        vm.prank(buyer);
        calls.exercise(id, 1); // first exercise second

        vm.startPrank(seller);
        calls.collectStrike(id);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id); // the stock does not return inside the window
        vm.stopPrank();

        vm.warp(windowEnd - 1);
        vm.prank(buyer);
        calls.exercise(id, 1); // last exercise second

        vm.warp(windowEnd);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.OutsideExerciseWindow.selector, expiry));
        calls.exercise(id, 1);

        vm.prank(seller);
        calls.claim(id); // first second the stock returns
        assertEq(stock.balanceOf(seller), 1_000 * TOKEN - 2);
        assertEq(stock.balanceOf(address(calls)), 2); // exercised, owed to the buyer
        vm.prank(seller);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id); // never twice
    }

    /// A change taking effect the second exercising closes is allowed; one second earlier is refused;
    /// `effectiveAt == now` counts as already in effect, as B20 refuses scheduling at `now`
    /// (`EffectiveAtInPast` when `effectiveAt <= block.timestamp`).
    function test_corporateActionBoundaries() public {
        uint256 windowEnd = uint256(expiry) + calls.EXERCISE_WINDOW();
        stock.schedule(windowEnd);
        _list(TOKEN);
        stock.schedule(windowEnd - 1);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.CorporateActionScheduled.selector, windowEnd - 1));
        calls.list(TOKEN, 110 * USD, 3 * USD, expiry);
        stock.schedule(block.timestamp);
        _list(TOKEN);
    }

    /// A change scheduled after listing stops fills until it takes effect; prices are per raw unit, so
    /// the listing's terms keep their value across it and fills resume.
    function test_fillsResumeOnAListingOnceItsCorporateActionHasTakenEffect() public {
        uint256 id = _list(10 * TOKEN);
        uint256 at = block.timestamp + 1 hours;
        stock.schedule(at);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.CorporateActionScheduled.selector, at));
        calls.fill(id, TOKEN);
        vm.warp(at);
        vm.prank(buyer);
        calls.fill(id, TOKEN);
        assertEq(calls.held(id, buyer), TOKEN);
    }

    // ---- the fee ----

    function test_feeIsPaidOnceAndNoAllowanceIsLeftBehind() public {
        uint256 id = _list(10 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, 10 * TOKEN); // premium 30 USDC
        assertEq(staking.deposited(), 300_000);
        assertEq(usdc.balanceOf(seller), 1_000_000 * USD + 30 * USD - 300_000);
        assertEq(usdc.allowance(address(calls), address(staking)), 0);
        assertEq(usdc.balanceOf(address(calls)), 0);
    }

    /// The fee rounds up, so splitting a fill into dust never avoids it.
    function test_tinyFillStillPaysTheFee() public {
        uint256 id = _list(10 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, 3300); // premium ceil(3300 * 3e6 / 1e8) = 99 micro-USDC
        assertEq(calls.premiumFor(id, 3300), 99);
        assertEq(staking.deposited(), 1);
    }

    /// Staking refusing deposits stops fills that carry a fee; nothing else touches staking.
    function test_stakingRefusalStopsFillsButNeverRecovery() public {
        uint256 id = _list(10 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, 2 * TOKEN);
        staking.setRefuses(true);
        vm.prank(buyer);
        vm.expectRevert(bytes("staking paused"));
        calls.fill(id, TOKEN);
        vm.warp(expiry);
        vm.startPrank(buyer);
        calls.exercise(id, TOKEN);
        calls.claim(id);
        vm.stopPrank();
        vm.startPrank(seller);
        calls.cancel(id);
        calls.collectStrike(id);
        vm.warp(uint256(expiry) + 1 days);
        calls.claim(id);
        vm.stopPrank();
        assertEq(stock.balanceOf(address(calls)), 0);
        assertEq(usdc.balanceOf(address(calls)), 0);
    }

    /// The 24-hour window is a deadline: if USDC is paused for all of it, no exercise is possible, the
    /// premium stays with the seller and the seller takes the stock back.
    function test_usdcPauseThroughTheWindowForfeitsExercise() public {
        uint256 id = _list(10 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, 10 * TOKEN);
        vm.warp(expiry);
        usdc.setPaused(true);
        vm.prank(buyer);
        vm.expectRevert();
        calls.exercise(id, 10 * TOKEN);
        vm.warp(uint256(expiry) + 1 days);
        usdc.setPaused(false);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.OutsideExerciseWindow.selector, expiry));
        calls.exercise(id, 10 * TOKEN);
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 1_000 * TOKEN);
    }

    // ---- everyone recovers once restrictions lift ----

    /// Random fractional fills by many accounts, exercises, a cancel, strike collected inside and
    /// after the window, while a holder is blocklisted, transfers are paused and the seller is
    /// blacklisted on USDC; once every restriction lifts, every party recovers exactly what is theirs
    /// and the contract ends empty.
    function testFuzz_everyoneRecoversOnceRestrictionsLift(uint256 seed) public {
        uint256 id = _list(37 * TOKEN + 12_345);
        uint256 premiumPaid;
        uint256 exercisedTotal;
        uint256 strikeTotal;
        uint256[ACTORS] memory exercisedBy;

        for (uint256 i; i < 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address a = actors[seed % ACTORS];
            CoveredCallsV1.Listing memory l = calls.listings(id);
            if (l.amount == l.filled) break;
            uint256 amount = bound(seed >> 8, 1, l.amount - l.filled);
            premiumPaid += calls.premiumFor(id, amount);
            vm.prank(a);
            calls.fill(id, amount);
        }
        stock.setPaused(seed % 2 == 0);
        stock.setBlocked(actors[seed % ACTORS], true);
        if (seed % 3 == 0) {
            vm.prank(seller);
            try calls.cancel(id) {} catch {}
        }

        vm.warp(uint256(expiry) + (seed >> 32) % 1 days);
        for (uint256 k; k < ACTORS; ++k) {
            uint256 h = calls.held(id, actors[k]);
            if (h == 0) continue;
            uint256 x = bound(uint256(keccak256(abi.encode(seed, k))), 0, h);
            if (x == 0) continue;
            strikeTotal += calls.strikeFor(id, x);
            exercisedBy[k] = x;
            exercisedTotal += x;
            vm.prank(actors[k]);
            calls.exercise(id, x);
        }
        if (seed % 5 == 0 && strikeTotal != 0) {
            vm.prank(seller);
            calls.collectStrike(id); // inside the window, while the stock may be paused
        }
        usdc.setBlacklisted(seller, seed % 7 == 0);

        vm.warp(uint256(expiry) + 1 days);
        stock.setPaused(false);
        stock.setBlocked(actors[seed % ACTORS], false);
        vm.startPrank(seller);
        try calls.cancel(id) {} catch {}
        CoveredCallsV1.Listing memory end = calls.listings(id);
        if (end.amount != end.exercised || calls.owed(id, seller) != 0) calls.claim(id); // stock never waits on USDC
        usdc.setBlacklisted(seller, false);
        if (calls.listings(id).strikePaid != calls.listings(id).strikeCollected) calls.collectStrike(id);
        vm.stopPrank();
        for (uint256 k; k < ACTORS; ++k) {
            if (calls.owed(id, actors[k]) == 0) continue;
            vm.prank(actors[k]);
            calls.claim(id);
            assertEq(stock.balanceOf(actors[k]), exercisedBy[k]);
        }

        assertEq(stock.balanceOf(address(calls)), 0);
        assertEq(usdc.balanceOf(address(calls)), 0);
        assertEq(stock.balanceOf(seller), 1_000 * TOKEN - exercisedTotal);
        assertEq(usdc.balanceOf(seller), 1_000_000 * USD + premiumPaid - staking.deposited() + strikeTotal);
    }
}
```

### `contracts/covered-calls/test/CoveredCallsV1.invariant.t.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {CoveredCallsV1} from "../src/CoveredCallsV1.sol";
import {B20Double, StakingDouble, UsdcDouble} from "./doubles/Doubles.sol";
import {WeeklyExpiry} from "./doubles/WeeklyExpiry.sol";

/// @notice Drives random sequences of every call by several accounts across time, with the stock's
///         transfer pause and blocklist, USDC's pause and blacklist, scheduled corporate actions and a
///         refusing staking contract switched on and off, and keeps the books the contract must match.
contract CoveredCallsHandler is Test {
    CoveredCallsV1 public immutable calls;
    B20Double public immutable stock;
    UsdcDouble public immutable usdc;
    StakingDouble public immutable staking;

    address[] public actors;
    mapping(uint256 listingId => uint256) public listedOf;
    mapping(uint256 listingId => uint256) public claimedOf;
    uint256 public feesExpected;
    /// Claims that paid something other than what `claimable` showed just before; must stay zero.
    uint256 public claimMismatches;
    /// Successful calls of each kind, so a run that never reaches an action is visible.
    mapping(bytes4 selector => uint256) public succeeded;

    constructor(CoveredCallsV1 calls_, B20Double stock_, UsdcDouble usdc_, StakingDouble staking_) {
        calls = calls_;
        stock = stock_;
        usdc = usdc_;
        staking = staking_;
        for (uint256 i; i < 4; ++i) {
            address actor = address(uint160(0xA000 + i));
            actors.push(actor);
            stock.mint(actor, 1_000e8);
            usdc.mint(actor, 1e15);
            vm.startPrank(actor);
            stock.approve(address(calls), type(uint256).max);
            usdc.approve(address(calls), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _someListing(uint256 seed) internal view returns (uint256) {
        uint256 count = calls.listingCount();
        return count == 0 ? 0 : 1 + seed % count;
    }

    function list(uint256 who, uint256 amount, uint256 strike, uint256 premium, uint256 weeksAhead) external {
        amount = bound(amount, 1, 50e8);
        strike = bound(strike, 1, 1_000e6);
        premium = bound(premium, 1, 100e6);
        uint64 expiry = WeeklyExpiry.next(block.timestamp, bound(weeksAhead, 0, 2));
        vm.prank(_actor(who));
        try calls.list(amount, strike, premium, expiry) returns (uint256 id) {
            listedOf[id] = amount;
            ++succeeded[this.list.selector];
        } catch {}
    }

    function fill(uint256 who, uint256 listingSeed, uint256 amount) external {
        uint256 id = _someListing(listingSeed);
        if (id == 0) return;
        CoveredCallsV1.Listing memory l = calls.listings(id);
        if (l.amount == l.filled) return;
        amount = bound(amount, 1, l.amount - l.filled);
        // The premium, worked out here from the listing's terms, not read from the contract.
        uint256 premium = (amount * l.premiumPerToken + 1e8 - 1) / 1e8;
        vm.prank(_actor(who));
        try calls.fill(id, amount) {
            feesExpected += (premium + 99) / 100;
            ++succeeded[this.fill.selector];
        } catch {}
    }

    function cancel(uint256 listingSeed) external {
        uint256 id = _someListing(listingSeed);
        if (id == 0) return;
        vm.prank(calls.listings(id).seller);
        try calls.cancel(id) {
            ++succeeded[this.cancel.selector];
        } catch {}
    }

    function exercise(uint256 who, uint256 listingSeed, uint256 amount, uint256 into) external {
        uint256 id = _someListing(listingSeed);
        if (id == 0) return;
        address holder = _actor(who);
        uint256 holding = calls.held(id, holder);
        if (holding == 0) return;
        // Time only moves forward: step into the listing's exercise window when it is still ahead.
        uint256 expiry = calls.listings(id).expiry;
        if (block.timestamp < expiry) vm.warp(expiry + bound(into, 0, 1 days - 1));
        vm.prank(holder);
        try calls.exercise(id, bound(amount, 1, holding)) {
            ++succeeded[this.exercise.selector];
        } catch {}
    }

    /// Half the time the seller claims, stepping past the window first when asked; otherwise an
    /// account owed stock on the listing claims.
    function claim(uint256 who, uint256 listingSeed, bool sellerAfterWindow) external {
        uint256 id = _someListing(listingSeed);
        if (id == 0) return;
        address account;
        if (who % 2 == 0) {
            account = calls.listings(id).seller;
            uint256 windowEnd = uint256(calls.listings(id).expiry) + calls.EXERCISE_WINDOW();
            if (sellerAfterWindow && block.timestamp < windowEnd) vm.warp(windowEnd);
        } else {
            account = _actor(who);
            for (uint256 i; i < actors.length && calls.owed(id, account) == 0; ++i) {
                account = _actor(who % actors.length + i);
            }
        }
        uint256 before = stock.balanceOf(account);
        uint256 shown = calls.claimable(id, account);
        vm.prank(account);
        try calls.claim(id) {
            uint256 paid = stock.balanceOf(account) - before;
            claimedOf[id] += paid;
            if (paid != shown) ++claimMismatches;
            ++succeeded[this.claim.selector];
        } catch {}
    }

    function collectStrike(uint256 listingSeed) external {
        uint256 id = _someListing(listingSeed);
        if (id == 0) return;
        vm.prank(calls.listings(id).seller);
        try calls.collectStrike(id) {
            ++succeeded[this.collectStrike.selector];
        } catch {}
    }

    function passTime(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 6 hours));
    }

    /// Switches one restriction on (one time in four) or off: the stock's transfer pause or blocklist
    /// on an actor, USDC's pause or blacklist on an actor, or staking refusing deposits.
    function restrict(uint256 seed, uint256 who) external {
        bool on = seed % 4 == 0;
        uint256 kind = (seed / 4) % 5;
        if (kind == 0) stock.setPaused(on);
        else if (kind == 1) stock.setBlocked(_actor(who), on);
        else if (kind == 2) usdc.setPaused(on);
        else if (kind == 3) usdc.setBlacklisted(_actor(who), on);
        else staking.setRefuses(on);
    }

    /// Schedules a corporate action up to 20 days out one time in eight, and otherwise clears it.
    function scheduleCorporateAction(uint256 inSeconds) external {
        stock.schedule(inSeconds % 8 == 0 ? block.timestamp + bound(inSeconds, 0, 20 days) : 0);
    }

    /// Lifts every restriction, moves past every exercise window and has every account take all it is
    /// owed. Called once a run ends.
    function recoverEverything() external {
        stock.setPaused(false);
        usdc.setPaused(false);
        for (uint256 a; a < actors.length; ++a) {
            stock.setBlocked(actors[a], false);
            usdc.setBlacklisted(actors[a], false);
        }
        vm.warp(block.timestamp + 22 days + calls.EXERCISE_WINDOW());
        for (uint256 id = 1; id <= calls.listingCount(); ++id) {
            CoveredCallsV1.Listing memory l = calls.listings(id);
            if (l.strikePaid != l.strikeCollected) {
                vm.prank(l.seller);
                calls.collectStrike(id);
            }
            for (uint256 a; a < actors.length; ++a) {
                address account = actors[a];
                bool sellerStockDue = account == l.seller && !l.stockReturned && l.amount != l.exercised;
                if (calls.owed(id, account) != 0 || sellerStockDue) {
                    uint256 before = stock.balanceOf(account);
                    vm.prank(account);
                    calls.claim(id);
                    claimedOf[id] += stock.balanceOf(account) - before;
                }
            }
        }
    }
}

contract CoveredCallsV1InvariantTest is Test {
    CoveredCallsV1 internal calls;
    B20Double internal stock;
    UsdcDouble internal usdc;
    StakingDouble internal staking;
    CoveredCallsHandler internal handler;
    uint256 internal stockSupply;
    uint256 internal usdcSupply;

    function setUp() public {
        vm.warp(1_800_000_000);
        stock = new B20Double();
        usdc = new UsdcDouble();
        staking = new StakingDouble(usdc);
        calls = new CoveredCallsV1(address(stock), address(usdc), address(staking));
        handler = new CoveredCallsHandler(calls, stock, usdc, staking);
        stockSupply = stock.totalSupply();
        usdcSupply = usdc.totalSupply();
        bytes4[] memory endOnly = new bytes4[](1);
        endOnly[0] = handler.recoverEverything.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: endOnly}));
        targetContract(address(handler));
    }

    /// The contract holds exactly the stock it still owes: every listing's unexercised stock until it
    /// is returned to the seller, plus everything any account may still claim.
    function invariant_stockHeldEqualsStockOwed() public view {
        uint256 owedTotal;
        for (uint256 id = 1; id <= calls.listingCount(); ++id) {
            CoveredCallsV1.Listing memory l = calls.listings(id);
            if (!l.stockReturned) owedTotal += l.amount - l.exercised;
            for (uint256 a; a < handler.actorCount(); ++a) {
                owedTotal += calls.owed(id, handler.actors(a));
            }
        }
        assertEq(stock.balanceOf(address(calls)), owedTotal);
    }

    /// The contract holds exactly the strike paid and not yet collected; premiums and fees pass through.
    function invariant_usdcHeldEqualsStrikeUncollected() public view {
        uint256 uncollected;
        for (uint256 id = 1; id <= calls.listingCount(); ++id) {
            CoveredCallsV1.Listing memory l = calls.listings(id);
            uncollected += l.strikePaid - l.strikeCollected;
        }
        assertEq(usdc.balanceOf(address(calls)), uncollected);
    }

    /// Nothing is oversold, and every unit a listing ever locked is still locked, owed or claimed.
    function invariant_noOversellingAndEveryUnitAccounted() public view {
        for (uint256 id = 1; id <= calls.listingCount(); ++id) {
            CoveredCallsV1.Listing memory l = calls.listings(id);
            assertLe(l.filled, l.amount);
            assertLe(l.exercised, l.filled);
            uint256 heldTotal;
            uint256 owedTotal;
            for (uint256 a; a < handler.actorCount(); ++a) {
                heldTotal += calls.held(id, handler.actors(a));
                owedTotal += calls.owed(id, handler.actors(a));
            }
            assertEq(heldTotal + l.exercised, l.filled);
            uint256 locked = l.stockReturned ? 0 : l.amount - l.exercised;
            assertEq(locked + owedTotal + handler.claimedOf(id), handler.listedOf(id));
        }
    }

    /// A claim pays exactly what `claimable` showed for that account just before it.
    function invariant_claimPaysWhatClaimableShows() public view {
        assertEq(handler.claimMismatches(), 0);
    }

    /// Stock is never created or lost.
    function invariant_stockIsConserved() public view {
        uint256 total = stock.balanceOf(address(calls));
        for (uint256 a; a < handler.actorCount(); ++a) {
            total += stock.balanceOf(handler.actors(a));
        }
        assertEq(total, stockSupply);
    }

    /// Every fee reached staking exactly once: 1% of each premium paid, rounded up.
    function invariant_feesReachStakingOnce() public view {
        assertEq(staking.deposited(), handler.feesExpected());
        assertEq(usdc.balanceOf(address(staking)), handler.feesExpected());
    }

    /// USDC is never created or lost.
    function invariant_usdcIsConserved() public view {
        uint256 total = usdc.balanceOf(address(calls)) + usdc.balanceOf(address(staking));
        for (uint256 a; a < handler.actorCount(); ++a) {
            total += usdc.balanceOf(handler.actors(a));
        }
        assertEq(total, usdcSupply);
    }

    /// Once every restriction lifts, every party recovers everything that is theirs and the contract
    /// is left holding nothing.
    function afterInvariant() public {
        console.log("list", handler.succeeded(handler.list.selector), "fill", handler.succeeded(handler.fill.selector));
        console.log(
            "cancel",
            handler.succeeded(handler.cancel.selector),
            "exercise",
            handler.succeeded(handler.exercise.selector)
        );
        console.log(
            "claim",
            handler.succeeded(handler.claim.selector),
            "collectStrike",
            handler.succeeded(handler.collectStrike.selector)
        );
        handler.recoverEverything();
        assertEq(stock.balanceOf(address(calls)), 0);
        assertEq(usdc.balanceOf(address(calls)), 0);
        invariant_noOversellingAndEveryUnitAccounted();
    }
}
```

### `contracts/covered-calls/test/doubles/Doubles.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice A B20 Asset stand-in with the behaviour covered calls depends on, as measured on Base: 8
///         decimals, a scheduled multiplier change read through `effectiveAt`, a blocklist that
///         reverts a transfer to or from a listed address, and a transfer pause that stops
///         `transfer` and `transferFrom` but not `approve`.
contract B20Double is ERC20 {
    error PolicyForbids(address account);
    error ContractPaused();

    uint256 public effectiveAt;
    bool public transfersPaused;
    mapping(address => bool) public blocked;

    function name() public pure override returns (string memory) {
        return "Amazon";
    }

    function symbol() public pure override returns (string memory) {
        return "AMZNc";
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function schedule(uint256 at) external {
        effectiveAt = at;
    }

    function setPaused(bool paused) external {
        transfersPaused = paused;
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _check(msg.sender, to);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _check(from, to);
        return super.transferFrom(from, to, amount);
    }

    function _check(address from, address to) internal view {
        if (transfersPaused) revert ContractPaused();
        if (blocked[from]) revert PolicyForbids(from);
        if (blocked[to]) revert PolicyForbids(to);
    }
}

/// @notice USDC with Circle FiatToken's restrictions: a blacklist checked on the caller, sender,
///         receiver and spender, and a pause that stops transfer, transferFrom and approve.
contract UsdcDouble is ERC20 {
    error Blacklisted(address account);
    error Paused();

    bool public paused;
    mapping(address => bool) public blacklisted;

    function name() public pure override returns (string memory) {
        return "USD Coin";
    }

    function symbol() public pure override returns (string memory) {
        return "USDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setBlacklisted(address account, bool isBlacklisted) external {
        blacklisted[account] = isBlacklisted;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _check(msg.sender);
        _check(to);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _check(msg.sender);
        _check(from);
        _check(to);
        return super.transferFrom(from, to, amount);
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _check(msg.sender);
        _check(spender);
        return super.approve(spender, amount);
    }

    function _check(address account) internal view {
        if (paused) revert Paused();
        if (blacklisted[account]) revert Blacklisted(account);
    }
}

/// @notice Live REGENT staking's `depositUSDC`: pulls the amount from the caller and records it, or
///         refuses every deposit while switched off (a paused or replaced staking contract).
contract StakingDouble {
    UsdcDouble public immutable usdc;
    bool public refuses;
    uint256 public deposited;
    bytes32 public lastTag;
    bytes32 public lastRef;

    constructor(UsdcDouble usdc_) {
        usdc = usdc_;
    }

    function setRefuses(bool refuses_) external {
        refuses = refuses_;
    }

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256) {
        require(!refuses, "staking paused");
        usdc.transferFrom(msg.sender, address(this), amount);
        deposited += amount;
        lastTag = sourceTag;
        lastRef = sourceRef;
        return amount;
    }
}
```

### `contracts/covered-calls/test/doubles/WeeklyExpiry.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @notice Expiries the contract accepts: Fridays at 21:00 UTC.
library WeeklyExpiry {
    uint256 internal constant OFFSET = 1 days + 21 hours;

    /// The first Friday close strictly after `t`, plus `weeksAhead` weeks.
    function next(uint256 t, uint256 weeksAhead) internal pure returns (uint64) {
        uint256 first = t - t % 1 weeks + OFFSET;
        if (first <= t) first += 1 weeks;
        return uint64(first + weeksAhead * 1 weeks);
    }
}
```

### `contracts/covered-calls/test/fork/CoveredCallsV1.fork.t.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {CoveredCallsV1} from "../../src/CoveredCallsV1.sol";
import {WeeklyExpiry} from "../doubles/WeeklyExpiry.sol";

interface IB20AssetFork {
    function multiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint256);
    function grantRole(bytes32 role, address account) external;
    function updateMultiplier(uint256 newMultiplier) external;
    function pause(uint8[] calldata features) external;
    function unpause(uint8[] calldata features) external;
}

interface IPolicyRegistryFork {
    function updateBlocklist(uint64 policyId, bool blocked, address[] calldata accounts) external;
}

/// @notice Covered calls against the real AMZNc B20 token, Base USDC and live REGENT staking on a
///         local Base fork. Run with `forge test --profile fork --network base --fork-url <anvil>`,
///         where anvil is `anvil --network base --fork-url <Base RPC>` (Foundry 1.8.4 or later).
///         The issuer's admin and policy accounts are impersonated only to stage a corporate
///         action, a blocklisting and a pause, exactly as the issuer would.
/// @dev    Foundry's local B20 is the Beryl version: it has `multiplier` and the instant
///         `updateMultiplier`, but not the Cobalt ERC-8056 reads live on Base since then
///         (`effectiveAt`, `newUIMultiplier`, `toUIAmount`), which revert locally. `effectiveAt` is
///         therefore stubbed with the value Base mainnet returns (0, nothing scheduled), and a
///         scheduled change is staged by stubbing its time and flipping the multiplier at that time
///         with `updateMultiplier`, which is what the scheduled change does when it falls due.
contract CoveredCallsV1ForkTest is Test {
    address internal constant AMZNC = 0xb200000000000000000000d9192b6B456483C2E8;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant LIVE_STAKING = 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5;
    /// The deepest AMZNc/USDC pool, used only as a holder to take stock from.
    address internal constant AMZNC_POOL = 0x532e0F46d1e528507FC9454d5847C231f23bDDf6;
    address internal constant TOKEN_ADMIN = 0x38467bE00970af18076fd08F6b4Cf38Ba91572B1;
    address internal constant POLICY_ADMIN = 0xEC0F05C174e54FBf0Fe16ad930a8AFEbCe612812;
    address internal constant POLICY_REGISTRY = 0x8453000000000000000000000000000000000002;
    uint64 internal constant TRANSFER_POLICY = 5;
    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 internal constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 internal constant UNPAUSE_ROLE = keccak256("UNPAUSE_ROLE");
    uint8 internal constant TRANSFER = 0;
    uint256 internal constant TOKEN = 1e8;
    uint256 internal constant USD = 1e6;

    CoveredCallsV1 internal calls;
    IERC20 internal stock = IERC20(AMZNC);
    IERC20 internal usdc = IERC20(USDC);
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal issuerOps = makeAddr("issuerOps");
    uint64 internal expiry;

    function setUp() public {
        _stubEffectiveAt(0);
        calls = new CoveredCallsV1(AMZNC, USDC, LIVE_STAKING);
        expiry = WeeklyExpiry.next(block.timestamp, 1);

        vm.prank(AMZNC_POOL);
        stock.transfer(seller, 10 * TOKEN);
        deal(USDC, buyer, 1_000_000 * USD);

        vm.prank(seller);
        stock.approve(address(calls), type(uint256).max);
        vm.prank(buyer);
        usdc.approve(address(calls), type(uint256).max);

        vm.startPrank(TOKEN_ADMIN);
        IB20AssetFork(AMZNC).grantRole(OPERATOR_ROLE, issuerOps);
        IB20AssetFork(AMZNC).grantRole(PAUSE_ROLE, issuerOps);
        IB20AssetFork(AMZNC).grantRole(UNPAUSE_ROLE, issuerOps);
        vm.stopPrank();
    }

    function _list(uint256 amount) internal returns (uint256 id) {
        vm.prank(seller);
        id = calls.list(amount, 260 * USD, 4 * USD, expiry);
    }

    function _stubEffectiveAt(uint256 at) internal {
        vm.mockCall(AMZNC, abi.encodeWithSelector(IB20AssetFork.effectiveAt.selector), abi.encode(at));
    }

    /// The seller stops sales while the issuer has transfers paused; the remainder waits for a claim.
    function test_fork_cancelWorksWhileTransfersArePaused() public {
        uint256 id = _list(3 * TOKEN);
        _pauseTransfers(true);
        vm.prank(seller);
        calls.cancel(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.ExceedsAvailable.selector, 1, 0));
        calls.fill(id, 1);
        _pauseTransfers(false);
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 10 * TOKEN);
    }

    function _pauseTransfers(bool paused) internal {
        uint8[] memory features = new uint8[](1);
        features[0] = TRANSFER;
        vm.prank(issuerOps);
        if (paused) IB20AssetFork(AMZNC).pause(features);
        else IB20AssetFork(AMZNC).unpause(features);
    }

    function test_fork_constructorReadsTheRealDecimals() public view {
        assertEq(calls.unit(), 1e8);
    }

    /// The whole life of an exercised call with real tokens, and the fee reaching live staking.
    function test_fork_exercisedLifecycle() public {
        uint256 id = _list(2 * TOKEN);
        assertEq(stock.balanceOf(address(calls)), 2 * TOKEN);

        uint256 stakingBefore = usdc.balanceOf(LIVE_STAKING);
        vm.prank(buyer);
        calls.fill(id, 2 * TOKEN);
        assertEq(usdc.balanceOf(seller), 8 * USD - 80_000);
        assertEq(usdc.balanceOf(LIVE_STAKING) - stakingBefore, 80_000);
        assertEq(usdc.balanceOf(address(calls)), 0);

        vm.warp(expiry);
        vm.startPrank(buyer);
        calls.exercise(id, 2 * TOKEN);
        calls.claim(id);
        vm.stopPrank();
        assertEq(stock.balanceOf(buyer), 2 * TOKEN);

        vm.prank(seller);
        calls.collectStrike(id);
        assertEq(usdc.balanceOf(seller), 8 * USD - 80_000 + 520 * USD);
        assertEq(stock.balanceOf(address(calls)), 0);
    }

    function test_fork_unexercisedStockReturnsAfterTheWindow() public {
        uint256 id = _list(3 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, TOKEN);
        vm.warp(uint256(expiry) + 1 days);
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 10 * TOKEN);
    }

    /// A scheduled multiplier change inside the life is refused; one after it is not; once it has
    /// taken effect, listings open again and raw amounts are unchanged.
    function test_fork_scheduledCorporateActionBlocksOverlappingListings() public {
        uint256 at = uint256(expiry) + 12 hours;
        _stubEffectiveAt(at);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.CorporateActionScheduled.selector, at));
        calls.list(TOKEN, 260 * USD, 4 * USD, expiry);

        vm.prank(seller);
        uint256 early = calls.list(TOKEN, 260 * USD, 4 * USD, expiry - 1 weeks);

        vm.warp(at);
        vm.prank(issuerOps);
        IB20AssetFork(AMZNC).updateMultiplier(2e18);
        assertEq(IB20AssetFork(AMZNC).multiplier(), 2e18);

        vm.prank(seller);
        uint256 id = calls.list(TOKEN, 130 * USD, 2 * USD, expiry + 1 weeks);
        assertEq(calls.listings(id).amount, TOKEN);
        assertEq(calls.listings(early).amount, TOKEN);
        assertEq(stock.balanceOf(address(calls)), 2 * TOKEN);
        assertEq(stock.balanceOf(seller), 8 * TOKEN);
    }

    /// The issuer blocklisting the holder stops only that holder's stock from leaving.
    function test_fork_blocklistedHolderCannotClaimButTheSellerCollects() public {
        uint256 id = _list(2 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, TOKEN);
        vm.warp(expiry);
        vm.prank(buyer);
        calls.exercise(id, TOKEN);

        address[] memory accounts = new address[](1);
        accounts[0] = buyer;
        vm.prank(POLICY_ADMIN);
        IPolicyRegistryFork(POLICY_REGISTRY).updateBlocklist(TRANSFER_POLICY, true, accounts);

        vm.prank(buyer);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        calls.claim(id);

        vm.warp(uint256(expiry) + 1 days);
        vm.startPrank(seller);
        calls.claim(id);
        calls.collectStrike(id);
        vm.stopPrank();
        assertEq(stock.balanceOf(seller), 9 * TOKEN);
        assertEq(usdc.balanceOf(seller), 4 * USD - 40_000 + 260 * USD);
        assertEq(stock.balanceOf(address(calls)), TOKEN);
    }

    /// A real transfer pause during the window: exercise still works, the seller's USDC strike is
    /// never held up, the stock waits, and both sides take their stock once transfers resume.
    function test_fork_transferPauseDelaysButNeverLosesStock() public {
        uint256 id = _list(2 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, TOKEN);
        vm.warp(expiry);
        _pauseTransfers(true);

        vm.prank(buyer);
        calls.exercise(id, TOKEN);
        vm.prank(buyer);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        calls.claim(id);

        vm.warp(uint256(expiry) + 1 days);
        vm.startPrank(seller);
        calls.collectStrike(id);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        calls.claim(id);
        vm.stopPrank();

        vm.warp(uint256(expiry) + 60 days);
        _pauseTransfers(false);
        vm.prank(buyer);
        calls.claim(id);
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(buyer), TOKEN);
        assertEq(stock.balanceOf(seller), 9 * TOKEN);
        assertEq(usdc.balanceOf(seller), 4 * USD - 40_000 + 260 * USD);
    }
}
```

### `contracts/covered-calls/test/rehearsal/DeployPacket.t.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {CoveredCallsV1} from "../../src/CoveredCallsV1.sol";
import {WeeklyExpiry} from "../doubles/WeeklyExpiry.sol";

/// @notice The deploy packet's contract, after `deploy/rehearse.sh` has sent the packet's exact
///         transaction on a local Base copy: the code and reads the packet promises, then a whole
///         call's life with the real AMZNc, Base USDC and live REGENT staking, the 1% fee landing in
///         staking. Run only by `deploy/rehearse.sh` (profile `rehearsal`).
/// @dev    Foundry's local B20 lacks the Cobalt `effectiveAt()` read live on Base since then, so it
///         stands in its mainnet value (0, nothing scheduled), as the fork suite does.
contract DeployPacketRehearsal is Test {
    /// An AMZNc/USDC pool holding AMZNc, used only to fund the test seller.
    address internal constant AMZNC_HOLDER = 0x532e0F46d1e528507FC9454d5847C231f23bDDf6;
    uint256 internal constant TOKEN = 1e8;
    uint256 internal constant USD = 1e6;

    string internal packet;
    CoveredCallsV1 internal calls;
    IERC20 internal stock;
    IERC20 internal usdc;
    address internal staking;
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");

    function setUp() public {
        packet = vm.readFile("deploy/packet.json");
        calls = CoveredCallsV1(vm.parseJsonAddress(packet, ".create2.predicted_address"));
        stock = IERC20(calls.stock());
        usdc = IERC20(calls.usdc());
        staking = calls.staking();
    }

    function test_packetContractIsWhatThePacketPromises() public view {
        assertEq(block.chainid, vm.parseJsonUint(packet, ".chain_id"));
        assertEq(address(calls).codehash, vm.parseJsonBytes32(packet, ".post_deploy.runtime_code_keccak"));
        assertEq(address(stock), vm.parseJsonAddress(packet, ".constructor[0].value"));
        assertEq(address(usdc), vm.parseJsonAddress(packet, ".constructor[1].value"));
        assertEq(staking, vm.parseJsonAddress(packet, ".constructor[2].value"));
        assertEq(calls.unit(), vm.parseUint(vm.parseJsonString(packet, ".post_deploy.reads['unit()']")));
        assertEq(calls.FEE_BPS(), 100);
        assertEq(calls.EXERCISE_WINDOW(), 1 days);
    }

    /// list, fill, exercise, claim and collectStrike on the deployed instance with real tokens.
    function test_wholeLifeOnTheDeployedInstance() public {
        vm.mockCall(address(stock), abi.encodeWithSignature("effectiveAt()"), abi.encode(uint256(0)));
        vm.prank(AMZNC_HOLDER);
        stock.transfer(seller, 2 * TOKEN);
        deal(address(usdc), buyer, 1_000 * USD);
        uint64 expiry = WeeklyExpiry.next(block.timestamp, 1);

        vm.startPrank(seller);
        stock.approve(address(calls), 2 * TOKEN);
        uint256 id = calls.list(2 * TOKEN, 300 * USD, 3 * USD, expiry);
        vm.stopPrank();

        uint256 stakingBefore = usdc.balanceOf(staking);
        vm.startPrank(buyer);
        usdc.approve(address(calls), type(uint256).max);
        calls.fill(id, 2 * TOKEN);
        vm.stopPrank();
        // 6 USDC of premium: 1% (0.06 USDC) into live staking, the rest to the seller.
        assertEq(usdc.balanceOf(staking) - stakingBefore, 60_000);
        assertEq(usdc.balanceOf(seller), 6 * USD - 60_000);

        vm.warp(expiry);
        vm.startPrank(buyer);
        calls.exercise(id, 2 * TOKEN);
        calls.claim(id);
        vm.stopPrank();
        assertEq(stock.balanceOf(buyer), 2 * TOKEN);

        vm.prank(seller);
        calls.collectStrike(id);
        assertEq(usdc.balanceOf(seller), 6 * USD - 60_000 + 600 * USD);
        assertEq(stock.balanceOf(address(calls)), 0);
        assertEq(usdc.balanceOf(address(calls)), 0);
    }
}
```

### `contracts/covered-calls/test/lab/LabStockToken.sol`

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title LabStockToken
/// @notice LAB ONLY. The AMZNc stand-in the local Base copy runs covered calls against
///         (platform/test/journeys/support/base_fork.py, `covered-calls`). A local chain cannot run
///         Base's B20 precompiles, so the journeys install contracts/stocks-v2's FixtureStockToken at
///         each stock; this is that same token, installed over it at AMZNc, with the two B20 Asset
///         reads covered calls make: `multiplier()` and `effectiveAt()`, plus `schedule` to stage a
///         corporate action and `setPaused` to stage an issuer's transfer pause on the copy (as on
///         Base, a pause stops `transfer` and `transferFrom` but not `approve`).
/// @dev Solady's ERC20 keeps balances and allowances in hashed slots and this contract's own state
///      sits in slots 0 and 1, so installing this over FixtureStockToken keeps every balance minted.
contract LabStockToken is ERC20 {
    /// @notice When a scheduled multiplier change takes effect; 0, as on Base, when none is.
    uint256 public effectiveAt;
    /// @notice Whether the issuer has paused transfers on the copy.
    bool public transfersPaused;

    error ContractPaused();

    function name() public pure override returns (string memory) {
        return "Fixture AMZNc";
    }

    function symbol() public pure override returns (string memory) {
        return "AMZNc";
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    /// @notice The B20 multiplier, WAD: AMZNc's reads exactly 1.0 on Base.
    function multiplier() external pure returns (uint256) {
        return 1e18;
    }

    /// @dev As FixtureStockToken: a plain allowance model, no implicit Permit2 allowance.
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }

    /// @notice Anyone may mint. Lab faucet only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (transfersPaused) revert ContractPaused();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (transfersPaused) revert ContractPaused();
        return super.transferFrom(from, to, amount);
    }

    /// @notice Stages or lifts an issuer's transfer pause. Lab only.
    function setPaused(bool paused) external {
        transfersPaused = paused;
    }

    /// @notice Stages a scheduled multiplier change at `at` (0 clears it). Lab only.
    function schedule(uint256 at) external {
        effectiveAt = at;
    }
}
```

## Appendix D — HTTP API for covered calls (OpenAPI, complete)

### `platform/contracts/covered-calls.openapiv3.yaml`

```yaml
# Covered calls, added to api-contract.openapiv3.yaml only while the site offers them
# (AUTOLAUNCH_COVERED_CALLS=true; AutolaunchWeb.PublicDocuments.openapi/0). Off, /openapi.json
# is api-contract.openapiv3.yaml exactly. Every path and component here is new; none replaces one.
paths:
  /api/v1/covered-calls/{symbol}:
    get:
      operationId: getCoveredCallBook
      summary: Read a stock's covered calls
      description: Every covered-call listing on one Base stock token as its contract holds them at the
        latest block, with each listing's stage and what is left to buy, the stock's multiplier and its
        reference price. Stock amounts are raw token units (`unit` is one whole token), prices micro-USDC
        per whole token, times Unix seconds. The reading is shared and may be up to five minutes old (`read_at`).
        Needs no account; the page tool autolaunch_covered_call_listings calls it.
      security: []
      parameters:
      - $ref: '#/components/parameters/CoveredCallSymbol'
      responses:
        '200':
          description: The stock's covered-call book
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallBookEnvelope'
        '404':
          description: No covered-call market for that stock (unknown_market)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
        '422':
          description: A query parameter was sent (invalid_request)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
        '503':
          description: The chain could not be read (chain_unavailable)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
        '429':
          $ref: '#/components/responses/TooManyRequests'
        default:
          $ref: '#/components/responses/OtherError'
  /api/v1/covered-calls/{symbol}/quote:
    post:
      operationId: quoteCoveredCall
      summary: Suggest a covered-call premium
      description: A suggested premium per whole token for a call at `strike_per_token` expiring at `expiry`,
        from the stock's reference price, as a guide for a seller. The contract enforces nothing from
        it. Refused while the reference price is more than four days old. Needs no account; the page tool
        autolaunch_covered_call_quote calls it.
      security: []
      parameters:
      - $ref: '#/components/parameters/CoveredCallSymbol'
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/CoveredCallQuoteRequest'
      responses:
        '200':
          description: The suggested premium
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallQuoteEnvelope'
        '404':
          description: No covered-call market for that stock (unknown_market)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
        '422':
          description: The expiry is not a Friday at 21:00 UTC or has passed, or the body is not the two
            whole numbers (not_a_weekly_expiry, expiry_passed, invalid_request)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
        '503':
          description: The reference price or the chain could not be read (price_unavailable, chain_unavailable)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
        '429':
          $ref: '#/components/responses/TooManyRequests'
        default:
          $ref: '#/components/responses/OtherError'
  /api/v1/me/covered-calls/{symbol}:
    get:
      operationId: listMyCoveredCalls
      summary: List your covered calls on a stock
      description: The listings the signed-in wallet sold on one Base stock token, and on every listing
        the calls it may exercise and the stock it may claim, read now at the latest block. Only the wallet
        the person signed in with is read. Needs the site's sign-in in the same browser.
      security:
      - SiteSession: []
      parameters:
      - $ref: '#/components/parameters/CoveredCallSymbol'
      responses:
        '200':
          description: The signed-in wallet's covered calls
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallPositionsEnvelope'
        '401':
          description: Nobody is signed in on this site in this browser (authentication_required)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
        '404':
          description: No covered-call market for that stock (unknown_market)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
        '409':
          description: The account has no wallet to read (wallet_required)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
        '503':
          description: The chain could not be read (chain_unavailable)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
        '429':
          $ref: '#/components/responses/TooManyRequests'
        default:
          $ref: '#/components/responses/OtherError'
  /api/agent/v1/covered-calls/{symbol}/positions:
    get:
      operationId: autolaunch_my_covered_calls
      summary: Read my covered calls on a stock
      description: The covered calls of the paired agent's person on one Base stock token, for the wallet
        they signed in with, read now at the latest block. Changes nothing.
      security:
      - SiwaProof: []
      parameters:
      - $ref: '#/components/parameters/CoveredCallSymbol'
      responses:
        '200':
          description: The person's covered calls
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallPositionsEnvelope'
        '401':
          description: Fresh request proof required
        '403':
          description: The agent is paired with nobody (agent_not_paired); the error's hint says what
            the person does next
        '404':
          description: No covered-call market for that stock (unknown_market)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
        '409':
          description: The person's account has no wallet to read (wallet_required)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
        '503':
          description: The chain could not be read (chain_unavailable)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
  /api/agent/v1/covered-calls/{symbol}/steps:
    post:
      operationId: autolaunch_covered_call_prepare
      summary: Prepare a covered-call step
      description: The wallet steps for one covered-call action, built from the chain at the latest block,
        for one of the person's own wallets (`signer`, or the wallet they signed in with). The site only
        prepares; the wallet's own key signs and sends each step. An action the chain's current state
        makes certain to fail answers 200 with `blocked`, and its steps. Changes nothing.
      security:
      - SiwaProof: []
      parameters:
      - $ref: '#/components/parameters/CoveredCallSymbol'
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/CoveredCallStepRequest'
      responses:
        '200':
          description: The steps, whether the allowance already covers them, and any reason they are certain
            to fail
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallStepsEnvelope'
        '401':
          description: Fresh request proof required
        '403':
          description: The agent is paired with nobody (agent_not_paired), or the signer is not one of
            the person's own wallets (wrong_signer)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
        '404':
          description: No such market or listing (unknown_market, unknown_listing)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
        '409':
          description: The person's account has no wallet to act with (wallet_required)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
        '422':
          description: An unknown field, kind or type, an amount below one, or an expiry that is not a
            future Friday at 21:00 UTC (invalid_request, invalid_amount, not_a_weekly_expiry, expiry_passed)
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/CoveredCallError'
        '503':
          description: The chain could not be read, or the site is not open yet (chain_unavailable, prelaunch_read_only)
components:
  parameters:
    CoveredCallSymbol:
      name: symbol
      in: path
      required: true
      description: The stock token's symbol exactly as the site lists it, such as AMZNc.
      schema:
        type: string
  schemas:
    CoveredCallListing:
      type: object
      additionalProperties: false
      required:
      - id
      - seller
      - expiry
      - amount
      - filled
      - exercised
      - strike_per_token
      - premium_per_token
      - stock_returned
      - stage
      - available
      - exercise_closes_at
      - strike_due
      properties:
        id:
          type: integer
          description: The listing's number on this market.
        seller:
          type: string
          description: The wallet that made the listing.
        expiry:
          type: integer
          description: 'Unix seconds: a Friday at 21:00 UTC. Buying closes then.'
        exercise_closes_at:
          type: integer
          description: Unix seconds; the exercise window is the 24 hours from expiry.
        amount:
          type: integer
          description: Raw stock units listed.
        filled:
          type: integer
          description: Raw stock units bought.
        available:
          type: integer
          description: Raw stock units still for sale.
        exercised:
          type: integer
          description: Raw stock units exercised.
        strike_per_token:
          type: integer
          description: Micro-USDC per whole token.
        premium_per_token:
          type: integer
          description: Micro-USDC per whole token.
        strike_due:
          type: integer
          description: Strike micro-USDC paid and not yet collected by the seller.
        stock_returned:
          type: boolean
          description: Whether the unexercised stock has been booked back to the seller.
        stage:
          type: string
          enum:
          - open
          - sold
          - exercise
          - closed
          description: 'open: for sale; sold: nothing left before expiry; exercise: the 24 hours after
            expiry; closed: after them.'
    CoveredCallBookEnvelope:
      type: object
      additionalProperties: false
      required:
      - data
      properties:
        data:
          type: object
          additionalProperties: false
          required:
          - symbol
          - contract
          - stock
          - block
          - now
          - read_at
          - unit
          - multiplier
          - multiplier_change_at
          - reference_price
          - listings
          properties:
            symbol:
              type: string
            contract:
              type: string
              description: The market's covered-calls contract on Base.
            stock:
              type: string
              description: The stock token on Base.
            block:
              type: integer
            now:
              type: integer
              description: The block's time
              Unix seconds.: null
            read_at:
              type: string
              format: date-time
            unit:
              type: integer
              description: Raw units in one whole token.
            multiplier:
              type: integer
              description: Shares per token, scaled by 10^18.
            multiplier_change_at:
              type: integer
              description: Unix seconds of a scheduled multiplier change, or 0 when none is scheduled.
            reference_price:
              description: The stock's reference price, or null when the feed does not answer.
              oneOf:
              - type: 'null'
              - type: object
                additionalProperties: false
                required:
                - answer
                - decimals
                - updated_at
                properties:
                  answer:
                    type: integer
                  decimals:
                    type: integer
                  updated_at:
                    type: integer
            listings:
              type: array
              items:
                $ref: '#/components/schemas/CoveredCallListing'
    CoveredCallQuoteRequest:
      type: object
      additionalProperties: false
      required:
      - strike_per_token
      - expiry
      properties:
        strike_per_token:
          type: integer
          minimum: 1
          maximum: 9007199254740991
        expiry:
          type: integer
          description: A Friday at 21:00 UTC, Unix seconds.
    CoveredCallQuoteEnvelope:
      type: object
      additionalProperties: false
      required:
      - data
      properties:
        data:
          type: object
          additionalProperties: false
          required:
          - symbol
          - spot_per_token
          - strike_per_token
          - expiry
          - volatility
          - suggested_premium_per_token
          - price_updated_at
          properties:
            symbol:
              type: string
            spot_per_token:
              type: integer
              description: The reference price in micro-USDC per whole token.
            strike_per_token:
              type: integer
            expiry:
              type: integer
            volatility:
              type: number
              description: The yearly volatility the suggestion assumes.
            suggested_premium_per_token:
              type: integer
              description: Micro-USDC per whole token.
            price_updated_at:
              type: integer
              description: Unix seconds.
    CoveredCallPositionsEnvelope:
      type: object
      additionalProperties: false
      required:
      - data
      properties:
        data:
          type: object
          additionalProperties: false
          required:
          - symbol
          - wallet
          - now
          - read_at
          - unit
          - sold
          - holdings
          properties:
            symbol:
              type: string
            wallet:
              type: string
            now:
              type: integer
            read_at:
              type: string
              format: date-time
            unit:
              type: integer
            sold:
              type: array
              items:
                $ref: '#/components/schemas/CoveredCallListing'
            holdings:
              type: array
              items:
                type: object
                additionalProperties: false
                required:
                - listing_id
                - held
                - claimable
                properties:
                  listing_id:
                    type: integer
                  held:
                    type: integer
                    description: Raw stock units of calls the wallet may exercise.
                  claimable:
                    type: integer
                    description: Raw stock units the wallet may claim now.
    CoveredCallStepRequest:
      type: object
      additionalProperties: false
      required:
      - kind
      properties:
        kind:
          type: string
          enum:
          - list
          - fill
          - cancel
          - exercise
          - claim
          - collect_strike
        listing_id:
          type: integer
          minimum: 1
          maximum: 9007199254740991
        amount:
          type: integer
          minimum: 1
          maximum: 9007199254740991
        strike_per_token:
          type: integer
          minimum: 1
          maximum: 9007199254740991
        premium_per_token:
          type: integer
          minimum: 1
          maximum: 9007199254740991
        expiry:
          type: integer
          description: 'For list: a Friday at 21:00 UTC, Unix seconds.'
        signer:
          type: string
          description: One of the person's own wallet addresses; omit it for the wallet they signed in
            with.
    CoveredCallStepsEnvelope:
      type: object
      additionalProperties: false
      required:
      - data
      properties:
        data:
          type: object
          additionalProperties: false
          required:
          - kind
          - signer
          - chain
          - steps
          - approved
          - blocked
          - facts
          properties:
            kind:
              type: string
              enum:
              - list
              - fill
              - cancel
              - exercise
              - claim
              - collect_strike
            signer:
              type: string
              description: The wallet the steps are for.
            chain:
              type: object
              required:
              - chain_id
              - name
              - rpc_url
              properties:
                chain_id:
                  type: integer
                name:
                  type: string
                rpc_url:
                  type: string
            steps:
              type: array
              items:
                type: object
                additionalProperties: false
                required:
                - kind
                - step
                - to
                - data
                - value
                properties:
                  kind:
                    type: string
                    enum:
                    - transaction
                  step:
                    type: string
                    enum:
                    - stock_approval
                    - usdc_approval
                    - list
                    - fill
                    - cancel
                    - exercise
                    - claim
                    - collect_strike
                  to:
                    type: string
                  data:
                    type: string
                  value:
                    type: string
                    description: Hex wei; always 0x0.
            approved:
              type: boolean
              description: Whether the allowance already covers the action; always true for actions with
                no approval.
            blocked:
              description: Null, or why the chain's current state makes the action certain to fail.
              oneOf:
              - type: 'null'
              - type: object
                additionalProperties: false
                required:
                - code
                - message
                properties:
                  code:
                    type: string
                    enum:
                    - corporate_action
                    - not_enough_stock
                    - approve_first
                    - fills_closed
                    - sold_out
                    - not_enough_usdc
                    - exercise_not_open
                    - exercise_closed
                    - more_than_held
                    - not_seller
                    - nothing_to_cancel
                    - nothing_to_claim
                    - nothing_to_collect
                  message:
                    type: string
            facts:
              type: object
              description: 'The action''s figures: listing_id, amount, and the premium, fee, strike or
                unsold amount it involves.'
    CoveredCallError:
      type: object
      additionalProperties: false
      required:
      - error
      properties:
        error:
          type: object
          additionalProperties: false
          required:
          - code
          - message
          - hint
          properties:
            code:
              type: string
              enum:
              - unknown_market
              - unknown_listing
              - invalid_amount
              - not_a_weekly_expiry
              - expiry_passed
              - invalid_request
              - wrong_signer
              - wallet_required
              - authentication_required
              - price_unavailable
              - chain_unavailable
              - agent_not_paired
            message:
              type: string
            hint:
              type: string
              description: What to do next.
```

## Appendix E — agent tools handed to the page while on (complete)

### `platform/priv/covered_calls_tools.json`

```json
{
  "_comment": "Covered calls' browser tools. AutolaunchWeb.ToolManifest adds them to tool_manifest.json, and prepare_agent_request's operations, only while the site offers covered calls (AUTOLAUNCH_COVERED_CALLS=true). A public tool's `request` is the HTTP request it makes: `path` with each {field} filled from its input, and `body` the input fields it posts.",
  "tools": [
    {
      "name": "autolaunch_covered_call_listings",
      "title": "List covered calls on a stock",
      "description": "List the covered calls on one Base stock token, as its contract holds them at the latest block: every listing with its seller, strike_per_token and premium_per_token (micro-USDC per whole token), expiry (a Friday at 21:00 UTC, Unix seconds), amount, filled and available (raw token units, unit per whole token) and stage (open, sold, exercise or closed), the stock's multiplier and its reference price. Reads only; needs no sign-in. The reading is shared and may be up to five minutes old; read_at says when it was taken.",
      "input_schema": {
        "type": "object",
        "properties": {
          "symbol": {
            "type": "string",
            "description": "The stock token's symbol exactly as the site lists it, such as AMZNc."
          }
        },
        "required": [
          "symbol"
        ],
        "additionalProperties": false
      },
      "annotations": {
        "readOnlyHint": true,
        "untrustedContentHint": false,
        "consequentialHint": false
      },
      "requires": "none",
      "state_changing": false,
      "payment": "none",
      "route": "GET /api/v1/covered-calls/{symbol}",
      "scope": "site",
      "request": {
        "path": "/api/v1/covered-calls/{symbol}"
      }
    },
    {
      "name": "autolaunch_covered_call_quote",
      "title": "Suggest a covered-call premium",
      "description": "Suggest a premium per whole token for a covered call on one Base stock token at a strike and weekly expiry, from the stock's reference price. A guide for a seller only: the contract enforces nothing from it, and it is refused while the reference price is more than four days old. Reads only; needs no sign-in.",
      "input_schema": {
        "type": "object",
        "properties": {
          "symbol": {
            "type": "string",
            "description": "The stock token's symbol exactly as the site lists it, such as AMZNc."
          },
          "strike_per_token": {
            "type": "integer",
            "minimum": 1,
            "maximum": 9007199254740991,
            "description": "The strike in micro-USDC (6 decimals) per whole token."
          },
          "expiry": {
            "type": "integer",
            "minimum": 1,
            "maximum": 9007199254740991,
            "description": "A Friday at 21:00 UTC, as Unix seconds; listings take no other expiry."
          }
        },
        "required": [
          "symbol",
          "strike_per_token",
          "expiry"
        ],
        "additionalProperties": false
      },
      "annotations": {
        "readOnlyHint": true,
        "untrustedContentHint": false,
        "consequentialHint": false
      },
      "requires": "none",
      "state_changing": false,
      "payment": "none",
      "route": "POST /api/v1/covered-calls/{symbol}/quote",
      "scope": "site",
      "request": {
        "path": "/api/v1/covered-calls/{symbol}/quote",
        "body": [
          "strike_per_token",
          "expiry"
        ]
      }
    },
    {
      "name": "autolaunch_my_covered_calls",
      "title": "Read my covered calls on a stock",
      "description": "Read my person's covered calls on one Base stock token, for their signed-in wallet, at the latest block: the listings it sold and, on every listing, the calls it may exercise (held) and the stock it may claim (claimable), in raw token units. Changes nothing. Prepare the exact request, sign it with your existing SIWA signer, then provide input, request and proof. Browser sign-in is not agent authority.",
      "input_schema": {
        "type": "object",
        "additionalProperties": false,
        "required": [
          "input",
          "request",
          "proof"
        ],
        "properties": {
          "input": {
            "type": "object",
            "properties": {
              "symbol": {
                "type": "string",
                "description": "The stock token's symbol exactly as the site lists it, such as AMZNc."
              }
            },
            "required": [
              "symbol"
            ],
            "additionalProperties": false
          },
          "request": {
            "type": "object",
            "description": "Exact request returned by prepare_agent_request."
          },
          "proof": {
            "type": "object",
            "additionalProperties": {
              "type": "string"
            },
            "description": "HTTP proof headers from the existing SIWA signer."
          }
        }
      },
      "annotations": {
        "readOnlyHint": true,
        "untrustedContentHint": false
      },
      "requires": "siwa_and_pairing",
      "state_changing": false,
      "payment": "none",
      "route": "GET /api/agent/v1/covered-calls/{symbol}/positions",
      "scope": "site",
      "authentication": "siwa_per_request",
      "pairing_required": true,
      "availability": "available",
      "interfaces": {
        "webmcp": "autolaunch_my_covered_calls",
        "http": "GET /api/agent/v1/covered-calls/{symbol}/positions"
      },
      "operation_input_schema": {
        "type": "object",
        "properties": {
          "symbol": {
            "type": "string",
            "description": "The stock token's symbol exactly as the site lists it, such as AMZNc."
          }
        },
        "required": [
          "symbol"
        ],
        "additionalProperties": false
      },
      "effect": "read"
    },
    {
      "name": "autolaunch_covered_call_prepare",
      "title": "Prepare a covered-call step",
      "description": "Prepare the wallet steps for one covered-call action on a Base stock token: list (amount, strike_per_token, premium_per_token, expiry), fill (listing_id, amount), exercise (listing_id, amount), cancel, claim or collect_strike (listing_id). The steps are for one of my person's own wallets: signer when given, otherwise the wallet they signed in with; any other wallet is refused. The site only prepares: the wallet's own key signs and sends each step in turn (to, data, value on chain), and money moves only then. approved says whether the allowance already covers the action; blocked names, in code and words, a reason the chain's current state makes the action certain to fail, and the steps are still returned. Changes nothing. Prepare the exact request, sign it with your existing SIWA signer, then provide input, request and proof. Browser sign-in is not agent authority.",
      "input_schema": {
        "type": "object",
        "additionalProperties": false,
        "required": [
          "input",
          "request",
          "proof"
        ],
        "properties": {
          "input": {
            "type": "object",
            "properties": {
              "symbol": {
                "type": "string",
                "description": "The stock token's symbol exactly as the site lists it, such as AMZNc."
              },
              "kind": {
                "type": "string",
                "enum": [
                  "list",
                  "fill",
                  "cancel",
                  "exercise",
                  "claim",
                  "collect_strike"
                ]
              },
              "listing_id": {
                "type": "integer",
                "minimum": 1,
                "maximum": 9007199254740991,
                "description": "The listing's number on this market, for every kind but list."
              },
              "amount": {
                "type": "integer",
                "minimum": 1,
                "maximum": 9007199254740991,
                "description": "Raw stock token units: to list, to buy (fill) or to exercise."
              },
              "strike_per_token": {
                "type": "integer",
                "minimum": 1,
                "maximum": 9007199254740991,
                "description": "For list: the strike in micro-USDC per whole token."
              },
              "premium_per_token": {
                "type": "integer",
                "minimum": 1,
                "maximum": 9007199254740991,
                "description": "For list: the minimum premium in micro-USDC per whole token."
              },
              "expiry": {
                "type": "integer",
                "minimum": 1,
                "maximum": 9007199254740991,
                "description": "For list: a Friday at 21:00 UTC, as Unix seconds."
              },
              "signer": {
                "type": "string",
                "description": "One of my person's own wallet addresses, 0x and 40 hex digits. Omit it to use the wallet they signed in with."
              }
            },
            "required": [
              "symbol",
              "kind"
            ],
            "additionalProperties": false
          },
          "request": {
            "type": "object",
            "description": "Exact request returned by prepare_agent_request."
          },
          "proof": {
            "type": "object",
            "additionalProperties": {
              "type": "string"
            },
            "description": "HTTP proof headers from the existing SIWA signer."
          }
        }
      },
      "annotations": {
        "readOnlyHint": true,
        "untrustedContentHint": false
      },
      "requires": "siwa_and_pairing",
      "state_changing": false,
      "payment": "none",
      "route": "POST /api/agent/v1/covered-calls/{symbol}/steps",
      "scope": "site",
      "authentication": "siwa_per_request",
      "pairing_required": true,
      "availability": "available",
      "interfaces": {
        "webmcp": "autolaunch_covered_call_prepare",
        "http": "POST /api/agent/v1/covered-calls/{symbol}/steps"
      },
      "operation_input_schema": {
        "type": "object",
        "properties": {
          "symbol": {
            "type": "string",
            "description": "The stock token's symbol exactly as the site lists it, such as AMZNc."
          },
          "kind": {
            "type": "string",
            "enum": [
              "list",
              "fill",
              "cancel",
              "exercise",
              "claim",
              "collect_strike"
            ]
          },
          "listing_id": {
            "type": "integer",
            "minimum": 1,
            "maximum": 9007199254740991,
            "description": "The listing's number on this market, for every kind but list."
          },
          "amount": {
            "type": "integer",
            "minimum": 1,
            "maximum": 9007199254740991,
            "description": "Raw stock token units: to list, to buy (fill) or to exercise."
          },
          "strike_per_token": {
            "type": "integer",
            "minimum": 1,
            "maximum": 9007199254740991,
            "description": "For list: the strike in micro-USDC per whole token."
          },
          "premium_per_token": {
            "type": "integer",
            "minimum": 1,
            "maximum": 9007199254740991,
            "description": "For list: the minimum premium in micro-USDC per whole token."
          },
          "expiry": {
            "type": "integer",
            "minimum": 1,
            "maximum": 9007199254740991,
            "description": "For list: a Friday at 21:00 UTC, as Unix seconds."
          },
          "signer": {
            "type": "string",
            "description": "One of my person's own wallet addresses, 0x and 40 hex digits. Omit it to use the wallet they signed in with."
          }
        },
        "required": [
          "symbol",
          "kind"
        ],
        "additionalProperties": false
      },
      "effect": "prepare"
    }
  ]
}
```
