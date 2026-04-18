# Autolaunch Local Rehearsal

This is the current **local-only** rehearsal path for Autolaunch.

Treat it as a pure testnet run:

- Regent staking deploys to **Base Sepolia**
- Autolaunch shared infra and launch jobs deploy to **Base Sepolia**
- the local website must be able to **read the freshly deployed Base Sepolia staking rail**
- Fly is **not** part of this rehearsal

The launch chain is Base Sepolia for this rehearsal.

## 1. Gather the required values first

Do not start deploying until you already have these:

- Base Sepolia RPC URL
- Base Sepolia `$REGENT` test token address
- Base Sepolia USDC or test-USDC address
- Base Sepolia RPC URL
- Base Sepolia CCA factory address
- Base Sepolia Uniswap v4 pool manager address
- Base Sepolia Uniswap v4 position manager address
- Base Sepolia USDC address
- Base Sepolia token factory address
- Base Sepolia ERC-8004 subgraph URL
- Base Sepolia identity registry address
- strategy operator address
- CCA values:
  - `CCA_FLOOR_PRICE_Q96`
  - `CCA_TICK_SPACING_Q96`
  - `CCA_REQUIRED_CURRENCY_RAISED`
- Privy values
- SIWA values
- XMTP agent private key
- deployer private key
- treasury and safe addresses

Important warnings:

- `TOKEN_FACTORY_ADDRESS` is still external. The shared infra deploy does not create it.
- `AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS`, `STRATEGY_OPERATOR`, `OFFICIAL_POOL_FEE`, `OFFICIAL_POOL_TICK_SPACING`, and the required `CCA_*` values still matter for a real launch even after shared infra is live.

## 2. Deploy Regent staking on Base Sepolia

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

Important defaults:

- `REGENT_REVENUE_STAKER_SHARE_BPS=10000` means **100% of each USDC deposit is staker-eligible**
- `REGENT_REVENUE_SUPPLY_DENOMINATOR=100000000000000000000000000000` is **100 billion tokens in raw 18-decimal units**

Deploy the staking contract:

```bash
forge script scripts/DeployRegentRevenueStaking.s.sol:DeployRegentRevenueStakingScript \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --broadcast
```

Save the printed `REGENT_REVENUE_STAKING_RESULT_JSON` values:

- `contractAddress`
- `regentTokenAddress`
- `usdcAddress`
- `treasuryRecipient`
- `owner`
- `stakerShareBps`
- `revenueShareSupplyDenominator`

Use `contractAddress` as `REGENT_REVENUE_STAKING_ADDRESS` later.

## 3. Deploy shared Autolaunch infra on Base Sepolia

Validate contracts first if you have not already:

```bash
cd /Users/sean/Documents/regent/autolaunch/contracts
forge test --offline
```

Set the shared infra deploy inputs:

```bash
export AUTOLAUNCH_RPC_URL=...
export AUTOLAUNCH_USDC_ADDRESS=...
export AUTOLAUNCH_INFRA_OWNER=...
export PRIVATE_KEY=...
```

Deploy the shared Autolaunch infra:

```bash
forge script scripts/DeployAutolaunchInfra.s.sol:DeployAutolaunchInfraScript \
  --rpc-url "$AUTOLAUNCH_RPC_URL" \
  --broadcast
```

Save the printed `AUTOLAUNCH_INFRA_RESULT_JSON` values:

- `subjectRegistryAddress`
- `revenueShareFactoryAddress`
- `revenueIngressFactoryAddress`
- `strategyFactoryAddress`
- `usdcAddress`
- `owner`

Map those into app env as:

- `REVENUE_SHARE_FACTORY_ADDRESS`
- `REVENUE_INGRESS_FACTORY_ADDRESS`
- `LBP_STRATEGY_FACTORY_ADDRESS`

Keep `subjectRegistryAddress` recorded as `SUBJECT_REGISTRY_ADDRESS` for reference even though the app runtime does not take it directly.

## 4. Prepare the local app runtime

Start from the checked-in example:

```bash
cd /Users/sean/Documents/regent/autolaunch
cp .env.example .env.local
direnv allow
```

Fill `.env.local` with at least:

```bash
export DATABASE_URL=...
export SECRET_KEY_BASE=...
export PHX_HOST=127.0.0.1
export PORT=4002

export PRIVY_APP_ID=...
export PRIVY_VERIFICATION_KEY=...
export AUTOLAUNCH_XMTP_AGENT_PRIVATE_KEY=...

export SIWA_INTERNAL_URL=...
export SIWA_SHARED_SECRET=...
export SIWA_HMAC_SECRET=...

export AUTOLAUNCH_DEPLOY_WORKDIR=/Users/sean/Documents/regent/autolaunch/contracts
export AUTOLAUNCH_DEPLOY_BINARY=forge
export AUTOLAUNCH_DEPLOY_SCRIPT_TARGET=scripts/ExampleCCADeploymentScript.s.sol:ExampleCCADeploymentScript
export AUTOLAUNCH_DEPLOY_PRIVATE_KEY=...
export AUTOLAUNCH_MOCK_DEPLOY=false

export AUTOLAUNCH_RPC_URL=...
export AUTOLAUNCH_CCA_FACTORY_ADDRESS=0xCCccCcCAE7503Cac057829BF2811De42E16e0bD5
export AUTOLAUNCH_UNISWAP_V4_POOL_MANAGER=...
export AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER=...
export AUTOLAUNCH_USDC_ADDRESS=...

export REVENUE_SHARE_FACTORY_ADDRESS=...
export REVENUE_INGRESS_FACTORY_ADDRESS=...
export LBP_STRATEGY_FACTORY_ADDRESS=...
export TOKEN_FACTORY_ADDRESS=...
export AUTOLAUNCH_ERC8004_SUBGRAPH_URL=...

export REGENT_STAKING_RPC_URL=...
export REGENT_STAKING_CHAIN_ID=84532
export REGENT_STAKING_CHAIN_LABEL=Base\ Sepolia
export REGENT_REVENUE_STAKING_ADDRESS=...

export AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS=...
export STRATEGY_OPERATOR=...
export OFFICIAL_POOL_FEE=...
export OFFICIAL_POOL_TICK_SPACING=...
export CCA_FLOOR_PRICE_Q96=...
export CCA_TICK_SPACING_Q96=...
export CCA_REQUIRED_CURRENCY_RAISED=...
export CCA_VALIDATION_HOOK=...
export CCA_CLAIM_BLOCK_OFFSET=0
```

