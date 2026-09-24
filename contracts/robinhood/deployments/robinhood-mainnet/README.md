# Robinhood Chain: the Memestake ceremony

**Deployed on 23–24 September 2026.** The founder approved packet digest
`0x410d7a8a45b9b2e31ab0d96a74b56df1750f7cb66d9730d2a1e7d6cdfa8eb811` and sent its 32 creations from
deployer `0x9b2C414614aEE294202c1219520955EF3B596031`: nonces 0–30 on Robinhood Chain (blocks
70983138–71059634) and nonce 27 on Base (block 51716506). `deployed-manifest.json` records them.
The launchpad was born paused. No stock is admitted, the inbox names no Base destination and the
hook names no executor until the admin Safe
(`0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`) runs its session; no launch is admitted until the
Safe calls `unpauseLaunches()`.

The Base receiver and the TSLA route share an address on two different chains: both are the
deployer's nonce 27.

| Contract | Chain | Address | Block |
| --- | --- | --- | --- |
| UERC20Factory | Robinhood | `0x90bA0ef13f7791Dd308bD3e10cd6aD755840d563` | 70983138 |
| RobinhoodProtocolRevenueInboxV1 | Robinhood | `0xAFa68eEFd0b9c02Be2BC2306AEe50CDE4BC2133d` | 70983280 |
| RobinhoodPositionsLib | Robinhood | `0x777b2e0F3c7787DA781c3948651249C2C822e9C3` | 70983380 |
| RobinhoodFeeHookFactory | Robinhood | `0x34636E5Cd649C1BBda2b63676c76F66E60bAe5E2` | 70983504 |
| RobinhoodStocksLaunchpadV1 | Robinhood | `0x635615cCEF2Ef24D0655fC2eBC47a14e005FEF6e` | 70983596 |
| RobinhoodStockBidAdapterV1 | Robinhood | `0x1d36a95112835f81b1B499A808e556020C64Cac2` | 70983696 |
| UniswapV3StockRouteV1 (AAPL) | Robinhood | `0xd28e66967C1fE651e6EC47f13397a74240C064A2` | 71059231 |
| UniswapV3StockRouteV1 (AMD) | Robinhood | `0xb4d24085bc5bd35C06b97f500e1019E8fD9d8e41` | 71059300 |
| UniswapV3StockRouteV1 (AMZN) | Robinhood | `0x740D2e1978991cdC0594D3a5F69B04C9148B2581` | 71059404 |
| UniswapV3StockRouteV1 (BABA) | Robinhood | `0xF26A18A009362695d00043eb63F7AB42B2170CA9` | 71059418 |
| UniswapV3StockRouteV1 (CRCL) | Robinhood | `0x6943c568549CEAb04EA07Ca9Cdb58a47165D3d27` | 71059438 |
| UniswapV3StockRouteV1 (DELL) | Robinhood | `0xdBBaA710EfddDe431027eBBa81b8c517e46544Df` | 71059449 |
| UniswapV3StockRouteV1 (GME) | Robinhood | `0xfE93FA01615d25DBeA7c2Ee8118A9988802DBF82` | 71059460 |
| UniswapV3StockRouteV1 (GOOGL) | Robinhood | `0x49E0995070753fA58152889829249febcF9E0C53` | 71059472 |
| UniswapV3StockRouteV1 (INTC) | Robinhood | `0xfFf81E528935FaEf2dd64087bc0b3740f7908a60` | 71059487 |
| UniswapV3StockRouteV1 (META) | Robinhood | `0xACfa95f1c16eF61C281C26511556Bf918814151F` | 71059497 |
| UniswapV3StockRouteV1 (MSFT) | Robinhood | `0xa39c8E7e26Ef5e66785a405a277B930e48e6Afb7` | 71059507 |
| UniswapV3StockRouteV1 (MSTR) | Robinhood | `0x547F3b931EaF75bAb98364aB396058ddc2E68e4a` | 71059518 |
| UniswapV3StockRouteV1 (MU) | Robinhood | `0xa851eb9bb6455b3C243B7ad0a3bAF026C76b2F4e` | 71059527 |
| UniswapV3StockRouteV1 (NVDA) | Robinhood | `0x33102EfaE7846b8B23199394c8e04b4Fbe760585` | 71059537 |
| UniswapV3StockRouteV1 (PLTR) | Robinhood | `0x2fFb4E5243DBE074a80221A671a940A34347624a` | 71059547 |
| UniswapV3StockRouteV1 (QQQ) | Robinhood | `0xb0214E19c899b95D4CDb9054f5C2DC9a26a1a53b` | 71059556 |
| UniswapV3StockRouteV1 (SGOV) | Robinhood | `0x9Bf555a848b11b19c248A137B828877BcADFd3C3` | 71059563 |
| UniswapV3StockRouteV1 (SLV) | Robinhood | `0xFc783A3cfACb4Af476d55b292107AEe3A23726eF` | 71059572 |
| UniswapV3StockRouteV1 (SNDK) | Robinhood | `0x51B6f1AdE5568701b67947dd69B07F6e2c8C1Ea9` | 71059581 |
| UniswapV3StockRouteV1 (SPCX) | Robinhood | `0x89B9f6D4408a88958eC3268D93b68e748Ab82EC3` | 71059590 |
| UniswapV3StockRouteV1 (SPY) | Robinhood | `0xD0C568fd5A45959da9B0bD7C002a973c845231E7` | 71059599 |
| UniswapV3StockRouteV1 (TSLA) | Robinhood | `0xbF73B915Baf7EBbbBA26cf51eEb64a6A23c81481` | 71059608 |
| UniswapV3StockRouteV1 (TSM) | Robinhood | `0x4c003500c6a28826d15A6E4cF023C1f1ecd41E08` | 71059617 |
| UniswapV3StockRouteV1 (USAR) | Robinhood | `0x8F511153393429468C3861E7cC5341Abb3310871` | 71059626 |
| UniswapV3StockRouteV1 (USO) | Robinhood | `0x0886e34742B5E5ab8e07B0A6C3fC66A7912DE942` | 71059634 |
| RobinhoodBaseRevenueReceiverV1 | Base | `0xbF73B915Baf7EBbbBA26cf51eEb64a6A23c81481` | 51716506 |
| RobinhoodFeeHookV1 (created by the launchpad) | Robinhood | `0xea3Bea7E546CB12aBf6eCB168Cb4bb17fc9A60CC` | 70983596 |
| RobinhoodMemestockSplitterV1 (created by the launchpad) | Robinhood | `0x69c13CCd9312e21d66fd162896E39bFC5f886F95` | 70983596 |
| MemestockLPLocker (created by the launchpad) | Robinhood | `0x849Fdcc586d6220d2763589170d7490142e87f88` | 70983596 |

