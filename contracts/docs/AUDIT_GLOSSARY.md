# Autolaunch Contracts Glossary

## Agent safe

The subject treasury safe that receives ownership of the deployed launch fee contracts and the subject revenue splitter.

## Auction initializer factory

The external factory that creates the continuous clearing auction used in the launch path.

## Default ingress

The default per-subject account that receives USDC and forwards it into the subject splitter.

## Launch fee hook

The Uniswap v4 hook that charges the launch-pool fee during swaps and routes the fee into the fee vault.

## Launch fee vault

The holding contract that keeps subject and Regent fee balances until the registered recipients withdraw them.

## Position manager

The official Uniswap v4 position manager used by the strategy to mint the canonical LP position during migration.

## Recognized revenue

Revenue that counts for the protocol accounting model. In this workspace, it means Base-family USDC that has actually reached the subject splitter.

## Regent lane

The fee lane or rewards lane reserved for Regent rather than the launched subject.

## Regent revenue staking

The separate staking contract for the existing `$REGENT` token. It accepts Base USDC deposits and is not the same as the per-subject launch splitter.

## Revenue ingress account

The per-subject USDC receiving address that sweeps received funds into the subject splitter.

## Revenue share supply denominator

The fixed denominator used by the reward-accounting model to convert deposited revenue into per-token reward credit.

## Splitter

Short name for `RevenueShareSplitter`, the canonical subject revenue and reward-accounting contract.

## Subject

A launched token and its linked configuration: splitter, treasury safe, active status, and optional identity links.

## Subject manager

A role allowed to manage subject metadata, lifecycle, and identity links in `SubjectRegistry`.

## Treasury residual

The part of recognized USDC revenue that is not currently attributed to stakers and remains withdrawable for the treasury path.

## Undistributed dust

Rounding remainder tracked by the splitter when the intended staker entitlement is larger than the amount materialized through the accumulator math.
