// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title RobinhoodPreset
/// @notice Every fixed Robinhood-chain launch term, in one place, with its provenance.
/// @dev USDG is the local dollar asset of every Robinhood launch: bids, refunds, official pools,
///      hook lanes, splitter revenue, launch fees and the protocol inbox are all USDG. Nothing here
///      depends on Base USDC or on REGENT. A value marked `PROVISIONAL` is a bounded proposal that
///      blocks release admission until the founder confirms or replaces it. Auction geometry (supply
///      split, schedule, tick grid, pool fee, lane divisor, metadata caps) is shared with the Base
///      Stocks component through `StocksPreset`; only the dollar-denominated terms live here.
library RobinhoodPreset {
    /// @notice USDG base units per whole dollar. Every launchpad reads the bound token's own
    ///         `decimals()` at construction and refuses any other value, so the constants below are
    ///         the dollar amounts they read as.
    uint8 internal constant USDG_DECIMALS = 6;

    // -------------------------------------------------------------------------
    // minimum raises (founder decisions of 2026-09-11; each launchpad is born at its value and the
    // Robinhood Safe may change it with the matching setter, zero refused)
    // -------------------------------------------------------------------------

    /// @notice A stock-pair auction graduates only by raising at least 1,000 USDG worth of its STOCK.
    ///         No launcher chooses it: the launchpad converts this amount into the STOCK-denominated
    ///         required raise through the admitted route's live quote at creation.
    uint256 internal constant MINIMUM_RAISE_USDG_STOCKS = 1_000e6;

    /// @notice A revenue-share auction's launcher sets the required raise, never below 5,000 USDG.
    uint256 internal constant MINIMUM_RAISE_USDG_REVSHARE = 5_000e6;

    // -------------------------------------------------------------------------
    // launch fee
    // -------------------------------------------------------------------------

    /// @notice The USDG a launch costs at birth. REGENT does not exist on the Robinhood chain, so
    ///         the fee is a USDG amount deposited into the protocol revenue inbox at creation and
    ///         never refunded. Zero at birth; the Robinhood Safe may set any value.
    // PROVISIONAL: awaiting founder decision record (the Base fee is 100,000 REGENT for Stocks and
    // 1,000,000 REGENT for Revshare; no USDG equivalent has been decided)
    uint256 internal constant LAUNCH_FEE_USDG = 0;

    // -------------------------------------------------------------------------
    // protocol revenue
    // -------------------------------------------------------------------------

    /// @notice Each hook lane is one percent of the realized fee-currency amount of a swap: the
    ///         mandatory protocol lane and, when a subject splitter is active, the subject lane.
    uint16 internal constant PROTOCOL_LANE_BPS = 100;
    uint16 internal constant SUBJECT_LANE_BPS = 100;

    /// @notice The skim every splitter floors exactly once from recognized USDG revenue, 2%.
    uint256 internal constant PROTOCOL_SKIM_BPS = 200;

    // -------------------------------------------------------------------------
    // revenue-share launch (mirrors the frozen Base Revshare allocation)
    // -------------------------------------------------------------------------

    /// @notice The exact NEW supply every revenue-share launch mints, the fixed denominator of the
    ///         splitter's staker share.
    uint256 internal constant REVSHARE_TOTAL_SUPPLY = 100_000_000_000e18;

    /// @notice 10% is sold through the auction, 5% is the migration reserve, 85% vests to the
    ///         launch treasury after graduation.
    uint128 internal constant REVSHARE_AUCTION_INVENTORY = 10_000_000_000e18;
    uint128 internal constant REVSHARE_MIGRATION_RESERVE = 5_000_000_000e18;
    uint256 internal constant REVSHARE_TREASURY_ALLOCATION = 85_000_000_000e18;

    /// @notice Linear vesting of the treasury allocation, measured from graduation.
    uint256 internal constant REVSHARE_VESTING_DURATION = 365 days;

    // -------------------------------------------------------------------------
    // Base destination
    // -------------------------------------------------------------------------

    /// @notice The only chain a bridge adapter may deliver protocol revenue to. Base mainnet.
    uint256 internal constant BASE_CHAIN_ID = 8453;
}
