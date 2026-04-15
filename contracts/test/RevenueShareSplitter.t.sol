// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

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

    address internal constant TREASURY = address(0xA11CE);
    address internal constant PROTOCOL_TREASURY = address(0xBEEF);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);
    address internal constant CAROL = address(0xC3);
    address internal constant DAVE = address(0xD4);
    address internal constant EVE = address(0xE5);
    address internal constant FUNDER = address(0xF00D);
    address internal constant NEXT_TREASURY = address(0xACCE55);
    address internal constant RANDOM_CALLER = address(0x123456);
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

    function testMainScenarioAccounting() external {
        assertEq(splitter.totalStaked(), 400 * XYZ);

        usdc.mint(address(this), INITIAL_INGRESS_DEPOSIT);
        usdc.approve(address(splitter), INITIAL_INGRESS_DEPOSIT);
        splitter.depositUSDC(INITIAL_INGRESS_DEPOSIT, bytes32("direct"), bytes32("round-1"));

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
            address(registry),
            subjectId,
            TREASURY,
            PROTOCOL_TREASURY,
            100,
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

        registry.updateSubject(subjectId, address(rotatedSplitter), TREASURY, false, "XYZ splitter v2");
        assertEq(rotatedSplitter.lastEmissionUpdate(), inactiveRotationTimestamp);

        assertApproxEqAbs(
            rotatedSplitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14
        );

        vm.warp(reactivationTimestamp);
        assertApproxEqAbs(
            rotatedSplitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14
        );

        registry.updateSubject(subjectId, address(rotatedSplitter), TREASURY, true, "XYZ splitter v2");
        assertEq(rotatedSplitter.lastEmissionUpdate(), reactivationTimestamp);

        assertApproxEqAbs(rotatedSplitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14);

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
        assertApproxEqAbs(
            splitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14
        );

        RevenueShareSplitter rotatedSplitter = new RevenueShareSplitter(
            address(stakeToken),
            address(usdc),
            address(registry),
            subjectId,
            TREASURY,
            PROTOCOL_TREASURY,
            100,
            INITIAL_SUPPLY_DENOMINATOR,
            "XYZ splitter v2",
            address(this)
        );

        uint256 rotationTime = block.timestamp;
        registry.updateSubject(subjectId, address(rotatedSplitter), TREASURY, true, "XYZ splitter v2");

        assertEq(splitter.lastEmissionUpdate(), rotationTime);
        assertApproxEqAbs(
            splitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14
        );

        vm.warp(block.timestamp + 30 days);
        assertApproxEqAbs(
            splitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14
        );

        registry.updateSubject(subjectId, address(rotatedSplitter), TREASURY, false, "XYZ splitter v2");

        vm.warp(block.timestamp + 30 days);
        assertApproxEqAbs(
            splitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14
        );

        registry.updateSubject(subjectId, address(rotatedSplitter), TREASURY, true, "XYZ splitter v2");

        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(
            splitter.previewClaimableStakeToken(ALICE), expectedBeforeRotation, 1e14
        );
        assertEq(splitter.lastEmissionUpdate(), rotationTime);
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

        vm.expectRevert("REWARD_INVENTORY_LOW");
        vm.prank(ALICE);
        splitter.claimStakeToken(ALICE);
    }

    function testClaimAndRestakeStakeTokenRevertsWhenInventoryIsShort() external {
        splitter.setEmissionAprBps(MAX_APR_BPS);
        vm.warp(block.timestamp + 365 days);

        vm.expectRevert("REWARD_INVENTORY_LOW");
        vm.prank(ALICE);
        splitter.claimAndRestakeStakeToken();
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

    function testSweepTreasuryResidualUSDCCallableByArbitraryAddress() external {
        usdc.mint(address(this), INITIAL_INGRESS_DEPOSIT);
        usdc.approve(address(splitter), INITIAL_INGRESS_DEPOSIT);
        splitter.depositUSDC(INITIAL_INGRESS_DEPOSIT, bytes32("direct"), bytes32("round-1"));

        uint256 amount = splitter.treasuryResidualUsdc();

        vm.prank(RANDOM_CALLER);
        splitter.sweepTreasuryResidualUSDC(amount);

        assertEq(usdc.balanceOf(TREASURY), amount);
        assertEq(splitter.treasuryResidualUsdc(), 0);
    }

    function testSweepProtocolReserveUSDCCallableByArbitraryAddress() external {
        usdc.mint(address(this), INITIAL_INGRESS_DEPOSIT);
        usdc.approve(address(splitter), INITIAL_INGRESS_DEPOSIT);
        splitter.depositUSDC(INITIAL_INGRESS_DEPOSIT, bytes32("direct"), bytes32("round-1"));

        uint256 amount = splitter.protocolReserveUsdc();

        vm.prank(RANDOM_CALLER);
        splitter.sweepProtocolReserveUSDC(amount);

        assertEq(usdc.balanceOf(PROTOCOL_TREASURY), amount);
        assertEq(splitter.protocolReserveUsdc(), 0);
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

    function testPausePreservesPrincipalExit() external {
        _fundStakeTokenRewards(splitter, stakeToken, 1000 * XYZ);
        splitter.setEmissionAprBps(MAX_APR_BPS);
        vm.warp(block.timestamp + 30 days);
        splitter.setPaused(true);

        vm.expectRevert("PAUSED");
        vm.prank(ALICE);
        splitter.claimStakeToken(ALICE);

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
        assertEq(stakeToken.balanceOf(ALICE), 50 * XYZ);
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
        subjectId = keccak256(abi.encodePacked(splitterLabel, token, denominator, block.timestamp));
        deployed = new RevenueShareSplitter(
            token,
            address(usdc),
            address(registry),
            subjectId,
            TREASURY,
            PROTOCOL_TREASURY,
            100,
            denominator,
            splitterLabel,
            address(this)
        );

        registry.createSubject(subjectId, token, address(deployed), TREASURY, true, splitterLabel);
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
