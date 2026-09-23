# Base mainnet: the Memestake ceremony

**Deployed on Base on 23 September 2026.** The founder approved packet digest
`0x26c7cb27f97e35915c27e9ede752c8dc63c6268a5b8ef1b6b0852eacb4f847a5` and sent its twelve creations from deployer
`0x9b2C414614aEE294202c1219520955EF3B596031` (nonces 5–16, Base blocks 51673079–51673339);
`deployed-manifest.json` records them. The launchpad was born paused and admits no stock and no
launch until the Governance and Regent Safe calls `admitStock` for each stock, `setExecutor` on the
hook and, last, `unpauseLaunches()`.

| Contract | Address | Base block |
| --- | --- | --- |
| StocksLaunchpadV1 | `0x1d36a95112835f81b1B499A808e556020C64Cac2` | 51673079 |
| StockBidAdapterV1 | `0xd28e66967C1fE651e6EC47f13397a74240C064A2` | 51673107 |
| AerodromeStockRouteV1 (AAPLc) | `0xb4d24085bc5bd35C06b97f500e1019E8fD9d8e41` | 51673122 |
| AerodromeStockRouteV1 (AMZNc) | `0x740D2e1978991cdC0594D3a5F69B04C9148B2581` | 51673169 |
| AerodromeStockRouteV1 (GOOGLc) | `0xF26A18A009362695d00043eb63F7AB42B2170CA9` | 51673205 |
| AerodromeStockRouteV1 (METAc) | `0x6943c568549CEAb04EA07Ca9Cdb58a47165D3d27` | 51673231 |
| AerodromeStockRouteV1 (MSFTc) | `0xdBBaA710EfddDe431027eBBa81b8c517e46544Df` | 51673243 |
| AerodromeStockRouteV1 (MSTRc) | `0xfE93FA01615d25DBeA7c2Ee8118A9988802DBF82` | 51673254 |
| AerodromeStockRouteV1 (NVDAc) | `0x49E0995070753fA58152889829249febcF9E0C53` | 51673273 |
| AerodromeStockRouteV1 (SNDKc) | `0xfFf81E528935FaEf2dd64087bc0b3740f7908a60` | 51673292 |
| AerodromeStockRouteV1 (SPCXc) | `0xACfa95f1c16eF61C281C26511556Bf918814151F` | 51673313 |
| AerodromeStockRouteV1 (TSLAc) | `0xa39c8E7e26Ef5e66785a405a277B930e48e6Afb7` | 51673339 |
| MemestockSplitterV1 (created by the launchpad) | `0x657e75434CED9dFa5397c7cE4d96da238923a452` | 51673079 |
| MemestockLPLocker (created by the launchpad) | `0x9e8B5EDdfC2aCdfc600FB37FBDc070c0Cd0033d7` | 51673079 |
| StocksFeeHookV1 (created by the launchpad) | `0x3820CD7413BC2EF795229C39C648326D99c8e0cC` | 51673079 |

| Nonce | Creation | Transaction |
| --- | --- | --- |
| 5 | StocksLaunchpadV1 | `0x0503dcf6b755d91f5166c6a3af0288c91215c0fddc17e1ddfbb9b5abcba35320` |
| 6 | StockBidAdapterV1 | `0x336114b51f04ba8cae3a62fff55d0d3202cdc5c6dc0775024351bb1c46a3e8df` |
| 7 | AerodromeStockRouteV1 (AAPLc) | `0x96dbf72dce5b9dc9c5a135b5f5d05a61b693dfe24d75a3201c33da484576f97e` |
| 8 | AerodromeStockRouteV1 (AMZNc) | `0xd69455923686738168decba7ffb4930d24e909ad887b2d807fee4f2ee49a3f92` |
| 9 | AerodromeStockRouteV1 (GOOGLc) | `0xd8a671a83defcad932a302c0dd994745cdb6dee609a181e22c1b9fb0e1c5f47e` |
| 10 | AerodromeStockRouteV1 (METAc) | `0x3cf3b31a86b5e65dbc7a64c27791a8158e537958f421c7fd3ddd1067a90830b2` |
| 11 | AerodromeStockRouteV1 (MSFTc) | `0x59392e30bdd2ce3e7f26a8ac0d11e1a67915d5e475c5c934e3bb7417000d8b9e` |
| 12 | AerodromeStockRouteV1 (MSTRc) | `0xc6b1f09b478dd4dd833251d089ee3f69f550257cc7afd27f030c64da5474dffa` |
| 13 | AerodromeStockRouteV1 (NVDAc) | `0xf85513e7f7a2ea3899c0f1427c80673e8525b561021a930477dec1784dfe41cd` |
| 14 | AerodromeStockRouteV1 (SNDKc) | `0xcc0d825505e64d59c6f08dbae2d420daf7fe45d96b5ae49b49c70c1156e408ee` |
| 15 | AerodromeStockRouteV1 (SPCXc) | `0x68c1520e2f8512c37d5134150c7331a1fa4c15f9df3642f934f43cf0456e8eee` |
| 16 | AerodromeStockRouteV1 (TSLAc) | `0xc5bd337d0762f4be426a3a415f536761163a837f975a5c122f4f621bb4215aec` |

