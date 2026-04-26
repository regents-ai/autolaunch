# Regent Staking, Autolaunch Testnet, and Local Test Deploy Guide

This is the current operator path:

1. deploy or confirm Regent staking on Base mainnet
2. deploy the Autolaunch shared launch contracts on Base Sepolia
3. run the local apps against those values
4. test the CLI through SIWA sign-in and the saved Agent account
5. optionally deploy the Autolaunch Base Sepolia rehearsal app to Fly

The important split is:

- Regent staking is Base mainnet.
- Autolaunch launch rehearsal is Base Sepolia.
- The first Base Sepolia launch creates the agent token, auction, vesting wallet, revenue splitter, and default ingress from the configured launch script.

Do not copy Base Sepolia launch addresses into the Base mainnet staking rail.

Use the shared beta run sheet as the stop/go record:

- `/Users/sean/Documents/regent/docs/public-beta-run-sheet.md`

## Done Means

- Foundry tests pass before any contract deploy.
- The Base mainnet staking address is saved once and copied into the right app variable names.
- Base Sepolia Autolaunch infra addresses are saved from the deploy output.
- Local Autolaunch starts, `mix autolaunch.doctor` passes, and the app reads the Base mainnet staking rail.
- The CLI signs in through SIWA, saves an Agent account, and can read Autolaunch plus Regent staking through the local app.
- A guided Base Sepolia launch reaches a real job and passes post-deploy verification.

## Operator Rules

- Never paste private keys into committed files.
- Never commit `.env`, `.env.local`, Foundry broadcast files with secrets, or Fly secrets.
- Use Foundry for contract deploys and contract tests.
- Use the Regents CLI guided launch path for launch work.
- Keep raw launch commands for debugging only.
- Record every deployed address immediately after each deploy.
- Use one terminal for local shell exports and one terminal for long-running servers.

## Files In This Repo

Autolaunch includes Fly-ready support files:

- `Dockerfile`: builds the Phoenix release from the Regent repo root and includes Foundry for runtime launch jobs.
- `Dockerfile.dragonfly`: builds a small Dragonfly cache service.
- `fly.phoenix.toml`: Phoenix app template.
- `fly.dragonfly.toml`: Dragonfly service template.
- `rel/overlays/bin/server`: starts the release with `PHX_SERVER=true`.
- `rel/overlays/bin/migrate`: runs database migrations in the release.

The Docker build context must be the Regent repo root because Autolaunch depends on sibling local packages.

## 0. Local Tooling Checklist

Install these before starting:

```bash
brew install flyctl
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Check the tools:

```bash
fly version
forge --version
cast --version
elixir --version
mix --version
node --version
pnpm --version
```

Check Fly auth if you will deploy to Fly:

```bash
fly auth whoami
```

## 1. Fast Environment Map

Use this section to find every value before editing private env files or setting Fly secrets.

### Base Mainnet Regent Staking

These values are used by `autolaunch/contracts/scripts/DeployRegentRevenueStaking.s.sol`. The script only runs on Base mainnet.

| Env var | Value source | Put it in |
| --- | --- | --- |
| `BASE_MAINNET_RPC_URL` | Base mainnet RPC provider | deploy shell, CLI submit shell |
| `PRIVATE_KEY` | deployer wallet for the Foundry broadcast | deploy shell only |
| `BASE_REGENT_TOKEN_ADDRESS` | live `$REGENT` token on Base mainnet | deploy shell |
| `BASE_USDC_ADDRESS` | Base mainnet USDC, `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | deploy shell |
| `REGENT_REVENUE_TREASURY_ADDRESS` | treasury recipient | deploy shell, private address sheet |
| `REGENT_REVENUE_GOVERNANCE_SAFE_ADDRESS` | governance Safe | deploy shell, private address sheet |
| `REGENT_REVENUE_SUPPLY_DENOMINATOR` | raw `$REGENT` denominator, usually total supply in 18-decimal units | deploy shell |
| `REGENT_REVENUE_STAKER_SHARE_BPS` | current script requires `10000` | deploy shell |

Save the deploy result:

| Deploy result field | Autolaunch env name | Platform env name |
| --- | --- | --- |
| `contractAddress` | `REGENT_REVENUE_STAKING_ADDRESS` | `REGENT_STAKING_CONTRACT_ADDRESS` |
| Base mainnet RPC URL | `REGENT_STAKING_RPC_URL` | `REGENT_STAKING_RPC_URL` |
| Chain id | `REGENT_STAKING_CHAIN_ID=8453` | `REGENT_STAKING_CHAIN_ID=8453` |
| Chain label | `REGENT_STAKING_CHAIN_LABEL=Base` | `REGENT_STAKING_CHAIN_LABEL=Base` |

