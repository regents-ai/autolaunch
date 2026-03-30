// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RegentRevenueStaking} from "src/revenue/RegentRevenueStaking.sol";
import {MintableBurnableERC20Mock} from "test/mocks/MintableBurnableERC20Mock.sol";

contract RegentRevenueStakingTest is Test {
    uint256 internal constant REGENT = 1e18;
    uint256 internal constant USDC = 1e6;
    uint16 internal constant STAKER_SHARE_BPS = 7000;

    address internal constant OWNER = address(0xA11CE);
    address internal constant TREASURY = address(0xBEEF);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);
    address internal constant CAROL = address(0xC3);

    MintableBurnableERC20Mock internal regent;
    MintableBurnableERC20Mock internal usdc;
    RegentRevenueStaking internal staking;

    function setUp() external {
        regent = new MintableBurnableERC20Mock("Regent", "REGENT", 18);
        usdc = new MintableBurnableERC20Mock("USD Coin", "USDC", 6);

        staking = new RegentRevenueStaking(
            address(regent), address(usdc), TREASURY, STAKER_SHARE_BPS, OWNER
        );

        regent.mint(ALICE, 200 * REGENT);
        regent.mint(BOB, 300 * REGENT);
        regent.mint(CAROL, 500 * REGENT);
    }

    function testSingleStakerDepositAndClaim() external {
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

    function testOwnerCanPauseActions() external {
        vm.prank(OWNER);
        staking.setPaused(true);

        vm.expectRevert("PAUSED");
        vm.prank(ALICE);
        staking.stake(1 * REGENT, ALICE);

        vm.expectRevert("PAUSED");
        staking.depositUSDC(1 * USDC, bytes32("manual"), bytes32("round-1"));
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
}
