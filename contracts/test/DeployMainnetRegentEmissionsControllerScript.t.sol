// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {
    DeployMainnetRegentEmissionsControllerScript
} from "scripts/DeployMainnetRegentEmissionsController.s.sol";
import {MainnetRegentEmissionsController} from "src/revenue/MainnetRegentEmissionsController.sol";
import {SimpleMintableERC20} from "src/SimpleMintableERC20.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";

contract DeployMainnetRegentEmissionsControllerScriptTest is Test {
    address internal constant USDC_TREASURY = address(0xCAFE);
    address internal constant OWNER = address(0xBEEF);
    uint256 internal constant GENESIS_TS = 1_700_000_000;
    uint256 internal constant EPOCH_LENGTH = 259_200;
    uint256 internal constant LOCAL_CHAIN_ID = 1;

    DeployMainnetRegentEmissionsControllerScript internal script;
    SimpleMintableERC20 internal regent;
    SimpleMintableERC20 internal usdc;
    SubjectRegistry internal subjectRegistry;

    function setUp() external {
        script = new DeployMainnetRegentEmissionsControllerScript();
        regent = new SimpleMintableERC20("Regent", "REGENT", 18, address(this), 0, address(this));
        usdc = new SimpleMintableERC20("USDC", "USDC", 6, address(this), 0, address(this));
        subjectRegistry = new SubjectRegistry(address(this));

        vm.setEnv("REGENT_TOKEN_ADDRESS", vm.toString(address(regent)));
        vm.setEnv("ETH_MAINNET_USDC_ADDRESS", vm.toString(address(usdc)));
        vm.setEnv("SUBJECT_REGISTRY_ADDRESS", vm.toString(address(subjectRegistry)));
        vm.setEnv("REGENT_USDC_TREASURY", vm.toString(USDC_TREASURY));
        vm.setEnv("REGENT_EMISSIONS_OWNER", vm.toString(OWNER));
        vm.setEnv("REVENUE_EPOCH_GENESIS_TS", vm.toString(GENESIS_TS));
        vm.setEnv("REVENUE_EPOCH_LENGTH", vm.toString(EPOCH_LENGTH));
        vm.setEnv("REGENT_EMISSIONS_CHAIN_ID", vm.toString(LOCAL_CHAIN_ID));
    }

    function testDeployFromEnvCreatesMainnetController() external {
        MainnetRegentEmissionsController controller = script.deployFromEnv();

        assertEq(address(controller.regent()), address(regent));
        assertEq(address(controller.usdc()), address(usdc));
        assertEq(address(controller.subjectRegistry()), address(subjectRegistry));
        assertEq(controller.usdcTreasury(), USDC_TREASURY);
        assertEq(controller.genesisTs(), GENESIS_TS);
        assertEq(controller.epochLength(), EPOCH_LENGTH);
        assertEq(controller.localChainId(), LOCAL_CHAIN_ID);
        assertEq(controller.owner(), OWNER);
        assertTrue(controller.hasRole(controller.CREDIT_ROLE(), OWNER));
        assertTrue(controller.hasRole(controller.EPOCH_PUBLISHER_ROLE(), OWNER));
        assertTrue(controller.hasRole(controller.PAUSER_ROLE(), OWNER));
    }
}
