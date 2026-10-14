# Plans: covered calls and automatic stock additions (Autolaunch new features lane)

Sean, 13 October 2026 16:08Z, relayed verbatim by the Chief Regent orchestrator:
"3. new project: autolaunch covered call options. 4. new project: automating the process to
add more onchain stock tokens as soon as they have a chainlink feed on base or rh, and a pool
with liquidity more than 10k."

Status: plan only. No code, no deployment, no signing. The orchestrator's sense check of
13 October 16:17Z cleared it to go to Sean with one added decision (AL-136). Base has nothing
to add today, and without a Uniswap v4 route the rule adds two Robinhood stocks, so AL-128 is
the decision that gives project 4 its value.

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
  (stock, pool, feed). No authority is involved, only gas. Who deploys is decision AL-136: the
  Safe's own batch (deploy at a predictable address, then admit, in one signing) or a low-value
  operator key on the server.
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

AL-136. Who deploys each stock's route contract? (Added at the orchestrator's sense check,
13 October 16:17Z; numbered 136 because 133 to 135 are the UI decisions already with Sean.)
- (a) The Safe's prepared batch deploys the route and admits the stock in one signing; the
  server holds no key that can spend anything.
- (b) A low-value operator key on the server deploys routes as stocks qualify; the Safe then
  only admits.
- Recommendation: (a) while additions are rare. A key on the server is one more thing to guard
  and watch, for perhaps two stocks a month.

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

## Sean's answers, 13 October

Sean, verbatim: "1a 2. a, though I thought all of our autolaunch contracts use uniswap v4
already? 3. b 4. b 5. hold on this until spec 6. hold 7. a 8. a 9. a 10. b". The list he
answered was numbered 1 AL-127, 2 AL-128, 3 AL-129, 4 AL-130, 5 AL-136, 6 AL-131, 7 AL-132,
8 AL-126, 9 AL-133, 10 AL-134, 11 AL-135.

- AL-127 (a): the Safe signs a batch the server prepares.
- AL-128 (a): build the Uniswap v4 route for Robinhood. Built, see below.
- AL-129 (b): one reading over $10,000 is enough.
- AL-130 (b): GLD is added as a stock like the others.
- AL-136: on hold until Sean's spec. (If he was counting one line later, this one is unanswered
  and "hold until spec" is the covered-call question; asked him to confirm.)
- AL-131: on hold. AL-132 (a): fixed menu. Both wait for the covered-call spec either way.
- AL-126 (a) and AL-133 (a): done on the UI branch.
- AL-MIN-1 (b), relayed by the orchestrator at about 17:08Z ("1 b"): the launch contracts stay
  as they are; Robinhood launches keep no real minimum. Closed, nothing to build.
- Sean, 17:35Z through the Patchbay thread: "nothing should be payable in any of the sites except
  with Credits (autolaunch USDC/USDG bidding is fine)". Autolaunch charges nothing in USDC today
  besides bids, trades and buying Credits themselves. A covered-call premium would be a new USDC
  payment, so the spec has to say whether it counts as bidding.

## The v4 route (AL-128 a): built, not deployed

- Why it was needed: Autolaunch's own launch pools and fee hooks are Uniswap v4 on both chains.
  The route is a separate small contract per stock that swaps USDG into the stock (to bid) and
  back (to convert fees) in the pool where the stock already trades with outsiders. On Robinhood
  only a v3 version existed, and six of the eight qualifying stocks trade only in v4 pools.
