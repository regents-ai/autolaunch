// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {PaymentReceiverV1} from "../../src/revenue/PaymentReceiverV1.sol";
import {RegentsAutolaunchFactoryV1} from "../../src/factory/RegentsAutolaunchFactoryV1.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
import {AutolaunchFixture} from "./AutolaunchFixture.sol";

/// @notice `MIG-021` and `MIG-022`: what a real graduation does with the two addresses it deploys to
///         and with the shared PositionManager's existing inventory.
/// @dev Both clones are deployed with CREATE2 from a salt the strategy derives from the launch's own
///      immutable identity, so both addresses are facts before the auction exists. That is what makes
///      launch-time treasury admission able to refuse them, and `MIG-021` is the other half of that
///      claim: the addresses admission refused are the addresses graduation actually occupies.
///
///      `MIG-022` is the settlement half. The strategy funds the PositionManager with exactly the two
///      amounts its own position consumes, so REGENT and SUBJECT already sitting at that shared
///      contract are byte-for-byte untouched by this launch's graduation.
contract AutolaunchTerminalCustodyTest is AutolaunchFixture {
    function setUp() public {
        _deployAutolaunch();
    }

    // -------------------------------------------------------------------------
    // MIG-021 — deterministic clone identity
    // -------------------------------------------------------------------------

    /// @notice `MIG-021`: a launch is refused at its own splitter slot and at its own canonical
    ///         receiver slot, and the graduation that follows deploys to exactly those two addresses.
    /// @dev Both slots are derived by `LaunchCloneSlots` from first principles — the two role strings
    ///      the strategy hashes, the salt it builds, and the CREATE2 rule — so nothing here restates a
    ///      production getter. The refused attempts and the successful launch share one identity:
    ///      each refusal rolls the whole launch back, so the launch id and the SUBJECT the pinned
    ///      UERC20 factory derives from it never move.
    function test_MIG_021_OwnCloneSlotsAreRefusedAndAreExactlyWhereGraduationDeploys() public {
        uint256 launchId = factory.nextLaunchId();
        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        params.name = _nameSorting(true, params.symbol, launchId);
        (address splitterSlot, address receiverSlot) = _plannedSlots(launchId, params);

        assertEq(splitterSlot.code.length, 0, "the splitter slot carries code before the launch");
        assertEq(receiverSlot.code.length, 0, "the receiver slot carries code before the launch");
        assertTrue(splitterSlot != receiverSlot, "both clone roles derive the same address");

        _assertRefusedAsTreasury(params.name, splitterSlot, launchId);
        _assertRefusedAsTreasury(params.name, receiverSlot, launchId);

        // The same launch, on an ordinary treasury, graduates into exactly those two addresses.
        Launched memory launched = _launchAs(launcher, params);
        assertEq(launched.launchId, launchId, "a refused attempt consumed the launch id");

        _bidToGraduation(launched, 2_000e18);
        strategy.migrate(address(launched.auction));

        RegentLBPStrategy.Distribution memory d = _distribution(launched);
        assertEq(d.splitter, splitterSlot, "the splitter is not at the address admission refused");
        assertEq(d.receiver, receiverSlot, "the receiver is not at the address admission refused");

        // And they are the real, correctly bound artifacts, not merely code at the right address.
        assertEq(SubjectSplitterV1(d.splitter).subject(), address(launched.subject), "splitter SUBJECT binding");
        assertEq(SubjectSplitterV1(d.splitter).treasury(), treasury, "splitter treasury binding");
        assertEq(PaymentReceiverV1(payable(d.receiver)).splitter(), d.splitter, "receiver splitter binding");
        assertEq(PaymentReceiverV1(payable(d.receiver)).referralBps(), 0, "the canonical receiver carries a referral");
        assertEq(hook.splitterOf(_poolId(launched)), d.splitter, "the pool registered another splitter");
    }

    /// @dev One launch attempt whose only defect is its treasury, refused before its auction exists
    ///      and leaving the launch id, the escrow and the strategy's records exactly where they were.
    function _assertRefusedAsTreasury(string memory name, address slot, uint256 launchId) private {
        RegentsAutolaunchFactoryV1.LaunchParams memory attempt = _params();
        attempt.name = name;
        attempt.treasury = slot;

        _fundFee(launcher, attempt.expectedLaunchFee);
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.RefusedTreasury.selector, slot));
        factory.launch(attempt);

        assertEq(factory.nextLaunchId(), launchId, "a refused launch consumed an id");
        assertEq(factory.launches(launchId).subject, address(0), "a refused launch left a record");
        assertEq(slot.code.length, 0, "a refused launch deployed something at the slot");
    }

    // -------------------------------------------------------------------------
    // MIG-022 — exact PositionManager funding
    // -------------------------------------------------------------------------

    /// @notice `MIG-022`, `C6-I8`: a real graduation transfers the PositionManager exactly the two
    ///         amounts its own position consumes, so REGENT and SUBJECT already held there are
    ///         untouched to the unit.
    /// @dev The pinned planner closes every plan by settling `CONTRACT_BALANCE` of each pool
    ///      currency, which would settle the shared PositionManager's *whole* balance and hand the
    ///      resulting credit back to the strategy as if it were this launch's unspent budget — from
    ///      there it would leave through this launch's own destinations. The strategy replaces those
    ///      two settlement amounts with the exact amounts it transfers in, and this proves it.
    ///
    ///      Both pre-seeds arrive through real production paths and no cheatcode writes a balance: a
    ///      REGENT holder sends REGENT to the shared PositionManager, and the auction's own bidder
    ///      claims SUBJECT at `claimBlock` — which precedes the migration block — and sends some of it
    ///      there. The launch then graduates normally, with its LP consumption, its residue routing
    ///      and its recorded artifacts all still exact.
    function test_MIG_022_GraduationLeavesForeignPositionManagerBalancesUntouched() public {
        // A raise well above the reserve's worth, so both residues are non-zero and the routing this
        // test must not disturb is really exercised.
        Launched memory launched = _defaultLaunch();
        _rollToStart(launched);
        uint256 bidId = _bid(launched, bidder, 20_000_000e18, _bidPrice(500));

        uint256 seededRegent = 1_000e18;
        address stranger = makeAddr("position-manager-stranger");
        regent.mint(stranger, seededRegent);
        vm.prank(stranger);
        regent.transfer(BaseBindings.POSITION_MANAGER, seededRegent);

        // The bidder's own claimed SUBJECT, sent from the bidder's own account. The pinned CCA
        // refuses `claimTokens` for a bid that has not been exited, so a claim is always the bid
        // owner's own two calls, and `claimBlock` precedes the migration block.
        vm.roll(uint256(launched.auction.claimBlock()));
        vm.prank(bidder);
        launched.auction.exitBid(bidId);
        vm.prank(bidder);
        launched.auction.claimTokens(bidId);
        uint256 seededSubject = launched.subject.balanceOf(bidder);
        assertGt(seededSubject, 0, "the bidder claimed no SUBJECT to pre-seed the PositionManager with");
        vm.prank(bidder);
        launched.subject.transfer(BaseBindings.POSITION_MANAGER, seededSubject);

        uint256 regentBefore = regent.balanceOf(BaseBindings.POSITION_MANAGER);
        uint256 subjectBefore = launched.subject.balanceOf(BaseBindings.POSITION_MANAGER);
        assertEq(regentBefore, seededRegent, "the PositionManager holds no foreign REGENT");
        assertEq(subjectBefore, seededSubject, "the PositionManager holds no foreign SUBJECT");

        uint256 treasuryRegentBefore = regent.balanceOf(treasury);
        uint256 escrowSubjectBefore = launched.subject.balanceOf(address(launched.escrow));
        uint256 auctionRegentBefore = regent.balanceOf(address(launched.auction));
        uint256 auctionSubjectBefore = launched.subject.balanceOf(address(launched.auction));

        _rollToMigration(launched);
        strategy.migrate(address(launched.auction));

        // The whole claim: not "roughly preserved", exactly preserved, in both pool assets.
        assertEq(
            regent.balanceOf(BaseBindings.POSITION_MANAGER),
            regentBefore,
            "graduation settled REGENT this launch never funded"
        );
        assertEq(
            launched.subject.balanceOf(BaseBindings.POSITION_MANAGER),
            subjectBefore,
            "graduation settled SUBJECT this launch never funded"
        );

        // And the foreign inventory reached neither of this launch's two value destinations: the
        // treasury received exactly the unused raise and the escrow exactly the unused reserve.
        RegentLBPStrategy.Distribution memory d = _distribution(launched);
        uint256 swept = auctionRegentBefore - regent.balanceOf(address(launched.auction));
        assertGt(swept, d.lpRegentUsed, "the position consumed the whole raise, so there is no residue to check");
        assertEq(
            regent.balanceOf(treasury) - treasuryRegentBefore,
            swept - d.lpRegentUsed,
            "the treasury received more than this launch's own unused raise"
        );
        // The escrow is fed from two places at graduation — its own sweep of the auction's unsold
        // SUBJECT and the strategy's residue — so the strategy's share is isolated before comparing.
        uint256 escrowFromStrategy = (launched.subject.balanceOf(address(launched.escrow)) - escrowSubjectBefore)
            - (auctionSubjectBefore - launched.subject.balanceOf(address(launched.auction)));
        assertEq(
            escrowFromStrategy,
            RESERVE_ALLOCATION - d.lpSubjectUsed,
            "the escrow received more than this launch's own unused reserve"
        );

        // The graduation itself is entirely normal.
        assertEq(uint8(d.lifecycle), uint8(RegentLBPStrategy.Lifecycle.Graduated), "the launch did not graduate");
        assertEq(positionManager.nextTokenId(), d.lpTokenId + 1, "exactly one position was not minted");
        assertGt(d.lpRegentUsed, 0, "the position consumed no REGENT");
        assertGt(d.lpSubjectUsed, 0, "the position consumed no SUBJECT");
        assertEq(regent.balanceOf(address(strategy)), 0, "the strategy kept REGENT after graduation");
        assertEq(launched.subject.balanceOf(address(strategy)), 0, "the strategy kept SUBJECT after graduation");
    }
}
