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
import {ExampleCCADeploymentScript} from "scripts/ExampleCCADeploymentScript.s.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";
import {
    MockContinuousClearingAuctionFactory
} from "test/mocks/MockContinuousClearingAuctionFactory.sol";
import {MockHookPoolManager} from "test/mocks/MockHookPoolManager.sol";
import {MockLaunchToken, MockTokenFactory} from "test/mocks/MockTokenFactory.sol";

contract ExampleCCADeploymentScriptTest is Test {
    address internal constant AGENT_SAFE = address(0x4321);
    address internal constant REGENT_MULTISIG = address(0x9FA1);
    address internal constant IDENTITY_REGISTRY = address(0x8004);
    address internal constant STRATEGY_OPERATOR = address(0xBEEF);
    uint256 internal constant IDENTITY_AGENT_ID = 42;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000_000_000_000_000;
    uint256 internal constant CCA_TICK_SPACING_Q96 = 1_000_000_000_000_000;
    uint256 internal constant CCA_FLOOR_PRICE_Q96 = 79_228_162_514_264_334_008_320;

    ExampleCCADeploymentScript internal script;
    MockContinuousClearingAuctionFactory internal auctionFactory;
    MockHookPoolManager internal poolManager;
    MintableERC20Mock internal usdc;
    SubjectRegistry internal subjectRegistry;
    RevenueShareFactory internal revenueShareFactory;
    RevenueIngressFactory internal revenueIngressFactory;
    RegentLBPStrategyFactory internal strategyFactory;
    MockTokenFactory internal tokenFactory;

    function setUp() external {
        script = new ExampleCCADeploymentScript();
        vm.chainId(84532);
        auctionFactory = new MockContinuousClearingAuctionFactory();
        poolManager = new MockHookPoolManager();
        usdc = new MintableERC20Mock("USD Coin", "USDC");
        subjectRegistry = new SubjectRegistry(address(this));
        revenueShareFactory =
            new RevenueShareFactory(address(script), address(usdc), subjectRegistry);
        revenueIngressFactory =
            new RevenueIngressFactory(address(usdc), address(subjectRegistry), address(script));
        strategyFactory = new RegentLBPStrategyFactory();
        tokenFactory = new MockTokenFactory();
        subjectRegistry.transferOwnership(address(revenueShareFactory));
        revenueShareFactory.acceptSubjectRegistryOwnership();

        _setEnvAddress("AUTOLAUNCH_AGENT_SAFE_ADDRESS", AGENT_SAFE);
        _setEnvAddress("REGENT_MULTISIG_ADDRESS", REGENT_MULTISIG);
        vm.setEnv(
            "AUTOLAUNCH_REVENUE_SHARE_FACTORY_ADDRESS",
            vm.toString(address(revenueShareFactory))
        );
        vm.setEnv(
            "AUTOLAUNCH_REVENUE_INGRESS_FACTORY_ADDRESS",
            vm.toString(address(revenueIngressFactory))
        );
        vm.setEnv(
            "AUTOLAUNCH_LBP_STRATEGY_FACTORY_ADDRESS",
            vm.toString(address(strategyFactory))
        );
        vm.setEnv("AUTOLAUNCH_TOKEN_FACTORY_ADDRESS", vm.toString(address(tokenFactory)));
        vm.setEnv("AUTOLAUNCH_CCA_FACTORY_ADDRESS", vm.toString(address(auctionFactory)));
        vm.setEnv("AUTOLAUNCH_UNISWAP_V4_POOL_MANAGER", vm.toString(address(poolManager)));
        vm.setEnv("AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER", vm.toString(address(0xDEAD)));
        _setEnvAddress("AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS", IDENTITY_REGISTRY);
        _setEnvAddress("STRATEGY_OPERATOR", STRATEGY_OPERATOR);
        vm.setEnv("AUTOLAUNCH_TOKEN_NAME", "Launch Agent");
        vm.setEnv("AUTOLAUNCH_TOKEN_SYMBOL", "LAGENT");
        vm.setEnv("AUTOLAUNCH_AGENT_ID", "1:42");
        vm.setEnv("AUTOLAUNCH_TOTAL_SUPPLY", vm.toString(TOTAL_SUPPLY));
        vm.setEnv("AUTOLAUNCH_USDC_ADDRESS", vm.toString(address(usdc)));
        vm.setEnv("CCA_TICK_SPACING_Q96", vm.toString(CCA_TICK_SPACING_Q96));
        vm.setEnv("CCA_FLOOR_PRICE_Q96", vm.toString(CCA_FLOOR_PRICE_Q96));
        vm.setEnv("CCA_REQUIRED_CURRENCY_RAISED", "1000000000000000000");
        vm.setEnv("CCA_CLAIM_BLOCK_OFFSET", "64");
        vm.setEnv("LBP_MIGRATION_BLOCK_OFFSET", "128");
        vm.setEnv("LBP_SWEEP_BLOCK_OFFSET", "256");
        vm.setEnv("VESTING_START_TIMESTAMP", "1700000000");
        vm.setEnv("VESTING_DURATION_SECONDS", "31536000");
    }

    function testDeployFromEnvCreatesModelBLaunchStack() external {
        LaunchDeploymentController.DeploymentResult memory result = script.deployFromEnv();

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
        assertEq(auctionFactory.lastAmount(), expectedAuctionAmount);
        RegentLBPStrategy strategy = RegentLBPStrategy(result.strategyAddress);
        assertEq(strategy.officialPoolFee(), 0);
        assertEq(strategy.officialPoolTickSpacing(), 60);
        assertEq(strategy.positionManager(), address(0xDEAD));
        assertEq(strategy.positionRecipient(), AGENT_SAFE);
        assertEq(strategy.poolManager(), address(poolManager));

        SubjectRegistry.SubjectConfig memory config = subjectRegistry.getSubject(result.subjectId);
        assertEq(config.stakeToken, result.tokenAddress);
        assertEq(config.splitter, result.revenueShareSplitterAddress);
        assertEq(config.treasurySafe, AGENT_SAFE);
        assertTrue(config.active);

        LaunchFeeRegistry registry = LaunchFeeRegistry(result.launchFeeRegistryAddress);
        LaunchFeeRegistry.PoolConfig memory poolConfig = registry.getPoolConfig(result.poolId);
        assertEq(poolConfig.launchToken, result.tokenAddress);
        assertEq(poolConfig.quoteToken, address(usdc));
        assertEq(poolConfig.treasury, result.revenueShareSplitterAddress);
        assertEq(poolConfig.regentRecipient, REGENT_MULTISIG);

        RevenueShareSplitter splitter = RevenueShareSplitter(result.revenueShareSplitterAddress);
        assertEq(splitter.stakeToken(), result.tokenAddress);
        assertEq(splitter.usdc(), address(usdc));
        assertEq(splitter.treasuryRecipient(), AGENT_SAFE);
        assertEq(splitter.protocolRecipient(), REGENT_MULTISIG);
        assertEq(splitter.protocolSkimBps(), 100);

        assertEq(
            subjectRegistry.subjectForIdentity(block.chainid, IDENTITY_REGISTRY, IDENTITY_AGENT_ID),
            result.subjectId
        );
        AuctionParameters memory parameters =
            abi.decode(auctionFactory.lastConfigData(), (AuctionParameters));
        assertEq(parameters.currency, address(usdc));
        assertEq(parameters.tokensRecipient, result.strategyAddress);
        assertEq(parameters.fundsRecipient, result.strategyAddress);
        assertEq(parameters.tickSpacing, CCA_TICK_SPACING_Q96);
        assertEq(parameters.floorPrice, CCA_FLOOR_PRICE_Q96);
        assertEq(parameters.requiredCurrencyRaised, 1 ether);
        assertEq(parameters.claimBlock, parameters.endBlock + 64);
        assertEq(parameters.validationHook, address(0));
        assertEq(parameters.endBlock - parameters.startBlock, 9258);

        assertEq(
            revenueIngressFactory.defaultIngressOfSubject(result.subjectId),
            result.defaultIngressAddress
        );
    }

    function _setEnvAddress(string memory key, address value) internal {
        vm.setEnv(key, vm.toString(value));
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

    function testDeployFromEnvRejectsNonBaseFamilyChain() external {
        vm.chainId(1);

        vm.expectRevert("BASE_FAMILY_ONLY");
        script.deployFromEnv();
    }
}
