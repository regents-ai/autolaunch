# Autolaunch Covered Calls V2

`CoveredCallsV2` is [`CoveredCallsV1`](../covered-calls/README.md) with standing buyer bids. It
does everything V1 does, unchanged, and adds one thing: a buyer can post a bid for calls and
escrow its premium, and any seller can sell into that bid and be paid at once. It is written so
the site can move to V2 alone; it neither imports nor calls V1.

Status: **not deployed.** Deploying it is a contract deployment, which needs Sean's go. Nothing for
it is prepared here: no deploy packet, script, salt, dry run, rehearsal or Base fork suite.

## In plain words

One contract per stock. It has no owner, admin, oracle, upgrade or pause.

**A seller can**

- list stock as calls at their own strike and premium, for any buyer to buy (as in V1);
- sell into a buyer's standing bid: the seller's stock is locked, and the bid's premium, less 1%
  for REGENT staking, lands in the seller's wallet in the same transaction;
- stop the unsold part of a listing selling and take that stock back (as in V1);
- collect the strike when a buyer exercises, and take back every unit not exercised once the
  exercise window closes (as in V1).

**A buyer can**

- buy calls from a listing (as in V1);
- post a bid: the number of tokens wanted, the strike, the premium per token and the Friday
  expiry. The whole premium is held by the contract from the moment the bid is posted, so a
  seller selling into it is always paid;
- raise a bid to ask for more at the same terms, paying in the extra premium;
- cancel a bid at any time: selling stops at once and the unspent premium becomes the buyer's
  to take back;
- take back unspent premium whenever it is free, with no deadline. After the bid's expiry,
  everything not spent is free without cancelling;
- exercise during the 24 hours after expiry and claim the stock (as in V1). Calls bought by a
  sale into a bid are exercised and claimed exactly like calls bought from a listing.

**A bid's life**

```
          bid (premium escrowed)       sellToBid (any seller, any part, until expiry)
  buyer ───────────────────────► OPEN ─────────────────────────────────────────► SOLD OUT
                                  │  raiseBid: asks for more, escrows more (reopens a closed bid)
                                  │  cancelBid: selling stops; unspent premium → refund
                                  ▼
   ─────────────── expiry (Friday 21:00 UTC) ───────────────
   selling stops; unspent premium is refundable with no deadline (refundBid)
   each sale is a V1 listing: exercise in [expiry, expiry + 24h), then claims and strike
```

**Why it is safe**

- Every sale is a V1 listing. Selling into a bid creates a new listing for the seller, fully
  sold, held by the bidder. Exercise, claim and strike collection are V1's, untouched, and so is
  V1's argument that the stock in the contract always covers what it owes.
- A bid's escrow is exactly the premium for what it still asks for. A sale is paid from its own
  bid's escrow and never more; across all the sales into one bid, sellers are paid exactly the
  premium one fill of everything sold would cost, however the sales are split or whoever makes
  them.
- Only the bidder can raise, cancel or refund a bid. Cancelling moves no tokens, so a USDC pause
  or a Circle blacklist on the bidder never stops them stopping their bid; the refund is a
  separate pull with no deadline.
- A sale is one atomic transaction: if the stock cannot move, the USDC cannot move, or staking
  refuses the fee, nothing happens.
- Every way out of the contract is a pull by its own party (`claim`, `collectStrike`,
  `refundBid`) with no deadline, as in V1.

**Known limits**

1. **Dust sales fragment a bidder's calls.** Each sale is its own listing, so a seller who sells
   1,000 tiny pieces into a bid leaves the bidder 1,000 listings to exercise one by one. No
   money is at risk and the griefer pays more gas per piece than the bidder does, but exercising
   everything costs the bidder many transactions in a 24-hour window. Not changed here; see open
   question 1 below.
2. **Another sale can shift a sale's price by one micro-USDC.** Sales into a bid share its
   rounding (see Arithmetic), so whether another seller's sale landed first moves a sale's
   premium by at most 0.000001 USDC either way. The terms per token never change.
3. **No bid deadline before expiry.** A bid sells until its expiry or until the bidder cancels,
   like a listing. A "good until" time would only save the bidder a cancel; cancelling is
   instant, cheap and needs no token.
