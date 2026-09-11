// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IRobinhoodLaunchpadBase} from "./IRobinhoodLaunchpadBase.sol";
import {IRobinhoodStockAdmission} from "./IRobinhoodStockAdmission.sol";

/// @title IRobinhoodStocksLaunchpadV1
/// @notice The Robinhood stock-pair launchpad: a NEW token sold for an admitted STOCK, migrating into
///         the official NEW/STOCK pool. The required raise is the Safe's USDG minimum converted into
///         STOCK by the admitted route's quote at creation; the launcher never chooses it.
interface IRobinhoodStocksLaunchpadV1 is IRobinhoodLaunchpadBase, IRobinhoodStockAdmission {
    struct LaunchParams {
        CoreParams core;
        address stock;
        /// @dev The account that may configure the subject lane and hand that role on. Never zero.
        address feeAdministrator;
        /// @dev Zero for no subject lane, else a splitter the bound revenue-share launchpad created.
        address subjectSplitter;
    }

    /// @dev What one graduation locked beyond the full range, and who administers the lane.
    struct StockRecord {
        address feeAdministrator;
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
        address feeAdministrator,
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
    event SubjectConfigured(
        uint256 indexed launchId,
        uint32 indexed version,
        address indexed splitter,
        uint16 subjectBps,
        address administrator
    );
    event FeeAdministratorTransferStarted(uint256 indexed launchId, address indexed current, address indexed proposed);
    event FeeAdministratorTransferred(uint256 indexed launchId, address indexed previous, address indexed current);
    event StockAdmitted(address indexed stock, uint8 decimals, address indexed route);
    event StockRevoked(address indexed stock);

    function launch(LaunchParams calldata params) external returns (uint256 launchId, address newToken, address auction);

    function configureSubject(uint256 launchId, address splitter, uint32 expectedVersion) external;
    function proposeFeeAdministrator(uint256 launchId, address proposed) external;
    function acceptFeeAdministrator(uint256 launchId) external;

    function admitStock(address stock, address route) external;
    function revokeStock(address stock) external;
    /// @notice Set the USDG every later launch must raise (in STOCK at the route's quote). Zero refused.
    function setMinimumRaiseUsdg(uint256 newMinimum) external;

    function minimumRaiseUsdg() external view returns (uint256);
    function revshareLaunchpad() external view returns (address);
    function stockRecords(uint256 launchId) external view returns (StockRecord memory);
    function subjectConfig(uint256 launchId)
        external
        view
        returns (
            uint32 version,
            address splitter,
            uint16 subjectBps,
            address administrator,
            address proposedAdministrator
        );
}
