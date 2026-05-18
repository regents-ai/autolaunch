# Stake, Split, Payment Receiver, and Token Flow

This note explains the Autolaunch revenue and launch contracts in human terms.
It covers:

- what each major contract does
- which contracts are shared singletons and which are created per launch,
  subject, or payment link
- how each token type enters, moves through, and exits the system
- the normal deploy order for the full stack

## Short Version

Each Autolaunch subject has a revenue lane. The normal launched subject uses
`RevenueShareSplitterV2` as its stake+split contract. That splitter is the
subject's Base USDC revenue home.

The subject also gets a default USDC receiver. This is a
`RevenueIngressAccount` created by `RevenueIngressFactory`. It can collect Base
USDC and later sweep that USDC into the subject splitter.

For the normal auction launch path, the subject splitter and default receiver
are created before auction graduation. In the staged deploy path, they are
created during `prepareLaunch`. In the all-at-once deploy path, they are created
before the auction strategy is initialized. Auction graduation later allows the
strategy to migrate the launch into its Uniswap v4 LP position. Graduation does
not create the subject revenue contracts.

For the deferred launch path, `DeferredAutolaunchFactory` creates the token,
vesting wallet, subject splitter, and default receiver without creating an
auction.

For an existing-token subject, `PermissionlessExistingTokenRevenueFactory`
creates a `LiveStakeFeePoolSplitter` and a default receiver around a token that
already exists. It does not create a token, auction, or vesting wallet.

## Contract Map

### Shared Subject And Revenue Infrastructure

`SubjectRegistry` is the onchain directory of subjects. It records the subject
ID, stake token, splitter, treasury, active status, managers, and optional
identity links.

`RevenueShareFactory` creates the normal subject splitter for launched or
deferred Autolaunch subjects. It deploys `RevenueShareSplitterV2`, registers the
subject in `SubjectRegistry`, optionally links identity data, and starts the
splitter ownership handoff to the agent treasury.

`RevenueShareSplitterV2Deployer` is a small helper used by
`RevenueShareFactory` to deploy `RevenueShareSplitterV2`.

`RevenueShareSplitterV2` is the normal stake+split contract. It accepts the
subject token for staking and Base USDC for revenue. It sends the fixed Regent
share to the staking router, sends the buyback share to the same router, and
keeps the remaining subject revenue for stakers and the subject treasury.

`RevenueIngressFactory` creates `RevenueIngressAccount` receivers for active
subjects.

`RevenueIngressAccount` is a managed USDC intake address. USDC sitting there has
not yet counted as subject revenue. It becomes recognized subject revenue when
the account sweeps into the subject splitter.

`PaymentLinkFactory` creates optional `PaymentLinkReceiver` contracts. Payment
links are shareable USDC receiver addresses for invoices, sponsors, buyers, or
other agents.

`PaymentLinkReceiver` forwards Base USDC into the subject's current splitter. It
looks up the current splitter in `SubjectRegistry` each time it forwards funds,
so it follows a splitter rotation.

`PermissionlessExistingTokenRevenueFactory` creates a revenue lane around an
already deployed stake token. It creates a `LiveStakeFeePoolSplitter`, registers
a permissionless subject, and creates a default ingress account.

`LiveStakeFeePoolSplitter` is the existing-token splitter. It is related to
`RevenueShareSplitterV2`, but it is used when the token already exists and the
subject does not have a launch auction. It uses a fixed staker pool percentage
instead of the normal V2 eligible-share schedule.

### Regent Staking And Buyback Infrastructure

`RegentRevenueStaking` is the shared `$REGENT` staking rail. `$REGENT` holders
stake `$REGENT` there. USDC deposits are credited across the fixed `$REGENT`
staking denominator, and unstaked denominator space leaves its matching USDC
with the Regent treasury.

The current Base mainnet runbook points the Regent staking contract to:

```text
0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5
```

`RegentStakingRevenueRouter` is the shared router used by subject splitters. It
has two jobs:

- deposit the 1% protocol share into `RegentRevenueStaking`
- use the configured buyback adapter to buy `$REGENT` for the subject treasury

`UniswapV4RegentBuybackAdapter` is the route-specific adapter that can turn
Base USDC into `$REGENT` through Uniswap v4. The current adapter route is USDC
to WETH to `$REGENT`. It can only be called by the staking revenue router that
was set as its `routerCaller`.

