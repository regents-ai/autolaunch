# Autolaunch and the Continuous Clearing Auction

This page is for engineers who know Uniswap's Continuous Clearing Auction (CCA) and want to see how
Autolaunch uses it.

| Section | What it covers |
|---|---|
| [What is deployed](#what-is-deployed) | status of each launch type |
| [The contracts we wrote](#the-contracts-we-wrote) | every production Solidity file of ours |
| [Uniswap code, used unchanged](#uniswap-code-used-unchanged) | the pinned upstream revisions and the canonical CCA factory |
| [Stock routes](#stock-routes) | the retired and the current stock routes |
| [CCA parameters](#cca-parameters) | every CCA parameter, and whether our contracts fix it or the launcher chooses it |

For what each launch type does, and every deployed address, start with the
[contracts overview](README.md).

## What is deployed

| Launch type | Chain | Status |
|---|---|---|
| Revstake | Base | Deployed on 22 September 2026 and verified on Basescan. Launches paused until 24 September 2026, 15:00 UTC. [Addresses](README.md#base-8453-revstake) |
| Memestake | Base | Deployed on 23 September 2026 and verified on Basescan. Ten tokenised stocks admitted, each with an `AerodromeStockRouteV2` route. Launches paused until 24 September 2026, 15:00 UTC. [Addresses](README.md#base-8453-memestake) |
| Memestake | Robinhood Chain | Deployed on 23–24 September 2026: the launchpad graph and 25 `UniswapV3StockRouteV1` routes on Robinhood Chain, plus one receiver on Base. Launches paused until 24 September 2026, 15:00 UTC. [Addresses](robinhood/deployments/robinhood-mainnet/README.md) |

## The contracts we wrote

These are the production Solidity files we wrote. The list includes shared bases and libraries, and
leaves out interfaces, tests, fixtures and pinned upstream projects.

| Area | Contracts and supporting code |
|---|---|
| Base Revstake | [Factory](v1/src/factory/RegentsAutolaunchFactoryV1.sol), [CCA strategy](v1/src/strategy/RegentLBPStrategy.sol), [vesting escrow](v1/src/escrow/ConditionalVestingEscrowV1.sol), [fee hook](v1/src/hook/RegentFeeHook.sol), [staking splitter](v1/src/revenue/SubjectSplitterV1.sol), [LP locker](v1/src/revenue/RevstakeLPLocker.sol), [payment receiver](v1/src/revenue/PaymentReceiverV1.sol). Supporting code: [BaseBindings](v1/src/bindings/BaseBindings.sol), [FrozenIdentity](v1/src/bindings/FrozenIdentity.sol). |
| Base Memestake | [Launchpad](stocks/src/StocksLaunchpadV1.sol), [fee hook](stocks/src/StocksFeeHookV1.sol), [staking splitter](stocks/src/MemestockSplitterV1.sol), [LP locker](stocks/src/MemestockLPLocker.sol), [bid adapter](stocks/src/StockBidAdapterV1.sol), [Aerodrome stock route V2](stocks/src/routes/AerodromeStockRouteV2.sol). Supporting code: [splitter core](stocks/src/MemestockSplitterCore.sol), [preset](stocks/src/StocksPreset.sol), [bindings](stocks/src/StocksBindings.sol). |
| Robinhood Memestake | [Launchpad](robinhood/src/RobinhoodStocksLaunchpadV1.sol), [fee hook](robinhood/src/RobinhoodFeeHookV1.sol), [hook factory](robinhood/src/RobinhoodFeeHookFactory.sol), [staking splitter](robinhood/src/RobinhoodMemestockSplitterV1.sol), [bid adapter](robinhood/src/RobinhoodStockBidAdapterV1.sol), [Uniswap v3 stock route](robinhood/src/routes/UniswapV3StockRouteV1.sol), [protocol revenue inbox](robinhood/src/RobinhoodProtocolRevenueInboxV1.sol), [Base revenue receiver](robinhood/src/RobinhoodBaseRevenueReceiverV1.sol). Supporting code: [launchpad base](robinhood/src/RobinhoodLaunchpadBase.sol), [positions library](robinhood/src/libraries/RobinhoodPositionsLib.sol), [preset](robinhood/src/RobinhoodPreset.sol). |
| Revenue Mesh (experimental, not deployed) | [CCTP revenue inbox](revenue-mesh/src/CctpRevenueInboxV1.sol), [inbox factory](revenue-mesh/src/RevenueInboxFactoryV1.sol), [Arbitrum factory](revenue-mesh/src/chains/ArbitrumOneRevenueInboxFactoryV1.sol), and its [Base compatibility](revenue-mesh/src/libraries/BaseCompatibilityV1.sol), [types](revenue-mesh/src/libraries/RevenueMeshTypes.sol) and [token](revenue-mesh/src/libraries/SafeToken.sol) libraries. This is adjacent work, not part of the auction launch path. |

## Uniswap code, used unchanged

We pin these upstream revisions:

| Project | Revision |
|---|---|
| Continuous Clearing Auction | `7d7602d2`, one commit after v2.0.0 |
| Liquidity Launcher | v3.0.0 |
| UERC20 factory | v1.0.0 |

| Fact | Detail |
|---|---|
| Auction contract | Every launch creates an unmodified `ContinuousClearingAuction` through the canonical CCA factory. |
| CCA factory | [`0x000000001F26a0044BaA66024e7b6599c61963F8`](https://basescan.org/address/0x000000001F26a0044BaA66024e7b6599c61963F8), the same address on Base and Robinhood Chain |
| Protocol fee | Each launchpad refuses to create an auction unless the factory's `protocolFeeController()` is the zero address. |

## Stock routes

| Route | Chain | Status | Price control on `swapExactIn` | `quoteExactIn` |
|---|---|---|---|---|
| [`AerodromeStockRouteV1`](https://github.com/regents-ai/autolaunch/blob/8b3d0ebeba83ac93a42a90b5e24228da26b98e6a/contracts/stocks/src/routes/AerodromeStockRouteV1.sol) | Base | Retired. Its ten deployed instances were never admitted. | a 5% Chainlink check, plus the caller's `minAmountOut` | Chainlink price |
| [`AerodromeStockRouteV2`](stocks/src/routes/AerodromeStockRouteV2.sol) | Base | Current; admitted for ten stocks | the caller's `minAmountOut` only; the price feed is not read | Chainlink price; reverts on a stale or non-positive answer |
| [`UniswapV3StockRouteV1`](robinhood/src/routes/UniswapV3StockRouteV1.sol) | Robinhood Chain | Current; deployed for 25 stocks, awaiting admission by the Safe | the caller's `minAmountOut` only; the price feed is not read | Chainlink price; reverts on a stale or non-positive answer |

## CCA parameters

Every launch calls `ContinuousClearingAuctionFactory.create(token, amount,
abi.encode(AuctionParameters), salt)` on the canonical factory, using the pinned CCA `7d7602d2`.
After creating the auction, each launchpad reads back the auction's token, currency, supply and both
recipients and checks them.

### Fixed by our contracts (the launcher cannot change these)

| `create` / `AuctionParameters` field | Base Revstake | Base Memestake | Robinhood Memestake |
|---|---|---|---|
| `token` | new UERC20, 100B supply, 18 decimals | new UERC20, 1B supply, 18 decimals | same as Base Memestake |
| `amount` (auction supply) | 10B (10%) | 800M (80%) | 800M (80%) |
| Held outside the auction | 5% LP reserve in the strategy; 85% in a vesting escrow | 20% LP reserve in the launchpad | 20% LP reserve in the launchpad |
| `currency` | REGENT [`0x6f89bcA4eA5931EdFCB09786267b251DeE752b07`](https://basescan.org/address/0x6f89bcA4eA5931EdFCB09786267b251DeE752b07) | the admitted stock token | the admitted stock token |
| `tokensRecipient` | the launch's vesting escrow; unsold tokens vest to the treasury on success | the launchpad; unsold tokens go to the dead address | the launchpad; unsold tokens go to the dead address |
| `fundsRecipient` | the strategy, which pairs the raise into the v4 pool and sends leftover REGENT to the treasury | the launchpad; the whole raise is locked in the v4 pool | the launchpad; the whole raise is locked in the v4 pool |
| `startBlock` | creation block + 300 (about 10 min at 2 s blocks) | creation block + 300 (about 10 min) | creation block + 6,000 (about 10 min at 0.1 s blocks) |
| `endBlock` | start + 86,401 (about 48 h) | start + 43,200 (about 24 h) | start + 864,000 (about 24 h) |
| `claimBlock` | end + 64 | end + 64 | end + 1,280 |
| Migration (our rule, not a CCA field) | end + 128; anyone can call `migrate` | end + 128; anyone can call `migrate` | end + 2,560; anyone can call `migrate` |
| `floorPrice` | fixed at 0.001 REGENT per token (`FLOOR_PRICE_Q96`) | set by the launcher (see below) | set by the launcher (see below) |
| `tickSpacing` | fixed at 0.00001 REGENT per token, 1% of the floor (`BID_TICK_Q96`) | floor ÷ 100 | floor ÷ 100 |
| `validationHook` | `address(0)`: anyone may bid | `address(0)` | `address(0)` |
| `auctionStepsData` | 13 steps: twelve windows each release about 5.8%, then a final single block releases 29.88% | same shape scaled to 24 h: twelve windows of about 5.8%, final block 29.88% | Base Memestake schedule with block counts ×20 and rates ÷20, rounded: twelve windows of 5.4–6.2%, final block 29.31% |
| `salt` | `bytes32(launchId)` | `bytes32(launchId)` | `bytes32(launchId)` |

### Set by the launcher

| Input | Base Revstake | Base Memestake | Robinhood Memestake |
|---|---|---|---|
| `requiredCurrencyRaised` (minimum raise) | **Required.** Must be above zero and no more than the 10B supply can reach at the highest on-grid bid price the CCA admits (`MAX_REACHABLE_RAISE`). | **Required.** Same rule, computed from the chosen floor's tick grid. | **Required.** Same rule. |
| `floorPrice` | not settable | Chosen by the launcher. Must be at least the CCA's `MIN_FLOOR_PRICE` (2^32 + 1) and divisible by 100, and the resulting tick must be at least the CCA's `MIN_TICK_SPACING`. | Same rules |
| Auction currency | not settable (always REGENT) | one of the stocks the Safe has admitted | one of the stocks the Safe has admitted |
| Other | treasury address (screened against six shared-system addresses) | none | none |
| Token metadata (not CCA) | name, symbol, description, website, image | same | same |

### When the auction ends

Anyone may call `migrate` once the migration block is reached. It checkpoints the auction and
branches on `isGraduated()`.

| Outcome | What happens |
|---|---|
| Graduated | The raise is paired with the reserve at the final clearing price in a Uniswap v4 pool, and the liquidity is locked permanently in a fee-only locker. |
| Not graduated | Bidders refund directly from the CCA. The new token's supply is sent to the dead address. |

### Block clock

Every launchpad and the CCA both use `BlockNumberish`.

| Chain | Block number used | Block time | 10 minutes | 24 hours |
|---|---|---|---|---|
| Base | `block.number` | 2 s | 300 blocks | 43,200 blocks |
| Robinhood Chain | Arbitrum block number, read through ArbSys | 0.1 s | 6,000 blocks | 864,000 blocks |

This matters on Robinhood Chain. On Arbitrum-style chains, a contract's plain `block.number` returns
the Ethereum block number instead of the chain's own. Measured in Ethereum's 12-second blocks, every
Robinhood window would stretch about 120-fold. Because the launchpad and the CCA both read the
chain's own block counter, the 10-minute start and the 24-hour auction hold as stated.

## Source for these values

| Launch type | Parameter source | Full guide |
|---|---|---|
| Base Revstake | [strategy](v1/src/strategy/RegentLBPStrategy.sol), [factory](v1/src/factory/RegentsAutolaunchFactoryV1.sol) | [Revstake spec](v1/SPEC.md) |
| Base Memestake | [preset](stocks/src/StocksPreset.sol), [launchpad](stocks/src/StocksLaunchpadV1.sol) | [Base Memestake guide](stocks/README.md) |
| Robinhood Memestake | [preset](robinhood/src/RobinhoodPreset.sol), [launchpad base](robinhood/src/RobinhoodLaunchpadBase.sol) | [Robinhood guide](robinhood/README.md) |
