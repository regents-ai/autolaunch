# Autolaunch Stocks contracts

Autolaunch Stocks creates a new token, **NEW**, sells 80% of its initial supply through the
pinned Uniswap Continuous Clearing Auction denominated in one admitted Base stock token,
**STOCK**, and after a successful auction opens the official **NEW/STOCK** Uniswap v4 pool with
all net STOCK raised plus the 20% migration reserve, locked forever in two positions. Official-pool trading pays
two STOCK-side hook fees on top of the 0.30% LP fee, both always on: a 100 bps REGENT lane, converted
to USDC and deposited into REGENT staking, and a 100 bps staker lane, deposited as STOCK into the
launch's own **memestock splitter**. Holders stake NEW (the MEMESTOCK) in that splitter and divide,
pro rata, everything it recognizes in USDC, MEMESTOCK and STOCK after a 2% protocol share. The two
locked positions sit in a fee-only locker whose LP fees also flow into the splitter. No launch has a
creator, an administrator or a treasury.

This is a separate Foundry component. It reuses the frozen `contracts/v1` dependencies at their
pinned revisions and never modifies them. Nothing here changes the Agent factory, strategy,
hook, escrow, splitter or receiver. The memestock splitter is a separate contract modelled on the
Agent subject splitter, not a change to it.

## Status

`implemented-unverified` at best until the evidence index in `platform/docs/stocks.md` says
otherwise. No deployment, funding or public-chain transaction is part of this component.

## Layout

| Path | Owns |
| --- | --- |
| `src/interfaces/` | The cross-component ABI. Website, indexer and CLI consume these shapes. |
| `src/StocksPreset.sol` | Every fixed launch term, in one place, with its provenance label. |
| `src/StocksLaunchpadV1.sol` | Admission, creation, custody, migration; deploys the locker and the splitter implementation, clones one splitter per graduation. |
| `src/StocksFeeHookV1.sol` | The official-pool hook: two accrual-only fee lanes and out-of-swap settlement. |
| `src/MemestockSplitterCore.sol` | The shared staking and revenue accounting: three recognized assets, 2% protocol share, pro rata accrual, one-block exit rule, recovery of unsupported tokens. Chain-neutral; the Robinhood splitter inherits it too. |
| `src/MemestockSplitterV1.sol` | The Base clone target: USDC protocol share into live REGENT staking, MEMESTOCK and STOCK protocol shares to the Governance and REGENT Safe. |
| `src/MemestockLPLocker.sol` | Permanent fee-only owner of every launch position; anyone may `collect`, the fees always land in the launch's splitter. Shared with the Robinhood launchpad. |
| `src/StockBidAdapterV1.sol` | Atomic USDC → STOCK → CCA bid owned by the caller. |
| `src/StocksBindings.sol` | The frozen Base bindings this component compiles against, copied from `contracts/v1`, plus canonical Permit2. |
| `src/routes/` | `IStockRoute` implementations: `AerodromeStockRouteV1`, the production route (one per admitted STOCK, over its Aerodrome Slipstream USDC pool and Chainlink feed), and the lab-only `FixtureStockRoute`. |
| `src/fixtures/` | `FixtureStockToken` and `FixtureStockCatalog`: the ERC-20 the local fork installs at the catalog addresses, and the catalog itself. Lab-only. |
| `test/` | Hermetic suite: real PoolManager, PositionManager, CCA factory, UERC20 factory and Permit2 bytecode at their frozen addresses; USDC, REGENT and live staking are named doubles; the splitter and the locker are the real contracts. |
| `test/fork/` | The local Base-fork suite (`FOUNDRY_PROFILE=fork`), against chain truth on the lab fork. |
| `SECURITY.md` | The invariant list and the test that proves each one. |
| `script/DeployStocksLab.s.sol` | Deploys the graph onto the local Base fork and logs `REGENT_STOCKS_LAB_<NAME>: 0x…` lines. |
| `bin/local-stocks-lab.py` | Extends a running `contracts/v1/bin/local-base-lab.py` fork with the Stocks graph, fixtures, funding and `stocks-site-config.json`. |
| `dependencies.json`, `bootstrap-deps.py` | Export the pinned dependencies from a hydrated Autolaunch checkout into `lib/` (ignored). |

## Preset: fixed terms and their provenance

