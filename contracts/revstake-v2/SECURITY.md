# Autolaunch Revstake version 2: security posture

Status: deployed on Base on 6 October 2026, not externally audited. Deployment receipts and code
checks are in `deployments/base-mainnet/`. On 28 September 2026 a practice run on a copy of Base,
using an earlier revision, exercised it against the real Permit2, CCA factory, PoolManager and
PositionManager: bids early, mid-auction and late, the exact minimum and the minimum plus one unit,
a launcher minimum, refusals before the claim and migration blocks, graduation, bidder claims,
vesting at half and full term, a failed auction with refunds and retirement of the whole supply,
swaps both ways (exact input and exact output), pool fee collection through the locker, staking,
and the fee rounding floor. Staker claims and unstaking were not part of that run.
That run used the earlier terms (20/15/65, a launcher-chosen floor, the pool at raise ÷ sale
allocation, a 4% hook fee); the 1 October 2026 terms have not yet had a practice run.

## Design rules

- Terminal lifecycles are written before the first external call of each terminal path
  (`_graduate`, `_retire`, the escrow's `resolveFailure`).
- `initializeDistribution` and `migrate` carry Solady's transient reentrancy guard.
- No `tx.origin`, no `delegatecall`, no caller-selected call target. Every external call goes to a
  frozen Base binding or to a contract this graph created.
- Every transfer that matters is measured by balance delta: the raise, the SUBJECT the auction
  sweeps back, what the position used, and the leftover SUBJECT the strategy hands to the escrow.
- Nothing can move LP principal or bidder funds. The position is minted to the locker, which can
  only collect fees into the launch's splitter. Bidder REGENT leaves the auction only through its
  own exit and claim functions.
- The only privileged power is the Governance and REGENT Safe's pause of new launches. No launch
  has an administrator.

## Properties

- A graduated auction sells its whole sale allocation to the bidders, up to crumbs, however its
  bids end: one bidder at the start, in the last eligible block or partly filled at its limit, or
  several bidders.
- Every SUBJECT left after graduation (crumbs, unpaired reserve, anything sent to the strategy
  before migration) goes to the escrow and vests to the treasury.
- Every launch has the one fixed floor, and the required raise is the floor times the sale
  allocation, rounded up.
- A zero-bid or under-raised auction fails and retires the whole supply; bidders are refunded.
- The pool opens at the final clearing price; the position takes half the raise (within one part in
  a million, never more) and at most the reserve, and the rest of the raise reaches the treasury.
- Every external boundary of launch, migration and graduation rolls back completely.
- Supply is conserved across every lifecycle; graduation sends the launch's own escrow exactly its
  leftover (the unpaired reserve plus crumbs), the unsold part is never more than crumbs, and the
  shared contracts keep nothing that is not a stranger's gift.

## Known limits

- **Rounding at the minimum.** The pinned CCA counts a bid placed after the auction's first block up
  to one REGENT base unit short, so the minimum plus one unit is what graduates in any block.
- **Crumbs.** The auction rounds its clearing price up, so a graduated auction can leave a few
  SUBJECT base units unsold: at most the sale allocation divided by the floor price. At the fixed
  floor that bound is about 4.66 whole tokens. Crumbs never reach a bidder or stay in the strategy:
  they go to the escrow and vest to the treasury.
