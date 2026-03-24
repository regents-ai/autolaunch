# Autolaunch Contracts Overview

This package now covers the full Autolaunch contract system, from launch through ongoing revenue recognition and emissions.

## Core contracts

### Launch-side stack

- `AgentLaunchToken`
  - the launched agent token with the fixed 100 billion supply convention used by the launch flow
- `LaunchDeploymentController`
  - assembles the launch stack in one call
  - deploys the token, auction, fee plumbing, and subject splitter
- `LaunchFeeRegistry`
  - records the official pool configuration and recipients for each launch pool
- `LaunchFeeVault`
  - stores the hook-side fee balances until they are withdrawn
- `LaunchPoolFeeHook`
  - charges the 2% launch-pool fee
  - 1% goes to the subject revenue lane
  - 1% goes to the Regent side

### Revenue / emissions stack

- `SubjectRegistry`
  - canonical record for each launched subject
  - links the stake token, splitter, treasury safe, linked identities, and emission recipient
- `RevenueShareFactory`
  - deploys the revsplit for a subject and provisions the subject record
- `RevenueShareSplitter`
  - canonical revsplit and staking contract for the launched token
  - only mainnet USDC that reaches this contract counts as recognized revenue
- `MainnetRegentEmissionsController`
  - mainnet emissions rail for recognized onchain USDC revenue

## External dependencies

- external CCA factory
- ERC-8004 identity registry
- USDC
- Uniswap v4 pool manager

## Deployment flow

1. Deploy shared Autolaunch infra with `DeployAutolaunchInfra.s.sol`.
2. Deploy the mainnet emissions controller with `DeployMainnetRegentEmissionsController.s.sol` when needed.
3. Run `ExampleCCADeploymentScript.s.sol` to create a launch.
4. The launch script returns the full stack through `CCA_RESULT_JSON:`.

## What the launch script creates

- agent token
- auction
- fee hook
- fee vault
- fee registry
- subject registry link
- revenue share splitter

## Routing rules for the wider project

- Autolaunch contracts live here: `/Users/sean/Documents/regent/autolaunch/contracts`
- Autolaunch CLI work lives in: `/Users/sean/Documents/regent/regent-cli`
- Autolaunch Phoenix app work lives in: `/Users/sean/Documents/regent/autolaunch`
