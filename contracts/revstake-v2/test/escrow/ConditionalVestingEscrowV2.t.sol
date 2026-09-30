// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {C1Fixture} from "../mocks/C1Fixture.sol";
import {MockAuction} from "../mocks/MockAuction.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV2} from "../../src/escrow/ConditionalVestingEscrowV2.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

/// @notice Claim-level proof for `ConditionalVestingEscrowV2`.
/// @dev Every selector below drives the production escrow directly. Only the SUBJECT token, the CCA
///      auction, and the calling account are mocked, which is exactly the C1 boundary.
contract ConditionalVestingEscrowV2Test is C1Fixture {
    address private constant DEAD = BaseBindings.DEAD_ADDRESS;

    function setUp() public {
        _deployC1();
    }

    // ------------------------------------------------------------------ ESC-001

    /// @notice ESC-001: one atomic initialization per clone, and never a second.
    function test_ESC_001_InitializationIsAtomicAndHappensExactlyOnce() public {
        // The implementation itself can never hold a launch.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrowImplementation.initialize(address(subject), treasury, strategy);

        MockERC20 launchSubject = new MockERC20("Subject", "SUBJ", 18);
        launchSubject.mint(address(this), TOTAL_SUPPLY);

        // Binding and custody happen in the same call, so a bound-but-unfunded escrow cannot exist.
        ConditionalVestingEscrowV2 escrow = ConditionalVestingEscrowV2(LibClone.clone(address(escrowImplementation)));
        assertEq(escrow.subject(), address(0), "unbound before initialization");
        launchSubject.approve(address(escrow), PENDING_ALLOCATION);
        escrow.initialize(address(launchSubject), treasury, strategy);

        assertEq(escrow.subject(), address(launchSubject), "subject bound");
        assertEq(escrow.treasury(), treasury, "treasury bound");
        assertEq(escrow.strategy(), strategy, "strategy bound");
        assertEq(uint256(escrow.lifecycle()), uint256(ConditionalVestingEscrowV2.Lifecycle.Pending), "pending");
        assertEq(launchSubject.balanceOf(address(escrow)), PENDING_ALLOCATION, "custody taken atomically");

        // A second initialization is impossible, from any caller.
        launchSubject.approve(address(escrow), PENDING_ALLOCATION);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrow.initialize(address(launchSubject), treasury, strategy);
        vm.prank(outsider);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrow.initialize(address(launchSubject), outsider, outsider);

        // Zero bindings are rejected.
        _expectInitRevert(ConditionalVestingEscrowV2.ZeroAddress.selector, address(0), treasury, strategy);
        _expectInitRevert(ConditionalVestingEscrowV2.ZeroAddress.selector, address(launchSubject), address(0), strategy);
        _expectInitRevert(ConditionalVestingEscrowV2.ZeroAddress.selector, address(launchSubject), treasury, address(0));

        // Self bindings, which would trap value in the clone, are rejected.
        ConditionalVestingEscrowV2 fresh = ConditionalVestingEscrowV2(LibClone.clone(address(escrowImplementation)));
        vm.expectRevert(ConditionalVestingEscrowV2.SelfAddress.selector);
        fresh.initialize(address(fresh), treasury, strategy);
        vm.expectRevert(ConditionalVestingEscrowV2.SelfAddress.selector);
        fresh.initialize(address(launchSubject), address(fresh), strategy);
        vm.expectRevert(ConditionalVestingEscrowV2.SelfAddress.selector);
        fresh.initialize(address(launchSubject), treasury, address(fresh));

        // A token that is not a 100B 18-decimal launch supply is rejected.
        MockERC20 wrongSupply = new MockERC20("Wrong", "WRG", 18);
        wrongSupply.mint(address(this), TOTAL_SUPPLY - 1);
        wrongSupply.approve(address(fresh), PENDING_ALLOCATION);
        vm.expectRevert(
            abi.encodeWithSelector(ConditionalVestingEscrowV2.InvalidSubjectSupply.selector, TOTAL_SUPPLY - 1)
        );
        fresh.initialize(address(wrongSupply), treasury, strategy);
    }

    // ------------------------------------------------------------------ ESC-002

    /// @notice ESC-002: a launch resolves once, and graduation and failure are mutually exclusive.
    function test_ESC_002_ResolutionHappensExactlyOnceAndIsExclusive() public {
        (, ConditionalVestingEscrowV2 graduated, MockAuction graduatedAuction) = _graduatedLaunch();

        vm.startPrank(strategy);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV2.NotPending.selector, ConditionalVestingEscrowV2.Lifecycle.Graduated
            )
        );
        graduated.resolveFailure(address(graduatedAuction));
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV2.NotPending.selector, ConditionalVestingEscrowV2.Lifecycle.Graduated
            )
        );
        graduated.activateVesting();
        vm.stopPrank();

        (, ConditionalVestingEscrowV2 failed, MockAuction failedAuction) = _failedLaunch();
        uint256 deadAfterFailure = MockERC20(failed.subject()).balanceOf(DEAD);

        vm.startPrank(strategy);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV2.NotPending.selector, ConditionalVestingEscrowV2.Lifecycle.Failed
            )
        );
        failed.resolveFailure(address(failedAuction));
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV2.NotPending.selector, ConditionalVestingEscrowV2.Lifecycle.Failed
            )
        );
        failed.activateVesting();
        vm.stopPrank();

        assertEq(MockERC20(failed.subject()).balanceOf(DEAD), deadAfterFailure, "no further retirement");
        assertEq(uint256(failed.lifecycle()), uint256(ConditionalVestingEscrowV2.Lifecycle.Failed), "still failed");

        // The two paths are exclusive at the auction as well as at the escrow: a launch whose
        // auction graduated can never be retired as a failure, even while it is still pending.
        (MockERC20 liveSubject, ConditionalVestingEscrowV2 live) = _newLaunch();
        MockAuction liveAuction = new MockAuction(address(liveSubject), strategy);
        liveSubject.transfer(address(live), AUCTION_ALLOCATION + RESERVE_ALLOCATION);
        liveAuction.setGraduated(true);

        vm.prank(strategy);
        vm.expectRevert(ConditionalVestingEscrowV2.AuctionIsGraduated.selector);
        live.resolveFailure(address(liveAuction));

        assertEq(uint256(live.lifecycle()), uint256(ConditionalVestingEscrowV2.Lifecycle.Pending), "still pending");
        assertEq(liveSubject.balanceOf(DEAD), 0, "the refused failure retired nothing");

        // Graduation that is only visible after the checkpoint is still honored, because escrow
        // checkpoints before it reads.
        (MockERC20 staleSubject, ConditionalVestingEscrowV2 stale) = _newLaunch();
        MockAuction staleAuction = new MockAuction(address(staleSubject), strategy);
        staleSubject.transfer(address(stale), AUCTION_ALLOCATION + RESERVE_ALLOCATION);
        staleAuction.setGraduatesOnCheckpoint(true);
        assertFalse(staleAuction.isGraduated(), "stale pre-checkpoint state");

        vm.prank(strategy);
        vm.expectRevert(ConditionalVestingEscrowV2.AuctionIsGraduated.selector);
        stale.resolveFailure(address(staleAuction));
        assertEq(staleSubject.balanceOf(DEAD), 0, "a checkpoint-graduated auction retired nothing");
    }

    // ------------------------------------------------------------------ ESC-004

    /// @notice ESC-004: failure accepts only this launch's own auction and retires what the strategy
    ///         delivered from it.
    function test_ESC_004_FailureRetiresTheDeliveredAuctionAllocation() public {
        (MockERC20 launchSubject, ConditionalVestingEscrowV2 escrow) = _newLaunch();
        MockAuction auction = new MockAuction(address(launchSubject), strategy);

        // The three contributors, each asserted before resolution.
        assertEq(launchSubject.balanceOf(address(escrow)), PENDING_ALLOCATION, "65B from initialization");
        launchSubject.transfer(address(escrow), AUCTION_ALLOCATION + RESERVE_ALLOCATION);
        assertEq(
            launchSubject.balanceOf(address(escrow)), TOTAL_SUPPLY, "65B plus the strategy's swept 20B and isolated 15B"
        );

        // An auction selling another token, or naming another unsold-token recipient, is refused
        // before anything happens.
        MockAuction foreign = new MockAuction(address(usdc), strategy);
        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(ConditionalVestingEscrowV2.AuctionTokenMismatch.selector, address(usdc)));
        escrow.resolveFailure(address(foreign));

        MockAuction misdirected = new MockAuction(address(launchSubject), address(escrow));
        vm.prank(strategy);
        vm.expectRevert(
            abi.encodeWithSelector(ConditionalVestingEscrowV2.AuctionRecipientMismatch.selector, address(escrow))
        );
        escrow.resolveFailure(address(misdirected));

        assertEq(foreign.checkpointCalls(), 0, "a substituted auction is never even checkpointed");
        assertEq(misdirected.checkpointCalls(), 0, "nor is a misdirected one");
        assertEq(uint256(escrow.lifecycle()), uint256(ConditionalVestingEscrowV2.Lifecycle.Pending), "still unresolved");

        vm.expectEmit(true, true, true, true, address(escrow));
        emit ConditionalVestingEscrowV2.LaunchFailed(address(auction), TOTAL_SUPPLY);
        vm.prank(strategy);
        escrow.resolveFailure(address(auction));

        assertEq(auction.checkpointCalls(), 1, "checkpointed exactly once before reading graduation");
        assertEq(launchSubject.balanceOf(DEAD), TOTAL_SUPPLY, "65B + 20B + 15B retired");
        assertEq(uint256(escrow.lifecycle()), uint256(ConditionalVestingEscrowV2.Lifecycle.Failed), "failed");
    }

    // ------------------------------------------------------------------ ESC-005

    /// @notice ESC-005: failure proves exactly 100B before retiring, and blocks anything else.
    function test_ESC_005_FailureProvesFullSupplyBeforeRetiring() public {
        // Short inventory: the strategy's 15% never arrived.
        (MockERC20 shortSubject, ConditionalVestingEscrowV2 shortEscrow) = _newLaunch();
        MockAuction shortAuction = new MockAuction(address(shortSubject), strategy);
        shortSubject.transfer(address(shortEscrow), AUCTION_ALLOCATION);

        vm.prank(strategy);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV2.InexactFinalInventory.selector, PENDING_ALLOCATION + AUCTION_ALLOCATION
            )
        );
        shortEscrow.resolveFailure(address(shortAuction));
        assertEq(shortSubject.balanceOf(DEAD), 0, "nothing retired");
        assertEq(
            uint256(shortEscrow.lifecycle()), uint256(ConditionalVestingEscrowV2.Lifecycle.Pending), "still pending"
        );

        // Long inventory: one unit more than the whole supply.
        (MockERC20 longSubject, ConditionalVestingEscrowV2 longEscrow) = _newLaunch();
        MockAuction longAuction = new MockAuction(address(longSubject), strategy);
        longSubject.transfer(address(longEscrow), AUCTION_ALLOCATION + RESERVE_ALLOCATION);
        longSubject.mint(address(longEscrow), 1);

        vm.prank(strategy);
        vm.expectRevert(
            abi.encodeWithSelector(ConditionalVestingEscrowV2.InexactFinalInventory.selector, TOTAL_SUPPLY + 1)
        );
        longEscrow.resolveFailure(address(longAuction));
        assertEq(longSubject.balanceOf(DEAD), 0, "nothing retired");

        // Exact inventory retires the whole supply, to the unit.
        (MockERC20 exactSubject, ConditionalVestingEscrowV2 exactEscrow,) = _failedLaunch();
        assertEq(exactSubject.balanceOf(DEAD), TOTAL_SUPPLY, "dead-address delta equals the whole supply");
        assertEq(exactSubject.balanceOf(address(exactEscrow)), 0, "escrow retains nothing");
    }

    // ------------------------------------------------------------------ ESC-006

    /// @notice ESC-006: late SUBJECT is retired to the dead address and never reopens the launch.
    function test_ESC_006_LateFailedSubjectIsRetiredWithoutReopening() public {
        (MockERC20 launchSubject, ConditionalVestingEscrowV2 escrow,) = _failedLaunch();

        // With nothing late, retirement is an exact no-op rather than a revert.
        escrow.retireLateFailedSubject();
        assertEq(launchSubject.balanceOf(DEAD), TOTAL_SUPPLY, "no double retirement");

        launchSubject.mint(address(escrow), 7e18);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit ConditionalVestingEscrowV2.LateFailedSubjectRetired(7e18);
        vm.prank(outsider);
        escrow.retireLateFailedSubject();

        assertEq(launchSubject.balanceOf(address(escrow)), 0, "late SUBJECT left escrow");
        assertEq(launchSubject.balanceOf(DEAD), TOTAL_SUPPLY + 7e18, "late SUBJECT reached the dead address");
        assertEq(uint256(escrow.lifecycle()), uint256(ConditionalVestingEscrowV2.Lifecycle.Failed), "still failed");
        assertEq(escrow.vestingStart(), 0, "no vesting was opened");

        // The path exists only in the failed terminal state.
        (, ConditionalVestingEscrowV2 pending) = _newLaunch();
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV2.NotFailed.selector, ConditionalVestingEscrowV2.Lifecycle.Pending
            )
        );
        pending.retireLateFailedSubject();

        (, ConditionalVestingEscrowV2 graduated,) = _graduatedLaunch();
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV2.NotFailed.selector, ConditionalVestingEscrowV2.Lifecycle.Graduated
            )
        );
        graduated.retireLateFailedSubject();
    }

    // ------------------------------------------------------------------ ESC-007

    /// @notice ESC-007: graduation starts a 365-day schedule at the graduation timestamp, over exactly
    ///         the pending allocation.
    function test_ESC_007_GraduationActivatesThreeSixtyFiveDayVesting() public {
        vm.warp(1_800_000_000);

        (MockERC20 launchSubject, ConditionalVestingEscrowV2 escrow) = _newLaunch();
        assertEq(escrow.vestingStart(), 0, "no schedule before activation");

        vm.expectEmit(true, true, true, true, address(escrow));
        emit ConditionalVestingEscrowV2.VestingActivated(uint64(1_800_000_000), 365 days);
        vm.prank(strategy);
        escrow.activateVesting();

        assertEq(escrow.vestingStart(), 1_800_000_000, "start is the graduation timestamp");
        assertEq(escrow.VESTING_DURATION(), 365 days, "duration is exactly 365 days");
        assertEq(uint256(escrow.lifecycle()), uint256(ConditionalVestingEscrowV2.Lifecycle.Graduated), "graduated");
        assertEq(launchSubject.balanceOf(address(escrow)), PENDING_ALLOCATION, "vesting holds exactly the 65B");
    }

    // ------------------------------------------------------------------ ESC-008

    /// @notice ESC-008: escrow moves custody nowhere outside its two resolutions, even under reentrancy.
    function test_ESC_008_EscrowHoldsNoCustodyAuthorityOutsideResolution() public {
        (MockERC20 launchSubject, ConditionalVestingEscrowV2 escrow) = _newLaunch();

        // While pending, no caller and no surface can move custody.
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV2.NotGraduated.selector, ConditionalVestingEscrowV2.Lifecycle.Pending
            )
        );
        escrow.release();
        assertFalse(_callSucceeds(address(escrow), abi.encodeWithSignature("rescue(address,uint256)", address(0), 1)));
        assertFalse(_callSucceeds(address(escrow), abi.encodeWithSignature("sweep(address)", address(0))));
        assertFalse(_callSucceeds(address(escrow), abi.encodeWithSignature("recoverForcedETH(uint256)", uint256(1))));
        assertEq(launchSubject.balanceOf(address(escrow)), PENDING_ALLOCATION, "custody untouched");

        // A re-entrant SUBJECT token cannot make the release path pay twice.
        (MockERC20 vestingSubject, ConditionalVestingEscrowV2 vesting,) = _graduatedLaunch();
        vm.warp(block.timestamp + 365 days);
        vestingSubject.setReentry(address(vesting), abi.encodeCall(ConditionalVestingEscrowV2.release, ()));

        vesting.release();

        assertEq(vestingSubject.reentryAttempts(), 1, "the token did try to re-enter");
        assertFalse(vestingSubject.lastReentrySucceeded(), "the re-entrant release was rejected");
        assertEq(vestingSubject.balanceOf(treasury), PENDING_ALLOCATION, "paid exactly once");
        assertEq(vestingSubject.balanceOf(address(vesting)), 0, "no extra custody left or moved");

        // A re-entrant auction cannot resolve the same launch twice from inside its own checkpoint.
        (MockERC20 failSubject, ConditionalVestingEscrowV2 failing) = _newLaunch();
        MockAuction auction = new MockAuction(address(failSubject), strategy);
        failSubject.transfer(address(failing), AUCTION_ALLOCATION + RESERVE_ALLOCATION);
        auction.setReentry(
            address(failing), abi.encodeCall(ConditionalVestingEscrowV2.resolveFailure, (address(auction)))
        );

        vm.prank(strategy);
        failing.resolveFailure(address(auction));

        assertFalse(auction.lastReentrySucceeded(), "the re-entrant resolution was rejected");
        assertEq(failSubject.balanceOf(DEAD), TOTAL_SUPPLY, "exactly one retirement");
    }

    // ------------------------------------------------------------------ ESC-009

    /// @notice ESC-009: pending custody is exactly 65% of the 100B supply, to the unit.
    function test_ESC_009_PendingCustodyIsExactlySixtyFivePercent() public {
        MockERC20 launchSubject = new MockERC20("Subject", "SUBJ", 18);
        launchSubject.mint(address(this), TOTAL_SUPPLY);
        uint256 funderBefore = launchSubject.balanceOf(address(this));

        ConditionalVestingEscrowV2 escrow = ConditionalVestingEscrowV2(LibClone.clone(address(escrowImplementation)));
        launchSubject.approve(address(escrow), PENDING_ALLOCATION);
        escrow.initialize(address(launchSubject), treasury, strategy);

        assertEq(escrow.PENDING_ALLOCATION(), (TOTAL_SUPPLY * 65) / 100, "65% of the frozen supply");
        assertEq(launchSubject.balanceOf(address(escrow)), PENDING_ALLOCATION, "exact custody");
        assertEq(funderBefore - launchSubject.balanceOf(address(this)), PENDING_ALLOCATION, "exact funder delta");
        assertEq(launchSubject.allowance(address(this), address(escrow)), 0, "the allowance was consumed exactly");

        // A token that delivers less than it is asked to move cannot fund a launch.
        MockERC20 lossy = new MockERC20("Lossy", "LOSS", 18);
        lossy.mint(address(this), TOTAL_SUPPLY);
        lossy.setFeeBps(1);
        ConditionalVestingEscrowV2 blocked = ConditionalVestingEscrowV2(LibClone.clone(address(escrowImplementation)));
        lossy.approve(address(blocked), PENDING_ALLOCATION);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV2.InexactTransfer.selector,
                PENDING_ALLOCATION,
                PENDING_ALLOCATION - PENDING_ALLOCATION / 10_000
            )
        );
        blocked.initialize(address(lossy), treasury, strategy);
    }

    // ------------------------------------------------------------------ ESC-010

    /// @notice ESC-010: nothing releases pending custody before resolution.
    function test_ESC_010_PendingCustodyCannotBeReleasedBeforeResolution() public {
        (MockERC20 launchSubject, ConditionalVestingEscrowV2 escrow) = _newLaunch();

        address[4] memory callers = [address(this), strategy, treasury, outsider];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ConditionalVestingEscrowV2.NotGraduated.selector, ConditionalVestingEscrowV2.Lifecycle.Pending
                )
            );
            escrow.release();
        }

        // Time alone opens nothing while the launch is pending.
        vm.warp(block.timestamp + 3650 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV2.NotGraduated.selector, ConditionalVestingEscrowV2.Lifecycle.Pending
            )
        );
        escrow.release();

        assertEq(launchSubject.balanceOf(address(escrow)), PENDING_ALLOCATION, "custody intact");
        assertEq(launchSubject.balanceOf(treasury), 0, "treasury received nothing");
        assertEq(escrow.totalReleased(), 0, "nothing recorded as released");
    }

    // ------------------------------------------------------------------ ESC-011

    /// @notice ESC-011: only the bound strategy resolves a launch.
    function test_ESC_011_OnlyTheStrategyResolvesALaunch() public {
        (MockERC20 launchSubject, ConditionalVestingEscrowV2 escrow) = _newLaunch();
        MockAuction auction = new MockAuction(address(launchSubject), strategy);
        launchSubject.transfer(address(escrow), AUCTION_ALLOCATION + RESERVE_ALLOCATION);

        address[3] memory callers = [address(this), treasury, outsider];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(ConditionalVestingEscrowV2.NotStrategy.selector, callers[i]));
            escrow.resolveFailure(address(auction));
            vm.expectRevert(abi.encodeWithSelector(ConditionalVestingEscrowV2.NotStrategy.selector, callers[i]));
            escrow.activateVesting();
            vm.stopPrank();
        }

        assertEq(uint256(escrow.lifecycle()), uint256(ConditionalVestingEscrowV2.Lifecycle.Pending), "still pending");
        assertEq(launchSubject.balanceOf(address(escrow)), TOTAL_SUPPLY, "custody untouched");

        // The bound strategy, and only it, resolves.
        vm.prank(strategy);
        escrow.resolveFailure(address(auction));
        assertEq(
            uint256(escrow.lifecycle()), uint256(ConditionalVestingEscrowV2.Lifecycle.Failed), "the strategy resolved"
        );
    }

    // ------------------------------------------------------------------ ESC-012

    /// @notice ESC-012: vesting is exactly linear over 365 days, including for later arrivals.
    function test_ESC_012_VestingReleasesLinearlyOverThreeSixtyFiveDays() public {
        (MockERC20 launchSubject, ConditionalVestingEscrowV2 escrow,) = _graduatedLaunch();
        uint256 start = escrow.vestingStart();
        uint256 duration = escrow.VESTING_DURATION();

        // Nothing is releasable at the start.
        escrow.release();
        assertEq(launchSubject.balanceOf(treasury), 0, "nothing vested at the start");

        vm.warp(start + duration / 4);
        escrow.release();
        assertEq(launchSubject.balanceOf(treasury), PENDING_ALLOCATION / 4, "one quarter vested");

        vm.warp(start + duration / 2);
        escrow.release();
        assertEq(launchSubject.balanceOf(treasury), PENDING_ALLOCATION / 2, "one half vested");

        vm.warp(start + duration);
        escrow.release();
        assertEq(launchSubject.balanceOf(treasury), PENDING_ALLOCATION, "everything vested at 365 days");
        assertEq(launchSubject.balanceOf(address(escrow)), 0, "escrow drained");

        // Past the end, repeated calls cannot over-release.
        vm.warp(start + duration + 30 days);
        escrow.release();
        assertEq(launchSubject.balanceOf(treasury), PENDING_ALLOCATION, "no over-release");
        assertEq(escrow.totalReleased(), PENDING_ALLOCATION, "released total is exact");

        // SUBJECT donated after graduation joins the same original schedule.
        (MockERC20 donatedSubject, ConditionalVestingEscrowV2 donated,) = _graduatedLaunch();
        uint256 donatedStart = donated.vestingStart();
        vm.warp(donatedStart + duration / 2);
        donatedSubject.mint(address(donated), 1_000e18);
        donated.release();
        assertEq(
            donatedSubject.balanceOf(treasury),
            (PENDING_ALLOCATION + 1_000e18) / 2,
            "the donation vests in proportion to elapsed time"
        );

        vm.warp(donatedStart + duration);
        donated.release();
        assertEq(
            donatedSubject.balanceOf(treasury), PENDING_ALLOCATION + 1_000e18, "fully releasable at or after day 365"
        );
    }

    // ------------------------------------------------------------------ ESC-013

    /// @notice ESC-013: the vesting beneficiary is the fixed treasury and can never be redirected.
    function test_ESC_013_VestingBeneficiaryIsTheFixedImmutableTreasury() public {
        (MockERC20 launchSubject, ConditionalVestingEscrowV2 escrow,) = _graduatedLaunch();
        assertEq(escrow.treasury(), treasury, "bound at initialization");

        // No surface exists to move the beneficiary, from any caller.
        bytes[3] memory attempts = [
            abi.encodeWithSignature("setTreasury(address)", outsider),
            abi.encodeWithSignature("setBeneficiary(address)", outsider),
            abi.encodeWithSignature("release(address)", outsider)
        ];
        for (uint256 i; i < attempts.length; ++i) {
            vm.prank(outsider);
            assertFalse(_callSucceeds(address(escrow), attempts[i]), "no redirect surface exists");
        }

        // Anyone may trigger the release, but only the treasury is ever paid.
        vm.warp(block.timestamp + 365 days);
        vm.prank(outsider);
        escrow.release();

        assertEq(escrow.treasury(), treasury, "still the same treasury");
        assertEq(launchSubject.balanceOf(treasury), PENDING_ALLOCATION, "treasury received everything");
        assertEq(launchSubject.balanceOf(outsider), 0, "the caller received nothing");
    }

    // ------------------------------------------------------------------ helpers

    function _expectInitRevert(bytes4 expected, address subject_, address treasury_, address strategy_) private {
        ConditionalVestingEscrowV2 fresh = ConditionalVestingEscrowV2(LibClone.clone(address(escrowImplementation)));
        vm.expectRevert(expected);
        fresh.initialize(subject_, treasury_, strategy_);
    }

    function _callSucceeds(address target, bytes memory data) private returns (bool ok) {
        (ok,) = target.call(data);
    }
}
