// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice A second, entirely ordinary settle-after-swap router.
/// @dev It exists so the hook's lane accounting can be proved identical through two unrelated
///      routers. It shares no code, no interface, and no assertion style with the pinned
///      `PoolSwapTest`: it unlocks, swaps once, and settles or takes exactly the swap delta it was
///      left holding. The hook has no router allowlist, so nothing here is privileged.
contract SimpleSwapRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    struct CallbackData {
        address payer;
        PoolKey key;
        SwapParams params;
        uint256 minAmountOut;
        uint256 maxAmountIn;
    }

    error NotManager();
    error InsufficientOutput(uint256 minimum, uint256 actual);
    error ExcessiveInput(uint256 maximum, uint256 actual);

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey calldata key, SwapParams calldata params) external returns (BalanceDelta delta) {
        return _swap(key, params, 0, type(uint256).max);
    }

    /// @notice The same single-pool path with caller limits enforced against the post-hook delta.
    function swapWithLimits(PoolKey calldata key, SwapParams calldata params, uint256 minAmountOut, uint256 maxAmountIn)
        external
        returns (BalanceDelta delta)
    {
        return _swap(key, params, minAmountOut, maxAmountIn);
    }

    function _swap(PoolKey calldata key, SwapParams calldata params, uint256 minAmountOut, uint256 maxAmountIn)
        private
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            manager.unlock(
                abi.encode(
                    CallbackData({
                        payer: msg.sender,
                        key: key,
                        params: params,
                        minAmountOut: minAmountOut,
                        maxAmountIn: maxAmountIn
                    })
                )
            ),
            (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta = manager.swap(data.key, data.params, "");
        bool specifiedIsCurrency0 = (data.params.amountSpecified < 0) == data.params.zeroForOne;
        int256 unspecifiedDelta = specifiedIsCurrency0 ? int256(delta.amount1()) : int256(delta.amount0());
        if (data.params.amountSpecified < 0) {
            uint256 actualOutput = uint256(unspecifiedDelta);
            if (actualOutput < data.minAmountOut) revert InsufficientOutput(data.minAmountOut, actualOutput);
        } else {
            uint256 actualInput = uint256(-unspecifiedDelta);
            if (actualInput > data.maxAmountIn) revert ExcessiveInput(data.maxAmountIn, actualInput);
        }

        // This router did nothing else inside the lock, so its outstanding deltas are exactly the
        // swap delta the manager just returned.
        _resolve(data.key.currency0, data.payer, delta.amount0());
        _resolve(data.key.currency1, data.payer, delta.amount1());

        return abi.encode(delta);
    }

    function _resolve(Currency currency, address payer, int128 amount) private {
        if (amount == 0) return;
        if (amount > 0) {
            manager.take(currency, payer, uint128(amount));
            return;
        }
        uint256 owed = uint256(uint128(-amount));
        manager.sync(currency);
        MockERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), owed);
        manager.settle();
    }
}
