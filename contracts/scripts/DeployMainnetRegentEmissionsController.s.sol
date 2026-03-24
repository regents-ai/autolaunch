// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {
    MainnetRegentEmissionsController,
    ISubjectRegistryMinimal
} from "src/revenue/MainnetRegentEmissionsController.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";

contract DeployMainnetRegentEmissionsControllerScript is Script {
    struct ScriptConfig {
        address regentToken;
        address usdcToken;
        address owner;
        address usdcTreasury;
        SubjectRegistry subjectRegistry;
        uint256 epochGenesisTs;
        uint256 epochLength;
        uint256 localChainId;
    }

    uint256 internal constant DEFAULT_ETHEREUM_MAINNET_CHAIN_ID = 1;
    uint256 internal constant DEFAULT_EPOCH_LENGTH = 3 days;

    function deployFromEnv() external returns (MainnetRegentEmissionsController controller) {
        return _deployFromEnv();
    }

    function _deployFromEnv() internal returns (MainnetRegentEmissionsController controller) {
        ScriptConfig memory cfg = _loadConfig();

        vm.startBroadcast();
        controller = new MainnetRegentEmissionsController(
            cfg.regentToken,
            cfg.usdcToken,
            ISubjectRegistryMinimal(address(cfg.subjectRegistry)),
            cfg.usdcTreasury,
            cfg.epochGenesisTs,
            cfg.epochLength,
            cfg.localChainId,
            cfg.owner
        );
        vm.stopBroadcast();

        string memory resultJson = string.concat(
            "MAINNET_REGENT_EMISSIONS_RESULT_JSON:{\"mainnetRegentEmissionsControllerAddress\":\"",
            vm.toString(address(controller)),
            "\",\"regentTokenAddress\":\"",
            vm.toString(cfg.regentToken),
            "\",\"usdcTokenAddress\":\"",
            vm.toString(cfg.usdcToken),
            "\",\"subjectRegistryAddress\":\"",
            vm.toString(address(cfg.subjectRegistry)),
            "\",\"usdcTreasury\":\"",
            vm.toString(cfg.usdcTreasury),
            "\",\"owner\":\"",
            vm.toString(cfg.owner),
            "\",\"epochGenesisTs\":",
            vm.toString(cfg.epochGenesisTs),
            ",\"epochLength\":",
            vm.toString(cfg.epochLength),
            ",\"localChainId\":",
            vm.toString(cfg.localChainId),
            "}"
        );
        console2.log(resultJson);
    }

    function _loadConfig() internal view returns (ScriptConfig memory cfg) {
        cfg.regentToken = vm.envAddress("REGENT_TOKEN_ADDRESS");
        require(cfg.regentToken != address(0), "REGENT_TOKEN_ZERO");

        cfg.usdcToken = vm.envAddress("ETH_MAINNET_USDC_ADDRESS");
        require(cfg.usdcToken != address(0), "USDC_TOKEN_ZERO");

        cfg.subjectRegistry = SubjectRegistry(vm.envAddress("SUBJECT_REGISTRY_ADDRESS"));
        require(address(cfg.subjectRegistry) != address(0), "SUBJECT_REGISTRY_ZERO");

        cfg.usdcTreasury = vm.envAddress("REGENT_USDC_TREASURY");
        require(cfg.usdcTreasury != address(0), "USDC_TREASURY_ZERO");

        cfg.owner = _envAddressOr(
            "REGENT_EMISSIONS_OWNER",
            _envAddressOr("AUTOLAUNCH_RECOVERY_SAFE_ADDRESS", _envAddressOr("DEPLOYER", address(0)))
        );
        require(cfg.owner != address(0), "OWNER_ZERO");

        cfg.epochGenesisTs = vm.envOr(
            "REVENUE_EPOCH_GENESIS_TS", vm.envOr("AUTOLAUNCH_EPOCH_GENESIS_TS", block.timestamp)
        );
        require(cfg.epochGenesisTs > 0, "EPOCH_GENESIS_ZERO");

        cfg.epochLength = vm.envOr("REVENUE_EPOCH_LENGTH", DEFAULT_EPOCH_LENGTH);
        require(cfg.epochLength > 0, "EPOCH_LENGTH_ZERO");

        cfg.localChainId = vm.envOr("REGENT_EMISSIONS_CHAIN_ID", DEFAULT_ETHEREUM_MAINNET_CHAIN_ID);
        require(cfg.localChainId == DEFAULT_ETHEREUM_MAINNET_CHAIN_ID, "MAINNET_ONLY");
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
