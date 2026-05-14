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
import {RevenueShareSplitterV2} from "src/revenue/RevenueShareSplitterV2.sol";
import {RevenueShareSplitterV2Deployer} from "src/revenue/RevenueShareSplitterV2Deployer.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {ExampleCCADeploymentScript} from "scripts/ExampleCCADeploymentScript.s.sol";
import {
    MockContinuousClearingAuctionFactory
} from "test/mocks/MockContinuousClearingAuctionFactory.sol";
import {MockRegentStakingRevenueRouter} from "test/mocks/MockRegentStakingRevenueRouter.sol";
import {MockHookPoolManager} from "test/mocks/MockHookPoolManager.sol";
import {UERC20Factory} from "@uniswap/uerc20-factory/src/factories/UERC20Factory.sol";

interface IUERC20LaunchToken {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function creator() external view returns (address);
    function graffiti() external view returns (bytes32);
    function tokenURI() external view returns (string memory);
}

contract ExampleCCADeploymentScriptHarness is ExampleCCADeploymentScript {
    function convexAuctionStepsForTest(
        uint256 durationBlocks,
        uint256 prebidBlocks,
        uint256 finalBlockBps
    ) external pure returns (bytes memory) {
        return _convexAuctionSteps(durationBlocks, prebidBlocks, finalBlockBps);
    }
}

