# Autolaunch and the Continuous Clearing Auction

This page is for engineers who know Uniswap's Continuous Clearing Auction (CCA) and want to see how
Autolaunch uses it for new v2 launches. Existing v1 auctions keep their original terms.
The [legacy packages](README.md#historical-v1-deployed-addresses) preserve their historical records.

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
| Revstake v2 | Base | Deployed 6 October 2026; open as checked on 9 October. [Receipts](revstake-v2/deployments/base-mainnet/README.md) |
| Memestake v2 | Base | Deployed and open as checked on 9 October 2026; ten admitted stocks. [Receipts](stocks-v2/deployments/base-mainnet/README.md) |
| Memestake v2 | Robinhood Chain | Deployed and open as checked on 9 October 2026; 25 admitted stocks. [Receipts](robinhood-v2/deployments/robinhood-mainnet/README.md) |

## The contracts we wrote

These are the production Solidity files we wrote. The list includes shared bases and libraries, and
leaves out interfaces, tests, fixtures and pinned upstream projects.

| Area | Contracts and supporting code |
|---|---|
| Base Revstake | [Factory](revstake-v2/src/factory/RegentsAutolaunchFactoryV2.sol), [CCA strategy](revstake-v2/src/strategy/RegentLBPStrategyV2.sol), [vesting escrow](revstake-v2/src/escrow/ConditionalVestingEscrowV2.sol), [fee hook](revstake-v2/src/hook/RegentFeeHook.sol), [staking splitter](revstake-v2/src/revenue/SubjectSplitterV1.sol), [LP locker](revstake-v2/src/revenue/RevstakeLPLocker.sol), [payment receiver](revstake-v2/src/revenue/PaymentReceiverV1.sol). Supporting code: [BaseBindings](revstake-v2/src/bindings/BaseBindings.sol). |
| Base Memestake | [Launchpad](stocks-v2/src/StocksLaunchpadV2.sol), [fee hook](stocks-v2/src/StocksFeeHookV1.sol), [staking splitter](stocks-v2/src/MemestockSplitterV1.sol), [LP locker](stocks-v2/src/MemestockLPLocker.sol), [bid adapter](stocks-v2/src/StockBidAdapterV1.sol), [Aerodrome stock route V2](stocks-v2/src/routes/AerodromeStockRouteV2.sol). Supporting code: [splitter core](stocks-v2/src/MemestockSplitterCore.sol), [preset](stocks-v2/src/StocksPreset.sol), [bindings](stocks-v2/src/StocksBindings.sol). |
| Robinhood Memestake | [Launchpad](robinhood-v2/src/RobinhoodStocksLaunchpadV2.sol), [fee hook](robinhood-v2/src/RobinhoodFeeHookV1.sol), [hook factory](robinhood-v2/src/RobinhoodFeeHookFactory.sol), [staking splitter](robinhood-v2/src/RobinhoodMemestockSplitterV1.sol), [bid adapter](robinhood-v2/src/RobinhoodStockBidAdapterV1.sol), [Uniswap v3 stock route](robinhood-v2/src/routes/UniswapV3StockRouteV1.sol), [protocol revenue inbox](robinhood-v2/src/RobinhoodProtocolRevenueInboxV1.sol), [Base revenue receiver](robinhood-v2/src/RobinhoodBaseRevenueReceiverV1.sol). Supporting code: [launchpad base](robinhood-v2/src/RobinhoodLaunchpadBase.sol), [positions library](robinhood-v2/src/libraries/RobinhoodPositionsLib.sol), [preset](robinhood-v2/src/RobinhoodPreset.sol). |
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
| [`AerodromeStockRouteV2`](stocks-v2/src/routes/AerodromeStockRouteV2.sol) | Base | Current; admitted for ten stocks | the caller's `minAmountOut` only; the price feed is not read | Chainlink price; reverts on a stale or non-positive answer |
| [`UniswapV3StockRouteV1`](robinhood-v2/src/routes/UniswapV3StockRouteV1.sol) | Robinhood Chain | Current; admitted for 25 stocks | the caller's `minAmountOut` only; the price feed is not read | Chainlink price; reverts on a stale or non-positive answer |

## CCA parameters

Every launch calls `ContinuousClearingAuctionFactory.create(token, amount,
abi.encode(AuctionParameters), salt)` on the canonical factory, using the pinned CCA `7d7602d2`.
After creating the auction, each launchpad reads back the auction's token, currency, supply and both
recipients and checks them.

### Fixed by our contracts (the launcher cannot change these)

| `create` / `AuctionParameters` field | Base Revstake | Base Memestake | Robinhood Memestake |
|---|---|---|---|
| `token` | new UERC20, 100B supply, 18 decimals | new UERC20, 1B supply, 18 decimals | same as Base Memestake |
| `amount` (auction supply) | 20B (20%) | 497.5M (49.75%) | 497.5M (49.75%) |
| Held outside the auction | 10% LP reserve in the strategy; 70% in a vesting escrow | 49.75% LP reserve and 0.5% creator vesting in the launchpad | same as Base Memestake |
| `currency` | REGENT [`0x6f89bcA4eA5931EdFCB09786267b251DeE752b07`](https://basescan.org/address/0x6f89bcA4eA5931EdFCB09786267b251DeE752b07) | the admitted stock token | the admitted stock token |
| `tokensRecipient` | the strategy; unsold rounding tokens pass to the treasury's vesting escrow on success | the launchpad; unsold tokens go to the dead address | the launchpad; unsold tokens go to the dead address |
| `fundsRecipient` | the strategy; half the raise budgets the v4 pool, and at least half reaches the treasury | the launchpad; the whole raise funds the locked v4 pool apart from stock rounding dust credited to the protocol fee lane | the launchpad; the whole raise funds the locked v4 pool apart from stock rounding dust credited to the protocol fee lane |
| `startBlock` | creation block + 300 (about 10 min at 2 s blocks) | creation block + 300 (about 10 min) | creation block + 6,000 (about 10 min at 0.1 s blocks) |
| `endBlock` | start + 86,401 (about 48 h) | start + 43,200 (about 24 h) | start + 864,000 (about 24 h) |
| `claimBlock` | end + 64 | end + 64 | end + 1,280 |
| Migration (our rule, not a CCA field) | end + 128; anyone can call `migrate` | end + 128; anyone can call `migrate` | end + 2,560; anyone can call `migrate` |
| `floorPrice` | fixed Q96 value 4,294,967,300 | same fixed Q96 value | same fixed Q96 value |
| `tickSpacing` | floor ÷ 100, Q96 value 42,949,673 | floor ÷ 100 | floor ÷ 100 |
| `validationHook` | `address(0)`: anyone may bid | `address(0)` | `address(0)` |
| `auctionStepsData` | 13 steps: twelve windows each release about 5.8%, then a final single block releases 29.88% | same shape scaled to 24 h: twelve windows of about 5.8%, final block 29.88% | Base Memestake schedule with block counts ×20 and rates ÷20, rounded: twelve windows of 5.4–6.2%, final block 29.31% |
| `salt` | `bytes32(launchId)` | `bytes32(launchId)` | `bytes32(launchId)` |

### Fixed minimum and launcher inputs

The minimum is `ceil(auctionSupply × floorPriceQ96 / 2^96)`: 1,084,202,174 REGENT base
units for Revstake and 26,969,530 stock base units for Memestake. The lowest permitted floor
is rounded up to the 100-tick grid. Neither value is chosen by the launcher. A bid submitted after the first auction block can be counted one currency base unit short
by CCA rounding on both launch types; the website asks for the minimum plus one unit.

| Input | Base Revstake | Base Memestake | Robinhood Memestake |
|---|---|---|---|
| Auction currency | fixed REGENT | one admitted stock | one admitted stock |
| Other | fixed treasury address | none | none |
| Token metadata (not CCA) | name, symbol, description, website, image | same | same |

### When the auction ends

Anyone may call `migrate` once the migration block is reached. It checkpoints the auction and
branches on `isGraduated()`.

| Outcome | What happens |
|---|---|
| Graduated | The sale allocation sells apart from rounding. Revstake pairs half the raise with reserve in one full-range position and vests unused tokens with the 70% treasury allocation over 365 days. Memestake pairs the stock raise with reserve in a full-range position and locks remaining reserve in a token-only position above the opening token price; the creator allocation vests over 30 days from graduation. Liquidity is locked permanently; Memestake rounding leftovers are retired. |
| Not graduated | Bidders refund directly from the CCA. The new token's whole supply, including the creator allocation, is sent to the dead address. ERC-20 total supply remains unchanged. |

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
| Base Revstake | [strategy](revstake-v2/src/strategy/RegentLBPStrategyV2.sol), [factory](revstake-v2/src/factory/RegentsAutolaunchFactoryV2.sol) | [Revstake spec](revstake-v2/README.md) |
| Base Memestake | [preset](stocks-v2/src/StocksPreset.sol), [launchpad](stocks-v2/src/StocksLaunchpadV2.sol) | [Base Memestake guide](stocks-v2/README.md) |
| Robinhood Memestake | [preset](robinhood-v2/src/RobinhoodPreset.sol), [launchpad base](robinhood-v2/src/RobinhoodLaunchpadBase.sol) | [Robinhood guide](robinhood-v2/README.md) |
