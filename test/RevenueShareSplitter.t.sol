// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RevenueShareSplitter} from "src/revenue/RevenueShareSplitter.sol";
import {RevenueIngressAccount} from "src/revenue/RevenueIngressAccount.sol";
import {MintableBurnableERC20Mock} from "test/mocks/MintableBurnableERC20Mock.sol";

contract RevenueShareSplitterTest is Test {
    uint256 internal constant XYZ = 1e18;
    uint256 internal constant USDC = 1e6;

    MintableBurnableERC20Mock internal stakeToken;
    MintableBurnableERC20Mock internal usdc;
    RevenueShareSplitter internal splitter;
    RevenueIngressAccount internal ingress;

    address internal treasury = address(0xA11CE);
    address internal protocolTreasury = address(0xBEEF);
    address internal alice = address(0xA1);
    address internal bob = address(0xB2);
    address internal carol = address(0xC3);
    address internal dave = address(0xD4);
    address internal eve = address(0xE5);

    function setUp() external {
        stakeToken = new MintableBurnableERC20Mock("Agent", "XYZ", 18);
        usdc = new MintableBurnableERC20Mock("USD Coin", "USDC", 6);

        splitter = new RevenueShareSplitter(
            address(stakeToken),
            address(usdc),
            treasury,
            protocolTreasury,
            100,
            "XYZ splitter",
            address(this)
        );
        ingress =
            new RevenueIngressAccount(address(splitter), address(usdc), bytes32("xyz-ingress-1"), address(this));

        stakeToken.mint(alice, 200 * XYZ);
        stakeToken.mint(bob, 150 * XYZ);
        stakeToken.mint(carol, 50 * XYZ);
        stakeToken.mint(dave, 30 * XYZ);
        stakeToken.mint(eve, 20 * XYZ);
        stakeToken.mint(treasury, 550 * XYZ);

        vm.startPrank(alice);
        stakeToken.approve(address(splitter), type(uint256).max);
        splitter.stake(200 * XYZ, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        stakeToken.approve(address(splitter), type(uint256).max);
        splitter.stake(100 * XYZ, bob);
        vm.stopPrank();

        vm.startPrank(carol);
        stakeToken.approve(address(splitter), type(uint256).max);
        splitter.stake(50 * XYZ, carol);
        vm.stopPrank();

        vm.startPrank(dave);
        stakeToken.approve(address(splitter), type(uint256).max);
        splitter.stake(30 * XYZ, dave);
        vm.stopPrank();

        vm.startPrank(eve);
        stakeToken.approve(address(splitter), type(uint256).max);
        splitter.stake(20 * XYZ, eve);
        vm.stopPrank();
    }

    function testMainScenarioAccounting() external {
        assertEq(splitter.totalStaked(), 400 * XYZ);

        usdc.mint(address(ingress), 10_000 * USDC);
        vm.prank(address(0x99));
        ingress.sweepUSDC();

        assertEq(splitter.protocolReserveUsdc(), 100 * USDC);
        assertEq(splitter.treasuryResidualUsdc(), 5_940 * USDC);
        assertEq(splitter.previewClaimableUSDC(alice), 1_980 * USDC);
        assertEq(splitter.previewClaimableUSDC(bob), 990 * USDC);
        assertEq(splitter.previewClaimableUSDC(carol), 495 * USDC);
        assertEq(splitter.previewClaimableUSDC(dave), 297 * USDC);
        assertEq(splitter.previewClaimableUSDC(eve), 198 * USDC);

        vm.startPrank(bob);
        splitter.stake(50 * XYZ, bob);
        vm.stopPrank();
        assertEq(splitter.totalStaked(), 450 * XYZ);
        assertEq(splitter.previewClaimableUSDC(bob), 990 * USDC);

        vm.prank(dave);
        splitter.unstake(10 * XYZ, dave);
        assertEq(splitter.totalStaked(), 440 * XYZ);
        assertEq(stakeToken.balanceOf(dave), 10 * XYZ);
        assertEq(splitter.previewClaimableUSDC(dave), 297 * USDC);

        vm.prank(alice);
        splitter.claimUSDC(alice);
        assertEq(usdc.balanceOf(alice), 1_980 * USDC);
        assertEq(splitter.previewClaimableUSDC(alice), 0);

        vm.prank(carol);
        splitter.unstake(50 * XYZ, carol);
        assertEq(splitter.totalStaked(), 390 * XYZ);
        assertEq(stakeToken.balanceOf(carol), 50 * XYZ);
        assertEq(splitter.previewClaimableUSDC(carol), 495 * USDC);

        usdc.mint(address(ingress), 5_000 * USDC);
        ingress.sweepUSDC();

        assertEq(splitter.protocolReserveUsdc(), 150 * USDC);
        assertEq(splitter.treasuryResidualUsdc(), 8_959_500_000);
        assertEq(splitter.previewClaimableUSDC(alice), 990 * USDC);
        assertEq(splitter.previewClaimableUSDC(bob), 1_732_500_000);
        assertEq(splitter.previewClaimableUSDC(carol), 495 * USDC);
        assertEq(splitter.previewClaimableUSDC(dave), 396 * USDC);
        assertEq(splitter.previewClaimableUSDC(eve), 297 * USDC);

        vm.prank(bob);
        splitter.claimUSDC(bob);
        assertEq(usdc.balanceOf(bob), 1_732_500_000);
        assertEq(splitter.previewClaimableUSDC(bob), 0);
    }

    function testTreasuryStakingIsRevenueNeutral() external {
        MintableBurnableERC20Mock controlStake = new MintableBurnableERC20Mock("Neutral", "NEUT", 18);
        controlStake.mint(alice, 100 * XYZ);
        controlStake.mint(treasury, 900 * XYZ);

        RevenueShareSplitter control = new RevenueShareSplitter(
            address(controlStake), address(usdc), treasury, protocolTreasury, 100, "control", address(this)
        );

        vm.startPrank(alice);
        controlStake.approve(address(control), type(uint256).max);
        control.stake(100 * XYZ, alice);
        vm.stopPrank();

        usdc.mint(address(this), 10_000 * USDC);
        usdc.approve(address(control), type(uint256).max);
        control.depositUSDC(10_000 * USDC, bytes32("direct"), bytes32("1"));
        uint256 treasuryTakeNoStake = control.treasuryResidualUsdc();

        MintableBurnableERC20Mock stakedStake =
            new MintableBurnableERC20Mock("Neutral2", "NEUT2", 18);
        stakedStake.mint(alice, 100 * XYZ);
        stakedStake.mint(treasury, 900 * XYZ);

        RevenueShareSplitter stakedTreasury = new RevenueShareSplitter(
            address(stakedStake),
            address(usdc),
            treasury,
            protocolTreasury,
            100,
            "stakedTreasury",
            address(this)
        );

        vm.startPrank(alice);
        stakedStake.approve(address(stakedTreasury), type(uint256).max);
        stakedTreasury.stake(100 * XYZ, alice);
        vm.stopPrank();

        vm.startPrank(treasury);
        stakedStake.approve(address(stakedTreasury), type(uint256).max);
        stakedTreasury.stake(900 * XYZ, treasury);
        vm.stopPrank();

        usdc.mint(address(this), 10_000 * USDC);
        usdc.approve(address(stakedTreasury), type(uint256).max);
        stakedTreasury.depositUSDC(10_000 * USDC, bytes32("direct"), bytes32("2"));

        uint256 treasuryResidualWithStake = stakedTreasury.treasuryResidualUsdc();
        uint256 treasuryAsStaker = stakedTreasury.previewClaimableUSDC(treasury);

        assertEq(treasuryTakeNoStake, 8_910 * USDC);
        assertEq(treasuryResidualWithStake + treasuryAsStaker, 8_910 * USDC);
    }

    function testBurnChangesFutureDepositsOnly() external {
        usdc.mint(address(this), 1_000 * USDC);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.depositUSDC(1_000 * USDC, bytes32("before_burn"), bytes32("1"));
        uint256 aliceBefore = splitter.previewClaimableUSDC(alice);

        stakeToken.burn(treasury, 100 * XYZ);
        assertEq(stakeToken.totalSupply(), 900 * XYZ);

        usdc.mint(address(this), 1_000 * USDC);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.depositUSDC(1_000 * USDC, bytes32("after_burn"), bytes32("2"));

        uint256 aliceAfter = splitter.previewClaimableUSDC(alice) - aliceBefore;
        assertEq(aliceAfter, 220 * USDC);
    }

    function testUnsupportedRewardTokenDoesNotGetProtocolCredit() external {
        MintableBurnableERC20Mock junk = new MintableBurnableERC20Mock("Junk", "JUNK", 18);
        junk.mint(address(ingress), 1e18);

        assertEq(splitter.previewClaimableUSDC(alice), 0);
        ingress.rescueUnsupportedToken(address(junk), 1e18, treasury);

        assertEq(junk.balanceOf(treasury), 1e18);
        assertEq(splitter.previewClaimableUSDC(alice), 0);
    }

    function testSecondSweepOfSameBalanceReverts() external {
        usdc.mint(address(ingress), 1_000 * USDC);
        ingress.sweepUSDC();

        uint256 reserveBefore = splitter.protocolReserveUsdc();
        uint256 residualBefore = splitter.treasuryResidualUsdc();

        vm.expectRevert("NOTHING_TO_SWEEP");
        ingress.sweepUSDC();

        assertEq(splitter.protocolReserveUsdc(), reserveBefore);
        assertEq(splitter.treasuryResidualUsdc(), residualBefore);
    }
}
