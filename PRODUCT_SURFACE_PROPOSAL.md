# Autolaunch product surface proposal

## Core recommendation

Do not force humans and agents through the same UX.

Build three clear surfaces:

1. Launch surface (human, guided)
2. Auction market + bid detail (human, live)
3. Skill + CLI + JSON API (agent, deterministic)

CCA is unfamiliar. Humans need explanation and simulation. Agents need exact verbs and machine-readable outputs.

## Human UX

### 1. Dashboard / home

Primary CTAs:

- Launch an Agent Coin
- Explore live auctions

Above the fold:

- Agent count
- Launch-eligible agents
- Active auctions
- Your active bids
- Total rewards / claimable tokens

### 2. Agent-first launch flow

Step 1: choose an eligible agent

- Show cards for all user agents
- Badge each card: `Eligible`, `Missing setup`, `Already launched`
- Disable ineligible cards with exact blocker text
- If there are no eligible agents, replace the launch CTA with `Set up an agent first`

Step 2: configure token

- Name, symbol, recovery safe, auction proceeds recipient, Ethereum revenue treasury
- Network is fixed to Ethereum mainnet and does not appear as a user choice
- Explain: one token per agent
- Explain: the auction sells 10% of the 100 billion supply
- Explain: only mainnet USDC that reaches the revsplit counts for staking
- Show fee split inline: `2% trading fee -> 1% agent treasury + 1% Regent multisig`

Step 3: review and sign

- Agent summary
- Token summary
- Launch network
- Risk / permanence notes
- Expected next steps after queueing

Step 4: queued / pending

- Job state timeline
- External dependency health if helpful
- Direct link to the future auction page once ready

### 3. Auction list page

Tabs or segmented control:

- `Hottest` (default)
- `Recently launched`
- `Expired`

Recommended card fields:

- agent avatar + agent name
- token symbol
- chain
- current clearing price
- total bid volume
- ends in / ended at
- bid count
- status pill
- your status if connected: `Active`, `Inactive`, `Claimable`

Sort logic:

- `Hottest`: weighted recent bid volume + bid velocity
- `Recently launched`: start time descending
- `Expired`: market cap descending

Filters:

- chain
- active / expired
- mine only

### 4. Auction detail page

Top section:

- agent identity
- token symbol
- chain
- current clearing price
- total bid volume
- time remaining
- your current position state

Main layout:

- Left: bid entry
- Right: live estimator
- Below: activity feed, bid ladder, FAQ

Bid entry should support:

- custom amount + max price
- `Starter bid` preset
- `Aggressive` preset
- `Custom` mode

Rename `optimal floor bid`.
That phrase is protocol-correct but unclear to most users. Better labels:

- `Starter bid`
- `Stay-active bid`
- `Floor-preserving bid`

### 5. Live estimator

This should answer one question clearly:

`If I bid this much at this max price, what do I probably get?`

Show three outputs:

- If auction ended now
- If no other bids change until the end
- Inactive above this price

Also show:

- active now? yes/no
- share of currently issued supply
- estimated final tokens under current conditions
- warning if the bid is one tick from going inactive

### 6. Bid status language

Avoid only saying `outbid`.
Use status states that map to CCA behavior:

- `Active — receiving tokens at the current clearing price`
- `Borderline — one move away from inactive`
- `Inactive — not receiving tokens at the current clearing price`
- `Claimable`
- `Exited`

### 7. Education

CCA is novel, so keep education in context:

- compact `How this auction works` explainer on every auction page
- one chart showing `clearing price` and `issued supply over time`
- one tooltip for `max price`
- one tooltip for `active / inactive`

Do not lead with whitepaper language.
Lead with `what happens to my money and tokens`.

## Agent surface

### Key principle

Agents should not depend on browser auth or UI affordances.

Give them:

- a narrow CLI
- stable JSON
- explicit previews before writes
- capability-scoped auth

### Auth model

Humans can keep using Privy.
Agents need delegated capabilities, for example:

- agent-scoped API token
- expiry
- spend limit
- allowed actions (`read`, `quote`, `bid`, `launch`)

### Suggested split

- Read-only operations: model-invocable or safe defaults
- Write operations: explicit user invocation only

## Phoenix implementation notes

- Use LiveView + PubSub for real-time auction updates
- Track per-user bid status server-side and broadcast only state transitions
- Render the estimator from server-calculated quote data, not client-only math
- Add a durable quote endpoint so web, CLI, and skill all use the same economic logic

## Biggest product risk

The main UX failure mode is making users learn CCA before they can act.

Instead, make the interface answer:

- Am I eligible to launch?
- Is this bid active now?
- What do I get if nothing changes?
- What price makes me inactive?
- What can I do next?
