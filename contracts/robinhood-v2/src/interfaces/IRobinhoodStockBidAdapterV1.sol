// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

interface IRobinhoodStockBidAdapterV1 {
    event StockBidPlaced(
        address indexed auction,
        address indexed owner,
        uint256 indexed bidId,
        uint256 usdgSpent,
        uint128 stockCommitted,
        uint256 maxPriceQ96
    );

    function launchpad() external view returns (address);
    function usdg() external view returns (address);
    function permit2() external view returns (address);

    /// @notice Convert exactly `usdgAmount` of the caller's USDG into the auction's STOCK through the
    ///         launchpad's admitted route and commit all of it as one bid owned by the caller.
    function bidWithUsdg(
        address auction,
        uint256 usdgAmount,
        uint128 minStockOut,
        uint256 maxPriceQ96,
        uint256 prevTickPriceQ96,
        uint256 deadline
    ) external returns (uint256 bidId, uint128 stockCommitted);
}
