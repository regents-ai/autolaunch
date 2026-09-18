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
| `RobinhoodPreset` | Every Robinhood-specific fixed term: USDG decimals, the minimum raise, the USDG launch fee, the two lane percentages, the Base chain id. |
| `RobinhoodProtocolRevenueInboxV1` | The on-chain collection point for every protocol dollar (hook protocol lane, the splitters' USDG protocol share, launch fees). Safe-only bridging to Base through a reviewed adapter, with destination versioning and batch records. |
| `RobinhoodBaseRevenueReceiverV1` | The Base-side address bridged USDC lands on. Base-Safe-attested batch attribution, permissionless deposit into live REGENT staking, surplus sweep. |
| `RobinhoodMemestockSplitterV1` | The per-launch staking splitter (clone target) over `MemestockSplitterCore`: recognizes USDG, MEMESTOCK and STOCK; 2% protocol share of each (USDG into the inbox, tagged `robinhood-splitter`; MEMESTOCK and STOCK to the Robinhood Safe); the other 98% wholly to MEMESTOCK stakers pro rata; everything to the protocol route while nothing is staked. No owner, no parameters. |
| `RobinhoodFeeHookV1` + `RobinhoodFeeHookFactory` | The official-pool v4 hook: two always-on STOCK-side lanes of one percent each. `settleProtocolLane` (executor only, admitted route, `minUsdgOut`) deposits USDG into the inbox; `settleStakerLane` (anyone) deposits the whole staker lane as STOCK into the pool's splitter. The factory holds the hook's creation code so the launchpad stays under the EIP-170 size limit. |
| `RobinhoodLaunchpadBase` | The launch machinery: validated constructor bindings, pause and fee governance, the USDG launch fee into the inbox, NEW and auction creation with full read-back, custody, migration. Deploys the splitter implementation and the `MemestockLPLocker` in its constructor; at graduation clones the launch's splitter, registers it with the hook, mints the positions to the locker and registers each one to that splitter. |
| `RobinhoodStocksLaunchpadV1` | Stock-pair launches: admitted STOCK as the auction currency, the required raise derived from the Safe's 1,000 USDG minimum through the route's quote, full-range plus one-sided STOCK positions locked in the fee-only locker. |
| `RobinhoodStockBidAdapterV1` | USDG in, STOCK bid out, in one transaction, owned by the caller. |
| `RobinhoodPositionsLib` | Linked library carrying the position planner (EIP-170). Must be deployed and linked before the launchpads. |
| `fixtures/FixtureUsdgStockRoute` | Lab-only fixed-price USDG/STOCK route. Never a production binding. |

## Building and testing

```bash
FOUNDRY_OFFLINE=true forge build --sizes
FOUNDRY_OFFLINE=true forge test
```

Libraries resolve from `../stocks/lib`; the package installs nothing of its own. forge 1.4's lint
pre-pass cannot follow those `../stocks/lib` imports and fails a build that touched any file, while
the compiler resolves them; add `FOUNDRY_LINT_LINT_ON_BUILD=false` when that happens (the lab
controller always does).

## What the founder must supply before any deployment

Every binding is a constructor argument and is verified at construction (code present, expected
decimals, matching cross-bindings). None is known at build time.

- Robinhood chain id and the block cadence (the auction schedule in `StocksPreset` is in Base 2-second blocks and is marked provisional for Robinhood; CCA and the launchpads read the chain's own block number through `BlockNumberish`).
- USDG address; confirmation that it reports six decimals (construction refuses anything else).
- Continuous Clearing Auction factory, Uniswap v4 PoolManager and PositionManager, Permit2, and a UERC20 factory whose runtime code hash equals the Base one.
- The Robinhood Safe (admin of every contract here) and the Base Safe (attests deliveries on the Base receiver).
- The reviewed bridge adapter (must report USDG and Base chain id 8453) and the Base receiver address it delivers to.
- The launch fee in USDG (born zero, Safe-settable) and the STOCK admissions with their routes.

## Deployment order

1. `RobinhoodProtocolRevenueInboxV1(usdg, robinhoodSafe)`.
2. `RobinhoodPositionsLib` (linked), `RobinhoodFeeHookFactory(poolManager)`.
3. `RobinhoodStocksLaunchpadV1(bindings, hookSalt)` with a salt mined against the hook factory for the predicted launchpad address (the launchpad deploys its hook, its locker and its splitter implementation itself), then `RobinhoodStockBidAdapterV1(stocksLaunchpad, permit2)`.
4. On Base: `RobinhoodBaseRevenueReceiverV1(usdc, liveStaking, baseSafe)`; then the Safe sets the inbox's destination and adapter.
5. The Safe admits stocks, sets the hook executor, and unpauses the launchpad.

## Decisions recorded in this package

1. Bindings are constructor immutables validated at construction; no bindings library and no hard-coded addresses.
2. The launch fee is USDG, born zero, Safe-settable, deposited into the inbox at creation and never refunded. There is no REGENT on the Robinhood chain.
3. Launches take the launcher's start block and floor price like Base Stocks.
4. Robinhood is memestake-only (founder decision 2026-09-18): the USDG agent launch, its splitter and its vesting were removed.
5. The splitter is created at graduation as a clone of an implementation the launchpad deploys in its constructor; the launch record's `splitter` is the only splitter provenance, and the hook and the locker accept a splitter only from the launchpad.
6. There is no payment-receiver clone and no administrator: both lanes are always on, and the splitter's `depositRecognizedRevenue` and `recognizeSurplusRevenue` are its only revenue surfaces.
7. The protocol lane settles executor-only (it chooses an amount and a minimum price); the staker lane and the locker's `collect` are permissionless (they choose nothing). The splitter's 2% protocol share goes to the inbox in USDG and to the Robinhood Safe in MEMESTOCK and STOCK (founder decision 2026-09-18).
8. The auction block schedule is shared with Base Stocks and is provisional until the Robinhood block cadence is confirmed.
9. USDG is assumed six-decimal and the assumption is enforced at construction of every contract that reads it.
10. Base receiver attribution is Base-Safe-attested; the deposit itself is permissionless with a surplus sweep.
11. The position planner lives in a linked library and the hook creation code in a factory so the launchpad stays under the EIP-170 limit.

## The local lab

`bin/local-robinhood-lab.py` boots a blank Anvil chain (id 31338), installs Permit2's runtime at its
canonical address, and runs `script/DeployRobinhoodLab.s.sol` from Anvil's first unlocked account,
which stands in for the admin Safe and the hook executor. The script deploys a mintable USDG double,
the pinned PoolManager, CCA factory, PositionManager and UERC20 factory, the inbox, the hook
factory, the Stocks launchpad (which deploys its hook, locker and splitter implementation), the USDG bid adapter, and thirteen mintable
fixture stocks (the Base lab's symbols and fixture prices) each with a `FixtureUsdgStockRoute`
holding one million shares and one billion USDG, admitted on the Stocks launchpad. The launchpad
is unpaused; the launch fee is zero and its minimum raise is the preset's 1,000 USDG.

```bash
uv run --no-project python bin/local-robinhood-lab.py start
uv run --no-project python bin/local-robinhood-lab.py fund 0xWALLET --usdg 100000 --stock AAPLc --shares 1000
uv run --no-project python bin/local-robinhood-lab.py status [--launch ID] [--auction 0x…]
uv run --no-project python bin/local-robinhood-lab.py advance 0xAUCTION --to start|end|claim|migration
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

`state.json` records the Anvil process, its loopback port and the chain's genesis hash. Before
`fund`, `advance`, `migrate` or `stop` touches the endpoint, the controller proves the recorded
process is alive, is Anvil, is the one process listening on that port, and that the chain there
carries the recorded genesis hash and the launchpad; any mismatch refuses without acting.
