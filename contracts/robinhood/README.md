# Autolaunch on the Robinhood chain

The Base launchpads (`contracts/v1` Revshare, `contracts/stocks` Stocks) rebuilt for the Robinhood
chain with USDG as the only dollar. Nothing here touches the frozen Base contracts; this package is
additive and shares only the Base Stocks preset geometry (`autolaunch-stocks/StocksPreset.sol`) and
the pinned libraries under `../stocks/lib`.

## What is here

| Contract | Role |
| --- | --- |
| `RobinhoodPreset` | Every Robinhood-specific fixed term: USDG decimals, both minimum raises, the USDG launch fee, lane and skim percentages, the Revshare supply split and vesting, the Base chain id. |
| `RobinhoodProtocolRevenueInboxV1` | The on-chain collection point for every protocol dollar (hook protocol lane, splitter skims, launch fees). Safe-only bridging to Base through a reviewed adapter, with destination versioning and batch records. |
| `RobinhoodBaseRevenueReceiverV1` | The Base-side address bridged USDC lands on. Base-Safe-attested batch attribution, permissionless deposit into live REGENT staking, surplus sweep. |
| `RobinhoodSubjectSplitterV1` | The per-launch revenue splitter (clone target): USDG revenue, 2% skim to the inbox exactly once, stakers paid pro rata on total supply, the treasury holds the rest. |
| `RobinhoodFeeHookV1` + `RobinhoodFeeHookFactory` | The official-pool v4 hook: one percent per lane in the pool's fee currency; the protocol lane always on, the subject lane with a splitter. USDG buckets settle permissionlessly; STOCK buckets settle executor-only through the admitted route. The factory holds the hook's creation code so the launchpads stay under the EIP-170 size limit. |
| `RobinhoodLaunchpadBase` | Everything both launch kinds share: validated constructor bindings, pause and fee governance, the USDG launch fee into the inbox, NEW and auction creation with full read-back, custody, migration and locked liquidity. |
| `RobinhoodStocksLaunchpadV1` | Stock-pair launches: admitted STOCK as the auction currency, the required raise derived from the Safe's 1,000 USDG minimum through the route's quote, full-range plus one-sided STOCK positions locked at the dead address. |
| `RobinhoodRevshareLaunchpadV1` | Revenue-share launches: USDG auction with a launcher-set raise never below the Safe's 5,000 USDG minimum, the splitter created at graduation, the treasury allocation vesting linearly for one year. Its `splitterOf` registry is the provenance every other component checks. |
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
3. `RobinhoodRevshareLaunchpadV1(bindings, hookSalt)` with a salt mined against the hook factory for the predicted launchpad address.
4. `RobinhoodStocksLaunchpadV1(bindings, revshareLaunchpad, hookSalt)`, then `RobinhoodStockBidAdapterV1(stocksLaunchpad, permit2)`.
5. On Base: `RobinhoodBaseRevenueReceiverV1(usdc, liveStaking, baseSafe)`; then the Safe sets the inbox's destination and adapter.
6. The Safe admits stocks, sets the hook executor, and unpauses both launchpads.

## Decisions recorded in this package

1. Bindings are constructor immutables validated at construction; no bindings library and no hard-coded addresses.
2. The launch fee is USDG, born zero, Safe-settable, deposited into the inbox at creation and never refunded. There is no REGENT on the Robinhood chain.
3. Both launch kinds take the launcher's start block and floor price like Base Stocks; the Base Revshare's fixed REGENT floor has no USDG equivalent.
4. The Revshare treasury allocation vests inside the launchpad (linear, 365 days from graduation, released to the treasury by anyone) instead of through an escrow clone; unsold and unpaired NEW joins the vesting allocation on graduation and everything is retired on failure. Unpaired USDG goes to the treasury.
5. The splitter is created at graduation as a clone of an implementation the Revshare launchpad deploys in its constructor; its registry is the only splitter provenance.
6. There is no payment-receiver clone: the splitter's `depositRecognizedRevenue` is the payment surface.
7. USDG hook buckets settle permissionlessly; STOCK buckets settle executor-only.
8. The auction block schedule is shared with Base Stocks and is provisional until the Robinhood block cadence is confirmed.
9. USDG is assumed six-decimal and the assumption is enforced at construction of every contract that reads it.
10. Base receiver attribution is Base-Safe-attested; the deposit itself is permissionless with a surplus sweep.
11. The position planner lives in a linked library and the hook creation code in a factory so both launchpads stay under the EIP-170 limit.

## The local lab

`bin/local-robinhood-lab.py` boots a blank Anvil chain (id 31338), installs Permit2's runtime at its
canonical address, and runs `script/DeployRobinhoodLab.s.sol` from Anvil's first unlocked account,
which stands in for the admin Safe and the hook executor. The script deploys a mintable USDG double,
the pinned PoolManager, CCA factory, PositionManager and UERC20 factory, the inbox, the hook
factory, the Revshare launchpad, the Stocks launchpad, the USDG bid adapter, and thirteen mintable
fixture stocks (the Base lab's symbols and fixture prices) each with a `FixtureUsdgStockRoute`
holding one million shares and one billion USDG, admitted on the Stocks launchpad. Both launchpads
are unpaused; the Stocks launch fee is zero and its minimum raise is the preset's 1,000 USDG.

```bash
uv run --no-project python bin/local-robinhood-lab.py start
uv run --no-project python bin/local-robinhood-lab.py fund 0xWALLET --usdg 100000 --stock AAPLc --shares 1000
uv run --no-project python bin/local-robinhood-lab.py status [--kind stocks|revshare] [--launch ID] [--auction 0x…]
uv run --no-project python bin/local-robinhood-lab.py advance 0xAUCTION --to start|end|claim|migration [--kind …]
uv run --no-project python bin/local-robinhood-lab.py migrate ID [--kind …]
uv run --no-project python bin/local-robinhood-lab.py stop
```

`start` writes `reports/generated/local-robinhood-lab/site-config.json` for the platform
(`AUTOLAUNCH_ROBINHOOD_LAB_CONFIG`): `rpc_url`, `chain_id`, `run_id`, `addresses` (`launchpad`,
`hook`, `stocks_launchpad`, `stocks_hook`, `bid_adapter`, `usdg`, `inbox`, `hook_factory`,
`pool_manager`, `position_manager`, `cca_factory`, `uerc20_factory`, `permit2`, `admin_safe`),
`stocks` (one entry per fixture: `symbol`, `name`, `address`, `decimals`, `route`,
`usdg_per_share`, `fixture`, `launch_admission`) and `abis` (`launchpad`, `stocks_launchpad`,
`bid_adapter`, `stock_route`, `auction`, `erc20`). Every stock entry is read back from the chain after
deployment, including its admission on the Stocks launchpad; the controller carries no catalog of
its own. Nothing proven against the fixture stocks or routes is evidence about a real stock market.

`state.json` records the Anvil process, its loopback port and the chain's genesis hash. Before
`fund`, `advance`, `migrate` or `stop` touches the endpoint, the controller proves the recorded
process is alive, is Anvil, is the one process listening on that port, and that the chain there
carries the recorded genesis hash and both launchpads; any mismatch refuses without acting.
