# Autolaunch Product Invariants

This is the single canonical product story for Autolaunch.

If another document, script note, page, or CLI help text disagrees with this file, this file wins and the other surface should be updated.

## Core model

Autolaunch has one launch stack and one revenue-recognition stack.

- The launch stack creates the token, auction, fee plumbing, subject wiring, and official Uniswap v4 migration path.
- The revenue stack starts only when Base USDC reaches the subject revenue splitter.
- Ingress is a routing wrapper for receiving and sweeping USDC. It is not a second accounting system.

## Hard product rules

1. Subject revenue is Base USDC only.
2. Subject revenue counts only when that Base USDC reaches the subject revenue splitter.
   - USDC waiting in an ingress account has not counted yet.
   - USDC swept after a share change goes live uses the new live share.
   - Direct manual deposits are tracked separately from verified ingress and launch-fee revenue.
3. The launch token allocation story is fixed:
   - 10% public sale
   - 5% LP reserve
   - 85% treasury vesting
4. The operator path is CLI-first:
   - save plan
   - validate
   - publish
   - run
   - monitor
   - finalize
   - release vesting later
5. The participant path is browser-first:
   - browse auctions
   - bid
   - return failed bids
   - claim purchased tokens
   - stake
   - unstake
   - claim rewards
6. The launch-side fee lane and the subject revenue splitter are different things:
   - the launch-side fee hook captures pool fees
   - the Regent-side fee lane is a plain treasury payout
   - subject rewards only come from Base USDC that reaches the splitter
   - the subject protocol skim is sent as USDC into the shared `$REGENT` staking rail
7. Rescue is not revenue accounting:
   - wrong tokens or stray ETH can be recovered by the contract owner or treasury controller
   - rescued assets do not count as subject revenue
   - subject revenue starts only when deliberate Base USDC reaches the subject splitter
8. The separate `$REGENT` staking rail uses a fixed revenue-share supply denominator:
   - there is no configurable staker-share percentage for deposited USDC
   - each staked `$REGENT` earns against that fixed denominator
   - unstaked denominator space leaves the matching USDC with the Regent treasury
   - live stake cannot exceed the denominator
9. Techtree evidence can support launch readiness, but it does not decide launch eligibility by itself in V1:
   - prelaunch plans may include a Techtree evidence packet reference
   - readiness may display that evidence as supporting context
   - launch gating stays with Autolaunch-owned plan and launch rules

## Migration rule

The launch story is not complete until the strategy has migrated its LP slice through the official Uniswap v4 position manager and recorded the resulting pool id and position id onchain.

Post-auction sweeps are downstream cleanup actions. They are not a substitute for migration.

## Ownership rule

Ownership handoffs should be two-step unless a contract must own another contract immediately as part of deployment wiring.

When a two-step handoff is pending, operational docs and checks should treat the transfer as incomplete until the new owner has accepted it.

Launch readiness must not treat another Regent product's database tables as its source of truth. Autolaunch owns saved launch plans and Autolaunch launch records; cross-product agent policy signals should come from a shared read contract before they are used to approve a launch.
