# Autolaunch Contracts

This Foundry project is the canonical home for all Autolaunch Solidity work.

It now contains the full launch stack plus the ongoing revsplit and ingress contracts in one place.

The canonical product rules live in `/Users/sean/Documents/regent/autolaunch/docs/product_invariants.md`.

## Active core architecture

- External CCA factory with $REGENT as the Base mainnet auction quote token
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
- `src/revenue/RevenueShareSplitterV2.sol`
- `src/revenue/RegentRevenueStaking.sol`
- `RegentLBPStrategy` now migrates its LP slice through the official Uniswap v4 position manager and records the minted pool and position ids.

## Product rule

- Subject USDC is counted when it reaches the revsplit. Verified ingress and direct deposits are tracked separately from $REGENT launch-pool fees.
- The Regent-side launch-pool fee lane is a plain treasury payout.
- Recognized subject USDC sends 1% into `RegentRevenueStaking`, uses 10% of the remaining 99% to buy `$REGENT` for the agent treasury, and leaves 89.1% in the subject revsplit lane.
- The staking revenue router must have a Regent buyback adapter set before recognized subject USDC can complete this route.
- The launch deployment uses the configured official pool fee, tick spacing, and position manager for the agent token / $REGENT pool.
- A human-readable walkthrough of splitter and receiver creation lives in `/Users/sean/Documents/regent/autolaunch/docs/stake-split-payment-receiver-flow.md`.

## Deployment helpers

- `scripts/DeployAutolaunchInfra.s.sol`
- `scripts/DeployUERC20Factory.s.sol`
- `scripts/ExampleCCADeploymentScript.s.sol`
- `scripts/DeployRegentRevenueStaking.s.sol`

The launch script expects the active Base mainnet inputs, including `AUTOLAUNCH_AUCTION_QUOTE_TOKEN_ADDRESS`, `AUTOLAUNCH_REVENUE_USDC_ADDRESS`, `AUTOLAUNCH_TOKEN_FACTORY_ADDRESS`, `AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER`, `OFFICIAL_POOL_FEE`, and `OFFICIAL_POOL_TICK_SPACING`. `AUTOLAUNCH_AUCTION_QUOTE_TOKEN_ADDRESS` must be Base mainnet $REGENT. `AUTOLAUNCH_REVENUE_USDC_ADDRESS` must be canonical Base USDC. `AUTOLAUNCH_TOKEN_FACTORY_ADDRESS` must point to a UERC20-compatible factory deployed on Base mainnet. The script builds a normalized convex CCA token release schedule from `AUCTION_DURATION_BLOCKS`; `86400` Base blocks is a 48-hour convex sale window, followed by the final one-block residual release. `CCA_PREBID_BLOCKS=0` and `CCA_FINAL_BLOCK_BPS=3000` are the defaults. `CCA_START_BLOCK_OFFSET=300` leaves about ten minutes for the staged broadcast to finish before bidding opens.

Important script output markers stay unchanged:

- `AUTOLAUNCH_INFRA_RESULT_JSON:`
- `CCA_RESULT_JSON:`

`AUTOLAUNCH_INFRA_RESULT_JSON` only includes Regent shared infra addresses. Deploy
`DeployUERC20Factory.s.sol` first when a UERC20 factory is not already deployed on the
target chain, then set `AUTOLAUNCH_TOKEN_FACTORY_ADDRESS` from
`UERC20_FACTORY_RESULT_JSON.factoryAddress`. The default $REGENT auction grid uses
`CCA_FLOOR_PRICE_Q96=7922816251426433759354395000` and
`CCA_TICK_SPACING_Q96=79228162514264337593543950`, which is a 0.1 REGENT floor with
0.001 REGENT ticks. At REGENT near $0.00001, that maps to about $0.000001 per
agent token at the floor and keeps bid prices aligned through the $0.10 range.

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