4. **Sale fees are counted per bid, fill fees per fill.** A bid's sales together pay exactly 1%
   (rounded up once) of what was sold, so splitting a sale neither avoids nor adds to the fee,
   and a dust sale may carry no fee. A fill pays 1% rounded up on its own, as in V1.
5. **A sale may pay nothing.** A seller selling a piece too small to round up to a micro-USDC
   gets nothing for it. That is the seller's choice; the bidder already paid for it in escrow.
6. **No token taking a fee on transfer.** As in V1, the contract counts the amounts it asked to
   move; AMZNc and USDC take no transfer fee.
7. V1's limits all carry over: the exercise window is a deadline; fills and sales need staking to
   accept deposits; `list`, `fill`, `bid`, `raiseBid` and `sellToBid` need the stock's
   `effectiveAt()` to answer; all listings share one stock balance; positions are not
   transferable.

## Calls

All state-changing functions are `nonReentrant`, update state and emit their event before any
token call (checks–effects–interactions). Every call except `sellToBid` moves at most one token;
`sellToBid` is the trade itself and is all-or-nothing.

| Function | Who | Checks | Effects | Tokens moved |
| --- | --- | --- | --- | --- |
| `list(amount, strikePerToken, premiumPerToken, expiry)` | anyone holding stock | as V1 | as V1 | stock: seller → contract |
| `fill(listingId, amount)` | any buyer | as V1 | as V1 | USDC only, as V1 |
| `cancel(listingId)` | seller only | as V1 | as V1 | none |
| `exercise(listingId, amount)` | a holder | as V1 | as V1 | USDC: holder → contract |
| `claim(listingId)` | anyone owed stock | as V1 | as V1 | stock: contract → caller |
| `collectStrike(listingId)` | seller only | as V1 | as V1 | USDC: contract → seller |
| `bid(amount, strikePerToken, premiumPerToken, expiry)` | any buyer | all three > 0; `expiry % 1 weeks == WEEKLY_EXPIRY_OFFSET`; `expiry > now`; no scheduled multiplier change before the window closes | new bid id `++bidCount`; `BidPosted` with the escrow | USDC: bidder → contract, `costFor(amount, premiumPerToken)` |
| `raiseBid(bidId, amount)` | bidder only | `amount > 0`; `now < expiry`; no scheduled multiplier change before the window closes | `amount += amount`; `BidRaised` | USDC: bidder → contract, `raiseCostFor(bidId, amount)` |
| `cancelBid(bidId)` | bidder only | something unsold | `refundDue += escrow left`; `amount = filled`; `BidClosed` | none |
| `sellToBid(bidId, amount)` | any seller | bid exists; `amount > 0`; `now < expiry`; `amount ≤ amount − filled`; no scheduled multiplier change before the window closes | `filled += amount`; new listing (seller = caller, `amount = filled = amount`, the bid's strike, premium and expiry); `held[listing][bidder] += amount`; `SoldToBid` | stock: seller → contract, `amount`; USDC: contract → seller, `premium − fee`; contract approves staking `fee`, staking pulls it via `depositUSDC` (tag `autolaunch-covered-calls`, ref the new listing id) and must report exactly `fee` |
| `refundBid(bidId)` | bidder only | something to refund (after expiry, the unspent escrow is booked first, once) | after expiry with something unsold: as `cancelBid`; then `refundDue = 0`; `BidRefunded` | USDC: contract → bidder |

Views: V1's `claimable(listingId, account)`, `premiumFor`, `strikeFor`, `listings(id)`, `held`,
`owed`, `listingCount`; and `bids(id)`, `bidCount`, `refundable(bidId)` (exactly what
`refundBid` would pay now, including the unspent escrow after expiry before it is booked),
`costFor(amount, perToken)` (a new bid's escrow), `salePremiumFor(bidId, amount)` (the premium
and fee a sale would carry now; the seller receives `premium − fee`), and
`raiseCostFor(bidId, amount)`.

A listing made by a sale is announced by `SoldToBid`, not `Listed`. It is fully sold, so it can be
neither filled nor cancelled.

## State

Immutable configuration and constants are V1's: `stock`, `usdc`, `staking`, `unit`, `FEE_BPS`
(100), `EXERCISE_WINDOW` (1 day), `WEEKLY_EXPIRY_OFFSET` (1 day 21 hours), `FEE_SOURCE_TAG`
(`bytes32("autolaunch-covered-calls")`).

```solidity
struct Listing { ... }   // V1's, field for field
uint256 public listingCount;                    // ids count from 1
mapping(uint256 => Listing) internal _listings;
mapping(uint256 => mapping(address => uint256)) public held;
mapping(uint256 => mapping(address => uint256)) public owed;

struct Bid {
    address bidder;           // who bid; nonzero for every real bid
    uint64  expiry;           // a Friday 21:00 UTC
    uint256 amount;           // raw stock asked for (lowered to `filled` when the bid closes)
    uint256 filled;           // raw stock sold into the bid
    uint256 strikePerToken;   // USDC (6 dp) per whole token
    uint256 premiumPerToken;  // USDC (6 dp) per whole token
    uint256 refundDue;        // escrow released by closing and not yet refunded
}
uint256 public bidCount;                        // ids count from 1
mapping(uint256 => Bid) internal _bids;
```

A bid's escrow is never stored; it is always `costFor(amount) − costFor(filled) + refundDue` at
the bid's premium.

## Events

V1's seven (`Listed`, `Filled`, `Cancelled`, `Exercised`, `StockReturned`, `Claimed`,
`StrikeCollected`), and:

| Event | When |
| --- | --- |
| `BidPosted(bidId, bidder, amount, strikePerToken, premiumPerToken, expiry, escrow)` | a bid is posted |
| `BidRaised(bidId, amount, escrow)` | a bid asks for `amount` more and `escrow` more is held |
| `SoldToBid(bidId, listingId, seller, amount, premium, fee)` | a sale; the seller received `premium − fee` |
| `BidClosed(bidId, unsold, escrow)` | a bid stopped selling (cancelled, or booked after expiry) |
| `BidRefunded(bidId, amount)` | the bidder took a refund |

## Errors

V1's twelve, and `UnknownBid(bidId)` and `NotBidder(caller)`.

## Arithmetic

- `costFor(amount, perToken) = ceil(amount × perToken / unit)` (solady `mulDivUp`, reverting on
  overflow). A fill's premium, an exercise's strike and a new bid's escrow are each one
  `costFor`, rounded up in the seller's favour, as in V1.
- Each bid rounds once, over everything sold into it. With `paid(n) = costFor(n, premiumPerToken)`
  and `fee(p) = ceil(p × 100 / 10_000)`, a sale of `x` into a bid that has sold `filled` carries
  premium `paid(filled + x) − paid(filled)` and fee `fee(paid(filled + x)) − fee(paid(filled))`.
  The sums telescope: all the sales into a bid together pay exactly `paid(filled)`, of which
  staking receives exactly `fee(paid(filled))`. So splitting a sale into many, by one seller or
  many, pays the sellers together exactly what one sale would, and the bidder exactly the same.
  Each sale's premium is its exact value rounded down or up, never further.
- A raise escrows `paid(amount + x) − paid(amount)`, and closing a bid releases
  `paid(amount) − paid(filled)`. So whatever mix of sales, raises and cancels a bid sees, once
  refunded its bidder has paid exactly `paid(filled)`: one fill of what was sold.
- `fee(a) − fee(b) ≤ a − b` for any `a ≥ b`, so a sale's fee never exceeds its premium.
- All counters are `uint256` with checked arithmetic; the subtractions above cannot underflow by
  construction (see Invariants).

## Invariants

The contract's balances always equal what it owes:

1. **Stock held equals stock owed:** `stock.balanceOf(this)` equals, over every listing, the
   unexercised stock not yet returned plus everything owed. Sales into bids are listings and are
   counted the same way.
2. **USDC:** `usdc.balanceOf(this) = Σ_listings (strikePaid − strikeCollected) +
   Σ_bids (costFor(amount) − costFor(filled) + refundDue)`. Fill premiums and every fee pass
   straight through.
