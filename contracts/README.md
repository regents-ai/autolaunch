# Autolaunch Contracts

This Foundry project is the canonical home for all Autolaunch Solidity work.

It now contains the full launch stack and the revenue / emissions stack in one place.

## Active core architecture

- External CCA factory with USDC quote token
- `src/AgentLaunchToken.sol`
- `src/LaunchDeploymentController.sol`
- `src/LaunchFeeRegistry.sol`
- `src/LaunchFeeVault.sol`
- `src/LaunchPoolFeeHook.sol`
- `src/revenue/SubjectRegistry.sol`
- `src/revenue/RevenueShareFactory.sol`
- `src/revenue/RevenueShareSplitter.sol`
- `src/revenue/MainnetRegentEmissionsController.sol`

## Product rule

- Only mainnet USDC that reaches the subject revsplit counts as recognized revenue.
- The mainnet emissions controller is the active emissions rail for that recognized onchain state.

## Deployment helpers

- `scripts/DeployAutolaunchInfra.s.sol`
- `scripts/ExampleCCADeploymentScript.s.sol`
- `scripts/DeployMainnetRegentEmissionsController.s.sol`

Important script output markers stay unchanged:

- `AUTOLAUNCH_INFRA_RESULT_JSON:`
- `CCA_RESULT_JSON:`
- `MAINNET_REGENT_EMISSIONS_RESULT_JSON:`

## Test coverage

Launch-side tests:

- `test/AgentLaunchToken.t.sol`
- `test/LaunchDeploymentController.t.sol`
- `test/LaunchFeeVault.t.sol`
- `test/LaunchPoolFeeHook.t.sol`
- `test/ExampleCCADeploymentScript.t.sol`

Revenue / emissions tests:

- `test/RevenueShareSplitter.t.sol`
- `test/MainnetRegentEmissionsController.t.sol`
- `test/DeployMainnetRegentEmissionsControllerScript.t.sol`

## Working here

- Put all Autolaunch Solidity contracts, Foundry scripts, and Foundry tests in this folder.
- Put Autolaunch CLI work in `/Users/sean/Documents/regent/monorepo/regent-cli`.
- Put Autolaunch Phoenix app work in `/Users/sean/Documents/regent/autolaunch`.

## Build and test

```bash
cd /Users/sean/Documents/regent/contracts/autolaunch
forge build
forge test
```

## Further reading

- `CONTRACTS.md`
- `docs/ARCHITECTURE_GUIDE.md`
- `docs/FOUNDRY_TESTING_GUIDE.md`