Platform also needs:

| Env var | Value source |
| --- | --- |
| `REGENT_STAKING_OPERATOR_WALLETS` | comma-separated operator wallets allowed to prepare treasury actions |
| `BASE_RPC_URL` | Base mainnet RPC for token reads and ENS-related Base reads |
| `SIWA_SERVER_BASE_URL` | shared SIWA server URL |

Autolaunch also needs:

| Env var | Value source |
| --- | --- |
| `AUTOLAUNCH_BASE_MAINNET_RPC_URL` | Base mainnet RPC, used for Base identity lookups |
| `BASE_MAINNET_RPC_URL` | Base mainnet RPC, used by AgentBook and CLI submit paths |

### Base Sepolia Autolaunch Contracts

These values are used by `autolaunch/contracts/scripts/DeployAutolaunchInfra.s.sol` and the launch script.

| Env var | Value source |
| --- | --- |
| `AUTOLAUNCH_CHAIN_ID` | `84532` for this rehearsal |
| `AUTOLAUNCH_RPC_URL` | Base Sepolia RPC provider |
| `AUTOLAUNCH_BASE_SEPOLIA_RPC_URL` | same Base Sepolia RPC, used by verifier address books |
| `BASE_SEPOLIA_RPC_URL` | same Base Sepolia RPC, used by AgentBook and CLI submit paths |
| `AUTOLAUNCH_USDC_ADDRESS` | Base Sepolia USDC, `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| `AUTOLAUNCH_INFRA_OWNER` | owner for the shared infra deploy |
| `PRIVATE_KEY` | deployer wallet for the Foundry broadcast |
| `AUTOLAUNCH_CCA_FACTORY_ADDRESS` | CCA factory, currently `0xCCccCcCAE7503Cac057829BF2811De42E16e0bD5` unless redeployed |
| `AUTOLAUNCH_UNISWAP_V4_POOL_MANAGER` | Base Sepolia Uniswap v4 pool manager |
| `AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER` | Base Sepolia Uniswap v4 position manager |
| `AUTOLAUNCH_TOKEN_FACTORY_ADDRESS` | token factory used by the launch script |
| `AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS` | ERC-8004 identity registry for launch validation |
| `AUTOLAUNCH_ERC8004_SUBGRAPH_URL` | ERC-8004 subgraph URL |
| `REGENT_MULTISIG_ADDRESS` | Regent recipient for protocol-side fees |
| `STRATEGY_OPERATOR` | launch strategy operator |
| `OFFICIAL_POOL_FEE` | official pool fee, usually `0` in the current script |
| `OFFICIAL_POOL_TICK_SPACING` | official pool tick spacing, usually `60` |
| `CCA_FLOOR_PRICE_Q96` | CCA pricing input |
| `CCA_TICK_SPACING_Q96` | CCA pricing input |
| `CCA_REQUIRED_CURRENCY_RAISED` | minimum raise in raw USDC units; the guided plan can set this per launch |
| `CCA_VALIDATION_HOOK` | optional validation hook address |
| `CCA_CLAIM_BLOCK_OFFSET` | claim offset, `0` or the intended launch value |

Save the shared infra deploy result:

| Deploy result field | App env name |
| --- | --- |
| `revenueShareFactoryAddress` | `AUTOLAUNCH_REVENUE_SHARE_FACTORY_ADDRESS` and `AUTOLAUNCH_BASE_SEPOLIA_REVENUE_SHARE_FACTORY_ADDRESS` |
| `revenueIngressFactoryAddress` | `AUTOLAUNCH_REVENUE_INGRESS_FACTORY_ADDRESS` and `AUTOLAUNCH_BASE_SEPOLIA_REVENUE_INGRESS_FACTORY_ADDRESS` |
| `strategyFactoryAddress` | `AUTOLAUNCH_LBP_STRATEGY_FACTORY_ADDRESS` |
| `subjectRegistryAddress` | save in the private address sheet |
| `usdcAddress` | confirm it is Base Sepolia canonical USDC |
| `owner` | save in the private address sheet |

### App Runtime And Auth

Autolaunch local and Fly values:

| Env var | Value source |
| --- | --- |
| `DATABASE_URL` or `LOCAL_DATABASE_URL` | local Postgres or Fly Postgres |
| `SECRET_KEY_BASE` | `mix phx.gen.secret` |
| `PHX_HOST` | `127.0.0.1` locally, final host on Fly |
| `PORT` | `4002` locally, Fly internal port from `fly.phoenix.toml` |
| `PRIVY_APP_ID` | Privy dashboard |
| `PRIVY_VERIFICATION_KEY` | Privy dashboard |
| `AUTOLAUNCH_XMTP_AGENT_PRIVATE_KEY` | private key for the public room agent |
| `SIWA_INTERNAL_URL` | shared SIWA server URL reachable from Autolaunch |
| `SIWA_SHARED_SECRET` | required for Autolaunch production startup |
| `DRAGONFLY_ENABLED` | `false` locally unless using Dragonfly, `true` on Fly |
| `DRAGONFLY_HOST` | Dragonfly host when enabled |
| `DRAGONFLY_PORT` | usually `6379` |

Shared SIWA server values:

| Env var | Value source |
| --- | --- |
| `DATABASE_URL` | SIWA Postgres |
| `SECRET_KEY_BASE` | `mix phx.gen.secret` |
| `SIWA_RECEIPT_SECRET` | private receipt signing secret |
| `KEYSTORE_PASSWORD` | key store password |
| `KEYRING_PROXY_SECRET` | private keyring proxy secret |
| `BASE_RPC_URL` | Base mainnet RPC for Agent account checks |

Platform local and Fly staking values:

| Env var | Value source |
| --- | --- |
| `REGENT_STAKING_CONTRACT_ADDRESS` | Base mainnet staking `contractAddress` |
| `REGENT_STAKING_RPC_URL` | Base mainnet RPC |
| `REGENT_STAKING_CHAIN_ID` | `8453` |
| `REGENT_STAKING_CHAIN_LABEL` | `Base` |
| `REGENT_STAKING_OPERATOR_WALLETS` | comma-separated operator wallets |
| `SIWA_SERVER_BASE_URL` | shared SIWA server URL |
| `BASE_RPC_URL` | Base mainnet RPC |

## 2. Validate Contracts Locally

```bash
cd /Users/sean/Documents/regent/autolaunch/contracts
forge fmt --check
forge build
forge test
```

Optional local dry run:

```bash
forge test --match-contract ExampleCCADeploymentScriptTest --offline -vvv
```

Stop if tests fail.

## 3. Deploy Regent Staking On Base Mainnet

Set deploy inputs:

```bash
cd /Users/sean/Documents/regent/autolaunch/contracts

