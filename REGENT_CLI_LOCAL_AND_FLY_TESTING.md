# Autolaunch Local, Base Sepolia, and Fly Runbook

This runbook is the operator path for rehearsing Autolaunch end to end:

1. prove the contracts locally
2. deploy the shared contracts to Base Sepolia
3. run the Phoenix app locally against those contracts
4. deploy Dragonfly and the Phoenix app to Fly
5. run the first guided Base Sepolia launch through Regents CLI
6. verify the live launch

Use Base Sepolia for this rehearsal. Do not mix this with the later Base mainnet production rail.

Use the shared public beta run sheet before opening this app to users:

- `/Users/sean/Documents/regent/docs/public-beta-run-sheet.md`

That sheet is the stop/go record across Platform, Autolaunch, and Regents CLI.

## Operator Rules

- Never paste private keys into a file committed to git.
- Never commit `.env`, `.env.local`, Foundry broadcast files with secrets, or Fly secrets.
- Use Foundry for contract deploys and contract tests.
- Run the guided Regents CLI path for launch work. Keep raw launch commands for debugging only.
- Keep the browser app as a review and follow-up surface. The CLI starts and runs launches.
- Record every deployed address immediately after each deploy.
- Use one terminal for local shell exports and one terminal for long-running servers.

## Files Added for Fly

The repo includes Fly-ready support files:

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

Check Fly auth:

```bash
fly auth whoami
```

## 1. Gather Values Before Deploying

Do not deploy until these values are known and written into a private operator note:

| Value | Used by |
| --- | --- |
| Base Sepolia RPC URL | contracts, app, CLI |
| Base Sepolia `$REGENT` test token | staking deploy |
| Base Sepolia USDC or test-USDC | staking and launch deploys |
| CCA factory address | launch deploys |
| Uniswap v4 pool manager | launch deploys |
| Uniswap v4 position manager | launch deploys |
| token factory address | launch deploys |
| ERC-8004 subgraph URL | launch reads |
| identity registry address | launch validation |
| strategy operator address | launch migration |
| treasury recipient | staking deploy |
| governance Safe | staking deploy |
| deployer wallet | Foundry broadcasts |
| Privy app id and verification key | browser auth |
| SIWA sidecar URL and shared secret | agent auth |
| XMTP agent private key | public room agent |
| database URL | Phoenix runtime |
| Fly app names | Fly deploy |

CCA values needed by real launch jobs:

```bash
CCA_FLOOR_PRICE_Q96=
CCA_TICK_SPACING_Q96=
CCA_REQUIRED_CURRENCY_RAISED=
CCA_VALIDATION_HOOK=
CCA_CLAIM_BLOCK_OFFSET=0
```

Important notes:

- `AUTOLAUNCH_TOKEN_FACTORY_ADDRESS` is external. The shared infra deploy does not create it.
- `AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS`, `STRATEGY_OPERATOR`, `OFFICIAL_POOL_FEE`, `OFFICIAL_POOL_TICK_SPACING`, and the `CCA_*` values still matter after shared infra is live.
- `REGENT_STAKING_RPC_URL` is the app read path for the staking rail.
- `BASE_SEPOLIA_RPC_URL` is separately used by Base Sepolia AgentBook trust flows.

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

If tests fail, stop. Do not deploy.

## 3. Deploy a Base Sepolia Test `$REGENT` Token If Needed

Skip this if you already have a Base Sepolia `$REGENT` token address.

```bash
cd /Users/sean/Documents/regent/autolaunch/contracts

export BASE_SEPOLIA_RPC_URL=...
export PRIVATE_KEY=...

forge script scripts/DeployTestnetMintableERC20.s.sol:DeployTestnetMintableERC20Script \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --broadcast
```

Save the printed token address. Use it as `BASE_REGENT_TOKEN_ADDRESS`.

## 4. Deploy Regent Staking on Base Sepolia

Set deploy inputs:

