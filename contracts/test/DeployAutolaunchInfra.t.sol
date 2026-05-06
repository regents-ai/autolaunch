// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeployAutolaunchInfraScript} from "scripts/DeployAutolaunchInfra.s.sol";
import {RegentLBPStrategyFactory} from "src/RegentLBPStrategyFactory.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {RevenueShareSplitterV2Deployer} from "src/revenue/RevenueShareSplitterV2Deployer.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {
    PermissionlessExistingTokenRevenueFactory
} from "src/revenue/PermissionlessExistingTokenRevenueFactory.sol";
import {DeferredAutolaunchFactory} from "src/revenue/DeferredAutolaunchFactory.sol";
import {MockRegentRevenueFeeRouter} from "test/mocks/MockRegentRevenueFeeRouter.sol";

contract DeployAutolaunchInfraScriptTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant DEPLOYER = address(0xBEEF);
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    DeployAutolaunchInfraScript internal script;
    MockRegentRevenueFeeRouter internal feeRouter;

    function setUp() external {
        script = new DeployAutolaunchInfraScript();
        vm.chainId(84_532);
        feeRouter = new MockRegentRevenueFeeRouter(USDC, address(0x8888));
    }

    function testDeployCreatesInfraAndAuthorizesSubjectFactories() external {
        DeployAutolaunchInfraScript.ScriptConfig memory cfg =
            DeployAutolaunchInfraScript.ScriptConfig({
                owner: OWNER, usdc: USDC, protocolFeeRouter: address(feeRouter)
            });

        (
            SubjectRegistry subjectRegistry,
            RevenueShareSplitterV2Deployer revenueShareSplitterDeployer,
            RevenueShareFactory revenueShareFactory,
            RevenueIngressFactory revenueIngressFactory,
            PermissionlessExistingTokenRevenueFactory existingTokenRevenueFactory,
            DeferredAutolaunchFactory deferredAutolaunchFactory,
            RegentLBPStrategyFactory strategyFactory
        ) = script.deploy(cfg);

        assertEq(subjectRegistry.owner(), OWNER);
        assertTrue(address(revenueShareSplitterDeployer) != address(0));
        assertTrue(subjectRegistry.canRegisterSubject(address(revenueShareFactory)));
        assertTrue(subjectRegistry.canRegisterSubject(address(existingTokenRevenueFactory)));
        assertEq(revenueShareFactory.owner(), OWNER);
        assertEq(revenueShareFactory.pendingOwner(), address(0));
        assertEq(revenueIngressFactory.owner(), OWNER);
        assertEq(existingTokenRevenueFactory.owner(), OWNER);
        assertEq(deferredAutolaunchFactory.owner(), OWNER);
        assertEq(strategyFactory.owner(), OWNER);
        assertEq(revenueShareFactory.usdc(), USDC);
        assertEq(revenueIngressFactory.usdc(), USDC);
        assertEq(existingTokenRevenueFactory.usdc(), USDC);
        assertEq(address(revenueShareFactory.subjectRegistry()), address(subjectRegistry));
        assertEq(revenueIngressFactory.subjectRegistry(), address(subjectRegistry));
        assertEq(revenueShareFactory.protocolFeeRouter(), address(feeRouter));
        assertEq(address(existingTokenRevenueFactory.feeRouter()), address(feeRouter));
        assertEq(address(deferredAutolaunchFactory.feeRouter()), address(feeRouter));
        assertTrue(revenueShareFactory.authorizedCreators(address(deferredAutolaunchFactory)));
        assertTrue(revenueIngressFactory.authorizedCreators(address(revenueShareFactory)));
        assertTrue(revenueIngressFactory.authorizedCreators(address(existingTokenRevenueFactory)));
        assertTrue(revenueIngressFactory.authorizedCreators(address(deferredAutolaunchFactory)));
        assertTrue(address(strategyFactory) != address(0));
    }

    function testDeploySupportsAnyConfiguredOwner() external {
        DeployAutolaunchInfraScript.ScriptConfig memory cfg =
            DeployAutolaunchInfraScript.ScriptConfig({
                owner: DEPLOYER, usdc: USDC, protocolFeeRouter: address(feeRouter)
            });

        (
            ,,
            RevenueShareFactory revenueShareFactory,
            RevenueIngressFactory revenueIngressFactory,
            PermissionlessExistingTokenRevenueFactory existingTokenRevenueFactory,
            DeferredAutolaunchFactory deferredAutolaunchFactory,
            RegentLBPStrategyFactory strategyFactory
        ) = script.deploy(cfg);

        assertEq(revenueShareFactory.owner(), DEPLOYER);
        assertEq(revenueShareFactory.pendingOwner(), address(0));
        assertEq(revenueIngressFactory.owner(), DEPLOYER);
        assertEq(existingTokenRevenueFactory.owner(), DEPLOYER);
        assertEq(deferredAutolaunchFactory.owner(), DEPLOYER);
        assertEq(strategyFactory.owner(), DEPLOYER);
    }

    function testLoadConfigFromEnvReadsExplicitOwnerAndUsdc() external {
        vm.setEnv("AUTOLAUNCH_INFRA_OWNER", "0x00000000000000000000000000000000000A11CE");
        vm.setEnv("AUTOLAUNCH_USDC_ADDRESS", vm.toString(USDC));
        vm.setEnv("REGENT_REVENUE_FEE_ROUTER_ADDRESS", vm.toString(address(feeRouter)));

        DeployAutolaunchInfraScript.ScriptConfig memory cfg = script.loadConfigFromEnv();

        assertEq(cfg.owner, OWNER);
        assertEq(cfg.usdc, USDC);
        assertEq(cfg.protocolFeeRouter, address(feeRouter));
    }

    function testDeployFromEnvUsesLoadedConfig() external {
        vm.setEnv("AUTOLAUNCH_INFRA_OWNER", "0x00000000000000000000000000000000000A11CE");
        vm.setEnv("AUTOLAUNCH_USDC_ADDRESS", vm.toString(USDC));
        vm.setEnv("REGENT_REVENUE_FEE_ROUTER_ADDRESS", vm.toString(address(feeRouter)));

        (
            SubjectRegistry subjectRegistry,
            RevenueShareSplitterV2Deployer revenueShareSplitterDeployer,
            RevenueShareFactory revenueShareFactory,
            RevenueIngressFactory revenueIngressFactory,
            PermissionlessExistingTokenRevenueFactory existingTokenRevenueFactory,
            DeferredAutolaunchFactory deferredAutolaunchFactory,
            RegentLBPStrategyFactory strategyFactory
        ) = script.deployFromEnv();

        assertEq(subjectRegistry.owner(), OWNER);
        assertTrue(address(revenueShareSplitterDeployer) != address(0));
        assertTrue(subjectRegistry.canRegisterSubject(address(revenueShareFactory)));
        assertTrue(subjectRegistry.canRegisterSubject(address(existingTokenRevenueFactory)));
        assertEq(revenueShareFactory.owner(), OWNER);
        assertEq(revenueShareFactory.pendingOwner(), address(0));
        assertEq(revenueIngressFactory.owner(), OWNER);
        assertEq(existingTokenRevenueFactory.owner(), OWNER);
        assertEq(deferredAutolaunchFactory.owner(), OWNER);
        assertEq(strategyFactory.owner(), OWNER);
        assertEq(revenueShareFactory.usdc(), USDC);
        assertTrue(address(strategyFactory) != address(0));
    }

    function testRunUsesSingleBroadcastPath() external {
        vm.setEnv("AUTOLAUNCH_INFRA_OWNER", "0x00000000000000000000000000000000000A11CE");
        vm.setEnv("AUTOLAUNCH_USDC_ADDRESS", vm.toString(USDC));
        vm.setEnv("REGENT_REVENUE_FEE_ROUTER_ADDRESS", vm.toString(address(feeRouter)));

        script.run();
    }

    function testValidateConfigRejectsWrongBaseSepoliaUsdc() external {
        DeployAutolaunchInfraScript.ScriptConfig memory cfg =
            DeployAutolaunchInfraScript.ScriptConfig({
                owner: OWNER, usdc: address(0xC0FFEE), protocolFeeRouter: address(feeRouter)
            });

        vm.expectRevert("USDC_NOT_CANONICAL");
        script.validateConfig(cfg);
    }

    function testLoadConfigFromEnvRejectsNonBaseChain() external {
        vm.chainId(1);
        vm.setEnv("AUTOLAUNCH_INFRA_OWNER", "0x00000000000000000000000000000000000A11CE");
        vm.setEnv("AUTOLAUNCH_USDC_ADDRESS", vm.toString(USDC));
        vm.setEnv("REGENT_REVENUE_FEE_ROUTER_ADDRESS", vm.toString(address(feeRouter)));

        vm.expectRevert("BASE_CHAIN_ONLY");
        script.loadConfigFromEnv();
    }
}
