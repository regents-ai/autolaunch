// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IRobinhoodLaunchpadBase} from "./IRobinhoodLaunchpadBase.sol";
import {IRobinhoodStockAdmission} from "./IRobinhoodStockAdmission.sol";

/// @title IRobinhoodStocksLaunchpadV1
/// @notice The Robinhood stock-pair launchpad: a NEW token sold for an admitted STOCK, migrating into
///         the official NEW/STOCK pool whose hook lanes and LP fees belong to the launch's own
///         memestock splitter. The required raise is the Safe's USDG minimum converted into
///         STOCK by the admitted route's quote at creation; the launcher never chooses it.
interface IRobinhoodStocksLaunchpadV1 is IRobinhoodLaunchpadBase, IRobinhoodStockAdmission {
    struct LaunchParams {
        CoreParams core;
        address stock;
    }

    /// @dev What one graduation locked beyond the full range.
    struct StockRecord {
        /// @dev Zero when the STOCK the full range could not pair was below one unit of liquidity.
        uint256 stockOnlyTokenId;
        uint128 stockOnlyStock;
    }

    event StockLaunchCreated(
        uint256 indexed launchId,
        address indexed launcher,
        address indexed newToken,
        address stock,
        address auction,
        uint64 startBlock,
        uint64 endBlock,
        uint256 floorPriceQ96,
        uint128 requiredStockRaised,
        uint128 auctionInventory,
        uint128 migrationReserve
    );
    event StockLaunchGraduated(
        uint256 indexed launchId,
        address indexed auction,
        bytes32 indexed poolId,
        uint160 sqrtPriceX96,
        uint256 fullRangeTokenId,
        uint128 fullRangeStock,
        uint128 fullRangeNew,
        uint256 stockOnlyTokenId,
        uint128 stockOnlyStock,
        uint256 stockRaised,
        uint256 stockDust,
        uint256 newRetired
    );
    event MinimumRaiseUsdgUpdated(uint256 previousMinimum, uint256 newMinimum);
    event StockAdmitted(address indexed stock, uint8 decimals, address indexed route);
    event StockRevoked(address indexed stock);

    function launch(LaunchParams calldata params) external returns (uint256 launchId, address newToken, address auction);

    function admitStock(address stock, address route) external;
    function revokeStock(address stock) external;
    /// @notice Set the USDG every later launch must raise (in STOCK at the route's quote). Zero refused.
    function setMinimumRaiseUsdg(uint256 newMinimum) external;

    function minimumRaiseUsdg() external view returns (uint256);
    function stockRecords(uint256 launchId) external view returns (StockRecord memory);
}