| Chain | Nonce | Creation | Transaction |
| --- | --- | --- | --- |
| Robinhood | 0 | UERC20Factory | `0x666f052d9e5d232d0165391e0356178e63544f277246f6a9d5b05ada32f007f6` |
| Robinhood | 1 | RobinhoodProtocolRevenueInboxV1 | `0xb09683f4a74734df2e0e95036dbe15c2a027d342f6f9db46e6246bed4d9c5eaf` |
| Robinhood | 2 | RobinhoodPositionsLib | `0xf9a6ff1166abbeaa64f1e99de7b62145073e03d2bacc023b62f81c8de3690239` |
| Robinhood | 3 | RobinhoodFeeHookFactory | `0x7ae89ebd0ac0d5a0bb31729983c8d07ed0775551886a9cc83b51438cbbc7740f` |
| Robinhood | 4 | RobinhoodStocksLaunchpadV1 | `0x6f70df59e59bf0e7861b768180f377d32bf290797c078eefca5660ab9b1863b4` |
| Robinhood | 5 | RobinhoodStockBidAdapterV1 | `0x41c969e924e21a496213317a3fb7aaad65df2d394a7ed340eb030fab9c0d2b37` |
| Robinhood | 6 | UniswapV3StockRouteV1 (AAPL) | `0x4a44a8094690c42e88326142cde39f85b6b297abc8b28bb297aa8cecb24633af` |
| Robinhood | 7 | UniswapV3StockRouteV1 (AMD) | `0xe66e6fa0f6130f1034e931c14a7c162d732785de202c678a21069afd885a3223` |
| Robinhood | 8 | UniswapV3StockRouteV1 (AMZN) | `0xcc07e240ef5b3c0b8b4fb8e9087a8ffc2c760fba406401a8049f414f6685e205` |
| Robinhood | 9 | UniswapV3StockRouteV1 (BABA) | `0xeb5a724080ee5c3b10ae4cf64cfff9b49bde9aba3da661d7585632535e11a087` |
| Robinhood | 10 | UniswapV3StockRouteV1 (CRCL) | `0x40caa378bd06493f17eef12c1704252c20562e2740c51c9f1ab6313c74537030` |
| Robinhood | 11 | UniswapV3StockRouteV1 (DELL) | `0xf0e18b5355655c5a737fcc0bce45ebfe69522124f7871a3e6254c248d21897db` |
| Robinhood | 12 | UniswapV3StockRouteV1 (GME) | `0x4b641095ccff61224fb6deb1cb01eb3282076caef688b0fbf173c69ba3f8770b` |
| Robinhood | 13 | UniswapV3StockRouteV1 (GOOGL) | `0xa114b2e51bd810ea669a04a403242027629a9a57e6d651fc58d2d6802728b98b` |
| Robinhood | 14 | UniswapV3StockRouteV1 (INTC) | `0x45ca48a470cbb091e398a87828837791e99c9a16cd3383e2b112123a4c68762f` |
| Robinhood | 15 | UniswapV3StockRouteV1 (META) | `0xd28c3129249b848b98601bee981076403053633048664347106f247149bd040c` |
| Robinhood | 16 | UniswapV3StockRouteV1 (MSFT) | `0xcf0e074945b884406100c868c773f1c3818ba5897aed227e3c939d422d35da8e` |
| Robinhood | 17 | UniswapV3StockRouteV1 (MSTR) | `0x16263425344ee857236fafdb63c45fe8eba7cb381fd800f1721071b2b11b7e46` |
| Robinhood | 18 | UniswapV3StockRouteV1 (MU) | `0xd6feec606b6b93663728efb968f6c9970717ddca6b0678d7f95303901e0982b6` |
| Robinhood | 19 | UniswapV3StockRouteV1 (NVDA) | `0x592733a93dfe2c0d020579035a34bdb4267160e8a47549c098ce3398c7070351` |
| Robinhood | 20 | UniswapV3StockRouteV1 (PLTR) | `0xe8f5f63612d4cf5e91c1fb60c200e39ed6504a954bd077cda67e1ae69abc7fc1` |
| Robinhood | 21 | UniswapV3StockRouteV1 (QQQ) | `0x48a82a412ce6e578af7a2dc2e2e60bc6f58a8c5b9c274e8d07b653b9c92255b0` |
| Robinhood | 22 | UniswapV3StockRouteV1 (SGOV) | `0xbb79e004254b40a48280a272456ba7d3d6bd2a884171720efb83fd7f9851bbf5` |
| Robinhood | 23 | UniswapV3StockRouteV1 (SLV) | `0x2df008bbda7497b6cbf7e9645296889a6e9067066155c7ef5bd873c0f343e038` |
| Robinhood | 24 | UniswapV3StockRouteV1 (SNDK) | `0x0bcc6ff5f9a79ddd9cdcc0b42437f9929de5b859b3d93c19197250b3afc0ec48` |
| Robinhood | 25 | UniswapV3StockRouteV1 (SPCX) | `0x239a19585c4661940e74eae08855f5cb25c152b8ef7ea5464aa6309fa09563bf` |
| Robinhood | 26 | UniswapV3StockRouteV1 (SPY) | `0xe0dfc5462d4d8a7f35fc0946efe156c348c13f935d09966c4810f83eb578d39f` |
| Robinhood | 27 | UniswapV3StockRouteV1 (TSLA) | `0x916f75c69ef0a9a68df3e6b25d3230dd687fc2b4e8780b7bb334faf9e21cbcf4` |
| Robinhood | 28 | UniswapV3StockRouteV1 (TSM) | `0x12ff015a2e452b9ab7b2df355914df013e5928f282afcd7f3bfe5e58a7bd388a` |
| Robinhood | 29 | UniswapV3StockRouteV1 (USAR) | `0xf73d5acf2fd35d7ac1c0d7cf7116fd5e124241228021f300a09cc3a12afbca8f` |
| Robinhood | 30 | UniswapV3StockRouteV1 (USO) | `0xd8e242c501f7a9c1dded5fd60c6a33edc633fc8776463ecada57e7d079a307ff` |
| Base | 27 | RobinhoodBaseRevenueReceiverV1 | `0x0895f9ad5ed617267275e68f5ddeaea1bbe01c560cdb2654eda9a25e80c1e348` |

