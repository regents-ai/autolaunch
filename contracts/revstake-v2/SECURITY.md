# Autolaunch Revstake version 2: security posture

Status: unit-proven against the hermetic suite, not deployed, not audited. No Base fork suite has
been run for version 2.

## Design rules

- Terminal lifecycles are written before the first external call of each terminal path
  (`_graduate`, `_retire`, the escrow's `resolveFailure`), and a share is marked paid before the
  SUBJECT moves.
- `initializeDistribution`, `migrate` and `claimUnsoldShare` carry Solady's transient reentrancy
  guard.
- No `tx.origin`, no `delegatecall`, no caller-selected call target. Every external call goes to a
  frozen Base binding or to a contract this graph created.
- Every transfer that matters is measured by balance delta: the raise, the SUBJECT the auction
  sweeps back, what the position used, and what the strategy holds for the share-out.
- Nothing can move LP principal or bidder funds. The position is minted to the locker, which can
  only collect fees into the launch's splitter. Bidder REGENT leaves the auction only through its
  own exit and claim functions.
- The only privileged power is the Governance and REGENT Safe's pause of new launches. No launch
  has an administrator.

## What the tests prove

| Property | Tests |
| --- | --- |
| Bidders receive the whole sale allocation, up to crumbs: one bidder at the start, in the last eligible block, partly filled at its limit, fuzzed, and several bidders covering every way a bid ends | `test_SHR_001` … `test_SHR_005` |
| A share is paid once, to the bid's owner, whoever calls; wrong checkpoint hints are refused | `test_SHR_005`, `test_SHR_006` |
| SUBJECT sent to the strategy before migration joins the share-out and cannot inflate a share | `test_SHR_007`, `test_STR_015_GiftedSubjectJoinsTheShareOut` |
| No share before graduation, after failure, for an unknown auction or an unknown bid | `test_SHR_008`, `test_SHR_009` |
| The required raise is the floor minimum or the launcher's higher minimum, reachable on the grid | `test_STR_013_RequiredRaiseIsTheFloorMinimumOrTheLauncherMinimum`, `test_FAC_023_*`, `test_MIN_001` … `test_MIN_004` |
| A zero-bid or under-raised auction fails and retires the whole supply; bidders are refunded | `test_FAIL_001` … `test_FAIL_008` |
| The pool opens at raise ÷ sale allocation; the position takes the reserve and about three quarters of the raise (within one part in a million), and the rest of the raise reaches the treasury | `test_MIG_005`, `test_MIG_007`, `test_MIG_008` |
| Every external boundary of launch, migration and graduation rolls back completely | `test_FAC_021_*`, `test_STR_004_*`, `AutolaunchTerminalRollback` |
| Supply is conserved across every lifecycle; the share-out is never overpaid | `AutolaunchLifecycleInvariants` (`INV-006`, `INV-010`) |

## Known limits

- **Rounding at the minimum.** The pinned CCA counts a bid placed after the auction's first block up
  to one REGENT base unit short, so the minimum plus one unit is what graduates in any block
  (`test_MIN_002`, `test_MIN_003`).
- **Crumbs.** The share-out and the full-range position each round down; the strategy may keep a few
  hundred thousand SUBJECT base units per launch, far below one whole token.
- **Permit2.** The real Permit2 cannot be built under this package's compiler, so hermetic bids use
  a double of its allowance-transfer slice; real Permit2 behaviour is proved only on a Base fork.
