# Foundry Testing Guide

This package now tests the full Autolaunch contract stack in one Foundry project.

## Current test surface

### Launch-side tests

- `test/LaunchDeploymentController.t.sol`
  - proves the deployment controller wires the factory-created token, strategy-owned auction, fee stack, subject registry, revsplit, vesting wallet, and default ingress together
- `test/RegentLBPStrategy.t.sol`
  - proves the strategy creates the auction, initializes the official v4 pool, mints a real position, and sweeps leftovers
- `test/RegentLBPStrategyFactory.t.sol`
  - proves the factory creates the strategy with the expected config
- `test/LaunchFeeVault.t.sol`
  - proves the treasury and Regent fee lanes are tracked separately
  - proves withdrawal permissions and native-quote rejection
- `test/LaunchPoolFeeHook.t.sol`
  - proves the 2% fee logic, USDC quote-token behavior, and pool-registration guards
- `test/ExampleCCADeploymentScript.t.sol`
  - proves the launch script reads env inputs correctly and returns the full launch stack

### Revenue tests

- `test/RevenueIngressAccount.t.sol`
- `test/RevenueIngressFactory.t.sol`
- `test/RevenueShareSplitter.t.sol`

## Recommended commands

Run the full suite:

```bash
cd /Users/sean/Documents/regent/autolaunch/contracts
forge test
```

Run launch-side tests only:

```bash
forge test --match-contract Launch
forge test --match-contract ExampleCCADeploymentScriptTest
forge test --match-contract RegentLBPStrategyTest
```

Run revenue tests only:

```bash
forge test --match-contract RevenueShareSplitterTest
forge test --match-contract RevenueIngressAccountTest
```

## What acceptance looks like

- the full suite passes inside `contracts/`
- the launch script can deploy:
  - token
  - strategy
  - vesting wallet
  - auction
  - fee hook
  - fee vault
  - fee registry
  - subject splitter
  - default ingress
- launch-side tests confirm:
  - USDC quote-token wiring
  - official pool fee and tick spacing wiring
  - 1% subject lane + 1% Regent lane
  - subject creation and identity linking
  - default ingress creation and linkage

## Active test posture

The main architecture story to protect is:

- launch stack and revenue stack live in one package
- only Sepolia USDC that reaches the revsplit counts as recognized revenue
- the active Sepolia launch path still has no automatic REGENT rewards rail, even though the separate Base `RegentRevenueStaking` contract exists