Two files live in this directory, and keeping them apart is the point.

- `mainnet-no-go-packet.json` is a **proposal**, and the sole committed ceremony authority. It
  carries the frozen code identity of every contract the ceremony creates, the build that produced
  it, the `src/` trees it was rendered from (this package's and the shared Base package's), and,
  once `../stocks/bin/ceremony.py prepare` has run for the founder's selection and a human has
  installed its candidate, the deployer, its starting nonce on each chain, the mined hook salt, the
  six external bindings, the admitted stocks with their pools and feeds, every predicted address on
  both chains, the observed external state, and the creation topology. `render` renders it deterministically, offline, and compares it byte for
  byte with this committed copy; the tool never installs a candidate. Every value in it is public;
  no key, mnemonic, keystore path, endpoint or credential belongs here.

- `deployed-manifest.json` is a **record**. It is empty until the ceremony's receipts are
  confirmed, and is then populated once, by `record`, from those receipts on both chains, after the
  founder has named the packet's exact digest and sent the ceremony by hand. No simulated fact may
  reach it.

Run every tool command from this directory's package root, `contracts/robinhood`, as
`python3 ../stocks/bin/ceremony.py <mode>`.

## The whole ceremony

Six fixed creations on Robinhood Chain (chain id 4663), then one production stock route per
admitted stock, then one creation on Base mainnet (chain id 8453), sent one after another by one
founder-selected deployer, each a plain zero-value contract creation. `n` is the deployer's live
nonce on Robinhood Chain and `m` its live nonce on Base at preparation time.