export BASE_MAINNET_RPC_URL=...
export BASE_REGENT_TOKEN_ADDRESS=...
export BASE_USDC_ADDRESS=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
export REGENT_REVENUE_TREASURY_ADDRESS=...
export REGENT_REVENUE_GOVERNANCE_SAFE_ADDRESS=...
export REGENT_REVENUE_SUPPLY_DENOMINATOR=100000000000000000000000000000
export REGENT_REVENUE_STAKER_SHARE_BPS=10000
export PRIVATE_KEY=...
```

Important defaults:

- `REGENT_REVENUE_STAKER_SHARE_BPS=10000` is required by the current deploy script.
- `REGENT_REVENUE_SUPPLY_DENOMINATOR=100000000000000000000000000000` means 100 billion tokens in raw 18-decimal units. Change it only if the live `$REGENT` supply denominator is different.

Deploy:

```bash
forge script scripts/DeployRegentRevenueStaking.s.sol:DeployRegentRevenueStakingScript \
  --rpc-url "$BASE_MAINNET_RPC_URL" \
  --broadcast
```

Save the `REGENT_REVENUE_STAKING_RESULT_JSON` output:

```text
contractAddress
regentTokenAddress
usdcAddress
treasuryRecipient
owner
revenueShareSupplyDenominator
stakerShareBps
```

Use `contractAddress` as:

```bash
# Autolaunch
export REGENT_REVENUE_STAKING_ADDRESS=<contractAddress>

# Platform
export REGENT_STAKING_CONTRACT_ADDRESS=<contractAddress>
```

## 4. Deploy Shared Autolaunch Infra On Base Sepolia

Set deploy inputs:

```bash
cd /Users/sean/Documents/regent/autolaunch/contracts

export AUTOLAUNCH_RPC_URL=...
export AUTOLAUNCH_USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e
export AUTOLAUNCH_INFRA_OWNER=...
export PRIVATE_KEY=...
```

Deploy:

```bash
forge script scripts/DeployAutolaunchInfra.s.sol:DeployAutolaunchInfraScript \
  --rpc-url "$AUTOLAUNCH_RPC_URL" \
  --broadcast
```

Save the `AUTOLAUNCH_INFRA_RESULT_JSON` output:

```text
subjectRegistryAddress
revenueShareFactoryAddress
revenueIngressFactoryAddress
strategyFactoryAddress
usdcAddress
owner
```

Map those into app env:

```bash
export AUTOLAUNCH_REVENUE_SHARE_FACTORY_ADDRESS=<revenueShareFactoryAddress>
export AUTOLAUNCH_REVENUE_INGRESS_FACTORY_ADDRESS=<revenueIngressFactoryAddress>
export AUTOLAUNCH_LBP_STRATEGY_FACTORY_ADDRESS=<strategyFactoryAddress>

