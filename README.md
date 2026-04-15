# Autolaunch

Autolaunch is the Phoenix LiveView app behind `autolaunch.sh`. This repo also holds the canonical local Foundry workspace under `contracts/`. The app owns the launch flow, the public auction surface, AgentBook verification, and the SIWA-backed session path that connects browser auth to onchain actions. The public sale model is a Continuous Clearing Auction designed to help quality teams bootstrap liquidity with healthier market behavior and true price discovery.

## Agents

Autolaunch is the browser and server layer for the launch product. The repo now owns both the app surface and the contract workspace, but the Phoenix app itself is still not the CLI. The app reads deployment output from the local `contracts/` workspace, then uses that data to drive launch jobs, bid quoting, and post-launch tracking.

What this repo handles:

- Public landing and auction explainer pages
- Guided launch flow for new launches
- Auction browsing, quoting, and bid lifecycle actions
- Agent inventory, launch readiness, and trust follow-up
- AgentBook registration, lookup, and verification
- Privy session exchange and SIWA verification
- Launch job persistence and onchain launch tracking

For agent-facing onboarding, start with [`SKILL.md`](SKILL.md) and [`docs/autolaunch_examples.json`](docs/autolaunch_examples.json). They now describe the CLI-first golden path:

- `regent autolaunch prelaunch wizard`
- `regent autolaunch launch run`
- `regent autolaunch launch monitor`
- `regent autolaunch launch finalize`
- `regent autolaunch vesting status`

For an operator-facing deployment and launch sequence, use [`docs/operator_runbook.md`](docs/operator_runbook.md).
The canonical product rules live in [`docs/product_invariants.md`](docs/product_invariants.md), and the hardening tracker lives in [`docs/mainnet_readiness_checklist.md`](docs/mainnet_readiness_checklist.md).

## Humans

### Quick Start

```bash
cp .env.example .env.local
direnv allow
mix setup
mix phx.server
```

For day-to-day validation and asset work:

```bash
mix test
mix precommit
mix assets.build
mix assets.deploy
mix autolaunch.doctor
AUTOLAUNCH_MOCK_DEPLOY=true mix autolaunch.smoke
mix autolaunch.verify_deploy --job <job-id>
```

If you need the launch docs that explain the public auction flow, start with [`AUTOLAUNCH_AUCTIONS_GUIDE.md`](AUTOLAUNCH_AUCTIONS_GUIDE.md).

### Why CCA Auctions

Autolaunch uses Continuous Clearing Auctions because we think they are the right launch model for quality projects and teams that need to bootstrap liquidity without turning launch day into a race for advanced users and bots.

The simple buyer mental model is:

- choose a total budget
- choose the highest token price you are willing to pay
- let the order run across the remaining blocks like a TWAP
- receive tokens only in blocks where the clearing price stays below your max price
- stop automatically once the clearing price moves above your cap

The intended game theory is simple too:

- bid early with your real budget and your real max price
- your max price protects you from paying above what you actually believe is fair
- waiting only shortens your participation window and usually worsens your average price
- with sane auction timing, there is far less room for sniping, bundling, sandwiching, or other timing games
- everyone gets access to the same block clearing price instead of specialized speed advantages

That is the core product claim: less timing game, more real price discovery.

The current live launch economics are:

- 10% of the 100 billion supply is sold in the auction
- 5% of the supply is reserved for the Uniswap v4 LP position
- half of auction USDC is used for that LP position
- the other half of auction USDC is swept to the agent Safe for business operations
- the remaining 85% of tokens vest to the agent treasury over 1 year

### What Runs Where

The main LiveView and API routes are:

- `/` and `/how-auctions-work` for the public home and auction explainer
- `/launch` for the guided launch flow
- `/contracts` for the operator contract console
- `/auctions`, `/auctions/:id`, and `/positions` for auction and position views
- `/subjects/:id` for subject staking, claiming, and ingress actions
- `/agentbook` for the human proof flow
- `/health` for readiness checks
- `/v1/agent/siwa/nonce` and `/v1/agent/siwa/verify` for SIWA
- `/api/auth/privy/session` for browser session exchange
- `/api/prelaunch/*` for saved launch drafts, hosted metadata, and upload-backed launch assets
- `/api/lifecycle/*` for launch monitoring, finalize guidance, and vesting status
- `/api/regent/staking/*` for the separate REGENT staking rail
- `/api/agents`, `/api/launch/*`, `/api/auctions/*`, `/api/bids/*`, `/api/subjects/*`, `/api/contracts/*`, `/api/agentbook/*`, and `/api/ens/link/*` for the supporting JSON flows

`/api/agents` is the agent inventory. `/api/agents/:id/readiness` is the launch-readiness check. They are related, but they answer different questions.

LiveView owns the page state. TypeScript stays in the browser-auth, wallet-signing, and motion layers.

### Contract Console

`/contracts` is the operator-facing contract surface. It accepts `job_id` and `subject_id` query parameters and reads the current launch stack or subject stack directly from the backend.

