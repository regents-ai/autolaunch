// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice The strongest form of the nested-swap attack: a second swap on the *same* pool, issued
///         straight at the already-unlocked PoolManager from inside the hook's settlement call.
/// @dev A router cannot mount this attack at all, because `PoolManager.unlock` rejects a second
///      unlock. Calling `swap` directly does reach the hook a second time, so this attacker settles
///      its own deltas out of its own inventory — the attempt therefore fails, if it fails, on the
///      hook's own protection and not merely on an unsettled delta count.
contract NestedSwapAttacker {
    IPoolManager public immutable manager;

    uint256 public attempts;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function attack(PoolKey calldata key, SwapParams calldata params) external {
        attempts += 1;
        BalanceDelta delta = manager.swap(key, params, "");
        _resolve(key.currency0, delta.amount0());
        _resolve(key.currency1, delta.amount1());
    }

    function _resolve(Currency currency, int128 amount) private {
        if (amount == 0) return;
        if (amount > 0) {
            manager.take(currency, address(this), uint128(amount));
            return;
        }
        uint256 owed = uint256(uint128(-amount));
        manager.sync(currency);
        MockERC20(Currency.unwrap(currency)).transfer(address(manager), owed);
        manager.settle();
    }
}
