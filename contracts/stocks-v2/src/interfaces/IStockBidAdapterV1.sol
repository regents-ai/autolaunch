// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IStockBidAdapterV1
/// @notice Atomic USDC -> STOCK -> CCA bid for one registered Stocks auction. The bid is owned by
///         the caller; the adapter is never a bid owner, never holds standing balances and never
///         keeps allowances.
/// @dev The adapter pulls exactly `usdcAmount` from `msg.sender` (ERC-20 allowance granted to the
///      adapter), sends it to the launchpad's admitted route for the auction's STOCK, measures the
///      STOCK this invocation received by balance delta, requires it to be at least `minStockOut`,
///      grants the pinned Permit2 an exact allowance and calls the five-argument `submitBid` with
///      `owner = msg.sender`. Any STOCK not committed and any USDC not consumed return to the
///      caller inside the call, and every allowance is restored to zero. Any failure reverts the
///      whole transaction.
interface IStockBidAdapterV1 {
    event StockBidPlaced(
        address indexed auction,
        address indexed owner,
        uint256 indexed bidId,
        uint256 usdcSpent,
        uint128 stockCommitted,
        uint256 maxPriceQ96
    );

    function launchpad() external view returns (address);
    function usdc() external view returns (address);
    function permit2() external view returns (address);

    /// @param auction A CCA created by the launchpad.
    /// @param usdcAmount Exact USDC pulled from the caller.
    /// @param minStockOut Minimum STOCK the route must deliver, else revert.
    /// @param maxPriceQ96 Bid maximum price, a multiple of the auction's tick spacing.
    /// @param prevTickPriceQ96 The CCA tick hint the caller reviewed.
    /// @param deadline Latest acceptable `block.timestamp`.
    function bidWithUsdc(
        address auction,
        uint256 usdcAmount,
        uint128 minStockOut,
        uint256 maxPriceQ96,
        uint256 prevTickPriceQ96,
        uint256 deadline
    ) external returns (uint256 bidId, uint128 stockCommitted);
}
