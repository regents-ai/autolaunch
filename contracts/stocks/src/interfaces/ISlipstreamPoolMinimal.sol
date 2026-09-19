// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title ISlipstreamPoolMinimal
/// @notice The slice of an Aerodrome Slipstream (Uniswap v3-derived) pool the stock route uses.
/// @dev `swap` pulls the input currency through `uniswapV3SwapCallback` on `msg.sender` and pays the
///      output currency to `recipient` before the callback runs. Positive deltas are owed to the pool,
///      negative deltas were paid out by it.
interface ISlipstreamPoolMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}