export AUTOLAUNCH_BASE_SEPOLIA_REVENUE_SHARE_FACTORY_ADDRESS=<revenueShareFactoryAddress>
export AUTOLAUNCH_BASE_SEPOLIA_REVENUE_INGRESS_FACTORY_ADDRESS=<revenueIngressFactoryAddress>
```

Keep `subjectRegistryAddress` recorded in the private operator note.

## 5. Create The Local Autolaunch Environment

Start from the checked-in example:

```bash
cd /Users/sean/Documents/regent/autolaunch
cp .env.example .env.local
direnv allow
```

Fill `.env.local` with local-safe values:

```bash
export DATABASE_URL=ecto://postgres:postgres@localhost/autolaunch_dev
export SECRET_KEY_BASE=replace_me_with_mix_phx_gen_secret_output
export PHX_HOST=127.0.0.1
export PORT=4002

export PRIVY_APP_ID=...
export PRIVY_VERIFICATION_KEY=...
export AUTOLAUNCH_XMTP_AGENT_PRIVATE_KEY=...

export SIWA_INTERNAL_URL=http://127.0.0.1:4100
export SIWA_SHARED_SECRET=...

export DRAGONFLY_ENABLED=false

export AUTOLAUNCH_CHAIN_ID=84532
export AUTOLAUNCH_RPC_URL=...
export AUTOLAUNCH_CCA_FACTORY_ADDRESS=0xCCccCcCAE7503Cac057829BF2811De42E16e0bD5
export AUTOLAUNCH_UNISWAP_V4_POOL_MANAGER=...
export AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER=...
export AUTOLAUNCH_USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e
export AUTOLAUNCH_REVENUE_SHARE_FACTORY_ADDRESS=...
export AUTOLAUNCH_REVENUE_INGRESS_FACTORY_ADDRESS=...
export AUTOLAUNCH_LBP_STRATEGY_FACTORY_ADDRESS=...
export AUTOLAUNCH_TOKEN_FACTORY_ADDRESS=...
export AUTOLAUNCH_ERC8004_SUBGRAPH_URL=...
export AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS=...

export AUTOLAUNCH_BASE_SEPOLIA_RPC_URL=...
export AUTOLAUNCH_BASE_SEPOLIA_UNISWAP_V4_POOL_MANAGER=...
export AUTOLAUNCH_BASE_SEPOLIA_REVENUE_SHARE_FACTORY_ADDRESS=...
export AUTOLAUNCH_BASE_SEPOLIA_REVENUE_INGRESS_FACTORY_ADDRESS=...
export AUTOLAUNCH_BASE_SEPOLIA_ERC8004_SUBGRAPH_URL=...
export AUTOLAUNCH_BASE_SEPOLIA_IDENTITY_REGISTRY_ADDRESS=...

export AUTOLAUNCH_BASE_MAINNET_RPC_URL=...
export AUTOLAUNCH_BASE_MAINNET_UNISWAP_V4_POOL_MANAGER=...
export AUTOLAUNCH_BASE_MAINNET_REVENUE_SHARE_FACTORY_ADDRESS=...
export AUTOLAUNCH_BASE_MAINNET_REVENUE_INGRESS_FACTORY_ADDRESS=...
export AUTOLAUNCH_BASE_MAINNET_ERC8004_SUBGRAPH_URL=...
export AUTOLAUNCH_BASE_MAINNET_IDENTITY_REGISTRY_ADDRESS=...

export AUTOLAUNCH_DEPLOY_WORKDIR=/Users/sean/Documents/regent/autolaunch/contracts
export AUTOLAUNCH_DEPLOY_BINARY=forge
export AUTOLAUNCH_DEPLOY_SCRIPT_TARGET=scripts/ExampleCCADeploymentScript.s.sol:ExampleCCADeploymentScript
export AUTOLAUNCH_DEPLOY_TIMEOUT_MS=180000
export AUTOLAUNCH_DEPLOY_PRIVATE_KEY=...
export AUTOLAUNCH_MOCK_DEPLOY=false

export REGENT_STAKING_RPC_URL=...
export REGENT_STAKING_CHAIN_ID=8453
export REGENT_STAKING_CHAIN_LABEL=Base
export REGENT_REVENUE_STAKING_ADDRESS=...

export REGENT_MULTISIG_ADDRESS=...
export STRATEGY_OPERATOR=...
export OFFICIAL_POOL_FEE=0
export OFFICIAL_POOL_TICK_SPACING=60
export CCA_FLOOR_PRICE_Q96=...
export CCA_TICK_SPACING_Q96=...
export CCA_REQUIRED_CURRENCY_RAISED=...
export CCA_VALIDATION_HOOK=...
export CCA_CLAIM_BLOCK_OFFSET=0