| # | Chain | Deployer nonce | Contract | What it is |
| --- | --- | --- | --- | --- |
| 1 | Robinhood | `n` | `UERC20Factory` | the pinned token factory; Robinhood Chain carries no deployment with this runtime, so the ceremony creates one and the launchpad requires its exact runtime hash |
| 2 | Robinhood | `n + 1` | `RobinhoodProtocolRevenueInboxV1` | collects protocol USDG; the admin Safe later points it at the Base destination and a bridge adapter |
| 3 | Robinhood | `n + 2` | `RobinhoodPositionsLib` | the externally linked library the launchpad delegates its position work to |
| 4 | Robinhood | `n + 3` | `RobinhoodFeeHookFactory` | creates the fee hook by `CREATE2` from inside the launchpad constructor |
| 5 | Robinhood | `n + 4` | `RobinhoodStocksLaunchpadV1` | the launchpad, linked against creation 3; its constructor asks the factory for the hook, then creates the splitter implementation (launchpad nonce 1) and the LP locker (nonce 2) |
| 6 | Robinhood | `n + 5` | `RobinhoodStockBidAdapterV1` | bids STOCK into a launch's auction through the launchpad's admitted route |
| 7 onward | Robinhood | `n + 6 + i` | `UniswapV3StockRouteV1` | one per admitted stock `i`, in admission order: that stock's USDG route over its Uniswap v3 USDG/STOCK pool and its Chainlink feed |
| last | Base | `m` | `RobinhoodBaseRevenueReceiverV1` | receives bridged USDG revenue on Base for the live staking contract, attested by the Base Safe |

The library address is pinned twice on purpose: the packet predicts it at `n + 2`, and the launchpad
must be compiled against exactly that address. The script refuses to broadcast a launchpad linked
anywhere else (`LibraryLinkMismatch`), and the hermetic suite pins the same address through the
`deployment` profile's `libraries` entry.

The launchpad is born paused and holds no owner: the admin Safe passed as a binding is its only
mutable authority. The deployer holds no role anywhere in the graph after the last creation.

## Deploying the graph and opening it are two separate acts

After the ceremony, the graph exists and does nothing. Opening it is the admin Safe's work, by
hand, one transaction each:

1. `setBaseDestination(address destination)` on the inbox, naming the Base receiver (creation 7).
2. `setBridgeAdapter(address adapter)` on the inbox, naming the bridge adapter the founder selects.
3. `admitStock(address stock, address route)` on the launchpad, once per admission, naming the
   stock and the route the ceremony created for it (creation `n + 6 + i` for admission `i`). The
   route reads its stock, pool and feed back (`stock()`, `pool()`, `feed()`), so a wrong pairing is
   visible before the call. A stock the Safe admits later needs a new route created by hand from
   the same source, then the same call.
