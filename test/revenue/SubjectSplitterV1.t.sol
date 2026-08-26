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
    function test_SPL_002_EveryRecognizedInflowIsSkimmedExactlyOnce() public {
        _stake(alice, 1_000e18);

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
        _stake(alice, 1_000e18);
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
        assertEq(liveStaking.depositCalls(), 1, "only the successful skim was committed");
        assertEq(usdc.allowance(address(splitter), address(liveStaking)), 0, "no residual allowance survives");
    }

    // ------------------------------------------------------------------ SPL-004

    /// @notice SPL-004: the REGENT and SUBJECT skims go to the Regent Safe.
    function test_SPL_004_RegentAndSubjectSkimsGoToTheRegentSafe() public {
        _stake(alice, 1_000e18);

        _deposit(regent, 50_000e18, bytes32("regent"));
        assertEq(regent.balanceOf(regentSafe), 1_000e18, "2% of REGENT to the Regent Safe");

        _deposit(subject, 50_000e18, bytes32("subject"));
        assertEq(subject.balanceOf(regentSafe), 1_000e18, "2% of SUBJECT to the Regent Safe");

        assertEq(regent.balanceOf(address(liveStaking)), 0, "REGENT never reaches live staking");
        assertEq(subject.balanceOf(address(liveStaking)), 0, "SUBJECT never reaches live staking");
        assertEq(regent.balanceOf(treasury), 0, "a staked launch pays no REGENT to treasury");
    }

    // ------------------------------------------------------------------ SPL-005

    /// @notice SPL-005: the net goes pro rata to current stakers, at dust and at realistic scale.
    function test_SPL_005_NetGoesProRataToCurrentStakers() public {
        _stake(alice, 3e18);
        _stake(bob, 1e18);

        _deposit(usdc, 1_000, bytes32("split"));
        assertEq(splitter.claimable(address(usdc), alice), 735, "three quarters of the 980 net");
        assertEq(splitter.claimable(address(usdc), bob), 245, "one quarter of the 980 net");

        // Joining after a deposit earns nothing from it.
        address carol = makeAddr("carol");
        _stake(carol, 4e18);
        assertEq(splitter.claimable(address(usdc), carol), 0, "no retroactive earnings");

        // One smallest unit still distributes at the maximum 100B stake.
        SubjectSplitterV1 maxStake = _newSplitter();
        address whale = makeAddr("whale");
        subject.mint(whale, TOTAL_SUPPLY);
        vm.startPrank(whale);
        subject.approve(address(maxStake), TOTAL_SUPPLY);
        maxStake.stake(TOTAL_SUPPLY);
        vm.stopPrank();

        usdc.mint(address(this), 1);
        usdc.approve(address(maxStake), 1);
        maxStake.depositRecognizedRevenue(address(usdc), 1, bytes32("dust"));
        assertEq(maxStake.claimable(address(usdc), whale), 1, "one smallest unit reaches the maximum stake");

        // A realistic one-USDC payment at a one-million-SUBJECT stake pays the exact net.
        SubjectSplitterV1 realistic = _newSplitter();
        address holder = makeAddr("holder");
        subject.mint(holder, 1_000_000e18);
        vm.startPrank(holder);
        subject.approve(address(realistic), 1_000_000e18);
        realistic.stake(1_000_000e18);
        vm.stopPrank();

        usdc.mint(address(this), 1e6);
        usdc.approve(address(realistic), 1e6);
        realistic.depositRecognizedRevenue(address(usdc), 1e6, bytes32("one-usdc"));
        assertEq(realistic.claimable(address(usdc), holder), 980_000, "one USDC minus the exact 2% skim");
    }

    // ------------------------------------------------------------------ SPL-006

    /// @notice SPL-006: with nothing staked, the net goes immediately to the immutable treasury.
    function test_SPL_006_ZeroStakeSendsNetToTheImmutableTreasury() public {
        assertEq(splitter.totalStaked(), 0, "nothing staked");

        _deposit(usdc, 1_000_000, bytes32("no-stakers"));

        assertEq(usdc.balanceOf(treasury), 980_000, "the exact net reached the treasury");
        assertEq(usdc.balanceOf(address(liveStaking)), 20_000, "the skim still ran");
        assertEq(usdc.balanceOf(address(splitter)), 0, "the splitter kept nothing");
        assertEq(splitter.unclaimedLiability(address(usdc)), 0, "a zero-stake net is never a liability");
        assertEq(splitter.accRewardPerShare(address(usdc)), 0, "no accumulator movement");

        // A staker who arrives afterwards has no claim on it.
        _stake(alice, 1_000e18);
        assertEq(splitter.claimable(address(usdc), alice), 0, "no later staker claim was created");
    }

    // ------------------------------------------------------------------ SPL-007

    /// @notice SPL-007: one indivisible remainder per asset is protected and carried forward.
    function test_SPL_007_PerTokenRemainderIsProtectedAndCarriedForward() public {
        // Three wei of stake and one-unit deposits make the carry the whole story: the third
        // deposit only pays out because the first two carries rolled forward.
        _stake(alice, 3);

        _deposit(usdc, 1, bytes32("carry-1"));
        assertEq(splitter.claimable(address(usdc), alice), 0, "nothing divisible yet");
        assertEq(splitter.carriedRemainder(address(usdc)), 1, "the whole scaled remainder is carried");
        assertEq(splitter.unclaimedLiability(address(usdc)), 1, "the full net stayed protected");

        _deposit(usdc, 1, bytes32("carry-2"));
        assertEq(splitter.claimable(address(usdc), alice), 1, "the carry released one unit");
        assertEq(splitter.carriedRemainder(address(usdc)), 2, "the carry rolls forward again");

        _deposit(usdc, 1, bytes32("carry-3"));
        assertEq(splitter.claimable(address(usdc), alice), 3, "the carry released the rest");
        assertEq(splitter.carriedRemainder(address(usdc)), 0, "the carry is spent, not lost");
        assertEq(splitter.unclaimedLiability(address(usdc)), 3, "liability equals every recognized net");

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
        _stake(alice, 3e18);
        _deposit(subject, 1_000e18, bytes32("subject-revenue"));

        uint256 liability = splitter.unclaimedLiability(address(subject));
        uint256 held = subject.balanceOf(address(splitter));
        assertEq(splitter.protectedBalance(address(subject)), liability + 3e18, "principal is protected separately");
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
        assertEq(splitter.totalStaked(), 3e18, "principal untouched");

        // Principal is still fully returnable after everything above.
        uint256 claimBefore = splitter.claimable(address(subject), alice);
        vm.prank(alice);
        splitter.unstake(3e18);
        assertEq(subject.balanceOf(alice), 3e18, "principal returned in full");
        assertEq(splitter.claimable(address(subject), alice), claimBefore, "earnings survived the unstake");
    }

    // ------------------------------------------------------------------ SPL-009

    /// @notice SPL-009: staking takes effect immediately, in the same block.
    function test_SPL_009_StakingTakesEffectImmediately() public {
        _stake(alice, 1_000e18);
        assertEq(splitter.stakedOf(alice), 1_000e18, "credited immediately");
        assertEq(splitter.totalStaked(), 1_000e18, "counted immediately");

        // A zero-amount stake or unstake is rejected outright rather than recorded as an event.
        vm.startPrank(alice);
        vm.expectRevert(SubjectSplitterV1.ZeroAmount.selector);
        splitter.stake(0);
        vm.expectRevert(SubjectSplitterV1.ZeroAmount.selector);
        splitter.unstake(0);
        vm.stopPrank();
        assertEq(splitter.totalStaked(), 1_000e18, "the refused calls changed no stake");

        _deposit(usdc, 1_000_000, bytes32("same-block"));
        assertEq(splitter.claimable(address(usdc), alice), 980_000, "earns from the very next recognition");

        // Unstaking is equally immediate.
        vm.prank(alice);
        splitter.unstake(1_000e18);
        assertEq(splitter.totalStaked(), 0, "removed immediately");

        _deposit(usdc, 1_000_000, bytes32("after-exit"));
        assertEq(splitter.claimable(address(usdc), alice), 980_000, "no share of revenue after exit");
        assertEq(usdc.balanceOf(treasury), 980_000, "the later net went to the treasury");
    }

    /// @notice SPL-009: immediacy in its strongest honest form. Nothing separates a stake from
    ///         the recognition that follows it, so a caller who owns or borrows SUBJECT may stake,
    ///         recognize a waiting inflow, claim, and unstake with no delay in between and keep
    ///         the whole net. This is the founder-frozen economic choice, recorded as accepted
    ///         behavior in the threat model, not a defect: there is no cooldown, epoch, queue, or
    ///         previous-block eligibility rule anywhere in this contract.
    function test_SPL_009_ImmediateStakeCanCaptureARecognitionAroundIt() public {
        // Revenue sits on the splitter as a bare transfer, waiting for anyone to recognize it.
        usdc.mint(address(this), 1_000_000);
        usdc.transfer(address(splitter), 1_000_000);

        // The opportunist borrows SUBJECT and is the only staker for exactly this recognition.
        address opportunist = makeAddr("opportunist");
        subject.mint(opportunist, 1_000e18);

        vm.startPrank(opportunist);
        subject.approve(address(splitter), 1_000e18);
        splitter.stake(1_000e18);
        splitter.recognizeSurplusRevenue(address(usdc), bytes32("captured"));
        splitter.claim(address(usdc));
        splitter.unstake(1_000e18);
        vm.stopPrank();

        assertEq(usdc.balanceOf(opportunist), 980_000, "the whole net was captured around the inflow");
        assertEq(subject.balanceOf(opportunist), 1_000e18, "the borrowed principal came straight back");
        assertEq(splitter.totalStaked(), 0, "and nothing is staked afterwards");
        assertEq(usdc.balanceOf(address(liveStaking)), 20_000, "the skim still ran exactly once");

        // The capture takes only what that one recognition created: no earlier or later revenue,
        // and no other staker's position, is reachable this way.
        _stake(alice, 1_000e18);
        _deposit(usdc, 1_000_000, bytes32("later"));
        assertEq(splitter.claimable(address(usdc), opportunist), 0, "the exited capturer earns nothing after");
        assertEq(splitter.claimable(address(usdc), alice), 980_000, "the later staker keeps its own net");
        _assertSolvent();
    }

    // ------------------------------------------------------------------ SPL-011

    /// @notice SPL-011: a bare transfer is revenue only after permissionless recognition.
    function test_SPL_011_BareTransfersBecomeRevenueOnlyThroughRecognition() public {
        _stake(alice, 1_000e18);

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
        vm.prank(alice);
        splitter.unstake(aliceStake);
        _assertSolvent();
        assertEq(subject.balanceOf(alice) - aliceSubjectBefore, aliceStake, "principal returned exactly");
        assertEq(splitter.stakedOf(alice), 0, "stake fully withdrawn");

        _assertMaximumStressSequenceStaysSolvent();
    }

    /// @dev The frozen deterministic stress sequence: one wei of stake, the maximum economic
    ///      recognition for each asset, the whole remaining supply staked, then claim and unstake.
    ///      It proves the 1e36 accumulator and Solady full-precision multiplication stay live and
    ///      solvent at the widest representable ratio, which is where a naive `stake * acc`
    ///      product would overflow and a naive scale would collapse into a non-distributing carry.
    function _assertMaximumStressSequenceStaysSolvent() private {
        SubjectSplitterV1 stressed = _newSplitter();
        address dust = makeAddr("dust");
        address whale = makeAddr("stress-whale");

        subject.mint(dust, 1);
        vm.startPrank(dust);
        subject.approve(address(stressed), 1);
        stressed.stake(1);
        vm.stopPrank();

        // The maximum economic inflow per asset: uint128 for the two external assets, and the
        // launch's whole 100B supply for SUBJECT, which can never exceed it.
        uint256 externalGross = type(uint128).max;
        uint256 externalNet = externalGross - (externalGross * 200) / 10_000;
        uint256 subjectNet = TOTAL_SUPPLY - (TOTAL_SUPPLY * 200) / 10_000;
        _depositTo(stressed, usdc, externalGross, bytes32("stress-usdc"));
        _depositTo(stressed, regent, externalGross, bytes32("stress-regent"));
        _depositTo(stressed, subject, TOTAL_SUPPLY, bytes32("stress-subject"));

        // The sole dust staker owns the whole net of every asset, to the unit.
        assertEq(stressed.claimable(address(usdc), dust), externalNet, "the whole USDC net reached one wei of stake");
        assertEq(stressed.claimable(address(regent), dust), externalNet, "the whole REGENT net did too");
        assertEq(stressed.claimable(address(subject), dust), subjectNet, "and the whole SUBJECT net");

        // The rest of the supply then stakes against an accumulator at its widest value.
        subject.mint(whale, TOTAL_SUPPLY - 1);
        vm.startPrank(whale);
        subject.approve(address(stressed), TOTAL_SUPPLY - 1);
        stressed.stake(TOTAL_SUPPLY - 1);
        vm.stopPrank();

        assertEq(stressed.totalStaked(), TOTAL_SUPPLY, "the whole supply is staked");
        assertEq(stressed.claimable(address(usdc), whale), 0, "the joiner captures no prior unit");
        assertEq(stressed.claimable(address(usdc), dust), externalNet, "and the dust staker keeps all of it");

        vm.prank(dust);
        stressed.claimAll();
        vm.prank(whale);
        stressed.claimAll();

        assertEq(usdc.balanceOf(dust), externalNet, "claimed the exact USDC net");
        assertEq(regent.balanceOf(dust), externalNet, "claimed the exact REGENT net");
        assertEq(subject.balanceOf(dust), subjectNet, "claimed the exact SUBJECT net");
        assertEq(usdc.balanceOf(whale), 0, "the joiner claimed nothing");
        _assertSolventFor(stressed);

        vm.prank(dust);
        stressed.unstake(1);
        vm.prank(whale);
        stressed.unstake(TOTAL_SUPPLY - 1);

        assertEq(stressed.totalStaked(), 0, "all principal returned");
        assertEq(subject.balanceOf(whale), TOTAL_SUPPLY - 1, "the whale's principal returned exactly");
        _assertSolventFor(stressed);
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

        // Alice reduces or fully exits her position, which is where the accounting must neither
        // re-credit nor forfeit the fraction of a unit she had already earned.
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

        // The sole staker earns the whole net apart from at most the one indivisible unit that
        // stays inside protected liability as this asset's carried remainder.
        _deposit(usdc, grossBetween, bytes32("alice-only"));
        uint256 netBetween = grossBetween - (grossBetween * 200) / 10_000;
        uint256 aliceEarnedAlone = splitter.claimable(address(usdc), alice);
        assertLe(aliceEarnedAlone, netBetween, "a sole staker never earns more than the net");
        assertGe(aliceEarnedAlone + 1, netBetween, "a sole staker loses at most the carried unit");

        // Bob joins. Alice keeps every unit she had already earned; Bob starts from zero.
        _stake(bob, secondStake);
        assertEq(splitter.claimable(address(usdc), alice), aliceEarnedAlone, "prior earnings preserved exactly");
        assertEq(splitter.claimable(address(usdc), bob), 0, "the joiner captures no prior unit");

        _deposit(usdc, grossAfter, bytes32("shared"));
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

        // A full exit preserves what was earned and forfeits nothing.
        vm.prank(alice);
        splitter.unstake(firstStake);
        assertEq(splitter.claimable(address(usdc), alice), aliceAfter, "a full unstake preserves earnings");

        // Every distributed unit is covered by protected liability, and nothing was invented.
        uint256 netAfter = grossAfter - (grossAfter * 200) / 10_000;
        assertLe(aliceAfter + bobAfter, netBetween + netAfter, "no unit exists that was never recognized");
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

    /// @notice SPL-013: the deterministic stake-change counterexample. Two equal stakers, a
    ///         two-unit recognition, an equal partial unstake by each, then a one-unit
    ///         recognition. Only three units ever entered liability and balance, so aggregate
    ///         whole-unit claimability may never reach four; the half unit each staker still owns
    ///         stays inside liability until a later recognition completes it.
    function test_SPL_013_StakeChangesNeverOverCreditOrStrandWholeUnits() public {
        _stake(alice, 2);
        _stake(bob, 2);

        // Two units enter against four wei of stake: half a unit per staked wei.
        _deposit(usdc, 2, bytes32("two"));
        assertEq(splitter.unclaimedLiability(address(usdc)), 2, "the whole net became liability");

        // Each staker halves its stake, banking exactly one earned whole unit.
        vm.prank(alice);
        splitter.unstake(1);
        vm.prank(bob);
        splitter.unstake(1);
        assertEq(splitter.claimable(address(usdc), alice), 1, "Alice keeps the whole unit she earned");
        assertEq(splitter.claimable(address(usdc), bob), 1, "and Bob keeps his");

        // One more unit enters against two wei of stake: half a unit per staked wei again.
        _deposit(usdc, 1, bytes32("one"));

        uint256 liability = splitter.unclaimedLiability(address(usdc));
        assertEq(liability, 3, "exactly three units were ever recognized");
        assertEq(usdc.balanceOf(address(splitter)), 3, "and exactly three units are held");

        uint256 aliceOwed = splitter.claimable(address(usdc), alice);
        uint256 bobOwed = splitter.claimable(address(usdc), bob);
        assertEq(aliceOwed + bobOwed, 2, "a second half unit is not a second whole unit");
        assertLe(aliceOwed + bobOwed, liability, "aggregate claimability never exceeds liability");

        // The half unit each staker still owns is held as sub-unit entitlement, inside liability.
        uint256 halfUnit = splitter.SCALE() / 2;
        assertEq(splitter.claimableDust(address(usdc), alice), halfUnit, "Alice's half unit is banked, not lost");
        assertEq(splitter.claimableDust(address(usdc), bob), halfUnit, "and so is Bob's");

        // A staker joining at this checkpoint earns nothing from either recognition.
        address carol = makeAddr("carol");
        _stake(carol, 4);
        assertEq(splitter.claimable(address(usdc), carol), 0, "the joiner captures nothing retroactively");
        vm.prank(carol);
        splitter.unstake(4);

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
        _deposit(usdc, 1, bytes32("three"));
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
        subject.mint(alice, 1_000e18);
        subject.mint(bob, 1_000e18);

        vm.startPrank(alice);
        subject.approve(address(splitter), 1_000e18);
        splitter.stake(1_000e18);
        vm.stopPrank();

        assertEq(splitter.stakedOf(alice), 1_000e18, "stake credited the caller");
        assertEq(splitter.stakedOf(bob), 0, "and nobody else");

        _deposit(usdc, 1_000_000, bytes32("shared"));

        // Bob cannot unstake or claim what belongs to Alice.
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
        _stake(alice, 1_000e18);
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
    function test_SPL_016_SkimRoundingIsExactAtTheInflowBoundaryInputs() public {
        _stake(alice, 1_000e18);

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
        _stake(alice, 3);
        _deposit(usdc, 1, bytes32("carry"));
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
        _stake(alice, 1_000e18);

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
        _stake(alice, 1_000e18);
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
        _stake(alice, 3);
        _deposit(usdc, 1, bytes32("carry"));
        _deposit(regent, 1_000e18, bytes32("regent"));

        uint256 principal = splitter.totalStaked();
        uint256 carry = splitter.carriedRemainder(address(usdc));
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

    /// @dev Deposit USDC and return the net that actually became a staker liability. With nobody
    ///      staked the net goes straight to the treasury and is never owed to a staker.
    function _depositTrackingStakerNet(uint256 gross, bytes32 revenueRef) private returns (uint256 stakerNet) {
        if (splitter.totalStaked() != 0) stakerNet = gross - (gross * 200) / 10_000;
        _deposit(usdc, gross, revenueRef);
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
