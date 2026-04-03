// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RegentRevenueStaking} from "src/revenue/RegentRevenueStaking.sol";
import {MintableBurnableERC20Mock} from "test/mocks/MintableBurnableERC20Mock.sol";

contract RegentRevenueStakingTest is Test {
    uint256 internal constant REGENT = 1e18;
    uint256 internal constant USDC = 1e6;
    uint16 internal constant STAKER_SHARE_BPS = 7000;
    uint256 internal constant REVENUE_SHARE_SUPPLY_DENOMINATOR = 1000 * REGENT;
    uint16 internal constant MAX_APR_BPS = 2000;

    address internal constant OWNER = address(0xA11CE);
    address internal constant TREASURY = address(0xBEEF);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);
    address internal constant CAROL = address(0xC3);
    address internal constant FUNDER = address(0xF00D);

    MintableBurnableERC20Mock internal regent;
    MintableBurnableERC20Mock internal usdc;
    RegentRevenueStaking internal staking;

    function setUp() external {
        regent = new MintableBurnableERC20Mock("Regent", "REGENT", 18);
        usdc = new MintableBurnableERC20Mock("USD Coin", "USDC", 6);

        staking = new RegentRevenueStaking(
            address(regent),
            address(usdc),
            TREASURY,
            STAKER_SHARE_BPS,
            REVENUE_SHARE_SUPPLY_DENOMINATOR,
            OWNER
        );

        regent.mint(ALICE, 200 * REGENT);
        regent.mint(BOB, 300 * REGENT);
        regent.mint(CAROL, 500 * REGENT);
        regent.mint(FUNDER, 10_000 * REGENT);
    }

    function testSingleStakerDepositAndClaimUsesFixedSupplyDenominator() external {
        _stake(ALICE, 200 * REGENT);

        usdc.mint(address(this), 1000 * USDC);
        usdc.approve(address(staking), type(uint256).max);
        staking.depositUSDC(1000 * USDC, bytes32("manual"), bytes32("round-1"));

        assertEq(staking.totalRecognizedRewardsUsdc(), 1000 * USDC);
        assertEq(staking.previewClaimableUSDC(ALICE), 140 * USDC);
        assertEq(staking.treasuryResidualUsdc(), 860 * USDC);

        vm.prank(ALICE);
        uint256 claimed = staking.claimUSDC(ALICE);

        assertEq(claimed, 140 * USDC);
        assertEq(usdc.balanceOf(ALICE), 140 * USDC);
        assertEq(staking.previewClaimableUSDC(ALICE), 0);
    }

    function testMultipleStakersReceiveProRataShareAcrossDeposits() external {
        _stake(ALICE, 200 * REGENT);
        _stake(BOB, 300 * REGENT);

        usdc.mint(address(this), 1000 * USDC);
        usdc.approve(address(staking), type(uint256).max);
        staking.depositUSDC(1000 * USDC, bytes32("manual"), bytes32("round-1"));

        assertEq(staking.previewClaimableUSDC(ALICE), 140 * USDC);
        assertEq(staking.previewClaimableUSDC(BOB), 210 * USDC);
        assertEq(staking.treasuryResidualUsdc(), 650 * USDC);

        _stake(CAROL, 500 * REGENT);

        usdc.mint(address(this), 500 * USDC);
        staking.depositUSDC(500 * USDC, bytes32("manual"), bytes32("round-2"));

        assertEq(staking.previewClaimableUSDC(ALICE), 210 * USDC);
        assertEq(staking.previewClaimableUSDC(BOB), 315 * USDC);
        assertEq(staking.previewClaimableUSDC(CAROL), 175 * USDC);
        assertEq(staking.treasuryResidualUsdc(), 800 * USDC);
    }

    function testBurningTokensElsewhereDoesNotChangeUsdcParticipation() external {
        _stake(ALICE, 200 * REGENT);

        usdc.mint(address(this), 1000 * USDC);
        usdc.approve(address(staking), type(uint256).max);
        staking.depositUSDC(1000 * USDC, bytes32("manual"), bytes32("round-1"));
        uint256 aliceBefore = staking.previewClaimableUSDC(ALICE);

        regent.burn(CAROL, 500 * REGENT);

        usdc.mint(address(this), 1000 * USDC);
        staking.depositUSDC(1000 * USDC, bytes32("manual"), bytes32("round-2"));

        uint256 aliceAfter = staking.previewClaimableUSDC(ALICE) - aliceBefore;
        assertEq(aliceAfter, 140 * USDC);
    }

    function testNoStakersLeavesFullDepositInTreasuryResidual() external {
        usdc.mint(address(this), 200 * USDC);
        usdc.approve(address(staking), type(uint256).max);
        staking.depositUSDC(200 * USDC, bytes32("manual"), bytes32("round-1"));

        assertEq(staking.previewClaimableUSDC(ALICE), 0);
        assertEq(staking.treasuryResidualUsdc(), 200 * USDC);
    }

    function testTreasuryWithdrawalIsRestricted() external {
        _stake(ALICE, 100 * REGENT);
        usdc.mint(address(this), 100 * USDC);
        usdc.approve(address(staking), type(uint256).max);
        staking.depositUSDC(100 * USDC, bytes32("manual"), bytes32("round-1"));

        vm.expectRevert("ONLY_TREASURY");
        vm.prank(ALICE);
        staking.withdrawTreasuryResidual(10 * USDC, TREASURY);

        vm.prank(TREASURY);
        staking.withdrawTreasuryResidual(93 * USDC, TREASURY);

        assertEq(usdc.balanceOf(TREASURY), 93 * USDC);
        assertEq(staking.treasuryResidualUsdc(), 0);
    }

    function testEmissionAprAccruesAndClaimTransfersRegent() external {
        _stake(ALICE, 100 * REGENT);
        _fundRegentRewards(1000 * REGENT);

        vm.prank(OWNER);
        staking.setEmissionAprBps(MAX_APR_BPS);

        vm.warp(block.timestamp + 30 days);

        uint256 expected = _expectedEmission(100 * REGENT, MAX_APR_BPS, 30 days);
        assertEq(staking.previewClaimableRegent(ALICE), expected);

        vm.prank(ALICE);
        uint256 claimed = staking.claimRegent(ALICE);

        assertEq(claimed, expected);
        assertEq(staking.totalClaimedRegent(), expected);
        assertEq(regent.balanceOf(ALICE), 100 * REGENT + expected);
        assertEq(staking.previewClaimableRegent(ALICE), 0);
    }

    function testAprChangeMidstreamSettlesUsingBothRates() external {
        _stake(ALICE, 1000 * REGENT / 10);
        _fundRegentRewards(1000 * REGENT);

        vm.prank(OWNER);
        staking.setEmissionAprBps(1500);

        vm.warp(150 days);

        vm.prank(OWNER);
        staking.setEmissionAprBps(1000);

        vm.warp(210 days);

        uint256 expected = _expectedEmission(100 * REGENT, 1500, 150 days)
            + _expectedEmission(100 * REGENT, 1000, 60 days);
        assertApproxEqAbs(staking.previewClaimableRegent(ALICE), expected, 1e14);
    }

    function testNoStakerIntervalAccruesZeroRegentEmissions() external {
        _fundRegentRewards(1000 * REGENT);

        vm.prank(OWNER);
        staking.setEmissionAprBps(MAX_APR_BPS);

        vm.warp(block.timestamp + 30 days);

        assertEq(staking.totalEmittedRegent(), 0);

        _stake(ALICE, 100 * REGENT);
        assertEq(staking.previewClaimableRegent(ALICE), 0);
    }

    function testClaimRegentRevertsWhenInventoryIsShort() external {
        _stake(ALICE, 100 * REGENT);

        vm.prank(OWNER);
        staking.setEmissionAprBps(MAX_APR_BPS);

        vm.warp(block.timestamp + 365 days);

        vm.expectRevert("REWARD_INVENTORY_LOW");
        vm.prank(ALICE);
        staking.claimRegent(ALICE);
    }

    function testClaimAndRestakeRegentRevertsWhenInventoryIsShort() external {
        _stake(ALICE, 100 * REGENT);

        vm.prank(OWNER);
        staking.setEmissionAprBps(MAX_APR_BPS);

        vm.warp(block.timestamp + 365 days);

        vm.expectRevert("REWARD_INVENTORY_LOW");
        vm.prank(ALICE);
        staking.claimAndRestakeRegent();
    }

    function testClaimAndRestakeRegentCompoundsIntoPrincipal() external {
        _stake(ALICE, 100 * REGENT);
        _fundRegentRewards(1000 * REGENT);

        vm.prank(OWNER);
        staking.setEmissionAprBps(MAX_APR_BPS);

        vm.warp(block.timestamp + 30 days);

        uint256 expected = _expectedEmission(100 * REGENT, MAX_APR_BPS, 30 days);

        vm.prank(ALICE);
        uint256 compounded = staking.claimAndRestakeRegent();

        assertEq(compounded, expected);
        assertEq(staking.totalClaimedRegent(), expected);
        assertEq(staking.stakedBalance(ALICE), 100 * REGENT + expected);
        assertEq(staking.totalStaked(), 100 * REGENT + expected);
        assertEq(staking.previewClaimableRegent(ALICE), 0);
        assertEq(regent.balanceOf(ALICE), 100 * REGENT);
    }

    function testPauseBlocksFundingClaimsAndStakeButNotUnstake() external {
        _stake(ALICE, 100 * REGENT);
        _fundRegentRewards(1000 * REGENT);

        vm.prank(OWNER);
        staking.setEmissionAprBps(MAX_APR_BPS);

        vm.warp(block.timestamp + 30 days);

        vm.prank(OWNER);
        staking.setPaused(true);

        vm.expectRevert("PAUSED");
        vm.prank(ALICE);
        staking.claimRegent(ALICE);

        vm.expectRevert("PAUSED");
        vm.prank(ALICE);
        staking.claimAndRestakeRegent();

        vm.expectRevert("PAUSED");
        vm.prank(ALICE);
        staking.stake(1 * REGENT, ALICE);

        vm.expectRevert("PAUSED");
        staking.depositUSDC(1 * USDC, bytes32("manual"), bytes32("round-1"));

        vm.expectRevert("PAUSED");
        vm.prank(FUNDER);
        staking.fundRegentRewards(1 * REGENT);

        vm.prank(ALICE);
        staking.unstake(50 * REGENT, ALICE);

        assertEq(staking.stakedBalance(ALICE), 50 * REGENT);
        assertEq(regent.balanceOf(ALICE), 150 * REGENT);
    }

    function testUnstakeStillWorksWhileRegentClaimsAreUnderfunded() external {
        _stake(ALICE, 100 * REGENT);

        vm.prank(OWNER);
        staking.setEmissionAprBps(MAX_APR_BPS);

        vm.warp(block.timestamp + 365 days);

        vm.prank(ALICE);
        staking.unstake(50 * REGENT, ALICE);

        assertEq(staking.stakedBalance(ALICE), 50 * REGENT);
        assertEq(regent.balanceOf(ALICE), 150 * REGENT);
    }

    function testFundingIncreasesAvailableRewardInventoryWithoutChangingStake() external {
        _stake(ALICE, 100 * REGENT);
        uint256 initialInventory = staking.availableRegentRewardInventory();

        _fundRegentRewards(250 * REGENT);

        assertEq(staking.availableRegentRewardInventory(), initialInventory + 250 * REGENT);
        assertEq(staking.stakedBalance(ALICE), 100 * REGENT);
        assertEq(staking.totalFundedRegent(), 250 * REGENT);
    }

    function testLiabilityTracksMaterializedRoundedClaims() external {
        MintableBurnableERC20Mock smallRegent =
            new MintableBurnableERC20Mock("Small Regent", "sREGENT", 18);
        RegentRevenueStaking smallStaking = new RegentRevenueStaking(
            address(smallRegent), address(usdc), TREASURY, STAKER_SHARE_BPS, 3 * REGENT, OWNER
        );

        address[3] memory stakers = [ALICE, BOB, CAROL];
        for (uint256 i = 0; i < stakers.length; ++i) {
            smallRegent.mint(stakers[i], REGENT);
            vm.startPrank(stakers[i]);
            smallRegent.approve(address(smallStaking), type(uint256).max);
            smallStaking.stake(REGENT, stakers[i]);
            vm.stopPrank();
        }

        smallRegent.mint(FUNDER, 100 * REGENT);
        vm.startPrank(FUNDER);
        smallRegent.approve(address(smallStaking), type(uint256).max);
        smallStaking.fundRegentRewards(100 * REGENT);
        vm.stopPrank();

        vm.prank(OWNER);
        smallStaking.setEmissionAprBps(MAX_APR_BPS);
        vm.warp(block.timestamp + 10 days);

        for (uint256 i = 0; i < stakers.length; ++i) {
            smallStaking.sync(stakers[i]);
        }

        uint256 expectedLiability = smallStaking.previewClaimableRegent(ALICE)
            + smallStaking.previewClaimableRegent(BOB) + smallStaking.previewClaimableRegent(CAROL);
        assertEq(smallStaking.unclaimedRegentLiability(), expectedLiability);
    }

    function testClaimWithoutRewardsReturnsZero() external {
        _stake(ALICE, 100 * REGENT);

        vm.prank(ALICE);
        uint256 claimed = staking.claimUSDC(ALICE);

        assertEq(claimed, 0);
    }

    function _stake(address account, uint256 amount) internal {
        vm.startPrank(account);
        regent.approve(address(staking), type(uint256).max);
        staking.stake(amount, account);
        vm.stopPrank();
    }

    function _fundRegentRewards(uint256 amount) internal {
        vm.startPrank(FUNDER);
        regent.approve(address(staking), type(uint256).max);
        staking.fundRegentRewards(amount);
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