```bash
cd /Users/sean/Documents/regent/autolaunch/contracts

export BASE_SEPOLIA_RPC_URL=...
export BASE_REGENT_TOKEN_ADDRESS=...
export BASE_USDC_ADDRESS=...
export REGENT_REVENUE_TREASURY_ADDRESS=...
export REGENT_REVENUE_GOVERNANCE_SAFE_ADDRESS=...
export REGENT_REVENUE_SUPPLY_DENOMINATOR=100000000000000000000000000000
export PRIVATE_KEY=...
```

Important default:

- `REGENT_REVENUE_SUPPLY_DENOMINATOR=100000000000000000000000000000` means 100 billion tokens in raw 18-decimal units.

Deploy:

```bash
forge script scripts/DeployRegentRevenueStaking.s.sol:DeployRegentRevenueStakingScript \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
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
```

Use `contractAddress` as `REGENT_REVENUE_STAKING_ADDRESS`.

## 5. Deploy Shared Autolaunch Infra on Base Sepolia

Set deploy inputs:

```bash
cd /Users/sean/Documents/regent/autolaunch/contracts

export AUTOLAUNCH_RPC_URL=...
export AUTOLAUNCH_USDC_ADDRESS=...
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
AUTOLAUNCH_REVENUE_SHARE_FACTORY_ADDRESS=<revenueShareFactoryAddress>
AUTOLAUNCH_REVENUE_INGRESS_FACTORY_ADDRESS=<revenueIngressFactoryAddress>
AUTOLAUNCH_LBP_STRATEGY_FACTORY_ADDRESS=<strategyFactoryAddress>
```

Keep `subjectRegistryAddress` recorded as `SUBJECT_REGISTRY_ADDRESS` for operator reference.

## 6. Create the Local App Environment

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

export SIWA_INTERNAL_URL=http://localhost:4100
export SIWA_SHARED_SECRET=...
export SIWA_HMAC_SECRET=...

export DRAGONFLY_ENABLED=false

export AUTOLAUNCH_CHAIN_ID=84532
export AUTOLAUNCH_RPC_URL=...
export AUTOLAUNCH_CCA_FACTORY_ADDRESS=0xCCccCcCAE7503Cac057829BF2811De42E16e0bD5
export AUTOLAUNCH_UNISWAP_V4_POOL_MANAGER=...
export AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER=...
export AUTOLAUNCH_USDC_ADDRESS=...
export AUTOLAUNCH_REVENUE_SHARE_FACTORY_ADDRESS=...
export AUTOLAUNCH_REVENUE_INGRESS_FACTORY_ADDRESS=...
export AUTOLAUNCH_LBP_STRATEGY_FACTORY_ADDRESS=...
export AUTOLAUNCH_TOKEN_FACTORY_ADDRESS=...
export AUTOLAUNCH_ERC8004_SUBGRAPH_URL=...
export AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS=...

export AUTOLAUNCH_BASE_SEPOLIA_RPC_URL=...
export AUTOLAUNCH_BASE_SEPOLIA_UNISWAP_V4_POOL_MANAGER=...
export AUTOLAUNCH_BASE_SEPOLIA_USDC_ADDRESS=...
export AUTOLAUNCH_BASE_SEPOLIA_REVENUE_SHARE_FACTORY_ADDRESS=...
export AUTOLAUNCH_BASE_SEPOLIA_REVENUE_INGRESS_FACTORY_ADDRESS=...
export AUTOLAUNCH_BASE_SEPOLIA_ERC8004_SUBGRAPH_URL=...
export AUTOLAUNCH_BASE_SEPOLIA_IDENTITY_REGISTRY_ADDRESS=...

export AUTOLAUNCH_DEPLOY_WORKDIR=/Users/sean/Documents/regent/autolaunch/contracts
export AUTOLAUNCH_DEPLOY_BINARY=forge
export AUTOLAUNCH_DEPLOY_SCRIPT_TARGET=scripts/ExampleCCADeploymentScript.s.sol:ExampleCCADeploymentScript
export AUTOLAUNCH_DEPLOY_TIMEOUT_MS=180000
export AUTOLAUNCH_DEPLOY_PRIVATE_KEY=...
export AUTOLAUNCH_MOCK_DEPLOY=false

