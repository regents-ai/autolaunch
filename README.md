# Autolaunch

Autolaunch is the Phoenix LiveView app behind `autolaunch.sh`. This repo now also holds the local Foundry workspace under `contracts/`. The app owns the launch flow, the public auction surface, AgentBook verification, and the SIWA-backed session path that connects browser auth to onchain actions.

## Agents

Autolaunch is the browser and server layer for the launch product. The repo now owns both the app surface and the contract workspace, but the Phoenix app itself is still not the CLI. The app reads deployment output from the local `contracts/` workspace, then uses that data to drive launch jobs, bid quoting, and post-launch tracking.

What this repo handles:

- Public landing and auction explainer pages
- Guided launch flow for new launches
- Auction browsing, quoting, and bid lifecycle actions
- AgentBook registration, lookup, and verification
- Privy session exchange and SIWA verification
- Launch job persistence and onchain launch tracking

## Humans

### Quick Start

```bash
cp .env.example .env
mix setup
mix phx.server
```

For day-to-day validation and asset work:

```bash
mix test
mix precommit
mix assets.build
mix assets.deploy
```

If you need the launch docs that explain the public auction flow, start with [`AUTOLAUNCH_AUCTIONS_GUIDE.md`](AUTOLAUNCH_AUCTIONS_GUIDE.md).

### What Runs Where

The main LiveView and API routes are:

- `/` and `/how-auctions-work` for the public home and auction explainer
- `/launch` for the guided launch flow
- `/auctions`, `/auctions/:id`, and `/positions` for auction and position views
- `/agentbook` for the human proof flow
- `/health` for readiness checks
- `/v1/agent/siwa/nonce` and `/v1/agent/siwa/verify` for SIWA
- `/api/auth/privy/session` for browser session exchange
- `/api/agents`, `/api/launch/*`, `/api/auctions/*`, `/api/bids/*`, `/api/agentbook/*`, and `/api/ens/link/*` for the supporting JSON flows

LiveView owns the page state. TypeScript stays in the browser-auth, wallet-signing, and motion layers.

### Configuration

The full environment list lives in [.env.example](.env.example). The important groups are:

- App runtime: `DATABASE_URL` or `LOCAL_DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`
- Privy auth: `PRIVY_APP_ID`, `PRIVY_VERIFICATION_KEY`
- SIWA sidecar: `SIWA_INTERNAL_URL`, `SIWA_SHARED_SECRET`, `SIWA_HMAC_SECRET`
- Launch deployment: `ETH_MAINNET_RPC_URL`, `ETH_MAINNET_FACTORY_ADDRESS`, `ETH_MAINNET_UNISWAP_V4_POOL_MANAGER`, `ETH_MAINNET_USDC_ADDRESS`, `AUTOLAUNCH_DEPLOY_WORKDIR`, `AUTOLAUNCH_DEPLOY_BINARY`, `AUTOLAUNCH_DEPLOY_SCRIPT_TARGET`, `AUTOLAUNCH_DEPLOY_ACCOUNT` or `AUTOLAUNCH_DEPLOY_PRIVATE_KEY`
- Launch revenue infra: `REVENUE_SHARE_FACTORY_ADDRESS`, `SUBJECT_REGISTRY_ADDRESS`, `MAINNET_REGENT_EMISSIONS_CONTROLLER_ADDRESS`, `ERC8004_MAINNET_SUBGRAPH_URL`
- AgentBook and World ID: `WORLD_ID_APP_ID`, `WORLD_ID_ACTION`, `WORLD_ID_RP_ID`, `WORLD_ID_SIGNING_KEY`, `WORLDCHAIN_RPC_URL`, `WORLDCHAIN_AGENTBOOK_ADDRESS`, `WORLDCHAIN_AGENTBOOK_RELAY_URL`, `BASE_MAINNET_RPC_URL`, `BASE_AGENTBOOK_ADDRESS`, `BASE_AGENTBOOK_RELAY_URL`, `BASE_SEPOLIA_RPC_URL`, `BASE_SEPOLIA_AGENTBOOK_ADDRESS`, `BASE_SEPOLIA_AGENTBOOK_RELAY_URL`

The launch path is Ethereum mainnet only.

### Launch Flow

Autolaunch expects the hard-cut `CCA_RESULT_JSON` payload from the configured deployment script. The revenue and emissions contract source of truth now lives in the local Foundry workspace under [`contracts/`](contracts).

The launch controller, fee registry, fee vault, fee hook, subject registry, revsplit, and ingress addresses are produced by the deploy script in `contracts/`, then stored and displayed by the app.

Important launch rules:

- Each auction sells 10% of a 100 billion supply
- Every auction is denominated in USDC on Ethereum mainnet
- Launch buyers must stake the claimed tokens to earn revenue and token-fee share
- Mock deploy is opt-in through `AUTOLAUNCH_MOCK_DEPLOY=true`
- Recognized revenue is mainnet USDC only, and it only counts once it reaches the revsplit
- The mainnet emissions controller finalizes epochs from that onchain state
- The fee hook is the launch-side fee lane, while the revsplit is the ongoing revenue-rights lane
- `AUTOLAUNCH_DEPLOY_SCRIPT_TARGET` is required at runtime; there is no baked-in example deploy script target anymore
- `config/runtime.exs` is the runtime environment path; `config/dev.exs` stays limited to dev-only browser tooling and reload support

### Commands

Run these from the repository root:

```bash
mix setup
mix test
mix precommit
mix assets.build
mix assets.deploy
```

The Phoenix aliases in `mix.exs` also include `ecto.reset` and the usual asset setup flow.

### Repo Map

- `lib/` - Phoenix app code, LiveView screens, launch logic, AgentBook logic, and SIWA support
- `config/` - runtime, development, test, and release configuration
- `priv/` - migrations, seed data, static assets, and gettext files
- `test/` - unit, controller, and LiveView coverage
- `contracts/` - local Foundry workspace for launch, revenue, and emissions contracts
- `AUTOLAUNCH_AUCTIONS_GUIDE.md` - public auction guide
- `AUTOLAUNCH_PORT.md` - port and process notes
- `PRODUCT_SURFACE_PROPOSAL.md` - product surface direction

### External Dependencies

- The canonical CLI lives in the standalone [`regent-ai/regent-cli`](https://github.com/regent-ai/regent-cli) repo, with the expected local checkout at `/Users/sean/Documents/regent/regent-cli`, as `regent autolaunch ...`
- The Autolaunch revenue and emissions contracts live in [`contracts/`](contracts)
- The public guide content for auctions lives in [`AUTOLAUNCH_AUCTIONS_GUIDE.md`](AUTOLAUNCH_AUCTIONS_GUIDE.md)