Every term lives only in `StocksPreset.sol`. The values marked **founder decision 2026-09-09**
began as single bounded proposals, because the Stocks decision record the September 8 brief refers
to was never found; the founder accepted all of them on 9 September 2026, on the basis that the step
schedule keeps about 30% of the auction supply in the final block as Agent's does (29.88%, proven in
`StocksPreset.t.sol`). No value was copied from Agent merely because it was nearby; where a value is
shared it is because the same pinned dependency imposes it.

| Term | Value | Provenance |
| --- | --- | --- |
| NEW decimals | 18 | Founder decision 2026-09-09 |
| NEW initial supply `S0` | 1,000,000,000 × 10^18 | Founder decision 2026-09-09; divisible by five; below the CCA `MAX_TOTAL_SUPPLY` |
| Auction inventory | `4 * (S0 / 5)` = 800,000,000 × 10^18 | Brief P04, exact |
| Migration reserve | `S0 / 5` = 200,000,000 × 10^18 | Brief P04, exact |
| Auction duration | 43,200 blocks (~24 h at Base's 2 s blocks) | Brief P03 "approximately 24 hours"; block count founder decision 2026-09-09 |
| Step schedule | 13 packed steps summing to 43,200 blocks and exactly `MPS = 1e7` | Derived; shape mirrors Agent's pinned schedule, proven by test |
| Start lead | `START_LEAD_BLOCKS` 300 (ten minutes at 2 s blocks): every auction opens exactly 300 blocks after its creation block; the launcher does not choose it; the opening block is in the launch record and the `StockLaunchCreated` event | Founder decision 2026-09-21 |
| Claim delay | 64 blocks after end | Same pinned CCA convention as Agent |
| Migration delay | 128 blocks after end | Same pinned CCA convention as Agent |
| Bid tick spacing | `floorPriceQ96 / 100`, requiring `floorPriceQ96 % 100 == 0` and the result ≥ CCA `MIN_TICK_SPACING` | Derived; floor ≥ CCA `MIN_FLOOR_PRICE` |
| Official pool LP fee | 3000 (0.30%) | Founder decision 2026-09-09 |
| Official pool tick spacing | 60 | Founder decision 2026-09-09 |
| REGENT hook lane | 100 bps of realized STOCK-side amount, floored | Brief P08 |
| Staker hook lane | 100 bps of realized STOCK-side amount, floored, always on; deposited as STOCK into the launch's splitter by anyone (`settleStakerLane`) | Founder decision 2026-09-18 |
| Splitter protocol share | 2% (`SKIM_BPS` 200) of every recognized amount in USDC, MEMESTOCK and STOCK; USDC straight into live REGENT staking, MEMESTOCK and STOCK to the Governance and REGENT Safe; the other 98% belongs wholly to stakers | Founder decision 2026-09-18 |
| Revenue with nothing staked | the whole amount follows the protocol route (USDC into REGENT staking, other assets to the Safe); the rule holds only while `totalStaked == 0`, so any stake placed before a settlement takes the 98% share of that settlement | Founder decision 2026-09-18 |
| Launch fee | none: a launch costs nothing beyond gas; no REGENT is pulled and the launchpad never holds REGENT | Founder decision 2026-09-21 |
| Required raise | chosen by the launcher in STOCK base units (`requiredStockRaised`), above zero and at most what the fixed inventory can settle on at the highest on-grid bid price (`UnreachableRequiredRaise` otherwise); no governance minimum; a recorded auction keeps its raise | Founder decision 2026-09-21 |
| Creator allocation, vesting, treasury | none | Brief P05 |
| Unsold NEW after graduation | transferred to `0x…dEaD` ("retired"; supply is not reduced because UERC20 has no burn) | Brief P13; mechanism labelled |
| Reserve and inventory after failed minimum | transferred to `0x…dEaD` in `migrate`; refunds remain independent | Brief §1.2 recommendation; founder decision 2026-09-09 |
| Locked liquidity | Two positions, both NFTs to the `MemestockLPLocker`: (1) full range, funded by the whole reserve and the STOCK it pairs at the clearing price; (2) one-sided STOCK, holding every remaining unit of net STOCK | Brief P13 "all-net-STOCK liquidity", exact; see the design note below |
| One-sided STOCK position geometry | From the tick-spacing boundary adjacent to the initial price out to the last usable tick on the STOCK side of the book (below the price when STOCK is currency1, above it when STOCK is currency0) | Founder decision 2026-09-09 (the width; the side follows from the price) |
| LP rounding remainder (STOCK below one unit of liquidity after both positions) | accrued to the REGENT lane of the pool's hook; proven `< sqrt(clearingPrice)` base units, zero at every fixture price | Founder decision 2026-09-09 (the destination) |
| LP custody | both position NFTs minted to the launchpad's `MemestockLPLocker` and registered to the launch's splitter, once and forever; the locker can only collect fees (a decrease of exactly zero) and deposit them into that splitter; no principal path exists | Brief P13; founder decision 2026-09-18 (fees to stakers) |

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
STOCK-only book; that geometry (and the accrual of the residue to the REGENT lane) was the founder's
decision of 9 September 2026.

## Hook mechanics

Uniswap v4 lets an after-swap return delta charge only the swap's *unspecified* currency, so an
afterSwap-only hook cannot charge STOCK when STOCK is the specified amount (exact-input STOCK→NEW,
exact-output NEW→STOCK). To charge STOCK on every swap form the hook declares `beforeInitialize`,
`beforeSwap`, `afterSwap`, `beforeSwapReturnDelta` and `afterSwapReturnDelta`; STOCK-specified swaps
pre-commit their exact fee in `beforeSwap` as a specified-currency delta and revert
(`PartialFillNotSupported`) if the trader's own price limit cuts the fill short, since the pre-committed
fee would otherwise be inexact. STOCK-unspecified swaps are charged in `afterSwap` and fill partially
as usual. The fee base is the gross STOCK amount: the trader's whole debit for STOCK-input swaps, the
pool's whole output for STOCK-output swaps; each lane is one percent of it, floored. Both lanes are
always charged. `settleRegentLane` (executor only, with `minUsdcOut`) converts REGENT-lane STOCK
through the admitted route and deposits the USDC into live REGENT staking. `settleStakerLane`
(anyone) deposits the whole staker lane, as STOCK, into the pool's splitter; it decides nothing, so it
needs no authority.

## Staking

Each graduation clones one `MemestockSplitterV1` bound to that launch's MEMESTOCK and STOCK. Holders
`stake` MEMESTOCK, `claim`/`claimAll` what they have earned and `unstake` from the next block on.
Revenue arrives by `depositRecognizedRevenue` (the hook's staker lane, the locker's LP fees, anyone)
or is picked up from a plain transfer by `recognizeSurplusRevenue`; staked principal is never counted
as revenue. Revenue is shared among whoever is staked at the moment it is recognized, and both the
staker lane and LP fees arrive in lumps when someone settles or collects, so the site should settle
and collect often. Tokens other than the three recognized assets can be swept to the Safe by anyone.

## Identity and admission

- STOCK identity is `(chainId 8453, exact address)`. The launchpad keeps a governance-set admission
  map: `admitStock(stock, route)` records decimals read from the token and the one admitted
  `IStockRoute`; `revokeStock` stops new launches only and never changes an existing launch.
- Base's native stock assets (`0xb2…`) carry a one-byte `0xef` code that Anvil cannot execute.
  The fork lab therefore installs `FixtureStockToken` (8 decimals, matching symbol) at those exact
  addresses with `anvil_setCode`. **This is a fixture. Nothing tested against it is B20-verified.**
  The live tokens were exercised on a Base node instead (23 September 2026, all ten admitted
  stocks): transfers between contracts, the bid adapter's Permit2 path, and a buy and a sale through
  each deployed route; delivery to the Safe was shown on 19 September. The issuer changing its
  transfer policy later remains an accepted limit (see SECURITY.md, AT04, AT48).
- The Governance and REGENT Safe (`0x9fa1…9a3e`) is the only governance. No launch has an
  administrator: both lanes and the splitter are fixed by the contracts.

### Stock routes

`AerodromeStockRouteV1` is the production `IStockRoute`: one contract per STOCK, pinned at
construction to that stock's Aerodrome Slipstream USDC/STOCK pool (factory
`0xf8f2eb4940cfe7d13603dddd87f123820fc061ef`, tick spacing 10, 0.05% fee; USDC is always
`token0`) and to its Chainlink total-return feed (8 decimals, USD per share, held at the last
close outside market hours). The route calls the pool directly with no router and no
caller-supplied calldata, and:

- quotes from the feed, not the pool; `launch` does not quote at all, the required raise is the
  launcher's STOCK amount and the CCA's raise test is in STOCK;
- executes on the pool with the widest price limit and refuses any execution that delivers more than
  5% (`MAX_DEVIATION_BPS`) under the feed quote, on top of the caller's own `minAmountOut`;
- refuses a feed answer that is not positive or is older than 7 days (`MAX_FEED_AGE`);
- returns whatever input the pool did not consume to the recipient in the same call and holds
  nothing between calls; the pool's pull callback accepts the pinned pool only.

Admittable today (a Chainlink feed and a Slipstream USDC pool both exist; COINc, CRCLc and INTCc
have neither):

| Stock | Token | Slipstream pool | Chainlink feed |
| --- | --- | --- | --- |
| AAPLc | `0xb200000000000000000000C2e324d24d7eEcd1fb` | `0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0` | `0x787f13dEa48Db0897CbCDD985de77809D837F988` |
| AMZNc | `0xb200000000000000000000d9192b6B456483C2E8` | `0xd03Bc8C7F2FAedCe2aac81bF0444AEA08Ea06E9b` | `0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295` |
| GOOGLc | `0xb2000000000000000000002D0BA3164cc74f58B7` | `0xB1987CAD1682841b4b641d50E520777eC5Ab5542` | `0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2` |
| METAc | `0xb2000000000000000000008bC8786B856E61707C` | `0xEAF57753BC382E0324a1D43F72E7027705a2273E` | `0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D` |
| MSFTc | `0xB200000000000000000000Ab99cFa739E253872B` | `0x7103eB3c9590d1281f7dc03b2A9EE27C39dF5D54` | `0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c` |
| MSTRc | `0xb2000000000000000000004884b426556b92883d` | `0x8b27f626ab668197000BC722A1012022CAeD10E2` | `0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a` |
| NVDAc | `0xb20000000000000000000078ee7ce2fE4908108C` | `0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9` | `0x04689a41629776563E6822F76f2e57D148d28513` |
| SNDKc | `0xb200000000000000000000397293Cb8cda9a10c5` | `0x5A8236f575471e7BfCA2C8462a200c28f737246E` | `0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA` |
| SPCXc | `0xb2000000000000000000007b9fcbd005511aCBd5` | `0x0bf58fe0FAc935Ac69595c19B12Ba0d75E3F8c0E` | `0x6A634B235903C4ad6376892180d6fF8612e3Fa68` |
| TSLAc | `0xb2000000000000000000001e800a7f5189430cD0` | `0x469337fDcc5E8f38e2E4B670B04F57865D13a7BB` | `0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4` |