Two files live in this directory, and keeping them apart is the point.

- `mainnet-no-go-packet.json` is a **proposal**, and the sole committed ceremony authority. It
  carries the frozen code identity of every contract the ceremony creates, the build that produced
  it, the `src/` tree it was rendered from, and, once `bin/ceremony.py prepare` has run for the
  founder's selection and a human has installed its candidate, the deployer, its starting nonce, the
  mined hook salt, the UERC20 factory the launchpad binds, the admitted stocks with their pools and
  feeds, every predicted address, the observed external state, and the creation topology.
  `bin/ceremony.py render` renders it deterministically, offline, and compares it byte for byte
  with this committed copy; the tool can fail an installed packet and can write a candidate to
  `reports/generated/deployment/`, but it never installs one. Every value in it is public; no key,
  mnemonic, keystore path, endpoint or credential belongs here.

- `deployed-manifest.json` is a **record**. It was populated once, by `bin/ceremony.py record`, from
  confirmed Base receipts, after the founder named the packet's exact digest and sent the ceremony
  by hand. No simulated fact reaches it. `render` proves on every run that it is a deployed record
  for the installed packet's digest.

## The whole ceremony

Two fixed creations and then one route per admitted stock, sent one after another by one
founder-selected deployer, each a plain zero-value contract creation. `n` is the packet's
`selection.starting_nonce`, which `prepare` reads off the chain as the deployer's live nonce.

| # | Deployer nonce | Contract | What it is |
| --- | --- | --- | --- |
| 1 | `n` | `StocksLaunchpadV1` | the launchpad; its constructor creates the splitter implementation (launchpad nonce 1), the LP locker (nonce 2) and the fee hook (`CREATE2` over the pinned salt) |
| 2 | `n + 1` | `StockBidAdapterV1` | bids STOCK into a launch's auction through the launchpad's admitted route |
| 3 + i | `n + 2 + i` | `AerodromeStockRouteV1` | one production route per admitted stock, in packet order, over its Aerodrome Slipstream USDC/STOCK pool and Chainlink feed |

The launchpad is born paused and holds no owner: the Governance and Regent Safe compiled into
`StocksBindings` is its only mutable authority. The deployer holds no role anywhere in the graph
after the last creation.

## Deploying the graph and opening it are two separate acts

After the ceremony, the graph exists and does nothing. Opening it is the Safe's work, by hand,
one transaction each, all verifiable through public reads:

1. `admitStock(address stock, address route)` on the launchpad, once per admitted stock, with the
   route address the packet predicts for that stock.
2. `setExecutor(address executor)` on the fee hook, naming the account that may drive the hook's
   executor-only path.
3. `unpauseLaunches()` on the launchpad, last.

The founder decided (23 September 2026) that the first two are one Safe session, and that the
launchpad opens at the same moment as the Revstake factory, just before the website goes live.
Before signing, both batches were run from the Safe on a Base node without sending (after block
51674137): every stock read back admitted with its own route, the executor read back, and both
launchpads read open after the activation batch; `admitStock` from any other account and a stock
paired with another stock's route were refused. On the same day every deployed route was run on live
Base state for all ten stocks: a 0.1-share sale landed within 0.35% of the Chainlink price, a 20 USDC
purchase succeeded inside the 5% bound, and the purchased stock moved through the bid adapter's
exact Permit2 allowance path with both allowances back at zero.

