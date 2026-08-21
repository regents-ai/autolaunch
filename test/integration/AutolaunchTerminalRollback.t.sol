// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../../src/escrow/ConditionalVestingEscrowV1.sol";
import {RegentsAutolaunchFactoryV1} from "../../src/factory/RegentsAutolaunchFactoryV1.sol";
import {RegentFeeHook} from "../../src/hook/RegentFeeHook.sol";
import {PaymentReceiverV1} from "../../src/revenue/PaymentReceiverV1.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {ILBPInitializer} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {AutolaunchFixture} from "./AutolaunchFixture.sol";
import {StagedERC20} from "../strategy/doubles/StagedERC20.sol";

/// @notice `C4-I6`: a technical problem anywhere in migration is an ordinary EVM revert. Every named
///         external call rolls the whole launch back to its exact pre-migration state, a terminal
///         launch cannot be driven again, and no dependency can re-enter a second mutation.
contract AutolaunchTerminalRollbackTest is AutolaunchFixture {
    /// @notice The exact amounts one clean graduation of this launch moves, measured by running it.
    struct Movements {
        uint128 lpRegentUsed;
        uint128 lpSubjectUsed;
        uint256 treasuryRegent;
        uint256 escrowSubject;
        uint256 regentStages;
    }

    function setUp() public {
        _deployAutolaunch();
    }

    /// @notice `MIG-017`: failure at every external call graduation makes restores the complete
    ///         pre-migration ledger, and the untouched launch then graduates normally.
    /// @dev The token movements are enumerated from a measured clean run rather than assumed: one
    ///      graduation is executed inside a snapshot to learn how many REGENT movements it makes and
    ///      exactly which SUBJECT payouts it performs, the snapshot is rolled back, and each of those
    ///      movements is then failed in turn from the identical pre-migration state. The named
    ///      non-token calls are failed one at a time by the same rule.
    function test_MIG_017_FailureAtEveryExternalCallRollsBack() public {
        // A raise large enough that both LP residues are non-zero, so every later stage is real.
        Launched memory launched = _defaultLaunch();
        _bidToGraduationAt(launched, 20_000_000e18, 500);

        Movements memory moves = _measure(launched);
        assertEq(moves.regentStages, 4, "the REGENT stages graduation moves through");
        assertGt(moves.treasuryRegent, 0, "this raise leaves no treasury payout to fail");
        assertGt(moves.escrowSubject, 0, "this raise leaves no escrow payout to fail");

        // Every REGENT movement: the auction sweep, the PositionManager funding transfer, the
        // PositionManager settlement, and the treasury payout.
        for (uint256 stage = 1; stage <= moves.regentStages; ++stage) {
            uint256 snap = vm.snapshotState();
            Ledger memory before = _ledger(launched);
            regent.resetMovements();
            regent.arm(stage, StagedERC20.Fault.Revert);

            vm.expectRevert();
            strategy.migrate(address(launched.auction));

            _assertLedgerUnchanged(before, _ledger(launched), string.concat("REGENT stage ", vm.toString(stage)));
            require(vm.revertToState(snap), "revert to REGENT stage snapshot failed");
        }

        // Every SUBJECT movement, addressed by its exact recipient and amount.
        _assertBoundaryRollsBack(
            launched,
            address(launched.subject),
            abi.encodeWithSignature("transfer(address,uint256)", BaseBindings.POSITION_MANAGER, moves.lpSubjectUsed),
            "SUBJECT stage 1 PositionManager funding"
        );
        _assertBoundaryRollsBack(
            launched,
            address(launched.subject),
            abi.encodeWithSignature("transfer(address,uint256)", BaseBindings.POOL_MANAGER, moves.lpSubjectUsed),
            "SUBJECT stage 2 PoolManager settlement"
        );
        _assertBoundaryRollsBack(
            launched,
            address(launched.subject),
            abi.encodeWithSignature("transfer(address,uint256)", address(launched.escrow), moves.escrowSubject),
            "SUBJECT stage 3 escrow payout"
        );

        // Every named non-token call graduation crosses, one at a time.
        _assertSelectorRollsBack(
            launched, address(launched.auction), IContinuousClearingAuction.checkpoint.selector, "1 CCA checkpoint"
        );
        _assertSelectorRollsBack(
            launched,
            address(launched.auction),
            ILBPInitializer.lbpInitializationParams.selector,
            "2 CCA graduation proof"
        );
        _assertSelectorRollsBack(
            launched, address(splitterImplementation), SubjectSplitterV1.initialize.selector, "3 splitter clone"
        );
        _assertSelectorRollsBack(launched, address(hook), RegentFeeHook.registerPool.selector, "4 hook registration");
        _assertSelectorRollsBack(
            launched, address(launched.auction), IContinuousClearingAuction.sweepCurrency.selector, "5 CCA sweep"
        );
        _assertSelectorRollsBack(
            launched, BaseBindings.POOL_MANAGER, IPoolManager.initialize.selector, "6 PoolManager initialize"
        );
        _assertSelectorRollsBack(
            launched, BaseBindings.POSITION_MANAGER, IPositionManager.nextTokenId.selector, "7 next position id"
        );
        _assertSelectorRollsBack(
            launched,
            BaseBindings.POSITION_MANAGER,
            IPositionManager.modifyLiquidities.selector,
            "8 PositionManager mint"
        );
        _assertSelectorRollsBack(
            launched,
            address(launched.escrow),
            ConditionalVestingEscrowV1.sweepGraduatedUnsoldSubject.selector,
            "9 escrow sweep"
        );
        _assertSelectorRollsBack(
            launched, address(receiverImplementation), PaymentReceiverV1.initialize.selector, "10 canonical receiver"
        );
        _assertSelectorRollsBack(
            launched, address(launched.escrow), ConditionalVestingEscrowV1.activateVesting.selector, "11 vesting"
        );

        // The launch none of those injections touched still graduates.
        strategy.migrate(address(launched.auction));
        assertEq(
            uint8(_distribution(launched).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Graduated),
            "the untouched migration did not work"
        );
    }

    /// @notice `MIG-018`: a graduated launch is terminal. Every further attempt reverts and the whole
    ///         ledger stands still.
    function test_MIG_018_RepeatedGraduationRevertsAndMovesNoValue() public {
        Launched memory launched = _defaultLaunch();
        _bidToGraduation(launched, 2_000e18);
        strategy.migrate(address(launched.auction));

        Ledger memory before = _ledger(launched);
        RegentLBPStrategy.Distribution memory d = _distribution(launched);

        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    RegentLBPStrategy.LaunchNotActive.selector, RegentLBPStrategy.Lifecycle.Graduated
                )
            );
            vm.prank(i == 0 ? outsider : launcher);
            strategy.migrate(address(launched.auction));
        }

        // The escrow refuses both of its terminal entry points too, so nothing downstream reopens.
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.NotPending.selector, ConditionalVestingEscrowV1.Lifecycle.Graduated
            )
        );
        vm.prank(address(strategy));
        launched.escrow.resolveFailure(address(launched.auction));

        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.NotPending.selector, ConditionalVestingEscrowV1.Lifecycle.Graduated
            )
        );
        vm.prank(address(strategy));
        launched.escrow.activateVesting();

        _assertLedgerUnchanged(before, _ledger(launched), "repeated graduation");
        RegentLBPStrategy.Distribution memory after_ = _distribution(launched);
        assertEq(after_.splitter, d.splitter, "the recorded splitter changed");
        assertEq(after_.receiver, d.receiver, "the recorded receiver changed");
        assertEq(after_.lpTokenId, d.lpTokenId, "the recorded position changed");
    }

    /// @notice `MIG-019`: a migration dependency that calls back into the migration path is refused,
    ///         and a dependency whose own failure propagates rolls the whole migration back.
    function test_MIG_019_MigrationDependencyReentrancyIsRejectedWithCompleteRollback() public {
        Launched memory launched = _defaultLaunch();
        Launched memory other = _launchAs(outsider, _params());
        _bidToGraduation(launched, 2_000e18);

        // 1. Re-entering the same launch's migration while a REGENT movement is in flight.
        uint256 attempts = regent.reentryAttempts();
        _armReentry(address(strategy), abi.encodeCall(RegentLBPStrategy.migrate, (address(launched.auction))));
        strategy.migrate(address(launched.auction));
        assertEq(regent.reentryAttempts(), attempts + 1, "the dependency did not attempt to re-enter");
        assertFalse(regent.lastReentrySucceeded(), "the re-entrant migration was admitted");
        assertEq(
            uint8(_distribution(launched).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Graduated),
            "the outer migration did not complete exactly once"
        );

        // 2. The guard is contract-wide, so a re-entrant call naming a different active launch is
        //    refused as well and that launch is untouched.
        Launched memory second = _launchAs(launcher, _params());
        _bidToGraduation(second, 2_000e18);
        _armReentry(address(strategy), abi.encodeCall(RegentLBPStrategy.migrate, (address(other.auction))));
        strategy.migrate(address(second.auction));
        assertFalse(regent.lastReentrySucceeded(), "a cross-launch re-entrant migration was admitted");
        assertEq(
            uint8(_distribution(other).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Active),
            "the unrelated launch was driven by a re-entrant call"
        );

        // 3. A re-entrant *launch* from a migration dependency is refused by the same guard, because
        //    the shared strategy is already inside a mutation.
        vm.prank(governance);
        factory.setLaunchFee(0);
        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        params.expectedLaunchFee = 0;
        Launched memory third = _launchAs(launcher, params);
        _bidToGraduation(third, 2_000e18);

        uint256 nextLaunchIdBefore = factory.nextLaunchId();
        attempts = regent.reentryAttempts();
        _armReentry(address(factory), abi.encodeCall(RegentsAutolaunchFactoryV1.launch, (params)));
        strategy.migrate(address(third.auction));
        assertEq(regent.reentryAttempts(), attempts + 1, "the dependency did not attempt a re-entrant launch");
        assertFalse(regent.lastReentrySucceeded(), "a re-entrant launch was admitted mid-migration");
        assertEq(factory.nextLaunchId(), nextLaunchIdBefore, "a re-entrant launch consumed an ID");

        // 4. When the dependency's own failure propagates instead of being swallowed, the whole
        //    migration rolls back to its exact pre-migration state.
        Launched memory fourth = _launchAs(launcher, params);
        _bidToGraduation(fourth, 2_000e18);
        Ledger memory before = _ledger(fourth);
        regent.resetMovements();
        regent.arm(1, StagedERC20.Fault.Revert);
        vm.expectRevert();
        strategy.migrate(address(fourth.auction));
        regent.arm(0, StagedERC20.Fault.None);
        _assertLedgerUnchanged(before, _ledger(fourth), "propagated dependency failure");
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    /// @dev Run one clean graduation inside a snapshot to learn the exact movements it makes, then
    ///      roll it back so every injection below starts from the identical pre-migration state.
    function _measure(Launched memory launched) private returns (Movements memory moves) {
        uint256 snap = vm.snapshotState();
        uint256 treasuryBefore = regent.balanceOf(treasury);
        uint256 escrowBefore = launched.subject.balanceOf(address(launched.escrow));
        uint256 auctionUnsoldBefore = launched.subject.balanceOf(address(launched.auction));

        regent.resetMovements();
        strategy.migrate(address(launched.auction));

        RegentLBPStrategy.Distribution memory d = _distribution(launched);
        moves.lpRegentUsed = d.lpRegentUsed;
        moves.lpSubjectUsed = d.lpSubjectUsed;
        moves.treasuryRegent = regent.balanceOf(treasury) - treasuryBefore;
        moves.regentStages = regent.movements();
        // The strategy's own payout to escrow, separated from the escrow's later auction sweep.
        moves.escrowSubject = launched.subject.balanceOf(address(launched.escrow)) - escrowBefore
            - (auctionUnsoldBefore - launched.subject.balanceOf(address(launched.auction)));

        require(vm.revertToState(snap), "revert to measurement snapshot failed");
    }

    function _assertBoundaryRollsBack(
        Launched memory launched,
        address target,
        bytes memory calldata_,
        string memory boundary
    ) private {
        uint256 snap = vm.snapshotState();
        Ledger memory before = _ledger(launched);

        vm.mockCallRevert(target, calldata_, "");
        vm.expectRevert();
        strategy.migrate(address(launched.auction));
        vm.clearMockedCalls();

        _assertLedgerUnchanged(before, _ledger(launched), boundary);
        require(vm.revertToState(snap), "revert to boundary snapshot failed");
    }

    function _assertSelectorRollsBack(Launched memory launched, address target, bytes4 selector, string memory boundary)
        private
    {
        _assertBoundaryRollsBack(launched, target, abi.encodePacked(selector), boundary);
    }

    /// @dev Make the launch's REGENT call back into the Autolaunch graph mid-migration. The staged
    ///      token records whether that call was admitted and swallows its failure, so the outer
    ///      migration's own behaviour under a refused re-entry is what gets observed.
    function _armReentry(address target, bytes memory callData) private {
        regent.setReentry(target, callData);
        regent.resetMovements();
        regent.arm(1, StagedERC20.Fault.Reenter);
    }
}
