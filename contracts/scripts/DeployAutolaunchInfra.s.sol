// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RegentLBPStrategyFactory} from "src/RegentLBPStrategyFactory.sol";

contract DeployAutolaunchInfraScript is Script {
    uint256 internal constant BASE_MAINNET_CHAIN_ID = 8453;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    struct ScriptConfig {
        address owner;
        address usdc;
    }

    function deployFromEnv()
        external
        returns (
            SubjectRegistry subjectRegistry,
            RevenueShareFactory revenueShareFactory,
            RevenueIngressFactory revenueIngressFactory,
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
            RevenueShareFactory revenueShareFactory,
            RevenueIngressFactory revenueIngressFactory,
            RegentLBPStrategyFactory strategyFactory
        )
    {
        address broadcaster = tx.origin;
        require(broadcaster != address(0), "BROADCASTER_ZERO");

        vm.startBroadcast();
        subjectRegistry = new SubjectRegistry(broadcaster);
        revenueShareFactory = new RevenueShareFactory(cfg.owner, cfg.usdc, subjectRegistry);
        revenueIngressFactory =
            new RevenueIngressFactory(cfg.usdc, address(subjectRegistry), cfg.owner);
        strategyFactory = new RegentLBPStrategyFactory();
        subjectRegistry.transferOwnership(address(revenueShareFactory));
        revenueShareFactory.acceptSubjectRegistryOwnership();
        vm.stopBroadcast();
    }

    function loadConfigFromEnv() public view returns (ScriptConfig memory cfg) {
        require(
            block.chainid == BASE_SEPOLIA_CHAIN_ID || block.chainid == BASE_MAINNET_CHAIN_ID,
            "BASE_FAMILY_ONLY"
        );

        cfg.owner = vm.envAddress("AUTOLAUNCH_INFRA_OWNER");
        require(cfg.owner != address(0), "OWNER_ZERO");

        cfg.usdc = vm.envAddress("AUTOLAUNCH_USDC_ADDRESS");
        require(cfg.usdc != address(0), "USDC_ZERO");
    }

    function run() external {
        ScriptConfig memory cfg = loadConfigFromEnv();

        (
            SubjectRegistry subjectRegistry,
            RevenueShareFactory revenueShareFactory,
            RevenueIngressFactory revenueIngressFactory,
            RegentLBPStrategyFactory strategyFactory
        ) = deploy(cfg);

        console2.log(
            string.concat(
                "AUTOLAUNCH_INFRA_RESULT_JSON:{\"subjectRegistryAddress\":\"",
                vm.toString(address(subjectRegistry)),
                "\",\"revenueShareFactoryAddress\":\"",
                vm.toString(address(revenueShareFactory)),
                "\",\"revenueIngressFactoryAddress\":\"",
                vm.toString(address(revenueIngressFactory)),
                "\",\"strategyFactoryAddress\":\"",
                vm.toString(address(strategyFactory)),
                "\",\"usdcAddress\":\"",
                vm.toString(cfg.usdc),
                "\",\"owner\":\"",
                vm.toString(cfg.owner),
                "\"}"
            )
        );
    }
}
