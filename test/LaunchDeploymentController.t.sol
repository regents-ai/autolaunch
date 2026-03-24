// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {LaunchDeploymentController} from "src/LaunchDeploymentController.sol";
import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareSplitter} from "src/revenue/RevenueShareSplitter.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {
    MockContinuousClearingAuctionFactory
} from "test/mocks/MockContinuousClearingAuctionFactory.sol";
import {MockHookPoolManager} from "test/mocks/MockHookPoolManager.sol";

contract LaunchDeploymentControllerTest is Test {
    LaunchDeploymentController internal controller;
    MockContinuousClearingAuctionFactory internal factory;
    MockHookPoolManager internal poolManager;
    SubjectRegistry internal subjectRegistry;
    RevenueShareFactory internal revenueShareFactory;
    RevenueIngressFactory internal ingressFactory;

    function setUp() external {
        controller = new LaunchDeploymentController();
        factory = new MockContinuousClearingAuctionFactory();
        poolManager = new MockHookPoolManager();
        subjectRegistry = new SubjectRegistry(address(this));
        revenueShareFactory =
            new RevenueShareFactory(address(this), address(0x2222), subjectRegistry);
        ingressFactory = new RevenueIngressFactory(address(this));
        subjectRegistry.transferOwnership(address(revenueShareFactory));
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

    function testDeploysSubjectSplitterAndDefaultIngress() external {
        LaunchDeploymentController.DeploymentResult memory result = controller.deploy(defaultConfig());

        assertTrue(result.tokenAddress != address(0));
        assertTrue(result.auctionAddress != address(0));
        assertTrue(result.hookAddress != address(0));
        assertTrue(result.feeVaultAddress != address(0));
        assertTrue(result.launchFeeRegistryAddress != address(0));
        assertTrue(result.subjectRegistryAddress != address(0));
        assertTrue(result.revenueShareSplitterAddress != address(0));
        assertTrue(result.defaultIngressAddress != address(0));
        assertEq(result.revenueIngressRouterAddress, address(0xCAFE));
        assertTrue(result.subjectId != bytes32(0));
        assertTrue(result.poolId != bytes32(0));

        LaunchFeeRegistry registry = LaunchFeeRegistry(result.launchFeeRegistryAddress);
        LaunchFeeRegistry.PoolConfig memory poolConfig = registry.getPoolConfig(result.poolId);
        assertEq(poolConfig.treasury, result.revenueShareSplitterAddress);
        assertEq(poolConfig.quoteToken, address(0x2222));
        assertEq(poolConfig.regentRecipient, address(0x9FA1));

        RevenueShareSplitter splitter = RevenueShareSplitter(result.revenueShareSplitterAddress);
        assertEq(splitter.stakeToken(), result.tokenAddress);
        assertEq(splitter.usdc(), address(0x2222));
        assertEq(splitter.treasuryRecipient(), address(0x5678));
        assertEq(splitter.protocolRecipient(), address(0x9FA1));

        SubjectRegistry.SubjectConfig memory subject = subjectRegistry.getSubject(result.subjectId);
        assertEq(subject.stakeToken, result.tokenAddress);
        assertEq(subject.splitter, result.revenueShareSplitterAddress);
        assertEq(subject.treasurySafe, address(0xABCD));
        assertTrue(subject.active);

        bytes32 expectedSubjectId = keccak256(abi.encode(block.chainid, result.tokenAddress));
        assertEq(result.subjectId, expectedSubjectId);
        assertEq(subjectRegistry.subjectOfStakeToken(result.tokenAddress), expectedSubjectId);
        assertEq(
            subjectRegistry.subjectForIdentity(block.chainid, address(0x8004), 42), expectedSubjectId
        );
        assertEq(subjectRegistry.emissionRecipient(expectedSubjectId, block.chainid), address(0x2468));
        assertEq(ingressFactory.ingressCount(result.revenueShareSplitterAddress), 1);
        assertEq(
            ingressFactory.ingressAt(result.revenueShareSplitterAddress, 0),
            result.defaultIngressAddress
        );
    }

    function defaultConfig()
        internal
        view
        returns (LaunchDeploymentController.DeploymentConfig memory cfg)
    {
        cfg.recoverySafe = address(0xABCD);
        cfg.auctionProceedsRecipient = address(0x1234);
        cfg.agentRevenueTreasury = address(0x5678);
        cfg.revenueShareFactory = address(revenueShareFactory);
        cfg.revenueIngressFactory = address(ingressFactory);
        cfg.revenueIngressRouter = address(0xCAFE);
        cfg.identityRegistry = address(0x8004);
        cfg.factoryAddress = address(factory);
        cfg.poolManager = address(poolManager);
        cfg.usdcToken = address(0x2222);
        cfg.regentRecipient = address(0x9FA1);
        cfg.mainnetEmissionsController = address(0);
        cfg.emissionRecipient = address(0x2468);
        cfg.identityAgentId = 42;
        cfg.totalSupply = 1_000_000_000e18;
        cfg.poolFee = 0;
        cfg.poolTickSpacing = 60;
        cfg.auctionTickSpacing = 79_228_162_514_264_334_008_320;
        cfg.stepMps = 100_000;
        cfg.stepBlockDelta = 1;
        cfg.startBlock = 1;
        cfg.endBlock = 101;
        cfg.claimBlock = 101;
        cfg.validationHook = address(0);
        cfg.floorPrice = 79_228_162_514_264_334_008_320;
        cfg.requiredCurrencyRaised = 0;
        cfg.protocolSkimBps = 100;
        cfg.tokenName = "Agent Coin";
        cfg.tokenSymbol = "AGENT";
        cfg.subjectLabel = "Agent Coin";
    }

    function testMainnetControllerOverridesRegentRecipients() external {
        LaunchDeploymentController.DeploymentConfig memory cfg = defaultConfig();
        cfg.mainnetEmissionsController = address(0xE111);

        LaunchDeploymentController.DeploymentResult memory result = controller.deploy(cfg);

        LaunchFeeRegistry registry = LaunchFeeRegistry(result.launchFeeRegistryAddress);
        LaunchFeeRegistry.PoolConfig memory poolConfig = registry.getPoolConfig(result.poolId);
        assertEq(poolConfig.regentRecipient, address(0xE111));

        RevenueShareSplitter splitter = RevenueShareSplitter(result.revenueShareSplitterAddress);
        assertEq(splitter.protocolRecipient(), address(0xE111));
    }
}
