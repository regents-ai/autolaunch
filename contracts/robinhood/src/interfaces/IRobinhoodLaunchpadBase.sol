// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IRobinhoodLaunchpadBase
/// @notice The surface every Robinhood launchpad shares: one launch mints a new token (NEW), sells a
///         fixed inventory through a pinned Continuous Clearing Auction denominated in the launch's
///         currency (USDG for a revenue-share launch, an admitted STOCK for a stock-pair launch),
///         custodies the reserve, and after the auction either migrates the raise plus the reserve
///         into the official NEW/currency Uniswap v4 pool or retires the inventory.
/// @dev Block numbers are the pinned auction's own notion of a block (`BlockNumberish`): the L2
///      block on Arbitrum-family chains such as the Robinhood chain, `block.number` elsewhere.
interface IRobinhoodLaunchpadBase {
    enum Lifecycle {
        None,
        Active,
        Graduated,
        Failed
    }

    /// @notice The metadata and terms every launcher supplies, whatever the launch kind.
    struct CoreParams {
        string name;
        string symbol;
        string description;
        string website;
        string image;
        /// @dev First bidding block, in the auction's block units. Must satisfy
        ///      `now + MIN_START_LEAD_BLOCKS <= startBlock <= now + MAX_START_LEAD_BLOCKS`.
        uint64 startBlock;
        /// @dev Q96 currency base units per NEW base unit, the CCA floor. Bid tick spacing is derived
        ///      deterministically from it (see `bidTickSpacingFor`).
        uint256 floorPriceQ96;
        /// @dev The USDG launch fee the launcher reviewed. Must equal the current `launchFee()`, and
        ///      the launcher's USDG allowance to the launchpad must equal it exactly. The fee is pulled
        ///      at creation, deposited into the protocol revenue inbox and never refunded.
        uint256 expectedLaunchFee;
    }

    /// @notice One recorded launch. Identity and lifecycle only; the record carries no authority.
    struct Launch {
        address launcher;
        address newToken;
        address currency;
        address auction;
        uint64 startBlock;
        uint64 endBlock;
        uint64 claimBlock;
        uint64 migrationBlock;
        uint128 requiredRaise;
        uint256 floorPriceQ96;
        Lifecycle lifecycle;
        bytes32 poolId;
        uint160 finalSqrtPriceX96;
        /// @dev The first locked position's token id; a launch kind may lock more, consecutively.
        uint256 lpTokenId;
        uint128 lpCurrencyUsed;
        uint128 lpNewUsed;
        uint256 retiredNew;
    }

    event LaunchFeeCollected(uint256 indexed launchId, address indexed payer, address indexed inbox, uint256 amount);
    event LaunchFeeUpdated(uint256 previousFee, uint256 newFee);
    event LaunchesPaused();
    event LaunchesUnpaused();
    event LaunchRetired(uint256 indexed launchId, address indexed auction, uint256 newRetired);

    /// @notice Drive a launch past its end to its terminal state. Anyone may call once the migration
    ///         block is reached.
    function migrate(uint256 launchId) external;

    function pauseLaunches() external;
    function unpauseLaunches() external;
    /// @notice Set the USDG a new launch costs. Zero is a valid fee.
    function setLaunchFee(uint256 newFee) external;

    function launches(uint256 launchId) external view returns (Launch memory);
    function launchIdOfAuction(address auction) external view returns (uint256);
    function launchIdOfToken(address newToken) external view returns (uint256);
    function nextLaunchId() external view returns (uint256);
    function launchesPaused() external view returns (bool);
    function launchFee() external view returns (uint256);
    function bidTickSpacingFor(uint256 floorPriceQ96) external pure returns (uint256);
    /// @notice The current block in the auction's block units.
    function currentBlock() external view returns (uint256);

    function hook() external view returns (address);
    function usdg() external view returns (address);
    function inbox() external view returns (address);
    function adminSafe() external view returns (address);
    function ccaFactory() external view returns (address);
    function poolManager() external view returns (address);
    function positionManager() external view returns (address);
    function uerc20Factory() external view returns (address);
}
