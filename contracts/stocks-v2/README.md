# Autolaunch Stocks contracts

Autolaunch Stocks creates a new token, **NEW**, sells 49.75% of its initial supply through the
pinned Uniswap Continuous Clearing Auction denominated in one admitted Base stock token,
**STOCK**, and after a successful auction gives its bidders that whole 49.75% and opens the official
**NEW/STOCK** Uniswap v4 pool at the auction's final clearing price. The whole raise and another
49.75% of the supply are locked forever: one full-range position pairs the whole raise with as much of
that reserve as it takes at the opening price, and a second position, NEW only, holds the rest of the
reserve just above the opening price. The last 0.5% vests to the launcher linearly, block by block, over
30 days from graduation. Official-pool trading pays
three STOCK-side hook fees on top of the 0.30% LP fee, all always on: a 30 bps creator lane, paid as
STOCK to the launcher, a 100 bps REGENT lane, converted to USDC and deposited into REGENT staking,
and a 300 bps staker lane, deposited as STOCK into the launch's own **memestock splitter**. Holders
stake NEW (the MEMESTOCK) in that splitter and divide, pro rata, everything it recognizes in USDC,
MEMESTOCK and STOCK after a 2% protocol share. The locked position sits in a fee-only locker whose
LP fees also flow into the splitter. No launch has an administrator or a treasury.

This is a separate Foundry component. It reuses the frozen `contracts/v1` dependencies at their
pinned revisions and never modifies them. Nothing here changes the Agent factory, strategy,
hook, escrow, splitter or receiver. The memestock splitter is a separate contract modelled on the
Agent subject splitter, not a change to it.

## Status

Version 2 is deployed on Base. Its receipt-based addresses and verified bindings are recorded in
`deployments/base-mainnet/deployed-manifest.json`; see `deployments/base-mainnet/README.md`.
It replaces the Base launchpad in `contracts/stocks`, which stays there for the launches made on it;
nothing in that folder changes. Version 2 changes only
the sale and graduation terms (founder decisions of 1 and 5 October 2026): 49.75% of the supply is
sold, 49.75% is the locked pool reserve and 0.5% vests to the launcher over 30 days; every auction uses the
lowest floor the pinned auction allows and the required raise is the sale allocation at that floor;
bidders receive the whole sale allocation from the auction itself; the pool opens at the final
clearing price with a full-range position and a NEW-only position above it, and the few crumbs of
NEW left over after graduation are retired. The hook, splitter, locker, bid adapter and routes are
the same source; a version 2 deployment creates new instances bound to the new launchpad.

## Layout