4. `setExecutor(address executor)` on the fee hook.
5. `unpauseLaunches()` on the launchpad, last.

## The values the ceremony consumes

```bash
python3 ../stocks/bin/ceremony.py prepare \
  --deployer 0x... \
  --usdg 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 \
  --cca-factory 0x000000001F26a0044BaA66024e7b6599c61963F8 \
  --pool-manager 0x8366a39cc670b4001a1121b8f6a443a643e40951 \
  --position-manager 0x58daec3116aae6d93017baaea7749052e8a04fa7 \
  --permit2 0x000000000022D473030F116dDEE9F6B43aC78BA3 \
  --admin-safe 0x... \
  --base-safe 0x... \
  --swap-router 0x204FAca1764B154221e35c0d20aBb3c525710498 \
  --quoter 0x8dc178efb8111bb0973dd9d722ebeff267c98f94 \
  --admission 0xSTOCK:0xPOOL:0xFEED
```

`--admission` repeats, one per admitted stock in ceremony order, each naming the stock token, its
Uniswap v3 USDG/STOCK pool and its Chainlink USD feed. `prepare` proves each pool on chain: its two
currencies are exactly USDG and the stock (in either order; the Robinhood pools sort both ways), it
reports Uniswap's v3 factory (`0x1f7d7550B1b028f7571E69A784071F0205FD2EfA`), and that factory
registers it for the pair at its fee. It records the stock's symbol, name and decimals, the feed's
decimals and description, and the code hash of all three, and `rehearse` holds every one of them.
Candidate pools and feeds, with measured depth, are in
`artifacts/memestake-splitter/robinhood-route/venue-discovery-2026-09-23.md`.

The five protocol bindings above are the addresses verified on Robinhood Chain on 2026-09-22; the
packet records their live code hashes and `rehearse` holds them. The router (Uniswap's Universal
Router 2.1.2) and the V4 quoter are Uniswap's own deployments on Robinhood Chain, verified the same
day; the graph never touches them, but the website trades through them, so `prepare` records them,
proves each is bound to the selected pool manager, and `site-config` carries them. `prepare` also
proves USDG reports six decimals, snapshots the admin Safe's owners and threshold, and on Base
snapshots the USDC and live staking code hashes, the live staking owner and paused flag, and the
Base Safe's owners and threshold. It reads through the endpoints under `REGENT_ROBINHOOD_RPC_URL`
and `REGENT_BASE_RPC_URL`, which it never prints.

The hook salt is mined once, offline, by `test-deployment/DeploymentSelection.t.sol` against the
predicted hook factory, and frozen into the packet. The deployment script imports no miner.

## What the tool proves before anything is sent

- `render` (offline): the hermetic ceremony suite passes under the `deployment` profile; the
  committed selection re-derives to the same salt and addresses; the packet renders byte for byte;
  the deployed manifest is the empty record.
- `rehearse` (read-only endpoints): the deployer's live nonce on each chain still equals the
  committed one; every committed external fact matches the live chains exactly; then both
  deployment scripts are simulated against their chains with no signer and no broadcast, the
  Robinhood one with `--libraries` pinned to the predicted library address.

Both refuse to run beside any signing, keystore, sender or hardware-wallet environment variable, or
beside a `.env`, `.env.local` or `.envrc` file.

## Sending the ceremony by hand

The founder sends each creation from a signer of his own, confirms its receipt against the packet
(chain, sender, nonce, created address, status) and only then sends the next. If any creation lands
elsewhere, the packet is terminal and is never resumed. With the packet's values written out:

```bash
forge create ../stocks/lib/uerc20-factory/src/factories/UERC20Factory.sol:UERC20Factory \
  --rpc-url robinhood --broadcast
```

```bash
forge create src/RobinhoodProtocolRevenueInboxV1.sol:RobinhoodProtocolRevenueInboxV1 \
  --rpc-url robinhood --broadcast \
  --constructor-args 0xUSDG 0xADMIN_SAFE
```

```bash
forge create src/libraries/RobinhoodPositionsLib.sol:RobinhoodPositionsLib \
  --rpc-url robinhood --broadcast
```

