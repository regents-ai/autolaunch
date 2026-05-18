// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "src/libraries/HookMiner.sol";
import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";
import {LaunchFeeVault} from "src/LaunchFeeVault.sol";
import {LaunchPoolFeeHook} from "src/LaunchPoolFeeHook.sol";

contract LaunchFeeInfraDeployer {
    uint160 internal constant REQUIRED_HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    function deploy(address owner, address poolManager, address quoteToken, bytes32 hookSalt)
        external
        returns (
            LaunchFeeRegistry launchFeeRegistry,
            LaunchFeeVault feeVault,
            LaunchPoolFeeHook hook
        )
    {
        require(owner != address(0), "OWNER_ZERO");
        require(poolManager != address(0), "POOL_MANAGER_ZERO");
        require(quoteToken != address(0), "QUOTE_TOKEN_ZERO");

        launchFeeRegistry = new LaunchFeeRegistry(address(this), quoteToken);
        feeVault = new LaunchFeeVault(address(this), address(launchFeeRegistry));

        bytes memory hookConstructorArgs =
            abi.encode(address(this), poolManager, address(launchFeeRegistry), address(feeVault));
        address expectedHookAddress = HookMiner.computeCreate2Address(
            address(this),
            hookSalt,
            keccak256(abi.encodePacked(type(LaunchPoolFeeHook).creationCode, hookConstructorArgs))
        );
        require(
            (uint160(expectedHookAddress) & uint160((1 << 14) - 1)) == REQUIRED_HOOK_FLAGS,
            "HOOK_FLAGS_INVALID"
        );

        hook = new LaunchPoolFeeHook{salt: hookSalt}(
            address(this), poolManager, address(launchFeeRegistry), address(feeVault)
        );
        require(address(hook) == expectedHookAddress, "HOOK_ADDRESS_MISMATCH");

        feeVault.setHook(address(hook));

        launchFeeRegistry.transferOwnership(owner);
        feeVault.transferOwnership(owner);
        hook.transferOwnership(owner);
    }
}
