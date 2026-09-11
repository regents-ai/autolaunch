// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IRobinhoodStockRoute} from "../interfaces/IRobinhoodStockRoute.sol";

/// @title FixtureUsdgStockRoute
/// @notice A fixed-price USDG <-> STOCK route for the local Robinhood lab.
/// @dev LAB ONLY. The lab funds it with minted fixture STOCK and USDG; it pays `amountOut` from that
///      inventory at the fixed price set at construction and keeps the caller's `amountIn`. It builds
///      no calldata from caller input and reaches no other contract than the two tokens. A production
///      route wraps an admitted on-chain market and is a separate admission decision; nothing proven
///      against this fixture is evidence about a real stock market.
contract FixtureUsdgStockRoute is IRobinhoodStockRoute {
    using SafeTransferLib for address;

    /// @notice One whole share in STOCK base units (eight decimals, like the Base catalog tokens).
    uint256 public constant SHARE = 1e8;

    address public immutable override stock;
    address public immutable override usdg;

    /// @notice USDG base units per one whole share. Fixed for the life of the fixture.
    uint256 public immutable usdgPerShare;

    error ZeroAddress();
    error ZeroPrice();
    error UnsupportedPair(address tokenIn, address tokenOut);
    error ZeroAmount();
    error InsufficientOutput(uint256 minimum, uint256 found);

    constructor(address stock_, address usdg_, uint256 usdgPerShare_) {
        if (stock_ == address(0) || usdg_ == address(0)) revert ZeroAddress();
        if (usdgPerShare_ == 0) revert ZeroPrice();
        stock = stock_;
        usdg = usdg_;
        usdgPerShare = usdgPerShare_;
    }

    /// @inheritdoc IRobinhoodStockRoute
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        override
        returns (uint256 amountOut)
    {
        if (recipient == address(0)) revert ZeroAddress();
        amountOut = quoteExactIn(tokenIn, tokenOut, amountIn);
        if (amountOut < minAmountOut) revert InsufficientOutput(minAmountOut, amountOut);
        tokenOut.safeTransfer(recipient, amountOut);
    }

    /// @inheritdoc IRobinhoodStockRoute
    function quoteExactIn(address tokenIn, address tokenOut, uint256 amountIn)
        public
        view
        override
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (tokenIn == usdg && tokenOut == stock) return amountIn * SHARE / usdgPerShare;
        if (tokenIn == stock && tokenOut == usdg) return amountIn * usdgPerShare / SHARE;
        revert UnsupportedPair(tokenIn, tokenOut);
    }
}
