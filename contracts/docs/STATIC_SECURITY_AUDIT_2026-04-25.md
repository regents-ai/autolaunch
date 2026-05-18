# Autolaunch Contracts Static Security Audit

Date: April 25, 2026

This is a static and symbolic-tool audit of the Autolaunch Solidity workspace. It is not a replacement for an external audit, but it is suitable as a release-gate review before a Base Sepolia or Base mainnet promotion.

## Done Checklist

- Audited project-owned Solidity files under `src/` and `scripts/`.
- Used the test and mock Solidity files under `test/` as supporting evidence.
- Excluded vendored dependencies under `lib/` and generated compiler artifacts under `out/`.
- Ran the full Foundry test suite.
- Ran Slither across the project contracts and deploy scripts.
- Ran Mythril where local tooling allowed it.
- Triaged tool findings against the source code.
- Wrote release-gate findings and follow-up recommendations.

## Scope

Primary scope:

- `src/**/*.sol`
- `scripts/**/*.sol`

Supporting scope:

- `test/**/*.sol`

Excluded from target findings:

- `lib/**/*.sol`, because these are vendored dependencies.
- `out/**/*.sol`, because these are generated build artifacts.

## Tool Results

### Foundry

Command:

```sh
forge fmt --check
forge test
```

Result:

- Formatting passed.
- Full test suite passed: 168 tests passed, 0 failed, 0 skipped.
- The test run included the existing invariant tests for `RegentRevenueStaking`.
- Foundry printed an Etherscan configuration warning, but it did not affect compilation or tests.

### Slither

Commands:

```sh
slither . --filter-paths 'lib|out|test' --json /tmp/autolaunch-contract-audit/slither.json
slither . --foundry-compile-all --filter-paths 'lib|out|test' --json /tmp/autolaunch-contract-audit/slither-compile-all.json
slither . --foundry-compile-all --filter-paths 'lib|out|test' --print human-summary --json /tmp/autolaunch-contract-audit/slither-summary.json
```

Result:

- Slither completed successfully and produced JSON reports.
- Slither reported one repeated high-impact, medium-confidence warning family in `RegentLBPStrategy.migrate()`.
- Slither also reported two informational unused constants in `scripts/ExampleCCADeploymentScript.s.sol`.

### Mythril

Commands:

```sh
uvx --with 'setuptools==70.0.0' --from mythril myth version
uvx --with 'setuptools==70.0.0' --from mythril myth analyze ...
```

Result:

- Mythril installed and ran through `uvx`.
- Source-mode Mythril was blocked because Mythril tried to download a Solidity compiler from `solc-bin.ethereum.org`, and DNS resolution failed in this environment.
- Bytecode-mode Mythril ran against the deployable project contracts.
- Bytecode-mode results were generic Solidity 0.8 arithmetic warnings and one fallback requirement warning, with no credible exploit path after manual review.

Raw Mythril outputs are under:

- `/tmp/autolaunch-contract-audit/mythril-bytecode/*.json`

## Findings

### F-001: Slither flags migration balance reads before external calls

Severity after triage: Low

Tool severity: High

SWC: closest category is SWC-107, reentrancy

Affected code:

- `src/RegentLBPStrategy.sol:206`

Slither reports that `RegentLBPStrategy.migrate()` reads token balances and later makes external calls to the token and Uniswap position manager.

Manual triage:

- `migrate()` is protected by `nonReentrant`.
- Only the configured operator can call it.
- The function sets `migrated = true` and records migration state before the external token transfers and Uniswap calls.
- The function uses the configured token, USDC, and position manager, not an arbitrary caller-provided target.

Assessment:

This is a useful warning, but I did not find a practical reentrancy exploit path in the current code. Treat it as a low-risk regression area, not as a confirmed high-severity bug.

Recommendation:

- Keep the current state-before-external-call ordering.
- Keep `migrate()` under `nonReentrant`.
- Add or keep a focused regression test with a malicious token or malicious position manager before suppressing the Slither warning permanently.

### F-002: Example deploy script has unused constants

Severity: Informational

SWC: none

Affected code:

- `scripts/ExampleCCADeploymentScript.s.sol:48`
- `scripts/ExampleCCADeploymentScript.s.sol:49`

Slither reports that `CANONICAL_CCA_FACTORY` and `REGENT_MULTISIG` are declared but unused.

Assessment:

This is not a contract vulnerability. It can still confuse operators if those constants look authoritative but are not used.

Recommendation:

- Remove the constants if the script should stay illustrative.
- Or wire them into script validation if the script is meant to enforce canonical deployment addresses.

### F-003: Mythril bytecode mode produced generic arithmetic warnings

Severity after triage: Informational

Tool severity: High

SWC: SWC-101

Affected code:

- Multiple deployable contracts in bytecode-only analysis.

Mythril bytecode mode reported arithmetic warnings across constructors, simple views, and normal arithmetic paths.