Important corrections:

- `REGENT_STAKING_RPC_URL` is what the app uses to read the Base Sepolia staking rail
- `BASE_SEPOLIA_RPC_URL` is only separately needed if you also want Base Sepolia AgentBook trust flows
- `mix autolaunch.doctor` validates the core launch environment, but it does **not** prove every ambient Foundry launch-script variable is present

## 5. Boot and validate the local website

Bring up the app:

```bash
cd /Users/sean/Documents/regent/autolaunch
mix setup
mix autolaunch.doctor
mix phx.server
```

Then check:

- `http://127.0.0.1:4002/health`
- `http://127.0.0.1:4002/`
- `http://127.0.0.1:4002/launch`
- `http://127.0.0.1:4002/auctions`
- `http://127.0.0.1:4002/positions`
- `http://127.0.0.1:4002/agentbook`

Also verify the Base Sepolia staking rail is readable through the app:

- `GET /api/regent/staking`
- `GET /api/regent/staking/account/<wallet>`

## 6. Bootstrap XMTP once

From the app repo:

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

## 7. Validate CLI and staking reads against the local app

Validate the CLI repo:

```bash
cd /Users/sean/Documents/regent/regents-cli
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
- `AUTOLAUNCH_PRIVY_BEARER_TOKEN` plus `AUTOLAUNCH_WALLET_ADDRESS`

Run local read checks first:

```bash
pnpm --filter @regentslabs/cli exec regent autolaunch agents list
pnpm --filter @regentslabs/cli exec regent autolaunch auctions list
pnpm --filter @regentslabs/cli exec regent regent-staking show
pnpm --filter @regentslabs/cli exec regent regent-staking account 0xYOUR_WALLET
```

This step matters because the rehearsal includes the app actively reading the newly deployed Base Sepolia staking rail.

## 8. Run the first real Base Sepolia launch through the guided flow

Use the guided operator path, not raw `launch create`, as the main run sheet:

```bash
pnpm --filter @regentslabs/cli exec regent autolaunch safe wizard --backup-signer-address 0x...
pnpm --filter @regentslabs/cli exec regent autolaunch safe create --backup-signer-address 0x... --website-wallet-address 0x...
pnpm --filter @regentslabs/cli exec regent autolaunch prelaunch wizard --agent <agent-id> --name "Agent Coin Name" --symbol "AGENT" --agent-safe-address <safe-address>
pnpm --filter @regentslabs/cli exec regent autolaunch prelaunch validate --plan <plan-id>
pnpm --filter @regentslabs/cli exec regent autolaunch prelaunch publish --plan <plan-id>
pnpm --filter @regentslabs/cli exec regent autolaunch launch run --plan <plan-id>
pnpm --filter @regentslabs/cli exec regent autolaunch launch monitor --job <job-id> --watch
pnpm --filter @regentslabs/cli exec regent autolaunch launch finalize --job <job-id> --submit
pnpm --filter @regentslabs/cli exec regent autolaunch vesting status --job <job-id>
```

Keep these low-level commands as debug-only fallback, not the main worksheet path:

- `regent autolaunch launch preview`
- `regent autolaunch launch create`
- `regent autolaunch jobs watch`

## 9. Verify the real deployed launch

After the real launch job reaches `ready`, verify the live deployment:

```bash
cd /Users/sean/Documents/regent/autolaunch
mix autolaunch.verify_deploy --job <job-id>
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

## 10. Fund Regent emissions after staking deploy

Do this only after the Base Sepolia staking contract exists:

1. approve `$REGENT` to the staking contract
2. call `fundRegentRewards(amount)`
3. then call `setEmissionAprBps(2000)`

Important notes:

- `stakerShareBps` is the fixed USDC revenue split and is already locked at deploy
- `emissionAprBps` is the adjustable reward APR lever controlled by `REGENT_REVENUE_GOVERNANCE_SAFE_ADDRESS`
- do not turn emissions on before the contract has `$REGENT` reward inventory

## What a good rehearsal produces

Do not call the rehearsal successful until you have all of these:

- saved `REGENT_REVENUE_STAKING_RESULT_JSON` from Base Sepolia
- saved `AUTOLAUNCH_INFRA_RESULT_JSON` from Base Sepolia
- local app booted cleanly with `mix autolaunch.doctor` passing
- successful XMTP bootstrap output
- successful app and CLI reads against the Base Sepolia staking rail
- successful guided launch flow through local app and Sepolia
- successful `mix autolaunch.verify_deploy --job <job-id>`

## Final warning

This is a Base Sepolia plus Base Sepolia rehearsal configuration. It should not be confused with the eventual production Regent staking rail on Base mainnet.