export REGENT_STAKING_RPC_URL=...
export REGENT_STAKING_CHAIN_ID=84532
export REGENT_STAKING_CHAIN_LABEL=Base\ Sepolia
export REGENT_REVENUE_STAKING_ADDRESS=...

export STRATEGY_OPERATOR=...
export OFFICIAL_POOL_FEE=...
export OFFICIAL_POOL_TICK_SPACING=...
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
export BASE_SEPOLIA_RPC_URL=...
export BASE_SEPOLIA_AGENTBOOK_ADDRESS=...
export BASE_SEPOLIA_AGENTBOOK_RELAY_URL=...
```

Generate a local secret if needed:

```bash
mix phx.gen.secret
```

## 7. Boot and Validate Locally

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

## 8. Bootstrap XMTP Once

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

## 9. Validate Regents CLI Against Local App

```bash
cd /Users/sean/Documents/regent/regents-cli
pnpm build
pnpm typecheck
pnpm test

export AUTOLAUNCH_BASE_URL=http://127.0.0.1:4002
```

For authenticated commands, provide one of:

```bash
export AUTOLAUNCH_SESSION_COOKIE=...
```

or:

```bash
export AUTOLAUNCH_PRIVY_BEARER_TOKEN=...
export AUTOLAUNCH_WALLET_ADDRESS=0x...
```

Run local read checks:

```bash
pnpm --filter @regentslabs/cli exec regent autolaunch agents list
pnpm --filter @regentslabs/cli exec regent autolaunch auctions list
pnpm --filter @regentslabs/cli exec regent autolaunch contracts admin
pnpm --filter @regentslabs/cli exec regent regent-staking show
pnpm --filter @regentslabs/cli exec regent regent-staking account 0xYOUR_WALLET
```

## 10. Prepare Fly Apps

Pick names before running commands:

```bash
export FLY_ORG=personal
export FLY_REGION=sjc
export AUTOLAUNCH_FLY_APP=autolaunch-sepolia
export AUTOLAUNCH_DRAGONFLY_APP=autolaunch-sepolia-dragonfly
```

Edit these files before first deploy:

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

## 11. Deploy Dragonfly to Fly

Run from the Regent repo root:

```bash
cd /Users/sean/Documents/regent
fly deploy --config autolaunch/fly.dragonfly.toml .
```

Private hostname pattern:

```text
<AUTOLAUNCH_DRAGONFLY_APP>.internal
```

Check it:

```bash
fly status --app "$AUTOLAUNCH_DRAGONFLY_APP"
```

## 12. Set Fly Secrets for Phoenix

Generate `SECRET_KEY_BASE`:

```bash
cd /Users/sean/Documents/regent/autolaunch
mix phx.gen.secret
```

Set secrets. Replace placeholders before running:

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
  AUTOLAUNCH_USDC_ADDRESS=... \
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
  AUTOLAUNCH_DEPLOY_WORKDIR=/app/contracts \
  AUTOLAUNCH_DEPLOY_BINARY=forge \
  AUTOLAUNCH_DEPLOY_SCRIPT_TARGET=scripts/ExampleCCADeploymentScript.s.sol:ExampleCCADeploymentScript \
  AUTOLAUNCH_DEPLOY_TIMEOUT_MS=180000 \
  AUTOLAUNCH_DEPLOY_PRIVATE_KEY=... \
  AUTOLAUNCH_MOCK_DEPLOY=false \
  REGENT_MULTISIG_ADDRESS=... \
  REGENT_STAKING_RPC_URL=... \
  REGENT_STAKING_CHAIN_ID=84532 \
  REGENT_STAKING_CHAIN_LABEL="Base Sepolia" \
  REGENT_REVENUE_STAKING_ADDRESS=... \
  PRIVY_APP_ID=... \
  PRIVY_VERIFICATION_KEY=... \
  AUTOLAUNCH_XMTP_AGENT_PRIVATE_KEY=... \
  SIWA_INTERNAL_URL=... \
  SIWA_SHARED_SECRET=... \
  SIWA_HMAC_SECRET=... \
  STRATEGY_OPERATOR=... \
  OFFICIAL_POOL_FEE=... \
  OFFICIAL_POOL_TICK_SPACING=... \
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
  BASE_SEPOLIA_RPC_URL=... \
  BASE_SEPOLIA_AGENTBOOK_ADDRESS=... \
  BASE_SEPOLIA_AGENTBOOK_RELAY_URL=...
```