Manual triage:

- The contracts compile with Solidity 0.8.26, which has checked arithmetic by default.
- The project uses explicit `require` bounds and `FullMath` where precision-sensitive calculations are needed.
- Foundry tests and invariant tests passed.
- The bytecode warnings did not identify a source-level exploit path.

Assessment:

No actionable arithmetic vulnerability was confirmed from Mythril output. The source-mode Mythril limitation means this should not be treated as full symbolic proof.

Recommendation:

- Re-run Mythril source-mode in an environment where the exact Solidity compiler is locally available to Mythril.
- Keep Foundry invariant tests around revenue accounting and staking accounting.

### F-004: Mythril fallback requirement warning

Severity after triage: Informational

Tool severity: Medium

SWC: SWC-123

Affected code:

- Bytecode fallback paths in bytecode-only Mythril output.

Mythril reported a generic fallback requirement violation in bytecode mode.

Manual triage:

- Contracts that should reject native ETH do so explicitly.
- The warning did not identify a path that loses funds or bypasses authorization.

Assessment:

No actionable fallback vulnerability was confirmed.

Recommendation:

- Keep explicit ETH rejection where contracts should not receive native ETH.
- Re-run source-mode Mythril before mainnet if the compiler environment is fixed.

## Security Checks That Passed Manual Review

### Launch fee routing

The launch fee path is now separated from subject USDC accounting:

- `LaunchFeeRegistry` stores an immutable canonical quote token.
- Pool registration rejects non-canonical quote tokens.
- `LaunchPoolFeeHook` only accrues quote-token fees.
- `LaunchFeeVault.recordAccrual()` rejects any accrual currency that does not match the registered quote token.
- Subject revenue splitters no longer pull launch-pool fees into USDC accounting.

Release implication:

- Launch-pool fee balances remain in the quote-token lane and are withdrawn by the configured fee recipients.

### Revenue source separation

Subject revenue now separates:

- direct deposits,
- authorized ingress revenue,
- launch fee revenue,
- total USDC received.

`RegentRevenueStaking` separates total USDC received from direct deposits for the Regent rail.

Release implication:

- Public metrics should use these separated fields. Direct public deposits should not be presented as verified operating revenue.

### Reward funding visibility

Both staking systems expose funded claimable reward views and shortfall views:

- Subject splitter: `previewFundedClaimableStakeToken()` and `stakeTokenRewardShortfall()`.
- Regent staking: `previewFundedClaimableRegent()` and `regentRewardShortfall()`.

Release implication:

- The app and CLI should show accrued rewards separately from rewards that can be claimed now.

### Subject permissions

Subject managers can still handle lower-risk operations such as labels and claimed identity links. High-impact changes now require the registry owner or the current treasury safe:

- splitter changes,
- treasury safe changes,
- active-state changes,
- manager assignment.

Release implication:

- The earlier subject-manager economic-route risk appears addressed in the current contracts.

### Ingress account cap

`RevenueIngressFactory` caps ingress accounts per subject at 64.

Release implication:

- The earlier unbounded ingress-account activation risk appears addressed at the contract layer.

### Claimed identity wording

Identity events use claimed-link wording:

- `ClaimedIdentityLinked`
- `ClaimedIdentityUnlinked`

Release implication:

- Onchain links should continue to be described as claimed links unless the app/SIWA/AgentBook layer has verified the identity proof.

### Ownership transfer flow

Ownership is two-step:

- `transferOwnership()` sets `pendingOwner`.
- `acceptOwnership()` must be called by the pending owner.

Deploy flow currently transfers ownership of launch-owned contracts to the agent safe. The release gate must verify final accepted ownership, not just pending ownership.

Release implication:

- A launch is not final until every launch-owned contract reports `owner == agentSafe` and `pendingOwner == address(0)`.

## Release-Gate Recommendations

Before Base mainnet promotion:

1. Re-run `forge fmt --check`.
2. Re-run `forge test`.
3. Re-run Slither with `--foundry-compile-all`.
4. Re-run Mythril source-mode in an environment where Mythril can use the pinned Solidity compiler without fetching it from the network.
5. Verify canonical USDC across deployment config, revenue factories, fee registry, fee vault, splitter, ingress, and staking.
6. Verify accepted ownership for fee registry, fee vault, hook, splitter, and any other launch-owned contract.
7. Verify public metrics separate total USDC received from verified operating revenue.
8. Verify UI and CLI show funded claimable rewards separately from accrued rewards.

## Bottom Line

I did not find a confirmed critical or high-severity exploitable vulnerability in the project-owned Autolaunch contracts during this pass.

The one Slither high warning is a migration reentrancy-balance warning that appears low risk after source review because of operator-only access, the reentrancy guard, and state updates before external calls.

The main remaining release risk is operational rather than a confirmed Solidity bug: final deployment verification must prove canonical USDC configuration and accepted ownership across the full launch stack.
