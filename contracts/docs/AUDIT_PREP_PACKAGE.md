# Autolaunch Contracts Audit Prep Package

Prepared on: 2026-04-22
Workspace: `/Users/sean/Documents/regent/autolaunch/contracts`
Freeze branch: `codex/audit-freeze-2026-04-22`
Freeze commit: record the branch head after the audit-prep commit is created

## Status

This workspace is materially ready for external review.

Completed:

- source scope reviewed
- build verified
- full Foundry test suite verified
- stable Foundry coverage baseline verified
- stable Slither baseline verified
- actor and privilege map documented
- workflow and trust assumptions documented
- glossary documented
- operator runbook documented

Known hot path still worth focused review:

- `RegentLBPStrategy.migrate` is now the only remaining live Slither warning family after baseline cleanup

## Assumed Review Goals

Because no project-specific goals were provided with this run, this package assumes the audit should focus on the following:

1. Launch deployment correctness
2. Auction-to-pool migration correctness
3. Fee capture and custody correctness
4. Revenue recognition and reward-accounting correctness
5. Privileged action safety
6. Subject lifecycle and identity-link integrity

Worst-case outcomes under this model:

- subject or Regent funds are over-credited, under-credited, or locked
- launch migration produces unusable pool state or leaves assets stranded
- treasury or protocol withdrawals can be redirected incorrectly
- subject ownership or lifecycle controls are exercised by the wrong party

## Verification Run

### Build

Command:

```bash
forge build
```

Result:

- succeeded

### Tests

Command:

```bash
forge test
```

Result:

- succeeded
- 131 tests passed
- 0 failed
- 0 skipped

The following high-risk suites were also checked directly:

- `test/LaunchDeploymentController.t.sol`
- `test/RegentLBPStrategy.t.sol`
- `test/LaunchPoolFeeHook.t.sol`
- `test/LaunchRevenueFlow.t.sol`
- `test/RevenueShareSplitter.t.sol`
- `test/RegentRevenueStaking.t.sol`

### Coverage

First attempt:

```bash
forge coverage --report summary
```

Result:

- failed
- Foundry disables IR for the default report mode and still hits a generic stack-depth compiler failure during instrumented compilation

Second attempt:

```bash
forge coverage --report summary --ir-minimum
```

Result:

- succeeded
- 131 tests passed under coverage
- this is now the reproducible audit coverage command for the workspace

Conclusion:

- the codebase now has a reproducible coverage baseline through `--ir-minimum`
- the default non-IR coverage command still fails and should be treated as a tooling limitation, not the canonical audit command

### Static Analysis

Attempt:

```bash
slither . --exclude-dependencies
```

Result:

- succeeded
- local baseline exclusions now remove generic noise from timestamp, pragma, low-level-call, and event-order reports
- the remaining report is concentrated on `RegentLBPStrategy.migrate`

Conclusion:

- Slither now produces a stable report for this workspace
- the remaining live warning family is the auction-to-pool migration path that should stay on the manual review list

## In-Scope Files

Primary review surface:

- `src/LaunchDeploymentController.sol`
- `src/RegentLBPStrategy.sol`
- `src/RegentLBPStrategyFactory.sol`
- `src/LaunchFeeRegistry.sol`
- `src/LaunchFeeVault.sol`
- `src/LaunchPoolFeeHook.sol`
- `src/AgentTokenVestingWallet.sol`
- `src/revenue/SubjectRegistry.sol`
- `src/revenue/RevenueShareFactory.sol`
- `src/revenue/RevenueIngressFactory.sol`
- `src/revenue/RevenueIngressAccount.sol`
- `src/revenue/RevenueShareSplitter.sol`
- `src/revenue/RegentRevenueStaking.sol`

Support code in scope when it affects behavior:

- `src/auth/Owned.sol`
- `src/libraries/SafeTransferLib.sol`
- `src/libraries/HookMiner.sol`
- `src/cca/**/*`
- `src/interfaces/**/*`
- `src/revenue/interfaces/**/*`

Normally out of scope for primary manual review:

- `lib/**/*`
- `test/**/*`
- `scripts/**/*`

These remain useful as evidence for behavior and setup.

## Preparation Gaps To Close Before Or During External Review

1. Decide whether the team wants to pursue a default non-IR coverage report, or accept `--ir-minimum` as the canonical audit baseline.
2. Perform a manual line-by-line review of `RegentLBPStrategy.migrate` against the runbook and migration assumptions.
3. Record the final freeze commit on this branch when the handoff commit is created.

## Audit Hand-Off Documents

This package adds the following audit-facing documents:

- `contracts/docs/AUDIT_PREP_PACKAGE.md`
- `contracts/docs/AUDIT_ACTORS_AND_PRIVILEGES.md`
- `contracts/docs/AUDIT_ASSUMPTIONS_AND_TRUST_BOUNDARIES.md`
- `contracts/docs/AUDIT_GLOSSARY.md`
- `contracts/docs/AUDIT_OPERATOR_RUNBOOK.md`
- `contracts/slither.config.json`

Related existing project documents:

- `contracts/CONTRACTS.md`
- `contracts/docs/ARCHITECTURE_GUIDE.md`
- `contracts/docs/FOUNDRY_TESTING_GUIDE.md`
- `contracts/DIMENSIONAL_UNITS.md`
- `contracts/DIMENSIONAL_SCOPE.json`

## Suggested Next Step

The next pass should focus on reviewer efficiency rather than broad prep work:

1. review `RegentLBPStrategy.migrate` with the runbook in hand
2. decide whether to keep or further reduce the remaining Slither warning family
3. hand auditors this frozen branch and its verification commands