## The values the ceremony consumes

`prepare` takes the founder's public choices on its command line and reads the rest off the chain
through a read-only endpoint it never prints:

```bash
python3 bin/ceremony.py prepare \
  --deployer 0x... \
  --uerc20-factory 0x... \
  --admission 0xSTOCK:0xPOOL:0xFEED \
  --admission 0xSTOCK:0xPOOL:0xFEED
```

- `--deployer`: the founder-selected deployer. Its live nonce becomes the starting nonce, so a
  deployer that has ever sent a transaction yields a packet that is only valid until it sends
  another. A completed ceremony moves it past its starting nonce, so an installed selection is
  single-use.
- `--uerc20-factory`: the token factory the launchpad binds. The launchpad constructor requires its
  runtime hash to equal the frozen constant, and `prepare` refuses a factory whose live code hash
  differs before it mines anything.
- `--admission`: one admitted stock per flag, in ceremony order. `prepare` proves the pool's
  `token0()` is USDC and `token1()` is the stock, and records the stock's symbol and decimals and
  the feed's decimals.

The hook salt is mined once, offline, by `test-deployment/DeploymentSelection.t.sol` against the
predicted launchpad, and frozen into the packet. The deployment script imports no miner and can
only consume a pinned salt.

## What the tool proves before anything is sent

- `render` (offline): the hermetic ceremony suite passes under the `deployment` profile; the
  committed selection re-derives to the same salt and addresses; the packet renders byte for byte;
  the deployed manifest is the empty record.
- `rehearse` (read-only endpoint under `REGENT_BASE_RPC_URL`): the deployer's live nonce still
  equals the committed one; every committed external fact (binding code hashes, the Safe's owners
  and threshold, the live staking owner and paused flag, each pool's tokens, each stock's and
  feed's decimals) matches the live chain exactly. It then builds each creation transaction from
  the frozen build and its constructor arguments, simulates all of them in order, at their nonces,
  on a Base node itself (`eth_simulateV1`, with nonce and balance validation), proves every created
  code against the frozen runtime and every readback below against the packet, and writes the
  transactions to `reports/generated/deployment/rehearsed-transactions.json`. Nothing is signed or
  broadcast. Forge cannot simulate this ceremony: Base's stock tokens carry a one-byte `0xef` code
  that only a Base node executes, and every route constructor reads its stock.

Both refuse to run beside any signing, keystore, sender or hardware-wallet environment variable, or
beside a `.env`, `.env.local` or `.envrc` file.

## Sending the ceremony by hand

The founder sends each creation from a signer of their own, confirms its receipt against the packet
(sender, nonce, created address, status) and only then sends the next. If any creation lands
elsewhere, the packet is terminal and is never resumed. Each creation's transaction data is the
`data` field of its row in `rehearsed-transactions.json`, from a rehearsal run just before the first
send:

```bash
cast send --rpc-url base <your signer flags> --nonce N --gas-limit GAS --create 0xDATA
```

Every flag comes before `--create`. The signer flags are the founder's own and are never written
down here. `base` is the `[rpc_endpoints]` alias in `foundry.toml`, resolved from
`REGENT_BASE_RPC_URL`.

After each receipt, the public reads that prove it:

```bash
cast nonce 0xDEPLOYER --rpc-url base
```

```bash
cast call 0xPREDICTED_LAUNCHPAD "hook()(address)" --rpc-url base
```

```bash
cast call 0xPREDICTED_LAUNCHPAD "locker()(address)" --rpc-url base
```

```bash
cast call 0xPREDICTED_LAUNCHPAD "splitterImplementation()(address)" --rpc-url base
```

```bash
cast call 0xPREDICTED_LAUNCHPAD "launchesPaused()(bool)" --rpc-url base
```

```bash
cast call 0xPREDICTED_BID_ADAPTER "launchpad()(address)" --rpc-url base
```

```bash
cast call 0xPREDICTED_ROUTE "stock()(address)" --rpc-url base
```

## Recording

With every receipt confirmed, list the transaction hashes in ceremony order in a JSON file and run:

```bash
python3 bin/ceremony.py record --receipts receipts.json --approved-digest 0xPACKET_DIGEST
```

`record` proves each transaction's sender, nonce, order, created address and status against the
packet, proves every created contract's code against the frozen runtime (exact code hash where the
runtime has no immutables, otherwise byte equality with immutables masked), performs the readbacks
above through the tool, and writes the deployed-manifest candidate to
`reports/generated/deployment/`. A human installs it here.

