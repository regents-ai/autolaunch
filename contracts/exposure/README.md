# Isolated Exposure to After-hours Stocks

One Base stock token split, for a fixed term, into an **OVERNIGHT** token (shown to customers as
After-hours) that carries the stock's close-to-open moves and a **SESSION** token (Market-hours) that
carries its open-to-close moves. Design and site plan: [exposure-design.md](../../platform/docs/exposure-design.md).

Status: **deployed on Base** (oracle and factory, 28 Oct 2026); see [deployments/base-mainnet](deployments/base-mainnet/README.md). Full specification: [after-hours-exposure-spec.md](../../platform/docs/after-hours-exposure-spec.md).

## How it works

One `ExposureSeriesV1` per stock and term, listed by `ExposureFactoryV1`. A series has no owner,
admin, upgrade, pause or fee.

| Call | Who | What it does |
| --- | --- | --- |
| `settle()` | anyone | Applies the next scheduled print. The first close sets both ledgers to half its price and opens minting; an open moves OVERNIGHT by the change since the close; a close moves SESSION by the change since the open. |
| `mint(assets)` | holder | Deposits `assets` raw stock from the caller and mints the caller `assets` of each leg. Open while the series is live and under its deposit cap. |
| `redeem(overnight, session)` | holder | Burns the caller's legs and sends the caller the stock they are worth. Before the end, equal amounts only (one raw unit per pair); after the end, any mix at the frozen ledgers. |
| `endOnMissingPrint()` | anyone | After the next print's deadline passes with no print made final in time, ends the series at the last ledgers. |
| `createSeries(terms)` | factory owner (the governance Safe) | Creates and lists a series. The owner has no power over it afterwards. |
| `record(at, isOpen, roundId)` | anyone, an hour after `at` | `ChainlinkPrintOracleV1`: records the stock's Chainlink value in force at `at` (the named round, checked to be the last one updated at or before it). Recorded once, never changed. |

- The two ledgers always sum to the last print, so a pair is always worth exactly its stock.
- A print that takes either ledger to zero or below ends the series, and the other leg owns all the
  stock. No leg can ever claim more than the stock behind the pairs.
- Collateral is raw B20 units, so a split or dividend changes only the oracle's price per raw
  token, never what the series holds or owes.
- Stock only ever goes to the account redeeming, so the issuer's blocklist and pauses apply to it.
- If the issuer takes stock from the series, every later redemption is cut by the same fraction and
  minting stops until the stock is back. Nobody can race the others out, and legs worth something
  are never burned for nothing.
- Each call does constant work: no loop over holders or prints, no trade inside the vault.

## Checks

```sh
bin/gate.sh
```

The offline gate: `forge fmt --check`, `forge build`, and the unit, fuzz, invariant, oracle and
factory suites. It builds against `../stocks-v2/lib` (forge-std and solady), filled by
`stocks-v2/bootstrap-deps.py`.

The Base fork suite (`test/fork/`) creates a series through the factory on the real AMZNc token and
settles it from the real Coinbase AMZN Chainlink feed over the week of 23 to 28 October 2026. Base
stock tokens are B20 precompiles, so it needs Foundry 1.8.4 or later: start
`anvil --network base --fork-url <Base RPC> --fork-block-number 53209576`, then
`FOUNDRY_PROFILE=fork forge test --network base --fork-url http://127.0.0.1:<port>`.

`script/DeployAfterHours.s.sol` deploys the AMZN oracle and the factory (owned by the Governance and
Regent Safe) and prints the Safe's `createSeries` call for the first AMZNc series; the fork suite's
`DeployAfterHours.fork.t.sol` rehearses both and runs that series' whole week. Broadcasting is a
protected action and needs Sean's go.