Verified on Base on 2026-09-19: every pool is a clone of one Slipstream implementation with
`token0 == USDC`, every feed reports 8 decimals, and the pool prices sat within 0.2% of the feeds.
`test/fork/AerodromeStockRouteFork.t.sol` re-checks all ten bindings and swaps through the live
AAPLc pool whenever it is run against Base itself.

## Money and custody rules the implementation must prove

1. Exactly `S0` is minted, to the launchpad, once. `auctionInventory + migrationReserve == S0`.
   The launchpad holds nothing of NEW after `launch` except the reserve.
2. CCA `currency == stock`, `tokensRecipient == launchpad`, `fundsRecipient == launchpad`,
   `protocolFeeController == 0`.
3. `migrate` classifies with the final checkpoint. Graduated: sweep STOCK, sweep unsold NEW, register
   the launch's splitter, register the pool and that splitter with the hook, initialize, mint two
   positions to the locker in one call and register both to the splitter — the full
   range from the whole reserve and the STOCK it pairs, then a one-sided STOCK position from every
   remaining unit of net STOCK — so `lpStockUsed + lpStockOnlyUsed + dust == netStock` with `dust`
   the bounded rounding residue; retire unsold NEW and any reserve the full range could not pair;
   route the residue as the preset says. Failed: retire reserve and swept inventory; never touch
   bidder STOCK.