3. **Each bid's escrow is its own:** what a bidder paid in, less what it took back, less what its
   bid's sales paid out, is exactly the escrow its bid still holds; its sales paid out exactly
   `costFor(filled)`, and exactly `ceil(1%)` of that as fee. No sale reaches another bid's escrow.
4. **No overselling:** `filled ≤ amount` for every listing and bid; `exercised ≤ filled` and
   `Σ held + exercised = filled` for every listing; the listings sold into a bid add up to exactly
   its `filled`.
5. **Each unit and each micro-USDC pays once:** `cancel` and `cancelBid` lower `amount` to `filled`
   and cannot repeat; the after-window return and the after-expiry refund book exactly once;
   `claim` and `refundBid` zero what they pay before transferring.
6. **Fees reach staking exactly once:** `ceil(1%)` of each fill's premium, and `ceil(1%)` of each
   bid's sold premium; no allowance to staking is left behind.
7. **`claimable` equals what `claim` pays and `refundable` equals what `refundBid` pays,** in every
   state.
8. After every random run, when all restrictions are lifted, everyone collects everything, the
   contract ends holding zero stock and zero USDC, and each bidder has paid exactly
   `costFor(filled)`.

These run as Foundry invariants over random sequences of every call, listings and bids, by four
accounts across time, with the stock's pause and blocklist, USDC's pause and blacklist, scheduled
corporate actions and a refusing staking contract switching on and off
(`test/CoveredCallsV2.invariant.t.sol`). Two deliberate bugs (a sale rounding on its own, and
closing a bid without releasing its escrow) were each caught by them before being undone.

## Review

Adversarial review of the bid paths, with what it found and what changed:

| Concern | Finding and handling |
| --- | --- |
| **Reentrancy through stock, USDC or staking** | Every state-changing call is guarded and writes state and events first. Tested with a stock and a USDC that call back into the contract mid-transfer, trying each state-changing function in turn, and a staking contract that does the same during a sale and a fill: every callback is refused with `Reentrancy()` and the books stay exact (`test/CoveredCallsV2.attacks.t.sol`). |
| **Rounding theft** | Found while building: if each sale rounded up on its own, a seller splitting a sale into dust would draw more than the bid escrowed and starve later sellers. Fixed by rounding once per bid (Arithmetic). Fuzzed: one seller's split, many sellers' split, and random sales, raises and cancels all end exactly level with one sale (`test/CoveredCallsV2.split.t.sol`). |
| **Griefing a bidder's escrow** | Only the bidder can raise, cancel or refund. Found while building: if cancelling sent the refund, a blacklisted or paused bidder could not stop sales; cancelling now moves no token and refunding is a separate pull. A seller can fragment a bidder's calls into dust listings (Known limits 1). |
| **Front-running a sale** | A bidder cancelling or another seller filling the rest just before a sale makes it revert whole (`ExceedsAvailable`); nothing moves. A raise in the same block changes nothing for the sale (the terms are per token and cannot change). A seller names the bid by id, so a cancelled bid re-posted on worse terms is a different bid. Another seller's sale landing first moves the price by at most one micro-USDC (fuzzed). A seller selling just before a cancel lands sells at the bidder's own posted terms, as with any standing order. |
| **Paused or blocklisted tokens** | A sale needs both tokens to move and reverts whole otherwise. `cancelBid` moves nothing; `refundBid` needs only USDC; a bidder blacklisted by Circle can still be sold into, since the sale never touches the bidder's balance. Tested for each. |
| **Fee-on-transfer tokens** | Not supported, as in V1 (Known limits 6). |
| **Corporate action between bid and sale** | `sellToBid` and `raiseBid` refuse while a multiplier change is scheduled before the bid's exercise window closes; `cancelBid` and `refundBid` never check, so the escrow is always recoverable. Tested. |
| **Staking short-changing a fee** | A sale requires `depositUSDC` to report exactly the fee (`DepositMismatch` otherwise) and leaves no allowance. Tested with a staking that pulls half and one that reports more. |
| **Overflow** | Checked arithmetic and `mulDivUp` revert; tested for bids and raises at extreme amounts. A sale cannot overflow: it never costs more than the escrow its bid already worked out. |
| **Someone else's funds** | No call sends to anyone but the caller, except a fill's premium to its listing's own seller and fees to staking. Tested: no account reaches another's escrow, stock or strike at any stage of a bid's life. |

