// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RevenueShareSplitter} from "src/revenue/RevenueShareSplitter.sol";
import {MintableBurnableERC20Mock} from "test/mocks/MintableBurnableERC20Mock.sol";

contract RevenueShareSplitterTest is Test {
    uint256 internal constant XYZ = 1e18;
    uint256 internal constant USDC = 1e6;
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

    MintableBurnableERC20Mock internal stakeToken;
    MintableBurnableERC20Mock internal usdc;
    RevenueShareSplitter internal splitter;

    address internal constant TREASURY = address(0xA11CE);
    address internal constant PROTOCOL_TREASURY = address(0xBEEF);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);
    address internal constant CAROL = address(0xC3);
    address internal constant DAVE = address(0xD4);
    address internal constant EVE = address(0xE5);

    function setUp() external {
        stakeToken = new MintableBurnableERC20Mock("Agent", "XYZ", 18);
        usdc = new MintableBurnableERC20Mock("USD Coin", "USDC", 6);

        splitter = new RevenueShareSplitter(
            address(stakeToken),
            address(usdc),
            TREASURY,
            PROTOCOL_TREASURY,
            100,
            "XYZ splitter",
            address(this)
        );

        stakeToken.mint(ALICE, ALICE_STAKE);
        stakeToken.mint(BOB, BOB_INITIAL_STAKE + BOB_TOP_UP);
        stakeToken.mint(CAROL, CAROL_STAKE);
        stakeToken.mint(DAVE, DAVE_STAKE);
        stakeToken.mint(EVE, EVE_STAKE);
        stakeToken.mint(TREASURY, 550 * XYZ);

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

        RevenueShareSplitter control = new RevenueShareSplitter(
            address(controlStake),
            address(usdc),
            TREASURY,
            PROTOCOL_TREASURY,
            100,
            "control",
            address(this)
        );

        _stake(control, controlStake, ALICE, 100 * XYZ);
        usdc.mint(address(this), DIRECT_DEPOSIT);
        usdc.approve(address(control), type(uint256).max);
        control.depositUSDC(DIRECT_DEPOSIT, bytes32("direct"), bytes32("1"));
        uint256 treasuryTakeNoStake = control.treasuryResidualUsdc();

        MintableBurnableERC20Mock stakedStake =
            new MintableBurnableERC20Mock("Neutral2", "NEUT2", 18);
        stakedStake.mint(ALICE, 100 * XYZ);
        stakedStake.mint(TREASURY, 900 * XYZ);

        RevenueShareSplitter stakedTreasury = new RevenueShareSplitter(
            address(stakedStake),
            address(usdc),
            TREASURY,
            PROTOCOL_TREASURY,
            100,
            "stakedTreasury",
            address(this)
        );

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

    function testBurnChangesFutureDepositsOnly() external {
        usdc.mint(address(this), 1000 * USDC);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.depositUSDC(1000 * USDC, bytes32("before_burn"), bytes32("1"));
        uint256 aliceBefore = splitter.previewClaimableUSDC(ALICE);

        stakeToken.burn(TREASURY, 100 * XYZ);
        assertEq(stakeToken.totalSupply(), 900 * XYZ);

        usdc.mint(address(this), 1000 * USDC);
        usdc.approve(address(splitter), type(uint256).max);
        splitter.depositUSDC(1000 * USDC, bytes32("after_burn"), bytes32("2"));

        uint256 aliceAfter = splitter.previewClaimableUSDC(ALICE) - aliceBefore;
        assertEq(aliceAfter, 220 * USDC);
    }

    function testUnsupportedRewardTokenDoesNotGetProtocolCredit() external {
        MintableBurnableERC20Mock junk = new MintableBurnableERC20Mock("Junk", "JUNK", 18);
        junk.mint(address(this), 1e18);

        assertEq(splitter.previewClaimableUSDC(ALICE), 0);
        junk.transfer(TREASURY, 1e18);

        assertEq(junk.balanceOf(TREASURY), 1e18);
        assertEq(splitter.previewClaimableUSDC(ALICE), 0);
    }

    function testZeroDepositReverts() external {
        vm.expectRevert("AMOUNT_ZERO");
        splitter.depositUSDC(0, bytes32("direct"), bytes32("zero"));
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
}
