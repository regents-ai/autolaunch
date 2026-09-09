# Fork preview: the site on a hosted Base fork

`AUTOLAUNCH_CHAIN_MODE=fork` runs a production build of the website against a hosted Anvil
fork of Base (chain 31337) that carries the lab contract graph, so the public can try the
create, launch, auction, bid and settlement flows with test assets and no mainnet value. It
is the [local Base-fork lab](local-base-lab.md) and the [Stocks lab](stocks.md) moved off a
laptop: the same two configuration files, the same validation, the same market feeds and the
same faucet, plus the pieces a public site needs. Nothing in this document deploys anything;
deployment remains a separate founder approval.

## What the flag does

`Autolaunch.ChainMode` reads `:chain_mode`, which `config/runtime.exs` sets from
`AUTOLAUNCH_CHAIN_MODE`. The variable admits exactly two values; anything else stops the boot.

| | `base` (default when unset) | `fork` |
| --- | --- | --- |
| Chain | Real Base (8453) | A hosted Base fork answering as 31337 |
| Lab configurations | Development and test only; production refuses them | Required (`AUTOLAUNCH_LAB_CONFIG` and `AUTOLAUNCH_STOCKS_LAB_CONFIG`), in every environment including production |
| Site's own RPC door (`rpc_url`) | Loopback only | Loopback, a private `http://…internal:PORT` URL, or an `https://` URL |
| Wallet RPC door (`public_rpc_url`) | Optional; wallets are given the loopback `rpc_url` when absent | Required, `https://` only |
| `prelaunch_read_only` | The fail-closed default (read-only until the explicit configuration change) | `false`, set by `runtime.exs`; no serve script |
| Base log ledger (indexer) | On when `AUTOLAUNCH_INDEXER_RPC_URL` is set and no lab is configured | Off (a lab is always configured) |
| Lab market feeds | Run when a lab is configured and the site is not read-only | Both run |
| Faucet cooldown | `AUTOLAUNCH_FAUCET_COOLDOWN_SECONDS`, default 0 | `AUTOLAUNCH_FAUCET_COOLDOWN_SECONDS`, default 3600 |
| Every page's notice | "Local Base fork · test assets · no mainnet value · launches and bids only · sign in with Privy" | "Preview on a Base fork · test assets · no mainnet value · sign in with Privy" (or "· sign-in unavailable") |
| Wallet chain name | "Autolaunch Local Lab" for a loopback door | "Autolaunch preview (Base fork)" for an `https://` door |

`Autolaunch.ChainMode.label/0` returns "Local Base fork" or "Preview on a Base fork" and every
surface that names the fork (notice line, network rows on wallet cards, the test-funds panel,
the home network chip) uses it. `Autolaunch.Lab.enabled?/0` and `Autolaunch.Stocks.Lab.enabled?/0`
are true in fork mode exactly as on a lab, so everything that is labelled rather than switched on
a lab (REGENT facts and links say public Base mainnet, treasury evidence is unavailable, subject
staking and payments are off) behaves the same way. `/healthz` is unchanged.

Base mode is unchanged: no code path that runs today changes when the variable is unset.

## The two RPC doors, and why the private one must never be public

A fork host has to answer two very different callers, so the configuration names two URLs.

**`rpc_url` — the site's own door (privileged).** The server reads the fork through it, checks
receipts through it, and the test-funds faucet sends through it using `anvil_impersonateAccount`,
`anvil_setBalance` and `eth_sendTransaction` from impersonated holders. Anyone who can reach this
door can move any balance on the fork, mint fixture stock, or reset state. It therefore has to
be a URL only the site can reach: loopback on the same machine, a Fly private-network address
(`http://<app>.internal:PORT`), or an `https://` endpoint the fork host restricts to the site. The
server never sends this URL to a browser, never puts it in an envelope, and never logs it
(`Autolaunch.Chain.Rpc` logs only the method and an error class). `Autolaunch.LabRpcUrl.admitted/2`
admits it; plain `http://` anywhere but loopback and `.internal` is refused.

