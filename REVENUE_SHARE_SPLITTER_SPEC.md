# RevenueShareSplitter Spec Note

This note describes the revsplit inside the full Autolaunch contracts package.

## Role in the system

`RevenueShareSplitter` is the canonical revsplit and staking contract for a launched agent token.

Inside the full Autolaunch architecture:

- `LaunchDeploymentController` creates the launch stack
- `RevenueShareFactory` creates the revsplit
- `SubjectRegistry` records the canonical subject
- `MainnetRegentEmissionsController` sits on top of recognized onchain USDC revenue

## Product rule

- only mainnet USDC that reaches the revsplit counts as recognized revenue
- the revsplit is therefore the canonical recognition point for the active architecture

## Math rule

For a recognized reward deposit `A`:

- `protocol = floor(A * protocolSkimBps / 10_000)`
- `net = A - protocol`
- `deltaAcc += floor(net * PRECISION / totalSupply())`
- `stakerEntitlement = floor(net * totalStaked / totalSupply())`
- `treasuryResidual += net - stakerEntitlement`

This matches the intended rule:

> a staker earns stake / totalSupply of the post-skim inflow

not stake / totalStaked.

## Scope of this note

This file only describes the revsplit behavior itself.

The launch stack, fee-hook lane, and emissions controller all live in the same package now, but they are documented separately in:

- `README.md`
- `CONTRACTS.md`
- `docs/ARCHITECTURE_GUIDE.md`
