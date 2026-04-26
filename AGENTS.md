# Autolaunch Agent Guide

This repo is the Autolaunch product app. It owns the Phoenix LiveView frontend and backend, and it also carries the local Foundry contracts workspace under `contracts/`.

Keep this file short and current. Use it as the fast start map for new coding agents.

## What This Repo Is

- Phoenix + LiveView app for the Autolaunch product
- TypeScript browser hooks for wallet, auth, and browser-only flows
- Ecto + Postgres for launch plans, jobs, bids, sessions, portfolio snapshots, and subject actions
- Dragonfly-backed cache for hot subject revenue reads, wallet position reads, obligation metrics, ingress accounts, and share history
- Local Foundry workspace in `contracts/` for launch, fee, splitter, ingress, and staking contracts

## Contract-First Rule

- `api-contract.openapiv3.yaml` is the source of truth for the product's HTTP backend contract, including routes, auth, request bodies, response shapes, and stable error envelopes.
- `regent-services-contract.openapiv3.yaml` is the source of truth for shared HTTP backend contracts that are not owned by one product, such as `regent-staking`.
- `cli-contract.yaml` is the source of truth for the product's shipped CLI surface, including command names, flags/args, auth mode, whether a command is HTTP-backed or local/runtime-backed, and which backend contract operation it is allowed to use.

Start contract work here, in this order:

- `/Users/sean/Documents/regent/regents-cli/docs/api-contract-workflow.md`
- `/Users/sean/Documents/regent/autolaunch/docs/api-contract.openapiv3.yaml`
- `/Users/sean/Documents/regent/autolaunch/docs/cli-contract.yaml`
- `/Users/sean/Documents/regent/regents-cli/docs/regent-services-contract.openapiv3.yaml`
- `/Users/sean/Documents/regent/regents-cli/docs/shared-cli-contract.yaml`
- `/Users/sean/Documents/regent/regents-cli/packages/regents-cli/src/contracts/api-ownership.ts`

Do not define HTTP behavior from Phoenix route files first and “fix the CLI later.” Change the contract files first, then make app code and CLI code match.

Hard cutover applies:

- Do not add fallback behavior, compatibility branches, shims, aliases, dual-shape support, or old-shape rejection tests.
- Prefer deleting old-shape handling over preserving it.
- Update producers, consumers, fixtures, docs, and tests to use the current shape only.
- Keep validation focused on the current contract.

## Important App Surfaces

Open these files first for product work:

- `lib/autolaunch_web/router.ex`
- `lib/autolaunch_web/live/launch_live.ex`
- `lib/autolaunch/contracts.ex`
- `lib/autolaunch/launch.ex`
- `lib/autolaunch/prelaunch.ex`
- `lib/autolaunch/lifecycle.ex`
- `lib/autolaunch/agentbook.ex`
- `lib/autolaunch/trust.ex`
- `lib/autolaunch/regent_staking.ex`
- `lib/autolaunch/revenue.ex`
- `lib/autolaunch/cache.ex`
- `lib/autolaunch/dragonfly.ex`
- `lib/autolaunch_web/regent_scenes.ex`
- `assets/js/app.ts`
- `assets/js/hooks/index.ts`

## Route Shape

The main route types are:

- LiveView pages for browser UI: `/`, `/launch`, `/auctions`, `/positions`, `/contracts`, `/subjects/:id`, `/agentbook`, `/ens-link`, `/x-link`
- Product JSON APIs under `/v1/app/*` and `/v1/agent/*`
- Agent-protected routes verify shared SIWA request proofs through the configured sidecar
- Privy browser session exchange under `/v1/auth/privy/session`
- Wallet-backed XMTP room identity completion under `/v1/auth/privy/xmtp/complete`

Current browser capabilities:

- Modern home and launch direction with a command-first CTA
- Auction and position search with shareable filters
- Real Regent staking status for connected wallets
- Subject pages cleaned up around status, revenue, staking, claims, ingress, and next actions
- Unified action panel behavior for wallet actions and prepared operator actions

## Major Backend Areas

- `Launch` owns launch preview, job creation, and launch-state reads
- `Prelaunch` owns saved launch plans, metadata, and uploaded assets
- `Lifecycle` owns finalize guidance, post-launch status, and vesting views
- `Contracts` owns operator contract reads and prepared transaction payloads
- `Agentbook` owns human proof registration, lookup, and verification
- `Trust` owns agent trust reads and X-link follow-up
- `RegentStaking` owns the shared staking rail
- `XMTPMirror` owns the mirrored Autolaunch public-room model and stays aligned with Techtree's room flow
- `Cache` and `Dragonfly` own short-lived hot reads. Cache keys include a product prefix, chain/job/subject identifiers where relevant, a digest for wallet address lists, and a subject cache epoch. Mutating subject actions bump the subject epoch instead of carrying stale reads forward.

## Settlement Flow

