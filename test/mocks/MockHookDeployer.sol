// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "src/libraries/HookMiner.sol";
import {LaunchPoolFeeHook} from "src/LaunchPoolFeeHook.sol";

contract MockHookDeployer {
    function deploy(address owner_, address poolManager_, address registry_, address vault_)
        external
        returns (LaunchPoolFeeHook hook)
    {
        (bytes32 salt,) = HookMiner.find(
            address(this),
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            type(LaunchPoolFeeHook).creationCode,
            abi.encode(owner_, poolManager_, registry_, vault_)
        );

        hook = new LaunchPoolFeeHook{salt: salt}(owner_, poolManager_, registry_, vault_);
    }
}
