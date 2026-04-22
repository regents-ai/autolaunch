# Autolaunch Contracts Actors And Privileges

This file maps who can do what in the active contracts workspace.

## Main Actors

### Launch deployment owner

Contract:

- `LaunchDeploymentController`

Capabilities:

- deploy the full launch stack

Notes:

- this is the highest-trust deployment role during bootstrap
- ownership of the fee registry, fee vault, and fee hook is handed to the agent safe after deployment

### Agent safe

Main touchpoints:

- owner of the deployed `LaunchFeeRegistry`
- owner of the deployed `LaunchFeeVault`
- owner of the deployed `LaunchPoolFeeHook`
- owner of each `RevenueShareSplitter`
- beneficiary and manager role in subject operations
- treasury authority for rescue paths in `RegentLBPStrategy`

Capabilities:

- rotate splitter treasury recipient
- pause or unpause splitter
- set splitter protocol recipient
- set splitter emissions rate
- reassign undistributed dust to treasury
- manage subject metadata and managers through `SubjectRegistry`
- withdraw launch fee vault treasury share for the registered pool treasury
- rescue non-canonical assets or native balance from the strategy

### Strategy operator

Contract:

- `RegentLBPStrategy`

Capabilities:

- migrate from auction proceeds into the official v4 LP
- sweep leftover launch token into vesting after migration
- sweep leftover USDC into the treasury after migration
- recover failed auctions after the allowed time window

Notes:

- this role cannot perform treasury rescue functions
- this role is operationally sensitive because it controls the migration and recovery path

### Pool manager

Contract:

- `LaunchPoolFeeHook`

Capabilities:

- may call `afterSwap`

Notes:

- the hook rejects direct calls from any other sender
- fee accrual depends on the pool having been registered in `LaunchFeeRegistry`

### Launch fee vault registered recipients

Contract:

- `LaunchFeeVault`

Capabilities:

- registered subject treasury can withdraw the treasury share for its pool
- registered Regent recipient can withdraw the Regent share for its pool

Notes:

- the hook is the only allowed accrual writer

### Subject registry owner and subject managers

Contract:

- `SubjectRegistry`

Capabilities:

- owner can create subjects
- subject managers can update a subject, rotate treasury-safe control, and manage identity links

Notes:

- the treasury safe is automatically made a subject manager
- subject lifecycle updates are forwarded into the splitter contracts

### Revenue share factory owner and authorized creators

Contract:

- `RevenueShareFactory`

Capabilities:

- owner can add authorized creators
- owner or authorized creators can create subject splitters
- owner can transfer subject registry ownership away from the factory

Notes:

- the factory temporarily owns a newly created splitter, creates and links the subject, then hands splitter ownership to the agent safe

### Revenue ingress factory owner, authorized creators, and subject managers

Contract:

- `RevenueIngressFactory`

Capabilities:

- owner can add authorized creators
- owner, authorized creators, or subject managers can create ingress accounts
- subject managers can change the default ingress account

### Revenue ingress account owner

Contract:

- `RevenueIngressAccount`

Capabilities:

- change the account label
- rescue unsupported assets or forced native balance through inherited ownership utilities

Notes:

- canonical USDC is protected from rescue

### Regent revenue staking owner and treasury

Contract:

- `RegentRevenueStaking`

Capabilities:

- owner can pause or unpause
- owner can change the treasury recipient
- owner can change the Regent emission rate
- owner or treasury recipient can withdraw treasury residual USDC

Notes:

- this contract is outside the active per-launch path, but still holds live accounting risk

## Functions Worth Extra Review

These paths combine privilege with meaningful asset movement:

- `LaunchDeploymentController.deploy`
- `RegentLBPStrategy.migrate`
- `RegentLBPStrategy.recoverFailedAuction`
- `LaunchFeeVault.withdrawTreasury`
- `LaunchFeeVault.withdrawRegent`
- `RevenueShareSplitter.depositUSDC`
- `RevenueShareSplitter.pullTreasuryShareFromLaunchVault`
- `RevenueShareSplitter.claimAndRestakeStakeToken`
- `RevenueShareSplitter.sweepTreasuryResidualUSDC`
- `RevenueShareSplitter.sweepProtocolReserveUSDC`
- `SubjectRegistry.updateSubject`
- `RevenueIngressAccount.sweepUSDC`
- `RegentRevenueStaking.depositUSDC`
- `RegentRevenueStaking.claimAndRestakeRegent`
- `RegentRevenueStaking.withdrawTreasuryResidual`
