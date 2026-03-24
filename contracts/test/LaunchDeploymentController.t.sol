// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {AgentLaunchToken} from "src/AgentLaunchToken.sol";
import {AuctionParameters} from "src/cca/interfaces/IContinuousClearingAuction.sol";
import {LaunchDeploymentController} from "src/LaunchDeploymentController.sol";
import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {RevenueShareSplitter} from "src/revenue/RevenueShareSplitter.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {
    MockContinuousClearingAuctionFactory
} from "test/mocks/MockContinuousClearingAuctionFactory.sol";
import {MockHookPoolManager} from "test/mocks/MockHookPoolManager.sol";

contract LaunchDeploymentControllerTest is Test {
    address internal constant USDC = address(0x2222);
    address internal constant RECOVERY_SAFE = address(0xABCD);
    address internal constant AUCTION_PROCEEDS_RECIPIENT = address(0x1234);
    address internal constant AGENT_REVENUE_TREASURY = address(0x5678);
    address internal constant IDENTITY_REGISTRY = address(0x8004);
    address internal constant REGENT_RECIPIENT = address(0x9FA1);
    address internal constant EMISSION_RECIPIENT = address(0x2468);
    address internal constant MAINNET_EMISSIONS_CONTROLLER = address(0xE111);
    uint96 internal constant IDENTITY_AGENT_ID = 42;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 internal constant AUCTION_TICK_SPACING = 79_228_162_514_264_334_008_320;

    LaunchDeploymentController internal controller;
    MockContinuousClearingAuctionFactory internal factory;
    MockHookPoolManager internal poolManager;
    SubjectRegistry internal subjectRegistry;
    RevenueShareFactory internal revenueShareFactory;

    function setUp() external {
        controller = new LaunchDeploymentController();
        factory = new MockContinuousClearingAuctionFactory();
        poolManager = new MockHookPoolManager();
        subjectRegistry = new SubjectRegistry(address(this));
        revenueShareFactory = new RevenueShareFactory(address(this), USDC, subjectRegistry);
        subjectRegistry.transferOwnership(address(revenueShareFactory));
        revenueShareFactory.setAuthorizedCreator(address(controller), true);
    }

    function testRejectsMissingIdentityRegistry() external {
        LaunchDeploymentController.DeploymentConfig memory cfg = defaultConfig();
        cfg.identityRegistry = address(0);

        vm.expectRevert("IDENTITY_REGISTRY_ZERO");
        controller.deploy(cfg);
    }

    function testRejectsScheduleThatDoesNotCoverAuctionDuration() external {
        LaunchDeploymentController.DeploymentConfig memory cfg = defaultConfig();
        cfg.stepBlockDelta = 99;

        vm.expectRevert("STEP_BLOCK_DELTA_MISMATCH");
        controller.deploy(cfg);
    }

    function testDeploysSubjectSplitter() external {
        LaunchDeploymentController.DeploymentResult memory result =
            controller.deploy(defaultConfig());

        _assertCoreAddressesWereCreated(result);
        assertTrue(result.subjectId != bytes32(0));
        assertTrue(result.poolId != bytes32(0));

        AgentLaunchToken token = AgentLaunchToken(result.tokenAddress);
        uint256 expectedSaleAmount = TOTAL_SUPPLY / 10;
        uint256 expectedRetainedAmount = TOTAL_SUPPLY - expectedSaleAmount;
        assertEq(token.balanceOf(result.auctionAddress), expectedSaleAmount);
        assertEq(token.balanceOf(RECOVERY_SAFE), expectedRetainedAmount);
        assertEq(token.balanceOf(address(controller)), 0);
        assertEq(factory.lastAmount(), expectedSaleAmount);

        LaunchFeeRegistry registry = LaunchFeeRegistry(result.launchFeeRegistryAddress);
        LaunchFeeRegistry.PoolConfig memory poolConfig = registry.getPoolConfig(result.poolId);
        assertEq(poolConfig.treasury, result.revenueShareSplitterAddress);
        assertEq(poolConfig.quoteToken, USDC);
        assertEq(poolConfig.regentRecipient, REGENT_RECIPIENT);

        AuctionParameters memory parameters =
            abi.decode(factory.lastConfigData(), (AuctionParameters));
        assertEq(parameters.currency, USDC);

        RevenueShareSplitter splitter = RevenueShareSplitter(result.revenueShareSplitterAddress);
        assertEq(splitter.stakeToken(), result.tokenAddress);
        assertEq(splitter.usdc(), USDC);
        assertEq(splitter.treasuryRecipient(), AGENT_REVENUE_TREASURY);
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
        assertEq(
            subjectRegistry.emissionRecipient(expectedSubjectId, block.chainid), EMISSION_RECIPIENT
        );
    }

    function defaultConfig()
        internal
        view
        returns (LaunchDeploymentController.DeploymentConfig memory cfg)
    {
        cfg.recoverySafe = RECOVERY_SAFE;
        cfg.auctionProceedsRecipient = AUCTION_PROCEEDS_RECIPIENT;
        cfg.agentRevenueTreasury = AGENT_REVENUE_TREASURY;
        cfg.revenueShareFactory = address(revenueShareFactory);
        cfg.identityRegistry = IDENTITY_REGISTRY;
        cfg.factoryAddress = address(factory);
        cfg.poolManager = address(poolManager);
        cfg.usdcToken = USDC;
        cfg.regentRecipient = REGENT_RECIPIENT;
        cfg.mainnetEmissionsController = address(0);
        cfg.emissionRecipient = EMISSION_RECIPIENT;
        cfg.identityAgentId = IDENTITY_AGENT_ID;
        cfg.totalSupply = TOTAL_SUPPLY;
        cfg.poolFee = 0;
        cfg.poolTickSpacing = 60;
        cfg.auctionTickSpacing = AUCTION_TICK_SPACING;
        cfg.stepMps = 100_000;
        cfg.stepBlockDelta = 1;
        cfg.startBlock = 1;
        cfg.endBlock = 101;
        cfg.claimBlock = 101;
        cfg.validationHook = address(0);
        cfg.floorPrice = AUCTION_TICK_SPACING;
        cfg.requiredCurrencyRaised = 0;
        cfg.protocolSkimBps = 100;
        cfg.tokenName = "Agent Coin";
        cfg.tokenSymbol = "AGENT";
        cfg.subjectLabel = "Agent Coin";
    }

    function testMainnetControllerOverridesRegentRecipients() external {
        LaunchDeploymentController.DeploymentConfig memory cfg = defaultConfig();
        cfg.mainnetEmissionsController = MAINNET_EMISSIONS_CONTROLLER;

        LaunchDeploymentController.DeploymentResult memory result = controller.deploy(cfg);

        LaunchFeeRegistry registry = LaunchFeeRegistry(result.launchFeeRegistryAddress);
        LaunchFeeRegistry.PoolConfig memory poolConfig = registry.getPoolConfig(result.poolId);
        assertEq(poolConfig.regentRecipient, MAINNET_EMISSIONS_CONTROLLER);

        RevenueShareSplitter splitter = RevenueShareSplitter(result.revenueShareSplitterAddress);
        assertEq(splitter.protocolRecipient(), MAINNET_EMISSIONS_CONTROLLER);
    }

    function _assertCoreAddressesWereCreated(
        LaunchDeploymentController.DeploymentResult memory result
    ) internal pure {
        assertTrue(result.tokenAddress != address(0));
        assertTrue(result.auctionAddress != address(0));
        assertTrue(result.hookAddress != address(0));
        assertTrue(result.feeVaultAddress != address(0));
        assertTrue(result.launchFeeRegistryAddress != address(0));
        assertTrue(result.subjectRegistryAddress != address(0));
        assertTrue(result.revenueShareSplitterAddress != address(0));
    }
}
