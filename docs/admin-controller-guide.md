# Autolaunch Admin Controller Guide

This guide is for the Autolaunch operator who controls deployments, launch settlement, contract administration, and production readiness.

The admin role is not a normal user role. Use it when you are preparing infrastructure, launching an agent, recovering a stuck launch, moving ownership, funding rewards, or checking that the public app and CLI are ready.

## What You Control

As admin controller, you can:

- deploy and verify the shared Autolaunch contracts
- configure app addresses and production settings
- prepare and run the CLI-first launch path for an agent
- monitor live auctions and post-auction settlement
- recover failed auctions when recovery is available
- prepare ownership, fee, splitter, registry, and ingress actions
- operate the subject revenue system for known subjects
- operate the separate `$REGENT` staking rail
- check profile, identity, ENS, AgentBook, and X connector readiness

You should not manually change live production data to force a launch forward. Use the app, CLI, contract actions, or documented recovery tasks.

## Readiness Checks

From `/Users/sean/Documents/regent/autolaunch`:

```bash
mix autolaunch.doctor
mix autolaunch.beta_check
AUTOLAUNCH_MOCK_DEPLOY=true mix autolaunch.smoke
mix precommit
```

From `/Users/sean/Documents/regent/autolaunch/contracts`:

```bash
forge fmt --check
forge build
forge test
```

Use these before a public launch and again after contract, API, CLI, or deployment setting changes.

## Deploy Shared Contracts

Use Foundry from the contracts workspace:

```bash
cd /Users/sean/Documents/regent/autolaunch/contracts
forge script scripts/DeployAutolaunchInfra.s.sol:DeployAutolaunchInfraScript \
  --rpc-url <base-rpc-url> \
  --broadcast \
  --slow
```

Record the deployed addresses in the app's normal deployment configuration. Do not copy secrets into docs or commit local environment files.

The contracts that matter for the launch stack are:

- launch deployment controller
- launch strategy factory
- launch fee registry and vault
- launch pool fee hook
- subject registry
- revenue share factory
- revenue ingress factory
- payment link factory
- `$REGENT` revenue staking contracts

## Prepare An Agent Launch

The preferred launch path is CLI-first.

Use the agent's local setup:

```bash
regents auth login --audience autolaunch
regents identity ensure
regents autolaunch safe wizard
regents autolaunch safe create --backup-signer-address <wallet> --website-wallet-address <wallet>
```

Then create and publish the launch plan:

```bash
regents autolaunch prelaunch wizard
regents autolaunch prelaunch validate --plan <plan-id>
regents autolaunch prelaunch publish --plan <plan-id>
```

Run the launch:

```bash
regents autolaunch launch run --plan <plan-id>
regents autolaunch jobs watch <job-id> --watch
regents autolaunch launch monitor --job <job-id> --watch
```

After the launch is ready, verify the deployment:

```bash
mix autolaunch.verify_deploy --job <job-id>
```

## Monitor Live Auctions

Use the browser when you want a quick visual read:

- `/auctions` for live and recent auctions
- `/auctions/:id` for one auction
- `/positions` for a wallet's bids and claims
- `/tokens` for graduated subject tokens

Use the CLI when you want repeatable output:

```bash
regents autolaunch auctions list --status live
regents autolaunch auction <auction-id>
regents autolaunch agents list
regents autolaunch agent <agent-id>
regents autolaunch agent readiness <agent-id>
```

## End And Settle Auctions

Use the settlement summary and the prepared actions it recommends. Do not treat every auction as a simple "migrate now" case.

For the normal CLI path:

```bash
regents autolaunch launch finalize --job <job-id>
regents autolaunch launch monitor --job <job-id>
```

For direct recovery and admin work, use the contracts surface:

```bash
regents autolaunch contracts job --job <job-id>
regents autolaunch strategy migrate --job <job-id>
regents autolaunch strategy sweep-quote-token --job <job-id>
regents autolaunch strategy sweep-token --job <job-id>
```

The web app also has `/contracts` for operator review and wallet actions. Use it when you want to inspect the action before sending it from a browser wallet or Safe.

## Subject Revenue And Staking

Use subject commands to inspect and operate one subject:

```bash
regents autolaunch subjects get <subject-id>
regents autolaunch subjects by-token --token <token-address>
regents autolaunch subjects ingress <subject-id>
regents autolaunch subjects staking <subject-id>
```

If the admin wallet is also the controller for a subject, it can prepare subject actions:

```bash
regents autolaunch subjects stake <subject-id> --amount <token-amount>
regents autolaunch subjects unstake <subject-id> --amount <token-amount>
regents autolaunch subjects claim-usdc <subject-id>
regents autolaunch subjects sweep-ingress <subject-id> --address <ingress-address>
```

Use `/subjects/:id` in the web app for the same kind of subject review and wallet-driven subject actions.

## Factory And Registry Administration

The admin-only contract actions are available through the CLI and `/contracts`.

Common examples:

```bash
regents autolaunch factory revenue-share set-authorized-creator --account <address> --enabled true
regents autolaunch factory revenue-ingress set-authorized-creator --account <address> --enabled true
regents autolaunch registry link-identity --subject <subject-id> --identity-chain-id <id> --identity-registry <address> --identity-agent-id <id>
regents autolaunch registry set-subject-manager --subject <subject-id> --account <address> --enabled true
regents autolaunch splitter propose-treasury-recipient-rotation --subject <subject-id> --recipient <address>
```

Use these only when the signer is the expected owner or operator. If a Safe owns the contract, prepare the action and submit it through the Safe.

## `$REGENT` Staking

`$REGENT` staking is separate from per-agent subject staking.

Use the CLI for operator checks and repeatable actions:

```bash
regents regent-staking get
regents regent-staking account <wallet-address>
regents regent-staking stake --amount <regent-amount>
regents regent-staking unstake --amount <regent-amount>
regents regent-staking claim-usdc
regents regent-staking claim-regent
regents regent-staking claim-and-restake-regent
```

Use `/regent-staking` in the web app when you want a wallet-driven view for a human user.

## Profiles And Identity Connectors

Use these admin checks when launch trust, identity, or profile data is part of the launch review:

```bash
regents identity status
regents identity ensure
regents identity graph --json
regents autolaunch pair --code <pairing-code>
regents autolaunch identities list --chain base-mainnet
regents autolaunch identities mint --chain base-mainnet
regents autolaunch ens plan --identity <identity-id>
regents autolaunch ens prepare-bidirectional --identity <identity-id>
regents agentbook lookup
regents agentbook register --watch
```

Use the web app for human-owned connectors:

- `/profile` for the signed-in human profile and paired agent identities
- `/agentbook` for human-backed trust
- `/ens-link` for ENS and ERC-8004 linking
- `/x-link` for X linking

## Payment Links

Payment links are contracts plus documentation in this repo. There is no public CLI command or web creation flow for them today.

Use `/Users/sean/Documents/regent/autolaunch/docs/payment-links.md` for direct contract usage. Payment link receivers forward Base USDC into the subject's current revenue destination. They are different from ingress accounts, which are factory-created and pinned to one known revenue path.

## Admin Safety Rules

- Use CLI and web actions instead of manual live data edits.
- Use Foundry for contract work.
- Keep launch settlement and deployment progress separate.
- Treat subject USDC as counted only when it reaches the subject revenue contract.
- Treat launch-pool fees as quote-token balances, separate from USDC ingress sweeps, direct deposits, and payment links.
- Do not expose payment links as a product flow until the deployed factory address is configured and documented.
- Do not read or commit local secret files.
