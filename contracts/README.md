# Autolaunch contracts

Autolaunch launches tokens through Uniswap's Continuous Clearing Auction (CCA). There are two
launch types: **Revstake** (an agent token auctioned for REGENT on Base) and **Memestake** (a new
token auctioned for one admitted tokenised stock, on Base and on Robinhood Chain). Every launch is
one unchanged CCA auction created through the canonical CCA factory; when the auction graduates,
our contracts sweep the raise, open the Uniswap v4 pool at the CCA's final price, lock the
liquidity forever in a fee-only locker, and route the pool's hook fees to a per-launch staking
splitter. When it does not graduate, the token supply is retired and bidders refund from the CCA.

Seven Foundry projects, one per directory. Each is built and verified from its own directory.

New launches use version 2. The four existing version 1 Memestake auctions remain supported;
keeping their bindings permits claims, withdrawals, staking and fee collection without reopening
the old launchpads. The legacy packages and deployment records below are historical.

| Current project | Chain | Deployment record | Verify |
| --- | --- | --- | --- |
| [revstake-v2/](revstake-v2/README.md) | Base (8453) | [Revstake v2 receipts](revstake-v2/deployments/base-mainnet/README.md) | `cd revstake-v2 && bin/gate.sh`, with `../stocks-v2/lib` in place |
| [stocks-v2/](stocks-v2/README.md) | Base (8453) | [Memestake v2 receipts](stocks-v2/deployments/base-mainnet/README.md) | `cd stocks-v2 && bin/gate.sh`, after `python3 bootstrap-deps.py <hydrated checkout>` |
| [robinhood-v2/](robinhood-v2/README.md) | Robinhood Chain (4663), receiver on Base | [Robinhood v2 receipts](robinhood-v2/deployments/robinhood-mainnet/README.md) | `cd robinhood-v2 && bin/gate.sh`, with `../stocks-v2/lib` in place |

For Uniswap CCA engineers, [CCA-INTEGRATION.md](CCA-INTEGRATION.md) lists every CCA parameter our
contracts set and every one the launcher chooses.

| Project | What it is | Chain | Status on 23 September 2026 | Verify |
| --- | --- | --- | --- | --- |
| [v1/](v1/README.md) | Base Revstake: agent tokens auctioned for REGENT, with a permanent fee-only LP locker, a shared fee hook, per-launch staking, payment receivers and a vesting escrow | Base (8453) | **Deployed** on Base on 22 September 2026 (eight contracts, verified on Basescan); launches open since 24 September 2026 | `cd v1 && bin/gate.sh`, offline, after the one-time setup in its README |
| [stocks/](stocks/README.md) | Base Memestake: a new token auctioned for one admitted tokenised stock, then locked into its stock pool with two stock-side fee lanes and per-launch staking | Base (8453) | **Deployed** on Base on 23 September 2026 (launchpad, bid adapter, hook, locker, splitter implementation); ten stocks admitted with `AerodromeStockRouteV2` routes and the hook executor set by the Safe; launches open since 24 September 2026 | `cd stocks && bin/gate.sh`, after `python3 bootstrap-deps.py <hydrated checkout>` has filled `lib/` |
| [robinhood/](robinhood/README.md) | Robinhood Memestake: the Memestake launchpad rebuilt for Robinhood Chain with USDG as the dollar, plus a Base-side receiver for bridged revenue | Robinhood Chain (4663), one contract on Base | **Deployed** on 23–24 September 2026 (launchpad graph, 25 `UniswapV3StockRouteV1` routes, the Base receiver; addresses in `robinhood/deployments/robinhood-mainnet/deployed-manifest.json`); no stock admitted yet; launches paused until the admin Safe admits the stocks and calls `unpauseLaunches()` | `cd robinhood && bin/gate.sh`, with `../stocks/lib` in place |
| [revenue-mesh/](revenue-mesh/README.md) | Immutable USDC payment routes over Circle CCTP from other chains into a Base `PaymentReceiverV1` | Source chains into Base | **Experimental.** Not deployed and not on the launch path | `cd revenue-mesh && forge fmt --check && forge build && forge test -vvv` |

The website's runtime copies of the ABIs and the chain manifest live in
[`platform/contracts/`](../platform/contracts/). They are consumers of this directory, not sources.

## What is upstream and what is ours

