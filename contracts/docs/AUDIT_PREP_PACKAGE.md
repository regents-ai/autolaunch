# Autolaunch Contracts Audit Prep Package

Prepared on: 2026-04-21
Workspace: `/Users/sean/Documents/regent/autolaunch/contracts`
Commit: `2a804d6600b783eb552022df1e0ca1773b03001f`
Branch: `main`

## Status

This workspace is materially ready for review, but not fully audit-ready yet.

Completed:

- source scope reviewed
- build verified
- full Foundry test suite verified
- actor and privilege map documented
- workflow and trust assumptions documented
- glossary documented

Still open:

- Slither does not currently produce a usable report in this workspace
- Foundry coverage does not currently produce a usable coverage summary in this workspace

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
- 126 tests passed
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
- Foundry disables the current compile mode for coverage and then hits a stack-depth compiler failure in `src/revenue/RevenueIngressFactory.sol`

Second attempt:

```bash
forge coverage --report summary --ir-minimum
```

Result:

- failed
- the build moved past the first compiler error but then failed with a Yul exception while compiling `RegentLBPStrategy`

Conclusion:

- the codebase has tests, but it does not currently have a reproducible coverage report

### Static Analysis

Attempt:

```bash
slither . --exclude-dependencies
```

Result:

- failed before analysis output
- `crytic-compile` raised `KeyError: 'output'` while parsing the Foundry project

Retry:

```bash
slither . --compile-force-framework foundry --foundry-compile-all --exclude-dependencies
```

Result:

- did not complete within the observed run after the build step

Conclusion:

- a fresh Slither report is currently blocked by tool integration, not by missing source files

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

## Preparation Gaps To Close Before External Review

1. Make Slither produce a stable report for this Foundry workspace.
2. Make Foundry produce a stable coverage report for this workspace.
3. Freeze a dedicated audit branch once the above is resolved.

## Audit Hand-Off Documents

This package adds the following audit-facing documents:

- `contracts/docs/AUDIT_PREP_PACKAGE.md`
- `contracts/docs/AUDIT_ACTORS_AND_PRIVILEGES.md`
- `contracts/docs/AUDIT_ASSUMPTIONS_AND_TRUST_BOUNDARIES.md`
- `contracts/docs/AUDIT_GLOSSARY.md`

Related existing project documents:

- `contracts/CONTRACTS.md`
- `contracts/docs/ARCHITECTURE_GUIDE.md`
- `contracts/docs/FOUNDRY_TESTING_GUIDE.md`
- `contracts/DIMENSIONAL_UNITS.md`
- `contracts/DIMENSIONAL_SCOPE.json`

## Suggested Next Step

If the goal is to be genuinely audit-ready rather than just audit-oriented, the next pass should focus on code changes:

1. make coverage reproducible
2. make Slither reproducible
3. cut an audit branch and rerun this package on that frozen commit
