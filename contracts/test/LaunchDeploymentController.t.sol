// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {AuctionParameters} from "src/cca/interfaces/IContinuousClearingAuction.sol";
import {LaunchDeploymentController} from "src/LaunchDeploymentController.sol";
import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";
import {LaunchFeeVault} from "src/LaunchFeeVault.sol";
import {LaunchPoolFeeHook} from "src/LaunchPoolFeeHook.sol";
import {AgentTokenVestingWallet} from "src/AgentTokenVestingWallet.sol";
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
    address internal constant AGENT_SAFE = address(0xABCD);
    address internal constant POSITION_RECIPIENT = AGENT_SAFE;
    address internal constant IDENTITY_REGISTRY = address(0x8004);
    address internal constant REGENT_RECIPIENT = address(0x9FA1);
    address internal constant STRATEGY_OPERATOR = address(0xBEEF);
    uint96 internal constant IDENTITY_AGENT_ID = 42;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 internal constant AUCTION_TICK_SPACING = 79_228_162_514_264_334_008_320;
    bytes32 internal constant LAUNCH_STACK_DEPLOYED_TOPIC0 = keccak256(
        "LaunchStackDeployed(address,bytes32,address,address,address,address,address,address,address,address,address,address,bytes32,address)"
    );

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
        revenueShareFactory.acceptSubjectRegistryOwnership();
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

    function testRejectsMismatchedPositionRecipient() external {
        LaunchDeploymentController.DeploymentConfig memory cfg = defaultConfig();
        cfg.positionRecipient = address(0x1234);

        vm.expectRevert("POSITION_RECIPIENT_MUST_MATCH_AGENT_SAFE");
        controller.deploy(cfg);
    }

    function testRejectsUnauthorizedDeployCaller() external {
        vm.prank(address(0xBAD));
        vm.expectRevert("ONLY_OWNER");
        controller.deploy(defaultConfig());
    }

    function testRejectsDeployWhenSubjectRegistryOwnershipNotAccepted() external {
        SubjectRegistry localSubjectRegistry = new SubjectRegistry(address(this));
        RevenueShareFactory localRevenueShareFactory =
            new RevenueShareFactory(address(this), address(usdc), localSubjectRegistry);
        RevenueIngressFactory localRevenueIngressFactory =
            new RevenueIngressFactory(address(usdc), address(localSubjectRegistry), address(this));

        localRevenueShareFactory.setAuthorizedCreator(address(controller), true);
        localRevenueIngressFactory.setAuthorizedCreator(address(controller), true);

        LaunchDeploymentController.DeploymentConfig memory cfg = defaultConfig();
        cfg.revenueShareFactory = address(localRevenueShareFactory);
        cfg.revenueIngressFactory = address(localRevenueIngressFactory);

        vm.expectRevert("SUBJECT_REGISTRY_NOT_OWNED_BY_FACTORY");
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
        assertEq(strategy.positionRecipient(), AGENT_SAFE);
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
        assertEq(registry.owner(), address(controller));
        assertEq(registry.pendingOwner(), AGENT_SAFE);

        RevenueShareSplitter splitter = RevenueShareSplitter(result.revenueShareSplitterAddress);
        assertEq(splitter.stakeToken(), result.tokenAddress);
        assertEq(splitter.usdc(), address(usdc));
        assertEq(splitter.owner(), address(revenueShareFactory));
        assertEq(splitter.pendingOwner(), AGENT_SAFE);
        assertEq(splitter.treasuryRecipient(), AGENT_SAFE);
        assertEq(splitter.protocolRecipient(), REGENT_RECIPIENT);

        LaunchFeeVault feeVault = LaunchFeeVault(payable(result.feeVaultAddress));
        assertEq(feeVault.owner(), address(controller));
        assertEq(feeVault.pendingOwner(), AGENT_SAFE);
        assertEq(feeVault.canonicalLaunchToken(), result.tokenAddress);
        assertEq(feeVault.canonicalQuoteToken(), address(usdc));

        LaunchPoolFeeHook hook = LaunchPoolFeeHook(result.hookAddress);
        assertEq(hook.owner(), address(controller));
        assertEq(hook.pendingOwner(), AGENT_SAFE);

        AgentTokenVestingWallet vestingWallet = AgentTokenVestingWallet(result.vestingWalletAddress);
        assertEq(vestingWallet.beneficiary(), AGENT_SAFE);

        SubjectRegistry.SubjectConfig memory subject = subjectRegistry.getSubject(result.subjectId);
        assertEq(subject.stakeToken, result.tokenAddress);
        assertEq(subject.splitter, result.revenueShareSplitterAddress);
        assertEq(subject.treasurySafe, AGENT_SAFE);
        assertTrue(subject.active);
        assertTrue(subjectRegistry.subjectManagers(result.subjectId, AGENT_SAFE));

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

    function testEmitsLaunchStackDeployedEvent() external {
        vm.recordLogs();
        LaunchDeploymentController.DeploymentResult memory result =
            controller.deploy(defaultConfig());

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found;

        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].emitter == address(controller) && entries[i].topics.length == 4
                    && entries[i].topics[0] == LAUNCH_STACK_DEPLOYED_TOPIC0
            ) {
                found = true;
                assertEq(address(uint160(uint256(entries[i].topics[1]))), address(this));
                assertEq(entries[i].topics[2], result.subjectId);
                assertEq(address(uint160(uint256(entries[i].topics[3]))), result.tokenAddress);

                (
                    address auctionAddress,
                    address strategyAddress,
                    address vestingWalletAddress,
                    address hookAddress,
                    address feeVaultAddress,
                    address launchFeeRegistryAddress,
                    address subjectRegistryAddress,
                    address revenueShareSplitterAddress,
                    address defaultIngressAddress,
                    bytes32 poolId,
                    address agentSafe
                ) = abi.decode(
                    entries[i].data,
                    (
                        address,
                        address,
                        address,
                        address,
                        address,
                        address,
                        address,
                        address,
                        address,
                        bytes32,
                        address
                    )
                );

                assertEq(auctionAddress, result.auctionAddress);
                assertEq(strategyAddress, result.strategyAddress);
                assertEq(vestingWalletAddress, result.vestingWalletAddress);
                assertEq(hookAddress, result.hookAddress);
                assertEq(feeVaultAddress, result.feeVaultAddress);
                assertEq(launchFeeRegistryAddress, result.launchFeeRegistryAddress);
                assertEq(subjectRegistryAddress, result.subjectRegistryAddress);
                assertEq(revenueShareSplitterAddress, result.revenueShareSplitterAddress);
                assertEq(defaultIngressAddress, result.defaultIngressAddress);
                assertEq(poolId, result.poolId);
                assertEq(agentSafe, AGENT_SAFE);
                break;
            }
        }

        assertTrue(found);
    }

    function defaultConfig()
        internal
        view
        returns (LaunchDeploymentController.DeploymentConfig memory cfg)
    {
        cfg.agentSafe = AGENT_SAFE;
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