Check secrets names without printing values:

```bash
fly secrets list --app "$AUTOLAUNCH_FLY_APP"
```

## 13. Deploy Phoenix to Fly

Run from the Regent repo root:

```bash
cd /Users/sean/Documents/regent
fly deploy --config autolaunch/fly.phoenix.toml .
```

The deploy runs database migrations with:

```text
/app/bin/migrate
```

Check release status:

```bash
fly status --app "$AUTOLAUNCH_FLY_APP"
fly logs --app "$AUTOLAUNCH_FLY_APP"
```

Run release checks:

```bash
fly ssh console --app "$AUTOLAUNCH_FLY_APP" -C "/app/bin/autolaunch eval 'Autolaunch.ReleaseDoctor.run() |> IO.inspect(label: :doctor)'"
```

Check HTTP:

```bash
curl -s https://<PHX_HOST>/health
curl -s https://<PHX_HOST>/api/regent/staking
```

## 14. Optional Fly Smoke With Mock Deploy

Use this only before allowing real launch jobs:

```bash
fly secrets set --app "$AUTOLAUNCH_FLY_APP" AUTOLAUNCH_MOCK_DEPLOY=true
fly deploy --config autolaunch/fly.phoenix.toml .
fly ssh console --app "$AUTOLAUNCH_FLY_APP" -C "/app/bin/autolaunch eval 'Autolaunch.ReleaseSmoke.run() |> IO.inspect(label: :smoke)'"
fly secrets set --app "$AUTOLAUNCH_FLY_APP" AUTOLAUNCH_MOCK_DEPLOY=false
fly deploy --config autolaunch/fly.phoenix.toml .
```

Do not leave `AUTOLAUNCH_MOCK_DEPLOY=true` on the rehearsal app.

## 15. Point Regents CLI at Fly

```bash
cd /Users/sean/Documents/regent/regents-cli

export AUTOLAUNCH_BASE_URL=https://<PHX_HOST>
export AUTOLAUNCH_SESSION_COOKIE=...
```

or:

```bash
export AUTOLAUNCH_PRIVY_BEARER_TOKEN=...
export AUTOLAUNCH_WALLET_ADDRESS=0x...
```

Check reads:

```bash
pnpm --filter @regentslabs/cli exec regent autolaunch agents list
pnpm --filter @regentslabs/cli exec regent autolaunch auctions list
pnpm --filter @regentslabs/cli exec regent autolaunch contracts admin
pnpm --filter @regentslabs/cli exec regent regent-staking show
pnpm --filter @regentslabs/cli exec regent regent-staking account 0xYOUR_WALLET
```

## 16. Run the First Guided Base Sepolia Launch

Use the guided path:

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

Keep these as debug-only commands:

```bash
pnpm --filter @regentslabs/cli exec regent autolaunch launch preview
pnpm --filter @regentslabs/cli exec regent autolaunch launch create
pnpm --filter @regentslabs/cli exec regent autolaunch jobs watch
```

## 17. Verify the Real Deployed Launch

Local verification:

```bash
cd /Users/sean/Documents/regent/autolaunch
mix autolaunch.verify_deploy --job <job-id>
```

Fly verification:

