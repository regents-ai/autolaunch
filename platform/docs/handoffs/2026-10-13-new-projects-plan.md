# Plans: covered calls and automatic stock additions (Autolaunch new features lane)

Sean, 13 October 2026 16:08Z, relayed verbatim by the Chief Regent orchestrator:
"3. new project: autolaunch covered call options. 4. new project: automating the process to
add more onchain stock tokens as soon as they have a chainlink feed on base or rh, and a pool
with liquidity more than 10k."

Status: plan only. No code, no deployment, no signing. Sent to the orchestrator for a sense
check; the numbered decisions go to Sean in the new-features thread.

## Project 4: add stocks automatically

### How a stock is added today (all by hand)

1. A Chainlink price feed for the stock exists on the chain.
2. A deep dollar pool exists (USDC on Base, USDG on Robinhood).
3. Someone deploys one small route contract for that stock. It is pinned for good to the
   stock, one pool and one feed (`AerodromeStockRouteV2` on Base, `UniswapV3StockRouteV1` on
   Robinhood). It has no owner; anyone can deploy one.
4. The Safe 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e (2 of 3) calls
   `admitStock(stock, route)` on the launchpad. Only the Safe can.
5. The site is released again: each chain "offers exactly the stocks its deployment
   description lists" (a file shipped with the site), plus a hard-coded Base catalog and feed
   list in `Autolaunch.Stocks.Assets` and `Autolaunch.Stocks.PriceFeeds`.

### What the automation is

- **Watcher** (site, one Oban cron job, the same shape as the existing morning volume read):
  reads Chainlink's public feed lists for Base and Robinhood, finds each feed's stock token,
  reads its dollar pools from GeckoTerminal, then confirms on the chain itself: the pool holds
  exactly the dollar token and the stock, the dollar side is worth more than $10,000, the feed
  answers and is fresh. Records each candidate and why it qualifies or not.
- **Route deployment**: for each qualifying stock, the fixed route contract is deployed with
  (stock, pool, feed). No authority is involved, only gas. Signed by a low-value operator key
  the server holds, or done by a small factory contract so the address is predictable.
- **Admission**: the one step that carries authority. See decision AL-127.
- **Site listing without a release**: the site reads `StockAdmitted` from the launchpads into
  its `Stock` table and offers what the chain has admitted; name, ticker and decimals come from
  the token; logo falls back to initials (already built); the hard-coded catalog and feed list
  are deleted, not kept beside the table.

### What I found today (13 October)

- No new Chainlink stock feeds since the 11 October survey (Base 13, Robinhood 36).
- Base: COIN, CRCL and INTC have feeds but no USDC pool at all. Nothing to add.
- Robinhood: 11 stocks have feeds and are not admitted. Eight have a pool over $10,000:
  GLD $2.25M, COIN $815K, NBIS $125K, ORCL $120K, CRWV $42.5K, RKLB $29K, ASML $24.7K,
  EWY $13K. Below the line: IONQ, RGTI, CLSK.
- **Six of those eight keep their liquidity on Uniswap v4.** The Robinhood route we have works
  only with Uniswap v3 pools (ASML and GLD). Without a v4 route the rule adds two stocks, not
  eight.
- GLD's feed prices gold, not a tokenised share; it needs a yes or no from Sean.

### Risks to settle before code

- A fake token or a fake feed: neither chain has an on-chain list of genuine Chainlink feeds or
  genuine issuer tokens, so "this is the real COIN and its real feed" cannot be proved by a
  contract alone. Whoever admits is trusting an off-chain read.
- $10,000 of liquidity can be placed for an hour and removed. The check should hold for a
  period (for example every read over 24 hours), not once.
- A wrong admission can be stopped (`revokeStock`) but only for new launches.

## Project 3: covered call options

No spec has reached this thread yet (Sean said he would share one), so this is a proposal to
react to, not a design.

### What it could be

- A holder of an onchain stock (AAPLc, MSTRc and so on; memestock stakers earn these from
  trading fees) deposits shares and sells the right to buy them at a set price (the strike) on
  a set date. The buyer pays a premium in dollars up front. The seller keeps the premium
  whatever happens; if the stock ends above the strike the buyer takes the shares at the
  strike.
- Fully covered: the shares sit in the contract until expiry, so a seller can never owe more
  than they deposited.
- The calls are sold through the same auction Autolaunch already runs for tokens, so the
  market sets the premium. This is the part only Autolaunch has.

### On-chain parts and who signs

- New contracts (Foundry, own folder, `contracts/v1` untouched): an option series (stock,
  strike, expiry), a vault holding the deposited shares, and the sale through the existing
  auction.
- The seller signs the deposit. The buyer signs the bid and, at expiry, the exercise. Nobody
  else can move the shares or the premium; there is no operator in the path.
- Settlement choice (decision AL-131): the buyer pays the strike and takes the shares
  (needs no price feed at all), or the contract pays the difference in dollars using the
  Chainlink feed (simpler for the buyer, but trusts the feed, which holds Friday's close over
  weekends).
- Deployment and any admin role: Sean's Safe, on his go.

### Site parts

- A "Sell covered calls" page for holders and a "Calls" list for buyers, built from the
  existing auction, bid and portfolio pieces.

## Decisions for Sean

AL-127. Who admits a new stock once the checks pass?
- Changes the launchpads' admission step on Base and Robinhood.
- (a) The Safe keeps signing: the server prepares one ready-to-sign batch and notifies the
  signers; a stock is live the same day, nothing new can go wrong on-chain.
- (b) A new admitter contract the Safe authorises once: it deploys the route itself, runs the
  pool and feed checks on-chain and admits with no human. Fully automatic, but a new audited
  contract, and it still trusts a server key to say which token and feed are genuine.
- Recommendation: (a). The dangerous part (is this the real stock and feed) cannot be proved
  on-chain, so a human signature there is cheap insurance; revisit when additions are frequent.

AL-128. Build a Uniswap v4 route for Robinhood?
- New contract in the Robinhood contracts folder, with tests and a review, deployed per stock.
- (a) Yes: the rule then covers COIN, NBIS, ORCL, CRWV, RKLB and EWY as well.
- (b) No: only stocks with a Uniswap v3 pool are added (today ASML and GLD).
- Recommendation: (a). Robinhood liquidity has moved to v4; without it the automation adds
  almost nothing.

AL-129. Does the $10,000 have to hold over time?
- Changes the watcher's rule only.
- (a) Every read over 24 hours must show more than $10,000.
- (b) One read is enough.
- Recommendation: (a). It costs a day and stops a pool that is filled for an hour.

AL-130. GLD on Robinhood?
- (a) Leave it out: its feed is the gold price, not a share price.
- (b) Add it as a stock like the others.
- Recommendation: (a) until Sean says commodities belong in the stock list.

AL-131. Covered calls: what is the underlying, and how do they settle?
- (a) Onchain stocks, buyer pays the strike and takes the shares (no price feed needed).
- (b) Onchain stocks, paid out in dollars from the Chainlink price.
- (c) Memestock tokens rather than the stocks.
- Recommendation: (a). It is the simplest contract, cannot be hurt by a bad or stale price,
  and the seller's risk is exactly the shares they put in. Sean's spec replaces this.

AL-132. Covered calls: who picks strike and expiry?
- (a) Fixed menu: weekly expiry, strike a set percentage above the price at listing.
- (b) The seller chooses freely.
- Recommendation: (a). Buyers pool into a few series instead of being spread over hundreds.

Also for Sean, not a lettered decision: options on tokenised stocks are regulated in many
places. This is a flag for his own advice, not legal advice from this thread.
