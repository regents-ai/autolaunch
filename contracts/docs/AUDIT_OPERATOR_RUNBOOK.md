# Autolaunch Contracts Audit Operator Runbook

This runbook is for the person preparing the contracts workspace for outside review or walking an auditor through the highest-risk operating paths.

## Freeze And Verify

Use this branch for the handoff snapshot:

- `codex/audit-freeze-2026-04-22`

Run these commands from `/Users/sean/Documents/regent/autolaunch/contracts`:

```bash
forge test
forge coverage --report summary --ir-minimum
slither . --exclude-dependencies
```

Expected result today:

- `forge test` passes with 131 tests
- `forge coverage --report summary --ir-minimum` passes and is the reproducible coverage baseline
- `slither . --exclude-dependencies` completes and leaves only the `RegentLBPStrategy.migrate` warning family visible

## What Changed In This Prep Pass

- treasury and protocol USDC sweeps in `RevenueShareSplitter` can no longer be triggered by arbitrary callers
- launch fee capture can now be disabled or re-enabled per pool through `LaunchFeeRegistry`
- the Slither baseline now suppresses generic noise so the migration path stays visible
- the coverage baseline now works through the IR-based Foundry coverage path

## Operator Checks Before Review

1. Confirm the branch is clean except for the handoff docs you intend to commit.
2. Re-run the three verification commands above.
3. Record the branch head in the prep package once the handoff commit exists.
4. Give reviewers the four core docs:
   `AUDIT_PREP_PACKAGE.md`, `AUDIT_ACTORS_AND_PRIVILEGES.md`, `AUDIT_ASSUMPTIONS_AND_TRUST_BOUNDARIES.md`, and this runbook.

## High-Risk Paths To Walk Reviewers Through

### Launch deployment

- `LaunchDeploymentController.deploy` still creates and wires the launch stack in one call.
- Reviewers should confirm the deployment inputs before the call, then confirm ownership handoff to the agent safe after the call.

### Auction to pool migration

- `RegentLBPStrategy.migrate` is the only remaining live Slither warning family.
- Walk reviewers through the sequence in plain order:
  auction funds arrive, LP amounts are capped, the official pool is initialized, the LP position is minted, then leftovers are swept.
- Reviewers should inspect the failure case too:
  if pool setup fails, migration must not leave funds stranded and the recovery path must remain usable.

### Treasury and protocol sweeps

- `RevenueShareSplitter.sweepTreasuryResidualUSDC` can now be triggered only by the splitter owner or the treasury recipient.
- `RevenueShareSplitter.sweepProtocolReserveUSDC` can now be triggered only by the splitter owner or the protocol recipient.
- These calls no longer accept an arbitrary destination, so reviewers only need to verify the stored recipient addresses.

### Fee capture emergency stop

- `LaunchFeeRegistry.setHookEnabled(poolId, false)` is now the stop switch for fee capture.
- The owner of the registry, expected to be the agent safe after deployment, can disable and later re-enable fee capture for a registered pool.
- Reviewers should verify both the ownership handoff and the intended operational owner before relying on this path.

## Practical Talking Points For Auditors

- The default Foundry coverage command still fails in non-IR mode; the supported audit baseline is the IR-based coverage command listed above.
- The Slither baseline intentionally leaves the migration warning family visible instead of suppressing it.
- `RegentRevenueStaking` remains outside the per-launch path and should be reviewed as a separate reward rail.