- Source: contracts/robinhood-v2/src/routes/UniswapV4StockRouteV1.sol. Tests:
  contracts/robinhood-v2/test/UniswapV4StockRoute.t.sol (26 run in both currency orders),
  contracts/robinhood-v2/test/RobinhoodV4RouteCallers.t.sol (through the bid adapter and the
  hook's lane settlement on a real pool manager), and
  contracts/robinhood-v2/test/fork/UniswapV4StockRouteFork.t.sol (the live COIN and CRWV pools;
  runs only on a fork of Robinhood Chain, outside the gate).
- Independent review: no critical, high or medium findings. Its two low findings and its notes
  are answered in 6bfac87, except that the fork suite stays outside the gate.
- What nothing on-chain checks: that a route points at the real pool manager, pool and feed.
  Admission checks only the route's stock and USDG. The Safe's checklist in
  contracts/robinhood-v2/README.md note 13 is the control, and the prepared batch (AL-127 a) must
  show those values to the signers.

## Still to build for project 4

1. The watcher: one Oban cron job that finds stocks with a Chainlink feed and an outside pool
   over $10,000 on a single reading (GLD included) and records each candidate.
2. The site reads `StockAdmitted` into its `Stock` table; the hard-coded lists
   (`Autolaunch.Stocks.Assets`, `Autolaunch.Stocks.PriceFeeds`) go.
3. The prepared Safe batch for admission, showing the checklist values. Who deploys the route
   (AL-136) is on hold, so the batch covers admission only until Sean answers.
Nothing is deployed, signed or paid without Sean's go.


## Design for project 4's site parts (13 October, for the orchestrator's sense check)

Branch `al/stock-watcher-1013`, cut from al/sean-ui-1013 23d51e4 in the same worktree. No code
yet. Build order is A then B; C waits for AL-136.

### A. New stocks appear without a site release

Today the stock list comes from two files written when contracts are deployed
(`stocks-site-config.json` for Base, `site-config.json` for Robinhood; written by
contracts/stocks-v2/bin/ceremony.py, its Robinhood counterpart and the two local lab scripts,
read by `Autolaunch.Stocks.Lab` and `Autolaunch.Robinhood.Lab`). Base names and feeds come from
two hard-coded lists (`Autolaunch.Stocks.Assets`, `Autolaunch.Stocks.PriceFeeds`). A new stock
therefore needs new files and a release.

After:

- One source: the `Autolaunch.Stocks.Stock` table (already one row per chain and address) gains
  route, feed, decimals and whether the stock is admitted now.
- One scheduled Oban job per chain (an AshOban trigger, as the weekly volume read already is)
  reads the launchpad's `StockAdmitted` and `StockRevoked` logs, then for each stock reads at
  the latest block: `stockAdmission(stock)`, the route's `feed()`, and the token's `name()`,
  `symbol()` and `decimals()`. It writes the rows. Every fact is a chain read.
- Pages, the picker, search and the market reads use the table.
- Removed, not kept beside it: the `stocks` list in both description files (the scripts stop
  writing it, the loaders stop reading it), the catalog and feed lists in the two modules above,
  and the start-up task `Autolaunch.Stocks.SupportedStocks`. "The same company on the other
  chain" becomes a match on ticker instead of the catalog's pairs.
- Unchanged: the launchpad's own `stockAdmission` is still read before every launch and bid, so
  a stock revoked a minute ago cannot be launched against even if a page still shows it.
- The local lab admits its practice stocks on its own chain, so they are read the same way.

What the release of A needs beyond code: a migration adding the columns (a production database
change). That is a release item for Sean, not done here. As built, the production description
files need no change: the loaders no longer read their `stocks` list and ignore it.

#### Build notes for A (13 October, after the orchestrator's clear with conditions a to e)

Settled while reading the code; this is what is being built on `al/stock-watcher-1013`.

- The job: an AshOban scheduled action on `Autolaunch.Stocks.Stock` (`:sync_admissions`, every
  five minutes, its own queue with a limit of one), the same shape as
  `Autolaunch.LaunchDiscovery`'s `:discover_memestock`. It takes the two stock launchpads from
  `Autolaunch.AuctionFinish.Launchpads.configured/0`.
- Its place: a new one-row-per-chain table (`Autolaunch.Stocks.AdmissionScan`: chain, launchpad,
  run id, next block). A different launchpad or run id (a new deployment, or a restarted local
  lab) starts the read again from the launchpad's first block. Each run has two passes. First,
  every stock already saved for the chain is asked of the chain again, which is how a revoked
  stock leaves the list. Second, `StockAdmitted` logs are read from the saved block less 1,000
  blocks to the latest block, in ranges of 2,000 blocks (the range the site's other log readers
  use), at most 250 ranges a run; each stock they name that is not saved yet is asked of the
  chain. The block after the last range read is saved with the stocks named but not read yet
  (`unread`), so one unreadable stock holds back neither the others nor the place.
- Every row's facts are read at the latest block: `stockAdmission(stock)`, the route's
  `feed()`, the token's `name()` and `symbol()`. No fact comes from a log.
- First block: the block the launchpad's code first appears in, found on the chain
  (`Autolaunch.Chain.Rpc.deployment_block/3`, as the auction activity reader already does). The
  description files gain nothing.
- When: every five minutes, and once when a server starts (the schedule runs on one server
  only, so each new server queues one run itself; the job is unique while it waits or runs, so
  a second is dropped and there is one run at a time across every server).
- Reads: `Autolaunch.Stocks.Assets` keeps its name and becomes the one way to ask for stocks
  (`all/1`, `fetch/2`, `named/2`, `counterpart/2`, `known/1`), answering from the table through
  a one-minute kept answer (Cachex), because the Robinhood market reader asks for a stock on
  every block. A new stock shows within a minute of the job writing it.
- Names: a stock's name is the token's own `name()` ("Apple Inc.", "Strategy Inc."), no longer
  the catalog's short name ("Apple", "Strategy").
- Feed: a route that names no feed (the practice routes) gives a stock no dollar price. So the
  Base practice lab keeps its prices, `FixtureStockRoute` gains a `feed` set by the lab script;
  the Robinhood practice route has never answered as a feed and stays without one.
- The practice preview (sample data, no chain) runs no jobs, so its stock rows are written by
  hand from what the live launchpads answer.
- Gone in the same head: the `stocks` list in both descriptions and their loaders, the catalog
  and counterpart pairs in `Autolaunch.Stocks.Assets`, `Autolaunch.Stocks.PriceFeeds`' feed list,
  `Autolaunch.Stocks.SupportedStocks`, and the unused `catalog_status`, `launch_admission`,
  `fixture`, `pool` and `oracle_registry` values.

#### What was checked for A (13 October)

- On a private copy of live Base (the real launchpad and routes), inside a database
  transaction that was thrown away: the first run filled in two saved stocks and left alone a
  saved stock the launchpad never admitted; after the Safe's address revoked Apple and
  re-admitted Alphabet, the next run took Apple out of the picker (it still answers by address,
  so old auctions keep working) and added Alphabet as a new row; a third run wrote nothing; a
  run with the chain not answering failed and kept its place; a newly admitted stock whose
  route did not answer failed the run, was kept as unread while the place moved on, and was
  saved once the route answered. Dollar prices came back from the feed saved on each row, a
  revoked stock's included.
- Two independent reviews (contracts and scripts; site code); every finding answered in the
  head. Details in `platform/docs/handoffs/2026-10-13-stock-list-from-chain.md`.
- `make check-platform` and both v2 packages' format, build, tests and frozen-surface checks.
  `bin/gate.sh` needs a pristine checkout and is for Sentinel.
- Live answers on 13 October: the Base launchpad admits ten stocks (AAPLc, AMZNc, GOOGLc,
  METAc, MSFTc, MSTRc, NVDAc, SNDKc, SPCXc, TSLAc); Circle and Intel are not admitted there.
  The Robinhood launchpad admits all 25 of its listed stocks, each with a feed.
- At the first release: saved stocks are right within seconds of the new server starting.
  Stocks not saved before are found by the log read: about 2 runs on Base, about 10 runs
  (some 50 minutes) on Robinhood, whose launchpad is some 5 million blocks old.
- Roll forward only: the version before this one writes its own stock rows at start, in mixed
  case, and would add a second copy of every Base stock beside the lowercase rows; those copies
  then make every run report a failure until they are deleted.
- For part C: `feed()` is in no route interface, so nothing but the sync asks a route for it.
  The Safe's check before signing has to include: the route answers `feed()`, and the token's
  name is at most 120 characters and its ticker at most 32, or the site will not list it.
- Seen and left for Sean: Base names in the picker are now the tokens' own, which are longer
  ("Space Exploration Technologies Corp." where the list said "SpaceX").

### B. The watcher (built 13 October, local, not released)

What it does: every hour the site writes down which stocks Chainlink prices on Base and on
Robinhood that the launchpad does not admit yet, and what each one's market looks like. The
rows are advice for the three signers. Nothing reads them for a launch, a bid, the picker or a
price, and no page shows them yet (that waits for AL-137).

- One table, `stock_candidates` (`Autolaunch.Stocks.StockCandidate`), one row per chain and
  ticker. Per chain and ticker, not per chain and token as first planned, so a stock with a
  feed and no pool yet still has a row.
- Two jobs, both in the shape the site's other jobs have (AshOban; no hand-built loop):
  - At two past each hour, `:list_feeds` reads Chainlink's public feed list for each chain
    (`reference-data-directory.vercel.app`, one read of fifteen seconds at most per chain),
    keeps a row for every stock feed whose ticker no admitted stock carries, and removes a row
    whose feed has left the list or whose stock has been admitted. Queue `outside_calls`, three
    attempts, one run at a time across every server. A list that cannot be read, that names no
    stock feed at all or more than two hundred, or that is larger than four megabytes, fails
    the run and changes nothing.
  - Every ten minutes (at :05, :15 and so on) the three rows tried longest ago are read, one at
    a time, on the queue the weekly volume reads use (`stock_volume`, GeckoTerminal's free
    service counts both together): the first page of GeckoTerminal's search for the stock's
    symbol, tried once with no wait, then, at one latest block, the feed's latest round and
    whether a pool's token is the issuer's. One attempt, thirty seconds at most. Each read
    writes the time it was tried before any outside read (`:mark_tried`, also the trigger's
    `on_error`), so a row whose read fails or runs out of time waits its turn like the rest.
  - The bound (Sentinel's finding of 20:28Z): the reads hold their queue for a minute and a
    half at a stretch at the very most (three rows, thirty seconds each), usually a few
    seconds, whatever the feed list names. Up to eighteen rows are each read within the hour;
    a longer list is read more slowly, not harder.
- A row says one of: `qualifies` (feed answers, issuer's token has a dollar pool with more than
  $10,000 in it; one reading, AL-129 b), `thin_pool`, `no_dollar_pool`, `feed_silent` (no
  price, or one more than seven days old), `unread`. It keeps the token, the deepest dollar
  pool, the venue under GeckoTerminal's name and the dollars in the pool. GLD is treated like
  any other (AL-130 b).
- The issuer marks: on Base an address of the form Coinbase's share tokens have, with the
  feed's ticker plus `c` as symbol; on Robinhood a token behind Robinhood's stock token beacon
  with the feed's ticker as symbol. Both can be copied by anyone, so a row is never proof that
  a token is the issuer's own. The Safe's check before signing (AL-127 a) is the control.
- Left for part C: the pool's fee and tick spacing and the route's settings are read when the
  batch is prepared, not kept on the row.
- Known limits: a stock whose pools GeckoTerminal's first search page does not show is missed
  until it does. The dollar figure is GeckoTerminal's, not the chain's. A pool whose token is
  not written as an address, or whose dollar figure is not a plain number under a trillion, is
  left out. A read stopped at its thirty seconds is not stamped as tried, so it is tried again
  first; that needs a chain or a GeckoTerminal slow enough to stall every row, not one bad row.
- Nothing here signs, sends or pays. No test was added.

Release item for Sean when this goes out: one more migration, the new `stock_candidates` table
(Autolaunch's own; it also goes on the protected-tables record).

#### What was checked for B (13 October, 20:24Z)

A rehearsal against live Base and live Robinhood Chain (read only), with the launchpads' real
admitted lists saved first:

- Feeds listed: Base COIN, CRCL, INTC; Robinhood ASML, CLSK, COIN, CRWV, EWY, GLD, IONQ, NBIS,
  ORCL, RGTI, RKLB.
- Robinhood `qualifies`: GLD ($2.25M, Uniswap v3), COIN ($812K), NBIS ($124K), ORCL ($119K),
  CRWV ($43K), ASML ($25K, Uniswap v3), RKLB ($19K); the rest on Uniswap v4.
- Robinhood `thin_pool`: EWY ($9,810), IONQ ($3,421), RGTI ($2,248), CLSK ($1,217).
- Base: all three `no_dollar_pool`.
- COIN left the Robinhood rows once saved as admitted (through the job's own action).
- A Base row read eight days on with no new price said `feed_silent`.
- A read with the chain not answering failed and left the row as it was.
- Three reads were refused by GeckoTerminal for a while and went through after the wait (30 to
  90 seconds each).
- The rehearsal found one defect, fixed in this head: the latest block was chosen before the
  GeckoTerminal search, so a search that waited could leave the chain reads asking about a
  block a node no longer answers for. The search now comes first.

After the reviews (Sentinel 20:28Z, orchestrator 20:33Z: one MEDIUM, the shared queue held for
as long as an outside list and GeckoTerminal's refusals decide; LOWs on unchecked outside values
and the list's size), rehearsed again on the changed code, live and read only:

- Six rounds of three, a minute apart: eighteen reads, none refused, every one of the fourteen
  rows read by the fifth round, each in under 2.3 seconds. The findings matched the first run.
- Without the pacing, ten reads at once: GeckoTerminal refused from the sixth on. That is why
  the rounds are three rows every ten minutes and not ten rows on the hour.
- The real jobs (the sweep, then its three reads, run through Oban): never-tried rows are
  picked first; with the chain not answering all three reads failed, each row kept what it said
  and was stamped as tried, and the next round picked three other rows; a refused GeckoTerminal
  read did the same.
- The feed lists are read with the four-megabyte limit (they are 85 and 252 kilobytes).
- Not rehearsed: a list larger than the limit, and a list naming more than two hundred stock
  feeds; both hosts are fixed in code, so neither can be made to answer that way.

### C. The Safe's prepared batch (AL-136 a)

Sean, 13 October, about 18:1xZ, answering the list of four in this thread (1 AL-NUM-1,
2 AL-136, 3 AL-135, 4 AL-131), verbatim: "1. where is this list coming from? link to file
2. a 3. b , but only show 2 venues max, the 2 highest ones". So AL-136 is (a): the Safe's
prepared batch deploys the route and admits the stock in one signing; the server holds no key.
AL-135 is built on al/sean-ui-1013 (659ab14). His first line is a question back about the
numbering check, so AL-131, AL-132 and AL-134 stay as the numbers literally read until he says.

Shape, to be checked before any code:

- A Safe cannot create a contract from an ordinary call, so the batch's first call goes to a
  deterministic deployer (CREATE2) with the route's code and its settings (stock, pool manager
  or pool, fee, spacing, feed); the second call is `admitStock(stock, route)`. To check on each
  chain first: that a deterministic deployer exists there, and which one.
- The route's address is fixed by its code and settings before anything is signed. That is how
  Sentinel's first condition is met with one signing: a second party recomputes the address
  from the code and settings in the batch and confirms the settings name the real pool manager,
  pool and feed, and that record is saved beside the admission.
- The server prepares the batch file for the Safe app from a qualifying `StockCandidate` row and
  shows the checklist values with it. It signs nothing and sends nothing.
- Still to settle with Sean: how the three signers are told a stock is ready.

Sentinel's two conditions for the day a route is put forward (13 October 17:47Z): the read-back
of `poolManager()`, `poolId()`, `fee()`, `tickSpacing()`, `feed()` and the runtime code hash is
done by someone other than whoever deployed the route and saved beside the admission; and
contracts/robinhood-v2/bin/gate.sh is run whole in a pristine checkout first.

The orchestrator's condition (13 October, sense check of 659ab14), to build with the batch and
before any admission: today `admitStock` checks only the route's `stock()` and `usdg()`, so
nothing on the chain ties a route to the real pool manager, pool and feed. Make `admitStock`
refuse a route whose `poolManager()` is not the launchpad's own, and have the prepared batch
show the route's `poolId` and `feed` beside the checklist. This is a contract change, so it
gets its own independent review.

## Notes from the reviews of al/sean-ui-1013 23d51e4 (Sentinel CLEAR 13 October 17:47Z)

- Sign-in window closed without signing in: platform/assets/js/privy_bridge.tsx says nothing,
  written this site's own way. The template does the same in its release line (2f5dc1b). At the
  next re-pin take the template's form so there is one standard.
- Boundary with the production fixes thread, agreed 13 October: that thread owns when and how
  often lists are read (`LiveListings`, the market feeds, each list page's mount, handle_info
  and load); this thread owns what a row, card and empty list show. Whoever ships second brings
  their branch up to main first.
- Done in 88313a0 and 08f718b: a prepared bid's key carries its auction, and each auction
  page's bid form is named after its auction.
