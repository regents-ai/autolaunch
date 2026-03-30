// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {AuctionParameters} from "src/cca/interfaces/IContinuousClearingAuction.sol";
import {LaunchDeploymentController} from "src/LaunchDeploymentController.sol";
import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";
import {RegentLBPStrategy} from "src/RegentLBPStrategy.sol";
import {RegentLBPStrategyFactory} from "src/RegentLBPStrategyFactory.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {RevenueShareSplitter} from "src/revenue/RevenueShareSplitter.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";
import {
    MockContinuousClearingAuctionFactory
} from "test/mocks/MockContinuousClearingAuctionFactory.sol";
import {MockHookPoolManager} from "test/mocks/MockHookPoolManager.sol";
import {MockLaunchToken, MockTokenFactory} from "test/mocks/MockTokenFactory.sol";

contract LaunchDeploymentControllerTest is Test {
    address internal constant RECOVERY_SAFE = address(0xABCD);
    address internal constant AGENT_TREASURY_SAFE = address(0x5678);
    address internal constant POSITION_RECIPIENT = address(0x1234);
    address internal constant IDENTITY_REGISTRY = address(0x8004);
    address internal constant REGENT_RECIPIENT = address(0x9FA1);
    address internal constant STRATEGY_OPERATOR = address(0xBEEF);
    uint96 internal constant IDENTITY_AGENT_ID = 42;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 internal constant AUCTION_TICK_SPACING = 79_228_162_514_264_334_008_320;

    LaunchDeploymentController internal controller;
    MockContinuousClearingAuctionFactory internal auctionFactory;
    MockHookPoolManager internal poolManager;
    MockTokenFactory internal tokenFactory;
    SubjectRegistry internal subjectRegistry;
    RevenueShareFactory internal revenueShareFactory;
    RevenueIngressFactory internal revenueIngressFactory;
    RegentLBPStrategyFactory internal strategyFactory;
    MintableERC20Mock internal usdc;

    function setUp() external {
        controller = new LaunchDeploymentController();
        auctionFactory = new MockContinuousClearingAuctionFactory();
        poolManager = new MockHookPoolManager();
        tokenFactory = new MockTokenFactory();
        strategyFactory = new RegentLBPStrategyFactory();
        usdc = new MintableERC20Mock("USD Coin", "USDC");
        subjectRegistry = new SubjectRegistry(address(this));
        revenueShareFactory = new RevenueShareFactory(address(this), address(usdc), subjectRegistry);
        revenueIngressFactory =
            new RevenueIngressFactory(address(usdc), address(subjectRegistry), address(this));
        subjectRegistry.transferOwnership(address(revenueShareFactory));
        revenueShareFactory.setAuthorizedCreator(address(controller), true);
        revenueIngressFactory.setAuthorizedCreator(address(controller), true);
    }

    function testRejectsMissingRevenueIngressFactory() external {
        LaunchDeploymentController.DeploymentConfig memory cfg = defaultConfig();
        cfg.revenueIngressFactory = address(0);

        vm.expectRevert("REVENUE_INGRESS_FACTORY_ZERO");
        controller.deploy(cfg);
    }

    function testRejectsBadMigrationTiming() external {
        LaunchDeploymentController.DeploymentConfig memory cfg = defaultConfig();
        cfg.migrationBlock = cfg.endBlock;

        vm.expectRevert("MIGRATION_BEFORE_END");
        controller.deploy(cfg);
    }

    function testRejectsZeroLpCurrencyCap() external {
        LaunchDeploymentController.DeploymentConfig memory cfg = defaultConfig();
        cfg.maxCurrencyAmountForLP = 0;

        vm.expectRevert("MAX_CCY_FOR_LP_ZERO");
        controller.deploy(cfg);
    }

    function testDeploysModelBLaunchStack() external {
        LaunchDeploymentController.DeploymentResult memory result =
            controller.deploy(defaultConfig());

        _assertCoreAddressesWereCreated(result);
        assertTrue(result.subjectId != bytes32(0));
        assertTrue(result.poolId != bytes32(0));

        uint256 expectedAuctionAmount = TOTAL_SUPPLY / 10;
        uint256 expectedReserveAmount = (TOTAL_SUPPLY * 500) / 10_000;
        uint256 expectedVestingAmount = TOTAL_SUPPLY - expectedAuctionAmount - expectedReserveAmount;

        MockLaunchToken token = MockLaunchToken(result.tokenAddress);
        assertEq(token.balanceOf(result.auctionAddress), expectedAuctionAmount);
        assertEq(token.balanceOf(result.strategyAddress), expectedReserveAmount);
        assertEq(token.balanceOf(result.vestingWalletAddress), expectedVestingAmount);

        RegentLBPStrategy strategy = RegentLBPStrategy(result.strategyAddress);
        assertEq(strategy.auctionAddress(), result.auctionAddress);
        assertEq(strategy.totalStrategySupply(), expectedAuctionAmount + expectedReserveAmount);
        assertEq(strategy.auctionTokenAmount(), expectedAuctionAmount);
        assertEq(strategy.reserveTokenAmount(), expectedReserveAmount);
        assertEq(strategy.tokenSplitToAuctionMps(), 6_666_666);
        assertEq(strategy.positionManager(), address(0xDEAD));
        assertEq(strategy.poolManager(), address(poolManager));
        assertEq(strategy.officialPoolFee(), 0);
        assertEq(strategy.officialPoolTickSpacing(), 60);

        AuctionParameters memory parameters =
            abi.decode(auctionFactory.lastConfigData(), (AuctionParameters));
        assertEq(parameters.currency, address(usdc));
        assertEq(parameters.tokensRecipient, result.strategyAddress);
        assertEq(parameters.fundsRecipient, result.strategyAddress);
        assertEq(auctionFactory.lastAmount(), expectedAuctionAmount);

        LaunchFeeRegistry registry = LaunchFeeRegistry(result.launchFeeRegistryAddress);
        LaunchFeeRegistry.PoolConfig memory poolConfig = registry.getPoolConfig(result.poolId);
        assertEq(poolConfig.treasury, result.revenueShareSplitterAddress);
        assertEq(poolConfig.quoteToken, address(usdc));
        assertEq(poolConfig.regentRecipient, REGENT_RECIPIENT);

        RevenueShareSplitter splitter = RevenueShareSplitter(result.revenueShareSplitterAddress);
        assertEq(splitter.stakeToken(), result.tokenAddress);
        assertEq(splitter.usdc(), address(usdc));
        assertEq(splitter.treasuryRecipient(), AGENT_TREASURY_SAFE);
        assertEq(splitter.protocolRecipient(), REGENT_RECIPIENT);

        SubjectRegistry.SubjectConfig memory subject = subjectRegistry.getSubject(result.subjectId);
        assertEq(subject.stakeToken, result.tokenAddress);
        assertEq(subject.splitter, result.revenueShareSplitterAddress);
        assertEq(subject.treasurySafe, RECOVERY_SAFE);
        assertTrue(subject.active);

        bytes32 expectedSubjectId = keccak256(abi.encode(block.chainid, result.tokenAddress));
        assertEq(result.subjectId, expectedSubjectId);
        assertEq(subjectRegistry.subjectOfStakeToken(result.tokenAddress), expectedSubjectId);
        assertEq(
            subjectRegistry.subjectForIdentity(block.chainid, IDENTITY_REGISTRY, IDENTITY_AGENT_ID),
            expectedSubjectId
        );

        RevenueIngressFactory ingressFactory = revenueIngressFactory;
        assertEq(
            ingressFactory.defaultIngressOfSubject(result.subjectId), result.defaultIngressAddress
        );
        assertEq(ingressFactory.ingressAccountCount(result.subjectId), 1);
    }

    function defaultConfig()
        internal
        view
        returns (LaunchDeploymentController.DeploymentConfig memory cfg)
    {
        cfg.recoverySafe = RECOVERY_SAFE;
        cfg.agentTreasurySafe = AGENT_TREASURY_SAFE;
        cfg.revenueShareFactory = address(revenueShareFactory);
        cfg.revenueIngressFactory = address(revenueIngressFactory);
        cfg.identityRegistry = IDENTITY_REGISTRY;
        cfg.tokenFactory = address(tokenFactory);
        cfg.strategyFactory = address(strategyFactory);
        cfg.auctionInitializerFactory = address(auctionFactory);
        cfg.poolManager = address(poolManager);
        cfg.positionManager = address(0xDEAD);
        cfg.positionRecipient = POSITION_RECIPIENT;
        cfg.strategyOperator = STRATEGY_OPERATOR;
        cfg.usdcToken = address(usdc);
        cfg.regentRecipient = REGENT_RECIPIENT;
        cfg.identityAgentId = IDENTITY_AGENT_ID;
        cfg.totalSupply = TOTAL_SUPPLY;
        cfg.officialPoolFee = 0;
        cfg.officialPoolTickSpacing = 60;
        cfg.auctionTickSpacing = AUCTION_TICK_SPACING;
        cfg.startBlock = 1;
        cfg.endBlock = 101;
        cfg.claimBlock = 101;
        cfg.migrationBlock = 202;
        cfg.sweepBlock = 303;
        cfg.vestingStartTimestamp = 1_700_000_000;
        cfg.vestingDurationSeconds = 365 days;
        cfg.validationHook = address(0);
        cfg.floorPrice = AUCTION_TICK_SPACING;
        cfg.requiredCurrencyRaised = 0;
        cfg.maxCurrencyAmountForLP = type(uint128).max;
        cfg.protocolSkimBps = 100;
        cfg.tokenName = "Agent Coin";
        cfg.tokenSymbol = "AGENT";
        cfg.subjectLabel = "Agent Coin";
        cfg.tokenFactoryData = bytes("");
        cfg.tokenFactorySalt = bytes32(0);
    }

    function _assertCoreAddressesWereCreated(
        LaunchDeploymentController.DeploymentResult memory result
    ) internal pure {
        assertTrue(result.tokenAddress != address(0));
        assertTrue(result.auctionAddress != address(0));
        assertTrue(result.strategyAddress != address(0));
        assertTrue(result.vestingWalletAddress != address(0));
        assertTrue(result.hookAddress != address(0));
        assertTrue(result.feeVaultAddress != address(0));
        assertTrue(result.launchFeeRegistryAddress != address(0));
        assertTrue(result.subjectRegistryAddress != address(0));
        assertTrue(result.revenueShareSplitterAddress != address(0));
        assertTrue(result.defaultIngressAddress != address(0));
    }
}
