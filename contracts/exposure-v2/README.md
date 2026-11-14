# Isolated Exposure to After-hours Stocks, version 2

Version 2 runs itself. Prices record themselves from Chainlink whenever anyone trades or redeems,
and each week's series opens on its first deposit. After the governance Safe sets the factory up
once, no wallet of ours has to sign anything to keep it going. Design, departures from version 1,
trust model, failure modes, gas and open questions:
[exposure-v2-design.md](../../platform/docs/exposure-v2-design.md).

Status: **candidate only**. Nothing deployed. Version 1 (`../exposure`) is unchanged.

## How it works

`ExposureFactoryV2` opens one `ExposureSeriesV2` per week, at a CREATE2 address that depends only on
the factory and the week. A series runs from the last close before its Monday (normally Friday
16:00 New York) through each trading day's 09:30 open and 16:00 close (13:00 on early closes), so
one week's last boundary is the next week's first. A series has no owner, admin, upgrade, pause or
fee.

| Call | Who | What it does |
| --- | --- | --- |
| `factory.deposit(week, assets)` | holder | Opens the week's series if nobody has, then deposits `assets` raw stock from the caller and mints the caller `assets` of each leg. `week` must be the current week. The caller approves the factory once. |
| `factory.open(week)` | anyone | Opens the current week's series. Whoever calls it, the series is the same. |
| `series.mint(assets, to)` | holder | The same deposit made on the series directly. |
| `series.redeem(overnight, session)` | holder | Burns the caller's legs and sends the caller the stock they are worth. Equal amounts are whole pairs (one raw unit each, any time, no price read). Unequal amounts first apply every due price and need the series to have ended. |
| `series.settle()` | anyone | Applies every boundary that is due. No input; the same result whenever and however often it is called. |
| `setTemplate`, `setDays`, `setPaused` | factory owner (the Safe) | Template (stock, feed and phase, cap, terms, ticker) for series not yet opened; closed days and early closes for weeks after the current one; pausing new openings. No power over an open series. |

- A boundary's price is the Chainlink round of the pinned phase in force at that moment: the last
  round updated at or before it. The series finds it with an on-chain search starting from the
  previous boundary's round. Nobody records it and nobody supplies a hint. It applies an hour later
  and is the same at any later time.
- `mint` and any single-leg `redeem` apply the due boundaries first. Pair redemptions and leg
  transfers never read the feed.
- The ledgers always sum to the last price, so a pair is always worth exactly its stock. A price
  that takes either ledger to zero ends the series, and the other leg owns all the stock.
- The series ends at the ledgers it had in these cases:
  - no round is in force at a boundary;
  - the round in force is more than 84 hours old;
  - the answer is zero or negative;
  - the feed's reads were seen failing twice, a week apart, with no good read in between.
- The other version 1 properties hold:
  - collateral is raw B20 units;
  - stock goes only to the account redeeming;
  - an issuer seizure cuts every later redemption by the same fraction and stops minting;
  - the cap is per series.

## Checks

```sh
bin/gate.sh
```

The offline gate runs `forge fmt --check`, `forge build` (with forge lint), and the unit, fuzz,
invariant and round-search suites. It builds against `../stocks-v2/lib` (forge-std and solady),
which `stocks-v2/bootstrap-deps.py` fills.

The Base fork suite (`test/fork/`) builds the factory exactly as the deploy script does, on the real
AMZNc token and the real Coinbase AMZN Chainlink feed. It replays the weeks of 26 October, 2 November
(the clocks went back) and 9 November 2026 from the feed's history, and checks every price against
an independent computation. It also covers a month with no settle, settle timing, the issuer's
blocklist, transfer pause and split, and gas. Base stock tokens are B20 precompiles, so it needs
Foundry 1.8.6:

```sh
FOUNDRY_PROFILE=fork forge test --network base --fork-url <Base RPC> \
  --fork-block-number 57228000 --isolate -vv
```

`script/DeployExposureV2.s.sol` builds the factory in a local simulation and prints its settings,
the current week and that week's series address. It contains no broadcast call:

```sh
forge script script/DeployExposureV2.s.sol --sig "run(bytes32)" <terms hash> \
  --network base --fork-url <Base RPC>
```

Deploying is a protected action and needs Sean's go. Before deploying, check the holiday list in
the script against NYSE's published calendar. The script does not list 2 July 2027 or 23 December
2027 as early closes; confirm that is right.
