# Autolaunch + Regent CLI Local Rehearsal

This guide is for the current local-only rehearsal path.

It is intentionally pure testnet:

- Regent staking deploys to Base Sepolia
- Autolaunch shared infra and launch jobs deploy to Ethereum Sepolia
- Fly is not part of this rehearsal

The launch chain is still Ethereum Sepolia only. Base Sepolia is only for the separate Regent staking rail in this rehearsal.

## What has to be running

Autolaunch is one Phoenix app for both frontend and backend. To test it end to end with `regent-cli`, you also need:

- Postgres
- Privy session exchange
- the SIWA sidecar
- the local Foundry contracts workspace
- a reachable Base Sepolia RPC for Regent staking rehearsal
- a reachable Ethereum Sepolia RPC for Autolaunch
- deployed Regent staking support values on Base Sepolia
- deployed Autolaunch shared support contracts on Ethereum Sepolia

Unlike Techtree, Autolaunch does not need the Regent runtime daemon for normal CLI use.

## Stage 1: Deploy Regent staking on Base Sepolia

Validate contracts first:

```bash
cd /Users/sean/Documents/regent/autolaunch/contracts
forge test --offline
```

Set the Base Sepolia staking deploy inputs in your shell:

```bash
export BASE_SEPOLIA_RPC_URL=...
export BASE_REGENT_TOKEN_ADDRESS=...
export BASE_USDC_ADDRESS=...
export REGENT_REVENUE_TREASURY_ADDRESS=...
export REGENT_REVENUE_GOVERNANCE_SAFE_ADDRESS=...
export REGENT_REVENUE_STAKER_SHARE_BPS=10000
export REGENT_REVENUE_SUPPLY_DENOMINATOR=100000000000000000000000000000
export PRIVATE_KEY=...
```

Important notes:

- `REGENT_REVENUE_STAKER_SHARE_BPS=10000` means 100% of each USDC deposit is staker-eligible before unstaked-supply remainder stays in treasury.
- `REGENT_REVENUE_SUPPLY_DENOMINATOR` must be the raw 18-decimal unit value for 100 billion tokens, not the human-readable `100000000000`.

Deploy the staking contract:

```bash
cd /Users/sean/Documents/regent/autolaunch/contracts

forge script scripts/DeployRegentRevenueStaking.s.sol:DeployRegentRevenueStakingScript \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --broadcast
```

Save the output:

- `REGENT_REVENUE_STAKING_ADDRESS`

After deploy, the Regent emission flow is:

1. approve `$REGENT` to the staking contract
2. call `fundRegentRewards(amount)`
3. then call `setEmissionAprBps(2000)`

`stakerShareBps` is fixed at deploy. `emissionAprBps` is the adjustable APR control owned by `REGENT_REVENUE_GOVERNANCE_SAFE_ADDRESS`.

## Stage 2: Deploy shared Autolaunch infra on Ethereum Sepolia

Set the shared infra deploy inputs:

```bash
export ETH_SEPOLIA_RPC_URL=...
export ETHEREUM_USDC_ADDRESS=...
export AUTOLAUNCH_INFRA_OWNER=...
export PRIVATE_KEY=...
```

Deploy the shared Autolaunch infra:

```bash
cd /Users/sean/Documents/regent/autolaunch/contracts

forge script scripts/DeployAutolaunchInfra.s.sol:DeployAutolaunchInfraScript \
  --rpc-url "$ETH_SEPOLIA_RPC_URL" \
  --broadcast
```

Save the output:

- `REVENUE_SHARE_FACTORY_ADDRESS`
- `REVENUE_INGRESS_FACTORY_ADDRESS`
- `LBP_STRATEGY_FACTORY_ADDRESS`
- `SUBJECT_REGISTRY_ADDRESS`

Important warning:

- `TOKEN_FACTORY_ADDRESS` is still an external dependency. The shared infra deploy does not create it for you.

## Stage 3: Prepare the local app runtime

Start from the checked-in example:

```bash
cd /Users/sean/Documents/regent/autolaunch
cp .env.example .env.local
direnv allow
```

Fill these required values in `.env.local`:

- `DATABASE_URL` or `LOCAL_DATABASE_URL`
- `SECRET_KEY_BASE`
- `PHX_HOST`
- `PORT`
- `PRIVY_APP_ID`
- `PRIVY_VERIFICATION_KEY`
- `AUTOLAUNCH_XMTP_AGENT_PRIVATE_KEY`
- `SIWA_INTERNAL_URL`
- `SIWA_SHARED_SECRET`
- `SIWA_HMAC_SECRET`
- `AUTOLAUNCH_DEPLOY_WORKDIR=/Users/sean/Documents/regent/autolaunch/contracts`
- `AUTOLAUNCH_DEPLOY_BINARY=forge`
- `AUTOLAUNCH_DEPLOY_SCRIPT_TARGET=scripts/ExampleCCADeploymentScript.s.sol:ExampleCCADeploymentScript`
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
- `REGENT_STAKING_RPC_URL`
- `REGENT_STAKING_CHAIN_ID=84532`
- `REGENT_STAKING_CHAIN_LABEL=Base Sepolia`
- `REGENT_REVENUE_STAKING_ADDRESS`

These values are still required for a real Sepolia launch even if shared infra deploys cleanly:

- `TOKEN_FACTORY_ADDRESS`
- `AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS`
- `STRATEGY_OPERATOR`
- `OFFICIAL_POOL_FEE`
- `OFFICIAL_POOL_TICK_SPACING`
- required `CCA_*` values

If you want AgentBook trust-check coverage too, also fill the World/Base/Base Sepolia AgentBook values already present in `.env.example`.

## Stage 4: Boot and validate the local app

Bring up the app:

```bash
cd /Users/sean/Documents/regent/autolaunch
mix setup
mix autolaunch.doctor
mix phx.server
```

Then check:

- `http://127.0.0.1:4002/health`
- `/`
- `/launch`
- `/auctions`
- `/positions`
- `/agentbook`

Bootstrap the XMTP room once:

```bash
mix autolaunch.bootstrap_xmtp_room
```

If the room already exists and you want to keep using it:

```bash
mix autolaunch.bootstrap_xmtp_room --reuse
```

Record the bootstrap output:

- room key
- conversation id
- agent wallet
- agent inbox

## Stage 5: Validate the local CLI

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

The CLI still treats Ethereum Sepolia as the only launch chain. If you omit `--chain`, it uses Sepolia.

Run the read checks first:

```bash
pnpm --filter @regentlabs/cli exec regent autolaunch agents list
pnpm --filter @regentlabs/cli exec regent autolaunch auctions list
```

## Stage 6: Run the first real Sepolia launch from local

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
  --issued-at 2026-04-10T00:00:00Z
```

Watch the job:

```bash
pnpm --filter @regentlabs/cli exec regent autolaunch jobs watch YOUR_JOB_ID --watch
```

Success means the job response includes the launch stack fields, including:

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

## Stage 7: Run live post-deploy verification

After the real launch job reaches `ready`, verify the live deployment:

```bash
cd /Users/sean/Documents/regent/autolaunch
mix autolaunch.verify_deploy --job YOUR_JOB_ID
```

This checks the live contract invariants that matter most:

- controller resolution from the deploy receipt
- controller authorization cleanup in the shared factories
- accepted ownership on the fee contracts
- fee-vault canonical token wiring
- completed strategy migration
- recorded pool and position ids
- hook-enabled state
- subject and ingress wiring

## Rehearsal status and warning

This is a Base Sepolia plus Ethereum Sepolia rehearsal configuration. It should not be confused with the eventual production Regent staking rail on Base mainnet.

Treat the system as ready for a first controlled testnet attempt, not fully proven, until you have these four artifacts:

- real Base Sepolia staking deploy output
- real Ethereum Sepolia shared infra deploy output
- successful local launch preview and launch create flow
- successful `mix autolaunch.verify_deploy --job ...`
