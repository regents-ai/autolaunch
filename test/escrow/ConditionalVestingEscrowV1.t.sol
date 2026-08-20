// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {C1Fixture} from "../mocks/C1Fixture.sol";
import {MockAuction} from "../mocks/MockAuction.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../../src/escrow/ConditionalVestingEscrowV1.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

/// @notice Claim-level proof for `ConditionalVestingEscrowV1`.
/// @dev Every selector below drives the production escrow directly. Only the SUBJECT token, the CCA
///      auction, and the calling account are mocked, which is exactly the C1 boundary.
contract ConditionalVestingEscrowV1Test is C1Fixture {
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
        ConditionalVestingEscrowV1 escrow = ConditionalVestingEscrowV1(LibClone.clone(address(escrowImplementation)));
        assertEq(escrow.subject(), address(0), "unbound before initialization");
        launchSubject.approve(address(escrow), PENDING_ALLOCATION);
        escrow.initialize(address(launchSubject), treasury, strategy);

        assertEq(escrow.subject(), address(launchSubject), "subject bound");
        assertEq(escrow.treasury(), treasury, "treasury bound");
        assertEq(escrow.strategy(), strategy, "strategy bound");
        assertEq(uint256(escrow.lifecycle()), uint256(ConditionalVestingEscrowV1.Lifecycle.Pending), "pending");
        assertEq(launchSubject.balanceOf(address(escrow)), PENDING_ALLOCATION, "custody taken atomically");

        // A second initialization is impossible, from any caller.
        launchSubject.approve(address(escrow), PENDING_ALLOCATION);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrow.initialize(address(launchSubject), treasury, strategy);
        vm.prank(outsider);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrow.initialize(address(launchSubject), outsider, outsider);

        // Zero bindings are rejected.
        _expectInitRevert(ConditionalVestingEscrowV1.ZeroAddress.selector, address(0), treasury, strategy);
        _expectInitRevert(ConditionalVestingEscrowV1.ZeroAddress.selector, address(launchSubject), address(0), strategy);
        _expectInitRevert(ConditionalVestingEscrowV1.ZeroAddress.selector, address(launchSubject), treasury, address(0));

        // Self bindings, which would trap value in the clone, are rejected.
        ConditionalVestingEscrowV1 fresh = ConditionalVestingEscrowV1(LibClone.clone(address(escrowImplementation)));
        vm.expectRevert(ConditionalVestingEscrowV1.SelfAddress.selector);
        fresh.initialize(address(fresh), treasury, strategy);
        vm.expectRevert(ConditionalVestingEscrowV1.SelfAddress.selector);
        fresh.initialize(address(launchSubject), address(fresh), strategy);
        vm.expectRevert(ConditionalVestingEscrowV1.SelfAddress.selector);
        fresh.initialize(address(launchSubject), treasury, address(fresh));

        // A token that is not a 100B 18-decimal launch supply is rejected.
        MockERC20 wrongSupply = new MockERC20("Wrong", "WRG", 18);
        wrongSupply.mint(address(this), TOTAL_SUPPLY - 1);
        wrongSupply.approve(address(fresh), PENDING_ALLOCATION);
        vm.expectRevert(
            abi.encodeWithSelector(ConditionalVestingEscrowV1.InvalidSubjectSupply.selector, TOTAL_SUPPLY - 1)
        );
        fresh.initialize(address(wrongSupply), treasury, strategy);
    }

    // ------------------------------------------------------------------ ESC-002

    /// @notice ESC-002: a launch resolves once, and graduation and failure are mutually exclusive.
    function test_ESC_002_ResolutionHappensExactlyOnceAndIsExclusive() public {
        (, ConditionalVestingEscrowV1 graduated, MockAuction graduatedAuction) = _graduatedLaunch(0);

        vm.startPrank(strategy);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.NotPending.selector, ConditionalVestingEscrowV1.Lifecycle.Graduated
            )
        );
        graduated.resolveFailure(address(graduatedAuction));
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.NotPending.selector, ConditionalVestingEscrowV1.Lifecycle.Graduated
            )
        );
        graduated.activateVesting();
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.NotPending.selector, ConditionalVestingEscrowV1.Lifecycle.Graduated
            )
        );
        graduated.sweepGraduatedUnsoldSubject(address(graduatedAuction));
        vm.stopPrank();

        (, ConditionalVestingEscrowV1 failed, MockAuction failedAuction) = _failedLaunch();
        uint256 deadAfterFailure = MockERC20(failed.subject()).balanceOf(DEAD);

        vm.startPrank(strategy);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.NotPending.selector, ConditionalVestingEscrowV1.Lifecycle.Failed
            )
        );
        failed.resolveFailure(address(failedAuction));
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.NotPending.selector, ConditionalVestingEscrowV1.Lifecycle.Failed
            )
        );
        failed.activateVesting();
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.NotPending.selector, ConditionalVestingEscrowV1.Lifecycle.Failed
            )
        );
        failed.sweepGraduatedUnsoldSubject(address(failedAuction));
        vm.stopPrank();

        assertEq(MockERC20(failed.subject()).balanceOf(DEAD), deadAfterFailure, "no further retirement");
        assertEq(uint256(failed.lifecycle()), uint256(ConditionalVestingEscrowV1.Lifecycle.Failed), "still failed");

        // The two paths are exclusive at the auction as well as at the escrow: a launch whose
        // auction graduated can never be retired as a failure, even while it is still pending.
        (MockERC20 liveSubject, ConditionalVestingEscrowV1 live) = _newLaunch();
        MockAuction liveAuction = new MockAuction(address(liveSubject), address(live));
        liveSubject.transfer(address(liveAuction), AUCTION_ALLOCATION);
        liveSubject.transfer(address(live), RESERVE_ALLOCATION);
        liveAuction.setGraduated(true);

        vm.prank(strategy);
        vm.expectRevert(ConditionalVestingEscrowV1.AuctionIsGraduated.selector);
        live.resolveFailure(address(liveAuction));

        assertEq(uint256(live.lifecycle()), uint256(ConditionalVestingEscrowV1.Lifecycle.Pending), "still pending");
        assertEq(liveSubject.balanceOf(DEAD), 0, "the refused failure retired nothing");
        assertFalse(liveAuction.swept(), "and never reached the failure sweep");
    }

    // ------------------------------------------------------------------ ESC-004

    /// @notice ESC-004: failure sweeps the failed auction's whole 10% back into escrow.
    function test_ESC_004_FailureSweepsTheFailedAuctionAllocation() public {
        (MockERC20 launchSubject, ConditionalVestingEscrowV1 escrow) = _newLaunch();
        MockAuction auction = new MockAuction(address(launchSubject), address(escrow));

        // The three contributors, each asserted independently before resolution.
        assertEq(launchSubject.balanceOf(address(escrow)), PENDING_ALLOCATION, "85B from initialization");
        launchSubject.transfer(address(auction), AUCTION_ALLOCATION);
        assertEq(launchSubject.balanceOf(address(auction)), AUCTION_ALLOCATION, "10B held by the auction");
        launchSubject.transfer(address(escrow), RESERVE_ALLOCATION);
        assertEq(
            launchSubject.balanceOf(address(escrow)),
            PENDING_ALLOCATION + RESERVE_ALLOCATION,
            "85B plus the strategy's isolated 5B"
        );

        // The failure sweep reaches only this launch's own auction. An auction selling another
        // token, or naming another unsold-token recipient, is refused before anything happens.
        MockAuction foreign = new MockAuction(address(usdc), address(escrow));
        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(ConditionalVestingEscrowV1.AuctionTokenMismatch.selector, address(usdc)));
        escrow.resolveFailure(address(foreign));

        MockAuction misdirected = new MockAuction(address(launchSubject), outsider);
        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(ConditionalVestingEscrowV1.AuctionRecipientMismatch.selector, outsider));
        escrow.resolveFailure(address(misdirected));

        assertEq(foreign.checkpointCalls(), 0, "a substituted auction is never even checkpointed");
        assertEq(misdirected.checkpointCalls(), 0, "nor is a misdirected one");
        assertEq(uint256(escrow.lifecycle()), uint256(ConditionalVestingEscrowV1.Lifecycle.Pending), "still unresolved");

        vm.prank(strategy);
        escrow.resolveFailure(address(auction));

        // A failed auction returns its entire inventory: no bidder can hold SUBJECT.
        assertEq(launchSubject.balanceOf(address(auction)), 0, "auction fully returned its 10B");
        assertTrue(auction.swept(), "sweep ran");
        assertEq(auction.checkpointCalls(), 1, "checkpointed exactly once before the sweep");
        assertEq(launchSubject.balanceOf(DEAD), TOTAL_SUPPLY, "85B + 5B + 10B retired");
    }

    // ------------------------------------------------------------------ ESC-005

    /// @notice ESC-005: failure proves exactly 100B before retiring, and blocks anything else.
    function test_ESC_005_FailureProvesFullSupplyBeforeRetiring() public {
        // Short inventory: the strategy's 5% never arrived.
        (MockERC20 shortSubject, ConditionalVestingEscrowV1 shortEscrow) = _newLaunch();
        MockAuction shortAuction = new MockAuction(address(shortSubject), address(shortEscrow));
        shortSubject.transfer(address(shortAuction), AUCTION_ALLOCATION);

        vm.prank(strategy);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.InexactFinalInventory.selector, PENDING_ALLOCATION + AUCTION_ALLOCATION
            )
        );
        shortEscrow.resolveFailure(address(shortAuction));
        assertEq(shortSubject.balanceOf(DEAD), 0, "nothing retired");
        assertEq(
            uint256(shortEscrow.lifecycle()), uint256(ConditionalVestingEscrowV1.Lifecycle.Pending), "still pending"
        );

        // Long inventory: one unit more than the whole supply.
        (MockERC20 longSubject, ConditionalVestingEscrowV1 longEscrow) = _newLaunch();
        MockAuction longAuction = new MockAuction(address(longSubject), address(longEscrow));
        longSubject.transfer(address(longAuction), AUCTION_ALLOCATION);
        longSubject.transfer(address(longEscrow), RESERVE_ALLOCATION);
        longSubject.mint(address(longEscrow), 1);

        vm.prank(strategy);
        vm.expectRevert(
            abi.encodeWithSelector(ConditionalVestingEscrowV1.InexactFinalInventory.selector, TOTAL_SUPPLY + 1)
        );
        longEscrow.resolveFailure(address(longAuction));
        assertEq(longSubject.balanceOf(DEAD), 0, "nothing retired");

        // Exact inventory retires the whole supply, to the unit.
        (MockERC20 exactSubject, ConditionalVestingEscrowV1 exactEscrow, MockAuction exactAuction) = _failedLaunch();
        assertEq(exactSubject.balanceOf(DEAD), TOTAL_SUPPLY, "dead-address delta equals the whole supply");
        assertEq(exactSubject.balanceOf(address(exactEscrow)), 0, "escrow retains nothing");
        assertEq(exactSubject.balanceOf(address(exactAuction)), 0, "auction retains nothing");
    }

    // ------------------------------------------------------------------ ESC-006

    /// @notice ESC-006: late SUBJECT is retired to the dead address and never reopens the launch.
    function test_ESC_006_LateFailedSubjectIsRetiredWithoutReopening() public {
        (MockERC20 launchSubject, ConditionalVestingEscrowV1 escrow,) = _failedLaunch();

        // With nothing late, retirement is an exact no-op rather than a revert.
        escrow.retireLateFailedSubject();
        assertEq(launchSubject.balanceOf(DEAD), TOTAL_SUPPLY, "no double retirement");

        launchSubject.mint(address(escrow), 7e18);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit ConditionalVestingEscrowV1.LateFailedSubjectRetired(7e18);
        vm.prank(outsider);
        escrow.retireLateFailedSubject();

        assertEq(launchSubject.balanceOf(address(escrow)), 0, "late SUBJECT left escrow");
        assertEq(launchSubject.balanceOf(DEAD), TOTAL_SUPPLY + 7e18, "late SUBJECT reached the dead address");
        assertEq(uint256(escrow.lifecycle()), uint256(ConditionalVestingEscrowV1.Lifecycle.Failed), "still failed");
        assertEq(escrow.vestingStart(), 0, "no vesting was opened");

        // The path exists only in the failed terminal state.
        (, ConditionalVestingEscrowV1 pending) = _newLaunch();
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.NotFailed.selector, ConditionalVestingEscrowV1.Lifecycle.Pending
            )
        );
        pending.retireLateFailedSubject();

        (, ConditionalVestingEscrowV1 graduated,) = _graduatedLaunch(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.NotFailed.selector, ConditionalVestingEscrowV1.Lifecycle.Graduated
            )
        );
        graduated.retireLateFailedSubject();
    }

    // ------------------------------------------------------------------ ESC-007

    /// @notice ESC-007: graduation starts a 365-day schedule at the graduation timestamp.
    function test_ESC_007_GraduationActivatesThreeSixtyFiveDayVesting() public {
        vm.warp(1_800_000_000);

        (MockERC20 launchSubject, ConditionalVestingEscrowV1 escrow) = _newLaunch();
        MockAuction auction = new MockAuction(address(launchSubject), address(escrow));
        launchSubject.transfer(address(auction), AUCTION_ALLOCATION);
        auction.setGraduated(true);
        auction.setRemainingSupply(0);

        vm.prank(strategy);
        escrow.sweepGraduatedUnsoldSubject(address(auction));

        assertEq(escrow.vestingStart(), 0, "no schedule before activation");

        vm.expectEmit(true, true, true, true, address(escrow));
        emit ConditionalVestingEscrowV1.VestingActivated(uint64(1_800_000_000), 365 days);
        vm.prank(strategy);
        escrow.activateVesting();

        assertEq(escrow.vestingStart(), 1_800_000_000, "start is the graduation timestamp");
        assertEq(escrow.VESTING_DURATION(), 365 days, "duration is exactly 365 days");
        assertEq(uint256(escrow.lifecycle()), uint256(ConditionalVestingEscrowV1.Lifecycle.Graduated), "graduated");
    }

    // ------------------------------------------------------------------ ESC-008

    /// @notice ESC-008: escrow moves custody nowhere outside its two resolutions, even under reentrancy.
    function test_ESC_008_EscrowHoldsNoCustodyAuthorityOutsideResolution() public {
        (MockERC20 launchSubject, ConditionalVestingEscrowV1 escrow) = _newLaunch();

        // While pending, no caller and no surface can move custody.
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.NotGraduated.selector, ConditionalVestingEscrowV1.Lifecycle.Pending
            )
        );
        escrow.release();
        assertFalse(_callSucceeds(address(escrow), abi.encodeWithSignature("rescue(address,uint256)", address(0), 1)));
        assertFalse(_callSucceeds(address(escrow), abi.encodeWithSignature("sweep(address)", address(0))));
        assertFalse(_callSucceeds(address(escrow), abi.encodeWithSignature("recoverForcedETH(uint256)", uint256(1))));
        assertEq(launchSubject.balanceOf(address(escrow)), PENDING_ALLOCATION, "custody untouched");

        // A re-entrant SUBJECT token cannot make the release path pay twice.
        (MockERC20 vestingSubject, ConditionalVestingEscrowV1 vesting,) = _graduatedLaunch(0);
        vm.warp(block.timestamp + 365 days);
        vestingSubject.setReentry(address(vesting), abi.encodeCall(ConditionalVestingEscrowV1.release, ()));

        vesting.release();

        assertEq(vestingSubject.reentryAttempts(), 1, "the token did try to re-enter");
        assertFalse(vestingSubject.lastReentrySucceeded(), "the re-entrant release was rejected");
        assertEq(vestingSubject.balanceOf(treasury), PENDING_ALLOCATION, "paid exactly once");
        assertEq(vestingSubject.balanceOf(address(vesting)), 0, "no extra custody left or moved");

        // A re-entrant auction cannot resolve the same launch twice from inside its own sweep.
        (MockERC20 failSubject, ConditionalVestingEscrowV1 failing) = _newLaunch();
        MockAuction auction = new MockAuction(address(failSubject), address(failing));
        failSubject.transfer(address(auction), AUCTION_ALLOCATION);
        failSubject.transfer(address(failing), RESERVE_ALLOCATION);
        auction.setReentry(
            address(failing), abi.encodeCall(ConditionalVestingEscrowV1.resolveFailure, (address(auction)))
        );

        vm.prank(strategy);
        failing.resolveFailure(address(auction));

        assertFalse(auction.lastReentrySucceeded(), "the re-entrant resolution was rejected");
        assertEq(failSubject.balanceOf(DEAD), TOTAL_SUPPLY, "exactly one retirement");
    }

    // ------------------------------------------------------------------ ESC-009

    /// @notice ESC-009: pending custody is exactly 85% of the 100B supply, to the unit.
    function test_ESC_009_PendingCustodyIsExactlyEightyFivePercent() public {
        MockERC20 launchSubject = new MockERC20("Subject", "SUBJ", 18);
        launchSubject.mint(address(this), TOTAL_SUPPLY);
        uint256 funderBefore = launchSubject.balanceOf(address(this));

        ConditionalVestingEscrowV1 escrow = ConditionalVestingEscrowV1(LibClone.clone(address(escrowImplementation)));
        launchSubject.approve(address(escrow), PENDING_ALLOCATION);
        escrow.initialize(address(launchSubject), treasury, strategy);

        assertEq(escrow.PENDING_ALLOCATION(), (TOTAL_SUPPLY * 85) / 100, "85% of the frozen supply");
        assertEq(launchSubject.balanceOf(address(escrow)), PENDING_ALLOCATION, "exact custody");
        assertEq(funderBefore - launchSubject.balanceOf(address(this)), PENDING_ALLOCATION, "exact funder delta");
        assertEq(launchSubject.allowance(address(this), address(escrow)), 0, "the allowance was consumed exactly");

        // A token that delivers less than it is asked to move cannot fund a launch.
        MockERC20 lossy = new MockERC20("Lossy", "LOSS", 18);
        lossy.mint(address(this), TOTAL_SUPPLY);
        lossy.setFeeBps(1);
        ConditionalVestingEscrowV1 blocked = ConditionalVestingEscrowV1(LibClone.clone(address(escrowImplementation)));
        lossy.approve(address(blocked), PENDING_ALLOCATION);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.InexactTransfer.selector,
                PENDING_ALLOCATION,
                PENDING_ALLOCATION - PENDING_ALLOCATION / 10_000
            )
        );
        blocked.initialize(address(lossy), treasury, strategy);
    }

    // ------------------------------------------------------------------ ESC-010

    /// @notice ESC-010: nothing releases pending custody before resolution.
    function test_ESC_010_PendingCustodyCannotBeReleasedBeforeResolution() public {
        (MockERC20 launchSubject, ConditionalVestingEscrowV1 escrow) = _newLaunch();

        address[4] memory callers = [address(this), strategy, treasury, outsider];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ConditionalVestingEscrowV1.NotGraduated.selector, ConditionalVestingEscrowV1.Lifecycle.Pending
                )
            );
            escrow.release();
        }

        // Time alone opens nothing while the launch is pending.
        vm.warp(block.timestamp + 3650 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConditionalVestingEscrowV1.NotGraduated.selector, ConditionalVestingEscrowV1.Lifecycle.Pending
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
        (MockERC20 launchSubject, ConditionalVestingEscrowV1 escrow) = _newLaunch();
        MockAuction auction = new MockAuction(address(launchSubject), address(escrow));
        launchSubject.transfer(address(auction), AUCTION_ALLOCATION);
        launchSubject.transfer(address(escrow), RESERVE_ALLOCATION);
        auction.setGraduated(true);

        address[3] memory callers = [address(this), treasury, outsider];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(ConditionalVestingEscrowV1.NotStrategy.selector, callers[i]));
            escrow.resolveFailure(address(auction));
            vm.expectRevert(abi.encodeWithSelector(ConditionalVestingEscrowV1.NotStrategy.selector, callers[i]));
            escrow.sweepGraduatedUnsoldSubject(address(auction));
            vm.expectRevert(abi.encodeWithSelector(ConditionalVestingEscrowV1.NotStrategy.selector, callers[i]));
            escrow.activateVesting();
            vm.stopPrank();
        }

        assertEq(uint256(escrow.lifecycle()), uint256(ConditionalVestingEscrowV1.Lifecycle.Pending), "still pending");
        assertEq(launchSubject.balanceOf(address(escrow)), PENDING_ALLOCATION + RESERVE_ALLOCATION, "custody untouched");

        // The bound strategy, and only it, resolves.
        vm.prank(strategy);
        escrow.sweepGraduatedUnsoldSubject(address(auction));
        assertTrue(escrow.graduatedSweepDone(), "the strategy resolved");
    }

    // ------------------------------------------------------------------ ESC-012

    /// @notice ESC-012: vesting is exactly linear over 365 days, including for later arrivals.
    function test_ESC_012_VestingReleasesLinearlyOverThreeSixtyFiveDays() public {
        (MockERC20 launchSubject, ConditionalVestingEscrowV1 escrow,) = _graduatedLaunch(0);
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
        (MockERC20 donatedSubject, ConditionalVestingEscrowV1 donated,) = _graduatedLaunch(0);
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
        (MockERC20 launchSubject, ConditionalVestingEscrowV1 escrow,) = _graduatedLaunch(0);
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

    // ------------------------------------------------------------------ ESC-014

    /// @notice ESC-014: the strategy checkpoints and sweeps the canonical graduated auction once,
    ///         before vesting activation, and nothing else can.
    function test_ESC_014_GraduatedUnsoldSubjectIsSweptBeforeVesting() public {
        (MockERC20 launchSubject, ConditionalVestingEscrowV1 escrow) = _newLaunch();
        MockAuction auction = new MockAuction(address(launchSubject), address(escrow));
        launchSubject.transfer(address(auction), AUCTION_ALLOCATION);

        // Vesting cannot open before the sweep.
        vm.prank(strategy);
        vm.expectRevert(ConditionalVestingEscrowV1.GraduatedSweepNotDone.selector);
        escrow.activateVesting();

        // A non-graduated auction is rejected.
        vm.prank(strategy);
        vm.expectRevert(ConditionalVestingEscrowV1.AuctionIsNotGraduated.selector);
        escrow.sweepGraduatedUnsoldSubject(address(auction));

        // A foreign auction is rejected on either identity check.
        MockAuction foreign = new MockAuction(address(usdc), address(escrow));
        foreign.setGraduated(true);
        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(ConditionalVestingEscrowV1.AuctionTokenMismatch.selector, address(usdc)));
        escrow.sweepGraduatedUnsoldSubject(address(foreign));

        MockAuction misdirected = new MockAuction(address(launchSubject), outsider);
        misdirected.setGraduated(true);
        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(ConditionalVestingEscrowV1.AuctionRecipientMismatch.selector, outsider));
        escrow.sweepGraduatedUnsoldSubject(address(misdirected));

        // Graduation that is only visible after the checkpoint is still honored, because escrow
        // checkpoints before it reads.
        auction.setGraduatesOnCheckpoint(true);
        auction.setRemainingSupply(2_500_000_000e18);
        assertFalse(auction.isGraduated(), "stale pre-checkpoint state");

        vm.expectEmit(true, true, true, true, address(escrow));
        emit ConditionalVestingEscrowV1.GraduatedUnsoldSubjectSwept(address(auction), 2_500_000_000e18);
        vm.prank(strategy);
        escrow.sweepGraduatedUnsoldSubject(address(auction));

        assertEq(auction.checkpointCalls(), 1, "the committed sweep checkpointed before it read graduation");
        assertEq(
            launchSubject.balanceOf(address(escrow)),
            PENDING_ALLOCATION + 2_500_000_000e18,
            "the exact unsold delta landed"
        );
        assertTrue(escrow.graduatedSweepDone(), "recorded once");
        assertEq(
            uint256(escrow.lifecycle()), uint256(ConditionalVestingEscrowV1.Lifecycle.Pending), "no lifecycle change"
        );

        // The sweep runs exactly once and creates no retry mode.
        vm.prank(strategy);
        vm.expectRevert(ConditionalVestingEscrowV1.GraduatedSweepAlreadyDone.selector);
        escrow.sweepGraduatedUnsoldSubject(address(auction));

        // Then, and only then, vesting activates.
        vm.prank(strategy);
        escrow.activateVesting();
        assertEq(uint256(escrow.lifecycle()), uint256(ConditionalVestingEscrowV1.Lifecycle.Graduated), "graduated");

        // A sold-out auction sweeps a legitimate zero.
        (MockERC20 soldOutSubject, ConditionalVestingEscrowV1 soldOut) = _newLaunch();
        MockAuction soldOutAuction = new MockAuction(address(soldOutSubject), address(soldOut));
        soldOutAuction.setGraduated(true);
        soldOutAuction.setRemainingSupply(0);

        vm.prank(strategy);
        soldOut.sweepGraduatedUnsoldSubject(address(soldOutAuction));
        assertEq(soldOutSubject.balanceOf(address(soldOut)), PENDING_ALLOCATION, "zero unsold is exact");
        assertTrue(soldOut.graduatedSweepDone(), "the zero sweep still completes");

        // An auction that delivers less than it reported fails closed.
        (MockERC20 lyingSubject, ConditionalVestingEscrowV1 lying) = _newLaunch();
        MockAuction lyingAuction = new MockAuction(address(lyingSubject), address(lying));
        lyingSubject.transfer(address(lyingAuction), AUCTION_ALLOCATION);
        lyingAuction.setGraduated(true);
        lyingAuction.setRemainingSupply(1_000e18);
        lyingAuction.setSweepAmountOverride(1e18);

        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(ConditionalVestingEscrowV1.InexactTransfer.selector, 1_000e18, 1e18));
        lying.sweepGraduatedUnsoldSubject(address(lyingAuction));
        assertFalse(lying.graduatedSweepDone(), "the failed sweep committed nothing");
        assertEq(lyingSubject.balanceOf(address(lying)), PENDING_ALLOCATION, "custody unchanged");
    }

    // ------------------------------------------------------------------ helpers

    function _expectInitRevert(bytes4 expected, address subject_, address treasury_, address strategy_) private {
        ConditionalVestingEscrowV1 fresh = ConditionalVestingEscrowV1(LibClone.clone(address(escrowImplementation)));
        vm.expectRevert(expected);
        fresh.initialize(subject_, treasury_, strategy_);
    }

    function _callSucceeds(address target, bytes memory data) private returns (bool ok) {
        (ok,) = target.call(data);
    }
}