4. Bidder refunds and claims go through the CCA and depend on nothing in this component.
5. The hook only accrues. The REGENT lane leaves only through `settleRegentLane` (executor-only, via
   the admitted route, with `minUsdcOut`) and the staker lane only through `settleStakerLane` (anyone,
   whole lane, as STOCK, into the pool's fixed splitter); a failing settlement reverts only itself.
6. A pool's splitter is fixed when the pool is registered; nothing redirects either lane afterwards.
   The splitter pays out exactly what it recognized: `gross == protocolShare + stakerShare`, staked
   principal is never revenue, and the locker can never move liquidity.
7. The adapter uses invocation balance deltas only, restores every allowance to zero, and bids as
   `owner = msg.sender`.
8. A launch costs nothing beyond gas and opens on a fixed clock. `launch` pulls no REGENT, needs no
   allowance and never calls the staking contract at creation, so a paused staking contract cannot
   stop a launch; the launchpad never holds REGENT. The auction's start block is the creation block
   plus `START_LEAD_BLOCKS`, its end block that plus `AUCTION_DURATION_BLOCKS`, both read back from
   the created auction and carried by `StockLaunchCreated`.

## Verification

```sh
cd contracts/stocks
python3 bootstrap-deps.py /path/to/hydrated/autolaunch/checkout   # once; fills lib/
forge build
forge test --fuzz-runs 64
FOUNDRY_PROFILE=fork forge test --fork-url http://127.0.0.1:PORT --fuzz-runs 64   # against the lab
FOUNDRY_PROFILE=fork forge test --fork-url https://base-rpc.publicnode.com --match-contract AerodromeStockRouteForkTest   # route against Base itself
```

### The gate

`bin/gate.sh` is the one required check before a change is proposed. It is offline and proves,
in order: the frozen tool and build identity (`requirements/frozen-identity.json` against
`forge --version`, `slither --version` and `forge config --json`), `forge fmt --check`, a clean
`forge build --sizes` whose artifacts carry the frozen compiler identity, the frozen release surface
(`bin/freeze.py check` reconciles `abi/` and `reports/frozen/` byte for byte against the fresh
build, the dependency snapshot under `lib/` against `reports/frozen/dependency-closure.json`, and
the compiled test listing against `reports/frozen/test-listing.json`), the whole hermetic test
portfolio, Slither with every detector on and every result dispositioned in
`docs/security/slither-dispositions.md`, and a provider-secret scan. It ends with `GATE PASS` and
a receipt under `reports/generated/`, which is never committed.

The gate proves a clean repository first: every tracked byte must equal the index and nothing
untracked may exist outside the ignored build directories, so it runs in a clean clone, not in a
working tree with edits. The dependency snapshot is exported, not a submodule tree, so the gate
does not walk submodules; `lib/` must be the snapshot the closure pins.

```sh
export PATH="$HOME/.foundry/bin:$PATH"      # forge 1.5.1
uv tool install slither-analyzer==0.11.5    # once; the gate resolves its interpreter itself
cd contracts/stocks && bin/gate.sh
```

`bin/freeze.py write` regenerates the frozen release surface after an intended production change.
It runs `forge clean`, `forge build` and `forge test --list --json` and rewrites `abi/` and
`reports/frozen/`; review the diff, then run the gate. The freeze pins every production contract's
runtime and creation code, its ABI and selectors, the clone template the launchpad stamps, the
hook flags the deploy script mines for, and the content digest of every dependency.

`test/fork/ForkAddresses.sol` pins the lab run it was written against; a restarted lab needs those
addresses updated. The route suite skips on the lab (chain id 31337) and the lifecycle suite skips
on Base itself, so each fork command runs only the tests that fit its chain.

The fork lab (`bin/local-stocks-lab.py`) requires an active `contracts/v1/bin/local-base-lab.py`
run and writes `stocks-site-config.json` (and its own `stocks-state.json`) next to that run's
`site-config.json`; the website reads the config through `AUTOLAUNCH_STOCKS_LAB_CONFIG`. It never
writes the Agent run record. `--agent-lab-dir` points it at a run in another checkout.

A launch costs nothing on either launchpad, so `fund` grants REGENT only for Revstake bids; the
controller checks the Safe's balance first.

```sh
python3 bin/local-stocks-lab.py [--agent-lab-dir DIR] deploy            # fixtures, graph, admission, funding, config
python3 bin/local-stocks-lab.py fund WALLET --regent 100000 --stock AAPLc --amount 100 --usdc 1000
python3 bin/local-stocks-lab.py status [--launch ID] [--auction ADDR]
python3 bin/local-stocks-lab.py advance --auction ADDR --to start|end|claim|migration
python3 bin/local-stocks-lab.py migrate --launch ID
python3 bin/local-stocks-lab.py settle-regent --pool-id 0x… --amount UNITS --min-usdc UNITS
python3 bin/local-stocks-lab.py settle-stakers --pool-id 0x…
python3 bin/local-stocks-lab.py collect --token-id ID
```

The lab deployer (`0x5700…0001`) and the hook executor are the same impersonated address; the
Governance Safe is impersonated for admission, unpausing and REGENT funding; USDC comes from a forked holder
(Morpho Blue by default, `--usdc-holder` to change). Nothing in the lab is B20-verified.
