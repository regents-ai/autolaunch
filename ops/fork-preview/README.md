# Fork preview host

A shared, always-on preview chain for autolaunch.sh: one Anvil forked from Base (chain id
31337) running on a Fly machine, carrying the Agent and Stocks contract graphs, behind a
proxy with two doors. Visitors' wallets talk to the public door; the website talks to the
private door. Nothing here is mainnet: forked Base state plus test assets with no value.

**What it is not.** Not a testnet and not a deployment of anything. The stock tokens are
fixtures (`FixtureStockToken` installed at the catalog addresses with `anvil_setCode`) because
Base's native stock assets carry code Anvil cannot run. Governance actions on the fork are made
by impersonating the Governance Safe. The chain is thrown away and rebuilt whenever useful;
launches, bids and balances on it are disposable.

## Pieces

| Piece | Where | Runs |
| --- | --- | --- |
| Image | `Dockerfile` | Foundry `anvil` v1.5.1 (pinned release tarball, digest-checked) + Node 22 |
| Entrypoint | `bin/run-fork.sh` | In the machine. Starts Anvil on `127.0.0.1:8546`, waits for chain 31337, starts the proxy |
| Upstream check | `bin/upstream-check.mjs` | In the machine. Proves the upstream is Base (8453) and reads its head; never prints the URL |
| Proxy | `proxy/server.mjs` (+ `server.test.mjs`) | In the machine. Public door `0.0.0.0:8545`, private door `fly-local-6pn:8547` |
| Fly config | `fly.toml` | App `autolaunch-fork-preview`, region `iad`, one machine, volume `fork_state` at `/data` |
| Bootstrap | `bin/bootstrap.sh`, `bin/deploy-agent-graph.py`, `bin/write-fork-configs.py` | Developer machine, through `fly proxy` |
| Operations | `bin/status.sh`, `bin/reset.sh` | Developer machine |
| Output | `generated/` (ignored by Git) | The four lab documents plus `generated/fork/` for the website |

## The two doors

Anvil accepts privileged methods (`anvil_*`, `evm_*`, `hardhat_*`, `debug_*`,
`eth_sendUnsignedTransaction`, `personal_*`, `miner_*`, `eth_accounts` with unlocked keys).
Anyone reaching them owns the chain. So Anvil binds only to localhost inside the machine and
the proxy decides who may say what.

**Public door** (`https://autolaunch-fork-preview.fly.dev`, internal port 8545, HTTPS 443 via
Fly). Wallets and browsers use it. It accepts only these JSON-RPC methods:

```
eth_chainId  eth_blockNumber  eth_getBalance  eth_getCode  eth_getStorageAt  eth_call
eth_estimateGas  eth_gasPrice  eth_maxPriorityFeePerGas  eth_feeHistory  eth_getTransactionCount
eth_getBlockByNumber  eth_getBlockByHash  eth_getTransactionByHash  eth_getTransactionReceipt
eth_getLogs  eth_sendRawTransaction  eth_syncing  net_version  web3_clientVersion
```

Everything else answers with JSON-RPC error `-32601` and never reaches Anvil. A batch with any
other method is refused whole (one error object). Bodies over 512 KiB answer 413. Batches over
100 requests are refused (`-32600`). `eth_getLogs` ranges over 10,000 blocks, or from `earliest`,
answer `-32005`; a `toBlock` tag is resolved against the current head before the check. CORS is
open (`*`, `POST, OPTIONS`, `content-type`). `GET /healthz` answers 200 only while Anvil answers
`eth_chainId` as 31337; that is the Fly health check. Logs are one JSON line per request with the
door, client IP, method names, status and duration, never the body.

**Private door** (`http://autolaunch-fork-preview.internal:8547`, no Fly service). Forwards
every method unchanged. It is bound to the machine's private IPv6 (`fly-local-6pn`), so it is
reachable only from apps in the same Fly organisation over the private network, or from a
developer machine through `fly proxy 8547:8547 -a autolaunch-fork-preview`, which makes it
appear at `http://127.0.0.1:8547`. The website's faucet and verifiers, and the lab controllers,
use `anvil_impersonateAccount`, `anvil_setBalance`, `anvil_setCode` and `anvil_mine` here. The
same 512 KiB body cap applies.

## Lifecycle

1. **Create** the Fly app, its volume and the upstream secret; deploy the image. On the first
   boot `run-fork.sh` asks the upstream for its head block, records it in
   `/data/fork-block-number`, and starts Anvil forked at that block with `--state
   /data/state.json --state-interval 60 --block-time 2`. Every later boot reuses the recorded
   block and loads the saved state, so restarts and redeploys keep launches, bids and balances.
   A state file without its recorded block refuses to start rather than sit on a different
   upstream snapshot.
