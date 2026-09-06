# FA-07 removed-test dispositions

Inventory authority: the test diff from `4beace7b788da039102651844a7d18a300d97201` through the
production authority `f4114f5276386f48bf8dc53ee344189d98c8896e`. The earlier endpoint
`3634f6f0e11523c426662b7524f2c94fd37d3597` is superseded; the window from it to `f4114f5` removed
one further selector. The 23 removed selectors below are accounted for exactly once. These rows
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