contract ExampleCCADeploymentScriptTest is Test {
    address internal constant AGENT_SAFE = address(0x4321);
    address internal constant REGENT_MULTISIG = address(0x9FA1);
    address internal constant IDENTITY_REGISTRY = address(0x8004);
    address internal constant STRATEGY_OPERATOR = address(0xBEEF);
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    uint256 internal constant IDENTITY_AGENT_ID = 42;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000_000_000_000_000;
    uint256 internal constant CCA_TICK_SPACING_Q96 = 792_281_625_142_643_340_083;
    uint256 internal constant CCA_FLOOR_PRICE_Q96 = 79_228_162_514_264_334_008_300;

    ExampleCCADeploymentScript internal script;
    ExampleCCADeploymentScriptHarness internal scheduleHarness;
    MockContinuousClearingAuctionFactory internal auctionFactory;
    MockHookPoolManager internal poolManager;
    SubjectRegistry internal subjectRegistry;
    RevenueShareFactory internal revenueShareFactory;
    RevenueShareSplitterV2Deployer internal splitterDeployer;
    RevenueIngressFactory internal revenueIngressFactory;
    RegentLBPStrategyFactory internal strategyFactory;
    UERC20Factory internal tokenFactory;
    MockRegentStakingRevenueRouter internal feeRouter;

    function setUp() external {
        script = new ExampleCCADeploymentScript();
        scheduleHarness = new ExampleCCADeploymentScriptHarness();
        vm.chainId(84_532);
        auctionFactory = new MockContinuousClearingAuctionFactory();
        poolManager = new MockHookPoolManager();
        subjectRegistry = new SubjectRegistry(address(this));
        feeRouter = new MockRegentStakingRevenueRouter(USDC, address(0x8888));
        splitterDeployer = new RevenueShareSplitterV2Deployer();
        revenueShareFactory = new RevenueShareFactory(
            address(script), USDC, subjectRegistry, address(feeRouter), address(splitterDeployer)
        );
        revenueIngressFactory =
            new RevenueIngressFactory(USDC, address(subjectRegistry), address(script));
        strategyFactory = new RegentLBPStrategyFactory(address(script));
        tokenFactory = new UERC20Factory();
        subjectRegistry.setAuthorizedRegistrar(address(revenueShareFactory), true);

        _setEnvAddress("AUTOLAUNCH_AGENT_SAFE_ADDRESS", AGENT_SAFE);
        _setEnvAddress("REGENT_MULTISIG_ADDRESS", REGENT_MULTISIG);
        vm.setEnv(
            "AUTOLAUNCH_REVENUE_SHARE_FACTORY_ADDRESS", vm.toString(address(revenueShareFactory))
        );
        vm.setEnv(
            "AUTOLAUNCH_REVENUE_INGRESS_FACTORY_ADDRESS",
            vm.toString(address(revenueIngressFactory))
        );
        vm.setEnv("AUTOLAUNCH_LBP_STRATEGY_FACTORY_ADDRESS", vm.toString(address(strategyFactory)));
        vm.setEnv("AUTOLAUNCH_TOKEN_FACTORY_ADDRESS", vm.toString(address(tokenFactory)));
        vm.setEnv("AUTOLAUNCH_CCA_FACTORY_ADDRESS", vm.toString(address(auctionFactory)));
        vm.setEnv("AUTOLAUNCH_FACTORY_OWNER_ADDRESS", vm.toString(address(script)));
        vm.setEnv("AUTOLAUNCH_UNISWAP_V4_POOL_MANAGER", vm.toString(address(poolManager)));
        vm.setEnv("AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER", vm.toString(address(0xDEAD)));
        _setEnvAddress("AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS", IDENTITY_REGISTRY);
        _setEnvAddress("STRATEGY_OPERATOR", STRATEGY_OPERATOR);
        vm.setEnv("AUTOLAUNCH_TOKEN_NAME", "Launch Agent");
        vm.setEnv("AUTOLAUNCH_TOKEN_SYMBOL", "LAGENT");
        vm.setEnv("AUTOLAUNCH_TOKEN_METADATA_DESCRIPTION", "Regent launch rehearsal");
        vm.setEnv("AUTOLAUNCH_TOKEN_METADATA_WEBSITE", "https://autolaunch.sh");
        vm.setEnv("AUTOLAUNCH_TOKEN_METADATA_IMAGE", "");
        vm.setEnv("AUTOLAUNCH_AGENT_ID", "1:42");
        vm.setEnv("AUTOLAUNCH_TOTAL_SUPPLY", vm.toString(TOTAL_SUPPLY));
        vm.setEnv("CCA_TICK_SPACING_Q96", vm.toString(CCA_TICK_SPACING_Q96));
        vm.setEnv("CCA_FLOOR_PRICE_Q96", vm.toString(CCA_FLOOR_PRICE_Q96));
        vm.setEnv("CCA_REQUIRED_CURRENCY_RAISED", "1000000000000000000");
        vm.setEnv("AUCTION_DURATION_BLOCKS", "86400");
        vm.setEnv("CCA_PREBID_BLOCKS", "0");
        vm.setEnv("CCA_FINAL_BLOCK_BPS", "3000");
        vm.setEnv("CCA_CLAIM_BLOCK_OFFSET", "64");
        vm.setEnv("LBP_MIGRATION_BLOCK_OFFSET", "128");
        vm.setEnv("LBP_SWEEP_BLOCK_OFFSET", "256");
        vm.setEnv("VESTING_START_TIMESTAMP", "1700000000");
        vm.setEnv("VESTING_DURATION_SECONDS", "31536000");
    }

    function testDeployFromEnvCreatesModelBLaunchStack() external {
        vm.chainId(84_532);
        vm.setEnv("AUTOLAUNCH_USDC_ADDRESS", vm.toString(USDC));

        LaunchDeploymentController.DeploymentResult memory result = script.deployFromEnv();

        _assertCoreAddressesWereCreated(result);
        assertTrue(result.subjectId != bytes32(0));
        assertTrue(result.poolId != bytes32(0));

        uint256 expectedAuctionAmount = TOTAL_SUPPLY / 10;
        uint256 expectedReserveAmount = (TOTAL_SUPPLY * 500) / 10_000;
        uint256 expectedVestingAmount = TOTAL_SUPPLY - expectedAuctionAmount - expectedReserveAmount;

        IUERC20LaunchToken token = IUERC20LaunchToken(result.tokenAddress);
        assertEq(token.balanceOf(result.auctionAddress), expectedAuctionAmount);
        assertEq(token.balanceOf(result.strategyAddress), expectedReserveAmount);
        assertEq(token.balanceOf(result.vestingWalletAddress), expectedVestingAmount);
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertTrue(bytes(token.tokenURI()).length > 0);
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
        assertEq(poolConfig.quoteToken, USDC);
        assertEq(poolConfig.treasury, result.revenueShareSplitterAddress);
        assertEq(poolConfig.regentRecipient, REGENT_MULTISIG);

        RevenueShareSplitterV2 splitter = RevenueShareSplitterV2(result.revenueShareSplitterAddress);
        assertEq(splitter.stakeToken(), result.tokenAddress);
        assertEq(splitter.usdc(), USDC);
        assertEq(splitter.treasuryRecipient(), AGENT_SAFE);
        assertEq(splitter.protocolRecipient(), address(feeRouter));
        assertEq(strategyFactory.owner(), address(script));

        assertEq(
            subjectRegistry.subjectForIdentity(block.chainid, IDENTITY_REGISTRY, IDENTITY_AGENT_ID),
            result.subjectId
        );
        AuctionParameters memory parameters =
            abi.decode(auctionFactory.lastConfigData(), (AuctionParameters));
        assertEq(parameters.currency, USDC);
        assertEq(parameters.tokensRecipient, result.strategyAddress);
        assertEq(parameters.fundsRecipient, result.strategyAddress);
        assertEq(parameters.tickSpacing, CCA_TICK_SPACING_Q96);
        assertEq(parameters.floorPrice, CCA_FLOOR_PRICE_Q96);
        assertEq(parameters.requiredCurrencyRaised, 1 ether);
        assertEq(parameters.claimBlock, parameters.endBlock + 64);
        assertEq(parameters.validationHook, address(0));
        assertEq(parameters.endBlock - parameters.startBlock, 86_401);
        assertEq(parameters.auctionStepsData, _defaultConvexAuctionSteps());
        _assertScheduleTotals(parameters.auctionStepsData, 86_401);

        assertEq(
            revenueIngressFactory.defaultIngressOfSubject(result.subjectId),
            result.defaultIngressAddress
        );
        address controller = strategy.auctionCreator();
        assertEq(token.creator(), controller);
        assertEq(token.graffiti(), keccak256(abi.encode(AGENT_SAFE)));
        assertFalse(revenueShareFactory.authorizedCreators(controller));
        assertFalse(revenueIngressFactory.authorizedCreators(controller));
        assertFalse(strategyFactory.authorizedCreators(controller));
    }

    function testDeployFromEnvPrependsPrebidBlocks() external view {
        bytes memory steps = scheduleHarness.convexAuctionStepsForTest(86_400, 100, 3000);
        assertEq(steps, abi.encodePacked(uint24(0), uint40(100), _defaultConvexAuctionSteps()));
        _assertScheduleTotals(steps, 86_501);
    }

    function testDeployFromEnvAcceptsMinimumConvexDuration() external view {
        bytes memory steps = scheduleHarness.convexAuctionStepsForTest(13, 0, 3000);
        _assertScheduleTotals(steps, 14);
    }

    function testDeployFromEnvRejectsTooShortConvexDuration() external {
        vm.expectRevert("AUCTION_STEP_BLOCKS_ZERO");
        scheduleHarness.convexAuctionStepsForTest(12, 0, 3000);
    }

    function testDeployFromEnvAcceptsFinalBlockBpsBounds() external view {
        _assertFinalBlockBpsAccepted(2000);
        _assertFinalBlockBpsAccepted(3000);
        _assertFinalBlockBpsAccepted(4000);
    }

    function testDeployFromEnvRejectsFinalBlockBpsBelowRange() external {
        vm.expectRevert("CCA_FINAL_BLOCK_BPS_INVALID");
        scheduleHarness.convexAuctionStepsForTest(86_400, 0, 1999);
    }

    function testDeployFromEnvRejectsFinalBlockBpsAboveRange() external {
        vm.expectRevert("CCA_FINAL_BLOCK_BPS_INVALID");
        scheduleHarness.convexAuctionStepsForTest(86_400, 0, 4001);
    }

    function _setEnvAddress(string memory key, address value) internal {
        vm.setEnv(key, vm.toString(value));
    }

    function _assertFinalBlockBpsAccepted(uint256 finalBlockBps) internal view {
        bytes memory steps = scheduleHarness.convexAuctionStepsForTest(86_400, 0, finalBlockBps);
        _assertScheduleTotals(steps, 86_401);
    }

    function _defaultConvexAuctionSteps() internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint24(54),
            uint40(10_894),
            uint24(68),
            uint40(8517),
            uint24(75),
            uint40(7803),
            uint24(79),
            uint40(7373),
            uint24(83),
            uint40(7068),
            uint24(85),
            uint40(6835),
            uint24(88),
            uint40(6647),
            uint24(90),
            uint40(6490),
            uint24(92),
            uint40(6356),
            uint24(94),
            uint40(6238),
            uint24(95),
            uint40(6136),
            uint24(97),
            uint40(6043),
            uint24(2_988_006),
            uint40(1)
        );
    }

    function _assertScheduleTotals(bytes memory steps, uint256 expectedBlocks) internal pure {
        uint256 totalMps;
        uint256 totalBlocks;

        for (uint256 offset; offset < steps.length; offset += 8) {
            uint256 packed;
            assembly {
                packed := shr(192, mload(add(add(steps, 0x20), offset)))
            }

            uint256 stepMps = packed >> 40;
            uint256 blockDelta = packed & type(uint40).max;
            totalMps += stepMps * blockDelta;
            totalBlocks += blockDelta;
        }

        assertEq(totalMps, 10_000_000);
        assertEq(totalBlocks, expectedBlocks);
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

    function testDeployFromEnvRejectsNonBaseChain() external {
        vm.chainId(1);
        vm.setEnv("AUTOLAUNCH_USDC_ADDRESS", vm.toString(USDC));

        vm.expectRevert("BASE_CHAIN_ONLY");
        script.deployFromEnv();
    }

    function testDeployFromEnvRejectsWrongBaseMainnetUsdc() external {
        vm.chainId(8453);
        vm.setEnv("AUTOLAUNCH_USDC_ADDRESS", vm.toString(USDC));

        vm.expectRevert("USDC_NOT_CANONICAL");
        script.deployFromEnv();
    }
}