`RegentV4SpotPriceOracle` is a supporting quote and safety contract. It reads
the `$REGENT` / WETH Uniswap v4 pool and the ETH/USD feed to quote how much
`$REGENT` should correspond to a USDC amount. It is not the splitter itself and
does not hold subject funds.

`RegentEmissionVault` is a separate `$REGENT` inventory vault. It can hold
`$REGENT` and let a configured router emit it to recipients. It is not part of
the normal subject splitter creation path unless a future route explicitly wires
it in.

### Launch And Auction Infrastructure

`LaunchDeploymentController` coordinates a launch. It creates the token and
vesting wallet, creates the subject revenue lane, deploys fee infrastructure,
creates the launch strategy, funds it, and lets the strategy create the auction.

`LaunchFeeInfraDeployer` deploys the per-launch fee contracts:

- `LaunchFeeRegistry`
- `LaunchFeeVault`
- `LaunchPoolFeeHook`

`LaunchFeeRegistry` records the official Uniswap v4 pool for the launch token
and `$REGENT` quote token. It also stores the fee recipients.

`LaunchFeeVault` holds launch-pool fee balances until the configured recipients
withdraw them.

`LaunchPoolFeeHook` charges the 2% launch-pool fee on `$REGENT` quote-token
swaps in the official Uniswap v4 pool. That fee lane is separate from subject
Base USDC revenue.

`RegentLBPStrategyFactory` creates a per-launch `RegentLBPStrategy`.

`RegentLBPStrategy` creates the CCA auction after it receives the launch token
sale and reserve allocation. After the auction graduates, the strategy migrates
the launch into the official Uniswap v4 LP position.

`AgentTokenVestingWallet` holds the normal launch treasury allocation and
releases it over the configured vesting schedule.

`DeferredAutolaunchFactory` creates a deferred subject without an auction. It
creates the token, vesting wallet, subject splitter, and default receiver.

`DeferredAutolaunchVestingWallet` holds the full deferred token supply for the
treasury. It has a 10 day cliff for 15% of the allocation and then linear
vesting through the rest of the first year.

### Older Or Adjacent Contracts

`RevenueShareSplitter` and `RevenueShareSplitterDeployer` are older splitter
shapes. The active normal subject path uses `RevenueShareSplitterV2`.

Interfaces, libraries, mocks, and test tokens support the contracts above but
are not independent product contracts.

## Revenue Economics

When recognized subject Base USDC reaches `RevenueShareSplitterV2` or
`LiveStakeFeePoolSplitter`, the current fixed route is:

1. 1% of gross USDC goes to Regent staking through
   `RegentStakingRevenueRouter.processProtocolFee`.
2. 10% of the remaining 99%, which is 9.9% of gross USDC, goes through
   `RegentStakingRevenueRouter.processTreasuryBuyback` to buy `$REGENT` for the
   subject treasury.
3. The remaining 89.1% stays in the subject revenue lane.

For 100 USDC:

- 1 USDC goes to Regent staking.
- 9.9 USDC buys `$REGENT` for the subject treasury.
- 89.1 USDC remains in the subject lane.

In `RevenueShareSplitterV2`, the subject lane is then split by the live eligible
revenue share. Staker rewards are calculated against the fixed revenue-share
supply denominator. Any eligible share corresponding to unstaked denominator
space becomes treasury residual.

In `LiveStakeFeePoolSplitter`, the subject lane is split by the immutable
`stakerPoolBps`. If no one is staked when revenue arrives, the staker pool is
routed to the treasury.

## Token Flow By Asset Type

### 1. Normal Launch Token

The normal launch token is created through the configured UERC20-compatible
token factory.

It enters the system when `LaunchDeploymentController` creates the token. The
controller then divides supply into three lanes:

- 10% for the auction
- 5% for the Uniswap v4 LP reserve
- 85% for treasury vesting

The 10% auction allocation and 5% LP reserve move to `RegentLBPStrategy`.
`RegentLBPStrategy` sends the auction allocation to the external CCA auction
contract. Buyers later claim purchased launch tokens from the auction according
to the CCA rules.

The 5% LP reserve stays with the strategy until migration. After the auction
graduates and migration is allowed, the strategy combines launch tokens with
raised `$REGENT` quote token and mints the official Uniswap v4 LP position to
the configured position recipient.