## Moving the site from V1 to V2

The simplest hard cutover is one release that points each market at V2 and drops V1 from the
site entirely.

**What stays the same.** The `Listing` struct, `listingCount`, `listings(uint256)` (the same ten
words), `held`, `owed`, `claimable`, `unit`, `usdc`, `stock`, `premiumFor`, `strikeFor` and the
stock's `effectiveAt()` and `multiplier()` reads are identical, so the listing reads in
`platform/lib/autolaunch/covered_calls/chain.ex` decode V2 unchanged. Calls bought through a bid
are ordinary listings: they appear as the bidder's holdings and as the seller's sold listings with
no new read. The six V1 steps (list, fill, cancel, exercise, claim, collect strike) are the same
calls.

**What the site must add.**

- Reads: `bidCount`; `bids(uint256)`, seven words (`bidder`, `expiry`, `amount`, `filled`,
  `strikePerToken`, `premiumPerToken`, `refundDue`); `refundable(bidId)`; `salePremiumFor(bidId,
  amount)` for what a seller receives (`premium − fee`); `raiseCostFor(bidId, amount)`; and
  `costFor(amount, premiumPerToken)` for a new bid's escrow. A bid is open while
  `now < expiry` and `amount > filled`.
- Steps: post a bid (exact USDC approval of `costFor`, then `bid`); raise (exact approval of
  `raiseCostFor`, then `raiseBid`); cancel a bid (no approval); sell into a bid (exact stock
  approval of `amount`, then `sellToBid`); refund (no approval). The new refusals are
  `UnknownBid` and `NotBidder`; the rest are V1's.
- Each new action needs its row and five surfaces in `docs/agent-parity.md`.

**The cutover.** The market record's `contract`
(`contracts/covered-calls/deploy/site-markets.json`, copied to the site's deployment file) changes
to the V2 address in the same release that ships the bid pages; no code path keeps reading V1. V2
counts listing and bid ids from 1, and the site reads one contract per market, so ids never meet
V1's. V1 has no owner and every pull on it has no deadline, so nothing on V1 is lost by the site
moving: the release should land after V1's last exercise window has closed, with a read at the
latest block listing any V1 stock or strike still unclaimed. Whether the site must show those
leftovers, or their owners claim on V1 directly, is a decision for Sean before the release.

**Deployment** of V2 is a contract deployment and needs Sean's go. It is not prepared here; V1's
[deploy/](../covered-calls/deploy/README.md) shows the shape it would follow (deterministic
CREATE2, an independently reviewed packet, a dry run on the latest Base block, and a Base fork
suite against the real AMZNc, USDC and REGENT staking).

## Checks

```sh
bin/gate.sh
```

The offline gate: `forge fmt --check`, `forge build`, and every suite. It builds against
`../stocks-v2/lib` (forge-std and solady), filled by `stocks-v2/bootstrap-deps.py`.

| Suite | Tests | What it covers |
| --- | --- | --- |
| `CoveredCallsV2.listings.t.sol` | 29 | V1's unit suite, run unchanged against V2's listings |
| `CoveredCallsV2.rules.t.sol` | 9 | V1's rules suite |
| `CoveredCallsV2.ordering.t.sol` | 9 | V1's ordering suite |
| `CoveredCallsV2.recovery.t.sol` | 13 | V1's recovery suite |
| `CoveredCallsV2.bids.t.sol` | 35 | every bid call and refusal, all-or-nothing sales, a blacklisted bidder still sold into, dust, many sellers, one seller into many bids, expiry with no deadline, corporate actions, cancel or raise just before a sale |
| `CoveredCallsV2.split.t.sol` | 3 fuzz | splitting never pays a seller less or a bidder more than one sale |
| `CoveredCallsV2.attacks.t.sol` | 5 | reentry through stock, USDC and staking; nobody reaches another's funds; overflow |
| `CoveredCallsV2.invariant.t.sol` | 8 invariants | the Invariants above |

There is no Base fork suite yet: it needs a Base RPC, and it belongs with the deployment work.
