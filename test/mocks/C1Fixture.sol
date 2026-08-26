// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {ConditionalVestingEscrowV1} from "../../src/escrow/ConditionalVestingEscrowV1.sol";
import {PaymentReceiverV1} from "../../src/revenue/PaymentReceiverV1.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {MockAuction} from "./MockAuction.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockLiveStaking} from "./MockLiveStaking.sol";

/// @notice Shared C1 fixture: the three implementations, the external mocks at their boundary, and
///         the ordinary `LibClone.clone` deployment path.
/// @dev The clone mechanism here is the same ordinary Solady `LibClone.clone` the C4 production
///      factory uses. This fixture exposes no production creation API and satisfies no factory or
///      strategy claim; it only reaches the initializer the way production will.
abstract contract C1Fixture is Test {
    uint256 internal constant TOTAL_SUPPLY = 100_000_000_000e18;
    uint256 internal constant PENDING_ALLOCATION = 85_000_000_000e18;
    uint256 internal constant AUCTION_ALLOCATION = 10_000_000_000e18;
    uint256 internal constant RESERVE_ALLOCATION = 5_000_000_000e18;

    ConditionalVestingEscrowV1 internal escrowImplementation;
    SubjectSplitterV1 internal splitterImplementation;
    PaymentReceiverV1 internal receiverImplementation;

    MockERC20 internal usdc;
    MockERC20 internal regent;
    MockERC20 internal subject;
    MockLiveStaking internal liveStaking;

    address internal treasury = makeAddr("treasury");
    address internal regentSafe = makeAddr("regentSafe");
    address internal strategy = makeAddr("strategy");
    address internal outsider = makeAddr("outsider");

    function _deployC1() internal {
        escrowImplementation = new ConditionalVestingEscrowV1();
        splitterImplementation = new SubjectSplitterV1();
        receiverImplementation = new PaymentReceiverV1();

        usdc = new MockERC20("USD Coin", "USDC", 6);
        regent = new MockERC20("Regent", "REGENT", 18);
        subject = new MockERC20("Subject", "SUBJ", 18);
        liveStaking = new MockLiveStaking(address(usdc));
    }

    /// @dev Clone and initialize a splitter in one call, the way C4 must.
    function _newSplitter() internal returns (SubjectSplitterV1 splitter) {
        splitter = SubjectSplitterV1(LibClone.clone(address(splitterImplementation)));
        splitter.initialize(
            address(usdc), address(regent), address(subject), address(liveStaking), regentSafe, treasury
        );
    }

    /// @dev Clone and initialize a receiver in one call, the way C4 must.
    function _newReceiver(address splitter, address beneficiary, uint16 referralBps, address noteEditor, bool canonical)
        internal
        returns (PaymentReceiverV1 receiver)
    {
        receiver = PaymentReceiverV1(LibClone.clone(address(receiverImplementation)));
        receiver.initialize(splitter, beneficiary, referralBps, noteEditor, canonical);
    }

    /// @dev One launch: its own SUBJECT token at exactly 100B supply, held by this contract the way
    ///      the factory holds it before distributing 10/5/85, and an escrow clone initialized with
    ///      the exact 85%. Each launch gets a fresh token so several launches can coexist in one
    ///      test without any of them presenting the wrong total supply.
    function _newLaunch() internal returns (MockERC20 launchSubject, ConditionalVestingEscrowV1 escrow) {
        launchSubject = new MockERC20("Subject", "SUBJ", 18);
        launchSubject.mint(address(this), TOTAL_SUPPLY);

        escrow = ConditionalVestingEscrowV1(LibClone.clone(address(escrowImplementation)));
        launchSubject.approve(address(escrow), PENDING_ALLOCATION);
        escrow.initialize(address(launchSubject), treasury, strategy);
    }

    /// @dev A graduated launch whose unsold SUBJECT has been swept and whose vesting is active.
    function _graduatedLaunch(uint256 unsold)
        internal
        returns (MockERC20 launchSubject, ConditionalVestingEscrowV1 escrow, MockAuction auction)
    {
        (launchSubject, escrow) = _newLaunch();
        auction = new MockAuction(address(launchSubject), address(escrow));
        launchSubject.transfer(address(auction), AUCTION_ALLOCATION);
        auction.setGraduated(true);
        auction.setRemainingSupply(unsold);

        vm.startPrank(strategy);
        escrow.sweepGraduatedUnsoldSubject(address(auction));
        escrow.activateVesting();
        vm.stopPrank();
    }

    /// @dev A launch resolved as economically failed, with all three contributors delivered.
    function _failedLaunch()
        internal
        returns (MockERC20 launchSubject, ConditionalVestingEscrowV1 escrow, MockAuction auction)
    {
        (launchSubject, escrow) = _newLaunch();
        auction = new MockAuction(address(launchSubject), address(escrow));
        launchSubject.transfer(address(auction), AUCTION_ALLOCATION);
        launchSubject.transfer(address(escrow), RESERVE_ALLOCATION);

        vm.prank(strategy);
        escrow.resolveFailure(address(auction));
    }
}
