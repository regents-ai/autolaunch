// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {DeployAutolaunchV1} from "../../script/DeployAutolaunchV1.s.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployLocalAutolaunchLab
/// @notice Local-chain guard and salt miner around the exact production deployment ceremony.
/// @dev This wrapper deliberately owns no deployment graph. It derives the one local salt needed
///      for the fork account's current nonce, then invokes DeployAutolaunchV1.execute unchanged.
contract DeployLocalAutolaunchLab is Script {
    uint256 internal constant LOCAL_CHAIN_ID = 31_337;
    uint256 internal constant STRATEGY_FACTORY_NONCE = 1;
    uint160 internal constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
    uint160 internal constant HOOK_FLAG_MASK = Hooks.ALL_HOOK_MASK;

    string internal constant DEPLOYER_ENV = "REGENT_LOCAL_LAB_DEPLOYER";

    error WrongLocalChain(uint256 expected, uint256 found);
    error UnselectedLocalDeployer();
    error HookSaltSearchExhausted();

    function run() external returns (DeployAutolaunchV1.Graph memory graph) {
        if (block.chainid != LOCAL_CHAIN_ID) revert WrongLocalChain(LOCAL_CHAIN_ID, block.chainid);

        address deployer = vm.envAddress(DEPLOYER_ENV);
        if (deployer == address(0)) revert UnselectedLocalDeployer();

        DeployAutolaunchV1 production = new DeployAutolaunchV1();
        uint256 startingNonce = vm.getNonce(deployer);
        bytes32 hookSalt = _mineHookSalt(production, deployer, startingNonce);

        graph = production.execute(
            DeployAutolaunchV1.Ceremony({deployer: deployer, startingNonce: startingNonce, hookSalt: hookSalt})
        );

        // Report the local addresses needed by the website config. Forge output is captured, so
        // upstream endpoints and Anvil development-key banners are never forwarded.
        console2.log("REGENT_LOCAL_LAB_HOOK_SALT", vm.toString(hookSalt));
        console2.log("REGENT_LOCAL_LAB_UERC20_FACTORY", graph.uerc20Factory);
        console2.log("REGENT_LOCAL_LAB_ESCROW_IMPLEMENTATION", graph.escrowImplementation);
        console2.log("REGENT_LOCAL_LAB_SPLITTER_IMPLEMENTATION", graph.splitterImplementation);
        console2.log("REGENT_LOCAL_LAB_RECEIVER_IMPLEMENTATION", graph.receiverImplementation);
        console2.log("REGENT_LOCAL_LAB_FACTORY", graph.factory);
        console2.log("REGENT_LOCAL_LAB_STRATEGY", graph.strategy);
        console2.log("REGENT_LOCAL_LAB_HOOK", graph.hook);
    }

    function _mineHookSalt(DeployAutolaunchV1 production, address deployer, uint256 startingNonce)
        private
        view
        returns (bytes32 salt)
    {
        DeployAutolaunchV1.Ceremony memory seed =
            DeployAutolaunchV1.Ceremony({deployer: deployer, startingNonce: startingNonce, hookSalt: bytes32(0)});
        address[5] memory top = production.topLevelAddresses(seed);
        address strategy = vm.computeCreateAddress(top[4], STRATEGY_FACTORY_NONCE);
        bytes32 initcodeHash = keccak256(production.hookInitcode(strategy));

        for (uint256 candidate; candidate < type(uint32).max; ++candidate) {
            salt = bytes32(candidate);
            address hook =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), top[4], salt, initcodeHash)))));
            if (uint160(hook) & HOOK_FLAG_MASK == HOOK_FLAGS) return salt;
        }
        revert HookSaltSearchExhausted();
    }
}