export WORLD_ID_APP_ID=...
export WORLD_ID_ACTION=agentbook-registration
export WORLD_ID_RP_ID=...
export WORLD_ID_SIGNING_KEY=...
export WORLD_ID_TTL_SECONDS=300

export BASE_MAINNET_RPC_URL=...
export BASE_AGENTBOOK_ADDRESS=...
export BASE_AGENTBOOK_RELAY_URL=...

export BASE_SEPOLIA_RPC_URL=...
export BASE_SEPOLIA_AGENTBOOK_ADDRESS=...
export BASE_SEPOLIA_AGENTBOOK_RELAY_URL=...
```

Generate a local secret if needed:

```bash
mix phx.gen.secret
```

## 6. Run The Shared SIWA Server Locally

Protected CLI commands use SIWA. For local testing, run the SIWA server on the same URL used by `SIWA_INTERNAL_URL` and the CLI config.

```bash
cd /Users/sean/Documents/regent/siwa-server

export PORT=4100
export DATABASE_URL=ecto://postgres:postgres@localhost/siwa_server_dev
export SECRET_KEY_BASE=replace_me_with_mix_phx_gen_secret_output
export SIWA_RECEIPT_SECRET=...
export KEYSTORE_PASSWORD=...
export KEYRING_PROXY_SECRET=...
export BASE_RPC_URL=...

mix setup
mix phx.server
```

Keep this server running while testing protected CLI commands.

## 7. Boot And Validate Autolaunch Locally

```bash
cd /Users/sean/Documents/regent/autolaunch
mix setup
mix autolaunch.doctor
mix phx.server
```

Check pages:

```bash
open http://127.0.0.1:4002/health
open http://127.0.0.1:4002/
open http://127.0.0.1:4002/launch
open http://127.0.0.1:4002/auctions
open http://127.0.0.1:4002/positions
open http://127.0.0.1:4002/contracts
open http://127.0.0.1:4002/agentbook
```

Check JSON reads:

```bash
curl -s http://127.0.0.1:4002/health
curl -s http://127.0.0.1:4002/api/regent/staking
curl -s http://127.0.0.1:4002/api/regent/staking/account/0xYOUR_WALLET
```

## 8. Optional Platform Local Staking Check

Platform uses a different env name for the same Base mainnet staking contract.

```bash
cd /Users/sean/Documents/regent/platform

export DATABASE_URL=ecto://postgres:postgres@localhost/platform_phx_dev
export SECRET_KEY_BASE=replace_me_with_mix_phx_gen_secret_output
export PORT=4000
export PHX_HOST=127.0.0.1
export BASE_RPC_URL=...
export SIWA_SERVER_BASE_URL=http://127.0.0.1:4100
export REGENT_STAKING_RPC_URL=...
export REGENT_STAKING_CHAIN_ID=8453
export REGENT_STAKING_CHAIN_LABEL=Base
export REGENT_STAKING_CONTRACT_ADDRESS=...
export REGENT_STAKING_OPERATOR_WALLETS=0x...

mix setup
mix phx.server
```

Check:

```bash
open http://127.0.0.1:4000/token-info
curl -s http://127.0.0.1:4000/healthz
curl -s http://127.0.0.1:4000/readyz
```

## 9. Bootstrap The Autolaunch XMTP Room Once

```bash
cd /Users/sean/Documents/regent/autolaunch
mix autolaunch.bootstrap_xmtp_room
```

If the room already exists and you want to keep it:

```bash
mix autolaunch.bootstrap_xmtp_room --reuse
```

Record:

```text
room key
conversation id
agent wallet
agent inbox
```

## 10. Validate Regents CLI Against The Local App

Build and test the CLI:

```bash
cd /Users/sean/Documents/regent/regents-cli
pnpm build
pnpm typecheck
pnpm test
```

Set the app URL:

```bash
export AUTOLAUNCH_BASE_URL=http://127.0.0.1:4002
```

Use a local CLI config whose `auth.baseUrl` points at the SIWA server:

```json
{
  "auth": {
    "baseUrl": "http://127.0.0.1:4100",
    "audience": "autolaunch",
    "defaultChainId": 84532,
    "requestTimeoutMs": 10000
  },
  "wallet": {
    "privateKeyEnv": "REGENT_WALLET_PRIVATE_KEY",
    "keystorePath": "~/.regent/keys/agent-wallet.json"
  }
}
```

Then sign in for Autolaunch and save the Agent account:

```bash
export REGENT_WALLET_PRIVATE_KEY=...

pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json auth login --audience autolaunch
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json identity ensure --network base-sepolia
```

Run local read checks:

```bash
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json autolaunch agents list
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json autolaunch auctions list
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json autolaunch contracts admin
```

For Regent staking commands, sign in with the shared-services audience, then read the same local app:

```bash
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json auth login --audience regent-services
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json identity ensure --network base
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json regent-staking show
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json regent-staking account 0xYOUR_WALLET
```

## 11. Run The First Guided Base Sepolia Launch

Use the guided path:

```bash
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json auth login --audience autolaunch
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json identity ensure --network base-sepolia
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json autolaunch safe wizard --backup-signer-address 0x...
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json autolaunch safe create --backup-signer-address 0x... --website-wallet-address 0x...
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json autolaunch prelaunch wizard --agent <agent-id> --name "Agent Coin Name" --symbol "AGENT" --agent-safe-address <safe-address>
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json autolaunch prelaunch validate --plan <plan-id>
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json autolaunch prelaunch publish --plan <plan-id>
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json autolaunch launch run --plan <plan-id>
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json autolaunch launch monitor --job <job-id> --watch
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json autolaunch launch finalize --job <job-id> --submit
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json autolaunch vesting status --job <job-id>
```

The app injects the per-launch values from the saved plan into the Foundry script, including:

- `AUTOLAUNCH_AGENT_ID`
- `AUTOLAUNCH_AGENT_SAFE_ADDRESS`
- `AUTOLAUNCH_TOKEN_NAME`
- `AUTOLAUNCH_TOKEN_SYMBOL`
- `AUTOLAUNCH_TOTAL_SUPPLY`
- `CCA_REQUIRED_CURRENCY_RAISED`

Keep these as debug-only commands:

```bash
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json autolaunch launch preview
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json autolaunch launch create
pnpm --filter @regentslabs/cli exec regents --config /absolute/path/to/local-regents.config.json autolaunch jobs watch
```

## 12. Verify The Real Deployed Launch

Local verification:

```bash
cd /Users/sean/Documents/regent/autolaunch
mix autolaunch.verify_deploy --job <job-id>
```

The verifier checks:

- controller resolution from the deploy receipt
- controller authorization cleanup in shared factories
- accepted ownership on the fee contracts
- accepted ownership on the revenue splitter
- fee-vault token wiring
- completed strategy migration
- recorded pool and position ids
- hook-enabled state
- subject and ingress wiring

## 13. Optional Fly Rehearsal Deploy

Use this after the local app and CLI checks are green.

Pick names before running commands:

```bash
export FLY_ORG=personal
export FLY_REGION=sjc
export AUTOLAUNCH_FLY_APP=autolaunch-sepolia
export AUTOLAUNCH_DRAGONFLY_APP=autolaunch-sepolia-dragonfly
```

Edit before first deploy:

- `fly.phoenix.toml`: set `app = "<AUTOLAUNCH_FLY_APP>"`
- `fly.dragonfly.toml`: set `app = "<AUTOLAUNCH_DRAGONFLY_APP>"`
- `fly.phoenix.toml`: set `PHX_HOST` to the final host
- `fly.phoenix.toml`: set `DRAGONFLY_HOST` to the private hostname printed after Dragonfly deploy

Create apps:

```bash
fly apps create "$AUTOLAUNCH_DRAGONFLY_APP" --org "$FLY_ORG"
fly apps create "$AUTOLAUNCH_FLY_APP" --org "$FLY_ORG"
```

Create Postgres if this is a new Fly environment:

```bash
fly postgres create \
  --name autolaunch-sepolia-db \
  --region "$FLY_REGION" \
  --org "$FLY_ORG"

