// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../../src/escrow/ConditionalVestingEscrowV1.sol";
import {RegentsAutolaunchFactoryV1} from "../../src/factory/RegentsAutolaunchFactoryV1.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
import {AutolaunchFixture} from "./AutolaunchFixture.sol";

/// @notice `STR-019`, `C6.1-I4`: the exact accepted consequence of admitting a treasury that happens
///         to collide with an address the shared strategy's current `CREATE` nonce would later
///         produce — driven end to end through the real factory, the real auctions and the real
///         strategy nonce.
/// @dev This is the behaviour the correction chooses to admit rather than prevent, so it is proved
///      rather than asserted away. Launch-time admission refuses six exact shared-system addresses
///      and judges nothing else: no `code.length` test, no clone fingerprint, and — the point here —
///      no predicted-address rule. A launcher may therefore name the address the strategy's next
///      ordinary clone will occupy.
///
///      What follows is ordinary EVM behaviour, and every step of it is measured below. The clone
///      lands on that address, its initializer refuses to bind a treasury equal to itself, and the
///      revert rolls the whole migration back — the clone, the terminal record, every transfer, and
///      the strategy's own nonce advance alike. Because the nonce is back where it started, an
///      immediate retry targets the same address and fails identically. Any other launch's
///      successful graduation consumes the next two nonces, and the stalled launch then migrates
///      normally onto different addresses.
///
///      The stall is bounded, not silent: while it lasts the raised REGENT is still in the CCA, the
///      escrow is still `Pending`, the isolated 5% reserve and the auction's unsold SUBJECT have not
///      moved, no pool or vesting has begun, and the CCA's own exit and claim rights are untouched.
///
///      The test computes `CREATE` addresses in order to *construct* this edge case. Production
///      admission derives no address at all; `test_STR_019_RefusedTreasuryClassesAreRejectedBefore
///      TheAuctionExists` is the enumeration of what it actually refuses.
contract AutolaunchTreasuryCollisionTest is AutolaunchFixture {
    function setUp() public {
        _deployAutolaunch();
    }

    function test_STR_019_NextCloneTreasuryStallsMigrationUntilAnInterveningGraduationMovesTheNonce() public {
        // The address the strategy's very next ordinary clone will occupy. Nothing has graduated
        // yet, so this is the splitter slot of whichever launch migrates first.
        (address contested,) = _nextCloneAddresses();
        assertEq(contested.code.length, 0, "the contested address already carries code");

        RegentsAutolaunchFactoryV1.LaunchParams memory stalledParams = _params();
        stalledParams.treasury = contested;
        Launched memory stalled = _launchSorted(true, stalledParams);
        Launched memory intervening = _launchSorted(false, _params());

        // Admission accepted it: the launch exists, holds its reserve, and recorded that treasury.
        assertEq(_distribution(stalled).treasury, contested, "the contested treasury was not admitted");

        // Both auctions were created in the same block, so one window carries both.
        _rollToStart(stalled);
        uint256 stalledBid = _bid(stalled, bidder, 20_000e18, _bidPrice(10));
        _bid(intervening, bidder, 20_000e18, _bidPrice(10));
        _rollToMigration(intervening);

        // -- the stall -------------------------------------------------------
        Ledger memory pristine = _ledger(stalled);
        uint256 reserveHeld = stalled.subject.balanceOf(address(strategy));

        vm.expectRevert(SubjectSplitterV1.SelfAddress.selector);
        strategy.migrate(address(stalled.auction));
        _assertLedgerUnchanged(pristine, _ledger(stalled), "first migration attempt");

        // Named, so the stall's shape is legible rather than only differential.
        assertEq(
            uint8(_distribution(stalled).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Active),
            "the stalled launch left Active"
        );
        assertEq(
            uint8(stalled.escrow.lifecycle()),
            uint8(ConditionalVestingEscrowV1.Lifecycle.Pending),
            "the stalled launch's escrow left Pending"
        );
        assertEq(stalled.escrow.vestingStart(), 0, "vesting began on a stalled launch");
        assertEq(hook.splitterOf(_poolId(stalled)), address(0), "a stalled launch registered a pool");
        assertGt(regent.balanceOf(address(stalled.auction)), 0, "the raised REGENT left the CCA");
        assertEq(stalled.subject.balanceOf(address(strategy)), reserveHeld, "the isolated reserve moved");
        assertGt(stalled.auction.remainingSupply(), 0, "this auction sold out, so there is no unsold SUBJECT");
        assertEq(contested.code.length, 0, "the rolled-back clone survived at the contested address");

        // An immediate retry targets exactly the same address, because the nonce rolled back too.
        (address retryTarget,) = _nextCloneAddresses();
        assertEq(retryTarget, contested, "the failed attempt moved the strategy nonce");
        vm.expectRevert(SubjectSplitterV1.SelfAddress.selector);
        strategy.migrate(address(stalled.auction));
        _assertLedgerUnchanged(pristine, _ledger(stalled), "immediate retry");

        // -- bidder rights are the CCA's, not the strategy's ------------------
        // The migration block is already past this auction's own claim block, and the pinned CCA
        // refuses `claimTokens` on an unexited bid, so this is exactly the two calls a real bidder
        // makes. Neither of them needs the strategy, and neither is blocked by the stall.
        assertGe(block.number, uint256(stalled.auction.claimBlock()), "the claim block has not passed");
        vm.prank(bidder);
        stalled.auction.exitBid(stalledBid);
        vm.prank(bidder);
        stalled.auction.claimTokens(stalledBid);
        assertGt(stalled.subject.balanceOf(bidder), 0, "a stalled launch blocked the bidder's own claim");

        // -- an intervening graduation moves the nonce past the collision -----
        uint64 nonceBefore = vm.getNonce(address(strategy));
        strategy.migrate(address(intervening.auction));
        assertEq(vm.getNonce(address(strategy)), nonceBefore + 2, "graduation consumed other than two clone nonces");
        RegentLBPStrategy.Distribution memory interveningRecord = _distribution(intervening);
        assertEq(interveningRecord.splitter, contested, "the intervening splitter did not take the contested address");
        assertEq(
            uint8(interveningRecord.lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Graduated),
            "the intervening launch did not graduate"
        );

        // -- the stalled launch now migrates, onto different addresses --------
        uint256 crossRoutedBefore = regent.balanceOf(contested);
        uint256 auctionRegentBefore = regent.balanceOf(address(stalled.auction));
        strategy.migrate(address(stalled.auction));

        RegentLBPStrategy.Distribution memory stalledRecord = _distribution(stalled);
        assertEq(
            uint8(stalledRecord.lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Graduated),
            "the stalled launch did not eventually graduate"
        );
        assertTrue(stalledRecord.splitter != contested, "the retry landed on the contested address again");
        assertTrue(stalledRecord.receiver != contested, "the retry's receiver landed on the contested address");
        assertEq(
            SubjectSplitterV1(stalledRecord.splitter).treasury(),
            contested,
            "the stalled launch did not keep the treasury it chose"
        );
        assertEq(hook.splitterOf(_poolId(stalled)), stalledRecord.splitter, "the retry registered another splitter");

        // The retry routed its own unused raise into the intervening launch's splitter, which is the
        // cross-launch consequence `FAC-015` owns — named here, not prevented.
        uint256 swept = auctionRegentBefore - regent.balanceOf(address(stalled.auction));
        assertEq(
            regent.balanceOf(contested) - crossRoutedBefore,
            swept - stalledRecord.lpRegentUsed,
            "the stalled launch's unused raise did not reach the treasury it chose"
        );

        // Neither launch's lifecycle, custody ledger or isolated reserve is corrupted by any of it.
        assertEq(
            uint8(_distribution(intervening).lifecycle),
            uint8(RegentLBPStrategy.Lifecycle.Graduated),
            "the intervening launch's lifecycle moved"
        );
        assertEq(
            uint8(stalled.escrow.lifecycle()),
            uint8(ConditionalVestingEscrowV1.Lifecycle.Graduated),
            "the stalled launch's escrow did not graduate"
        );
        assertEq(stalled.subject.balanceOf(address(strategy)), 0, "the stalled launch stranded its reserve");
        assertEq(intervening.subject.balanceOf(address(strategy)), 0, "the intervening launch stranded its reserve");
        assertEq(stalled.subject.totalSupply(), TOTAL_SUPPLY, "the stalled launch's supply moved");
        assertEq(intervening.subject.totalSupply(), TOTAL_SUPPLY, "the intervening launch's supply moved");
        assertEq(
            SubjectSplitterV1(contested).unclaimedLiability(BaseBindings.REGENT),
            0,
            "the cross-routed REGENT was silently recognized as the intervening launch's revenue"
        );
    }
}
