// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IRobinhoodLaunchpadBase} from "./IRobinhoodLaunchpadBase.sol";
import {IRobinhoodStockAdmission} from "./IRobinhoodStockAdmission.sol";

/// @title IRobinhoodStocksLaunchpadV1
/// @notice The Robinhood stock-pair launchpad: a NEW token sold for an admitted STOCK, migrating into
///         the official NEW/STOCK pool whose hook lanes and LP fees belong to the launch's own
///         memestock splitter. The launcher chooses the required raise in STOCK; there is no
///         governance minimum.
interface IRobinhoodStocksLaunchpadV1 is IRobinhoodLaunchpadBase, IRobinhoodStockAdmission {
    struct LaunchParams {
        CoreParams core;
        address stock;
        /// @dev STOCK base units the auction must raise to graduate. Must be above zero and no more
        ///      than the fixed inventory can settle on at the highest admitted bid price; anything
        ///      else is refused with `UnreachableRequiredRaise`.
        uint128 requiredStockRaised;
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
    event StockAdmitted(address indexed stock, uint8 decimals, address indexed route);
    event StockRevoked(address indexed stock);

    function launch(LaunchParams calldata params) external returns (uint256 launchId, address newToken, address auction);

    function admitStock(address stock, address route) external;
    function revokeStock(address stock) external;

    function stockRecords(uint256 launchId) external view returns (StockRecord memory);
}
