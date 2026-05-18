# Autolaunch Contracts Overview

This package now covers the full Autolaunch contract system, from launch through ongoing revenue recognition.

## Core contracts

### Launch-side stack

- `LaunchDeploymentController`
  - assembles the launch stack in one call
  - creates the UERC20 launch token, strategy-owned auction, vesting wallet, fee plumbing, subject splitter, and default ingress
  - threads the official pool fee, tick spacing, and position manager into the strategy config
- `AgentTokenVestingWallet`
  - holds the 85% retained launch allocation on a timestamp vesting schedule
- `RegentLBPStrategy`
  - owns the 15% launch-side token supply
  - creates the auction
  - passes the configured CCA duration as an even token release schedule
  - migrates the LP slice through the official Uniswap v4 position manager, then sweeps leftovers
  - records the minted pool id, position id, and liquidity onchain
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
  - counts subject USDC when it reaches this contract, with verified ingress and direct deposits tracked separately
- `RegentRevenueStaking`
  - singleton Base-mainnet staking and Base USDC rewards rail for the existing `$REGENT` token
  - fed manually after Treasury A bridges non-Base income into Base USDC
  - distinct from the Sepolia per-agent subject splitters

## External dependencies

- external CCA factory
- UERC20-compatible token factory
- optional ERC-8004 identity registry for launch identity links
- USDC
- official Uniswap v4 pool manager and position manager

## Deployment flow

1. Deploy or confirm a UERC20-compatible token factory and set `AUTOLAUNCH_TOKEN_FACTORY_ADDRESS`.
2. Deploy shared Regent Autolaunch infra with `DeployAutolaunchInfra.s.sol`.
3. Run `ExampleCCADeploymentScript.s.sol` to create a launch.
4. The launch script returns the full stack through `CCA_RESULT_JSON:`.

For a 48-hour Base Sepolia auction, set `AUCTION_DURATION_BLOCKS=86400`. The script builds a normalized convex CCA auction-step schedule from that duration, then appends the final one-block residual release. The default schedule uses `CCA_PREBID_BLOCKS=0` and `CCA_FINAL_BLOCK_BPS=3000`.

The default $REGENT auction grid uses `CCA_FLOOR_PRICE_Q96=7922816251426433759354395000` and `CCA_TICK_SPACING_Q96=79228162514264337593543950`, a 0.1 REGENT floor with 0.001 REGENT ticks. At REGENT near $0.00001, that maps to about $0.000001 per agent token at the floor and keeps bid prices aligned through the $0.10 range. The script rejects zero floor price, zero tick spacing, misaligned floor/tick values, and auction steps that do not exactly cover the configured duration and supply schedule.

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
- Autolaunch CLI work lives in: `/Users/sean/Documents/regent/regents-cli`
- Autolaunch Phoenix app work lives in: `/Users/sean/Documents/regent/autolaunch`
