// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @dev Deliberately bounded candidate, not a production hook. The proof checks
/// whether an afterSwap-only STOCK charge survives native v4 flash accounting.
contract AfterSwapStockCandidate is BaseTestHooks {
    IPoolManager public immutable manager;
    address public immutable stock;
    uint256 public realizedStock;

    constructor(IPoolManager manager_, address stock_) {
        manager = manager_;
        stock = stock_;
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        external override returns (bytes4, int128)
    {
        require(msg.sender == address(manager));
        int256 stockDelta = Currency.unwrap(key.currency0) == stock ? int256(delta.amount0()) : int256(delta.amount1());
        realizedStock = uint256(stockDelta < 0 ? -stockDelta : stockDelta);
        uint256 charge = realizedStock / 100;
        if (charge > 0) manager.take(Currency.wrap(stock), address(this), charge);
        require(charge <= uint256(uint128(type(int128).max)));
        return (this.afterSwap.selector, int128(uint128(charge)));
    }
}
