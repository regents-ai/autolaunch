// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IStocksLaunchpadV2
/// @notice The launch, custody and migration surface of Autolaunch Stocks. One launch creates a
///         new token (NEW), sells half of its initial supply through a pinned Continuous Clearing
///         Auction denominated in one admitted Base stock token (STOCK) and holds the other half as
///         the migration reserve. A graduated launch pairs the whole reserve with the whole raise in
///         the official NEW/STOCK Uniswap v4 pool and gives bidders every unit of the sale
///         allocation; a failed launch refunds bidders and retires the launch inventory.
/// @dev This interface is the contract between the Solidity component and the website, indexer
///      and CLI. Event and function shapes here are consumed off-chain; change them only together
///      with `platform/contracts/abi/stocks-*.json` and the platform ABI validation.
interface IStocksLaunchpadV2 {
    /// @notice Everything a launcher supplies. Supply, decimals, allocations, schedule (the auction
    ///         opens `START_LEAD_BLOCKS` after the creation block), claim/migration delays, LP fee,
    ///         hook rates and custody policy are fixed by the preset. There is no launch fee.
    /// @dev `treasury`, creator allocation, vesting, any Agent identity and any launcher authority over
    ///      fees are deliberately absent.
    struct LaunchParams {
        string name;
        string symbol;
        string description;
        string website;
        string image;
        /// @dev Exact admitted STOCK address on Base. Symbols are display metadata, never identity.
        address stock;
        /// @dev Q96 STOCK base units per NEW base unit, the CCA floor. Bid tick spacing and the
        ///      required raise are derived deterministically from it (see `bidTickSpacingFor` and
        ///      `requiredStockRaisedFor`).
        uint256 floorPriceQ96;
    }

    enum Lifecycle {
        None,
        Active,
        Graduated,
        Failed
    }

    /// @notice One recorded launch. Identity and lifecycle only; the record carries no authority.
    /// @dev `splitter` is the launch's memestock splitter, created at graduation and zero before it. A
    ///      graduated launch locks one full-range position, `lpTokenId`, funded by
    ///      `(lpStockUsed, lpNewUsed)`. `newSold` is the NEW the auction kept for its bids' claims and
    ///      `newShared` the NEW this launchpad holds for them on top (see `claimUnsoldShare`).
    ///      `retiredNew` is set only for a failed launch.
    struct Launch {
        address launcher;
        address newToken;
        address stock;
        address auction;
        address splitter;
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
        uint256 newSold;
        uint256 newShared;
        uint256 retiredNew;
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
        uint256 stockRaised,
        uint256 stockDustToRevenue,
        uint256 newSold,
        uint256 newShared
    );

    /// @notice One bid's share of the NEW the auction did not sell, paid to the bid's owner.
    event UnsoldShareClaimed(
        uint256 indexed launchId, uint256 indexed bidId, address indexed owner, uint256 tokensFilled, uint256 share
    );

    /// @notice The launch's memestock splitter, created as the first step of its graduation: where
    ///         MEMESTOCK is staked, the hook's staker lane is deposited and the locked position's LP
    ///         fees are recognized.
    event MemestockSplitterCreated(
        uint256 indexed launchId, address indexed newToken, address indexed stock, address splitter
    );

    event StockLaunchRetired(uint256 indexed launchId, address indexed auction, uint256 newRetired);

    event StockAdmitted(address indexed stock, uint8 decimals);
    event StockRevoked(address indexed stock);
    event LaunchesPaused();
    event LaunchesUnpaused();

    // -------------------------------------------------------------------------
    // creation
    // -------------------------------------------------------------------------

    /// @notice Create one Stocks launch: NEW, its pinned CCA denominated in STOCK and the 50/50
    ///         allocation, atomically.
    function launch(LaunchParams calldata params) external returns (uint256 launchId, address newToken, address auction);

    /// @notice Drive a launch past its end to its terminal state. Anyone may call once the
    ///         migration block is reached. Graduated: create the launch's memestock splitter,
    ///         initialize the official pool at the raise divided by the sale allocation, lock the whole
    ///         reserve and the whole raise in the fee-only locker as one full-range position, and hold
    ///         the unsold NEW for the bids. Failed: retire the reserve and every unsold unit; bidders
    ///         refund through the CCA.
    function migrate(uint256 launchId) external;

    /// @notice Pay one bid of a graduated launch its share of the unsold NEW:
    ///         `newShared * tokensFilled / newSold`, rounded down, to the bid's owner. Anyone may call,
    ///         once per bid, before or after the bid's own exit and claim at the auction.
    /// @param lastFullyFilledCheckpointBlock, outbidBlock The hints the auction's
    ///        `exitPartiallyFilledBid` takes; ignored for a bid priced above the final clearing price.
    function claimUnsoldShare(
        uint256 launchId,
        uint256 bidId,
        uint64 lastFullyFilledCheckpointBlock,
        uint64 outbidBlock
    ) external;

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
    /// @notice The bid tick spacing (Q96) the CCA is created with for a floor price.
    function bidTickSpacingFor(uint256 floorPriceQ96) external pure returns (uint256);
    /// @notice The STOCK a launch at this floor must raise to graduate: the whole sale allocation at
    ///         the floor price, rounded up, so it is never zero.
    function requiredStockRaisedFor(uint256 floorPriceQ96) external pure returns (uint128);
    /// @notice What `claimUnsoldShare` would pay for one bid of a graduated launch, and whether it was
    ///         already paid.
    function unsoldShareOf(uint256 launchId, uint256 bidId, uint64 lastFullyFilledCheckpointBlock, uint64 outbidBlock)
        external
        view
        returns (address owner, uint256 share, bool claimed);
    function hook() external view returns (address);
    /// @notice The clone target every launch's memestock splitter is created from.
    function splitterImplementation() external view returns (address);
    /// @notice The permanent fee-only custodian of every graduated position.
    function locker() external view returns (address);
}
