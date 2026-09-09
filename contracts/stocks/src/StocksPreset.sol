// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title StocksPreset
/// @notice Every fixed launch term of Autolaunch Stocks, in one place, with its provenance.
/// @dev A value marked `PROVISIONAL` is a single bounded proposal from `contracts/stocks/README.md`.
///      It blocks release admission until the founder confirms or replaces it; nothing else in the
///      component restates it. Values with a brief or pinned-dependency provenance are exact.
library StocksPreset {
    // -------------------------------------------------------------------------
    // NEW token and allocation
    // -------------------------------------------------------------------------

    // PROVISIONAL: awaiting founder decision record
    uint8 internal constant NEW_DECIMALS = 18;

    /// @notice `S0`. Divisible by five; below the CCA `MAX_TOTAL_SUPPLY` (1 << 100).
    // PROVISIONAL: awaiting founder decision record
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000e18;

    /// @notice Brief P04, exact: 80% of `S0` is sold through the auction.
    // slither-disable-next-line divide-before-multiply
    // forge-lint: disable-next-line(unsafe-typecast)
    uint128 internal constant AUCTION_INVENTORY = uint128(4 * (INITIAL_SUPPLY / 5));

    /// @notice Brief P04, exact: 20% of `S0` is the migration reserve.
    // forge-lint: disable-next-line(unsafe-typecast)
    uint128 internal constant MIGRATION_RESERVE = uint128(INITIAL_SUPPLY / 5);

    // -------------------------------------------------------------------------
    // auction schedule
    // -------------------------------------------------------------------------

    /// @notice Brief P03 "approximately 24 hours" at Base's 2-second blocks.
    // PROVISIONAL: awaiting founder decision record (the block count; the ~24 h intent is the brief's)
    uint64 internal constant AUCTION_DURATION_BLOCKS = 43_200;

    /// @notice The earliest and latest first bidding block, relative to the launch block.
    // PROVISIONAL: awaiting founder decision record
    uint64 internal constant MIN_START_LEAD_BLOCKS = 300;
    // PROVISIONAL: awaiting founder decision record
    uint64 internal constant MAX_START_LEAD_BLOCKS = 1_296_000;

    /// @notice Same pinned CCA convention as Agent.
    uint64 internal constant CLAIM_DELAY_BLOCKS = 64;
    uint64 internal constant MIGRATION_DELAY_BLOCKS = 128;

    /// @notice Thirteen packed `uint24 mps | uint40 blockDelta` steps summing to
    ///         `AUCTION_DURATION_BLOCKS` blocks and exactly `ConstantsLib.MPS = 1e7`.
    /// @dev Derived from the Agent schedule's shape: twelve scheduled steps of shortening windows at
    ///      rising per-block rates, each releasing about 5.8% of the inventory (5,445 blocks at 108 mps
    ///      down to 3,022 blocks at 194 mps), and a thirteenth single terminal block carrying the
    ///      remaining 2,988,024 mps. `StocksPreset.t.sol` proves both sums against this exact vector
    ///      and the pinned `StepStorage` accepts it.
    bytes internal constant AUCTION_STEPS = hex"00006c0000001545" hex"00008800000010a2" hex"0000960000000f3e"
        hex"00009e0000000e66" hex"0000a60000000dce" hex"0000aa0000000d5a" hex"0000b00000000cfc" hex"0000b40000000cad"
        hex"0000b80000000c6a" hex"0000bc0000000c2f" hex"0000be0000000bfc" hex"0000c20000000bce" hex"2d97f80000000001";

    uint256 internal constant AUCTION_STEP_COUNT = 13;

    /// @notice Bid tick spacing is `floorPriceQ96 / BID_TICK_DIVISOR`; the floor must divide exactly.
    uint256 internal constant BID_TICK_DIVISOR = 100;

    // -------------------------------------------------------------------------
    // official pool
    // -------------------------------------------------------------------------

    // PROVISIONAL: awaiting founder decision record
    uint24 internal constant POOL_FEE = 3000;
    // PROVISIONAL: awaiting founder decision record
    int24 internal constant POOL_TICK_SPACING = 60;

    /// @notice Brief P08: each hook lane is `feeBase / LANE_DIVISOR`, floored per lane.
    uint256 internal constant LANE_DIVISOR = 100;
    uint16 internal constant REGENT_LANE_BPS = 100;
    /// @notice Brief P09/P10: the subject lane is either off or exactly this.
    uint16 internal constant SUBJECT_LANE_BPS = 100;

    // -------------------------------------------------------------------------
    // metadata caps (same shape as the Agent factory; bytes, inclusive, each nonempty)
    // -------------------------------------------------------------------------

    uint256 internal constant MAX_NAME_BYTES = 64;
    uint256 internal constant MAX_SYMBOL_BYTES = 16;
    uint256 internal constant MAX_DESCRIPTION_BYTES = 512;
    uint256 internal constant MAX_WEBSITE_BYTES = 256;
    uint256 internal constant MAX_IMAGE_BYTES = 256;

    // -------------------------------------------------------------------------
    // terminal custody (mechanisms are labelled, not chosen, here)
    // -------------------------------------------------------------------------

    /// @notice Brief P13. Unsold NEW after graduation is transferred to the dead address ("retired");
    ///         supply is not reduced because UERC20 has no burn.
    /// @notice Brief §1.2 recommendation: after a failed minimum the reserve and the swept inventory
    ///         are retired the same way.
    // PROVISIONAL: awaiting founder decision record (failed-minimum retirement)
    bool internal constant RETIRE_FAILED_INVENTORY = true;

    /// @notice Brief P13 "all-net-STOCK liquidity": graduation locks two positions at the dead
    ///         address. The full-range position takes the whole reserve and the STOCK it pairs with
    ///         at the clearing price; the one-sided STOCK position takes every remaining unit of net
    ///         STOCK. Only the rounding remainder below one unit of liquidity, bounded by
    ///         `sqrt(clearingPrice)` base units and zero at every realistic price, accrues to the
    ///         REGENT bucket of the pool's hook. See README "Money and custody rules" 3.
    // PROVISIONAL: awaiting founder decision record (the destination of the rounding remainder)
    bool internal constant LP_STOCK_DUST_TO_REGENT_BUCKET = true;

    // -------------------------------------------------------------------------
    // one-sided STOCK position geometry (PositionPlanner offsets from the pool's initial tick)
    // -------------------------------------------------------------------------

    /// @notice The one-sided STOCK position covers the whole STOCK side of the book: from the
    ///         tick-spacing boundary adjacent to the initial price out to the last usable tick on that
    ///         side. It therefore holds only STOCK at initialization and is the first liquidity a NEW
    ///         seller meets.
    ///
    ///         STOCK is currency1: the STOCK side is below the price. The pinned planner rounds an
    ///         upper offset up to the spacing, so `-(spacing - 1)` lands exactly on the initial tick
    ///         rounded down, which keeps the whole range at or below the initial price; the lower bound
    ///         is the lowest usable tick (`MIN_TICK` clamps there).
    ///
    ///         STOCK is currency0: the STOCK side is above the price. The planner rounds a lower
    ///         offset down, so `+spacing` lands one spacing above the initial tick rounded down, which
    ///         keeps the whole range strictly above the initial tick; the upper bound is the highest
    ///         usable tick (`MAX_TICK` clamps there).
    // PROVISIONAL: awaiting founder decision record (the width; the side follows from the price)
    int24 internal constant STOCK_ONLY_BELOW_LOWER_OFFSET = TickMath.MIN_TICK;
    int24 internal constant STOCK_ONLY_BELOW_UPPER_OFFSET = -(POOL_TICK_SPACING - 1);
    int24 internal constant STOCK_ONLY_ABOVE_LOWER_OFFSET = POOL_TICK_SPACING;
    int24 internal constant STOCK_ONLY_ABOVE_UPPER_OFFSET = TickMath.MAX_TICK;
}
