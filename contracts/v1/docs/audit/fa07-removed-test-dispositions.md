# FA-07 removed-test dispositions

Inventory authority: the test diff from `4beace7b788da039102651844a7d18a300d97201` through the
production authority `7d564cec735c3b1b928ec4e2ede0b244682d105b`. The earlier endpoint
`f4114f5276386f48bf8dc53ee344189d98c8896e` is superseded; the window from it to `7d564ce` removed
thirteen further selectors. The 36 removed selectors below are accounted for exactly once. A
disposition is `replaced_by` when a named successor carries the property, and `retired` when the
property's subject was deleted from production and its claim retired, never to be reused. These rows
track test accountability only; production ABI and removed-surface claims remain static ABI/source
evidence.

| Removed test | Disposition | Property evidence |
| --- | --- | --- |
| `invariant_INV_004_HookNeverRetainsAttributableRegent` | `replaced_by` | `invariant_INV_004_FA07_I4_HookNeverRetainsAttributableFeeAssets` covers both REGENT and SUBJECT, both routers, gifts, allowances, and supply conservation. |
| `test_HOK_001_BindingToStrategyAndPoolManagerIsImmutable` | `replaced_by` | `test_HOK_003_FA07_I3_ImmutableBindingsAndExactRegistrationAuthority` asserts both immutable bindings. |
| `test_HOK_001_FactoryConstructionBindsHookToStrategyAndPoolManager` | `replaced_by` | `test_HOK_003_FA07_I3_FactoryBindsHookToStrategyAndPoolManager` exercises the production factory construction graph. |
| `test_HOK_002_OnlyTheStrategyRegistersAnExactPoolKey` | `replaced_by` | `test_HOK_003_FA07_I3_ImmutableBindingsAndExactRegistrationAuthority` proves the strategy-only exact-key boundary. |
| `test_HOK_003_PoolKeyRegistrationIsOnceAndFinal` | `replaced_by` | `test_HOK_003_FA07_I3_ImmutableBindingsAndExactRegistrationAuthority` proves write-once registration. |
| `test_HOK_004_HookPermissionsAreExactlyThoseRequired` | `replaced_by` | `test_HOK_003_FA07_I3_PermissionsAndInheritedBeforeSwapBoundaryAreExact` checks all permission flags. |
| `test_HOK_004_MinedHookAddressCarriesExactlyTheDeclaredPermissionBits` | `replaced_by` | `test_HOK_003_FA07_I3_FactoryHookAddressCarriesExactPermissionBits` proves the production-mined address, while `test_HOK_003_FA07_I3_PermissionsAndInheritedBeforeSwapBoundaryAreExact` independently mines and deploys the hook. |
| `test_HOK_005_ExactInputChargesRegentWhenSpecified` | `replaced_by` | `test_HOK_001_FA07_I1_AllTradeFormsAndOrderingsUseRealizedUnspecifiedCurrency` covers the corresponding exact-input shape under realized-unspecified charging. |
| `test_HOK_006_ExactOutputChargesRegentWhenSpecified` | `replaced_by` | `test_HOK_001_FA07_I1_AllTradeFormsAndOrderingsUseRealizedUnspecifiedCurrency` covers the corresponding exact-output shape under realized-unspecified charging. |
| `test_HOK_007_ExactOutputChargesRegentWhenUnspecified` | `replaced_by` | `test_HOK_001_FA07_I1_AllTradeFormsAndOrderingsUseRealizedUnspecifiedCurrency` and `test_HOK_001_FA07_I1_PriceLimitedPartialAndZeroFillsRemainValid` cover full, partial, and zero exact-output execution. |
| `test_HOK_008_ExactInputChargesRegentWhenUnspecified` | `replaced_by` | `test_HOK_001_FA07_I1_AllTradeFormsAndOrderingsUseRealizedUnspecifiedCurrency` covers both exact-input currency orderings. |
| `test_HOK_009_TwoOnePercentLanesAreFlooredIndependently` | `replaced_by` | `test_HOK_002_FA07_I2_RoundingBoundariesAreMeasuredFromExecution` proves independent lane flooring across the live execution boundaries. |
| `test_HOK_010_OneLaneGoesDirectlyToTheRegentSafe` | `replaced_by` | `test_HOK_002_FA07_I2_BothAssetsRouteInKindWithExactCleanLanes` proves the exact Safe lane for both fee assets. |
| `test_HOK_011_OtherLaneGoesToTheSplitterAndIsSkimmed` | `replaced_by` | `test_HOK_002_FA07_I2_BothAssetsRouteInKindWithExactCleanLanes` proves splitter receipt, skim, and final treasury routing for both assets. |
| `test_HOK_012_TinySwapsChargeNothingWithoutLoss` | `replaced_by` | `test_HOK_002_FA07_I2_RoundingBoundariesAreMeasuredFromExecution` proves sub-threshold zero-lane execution without settlement. |
| `test_HOK_013_SettlementCompletesInsideTheSwapTransaction` | `replaced_by` | `test_HOK_002_FA07_I2_BothAssetsRouteInKindWithExactCleanLanes` proves synchronous routing and cleanup before return. |
| `test_HOK_014_NoAttributableInventoryRemainsAfterASwap` | `replaced_by` | `invariant_INV_004_FA07_I4_HookNeverRetainsAttributableFeeAssets` and `test_HOK_002_FA07_I2_BothAssetsRouteInKindWithExactCleanLanes` prove zero attributable balances and allowances. |
| `test_HOK_015_NoFlushThresholdKeeperPauseOrFeeSetterExists` | `replaced_by` | `test_HOK_006_FA07_I6_ObsoletePreSwapControlPlaneIsAbsent` provides the static surface assertion. |
| `test_HOK_016_SettlementFailureRevertsTheSwap` | `replaced_by` | `test_HOK_004_FA07_I4_SplitterFailuresRollbackBothFeeAssets` proves revert, under-pull, and refund rollback for both fee assets. |
| `test_HOK_017_PoolManagerAndRegisteredKeyAreTheOnlyAuthority` | `replaced_by` | `test_HOK_003_FA07_I3_ImmutableBindingsAndExactRegistrationAuthority` and `test_HOK_003_FA07_I3_PermissionsAndInheritedBeforeSwapBoundaryAreExact` prove both sides of the callback boundary. |
| `test_HOK_018_ArbitraryRoutersAndReentrancyCannotChangeLaneAccounting` | `replaced_by` | `test_HOK_004_FA07_I4_ForeignAndReentrantCallbacksGainNoAuthority` plus `test_HOK_005_FA07_I5_EventUsesRouterContextWithoutAuthority` cover reentrancy and arbitrary-router context. |
| `test_HOK_019_LaneRoundingIsExactAtTheFeeBoundaryInputs` | `replaced_by` | `test_HOK_002_FA07_I2_RoundingBoundariesAreMeasuredFromExecution` proves the zero-, one-, and two-unit lane boundaries from actual swaps. |
| `test_MIG_013_TwelveStepsExecuteInTheSpecifiedOrder` | `replaced_by` | `test_MIG_013_FourteenStepsExecuteInTheSpecifiedOrder` in `test/integration/AutolaunchGraduation.t.sol`, the selector `MIG-013` in `requirements/ledger.toml` names, carries every ordering assertion the removed test made and adds the factory receiver-provenance registration. |
| `test_FAC_005_InitialLaunchFeeIsOneMillionRegentToTheSafe` | `retired` | The launch fee is deleted (`claim-corrections.md` section 10); `FAC-005` is retired with it. `test_FAC_027_LaunchMovesNoRegentAndLeavesNoAllowance` proves launching pulls no REGENT. |
| `test_FAC_006_OnlyGovernanceChangesTheLaunchFee` | `retired` | `setLaunchFee` no longer exists; `FAC-006` is retired. `test_ABI_002_FactoryPublicMutationSurfaceIsExact` proves the factory's mutation surface carries no fee setter. |
| `test_FAC_008_AllowanceMustEqualTheExpectedPositiveFee` | `retired` | No allowance is required or read; `FAC-008` is retired. `test_FAC_027_LaunchMovesNoRegentAndLeavesNoAllowance` proves a launch with no allowance succeeds and leaves none. |
| `test_FAC_009_ZeroFeeRequiresZeroAllowance` | `retired` | The fee and its allowance rule are deleted; `FAC-009` is retired. Covered by the same `FAC-027` selector. |
| `test_FAC_010_StaleExpectedFeeRevertsTheWholeLaunch` | `retired` | `LaunchParams.expectedLaunchFee` and `StaleLaunchFee` are deleted; `FAC-010` is retired. `test_ABI_003_LaunchParamsFieldsAreExact` proves the seven-field struct. |
| `test_FAC_011_AuctionStartIsAlwaysBlockNumberPlus1800` | `replaced_by` | `test_FAC_011_AuctionStartIsAlwaysBlockNumberPlus300` proves the ten-minute start and asserts the constant. |
| `test_FAC_018_FailedAuctionDoesNotRefundTheLaunchFee` | `retired` | There is no fee to refund; `FAC-018` is retired. `test_FAIL_006_BidderRefundsSurviveRetirement` and `test_FAIL_008_RepeatedFailureResolutionMovesNoValue` cover the failure-path value movement that remains. |
| `test_FAC_023_RequiredRaiseIsNonzeroAndReachable` | `replaced_by` | `test_FAC_023_RequiredRaiseIsAnyPositiveReachableAmount` proves zero is refused, one wei and the exact maximum are admitted, and keeps the floor raise's measured economics. |
| `test_FAC_025_FeeUpdateEmitsTheExactPreviousAndNewFee` | `retired` | `LaunchFeeUpdated` is deleted; `FAC-025` is retired. `test_ABI_007_EventTopicsIndexingAndWidthsAreFrozen` proves the frozen event set carries no fee event. |
| `test_FAC_026_SuccessfulFeeCollectionEmitsTheExactCollectionEvent` | `retired` | `LaunchFeeCollected` is deleted; `FAC-026` is retired. Covered by the same `ABI-007` selector. |
| `test_FAC_027_PositiveFeeLaunchLeavesNoResidualAllowance` | `replaced_by` | `test_FAC_027_LaunchMovesNoRegentAndLeavesNoAllowance` proves the launcher keeps its exact balance and no allowance survives the launch. |
| `test_MIG_006_MintsOneFullRangePositionToTheDeadAddress` | `replaced_by` | `test_MIG_006_MintsOneFullRangePositionToThePermanentLocker` proves the position is minted to the strategy's fee-only LP locker and the fixed splitter is registered there. |
| `test_STR_013_StartIsAlwaysCurrentBlockPlus1800` | `replaced_by` | `test_STR_013_StartIsAlwaysCurrentBlockPlus300` proves the strategy's ten-minute start. |