| Path | Owns |
| --- | --- |
| `src/interfaces/` | The cross-component ABI. Website, indexer and CLI consume these shapes. |
| `src/StocksPreset.sol` | Every fixed launch term, in one place, with its provenance label. |
| `src/StocksLaunchpadV2.sol` | Admission, creation, custody, migration; deploys the locker and the splitter implementation, clones one splitter per graduation. |
| `src/StocksFeeHookV1.sol` | The official-pool hook: three accrual-only fee lanes and out-of-swap settlement. |
| `src/MemestockSplitterCore.sol` | The shared staking and revenue accounting: three recognized assets, 2% protocol share, pro rata accrual, one-block exit rule, recovery of unsupported tokens. Chain-neutral; the Robinhood splitter inherits it too. |
| `src/MemestockSplitterV1.sol` | The Base clone target: USDC protocol share into live REGENT staking, MEMESTOCK and STOCK protocol shares to the Governance and REGENT Safe. |
| `src/MemestockLPLocker.sol` | Permanent fee-only owner of every launch position; anyone may `collect`, the fees always land in the launch's splitter. Shared with the Robinhood launchpad. |
| `src/StockBidAdapterV1.sol` | Atomic USDC → STOCK → CCA bid owned by the caller. |
| `src/StocksBindings.sol` | The frozen Base bindings this component compiles against, copied from `contracts/v1`, plus canonical Permit2. |
| `src/routes/` | `IStockRoute` implementations: `AerodromeStockRouteV2`, the production route (one per admitted STOCK, over its Aerodrome Slipstream USDC pool and Chainlink feed), and the lab-only `FixtureStockRoute`. |
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
| NEW initial supply `S0` | 1,000,000,000 × 10^18 | Founder decision 2026-09-09; even; below the CCA `MAX_TOTAL_SUPPLY` |
| Auction inventory (the sale allocation) | 49.75% of `S0` = 497,500,000 × 10^18 | Founder decision 2026-10-05 |
| Migration reserve | 49.75% of `S0` = 497,500,000 × 10^18 | Founder decision 2026-10-05 |
| Creator vesting | 0.5% of `S0` = 5,000,000 × 10^18, held by the launchpad from launch; vests linearly per block over `CREATOR_VESTING_BLOCKS` 1,296,000 blocks (30 days at 2 s blocks) from the graduation block; anyone may call `releaseCreatorVesting`, which pays only the launcher; retired with the rest if the auction fails | Founder decisions 2026-10-01 (term) and 2026-10-05 (amount) |
| Auction duration | 43,200 blocks (~24 h at Base's 2 s blocks) | Brief P03 "approximately 24 hours"; block count founder decision 2026-09-09 |
| Step schedule | 13 packed steps summing to 43,200 blocks and exactly `MPS = 1e7` | Derived; shape mirrors Agent's pinned schedule, proven by test |
| Start lead | `START_LEAD_BLOCKS` 300 (ten minutes at 2 s blocks): every auction opens exactly 300 blocks after its creation block; the launcher does not choose it; the opening block is in the launch record and the `StockLaunchCreated` event | Founder decision 2026-09-21 |
| Claim delay | 64 blocks after end | Same pinned CCA convention as Agent |
| Migration delay | 128 blocks after end | Same pinned CCA convention as Agent |
| Floor price | `FLOOR_PRICE_Q96` 4,294,967,300: the CCA `MIN_FLOOR_PRICE` (2^32 + 1) rounded up to the 100-tick grid; the same for every launch, the launcher chooses nothing | Founder decision 2026-10-01 (the lowest floor) |
| Bid tick spacing | `BID_TICK_SPACING_Q96` = `FLOOR_PRICE_Q96 / 100` = 42,949,673, at least CCA `MIN_TICK_SPACING` | Derived from the floor |
| Official pool LP fee | 3000 (0.30%) | Founder decision 2026-09-09 |
| Official pool tick spacing | 60 | Founder decision 2026-09-09 |
| Hook fee | 430 bps of the gross STOCK-side amount, floored once, split into the three lanes below | Founder decision 2026-09-28 |
| Creator hook lane | 30 bps of the gross STOCK-side amount, floored, always on; paid as STOCK to the launcher by anyone (`settleCreatorLane`) | Founder decision 2026-09-28 |
| REGENT hook lane | 100 bps of the gross STOCK-side amount, floored; converted to USDC into REGENT staking by the executor (`settleRegentLane`) | Founder decision 2026-09-28 |
| Staker hook lane | the rest of the hook fee, never less than 300 bps of the gross STOCK-side amount floored, always on; deposited as STOCK into the launch's splitter by anyone (`settleStakerLane`) | Founder decision 2026-09-28 |
| Splitter protocol share | 2% (`SKIM_BPS` 200) of every recognized amount in USDC, MEMESTOCK and STOCK; USDC straight into live REGENT staking, MEMESTOCK and STOCK to the Governance and REGENT Safe; the other 98% belongs wholly to stakers | Founder decision 2026-09-18 |
| Revenue with nothing staked | the whole amount follows the protocol route (USDC into REGENT staking, other assets to the Safe); the rule holds only while `totalStaked == 0`, so any stake placed before a settlement takes the 98% share of that settlement | Founder decision 2026-09-18 |
| Launch fee | none: a launch costs nothing beyond gas; no REGENT is pulled and the launchpad never holds REGENT | Founder decision 2026-09-21 |
| Required raise | the whole sale allocation at the floor price, rounded up: `REQUIRED_STOCK_RAISED` = `ceil(AUCTION_INVENTORY × FLOOR_PRICE_Q96 / 2^96)` = 26,969,530 STOCK base units, never zero, so an auction nobody bid in never graduates; below it the auction fails and bidders are refunded. At the lowest floor it is about 0.27 of a share for an 8-decimal stock | Founder decision 2026-10-01 (derived from the floor only) |
| Treasury | none | Brief P05 |
| Leftover NEW after graduation | every unit of the launch's NEW the launchpad still holds once both positions are minted, apart from the creator vesting (the auction's unsold rounding, the planner's rounding, and anything sent to the launchpad) is transferred to `0x…dEaD` in `migrate` and recorded as `retiredNew`; bidders receive the whole sale allocation from the auction itself | Founder decision 2026-10-01 |
| Reserve, inventory and vesting after failed minimum | transferred to `0x…dEaD` in `migrate`; refunds remain independent | Brief §1.2 recommendation; founder decisions 2026-09-09 and 2026-10-01 |
| Opening price | the auction's final clearing price (`lbpInitializationParams().initialPriceX96`) | Founder decision 2026-10-01 |
| Locked liquidity | Two positions, both NFTs to the `MemestockLPLocker`: one full-range position pairing the whole raise with the reserve it takes at the opening price, and one NEW-only position holding the rest of the reserve from one pool tick spacing past the opening price out as far as the pinned planner reaches (887,272 ticks, or the last usable tick when nearer); no NEW-only position is minted when the full range takes the whole reserve; nothing burned | Founder decision 2026-10-01 |
| LP rounding remainder (STOCK the position could not pair) | accrued to the REGENT lane of the pool's hook; below one part in a billion of the raise in every test | Founder decision 2026-09-09 (the destination) |
| LP custody | each position NFT minted to the launchpad's `MemestockLPLocker` and registered to the launch's splitter, once and forever; the locker can only collect fees (a decrease of exactly zero) and deposit them into that splitter; no principal path exists | Brief P13; founder decision 2026-09-18 (fees to stakers) |

### Design note on graduation

The pinned auction never lowers its clearing price and carries every unit it has not sold into the
blocks that follow. An auction that ended at the floor therefore sold its raise divided by the floor,
which is at least the sale allocation once the raise meets the minimum; an auction that ended above
the floor sold everything left in its final block. Either way a graduated auction has sold the whole
sale allocation to its bidders but for its own rounding, so bidders receive the whole sale allocation
from the auction itself.

Every bidder pays the clearing price of the blocks it bought in, never more than the final clearing
price, so the raise is at most the sale allocation times the final price. The pool opens at that
final price, and the full-range position pairing the whole raise there takes the raise divided by the
final price of NEW: never more than the reserve, which equals the sale allocation. When every unit
sold at the final price (a single bidder from the first block, say) the full range takes the whole
reserve but for rounding and no NEW-only position is minted. Otherwise the rest of the reserve goes
into the NEW-only position, which starts one pool tick spacing past the opening price on the NEW side
and so holds only NEW until buyers lift the price into it.

The planner's rounding leaves a sliver unpaired: STOCK goes to the REGENT lane, NEW is retired. Every
unit of the launch's NEW the launchpad still holds after the positions are minted, except the creator
vesting, goes to the dead address. The shortfall and the retired NEW come from prices kept to one
unit of 2^-96 and never below the floor, so the tests hold them below the supply divided by the floor
price (`_newCrumbs` in `StocksLaunchpadMigrateTest`): about 0.23 NEW at the fixed floor.

The pinned auction may count a bid placed after its first block one STOCK base unit short, so a
single bid of exactly the minimum graduates only in the first block; the minimum plus one base unit
graduates in any block (`testFuzz_minimum_plus_one_unit_graduates_in_any_block`).

## Hook mechanics

Uniswap v4 lets an after-swap return delta charge only the swap's *unspecified* currency, so an
afterSwap-only hook cannot charge STOCK when STOCK is the specified amount (exact-input STOCK→NEW,
exact-output NEW→STOCK). To charge STOCK on every swap form the hook declares `beforeInitialize`,
`beforeSwap`, `afterSwap`, `beforeSwapReturnDelta` and `afterSwapReturnDelta`; STOCK-specified swaps
pre-commit their exact fee in `beforeSwap` as a specified-currency delta and revert
(`PartialFillNotSupported`) if the trader's own price limit cuts the fill short, since the pre-committed
fee would otherwise be inexact. STOCK-unspecified swaps are charged in `afterSwap` and fill partially
as usual. The fee base is the gross STOCK amount: the trader's whole debit for STOCK-input swaps, the
pool's whole output for STOCK-output swaps. The hook fee is 4.3% of it, floored once; the creator
lane is 0.3% of it and the REGENT lane 1%, each floored, and the staker lane takes the rest, so it is
never less than its own floored 3%. All three lanes are always charged. `settleCreatorLane` (anyone)
pays the whole creator lane, as STOCK, to the launcher. `settleRegentLane` (executor only, with
`minUsdcOut`) converts REGENT-lane STOCK through the admitted route and deposits the USDC into live
REGENT staking. `settleStakerLane` (anyone) deposits the whole staker lane, as STOCK, into the pool's
splitter. The two permissionless settlements decide nothing, so they need no authority, and a STOCK
that refuses the launcher only stalls that launcher's own lane, never a swap.

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
  administrator: the three lanes, the launcher and the splitter are fixed by the contracts.

### Stock routes

`AerodromeStockRouteV2` is the production `IStockRoute`: one contract per STOCK, pinned at
construction to that stock's Aerodrome Slipstream USDC/STOCK pool (factory
`0xf8f2eb4940cfe7d13603dddd87f123820fc061ef`, tick spacing 10, 0.05% fee; USDC is always
`token0`) and to its Chainlink total-return feed (8 decimals, USD per share, held at the last
close outside market hours). The route calls the pool directly with no router and no
caller-supplied calldata, and:

