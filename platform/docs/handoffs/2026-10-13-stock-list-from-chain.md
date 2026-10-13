# Hand-off: the stock list is read from the chain (project 4, part A)

Branch `al/stock-watcher-1013`, worktree
`/Users/sean/Documents/regent/worktrees/autolaunch/stocks-cca`. Cut from `al/sean-ui-1013`
08f718b, so it releases after that head or together with it. Nothing is pushed, deployed, signed
or paid. Design and the orchestrator's conditions a to e are in
`platform/docs/handoffs/2026-10-13-new-projects-plan.md`.

## What changes for a person

A stock the Safe admits on a launchpad shows in the create page's picker within about six
minutes, with its dollar price, with no site release. A stock the Safe revokes leaves the picker
within about six minutes; auctions already trading in it keep working and keep their dollar
prices.

Stocks are named as their tokens name themselves, and the picker shows that name without the
company's legal form at the end (Sean, 13 October, AL-138 b): "Apple Inc." shows as "Apple",
"Microsoft Corporation" as "Microsoft", "Space Exploration Technologies Corp." as "Space
Exploration Technologies", where the built-in list said "Apple" and "SpaceX". The saved row keeps
the token's name as the chain gives it. One rule for both chains, so on Robinhood "Strategy Inc."
and "Sandisk Corporation" lose their endings too; its "Space Exploration Technologies Corp. Class
A Common Stock" does not end in a legal form and shows whole.

## How it works

- `Autolaunch.Stocks.Stock` gains `admitted`, `decimals`, `route` and `feed`. Its scheduled
  action `:sync_admissions` (AshOban, queue `stock_admissions`, three attempts) runs every five
  minutes and once when a server starts. The job is unique while it waits, runs or waits to be
  tried again, so there is one run at a time across every server.
- Each run, for each stock launchpad: first every saved stock is asked of the chain again;
  then the launchpad's `StockAdmitted` logs are read from where the last run stopped
  (`Autolaunch.Stocks.AdmissionScan`, one row per launchpad), less 1,000 blocks, in ranges of
  2,000 blocks, at most 250 ranges and none once the run is three minutes old; each stock they
  name that is not saved yet is asked of the chain. The block after the last range read is then
  saved, and it never moves back.
- A stock that cannot be read or saved (a route with no `feed()`, a name over 120 characters, a
  ticker over 32) does not hold back the others or the place in the logs. Its address is kept on
  the launchpad's `stock_admission_scans` row (`unread`) and asked about again on every run. The
  run fails and is reported for as long as it stays unread.
- A run is bounded: eight seconds a chain call, a minute a stock, three minutes of log reading.
- Asking the chain means, at the latest block: the launchpad's `stockAdmission`, the route's
  `feed()`, the token's `name()` and `symbol()`. No fact comes from a log or an outside list.
- `Autolaunch.Stocks.Assets` answers pickers, search, launches and bids from the saved rows,
  kept for up to a minute on each server (Cachex). The server that ran the sync reads again at
  once; the others within the minute. `Autolaunch.Stocks.MarketData` prices each stock from the
  feed saved on its row, revoked stocks included.