```bash
forge create src/RobinhoodFeeHookFactory.sol:RobinhoodFeeHookFactory \
  --rpc-url robinhood --broadcast \
  --constructor-args 0xPOOL_MANAGER
```

```bash
forge create src/RobinhoodStocksLaunchpadV1.sol:RobinhoodStocksLaunchpadV1 \
  --rpc-url robinhood --broadcast \
  --libraries src/libraries/RobinhoodPositionsLib.sol:RobinhoodPositionsLib:0xPREDICTED_POSITIONS_LIB \
  --constructor-args "(0xPREDICTED_UERC20_FACTORY,0xCCA_FACTORY,0xPOOL_MANAGER,0xPOSITION_MANAGER,0xPREDICTED_HOOK_FACTORY,0xUSDG,0xPREDICTED_INBOX,0xADMIN_SAFE)" 0xHOOK_SALT
```

```bash
forge create src/RobinhoodStockBidAdapterV1.sol:RobinhoodStockBidAdapterV1 \
  --rpc-url robinhood --broadcast \
  --constructor-args 0xPREDICTED_LAUNCHPAD 0xPERMIT2
```

Then once per admission, in admission order:

```bash
forge create src/routes/UniswapV3StockRouteV1.sol:UniswapV3StockRouteV1 \
  --rpc-url robinhood --broadcast \
  --constructor-args 0xUSDG 0xSTOCK 0xPOOL 0xFEED
```

```bash
forge create src/RobinhoodBaseRevenueReceiverV1.sol:RobinhoodBaseRevenueReceiverV1 \
  --rpc-url base --broadcast \
  --constructor-args 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5 0xBASE_SAFE
```

The signer flags are the founder's own and are never written down here. `robinhood` and `base`
are the `[rpc_endpoints]` aliases in `foundry.toml`, resolved from `REGENT_ROBINHOOD_RPC_URL` and
`REGENT_BASE_RPC_URL`.

After each receipt, the public reads that prove it:

```bash
cast nonce 0xDEPLOYER --rpc-url robinhood
```

```bash
cast codehash 0xPREDICTED_UERC20_FACTORY --rpc-url robinhood
```

```bash
cast call 0xPREDICTED_LAUNCHPAD "hook()(address)" --rpc-url robinhood
```

```bash
cast call 0xPREDICTED_LAUNCHPAD "locker()(address)" --rpc-url robinhood
```

```bash
cast call 0xPREDICTED_LAUNCHPAD "splitterImplementation()(address)" --rpc-url robinhood
```

```bash
cast call 0xPREDICTED_LAUNCHPAD "launchesPaused()(bool)" --rpc-url robinhood
```

```bash
cast call 0xPREDICTED_INBOX "adminSafe()(address)" --rpc-url robinhood
```

```bash
cast call 0xPREDICTED_ROUTE "pool()(address)" --rpc-url robinhood
```

```bash
cast call 0xPREDICTED_BASE_RECEIVER "baseSafe()(address)" --rpc-url base
```

The UERC20 factory's code hash must read back as
`0x47a5ee559aa5c815a6a350486a1de3beb868d238ba5b2d46e62db5128645195f`, the frozen constant the
launchpad constructor checks.

## Recording

With every receipt confirmed, list every transaction hash in ceremony order (the six fixed
creations, one route per admission, the Base receiver last) in a JSON file and run:

```bash
python3 ../stocks/bin/ceremony.py record --receipts receipts.json --approved-digest 0xPACKET_DIGEST
```

`record` proves each transaction's chain, sender, nonce, order, created address and status against
the packet, proves every created contract's code against the frozen runtime (exact code hash for
the factory and the library, byte equality with immutables masked and the library linked for the
rest), performs the readbacks above through the tool (including each route's stock, USDG, pool and feed),
records the admissions with their routes, and writes the deployed-manifest candidate to
`reports/generated/deployment/`. A human installs it here.

## The website's file

Once the deployed manifest is installed and the admin Safe has admitted the stocks:

```bash
python3 ../stocks/bin/ceremony.py site-config --rpc-url URL --public-rpc-url URL --run-id LABEL
```

writes `reports/generated/deployment/site-config.json` in the exact shape the website loads. Its
stock entries come from the deployed manifest's admissions (each stock's symbol, name, decimals,
route, pool and feed, as the ceremony proved them), so nothing about a stock is typed in. It
carries the endpoints passed on the command line and is never committed.