- Post-auction settlement is now a separate concern from launch-job progress. Do not try to model deploy progress and settlement as one giant state machine.
- `Lifecycle` now returns a settlement summary with: `settlement_state`, `blocked_reason`, `recommended_action`, `allowed_actions`, `required_actor`, `balance_snapshot`, and `ownership_status`.
- The main settlement branches are: `awaiting_migration`, `awaiting_auction_asset_return`, `failed_auction_recoverable`, `post_recovery_cleanup`, `awaiting_sweeps`, `ownership_acceptance_required`, `settled`, and `wait`.
- `Contracts` now reads both strategy-side and auction-side balances for launch settlement, plus fee-contract owner and pending-owner state for the fee registry, fee vault, and hook.
- Prepared job actions now include: strategy `recover_failed_auction`, auction `sweep_currency` and `sweep_unsold_tokens`, and fee-contract `accept_ownership` actions for the fee registry, fee vault, and hook.
- `launch finalize` should be treated as a dispatcher over the settlement summary, not as a hardcoded “migrate, then sweep” flow.
- Do not use `mix autolaunch.verify_deploy --job <job-id>` as a pre-finalize gate. Treat deploy sanity and settlement completion as separate checks when reasoning about operator flow.

## Contracts Workspace

The local contracts workspace is canonical for Autolaunch Solidity:

- `contracts/src/LaunchDeploymentController.sol`
- `contracts/src/RegentLBPStrategy.sol`
- `contracts/src/RegentLBPStrategyFactory.sol`
- `contracts/src/LaunchFeeRegistry.sol`
- `contracts/src/LaunchFeeVault.sol`
- `contracts/src/LaunchPoolFeeHook.sol`
- `contracts/src/revenue/SubjectRegistry.sol`
- `contracts/src/revenue/RevenueShareFactory.sol`
- `contracts/src/revenue/RevenueIngressFactory.sol`
- `contracts/src/revenue/RevenueIngressAccount.sol`
- `contracts/src/revenue/RevenueShareSplitter.sol`
- `contracts/src/revenue/RegentRevenueStaking.sol`

Start Solidity work with:

- `contracts/AGENTS.md`
- `contracts/README.md`

## Product Story

- The launch path is Base-family only: Base Sepolia for rehearsal and Base mainnet for production.
- Browser auth is Privy-based.
- Agent auth is SIWA-based.
- A Regent identity is a saved Agent account: wallet, registry address, and token ID.
- The browser wizard exists, but the preferred operator flow is CLI-first.
- `regent-staking` is a separate shared rail and should stay distinct from the Base-family launch flow.
- The Autolaunch public room now follows the same mirrored XMTP group-chat model as Techtree. Keep room identity, membership command queueing, and internal sync endpoints aligned across both repos.
- Main public CTA: if the reader already has an agent, use `regents-cli`; if they do not have an agent yet, send them to `regents.sh`.
- Public copy should describe what a person can do, what happens next, and why it matters. Do not expose framework names, internal route wiring, cache mechanics, signing internals, legacy behavior, or compatibility plans in public UI text.

## Agent Operator Path

For launch work, treat `regents-cli` as the default operator surface.

- Read `/Users/sean/Documents/regent/regents-cli/docs/autolaunch-cli.md` before changing or operating the guided flow.
- Use `regents autolaunch prelaunch wizard`, `validate`, `publish`, `launch run`, `launch monitor`, `launch finalize`, and `vesting status` as the main path.
- Use `regents autolaunch safe wizard` and `safe create` before launch planning if the agent Safe does not exist yet.
- Keep raw `launch create`, strategy, splitter, ingress, and registry commands for debugging or incident recovery only.

The CLI auth path for Autolaunch expects:

- `AUTOLAUNCH_BASE_URL`
- a saved Autolaunch sign-in from `regents auth login --audience autolaunch`
- an Agent account from `regents identity ensure`

Before a real launch, verify the launch node with:

```bash
mix autolaunch.doctor
AUTOLAUNCH_MOCK_DEPLOY=true mix autolaunch.smoke
```

After a real launch reaches `ready`, verify it with:

```bash
mix autolaunch.verify_deploy --job <job-id>
```

If a legitimate deploy needs more time on a slow or congested Sepolia path, raise `AUTOLAUNCH_DEPLOY_TIMEOUT_MS` in the environment. Do not patch the timeout in code for one-off operations.

## Validation

For app changes:

```bash
cd /Users/sean/Documents/regent/autolaunch
mix precommit
```

For assets:

```bash
cd /Users/sean/Documents/regent/autolaunch/assets
npm run typecheck
```

For contracts:

```bash
cd /Users/sean/Documents/regent/autolaunch/contracts
forge test
```

For cross-repo API or CLI changes, also validate `/Users/sean/Documents/regent/regents-cli`.

## Core Rules

- Hard cutover only. No backwards compatibility shims.
- Use Foundry for contract development and testing.
- Keep LiveView as the owner of page state; use TypeScript only for browser-only concerns.
- Prefer small pure helpers for validation, normalization, and decision logic. Keep side effects at the edges.
- For Python tasks, use `uv`.
- Never read `.env` files. `.env.example` is allowed.
- Keep public docs and UI text concise, crypto-native, and plain. Avoid implementation language in customer-facing copy.
