# Autolaunch Stocks contracts

Autolaunch Stocks creates a new token, **NEW**, sells 80% of its initial supply through the
pinned Uniswap Continuous Clearing Auction denominated in one admitted Base stock token,
**STOCK**, and after a successful auction opens the official **NEW/STOCK** Uniswap v4 pool with
all net STOCK raised plus the 20% migration reserve, locked forever in two positions. Official-pool trading pays
STOCK-side hook fees: a mandatory 100 bps REGENT lane and an optional 100 bps subject lane.
Both are converted to USDC and deposited outside ordinary swaps.

This is a separate Foundry component. It reuses the frozen `contracts/v1` dependencies at their
pinned revisions and never modifies them. Nothing here changes the Agent factory, strategy,
hook, escrow, splitter or receiver.

## Status

`implemented-unverified` at best until the evidence index in `platform/docs/stocks.md` says
otherwise. No deployment, funding or public-chain transaction is part of this component.

## Layout

| Path | Owns |
| --- | --- |
| `src/interfaces/` | The cross-component ABI. Website, indexer and CLI consume these shapes. |
| `src/StocksPreset.sol` | Every fixed launch term, in one place, with its provenance label. |
| `src/StocksLaunchpadV1.sol` | Admission, creation, custody, migration, subject administration. |
| `src/StocksFeeHookV1.sol` | The official-pool hook: accrual-only fee lanes and out-of-swap settlement. |
| `src/StockBidAdapterV1.sol` | Atomic USDC → STOCK → CCA bid owned by the caller. |
| `src/StocksBindings.sol` | The frozen Base bindings this component compiles against, copied from `contracts/v1`, plus canonical Permit2. |
| `src/routes/` | `IStockRoute` implementations. `FixtureStockRoute` is lab-only. |
| `src/fixtures/` | `FixtureStockToken` and `FixtureStockCatalog`: the ERC-20 the local fork installs at the catalog addresses, and the catalog itself. Lab-only. |
| `test/` | Hermetic suite: real PoolManager, PositionManager, CCA factory, UERC20 factory and Permit2 bytecode at their frozen addresses; USDC, REGENT, live staking, the Agent strategy and the splitter are named doubles. |
| `test/fork/` | The local Base-fork suite (`FOUNDRY_PROFILE=fork`), against chain truth and the Agent graph the lab deployed. |
| `SECURITY.md` | The invariant list and the test that proves each one. |
| `script/DeployStocksLab.s.sol` | Deploys the graph onto the local Base fork and logs `REGENT_STOCKS_LAB_<NAME>: 0x…` lines. |
| `bin/local-stocks-lab.py` | Extends a running `contracts/v1/bin/local-base-lab.py` fork with the Stocks graph, fixtures, funding and `stocks-site-config.json`. |
| `dependencies.json`, `bootstrap-deps.py` | Export the pinned dependencies from a hydrated Autolaunch checkout into `lib/` (ignored). |

## Preset: fixed terms and their provenance

The Stocks decision record the September 8 brief refers to was not found in this repository or
the workspace. Every value marked **PROVISIONAL** below is a single bounded proposal, lives only
in `StocksPreset.sol`, and blocks release admission until the founder confirms or replaces it.
No value was copied from Agent merely because it was nearby; where a value is shared it is
because the same pinned dependency imposes it.

