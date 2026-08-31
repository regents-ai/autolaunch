# Contract Property Ledger

This ledger is the acceptance checklist for the first offline EVM CCTP candidate. There were no
pre-existing tests in the repository and no tests are removed by this ticket.

## Acceptance properties

| Property | Why it remains required | Existing proof | New or replacement proof | Status |
| --- | --- | --- | --- | --- |
| Successful production-realistic route deployment and sweep | RM-EVM-1 through RM-EVM-5 | Gap | `testSuccessfulBoundedSweepUsesExactCctpFieldsAndAllowance` and `testPermissionlessDeploymentAndSweepUseOrdinaryCallers` | Passing |
| Factory rejects zero source asset, bridge, namespace, or chain identity and invalid economic bounds | RM-EVM-2 | Gap | `testFactoryRejectsInvalidBindingsAndEconomics` and `testDirectInboxConstructionRejectsZeroRouteBinding` | Passing |
| Route deployment accepts only the nonzero Base receiver and splitter | RM-EVM-1 and RM-EVM-2 | Gap | `testFactoryRejectsZeroBasePair` plus production ABI inspection | Passing |
| Inbox permanently exposes the exact factory configuration and Base bindings | RM-EVM-1 and RM-EVM-2 | Gap | `testFactoryAndInboxBindingsAreExact` plus forbidden-selector proof | Passing |
| Destination domain is 6, finality is 2000, destination caller is open, recipient and burn token are exact | RM-EVM-1 and pinned Circle V2 ABI | Gap | `testSuccessfulBoundedSweepUsesExactCctpFieldsAndAllowance` and pinned selector `0x8e0250ee` | Passing |
| Permissionless sweep uses `min(balance, cap)` and rejects amounts below minimum | RM-EVM-3 | Gap | Permissionless, below-minimum, exact-minimum, exact-cap, and above-cap tests | Passing |
| Caller fee authorization is bounded by the immutable basis-point ceiling and strictly below amount | RM-EVM-3 and pinned Circle V2 behavior | Gap | Exact ceiling, one-over, zero ceiling, amount, amount-minus-one, and uint256-maximum tests | Passing |
| Successful allowance is exact during the messenger call and zero afterward | RM-EVM-5 | Gap | `testSuccessfulBoundedSweepUsesExactCctpFieldsAndAllowance` | Passing |
| Messenger under-consumption fails atomically | RM-EVM-5 | Gap | `testMessengerUnderConsumptionRevertsAtomically` | Passing |
| Token read, approval, transfer, messenger, and cleanup failures roll back | RM-EVM-3 and RM-EVM-5 | Gap | Token and messenger fault-injection rollback tests | Passing |
| Reentrancy cannot enter a second sweep | RM-EVM-3 and RM-EVM-4 | Gap | Caught and uncaught messenger callback tests through normally deployed contracts | Passing |
| No owner, mutation, rescue, withdrawal, pause, proxy, execute, or delegatecall selector exists | RM-EVM-4 | Gap | Static proof over both production ABIs and runtime opcode proof | Passing |
| CREATE2 address matches the exact factory-relative formula | RM-EVM-6 | Gap | `testCreate2FormulaIsFactoryRelativeAndRepeatDeploymentIsExact` | Passing |
| Repeat deployment returns only an exact-code, exact-binding inbox | RM-EVM-6 | Gap | Repeat call from a distinct actor plus runtime hash and binding assertions | Passing |
| Configuration, factory, and creation-code changes cannot silently alias a route | RM-EVM-6 | Gap | `testConfigurationAndCreationCodeChangesCannotAlias` | Passing |
| Base compatibility requires admitted code identity, initialization, receiver, splitter, Base USDC, zero referral, and provenance | RM-EVM-7 | Gap | Fail-closed fact tests and normally deployed same-code/different-storage receivers | Passing |
| Every offline manifest/facts result is unverified and inactive | RM-EVM-7 and RM-EVM-8 | Gap | `testRouteFactsAreExplicitlyOfflineAndInactive` and no activation mutator | Passing |
| Outputs distinguish issuer-native CCTP, exact source token, domains, finality, permissionless completion, and immutable bindings | RM-EVM-8 | Gap | Route-facts and messenger call-field assertions | Passing |
| Settlement docs do not claim one-to-one recognition | Pinned `PaymentReceiverV1.sweep` behavior and RM-EVM-8 | Pinned source blob `8909504ae1de9bf1b1be84fde6c70751ccf4c0f8` | Manifest and settlement documentation | Passing |
| Deployable runtime and total initcode remain within EIP-170/EIP-3860 with at least 1,000 runtime bytes headroom | Tier 1 plan | Gap | Bundled deployability gate with 256-byte factory and 352-byte inbox constructor arguments | Passing |
| Static analysis has no unresolved high-impact finding | Tier 1 plan | Gap | `slither .` reports zero findings after narrow, documented design suppressions | Passing |

## Removed tests

None. The base repository contains no tests or production source.

## Evidence depth

- [x] One successful production-realistic flow.
- [x] Every applicable authorization boundary.
- [x] Every economic and recipient guard.
- [x] Nonce, replay, cancellation, deadline, and schedule boundaries do not exist in this source
      foundation; CCTP message replay protection is outside the pinned `depositForBurn` caller ABI.
- [x] Exact final balances, allowances, bindings, custody, and factory state.
- [x] Rollback at every materially distinct external-call stage.
- [x] Required repeat behavior for deterministic deployment.
