// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IStocksLaunchpadV1
/// @notice The launch, custody and migration surface of Autolaunch Stocks. One launch creates a
///         new token (NEW), sells exactly 80% of its initial supply through a pinned Continuous
///         Clearing Auction denominated in one admitted Base stock token (STOCK), holds the other
///         20% as the migration reserve, and after the auction either migrates all net STOCK plus
///         the reserve into the official NEW/STOCK Uniswap v4 pool or retires the launch inventory.
/// @dev This interface is the contract between the Solidity component and the website, indexer
///      and CLI. Event and function shapes here are consumed off-chain; change them only together
///      with `platform/contracts/abi/stocks-*.json` and the platform ABI validation.
interface IStocksLaunchpadV1 {
    /// @notice Everything a launcher supplies. Supply, decimals, allocations, schedule shape,
    ///         claim/migration delays, LP fee, hook rates and custody policy are fixed by the preset.
    /// @dev `treasury`, creator allocation, vesting and any Agent identity are deliberately absent.
    struct LaunchParams {
        string name;
        string symbol;
        string description;
        string website;
        string image;
        /// @dev Exact admitted STOCK address on Base. Symbols are display metadata, never identity.
        address stock;
        /// @dev First bidding block. Must satisfy `block.number + MIN_START_LEAD_BLOCKS <= startBlock
        ///      <= block.number + MAX_START_LEAD_BLOCKS`. The end is `startBlock + AUCTION_DURATION_BLOCKS`.
        uint64 startBlock;
        /// @dev Q96 STOCK base units per NEW base unit, the CCA floor. Bid tick spacing is derived
        ///      deterministically from it (see `bidTickSpacingFor`).
        uint256 floorPriceQ96;
        /// @dev Minimum STOCK (base units) the auction must raise to graduate.
        uint128 requiredStockRaised;
        /// @dev The account allowed to enable, disable or retarget the optional subject lane later.
        ///      Required even when the subject lane starts disabled. Has no other power.
        address feeAdministrator;
        /// @dev Zero leaves the subject lane off. Nonzero must be an authentic Agent
        ///      `SubjectSplitterV1` recorded by the bound Agent strategy; it becomes the active
        ///      subject destination at 100 bps.
        address subjectSplitter;
    }

    enum Lifecycle {
        None,
        Active,
        Graduated,
        Failed
    }

    /// @notice One recorded launch. Identity and lifecycle only; the record carries no authority.
    /// @dev A graduated launch locks two positions at the dead address: `lpTokenId` is the full-range
    ///      position funded by `(lpStockUsed, lpNewUsed)`; `lpStockOnlyTokenId` is the one-sided STOCK
    ///      position holding `lpStockOnlyUsed`, every unit of net STOCK the full range could not pair.
    ///      `lpStockOnlyTokenId` is zero only when that remainder was below one unit of liquidity.
    struct Launch {
        address launcher;
        address newToken;
        address stock;
        address auction;
        address feeAdministrator;
        uint64 startBlock;
        uint64 endBlock;
        uint64 claimBlock;
        uint64 migrationBlock;
        uint128 requiredStockRaised;
        uint256 floorPriceQ96;
        Lifecycle lifecycle;
        bytes32 poolId;
        uint160 finalSqrtPriceX96;
        uint256 lpTokenId;
        uint128 lpStockUsed;
        uint128 lpNewUsed;
        uint256 retiredNew;
        uint256 lpStockOnlyTokenId;
        uint128 lpStockOnlyUsed;
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
        uint256 auctionInventory,
        uint256 migrationReserve
    );

    event StockLaunchGraduated(
        uint256 indexed launchId,
        address indexed auction,
        bytes32 poolId,
        uint160 sqrtPriceX96,
        uint256 lpTokenId,
        uint128 lpStockUsed,
        uint128 lpNewUsed,
        uint256 lpStockOnlyTokenId,
        uint128 lpStockOnlyUsed,
        uint256 stockRaised,
        uint256 stockDustToRevenue,
        uint256 unsoldNewRetired
    );

    event StockLaunchRetired(uint256 indexed launchId, address indexed auction, uint256 newRetired);

    /// @notice Subject lane configuration change. `version` is monotonic per launch, starting at 1
    ///         for the configuration recorded at creation.
    event SubjectConfigured(
        uint256 indexed launchId, uint32 indexed version, address indexed splitter, uint16 subjectBps, address administrator
    );
    event FeeAdministratorTransferStarted(uint256 indexed launchId, address indexed current, address indexed proposed);
    event FeeAdministratorTransferred(uint256 indexed launchId, address indexed previous, address indexed current);

    event StockAdmitted(address indexed stock, uint8 decimals);
    event StockRevoked(address indexed stock);
    event LaunchesPaused();
    event LaunchesUnpaused();

    // -------------------------------------------------------------------------
    // creation
    // -------------------------------------------------------------------------

    /// @notice Create one Stocks launch: NEW, its pinned CCA denominated in STOCK, the 80/20
    ///         allocation and the initial fee configuration, atomically.
    function launch(LaunchParams calldata params)
        external
        returns (uint256 launchId, address newToken, address auction);

    /// @notice Drive a launch past its end to its terminal state. Anyone may call once the
    ///         migration block is reached. Graduated: initialize the official pool, lock the whole
    ///         reserve and all net STOCK in two positions (full range, then one-sided STOCK for the
    ///         remainder), retire unsold NEW. Failed: retire the reserve and every unsold unit;
    ///         bidders refund through the CCA.
    function migrate(uint256 launchId) external;

    // -------------------------------------------------------------------------
    // fee administration (subject lane only; the REGENT lane is immutable)
    // -------------------------------------------------------------------------

    /// @notice Enable, disable (`splitter == address(0)`) or retarget the subject lane for future
    ///         swaps. `expectedVersion` must equal the current configuration version.
    function configureSubject(uint256 launchId, address splitter, uint32 expectedVersion) external;
    function proposeFeeAdministrator(uint256 launchId, address proposed) external;
    function acceptFeeAdministrator(uint256 launchId) external;

    // -------------------------------------------------------------------------
    // governance (frozen Regent Safe only)
    // -------------------------------------------------------------------------

    function admitStock(address stock, address route) external;
    function revokeStock(address stock) external;
    function pauseLaunches() external;
    function unpauseLaunches() external;

    // -------------------------------------------------------------------------
    // reads
    // -------------------------------------------------------------------------

    function launches(uint256 launchId) external view returns (Launch memory);
    function launchIdOfAuction(address auction) external view returns (uint256);
    function launchIdOfToken(address newToken) external view returns (uint256);
    function nextLaunchId() external view returns (uint256);
    function launchesPaused() external view returns (bool);
    /// @notice Whether STOCK may be used for a new launch right now, and its recorded decimals.
    function stockAdmission(address stock) external view returns (bool admitted, uint8 decimals, address route);
    /// @notice Current subject lane configuration of a launch.
    function subjectConfig(uint256 launchId)
        external
        view
        returns (uint32 version, address splitter, uint16 subjectBps, address administrator, address proposedAdministrator);
    /// @notice The bid tick spacing (Q96) the CCA is created with for a floor price.
    function bidTickSpacingFor(uint256 floorPriceQ96) external pure returns (uint256);
    function hook() external view returns (address);
}