## The website's file

Once the deployed manifest is installed and the Base Revstake factory address is known from
`contracts/v1/deployments/base-mainnet/deployed-manifest.json`:

```bash
python3 bin/ceremony.py site-config --rpc-url URL --public-rpc-url URL --agent-factory 0x...
```

writes `reports/generated/deployment/site-config.json` in the exact shape the website loads. It
carries the endpoints passed on the command line and is never committed.

## The executor

The fee hook charges two lanes of STOCK on every swap in a launched pool. The staker lane needs
nobody: anyone may call `settleStakerLane(bytes32 poolId)` and the whole lane goes, as STOCK, into
that pool's fixed memestock splitter. The REGENT lane needs a decision — how much STOCK to sell,
and the least USDC to accept for it — and that decision belongs to one account the Safe names: the
executor. Everything below is read from `src/StocksFeeHookV1.sol` and
`src/routes/AerodromeStockRouteV1.sol`.

### What the executor can do

Exactly one thing. `settleRegentLane(bytes32 poolId, uint256 stockAmount, uint256 minUsdcOut)` on
the hook, which only the executor may call (`NotExecutor` otherwise, and no one at all while the
executor is the zero address). For a registered pool it:

- takes `stockAmount` off that pool's REGENT lane (`ZeroAmount` for zero; `InsufficientAccrual` if
  the lane holds less);
- looks the stock's route up on the launchpad, `stockAdmission(address stock)` returning
  `(bool admitted, uint8 decimals, address route)`, and refuses with `NoRoute` if there is none;
- sends the STOCK to that route and calls its
  `swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)`
  with `tokenIn` the stock, `tokenOut` USDC, `minAmountOut` the executor's `minUsdcOut` and the
  hook itself as recipient. STOCK the pool did not consume comes back and is credited to the lane
  again, never lost;
- refuses with `InsufficientUsdcOut` if the USDC received is below `minUsdcOut` or is zero;
- deposits every USDC it received into the live staking contract
  (`StocksBindings.LIVE_STAKING`, `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`) through
  `depositUSDC(usdcOut, REGENT_SOURCE_TAG, poolId)`, where `REGENT_SOURCE_TAG` is
  `bytes32("autolaunch-stocks")`, and checks that the deposit consumed the exact allowance and left
  the hook's USDC balance where it started;
- records the totals and emits `RegentLaneSettled(bytes32 indexed poolId, uint256 stockConverted, uint256 usdcDeposited)`.

Any refusal reverts the whole call: the lane is not debited, no token moves.

### What the executor cannot do

- Choose where anything goes. STOCK goes only to the route the launchpad admitted for that stock;
  USDC goes only to live staking. The executor names amounts, never addresses.
- Touch the staker lane, register or initialize a pool, credit launch dust, change the route,
  change the executor, or pause anything. Pools and dust are the launchpad's (`NotLaunchpad`); the
  executor and the admissions are the Safe's (`NotGovernance`).
- Sell below the feed. The route quotes from the Chainlink feed, not the pool, and refuses any
  execution that delivers more than `MAX_DEVIATION_BPS` (`500`, five percent) under that quote
  (`PriceDeviation`). `minUsdcOut` can only tighten that bound.
- Sell against a stopped feed. The route reads the feed's latest round on every quote and every
  swap and refuses with `StaleFeed` when the answer is older than `MAX_FEED_AGE` (`7 days`) or has
  no timestamp, and with `BadFeedAnswer` when the answer is not positive. While a feed is stale,
  `quoteExactIn` and `swapExactIn` both revert, so that stock's REGENT lane cannot be settled at
  all; it keeps accruing, and the staker lane is unaffected. The feeds hold the last close over
  weekends and holidays, so this bound only catches a feed that has stopped.

