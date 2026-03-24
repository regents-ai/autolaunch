// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";

contract DeployAutolaunchInfraScript is Script {
    struct ScriptConfig {
        address owner;
        address usdc;
    }

    function deployFromEnv()
        external
        returns (SubjectRegistry subjectRegistry, RevenueShareFactory revenueShareFactory)
    {
        ScriptConfig memory cfg = _loadConfig();

        vm.startBroadcast();
        subjectRegistry = new SubjectRegistry(cfg.owner);
        revenueShareFactory = new RevenueShareFactory(cfg.owner, cfg.usdc, subjectRegistry);
        subjectRegistry.transferOwnership(address(revenueShareFactory));
        vm.stopBroadcast();

        console2.log(
            string.concat(
                "AUTOLAUNCH_INFRA_RESULT_JSON:{\"subjectRegistryAddress\":\"",
                vm.toString(address(subjectRegistry)),
                "\",\"revenueShareFactoryAddress\":\"",
                vm.toString(address(revenueShareFactory)),
                "\",\"usdcAddress\":\"",
                vm.toString(cfg.usdc),
                "\",\"owner\":\"",
                vm.toString(cfg.owner),
                "\"}"
            )
        );
    }

    function _loadConfig() internal view returns (ScriptConfig memory cfg) {
        cfg.owner = _envAddressOr("AUTOLAUNCH_INFRA_OWNER", _envAddressOr("DEPLOYER", address(0)));
        require(cfg.owner != address(0), "OWNER_ZERO");

        cfg.usdc = vm.envAddress("ETHEREUM_USDC_ADDRESS");
        require(cfg.usdc != address(0), "USDC_ZERO");
    }

    function _envAddressOr(string memory key, address fallbackValue)
        internal
        view
        returns (address)
    {
        try vm.envAddress(key) returns (address value) {
            return value;
        } catch {
            return fallbackValue;
        }
    }
}
