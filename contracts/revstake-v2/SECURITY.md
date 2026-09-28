# Autolaunch Revstake version 2: security posture

Status: unit-proven against the hermetic suite, not deployed, not audited. No Base fork suite has
been run for version 2.

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

## What the tests prove

| Property | Tests |
| --- | --- |
| A graduated auction sells its whole sale allocation to the bidders, up to crumbs: one bidder at the start, in the last eligible block, partly filled at its limit, fuzzed, several bidders covering every way a bid ends, and a launcher minimum three times the floor minimum | `test_SALE_001` … `test_SALE_006` |
| Every SUBJECT left after graduation (crumbs, unpaired reserve, anything sent to the strategy before migration) goes to the escrow and vests to the treasury | `test_SALE_007`, `test_MIG_008_LeftoverSubjectGoesToTheEscrow` |
| The required raise is the floor minimum or the launcher's higher minimum, reachable on the grid | `test_STR_013_RequiredRaiseIsTheFloorMinimumOrTheLauncherMinimum`, `test_FAC_023_*`, `test_MIN_001` … `test_MIN_004` |
| A zero-bid or under-raised auction fails and retires the whole supply; bidders are refunded | `test_FAIL_001` … `test_FAIL_008` |
| The pool opens at raise ÷ sale allocation; the position takes the reserve and about three quarters of the raise (within one part in a million), and the rest of the raise reaches the treasury | `test_MIG_005`, `test_MIG_007`, `test_MIG_008` |
| Every external boundary of launch, migration and graduation rolls back completely | `test_FAC_021_*`, `test_STR_004_*`, `AutolaunchTerminalRollback` |
| Supply is conserved across every lifecycle; graduation sends the launch's own escrow exactly its leftover, the unsold part is never more than crumbs, and the shared contracts keep nothing that is not a stranger's gift | `AutolaunchLifecycleInvariants` (`INV-006`, `INV-010`) |

## Known limits

- **Rounding at the minimum.** The pinned CCA counts a bid placed after the auction's first block up
  to one REGENT base unit short, so the minimum plus one unit is what graduates in any block
  (`test_MIN_002`, `test_MIN_003`).
- **Crumbs.** The auction rounds its clearing price up, so a graduated auction can leave a few
  SUBJECT base units unsold: at most the sale allocation divided by the floor price. At the default
  floor that is about 250,000 base units, far below one whole token; the largest seen in fuzzing is
  about 120,000 in the sale tests and about 207,000 in the invariant campaign. At the lowest floor
  the auction accepts, the same bound is about five whole tokens; that case is derived, not
  measured. Crumbs never reach a bidder or stay in the strategy: they go to the escrow and vest to
  the treasury.
- **Permit2.** The real Permit2 cannot be built under this package's compiler, so hermetic bids use
  a double of its allowance-transfer slice; real Permit2 behaviour is proved only on a Base fork.
