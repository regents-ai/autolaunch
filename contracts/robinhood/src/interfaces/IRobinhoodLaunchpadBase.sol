// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IRobinhoodLaunchpadBase
/// @notice The chain-level surface of the Robinhood launchpad: one launch mints a new token (NEW),
///         sells a fixed inventory through a pinned Continuous Clearing Auction denominated in the
///         launch's currency (an admitted STOCK), custodies the reserve, and after the auction either
///         migrates the raise plus the reserve into the official NEW/currency Uniswap v4 pool, whose
///         fees belong to the launch's own memestock splitter, or retires the inventory.
/// @dev Block numbers are the pinned auction's own notion of a block (`BlockNumberish`): the L2
///      block on Arbitrum-family chains such as the Robinhood chain, `block.number` elsewhere.
interface IRobinhoodLaunchpadBase {
    enum Lifecycle {
        None,
        Active,
        Graduated,
        Failed
    }

    /// @notice The metadata and terms every launcher supplies. The auction opens
    ///         `RobinhoodPreset.START_LEAD_BLOCKS` after the creation block (in the auction's block
    ///         units): the opening block is fixed at creation, recorded in the launch and carried by
    ///         the creation event. There is no launch fee.
    struct CoreParams {
        string name;
        string symbol;
        string description;
        string website;
        string image;
        /// @dev Q96 currency base units per NEW base unit, the CCA floor. Bid tick spacing is derived
        ///      deterministically from it (see `bidTickSpacingFor`).
        uint256 floorPriceQ96;
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
        /// @dev The launch's own memestock splitter, created at graduation; zero before it.
        address splitter;
        /// @dev The first locked position's token id; more may be locked, consecutively.
        uint256 lpTokenId;
        uint128 lpCurrencyUsed;
        uint128 lpNewUsed;
        uint256 retiredNew;
    }

    event LaunchesPaused();
    event LaunchesUnpaused();
    event LaunchRetired(uint256 indexed launchId, address indexed auction, uint256 newRetired);
    /// @notice Graduation created the launch's own memestock splitter.
    event MemestockSplitterCreated(
        uint256 indexed launchId, address indexed memestock, address indexed stock, address splitter
    );

    /// @notice Drive a launch past its end to its terminal state. Anyone may call once the migration
    ///         block is reached.
    function migrate(uint256 launchId) external;

    function pauseLaunches() external;
    function unpauseLaunches() external;

    function launches(uint256 launchId) external view returns (Launch memory);
    function launchIdOfAuction(address auction) external view returns (uint256);
    function launchIdOfToken(address newToken) external view returns (uint256);
    function nextLaunchId() external view returns (uint256);
    function launchesPaused() external view returns (bool);
    function bidTickSpacingFor(uint256 floorPriceQ96) external pure returns (uint256);
    /// @notice The current block in the auction's block units.
    function currentBlock() external view returns (uint256);

    function hook() external view returns (address);
    function splitterImplementation() external view returns (address);
    function locker() external view returns (address);
    function usdg() external view returns (address);
    function inbox() external view returns (address);
    function adminSafe() external view returns (address);
    function ccaFactory() external view returns (address);
    function poolManager() external view returns (address);
    function positionManager() external view returns (address);
    function uerc20Factory() external view returns (address);
}