2. **Bootstrap** from a developer machine through `fly proxy`: deploy the Agent graph
   (`deploy-agent-graph.py`, which reuses `contracts/v1/bin/local-base-lab.py` unchanged), then
   the Stocks graph (`contracts/stocks/bin/local-stocks-lab.py deploy`), then write the two
   website documents. Bootstrapping is done once per chain; the state persists.
3. **Run for days.** Blocks every two seconds, like Base. Fund test wallets with the Stocks
   controller's `fund` command through `fly proxy`, or let visitors use the site's faucet.
4. **Reset** when the chain should start over: `bin/reset.sh --yes` destroys the machine and
   the volume, creates a new volume, deploys one machine and tells you to bootstrap again.

### Pinning the fork block

Set `FORK_BLOCK_NUMBER` before the first boot (`fly secrets set FORK_BLOCK_NUMBER=N -a
autolaunch-fork-preview --stage`, then deploy) to fork at a chosen Base block. It is read only
when `/data/fork-block-number` does not exist yet; unset it afterwards
(`fly secrets unset FORK_BLOCK_NUMBER ...`) so a later reset forks at the head again.

## Costs and limits

- **Upstream.** Anvil reads every untouched storage slot, account and block from the upstream
  on demand and caches it. The public `https://mainnet.base.org` rate-limits and drops bursts,
  which shows up as slow `eth_call`s and stalled deployments. Use a paid Base endpoint
  (Alchemy, QuickNode, ...) with its key in the URL and pass it as the Fly secret
  `FORK_UPSTREAM_RPC_URL`. The key never appears in files or logs: `upstream-check.mjs` prints
  only the head block, the proxy refuses `anvil_nodeInfo` on the public door, and
  `status.sh` reads only the fork block number out of it on the private door.
- **Machine.** `shared-cpu-2x`, 2 GB memory, 10 GB volume in `iad`; roughly USD 12 to 15 a
  month at current Fly pricing plus egress. `auto_stop_machines = "off"` and
  `min_machines_running = 1` keep it on. Memory grows with the chain's history; the state file
  (all local accounts, blocks and transactions) grows with every mined block, 43,200 a day at
  two seconds each. Plan to reset every few weeks, or sooner after heavy use.
- **State dump.** Anvil rewrites `/data/state.json` every 60 s and on `SIGTERM`; `fly.toml`
  gives it `kill_timeout = "120s"`. A crash loses at most the last minute.
- **Chain id 31337** is the id every Hardhat and Anvil network uses. A visitor's wallet may
  already hold a "Localhost 8545" network with that id and must edit its RPC URL to the public
  door, or add a new network: name "Autolaunch preview (Base fork)", RPC
  `https://autolaunch-fork-preview.fly.dev`, chain id `31337`, currency `ETH`.
- **Private door reach.** `autolaunch-fork-preview.internal` resolves only inside the Fly
  organisation's private network and returns an IPv6 address; the website app must live in the
  same organisation and its HTTP client must speak IPv6.
- **Concurrency.** Fly's connection limits in `fly.toml` (soft 300, hard 400) are the only
  rate limit on the public door; there is no per-IP throttle.
- **Runs as root** inside the container because Fly mounts the volume owned by root. The
  machine serves nothing but this chain.

## Runbook (founder runs these; nothing in this folder executes them)

Prerequisites on the machine that runs them: `fly` logged in to the organisation, `forge`,
`cast`, `python3` 3.12+, `curl`, and `contracts/stocks/lib` filled once with
`cd contracts/stocks && python3 bootstrap-deps.py <hydrated autolaunch checkout>`.
Run from the repository root unless a step says otherwise.

1. Create the app and its volume (once):

   ```sh
   fly apps create autolaunch-fork-preview --org <organisation>
   fly volumes create fork_state -a autolaunch-fork-preview -r iad -s 10 -y
   ```

2. Set the upstream secret (the only secret). `--stage` stores it without deploying:

   ```sh
   fly secrets set FORK_UPSTREAM_RPC_URL='https://<paid Base mainnet endpoint>' -a autolaunch-fork-preview --stage
   ```

   Optional, first boot only: `fly secrets set FORK_BLOCK_NUMBER=<Base block> -a autolaunch-fork-preview --stage`.

