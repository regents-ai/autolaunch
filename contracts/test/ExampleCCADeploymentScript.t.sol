// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {AgentLaunchToken} from "src/AgentLaunchToken.sol";
import {ExampleCCADeploymentScript} from "scripts/ExampleCCADeploymentScript.s.sol";
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
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";

contract ExampleCCADeploymentScriptTest is Test {
    address internal constant RECOVERY_SAFE = address(0x4321);
    address internal constant AUCTION_PROCEEDS_RECIPIENT = address(0x1234);
    address internal constant AGENT_REVENUE_TREASURY = address(0x5678);
    address internal constant EMISSION_RECIPIENT = address(0x2468);
    address internal constant REGENT_MULTISIG = address(0x9FA1);
    address internal constant MAINNET_EMISSIONS_CONTROLLER = address(0xE111);
    address internal constant IDENTITY_REGISTRY = address(0x8004);
    uint256 internal constant IDENTITY_AGENT_ID = 42;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000_000_000_000_000;
    uint256 internal constant CCA_TICK_SPACING_Q96 = 1_000_000_000_000_000;
    uint256 internal constant CCA_FLOOR_PRICE_Q96 = 79_228_162_514_264_334_008_320;

    ExampleCCADeploymentScript internal script;
    MockContinuousClearingAuctionFactory internal factory;
    MockHookPoolManager internal poolManager;
    MintableERC20Mock internal usdc;
    SubjectRegistry internal subjectRegistry;
    RevenueShareFactory internal revenueShareFactory;

    function setUp() external {
        script = new ExampleCCADeploymentScript();
        factory = new MockContinuousClearingAuctionFactory();
        poolManager = new MockHookPoolManager();
        usdc = new MintableERC20Mock("USD Coin", "USDC");
        subjectRegistry = new SubjectRegistry(address(this));
        revenueShareFactory =
            new RevenueShareFactory(address(script), address(usdc), subjectRegistry);
        subjectRegistry.transferOwnership(address(revenueShareFactory));

        _setEnvAddress("AUTOLAUNCH_RECOVERY_SAFE_ADDRESS", RECOVERY_SAFE);
        _setEnvAddress("AUTOLAUNCH_AUCTION_PROCEEDS_RECIPIENT", AUCTION_PROCEEDS_RECIPIENT);
        _setEnvAddress("AUTOLAUNCH_ETHEREUM_REVENUE_TREASURY", AGENT_REVENUE_TREASURY);
        _setEnvAddress("AUTOLAUNCH_EMISSION_RECIPIENT", EMISSION_RECIPIENT);
        _setEnvAddress("REGENT_MULTISIG_ADDRESS", REGENT_MULTISIG);
        _setEnvAddress("MAINNET_REGENT_EMISSIONS_CONTROLLER_ADDRESS", MAINNET_EMISSIONS_CONTROLLER);
        vm.setEnv("REVENUE_SHARE_FACTORY_ADDRESS", vm.toString(address(revenueShareFactory)));
        vm.setEnv("FACTORY_ADDRESS", vm.toString(address(factory)));
        vm.setEnv("UNISWAP_V4_POOL_MANAGER", vm.toString(address(poolManager)));
        _setEnvAddress("AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS", IDENTITY_REGISTRY);
        vm.setEnv("AGENT_NAME", "Launch Agent");
        vm.setEnv("AGENT_SYMBOL", "LAGENT");
        vm.setEnv("AUTOLAUNCH_AGENT_ID", "1:42");
        vm.setEnv("TOTAL_SUPPLY", vm.toString(TOTAL_SUPPLY));
        vm.setEnv("ETHEREUM_USDC_ADDRESS", vm.toString(address(usdc)));
        vm.setEnv("CCA_TICK_SPACING_Q96", vm.toString(CCA_TICK_SPACING_Q96));
        vm.setEnv("CCA_FLOOR_PRICE_Q96", vm.toString(CCA_FLOOR_PRICE_Q96));
        vm.setEnv("CCA_REQUIRED_CURRENCY_RAISED", "1000000000000000000");
        vm.setEnv("CCA_CLAIM_BLOCK_OFFSET", "64");
    }

    function testDeployFromEnvCreatesTokenAuctionAndSubjectStack() external {
        LaunchDeploymentController.DeploymentResult memory result = script.deployFromEnv();

        _assertCoreAddressesWereCreated(result);
        assertTrue(result.subjectId != bytes32(0));
        assertTrue(result.poolId != bytes32(0));

        AgentLaunchToken token = AgentLaunchToken(result.tokenAddress);
        uint256 expectedSaleAmount = TOTAL_SUPPLY / 10;
        uint256 expectedRetainedAmount = TOTAL_SUPPLY - expectedSaleAmount;
        assertEq(token.balanceOf(result.auctionAddress), expectedSaleAmount);
        assertEq(token.balanceOf(RECOVERY_SAFE), expectedRetainedAmount);
        assertEq(factory.lastAmount(), expectedSaleAmount);

        SubjectRegistry.SubjectConfig memory config = subjectRegistry.getSubject(result.subjectId);
        assertEq(config.stakeToken, result.tokenAddress);
        assertEq(config.splitter, result.revenueShareSplitterAddress);
        assertEq(config.treasurySafe, RECOVERY_SAFE);
        assertTrue(config.active);

        LaunchFeeRegistry registry = LaunchFeeRegistry(result.launchFeeRegistryAddress);
        LaunchFeeRegistry.PoolConfig memory poolConfig = registry.getPoolConfig(result.poolId);
        assertEq(poolConfig.launchToken, result.tokenAddress);
        assertEq(poolConfig.quoteToken, address(usdc));
        assertEq(poolConfig.treasury, result.revenueShareSplitterAddress);
        assertEq(poolConfig.regentRecipient, MAINNET_EMISSIONS_CONTROLLER);

        RevenueShareSplitter splitter = RevenueShareSplitter(result.revenueShareSplitterAddress);
        assertEq(splitter.stakeToken(), result.tokenAddress);
        assertEq(splitter.usdc(), address(usdc));
        assertEq(splitter.treasuryRecipient(), AGENT_REVENUE_TREASURY);
        assertEq(splitter.protocolRecipient(), MAINNET_EMISSIONS_CONTROLLER);

        assertEq(
            subjectRegistry.subjectForIdentity(block.chainid, IDENTITY_REGISTRY, IDENTITY_AGENT_ID),
            result.subjectId
        );
        assertEq(
            subjectRegistry.emissionRecipient(result.subjectId, block.chainid), EMISSION_RECIPIENT
        );

        AuctionParameters memory parameters =
            abi.decode(factory.lastConfigData(), (AuctionParameters));
        assertEq(parameters.currency, address(usdc));
        assertEq(parameters.tokensRecipient, RECOVERY_SAFE);
        assertEq(parameters.fundsRecipient, AUCTION_PROCEEDS_RECIPIENT);
        assertEq(parameters.tickSpacing, CCA_TICK_SPACING_Q96);
        assertEq(parameters.floorPrice, CCA_FLOOR_PRICE_Q96);
        assertEq(parameters.requiredCurrencyRaised, 1 ether);
        assertEq(parameters.claimBlock, parameters.endBlock + 64);
        assertEq(parameters.validationHook, address(0));
        assertEq(parameters.endBlock - parameters.startBlock, 21_600);
    }

    function _setEnvAddress(string memory key, address value) internal {
        vm.setEnv(key, vm.toString(value));
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