**`public_rpc_url` — the wallet door.** Wallets need an RPC to add chain 31337 and to send the
reviewed transaction. This is the URL every envelope's `lab_binding.rpc_url` carries to the
browser and the URL `wallet_addEthereumChain` receives. The fork host exposes it as a plain
JSON-RPC endpoint over `https://` with the Anvil administrative methods (`anvil_*`, `evm_*`,
`hardhat_*`) blocked, so a wallet can read, estimate and send but cannot impersonate or mint.
`Autolaunch.LabRpcUrl.public/3` admits it: `https://` only, no credentials, query or fragment.
The browser (`assets/js/wallet_actions/autolaunch_network.ts`) accepts it for the same reasons
and keeps refusing plain `http://` unless it is loopback.

Both files carry both keys, and the Stocks file's values must equal the Agent file's, so one
site never prepares against two forks.

## Environment

Production boot requirements are unchanged: `AUTOLAUNCH_DEPLOYMENT_ROLE`, `DATABASE_URL`,
`SECRET_KEY_BASE`, `PHX_HOST` and `BASE_READ_RPC_URL` (the REGENT facts panel and the other
public Base reads still go to real Base, labelled as such). Fork mode adds:

| Variable | Required | Default | What it is |
| --- | --- | --- | --- |
| `AUTOLAUNCH_CHAIN_MODE` | Yes, `fork` | `base` | Selects the mode. Anything but `base` or `fork` stops the boot. |
| `AUTOLAUNCH_LAB_CONFIG` | Yes | — | Absolute path of the Agent fork configuration (`site-config.json`). |
| `AUTOLAUNCH_STOCKS_LAB_CONFIG` | Yes | — | Absolute path of the Stocks fork configuration (`stocks-site-config.json`); its `agent_lab_config` must equal `AUTOLAUNCH_LAB_CONFIG`. |
| `AUTOLAUNCH_FORK_RUN_ID` | Yes | — | A label for this fork run. It travels in every envelope's lab binding, so a review made against one run never confirms against another. (The same variable labels a local lab run.) |
| `AUTOLAUNCH_FAUCET_COOLDOWN_SECONDS` | No | `3600` in fork mode, `0` in base mode | At most one test-funds grant per wallet and asset within this many seconds; `0` disables the cooldown. Must be a non-negative integer. |
| `AUTOLAUNCH_DEPLOYMENT_ROLE` | Yes (unchanged) | — | `staging` for a preview. The production database pin (`regents_prod` on the approved cluster with the runtime login) applies only to `production`; with `staging`, `Autolaunch.DatabaseConfig.runtime_config!/2` accepts any valid PostgreSQL URL and still refuses `DATABASE_DIRECT_URL` on the serving app (`core_tests/elixir/autolaunch/database_config_test.exs` covers the staging path). The pin itself is not weakened. |
| `AUTOLAUNCH_DB_SCHEMA` | Yes for a bootstrapped database | `public` | `autolaunch_app` when the preview database was initialised with `/app/bin/bootstrap`. |
| `PRIVY_APP_ID`, `PRIVY_VERIFICATION_KEY` | For sign-in | — | The Privy application the preview hostname is allowed on. Production verifier as on the public site. |

`AUTOLAUNCH_LAB_AUTH` and `AUTOLAUNCH_BROWSER_TEST` are test-environment switches and do not
apply to a production build.

## Configuration files

The fork host writes the same two files the lab controllers write
(`contracts/v1/bin/local-base-lab.py` and `contracts/stocks/bin/local-stocks-lab.py deploy`),
with three differences:

- `rpc_url` in both files is the private door (`http://<fork-app>.internal:8545` on Fly, or an
  `https://` URL the host restricts to the site).
- `public_rpc_url` in both files is the wallet door (`https://…`), identical in both.
- `agent_lab_config` in the Stocks file is the path the Agent file has inside the image:
  `/app/fork/site-config.json`.

Everything else (`chain_id` 31337, the address sets, the ABIs, `faucet`, `stocks`) is validated
exactly as for a lab (`Autolaunch.Lab.load/2`, `Autolaunch.Stocks.Lab.load/2`).

## Faucet cooldown

The test-funds panel keeps every button (1,000 REGENT, the launch-fee REGENT, each admitted
stock, USDC) and every press still sends. With a cooldown above zero, one asset goes to one
wallet at most once per window: `Autolaunch.Stocks.FaucetCooldown` reads and locks the last
grant of that asset to that wallet (`Autolaunch.Stocks.FaucetGrant`, table `faucet_grants`:
`wallet`, `asset`, `granted_at`), refuses a press inside the window with "That test asset was
already sent to this wallet recently; try again after HH:MM UTC.", and otherwise sends the
grant and replaces the row in the same database transaction. A send that fails records nothing,
so the next press is not penalised. Nothing is disabled in the browser; the check happens on the
press. The assets are `regent`, `regent_launch_fee`, `usdc` and each stock's address.

