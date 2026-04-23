# Autolaunch

Autolaunch helps an agent with a real edge turn that edge into runway. It gives the agent a market to raise aligned capital, fund compute and distribution, and keep supporters active after launch.

If you already have an agent, use [`regents-cli`](../regents-cli) and start with:

```bash
regents autolaunch prelaunch wizard
```

If you do not have an agent yet, use [regents.sh](https://regents.sh) to make one.

The sale model is a Continuous Clearing Auction: buyers choose a budget and a max price, the auction clears block by block, and launch capital goes toward liquidity and the agent Safe.

## Product Direction

Autolaunch centers on a cleaner market and launch workspace:

- a modern public site for agent launches, auctions, positions, and subject pages
- command-first launch planning through `regents-cli`
- search and filters for live markets, positions, and returns
- shareable filtered market views
- real Regent status and staking reads for the connected wallet
- cleaner subject pages with staking, claims, revenue, ingress, and next actions in one place
- one action panel pattern for wallet actions and prepared operator actions
- faster subject reads backed by Dragonfly for hot revenue and position state
- a slimmer Elixir/Phoenix structure with product areas split by launch, lifecycle, contracts, trust, revenue, staking, and AgentBook

Autolaunch is built for agents that can earn but need capital before revenue catches up. The product should make three things obvious: what is live, what the agent needs next, and what a backer can do now.

## For Agents

Use `regents-cli` for launch work:

```bash
regents autolaunch safe wizard
regents autolaunch safe create
regents autolaunch prelaunch wizard
regents autolaunch prelaunch validate
regents autolaunch prelaunch publish
regents autolaunch launch run
regents autolaunch launch monitor
regents autolaunch launch finalize
regents autolaunch vesting status
```

Use the website for market discovery, auction participation, subject pages, staking, claims, trust follow-up, and AgentBook.

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

The current fixed fee rules are:

- the launch-pool fee is fixed at 2% on swaps in the official pool
- that 2% split is fixed at 1% to Regent and 1% to the agent treasury
- recognized subject revenue first sends a fixed 1% skim to Regent
- the remaining 99% stays in the subject lane, where stakers earn their formula share and the remainder accrues to the agent treasury

### What Runs Where

The main product routes are:

- `/` and `/how-auctions-work` for the public home and auction explainer
- `/launch` for the guided launch flow
- `/contracts` for the operator contract console
- `/auctions`, `/auctions/:id`, and `/positions` for auction search, shareable filters, and position views
- `/subjects/:id` for subject status, staking, claims, revenue routing, ingress, and available actions
- `/agentbook` for the human proof flow
- `/health` for readiness checks
- `/v1/agent/siwa/nonce` and `/v1/agent/siwa/verify` for SIWA
- `/v1/auth/privy/session` for browser session exchange
- `/v1/auth/privy/xmtp/complete` for finishing wallet-backed XMTP room setup after the browser session opens
- `/v1/app/prelaunch/*` for saved launch drafts, hosted metadata, and upload-backed launch assets
- `/v1/app/lifecycle/*` for launch monitoring, finalize guidance, and vesting status
- `/v1/app/regent/staking/*` for the separate REGENT staking rail
- `/v1/app/agents`, `/v1/app/launch/*`, `/v1/app/auctions/*`, `/v1/app/bids/*`, `/v1/app/subjects/*`, `/v1/app/contracts/*`, `/v1/app/agentbook/*`, and `/v1/app/ens/link/*` for the supporting JSON flows

`/v1/app/agents` is the agent inventory. `/v1/app/agents/:id/readiness` checks whether an agent is ready to launch.

### Contract Console

`/contracts` is the operator-facing contract surface. It accepts `job_id` and `subject_id` query parameters and reads the current launch stack or subject stack directly from the backend.

What it shows:

- launch deployment provenance and the returned stack addresses
- live strategy, vesting, fee-registry, fee-vault, splitter, ingress, and subject-registry state
- prepared transaction payloads for advanced contract actions

Action modes are intentionally split:

- wallet actions stay on auction and subject pages for bid, stake, unstake, claim, and ingress sweep
- confirmed wallet actions are registered after the transaction hash exists
- prepared operator actions live in `/contracts` for multisig or operator submission

### Configuration

The full environment list lives in [.env.example](.env.example). For local work, copy it to `.env.local` and run `direnv allow`. The important groups are:

- App runtime: `DATABASE_URL` or `LOCAL_DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`
- Privy auth: `PRIVY_APP_ID`, `PRIVY_VERIFICATION_KEY`, `AUTOLAUNCH_XMTP_AGENT_PRIVATE_KEY`
- Internal XMTP sync auth: `AUTOLAUNCH_INTERNAL_SHARED_SECRET`
- SIWA sidecar: `SIWA_INTERNAL_URL`, `SIWA_SHARED_SECRET`, `SIWA_HMAC_SECRET`
- Launch deployment: `AUTOLAUNCH_RPC_URL`, `AUTOLAUNCH_CCA_FACTORY_ADDRESS`, `AUTOLAUNCH_UNISWAP_V4_POOL_MANAGER`, `AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER`, `AUTOLAUNCH_USDC_ADDRESS`, `AUTOLAUNCH_DEPLOY_WORKDIR`, `AUTOLAUNCH_DEPLOY_BINARY`, `AUTOLAUNCH_DEPLOY_SCRIPT_TARGET`, `AUTOLAUNCH_DEPLOY_ACCOUNT` or `AUTOLAUNCH_DEPLOY_PRIVATE_KEY`
- Launch contracts: `REVENUE_SHARE_FACTORY_ADDRESS`, `REVENUE_INGRESS_FACTORY_ADDRESS`, `LBP_STRATEGY_FACTORY_ADDRESS`, `TOKEN_FACTORY_ADDRESS`, `AUTOLAUNCH_ERC8004_SUBGRAPH_URL`
- Base identity lookups: `AUTOLAUNCH_BASE_MAINNET_RPC_URL`, `AUTOLAUNCH_BASE_SEPOLIA_RPC_URL`, `AUTOLAUNCH_BASE_MAINNET_ERC8004_SUBGRAPH_URL`, `AUTOLAUNCH_BASE_SEPOLIA_ERC8004_SUBGRAPH_URL`, `AUTOLAUNCH_BASE_MAINNET_IDENTITY_REGISTRY_ADDRESS`, `AUTOLAUNCH_BASE_SEPOLIA_IDENTITY_REGISTRY_ADDRESS`
- Base verifier address books: `AUTOLAUNCH_BASE_MAINNET_UNISWAP_V4_POOL_MANAGER`, `AUTOLAUNCH_BASE_SEPOLIA_UNISWAP_V4_POOL_MANAGER`, `AUTOLAUNCH_BASE_MAINNET_USDC_ADDRESS`, `AUTOLAUNCH_BASE_SEPOLIA_USDC_ADDRESS`, `AUTOLAUNCH_BASE_MAINNET_REVENUE_SHARE_FACTORY_ADDRESS`, `AUTOLAUNCH_BASE_SEPOLIA_REVENUE_SHARE_FACTORY_ADDRESS`, `AUTOLAUNCH_BASE_MAINNET_REVENUE_INGRESS_FACTORY_ADDRESS`, `AUTOLAUNCH_BASE_SEPOLIA_REVENUE_INGRESS_FACTORY_ADDRESS`
- Launch-script ambient env: `AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS`, `STRATEGY_OPERATOR`, `OFFICIAL_POOL_FEE`, `OFFICIAL_POOL_TICK_SPACING`, `CCA_FLOOR_PRICE_Q96`, `CCA_TICK_SPACING_Q96`, `CCA_REQUIRED_CURRENCY_RAISED`, optional `CCA_VALIDATION_HOOK`, optional `CCA_CLAIM_BLOCK_OFFSET`
- Regent staking rail: `REGENT_STAKING_RPC_URL`, `REGENT_STAKING_CHAIN_ID`, `REGENT_STAKING_CHAIN_LABEL`, `REGENT_REVENUE_STAKING_ADDRESS`
- AgentBook and World ID: `WORLD_ID_APP_ID`, `WORLD_ID_ACTION`, `WORLD_ID_RP_ID`, `WORLD_ID_SIGNING_KEY`, `WORLDCHAIN_RPC_URL`, `WORLDCHAIN_AGENTBOOK_ADDRESS`, `WORLDCHAIN_AGENTBOOK_RELAY_URL`, `BASE_MAINNET_RPC_URL`, `BASE_AGENTBOOK_ADDRESS`, `BASE_AGENTBOOK_RELAY_URL`, `BASE_SEPOLIA_RPC_URL`, `BASE_SEPOLIA_AGENTBOOK_ADDRESS`, `BASE_SEPOLIA_AGENTBOOK_RELAY_URL`

The launch path supports Base Sepolia for rehearsal and Base mainnet for production.

For the current local-only rehearsal, use the run sheet in [REGENT_CLI_LOCAL_AND_FLY_TESTING.md](/Users/sean/Documents/regent/autolaunch/REGENT_CLI_LOCAL_AND_FLY_TESTING.md). It treats Regent staking as Base Sepolia, Autolaunch infra and launches as Base Sepolia, and the guided CLI lifecycle as the main operator path.

If product copy, launch docs, or contract docs disagree about the active rules, use [`docs/product_invariants.md`](docs/product_invariants.md) as the source of truth and update the other surface.

### REGENT Staking Rail

Autolaunch exposes a separate Regent staking rail for Regent Labs itself.

- It is not part of the launch flow itself.
- Its production target is Base mainnet, but local rehearsal can point it at Base Sepolia with `REGENT_STAKING_*`.
- It uses the existing `$REGENT` token on the configured Base network as the stake token.
- It accepts USDC deposits manually on the configured Base network.
- It pays the configured staker share to `$REGENT` stakers and leaves the rest accruing for the Regent treasury.
- Other-chain Regent income still lands in Treasury A first, then gets bridged manually to Base USDC and deposited into the staking contract.

This rail is separate from agent subject splitters:

- agent subject splitters are per-agent revenue-rights contracts on the active Base-family launch network
- REGENT staking is one singleton company-token rewards rail on the configured Base network

### Launch Flow

Autolaunch expects the current `CCA_RESULT_JSON` payload from the configured deployment script. The contract source of truth lives in the local Foundry workspace under [`contracts/`](contracts).

The operator flow is CLI-first:

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
- Every auction is denominated in USDC on Base Sepolia
- Buyers set a total budget and a max price, and the order runs across the remaining blocks like a TWAP
- Each block clears at the highest price where demand exceeds supply, and no one pays above their stated max price
- Launch buyers must stake the claimed tokens to earn recognized Base-family USDC revenue once it reaches the revsplit
- Mock deploy is opt-in through `AUTOLAUNCH_MOCK_DEPLOY=true`
- Recognized revenue is Base-family USDC only, and it only counts once it reaches the revsplit
- Funds waiting in an ingress account are not recognized yet; they can be swept before a pending share change takes effect, and anything swept later uses the live share at that time
- The fee hook is the launch-side fee lane, while the revsplit is the ongoing revenue-rights lane
- `AUTOLAUNCH_DEPLOY_SCRIPT_TARGET` is required at runtime
- `config/runtime.exs` is the runtime environment path; `config/dev.exs` stays limited to dev-only browser tooling and reload support

The CLI is the first stop for launch planning, launch execution, monitoring, finalize guidance, and vesting follow-up.

### Contributor Rules

- API and CLI changes start in the YAML source-of-truth files, then the app and CLI are updated to match.
- Autolaunch HTTP behavior lives in [`docs/api-contract.openapiv3.yaml`](docs/api-contract.openapiv3.yaml).
- Autolaunch CLI behavior lives in [`docs/cli-contract.yaml`](docs/cli-contract.yaml).
- Shared Regent staking behavior lives in [`../regents-cli/docs/regent-services-contract.openapiv3.yaml`](../regents-cli/docs/regent-services-contract.openapiv3.yaml).
- Keep one current contract shape. Remove obsolete handling instead of documenting or preserving it.
- Use Foundry for EVM contract development and testing.
- Use plain public copy: say what a person can do, what happens next, and why it matters.

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

`mix autolaunch.doctor` is the blocking release gate for database reachability, launch-chain config, SIWA, and deploy dependencies. `mix autolaunch.smoke` is the synthetic in-repo launch-to-subject smoke. `mix autolaunch.verify_deploy --job <job-id>` is the post-deploy live-chain check for ownership acceptance, factory authorization cleanup, fee-vault canonical tokens, migration, pool and position recording, hook state, and subject wiring.

Doctor checks map directly to product breakage:

- database failure means launch jobs, bids, sessions, and subject action registrations cannot be stored
- Privy failure means browser and CLI session exchange cannot start authenticated flows
- SIWA failure means launch creation cannot verify the wallet signature
- deploy binary, workdir, or script-target failure means launches cannot be executed on that node
- launch-chain RPC failure means launch reads, quote reads, and transaction verification become unreliable
- trust-network warnings only affect trust follow-up surfaces; launch and auction flows should still work

`mix autolaunch.doctor` does not prove every Foundry launch-script variable is present. The ambient launch-script values like `AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS`, `STRATEGY_OPERATOR`, `OFFICIAL_POOL_FEE`, `OFFICIAL_POOL_TICK_SPACING`, and required `CCA_*` values still need to be set correctly for a real launch.

### What Must Be Alive

Autolaunch is not a static frontend. A working environment needs:

- a live Phoenix node
  This handles Privy session exchange, SIWA verification, launch preview, launch creation, in-process launch job execution, queue polling, quote computation, transaction registration, and the contract-read models used by the web app and CLI.
- a live Postgres database
  Jobs, auctions, bids, human sessions, and subject action registrations are all persisted there.
- a live launch-chain RPC
  The app uses it for launch status reads, auction reads, quote checks, and transaction verification.
- a reachable SIWA sidecar
  Launch creation depends on it for signature verification.
- the Foundry deploy binary plus the configured deploy workdir and script target on the launch node
  Without those, the backend cannot run the launch deployment at all.

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

- The canonical CLI lives in the standalone [`regents-ai/regents-cli`](https://github.com/regents-ai/regents-cli) repo, with the expected local checkout at `/Users/sean/Documents/regent/regents-cli`, as `regents autolaunch ...`
- The Autolaunch contracts live in [`contracts/`](contracts)
- The public guide content for auctions lives in [`AUTOLAUNCH_AUCTIONS_GUIDE.md`](AUTOLAUNCH_AUCTIONS_GUIDE.md)

The CLI namespace, routing flags, and CLI-side trust follow-up commands are tracked in `regents-cli`. This repo documents the shared launch contract and the web surfaces only.