The 85% treasury allocation moves to `AgentTokenVestingWallet`. The beneficiary
can release vested tokens over time. If the auction fails and does not
graduate, the strategy can recover unsold tokens and send them to the vesting
wallet.

After launch, people can stake the launch token in the subject splitter. Staked
tokens leave the user's wallet and sit in the splitter. They exit the splitter
when the user unstakes.

### 2. Deferred Launch Token

The deferred launch token is created by `DeferredAutolaunchFactory`.

The full supply first lands with the deferred factory. The factory then creates
`DeferredAutolaunchVestingWallet` and transfers the full supply there.

No auction is created. No LP migration is created. The token exits the vesting
wallet only through the deferred vesting release path.

The same token is also the stake token for the subject splitter created in the
same deferred call.

### 3. Existing Stake Token

An existing-token subject does not mint a new token. The token already exists
before Autolaunch creates the subject.

`PermissionlessExistingTokenRevenueFactory` checks that the stake token is a
contract, creates a `LiveStakeFeePoolSplitter`, registers the subject, and
creates the default ingress account.

Token holders can stake that existing token into `LiveStakeFeePoolSplitter`.
The token exits when they unstake. There is no launch auction, no launch
vesting wallet, and no launch LP migration in this path.

### 4. Base USDC Subject Revenue

Base USDC becomes subject revenue only when it reaches the subject splitter.

There are three normal entry paths:

1. Direct deposit into the splitter with `depositUSDC`.
2. Deposit into a `RevenueIngressAccount`, followed by `sweepUSDC`.
3. Deposit into a `PaymentLinkReceiver`, which forwards to the current splitter.

USDC in an ingress account has not yet gone through the subject split. It counts
only when the ingress account sweeps it into the splitter.

Once USDC reaches the splitter, the splitter applies the 1% Regent staking
share, the 9.9% subject treasury `$REGENT` buyback share, and the 89.1% subject
lane.

Subject stakers exit by claiming USDC from the splitter. The subject treasury
exits by sweeping the treasury-reserved or treasury-residual balances.

### 5. Base USDC In Regent Staking

`RegentRevenueStaking` receives Base USDC from direct deposits and from the 1%
subject protocol share routed through `RegentStakingRevenueRouter`.

Inside `RegentRevenueStaking`, USDC is credited across the fixed `$REGENT`
staking denominator. Staked `$REGENT` earns its proportional USDC share. The
portion corresponding to unstaked denominator space stays with the Regent
treasury.

Stakers exit by claiming USDC. The Regent treasury exits by withdrawing treasury
residual USDC.

### 6. `$REGENT` As Auction Quote Token

The normal Base mainnet launch auction is quoted in `$REGENT`.

Buyers bring `$REGENT` into the external CCA auction. When the auction
graduates, `RegentLBPStrategy` sweeps raised `$REGENT` from the auction.

The strategy uses the configured LP share of raised `$REGENT` for the official
Uniswap v4 LP position. The remaining raised `$REGENT` is swept to the agent
treasury after migration.

This `$REGENT` auction lane is separate from the subject Base USDC revenue
lane.

### 7. `$REGENT` From Subject Revenue Buybacks

When subject Base USDC is recognized, 9.9% of gross USDC is routed to buy
`$REGENT` for the subject treasury.

The splitter transfers that USDC to `RegentStakingRevenueRouter`. The router
transfers it to `UniswapV4RegentBuybackAdapter`. The adapter swaps through its
configured Uniswap v4 route and sends the purchased `$REGENT` directly to the
subject treasury.

The bought `$REGENT` does not sit in the splitter.

### 8. `$REGENT` In Regent Staking

`RegentRevenueStaking` uses `$REGENT` as its stake token.

Stakers bring `$REGENT` into the staking contract. They can later unstake it.
If the contract has funded `$REGENT` reward inventory and emissions are enabled,
stakers can claim `$REGENT` rewards or compound them back into stake.

This rail is separate from the subject token splitter. Subject splitters send
USDC to Regent staking; they do not stake subject tokens there.

### 9. `$REGENT` In The Emission Vault

`RegentEmissionVault` is a funded inventory vault for `$REGENT`.

`$REGENT` enters when someone calls `fundRegent`. A configured router can then
call `emitRegent` to send `$REGENT` to a recipient with a subject and source
reference.

This is separate from the normal subject splitter flow unless a route is
explicitly wired to use it.

