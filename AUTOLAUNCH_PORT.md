# Autolaunch Port Notes

## Source

- Legacy route: `monorepo/platform/src/routes/agentlaunch.tsx`
- Legacy detail route: `monorepo/platform/src/routes/agentlaunch/$network/$auctionAddress.tsx`
- Legacy APIs: `server/routes/api/agentlaunch/*`

## New Surface

- `/` is the public auction explainer and front door
- `/how-auctions-work` is the direct explainer alias
- `/launch` is the guided human launch wizard
- `/auctions` is the live market surface
- `/auctions/:id` is the bid detail + estimator surface
- `/positions` is the returning-user bid state surface
- `/api/agents` lists launchable agents
- `/api/agents/:id/readiness` exposes agent readiness
- `/api/launch/preview` returns shared launch preview data
- `/api/launch/jobs` queues launches
- `/api/launch/jobs/:id` polls job state
- `/api/auctions/:id/bid_quote` returns shared bid quote data
- `/api/me/bids` returns current-user positions
- `/api/bids/:id/exit` and `/api/bids/:id/claim` update position state
- `/api/auth/privy/session` bridges Privy bearer tokens into Phoenix session state
- `/v1/agent/siwa/nonce` and `/v1/agent/siwa/verify` proxy to the SIWA sidecar
- `AUTOLAUNCH_AUCTIONS_GUIDE.md` is the agent-facing text guide mirrored by the public explainer page

## Auth Model

- Privy is browser identity and Phoenix session hydration.
- SIWA sidecar is wallet-proof verification.
- LiveView is canonical UI state.
- Browser TS is limited to Privy auth, SIWA nonce/signature flow, and anime/copy interactions.

## Data Model

Local app-owned tables:

- `autolaunch_human_users`
- `autolaunch_jobs`
- `autolaunch_auctions`
- `autolaunch_bids`

Shared Regent policy tables read by readiness:

- `agent_lifecycle_runs`
- `agent_token_launches`
- `agent_token_launch_stakes`
- `agent_social_accounts`
- `ironsprite_agents`
- `regentbot_agents`

## Runtime Defaults

- Hard cutover: no legacy compatibility routes
- Launch network is fixed to Ethereum mainnet and is not user-selectable in the launch form.
- AgentLaunchToken supply is fixed at 100 billion and every auction sells 10%.
- Mock deploy path is disabled by default and only enabled when `AUTOLAUNCH_MOCK_DEPLOY=true`
- Revenue counts only when mainnet USDC reaches the revsplit.
- The mainnet emissions controller finalizes epochs from that onchain state.
- Revenue and emissions contract source of truth lives at `/Users/sean/Documents/regent/autolaunch/contracts`.
- Missing launch-side contracts stay as deploy-script outputs until they land in the local `contracts/` workspace.
