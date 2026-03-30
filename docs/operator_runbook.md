# Autolaunch Operator Runbook

This is the plain-English runbook for standing up Autolaunch and taking a token from shared infrastructure to a live launch.

It is meant for the operator who needs to know what to deploy, what to configure, what outputs to save, and what to check before moving to the next step.

## What this runbook covers

Autolaunch has two separate setup layers:

1. Shared infrastructure
   This is the one-time foundation that all later launches reuse.
2. Per-launch deployment
   This is the one token launch that creates the token, auction, fee plumbing, revenue splitter, and ingress account for a specific agent.

If you remember only one thing, remember this:

- shared infrastructure is deployed once
- a launch stack is deployed once per token

## The main files

- App overview: [/Users/sean/Documents/regent/autolaunch/README.md](README.md)
- Contract overview: [/Users/sean/Documents/regent/autolaunch/contracts/README.md](../contracts/README.md)
- Contract architecture: [/Users/sean/Documents/regent/autolaunch/contracts/docs/ARCHITECTURE_GUIDE.md](../contracts/docs/ARCHITECTURE_GUIDE.md)
- Shared infra script: [/Users/sean/Documents/regent/autolaunch/contracts/scripts/DeployAutolaunchInfra.s.sol](../contracts/scripts/DeployAutolaunchInfra.s.sol)
- Per-launch script: [/Users/sean/Documents/regent/autolaunch/contracts/scripts/ExampleCCADeploymentScript.s.sol](../contracts/scripts/ExampleCCADeploymentScript.s.sol)

## Before you start

You need five things working before any real launch should be attempted:

1. A live Postgres database
   The app stores launch jobs, auctions, bids, sessions, and subject-action tracking there.
2. A live Phoenix app
   The app is the system that queues launches, watches jobs, verifies transactions, and shows operator state.
3. A live Sepolia RPC
   Launch reads, quote reads, and transaction verification depend on it.
4. A reachable SIWA sidecar
   Launch creation uses it to verify the wallet signature.
5. A machine with Foundry, the deploy workdir, and the deploy script target configured
   Without that, the launch backend cannot actually deploy contracts.

The release gate for this is:

```bash
mix autolaunch.doctor
```

If that command is not clean, stop there.

## Phase 1: Deploy shared infrastructure once

This is the one-time setup that gives the system its reusable onchain foundation.

The script creates four things:

1. Subject registry
   This is the master list of launched subjects. Each subject links the token, the revenue splitter, the treasury safe, and any attached identity records.
2. Revenue share factory
   This creates the revenue splitter for each launched token.
3. Revenue ingress factory
   This creates the known USDC intake addresses for each subject.
4. Strategy factory
   This creates the per-launch auction strategy contract.

### Inputs

At minimum, the shared infra script needs:

- the owner address for the shared factories
- the Sepolia USDC address

### What the script returns

The script prints one machine-readable line:

- `AUTOLAUNCH_INFRA_RESULT_JSON:`

Save those returned addresses. They become runtime inputs for the app and the per-launch script.

### What to verify after shared infra deploy

After the script finishes, verify these facts:

1. The subject registry exists.
2. The revenue share factory exists.
3. The revenue ingress factory exists.
4. The strategy factory exists.
5. The subject registry is handed off to the revenue share factory so later launches can create subjects through the supported path.

If that ownership handoff did not happen, later launches will fail when they try to register a subject.

## Phase 2: Configure the app and launch environment

Once the shared infrastructure is live, wire those returned addresses into the app and deploy environment.

The important config groups are:

- Sepolia RPC
- SIWA config
- Privy config
- shared infra addresses
- launch deploy binary, workdir, and script target

The app expects the launch path to be Sepolia-only.

The app-side validation steps are:

```bash
mix autolaunch.doctor
AUTOLAUNCH_MOCK_DEPLOY=true mix autolaunch.smoke
```

Use `doctor` to confirm the environment.

Use `smoke` to prove the app can carry a synthetic launch through to a readable subject.

## Phase 3: Deploy one launch stack

This is the per-token deployment.

The launch script uses the shared infrastructure from phase 1 and creates the token-specific stack for one launch.

It creates:

1. The token
2. The auction
3. The strategy
4. The vesting wallet
5. The fee hook
6. The fee vault
7. The fee registry entry for the official pool
8. The revenue splitter for this subject
9. The default ingress account for this subject

