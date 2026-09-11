// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IRobinhoodStockAdmission
/// @notice The one read the hook and the bid adapter make on the stock-pair launchpad: which route
///         governance admitted for a STOCK.
interface IRobinhoodStockAdmission {
    function stockAdmission(address stock) external view returns (bool admitted, uint8 decimals, address route);
}
