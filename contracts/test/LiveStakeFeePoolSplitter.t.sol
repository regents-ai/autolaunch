// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {LiveStakeFeePoolSplitter} from "src/revenue/LiveStakeFeePoolSplitter.sol";
import {RegentRevenueStaking} from "src/revenue/RegentRevenueStaking.sol";
import {RegentStakingRevenueRouter} from "src/revenue/RegentStakingRevenueRouter.sol";
import {RevenueIngressAccount} from "src/revenue/RevenueIngressAccount.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";
import {MockRegentStakingRevenueRouter} from "test/mocks/MockRegentStakingRevenueRouter.sol";
import {TransferFeeERC20Mock} from "test/mocks/TransferFeeERC20Mock.sol";

contract LiveStakeFeePoolSplitterTest is Test {
    bytes32 internal constant SUBJECT_ID = keccak256("live-subject");
    address internal constant TREASURY = address(0x1111);
    address internal constant CREATOR = address(0x2222);
    address internal constant STAKER_ONE = address(0x3333);
    address internal constant STAKER_TWO = address(0x4444);

    MintableERC20Mock internal usdc;
    MintableERC20Mock internal stakeToken;
    SubjectRegistry internal subjectRegistry;
    RevenueIngressFactory internal ingressFactory;
    MockRegentStakingRevenueRouter internal feeRouter;
    LiveStakeFeePoolSplitter internal splitter;
    RevenueIngressAccount internal ingress;

    function setUp() external {
        usdc = new MintableERC20Mock("USD Coin", "USDC");
        stakeToken = new MintableERC20Mock("Agent", "AGENT");
        subjectRegistry = new SubjectRegistry(address(this));
        ingressFactory =
            new RevenueIngressFactory(address(usdc), address(subjectRegistry), address(this));
        feeRouter = new MockRegentStakingRevenueRouter(address(usdc), address(0x8888));
        splitter = new LiveStakeFeePoolSplitter(
            address(stakeToken),
            address(usdc),
            address(ingressFactory),
            address(subjectRegistry),
            SUBJECT_ID,
            TREASURY,
            address(feeRouter),
            1000,
            "Live subject",
            TREASURY
        );

        subjectRegistry.createPermissionlessSubject(
            SUBJECT_ID,
            address(stakeToken),
            address(splitter),
            TREASURY,
            CREATOR,
            true,
            "Live subject"
        );

        vm.prank(TREASURY);
        ingress = RevenueIngressAccount(
            payable(ingressFactory.createIngressAccount(SUBJECT_ID, "default-usdc-ingress", true))
        );
    }

    function testHundredUsdcRoutesProtocolStakerPoolAndTreasury() external {
        _stake(STAKER_ONE, 10e18);

        _depositUsdc(address(this), 100e18);

        assertEq(splitter.protocolFeeUsdc(), 10e18);
        assertEq(splitter.netAgentLaneUsdc(), 90e18);
        assertEq(splitter.stakerPoolInflowUsdc(), 9e18);
        assertEq(splitter.treasuryReservedUsdc(), 81e18);
        assertEq(splitter.previewClaimableUSDC(STAKER_ONE), 9e18);
        assertEq(usdc.balanceOf(address(feeRouter)), 10e18);
        assertEq(feeRouter.totalUsdcProcessed(), 10e18);
        assertEq(feeRouter.totalUsdcDepositedToRegentStaking(), 10e18);
    }

    function testHundredUsdcDepositsProtocolSkimIntoRegentStaking() external {
        bytes32 liveSubjectId = keccak256("live-subject-real-router");
        MintableERC20Mock regent = new MintableERC20Mock("REGENT", "REGENT");
        RegentRevenueStaking staking = new RegentRevenueStaking(
            address(regent), address(usdc), TREASURY, 1_000_000e18, address(this)
        );
        RegentStakingRevenueRouter router = new RegentStakingRevenueRouter(
            address(this), address(usdc), address(subjectRegistry), address(staking)
        );
        router.setMaxUsdcPerSettlement(1000e18);
        LiveStakeFeePoolSplitter realRouterSplitter = new LiveStakeFeePoolSplitter(
            address(stakeToken),
            address(usdc),
            address(ingressFactory),
            address(subjectRegistry),
            liveSubjectId,
            TREASURY,
            address(router),
            1000,
            "Live subject",
            TREASURY
        );
        subjectRegistry.createPermissionlessSubject(
            liveSubjectId,
            address(stakeToken),
            address(realRouterSplitter),
            TREASURY,
            CREATOR,
            true,
            "Live subject"
        );

        stakeToken.mint(STAKER_ONE, 1000e18);
        vm.prank(STAKER_ONE);
        stakeToken.approve(address(realRouterSplitter), 10e18);
        vm.prank(STAKER_ONE);
        realRouterSplitter.stake(10e18, STAKER_ONE);

        usdc.mint(address(this), 100e18);
        usdc.approve(address(realRouterSplitter), 100e18);
        realRouterSplitter.depositUSDC(100e18, bytes32("direct"), bytes32("source"));

        assertEq(realRouterSplitter.protocolFeeUsdc(), 10e18);
        assertEq(realRouterSplitter.netAgentLaneUsdc(), 90e18);
        assertEq(realRouterSplitter.stakerPoolInflowUsdc(), 9e18);
        assertEq(realRouterSplitter.treasuryReservedUsdc(), 81e18);
        assertEq(realRouterSplitter.previewClaimableUSDC(STAKER_ONE), 9e18);
        assertEq(usdc.balanceOf(address(staking)), 10e18);
        assertEq(staking.totalUsdcReceived(), 10e18);
        assertEq(router.totalUsdcDepositedToRegentStaking(), 10e18);
        assertEq(regent.balanceOf(TREASURY), 0);
    }

    function testTwoLiveStakersSplitPoolByCurrentStakeOnly() external {
        _stake(STAKER_ONE, 20e18);
        _stake(STAKER_TWO, 10e18);

        _depositUsdc(address(this), 100e18);

        assertEq(splitter.previewClaimableUSDC(STAKER_ONE), 6e18);
        assertEq(splitter.previewClaimableUSDC(STAKER_TWO), 3e18);

        vm.prank(STAKER_ONE);
        splitter.claimUSDC(STAKER_ONE);
        vm.prank(STAKER_TWO);
        splitter.claimUSDC(STAKER_TWO);

        assertEq(usdc.balanceOf(STAKER_ONE), 6e18);
        assertEq(usdc.balanceOf(STAKER_TWO), 3e18);
    }

    function testNoStakersRoutesStakerPoolToTreasuryAndLateStakeGetsNothing() external {
        _depositUsdc(address(this), 100e18);

        assertEq(splitter.treasuryReservedUsdc(), 90e18);
        assertEq(splitter.noStakerPoolRoutedToTreasuryUsdc(), 9e18);

        _stake(STAKER_ONE, 10e18);

        assertEq(splitter.previewClaimableUSDC(STAKER_ONE), 0);
    }

    function testUnstakeSyncsBeforeReducingBalance() external {
        _stake(STAKER_ONE, 10e18);
        _depositUsdc(address(this), 100e18);

        vm.prank(STAKER_ONE);
        splitter.unstake(5e18, STAKER_ONE);

        assertEq(splitter.previewClaimableUSDC(STAKER_ONE), 9e18);
        assertEq(stakeToken.balanceOf(STAKER_ONE), 995e18);
    }

    function testFeeOnTransferStakeTokenFailsExactTransferCheck() external {
        TransferFeeERC20Mock feeToken = new TransferFeeERC20Mock("Fee", "FEE", 18, address(0x9999));
        bytes32 feeSubjectId = keccak256("fee-subject");
        LiveStakeFeePoolSplitter feeSplitter = new LiveStakeFeePoolSplitter(
            address(feeToken),
            address(usdc),
            address(ingressFactory),
            address(subjectRegistry),
            feeSubjectId,
            TREASURY,
            address(feeRouter),
            1000,
            "Fee subject",
            TREASURY
        );
        subjectRegistry.createPermissionlessSubject(
            feeSubjectId,
            address(feeToken),
            address(feeSplitter),
            TREASURY,
            CREATOR,
            true,
            "Fee subject"
        );

        feeToken.mint(STAKER_ONE, 100e18);
        feeToken.setFeeBps(100);
        feeToken.setFeeTriggers(address(feeSplitter), false, true);

        vm.prank(STAKER_ONE);
        feeToken.approve(address(feeSplitter), 100e18);

        vm.prank(STAKER_ONE);
        vm.expectRevert("STAKE_TOKEN_IN_EXACT");
        feeSplitter.stake(100e18, STAKER_ONE);
    }

    function testIngressSweepRequiresKnownIngressForSameSubject() external {
        vm.expectRevert("ONLY_INGRESS_ACCOUNT");
        splitter.recordIngressSweep(100e18, bytes32("not-ingress"));

        usdc.mint(address(ingress), 100e18);
        ingress.sweepUSDC();

        assertEq(feeRouter.totalUsdcProcessed(), 10e18);
        assertEq(splitter.verifiedIngressUsdc(), 100e18);
    }

    function testDirectDepositAndIngressSweepBothCallRouterSynchronously() external {
        _depositUsdc(address(this), 100e18);
        usdc.mint(address(ingress), 50e18);
        ingress.sweepUSDC();

        assertEq(feeRouter.totalUsdcProcessed(), 15e18);
    }

    function testRouterRevertLeavesDirectDepositAndSweepAccountingUnchanged() external {
        feeRouter.setShouldRevert(true);

        usdc.mint(address(this), 100e18);
        usdc.approve(address(splitter), 100e18);

        vm.expectRevert("MOCK_ROUTER_REVERT");
        splitter.depositUSDC(100e18, bytes32("direct"), bytes32("source"));

        assertEq(usdc.balanceOf(address(this)), 100e18);
        assertEq(splitter.totalUsdcReceived(), 0);

        usdc.mint(address(ingress), 100e18);

        vm.expectRevert("MOCK_ROUTER_REVERT");
        ingress.sweepUSDC();

        assertEq(usdc.balanceOf(address(ingress)), 100e18);
        assertEq(splitter.totalUsdcReceived(), 0);
    }

    function _stake(address account, uint256 amount) internal {
        stakeToken.mint(account, 1000e18);
        vm.prank(account);
        stakeToken.approve(address(splitter), amount);
        vm.prank(account);
        splitter.stake(amount, account);
    }

    function _depositUsdc(address depositor, uint256 amount) internal {
        usdc.mint(depositor, amount);
        vm.prank(depositor);
        usdc.approve(address(splitter), amount);
        vm.prank(depositor);
        splitter.depositUSDC(amount, bytes32("direct"), bytes32("source"));
    }
}