fly postgres attach autolaunch-sepolia-db --app "$AUTOLAUNCH_FLY_APP"
```

After `postgres attach`, Fly sets `DATABASE_URL` for the app.

Deploy Dragonfly from the Regent repo root:

```bash
cd /Users/sean/Documents/regent
fly deploy --config autolaunch/fly.dragonfly.toml .
```

Set Phoenix secrets. Replace placeholders before running:

```bash
fly secrets set --app "$AUTOLAUNCH_FLY_APP" \
  SECRET_KEY_BASE=... \
  PHX_HOST=... \
  PORT=8080 \
  PHX_SERVER=true \
  DRAGONFLY_ENABLED=true \
  DRAGONFLY_HOST="$AUTOLAUNCH_DRAGONFLY_APP.internal" \
  DRAGONFLY_PORT=6379 \
  AUTOLAUNCH_CHAIN_ID=84532 \
  AUTOLAUNCH_RPC_URL=... \
  AUTOLAUNCH_BASE_SEPOLIA_RPC_URL=... \
  AUTOLAUNCH_CCA_FACTORY_ADDRESS=... \
  AUTOLAUNCH_UNISWAP_V4_POOL_MANAGER=... \
  AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER=... \
  AUTOLAUNCH_USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e \
  AUTOLAUNCH_REVENUE_SHARE_FACTORY_ADDRESS=... \
  AUTOLAUNCH_REVENUE_INGRESS_FACTORY_ADDRESS=... \
  AUTOLAUNCH_LBP_STRATEGY_FACTORY_ADDRESS=... \
  AUTOLAUNCH_TOKEN_FACTORY_ADDRESS=... \
  AUTOLAUNCH_ERC8004_SUBGRAPH_URL=... \
  AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS=... \
  AUTOLAUNCH_BASE_SEPOLIA_UNISWAP_V4_POOL_MANAGER=... \
  AUTOLAUNCH_BASE_SEPOLIA_REVENUE_SHARE_FACTORY_ADDRESS=... \
  AUTOLAUNCH_BASE_SEPOLIA_REVENUE_INGRESS_FACTORY_ADDRESS=... \
  AUTOLAUNCH_BASE_SEPOLIA_ERC8004_SUBGRAPH_URL=... \
  AUTOLAUNCH_BASE_SEPOLIA_IDENTITY_REGISTRY_ADDRESS=... \
  AUTOLAUNCH_BASE_MAINNET_RPC_URL=... \
  AUTOLAUNCH_BASE_MAINNET_UNISWAP_V4_POOL_MANAGER=... \
  AUTOLAUNCH_BASE_MAINNET_REVENUE_SHARE_FACTORY_ADDRESS=... \
  AUTOLAUNCH_BASE_MAINNET_REVENUE_INGRESS_FACTORY_ADDRESS=... \
  AUTOLAUNCH_BASE_MAINNET_ERC8004_SUBGRAPH_URL=... \
  AUTOLAUNCH_BASE_MAINNET_IDENTITY_REGISTRY_ADDRESS=... \
  AUTOLAUNCH_DEPLOY_WORKDIR=/app/contracts \
  AUTOLAUNCH_DEPLOY_BINARY=forge \
  AUTOLAUNCH_DEPLOY_SCRIPT_TARGET=scripts/ExampleCCADeploymentScript.s.sol:ExampleCCADeploymentScript \
  AUTOLAUNCH_DEPLOY_TIMEOUT_MS=180000 \
  AUTOLAUNCH_DEPLOY_PRIVATE_KEY=... \
  AUTOLAUNCH_MOCK_DEPLOY=false \
  REGENT_MULTISIG_ADDRESS=... \
  REGENT_STAKING_RPC_URL=... \
  REGENT_STAKING_CHAIN_ID=8453 \
  REGENT_STAKING_CHAIN_LABEL=Base \
  REGENT_REVENUE_STAKING_ADDRESS=... \
  PRIVY_APP_ID=... \
  PRIVY_VERIFICATION_KEY=... \
  AUTOLAUNCH_XMTP_AGENT_PRIVATE_KEY=... \
  SIWA_INTERNAL_URL=... \
  SIWA_SHARED_SECRET=... \
  STRATEGY_OPERATOR=... \
  OFFICIAL_POOL_FEE=0 \
  OFFICIAL_POOL_TICK_SPACING=60 \
  CCA_FLOOR_PRICE_Q96=... \
  CCA_TICK_SPACING_Q96=... \
  CCA_REQUIRED_CURRENCY_RAISED=... \
  CCA_VALIDATION_HOOK=... \
  CCA_CLAIM_BLOCK_OFFSET=0 \
  WORLD_ID_APP_ID=... \
  WORLD_ID_ACTION=agentbook-registration \
  WORLD_ID_RP_ID=... \
  WORLD_ID_SIGNING_KEY=... \
  WORLD_ID_TTL_SECONDS=300 \
  BASE_MAINNET_RPC_URL=... \
  BASE_AGENTBOOK_ADDRESS=... \
  BASE_AGENTBOOK_RELAY_URL=... \
  BASE_SEPOLIA_RPC_URL=... \
  BASE_SEPOLIA_AGENTBOOK_ADDRESS=... \
  BASE_SEPOLIA_AGENTBOOK_RELAY_URL=...