The faucet refuses on a read-only site or without a lab, so a `base`-mode production build
never funds anyone.

## Building and deploying the preview image

No deployment is performed here. Once the fork host exists and has written the two files:

1. Build and accept the production image exactly as [README.md](../README.md) describes; the
   preview reuses that digest unchanged.
2. Assemble a small build context: `Dockerfile.preview` and a `fork/` directory holding
   `site-config.json` and `stocks-site-config.json`. The private `rpc_url` inside them is a
   secret of the fork host; treat the context and the resulting image accordingly.
3. Build the preview image on top of the accepted digest:

   ```sh
   docker build -f Dockerfile.preview \
     --build-arg AUTOLAUNCH_IMAGE=registry.fly.io/autolaunch-sh@sha256:<accepted digest> \
     -t registry.fly.io/autolaunch-preview:<tag> /absolute/preview-context
   ```

   The only layer it adds is `COPY fork /app/fork`; the release, ERTS and assets are the
   production image's own.
4. Prepare the preview database once, on a disposable database of its own, never the
   production one: run `/app/bin/bootstrap` from a one-off machine with `DATABASE_DIRECT_URL`,
   `AUTOLAUNCH_DEPLOYMENT_ROLE=staging`, `AUTOLAUNCH_DB_SCHEMA=autolaunch_app` and
   `AUTOLAUNCH_BOOTSTRAP_DATABASE=<its name>`, as the shared-database section of the README
   describes. Later schema changes run `/app/bin/migrate` the same way. Neither command runs
   on a serving machine, and the serving app never holds `DATABASE_DIRECT_URL`.
5. Deploy with `fly.preview.toml` (app `autolaunch-preview`, `PHX_HOST` placeholder
   `preview.autolaunch.sh`, `AUTOLAUNCH_DEPLOYMENT_ROLE=staging`, `AUTOLAUNCH_CHAIN_MODE=fork`,
   the two `/app/fork/...` paths, `AUTOLAUNCH_FORK_RUN_ID=preview`, the production vm and health
   settings): `fly deploy --app autolaunch-preview --config fly.preview.toml --image <preview
   digest> --ha=false`. The app's secrets are `DATABASE_URL`, `SECRET_KEY_BASE`,
   `BASE_READ_RPC_URL`, `PRIVY_APP_ID` and `PRIVY_VERIFICATION_KEY`.
6. Check `/healthz`, that every page carries "Preview on a Base fork · test assets · no mainnet
   value · sign in with Privy", that `/create/stocks` answers 200, and that a wallet prompted to
   add the network is offered "Autolaunch preview (Base fork)" with the public door only.

A fresh fork is a fresh database: when the fork host restarts from a new block, bootstrap a new
preview database rather than migrating or reusing the old one, exactly as for a local lab.

## Running fork mode locally

The test environment can run fork mode against a local Anvil to check the server side
without a hosted fork. Copy the lab's two files, add `"public_rpc_url": "https://…"` to both,
and start the site with `AUTOLAUNCH_CHAIN_MODE=fork` and no serve script:

```sh
env -u DATABASE_URL -u DATABASE_DIRECT_URL MIX_ENV=test REGENT_DEPS_ROOT=/absolute/path/to/repos \
  MIX_TEST_PARTITION=_fork_mode AUTOLAUNCH_BROWSER_TEST=1 AUTOLAUNCH_DB_POOL_SIZE=3 PORT=4090 \
  AUTOLAUNCH_CHAIN_MODE=fork \
  AUTOLAUNCH_LAB_CONFIG=/tmp/fork/site-config.json \
  AUTOLAUNCH_STOCKS_LAB_CONFIG=/tmp/fork/stocks-site-config.json \
  AUTOLAUNCH_FORK_RUN_ID=fork-local PRIVY_APP_ID=browser-test-public-id \
  sh -c 'mix ash.setup && mix phx.server'
```

The browser side is not exercised this way (wallets would be pointed at the placeholder
`public_rpc_url`); the server reads the loopback `rpc_url`.
