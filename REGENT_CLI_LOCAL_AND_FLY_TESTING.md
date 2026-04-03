# Autolaunch + Regent CLI Local And Fly Testing

This guide reflects the current cutover:

- Autolaunch launch creation is Ethereum Sepolia only
- `regent autolaunch ...` talks directly to the Autolaunch HTTP API
- the app and the CLI should both assume chain ID `11155111`

Base Sepolia still exists in this repo for AgentBook and trust-check work. It is not the launch chain.

## What has to be running

Autolaunch is one Phoenix app for both the frontend and backend. To work end to end with `regent-cli`, you also need:

- Postgres
- Privy session exchange
- the SIWA sidecar
- the local Foundry contracts workspace
- a reachable Ethereum Sepolia RPC
- deployed launch support contracts on Ethereum Sepolia

Unlike Techtree, Autolaunch does not need the Regent runtime daemon for normal CLI use.

## Contract deployment steps

Validate the contracts first:

```bash
cd /Users/sean/Documents/regent/autolaunch/contracts
forge test --offline
```

Deploy the shared launch infrastructure on Sepolia and capture the addresses it prints:

```bash
cd /Users/sean/Documents/regent/autolaunch/contracts
export ETH_SEPOLIA_RPC_URL=...
export ETHEREUM_USDC_ADDRESS=...
export PRIVATE_KEY=...

forge script scripts/DeployAutolaunchInfra.s.sol:DeployAutolaunchInfra \
  --rpc-url "$ETH_SEPOLIA_RPC_URL" \
  --broadcast
```

The app needs the infrastructure addresses from that output:

- `REVENUE_SHARE_FACTORY_ADDRESS`
- `REVENUE_INGRESS_FACTORY_ADDRESS`
- `LBP_STRATEGY_FACTORY_ADDRESS`
- `TOKEN_FACTORY_ADDRESS`

For a representative live launch test, point `AUTOLAUNCH_DEPLOY_SCRIPT_TARGET` at the CCA deploy script target you want to run and keep `AUTOLAUNCH_MOCK_DEPLOY=false`.

If you only want an app smoke test first, set `AUTOLAUNCH_MOCK_DEPLOY=true`.

## Local app setup

Start from the checked-in example:

```bash
cd /Users/sean/Documents/regent/autolaunch
cp .env.example .env.local
direnv allow
```

Fill the required values:

- `DATABASE_URL` or `LOCAL_DATABASE_URL`
- `SECRET_KEY_BASE`
- `PHX_HOST`
- `PORT`
- `PRIVY_APP_ID`
- `PRIVY_VERIFICATION_KEY`
- `SIWA_INTERNAL_URL`
- `SIWA_SHARED_SECRET`
- `SIWA_HMAC_SECRET`
- `AUTOLAUNCH_DEPLOY_WORKDIR=/Users/sean/Documents/regent/autolaunch/contracts`
- `AUTOLAUNCH_DEPLOY_BINARY=forge`
- `AUTOLAUNCH_DEPLOY_SCRIPT_TARGET`
- `AUTOLAUNCH_DEPLOY_ACCOUNT` or `AUTOLAUNCH_DEPLOY_PRIVATE_KEY`
- `ETH_SEPOLIA_RPC_URL`
- `ETH_SEPOLIA_FACTORY_ADDRESS`
- `ETH_SEPOLIA_UNISWAP_V4_POOL_MANAGER`
- `ETH_SEPOLIA_UNISWAP_V4_POSITION_MANAGER`
- `ETH_SEPOLIA_USDC_ADDRESS`
- `REVENUE_SHARE_FACTORY_ADDRESS`
- `REVENUE_INGRESS_FACTORY_ADDRESS`
- `LBP_STRATEGY_FACTORY_ADDRESS`
- `TOKEN_FACTORY_ADDRESS`
- `ERC8004_SEPOLIA_SUBGRAPH_URL`

If you want AgentBook trust-check coverage too, also fill the World/Base/Base Sepolia AgentBook values already present in `.env.example`.

## Local app boot steps

Bring up the app:

```bash
cd /Users/sean/Documents/regent/autolaunch
mix setup
mix phx.server
```

Then check:

- `http://127.0.0.1:4002/health`
- `/`
- `/launch`
- `/auctions`
- `/positions`
- `/agentbook`

## Local Regent CLI setup

Validate the CLI repo:

```bash
cd /Users/sean/Documents/regent/regent-cli
pnpm build
pnpm typecheck
pnpm test
```

Point the CLI at the local app:

```bash
export AUTOLAUNCH_BASE_URL=http://127.0.0.1:4002
```

For authenticated commands, provide one of:

- `AUTOLAUNCH_SESSION_COOKIE`
- `AUTOLAUNCH_PRIVY_BEARER_TOKEN`

The CLI now treats Ethereum Sepolia as the only launch chain. If you omit `--chain`, it uses Sepolia.

