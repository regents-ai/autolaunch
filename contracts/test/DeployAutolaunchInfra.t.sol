// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeployAutolaunchInfraScript} from "scripts/DeployAutolaunchInfra.s.sol";
import {RegentLBPStrategyFactory} from "src/RegentLBPStrategyFactory.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {RevenueShareSplitterV2Deployer} from "src/revenue/RevenueShareSplitterV2Deployer.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {PermissionlessExistingTokenRevenueFactory} from "src/revenue/PermissionlessExistingTokenRevenueFactory.sol";
import {DeferredAutolaunchFactory} from "src/revenue/DeferredAutolaunchFactory.sol";
import {RegentStakingRevenueRouter} from "src/revenue/RegentStakingRevenueRouter.sol";
import {RegentRevenueStaking} from "src/revenue/RegentRevenueStaking.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";

contract DeployAutolaunchInfraScriptTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant DEPLOYER = address(0xBEEF);
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    DeployAutolaunchInfraScript internal script;
    MintableERC20Mock internal regent;
    RegentRevenueStaking internal staking;

    function setUp() external {
        script = new DeployAutolaunchInfraScript();
        vm.chainId(8453);
        regent = new MintableERC20Mock("REGENT", "REGENT");
        staking = new RegentRevenueStaking(address(regent), USDC, address(0xCAFE), 1e29, OWNER);
    }

    function testDeployCreatesInfraAndAuthorizesSubjectFactories() external {
        DeployAutolaunchInfraScript.ScriptConfig memory cfg = DeployAutolaunchInfraScript.ScriptConfig({
            owner: OWNER, usdc: USDC, regentRevenueStaking: address(staking)
        });

        (
            SubjectRegistry subjectRegistry,
            RevenueShareSplitterV2Deployer revenueShareSplitterDeployer,
            RevenueShareFactory revenueShareFactory,
            RevenueIngressFactory revenueIngressFactory,
            PermissionlessExistingTokenRevenueFactory existingTokenRevenueFactory,
            DeferredAutolaunchFactory deferredAutolaunchFactory,
            RegentStakingRevenueRouter stakingRevenueRouter,
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
        assertEq(revenueShareFactory.stakingRevenueRouter(), address(stakingRevenueRouter));
        assertEq(address(existingTokenRevenueFactory.stakingRevenueRouter()), address(stakingRevenueRouter));
        assertEq(address(deferredAutolaunchFactory.stakingRevenueRouter()), address(stakingRevenueRouter));
        assertEq(stakingRevenueRouter.regentRevenueStaking(), address(staking));
        assertTrue(revenueShareFactory.authorizedCreators(address(deferredAutolaunchFactory)));
        assertTrue(revenueIngressFactory.authorizedCreators(address(revenueShareFactory)));
        assertTrue(revenueIngressFactory.authorizedCreators(address(existingTokenRevenueFactory)));
        assertTrue(revenueIngressFactory.authorizedCreators(address(deferredAutolaunchFactory)));
        assertTrue(address(strategyFactory) != address(0));
    }

    function testDeploySupportsAnyConfiguredOwner() external {
        DeployAutolaunchInfraScript.ScriptConfig memory cfg = DeployAutolaunchInfraScript.ScriptConfig({
            owner: DEPLOYER, usdc: USDC, regentRevenueStaking: address(staking)
        });

        (
            ,,
            RevenueShareFactory revenueShareFactory,
            RevenueIngressFactory revenueIngressFactory,
            PermissionlessExistingTokenRevenueFactory existingTokenRevenueFactory,
            DeferredAutolaunchFactory deferredAutolaunchFactory,,
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
        vm.setEnv("REGENT_REVENUE_STAKING_ADDRESS", vm.toString(address(staking)));

        DeployAutolaunchInfraScript.ScriptConfig memory cfg = script.loadConfigFromEnv();

        assertEq(cfg.owner, OWNER);
        assertEq(cfg.usdc, USDC);
        assertEq(cfg.regentRevenueStaking, address(staking));
    }

    function testDeployFromEnvUsesLoadedConfig() external {
        vm.setEnv("AUTOLAUNCH_INFRA_OWNER", "0x00000000000000000000000000000000000A11CE");
        vm.setEnv("AUTOLAUNCH_USDC_ADDRESS", vm.toString(USDC));
        vm.setEnv("REGENT_REVENUE_STAKING_ADDRESS", vm.toString(address(staking)));

        (
            SubjectRegistry subjectRegistry,
            RevenueShareSplitterV2Deployer revenueShareSplitterDeployer,
            RevenueShareFactory revenueShareFactory,
            RevenueIngressFactory revenueIngressFactory,
            PermissionlessExistingTokenRevenueFactory existingTokenRevenueFactory,
            DeferredAutolaunchFactory deferredAutolaunchFactory,,
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
        vm.setEnv("REGENT_REVENUE_STAKING_ADDRESS", vm.toString(address(staking)));

        script.run();
    }

    function testValidateConfigRejectsWrongBaseMainnetUsdc() external {
        DeployAutolaunchInfraScript.ScriptConfig memory cfg = DeployAutolaunchInfraScript.ScriptConfig({
            owner: OWNER, usdc: BASE_SEPOLIA_USDC, regentRevenueStaking: address(staking)
        });

        vm.expectRevert("USDC_NOT_CANONICAL");
        script.validateConfig(cfg);
    }

    function testLoadConfigFromEnvRejectsNonMainnetChain() external {
        vm.chainId(84_532);
        vm.setEnv("AUTOLAUNCH_INFRA_OWNER", "0x00000000000000000000000000000000000A11CE");
        vm.setEnv("AUTOLAUNCH_USDC_ADDRESS", vm.toString(USDC));
        vm.setEnv("REGENT_REVENUE_STAKING_ADDRESS", vm.toString(address(staking)));

        vm.expectRevert("BASE_MAINNET_ONLY");
        script.loadConfigFromEnv();
    }
}
