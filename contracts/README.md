# Autolaunch Contracts

This Foundry project is the canonical home for all Autolaunch Solidity work.

It now contains the full launch stack plus the ongoing revsplit and ingress contracts in one place.

The canonical product rules live in `/Users/sean/Documents/regent/autolaunch/docs/product_invariants.md`.

## Active core architecture

- External CCA factory with USDC quote token
- Uniswap UERC20 factory for launch token creation
- `src/LaunchDeploymentController.sol`
- `src/AgentTokenVestingWallet.sol`
- `src/RegentLBPStrategy.sol`
- `src/RegentLBPStrategyFactory.sol`
- `src/LaunchFeeRegistry.sol`
- `src/LaunchFeeVault.sol`
- `src/LaunchPoolFeeHook.sol`
- `src/revenue/SubjectRegistry.sol`
- `src/revenue/RevenueShareFactory.sol`
- `src/revenue/RevenueIngressFactory.sol`
- `src/revenue/RevenueIngressAccount.sol`
- `src/revenue/RevenueShareSplitter.sol`
- `src/revenue/RegentRevenueStaking.sol`
- `RegentLBPStrategy` now migrates its LP slice through the official Uniswap v4 position manager and records the minted pool and position ids.

## Product rule

- Subject USDC is counted when it reaches the revsplit. Verified ingress, launch fees, and direct deposits are tracked separately.
- The Regent-side fee lane is a plain treasury payout. There is no REGENT reward-accounting contract in the active path.
- A separate Base-mainnet `RegentRevenueStaking` rail now exists for `$REGENT` rewards. It is fed manually with Base USDC and does not change the active launch path.
- The launch deployment uses the configured official pool fee, tick spacing, and position manager as part of the hard-cutover migration path.

## Deployment helpers

- `scripts/DeployAutolaunchInfra.s.sol`
- `scripts/DeployUERC20Factory.s.sol`
- `scripts/ExampleCCADeploymentScript.s.sol`
- `scripts/DeployRegentRevenueStaking.s.sol`

The launch script expects the active Base mainnet inputs, including `AUTOLAUNCH_TOKEN_FACTORY_ADDRESS`, `AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER`, `OFFICIAL_POOL_FEE`, and `OFFICIAL_POOL_TICK_SPACING`. `AUTOLAUNCH_TOKEN_FACTORY_ADDRESS` must point to a UERC20-compatible factory deployed on Base mainnet. The script builds a normalized convex CCA token release schedule from `AUCTION_DURATION_BLOCKS`; `86400` Base blocks is a 48-hour convex sale window, followed by the final one-block residual release. `CCA_PREBID_BLOCKS=0` and `CCA_FINAL_BLOCK_BPS=3000` are the defaults. `CCA_START_BLOCK_OFFSET=300` leaves about ten minutes for the staged broadcast to finish before bidding opens.

Important script output markers stay unchanged:

- `AUTOLAUNCH_INFRA_RESULT_JSON:`
- `CCA_RESULT_JSON:`

`AUTOLAUNCH_INFRA_RESULT_JSON` only includes Regent shared infra addresses. Deploy
`DeployUERC20Factory.s.sol` first when a UERC20 factory is not already deployed on the
target chain, then set `AUTOLAUNCH_TOKEN_FACTORY_ADDRESS` from
`UERC20_FACTORY_RESULT_JSON.factoryAddress`. For rehearsals, use a CCA tick spacing equal
to 1% of the floor price unless there is a specific reason to use tighter ticks.

## Test coverage

Launch-side tests:

- `test/LaunchDeploymentController.t.sol`
- `test/DeployUERC20Factory.t.sol`
- `test/RegentLBPStrategy.t.sol`
- `test/RegentLBPStrategyFactory.t.sol`
- `test/LaunchFeeVault.t.sol`
- `test/LaunchPoolFeeHook.t.sol`
- `test/ExampleCCADeploymentScript.t.sol`

Revenue tests:

- `test/RevenueIngressAccount.t.sol`
- `test/RevenueIngressFactory.t.sol`
- `test/RevenueShareSplitter.t.sol`
- `test/RegentRevenueStaking.t.sol`

## Working here

- Put all Autolaunch Solidity contracts, Foundry scripts, and Foundry tests in this folder.
- Put Autolaunch CLI work in `/Users/sean/Documents/regent/regents-cli`.
- Put Autolaunch Phoenix app work in `/Users/sean/Documents/regent/autolaunch`.

## Build and test

```bash
cd /Users/sean/Documents/regent/autolaunch/contracts
forge build
forge test
```

## Further reading

- `CONTRACTS.md`
- `docs/ARCHITECTURE_GUIDE.md`
- `docs/FOUNDRY_TESTING_GUIDE.md`
- `docs/LAUNCH_POOL_FEE_HOOK_SECURITY.md`