## Local CLI testing steps

Read checks:

```bash
pnpm --filter @regentlabs/cli exec regent autolaunch agents list
pnpm --filter @regentlabs/cli exec regent autolaunch auctions list
```

Representative launch preview:

```bash
pnpm --filter @regentlabs/cli exec regent autolaunch launch preview \
  --agent YOUR_AGENT_ID \
  --chain-id 11155111 \
  --name "Agent Coin Name" \
  --symbol "AGENT" \
  --treasury-address 0xYOUR_SAFE
```

Representative launch creation:

```bash
pnpm --filter @regentlabs/cli exec regent autolaunch launch create \
  --agent YOUR_AGENT_ID \
  --chain-id 11155111 \
  --name "Agent Coin Name" \
  --symbol "AGENT" \
  --treasury-address 0xYOUR_SAFE \
  --wallet-address 0xYOUR_WALLET \
  --nonce YOUR_NONCE \
  --message "YOUR_SIWA_MESSAGE" \
  --signature "YOUR_SIGNATURE" \
  --issued-at 2026-03-26T00:00:00Z
```

Watch the job:

```bash
pnpm --filter @regentlabs/cli exec regent autolaunch jobs watch YOUR_JOB_ID --watch
```

Success means the job response includes the current launch stack fields, including:

- `strategy_address`
- `vesting_wallet_address`
- `hook_address`
- `launch_fee_registry_address`
- `launch_fee_vault_address`
- `subject_registry_address`
- `subject_id`
- `revenue_share_splitter_address`
- `default_ingress_address`
- `pool_id`

## Fly deployment steps

This repo does not currently include tracked Fly app config files. The practical Fly path is:

1. create the app with `fly launch --no-deploy`
2. attach Postgres or point Fly at your managed Postgres
3. set the same runtime secrets you used locally
4. deploy from the Autolaunch repo root

The required Fly secrets are the same launch values listed above, especially:

- `PRIVY_APP_ID`
- `PRIVY_VERIFICATION_KEY`
- `SIWA_INTERNAL_URL`
- `SIWA_SHARED_SECRET`
- `AUTOLAUNCH_DEPLOY_WORKDIR`
- `AUTOLAUNCH_DEPLOY_BINARY`
- `AUTOLAUNCH_DEPLOY_SCRIPT_TARGET`
- `AUTOLAUNCH_DEPLOY_ACCOUNT` or `AUTOLAUNCH_DEPLOY_PRIVATE_KEY`
- `ETH_SEPOLIA_RPC_URL`
- `ETH_SEPOLIA_FACTORY_ADDRESS`
- `ETH_SEPOLIA_UNISWAP_V4_POOL_MANAGER`
- `ETH_SEPOLIA_UNISWAP_V4_POSITION_MANAGER`
- `ETH_SEPOLIA_USDC_ADDRESS`
- `REVENUE_SHARE_FACTORY_ADDRESS`
- `REVENUE_INGRESS_FACTORY_ADDRESS`
- `LBP_STRATEGY_FACTORY_ADDRESS`
- `TOKEN_FACTORY_ADDRESS`
- `ERC8004_SEPOLIA_SUBGRAPH_URL`

If you are deploying the SIWA sidecar separately, keep its shared secret matched with the Phoenix app.

## Server testing steps

After Fly deploy, verify the server first:

```bash
curl -fsS https://YOUR_AUTOLAUNCH_HOST/health
```

Then point the CLI at Fly:

```bash
export AUTOLAUNCH_BASE_URL=https://YOUR_AUTOLAUNCH_HOST
```

Repeat the live checks:

```bash
pnpm --filter @regentlabs/cli exec regent autolaunch agents list
pnpm --filter @regentlabs/cli exec regent autolaunch launch preview \
  --agent YOUR_AGENT_ID \
  --chain-id 11155111 \
  --name "Agent Coin Name" \
  --symbol "AGENT" \
  --treasury-address 0xYOUR_SAFE
pnpm --filter @regentlabs/cli exec regent autolaunch launch create \
  --agent YOUR_AGENT_ID \
  --chain-id 11155111 \
  --name "Agent Coin Name" \
  --symbol "AGENT" \
  --treasury-address 0xYOUR_SAFE \
  --wallet-address 0xYOUR_WALLET \
  --nonce YOUR_NONCE \
  --message "YOUR_SIWA_MESSAGE" \
  --signature "YOUR_SIGNATURE" \
  --issued-at 2026-03-26T00:00:00Z
pnpm --filter @regentlabs/cli exec regent autolaunch jobs watch YOUR_JOB_ID --watch
```

Server verification is complete when:

- the Fly health endpoint is up
- authenticated CLI calls succeed
- launch preview succeeds on Sepolia
- a real launch job returns the full strategy, vesting, fee, subject, and ingress addresses from the deploy script
