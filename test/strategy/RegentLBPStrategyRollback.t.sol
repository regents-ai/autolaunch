// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
import {ContinuousClearingAuction} from "continuous-clearing-auction/ContinuousClearingAuction.sol";
import {StrategyFixture} from "./StrategyFixture.sol";
import {StagedERC20} from "./doubles/StagedERC20.sol";

/// @notice `C3-I4` and `C3-I6`: a technical problem anywhere in initialization or migration is an
///         ordinary EVM revert that restores the exact pre-call state, no dependency can re-enter a
///         second mutation, no retry, recovery, progress or alternate surface exists, and checkpoint
///         exhaustion is resolved by permissionless upstream work rather than by strategy state.
contract RegentLBPStrategyRollbackTest is StrategyFixture {
    function setUp() public {
        _deployC3();
    }

    /// @notice A failed migration commits nothing at all, and a later migration starts from exactly
    ///         the same state the failed one started from.
    function test_STR_004_TechnicalFailureIsAnOrdinaryRevertWithNoRetryState() public {
        Launch memory launch = _defaultLaunch();
        _bidToGraduation(launch, 2_000e18);

        Ledger memory before = _ledger(launch);

        // The auction's REGENT sweep is the first REGENT movement migration makes.
        regent.resetMovements();
        regent.arm(1, StagedERC20.Fault.Revert);
        vm.expectRevert();
        strategy.migrate(address(launch.auction));

        _assertLedgerUnchanged(before, _ledger(launch), "failed migration");

        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launch.auction));
        assertEq(uint8(d.lifecycle), uint8(RegentLBPStrategy.Lifecycle.Active), "still active, not a failure state");
        assertEq(d.splitter, address(0), "no partial artifact");
        assertEq(d.lpTokenId, 0, "no partial artifact");
        assertEq(d.finalSqrtPriceX96, 0, "no partial artifact");

        regent.arm(0, StagedERC20.Fault.None);
        strategy.migrate(address(launch.auction));
        assertEq(
            uint8(strategy.distribution(address(launch.auction)).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Graduated),
            "the fresh call graduated with no memory of the failed one"
        );
    }

    /// @notice Rollback is complete after every materially distinct external stage of graduation.
    /// @dev The stages are enumerated from the run itself: one clean migration is measured to learn
    ///      how many REGENT and SUBJECT movements graduation makes, and then each of those movements
    ///      is failed in turn from the identical pre-migration state.
    function test_STR_004_RollbackIsCompleteAfterEveryExternalStage() public {
        // A raise big enough that both residues are non-zero, so the treasury payout stage is real.
        Launch memory launch = _defaultLaunch();
        _bidToGraduationAt(launch, 20_000_000e18, 500);

        uint256 root = vm.snapshotState();
        regent.resetMovements();
        launch.subject.resetMovements();
        strategy.migrate(address(launch.auction));
        uint256 regentStages = regent.movements();
        uint256 subjectStages = launch.subject.movements();
        require(vm.revertToState(root), "revert to root failed");

        // Every REGENT stage: the auction sweep, the PositionManager funding transfer, the
        // PositionManager settlement, and the treasury payout. Every SUBJECT stage: the
        // PositionManager funding transfer, the PositionManager settlement, the escrow payout, and
        // the escrow's own sweep of the graduated auction.
        assertEq(regentStages, 4, "the REGENT stages graduation moves through");
        assertEq(subjectStages, 4, "the SUBJECT stages graduation moves through");

        for (uint256 stage = 1; stage <= regentStages; ++stage) {
            _assertStageRollsBack(launch, regent, stage, "REGENT stage ");
        }
        for (uint256 stage = 1; stage <= subjectStages; ++stage) {
            _assertStageRollsBack(launch, launch.subject, stage, "SUBJECT stage ");
        }
    }

    /// @notice No dependency callback can enter a second mutation, in either entry point.
    function test_STR_004_ReentrantDependencyCannotEnterASecondMutation() public {
        Launch memory launch = _defaultLaunch();
        Launch memory other = _newLaunch(SUBJECT_HIGH, 2, 1_000e18);
        _bidToGraduation(launch, 2_000e18);

        // A SUBJECT that calls back into `migrate` while a graduation transfer is in flight.
        launch.subject
            .setReentry(address(strategy), abi.encodeCall(RegentLBPStrategy.migrate, (address(launch.auction))));
        launch.subject.resetMovements();
        launch.subject.arm(1, StagedERC20.Fault.Reenter);

        strategy.migrate(address(launch.auction));

        assertEq(launch.subject.reentryAttempts(), 1, "the token did attempt to re-enter");
        assertFalse(launch.subject.lastReentrySucceeded(), "and the re-entrant migration was refused");
        assertEq(
            uint8(strategy.distribution(address(launch.auction)).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Graduated),
            "the outer migration still completed exactly once"
        );

        // The same guard covers initialization: a SUBJECT that calls back into `migrate` during the
        // strategy's own 15% pull is refused.
        StagedERC20 third = _etchToken(SUBJECT_LOW_ALT);
        third.mint(address(factory), TOTAL_SUPPLY);
        third.setReentry(address(strategy), abi.encodeCall(RegentLBPStrategy.migrate, (address(other.auction))));
        address escrow = factory.fundedEscrow(SUBJECT_LOW_ALT, treasury);
        third.resetMovements();
        third.arm(1, StagedERC20.Fault.Reenter);

        factory.initialize(SUBJECT_LOW_ALT, escrow, address(recoveryAdmin), 3, 1_000e18);

        assertEq(third.reentryAttempts(), 1, "the token did attempt to re-enter initialization");
        assertFalse(third.lastReentrySucceeded(), "and the re-entrant call was refused");
    }

    /// @notice The superseded upstream surfaces are absent from the deployed strategy.
    /// @dev A selector diff over the deployed runtime, not a runtime call to a deleted function: the
    ///      dispatcher carries every live selector as a literal, so the three that must exist are
    ///      found and none of the forbidden ones are.
    function test_STR_004_NoRetryRecoveryOrAlternatePoolSurfaceExists() public view {
        bytes memory runtime = address(strategy).code;

        bytes4[3] memory live = [
            RegentLBPStrategy.bindHook.selector,
            RegentLBPStrategy.initializeDistribution.selector,
            RegentLBPStrategy.migrate.selector
        ];
        for (uint256 i; i < live.length; ++i) {
            assertTrue(_carriesSelector(runtime, live[i]), "a live entry point is missing from the dispatcher");
        }

        string[14] memory forbidden = [
            "initializeDistribution(address,uint256,bytes,bytes32)",
            "tryMigrate(address,address,bytes)",
            "migrate(address,bytes)",
            "retryMigration(address)",
            "recoverReserves(address)",
            "rescue(address,address,uint256)",
            "flush(address)",
            "setHook(address)",
            "setFactory(address)",
            "setPositionPlan(address,bytes)",
            "sweep(address,address,uint256)",
            "initializers(address)",
            "registeredPoolIds(bytes32)",
            "migrationProgress(address)"
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            assertFalse(
                _carriesSelector(runtime, bytes4(keccak256(bytes(forbidden[i])))),
                string.concat("a forbidden surface is still reachable: ", forbidden[i])
            );
        }
    }

    /// @notice Checkpoint exhaustion is an upstream liveness condition, not a strategy feature. A
    ///         migration that cannot afford the auction's tick iteration reverts and remembers
    ///         nothing; permissionless upstream iteration then makes a fresh migration affordable.
    function test_STR_004_CheckpointExhaustionIsResolvedUpstreamNotByRetryState() public {
        Launch memory launch = _newLaunch(SUBJECT_LOW, 1, 1_000e18);
        _rollToStart(launch);

        // Every bid lands in one block, so the auction never gets to advance its clearing price
        // incrementally and the whole tick book is left for the final checkpoint to walk.
        uint256 tickSpacing = strategy.BID_TICK_Q96();
        for (uint256 i; i < 40; ++i) {
            _bid(
                launch, address(uint160(0xB1D000 + i)), 1_000_000e18, strategy.FLOOR_PRICE_Q96() + (i + 1) * tickSpacing
            );
        }
        _rollToMigration(launch);

        uint256 root = vm.snapshotState();
        uint256 crowdedCost = _migrationCost(launch);
        require(vm.revertToState(root), "revert to root failed");

        root = vm.snapshotState();
        ContinuousClearingAuction(address(launch.auction)).forceIterateOverTicks(_maxTickPointer(launch));
        uint256 iteratedCost = _migrationCost(launch);
        require(vm.revertToState(root), "revert to root failed");

        assertLt(iteratedCost, crowdedCost, "permissionless upstream iteration moves work out of migration");

        // A migration that cannot afford the crowded auction fails outright, commits nothing, and
        // leaves no attempt record behind.
        uint256 budget = (crowdedCost * 9) / 10;
        Ledger memory before = _ledger(launch);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) =
            address(strategy).call{gas: budget}(abi.encodeCall(RegentLBPStrategy.migrate, (address(launch.auction))));
        assertFalse(ok, "the crowded migration could not afford the auction's tick iteration");
        _assertLedgerUnchanged(before, _ledger(launch), "exhausted migration");

        // Anyone does the upstream work, and the very next migration succeeds.
        vm.prank(outsider);
        ContinuousClearingAuction(address(launch.auction)).forceIterateOverTicks(_maxTickPointer(launch));

        strategy.migrate(address(launch.auction));
        assertEq(
            uint8(strategy.distribution(address(launch.auction)).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Graduated),
            "with no attempt, progress or retry state anywhere in between"
        );
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _assertStageRollsBack(Launch memory launch, StagedERC20 token, uint256 stage, string memory label)
        private
    {
        uint256 snap = vm.snapshotState();
        Ledger memory before = _ledger(launch);

        token.resetMovements();
        token.arm(stage, StagedERC20.Fault.Revert);

        vm.expectRevert();
        strategy.migrate(address(launch.auction));

        _assertLedgerUnchanged(before, _ledger(launch), string.concat(label, vm.toString(stage)));
        require(vm.revertToState(snap), "revert to stage snapshot failed");
    }

    function _maxTickPointer(Launch memory launch) private view returns (uint256) {
        return ContinuousClearingAuction(address(launch.auction)).MAX_TICK_PTR();
    }

    function _migrationCost(Launch memory launch) private returns (uint256) {
        uint256 startGas = gasleft();
        strategy.migrate(address(launch.auction));
        return startGas - gasleft();
    }

    function _carriesSelector(bytes memory runtime, bytes4 selector) private pure returns (bool) {
        for (uint256 i; i + 4 <= runtime.length; ++i) {
            if (
                runtime[i] == selector[0] && runtime[i + 1] == selector[1] && runtime[i + 2] == selector[2]
                    && runtime[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }
}
