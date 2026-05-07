// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RegentRevenueStaking} from "src/revenue/RegentRevenueStaking.sol";
import {RegentStakingRevenueRouter} from "src/revenue/RegentStakingRevenueRouter.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareSplitterV2} from "src/revenue/RevenueShareSplitterV2.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";

contract RevenueShareSplitterV2StakingRouterTest is Test {
    bytes32 internal constant SUBJECT_ID = keccak256("v2-subject");
    address internal constant TREASURY = address(0x1111);
    address internal constant STAKER = address(0x3333);
    uint256 internal constant SUPPLY_DENOMINATOR = 1000e18;

    MintableERC20Mock internal usdc;
    MintableERC20Mock internal regent;
    MintableERC20Mock internal stakeToken;
    SubjectRegistry internal subjectRegistry;
    RevenueIngressFactory internal ingressFactory;
    RegentRevenueStaking internal staking;
    RegentStakingRevenueRouter internal router;
    RevenueShareSplitterV2 internal splitter;

    function setUp() external {
        usdc = new MintableERC20Mock("USD Coin", "USDC");
        regent = new MintableERC20Mock("REGENT", "REGENT");
        stakeToken = new MintableERC20Mock("Agent", "AGENT");
        subjectRegistry = new SubjectRegistry(address(this));
        ingressFactory =
            new RevenueIngressFactory(address(usdc), address(subjectRegistry), address(this));
        staking = new RegentRevenueStaking(
            address(regent), address(usdc), TREASURY, 1_000_000e18, address(this)
        );
        router = new RegentStakingRevenueRouter(
            address(this), address(usdc), address(subjectRegistry), address(staking)
        );
        router.setMaxUsdcPerSettlement(1000e18);
        splitter = new RevenueShareSplitterV2(
            address(stakeToken),
            address(usdc),
            address(ingressFactory),
            address(subjectRegistry),
            SUBJECT_ID,
            TREASURY,
            address(router),
            SUPPLY_DENOMINATOR,
            "Subject",
            TREASURY
        );
        subjectRegistry.createSubject(
            SUBJECT_ID, address(stakeToken), address(splitter), TREASURY, true, "Subject"
        );
    }

    function testHundredUsdcRoutesProtocolSkimToRegentStaking() external {
        stakeToken.mint(STAKER, SUPPLY_DENOMINATOR / 10);
        vm.prank(STAKER);
        stakeToken.approve(address(splitter), SUPPLY_DENOMINATOR / 10);
        vm.prank(STAKER);
        splitter.stake(SUPPLY_DENOMINATOR / 10, STAKER);

        usdc.mint(address(this), 100e18);
        usdc.approve(address(splitter), 100e18);
        splitter.depositUSDC(100e18, bytes32("direct"), bytes32("source"));

        assertEq(splitter.protocolFeeUsdc(), 10e18);
        assertEq(splitter.totalProtocolUsdcDepositedToRegentStaking(), 10e18);
        assertEq(splitter.stakerEligibleInflowUsdc(), 90e18);
        assertEq(splitter.previewClaimableUSDC(STAKER), 9e18);
        assertEq(splitter.treasuryResidualUsdc(), 81e18);
        assertEq(usdc.balanceOf(address(staking)), 10e18);
        assertEq(staking.totalUsdcReceived(), 10e18);
        assertEq(router.totalUsdcDepositedToRegentStaking(), 10e18);
        assertEq(regent.balanceOf(TREASURY), 0);
    }

    function testNoStakerSubjectStillSendsProtocolSkimToRegentStaking() external {
        usdc.mint(address(this), 100e18);
        usdc.approve(address(splitter), 100e18);
        splitter.depositUSDC(100e18, bytes32("direct"), bytes32("source"));

        assertEq(splitter.protocolFeeUsdc(), 10e18);
        assertEq(splitter.totalProtocolUsdcDepositedToRegentStaking(), 10e18);
        assertEq(splitter.previewClaimableUSDC(STAKER), 0);
        assertEq(splitter.treasuryResidualUsdc(), 90e18);
        assertEq(usdc.balanceOf(address(staking)), 10e18);
        assertEq(staking.totalUsdcReceived(), 10e18);
        assertEq(regent.balanceOf(TREASURY), 0);
    }
}
