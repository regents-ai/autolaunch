// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IRobinhoodLaunchpadBase} from "./IRobinhoodLaunchpadBase.sol";

/// @title IRobinhoodRevshareLaunchpadV1
/// @notice The Robinhood revenue-share launchpad: a NEW token sold for USDG, migrating into the
///         official NEW/USDG pool with its own revenue splitter, and a treasury allocation vesting
///         linearly for a year from graduation.
interface IRobinhoodRevshareLaunchpadV1 is IRobinhoodLaunchpadBase {
    struct LaunchParams {
        CoreParams core;
        /// @dev Receives the vesting allocation, the USDG the full range could not pair, and the
        ///      splitter's recoveries. Never a shared-system address.
        address treasury;
        /// @dev The USDG the auction must raise to graduate, at least `minimumRaiseUsdg()`.
        uint128 requiredUsdgRaised;
    }

    struct RevshareRecord {
        address treasury;
        /// @dev Created at graduation; zero before and forever after a failed launch.
        address splitter;
        uint64 vestingStart;
        uint256 vestingTotal;
        uint256 vestingReleased;
    }

    event RevshareLaunchCreated(
        uint256 indexed launchId,
        address indexed launcher,
        address indexed newToken,
        address treasury,
        address auction,
        uint64 startBlock,
        uint64 endBlock,
        uint256 floorPriceQ96,
        uint128 requiredUsdgRaised,
        uint128 auctionInventory,
        uint128 migrationReserve
    );
    event RevshareLaunchGraduated(
        uint256 indexed launchId,
        address indexed auction,
        bytes32 indexed poolId,
        address splitter,
        uint160 sqrtPriceX96,
        uint256 fullRangeTokenId,
        uint128 fullRangeUsdg,
        uint128 fullRangeNew,
        uint256 usdgRaised,
        uint256 usdgToTreasury,
        uint256 newVesting
    );
    event VestingReleased(uint256 indexed launchId, address indexed treasury, uint256 amount, uint256 totalReleased);
    event MinimumRaiseUsdgUpdated(uint256 previousMinimum, uint256 newMinimum);

    function launch(LaunchParams calldata params) external returns (uint256 launchId, address newToken, address auction);

    /// @notice Push every vested, unreleased unit of NEW to the launch treasury. Anyone may call.
    function release(uint256 launchId) external returns (uint256 amount);

    /// @notice Set the least USDG a later launch may require. Zero refused.
    function setMinimumRaiseUsdg(uint256 newMinimum) external;

    function minimumRaiseUsdg() external view returns (uint256);
    function splitterImplementation() external view returns (address);
    /// @notice The splitter this launchpad created for a NEW at graduation; zero for any other address.
    function splitterOf(address newToken) external view returns (address);
    function revshareRecords(uint256 launchId) external view returns (RevshareRecord memory);
    function vested(uint256 launchId) external view returns (uint256);
    function releasable(uint256 launchId) external view returns (uint256);
}