What it shows:

- launch deployment provenance and the returned stack addresses
- live strategy, vesting, fee-registry, fee-vault, splitter, ingress, and subject-registry state
- prepared transaction payloads for advanced contract actions

Action modes are intentionally split:

- direct wallet flows stay on the auction and subject pages for bid, stake, unstake, claim, and ingress sweep
- backend-tracked flows are only the wallet actions the app already registers after a real transaction hash is known
- prepare-only flows live in `/contracts` and return JSON payloads for multisig or operator submission instead of trying to send from the browser

### Configuration

The full environment list lives in [.env.example](.env.example). For local work, copy it to `.env.local` and run `direnv allow`. The important groups are:

- App runtime: `DATABASE_URL` or `LOCAL_DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`
- Privy auth: `PRIVY_APP_ID`, `PRIVY_VERIFICATION_KEY`, `AUTOLAUNCH_XMTP_AGENT_PRIVATE_KEY`
- SIWA sidecar: `SIWA_INTERNAL_URL`, `SIWA_SHARED_SECRET`, `SIWA_HMAC_SECRET`
- Launch deployment: `ETH_SEPOLIA_RPC_URL`, `ETH_SEPOLIA_FACTORY_ADDRESS`, `ETH_SEPOLIA_UNISWAP_V4_POOL_MANAGER`, `ETH_SEPOLIA_UNISWAP_V4_POSITION_MANAGER`, `ETH_SEPOLIA_USDC_ADDRESS`, `AUTOLAUNCH_DEPLOY_WORKDIR`, `AUTOLAUNCH_DEPLOY_BINARY`, `AUTOLAUNCH_DEPLOY_SCRIPT_TARGET`, `AUTOLAUNCH_DEPLOY_ACCOUNT` or `AUTOLAUNCH_DEPLOY_PRIVATE_KEY`
- Launch contracts: `REVENUE_SHARE_FACTORY_ADDRESS`, `REVENUE_INGRESS_FACTORY_ADDRESS`, `LBP_STRATEGY_FACTORY_ADDRESS`, `TOKEN_FACTORY_ADDRESS`, `ERC8004_SEPOLIA_SUBGRAPH_URL`
- Regent staking rail: `REGENT_STAKING_RPC_URL`, `REGENT_STAKING_CHAIN_ID`, `REGENT_STAKING_CHAIN_LABEL`, `REGENT_REVENUE_STAKING_ADDRESS`
- AgentBook and World ID: `WORLD_ID_APP_ID`, `WORLD_ID_ACTION`, `WORLD_ID_RP_ID`, `WORLD_ID_SIGNING_KEY`, `WORLDCHAIN_RPC_URL`, `WORLDCHAIN_AGENTBOOK_ADDRESS`, `WORLDCHAIN_AGENTBOOK_RELAY_URL`, `BASE_MAINNET_RPC_URL`, `BASE_AGENTBOOK_ADDRESS`, `BASE_AGENTBOOK_RELAY_URL`, `BASE_SEPOLIA_RPC_URL`, `BASE_SEPOLIA_AGENTBOOK_ADDRESS`, `BASE_SEPOLIA_AGENTBOOK_RELAY_URL`

The launch path is Ethereum Sepolia only.

If product copy, launch docs, or contract docs disagree about the active rules, use [`docs/product_invariants.md`](docs/product_invariants.md) as the source of truth and update the other surface.

### REGENT Staking Rail

Autolaunch now also exposes a separate Regent staking rail for Regent Labs itself.

- It is not part of the Sepolia launch flow.
- Its production target is Base mainnet, but local rehearsal can point it at Base Sepolia with `REGENT_STAKING_*`.
- It uses the existing `$REGENT` token on the configured Base network as the stake token.
- It accepts USDC deposits manually on the configured Base network.
- It pays the configured staker share to `$REGENT` stakers and leaves the rest accruing for the Regent treasury.
- Other-chain Regent income still lands in Treasury A first, then gets bridged manually to Base USDC and deposited into the staking contract.

This rail is separate from agent subject splitters:

- agent subject splitters are per-agent revenue-rights contracts on Sepolia
- REGENT staking is one singleton company-token rewards rail on the configured Base network

### Launch Flow

Autolaunch expects the hard-cut `CCA_RESULT_JSON` payload from the configured deployment script. The contract source of truth lives in the local Foundry workspace under [`contracts/`](contracts).

The preferred operator flow is now CLI-first:

1. save a prelaunch plan
2. validate and publish the hosted metadata draft
3. run the launch from that saved plan
4. monitor the auction lifecycle
5. finalize post-auction actions
6. release vested tokens later

The launch controller returns the strategy, vesting wallet, fee registry, fee vault, fee hook, subject registry, revsplit, and default ingress addresses. The app stores that output and uses it for post-launch tracking.

