# Foundry Testing Guide

This package now tests the full Autolaunch contract stack in one Foundry project.

## Current test surface

### Launch-side tests

- `test/AgentLaunchToken.t.sol`
  - proves plain transfer behavior for the launch token
- `test/LaunchDeploymentController.t.sol`
  - proves the deployment controller wires the launch token, auction, fee stack, subject registry, revsplit, and default ingress together
  - includes the mainnet emissions controller override case
- `test/LaunchFeeVault.t.sol`
  - proves the treasury and Regent fee lanes are tracked separately
  - proves withdrawal permissions and native-quote rejection
- `test/LaunchPoolFeeHook.t.sol`
  - proves the 2% fee logic, USDC quote-token behavior, and pool-registration guards
- `test/ExampleCCADeploymentScript.t.sol`
  - proves the launch script reads env inputs correctly and returns the full launch stack

### Revenue / emissions tests

- `test/RevenueShareSplitter.t.sol`
- `test/MainnetRegentEmissionsController.t.sol`
- `test/DeployMainnetRegentEmissionsControllerScript.t.sol`

## Recommended commands

Run the full suite:

```bash
cd /Users/sean/Documents/regent/contracts/autolaunch
forge test
```

Run launch-side tests only:

```bash
forge test --match-contract Launch
forge test --match-contract ExampleCCADeploymentScriptTest
forge test --match-contract AgentLaunchTokenTest
```

Run revenue / emissions tests only:

```bash
forge test --match-contract RevenueShareSplitterTest
forge test --match-contract MainnetRegentEmissionsControllerTest
```

## What acceptance looks like

- the full suite passes inside `contracts/autolaunch`
- the launch script can deploy:
  - token
  - auction
  - fee hook
- fee vault
- fee registry
- subject splitter
- launch-side tests confirm:
  - USDC quote-token wiring
  - 1% subject lane + 1% Regent lane
  - subject creation and identity linking
  - mainnet emissions controller override behavior

## Active test posture

The main architecture story to protect is:

- launch stack and revenue stack live in one package
- only mainnet USDC that reaches the revsplit counts as recognized revenue
- the mainnet emissions controller is the active emissions rail
