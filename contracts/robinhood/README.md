# Autolaunch on the Robinhood chain

The Base Stocks (memestake) launchpad (`contracts/stocks`) rebuilt for the Robinhood chain with USDG
as the only dollar. Robinhood is memestake-only: there is no agent (Revshare) launch here. Nothing
here touches the frozen Base contracts; this package is additive and shares the Base Stocks preset
geometry (`autolaunch-stocks/StocksPreset.sol`), the chain-neutral staking accounting
(`autolaunch-stocks/MemestockSplitterCore.sol`), the fee-only position locker
(`autolaunch-stocks/MemestockLPLocker.sol`) and the pinned libraries under `../stocks/lib`.

Official-pool trading pays the 0.30% LP fee plus two STOCK-side hook lanes, both always on: a 100 bps
protocol lane, converted to USDG and deposited into the inbox, and a 100 bps staker lane, deposited
as STOCK into the launch's own splitter. Holders stake the MEMESTOCK there and divide, pro rata,
everything the splitter recognizes in USDG, MEMESTOCK and STOCK after a 2% protocol share. The locked
positions' LP fees flow into the same splitter. No launch has a creator, an administrator or a
treasury.

## What is here

| Contract | Role |
| --- | --- |
| `RobinhoodPreset` | Every Robinhood-specific fixed term: USDG decimals, the auction schedule in Robinhood's 0.1-second blocks (fixed ten-minute start lead of 6,000 blocks, one-day duration of 864,000, claim and migration delays, the thirteen-step release vector), the two lane percentages, the Base chain id. |
| `RobinhoodProtocolRevenueInboxV1` | The on-chain collection point for every protocol dollar (hook protocol lane, the splitters' USDG protocol share). Safe-only bridging to Base through a reviewed adapter, with destination versioning and batch records. |
| `RobinhoodBaseRevenueReceiverV1` | The Base-side address bridged USDC lands on. Base-Safe-attested batch attribution, permissionless deposit into live REGENT staking, surplus sweep. |
| `RobinhoodMemestockSplitterV1` | The per-launch staking splitter (clone target) over `MemestockSplitterCore`: recognizes USDG, MEMESTOCK and STOCK; 2% protocol share of each (USDG into the inbox, tagged `robinhood-splitter`; MEMESTOCK and STOCK to the Robinhood Safe); the other 98% wholly to MEMESTOCK stakers pro rata; everything to the protocol route while nothing is staked. No owner, no parameters. |
| `RobinhoodFeeHookV1` + `RobinhoodFeeHookFactory` | The official-pool v4 hook: two always-on STOCK-side lanes of one percent each. `settleProtocolLane` (executor only, admitted route, `minUsdgOut`) deposits USDG into the inbox; `settleStakerLane` (anyone) deposits the whole staker lane as STOCK into the pool's splitter. The factory holds the hook's creation code so the launchpad stays under the EIP-170 size limit. |
| `RobinhoodLaunchpadBase` | The launch machinery: validated constructor bindings, pause governance, NEW and auction creation on the fixed Robinhood schedule with full read-back, custody, migration. A launch costs nothing beyond gas. Deploys the splitter implementation and the `MemestockLPLocker` in its constructor; at graduation clones the launch's splitter, registers it with the hook, mints the positions to the locker and registers each one to that splitter. |
| `RobinhoodStocksLaunchpadV1` | Stock-pair launches: admitted STOCK as the auction currency, the required raise chosen by the launcher in STOCK (above zero, within what the inventory can settle on), full-range plus one-sided STOCK positions locked in the fee-only locker. |
| `RobinhoodStockBidAdapterV1` | USDG in, STOCK bid out, in one transaction, owned by the caller. |
| `routes/UniswapV3StockRouteV1` | The production USDG <-> STOCK route, one per admitted stock: executes on that stock's Uniswap v3 USDG/STOCK pool (either currency order), quotes from its Chainlink feed and refuses any execution more than five percent under the feed. Holds nothing between calls. |
| `RobinhoodPositionsLib` | Linked library carrying the position planner (EIP-170). Must be deployed and linked before the launchpads. |
| `fixtures/FixtureUsdgStockRoute` | Lab-only fixed-price USDG/STOCK route. Never a production binding. |

## Building and testing

```bash
FOUNDRY_OFFLINE=true forge build --sizes
FOUNDRY_OFFLINE=true forge test
FOUNDRY_PROFILE=fork forge test --fork-url robinhood    # the production route against Robinhood Chain itself
```

`test/fork/` runs only under the `fork` profile, against Robinhood Chain through the `robinhood`
alias in `foundry.toml` (resolved from `REGENT_ROBINHOOD_RPC_URL`, which is never written down); the
default profile and the gate exclude it. It binds the route to the live AAPL, TSLA and SNDK pools,
buys and sells a thousand dollars of each through the real pools and issuer tokens, and shows the
feed bound refusing a fifty-thousand-dollar purchase on the thin SNDK pool.

Libraries resolve from `../stocks/lib`; the package installs nothing of its own. forge 1.4's lint
pre-pass cannot follow those `../stocks/lib` imports and fails a build that touched any file, while
the compiler resolves them; add `FOUNDRY_LINT_LINT_ON_BUILD=false` when that happens (the lab
controller always does).

### The gate

`bin/gate.sh` is the one required check before a change is proposed. It shares its body with the
Base package (`../stocks/bin/memestake-gate.sh`) and proves the same things in the same order: the
frozen tool and build identity in `requirements/frozen-identity.json`, formatting, a clean build
whose artifacts carry the frozen compiler identity, the frozen release surface under `abi/` and
`reports/frozen/` (`../stocks/bin/freeze.py check` against `requirements/freeze.json`), the whole
hermetic test portfolio, Slither with every detector on and every result dispositioned in
`docs/security/slither-dispositions.md`, and a provider-secret scan. It ends with `GATE PASS` and
a receipt under `reports/generated/`, which is never committed.

Slither cannot follow this package's `../stocks/lib` and `allow_paths`, so the gate builds a
self-contained copy under `reports/generated/slither-copy/` (this package's sources, the Base
sources it imports, the dependency snapshot through symlinks, and the remappings rewritten to
match) and analyzes that copy; the dispositions record locations relative to it.

The gate proves a clean repository first, so it runs in a clean clone with the Base package's
`lib/` snapshot in place, not in a working tree with edits.

```sh
export PATH="$HOME/.foundry/bin:$PATH"      # forge 1.5.1
uv tool install slither-analyzer==0.11.5    # once; the gate resolves its interpreter itself
cd contracts/robinhood && bin/gate.sh
```

`python3 ../stocks/bin/freeze.py write` regenerates the frozen release surface after an intended
production change; review the diff, then run the gate.

## What the founder must supply before any deployment

Every binding is a constructor argument and is verified at construction (code present, expected
decimals, matching cross-bindings). None is known at build time.

- Robinhood chain id. The auction schedule in `RobinhoodPreset` assumes 0.1-second blocks (founder decision of 21 September 2026: every Base term times twenty); CCA and the launchpads read the chain's own block number through `BlockNumberish`.
- USDG address; confirmation that it reports six decimals (construction refuses anything else).
- Continuous Clearing Auction factory, Uniswap v4 PoolManager and PositionManager, Permit2, and a UERC20 factory whose runtime code hash equals the Base one.
- The Robinhood Safe (admin of every contract here) and the Base Safe (attests deliveries on the Base receiver).
- The reviewed bridge adapter (must report USDG and Base chain id 8453) and the Base receiver address it delivers to.
- The STOCK admissions with their routes.

## Deployment order

1. `RobinhoodProtocolRevenueInboxV1(usdg, robinhoodSafe)`.
2. `RobinhoodPositionsLib` (linked), `RobinhoodFeeHookFactory(poolManager)`.
3. `RobinhoodStocksLaunchpadV1(bindings, hookSalt)` with a salt mined against the hook factory for the predicted launchpad address (the launchpad deploys its hook, its locker and its splitter implementation itself), then `RobinhoodStockBidAdapterV1(stocksLaunchpad, permit2)`.
4. On Base: `RobinhoodBaseRevenueReceiverV1(usdc, liveStaking, baseSafe)`; then the Safe sets the inbox's destination and adapter.
5. The Safe admits stocks, sets the hook executor, and unpauses the launchpad.

## Decisions recorded in this package

1. Bindings are constructor immutables validated at construction; no bindings library and no hard-coded addresses.
2. A launch costs nothing beyond gas: no fee is pulled and the launchpad never holds USDG (founder decision 2026-09-21). There is no REGENT on the Robinhood chain.
3. Every auction opens exactly ten minutes after its creation block (6,000 Robinhood blocks); the opening block is in the launch record and the creation event. The launcher supplies the floor price and the required raise in STOCK, above zero and within what the inventory can settle on; there is no governance minimum (founder decision 2026-09-21).
4. Robinhood is memestake-only (founder decision 2026-09-18): the USDG agent launch, its splitter and its vesting were removed.
5. The splitter is created at graduation as a clone of an implementation the launchpad deploys in its constructor; the launch record's `splitter` is the only splitter provenance, and the hook and the locker accept a splitter only from the launchpad.
6. There is no payment-receiver clone and no administrator: both lanes are always on, and the splitter's `depositRecognizedRevenue` and `recognizeSurplusRevenue` are its only revenue surfaces.
7. The protocol lane settles executor-only (it chooses an amount and a minimum price); the staker lane and the locker's `collect` are permissionless (they choose nothing). The splitter's 2% protocol share goes to the inbox in USDG and to the Robinhood Safe in MEMESTOCK and STOCK (founder decision 2026-09-18).
8. The auction block schedule is the Base Stocks schedule scaled twentyfold for 0.1-second blocks: start lead 6,000, duration 864,000, claim delay 1,280, migration delay 2,560, and a thirteen-step release vector whose scheduled steps each last twenty times the Base blocks at a twentieth of the Base rate (`RobinhoodPreset.t.sol` proves the sums). Because a per-block rate is a whole number of mps, dividing by twenty rounds each step's rate, so the per-step releases differ slightly from Base's (founder, 21 September 2026: accepted as is). For reference:

   | Step | Base blocks (2 s) | Base release | Robinhood blocks (0.1 s) | Robinhood release |
   |---|---|---|---|---|
   | 1 | 5,445 | 5.8806% | 108,900 | 5.4450% |
   | 2 | 4,258 | 5.7909% | 85,160 | 5.9612% |
   | 3 | 3,902 | 5.8530% | 78,040 | 6.2432% |
   | 4 | 3,686 | 5.8239% | 73,720 | 5.8976% |
   | 5 | 3,534 | 5.8664% | 70,680 | 5.6544% |
   | 6 | 3,418 | 5.8106% | 68,360 | 6.1524% |
   | 7 | 3,324 | 5.8502% | 66,480 | 5.9832% |
   | 8 | 3,245 | 5.8410% | 64,900 | 5.8410% |
   | 9 | 3,178 | 5.8475% | 63,560 | 5.7204% |
   | 10 | 3,119 | 5.8637% | 62,380 | 5.6142% |
   | 11 | 3,068 | 5.8292% | 61,360 | 6.1360% |
   | 12 | 3,022 | 5.8627% | 60,459 | 6.0459% |
   | 13 (terminal, one block) | 1 | 29.8802% | 1 | 29.3055% |

   Both columns sum to 100% of the auction inventory over one day of clock time.
9. USDG is assumed six-decimal and the assumption is enforced at construction of every contract that reads it.
10. Base receiver attribution is Base-Safe-attested; the deposit itself is permissionless with a surplus sweep.
11. The position planner lives in a linked library and the hook creation code in a factory so the launchpad stays under the EIP-170 limit.
13. Stock routes. `UniswapV3StockRouteV1` is the production route, one per admitted stock, created by the deployment ceremony after the bid adapter and admitted by the Safe. It executes directly on the stock's Uniswap v3 USDG/STOCK pool (the Robinhood pools sort USDG and the stock either way; the route reads the order once at construction), quotes from the stock's Chainlink USD feed, refuses a feed older than seven days (the feeds hold the last close over weekends and holidays, so a shorter bound would stop every Monday morning) and refuses any execution that delivers more than 5% under the feed quote. Every Robinhood stock has eighteen decimals; the hermetic suite, the lab and the fixtures use eighteen decimals throughout, and `RobinhoodEighteenDecimalLifecycle.t.sol` walks a whole launch through the production route in both currency orders. `test/fork/UniswapV3StockRouteFork.t.sol` bought and sold a thousand dollars of AAPL, TSLA and SNDK through the live pools on 23 September 2026 (largest shortfall against the feed: 1.25% on the thin SNDK purchase) and showed the bound refusing a fifty-thousand-dollar SNDK purchase.
14. The issuer's powers over the stock tokens. The Robinhood stock tokens are the issuer's upgradeable contracts. One issuer key can replace the token code for every stock at once, pause all transfers, block any address from sending or receiving, burn any holder's balance (neither the pause nor the blocklist stops a burn), and rename a token, with no delay and no on-chain notice before it happens (verified on chain 4663 on 23 September 2026: every issuer role is held by a single externally owned key; 175 addresses are blocked, all of them wallets and none of them contracts; the global pause was used once, before launch). Any of these powers used against the launchpad, the hook, the locker, a splitter, a route or a pool would stall bids, settlements and fee collection for every market on that stock until the issuer reversed it; balances would stay where they are, a burn being the issuer's alone. The pools trade against these tokens around the clock today, and nothing in the graph can be blocked for being a contract. Accepted as a known limit (recorded 23 September 2026 on the chief engineer's instruction; the founder's own word on it is not yet on file).
15. Thin pools. Several USDG pools are thin (SNDK, INTC and MSTR at the time of writing: more than 1% of price impact on a ten-thousand-dollar trade, and the SNDK pool cannot fill fifty thousand dollars within the bound). The bound protects every caller, so a settlement too large for its pool simply does not go through: the executor settles the protocol lane in pieces small enough for the pool at hand rather than in one call, and the website should size bids the same way.
12. The splitter's exit rule ("nothing leaves an account in its own stake block") reads the chain's native `block.number`, which on this Arbitrum Orbit rollup is the Ethereum block the rollup last observed, while the launchpad and the auction count Robinhood blocks through `BlockNumberish`. A staker therefore waits until the next Ethereum block, about twelve seconds, before claiming or unstaking (verified read-only on chain 4663 on 21 September 2026: a contract saw block 26,027,887 while `ArbSys.arbBlockNumber()` returned 69,038,732). The founder kept the rule as is and had this documented (21 September 2026). The local lab, a plain Anvil chain, does not reproduce this.

## The local lab

`bin/local-robinhood-lab.py` boots a blank Anvil chain (id 31338), installs Permit2's runtime at its
canonical address and a block clock at the ArbSys precompile address (see below), and runs
`script/DeployRobinhoodLab.s.sol` from Anvil's first unlocked account,
which stands in for the admin Safe and the hook executor. The script deploys a mintable USDG double,
the pinned PoolManager, CCA factory, PositionManager and UERC20 factory, the inbox, the hook
factory, the Stocks launchpad (which deploys its hook, locker and splitter implementation), the USDG bid adapter, and thirteen mintable
fixture stocks (the Base lab's symbols and fixture prices) each with a `FixtureUsdgStockRoute`
holding one million shares and one billion USDG, admitted on the Stocks launchpad. The launchpad
is unpaused.

```bash
uv run --no-project python bin/local-robinhood-lab.py start
uv run --no-project python bin/local-robinhood-lab.py fund 0xWALLET --usdg 100000 --stock AAPLc --shares 1000
uv run --no-project python bin/local-robinhood-lab.py status [--launch ID] [--auction 0x…]
uv run --no-project python bin/local-robinhood-lab.py advance 0xAUCTION --to start|end|claim|migration
uv run --no-project python bin/local-robinhood-lab.py pace 0xAUCTION [--to migration] [--duration-seconds 1200]
uv run --no-project python bin/local-robinhood-lab.py migrate ID
uv run --no-project python bin/local-robinhood-lab.py stop
```

`start` writes `reports/generated/local-robinhood-lab/site-config.json` for the platform
(`AUTOLAUNCH_ROBINHOOD_LAB_CONFIG`): `rpc_url`, `chain_id`, `run_id`, `addresses` (`stocks_launchpad`,
`stocks_hook`, `stocks_locker`, `stocks_splitter_implementation`, `bid_adapter`, `usdg`, `inbox`, `hook_factory`,
`pool_manager`, `position_manager`, `cca_factory`, `uerc20_factory`, `permit2`, `admin_safe`),
`stocks` (one entry per fixture: `symbol`, `name`, `address`, `decimals`, `route`,
`usdg_per_share`, `fixture`, `launch_admission`) and `abis` (`stocks_launchpad`, `stocks_hook`,
`stocks_locker`, `splitter`, `bid_adapter`, `stock_route`, `auction`, `erc20`). Every stock entry is read back from the chain after
deployment, including its admission on the Stocks launchpad; the controller carries no catalog of
its own. Nothing proven against the fixture stocks or routes is evidence about a real stock market.

The block clock. On the Robinhood chain the launchpad and the auction read the rollup block number
from the ArbSys precompile (`arbBlockNumber()` at `0x…64`, through `BlockNumberish`), not from
`block.number`. The lab installs a stand-in at that address before deploying, so every contract
takes the same code path it takes on the real chain, and the controller sets the number the
contracts see with one call: `advance` jumps the clock to a lifecycle block, `pace` moves it there
evenly over wall time (twenty minutes by default, so a whole one-day auction plays out in twenty
minutes), and `status` reports it as `block_clock`. Mining is not an option at these terms: Anvil
mines about forty empty blocks a second, so the 864,000-block auction would take more than five
hours. The clock only moves when `advance` or `pace` moves it, only forward, and only one of them
at a time: a second `advance` or `pace` started while one is running is refused, and a target the
clock has already passed is refused, so the number the contracts see never goes backwards. The
splitters read `block.number`,
which on the lab is Anvil's own block (one per transaction) and on the real chain is the Ethereum
block. Anything that shows the auction clock must read it the way the contracts do: on Robinhood,
call `arbBlockNumber()` at `0x…64` (on the real chain it agrees with `eth_blockNumber` within a few
blocks; on the lab only the precompile is right).

`state.json` records the Anvil process, its loopback port and the chain's genesis hash. Before
`fund`, `advance`, `migrate` or `stop` touches the endpoint, the controller proves the recorded
process is alive, is Anvil, is the one process listening on that port, and that the chain there
carries the recorded genesis hash and the launchpad; any mismatch refuses without acting.
