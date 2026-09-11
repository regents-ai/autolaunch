// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IRobinhoodStockRoute
/// @notice One admitted acquisition/conversion route for one STOCK on the Robinhood chain: USDG -> STOCK
///         for bidding and STOCK -> USDG for revenue conversion. Governance admits exactly one route per
///         STOCK on the launchpad; the bid adapter and the hook call only that route.
/// @dev A route is a narrow executor, never a custodian. The caller transfers `amountIn` of `tokenIn`
///      to the route immediately before calling `swapExactIn` in the same transaction, and the route
///      must deliver at least `minAmountOut` of `tokenOut` to `recipient`, returning the exact amount
///      delivered. Callers verify with their own balance deltas and never trust the return value
///      alone. Any residue of `tokenIn` the route did not consume must be returned to `recipient`
///      inside the call. Calldata is built inside the route, never supplied by the caller.
interface IRobinhoodStockRoute {
    function stock() external view returns (address);
    function usdg() external view returns (address);

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        returns (uint256 amountOut);

    /// @notice A read-only estimate. The launchpad converts the USDG minimum raise through it at
    ///         creation; everywhere else it is review copy and never binding.
    function quoteExactIn(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);
}