### Economic shape of the launch

The launch split is fixed:

- 10% sold in the auction
- 5% reserved for LP migration
- 85% sent to vesting

The launch is Sepolia-only and auction bids are in Sepolia USDC.

### What the launch script returns

The launch script prints one machine-readable line:

- `CCA_RESULT_JSON:`

That result includes the important addresses the app needs to track the launch:

- token
- auction
- strategy
- vesting wallet
- fee hook
- fee vault
- fee registry
- subject registry
- subject id
- revenue splitter
- default ingress
- pool id

### What to verify after launch deploy

Do not treat the launch as complete until you verify:

1. The launch job reached `ready`.
2. The app stored the returned launch addresses.
3. The auction page is live.
4. The subject page is live.
5. The subject has a default ingress address.
6. The revenue splitter and subject id exist.

## Phase 4: Auction goes live

Once the launch stack exists, the auction becomes the public entrypoint.

Operationally, the operator should confirm:

1. The auction is visible in `/auctions`.
2. The auction detail page can return live quotes.
3. Bids can be submitted and then appear in positions.
4. Exit and claim actions behave as expected after the auction lifecycle changes.

At this point, the operator is mostly watching and supporting, not deploying.

## Phase 5: Post-auction liquidity and revenue path

After the auction, the strategy moves the reserved LP slice into the official Uniswap v4 position.

That is the handoff from launch mode into ongoing market mode.

From there, the fee and revenue path is:

1. Pool activity creates launch-pool fees.
2. The fee hook records those fees in the fee vault.
3. The subject treasury lane can be pulled from the fee vault into the revenue splitter.
4. Recognized Sepolia USDC can also arrive through ingress accounts and be swept into the splitter.
5. The splitter makes the staker share claimable and tracks the treasury and protocol shares separately.

Important rule:

- revenue only counts once Sepolia USDC reaches the subject’s revenue splitter

That is the point where the system treats revenue as recognized.

## Phase 6: Subject operations after launch

Once the subject exists, the operator can use the subject surface for ongoing actions.

The subject page is where the operator or token holder can:

- view staking state
- prepare stake and unstake actions
- prepare USDC claim actions
- inspect ingress accounts
- prepare ingress sweep actions

The app path for this is:

- `/subjects/:id`

The advanced contract console is:

- `/contracts`

Use the subject page for normal actions and the contracts page for deeper inspection and prepared payloads.

## Trust and identity follow-up

Launch itself is Sepolia-only.

Trust follow-up is separate.

After launch, the operator may still need to:

- attach ENS to the creator identity
- complete AgentBook or World trust follow-up for the launched token

Those are valid follow-up tasks, but they are not part of the core Sepolia launch deployment itself.

## Release checklist

Use this as the short operator checklist.

### Before shared infra

- `mix autolaunch.doctor` passes
- Sepolia RPC is reachable
- SIWA is reachable
- deploy binary, workdir, and script target are configured

### After shared infra

- saved `AUTOLAUNCH_INFRA_RESULT_JSON`
- subject registry exists
- revenue share factory exists
- revenue ingress factory exists
- strategy factory exists

### Before real launch

- shared infra addresses are present in runtime config
- `AUTOLAUNCH_MOCK_DEPLOY=true mix autolaunch.smoke` passes
- launch owner wallet and routing addresses are confirmed

### After real launch

- saved `CCA_RESULT_JSON`
- launch job is `ready`
- auction page is live
- subject page is live
- default ingress exists
- revenue splitter exists

## What can go wrong

These are the most important operator failure modes.

### `doctor` fails

That means the environment is not ready. Do not attempt a real launch.

### Shared infra deploy succeeds but later launches cannot create subjects

That usually means the subject registry was not handed off correctly to the revenue share factory.

### Launch deploy returns incomplete output

Do not move forward. The app expects the full returned stack.

### Auction is live but subject page is missing

That means the launch output was not stored or surfaced correctly. Treat it as a broken launch state until resolved.

### USDC arrives somewhere but is not recognized as revenue

That usually means it has not actually reached the revenue splitter yet.

## Bottom line

The operator process is:

1. stand up the shared factories once
2. wire those addresses into the app and launch environment
3. deploy one launch stack per token
4. verify the auction and subject surfaces
5. let fees and recognized Sepolia USDC flow into the subject splitter over time

That is the full infrastructure setup story in operational form.