```

Check secret names without printing values:

```bash
fly secrets list --app "$AUTOLAUNCH_FLY_APP"
```

Deploy Phoenix from the Regent repo root:

```bash
cd /Users/sean/Documents/regent
fly deploy --config autolaunch/fly.phoenix.toml .
```

Run release checks:

```bash
fly ssh console --app "$AUTOLAUNCH_FLY_APP" -C "/app/bin/autolaunch eval 'Autolaunch.ReleaseDoctor.run() |> IO.inspect(label: :doctor)'"
curl -s https://<PHX_HOST>/health
curl -s https://<PHX_HOST>/api/regent/staking
```

Optional Fly smoke with mock deploy:

```bash
fly secrets set --app "$AUTOLAUNCH_FLY_APP" AUTOLAUNCH_MOCK_DEPLOY=true
fly deploy --config autolaunch/fly.phoenix.toml .
fly ssh console --app "$AUTOLAUNCH_FLY_APP" -C "/app/bin/autolaunch eval 'Autolaunch.ReleaseSmoke.run() |> IO.inspect(label: :smoke)'"
fly secrets set --app "$AUTOLAUNCH_FLY_APP" AUTOLAUNCH_MOCK_DEPLOY=false
fly deploy --config autolaunch/fly.phoenix.toml .
```

Do not leave `AUTOLAUNCH_MOCK_DEPLOY=true` on the rehearsal app.

## 14. Good Rehearsal Checklist

- [ ] `forge build` passed
- [ ] `forge fmt --check` passed
- [ ] `forge test` passed
- [ ] Base mainnet `$REGENT` token address confirmed
- [ ] Base mainnet Regent staking deploy result saved
- [ ] `REGENT_REVENUE_STAKING_ADDRESS` set in Autolaunch
- [ ] `REGENT_STAKING_CONTRACT_ADDRESS` set in Platform
- [ ] Base Sepolia shared Autolaunch infra deploy result saved
- [ ] local `.env.local` filled with Base mainnet staking and Base Sepolia launch values
- [ ] SIWA server running locally
- [ ] `mix autolaunch.doctor` passed locally
- [ ] local app reads the Base mainnet staking rail
- [ ] XMTP bootstrap output saved
- [ ] CLI signs in with `autolaunch` audience and reads local Autolaunch
- [ ] CLI signs in with `regent-services` audience and reads Regent staking
- [ ] guided launch flow reached a real Base Sepolia job
- [ ] launch monitor reached `ready`
- [ ] launch finalize completed or clearly reported the next action
- [ ] `mix autolaunch.verify_deploy --job <job-id>` passed
- [ ] Fly deploy completed only after local checks passed
- [ ] `AUTOLAUNCH_MOCK_DEPLOY=false` confirmed before real launch jobs

## 15. Fast Failure Map

| Symptom | First check |
| --- | --- |
| Regent staking deploy reverts with `BASE_MAINNET_ONLY` | you are not broadcasting on Base mainnet |
| Regent staking deploy reverts with `USDC_NOT_CANONICAL` | `BASE_USDC_ADDRESS` is not Base mainnet USDC |
| `mix autolaunch.doctor` fails | missing deploy env, RPC, factory, SIWA, or Foundry path |
| local app cannot read staking | check `REGENT_STAKING_RPC_URL` and `REGENT_REVENUE_STAKING_ADDRESS` |
| Platform cannot read staking | check `REGENT_STAKING_RPC_URL` and `REGENT_STAKING_CONTRACT_ADDRESS` |
| SIWA auth fails | check SIWA server URL, `auth.baseUrl` in CLI config, and the requested audience |
| CLI protected request fails only when query strings are present | confirm the CLI and app both sign and verify the full path with the query string |
| launch job cannot run `forge` | check `AUTOLAUNCH_DEPLOY_BINARY` and `AUTOLAUNCH_DEPLOY_WORKDIR` |
| launch job times out | raise `AUTOLAUNCH_DEPLOY_TIMEOUT_MS` |
| AgentBook fails on Base Sepolia | check `BASE_SEPOLIA_RPC_URL`, AgentBook address, relay URL, and World values |
| Dragonfly reads fail | check `DRAGONFLY_HOST`, private networking, and Dragonfly machine status |

## 16. Addresses To Save

Keep this table in a private operator note:

| Name | Address or value |
| --- | --- |
| Base mainnet `$REGENT` token | |
| Base mainnet USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Base mainnet Regent revenue staking | |
| Regent revenue treasury | |
| Regent revenue governance Safe | |
| Platform `REGENT_STAKING_CONTRACT_ADDRESS` | |
| Autolaunch `REGENT_REVENUE_STAKING_ADDRESS` | |
| Base Sepolia USDC | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| Base Sepolia subject registry | |
| Base Sepolia revenue share factory | |
| Base Sepolia revenue ingress factory | |
| Base Sepolia LBP strategy factory | |
| Base Sepolia token factory | |
| Base Sepolia CCA factory | |
| Base Sepolia Uniswap v4 pool manager | |
| Base Sepolia Uniswap v4 position manager | |
| Base Sepolia ERC-8004 identity registry | |
| Strategy operator | |
| Regent multisig | |
| SIWA server host | |
| Platform host | |
| Autolaunch host | |
| Fly Phoenix app | |
| Fly Dragonfly app | |
