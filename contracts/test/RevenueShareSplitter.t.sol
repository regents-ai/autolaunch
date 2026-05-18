// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RevenueIngressAccount} from "src/revenue/RevenueIngressAccount.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareSplitter} from "src/revenue/RevenueShareSplitter.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {MintableBurnableERC20Mock} from "test/mocks/MintableBurnableERC20Mock.sol";
import {TransferFeeERC20Mock} from "test/mocks/TransferFeeERC20Mock.sol";

contract RevenueShareSplitterTest is Test {
    uint256 internal constant XYZ = 1e18;
    uint256 internal constant USDC = 1e6;
    uint256 internal constant INITIAL_SUPPLY_DENOMINATOR = 1000 * XYZ;
    uint256 internal constant INITIAL_INGRESS_DEPOSIT = 10_000 * USDC;
    uint256 internal constant SECOND_INGRESS_DEPOSIT = 5000 * USDC;
    uint256 internal constant DIRECT_DEPOSIT = 10_000 * USDC;
    uint256 internal constant ALICE_STAKE = 200 * XYZ;
    uint256 internal constant BOB_INITIAL_STAKE = 100 * XYZ;
    uint256 internal constant BOB_TOP_UP = 50 * XYZ;
    uint256 internal constant CAROL_STAKE = 50 * XYZ;
    uint256 internal constant DAVE_STAKE = 30 * XYZ;
    uint256 internal constant DAVE_UNSTAKE = 10 * XYZ;
    uint256 internal constant EVE_STAKE = 20 * XYZ;
    uint16 internal constant MAX_APR_BPS = 10_000;

    MintableBurnableERC20Mock internal stakeToken;
    MintableBurnableERC20Mock internal usdc;
    RevenueShareSplitter internal splitter;
    mapping(address => SubjectRegistry) internal registryOfSplitter;
    mapping(address => bytes32) internal subjectIdOfSplitter;

    event AccountSynced(address indexed account);
    event SubjectLifecycleSynced(bool active, bool retiring, bool retired);

    address internal constant TREASURY = address(0xA11CE);
    address internal constant PROTOCOL_TREASURY = address(0xBEEF);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);
    address internal constant CAROL = address(0xC3);
    address internal constant DAVE = address(0xD4);
    address internal constant EVE = address(0xE5);
    address internal constant FUNDER = address(0xF00D);
    address internal constant NEXT_TREASURY = address(0xACCE55);
    address internal constant INGRESS_FACTORY = address(0x5151);
    uint64 internal constant TREASURY_ROTATION_DELAY = 3 days;

    function setUp() external {
        stakeToken = new MintableBurnableERC20Mock("Agent", "XYZ", 18);
        usdc = new MintableBurnableERC20Mock("USD Coin", "USDC", 6);

        splitter = _deploySplitter(stakeToken, INITIAL_SUPPLY_DENOMINATOR, "XYZ splitter");

        stakeToken.mint(ALICE, ALICE_STAKE);
        stakeToken.mint(BOB, BOB_INITIAL_STAKE + BOB_TOP_UP);
        stakeToken.mint(CAROL, CAROL_STAKE);
        stakeToken.mint(DAVE, DAVE_STAKE);
        stakeToken.mint(EVE, EVE_STAKE);
        stakeToken.mint(TREASURY, 550 * XYZ);
        stakeToken.mint(FUNDER, 10_000 * XYZ);

        _stake(splitter, stakeToken, ALICE, ALICE_STAKE);
        _stake(splitter, stakeToken, BOB, BOB_INITIAL_STAKE);
        _stake(splitter, stakeToken, CAROL, CAROL_STAKE);
        _stake(splitter, stakeToken, DAVE, DAVE_STAKE);
        _stake(splitter, stakeToken, EVE, EVE_STAKE);
    }

    function testSyncEmitsAccountSynced() external {
        vm.expectEmit(true, false, false, true, address(splitter));
        emit AccountSynced(ALICE);

        splitter.sync(ALICE);
    }

    function testSubjectLifecycleSyncEmitsInactiveState() external {
        SubjectRegistry registry = registryOfSplitter[address(splitter)];
        bytes32 subjectId = subjectIdOfSplitter[address(splitter)];

        vm.expectEmit(false, false, false, true, address(splitter));
        emit SubjectLifecycleSynced(false, false, false);

        registry.updateSubject(subjectId, address(splitter), TREASURY, false, "XYZ splitter");
    }

    function testMainScenarioAccounting() external {
        assertEq(splitter.totalStaked(), 400 * XYZ);

        usdc.mint(address(this), INITIAL_INGRESS_DEPOSIT);
        usdc.approve(address(splitter), INITIAL_INGRESS_DEPOSIT);
        splitter.depositUSDC(INITIAL_INGRESS_DEPOSIT, bytes32("direct"), bytes32("round-1"));

        assertEq(splitter.totalUsdcReceived(), INITIAL_INGRESS_DEPOSIT);
        assertEq(splitter.directDepositUsdc(), INITIAL_INGRESS_DEPOSIT);
        assertEq(splitter.verifiedIngressUsdc(), 0);
        assertEq(splitter.protocolReserveUsdc(), 100 * USDC);
        assertEq(splitter.treasuryResidualUsdc(), 5940 * USDC);
        assertEq(splitter.previewClaimableUSDC(ALICE), 1980 * USDC);
        assertEq(splitter.previewClaimableUSDC(BOB), 990 * USDC);
        assertEq(splitter.previewClaimableUSDC(CAROL), 495 * USDC);
        assertEq(splitter.previewClaimableUSDC(DAVE), 297 * USDC);
        assertEq(splitter.previewClaimableUSDC(EVE), 198 * USDC);

        vm.prank(BOB);
        splitter.stake(BOB_TOP_UP, BOB);
        assertEq(splitter.totalStaked(), 450 * XYZ);
        assertEq(splitter.previewClaimableUSDC(BOB), 990 * USDC);

        vm.prank(DAVE);
        splitter.unstake(DAVE_UNSTAKE, DAVE);
        assertEq(splitter.totalStaked(), 440 * XYZ);
        assertEq(stakeToken.balanceOf(DAVE), DAVE_UNSTAKE);
        assertEq(splitter.previewClaimableUSDC(DAVE), 297 * USDC);

        vm.prank(ALICE);
        splitter.claimUSDC(ALICE);
        assertEq(usdc.balanceOf(ALICE), 1980 * USDC);
        assertEq(splitter.previewClaimableUSDC(ALICE), 0);

        vm.prank(CAROL);
        splitter.unstake(CAROL_STAKE, CAROL);
        assertEq(splitter.totalStaked(), 390 * XYZ);
        assertEq(stakeToken.balanceOf(CAROL), CAROL_STAKE);
        assertEq(splitter.previewClaimableUSDC(CAROL), 495 * USDC);

        usdc.mint(address(this), SECOND_INGRESS_DEPOSIT);
        usdc.approve(address(splitter), SECOND_INGRESS_DEPOSIT);
        splitter.depositUSDC(SECOND_INGRESS_DEPOSIT, bytes32("direct"), bytes32("round-2"));

        assertEq(splitter.protocolReserveUsdc(), 150 * USDC);
        assertEq(splitter.treasuryResidualUsdc(), 8_959_500_000);
        assertEq(splitter.previewClaimableUSDC(ALICE), 990 * USDC);
        assertEq(splitter.previewClaimableUSDC(BOB), 1_732_500_000);
        assertEq(splitter.previewClaimableUSDC(CAROL), 495 * USDC);
        assertEq(splitter.previewClaimableUSDC(DAVE), 396 * USDC);
        assertEq(splitter.previewClaimableUSDC(EVE), 297 * USDC);

        vm.prank(BOB);
        splitter.claimUSDC(BOB);
        assertEq(usdc.balanceOf(BOB), 1_732_500_000);
        assertEq(splitter.previewClaimableUSDC(BOB), 0);
    }

    function testTreasuryStakingIsRevenueNeutral() external {
        MintableBurnableERC20Mock controlStake =
            new MintableBurnableERC20Mock("Neutral", "NEUT", 18);
        controlStake.mint(ALICE, 100 * XYZ);
        controlStake.mint(TREASURY, 900 * XYZ);

        RevenueShareSplitter control = _deploySplitter(controlStake, 1000 * XYZ, "control");

        _stake(control, controlStake, ALICE, 100 * XYZ);
        usdc.mint(address(this), DIRECT_DEPOSIT);
        usdc.approve(address(control), type(uint256).max);
        control.depositUSDC(DIRECT_DEPOSIT, bytes32("direct"), bytes32("1"));
        uint256 treasuryTakeNoStake = control.treasuryResidualUsdc();

        MintableBurnableERC20Mock stakedStake =
            new MintableBurnableERC20Mock("Neutral2", "NEUT2", 18);
        stakedStake.mint(ALICE, 100 * XYZ);
        stakedStake.mint(TREASURY, 900 * XYZ);

        RevenueShareSplitter stakedTreasury =
            _deploySplitter(stakedStake, 1000 * XYZ, "stakedTreasury");

        _stake(stakedTreasury, stakedStake, ALICE, 100 * XYZ);
        _stake(stakedTreasury, stakedStake, TREASURY, 900 * XYZ);

        usdc.mint(address(this), DIRECT_DEPOSIT);
        usdc.approve(address(stakedTreasury), type(uint256).max);
        stakedTreasury.depositUSDC(DIRECT_DEPOSIT, bytes32("direct"), bytes32("2"));

        uint256 treasuryResidualWithStake = stakedTreasury.treasuryResidualUsdc();
        uint256 treasuryAsStaker = stakedTreasury.previewClaimableUSDC(TREASURY);

        assertEq(treasuryTakeNoStake, 8910 * USDC);
        assertEq(treasuryResidualWithStake + treasuryAsStaker, 8910 * USDC);
    }

    function testBurnDoesNotChangeFutureUsdcParticipation() external {
        usdc.mint(address(this), 1000 * USDC);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.depositUSDC(1000 * USDC, bytes32("before_burn"), bytes32("1"));
        uint256 aliceBefore = splitter.previewClaimableUSDC(ALICE);

        stakeToken.burn(TREASURY, 100 * XYZ);

        usdc.mint(address(this), 1000 * USDC);
        splitter.depositUSDC(1000 * USDC, bytes32("after_burn"), bytes32("2"));

        uint256 aliceAfter = splitter.previewClaimableUSDC(ALICE) - aliceBefore;
        assertEq(aliceAfter, 198 * USDC);
    }

    function testTokenEmissionsAccrueByTimestamp() external {
        _fundStakeTokenRewards(splitter, stakeToken, 1000 * XYZ);

        vm.prank(address(this));
        splitter.setEmissionAprBps(MAX_APR_BPS);

        vm.warp(block.timestamp + 30 days);

        uint256 expectedAlice = _expectedEmission(ALICE_STAKE, MAX_APR_BPS, 30 days);
        uint256 expectedBob = _expectedEmission(BOB_INITIAL_STAKE, MAX_APR_BPS, 30 days);

        assertEq(splitter.previewClaimableStakeToken(ALICE), expectedAlice);
        assertEq(splitter.previewClaimableStakeToken(BOB), expectedBob);
    }

    function testAprChangeMidstreamWorks() external {
        _fundStakeTokenRewards(splitter, stakeToken, 1000 * XYZ);

        splitter.setEmissionAprBps(5000);
        vm.warp(90 days);
        splitter.setEmissionAprBps(2500);
        uint256 firstPeriod = _expectedEmission(ALICE_STAKE, 5000, 90 days);
        assertApproxEqAbs(splitter.previewClaimableStakeToken(ALICE), firstPeriod, 1e14);
        vm.warp(120 days);

        uint256 expectedAlice = firstPeriod + _expectedEmission(ALICE_STAKE, 2500, 30 days);
        assertApproxEqAbs(splitter.previewClaimableStakeToken(ALICE), expectedAlice, 1e14);
    }

    function testMultipleStakersEnteringAtDifferentTimesGetCorrectTokenEmissions() external {
        MintableBurnableERC20Mock customStake = new MintableBurnableERC20Mock("Custom", "CSTM", 18);
        RevenueShareSplitter custom = _deploySplitter(customStake, 1000 * XYZ, "custom");

        customStake.mint(ALICE, 200 * XYZ);
        customStake.mint(BOB, 300 * XYZ);
        customStake.mint(FUNDER, 5000 * XYZ);

        _stake(custom, customStake, ALICE, 200 * XYZ);
        _fundStakeTokenRewards(custom, customStake, 1000 * XYZ);
        custom.setEmissionAprBps(MAX_APR_BPS);

        vm.warp(30 days);
        uint256 firstPeriodAlice = custom.previewClaimableStakeToken(ALICE);
        assertApproxEqAbs(
            firstPeriodAlice, _expectedEmission(200 * XYZ, MAX_APR_BPS, 30 days), 1e14
        );
        _stake(custom, customStake, BOB, 300 * XYZ);
        assertEq(custom.lastEmissionUpdate(), 30 days);
        vm.warp(60 days);

        uint256 expectedAlice =
            firstPeriodAlice + _expectedEmission(200 * XYZ, MAX_APR_BPS, 30 days);
        uint256 expectedBob = _expectedEmission(300 * XYZ, MAX_APR_BPS, 30 days);

        assertApproxEqAbs(custom.previewClaimableStakeToken(ALICE), expectedAlice, 1e14);
        assertApproxEqAbs(custom.previewClaimableStakeToken(BOB), expectedBob, 1e14);
    }

    function testInactiveSubjectStopsNewLifecycleWorkButPreservesExit() external {
        SubjectRegistry registry = registryOfSplitter[address(splitter)];
        bytes32 subjectId = subjectIdOfSplitter[address(splitter)];

        _fundStakeTokenRewards(splitter, stakeToken, 1000 * XYZ);
        splitter.setEmissionAprBps(MAX_APR_BPS);

        vm.warp(block.timestamp + 30 days);
        registry.updateSubject(subjectId, address(splitter), TREASURY, false, "XYZ splitter");

        uint256 expectedAlice = _expectedEmission(ALICE_STAKE, MAX_APR_BPS, 30 days);
        assertEq(splitter.previewClaimableStakeToken(ALICE), expectedAlice);

        vm.warp(block.timestamp + 60 days);
        assertEq(splitter.previewClaimableStakeToken(ALICE), expectedAlice);

        usdc.mint(address(this), 100 * USDC);
        usdc.approve(address(splitter), type(uint256).max);
        vm.expectRevert("SUBJECT_INACTIVE");
        splitter.depositUSDC(100 * USDC, bytes32("inactive"), bytes32("1"));

        vm.prank(ALICE);
        vm.expectRevert("SUBJECT_INACTIVE");
        splitter.stake(XYZ, ALICE);

        vm.prank(ALICE);
        vm.expectRevert("SUBJECT_INACTIVE");
        splitter.claimAndRestakeStakeToken();

        vm.prank(ALICE);
        uint256 claimed = splitter.claimStakeToken(ALICE);
        assertEq(claimed, expectedAlice);

        vm.prank(ALICE);
        splitter.unstake(10 * XYZ, ALICE);
        assertEq(splitter.stakedBalance(ALICE), ALICE_STAKE - 10 * XYZ);
    }

    function testRotatingToANewSplitterWhileInactiveResetsTheNewLifecycleClock() external {
        SubjectRegistry registry = registryOfSplitter[address(splitter)];
        bytes32 subjectId = subjectIdOfSplitter[address(splitter)];
        uint256 initialTimestamp = 1;
        uint256 inactiveRotationTimestamp = 86_401;
        uint256 reactivationTimestamp = 2_678_401;
        uint256 postReactivationTimestamp = 2_764_801;
        uint256 oneDay = 1 days;

        RevenueShareSplitter rotatedSplitter = new RevenueShareSplitter(
            address(stakeToken),
            address(usdc),
            INGRESS_FACTORY,
            address(registry),
            subjectId,
            TREASURY,
            PROTOCOL_TREASURY,
            INITIAL_SUPPLY_DENOMINATOR,
            "XYZ splitter v2",
            address(this)
        );

        stakeToken.mint(ALICE, ALICE_STAKE);
        vm.startPrank(ALICE);
        stakeToken.approve(address(rotatedSplitter), type(uint256).max);
        rotatedSplitter.stake(ALICE_STAKE, ALICE);
        vm.stopPrank();

        _fundStakeTokenRewards(rotatedSplitter, stakeToken, 1000 * XYZ);
        rotatedSplitter.setEmissionAprBps(MAX_APR_BPS);

        // Keep the checkpoints pinned so this regression stays focused on lifecycle handoff timing.
        assertEq(block.timestamp, initialTimestamp);

        vm.warp(inactiveRotationTimestamp);
        uint256 expectedBeforeRotation = _expectedEmission(ALICE_STAKE, MAX_APR_BPS, oneDay);
        assertApproxEqAbs(
            rotatedSplitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14
        );

        registry.updateSubject(
            subjectId, address(rotatedSplitter), TREASURY, false, "XYZ splitter v2"
        );
        assertEq(rotatedSplitter.lastEmissionUpdate(), inactiveRotationTimestamp);

        assertApproxEqAbs(
            rotatedSplitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14
        );

        vm.warp(reactivationTimestamp);
        assertApproxEqAbs(
            rotatedSplitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14
        );

        registry.updateSubject(
            subjectId, address(rotatedSplitter), TREASURY, true, "XYZ splitter v2"
        );
        assertEq(rotatedSplitter.lastEmissionUpdate(), reactivationTimestamp);

        assertApproxEqAbs(
            rotatedSplitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14
        );

        vm.warp(postReactivationTimestamp);
        uint256 expectedAfterReactivate =
            expectedBeforeRotation + _expectedEmission(ALICE_STAKE, MAX_APR_BPS, oneDay);
        assertApproxEqAbs(
            rotatedSplitter.previewClaimableStakeToken(ALICE), expectedAfterReactivate, 1e14
        );
    }

    function testRotatedAwaySplitterStopsAccruingAcrossLaterLifecycleFlips() external {
        SubjectRegistry registry = registryOfSplitter[address(splitter)];
        bytes32 subjectId = subjectIdOfSplitter[address(splitter)];

        _fundStakeTokenRewards(splitter, stakeToken, 1000 * XYZ);
        splitter.setEmissionAprBps(MAX_APR_BPS);

        vm.warp(block.timestamp + 1 days);
        uint256 expectedBeforeRotation = _expectedEmission(ALICE_STAKE, MAX_APR_BPS, 1 days);
        assertApproxEqAbs(splitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14);

        RevenueShareSplitter rotatedSplitter = new RevenueShareSplitter(
            address(stakeToken),
            address(usdc),
            INGRESS_FACTORY,
            address(registry),
            subjectId,
            TREASURY,
            PROTOCOL_TREASURY,
            INITIAL_SUPPLY_DENOMINATOR,
            "XYZ splitter v2",
            address(this)
        );

        uint256 rotationTime = block.timestamp;
        registry.updateSubject(
            subjectId, address(rotatedSplitter), TREASURY, true, "XYZ splitter v2"
        );

        assertEq(splitter.lastEmissionUpdate(), rotationTime);
        assertApproxEqAbs(splitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14);

        vm.warp(block.timestamp + 30 days);
        assertApproxEqAbs(splitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14);

        registry.updateSubject(
            subjectId, address(rotatedSplitter), TREASURY, false, "XYZ splitter v2"
        );

        vm.warp(block.timestamp + 30 days);
        assertApproxEqAbs(splitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14);

        registry.updateSubject(
            subjectId, address(rotatedSplitter), TREASURY, true, "XYZ splitter v2"
        );

        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(splitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14);
    }

    function testStakeRejectsInboundFeeOnTransferToken() external {
        TransferFeeERC20Mock taxed = new TransferFeeERC20Mock("Taxed", "TAX", 18, address(0));
        (RevenueShareSplitter taxedSplitter,,) =
            _deployCustomSplitter(address(taxed), INITIAL_SUPPLY_DENOMINATOR, "taxed-in");

        taxed.setFeeBps(500);
        taxed.setFeeTriggers(address(taxedSplitter), false, true);
        taxed.mint(ALICE, 100 * XYZ);

        vm.startPrank(ALICE);
        taxed.approve(address(taxedSplitter), type(uint256).max);
        vm.expectRevert("STAKE_TOKEN_IN_EXACT");
        taxedSplitter.stake(100 * XYZ, ALICE);
        vm.stopPrank();
    }

    function testClaimRejectsOutboundFeeOnTransferToken() external {
        TransferFeeERC20Mock taxed = new TransferFeeERC20Mock("Taxed", "TAX", 18, address(0));
        (RevenueShareSplitter taxedSplitter,,) =
            _deployCustomSplitter(address(taxed), INITIAL_SUPPLY_DENOMINATOR, "taxed-out");

        taxed.mint(ALICE, 100 * XYZ);
        taxed.mint(FUNDER, 1000 * XYZ);

        vm.startPrank(ALICE);
        taxed.approve(address(taxedSplitter), type(uint256).max);
        taxedSplitter.stake(100 * XYZ, ALICE);
        vm.stopPrank();

        vm.startPrank(FUNDER);
        taxed.approve(address(taxedSplitter), type(uint256).max);
        taxedSplitter.fundStakeTokenRewards(1000 * XYZ);
        vm.stopPrank();

        taxedSplitter.setEmissionAprBps(MAX_APR_BPS);
        vm.warp(block.timestamp + 30 days);

        taxed.setFeeBps(500);
        taxed.setFeeTriggers(address(taxedSplitter), true, false);

        vm.prank(ALICE);
        vm.expectRevert("STAKE_TOKEN_OUT_EXACT");
        taxedSplitter.claimStakeToken(ALICE);
    }

    function testClaimStakeTokenRevertsWhenInventoryIsShort() external {
        splitter.setEmissionAprBps(MAX_APR_BPS);
        vm.warp(block.timestamp + 365 days);

        assertGt(splitter.previewClaimableStakeToken(ALICE), 0);
        assertEq(splitter.previewFundedClaimableStakeToken(ALICE), 0);

        vm.expectRevert("REWARD_INVENTORY_LOW");
        vm.prank(ALICE);
        splitter.claimStakeToken(ALICE);
    }

    function testClaimAndRestakeStakeTokenRevertsWhenInventoryIsShort() external {
        splitter.setEmissionAprBps(MAX_APR_BPS);
        vm.warp(block.timestamp + 365 days);

        assertGt(splitter.previewClaimableStakeToken(ALICE), 0);
        assertEq(splitter.previewFundedClaimableStakeToken(ALICE), 0);

        vm.expectRevert("REWARD_INVENTORY_LOW");
        vm.prank(ALICE);
        splitter.claimAndRestakeStakeToken();
    }

    function testProtocolSkimIsFixedAtOnePercent() external {
        assertEq(splitter.protocolSkimBps(), 100);

        (bool success,) =
            address(splitter).call(abi.encodeWithSignature("setProtocolSkimBps(uint16)", 250));

        assertFalse(success);
        assertEq(splitter.protocolSkimBps(), 100);
    }

    function testEligibleRevenueShareProposalRulesAndCooldowns() external {
        vm.expectRevert("ELIGIBLE_SHARE_TOO_LOW");
        splitter.proposeEligibleRevenueShare(999);

        vm.expectRevert("ELIGIBLE_SHARE_STEP_TOO_LARGE");
        splitter.proposeEligibleRevenueShare(7000);

        splitter.proposeEligibleRevenueShare(8000);
        assertEq(splitter.pendingEligibleRevenueShareBps(), 8000);
        assertEq(splitter.pendingEligibleRevenueShareEta(), block.timestamp + 30 days);

        vm.expectRevert("PENDING_SHARE_EXISTS");
        splitter.proposeEligibleRevenueShare(9000);

        vm.expectRevert("SHARE_NOT_READY");
        splitter.activateEligibleRevenueShare();

        uint256 cancelTime = block.timestamp;
        splitter.cancelEligibleRevenueShare();
        assertEq(splitter.pendingEligibleRevenueShareBps(), 0);
        assertEq(splitter.eligibleRevenueShareCooldownEnd(), cancelTime + 30 days);

        vm.expectRevert("SHARE_COOLDOWN_ACTIVE");
        splitter.proposeEligibleRevenueShare(9000);

        vm.warp(block.timestamp + 30 days);
        splitter.proposeEligibleRevenueShare(9000);

        uint256 activationTime = splitter.pendingEligibleRevenueShareEta();
        vm.warp(activationTime);
        vm.prank(ALICE);
        splitter.activateEligibleRevenueShare();

        assertEq(splitter.eligibleRevenueShareBps(), 9000);
        assertEq(splitter.pendingEligibleRevenueShareBps(), 0);
        assertEq(splitter.eligibleRevenueShareCooldownEnd(), activationTime + 30 days);
    }

    function testTenPercentEligibleShareRoutesIntoReserveLane() external {
        MintableBurnableERC20Mock fullStake = new MintableBurnableERC20Mock("Full", "FULL", 18);
        RevenueShareSplitter fullSplitter = _deploySplitter(fullStake, 100 * XYZ, "full-stake");

        fullStake.mint(ALICE, 100 * XYZ);
        _stake(fullSplitter, fullStake, ALICE, 100 * XYZ);

        _stepEligibleRevenueShare(fullSplitter, 8000);
        _stepEligibleRevenueShare(fullSplitter, 6000);
        _stepEligibleRevenueShare(fullSplitter, 4000);
        _stepEligibleRevenueShare(fullSplitter, 2000);
        _stepEligibleRevenueShare(fullSplitter, 1000);

        usdc.mint(address(this), 1000 * USDC);
        usdc.approve(address(fullSplitter), type(uint256).max);
        fullSplitter.depositUSDC(1000 * USDC, bytes32("direct"), bytes32("ten-percent"));

        assertEq(fullSplitter.eligibleRevenueShareBps(), 1000);
        assertEq(fullSplitter.protocolReserveUsdc(), 10 * USDC);
        assertEq(fullSplitter.stakerEligibleInflowUsdc(), 99 * USDC);
        assertEq(fullSplitter.treasuryReservedInflowUsdc(), 891 * USDC);
        assertEq(fullSplitter.treasuryReservedUsdc(), 891 * USDC);
        assertEq(fullSplitter.previewClaimableUSDC(ALICE), 99 * USDC);
    }

    function testIngressSweepBeforeActivationUsesOldShare() external {
        (
            RevenueShareSplitter ingressSplitter,
            SubjectRegistry registry,
            RevenueIngressFactory ingressFactory,
            bytes32 subjectId
        ) = _deploySplitterWithIngressFactory("checkpoint");
        registryOfSplitter[address(ingressSplitter)] = registry;
        subjectIdOfSplitter[address(ingressSplitter)] = subjectId;

        address ingress = ingressFactory.createIngressAccount(subjectId, "default", true);
        usdc.mint(ingress, 1000 * USDC);

        ingressSplitter.proposeEligibleRevenueShare(8000);

        RevenueIngressAccount(payable(ingress)).sweepUSDC();

        assertEq(ingressSplitter.eligibleRevenueShareBps(), 10_000);
        assertEq(ingressSplitter.pendingEligibleRevenueShareBps(), 8000);
        assertEq(ingressSplitter.totalUsdcReceived(), 1000 * USDC);
        assertEq(ingressSplitter.verifiedIngressUsdc(), 1000 * USDC);
        assertEq(ingressSplitter.directDepositUsdc(), 0);
        assertEq(ingressSplitter.protocolReserveUsdc(), 10 * USDC);
        assertEq(ingressSplitter.stakerEligibleInflowUsdc(), 990 * USDC);
        assertEq(ingressSplitter.treasuryReservedInflowUsdc(), 0);
        assertEq(ingressSplitter.treasuryReservedUsdc(), 0);
        assertEq(ingressSplitter.treasuryResidualUsdc(), 990 * USDC);
    }

    function testIngressSweepAfterActivationUsesNewShareForEarlierUsdc() external {
        (
            RevenueShareSplitter ingressSplitter,
            SubjectRegistry registry,
            RevenueIngressFactory ingressFactory,
            bytes32 subjectId
        ) = _deploySplitterWithIngressFactory("sweep-after-activation");
        registryOfSplitter[address(ingressSplitter)] = registry;
        subjectIdOfSplitter[address(ingressSplitter)] = subjectId;

        address ingress = ingressFactory.createIngressAccount(subjectId, "default", true);
        usdc.mint(ingress, 1000 * USDC);

        ingressSplitter.proposeEligibleRevenueShare(8000);
        vm.warp(block.timestamp + 30 days);
        vm.prank(ALICE);
        ingressSplitter.activateEligibleRevenueShare();

        RevenueIngressAccount(payable(ingress)).sweepUSDC();

        assertEq(ingressSplitter.eligibleRevenueShareBps(), 8000);
        assertEq(ingressSplitter.protocolReserveUsdc(), 10 * USDC);
        assertEq(ingressSplitter.stakerEligibleInflowUsdc(), 792 * USDC);
        assertEq(ingressSplitter.treasuryReservedInflowUsdc(), 198 * USDC);
        assertEq(ingressSplitter.treasuryReservedUsdc(), 198 * USDC);
        assertEq(ingressSplitter.treasuryResidualUsdc(), 792 * USDC);
    }

    function testActivationDoesNotReadIngressBalances() external {
        (
            RevenueShareSplitter ingressSplitter,
            SubjectRegistry registry,
            RevenueIngressFactory ingressFactory,
            bytes32 subjectId
        ) = _deploySplitterWithIngressFactory("activation-no-balance-read");
        registryOfSplitter[address(ingressSplitter)] = registry;
        subjectIdOfSplitter[address(ingressSplitter)] = subjectId;

        address ingressA = ingressFactory.createIngressAccount(subjectId, "default", true);
        usdc.mint(ingressA, 1000 * USDC);

        ingressSplitter.proposeEligibleRevenueShare(8000);
        vm.warp(block.timestamp + 30 days);
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSignature("balanceOf(address)", ingressA),
            bytes("BALANCE_READ_BLOCKED")
        );

        ingressSplitter.activateEligibleRevenueShare();

        vm.clearMockedCalls();

        assertEq(ingressSplitter.eligibleRevenueShareBps(), 8000);
        assertEq(ingressSplitter.totalUsdcReceived(), 0);
        assertEq(usdc.balanceOf(ingressA), 1000 * USDC);
    }

    function testMultipleIngressAccountsUseCurrentShareAtSweepTime() external {
        (
            RevenueShareSplitter ingressSplitter,
            SubjectRegistry registry,
            RevenueIngressFactory ingressFactory,
            bytes32 subjectId
        ) = _deploySplitterWithIngressFactory("multi-ingress-current-share");
        registryOfSplitter[address(ingressSplitter)] = registry;
        subjectIdOfSplitter[address(ingressSplitter)] = subjectId;

        address ingressA = ingressFactory.createIngressAccount(subjectId, "default", true);
        address ingressB = ingressFactory.createIngressAccount(subjectId, "backup", false);
        usdc.mint(ingressA, 1000 * USDC);

        ingressSplitter.proposeEligibleRevenueShare(8000);
        vm.warp(block.timestamp + 30 days);
        ingressSplitter.activateEligibleRevenueShare();

        usdc.mint(ingressB, 500 * USDC);

        RevenueIngressAccount(payable(ingressA)).sweepUSDC();
        RevenueIngressAccount(payable(ingressB)).sweepUSDC();

        assertEq(ingressSplitter.protocolReserveUsdc(), 15 * USDC);
        assertEq(ingressSplitter.stakerEligibleInflowUsdc(), 1188 * USDC);
        assertEq(ingressSplitter.treasuryReservedInflowUsdc(), 297 * USDC);
        assertEq(ingressSplitter.treasuryReservedUsdc(), 297 * USDC);
        assertEq(ingressSplitter.treasuryResidualUsdc(), 1188 * USDC);
    }

    function testIngressFactoryCapsAccountsPerSubject() external {
        (,, RevenueIngressFactory ingressFactory, bytes32 subjectId) =
            _deploySplitterWithIngressFactory("ingress-cap");

        uint256 maxAccounts = ingressFactory.MAX_INGRESS_ACCOUNTS_PER_SUBJECT();
        for (uint256 i; i < maxAccounts; ++i) {
            ingressFactory.createIngressAccount(subjectId, "account", i == 0);
        }

        assertEq(ingressFactory.ingressAccountCount(subjectId), maxAccounts);

        vm.expectRevert("INGRESS_ACCOUNT_LIMIT");
        ingressFactory.createIngressAccount(subjectId, "overflow", false);
    }

    function testRewardClaimsRecoverAfterFundingArrivesLater() external {
        MintableBurnableERC20Mock customStake = new MintableBurnableERC20Mock("Recover", "RCV", 18);
        RevenueShareSplitter custom = _deploySplitter(customStake, 1000 * XYZ, "recover");

        customStake.mint(ALICE, 200 * XYZ);
        customStake.mint(BOB, 300 * XYZ);
        customStake.mint(FUNDER, 1000 * XYZ);

        _stake(custom, customStake, ALICE, 200 * XYZ);
        _stake(custom, customStake, BOB, 300 * XYZ);

        custom.setEmissionAprBps(MAX_APR_BPS);
        vm.warp(block.timestamp + 365 days);

        _fundStakeTokenRewards(custom, customStake, 300 * XYZ);

        assertEq(custom.previewFundedClaimableStakeToken(BOB), 300 * XYZ);

        vm.prank(BOB);
        uint256 bobClaim = custom.claimStakeToken(BOB);
        assertEq(bobClaim, 300 * XYZ);

        assertEq(custom.previewFundedClaimableStakeToken(ALICE), 0);
        vm.prank(ALICE);
        vm.expectRevert("REWARD_INVENTORY_LOW");
        custom.claimStakeToken(ALICE);

        _fundStakeTokenRewards(custom, customStake, 200 * XYZ);

        vm.prank(ALICE);
        uint256 aliceClaim = custom.claimStakeToken(ALICE);
        assertEq(aliceClaim, 200 * XYZ);
        assertEq(custom.previewClaimableStakeToken(ALICE), 0);
    }

    function testClaimStakeTokenTransfersAndTracksTotalClaimed() external {
        _fundStakeTokenRewards(splitter, stakeToken, 1000 * XYZ);

        splitter.setEmissionAprBps(MAX_APR_BPS);
        vm.warp(block.timestamp + 30 days);

        uint256 expected = _expectedEmission(ALICE_STAKE, MAX_APR_BPS, 30 days);

        vm.prank(ALICE);
        uint256 claimed = splitter.claimStakeToken(ALICE);

        assertEq(claimed, expected);
        assertEq(splitter.totalClaimedStakeToken(), expected);
        assertEq(stakeToken.balanceOf(ALICE), expected);
        assertEq(splitter.previewClaimableStakeToken(ALICE), 0);
    }

    function testClaimAndRestakeStakeTokenCompoundsIntoStake() external {
        _fundStakeTokenRewards(splitter, stakeToken, 1000 * XYZ);

        splitter.setEmissionAprBps(MAX_APR_BPS);
        vm.warp(block.timestamp + 30 days);

        uint256 expected = _expectedEmission(ALICE_STAKE, MAX_APR_BPS, 30 days);

        vm.prank(ALICE);
        uint256 compounded = splitter.claimAndRestakeStakeToken();

        assertEq(compounded, expected);
        assertEq(splitter.totalClaimedStakeToken(), expected);
        assertEq(splitter.stakedBalance(ALICE), ALICE_STAKE + expected);
        assertEq(splitter.previewClaimableStakeToken(ALICE), 0);
    }

    function testStakeRevertsWhenCapWouldBeExceeded() external {
        stakeToken.mint(address(0xD4D4), 601 * XYZ);

        vm.startPrank(address(0xD4D4));
        stakeToken.approve(address(splitter), type(uint256).max);
        vm.expectRevert("STAKE_CAP_EXCEEDED");
        splitter.stake(601 * XYZ, address(0xD4D4));
        vm.stopPrank();
    }

    function testClaimAndRestakeStakeTokenRevertsWhenCapWouldBeExceeded() external {
        MintableBurnableERC20Mock smallStake =
            new MintableBurnableERC20Mock("Small Agent", "sAGENT", 18);
        RevenueShareSplitter smallSplitter = _deploySplitter(smallStake, 3 * XYZ, "small-cap");

        address[3] memory stakers = [ALICE, BOB, CAROL];
        for (uint256 i = 0; i < stakers.length; ++i) {
            smallStake.mint(stakers[i], XYZ);
            vm.startPrank(stakers[i]);
            smallStake.approve(address(smallSplitter), type(uint256).max);
            smallSplitter.stake(XYZ, stakers[i]);
            vm.stopPrank();
        }

        smallStake.mint(FUNDER, 100 * XYZ);
        _fundStakeTokenRewards(smallSplitter, smallStake, 100 * XYZ);

        smallSplitter.setEmissionAprBps(MAX_APR_BPS);
        vm.warp(block.timestamp + 365 days);

        vm.prank(ALICE);
        vm.expectRevert("STAKE_CAP_EXCEEDED");
        smallSplitter.claimAndRestakeStakeToken();
    }

    function testClaimStakeTokenStillWorksWhenStakeCapIsAlreadyFull() external {
        MintableBurnableERC20Mock smallStake =
            new MintableBurnableERC20Mock("Small Agent", "sAGENT", 18);
        RevenueShareSplitter smallSplitter = _deploySplitter(smallStake, 3 * XYZ, "small-cap");

        address[3] memory stakers = [ALICE, BOB, CAROL];
        for (uint256 i = 0; i < stakers.length; ++i) {
            smallStake.mint(stakers[i], XYZ);
            vm.startPrank(stakers[i]);
            smallStake.approve(address(smallSplitter), type(uint256).max);
            smallSplitter.stake(XYZ, stakers[i]);
            vm.stopPrank();
        }

        smallStake.mint(FUNDER, 100 * XYZ);
        _fundStakeTokenRewards(smallSplitter, smallStake, 100 * XYZ);

        smallSplitter.setEmissionAprBps(MAX_APR_BPS);
        vm.warp(block.timestamp + 365 days);

        uint256 expected = _expectedEmission(XYZ, MAX_APR_BPS, 365 days);

        vm.prank(ALICE);
        uint256 claimed = smallSplitter.claimStakeToken(ALICE);

        assertEq(claimed, expected);
        assertEq(smallSplitter.totalStaked(), 3 * XYZ);
        assertEq(smallStake.balanceOf(ALICE), expected);
    }

    function testSweepTreasuryResidualUSDCIsRestrictedToTreasuryOrOwner() external {
        usdc.mint(address(this), INITIAL_INGRESS_DEPOSIT);
        usdc.approve(address(splitter), INITIAL_INGRESS_DEPOSIT);
        splitter.depositUSDC(INITIAL_INGRESS_DEPOSIT, bytes32("direct"), bytes32("round-1"));

        uint256 amount = splitter.treasuryResidualUsdc();

        vm.prank(ALICE);
        vm.expectRevert("ONLY_TREASURY");
        splitter.sweepTreasuryResidualUSDC(amount);

        vm.prank(TREASURY);
        splitter.sweepTreasuryResidualUSDC(amount);

        assertEq(usdc.balanceOf(TREASURY), amount);
        assertEq(splitter.treasuryResidualUsdc(), 0);
    }

    function testSweepTreasuryResidualUSDCRejectsZeroAmount() external {
        vm.prank(TREASURY);
        vm.expectRevert("AMOUNT_ZERO");
        splitter.sweepTreasuryResidualUSDC(0);
    }

    function testSweepProtocolReserveUSDCIsRestrictedToProtocolOrOwner() external {
        usdc.mint(address(this), INITIAL_INGRESS_DEPOSIT);
        usdc.approve(address(splitter), INITIAL_INGRESS_DEPOSIT);
        splitter.depositUSDC(INITIAL_INGRESS_DEPOSIT, bytes32("direct"), bytes32("round-1"));

        uint256 amount = splitter.protocolReserveUsdc();

        vm.prank(ALICE);
        vm.expectRevert("ONLY_PROTOCOL");
        splitter.sweepProtocolReserveUSDC(amount);

        vm.prank(PROTOCOL_TREASURY);
        splitter.sweepProtocolReserveUSDC(amount);

        assertEq(usdc.balanceOf(PROTOCOL_TREASURY), amount);
        assertEq(splitter.protocolReserveUsdc(), 0);
    }

    function testZeroValueReserveSweepsAndDustReassignRevert() external {
        vm.prank(TREASURY);
        vm.expectRevert("AMOUNT_ZERO");
        splitter.sweepTreasuryReservedUSDC(0);

        vm.prank(PROTOCOL_TREASURY);
        vm.expectRevert("AMOUNT_ZERO");
        splitter.sweepProtocolReserveUSDC(0);

        vm.expectRevert("AMOUNT_ZERO");
        splitter.reassignUndistributedDustToTreasury(0);
    }

    function testRejectsSelfRecipients() external {
        usdc.mint(address(this), INITIAL_INGRESS_DEPOSIT);
        usdc.approve(address(splitter), INITIAL_INGRESS_DEPOSIT);
        splitter.depositUSDC(INITIAL_INGRESS_DEPOSIT, bytes32("direct"), bytes32("round-1"));
        _fundStakeTokenRewards(splitter, stakeToken, 1000 * XYZ);

        stakeToken.mint(ALICE, XYZ);
        vm.startPrank(ALICE);
        stakeToken.approve(address(splitter), type(uint256).max);
        vm.expectRevert("RECEIVER_IS_SELF");
        splitter.stake(XYZ, address(splitter));

        vm.expectRevert("RECIPIENT_IS_SELF");
        splitter.claimUSDC(address(splitter));
        vm.stopPrank();

        splitter.setEmissionAprBps(MAX_APR_BPS);
        vm.warp(block.timestamp + 30 days);

        vm.expectRevert("RECIPIENT_IS_SELF");
        vm.prank(ALICE);
        splitter.claimStakeToken(address(splitter));

        vm.expectRevert("RECIPIENT_IS_SELF");
        vm.prank(ALICE);
        splitter.unstake(XYZ, address(splitter));

        vm.expectRevert("TREASURY_IS_SELF");
        splitter.proposeTreasuryRecipientRotation(address(splitter));

        vm.expectRevert("PROTOCOL_IS_SELF");
        splitter.setProtocolRecipient(address(splitter));
    }

    function testConstructorRejectsStakeTokenAsUsdc() external {
        SubjectRegistry registry = registryOfSplitter[address(splitter)];
        vm.expectRevert("STAKE_TOKEN_IS_USDC");
        new RevenueShareSplitter(
            address(usdc),
            address(usdc),
            INGRESS_FACTORY,
            address(registry),
            keccak256("bad-token-pair"),
            TREASURY,
            PROTOCOL_TREASURY,
            INITIAL_SUPPLY_DENOMINATOR,
            "bad-token-pair",
            address(this)
        );
    }

    function testDirectStakeTokenTransferBecomesRewardPoolInventory() external {
        uint256 inventoryBefore = splitter.availableStakeTokenRewardInventory();

        stakeToken.mint(address(splitter), 123 * XYZ);

        assertEq(inventoryBefore, 0);
        assertEq(splitter.stakeTokenRewardPool(), 123 * XYZ);
        assertEq(splitter.availableStakeTokenRewardInventory(), 123 * XYZ);
        assertEq(splitter.totalFundedStakeToken(), 0);
    }

    function testOwnerCanRefundStakeTokenRewardPoolWithoutTouchingPrincipal() external {
        uint256 principalBefore = splitter.totalStaked();
        stakeToken.mint(address(splitter), 123 * XYZ);

        splitter.refundStakeTokenRewardPool(23 * XYZ, FUNDER);

        assertEq(stakeToken.balanceOf(FUNDER), 10_023 * XYZ);
        assertEq(splitter.totalRewardTokenPoolRefunded(), 23 * XYZ);
        assertEq(splitter.stakeTokenRewardPool(), 100 * XYZ);
        assertEq(stakeToken.balanceOf(address(splitter)), principalBefore + 100 * XYZ);

        vm.prank(ALICE);
        splitter.unstake(ALICE_STAKE, ALICE);

        assertEq(stakeToken.balanceOf(ALICE), ALICE_STAKE);
        assertEq(stakeToken.balanceOf(address(splitter)), splitter.totalStaked() + 100 * XYZ);
    }

    function testOwnerCannotRefundMoreThanStakeTokenRewardPool() external {
        uint256 principalBefore = splitter.totalStaked();
        stakeToken.mint(address(splitter), 25 * XYZ);

        vm.expectRevert("REWARD_POOL_LOW");
        splitter.refundStakeTokenRewardPool(26 * XYZ, FUNDER);

        assertEq(splitter.stakeTokenRewardPool(), 25 * XYZ);
        assertEq(stakeToken.balanceOf(address(splitter)), principalBefore + 25 * XYZ);

        vm.prank(ALICE);
        splitter.unstake(ALICE_STAKE, ALICE);

        assertEq(stakeToken.balanceOf(ALICE), ALICE_STAKE);
    }

    function testTreasuryCanSweepStakeTokenRewardPoolWithoutTouchingPrincipal() external {
        uint256 principalBefore = splitter.totalStaked();
        _fundStakeTokenRewards(splitter, stakeToken, 50 * XYZ);
        stakeToken.mint(address(splitter), 25 * XYZ);

        assertEq(splitter.stakeTokenRewardPool(), 75 * XYZ);
        assertEq(splitter.sweepableStakeTokenRewardPool(), 75 * XYZ);

        vm.prank(TREASURY);
        vm.expectRevert("REWARD_POOL_LOW");
        splitter.sweepStakeTokenRewardPool(76 * XYZ);

        vm.prank(TREASURY);
        splitter.sweepStakeTokenRewardPool(75 * XYZ);

        assertEq(splitter.totalRewardTokenPoolSwept(), 75 * XYZ);
        assertEq(stakeToken.balanceOf(TREASURY), 550 * XYZ + 75 * XYZ);
        assertEq(splitter.stakeTokenRewardPool(), 0);
        assertEq(stakeToken.balanceOf(address(splitter)), principalBefore);

        vm.prank(ALICE);
        splitter.unstake(ALICE_STAKE, ALICE);

        assertEq(stakeToken.balanceOf(ALICE), ALICE_STAKE);
        assertEq(stakeToken.balanceOf(address(splitter)), splitter.totalStaked());
    }

    function testStakeTokenRewardPoolWithdrawalsCannotDrainAccruedRewards() external {
        _fundStakeTokenRewards(splitter, stakeToken, 50 * XYZ);
        stakeToken.mint(address(splitter), 25 * XYZ);

        splitter.setEmissionAprBps(MAX_APR_BPS);
        vm.warp(block.timestamp + 30 days);

        uint256 aliceOwed = splitter.previewClaimableStakeToken(ALICE);
        uint256 owed = aliceOwed + splitter.previewClaimableStakeToken(BOB)
            + splitter.previewClaimableStakeToken(CAROL) + splitter.previewClaimableStakeToken(DAVE)
            + splitter.previewClaimableStakeToken(EVE);
        uint256 reserved = splitter.reservedStakeTokenRewards();
        assertGt(owed, 0);
        assertGe(reserved, owed);
        assertEq(splitter.sweepableStakeTokenRewardPool(), 75 * XYZ - reserved);

        vm.prank(TREASURY);
        vm.expectRevert("REWARD_POOL_LOW");
        splitter.sweepStakeTokenRewardPool(75 * XYZ);

        vm.prank(TREASURY);
        splitter.sweepStakeTokenRewardPool(75 * XYZ - reserved);

        assertEq(splitter.stakeTokenRewardPool(), reserved);
        assertEq(splitter.sweepableStakeTokenRewardPool(), 0);

        vm.prank(ALICE);
        uint256 claimed = splitter.claimStakeToken(ALICE);

        assertEq(claimed, aliceOwed);
        assertEq(stakeToken.balanceOf(ALICE), aliceOwed);
    }

    function testStakeTokenRewardPoolWithdrawalsRejectBadCallersAndRecipients() external {
        stakeToken.mint(address(splitter), 100 * XYZ);

        vm.prank(ALICE);
        vm.expectRevert("ONLY_TREASURY");
        splitter.sweepStakeTokenRewardPool(1 * XYZ);

        vm.prank(ALICE);
        vm.expectRevert("ONLY_OWNER");
        splitter.refundStakeTokenRewardPool(1 * XYZ, FUNDER);

        vm.expectRevert("RECIPIENT_ZERO");
        splitter.refundStakeTokenRewardPool(1 * XYZ, address(0));

        vm.expectRevert("RECIPIENT_IS_SELF");
        splitter.refundStakeTokenRewardPool(1 * XYZ, address(splitter));

        vm.expectRevert("AMOUNT_ZERO");
        splitter.refundStakeTokenRewardPool(0, FUNDER);
    }

    function testSurplusUsdcCanBeSwept() external {
        usdc.mint(address(splitter), 100 * USDC);

        assertEq(splitter.surplusUsdc(), 100 * USDC);

        vm.prank(TREASURY);
        splitter.sweepSurplusUSDC(100 * USDC, TREASURY);

        assertEq(usdc.balanceOf(TREASURY), 100 * USDC);
        assertEq(splitter.totalSurplusUsdcSwept(), 100 * USDC);
        assertEq(splitter.surplusUsdc(), 0);
    }

    function testSurplusUsdcCanBeRedepositedIntoSplitterAccounting() external {
        usdc.mint(address(splitter), 1000 * USDC);

        splitter.redepositSurplusUSDC(1000 * USDC, bytes32("surplus"), bytes32("manual-redeposit"));

        assertEq(splitter.surplusUsdc(), 0);
        assertEq(splitter.totalSurplusUsdcRedeposited(), 1000 * USDC);
        assertEq(splitter.surplusRedepositUsdc(), 1000 * USDC);
        assertEq(splitter.protocolReserveUsdc(), 10 * USDC);
        assertEq(splitter.previewClaimableUSDC(ALICE), 198 * USDC);
        assertEq(splitter.treasuryResidualUsdc(), 594 * USDC);
        assertEq(splitter.reservedUsdc(), usdc.balanceOf(address(splitter)));
    }

    function testTreasuryRecipientRotationDelay() external {
        uint64 currentTime = uint64(block.timestamp);

        splitter.proposeTreasuryRecipientRotation(NEXT_TREASURY);

        assertEq(splitter.pendingTreasuryRecipient(), NEXT_TREASURY);
        assertEq(splitter.pendingTreasuryRecipientEta(), currentTime + TREASURY_ROTATION_DELAY);
        assertEq(splitter.treasuryRecipient(), TREASURY);
    }

    function testCancelTreasuryRecipientRotation() external {
        splitter.proposeTreasuryRecipientRotation(NEXT_TREASURY);
        splitter.cancelTreasuryRecipientRotation();

        assertEq(splitter.pendingTreasuryRecipient(), address(0));
        assertEq(splitter.pendingTreasuryRecipientEta(), 0);
        assertEq(splitter.treasuryRecipient(), TREASURY);
    }

    function testExecuteTreasuryRecipientRotationAfterDelay() external {
        splitter.proposeTreasuryRecipientRotation(NEXT_TREASURY);

        vm.warp(block.timestamp + TREASURY_ROTATION_DELAY);
        splitter.executeTreasuryRecipientRotation();

        assertEq(splitter.treasuryRecipient(), NEXT_TREASURY);
        assertEq(splitter.pendingTreasuryRecipient(), address(0));
        assertEq(splitter.pendingTreasuryRecipientEta(), 0);
    }

    function testStakerClaimsRemainUnaffectedDuringTreasuryRotation() external {
        usdc.mint(address(this), INITIAL_INGRESS_DEPOSIT);
        usdc.approve(address(splitter), INITIAL_INGRESS_DEPOSIT);
        splitter.depositUSDC(INITIAL_INGRESS_DEPOSIT, bytes32("direct"), bytes32("round-1"));

        splitter.proposeTreasuryRecipientRotation(NEXT_TREASURY);

        vm.prank(ALICE);
        uint256 claimed = splitter.claimUSDC(ALICE);

        assertEq(claimed, 1980 * USDC);
        assertEq(usdc.balanceOf(ALICE), 1980 * USDC);
        assertEq(splitter.treasuryRecipient(), TREASURY);
    }

    function testDirectTransferCreatesSurplusButNoClaimableUsdc() external {
        usdc.mint(address(splitter), 1000 * USDC);

        assertEq(splitter.surplusUsdc(), 1000 * USDC);
        assertEq(splitter.reservedUsdc(), 0);
        assertEq(splitter.previewClaimableUSDC(ALICE), 0);
        assertEq(splitter.totalUsdcReceived(), 0);
    }

    function testRedepositSurplusCreditsStakersTreasuryAndProtocol() external {
        usdc.mint(address(splitter), 1000 * USDC);

        splitter.redepositSurplusUSDC(1000 * USDC, bytes32("surplus"), bytes32("manual"));

        assertEq(splitter.totalUsdcReceived(), 1000 * USDC);
        assertEq(splitter.surplusRedepositUsdc(), 1000 * USDC);
        assertEq(splitter.totalSurplusUsdcRedeposited(), 1000 * USDC);
        assertEq(splitter.protocolReserveUsdc(), 10 * USDC);
        assertEq(splitter.totalUsdcCreditedToStakers(), 396 * USDC);
        assertEq(splitter.previewClaimableUSDC(ALICE), 198 * USDC);
        assertEq(splitter.previewClaimableUSDC(BOB), 99 * USDC);
        assertEq(splitter.treasuryResidualUsdc(), 594 * USDC);
        assertEq(splitter.reservedUsdc(), 1000 * USDC);
        assertEq(splitter.surplusUsdc(), 0);
    }

    function testSweepSurplusCannotWithdrawReservedSplitterUsdc() external {
        usdc.mint(address(this), 1000 * USDC);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.depositUSDC(1000 * USDC, bytes32("direct"), bytes32("round-1"));

        assertEq(splitter.reservedUsdc(), 1000 * USDC);
        assertEq(splitter.surplusUsdc(), 0);

        vm.expectRevert("SURPLUS_BALANCE_LOW");
        splitter.sweepSurplusUSDC(1, TREASURY);

        usdc.mint(address(splitter), 10 * USDC);
        vm.prank(TREASURY);
        splitter.sweepSurplusUSDC(10 * USDC, TREASURY);

        assertEq(usdc.balanceOf(TREASURY), 10 * USDC);
        assertEq(splitter.reservedUsdc(), 1000 * USDC);
        assertEq(splitter.totalSurplusUsdcSwept(), 10 * USDC);
    }

    function testClaimUsdcReducesSplitterReservedUsdc() external {
        usdc.mint(address(splitter), 1000 * USDC);
        splitter.redepositSurplusUSDC(1000 * USDC, bytes32("surplus"), bytes32("manual"));

        assertEq(splitter.reservedUsdc(), 1000 * USDC);

        vm.prank(ALICE);
        splitter.claimUSDC(ALICE);

        assertEq(splitter.totalClaimedUsdc(), 198 * USDC);
        assertEq(splitter.reservedUsdc(), 802 * USDC);
        assertEq(usdc.balanceOf(address(splitter)), 802 * USDC);
    }

    function testSplitterUsdcRecoveryRejectsSelfAndZero() external {
        usdc.mint(address(splitter), 1000 * USDC);
        splitter.redepositSurplusUSDC(1000 * USDC, bytes32("surplus"), bytes32("manual"));
        usdc.mint(address(splitter), 10 * USDC);

        vm.prank(ALICE);
        vm.expectRevert("RECIPIENT_IS_SELF");
        splitter.claimUSDC(address(splitter));

        vm.expectRevert("AMOUNT_ZERO");
        splitter.sweepTreasuryResidualUSDC(0);

        vm.expectRevert("RECIPIENT_IS_SELF");
        splitter.sweepSurplusUSDC(10 * USDC, address(splitter));
    }

    function testPausePreservesPrincipalExit() external {
        usdc.mint(address(this), INITIAL_INGRESS_DEPOSIT);
        usdc.approve(address(splitter), INITIAL_INGRESS_DEPOSIT);
        splitter.depositUSDC(INITIAL_INGRESS_DEPOSIT, bytes32("direct"), bytes32("pause"));
        _fundStakeTokenRewards(splitter, stakeToken, 1000 * XYZ);
        splitter.setEmissionAprBps(MAX_APR_BPS);
        vm.warp(block.timestamp + 30 days);
        splitter.setPaused(true);

        vm.prank(ALICE);
        uint256 usdcClaimed = splitter.claimUSDC(ALICE);
        assertGt(usdcClaimed, 0);

        vm.prank(ALICE);
        uint256 claimed = splitter.claimStakeToken(ALICE);
        assertGt(claimed, 0);

        vm.expectRevert("PAUSED");
        vm.prank(ALICE);
        splitter.claimAndRestakeStakeToken();

        vm.expectRevert("PAUSED");
        vm.prank(ALICE);
        splitter.stake(1 * XYZ, ALICE);

        vm.expectRevert("PAUSED");
        vm.prank(FUNDER);
        splitter.fundStakeTokenRewards(1 * XYZ);

        vm.prank(ALICE);
        splitter.unstake(50 * XYZ, ALICE);

        assertEq(splitter.stakedBalance(ALICE), ALICE_STAKE - 50 * XYZ);
        assertEq(stakeToken.balanceOf(ALICE), 50 * XYZ + claimed);
    }

    function testTopUpsByAnyCallerIncreaseRewardInventoryOnly() external {
        uint256 inventoryBefore = splitter.availableStakeTokenRewardInventory();

        _fundStakeTokenRewards(splitter, stakeToken, 123 * XYZ);

        assertEq(splitter.availableStakeTokenRewardInventory(), inventoryBefore + 123 * XYZ);
        assertEq(splitter.totalFundedStakeToken(), 123 * XYZ);
        assertEq(splitter.totalStaked(), 400 * XYZ);
    }

    function testLiabilityTracksMaterializedRoundedClaims() external {
        MintableBurnableERC20Mock smallStake =
            new MintableBurnableERC20Mock("Small Agent", "sAGENT", 18);
        RevenueShareSplitter smallSplitter = _deploySplitter(smallStake, 3 * XYZ, "small-splitter");

        address[3] memory stakers = [ALICE, BOB, CAROL];
        for (uint256 i = 0; i < stakers.length; ++i) {
            smallStake.mint(stakers[i], XYZ);
            vm.startPrank(stakers[i]);
            smallStake.approve(address(smallSplitter), type(uint256).max);
            smallSplitter.stake(XYZ, stakers[i]);
            vm.stopPrank();
        }

        smallStake.mint(FUNDER, 100 * XYZ);
        _fundStakeTokenRewards(smallSplitter, smallStake, 100 * XYZ);

        smallSplitter.setEmissionAprBps(MAX_APR_BPS);
        vm.warp(block.timestamp + 2 days);

        for (uint256 i = 0; i < stakers.length; ++i) {
            smallSplitter.sync(stakers[i]);
        }

        uint256 expectedLiability = smallSplitter.previewClaimableStakeToken(ALICE)
            + smallSplitter.previewClaimableStakeToken(BOB)
            + smallSplitter.previewClaimableStakeToken(CAROL);
        assertEq(smallSplitter.unclaimedStakeTokenLiability(), expectedLiability);
    }

    function testUnsupportedRewardTokenDoesNotGetProtocolCredit() external {
        MintableBurnableERC20Mock junk = new MintableBurnableERC20Mock("Junk", "JUNK", 18);
        junk.mint(address(this), 1e18);

        assertEq(splitter.previewClaimableUSDC(ALICE), 0);
        junk.transfer(TREASURY, 1e18);

        assertEq(junk.balanceOf(TREASURY), 1e18);
        assertEq(splitter.previewClaimableUSDC(ALICE), 0);
    }

    function testOwnerCanRescueUnsupportedAssetsButNotCanonicalOnes() external {
        MintableBurnableERC20Mock junk = new MintableBurnableERC20Mock("Junk", "JUNK", 18);
        junk.mint(address(splitter), 3e18);
        vm.deal(address(splitter), 1 ether);

        splitter.rescueUnsupportedToken(address(junk), 3e18, TREASURY);
        splitter.rescueNative(PROTOCOL_TREASURY);

        assertEq(junk.balanceOf(TREASURY), 3e18);
        assertEq(address(splitter).balance, 0);
        assertEq(address(PROTOCOL_TREASURY).balance, 1 ether);

        vm.expectRevert("PROTECTED_TOKEN");
        splitter.rescueUnsupportedToken(address(usdc), 1, TREASURY);
    }

    function testZeroDepositReverts() external {
        vm.expectRevert("AMOUNT_ZERO");
        splitter.depositUSDC(0, bytes32("direct"), bytes32("zero"));
    }

    function testClaimWithoutRewardsReturnsZero() external {
        vm.prank(ALICE);
        uint256 claimed = splitter.claimUSDC(ALICE);

        assertEq(claimed, 0);
        assertEq(usdc.balanceOf(ALICE), 0);
    }

    function testDepositWithoutStakersLeavesNetInTreasury() external {
        RevenueShareSplitter emptySplitter =
            _deploySplitter(stakeToken, INITIAL_SUPPLY_DENOMINATOR, "empty");

        usdc.mint(address(this), 1000 * USDC);
        usdc.approve(address(emptySplitter), type(uint256).max);
        emptySplitter.depositUSDC(1000 * USDC, bytes32("direct"), bytes32("no-stakers"));

        assertEq(emptySplitter.protocolReserveUsdc(), 10 * USDC);
        assertEq(emptySplitter.treasuryResidualUsdc(), 990 * USDC);
        assertEq(emptySplitter.previewClaimableUSDC(ALICE), 0);
    }

    function testFuzzSingleStakerUsdcAccountingConservesDeposits(
        uint256 stakeAmount,
        uint256 depositAmount
    ) external {
        stakeAmount = bound(stakeAmount, 1, INITIAL_SUPPLY_DENOMINATOR);
        depositAmount = bound(depositAmount, 1, 1_000_000_000 * USDC);

        MintableBurnableERC20Mock customStake =
            new MintableBurnableERC20Mock("Fuzz Agent", "FUZ", 18);
        RevenueShareSplitter fuzzSplitter =
            _deploySplitter(customStake, INITIAL_SUPPLY_DENOMINATOR, "fuzz");

        customStake.mint(ALICE, stakeAmount);
        _stake(fuzzSplitter, customStake, ALICE, stakeAmount);

        usdc.mint(address(this), depositAmount);
        usdc.approve(address(fuzzSplitter), type(uint256).max);
        fuzzSplitter.depositUSDC(depositAmount, bytes32("fuzz"), bytes32("single"));

        uint256 tracked = fuzzSplitter.protocolReserveUsdc() + fuzzSplitter.treasuryResidualUsdc()
            + fuzzSplitter.previewClaimableUSDC(ALICE);
        assertEq(usdc.balanceOf(address(fuzzSplitter)), tracked);
        assertEq(
            fuzzSplitter.protocolReserveUsdc() + fuzzSplitter.stakerEligibleInflowUsdc()
                + fuzzSplitter.treasuryReservedInflowUsdc(),
            depositAmount
        );
    }

    function _deploySplitter(
        MintableBurnableERC20Mock token,
        uint256 denominator,
        string memory splitterLabel
    ) internal returns (RevenueShareSplitter) {
        (RevenueShareSplitter deployed, SubjectRegistry registry, bytes32 subjectId) =
            _deployCustomSplitter(address(token), denominator, splitterLabel);
        registryOfSplitter[address(deployed)] = registry;
        subjectIdOfSplitter[address(deployed)] = subjectId;
        return deployed;
    }

    function _deployCustomSplitter(address token, uint256 denominator, string memory splitterLabel)
        internal
        returns (RevenueShareSplitter deployed, SubjectRegistry registry, bytes32 subjectId)
    {
        registry = new SubjectRegistry(address(this));
        RevenueIngressFactory ingressFactory =
            new RevenueIngressFactory(address(usdc), address(registry), address(this));
        subjectId = keccak256(abi.encodePacked(splitterLabel, token, denominator, block.timestamp));
        deployed = new RevenueShareSplitter(
            token,
            address(usdc),
            address(ingressFactory),
            address(registry),
            subjectId,
            TREASURY,
            PROTOCOL_TREASURY,
            denominator,
            splitterLabel,
            address(this)
        );

        registry.createSubject(subjectId, token, address(deployed), TREASURY, true, splitterLabel);
    }

    function _deploySplitterWithIngressFactory(string memory splitterLabel)
        internal
        returns (
            RevenueShareSplitter deployed,
            SubjectRegistry registry,
            RevenueIngressFactory ingressFactory,
            bytes32 subjectId
        )
    {
        registry = new SubjectRegistry(address(this));
        ingressFactory = new RevenueIngressFactory(address(usdc), address(registry), address(this));
        subjectId =
            keccak256(abi.encodePacked(splitterLabel, address(ingressFactory), block.timestamp));
        deployed = new RevenueShareSplitter(
            address(stakeToken),
            address(usdc),
            address(ingressFactory),
            address(registry),
            subjectId,
            TREASURY,
            PROTOCOL_TREASURY,
            INITIAL_SUPPLY_DENOMINATOR,
            splitterLabel,
            address(this)
        );

        registry.createSubject(
            subjectId, address(stakeToken), address(deployed), TREASURY, true, splitterLabel
        );
    }

    function _stepEligibleRevenueShare(RevenueShareSplitter targetSplitter, uint16 nextShareBps)
        internal
    {
        uint256 cooldownEnd = targetSplitter.eligibleRevenueShareCooldownEnd();
        if (cooldownEnd > block.timestamp) {
            vm.warp(cooldownEnd);
        }
        targetSplitter.proposeEligibleRevenueShare(nextShareBps);
        vm.warp(targetSplitter.pendingEligibleRevenueShareEta());
        targetSplitter.activateEligibleRevenueShare();
    }

    function _stake(
        RevenueShareSplitter targetSplitter,
        MintableBurnableERC20Mock token,
        address account,
        uint256 amount
    ) internal {
        vm.startPrank(account);
        token.approve(address(targetSplitter), type(uint256).max);
        targetSplitter.stake(amount, account);
        vm.stopPrank();
    }

    function _fundStakeTokenRewards(
        RevenueShareSplitter targetSplitter,
        MintableBurnableERC20Mock token,
        uint256 amount
    ) internal {
        vm.startPrank(FUNDER);
        token.approve(address(targetSplitter), type(uint256).max);
        targetSplitter.fundStakeTokenRewards(amount);
        vm.stopPrank();
    }

    function _expectedEmission(uint256 amount, uint256 aprBps, uint256 elapsed)
        internal
        pure
        returns (uint256)
    {
        return (amount * aprBps * elapsed) / 10_000 / 365 days;
    }
}
