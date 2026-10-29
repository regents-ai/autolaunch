# What you can do on Autolaunch with your onchain stock

Draft, 27 October 2026. For holders of onchain stock tokens. One walkthrough for each
family of stock tokens Autolaunch supports today. Every link opens the live page. Figures
and lists are as the site showed them on 27 October; the stock list is refreshed
separately (see "Which stocks").

Covered calls are not live yet. Their section is marked below and is replaced once the
covered-call flow is built and released.

## Coinbase stock tokens on Base

The tickers end in a small "c": AAPLc, AMZNc, GOOGLc, METAc, MSFTc, MSTRc, NVDAc, SNDKc,
SPCXc and TSLAc. All ten can be used on Autolaunch today.

### 1. Bid in a Memestock auction with your stock

- **What you do:** open a live Memestock auction paired to your stock from
  [Auctions](https://autolaunch.sh/auctions), and bid with the stock itself. You set your
  total budget and the highest price you would pay.
- **What you receive:** the new token, bought a little at a time over the auction at the
  price each block clears at, never above your highest price.
- **What happens to your stock:** the part of your budget that buys tokens stays in the
  auction. If the price passes your highest price, the rest of your budget is no longer
  spent and you take it back. If the auction misses its minimum, you take back your whole
  bid. Your open bids are on [Portfolio](https://autolaunch.sh/portfolio).
- **After the auction:** the stock raised is paired with the new token in a trading pool
  that is locked for good. That stock does not come back to bidders; what bidders hold is
  the new token.

### 2. Stake the token and earn your stock

- **What you do:** on the token's page (for example
  [BITE, paired to AAPLc](https://autolaunch.sh/tokens/BITE/80be8) or
  [AIFROG, paired to NVDAc](https://autolaunch.sh/tokens/AIFROG/85e71)), press Stake.
- **What you receive:** a share of every trade's fee, paid in the stock. For new
  Memestock tokens, stakers share 3% of the stock side of every trade; BITE, JollyB, AGI
  and RDOG, launched under the first terms, pay stakers 1%.
- **What happens to your position:** your tokens stay staked until you press Unstake,
  which you can do for any part of your stake. Claim Rewards sends the stock you have
  earned to your wallet.

### 3. Launch a Memestock token paired to your stock

- **What you do:** open [Create](https://autolaunch.sh/create), pick Memestock, choose Base
  and your stock, name your token and start a 24-hour auction.
- **What you receive:** 0.5% of the token, released to you over 30 days after the auction
  succeeds, and 0.30% of the stock side of every trade.
- **What happens:** bidders pay in your stock. 49.75% of the tokens are sold in the auction
  and 49.75% go into the locked trading pool. If the auction misses its minimum, every bidder is
  refunded in full and the tokens are retired.

### 4. Covered calls

[local text to be replaced by: what a holder of a Coinbase stock token does to sell a
covered call on Autolaunch, what they receive (the premium), what happens to the shares
held for the call until expiry, how the buyer's side works, and the direct link into the
flow. Written once Sean's covered-call spec and the flow exist.]

## Robinhood stock tokens on Robinhood Chain

Plain tickers such as SPCX and SNDK. 25 Robinhood stocks can be used on Autolaunch today;
the full list is on [Onchain Stocks](https://autolaunch.sh/stock-listing).

### 1. Bid in a Memestock auction with your stock

Same as on Base: bid with the stock in a live Robinhood Memestock auction from
[Auctions](https://autolaunch.sh/auctions); you receive the new token, unspent stock comes
back to you, and a failed auction refunds your whole bid. Example: RDOG, paired to SPCX.

### 2. Stake the token and earn your stock

On the token's page, for example
[SANDY, paired to SNDK](https://autolaunch.sh/tokens/SANDY/96468) or
[RDOG, paired to SPCX](https://autolaunch.sh/tokens/RDOG/9ad00), press Stake. Rewards are
paid in the Robinhood stock token and claimed with Claim Rewards.

### 3. Launch a Memestock token paired to your stock

On [Create](https://autolaunch.sh/create), choose Robinhood and your stock. Same terms as
on Base.

### 4. Covered calls

[local text to be replaced by: the same covered-call walkthrough for Robinhood stock
tokens, with its direct link. Written once the flow exists.]

## Which stocks

[Onchain Stocks](https://autolaunch.sh/stock-listing) shows the stocks you can use now
(Available to Pair) and those coming next. Each stock's own page, for example
[AAPLc](https://autolaunch.sh/stock-listing/AAPLc), shows its addresses, company links and
where to buy it.

## Notes for whoever publishes this

- Before any of this goes out under Sean's name, it needs its own decision with the exact
  place and final text.
- Re-read every figure on the day it is published: auction terms, the fee shares and the
  stock list come from the live site on 27 October.
- The adoption steps to count for each family of stocks, split founder, friends and
  people we do not know: starts the flow, funds a position, gets a fill, finishes.
