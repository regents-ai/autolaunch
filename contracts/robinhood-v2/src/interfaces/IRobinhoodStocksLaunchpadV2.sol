// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IRobinhoodLaunchpadBase} from "./IRobinhoodLaunchpadBase.sol";
import {IRobinhoodStockAdmission} from "./IRobinhoodStockAdmission.sol";

/// @title IRobinhoodStocksLaunchpadV2
/// @notice The Robinhood stock-pair launchpad: a NEW token sold for an admitted STOCK, migrating into
///         the official NEW/STOCK pool whose hook lanes and LP fees belong to the launch's own
///         memestock splitter. 49.5% of the supply is the sale allocation, 49.5% the reserve and 1% the
///         creator vesting. Every auction opens at the same lowest floor and the required raise is the
///         whole sale allocation at it, rounded up; there is no governance minimum and the launcher
///         chooses no term.
interface IRobinhoodStocksLaunchpadV2 is IRobinhoodLaunchpadBase, IRobinhoodStockAdmission {
    struct LaunchParams {
        CoreParams core;
        address stock;
    }

    event StockLaunchCreated(
        uint256 indexed launchId,
        address indexed launcher,
        address indexed newToken,
        address stock,
        address auction,
        uint64 startBlock,
        uint64 endBlock,
        uint128 auctionInventory,
        uint128 migrationReserve,
        uint128 creatorVesting
    );
    event StockLaunchGraduated(
        uint256 indexed launchId,
        address indexed auction,
        bytes32 indexed poolId,
        uint160 sqrtPriceX96,
        uint256 lpTokenId,
        uint128 lpStockUsed,
        uint128 lpNewUsed,
        uint256 newOnlyTokenId,
        uint128 newOnlyUsed,
        uint256 stockRaised,
        uint256 stockDust,
        uint256 newRetired
    );
    event StockAdmitted(address indexed stock, uint8 decimals, address indexed route);
    event StockRevoked(address indexed stock);

    /// @notice Create one stock launch: NEW, its pinned CCA denominated in STOCK and the
    ///         49.5/49.5/1 allocation, atomically.
    function launch(LaunchParams calldata params) external returns (uint256 launchId, address newToken, address auction);

    function admitStock(address stock, address route) external;
    function revokeStock(address stock) external;
}
