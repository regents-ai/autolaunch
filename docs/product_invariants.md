# Autolaunch Product Invariants

This is the single canonical product story for Autolaunch.

If another document, script note, page, or CLI help text disagrees with this file, this file wins and the other surface should be updated.

## Core model

Autolaunch has one launch stack and one revenue-recognition stack.

- The launch stack creates the token, auction, fee plumbing, subject wiring, and official Uniswap v4 migration path.
- The revenue stack starts only when Base-family USDC reaches the subject revenue splitter.
- Ingress is a routing wrapper for receiving and sweeping USDC. It is not a second accounting system.

## Hard product rules

1. Recognized subject revenue is Base-family USDC only.
2. Subject revenue counts only when that Base-family USDC reaches the subject revenue splitter.
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
   - subject rewards only come from Base-family USDC that reaches the splitter
7. Rescue is not revenue accounting:
   - wrong tokens or stray ETH can be recovered by the contract owner or treasury controller
   - rescued assets do not count as recognized subject revenue
   - recognized subject revenue still starts only when deliberate Base-family USDC reaches the subject splitter

## Migration rule

The launch story is not complete until the strategy has migrated its LP slice through the official Uniswap v4 position manager and recorded the resulting pool id and position id onchain.

Post-auction sweeps are downstream cleanup actions. They are not a substitute for migration.

## Ownership rule

Ownership handoffs should be two-step unless a contract must own another contract immediately as part of deployment wiring.

When a two-step handoff is pending, operational docs and checks should treat the transfer as incomplete until the new owner has accepted it.