| Term | Value | Provenance |
| --- | --- | --- |
| NEW decimals | 18 | PROVISIONAL |
| NEW initial supply `S0` | 1,000,000,000 × 10^18 | PROVISIONAL; divisible by five; below the CCA `MAX_TOTAL_SUPPLY` |
| Auction inventory | `4 * (S0 / 5)` = 800,000,000 × 10^18 | Brief P04, exact |
| Migration reserve | `S0 / 5` = 200,000,000 × 10^18 | Brief P04, exact |
| Auction duration | 43,200 blocks (~24 h at Base's 2 s blocks) | Brief P03 "approximately 24 hours"; block count PROVISIONAL |
| Step schedule | 13 packed steps summing to 43,200 blocks and exactly `MPS = 1e7` | Derived; shape mirrors Agent's pinned schedule, proven by test |
| Start lead | `MIN_START_LEAD_BLOCKS` 300 (~10 min), `MAX_START_LEAD_BLOCKS` 1,296,000 (~30 days) | PROVISIONAL |
| Claim delay | 64 blocks after end | Same pinned CCA convention as Agent |
| Migration delay | 128 blocks after end | Same pinned CCA convention as Agent |
| Bid tick spacing | `floorPriceQ96 / 100`, requiring `floorPriceQ96 % 100 == 0` and the result ≥ CCA `MIN_TICK_SPACING` | Derived; floor ≥ CCA `MIN_FLOOR_PRICE` |
| Official pool LP fee | 3000 (0.30%) | PROVISIONAL |
| Official pool tick spacing | 60 | PROVISIONAL |
| REGENT hook lane | 100 bps of realized STOCK-side amount, floored | Brief P08 |
| Subject hook lane | 0 or 100 bps, off by default | Brief P09/P10 |
| Launch fee | 100,000 REGENT (`LAUNCH_FEE_REGENT`), pulled from the launcher at `launch` and funded into the live REGENT staking contract as staker rewards (`fundRegentRewards`); never refunded; governance may change it with `setLaunchFee` (zero valid) | Founder decision |
| Creator allocation, vesting, treasury | none | Brief P05 |
| Unsold NEW after graduation | transferred to `0x…dEaD` ("retired"; supply is not reduced because UERC20 has no burn) | Brief P13; mechanism labelled |
| Reserve and inventory after failed minimum | transferred to `0x…dEaD` in `migrate`; refunds remain independent | Brief §1.2 recommendation; PROVISIONAL |
| Locked liquidity | Two positions, both NFTs to `0x…dEaD`: (1) full range, funded by the whole reserve and the STOCK it pairs at the clearing price; (2) one-sided STOCK, holding every remaining unit of net STOCK | Brief P13 "all-net-STOCK liquidity", exact; see the design note below |
| One-sided STOCK position geometry | From the tick-spacing boundary adjacent to the initial price out to the last usable tick on the STOCK side of the book (below the price when STOCK is currency1, above it when STOCK is currency0) | PROVISIONAL (the width; the side follows from the price) |
| LP rounding remainder (STOCK below one unit of liquidity after both positions) | accrued to the REGENT bucket of the pool's hook; proven `< sqrt(clearingPrice)` base units, zero at every fixture price | PROVISIONAL (the destination) |
| LP custody | both position NFTs minted to `0x…dEaD`; no principal path exists | Brief P13 |

### Design note on the two positions

One full-range position at the clearing price pairs STOCK and NEW in equal value, so it can place at
most `reserve × clearingPrice` of STOCK. The auction raises `tokensSold × clearingPrice`, so whenever
more than a quarter of the inventory sells (`tokensSold > reserve`) the full range leaves
`(tokensSold − reserve) × clearingPrice` of STOCK unpaired — 75% of the raise on a sell-out. Agent sends
that excess to the launch treasury; Stocks has none and brief P13 says every unit of net STOCK becomes
locked liquidity. Graduation therefore plans a second position with the pinned `PositionPlanner`: one
`PositionDefinition` covering the STOCK side of the book from the initial tick (rounded to the pool's
spacing) to the min or max usable tick, weighted 100% of the remaining STOCK and zero NEW. That range
contains only STOCK at the initial price, so the planner's liquidity math places the whole remainder
except the floor-then-round-up residue of one position, which is strictly below `sqrt(clearingPrice)`
STOCK base units per NEW base unit — below one unit for every price the CCA's floor and the pool's
decimals make plausible (`testFuzz_graduation_locks_all_net_stock_at_any_clearing_price` proves the
bound at every bid-grid price up to 656× the fixture floor; the observed remainder is zero). Both
positions are minted in one PositionManager call with exact settlement amounts. When less than a
quarter sells the full range is STOCK-bound, takes the whole raise itself, and the reserve it cannot
pair is retired with the unsold NEW (`test_graduation_with_less_than_a_quarter_sold_both_orderings`).
The second position is the first liquidity a NEW seller meets and moves the price down through a
STOCK-only book; that geometry (and the accrual of the residue to the REGENT bucket) is the
PROVISIONAL part awaiting the founder's decision record.

## Hook mechanics

Uniswap v4 lets an after-swap return delta charge only the swap's *unspecified* currency, so an
afterSwap-only hook cannot charge STOCK when STOCK is the specified amount (exact-input STOCK→NEW,
exact-output NEW→STOCK). To charge STOCK on every swap form the hook declares `beforeInitialize`,
`beforeSwap`, `afterSwap`, `beforeSwapReturnDelta` and `afterSwapReturnDelta`; STOCK-specified swaps
pre-commit their exact fee in `beforeSwap` as a specified-currency delta and revert
(`PartialFillNotSupported`) if the trader's own price limit cuts the fill short, since the pre-committed
fee would otherwise be inexact. STOCK-unspecified swaps are charged in `afterSwap` and fill partially
as usual. The fee base is the gross STOCK amount: the trader's whole debit for STOCK-input swaps, the
pool's whole output for STOCK-output swaps; each lane is one percent of it, floored.

## Identity and admission

- STOCK identity is `(chainId 8453, exact address)`. The launchpad keeps a governance-set admission
  map: `admitStock(stock, route)` records decimals read from the token and the one admitted
  `IStockRoute`; `revokeStock` stops new launches only and never changes an existing launch.
- Base's native stock assets (`0xb2…`) carry a one-byte `0xef` code that Anvil cannot execute.
  The fork lab therefore installs `FixtureStockToken` (8 decimals, matching symbol) at those exact
  addresses with `anvil_setCode`. **This is a fixture. Nothing tested against it is B20-verified.**
  Issuer transfer policy, Permit2 compatibility and the real acquisition route remain open
  admission blockers (acceptance tests AT04, AT48).
- The Governance and REGENT Safe (`0x9fa1…9a3e`) is the only governance. The fee administrator of
  a launch can only configure that launch's subject lane and transfer its own role.

## Money and custody rules the implementation must prove

1. Exactly `S0` is minted, to the launchpad, once. `auctionInventory + migrationReserve == S0`.
   The launchpad holds nothing of NEW after `launch` except the reserve.
2. CCA `currency == stock`, `tokensRecipient == launchpad`, `fundsRecipient == launchpad`,
   `protocolFeeController == 0`.
3. `migrate` classifies with the final checkpoint. Graduated: sweep STOCK, sweep unsold NEW, register
   the pool with the hook, initialize, mint two positions to the dead address in one call — the full
   range from the whole reserve and the STOCK it pairs, then a one-sided STOCK position from every
   remaining unit of net STOCK — so `lpStockUsed + lpStockOnlyUsed + dust == netStock` with `dust`
   the bounded rounding residue; retire unsold NEW and any reserve the full range could not pair;
   route the residue as the preset says. Failed: retire reserve and swept inventory; never touch
   bidder STOCK.
4. Bidder refunds and claims go through the CCA and depend on nothing in this component.
5. The hook only accrues. `settle` is the only path out, executor-only, per bucket, via the admitted
   route, with `minUsdcOut`; a failing settle reverts only itself.
6. Each accrual belongs to `(poolId, destination)` at the time of the swap. Disabling the subject
   lane charges nothing afterwards and never re-attributes old buckets.
7. The adapter uses invocation balance deltas only, restores every allowance to zero, and bids as
   `owner = msg.sender`.
8. The launch fee is collected exactly and funded exactly, and never comes back. `launch` refuses a
   `expectedLaunchFee` that is not the current `launchFee()` and a REGENT allowance that is not exactly
   the fee (a zero fee moves nothing and still requires a zero allowance); it pulls the fee into the
   launchpad, proves the delta, funds it into `LIVE_STAKING.fundRegentRewards` in the same
   transaction, proves `received == fee`, proves its own REGENT delta is zero afterwards and both
   allowances are back at zero, all before NEW or the auction exist. Nothing in `migrate` or anywhere
   else can return it.

## Verification

```sh
cd contracts/stocks
python3 bootstrap-deps.py /path/to/hydrated/autolaunch/checkout   # once; fills lib/
forge build
forge test --fuzz-runs 64
FOUNDRY_PROFILE=fork forge test --fork-url http://127.0.0.1:PORT --fuzz-runs 64   # against the lab
slither . --config-file slither.config.json --filter-paths "lib/|test/|script/"   # if installed
```

`test/fork/ForkAddresses.sol` pins the Agent graph of the lab run it was written against; a restarted
Agent lab needs those four addresses updated.

The fork lab (`bin/local-stocks-lab.py`) requires an active `contracts/v1/bin/local-base-lab.py`
run and writes `stocks-site-config.json` (and its own `stocks-state.json`) next to that run's
`site-config.json`; the website reads the config through `AUTOLAUNCH_STOCKS_LAB_CONFIG`. It never
writes the Agent run record. `--agent-lab-dir` points it at a run in another checkout.

`deploy` also sets the frozen Agent factory's launch fee to the lab's 500,000 REGENT from the
impersonated Governance Safe (one governance call on the fork; the Agent sources and run record are
untouched) and records both fees in the config: `stocks_launch_fee_regent` (read from the launchpad,
100,000 REGENT) and `agent_launch_fee_regent`, in base units. `faucet.regent_launch_fee_amount`
(500,000 REGENT) is one grant that covers either fee. `fund --regent 600000` covers one Agent and one
Stocks launch fee plus bids; the controller checks the Safe's balance first.

```sh
python3 bin/local-stocks-lab.py [--agent-lab-dir DIR] deploy            # fixtures, graph, admission, funding, Agent fee, config
python3 bin/local-stocks-lab.py set-agent-fee [--amount 500000]         # Agent factory launchFee, from the impersonated Safe
python3 bin/local-stocks-lab.py fund WALLET --regent 600000 --stock AAPLc --amount 100 --usdc 1000
python3 bin/local-stocks-lab.py status [--launch ID] [--auction ADDR]
python3 bin/local-stocks-lab.py advance --auction ADDR --to start|end|claim|migration
python3 bin/local-stocks-lab.py migrate --launch ID
python3 bin/local-stocks-lab.py settle --pool-id 0x… --destination ADDR --amount UNITS --min-usdc UNITS
```

The lab deployer (`0x5700…0001`) and the hook executor are the same impersonated address; the
Governance Safe is impersonated for admission, unpausing, the Agent fee and REGENT funding; USDC comes from a forked holder
(Morpho Blue by default, `--usdc-holder` to change). Nothing in the lab is B20-verified.
