// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeployTestnetMintableERC20Script} from "scripts/DeployTestnetMintableERC20.s.sol";
import {TestnetMintableERC20} from "src/mocks/TestnetMintableERC20.sol";

contract DeployTestnetMintableERC20ScriptTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant HOLDER = address(0xBEEF);
    uint256 internal constant INITIAL_SUPPLY = 100_000_000_000e18;

    DeployTestnetMintableERC20Script internal script;

    function setUp() external {
        script = new DeployTestnetMintableERC20Script();
        vm.chainId(84532);
    }

    function testDeployCreatesMintableTokenWithInitialSupply() external {
        DeployTestnetMintableERC20Script.ScriptConfig memory cfg = DeployTestnetMintableERC20Script
            .ScriptConfig({
            name: "Regent Test",
            symbol: "tREGENT",
            decimals: 18,
            owner: OWNER,
            initialHolder: HOLDER,
            initialSupply: INITIAL_SUPPLY
        });

        TestnetMintableERC20 token = script.deploy(cfg);

        assertEq(token.name(), "Regent Test");
        assertEq(token.symbol(), "tREGENT");
        assertEq(token.decimals(), 18);
        assertEq(token.owner(), OWNER);
        assertEq(token.balanceOf(HOLDER), INITIAL_SUPPLY);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function testOwnerCanMintAfterDeploy() external {
        DeployTestnetMintableERC20Script.ScriptConfig memory cfg = DeployTestnetMintableERC20Script
            .ScriptConfig({
            name: "Regent Test",
            symbol: "tREGENT",
            decimals: 18,
            owner: OWNER,
            initialHolder: HOLDER,
            initialSupply: INITIAL_SUPPLY
        });

        TestnetMintableERC20 token = script.deploy(cfg);

        vm.prank(OWNER);
        token.mint(address(0xCAFE), 5e18);

        assertEq(token.balanceOf(address(0xCAFE)), 5e18);
        assertEq(token.totalSupply(), INITIAL_SUPPLY + 5e18);
    }

    function testLoadConfigFromEnvReadsExplicitValues() external {
        vm.setEnv("TESTNET_TOKEN_NAME", "Regent Test");
        vm.setEnv("TESTNET_TOKEN_SYMBOL", "tREGENT");
        vm.setEnv("TESTNET_TOKEN_DECIMALS", "18");
        vm.setEnv("TESTNET_TOKEN_OWNER", "0x00000000000000000000000000000000000A11CE");
        vm.setEnv("TESTNET_TOKEN_INITIAL_HOLDER", "0x000000000000000000000000000000000000BEEF");
        vm.setEnv("TESTNET_TOKEN_INITIAL_SUPPLY", "100000000000000000000000000000");

        DeployTestnetMintableERC20Script.ScriptConfig memory cfg = script.loadConfigFromEnv();

        assertEq(cfg.name, "Regent Test");
        assertEq(cfg.symbol, "tREGENT");
        assertEq(cfg.decimals, 18);
        assertEq(cfg.owner, OWNER);
        assertEq(cfg.initialHolder, HOLDER);
        assertEq(cfg.initialSupply, INITIAL_SUPPLY);
    }

    function testLoadConfigFromEnvRejectsWrongChain() external {
        vm.chainId(8453);
        vm.setEnv("TESTNET_TOKEN_NAME", "Regent Test");
        vm.setEnv("TESTNET_TOKEN_SYMBOL", "tREGENT");
        vm.setEnv("TESTNET_TOKEN_DECIMALS", "18");
        vm.setEnv("TESTNET_TOKEN_OWNER", "0x00000000000000000000000000000000000A11CE");
        vm.setEnv("TESTNET_TOKEN_INITIAL_HOLDER", "0x000000000000000000000000000000000000BEEF");
        vm.setEnv("TESTNET_TOKEN_INITIAL_SUPPLY", "100000000000000000000000000000");

        vm.expectRevert("BASE_SEPOLIA_ONLY");
        script.loadConfigFromEnv();
    }
}
