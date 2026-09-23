# Robinhood Chain: the Memestake ceremony

**Nothing here has been deployed.** The package is mainnet NO-GO.

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

- `deployed-manifest.json` is a **record**, and it is empty. It is populated once, by `record`,
  from confirmed receipts on both chains, after the founder has named the packet's exact digest and
  sent the ceremony by hand. No simulated fact may reach it.

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
