// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title RobinhoodPreset
/// @notice Every fixed Robinhood-chain launch term, in one place, with its provenance.
/// @dev USDG is the local dollar asset of the Robinhood chain: minimum raises, launch fees, the
///      protocol lane's settlement and the protocol inbox are all USDG. Nothing here
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
    // minimum raise (founder decision of 2026-09-11; the launchpad is born at this value and the
    // Robinhood Safe may change it with the setter, zero refused)
    // -------------------------------------------------------------------------

    /// @notice A stock-pair auction graduates only by raising at least 1,000 USDG worth of its STOCK.
    ///         No launcher chooses it: the launchpad converts this amount into the STOCK-denominated
    ///         required raise through the admitted route's live quote at creation.
    uint256 internal constant MINIMUM_RAISE_USDG_STOCKS = 1_000e6;

    // -------------------------------------------------------------------------
    // launch fee
    // -------------------------------------------------------------------------

    /// @notice The USDG a launch costs at birth. REGENT does not exist on the Robinhood chain, so
    ///         the fee is a USDG amount deposited into the protocol revenue inbox at creation and
    ///         never refunded. Zero at birth; the Robinhood Safe may set any value.
    // PROVISIONAL: awaiting founder decision record (the Base Stocks fee is 100,000 REGENT; no USDG
    // equivalent has been decided)
    uint256 internal constant LAUNCH_FEE_USDG = 0;

    // -------------------------------------------------------------------------
    // protocol revenue
    // -------------------------------------------------------------------------

    /// @notice Each hook lane is one percent of the realized STOCK amount of a swap: the protocol
    ///         lane and the staker lane of the launch's memestock splitter. Both are always on.
    uint16 internal constant PROTOCOL_LANE_BPS = 100;
    uint16 internal constant STAKER_LANE_BPS = 100;

    // -------------------------------------------------------------------------
    // Base destination
    // -------------------------------------------------------------------------

    /// @notice The only chain a bridge adapter may deliver protocol revenue to. Base mainnet.
    uint256 internal constant BASE_CHAIN_ID = 8453;
}
