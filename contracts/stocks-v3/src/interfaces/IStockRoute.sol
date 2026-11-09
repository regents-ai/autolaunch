// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IStockRoute
/// @notice One admitted acquisition/conversion route for one STOCK: USDC -> STOCK for bidding and
///         STOCK -> USDC for revenue conversion. Governance admits exactly one route per STOCK on
///         the launchpad; the bid adapter and the revenue settler call only that route.
/// @dev A route is a narrow executor, never a custodian. The caller transfers `amountIn` of
///      `tokenIn` to the route immediately before calling `swapExactIn` in the same transaction,
///      and the route must deliver at least `minAmountOut` of `tokenOut` to `recipient`, returning
///      the exact amount delivered. Callers verify with their own balance deltas and never trust
///      the return value alone. Any residue of `tokenIn` the route did not consume must be returned
///      to `recipient` inside the call. The local Base-fork lab installs a fixed-price fixture
///      route; a production route wraps an admitted on-chain market. Neither is a generic router:
///      calldata is built inside the route, never supplied by the caller.
interface IStockRoute {
    function stock() external view returns (address);
    function usdc() external view returns (address);

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        returns (uint256 amountOut);

    /// @notice A read-only estimate for review copy. Never binding.
    function quoteExactIn(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);
}
