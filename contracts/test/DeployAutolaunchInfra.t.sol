// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeployAutolaunchInfraScript} from "scripts/DeployAutolaunchInfra.s.sol";
import {RegentLBPStrategyFactory} from "src/RegentLBPStrategyFactory.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";

contract DeployAutolaunchInfraScriptTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant DEPLOYER = address(0xBEEF);
    address internal constant USDC = address(0xC0FFEE);

    DeployAutolaunchInfraScript internal script;

    function setUp() external {
        script = new DeployAutolaunchInfraScript();
        vm.chainId(84532);
    }

    function testDeployCreatesInfraAndTransfersRegistryOwnership() external {
        DeployAutolaunchInfraScript.ScriptConfig memory cfg =
            DeployAutolaunchInfraScript.ScriptConfig({owner: OWNER, usdc: USDC});

        (
            SubjectRegistry subjectRegistry,
            RevenueShareFactory revenueShareFactory,
            RevenueIngressFactory revenueIngressFactory,
            RegentLBPStrategyFactory strategyFactory
        ) = script.deploy(cfg);

        assertEq(subjectRegistry.owner(), address(revenueShareFactory));
        assertEq(revenueShareFactory.owner(), OWNER);
        assertEq(revenueIngressFactory.owner(), OWNER);
        assertEq(revenueShareFactory.usdc(), USDC);
        assertEq(revenueIngressFactory.usdc(), USDC);
        assertEq(address(revenueShareFactory.subjectRegistry()), address(subjectRegistry));
        assertEq(revenueIngressFactory.subjectRegistry(), address(subjectRegistry));
        assertTrue(address(strategyFactory) != address(0));
    }

    function testDeploySupportsAnyConfiguredOwner() external {
        DeployAutolaunchInfraScript.ScriptConfig memory cfg =
            DeployAutolaunchInfraScript.ScriptConfig({owner: DEPLOYER, usdc: USDC});

        (, RevenueShareFactory revenueShareFactory, RevenueIngressFactory revenueIngressFactory,) =
            script.deploy(cfg);

        assertEq(revenueShareFactory.owner(), DEPLOYER);
        assertEq(revenueIngressFactory.owner(), DEPLOYER);
    }

    function testLoadConfigFromEnvReadsExplicitOwnerAndUsdc() external {
        vm.setEnv("AUTOLAUNCH_INFRA_OWNER", "0x00000000000000000000000000000000000A11CE");
        vm.setEnv("AUTOLAUNCH_USDC_ADDRESS", "0x0000000000000000000000000000000000C0FFEE");

        DeployAutolaunchInfraScript.ScriptConfig memory cfg = script.loadConfigFromEnv();

        assertEq(cfg.owner, OWNER);
        assertEq(cfg.usdc, USDC);
    }

    function testDeployFromEnvUsesLoadedConfig() external {
        vm.setEnv("AUTOLAUNCH_INFRA_OWNER", "0x00000000000000000000000000000000000A11CE");
        vm.setEnv("AUTOLAUNCH_USDC_ADDRESS", "0x0000000000000000000000000000000000C0FFEE");

        (
            SubjectRegistry subjectRegistry,
            RevenueShareFactory revenueShareFactory,
            RevenueIngressFactory revenueIngressFactory,
            RegentLBPStrategyFactory strategyFactory
        ) = script.deployFromEnv();

        assertEq(subjectRegistry.owner(), address(revenueShareFactory));
        assertEq(revenueShareFactory.owner(), OWNER);
        assertEq(revenueIngressFactory.owner(), OWNER);
        assertEq(revenueShareFactory.usdc(), USDC);
        assertTrue(address(strategyFactory) != address(0));
    }

    function testRunUsesSingleBroadcastPath() external {
        vm.setEnv("AUTOLAUNCH_INFRA_OWNER", "0x00000000000000000000000000000000000A11CE");
        vm.setEnv("AUTOLAUNCH_USDC_ADDRESS", "0x0000000000000000000000000000000000C0FFEE");

        script.run();
    }

    function testLoadConfigFromEnvRejectsNonBaseFamilyChain() external {
        vm.chainId(1);
        vm.setEnv("AUTOLAUNCH_INFRA_OWNER", "0x00000000000000000000000000000000000A11CE");
        vm.setEnv("AUTOLAUNCH_USDC_ADDRESS", "0x0000000000000000000000000000000000C0FFEE");

        vm.expectRevert("BASE_FAMILY_ONLY");
        script.loadConfigFromEnv();
    }
}