```bash
fly ssh console --app "$AUTOLAUNCH_FLY_APP" -C "/app/bin/autolaunch eval 'Autolaunch.ReleaseDeployVerifier.run(\"<job-id>\") |> IO.inspect(label: :verify)'"
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

## 18. Fund Regent Emissions After Staking Deploy

Do this only after the Base Sepolia staking contract exists and has been checked from the app.

1. approve `$REGENT` to the staking contract
2. call `fundRegentRewards(amount)`
3. call `setEmissionAprBps(2000)`

Important notes:

- all Regent revenue deposits are staker-eligible
- `emissionAprBps` is controlled by `REGENT_REVENUE_GOVERNANCE_SAFE_ADDRESS`
- do not turn emissions on before the contract has `$REGENT` reward inventory

## 19. Good Rehearsal Checklist

A rehearsal is not done until every line is checked:

- [ ] `forge build` passed
- [ ] `forge fmt --check` passed
- [ ] `forge test` passed
- [ ] public beta run sheet updated
- [ ] Base Sepolia `$REGENT` token exists or was deployed
- [ ] `REGENT_REVENUE_STAKING_RESULT_JSON` saved
- [ ] `AUTOLAUNCH_INFRA_RESULT_JSON` saved
- [ ] local `.env.local` filled with Base Sepolia values
- [ ] `mix autolaunch.doctor` passed locally
- [ ] local app reads the staking rail
- [ ] XMTP bootstrap output saved
- [ ] Regents CLI reads local app successfully
- [ ] Fly Dragonfly deployed
- [ ] Fly Postgres attached
- [ ] Fly Phoenix secrets set
- [ ] Fly Phoenix deploy succeeded
- [ ] release migration succeeded
- [ ] Fly `/health` passed
- [ ] Fly app reads the staking rail
- [ ] optional mock smoke passed and was turned off afterward
- [ ] `AUTOLAUNCH_MOCK_DEPLOY=false` confirmed before real launch jobs
- [ ] Regents CLI reads Fly app successfully
- [ ] guided launch flow reached a real job
- [ ] launch monitor reached `ready`
- [ ] launch finalize completed or clearly reported the next action
- [ ] `mix autolaunch.verify_deploy --job <job-id>` passed

## 20. Fast Failure Map

| Symptom | First check |
| --- | --- |
| `mix autolaunch.doctor` fails | missing deploy env, RPC, factory, or Foundry path |
| Fly app starts then exits | `fly logs`, `SECRET_KEY_BASE`, `DATABASE_URL`, SIWA secret |
| Fly deploy cannot compile path deps | deploy from `/Users/sean/Documents/regent`, not from `autolaunch/` |
| launch job cannot run `forge` | check `/usr/local/bin/forge` inside Fly machine |
| launch job times out | raise `AUTOLAUNCH_DEPLOY_TIMEOUT_MS` as a Fly secret |
| app cannot read staking | check `REGENT_STAKING_RPC_URL` and `REGENT_REVENUE_STAKING_ADDRESS` |
| AgentBook fails on Base Sepolia | check `BASE_SEPOLIA_RPC_URL`, AgentBook address, relay URL, and World values |
| Dragonfly reads fail | check `DRAGONFLY_HOST`, private networking, and Dragonfly machine status |
| CLI auth fails | refresh `AUTOLAUNCH_SESSION_COOKIE` or Privy bearer token and wallet address |

## 21. Addresses to Save

Keep this table in a private operator note:

| Name | Address |
| --- | --- |
| Base Sepolia `$REGENT` token | |
| Base Sepolia USDC | |
| Regent revenue staking | |
| Regent revenue treasury | |
| Regent revenue governance Safe | |
| Subject registry | |
| Revenue share factory | |
| Revenue ingress factory | |
| LBP strategy factory | |
| Token factory | |
| CCA factory | |
| Uniswap v4 pool manager | |
| Uniswap v4 position manager | |
| ERC-8004 identity registry | |
| Strategy operator | |
| Fly Phoenix app | |
| Fly Dragonfly app | |
| Fly hostname | |

## Final Warning

This is a Base Sepolia rehearsal path. Do not copy these addresses into Base mainnet production settings unless they are intentionally redeployed and verified for Base mainnet.