Upstream Uniswap code, pinned as Git submodules under `contracts/v1/lib/` (declared in the
repository's top-level `.gitmodules`) and not modified by us:

| Dependency | Pinned commit | Upstream tag |
| --- | --- | --- |
| `Uniswap/continuous-clearing-auction` | `7d7602d257733315434570f2a0c2f94f1c7b207a` | one commit after `v2.0.0` |
| `Uniswap/liquidity-launcher` | `3a3103543f50a13a0ae52a253bb98a925d72146f` | `v3.0.0` |
| `Uniswap/uerc20-factory` | `09ae130f7a10f7c1b96e0dc7d9724d567080c4ef` | `v1.0.0` |
| `foundry-rs/forge-std` | `3b20d60d14b343ee4f908cb8079495c07f5e8981` | `v1.9.6` |

`contracts/stocks/dependencies.json` pins the same three Uniswap revisions and their nested trees
(v4-core, v4-periphery, Permit2, OpenZeppelin, Solady, Solmate, BlockNumberish, Optimism) for the
Memestake projects. `v1/src/bindings/FrozenIdentity.sol` carries the three Uniswap commit hashes as
constants and the gates check them.

Every launch calls the canonical deployed CCA factory, `0x000000001F26a0044BaA66024e7b6599c61963F8`,
on both chains: on Base it is the `CCA_FACTORY` constant in `v1/src/bindings/BaseBindings.sol` and
`stocks/src/StocksBindings.sol` (runtime code hash
`0xa1d2a90564f4f63580b25de42efaff92505c254b00fc666f65ab38126cce5cfa`); on Robinhood Chain it is
the `ccaFactory` constructor binding recorded in the approved packet, at the same address. Each
launchpad refuses to create an auction unless that factory's `protocolFeeController()` is the zero
address, so no protocol fee is ever taken from a raise. The auction contracts themselves are
upstream `ContinuousClearingAuction` instances created by `ContinuousClearingAuctionFactory.create`;
we never deploy a modified auction.

Ours (this repository):

- **Base Revstake** (`v1/src`): `RegentsAutolaunchFactoryV1`, `RegentLBPStrategy` (a hard-cut fork
  of the Liquidity Launcher's `LBPStrategy` with every configurable input removed; the CCA creation,
  final-price conversion through `TokenPricing` and the `PositionPlanner` plan are the upstream
  technique), `RegentFeeHook`, `RevstakeLPLocker`, `SubjectSplitterV1`, `PaymentReceiverV1`,
  `ConditionalVestingEscrowV1`.
- **Base Memestake** (`stocks/src`): `StocksLaunchpadV1`, `StocksFeeHookV1`, `MemestockLPLocker`,
  `MemestockSplitterV1` over `MemestockSplitterCore`, `StockBidAdapterV1`,
  `routes/AerodromeStockRouteV2`.
- **Robinhood Memestake** (`robinhood/src`): `RobinhoodStocksLaunchpadV1` over
  `RobinhoodLaunchpadBase`, `RobinhoodFeeHookV1` and `RobinhoodFeeHookFactory`,
  `RobinhoodMemestockSplitterV1`, `RobinhoodStockBidAdapterV1`, `RobinhoodProtocolRevenueInboxV1`,
  `RobinhoodBaseRevenueReceiverV1`, `RobinhoodPositionsLib`, `routes/UniswapV3StockRouteV1`.
- **Revenue Mesh** (`revenue-mesh/src`): experimental CCTP payment routes, not deployed.

## Historical v1 deployed addresses

### Base (8453): Revstake

Deployed 22 September 2026 by deployer `0x9b2C414614aEE294202c1219520955EF3B596031`, nonces 0–4,
packet digest `0x5ba245ed0af9de1c1749f0b50cd54919a8084faf580d92282ef0592144f35327`. Record:
[v1/deployments/base-mainnet/](v1/deployments/base-mainnet/README.md). `launchesPaused()` read
`false` at Base block 51,875,928 (27 September 2026). This is a historical reading;
the v1 factory is now paused for new launches, as checked on 9 October 2026.

| Contract | Address |
| --- | --- |
| UERC20Factory (upstream, our deployment) | [`0x90bA0ef13f7791Dd308bD3e10cd6aD755840d563`](https://basescan.org/address/0x90bA0ef13f7791Dd308bD3e10cd6aD755840d563) |
| ConditionalVestingEscrowV1 (implementation) | [`0xAFa68eEFd0b9c02Be2BC2306AEe50CDE4BC2133d`](https://basescan.org/address/0xAFa68eEFd0b9c02Be2BC2306AEe50CDE4BC2133d) |
| SubjectSplitterV1 (implementation) | [`0x777b2e0F3c7787DA781c3948651249C2C822e9C3`](https://basescan.org/address/0x777b2e0F3c7787DA781c3948651249C2C822e9C3) |
| PaymentReceiverV1 (implementation) | [`0x34636E5Cd649C1BBda2b63676c76F66E60bAe5E2`](https://basescan.org/address/0x34636E5Cd649C1BBda2b63676c76F66E60bAe5E2) |
| RegentsAutolaunchFactoryV1 | [`0x635615cCEF2Ef24D0655fC2eBC47a14e005FEF6e`](https://basescan.org/address/0x635615cCEF2Ef24D0655fC2eBC47a14e005FEF6e) |
| RegentLBPStrategy | [`0x69c13CCd9312e21d66fd162896E39bFC5f886F95`](https://basescan.org/address/0x69c13CCd9312e21d66fd162896E39bFC5f886F95) |
| RevstakeLPLocker | [`0xBdC4b69bfd66aCDb8b794bADbEf3a50a14891159`](https://basescan.org/address/0xBdC4b69bfd66aCDb8b794bADbEf3a50a14891159) |
| RegentFeeHook | [`0x1F4E9AD63d95531d44eC90A700F21F0bBD40e044`](https://basescan.org/address/0x1F4E9AD63d95531d44eC90A700F21F0bBD40e044) |

### Base (8453): Memestake

Deployed 23 September 2026 by the same deployer, nonces 5–16, packet digest
`0x26c7cb27f97e35915c27e9ede752c8dc63c6268a5b8ef1b6b0852eacb4f847a5`. Record:
[stocks/deployments/base-mainnet/](stocks/deployments/base-mainnet/README.md). `launchesPaused()`
read `false` at Base block 51,875,928 (27 September 2026). That reading is historical; new v1 launches are now paused. `executor()` on the hook reads `0x72E2FB09147d3E6E5c9F44A4E127E6321e022045`.

| Contract | Address |
| --- | --- |
| StocksLaunchpadV1 | [`0x1d36a95112835f81b1B499A808e556020C64Cac2`](https://basescan.org/address/0x1d36a95112835f81b1B499A808e556020C64Cac2) |
| StockBidAdapterV1 | [`0xd28e66967C1fE651e6EC47f13397a74240C064A2`](https://basescan.org/address/0xd28e66967C1fE651e6EC47f13397a74240C064A2) |
| StocksFeeHookV1 | [`0x3820CD7413BC2EF795229C39C648326D99c8e0cC`](https://basescan.org/address/0x3820CD7413BC2EF795229C39C648326D99c8e0cC) |
| MemestockLPLocker | [`0x9e8B5EDdfC2aCdfc600FB37FBDc070c0Cd0033d7`](https://basescan.org/address/0x9e8B5EDdfC2aCdfc600FB37FBDc070c0Cd0033d7) |
| MemestockSplitterV1 (implementation) | [`0x657e75434CED9dFa5397c7cE4d96da238923a452`](https://basescan.org/address/0x657e75434CED9dFa5397c7cE4d96da238923a452) |

The ten admitted stocks and their `AerodromeStockRouteV2` routes. The Base Safe admitted all ten in
transaction
[`0x97030521eac9d0eace8f53d1bcb5f42ef3527cabb712d73228bfe4fc8617fbd6`](https://basescan.org/tx/0x97030521eac9d0eace8f53d1bcb5f42ef3527cabb712d73228bfe4fc8617fbd6)
(block 51698209). `stockAdmission(stock)` on the launchpad returns each route below; each route's
`stock()` returns its stock.

| Stock | Stock token | AerodromeStockRouteV2 |
| --- | --- | --- |
| AAPLc | `0xb200000000000000000000C2e324d24d7eEcd1fb` | [`0x547F3b931EaF75bAb98364aB396058ddc2E68e4a`](https://basescan.org/address/0x547F3b931EaF75bAb98364aB396058ddc2E68e4a) |
| AMZNc | `0xb200000000000000000000d9192b6B456483C2E8` | [`0xa851eb9bb6455b3C243B7ad0a3bAF026C76b2F4e`](https://basescan.org/address/0xa851eb9bb6455b3C243B7ad0a3bAF026C76b2F4e) |
| GOOGLc | `0xb2000000000000000000002D0BA3164cc74f58B7` | [`0x33102EfaE7846b8B23199394c8e04b4Fbe760585`](https://basescan.org/address/0x33102EfaE7846b8B23199394c8e04b4Fbe760585) |
| METAc | `0xb2000000000000000000008bC8786B856E61707C` | [`0x2fFb4E5243DBE074a80221A671a940A34347624a`](https://basescan.org/address/0x2fFb4E5243DBE074a80221A671a940A34347624a) |
| MSFTc | `0xB200000000000000000000Ab99cFa739E253872B` | [`0xb0214E19c899b95D4CDb9054f5C2DC9a26a1a53b`](https://basescan.org/address/0xb0214E19c899b95D4CDb9054f5C2DC9a26a1a53b) |
| MSTRc | `0xb2000000000000000000004884b426556b92883d` | [`0x9Bf555a848b11b19c248A137B828877BcADFd3C3`](https://basescan.org/address/0x9Bf555a848b11b19c248A137B828877BcADFd3C3) |
| NVDAc | `0xb20000000000000000000078ee7ce2fE4908108C` | [`0xFc783A3cfACb4Af476d55b292107AEe3A23726eF`](https://basescan.org/address/0xFc783A3cfACb4Af476d55b292107AEe3A23726eF) |
| SNDKc | `0xb200000000000000000000397293Cb8cda9a10c5` | [`0x51B6f1AdE5568701b67947dd69B07F6e2c8C1Ea9`](https://basescan.org/address/0x51B6f1AdE5568701b67947dd69B07F6e2c8C1Ea9) |
| SPCXc | `0xb2000000000000000000007b9fcbd005511aCBd5` | [`0x89B9f6D4408a88958eC3268D93b68e748Ab82EC3`](https://basescan.org/address/0x89B9f6D4408a88958eC3268D93b68e748Ab82EC3) |
| TSLAc | `0xb2000000000000000000001e800a7f5189430cD0` | [`0xD0C568fd5A45959da9B0bD7C002a973c845231E7`](https://basescan.org/address/0xD0C568fd5A45959da9B0bD7C002a973c845231E7) |

The ten `AerodromeStockRouteV1` routes the Memestake ceremony created (nonces 7–16) were never
admitted and are retired; they stay on chain unused. Their 5% Chainlink guard on execution was
removed by founder decision before any admission. `AerodromeStockRouteV2` has no execution guard:
`swapExactIn` never reads the price feed and the caller's `minAmountOut` is the only price control;
`quoteExactIn` returns the Chainlink price and reverts on a stale (older than 7 days) or
non-positive answer.

### Robinhood Chain (4663): Memestake

Deployed on 23–24 September 2026 from packet digest
`0x410d7a8a45b9b2e31ab0d96a74b56df1750f7cb66d9730d2a1e7d6cdfa8eb811`. Every address, block and
transaction is in [robinhood/deployments/robinhood-mainnet/](robinhood/deployments/robinhood-mainnet/README.md)
and its `deployed-manifest.json`; the 25 routes are listed there by stock.

| Contract | Chain | Address |
| --- | --- | --- |
| `RobinhoodStocksLaunchpadV1` | Robinhood Chain | `0x635615cCEF2Ef24D0655fC2eBC47a14e005FEF6e` |
| `RobinhoodFeeHookV1` | Robinhood Chain | `0xea3Bea7E546CB12aBf6eCB168Cb4bb17fc9A60CC` |
| `RobinhoodStockBidAdapterV1` | Robinhood Chain | `0x1d36a95112835f81b1B499A808e556020C64Cac2` |
| `RobinhoodProtocolRevenueInboxV1` | Robinhood Chain | `0xAFa68eEFd0b9c02Be2BC2306AEe50CDE4BC2133d` |
| `UERC20Factory` | Robinhood Chain | `0x90bA0ef13f7791Dd308bD3e10cd6aD755840d563` |
| `RobinhoodBaseRevenueReceiverV1` | Base | `0xbF73B915Baf7EBbbBA26cf51eEb64a6A23c81481` |

At the original September deployment, the launchpad was paused and no stock was admitted. The original switch-on procedure was for the admin Safe to name the inbox's Base
destination, admits each stock with its route, names the hook executor, then unpauses launches.

## Current v2 launch mechanics

**Base Revstake** (`revstake-v2/src`). A 100 billion token supply is divided into a 20%
auction, a 10% liquidity reserve and a 70% treasury allocation. The fixed minimum covers the
whole sale at the fixed floor, rounded up. Graduation sells that allocation apart from rounding,
opens a full-range REGENT/token position at the final clearing price and locks it forever.
Half the raise funds liquidity; at least half reaches the treasury. The 70% and unused token
inventory vest to the treasury over 365 days from graduation. The 3% hook fee sends 1% to
REGENT staking when collected in REGENT, or to the Regent Safe when collected in the launch
token, and 2% to the launch's revenue splitter. LP fees enter that same splitter.

**Base Memestake** (`stocks-v2/src`). A 1 billion token supply is divided into a 49.75%
auction, a 49.75% liquidity reserve and a 0.5% creator allocation. The minimum and floor are
fixed. Graduation sells the auction allocation apart from rounding. All raised stock, apart
from rounding dust sent to the protocol fee bucket, funds a full-range position with the new
tokens it needs. Remaining reserve funds a new-token-only position above the opening token
price. Both positions are locked forever. The creator allocation vests over 30 days from
graduation; other remaining new tokens are retired to the dead address. The 4.3% gross stock-side
hook fee accrues 0.3% for the original creator, 1% for the protocol and 3% for the staking
splitter. Creator and staker settlement are permissionless; protocol settlement is executor-only
and converts stock to USDC for live REGENT staking. The separate LP fee is 0.30%.

**Robinhood Memestake** (`robinhood-v2/src`) uses the same allocation, vesting, liquidity and
hook rates. Bidders may use USDG through the adapter. Protocol stock fees convert to USDG and
stop in the protocol revenue inbox. Across was chosen for the bridge to Base, but the bridge
is not built; protocol USDG stays in the inbox until it is configured.

**Shared accounting.** The CCA and UERC20 factory are unchanged. A failed auction refunds
bidders in full and retires all new tokens, including any creator allocation, to the dead address.
Retirement does not reduce ERC-20 total supply. Splitters deduct 2% of recognized revenue before
the remainder is allocated under their staking rules. Revstake pays stakers according to their
share of total supply and sends the unstaked portion to the treasury. Memestake distributes the
remainder among current stakers, or sends it to the protocol route when nobody is staked.

**Dependencies.** `stocks-v2/` exports pinned revisions into its ignored `lib/` with
`bootstrap-deps.py`; `revstake-v2/` and `robinhood-v2/` resolve libraries from
`../stocks-v2/lib`. Legacy packages retain their own dependencies and records. No v1 source
is changed by the v2 release. `revenue-mesh/` remains experimental and outside the launch path.

## Historical v1 deployment state and order

Every project keeps two files apart: a **packet** (`mainnet-no-go-packet.json`), the proposal that
describes what a ceremony would do and the only committed ceremony authority, and a **deployed
manifest** (`deployed-manifest.json`), the record of what was actually created, populated only from
confirmed receipts. The v1 and Base Memestake manifests record the Base deployments; the Robinhood
manifest records the Robinhood deployment. The founder signs and sends every creation by
hand; no key, endpoint or credential appears in this repository.

1. **Base Revstake first** ([v1/deployments/base-mainnet/](v1/deployments/base-mainnet/README.md)).
   Five zero-value creations from one dedicated deployer, in order: `UERC20Factory`,
   `ConditionalVestingEscrowV1`, `SubjectSplitterV1`, `PaymentReceiverV1` and
   `RegentsAutolaunchFactoryV1`, whose constructor creates `RegentLBPStrategy`, which creates
   `RevstakeLPLocker`, and mines `RegentFeeHook` with the pinned salt: eight contracts in all. The
   packet names the deployer, its starting nonce (0), the hook salt and the eight predicted
   addresses, and records the external state observed at Base block 51657720; it was rendered
   offline, prepared and rehearsed against a read-only Base fork with nothing broadcast. The founder
   approved its digest, `0x5ba245ed0af9de1c1749f0b50cd54919a8084faf580d92282ef0592144f35327`, and
   sent the five creations on 22 September 2026 (Base blocks 51660956–51661052);
   `bin/ceremony.py record` proved the receipts against the packet and wrote the deployed manifest,
   and `bin/ceremony.py site-config` renders the website's deployment file from it. The factory was
   born paused; the Governance and Regent Safe's `unpauseLaunches()` opened it, and launches have
   been open since 24 September 2026.
2. **Base Memestake next** ([stocks/deployments/base-mainnet/](stocks/deployments/base-mainnet/README.md)).
   Twelve zero-value creations from the same deployer (nonces 5–16): `StocksLaunchpadV1` (creating
   its splitter implementation, `MemestockLPLocker` and `StocksFeeHookV1`), `StockBidAdapterV1`, and
   ten `AerodromeStockRouteV1` routes that were later retired unadmitted. `bin/ceremony.py rehearse`
   simulated the exact transactions in order on a Base node, since Base's stock tokens run only
   there. The founder approved digest `0x26c7cb27f97e35915c27e9ede752c8dc63c6268a5b8ef1b6b0852eacb4f847a5` and sent the twelve on
   23 September 2026 (Base blocks 51673079–51673339); `record` proved the
   receipts and wrote the deployed manifest. On the same day ten `AerodromeStockRouteV2` routes
   were created by hand from the deployer, the Safe admitted each stock with its V2 route in one
   transaction (block 51698209), and the hook's `executor()` now reads the account the Safe named.
   The Safe's `unpauseLaunches()` opened the launchpad at website activation; launches have been
   open since 24 September 2026.
3. **Robinhood as its own track** ([robinhood/deployments/robinhood-mainnet/](robinhood/deployments/robinhood-mainnet/README.md)).
   Six creations on Robinhood Chain (`UERC20Factory`, the revenue inbox, the positions library,
   the hook factory, the launchpad and the bid adapter), 25 `UniswapV3StockRouteV1` routes, and
   one creation on Base (the revenue receiver). The founder approved digest
   `0x410d7a8a45b9b2e31ab0d96a74b56df1750f7cb66d9730d2a1e7d6cdfa8eb811` and sent the 32 creations on
   23–24 September 2026 (Robinhood Chain blocks 70983138–71059634, Base block 51716506); `record`
   proved the receipts and wrote the deployed manifest. The Safe then admits each stock with its
   route, names the hook executor and unpauses the launchpad. The bridge adapter the inbox needs to move USDG to Base is not built.

The revenue mesh has no deployment script and no production address.

## Decisions in force

- **No launch fee**, on any launch type (founder decision, 21–22 September 2026). A launch costs
  only gas. The Revstake factory moves no REGENT and takes no allowance; the Base Memestake
  launchpad pulls no REGENT and never holds it; the Robinhood launchpad pulls no USDG.
- **The launcher chooses the required raise.** Every launchpad admits any raise above zero that the
  fixed inventory can reach at the highest bid price, and there is no governance minimum.
- **Every auction opens on a fixed clock**: 300 blocks after the launch on Base, 6,000 blocks on
  Robinhood Chain (the Base schedule times twenty for 0.1-second blocks). The launcher does not
  choose it.
- **Memestake preset accepted** (9 September 2026): the fixed terms in `StocksPreset.sol` stand, on
  the basis that their 13-step schedule leaves about 30% of the auction inventory for the final
  block, as the Revstake schedule does (29.88% on Base). `stocks/README.md` marks each of them
  "Founder decision 2026-09-09".
- **Stock routes carry no execution guard** (founder decision, 23 September 2026). On both chains
  `swapExactIn` never reads the Chainlink feed; the caller's minimum out is the only price control
  (the hook executor's when settling a lane, the bidder's when bidding through a bid adapter).
  `quoteExactIn` reads the feed and refuses a stale or non-positive answer; the website offers
  bidders a minimum at 95% of that quote.
- **Hook permissions.** The Memestake hooks declare `beforeInitialize`, `beforeSwap`, `afterSwap`
  and both swap return deltas, so the stock is charged on every swap form. Both lanes are always
  on; the staker lane and the locker's `collect` need no authority, the REGENT (Base) or protocol
  (Robinhood) lane is settled only by the executor the Safe names, with a minimum out.
- **Listing.** The website lists Base launches it verified itself from its accounts' wallets;
  anything else on a launchpad is not listed. Robinhood launches are read from the launchpad
  directly, so every launch there is listed.
- **Revstake is Base-only; Robinhood is Memestake-only** (founder decision, 18 September 2026).
- **Robinhood's staking exit rule reads the Ethereum block** the rollup last observed, so a staker
  waits about twelve seconds after staking before claiming or unstaking (kept as is, 21 September
  2026).