- quotes from the feed, not the pool; `launch` does not quote at all, the required raise follows
  from the floor in STOCK and the CCA's raise test is in STOCK;
- executes on the pool with the widest price limit; the price control is the minimum each caller
  sets (`minAmountOut`), and `swapExactIn` never reads the feed. The executor's minimum is what
  protects REGENT's share of every REGENT-lane sale, so the executor key must be kept safe and
  sales should be split in thin markets; the website offers bidders a minimum at 95% of the
  Chainlink price;
- refuses a quote whose feed answer is not positive or is older than 7 days (`MAX_FEED_AGE`);
- returns whatever input the pool did not consume to the recipient in the same call and holds
  nothing between calls; the pool's pull callback accepts the pinned pool only.

The ten `AerodromeStockRouteV1` routes the Base ceremony created on 22–23 September 2026 carried a
5% feed guard on execution; the founder removed it before any was admitted. They are retired.
Ten V2 routes were created by hand from the deployer on 23 September 2026 and admitted by the Safe
in transaction `0x97030521eac9d0eace8f53d1bcb5f42ef3527cabb712d73228bfe4fc8617fbd6` (block
51698209); their addresses are in the top-level [contracts/README.md](../README.md) and readable
from the launchpad's `stockAdmission(stock)`.

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

