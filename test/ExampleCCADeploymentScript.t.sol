// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ExampleCCADeploymentScript} from "scripts/ExampleCCADeploymentScript.s.sol";
import {AuctionParameters} from "src/cca/interfaces/IContinuousClearingAuction.sol";
import {LaunchDeploymentController} from "src/LaunchDeploymentController.sol";
import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {RevenueShareSplitter} from "src/revenue/RevenueShareSplitter.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {
    MockContinuousClearingAuctionFactory
} from "test/mocks/MockContinuousClearingAuctionFactory.sol";
import {MockHookPoolManager} from "test/mocks/MockHookPoolManager.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";

contract ExampleCCADeploymentScriptTest is Test {
    ExampleCCADeploymentScript internal script;
    MockContinuousClearingAuctionFactory internal factory;
    MockHookPoolManager internal poolManager;
    MintableERC20Mock internal usdc;
    SubjectRegistry internal subjectRegistry;
    RevenueShareFactory internal revenueShareFactory;
    RevenueIngressFactory internal ingressFactory;

    function setUp() external {
        script = new ExampleCCADeploymentScript();
        factory = new MockContinuousClearingAuctionFactory();
        poolManager = new MockHookPoolManager();
        usdc = new MintableERC20Mock("USD Coin", "USDC");
        subjectRegistry = new SubjectRegistry(address(this));
        revenueShareFactory =
            new RevenueShareFactory(address(this), address(usdc), subjectRegistry);
        ingressFactory = new RevenueIngressFactory(address(this));
        subjectRegistry.transferOwnership(address(revenueShareFactory));

        vm.setEnv("AUTOLAUNCH_RECOVERY_SAFE_ADDRESS", vm.toString(address(0x4321)));
        vm.setEnv("AUTOLAUNCH_AUCTION_PROCEEDS_RECIPIENT", vm.toString(address(0x1234)));
        vm.setEnv("AUTOLAUNCH_ETHEREUM_REVENUE_TREASURY", vm.toString(address(0x5678)));
        vm.setEnv("AUTOLAUNCH_EMISSION_RECIPIENT", vm.toString(address(0x2468)));
        vm.setEnv("REGENT_MULTISIG_ADDRESS", vm.toString(address(0x9FA1)));
        vm.setEnv("MAINNET_REGENT_EMISSIONS_CONTROLLER_ADDRESS", vm.toString(address(0xE111)));
        vm.setEnv("REVENUE_SHARE_FACTORY_ADDRESS", vm.toString(address(revenueShareFactory)));
        vm.setEnv("REVENUE_INGRESS_FACTORY_ADDRESS", vm.toString(address(ingressFactory)));
        vm.setEnv("REVENUE_INGRESS_ROUTER_ADDRESS", vm.toString(address(0xAAA1)));
        vm.setEnv("FACTORY_ADDRESS", vm.toString(address(factory)));
        vm.setEnv("UNISWAP_V4_POOL_MANAGER", vm.toString(address(poolManager)));
        vm.setEnv("AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS", vm.toString(address(0x8004)));
        vm.setEnv("AGENT_NAME", "Launch Agent");
        vm.setEnv("AGENT_SYMBOL", "LAGENT");
        vm.setEnv("AUTOLAUNCH_AGENT_ID", "1:42");
        vm.setEnv("TOTAL_SUPPLY", "1000000000000000000000");
        vm.setEnv("ETHEREUM_USDC_ADDRESS", vm.toString(address(usdc)));
        vm.setEnv("CCA_TICK_SPACING_Q96", "1000000000000000");
        vm.setEnv("CCA_FLOOR_PRICE_Q96", "79228162514264334008320");
        vm.setEnv("CCA_REQUIRED_CURRENCY_RAISED", "1000000000000000000");
        vm.setEnv("CCA_CLAIM_BLOCK_OFFSET", "64");
    }

    function testDeployFromEnvCreatesTokenAuctionAndSubjectStack() external {
        LaunchDeploymentController.DeploymentResult memory result = script.deployFromEnv();

        assertTrue(result.tokenAddress != address(0));
        assertTrue(result.auctionAddress != address(0));
        assertTrue(result.hookAddress != address(0));
        assertTrue(result.feeVaultAddress != address(0));
        assertTrue(result.launchFeeRegistryAddress != address(0));
        assertTrue(result.subjectRegistryAddress != address(0));
        assertTrue(result.revenueShareSplitterAddress != address(0));
        assertTrue(result.defaultIngressAddress != address(0));
        assertEq(result.revenueIngressRouterAddress, address(0xAAA1));
        assertTrue(result.subjectId != bytes32(0));
        assertTrue(result.poolId != bytes32(0));

        SubjectRegistry.SubjectConfig memory config = subjectRegistry.getSubject(result.subjectId);
        assertEq(config.stakeToken, result.tokenAddress);
        assertEq(config.splitter, result.revenueShareSplitterAddress);
        assertEq(config.treasurySafe, address(0x4321));
        assertTrue(config.active);

        LaunchFeeRegistry registry = LaunchFeeRegistry(result.launchFeeRegistryAddress);
        LaunchFeeRegistry.PoolConfig memory poolConfig = registry.getPoolConfig(result.poolId);
        assertEq(poolConfig.launchToken, result.tokenAddress);
        assertEq(poolConfig.quoteToken, address(usdc));
        assertEq(poolConfig.treasury, result.revenueShareSplitterAddress);
        assertEq(poolConfig.regentRecipient, address(0xE111));

        RevenueShareSplitter splitter = RevenueShareSplitter(result.revenueShareSplitterAddress);
        assertEq(splitter.stakeToken(), result.tokenAddress);
        assertEq(splitter.usdc(), address(usdc));
        assertEq(splitter.treasuryRecipient(), address(0x5678));
        assertEq(splitter.protocolRecipient(), address(0xE111));

        assertEq(
            subjectRegistry.subjectForIdentity(block.chainid, address(0x8004), 42), result.subjectId
        );
        assertEq(subjectRegistry.emissionRecipient(result.subjectId, block.chainid), address(0x2468));
        assertEq(ingressFactory.ingressCount(result.revenueShareSplitterAddress), 1);
        assertEq(
            ingressFactory.ingressAt(result.revenueShareSplitterAddress, 0),
            result.defaultIngressAddress
        );

        AuctionParameters memory parameters =
            abi.decode(factory.lastConfigData(), (AuctionParameters));
        assertEq(parameters.currency, address(0));
        assertEq(parameters.tokensRecipient, address(0x4321));
        assertEq(parameters.fundsRecipient, address(0x1234));
        assertEq(parameters.tickSpacing, 1_000_000_000_000_000);
        assertEq(parameters.floorPrice, 79_228_162_514_264_334_008_320);
        assertEq(parameters.requiredCurrencyRaised, 1 ether);
        assertEq(parameters.claimBlock, parameters.endBlock + 64);
        assertEq(parameters.validationHook, address(0));
        assertEq(parameters.endBlock - parameters.startBlock, 21_600);
    }
}