Launch responses also carry a `reputation_prompt` when the user should do follow-up trust steps. That prompt links into `/ens-link` for ENS and `/agentbook` for the human proof flow. The launch page uses those same links after the token exists.

Important launch rules:

- Each auction sells 10% of a 100 billion supply
- The launch strategy holds another 5% for LP migration and sends 85% into the vesting wallet
- Every auction is denominated in USDC on Ethereum Sepolia
- Buyers set a total budget and a max price, and the order runs across the remaining blocks like a TWAP
- Each block clears at the highest price where demand exceeds supply, and no one pays above their stated max price
- Launch buyers must stake the claimed tokens to earn recognized Sepolia USDC revenue once it reaches the revsplit
- Mock deploy is opt-in through `AUTOLAUNCH_MOCK_DEPLOY=true`
- Recognized revenue is Sepolia USDC only, and it only counts once it reaches the revsplit
- The fee hook is the launch-side fee lane, while the revsplit is the ongoing revenue-rights lane
- `AUTOLAUNCH_DEPLOY_SCRIPT_TARGET` is required at runtime; there is no baked-in example deploy script target anymore
- `config/runtime.exs` is the runtime environment path; `config/dev.exs` stays limited to dev-only browser tooling and reload support

The current browser launch flow is still available, but it is no longer the primary operator path. The CLI should be the first stop for launch planning, launch execution, monitoring, finalize guidance, and vesting follow-up.

### Commands

Run these from the repository root:

```bash
mix setup
mix test
mix precommit
mix assets.build
mix assets.deploy
mix autolaunch.doctor
AUTOLAUNCH_MOCK_DEPLOY=true mix autolaunch.smoke
mix autolaunch.verify_deploy --job <job-id>
```

`mix autolaunch.doctor` is the blocking release gate for database reachability, Sepolia launch config, SIWA, and deploy dependencies. `mix autolaunch.smoke` is the synthetic in-repo launch-to-subject smoke. `mix autolaunch.verify_deploy --job <job-id>` is the post-deploy live-chain check for ownership acceptance, factory authorization cleanup, fee-vault canonical tokens, migration, pool and position recording, hook state, and subject wiring.

Doctor checks map directly to product breakage:

- database failure means launch jobs, bids, sessions, and subject action registrations cannot be stored
- Privy failure means browser and CLI session exchange cannot start authenticated flows
- SIWA failure means launch creation cannot verify the wallet signature
- deploy binary, workdir, or script-target failure means launches cannot be executed on that node
- Sepolia RPC failure means launch reads, quote reads, and transaction verification become unreliable
- trust-network warnings only affect trust follow-up surfaces; launch and auction flows should still work

### What Must Be Alive

Autolaunch is not a static frontend. A working environment needs:

- a live Phoenix node
  This handles Privy session exchange, SIWA verification, launch preview, launch creation, in-process launch job execution, queue polling, quote computation, transaction registration, and the contract-read models used by the web app and CLI.
- a live Postgres database
  Jobs, auctions, bids, human sessions, and subject action registrations are all persisted there.
- a live Sepolia RPC
  The app uses it for launch status reads, auction reads, quote checks, and transaction verification.
- a reachable SIWA sidecar
  Launch creation depends on it for signature verification.
- the Foundry deploy binary plus the configured deploy workdir and script target on the launch node
  Without those, the backend cannot run the launch deployment at all.

Trust-network configuration is optional. If it is missing, the trust follow-up surfaces degrade gracefully, but the core launch, auction, and subject revenue flows should keep working.

The Phoenix aliases in `mix.exs` also include `ecto.reset` and the usual asset setup flow.

### Repo Map

- `lib/` - Phoenix app code, LiveView screens, launch logic, AgentBook logic, and SIWA support
- `config/` - runtime, development, test, and release configuration
- `priv/` - migrations, seed data, static assets, and gettext files
- `test/` - unit, controller, and LiveView coverage
- `contracts/` - local Foundry workspace for launch, revsplit, and ingress contracts
- `AUTOLAUNCH_AUCTIONS_GUIDE.md` - public auction guide
- `SKILL.md` - repo-level autolaunch onboarding skill
- `docs/autolaunch_examples.json` - canonical machine-readable payload examples
- `AUTOLAUNCH_PORT.md` - port and process notes
- `PRODUCT_SURFACE_PROPOSAL.md` - product surface direction

### External Dependencies

- The canonical CLI lives in the standalone [`regent-ai/regent-cli`](https://github.com/regent-ai/regent-cli) repo, with the expected local checkout at `/Users/sean/Documents/regent/regent-cli`, as `regent autolaunch ...`
- The Autolaunch contracts live in [`contracts/`](contracts)
- The public guide content for auctions lives in [`AUTOLAUNCH_AUCTIONS_GUIDE.md`](AUTOLAUNCH_AUCTIONS_GUIDE.md)

The CLI namespace, routing flags, and CLI-side trust follow-up commands are tracked in `regent-cli`. This repo documents the shared launch contract and the web surfaces only.
