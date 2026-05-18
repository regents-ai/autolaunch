// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RegentRevenueStaking} from "src/revenue/RegentRevenueStaking.sol";
import {RegentStakingRevenueRouter} from "src/revenue/RegentStakingRevenueRouter.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareSplitterV2} from "src/revenue/RevenueShareSplitterV2.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {MockRegentBuybackAdapter} from "test/mocks/MockRegentBuybackAdapter.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";

contract RevenueShareSplitterV2StakingRouterTest is Test {
    bytes32 internal constant SUBJECT_ID = keccak256("v2-subject");
    address internal constant TREASURY = address(0x1111);
    address internal constant STAKER = address(0x3333);
    uint256 internal constant SUPPLY_DENOMINATOR = 1000e18;
    uint256 internal constant HUNDRED_USDC = 100e18;
    uint256 internal constant PROTOCOL_SKIM = 1e18;
    uint256 internal constant TREASURY_BUYBACK = 9900e15;
    uint256 internal constant SUBJECT_LANE = 89_100e15;
    uint256 internal constant STAKER_CLAIM = 8910e15;
    uint256 internal constant TREASURY_RESIDUAL = 80_190e15;

    MintableERC20Mock internal usdc;
    MintableERC20Mock internal regent;
    MintableERC20Mock internal stakeToken;
    SubjectRegistry internal subjectRegistry;
    RevenueIngressFactory internal ingressFactory;
    RegentRevenueStaking internal staking;
    RegentStakingRevenueRouter internal router;
    MockRegentBuybackAdapter internal buybackAdapter;
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
        buybackAdapter = new MockRegentBuybackAdapter(address(usdc), address(regent));
        router.setTreasuryBuybackAdapter(address(buybackAdapter));
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

        usdc.mint(address(this), HUNDRED_USDC);
        usdc.approve(address(splitter), HUNDRED_USDC);
        splitter.depositUSDC(HUNDRED_USDC, bytes32("direct"), bytes32("source"));

        assertEq(splitter.protocolFeeUsdc(), PROTOCOL_SKIM);
        assertEq(splitter.treasuryBuybackUsdc(), TREASURY_BUYBACK);
        assertEq(splitter.totalProtocolUsdcDepositedToRegentStaking(), PROTOCOL_SKIM);
        assertEq(splitter.totalRegentBoughtForTreasury(), TREASURY_BUYBACK);
        assertEq(splitter.stakerEligibleInflowUsdc(), SUBJECT_LANE);
        assertEq(splitter.previewClaimableUSDC(STAKER), STAKER_CLAIM);
        assertEq(splitter.treasuryResidualUsdc(), TREASURY_RESIDUAL);
        assertEq(usdc.balanceOf(address(staking)), PROTOCOL_SKIM);
        assertEq(staking.totalUsdcReceived(), PROTOCOL_SKIM);
        assertEq(router.totalUsdcDepositedToRegentStaking(), PROTOCOL_SKIM);
        assertEq(router.totalUsdcUsedForTreasuryBuyback(), TREASURY_BUYBACK);
        assertEq(usdc.balanceOf(address(buybackAdapter)), TREASURY_BUYBACK);
        assertEq(regent.balanceOf(TREASURY), TREASURY_BUYBACK);
    }

    function testNoStakerSubjectStillSendsProtocolSkimToRegentStaking() external {
        usdc.mint(address(this), HUNDRED_USDC);
        usdc.approve(address(splitter), HUNDRED_USDC);
        splitter.depositUSDC(HUNDRED_USDC, bytes32("direct"), bytes32("source"));

        assertEq(splitter.protocolFeeUsdc(), PROTOCOL_SKIM);
        assertEq(splitter.treasuryBuybackUsdc(), TREASURY_BUYBACK);
        assertEq(splitter.totalProtocolUsdcDepositedToRegentStaking(), PROTOCOL_SKIM);
        assertEq(splitter.totalRegentBoughtForTreasury(), TREASURY_BUYBACK);
        assertEq(splitter.previewClaimableUSDC(STAKER), 0);
        assertEq(splitter.treasuryResidualUsdc(), SUBJECT_LANE);
        assertEq(usdc.balanceOf(address(staking)), PROTOCOL_SKIM);
        assertEq(staking.totalUsdcReceived(), PROTOCOL_SKIM);
        assertEq(regent.balanceOf(TREASURY), TREASURY_BUYBACK);
    }
}
