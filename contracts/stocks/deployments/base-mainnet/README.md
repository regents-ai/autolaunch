# Base mainnet: the Memestake ceremony

**Nothing here has been deployed.** The package is mainnet NO-GO.

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

- `deployed-manifest.json` is a **record**, and it is empty. It is populated once, by
  `bin/ceremony.py record`, from confirmed Base receipts, after the founder has named the packet's
  exact digest and sent the ceremony by hand. No simulated fact may reach it. `render` proves on
  every run that it is the empty record.

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
  feed's decimals) matches the live chain exactly; then the exact deployment script is simulated
  against Base with no signer and no broadcast.

Both refuse to run beside any signing, keystore, sender or hardware-wallet environment variable, or
beside a `.env`, `.env.local` or `.envrc` file.

## Sending the ceremony by hand

The founder sends each creation from a signer of his own, confirms its receipt against the packet
(sender, nonce, created address, status) and only then sends the next. If any creation lands
elsewhere, the packet is terminal and is never resumed. With the packet's values written out, the
three kinds of creation are:

```bash
forge create src/StocksLaunchpadV1.sol:StocksLaunchpadV1 \
  --rpc-url base --broadcast \
  --constructor-args 0xUERC20_FACTORY 0xHOOK_SALT
```

```bash
forge create src/StockBidAdapterV1.sol:StockBidAdapterV1 \
  --rpc-url base --broadcast \
  --constructor-args 0xPREDICTED_LAUNCHPAD
```

```bash
forge create src/routes/AerodromeStockRouteV1.sol:AerodromeStockRouteV1 \
  --rpc-url base --broadcast \
  --constructor-args 0xSTOCK 0xPOOL 0xFEED
```

The signer flags are the founder's own and are never written down here. `base` is the
`[rpc_endpoints]` alias in `foundry.toml`, resolved from `REGENT_BASE_RPC_URL`.

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