The route holds nothing between calls and calls the pool directly, never a router.

### Setting the executor up

1. Create the executor's key with your own tooling. It never appears in this repository, a handoff
   or a chat, and this tool never reads it.
2. Fund the address with a little ETH for gas. It holds no STOCK and no USDC: the hook does, and
   the hook only ever moves them along the path above.
3. From the Safe, call `setExecutor(address executor_)` on the hook. Governance only
   (`NotGovernance` for anyone else). It emits `ExecutorSet(address indexed previous, address indexed current)`.
4. Read it back:

```bash
cast call 0xHOOK "executor()(address)" --rpc-url base
```

### Executing a settlement

First find the pool. Every launch's `poolId` is the last field of
`launches(uint256 launchId)` on the launchpad and the first topic of the hook's
`PoolRegistered(bytes32 indexed poolId, address indexed stock, address indexed newToken, address splitter)`
event. Then read what is there and who sells it:

```bash
cast call 0xHOOK "accrued(bytes32)(uint256,uint256)" 0xPOOL_ID --rpc-url base
```

```bash
cast call 0xHOOK "pool(bytes32)((address,address,address))" 0xPOOL_ID --rpc-url base
```

```bash
cast call 0xLAUNCHPAD "stockAdmission(address)(bool,uint8,address)" 0xSTOCK --rpc-url base
```

The first read returns `(regentLane, stakerLane)` in STOCK base units; the second returns the
pool's `(stock, newToken, splitter)`; the third's last value is the route. Quote the amount you
intend to sell at the feed price, in USDC base units:

```bash
cast call 0xROUTE "quoteExactIn(address,address,uint256)(uint256)" 0xSTOCK 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 STOCK_AMOUNT --rpc-url base
```

Choose `MIN_USDC_OUT` from that quote: the route already refuses anything more than five percent
under it, so the value is the tighter floor you are willing to accept, never more than the quote.
Then send, from the executor's key:

```bash
cast send 0xHOOK "settleRegentLane(bytes32,uint256,uint256)" 0xPOOL_ID STOCK_AMOUNT MIN_USDC_OUT \
  --rpc-url base <your signer flags>
```

The signer flags are yours and are never written down here. After the receipt:

```bash
cast call 0xHOOK "settled(bytes32)(uint256,uint256,uint256)" 0xPOOL_ID --rpc-url base
```

returns the running totals `(stockConverted, usdcDeposited, stockDepositedToStakers)`, and
`accrued` shows the lane debited by exactly what the pool consumed.

### Replacing the executor

From the Safe, call `setExecutor(address executor_)` with the new address. The previous key loses
the right in the same block; nothing else changes and nothing needs migrating, because the executor
holds nothing. `setExecutor(0x0000000000000000000000000000000000000000)` disables the REGENT lane's
settlement entirely until a new executor is named. Read it back with the same `executor()` call.

### Readback

Every fact above is a public read.

| Contract | Read | Returns |
| --- | --- | --- |
| hook | `executor()(address)` | the one account that may settle the REGENT lane; zero means nobody |
| hook | `launchpad()(address)` | the only account that may register pools and credit dust |
| hook | `REGENT_SOURCE_TAG()(bytes32)` | `bytes32("autolaunch-stocks")`, the tag every REGENT-lane deposit carries |
| hook | `accrued(bytes32)(uint256,uint256)` | `(regentLane, stakerLane)` STOCK not yet settled |
| hook | `settled(bytes32)(uint256,uint256,uint256)` | `(stockConverted, usdcDeposited, stockDepositedToStakers)` |
| hook | `pool(bytes32)((address,address,address))` | the pool's `(stock, newToken, splitter)` |
| launchpad | `stockAdmission(address)(bool,uint8,address)` | `(admitted, decimals, route)` |
| route | `stock()(address)`, `usdc()(address)`, `pool()(address)`, `feed()(address)` | the four bindings pinned at construction |
| route | `MAX_FEED_AGE()(uint256)`, `MAX_DEVIATION_BPS()(uint256)` | `604800` seconds and `500` basis points |
| route | `quoteExactIn(address,address,uint256)(uint256)` | the feed-price quote; reverts `StaleFeed` while the feed is stale |
