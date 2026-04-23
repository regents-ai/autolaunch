// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {TestnetMintableERC20} from "src/mocks/TestnetMintableERC20.sol";

contract DeployTestnetMintableERC20Script is Script {
    struct ScriptConfig {
        string name;
        string symbol;
        uint8 decimals;
        address owner;
        address initialHolder;
        uint256 initialSupply;
    }

    function deployFromEnv() external returns (TestnetMintableERC20 token) {
        return deploy(loadConfigFromEnv());
    }

    function deploy(ScriptConfig memory cfg) public returns (TestnetMintableERC20 token) {
        vm.startBroadcast();
        token = new TestnetMintableERC20(
            cfg.name, cfg.symbol, cfg.decimals, cfg.owner, cfg.initialHolder, cfg.initialSupply
        );
        vm.stopBroadcast();
    }

    function loadConfigFromEnv() public view returns (ScriptConfig memory cfg) {
        require(block.chainid == 84532, "BASE_SEPOLIA_ONLY");

        cfg.name = vm.envString("TESTNET_TOKEN_NAME");
        require(bytes(cfg.name).length != 0, "NAME_REQUIRED");

        cfg.symbol = vm.envString("TESTNET_TOKEN_SYMBOL");
        require(bytes(cfg.symbol).length != 0, "SYMBOL_REQUIRED");

        cfg.decimals = uint8(vm.envUint("TESTNET_TOKEN_DECIMALS"));
        cfg.owner = vm.envAddress("TESTNET_TOKEN_OWNER");
        require(cfg.owner != address(0), "OWNER_ZERO");

        cfg.initialHolder = vm.envAddress("TESTNET_TOKEN_INITIAL_HOLDER");
        require(cfg.initialHolder != address(0), "INITIAL_HOLDER_ZERO");

        cfg.initialSupply = vm.envUint("TESTNET_TOKEN_INITIAL_SUPPLY");
        require(cfg.initialSupply != 0, "INITIAL_SUPPLY_ZERO");
    }

    function run() external {
        ScriptConfig memory cfg = loadConfigFromEnv();
        TestnetMintableERC20 token = deploy(cfg);

        console2.log(
            string.concat(
                "TESTNET_TOKEN_RESULT_JSON:{\"contractAddress\":\"",
                vm.toString(address(token)),
                "\",\"name\":\"",
                cfg.name,
                "\",\"symbol\":\"",
                cfg.symbol,
                "\",\"decimals\":",
                vm.toString(uint256(cfg.decimals)),
                ",\"owner\":\"",
                vm.toString(cfg.owner),
                "\",\"initialHolder\":\"",
                vm.toString(cfg.initialHolder),
                "\",\"initialSupply\":",
                vm.toString(cfg.initialSupply),
                ",\"chainId\":",
                vm.toString(block.chainid),
                "}"
            )
        );
    }
}