### 10. `$REGENT` Launch-Pool Fees

After launch migration, the official Uniswap v4 pool charges the launch-pool
fee through `LaunchPoolFeeHook`.

The hook charges the quote token, which is `$REGENT` in the active Base mainnet
path. The hook sends the fee to `LaunchFeeVault` and records two buckets:

- the agent treasury share
- the Regent recipient share

Each recipient withdraws its own bucket from `LaunchFeeVault`.

These launch-pool fees are not subject Base USDC revenue and do not go through
the subject splitter.

### 11. WETH

WETH appears as an intermediate asset in the current buyback route and in the
spot-price oracle.

`UniswapV4RegentBuybackAdapter` routes USDC to WETH to `$REGENT`. The adapter
does not keep WETH as a long-term balance.

`RegentV4SpotPriceOracle` reads the `$REGENT` / WETH pool and the ETH/USD feed
to estimate a `$REGENT` amount for a USDC amount. It is a quoting and safety
surface, not a custody lane.

### 12. Uniswap v4 LP Position

The LP position is not a fungible token balance in the subject splitter.

During migration, `RegentLBPStrategy` sends launch tokens and `$REGENT` to the
Uniswap v4 position manager. The position manager mints the LP position to the
configured position recipient.

After that, the LP position is controlled by the recipient, not by the subject
splitter.

### 13. Native ETH And Unsupported Tokens

Revenue receivers reject native ETH where they are not meant to receive it.

Wrong tokens and stray native balances are treated as rescue cases, not revenue.
Protected tokens, such as the stake token, USDC, `$REGENT`, or WETH depending on
the contract, cannot be rescued through the unsupported-token escape hatch.

## Creation Paths

### Normal Auction Launch

The normal launch path uses `LaunchDeploymentController`.

In the staged flow:

1. `prepareLaunch` creates the launch token.
2. `prepareLaunch` creates `AgentTokenVestingWallet`.
3. `prepareLaunch` calls `RevenueShareFactory.createSubjectSplitter`.
4. `RevenueShareFactory` deploys `RevenueShareSplitterV2`.
5. `RevenueShareFactory` registers the subject in `SubjectRegistry` as active.
6. `prepareLaunch` calls `RevenueIngressFactory.createIngressAccount` for the
   default USDC receiver.
7. `deployLaunchFeeInfra` deploys `LaunchFeeRegistry`, `LaunchFeeVault`, and
   `LaunchPoolFeeHook`.
8. `finalizeLaunch` calls `RegentLBPStrategyFactory.initializeDistribution`.
9. `RegentLBPStrategyFactory` deploys `RegentLBPStrategy`.
10. `finalizeLaunch` transfers the auction and reserve token supply to the
    strategy.
11. `RegentLBPStrategy.onTokensReceived` creates the external CCA auction.
12. `finalizeLaunch` registers the official pool in `LaunchFeeRegistry`.
13. Ownership handoffs are started for the splitter and launch fee contracts.

The all-at-once `deploy` function follows the same logical order. It creates
the subject splitter and default receiver before the strategy creates the
auction.

### Deferred Autolaunch

The deferred path uses `DeferredAutolaunchFactory`.

One call to `createDeferredAutolaunch`:

1. Creates the token through the trusted token factory.
2. Creates `DeferredAutolaunchVestingWallet`.
3. Transfers the full token supply into that vesting wallet.
4. Computes the subject ID from the chain ID and token address.
5. Calls `RevenueShareFactory.createSubjectSplitter`.
6. Creates `RevenueShareSplitterV2`.
7. Registers the subject in `SubjectRegistry` as active.
8. Creates the default `RevenueIngressAccount`.

No auction is created. No launch-pool fee contracts are created. No strategy is
created.

### Existing-Token Revenue Subject

The existing-token path uses `PermissionlessExistingTokenRevenueFactory`.

One call to `createExistingTokenRevenueSubject`:

1. Checks the existing stake token.
2. Computes a subject ID from chain ID, factory address, stake token, treasury,
   creator, and salt.
3. Deploys `LiveStakeFeePoolSplitter`.
4. Registers a permissionless subject in `SubjectRegistry`.
5. Creates the default `RevenueIngressAccount`.

No token is created. No vesting wallet is created. No auction is created.

### Payment Link

Payment links are created after a subject already exists and is active.