3. Deploy one machine (the build context is this folder):

   ```sh
   cd ops/fork-preview && fly deploy --ha=false && cd -
   fly logs -a autolaunch-fork-preview          # wait for "anvil_ready" then two "listening" lines
   curl -s https://autolaunch-fork-preview.fly.dev/healthz
   curl -s -X POST -H 'content-type: application/json' \
     --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
     https://autolaunch-fork-preview.fly.dev      # {"jsonrpc":"2.0","id":1,"result":"0x7a69"}
   ```

4. Open the private door on this machine and keep that terminal open:

   ```sh
   fly proxy 8547:8547 -a autolaunch-fork-preview
   ```

5. Put both graphs on the chain and write the website documents (a second terminal):

   ```sh
   ops/fork-preview/bin/bootstrap.sh --dry-run   # prints every command, runs none
   ops/fork-preview/bin/bootstrap.sh
   ops/fork-preview/bin/status.sh
   ```

   `bootstrap.sh` checks the door answers as 31337 and carries Base (REGENT, the CCA factory,
   the PoolManager and the Governance Safe have code), runs
   `bin/deploy-agent-graph.py --rpc-url http://127.0.0.1:8547 --out ops/fork-preview/generated`
   (Forge build with the `local-base-lab` profile, `DeployLocalAutolaunchLab` broadcast from
   Anvil's first account, code and Safe-runtime checks, `unpauseLaunches` from the impersonated
   Safe; writes `generated/state.json` and `generated/site-config.json`), then
   `contracts/stocks/bin/local-stocks-lab.py --agent-lab-dir ops/fork-preview/generated
   --rpc-url http://127.0.0.1:8547 deploy` (fixture tokens, Stocks graph, admissions, route
   funding, the Agent factory's 500,000 REGENT fee; writes `generated/stocks-state.json` and
   `generated/stocks-site-config.json`), then `bin/write-fork-configs.py`.

6. Hand the website these two files for `AUTOLAUNCH_CHAIN_MODE=fork`:

   ```
   ops/fork-preview/generated/fork/site-config.json
   ops/fork-preview/generated/fork/stocks-site-config.json
   ```

   They are the lab controllers' documents with `rpc_url` set to the private door
   `http://autolaunch-fork-preview.internal:8547`, one extra key `public_rpc_url` set to
   `https://autolaunch-fork-preview.fly.dev`, and (Stocks file) `agent_lab_config` pointing at
   the fork `site-config.json` beside it. Every other key (`chain_id`, `addresses`, `abis`,
   `faucet`, `stocks`, the two fee strings) is copied unchanged. `FORK_INTERNAL_RPC_URL` and
   `FORK_PUBLIC_RPC_URL` override the two URLs; `FORK_APP` renames the app everywhere.

7. Day to day, with `fly proxy` open:

   ```sh
   ops/fork-preview/bin/status.sh                                   # chain id, blocks, fees, launch counts
   cd contracts/stocks && python3 bin/local-stocks-lab.py \
     --agent-lab-dir ../../ops/fork-preview/generated --rpc-url http://127.0.0.1:8547 \
     fund 0x<wallet> --regent 600000 --stock AAPLc --amount 100 --usdc 1000
   fly logs -a autolaunch-fork-preview
   ```

   The other controller commands (`status`, `advance`, `migrate`, `settle`, `set-agent-fee`)
   take the same two flags. `contracts/v1/bin/local-base-lab.py` cannot be pointed at this
   chain (it reads its own run record), so Agent-side mining uses `anvil_mine` on the private
   door or the Stocks controller's `advance`.

8. Start over:

   ```sh
   ops/fork-preview/bin/reset.sh          # prints the steps
   ops/fork-preview/bin/reset.sh --yes    # destroys machine + volume, recreates, redeploys; then repeat 4 to 6
   ```

## Verifying this folder locally

```sh
cd ops/fork-preview
node --check proxy/server.mjs && node --test proxy/
FORK_ANVIL_URL=http://127.0.0.1:<local anvil port> FORK_PUBLIC_HOST=127.0.0.1 FORK_PUBLIC_PORT=18545 \
  FORK_PRIVATE_HOST=127.0.0.1 FORK_PRIVATE_PORT=18547 node proxy/server.mjs
bin/bootstrap.sh --dry-run
FORK_PRIVATE_RPC_URL=http://127.0.0.1:18547 bin/status.sh
```

`run-fork.sh` needs bash 4.3+ (`wait -n`); the image has bash 5. To try the entrypoint on a
Mac use Homebrew's bash with `FORK_DATA_DIR=/tmp/fork-preview-data FORK_APP_DIR=$PWD
FORK_PUBLIC_HOST=127.0.0.1 FORK_PRIVATE_HOST=127.0.0.1 FORK_UPSTREAM_RPC_URL=<Base RPC>`.
