// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {RevenueShareSplitterV2Deployer} from "src/revenue/RevenueShareSplitterV2Deployer.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {
    PermissionlessExistingTokenRevenueFactory
} from "src/revenue/PermissionlessExistingTokenRevenueFactory.sol";
import {DeferredAutolaunchFactory} from "src/revenue/DeferredAutolaunchFactory.sol";
import {IRegentRevenueFeeRouter} from "src/revenue/interfaces/IRegentRevenueFeeRouter.sol";
import {RegentLBPStrategyFactory} from "src/RegentLBPStrategyFactory.sol";
import {BaseUsdc} from "src/libraries/BaseUsdc.sol";

contract DeployAutolaunchInfraScript is Script {
    struct ScriptConfig {
        address owner;
        address usdc;
        address protocolFeeRouter;
    }

    function deployFromEnv()
        external
        returns (
            SubjectRegistry subjectRegistry,
            RevenueShareSplitterV2Deployer revenueShareSplitterDeployer,
            RevenueShareFactory revenueShareFactory,
            RevenueIngressFactory revenueIngressFactory,
            PermissionlessExistingTokenRevenueFactory existingTokenRevenueFactory,
            DeferredAutolaunchFactory deferredAutolaunchFactory,
            RegentLBPStrategyFactory strategyFactory
        )
    {
        ScriptConfig memory cfg = loadConfigFromEnv();

        return deploy(cfg);
    }

    function deploy(ScriptConfig memory cfg)
        public
        returns (
            SubjectRegistry subjectRegistry,
            RevenueShareSplitterV2Deployer revenueShareSplitterDeployer,
            RevenueShareFactory revenueShareFactory,
            RevenueIngressFactory revenueIngressFactory,
            PermissionlessExistingTokenRevenueFactory existingTokenRevenueFactory,
            DeferredAutolaunchFactory deferredAutolaunchFactory,
            RegentLBPStrategyFactory strategyFactory
        )
    {
        validateConfig(cfg);

        vm.startBroadcast(cfg.owner);
        subjectRegistry = new SubjectRegistry(cfg.owner);
        revenueShareSplitterDeployer = new RevenueShareSplitterV2Deployer();
        revenueShareFactory = new RevenueShareFactory(
            cfg.owner,
            cfg.usdc,
            subjectRegistry,
            cfg.protocolFeeRouter,
            address(revenueShareSplitterDeployer)
        );
        revenueIngressFactory =
            new RevenueIngressFactory(cfg.usdc, address(subjectRegistry), cfg.owner);
        existingTokenRevenueFactory = new PermissionlessExistingTokenRevenueFactory(
            cfg.owner,
            cfg.usdc,
            address(revenueIngressFactory),
            subjectRegistry,
            IRegentRevenueFeeRouter(cfg.protocolFeeRouter)
        );
        deferredAutolaunchFactory = new DeferredAutolaunchFactory(
            cfg.owner,
            revenueShareFactory,
            revenueIngressFactory,
            IRegentRevenueFeeRouter(cfg.protocolFeeRouter)
        );
        strategyFactory = new RegentLBPStrategyFactory(cfg.owner);
        subjectRegistry.setAuthorizedRegistrar(address(revenueShareFactory), true);
        subjectRegistry.setAuthorizedRegistrar(address(existingTokenRevenueFactory), true);
        revenueIngressFactory.setAuthorizedCreator(address(revenueShareFactory), true);
        revenueIngressFactory.setAuthorizedCreator(address(existingTokenRevenueFactory), true);
        revenueIngressFactory.setAuthorizedCreator(address(deferredAutolaunchFactory), true);
        revenueShareFactory.setAuthorizedCreator(address(deferredAutolaunchFactory), true);
        vm.stopBroadcast();
    }

    function validateConfig(ScriptConfig memory cfg) public view {
        require(cfg.owner != address(0), "OWNER_ZERO");
        require(cfg.usdc != address(0), "USDC_ZERO");
        require(cfg.protocolFeeRouter != address(0), "FEE_ROUTER_ZERO");
        BaseUsdc.requireCanonical(cfg.usdc);
    }

    function loadConfigFromEnv() public view returns (ScriptConfig memory cfg) {
        cfg.owner = vm.envAddress("AUTOLAUNCH_INFRA_OWNER");
        cfg.usdc = vm.envAddress("AUTOLAUNCH_USDC_ADDRESS");
        cfg.protocolFeeRouter = vm.envAddress("REGENT_REVENUE_FEE_ROUTER_ADDRESS");
        validateConfig(cfg);
    }

    function run() external {
        ScriptConfig memory cfg = loadConfigFromEnv();

        (
            SubjectRegistry subjectRegistry,
            RevenueShareSplitterV2Deployer revenueShareSplitterDeployer,
            RevenueShareFactory revenueShareFactory,
            RevenueIngressFactory revenueIngressFactory,
            PermissionlessExistingTokenRevenueFactory existingTokenRevenueFactory,
            DeferredAutolaunchFactory deferredAutolaunchFactory,
            RegentLBPStrategyFactory strategyFactory
        ) = deploy(cfg);

        console2.log(
            string.concat(
                "AUTOLAUNCH_INFRA_RESULT_JSON:{\"subjectRegistryAddress\":\"",
                vm.toString(address(subjectRegistry)),
                "\",\"revenueShareSplitterDeployerAddress\":\"",
                vm.toString(address(revenueShareSplitterDeployer)),
                "\",\"revenueShareFactoryAddress\":\"",
                vm.toString(address(revenueShareFactory)),
                "\",\"revenueIngressFactoryAddress\":\"",
                vm.toString(address(revenueIngressFactory)),
                "\",\"existingTokenRevenueFactoryAddress\":\"",
                vm.toString(address(existingTokenRevenueFactory)),
                "\",\"deferredAutolaunchFactoryAddress\":\"",
                vm.toString(address(deferredAutolaunchFactory)),
                "\",\"strategyFactoryAddress\":\"",
                vm.toString(address(strategyFactory)),
                "\",\"usdcAddress\":\"",
                vm.toString(cfg.usdc),
                "\",\"protocolFeeRouterAddress\":\"",
                vm.toString(cfg.protocolFeeRouter),
                "\",\"revenueShareFactoryOwner\":\"",
                vm.toString(revenueShareFactory.owner()),
                "\",\"revenueShareFactoryPendingOwner\":\"",
                vm.toString(revenueShareFactory.pendingOwner()),
                "\",\"revenueIngressFactoryOwner\":\"",
                vm.toString(revenueIngressFactory.owner()),
                "\",\"strategyFactoryOwner\":\"",
                vm.toString(strategyFactory.owner()),
                "\",\"owner\":\"",
                vm.toString(cfg.owner),
                "\"}"
            )
        );
    }
}