1. Exactly `S0` is minted, to the launchpad, once.
   `auctionInventory + migrationReserve + creatorVesting == S0`. The launchpad holds nothing of NEW
   after `launch` except the reserve and the vesting.
2. CCA `currency == stock`, `tokensRecipient == launchpad`, `fundsRecipient == launchpad`,
   `protocolFeeController == 0`.
3. `migrate` classifies with the final checkpoint. Graduated: register the launch's splitter and
   the pool with the hook, sweep STOCK, sweep unsold NEW, initialize at the final clearing price,
   mint the full-range position from the whole raise and the reserve it takes, and the NEW-only
   position from the rest of the reserve, both to the locker and registered to the splitter, so
   `lpStockUsed + dust == raised` with `dust` the rounding the REGENT lane takes; start the creator
   vesting at the graduation block and retire every other unit of the launch's NEW still held:
   `NEW kept by the auction + lpNewUsed + newOnlyUsed + retiredNew + creatorVesting == S0`. Failed:
   retire the reserve, the vesting and the swept inventory; never touch bidder STOCK.
4. Bidder refunds and claims go through the CCA and depend on nothing in this component. The bids
   of a graduated launch receive the whole sale allocation from the auction but for crumbs.
5. The hook only accrues. The creator lane leaves only through `settleCreatorLane` (anyone, whole
   lane, as STOCK, to the launcher), the REGENT lane only through `settleRegentLane` (executor-only,
   via the admitted route, with `minUsdcOut`) and the staker lane only through `settleStakerLane`
   (anyone, whole lane, as STOCK, into the pool's fixed splitter); a failing settlement reverts only
   itself.
6. A pool's splitter and launcher are fixed when the pool is registered; nothing redirects any lane
   afterwards.
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
cd contracts/stocks-v2
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
cd contracts/stocks-v2 && bin/gate.sh
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
python3 bin/local-stocks-lab.py settle-creator --pool-id 0x…
python3 bin/local-stocks-lab.py settle-stakers --pool-id 0x…
python3 bin/local-stocks-lab.py collect --token-id ID
```

The lab deployer (`0x5700…0001`) and the hook executor are the same impersonated address; the
Governance Safe is impersonated for admission, unpausing and REGENT funding; USDC comes from a forked holder
(Morpho Blue by default, `--usdc-holder` to change). Nothing in the lab is B20-verified.
