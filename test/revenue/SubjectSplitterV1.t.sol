// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {C1Fixture} from "../mocks/C1Fixture.sol";
import {ForceEthSender} from "../mocks/ForceEthSender.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockLiveStaking} from "../mocks/MockLiveStaking.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/// @notice Claim-level proof for `SubjectSplitterV1`.
/// @dev Every selector drives the production splitter directly. Only the three tokens, the live
///      staking contract, and the calling account are mocked — the C1 boundary exactly. `SPL-010`
///      names the factory pause and belongs to C4; C1 proves only that no splitter path reads any
///      external lifecycle state, which every selector here exercises by never having one.
contract SubjectSplitterV1Test is C1Fixture {
    SubjectSplitterV1 internal splitter;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        _deployC1();
        splitter = _newSplitter();
    }

    // ------------------------------------------------------------------ SPL-001

    /// @notice SPL-001: exactly three recognized assets, fixed once and never widened.
    function test_SPL_001_RecognizedAssetsAreExactlyUsdcRegentAndSubject() public {
        assertEq(splitter.usdc(), address(usdc), "usdc bound");
        assertEq(splitter.regent(), address(regent), "regent bound");
        assertEq(splitter.subject(), address(subject), "subject bound");
        assertEq(splitter.liveStaking(), address(liveStaking), "live staking bound");
        assertEq(splitter.regentSafe(), regentSafe, "regent safe bound");
        assertEq(splitter.treasury(), treasury, "treasury bound");

        // A fourth asset is not revenue, is not claimable, and is not recognizable.
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(this), 1_000e18);
        other.transfer(address(splitter), 1_000e18);

        vm.expectRevert(abi.encodeWithSelector(SubjectSplitterV1.UnsupportedToken.selector, address(other)));
        splitter.depositRecognizedRevenue(address(other), 1, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(SubjectSplitterV1.UnsupportedToken.selector, address(other)));
        splitter.recognizeSurplusRevenue(address(other), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(SubjectSplitterV1.UnsupportedToken.selector, address(other)));
        splitter.claim(address(other));

        // The implementation can never hold revenue, and a clone binds exactly once.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        splitterImplementation.initialize(
            address(usdc), address(regent), address(subject), address(liveStaking), regentSafe, treasury
        );
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        splitter.initialize(
            address(usdc), address(regent), address(subject), address(liveStaking), regentSafe, treasury
        );

        // Every binding is validated before it is fixed.
        for (uint256 i; i < 6; ++i) {
            _expectInitRevert(SubjectSplitterV1.ZeroAddress.selector, i, address(0));
            _expectSelfBindingRevert(i);
        }

        // Two recognized assets can never be the same address.
        _expectInitRevert(SubjectSplitterV1.DuplicateTokenBinding.selector, 0, address(regent));
        _expectInitRevert(SubjectSplitterV1.DuplicateTokenBinding.selector, 0, address(subject));
        _expectInitRevert(SubjectSplitterV1.DuplicateTokenBinding.selector, 1, address(subject));
    }

    // ------------------------------------------------------------------ SPL-002

    /// @notice SPL-002: every recognized inflow floors a 2% skim exactly once.
    /// @dev The whole supply is staked, so coverage is complete and the entire net is the staker
    ///      allocation. That isolates the skim: nothing here is absorbed by treasury rounding.
    function test_SPL_002_EveryRecognizedInflowIsSkimmedExactlyOnce() public {
        _stake(alice, TOTAL_SUPPLY);

        MockERC20[3] memory tokens = [usdc, regent, subject];
        for (uint256 i; i < tokens.length; ++i) {
            MockERC20 token = tokens[i];
            uint256 gross = 100_000;
            uint256 skimBefore = _skimHeld(token);

            _deposit(token, gross, bytes32("once"));

            uint256 skim = (gross * 200) / 10_000;
            assertEq(_skimHeld(token) - skimBefore, skim, "exactly one 2% skim reached its destination");
            assertEq(splitter.unclaimedLiability(address(token)), gross - skim, "the whole net became liability");
            assertEq(gross, skim + (gross - skim), "gross equals skim plus net");

            // Recognizing again finds nothing: the inflow cannot be skimmed a second time.
            vm.expectRevert(SubjectSplitterV1.ZeroAmount.selector);
            splitter.recognizeSurplusRevenue(address(token), bytes32("again"));
            assertEq(_skimHeld(token) - skimBefore, skim, "still exactly one skim");
        }
    }

    // ------------------------------------------------------------------ SPL-003

    /// @notice SPL-003: the USDC skim approves exactly, deposits, verifies, and clears its allowance.
    function test_SPL_003_UsdcSkimApprovesDepositsVerifiesAndClearsAllowance() public {
        // Half the supply is staked, so every recognition below has a live staker branch *and* a
        // live treasury branch: a failure inside the skim must roll both of them back.
        _stake(alice, TOTAL_SUPPLY / 2);
        _deposit(usdc, 1_000_000, bytes32("pay-1"));

        assertEq(liveStaking.depositCalls(), 1, "deposited once");
        assertEq(liveStaking.lastAmount(), 20_000, "the exact floored skim");
        assertEq(liveStaking.lastCaller(), address(splitter), "the splitter is the depositor");
        assertEq(liveStaking.lastSourceTag(), bytes32(uint256(uint160(address(subject)))), "SUBJECT as source tag");
        assertEq(liveStaking.lastSourceRef(), bytes32("pay-1"), "the caller's revenueRef is forwarded");
        assertEq(usdc.balanceOf(address(liveStaking)), 20_000, "the skim landed");
        assertEq(usdc.allowance(address(splitter), address(liveStaking)), 0, "allowance cleared");

        uint256 liabilityAfter = splitter.unclaimedLiability(address(usdc));
        uint256 accAfter = splitter.accRewardPerShare(address(usdc));
        uint256 treasuryAfter = usdc.balanceOf(treasury);
        assertGt(liabilityAfter, 0, "the staker branch is not live");
        assertGt(treasuryAfter, 0, "the treasury branch is not live");

        // A staking contract that reports the wrong amount fails the whole recognition closed.
        liveStaking.setReportsWrongAmount(true);
        usdc.mint(address(this), 1_000_000);
        usdc.approve(address(splitter), 1_000_000);
        vm.expectRevert(abi.encodeWithSelector(SubjectSplitterV1.StakingDepositMismatch.selector, 20_000, 20_001));
        splitter.depositRecognizedRevenue(address(usdc), 1_000_000, bytes32("bad-return"));
        liveStaking.setReportsWrongAmount(false);

        // A staking contract that pulls only part of the approval fails closed on its own report.
        liveStaking.setPullsPartially(true);
        vm.expectRevert(abi.encodeWithSelector(SubjectSplitterV1.StakingDepositMismatch.selector, 20_000, 10_000));
        splitter.depositRecognizedRevenue(address(usdc), 1_000_000, bytes32("partial"));

        // A staking contract that pulls part and claims it took everything fails on the deltas.
        liveStaking.setLieAboutReceived(true);
        vm.expectRevert(abi.encodeWithSelector(SubjectSplitterV1.InexactTransfer.selector, 20_000, 10_000));
        splitter.depositRecognizedRevenue(address(usdc), 1_000_000, bytes32("partial-and-lying"));
        liveStaking.setLieAboutReceived(false);
        liveStaking.setPullsPartially(false);

        // A paused staking contract fails closed and rolls the whole recognition back.
        liveStaking.setPaused(true);
        vm.expectRevert(MockLiveStaking.Paused.selector);
        splitter.depositRecognizedRevenue(address(usdc), 1_000_000, bytes32("paused"));
        liveStaking.setPaused(false);

        assertEq(splitter.unclaimedLiability(address(usdc)), liabilityAfter, "no failed attempt changed liability");
        assertEq(splitter.accRewardPerShare(address(usdc)), accAfter, "no failed attempt changed the accumulator");
        assertEq(usdc.balanceOf(treasury), treasuryAfter, "no failed attempt delivered a treasury allocation");
        assertEq(liveStaking.depositCalls(), 1, "only the successful skim was committed");
        assertEq(usdc.allowance(address(splitter), address(liveStaking)), 0, "no residual allowance survives");
    }

    // ------------------------------------------------------------------ SPL-004

    /// @notice SPL-004: the REGENT and SUBJECT skims go to the Regent Safe.
    function test_SPL_004_RegentAndSubjectSkimsGoToTheRegentSafe() public {
        // Complete coverage, so no part of either net is a treasury allocation and the Regent Safe
        // deltas below are the skims and nothing else.
        _stake(alice, TOTAL_SUPPLY);

        _deposit(regent, 50_000e18, bytes32("regent"));
        assertEq(regent.balanceOf(regentSafe), 1_000e18, "2% of REGENT to the Regent Safe");

        _deposit(subject, 50_000e18, bytes32("subject"));
        assertEq(subject.balanceOf(regentSafe), 1_000e18, "2% of SUBJECT to the Regent Safe");

        assertEq(regent.balanceOf(address(liveStaking)), 0, "REGENT never reaches live staking");
        assertEq(subject.balanceOf(address(liveStaking)), 0, "SUBJECT never reaches live staking");
        assertEq(regent.balanceOf(treasury), 0, "a staked launch pays no REGENT to treasury");
    }

    // ------------------------------------------------------------------ SPL-005

    /// @notice SPL-005: the staker allocation is the floored fraction of the net represented by
    ///         `totalStaked / 100B`, and current stakers divide exactly that allocation pro rata.
    ///         An account's earnings follow its share of the complete supply, not its share of
    ///         whoever happens to be staked beside it.
    function test_SPL_005_NetSplitsByFixedSupplyCoverage() public {
        // 30% and 10% of the complete supply: 40% coverage, held three-to-one.
        _stake(alice, 30_000_000_000e18);
        _stake(bob, 10_000_000_000e18);

        usdc.mint(address(this), 1_000_000);
        usdc.approve(address(splitter), 1_000_000);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit SubjectSplitterV1.RevenueRecognized(
            address(usdc), address(this), bytes32("split"), 1_000_000, 20_000, 980_000, true
        );
        splitter.depositRecognizedRevenue(address(usdc), 1_000_000, bytes32("split"));

        // 40% of the 980,000 net reaches stakers; the uncovered 60% is the treasury's immediately.
        assertEq(splitter.unclaimedLiability(address(usdc)), 392_000, "40% coverage of the net");
        assertEq(usdc.balanceOf(treasury), 588_000, "the uncovered 60% reached the treasury at once");
        assertEq(usdc.balanceOf(address(liveStaking)), 20_000, "the skim is unchanged by coverage");

        // Inside that allocation the two stakers divide three-to-one, which is the same thing as
        // each earning its own coverage of the complete supply: Alice staked 30% of the supply and
        // earned 30% of the whole net, Bob staked 10% and earned 10%.
        assertEq(splitter.claimable(address(usdc), alice), (980_000 * 3) / 10, "Alice earned her 30% of the net");
        assertEq(splitter.claimable(address(usdc), bob), 980_000 / 10, "Bob earned his 10% of the net");

        // Joining after a recognition earns nothing from it.
        address carol = makeAddr("carol");
        _stake(carol, 10_000_000_000e18);
        assertEq(splitter.claimable(address(usdc), carol), 0, "no retroactive earnings");

        // The founder's example standing alone: one account holding 10% of the supply is the only
        // staker, and still earns exactly 10% of the net rather than all of it.
        SubjectSplitterV1 soleTenth = _newSplitter();
        address holder = makeAddr("holder");
        subject.mint(holder, 10_000_000_000e18);
        vm.startPrank(holder);
        subject.approve(address(soleTenth), 10_000_000_000e18);
        soleTenth.stake(10_000_000_000e18);
        vm.stopPrank();

        _depositTo(soleTenth, usdc, 1_000_000, bytes32("sole-tenth"));
        assertEq(soleTenth.claimable(address(usdc), holder), 98_000, "a sole 10% holder earns 10% of the net");
        assertEq(usdc.balanceOf(treasury), 588_000 + 882_000, "the other 90% went to the treasury");

        // Complete coverage is the upper bound: the whole net becomes the staker allocation and the
        // treasury receives nothing, for the smallest possible inflow as well as a large one.
        SubjectSplitterV1 fullCoverage = _newSplitter();
        address whale = makeAddr("whale");
        subject.mint(whale, TOTAL_SUPPLY);
        vm.startPrank(whale);
        subject.approve(address(fullCoverage), TOTAL_SUPPLY);
        fullCoverage.stake(TOTAL_SUPPLY);
        vm.stopPrank();

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        _depositTo(fullCoverage, usdc, 1, bytes32("dust"));
        assertEq(fullCoverage.claimable(address(usdc), whale), 1, "one smallest unit reaches a fully covered stake");
        _depositTo(fullCoverage, usdc, 1_000_000, bytes32("full"));
        assertEq(fullCoverage.claimable(address(usdc), whale), 1 + 980_000, "the whole net at complete coverage");
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "complete coverage left nothing for the treasury");
    }

    // ------------------------------------------------------------------ SPL-006

    /// @notice SPL-006: whatever the staked supply does not cover reaches the immutable treasury in
    ///         the same recognition, including the coverage rounding and the whole net when nothing
    ///         is staked. A treasury that cannot receive fails the entire recognition.
    function test_SPL_006_UncoveredNetGoesImmediatelyToTheImmutableTreasury() public {
        assertEq(splitter.totalStaked(), 0, "nothing staked");

        _deposit(usdc, 1_000_000, bytes32("no-stakers"));

        assertEq(usdc.balanceOf(treasury), 980_000, "the exact net reached the treasury");
        assertEq(usdc.balanceOf(address(liveStaking)), 20_000, "the skim still ran");
        assertEq(usdc.balanceOf(address(splitter)), 0, "the splitter kept nothing");
        assertEq(splitter.unclaimedLiability(address(usdc)), 0, "a zero-stake net is never a liability");
        assertEq(splitter.accRewardPerShare(address(usdc)), 0, "no accumulator movement");

        // A staker who arrives afterwards has no claim on it.
        _stake(alice, 10_000_000_000e18);
        assertEq(splitter.claimable(address(usdc), alice), 0, "no later staker claim was created");

        // Coverage rounding belongs to the treasury: at 10% coverage a nine-unit net floors to a
        // zero staker allocation, the whole net is delivered, and the event says so.
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        usdc.mint(address(this), 9);
        usdc.approve(address(splitter), 9);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit SubjectSplitterV1.RevenueRecognized(address(usdc), address(this), bytes32("rounding"), 9, 0, 9, false);
        splitter.depositRecognizedRevenue(address(usdc), 9, bytes32("rounding"));

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 9, "the floored-away net reached the treasury whole");
        assertEq(splitter.unclaimedLiability(address(usdc)), 0, "a floored allocation created no liability");
        assertEq(splitter.accRewardPerShare(address(usdc)), 0, "a floored allocation never moved the accumulator");
        assertEq(splitter.carriedRemainder(address(usdc)), 0, "a floored allocation created no carry");

        // A treasury delivery that fails rolls the whole recognition back. A ten-unit bare balance
        // skims nothing, so the treasury transfer is the only transfer this recognition attempts.
        usdc.mint(address(this), 10);
        usdc.transfer(address(splitter), 10);
        uint256 liability = splitter.unclaimedLiability(address(usdc));
        uint256 accumulator = splitter.accRewardPerShare(address(usdc));
        uint256 carry = splitter.carriedRemainder(address(usdc));

        usdc.setReturnsFalse(true);
        vm.expectRevert();
        splitter.recognizeSurplusRevenue(address(usdc), bytes32("treasury-down"));
        usdc.setReturnsFalse(false);

        assertEq(splitter.unclaimedLiability(address(usdc)), liability, "a failed delivery changed liability");
        assertEq(splitter.accRewardPerShare(address(usdc)), accumulator, "a failed delivery moved the accumulator");
        assertEq(splitter.carriedRemainder(address(usdc)), carry, "a failed delivery changed the carry");
        assertEq(
            usdc.balanceOf(address(splitter)) - splitter.protectedBalance(address(usdc)),
            10,
            "the refused inflow is still unrecognized"
        );
    }

    // ------------------------------------------------------------------ SPL-007

    /// @notice SPL-007: one indivisible remainder per asset is protected and carried forward.
    function test_SPL_007_PerTokenRemainderIsProtectedAndCarriedForward() public {
        // 30% coverage held equally by three accounts. Each four-unit inflow allocates exactly one
        // unit to stakers, which three equal stakes cannot divide, so the carry is the whole story:
        // the third recognition only pays out because the first two carries rolled forward.
        address carol = makeAddr("carol");
        _stake(alice, 10_000_000_000e18);
        _stake(bob, 10_000_000_000e18);
        _stake(carol, 10_000_000_000e18);

        _deposit(usdc, 4, bytes32("carry-1"));
        assertEq(splitter.unclaimedLiability(address(usdc)), 1, "30% of the four-unit net, floored");
        assertEq(splitter.claimable(address(usdc), alice), 0, "nothing divisible yet");
        assertGt(splitter.carriedRemainder(address(usdc)), 0, "the indivisible scaled numerator is carried");

        _deposit(usdc, 4, bytes32("carry-2"));
        assertEq(splitter.claimable(address(usdc), alice), 0, "two units still do not divide by three");
        assertGt(splitter.carriedRemainder(address(usdc)), 0, "the carry rolls forward again");

        _deposit(usdc, 4, bytes32("carry-3"));
        assertEq(splitter.claimable(address(usdc), alice), 1, "the carry released one whole unit each");
        assertEq(splitter.claimable(address(usdc), bob), 1, "for every equal staker");
        assertEq(splitter.claimable(address(usdc), carol), 1, "including the third");
        assertEq(splitter.carriedRemainder(address(usdc)), 0, "the carry is spent, not lost");
        assertEq(splitter.unclaimedLiability(address(usdc)), 3, "liability equals every staker allocation");
        assertEq(usdc.balanceOf(treasury), 9, "the uncovered 70% of each net reached the treasury");

        // The carry is never separately withdrawable and never re-recognizable.
        assertLt(splitter.carriedRemainder(address(regent)), splitter.totalStaked() + 1, "one carry per asset");
        vm.expectRevert(SubjectSplitterV1.ZeroAmount.selector);
        splitter.recognizeSurplusRevenue(address(usdc), bytes32("skim-the-carry"));
        vm.expectRevert(abi.encodeWithSelector(SubjectSplitterV1.ProtectedToken.selector, address(usdc)));
        splitter.recoverUnsupportedToken(address(usdc));
    }

    // ------------------------------------------------------------------ SPL-008

    /// @notice SPL-008: principal, unclaimed claims, and the remainder are outside surplus.
    function test_SPL_008_PrincipalClaimsAndRemainderAreExcludedFromSurplus() public {
        // Complete coverage, so every net below is wholly a staker allocation and the held SUBJECT
        // is exactly principal plus liability with no treasury share in between.
        _stake(alice, TOTAL_SUPPLY);
        _deposit(subject, 1_000e18, bytes32("subject-revenue"));

        uint256 liability = splitter.unclaimedLiability(address(subject));
        uint256 held = subject.balanceOf(address(splitter));
        assertEq(
            splitter.protectedBalance(address(subject)), liability + TOTAL_SUPPLY, "principal is protected separately"
        );
        assertEq(held, splitter.protectedBalance(address(subject)), "nothing is unaccounted");

        // With principal and unclaimed claims present, surplus recognition finds nothing.
        vm.expectRevert(SubjectSplitterV1.ZeroAmount.selector);
        splitter.recognizeSurplusRevenue(address(subject), bytes32("relabel"));

        // Only a genuinely unaccounted bare transfer becomes surplus.
        subject.mint(address(this), 500e18);
        subject.transfer(address(splitter), 500e18);
        splitter.recognizeSurplusRevenue(address(subject), bytes32("bare"));

        assertEq(subject.balanceOf(regentSafe), 20e18 + 10e18, "each inflow skimmed once");
        assertEq(
            splitter.unclaimedLiability(address(subject)), liability + 490e18, "only the bare balance was recognized"
        );
        assertEq(splitter.totalStaked(), TOTAL_SUPPLY, "principal untouched");

        // Principal is still fully returnable after everything above, one block on from the stake.
        uint256 claimBefore = splitter.claimable(address(subject), alice);
        _nextBlock();
        vm.prank(alice);
        splitter.unstake(TOTAL_SUPPLY);
        assertEq(subject.balanceOf(alice), TOTAL_SUPPLY, "principal returned in full");
        assertEq(splitter.claimable(address(subject), alice), claimBefore, "earnings survived the unstake");
    }

    // ------------------------------------------------------------------ SPL-009

    /// @notice SPL-009: staking and claiming take effect immediately, in the staking block itself.
    function test_SPL_009_StakingAndClaimingTakeEffectImmediately() public {
        _stake(alice, TOTAL_SUPPLY);
        assertEq(splitter.stakedOf(alice), TOTAL_SUPPLY, "credited immediately");
        assertEq(splitter.totalStaked(), TOTAL_SUPPLY, "counted immediately");

        // A zero-amount stake or unstake is rejected outright rather than recorded as an event.
        vm.startPrank(alice);
        vm.expectRevert(SubjectSplitterV1.ZeroAmount.selector);
        splitter.stake(0);
        vm.expectRevert(SubjectSplitterV1.ZeroAmount.selector);
        splitter.unstake(0);
        vm.stopPrank();
        assertEq(splitter.totalStaked(), TOTAL_SUPPLY, "the refused calls changed no stake");

        // Earning and settling both happen inside the staking block. Only the exit waits.
        _deposit(usdc, 1_000_000, bytes32("same-block"));
        assertEq(splitter.claimable(address(usdc), alice), 980_000, "earns from the very next recognition");
        vm.prank(alice);
        splitter.claim(address(usdc));
        assertEq(usdc.balanceOf(alice), 980_000, "claimed in the same block it was earned");

        // One block on, the position leaves in full and earns nothing afterwards.
        _nextBlock();
        vm.prank(alice);
        splitter.unstake(TOTAL_SUPPLY);
        assertEq(splitter.totalStaked(), 0, "removed in the block the exit was allowed");

        _deposit(usdc, 1_000_000, bytes32("after-exit"));
        assertEq(splitter.claimable(address(usdc), alice), 0, "no share of revenue after exit");
        assertEq(usdc.balanceOf(treasury), 980_000, "the later net went to the treasury");
    }

    /// @notice SPL-009: a position cannot leave in the block it was funded in. One block is the
    ///         whole rule — there is no cooldown, epoch, queue, or time weighting — and it prevents
    ///         exactly one thing: financing a stake, recognizing revenue against it, and exiting,
    ///         all inside a single atomic transaction. What bounds a funded holder's share is the
    ///         fixed-supply fraction, not the delay.
    function test_SPL_009_UnstakeRequiresALaterBlockThanTheLatestStake() public {
        _stake(alice, 30_000_000_000e18);

        // Zero amount is refused first, an over-withdrawal second, and only a valid positive
        // withdrawal in the staking block reaches the same-block refusal.
        vm.startPrank(alice);
        vm.expectRevert(SubjectSplitterV1.ZeroAmount.selector);
        splitter.unstake(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                SubjectSplitterV1.InsufficientStake.selector, 30_000_000_000e18, 30_000_000_000e18 + 1
            )
        );
        splitter.unstake(30_000_000_000e18 + 1);

        // Partial and complete withdrawals alike are refused, and neither mutates anything.
        vm.expectRevert(SubjectSplitterV1.SameBlockUnstake.selector);
        splitter.unstake(1);
        vm.expectRevert(SubjectSplitterV1.SameBlockUnstake.selector);
        splitter.unstake(30_000_000_000e18);
        vm.stopPrank();

        assertEq(splitter.stakedOf(alice), 30_000_000_000e18, "a refused exit changed the position");
        assertEq(splitter.totalStaked(), 30_000_000_000e18, "a refused exit changed the staked total");
        assertEq(subject.balanceOf(alice), 0, "a refused exit returned principal");

        // The next block permits an ordinary partial exit.
        _nextBlock();
        vm.prank(alice);
        splitter.unstake(10_000_000_000e18);
        assertEq(splitter.stakedOf(alice), 20_000_000_000e18, "the partial exit was refused after a block");

        // A later stake resets the delay for the whole position, not only for the new principal.
        _stake(alice, 1_000e18);
        vm.startPrank(alice);
        vm.expectRevert(SubjectSplitterV1.SameBlockUnstake.selector);
        splitter.unstake(1);
        vm.stopPrank();
        _nextBlock();
        vm.prank(alice);
        splitter.unstake(20_000_000_000e18 + 1_000e18);
        assertEq(splitter.stakedOf(alice), 0, "the reset delay never cleared");

        // The atomic capture the rule exists to prevent. Revenue waits on the splitter as a bare
        // transfer; a capturer borrows the whole supply, stakes it, recognizes the inflow, claims
        // and tries to leave in one transaction. The exit fails and takes the whole attempt with it.
        usdc.mint(address(this), 1_000_000);
        usdc.transfer(address(splitter), 1_000_000);
        subject.mint(address(this), TOTAL_SUPPLY);

        vm.expectRevert(SubjectSplitterV1.SameBlockUnstake.selector);
        this.attemptAtomicCapture(TOTAL_SUPPLY);

        assertEq(splitter.totalStaked(), 0, "the refused attempt left principal staked");
        assertEq(subject.balanceOf(address(this)), TOTAL_SUPPLY, "the borrowed principal did not roll back");
        assertEq(usdc.balanceOf(address(this)), 0, "the refused attempt paid the capturer");
        assertEq(usdc.balanceOf(address(liveStaking)), 0, "the refused attempt committed a skim");
        assertEq(usdc.balanceOf(treasury), 0, "the refused attempt delivered a treasury allocation");
        assertEq(
            usdc.balanceOf(address(splitter)) - splitter.protectedBalance(address(usdc)),
            1_000_000,
            "the waiting inflow is still unrecognized"
        );

        // The same inflow is recognized normally afterwards and nobody captured anything.
        _stake(bob, TOTAL_SUPPLY);
        vm.prank(outsider);
        splitter.recognizeSurplusRevenue(address(usdc), bytes32("honest"));
        assertEq(splitter.claimable(address(usdc), bob), 980_000, "the honest staker earns the net");
        assertEq(splitter.claimable(address(usdc), address(this)), 0, "the refused capturer earns nothing");
        _assertSolvent();
    }

    /// @dev One external self-call, so `vm.expectRevert` proves the *whole* stake, recognize, claim
    ///      and unstake attempt reverts together rather than only its last step.
    function attemptAtomicCapture(uint256 amount) external {
        subject.approve(address(splitter), amount);
        splitter.stake(amount);
        splitter.recognizeSurplusRevenue(address(usdc), bytes32("captured"));
        splitter.claim(address(usdc));
        splitter.unstake(amount);
    }

    // ------------------------------------------------------------------ SPL-011

    /// @notice SPL-011: a bare transfer is revenue only after permissionless recognition.
    function test_SPL_011_BareTransfersBecomeRevenueOnlyThroughRecognition() public {
        _stake(alice, TOTAL_SUPPLY);

        usdc.mint(address(this), 1_000_000);
        usdc.transfer(address(splitter), 1_000_000);

        assertEq(splitter.claimable(address(usdc), alice), 0, "a bare transfer is not yet revenue");
        assertEq(splitter.unclaimedLiability(address(usdc)), 0, "no liability yet");
        assertEq(usdc.balanceOf(address(liveStaking)), 0, "no skim yet");

        vm.prank(outsider);
        splitter.recognizeSurplusRevenue(address(usdc), bytes32("anyone"));

        assertEq(usdc.balanceOf(address(liveStaking)), 20_000, "recognition skimmed once");
        assertEq(splitter.claimable(address(usdc), alice), 980_000, "recognition created the claim");

        // A second recognition finds nothing and changes nothing.
        vm.expectRevert(SubjectSplitterV1.ZeroAmount.selector);
        splitter.recognizeSurplusRevenue(address(usdc), bytes32("again"));
        assertEq(usdc.balanceOf(address(liveStaking)), 20_000, "still one skim");
    }

    // ------------------------------------------------------------------ SPL-012

    /// @notice SPL-012: every recognized token stays solvent across bounded amounts and stakes.
    function testFuzz_SPL_012_RecognizedRevenueRemainsSolvent(
        uint256 aliceStake,
        uint256 bobStake,
        uint256 usdcGross,
        uint256 regentGross,
        uint256 subjectGross,
        bool stakeFirst
    ) public {
        aliceStake = bound(aliceStake, 1, TOTAL_SUPPLY / 2);
        bobStake = bound(bobStake, 1, TOTAL_SUPPLY / 2);
        usdcGross = bound(usdcGross, 1, 1e18);
        regentGross = bound(regentGross, 1, 1e30);
        subjectGross = bound(subjectGross, 1, TOTAL_SUPPLY);

        if (stakeFirst) {
            _stake(alice, aliceStake);
            _stake(bob, bobStake);
        }

        _deposit(usdc, usdcGross, bytes32("fuzz-usdc"));
        _deposit(regent, regentGross, bytes32("fuzz-regent"));
        _deposit(subject, subjectGross, bytes32("fuzz-subject"));

        if (!stakeFirst) {
            _stake(alice, aliceStake);
            _stake(bob, bobStake);
        }

        _assertSolvent();

        vm.prank(alice);
        splitter.claimAll();
        _assertSolvent();

        vm.prank(bob);
        splitter.claimAll();
        _assertSolvent();

        uint256 aliceSubjectBefore = subject.balanceOf(alice);
        _nextBlock();
        vm.prank(alice);
        splitter.unstake(aliceStake);
        _assertSolvent();
        assertEq(subject.balanceOf(alice) - aliceSubjectBefore, aliceStake, "principal returned exactly");
        assertEq(splitter.stakedOf(alice), 0, "stake fully withdrawn");

        _assertCoverageExtremesStaySolvent();
    }

    /// @dev The deterministic coverage-extreme sequence, re-derived for the supply-coverage split.
    ///      The old maximum-ratio case aimed at a `stake * accumulator` overflow that the coverage
    ///      denominator now makes unreachable, so what is worth proving instead is the two ends of
    ///      the coverage range against the maximum economic inflow per asset: the smallest nonzero
    ///      stake, where the allocation must be nonzero yet far below the net, and complete
    ///      coverage, where it must be the whole net and the treasury must receive nothing.
    function _assertCoverageExtremesStaySolvent() private {
        uint256 externalGross = type(uint128).max;
        uint256 externalNet = externalGross - (externalGross * 200) / 10_000;
        uint256 subjectNet = TOTAL_SUPPLY - (TOTAL_SUPPLY * 200) / 10_000;

        // One wei of stake: the smallest coverage a launch can have without being unstaked.
        SubjectSplitterV1 minimal = _newSplitter();
        address dust = makeAddr("dust");
        subject.mint(dust, 1);
        vm.startPrank(dust);
        subject.approve(address(minimal), 1);
        minimal.stake(1);
        vm.stopPrank();

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        _depositTo(minimal, usdc, externalGross, bytes32("extreme-usdc"));
        uint256 allocated = minimal.unclaimedLiability(address(usdc));

        assertGt(allocated, 0, "one wei of stake earned nothing from the maximum inflow");
        assertLt(allocated, externalNet, "one wei of stake earned an uncovered share of the net");
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, externalNet - allocated, "the rest is the treasury's");
        // With a single staked wei there is nothing to divide, so the sole staker owns it exactly.
        assertEq(minimal.claimable(address(usdc), dust), allocated, "the sole staker owns the whole allocation");
        _assertSolventFor(minimal);

        // Complete coverage: the whole net of every asset becomes the staker allocation.
        SubjectSplitterV1 complete = _newSplitter();
        address whale = makeAddr("coverage-whale");
        subject.mint(whale, TOTAL_SUPPLY);
        vm.startPrank(whale);
        subject.approve(address(complete), TOTAL_SUPPLY);
        complete.stake(TOTAL_SUPPLY);
        vm.stopPrank();

        treasuryBefore = usdc.balanceOf(treasury);
        _depositTo(complete, usdc, externalGross, bytes32("complete-usdc"));
        _depositTo(complete, regent, externalGross, bytes32("complete-regent"));
        _depositTo(complete, subject, TOTAL_SUPPLY, bytes32("complete-subject"));

        assertEq(complete.claimable(address(usdc), whale), externalNet, "the whole USDC net at complete coverage");
        assertEq(complete.claimable(address(regent), whale), externalNet, "the whole REGENT net did too");
        assertEq(complete.claimable(address(subject), whale), subjectNet, "and the whole SUBJECT net");
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "complete coverage left the treasury nothing");
        _assertSolventFor(complete);

        vm.prank(whale);
        complete.claimAll();
        assertEq(usdc.balanceOf(whale), externalNet, "claimed the exact USDC net");
        assertEq(regent.balanceOf(whale), externalNet, "claimed the exact REGENT net");
        _assertSolventFor(complete);

        _nextBlock();
        vm.prank(whale);
        complete.unstake(TOTAL_SUPPLY);
        assertEq(complete.totalStaked(), 0, "all principal returned");
        _assertSolventFor(complete);
    }

    /// @notice SPL-012: across stakes, unstakes, deposits, claims, and a restake, everything
    ///         already paid to stakers plus everything they may claim right now never exceeds the
    ///         revenue actually recognized for them, and liability never exceeds the held balance.
    ///         Small stakes against small inflows are where sub-unit entitlement dominates, which
    ///         is exactly where re-flooring a position at a stake change over-credits.
    function testFuzz_SPL_012_PaidPlusClaimableNeverExceedsRecognizedRevenue(
        uint256 aliceStake,
        uint256 bobStake,
        uint256 aliceExit,
        uint256 firstGross,
        uint256 secondGross,
        uint256 thirdGross
    ) public {
        aliceStake = bound(aliceStake, 1, 1e24);
        bobStake = bound(bobStake, 1, 1e24);
        aliceExit = bound(aliceExit, 1, aliceStake);
        firstGross = bound(firstGross, 1, 1e12);
        secondGross = bound(secondGross, 1, 1e12);
        thirdGross = bound(thirdGross, 1, 1e12);

        uint256 recognized;

        _stake(alice, aliceStake);
        recognized += _depositTrackingStakerNet(firstGross, bytes32("first"));
        _assertPaidPlusClaimableWithin(recognized);

        // A second staker joins between recognitions.
        _stake(bob, bobStake);
        _assertPaidPlusClaimableWithin(recognized);

        recognized += _depositTrackingStakerNet(secondGross, bytes32("second"));
        _assertPaidPlusClaimableWithin(recognized);

        // Alice reduces or fully exits her position one block on, which is where the accounting
        // must neither re-credit nor forfeit the fraction of a unit she had already earned.
        _nextBlock();
        vm.prank(alice);
        splitter.unstake(aliceExit);
        _assertPaidPlusClaimableWithin(recognized);

        recognized += _depositTrackingStakerNet(thirdGross, bytes32("third"));
        _assertPaidPlusClaimableWithin(recognized);

        vm.prank(alice);
        splitter.claim(address(usdc));
        _assertPaidPlusClaimableWithin(recognized);

        vm.prank(bob);
        splitter.claim(address(usdc));
        _assertPaidPlusClaimableWithin(recognized);

        // Restaking opens a fresh snapshot and recovers no earlier revenue.
        _stake(alice, aliceExit);
        _assertPaidPlusClaimableWithin(recognized);

        recognized += _depositTrackingStakerNet(firstGross, bytes32("fourth"));
        _assertPaidPlusClaimableWithin(recognized);

        vm.prank(alice);
        splitter.claimAll();
        vm.prank(bob);
        splitter.claimAll();
        _assertPaidPlusClaimableWithin(recognized);
        _assertSolvent();
    }

    // ------------------------------------------------------------------ SPL-013

    /// @notice SPL-013: a stake change preserves earned value and grants nothing retroactively.
    function testFuzz_SPL_013_StakeSnapshotsPayExactlyWhatWasEarned(
        uint256 firstStake,
        uint256 secondStake,
        uint256 grossBefore,
        uint256 grossBetween,
        uint256 grossAfter
    ) public {
        firstStake = bound(firstStake, 1e6, TOTAL_SUPPLY / 4);
        secondStake = bound(secondStake, 1e6, TOTAL_SUPPLY / 4);
        grossBefore = bound(grossBefore, 1, 1e18);
        grossBetween = bound(grossBetween, 1, 1e18);
        grossAfter = bound(grossAfter, 1, 1e18);

        // A deposit taken with nobody staked reaches the treasury, not a later staker.
        _deposit(usdc, grossBefore, bytes32("zero-stake"));
        _stake(alice, firstStake);
        assertEq(splitter.claimable(address(usdc), alice), 0, "no retroactive earnings from before the stake");

        // The sole staker earns its whole coverage allocation apart from at most the one
        // indivisible unit that stays inside protected liability as this asset's carried remainder.
        uint256 netBetween = grossBetween - (grossBetween * 200) / 10_000;
        uint256 allocatedBetween = _depositTrackingStakerNet(grossBetween, bytes32("alice-only"));
        uint256 aliceEarnedAlone = splitter.claimable(address(usdc), alice);
        assertLe(allocatedBetween, netBetween, "the allocation exceeded the net it came from");
        assertLe(aliceEarnedAlone, allocatedBetween, "a sole staker never earns more than the allocation");
        assertGe(aliceEarnedAlone + 1, allocatedBetween, "a sole staker loses at most the carried unit");

        // Bob joins. Alice keeps every unit she had already earned; Bob starts from zero.
        _stake(bob, secondStake);
        assertEq(splitter.claimable(address(usdc), alice), aliceEarnedAlone, "prior earnings preserved exactly");
        assertEq(splitter.claimable(address(usdc), bob), 0, "the joiner captures no prior unit");

        uint256 allocatedAfter = _depositTrackingStakerNet(grossAfter, bytes32("shared"));
        uint256 aliceAfter = splitter.claimable(address(usdc), alice);
        uint256 bobAfter = splitter.claimable(address(usdc), bob);
        assertGe(aliceAfter, aliceEarnedAlone, "earnings never shrink");

        // Deposits interleaved in the other two assets accrue against the same stake snapshots.
        _deposit(regent, grossBetween, bytes32("regent-shared"));
        _deposit(subject, grossAfter, bytes32("subject-shared"));

        // A claim taken before a stake change pays exactly that asset's earnings and nothing else.
        uint256 aliceRegentOwed = splitter.claimable(address(regent), alice);
        vm.prank(alice);
        splitter.claim(address(regent));
        assertEq(regent.balanceOf(alice), aliceRegentOwed, "the pre-change claim paid exactly what was earned");
        assertEq(splitter.claimable(address(regent), alice), 0, "and settled it exactly once");
        assertEq(splitter.claimable(address(usdc), alice), aliceAfter, "settling one asset never touches another");

        // A full exit one block on preserves what was earned and forfeits nothing.
        _nextBlock();
        vm.prank(alice);
        splitter.unstake(firstStake);
        assertEq(splitter.claimable(address(usdc), alice), aliceAfter, "a full unstake preserves earnings");

        // Every distributed unit is covered by protected liability, and nothing was invented: the
        // two stakers together never hold more than the two allocations actually made to them.
        assertLe(aliceAfter + bobAfter, allocatedBetween + allocatedAfter, "no unit exists that was never allocated");
        assertLe(aliceAfter + bobAfter, splitter.unclaimedLiability(address(usdc)), "claims are covered by liability");
        _assertSolvent();

        // A claim taken after that same stake change pays the identical earned amount.
        vm.prank(alice);
        splitter.claim(address(usdc));
        assertEq(usdc.balanceOf(alice), aliceAfter, "the post-change claim paid exactly the same earnings");
        assertEq(splitter.claimable(address(usdc), alice), 0, "settled exactly once");

        // A restake opens a fresh snapshot: it recovers no earlier revenue and disturbs nobody.
        uint256 bobSubjectBefore = splitter.claimable(address(subject), bob);
        _stake(alice, firstStake);
        assertEq(splitter.stakedOf(alice), firstStake, "restaked in full");
        assertEq(splitter.claimable(address(usdc), alice), 0, "a restake captures nothing retroactively");
        assertEq(splitter.claimable(address(subject), bob), bobSubjectBefore, "another staker's earnings survive it");

        _deposit(subject, grossBetween, bytes32("after-restake"));
        assertLe(
            splitter.claimable(address(subject), alice) + splitter.claimable(address(subject), bob),
            splitter.unclaimedLiability(address(subject)),
            "post-restake SUBJECT claims are covered by liability too"
        );
        _assertSolvent();
    }

    /// @notice SPL-013: the deterministic stake-change counterexample. Half the supply is staked
    ///         equally by two accounts, so a four-unit net allocates two units to stakers; each
    ///         halves its stake, and a second four-unit net then allocates one unit against a
    ///         quarter of the supply. Only three units were ever allocated, so aggregate whole-unit
    ///         claimability may never reach four; the half unit each staker still owns stays inside
    ///         liability until a later recognition completes it.
    function test_SPL_013_StakeChangesNeverOverCreditOrStrandWholeUnits() public {
        _stake(alice, 25_000_000_000e18);
        _stake(bob, 25_000_000_000e18);

        // 50% coverage of a four-unit net: two units to stakers, one each, two to the treasury.
        _deposit(usdc, 4, bytes32("two"));
        assertEq(splitter.unclaimedLiability(address(usdc)), 2, "half the four-unit net became liability");
        assertEq(usdc.balanceOf(treasury), 2, "the uncovered half reached the treasury");

        // Each staker halves its stake one block on, banking exactly one earned whole unit.
        _nextBlock();
        vm.prank(alice);
        splitter.unstake(12_500_000_000e18);
        vm.prank(bob);
        splitter.unstake(12_500_000_000e18);
        assertEq(splitter.claimable(address(usdc), alice), 1, "Alice keeps the whole unit she earned");
        assertEq(splitter.claimable(address(usdc), bob), 1, "and Bob keeps his");

        // 25% coverage of another four-unit net: one unit against two equal stakes, so half a unit
        // per staker again.
        _deposit(usdc, 4, bytes32("one"));

        uint256 liability = splitter.unclaimedLiability(address(usdc));
        assertEq(liability, 3, "exactly three units were ever allocated to stakers");
        assertEq(usdc.balanceOf(address(splitter)), 3, "and exactly three units are held");

        uint256 aliceOwed = splitter.claimable(address(usdc), alice);
        uint256 bobOwed = splitter.claimable(address(usdc), bob);
        assertEq(aliceOwed + bobOwed, 2, "a second half unit is not a second whole unit");
        assertLe(aliceOwed + bobOwed, liability, "aggregate claimability never exceeds liability");

        // The half unit each staker still owns is held as sub-unit entitlement, inside liability.
        uint256 halfUnit = splitter.SCALE() / 2;
        assertEq(splitter.claimableDust(address(usdc), alice), halfUnit, "Alice's half unit is banked, not lost");
        assertEq(splitter.claimableDust(address(usdc), bob), halfUnit, "and so is Bob's");

        // A staker joining at this checkpoint earns nothing from either recognition, and leaves
        // again a block later without disturbing anything.
        address carol = makeAddr("carol");
        _stake(carol, 10_000_000_000e18);
        assertEq(splitter.claimable(address(usdc), carol), 0, "the joiner captures nothing retroactively");
        _nextBlock();
        vm.prank(carol);
        splitter.unstake(10_000_000_000e18);

        // Both settle. Each is paid its whole unit; each half unit stays inside liability.
        vm.prank(alice);
        splitter.claim(address(usdc));
        vm.prank(bob);
        splitter.claim(address(usdc));

        assertEq(usdc.balanceOf(alice), 1, "Alice was paid exactly one unit");
        assertEq(usdc.balanceOf(bob), 1, "and Bob exactly one");
        assertEq(splitter.unclaimedLiability(address(usdc)), 1, "the undivided unit is still owed");
        assertEq(usdc.balanceOf(address(splitter)), 1, "and is still held");
        assertEq(splitter.claimable(address(usdc), alice), 0, "no whole unit is claimable yet");
        assertEq(splitter.claimable(address(usdc), bob), 0, "for either staker");

        // A later recognition completes each protected half unit into a whole one.
        _deposit(usdc, 4, bytes32("three"));
        assertEq(splitter.claimable(address(usdc), alice), 1, "the carried half unit became a whole unit");
        assertEq(splitter.claimable(address(usdc), bob), 1, "for both stakers");

        vm.prank(alice);
        splitter.claim(address(usdc));
        vm.prank(bob);
        splitter.claim(address(usdc));

        assertEq(usdc.balanceOf(alice), 2, "Alice was paid every unit she earned");
        assertEq(usdc.balanceOf(bob), 2, "and so was Bob");
        assertEq(splitter.unclaimedLiability(address(usdc)), 0, "every recognized unit is settled");
        assertEq(usdc.balanceOf(address(splitter)), 0, "and nothing was stranded");
        assertEq(splitter.claimable(address(usdc), carol), 0, "the joiner still earned nothing");
        _assertSolvent();
    }

    // ------------------------------------------------------------------ SPL-014

    /// @notice SPL-014: the six caller-only functions act only for their caller.
    function test_SPL_014_CallerOnlyFunctionsActOnlyForTheCaller() public {
        subject.mint(alice, TOTAL_SUPPLY);
        subject.mint(bob, 1_000e18);

        vm.startPrank(alice);
        subject.approve(address(splitter), TOTAL_SUPPLY);
        splitter.stake(TOTAL_SUPPLY);
        vm.stopPrank();

        assertEq(splitter.stakedOf(alice), TOTAL_SUPPLY, "stake credited the caller");
        assertEq(splitter.stakedOf(bob), 0, "and nobody else");

        _deposit(usdc, 1_000_000, bytes32("shared"));

        // Bob cannot unstake or claim what belongs to Alice. A non-staker is refused for having no
        // stake at all, before any exit-delay question is ever asked.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SubjectSplitterV1.InsufficientStake.selector, 0, 1));
        splitter.unstake(1);

        vm.prank(bob);
        splitter.claim(address(usdc));
        assertEq(usdc.balanceOf(bob), 0, "a non-staker claims nothing");
        assertEq(splitter.claimable(address(usdc), alice), 980_000, "Alice's claim is untouched");

        vm.prank(alice);
        splitter.claim(address(usdc));
        assertEq(usdc.balanceOf(alice), 980_000, "only the caller is paid");

        // A recognized deposit is funded only by its caller.
        usdc.mint(bob, 1_000_000);
        vm.prank(bob);
        usdc.approve(address(splitter), 1_000_000);
        usdc.mint(alice, 1_000_000);
        vm.prank(alice);
        usdc.approve(address(splitter), 1_000_000);
        vm.prank(bob);
        splitter.depositRecognizedRevenue(address(usdc), 1_000_000, bytes32("bob-pays"));
        assertEq(usdc.balanceOf(alice), 980_000 + 1_000_000, "Alice's approval was not touched");

        // No surface accepts a beneficiary or a recipient.
        assertFalse(_callSucceeds(abi.encodeWithSignature("stake(uint256,address)", uint256(1), bob)));
        assertFalse(_callSucceeds(abi.encodeWithSignature("unstake(uint256,address)", uint256(1), bob)));
        assertFalse(_callSucceeds(abi.encodeWithSignature("claim(address,address)", address(usdc), bob)));
        assertFalse(_callSucceeds(abi.encodeWithSignature("claimAll(address)", bob)));
        assertFalse(_callSucceeds(abi.encodeWithSignature("claimFor(address,address)", address(usdc), alice)));
    }

    // ------------------------------------------------------------------ SPL-015

    /// @notice SPL-015: claimAll settles exactly the three recognized tokens.
    function test_SPL_015_ClaimAllSettlesExactlyTheThreeRecognizedTokens() public {
        _stake(alice, TOTAL_SUPPLY);
        _deposit(usdc, 1_000_000, bytes32("u"));
        _deposit(regent, 1_000e18, bytes32("r"));
        _deposit(subject, 1_000e18, bytes32("s"));

        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(splitter), 500e18);

        vm.prank(alice);
        splitter.claimAll();

        assertEq(usdc.balanceOf(alice), 980_000, "USDC settled");
        assertEq(regent.balanceOf(alice), 980e18, "REGENT settled");
        assertEq(subject.balanceOf(alice), 980e18, "SUBJECT settled");
        assertEq(other.balanceOf(alice), 0, "no fourth token is settled");
        assertEq(other.balanceOf(address(splitter)), 500e18, "the fourth token is untouched");

        assertEq(splitter.claimable(address(usdc), alice), 0, "USDC drained");
        assertEq(splitter.claimable(address(regent), alice), 0, "REGENT drained");
        assertEq(splitter.claimable(address(subject), alice), 0, "SUBJECT drained");

        // With nothing owed, claimAll is an exact no-op rather than a revert or a stray transfer.
        uint256 aliceUsdc = usdc.balanceOf(alice);
        vm.prank(alice);
        splitter.claimAll();
        assertEq(usdc.balanceOf(alice), aliceUsdc, "a zero-value claimAll moves nothing");
    }

    // ------------------------------------------------------------------ SPL-016

    /// @notice SPL-016: the 2% skim floors exactly at every boundary inflow.
    /// @dev Complete coverage, so each recognition's liability delta is the whole net and the skim
    ///      is the only rounding this test can be measuring.
    function test_SPL_016_SkimRoundingIsExactAtTheInflowBoundaryInputs() public {
        _stake(alice, TOTAL_SUPPLY);

        uint256[7] memory grossInputs = [uint256(1), 49, 50, 99, 100, 9_999, 10_000];
        uint256[7] memory expectedSkims = [uint256(0), 0, 1, 1, 2, 199, 200];

        MockERC20[3] memory tokens = [usdc, regent, subject];
        for (uint256 t; t < tokens.length; ++t) {
            MockERC20 token = tokens[t];
            for (uint256 i; i < grossInputs.length; ++i) {
                uint256 before = _skimHeld(token);
                uint256 liabilityBefore = splitter.unclaimedLiability(address(token));

                _deposit(token, grossInputs[i], bytes32("boundary"));

                uint256 skim = _skimHeld(token) - before;
                assertEq(skim, expectedSkims[i], "floored skim is exact at the boundary");
                assertEq(
                    splitter.unclaimedLiability(address(token)) - liabilityBefore,
                    grossInputs[i] - expectedSkims[i],
                    "net is exactly gross minus skim"
                );
            }
        }

        // A zero gross inflow is rejected, so no path can recognize nothing.
        vm.expectRevert(SubjectSplitterV1.ZeroAmount.selector);
        splitter.depositRecognizedRevenue(address(usdc), 0, bytes32("zero"));
    }

    // ------------------------------------------------------------------ SPL-017

    /// @notice SPL-017: splitter recovery is permissionless, moves the complete balance, and can
    ///         only ever reach the immutable treasury. A zero balance fails and mutates nothing.
    function test_SPL_017_RecoveryIsPermissionlessWholeBalanceToTheTreasury() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);

        // Nothing to recover: both paths revert and neither leaves a trace.
        address[3] memory callers = [address(this), treasury, outsider];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(SubjectSplitterV1.ZeroAmount.selector);
            splitter.recoverUnsupportedToken(address(other));
            vm.expectRevert(SubjectSplitterV1.ZeroAmount.selector);
            splitter.recoverForcedETH();
            vm.stopPrank();
        }
        assertEq(other.balanceOf(treasury), 0, "a failed recovery moved value");
        assertEq(address(splitter).balance, 0, "a failed ETH recovery moved value");

        // Every caller in turn recovers the complete balance, and every unit lands on the fixed
        // treasury. No caller keeps anything and no caller can name a destination.
        for (uint256 i; i < callers.length; ++i) {
            other.mint(address(splitter), 500e18);
            uint256 treasuryBefore = other.balanceOf(treasury);

            vm.prank(callers[i]);
            vm.expectEmit(true, true, true, true, address(splitter));
            emit SubjectSplitterV1.UnsupportedTokenRecovered(address(other), treasury, 500e18);
            splitter.recoverUnsupportedToken(address(other));

            assertEq(other.balanceOf(treasury) - treasuryBefore, 500e18, "the whole balance reached the treasury");
            assertEq(other.balanceOf(address(splitter)), 0, "the splitter kept a remainder");
            if (callers[i] != treasury) assertEq(other.balanceOf(callers[i]), 0, "the caller was paid for calling");
        }

        // There is no amount-taking or recipient-taking overload left to call.
        assertFalse(
            _callSucceeds(
                abi.encodeWithSignature("recoverUnsupportedToken(address,uint256)", address(other), uint256(1))
            ),
            "an amount-taking recovery selector still exists"
        );
        assertFalse(_callSucceeds(abi.encodeWithSignature("recoverForcedETH(uint256)", uint256(1))));

        vm.deal(address(this), 1 ether);
        new ForceEthSender{value: 1 ether}(address(splitter));
        uint256 treasuryEth = treasury.balance;

        vm.prank(outsider);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit SubjectSplitterV1.ForcedEthRecovered(treasury, 1 ether);
        splitter.recoverForcedETH();
        assertEq(treasury.balance - treasuryEth, 1 ether, "forced ETH reached the treasury");
        assertEq(address(splitter).balance, 0, "no ETH remains");
        assertEq(outsider.balance, 0, "the caller took forced ETH");
    }

    // ------------------------------------------------------------------ SPL-018

    /// @notice SPL-018: recovery can never reach a core token or staker-owned value.
    function test_SPL_018_RecoveryCanNeverReachProtectedSplitterAssets() public {
        // 30% coverage, which allocates one indivisible unit out of a four-unit net and so leaves a
        // real carry for recovery to fail to reach.
        _stake(alice, 30_000_000_000e18);
        _deposit(usdc, 4, bytes32("carry"));
        _deposit(regent, 1_000e18, bytes32("regent"));
        _deposit(subject, 1_000e18, bytes32("subject"));

        uint256 principal = splitter.totalStaked();
        uint256 usdcLiability = splitter.unclaimedLiability(address(usdc));
        uint256 regentLiability = splitter.unclaimedLiability(address(regent));
        uint256 subjectLiability = splitter.unclaimedLiability(address(subject));
        uint256 carry = splitter.carriedRemainder(address(usdc));
        assertGt(carry, 0, "there is a carry to protect");

        address[3] memory core = [address(usdc), address(regent), address(subject)];
        vm.startPrank(outsider);
        for (uint256 i; i < core.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(SubjectSplitterV1.ProtectedToken.selector, core[i]));
            splitter.recoverUnsupportedToken(core[i]);
        }

        // An unsupported token is recoverable and touches nothing that belongs to a staker.
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(splitter), 500e18);
        splitter.recoverUnsupportedToken(address(other));
        vm.stopPrank();

        assertEq(splitter.totalStaked(), principal, "principal untouched");
        assertEq(splitter.unclaimedLiability(address(usdc)), usdcLiability, "USDC liability untouched");
        assertEq(splitter.unclaimedLiability(address(regent)), regentLiability, "REGENT liability untouched");
        assertEq(splitter.unclaimedLiability(address(subject)), subjectLiability, "SUBJECT liability untouched");
        assertEq(splitter.carriedRemainder(address(usdc)), carry, "carry untouched");
        _assertSolvent();
    }

    // ------------------------------------------------------------------ SPL-019

    /// @notice SPL-019: ordinary ETH reverts, so only forced ETH can ever be present.
    function test_SPL_019_OrdinaryEthTransfersRevert() public {
        vm.deal(address(this), 3 ether);

        (bool plain,) = address(splitter).call{value: 1 ether}("");
        assertFalse(plain, "a plain ETH transfer reverts");
        (bool withData,) = address(splitter).call{value: 1 ether}(hex"deadbeef");
        assertFalse(withData, "an unknown payable call reverts");
        assertEq(address(splitter).balance, 0, "no ETH accumulated");

        // Only EVM force-send behavior can leave ETH here, and only recovery removes it.
        new ForceEthSender{value: 1 ether}(address(splitter));
        assertEq(address(splitter).balance, 1 ether, "forced ETH is possible");

        vm.prank(outsider);
        splitter.recoverForcedETH();
        assertEq(address(splitter).balance, 0, "forced ETH is recoverable to the treasury");
    }

    // ------------------------------------------------------------------ SPL-020

    /// @notice SPL-020: a direct deposit recognizes exactly its own amount, once, with its ref.
    function test_SPL_020_DepositRecognizedRevenueRecognizesExactlyOnce() public {
        // Complete coverage, so the event's `net` and the liability it creates are the same number
        // and `paidToStakers` is true because the allocation is nonzero.
        _stake(alice, TOTAL_SUPPLY);

        // An unrelated bare balance is present and must not be swept into this deposit.
        usdc.mint(address(this), 5_000_000);
        usdc.transfer(address(splitter), 4_000_000);

        usdc.approve(address(splitter), 1_000_000);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit SubjectSplitterV1.RevenueRecognized(
            address(usdc), address(this), bytes32("ref-42"), 1_000_000, 20_000, 980_000, true
        );
        splitter.depositRecognizedRevenue(address(usdc), 1_000_000, bytes32("ref-42"));

        assertEq(splitter.unclaimedLiability(address(usdc)), 980_000, "only the deposited amount was recognized");
        assertEq(usdc.balanceOf(address(liveStaking)), 20_000, "exactly one skim");
        assertEq(
            usdc.balanceOf(address(splitter)) - splitter.protectedBalance(address(usdc)),
            4_000_000,
            "the bare balance is still unaccounted"
        );

        vm.expectRevert(SubjectSplitterV1.ZeroAmount.selector);
        splitter.depositRecognizedRevenue(address(usdc), 0, bytes32("ref-0"));

        // A token that moves nothing and reports `false` recognizes nothing.
        uint256 liability = splitter.unclaimedLiability(address(usdc));
        usdc.setReturnsFalse(true);
        usdc.approve(address(splitter), 1_000_000);
        vm.expectRevert();
        splitter.depositRecognizedRevenue(address(usdc), 1_000_000, bytes32("lying"));
        usdc.setReturnsFalse(false);
        assertEq(splitter.unclaimedLiability(address(usdc)), liability, "a false return recognized nothing");
    }

    // ------------------------------------------------------------------ SPL-021

    /// @notice SPL-021: reentrancy through a recognized token changes no accounting.
    function test_SPL_021_ReentrancyCannotChangeSplitterAccounting() public {
        _stake(alice, TOTAL_SUPPLY / 2);
        _deposit(usdc, 1_000_000, bytes32("base"));

        uint256 liability = splitter.unclaimedLiability(address(usdc));
        uint256 accumulator = splitter.accRewardPerShare(address(usdc));
        uint256 staked = splitter.totalStaked();

        // The SUBJECT pull re-enters surplus recognition mid-stake.
        subject.mint(bob, 500e18);
        subject.setReentry(
            address(splitter),
            abi.encodeCall(SubjectSplitterV1.recognizeSurplusRevenue, (address(subject), bytes32("reenter")))
        );
        vm.startPrank(bob);
        subject.approve(address(splitter), 500e18);
        splitter.stake(500e18);
        vm.stopPrank();

        assertEq(subject.reentryAttempts(), 1, "the token did try to re-enter");
        assertFalse(subject.lastReentrySucceeded(), "the re-entrant recognition was rejected");
        assertEq(splitter.totalStaked(), staked + 500e18, "stake recorded exactly once");
        assertEq(splitter.unclaimedLiability(address(subject)), 0, "principal was never recognized as revenue");
        subject.setReentry(address(0), "");

        // A claim transfer re-enters the same claim.
        usdc.setReentry(address(splitter), abi.encodeCall(SubjectSplitterV1.claim, (address(usdc))));
        uint256 owed = splitter.claimable(address(usdc), alice);
        vm.prank(alice);
        splitter.claim(address(usdc));

        assertFalse(usdc.lastReentrySucceeded(), "the re-entrant claim was rejected");
        assertEq(usdc.balanceOf(alice), owed, "paid exactly once");
        assertEq(splitter.claimable(address(usdc), alice), 0, "settled exactly once");
        assertEq(splitter.unclaimedLiability(address(usdc)), liability - owed, "liability fell by exactly the claim");
        assertEq(splitter.accRewardPerShare(address(usdc)), accumulator, "the accumulator never moved");
        _assertSolvent();
    }

    // ------------------------------------------------------------------ SPL-022

    /// @notice SPL-022: a re-entrant recovery token reaches nothing protected.
    function test_SPL_022_RecoveryTokenReentrancyCannotReachProtectedSplitterAssets() public {
        _stake(alice, 30_000_000_000e18);
        _deposit(usdc, 4, bytes32("carry"));
        _deposit(regent, 1_000e18, bytes32("regent"));

        uint256 principal = splitter.totalStaked();
        uint256 carry = splitter.carriedRemainder(address(usdc));
        assertGt(carry, 0, "there is a carry to protect");
        uint256 regentLiability = splitter.unclaimedLiability(address(regent));
        uint256 regentHeld = regent.balanceOf(address(splitter));

        MockERC20 hostile = new MockERC20("Hostile", "HOS", 18);
        hostile.mint(address(splitter), 500e18);
        hostile.setReentry(
            address(splitter), abi.encodeCall(SubjectSplitterV1.recoverUnsupportedToken, (address(regent)))
        );

        vm.prank(outsider);
        splitter.recoverUnsupportedToken(address(hostile));

        assertEq(hostile.reentryAttempts(), 1, "the token did try to re-enter");
        assertFalse(hostile.lastReentrySucceeded(), "the re-entrant recovery was rejected");
        assertEq(hostile.balanceOf(treasury), 500e18, "the honest recovery still completed");
        assertEq(regent.balanceOf(address(splitter)), regentHeld, "no REGENT left the splitter");
        assertEq(splitter.totalStaked(), principal, "principal untouched");
        assertEq(splitter.carriedRemainder(address(usdc)), carry, "carry untouched");
        assertEq(splitter.unclaimedLiability(address(regent)), regentLiability, "liability untouched");

        // A token that simply reverts fails only its own recovery call.
        MockERC20 broken = new MockERC20("Broken", "BRK", 18);
        broken.mint(address(splitter), 10e18);
        broken.setReverts(true);
        vm.prank(outsider);
        vm.expectRevert();
        splitter.recoverUnsupportedToken(address(broken));

        uint256 owed = splitter.claimable(address(regent), alice);
        vm.prank(alice);
        splitter.claimAll();
        assertEq(regent.balanceOf(alice), owed, "claims still work after a hostile recovery attempt");
        assertLe(owed, regentLiability, "the claim never exceeds protected liability");
        _assertSolvent();
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Advance exactly one block, so a staked position becomes withdrawable. The height comes
    ///      from the cheatcode rather than from `block.number`, which the via-IR optimizer is free
    ///      to hoist across an intervening `vm.roll` and would otherwise make a second advance in
    ///      the same test silently repeat the first.
    function _nextBlock() private {
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _stake(address account, uint256 amount) private {
        subject.mint(account, amount);
        vm.startPrank(account);
        subject.approve(address(splitter), amount);
        splitter.stake(amount);
        vm.stopPrank();
    }

    function _deposit(MockERC20 token, uint256 gross, bytes32 revenueRef) private {
        _depositTo(splitter, token, gross, revenueRef);
    }

    function _depositTo(SubjectSplitterV1 target, MockERC20 token, uint256 gross, bytes32 revenueRef) private {
        token.mint(address(this), gross);
        token.approve(address(target), gross);
        target.depositRecognizedRevenue(address(token), gross, revenueRef);
    }

    /// @dev Deposit USDC and return the amount that actually became a staker liability, observed as
    ///      the liability the recognition created rather than recomputed from the splitter's own
    ///      formula. Whatever the staked supply did not cover went straight to the treasury and is
    ///      never owed to a staker, so this is independently bounded by the post-skim net.
    function _depositTrackingStakerNet(uint256 gross, bytes32 revenueRef) private returns (uint256 stakerNet) {
        uint256 before = splitter.unclaimedLiability(address(usdc));
        _deposit(usdc, gross, revenueRef);
        stakerNet = splitter.unclaimedLiability(address(usdc)) - before;
        assertLe(stakerNet, gross - (gross * 200) / 10_000, "a recognition credited stakers beyond its own net");
    }

    /// @dev Everything already paid to the two stakers plus everything they may claim right now is
    ///      covered by the revenue recognized for stakers, by protected liability, and by the
    ///      balance the splitter actually holds. Neither account holds USDC from any other source.
    function _assertPaidPlusClaimableWithin(uint256 recognizedNet) private view {
        uint256 paid = usdc.balanceOf(alice) + usdc.balanceOf(bob);
        uint256 owed = splitter.claimable(address(usdc), alice) + splitter.claimable(address(usdc), bob);

        assertLe(paid + owed, recognizedNet, "paid plus claimable never exceeds recognized revenue");
        assertLe(owed, splitter.unclaimedLiability(address(usdc)), "claimable is covered by liability");
        assertLe(
            splitter.unclaimedLiability(address(usdc)),
            usdc.balanceOf(address(splitter)),
            "liability is covered by the held balance"
        );
    }

    /// @dev Where this asset's skim lands: live staking for USDC, the Regent Safe otherwise.
    function _skimHeld(MockERC20 token) private view returns (uint256) {
        return token == usdc ? usdc.balanceOf(address(liveStaking)) : token.balanceOf(regentSafe);
    }

    function _assertSolvent() private view {
        _assertSolventFor(splitter);
    }

    function _assertSolventFor(SubjectSplitterV1 target) private view {
        assertGe(usdc.balanceOf(address(target)), target.protectedBalance(address(usdc)), "USDC solvent");
        assertGe(regent.balanceOf(address(target)), target.protectedBalance(address(regent)), "REGENT solvent");
        assertGe(
            subject.balanceOf(address(target)),
            target.unclaimedLiability(address(subject)) + target.totalStaked(),
            "SUBJECT covers liability plus principal"
        );
    }

    /// @dev The six valid bindings, rebuilt on every call so no arm can leak into the next.
    function _validBindings() private view returns (address[6] memory values) {
        values[0] = address(usdc);
        values[1] = address(regent);
        values[2] = address(subject);
        values[3] = address(liveStaking);
        values[4] = regentSafe;
        values[5] = treasury;
    }

    function _expectInitRevert(bytes4 expected, uint256 index, address replacement) private {
        address[6] memory values = _validBindings();
        values[index] = replacement;
        SubjectSplitterV1 fresh = SubjectSplitterV1(LibClone.clone(address(splitterImplementation)));
        vm.expectRevert(expected);
        fresh.initialize(values[0], values[1], values[2], values[3], values[4], values[5]);
    }

    function _expectSelfBindingRevert(uint256 index) private {
        address[6] memory values = _validBindings();
        SubjectSplitterV1 fresh = SubjectSplitterV1(LibClone.clone(address(splitterImplementation)));
        values[index] = address(fresh);
        vm.expectRevert(SubjectSplitterV1.SelfAddress.selector);
        fresh.initialize(values[0], values[1], values[2], values[3], values[4], values[5]);
    }

    function _callSucceeds(bytes memory data) private returns (bool ok) {
        (ok,) = address(splitter).call(data);
    }
}
