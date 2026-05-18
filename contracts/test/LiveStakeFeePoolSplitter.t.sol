// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {LiveStakeFeePoolSplitter} from "src/revenue/LiveStakeFeePoolSplitter.sol";
import {RegentRevenueStaking} from "src/revenue/RegentRevenueStaking.sol";
import {RegentStakingRevenueRouter} from "src/revenue/RegentStakingRevenueRouter.sol";
import {RevenueIngressAccount} from "src/revenue/RevenueIngressAccount.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {MockRegentBuybackAdapter} from "test/mocks/MockRegentBuybackAdapter.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";
import {MockRegentStakingRevenueRouter} from "test/mocks/MockRegentStakingRevenueRouter.sol";
import {TransferFeeERC20Mock} from "test/mocks/TransferFeeERC20Mock.sol";

contract LiveStakeFeePoolSplitterTest is Test {
    bytes32 internal constant SUBJECT_ID = keccak256("live-subject");
    address internal constant TREASURY = address(0x1111);
    address internal constant CREATOR = address(0x2222);
    address internal constant STAKER_ONE = address(0x3333);
    address internal constant STAKER_TWO = address(0x4444);
    uint256 internal constant HUNDRED_USDC = 100e18;
    uint256 internal constant PROTOCOL_SKIM = 1e18;
    uint256 internal constant TREASURY_BUYBACK = 9900e15;
    uint256 internal constant SUBJECT_LANE = 89_100e15;
    uint256 internal constant STAKER_POOL = 8910e15;
    uint256 internal constant TREASURY_LANE = 80_190e15;

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

        assertEq(splitter.protocolFeeUsdc(), PROTOCOL_SKIM);
        assertEq(splitter.treasuryBuybackUsdc(), TREASURY_BUYBACK);
        assertEq(splitter.netAgentLaneUsdc(), SUBJECT_LANE);
        assertEq(splitter.stakerPoolInflowUsdc(), STAKER_POOL);
        assertEq(splitter.treasuryReservedUsdc(), TREASURY_LANE);
        assertEq(splitter.previewClaimableUSDC(STAKER_ONE), STAKER_POOL);
        assertEq(splitter.totalRegentBoughtForTreasury(), TREASURY_BUYBACK);
        assertEq(usdc.balanceOf(address(feeRouter)), PROTOCOL_SKIM + TREASURY_BUYBACK);
        assertEq(feeRouter.totalUsdcProcessed(), PROTOCOL_SKIM);
        assertEq(feeRouter.totalUsdcDepositedToRegentStaking(), PROTOCOL_SKIM);
        assertEq(feeRouter.totalUsdcUsedForTreasuryBuyback(), TREASURY_BUYBACK);
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
        MockRegentBuybackAdapter buybackAdapter =
            new MockRegentBuybackAdapter(address(usdc), address(regent));
        router.setTreasuryBuybackAdapter(address(buybackAdapter));
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

        usdc.mint(address(this), HUNDRED_USDC);
        usdc.approve(address(realRouterSplitter), HUNDRED_USDC);
        realRouterSplitter.depositUSDC(HUNDRED_USDC, bytes32("direct"), bytes32("source"));

        assertEq(realRouterSplitter.protocolFeeUsdc(), PROTOCOL_SKIM);
        assertEq(realRouterSplitter.treasuryBuybackUsdc(), TREASURY_BUYBACK);
        assertEq(realRouterSplitter.netAgentLaneUsdc(), SUBJECT_LANE);
        assertEq(realRouterSplitter.stakerPoolInflowUsdc(), STAKER_POOL);
        assertEq(realRouterSplitter.treasuryReservedUsdc(), TREASURY_LANE);
        assertEq(realRouterSplitter.previewClaimableUSDC(STAKER_ONE), STAKER_POOL);
        assertEq(realRouterSplitter.totalRegentBoughtForTreasury(), TREASURY_BUYBACK);
        assertEq(usdc.balanceOf(address(staking)), PROTOCOL_SKIM);
        assertEq(usdc.balanceOf(address(buybackAdapter)), TREASURY_BUYBACK);
        assertEq(staking.totalUsdcReceived(), PROTOCOL_SKIM);
        assertEq(router.totalUsdcDepositedToRegentStaking(), PROTOCOL_SKIM);
        assertEq(router.totalUsdcUsedForTreasuryBuyback(), TREASURY_BUYBACK);
        assertEq(regent.balanceOf(TREASURY), TREASURY_BUYBACK);
    }

    function testTwoLiveStakersSplitPoolByCurrentStakeOnly() external {
        _stake(STAKER_ONE, 20e18);
        _stake(STAKER_TWO, 10e18);

        _depositUsdc(address(this), 100e18);

        assertEq(splitter.previewClaimableUSDC(STAKER_ONE), 5940e15);
        assertEq(splitter.previewClaimableUSDC(STAKER_TWO), 2970e15);

        vm.prank(STAKER_ONE);
        splitter.claimUSDC(STAKER_ONE);
        vm.prank(STAKER_TWO);
        splitter.claimUSDC(STAKER_TWO);

        assertEq(usdc.balanceOf(STAKER_ONE), 5940e15);
        assertEq(usdc.balanceOf(STAKER_TWO), 2970e15);
    }

    function testNoStakersRoutesStakerPoolToTreasuryAndLateStakeGetsNothing() external {
        _depositUsdc(address(this), 100e18);

        assertEq(splitter.treasuryReservedUsdc(), SUBJECT_LANE);
        assertEq(splitter.noStakerPoolRoutedToTreasuryUsdc(), STAKER_POOL);

        _stake(STAKER_ONE, 10e18);

        assertEq(splitter.previewClaimableUSDC(STAKER_ONE), 0);
    }

    function testUnstakeSyncsBeforeReducingBalance() external {
        _stake(STAKER_ONE, 10e18);
        _depositUsdc(address(this), 100e18);

        vm.prank(STAKER_ONE);
        splitter.unstake(5e18, STAKER_ONE);

        assertEq(splitter.previewClaimableUSDC(STAKER_ONE), STAKER_POOL);
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

        assertEq(feeRouter.totalUsdcProcessed(), PROTOCOL_SKIM);
        assertEq(feeRouter.totalUsdcUsedForTreasuryBuyback(), TREASURY_BUYBACK);
        assertEq(splitter.verifiedIngressUsdc(), 100e18);
    }

    function testDirectDepositAndIngressSweepBothCallRouterSynchronously() external {
        _depositUsdc(address(this), 100e18);
        usdc.mint(address(ingress), 50e18);
        ingress.sweepUSDC();

        assertEq(feeRouter.totalUsdcProcessed(), 1500e15);
        assertEq(feeRouter.totalUsdcUsedForTreasuryBuyback(), 14_850e15);
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

    function testBuybackRevertLeavesDepositAccountingUnchanged() external {
        feeRouter.setShouldRevertBuyback(true);

        usdc.mint(address(this), 100e18);
        usdc.approve(address(splitter), 100e18);

        vm.expectRevert("MOCK_BUYBACK_REVERT");
        splitter.depositUSDC(100e18, bytes32("direct"), bytes32("source"));

        assertEq(usdc.balanceOf(address(this)), 100e18);
        assertEq(splitter.totalUsdcReceived(), 0);
        assertEq(splitter.treasuryBuybackUsdc(), 0);
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