- The launchpad's own `stockAdmission` is still read before every launch and bid.
- A run that read a launchpad's logs and left no stock unread sends the measurement the other
  chain readers send, `[:autolaunch, :indexer, :lag]` with `indexer: :stock_admissions`, the
  chain id, and `blocks`, how far the saved place is behind the chain's latest block. A failed
  log read, or one that left a stock unread, sends nothing, so "no measurement for 20 minutes"
  is the alarm for a list that has stopped being read (Sentinel's finding of 19:41Z). The
  measurement is about the log read only: a run whose re-asking of the saved stocks failed can
  still send it, and that run fails and is tried again like any other (the orchestrator's note
  of 20:33Z). The alarm itself is Sentinel's, outside this repository; its two reader rows must
  carry the `stock_admissions` label before the release.
- Gone: the `stocks` list in both deployment descriptions and their loaders, the built-in Base
  catalog and feed list, and the start-up step `Autolaunch.Stocks.SupportedStocks`. The lab and
  ceremony scripts no longer write the list.
- Practice routes (`FixtureStockRoute`, `FixtureUsdgStockRoute`) gained `feed()`, as production
  routes already have. No production contract's source, ABI or code changed; the frozen records
  of both v2 packages changed only for the practice contracts.

## Release items for Sean, named up front

1. One migration on the shared production database, Autolaunch's own tables only: four new
   columns on `stocks`, the new `stock_admission_scans` table, and saved stock addresses put in
   lowercase.
2. Roll forward only. The version before this one writes its own stock rows at start, in mixed
   case. If it runs after the migration (a rollback, or an old server restarting while both
   versions are up) it adds a second, mixed-case copy of every Base stock. Those copies are
   never shown, but once this version is back every run reports a failure (the other stocks are
   still written) until the copies are deleted, which is a production data change for Sean.
3. Before the release, the releaser confirms that production `stocks` already holds the admitted
   stocks (25 on chain 4663, at least 10 on chain 8453). Saved stocks are right within seconds;
   missing ones wait for the log read (see below).

4. `stock_admission_scans` goes on the protected-tables record at the release.
5. Owed before the release, and not run yet: `sh bin/gate.sh` whole, for
   `contracts/stocks-v2` and for `contracts/robinhood-v2`, inside the pristine release export
   the orchestrator cuts, with logs and exit codes to Sentinel. The gate needs a pristine
   checkout, and this lane has no worktree left to make one.
6. Tests changed, by file (none added, none asserts the old file shape):
   - `platform/test/autolaunch_web/live/stocks_create_live_test.exs`: its setup now saves two
     stocks, addresses in lowercase.
   - `platform/test/fixtures/base-stocks-deployment.json`: the `stocks` list removed.
   - `contracts/stocks-v2/test/StocksFixture.sol`, `StocksLaunchpadLaunch.t.sol`,
     `StocksLaunchpadMigrate.t.sol` and `test/fork/StocksForkLifecycle.t.sol`: the practice
     route's constructor takes a feed.

The production description files need no change: their `stocks` list is no longer read.

## What to expect at the release

- Each new server queues one run as it starts, because the five-minute schedule runs on one
  server only and during a release that can still be an old one. Saved stocks are right within
  seconds, normally before traffic moves to the new servers. If the chain cannot be read then,
  the pickers are empty and a stock's page says the stock is not listed until a run succeeds.
- Stocks not saved before are found by the log read: about 2 runs on Base, about 10 runs
  (some 50 minutes) on Robinhood, whose launchpad is some 5 million blocks old.
- The first run on each chain finds the launchpad's first block by asking for its code at old
  blocks, which needs a node that keeps old state. The auction activity reader already does the
  same on both chains in production.
- Every admitted route has to answer `feed()`. A stock whose route does not is left out and the
  run reports a failure, rather than saving a stock with no price.

## Known limits

- The sync asks the launchpads new launches go through. A stock only an earlier launchpad
  admitted has no saved facts. None on live on 13 October: the six live auctions are priced in
  SNDK and SPCX (Robinhood) and NVDAc, SPCXc, METAc and AAPLc (Base), all admitted on the
  current launchpads.
- A launch in a stock admitted minutes ago and not read yet fails the Robinhood auction and
  market reads for that auction until the next run (up to five minutes). Before this change the
  same gap lasted until a site release.
- Two stocks under one symbol on one chain are no longer refused by the site, and a price is
  kept by ticker, so two such stocks would share one price. Only the governance Safe admits a
  stock, so this is a rule for the signers' check, not something a stranger can cause.
- The kept list is cleared at once only on the server that ran the job. Any other server shows
  the old list for up to a minute more.
- The migration puts saved addresses in lowercase. If two saved rows differ only by letter
  case, that step fails, and so does the release. The row check before the release (item 3)
  is where this would be seen first.
- Older tooling left as it was: `ops/fork-preview` and the first-generation lab scripts in
  `contracts/stocks` and `contracts/robinhood` still build first-generation launchpads, which
  this site no longer reads stocks from. The practice labs to use are
  `contracts/stocks-v2/bin/local-stocks-lab.py` and
  `contracts/robinhood-v2/bin/local-robinhood-lab.py`.

## What was checked

- A rehearsal on a private copy of live Base, with the real launchpad and routes: fill-in of
  saved stocks, a revocation, a new admission, a run with nothing to do, a run with the chain
  not answering (failed, place kept; the same through the job's own action), a newly admitted
  stock whose route does not answer (run failed, place moved on, address kept as unread, other
  stocks untouched), and its recovery (stock saved, unread list emptied). Prices came back from
  the saved feeds, the revoked stock's included.
- `make check-platform`; both v2 packages' format, build, tests (114 and 165), frozen-surface
  check and the security record reconciled against a fresh Slither run. `bin/gate.sh` needs a
  pristine checkout and is Sentinel's to run.
- Two independent reviews, one of the contracts and scripts, one of the site code. Every finding
  is answered in this head: the unread list and the bounded, one-at-a-time run; revoked stocks
  keep prices; the kept list is Cachex, not a hand-built table; the Slither record matches the
  changed practice contracts. Two are answered by the release rules above (roll forward only;
  the row check before release).
- No test was added. Not covered by any test: that a practice route's `feed()` reaches the
  saved row. A new test needs Sean's agreement.
- Live answers on 13 October: Base admits ten stocks (no Circle, no Intel); Robinhood admits
  all 25 of its listed stocks, each with a feed.

## Local preview

`http://127.0.0.1:4070/create` (launch entry `autolaunch-home-1013-4070`). It is sample data
with no chain and runs no jobs, so its stock rows were written by hand from the live launchpads'
answers on 13 October.

## Next

Part B, the watcher, is built on the same branch: see "B. The watcher" in
`/Users/sean/Documents/regent/worktrees/autolaunch/stocks-cca/platform/docs/handoffs/2026-10-13-new-projects-plan.md`.
Part C, the Safe's prepared batch, stays design.