One call to `PaymentLinkFactory.createPaymentLink`:

1. Reads the subject from `SubjectRegistry`.
2. Checks that the subject is active and has a splitter.
3. Checks that the splitter's USDC token and subject ID match the factory input.
4. Deploys a `PaymentLinkReceiver`.
5. Records the receiver by subject and creator.

The payment-link receiver can then forward USDC into the subject's current
splitter.

## Deploy Order And Singleton Status

### External Dependencies

These are expected to exist before Autolaunch uses them:

| Contract or asset | Status | Notes |
| --- | --- | --- |
| Base `$REGENT` token | external singleton | Quote token for active Base mainnet launches. |
| Base USDC | external singleton | Subject revenue token and Regent staking deposit token. |
| WETH | external singleton | Intermediate asset for the current buyback and oracle route. |
| UERC20-compatible token factory | external singleton | Creates launch and deferred tokens. |
| External CCA factory | external singleton | Creates auction contracts. |
| Uniswap v4 pool manager | external singleton | Official pool execution surface. |
| Uniswap v4 position manager | external singleton | Mints the migration LP position. |
| Universal Router and Permit2 | external singletons | Used by the buyback adapter. |
| ETH/USD and sequencer feeds | external singletons | Used by the spot-price oracle. |

### Regent Staking Rail

| Contract | Singleton or factory-created | Deploy order |
| --- | --- | --- |
| `RegentRevenueStaking` | singleton | Deploy before Autolaunch revenue infra, because the staking router constructor points at it. |
| `RegentEmissionVault` | singleton if used | Deploy only for routes that need funded `$REGENT` emissions. |

### Autolaunch Revenue Infrastructure

`DeployAutolaunchInfra.s.sol` deploys the shared Autolaunch revenue
infrastructure in this order:

| Contract | Singleton or factory-created | Deploy order |
| --- | --- | --- |
| `SubjectRegistry` | singleton | Deployed first. |
| `RegentStakingRevenueRouter` | singleton | Deployed after registry and existing `RegentRevenueStaking`. |
| `RevenueShareSplitterV2Deployer` | singleton helper | Deployed before `RevenueShareFactory`. |
| `RevenueShareFactory` | singleton factory | Creates normal `RevenueShareSplitterV2` contracts. |
| `RevenueIngressFactory` | singleton factory | Creates `RevenueIngressAccount` receivers. |
| `PermissionlessExistingTokenRevenueFactory` | singleton factory | Creates existing-token subjects and `LiveStakeFeePoolSplitter` contracts. |
| `DeferredAutolaunchFactory` | singleton factory | Creates deferred tokens, vesting wallets, splitters, and receivers. |
| `RegentLBPStrategyFactory` | singleton factory | Creates per-launch `RegentLBPStrategy` contracts. |

The script also wires permissions:

- `SubjectRegistry` authorizes `RevenueShareFactory`.
- `SubjectRegistry` authorizes `PermissionlessExistingTokenRevenueFactory`.
- `RevenueIngressFactory` authorizes `RevenueShareFactory`.
- `RevenueIngressFactory` authorizes `PermissionlessExistingTokenRevenueFactory`.
- `RevenueIngressFactory` authorizes `DeferredAutolaunchFactory`.
- `RevenueShareFactory` authorizes `DeferredAutolaunchFactory`.

Launch scripts temporarily authorize each `LaunchDeploymentController` that
needs to create one launch, then revoke that authorization.

### Buyback And Oracle Support

These are route-specific support contracts. They are not created by
`DeployAutolaunchInfra.s.sol`.

| Contract | Singleton or factory-created | Deploy order |
| --- | --- | --- |
| `RegentV4SpotPriceOracle` | singleton per quote route | Deploy after the `$REGENT` / WETH pool and oracle feeds are known. |
| `UniswapV4RegentBuybackAdapter` | singleton per swap route | Deploy after router, Permit2, USDC/WETH pool, and WETH/`$REGENT` pool are known. |

Before recognized subject revenue can complete the buyback route, the owner of
`RegentStakingRevenueRouter` must set the buyback adapter with
`setTreasuryBuybackAdapter`.

### Per-Launch Contracts

For each normal launch:

| Contract | Singleton or factory-created | Created by |
| --- | --- | --- |
| `LaunchDeploymentController` | normally one script-created controller per launch run | `ExampleCCADeploymentScript` currently deploys it for the launch. |
| Launch token | per launch | UERC20-compatible token factory, called by the controller. |
| `AgentTokenVestingWallet` | per launch | `LaunchDeploymentController`. |
| `RevenueShareSplitterV2` | per launch subject | `RevenueShareFactory`, called by the controller. |
| `RevenueIngressAccount` | at least one per subject | `RevenueIngressFactory`, called by the controller. |
| `LaunchFeeRegistry` | per launch fee stack | `LaunchFeeInfraDeployer`, called by the controller. |
| `LaunchFeeVault` | per launch fee stack | `LaunchFeeInfraDeployer`, called by the controller. |
| `LaunchPoolFeeHook` | per launch fee stack | `LaunchFeeInfraDeployer`, called by the controller. |
| `RegentLBPStrategy` | per launch | `RegentLBPStrategyFactory`, called by the controller. |
| CCA auction | per launch | External CCA factory, called by `RegentLBPStrategy`. |
| Uniswap v4 LP position | per migrated launch | Uniswap v4 position manager, called by `RegentLBPStrategy`. |

### Per-Deferred-Subject Contracts

For each deferred subject:

| Contract | Singleton or factory-created | Created by |
| --- | --- | --- |
| Deferred token | per deferred subject | Trusted token factory, called by `DeferredAutolaunchFactory`. |
| `DeferredAutolaunchVestingWallet` | per deferred subject | `DeferredAutolaunchFactory`. |
| `RevenueShareSplitterV2` | per deferred subject | `RevenueShareFactory`, called by `DeferredAutolaunchFactory`. |
| `RevenueIngressAccount` | at least one per subject | `RevenueIngressFactory`, called by `DeferredAutolaunchFactory`. |

### Per-Existing-Token Subject Contracts

For each existing-token subject:

| Contract | Singleton or factory-created | Created by |
| --- | --- | --- |
| Existing stake token | external existing token | Not created by Autolaunch. |
| `LiveStakeFeePoolSplitter` | per subject | `PermissionlessExistingTokenRevenueFactory`. |
| `RevenueIngressAccount` | at least one per subject | `RevenueIngressFactory`, called by `PermissionlessExistingTokenRevenueFactory`. |

### Per-Payment-Link Contracts

For each payment link:

| Contract | Singleton or factory-created | Created by |
| --- | --- | --- |
| `PaymentLinkFactory` | singleton if payment links are enabled | Deployed separately for the network. |
| `PaymentLinkReceiver` | per payment link | `PaymentLinkFactory`. |

### Helper Contracts

| Contract | Singleton or factory-created | Created by |
| --- | --- | --- |
| `LaunchFeeInfraDeployer` | reusable helper or script-created helper | `ExampleCCADeploymentScript` creates one when no deployed helper address is supplied. |
| `RevenueShareSplitterDeployer` | older helper | Only relevant to the older `RevenueShareSplitter` path, not the active V2 path. |

## Operational Checks

When reviewing a launch, deferred subject, or existing-token subject, check:

- the subject ID matches the intended token and creation path
- `SubjectRegistry` points to the expected splitter
- the subject is active when receivers are created
- the splitter uses the expected Base USDC token
- the splitter uses the expected `RegentStakingRevenueRouter`
- the default ingress account points to the expected splitter
- the subject treasury is the expected treasury
- splitter ownership handoff has been accepted when required
- `RegentStakingRevenueRouter` points to the expected `RegentRevenueStaking`
- the 1% Regent staking route points to the expected staking contract
- the buyback adapter is configured before subject revenue is recognized
- the launch-pool fee lane is not being treated as subject Base USDC revenue

## Common Misreadings

The stake+split contract is not created when the auction graduates. It is
created during launch setup.

The default USDC receiver is not the same as a payment-link receiver. The
default receiver is a managed ingress account. Payment links are optional
shareable receivers.

USDC sitting in the default ingress account has not yet gone through the subject
split. It becomes recognized subject revenue when swept into the splitter.

The deferred launch path does not create an auction. It creates the token,
vesting wallet, subject, splitter, and default receiver so the subject's revenue
lane can exist before the launch is completed elsewhere.

The existing-token path does not create a token. It creates a revenue lane
around a token that already exists.

Launch-pool `$REGENT` fees are not subject Base USDC revenue. They belong to the
per-launch fee vault path.
