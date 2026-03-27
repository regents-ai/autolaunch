# Autolaunch Contracts Overview

This package now covers the full Autolaunch contract system, from launch through ongoing revenue recognition.

## Core contracts

### Launch-side stack

- `LaunchDeploymentController`
  - assembles the launch stack in one call
  - deploys the token, strategy-owned auction, vesting wallet, fee plumbing, subject splitter, and default ingress
- `AgentTokenVestingWallet`
  - holds the 85% retained launch allocation on a timestamp vesting schedule
- `RegentLBPStrategy`
  - owns the 15% launch-side token supply
  - creates the auction
  - migrates the LP slice and later sweeps leftovers
- `RegentLBPStrategyFactory`
  - creates the per-launch Regent strategy instance
- `LaunchFeeRegistry`
  - records the official pool configuration and recipients for each launch pool
- `LaunchFeeVault`
  - stores the hook-side fee balances until they are withdrawn
- `LaunchPoolFeeHook`
  - charges the 2% launch-pool fee
  - 1% goes to the subject revenue lane
  - 1% goes to the Regent side

### Revenue stack

- `SubjectRegistry`
  - canonical record for each launched subject
  - links the stake token, splitter, treasury safe, and linked identities
- `RevenueShareFactory`
  - deploys the revsplit for a subject and provisions the subject record
- `RevenueIngressFactory`
  - deploys the canonical per-subject USDC receiving addresses
- `RevenueIngressAccount`
  - receives raw USDC and sweeps it into splitter accounting
- `RevenueShareSplitter`
  - canonical revsplit and staking contract for the launched token
  - only Sepolia USDC that reaches this contract counts as recognized revenue

## External dependencies

- external CCA factory
- ERC-8004 identity registry
- USDC
- Uniswap v4 pool manager

## Deployment flow

1. Deploy shared Autolaunch infra with `DeployAutolaunchInfra.s.sol`.
2. Run `ExampleCCADeploymentScript.s.sol` to create a launch.
3. The launch script returns the full stack through `CCA_RESULT_JSON:`.

## What the launch script creates

- agent token
- vesting wallet
- Regent strategy
- auction
- fee hook
- fee vault
- fee registry
- subject registry link
- revenue share splitter
- default ingress

## Routing rules for the wider project

- Autolaunch contracts live here: `/Users/sean/Documents/regent/autolaunch/contracts`
- Autolaunch CLI work lives in: `/Users/sean/Documents/regent/regent-cli`
- Autolaunch Phoenix app work lives in: `/Users/sean/Documents/regent/autolaunch`
