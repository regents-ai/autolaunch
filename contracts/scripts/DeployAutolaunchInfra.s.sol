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
import {IRegentStakingRevenueRouter} from "src/revenue/interfaces/IRegentStakingRevenueRouter.sol";
import {RegentStakingRevenueRouter} from "src/revenue/RegentStakingRevenueRouter.sol";
import {RegentLBPStrategyFactory} from "src/RegentLBPStrategyFactory.sol";
import {BaseUsdc} from "src/libraries/BaseUsdc.sol";

contract DeployAutolaunchInfraScript is Script {
    uint256 internal constant BASE_MAINNET_CHAIN_ID = 8453;

    struct ScriptConfig {
        address owner;
        address revenueUsdcToken;
        address regentRevenueStaking;
        address tokenFactory;
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
            RegentStakingRevenueRouter stakingRevenueRouter,
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
            RegentStakingRevenueRouter stakingRevenueRouter,
            RegentLBPStrategyFactory strategyFactory
        )
    {
        validateConfig(cfg);

        vm.startBroadcast(cfg.owner);
        subjectRegistry = new SubjectRegistry(cfg.owner);
        stakingRevenueRouter = new RegentStakingRevenueRouter(
            cfg.owner, cfg.revenueUsdcToken, address(subjectRegistry), cfg.regentRevenueStaking
        );
        revenueShareSplitterDeployer = new RevenueShareSplitterV2Deployer();
        revenueShareFactory = new RevenueShareFactory(
            cfg.owner,
            cfg.revenueUsdcToken,
            subjectRegistry,
            address(stakingRevenueRouter),
            address(revenueShareSplitterDeployer)
        );
        revenueIngressFactory =
            new RevenueIngressFactory(cfg.revenueUsdcToken, address(subjectRegistry), cfg.owner);
        existingTokenRevenueFactory = new PermissionlessExistingTokenRevenueFactory(
            cfg.owner,
            cfg.revenueUsdcToken,
            address(revenueIngressFactory),
            subjectRegistry,
            IRegentStakingRevenueRouter(address(stakingRevenueRouter))
        );
        deferredAutolaunchFactory = new DeferredAutolaunchFactory(
            cfg.owner,
            revenueShareFactory,
            revenueIngressFactory,
            IRegentStakingRevenueRouter(address(stakingRevenueRouter)),
            cfg.tokenFactory
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
        require(cfg.revenueUsdcToken != address(0), "REVENUE_USDC_ZERO");
        require(cfg.regentRevenueStaking != address(0), "REGENT_STAKING_ZERO");
        require(cfg.tokenFactory != address(0), "TOKEN_FACTORY_ZERO");
        require(cfg.tokenFactory.code.length != 0, "TOKEN_FACTORY_NOT_DEPLOYED");
        require(block.chainid == BASE_MAINNET_CHAIN_ID, "BASE_MAINNET_ONLY");
        BaseUsdc.requireCanonical(cfg.revenueUsdcToken);
    }

    function loadConfigFromEnv() public view returns (ScriptConfig memory cfg) {
        cfg.owner = vm.envAddress("AUTOLAUNCH_INFRA_OWNER");
        cfg.revenueUsdcToken = vm.envAddress("AUTOLAUNCH_REVENUE_USDC_ADDRESS");
        cfg.regentRevenueStaking = vm.envAddress("REGENT_REVENUE_STAKING_ADDRESS");
        cfg.tokenFactory = vm.envAddress("AUTOLAUNCH_TOKEN_FACTORY_ADDRESS");
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
            RegentStakingRevenueRouter stakingRevenueRouter,
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
                "\",\"stakingRevenueRouterAddress\":\"",
                vm.toString(address(stakingRevenueRouter)),
                "\",\"strategyFactoryAddress\":\"",
                vm.toString(address(strategyFactory)),
                "\",\"revenueUsdcTokenAddress\":\"",
                vm.toString(cfg.revenueUsdcToken),
                "\",\"revenueTokenSymbol\":\"USDC\",\"revenueTokenDecimals\":6",
                ",\"regentRevenueStakingAddress\":\"",
                vm.toString(cfg.regentRevenueStaking),
                "\",\"trustedTokenFactoryAddress\":\"",
                vm.toString(cfg.tokenFactory),
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
