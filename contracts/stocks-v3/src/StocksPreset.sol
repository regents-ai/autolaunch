// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title StocksPreset
/// @notice Every fixed launch term of Autolaunch Stocks, in one place, with its provenance.
/// @dev A value marked `Founder decision 2026-09-09` began as a single bounded proposal from
///      `contracts/stocks-v2/README.md` and was accepted by the founder on 9 September 2026; nothing else
///      in the component restates it. Values with a brief or pinned-dependency provenance are exact.
///
///      Version 3 keeps every version 2 term and restates the block counts for Base's 0.2-second blocks
///      (Denim, 5 November 2026): each lasts the same wall-clock time it did at 2-second blocks. The
///      creator vesting is counted in seconds, because `block.timestamp` keeps whole seconds whatever
///      the block time.
library StocksPreset {
    // -------------------------------------------------------------------------
    // NEW token and allocation
    // -------------------------------------------------------------------------

    // Founder decision 2026-09-09
    uint8 internal constant NEW_DECIMALS = 18;

    /// @notice `S0`, the sale allocation, the migration reserve and the creator vesting together.
    ///         Below the CCA `MAX_TOTAL_SUPPLY` (1 << 100).
    // Founder decision 2026-09-09
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000e18;

    /// @notice 49.75% of `S0` is the sale allocation. A launch that graduates has sold all of it to its
    ///         bidders through the auction, but for rounding.
    // Founder decision 2026-10-05
    uint128 internal constant AUCTION_INVENTORY = 497_500_000e18;

    /// @notice 49.75% of `S0` is the migration reserve: the full-range position pairs what the whole
    ///         raise matches at the final clearing price, and the rest is locked as a NEW-only position
    ///         above the opening price.
    // Founder decision 2026-10-05
    uint128 internal constant MIGRATION_RESERVE = 497_500_000e18;

    /// @notice 0.5% of `S0` vests to the launcher, linearly per second from graduation. A failed launch
    ///         retires it with the rest of its inventory.
    // Founder decision 2026-10-05
    uint128 internal constant CREATOR_VESTING = 5_000_000e18;

    /// @notice Thirty days, counted on `block.timestamp`.
    // Founder decision 2026-10-01 (thirty days)
    uint64 internal constant CREATOR_VESTING_SECONDS = 30 days;

    // -------------------------------------------------------------------------
    // auction schedule (Base 0.2-second blocks)
    // -------------------------------------------------------------------------

    /// @notice Brief P03 "approximately 24 hours": 431,991 blocks, 86,398.2 seconds at 0.2-second
    ///         blocks. Version 2's 43,199 scheduled blocks, ten times over, plus the single terminal
    ///         block.
    // Founder decision 2026-09-09 (the ~24 h intent is the brief's)
    uint64 internal constant AUCTION_DURATION_BLOCKS = 431_991;

    /// @notice Founder decision (21 September 2026): every auction opens exactly ten minutes after its
    ///         creation block, 3,000 blocks at 0.2 seconds. The launcher does not choose it.
    uint64 internal constant START_LEAD_BLOCKS = 3000;

    /// @notice Same pinned CCA convention as Agent, at the same wall-clock time: 128 and 256 seconds.
    uint64 internal constant CLAIM_DELAY_BLOCKS = 640;
    uint64 internal constant MIGRATION_DELAY_BLOCKS = 1280;

    /// @notice Thirteen packed `uint24 mps | uint40 blockDelta` steps summing to
    ///         `AUCTION_DURATION_BLOCKS` blocks and exactly `ConstantsLib.MPS = 1e7`.
    /// @dev Version 2's thirteen-step schedule at a tenth of the per-block rate over ten times the
    ///      blocks. Each version 2 step of `m = 10q + r` mps over `b` blocks becomes `(10 - r) * b` blocks
    ///      at `q` mps and `r * b` blocks at `q + 1` mps, which releases exactly `m * b` mps, and
    ///      neighbouring pieces at the same rate are joined. The single terminal block keeps its
    ///      2,988,024 mps. The auction therefore releases exactly what version 2 released at every one of
    ///      its step boundaries, at the same wall-clock time; between them the two differ by at most
    ///      10,218 mps (0.10% of the inventory). `StocksPreset.t.sol` proves the sums and the boundaries
    ///      against this exact vector and the pinned auction accepts it.
    bytes internal constant AUCTION_STEPS = hex"00000a0000002a8a" hex"00000b000000aa28" hex"00000d0000004288"
        hex"00000e00000063cc" hex"00000f000000b538" hex"000010000000aa68" hex"0000110000010c48" hex"0000120000011726"
        hex"00001300000031a8" hex"000012000000185e" hex"0000130000012024" hex"0000140000002f38" hex"2d97f80000000001";

    uint256 internal constant AUCTION_STEP_COUNT = 13;

    /// @notice Every launch's CCA floor: the pinned auction's lowest admitted floor
    ///         (`ConstantsLib.MIN_FLOOR_PRICE`, 2^32 + 1) rounded up to the 100-tick grid. Q96 STOCK base
    ///         units per NEW base unit.
    // Founder decision 2026-10-01 (the lowest floor)
    uint256 internal constant FLOOR_PRICE_Q96 = 4_294_967_300;

    /// @notice A hundredth of the floor, so the floor sits on the bid-tick grid.
    uint256 internal constant BID_TICK_SPACING_Q96 = FLOOR_PRICE_Q96 / 100;

    /// @notice The STOCK every launch must raise to graduate: the whole sale allocation at the floor,
    ///         rounded up, so an auction nobody bid in never graduates.
    // forge-lint: disable-next-line(unsafe-typecast)
    uint128 internal constant REQUIRED_STOCK_RAISED =
        uint128((uint256(AUCTION_INVENTORY) * FLOOR_PRICE_Q96 + (1 << 96) - 1) >> 96);

    // -------------------------------------------------------------------------
    // official pool
    // -------------------------------------------------------------------------

    // Founder decision 2026-09-09
    uint24 internal constant POOL_FEE = 3000;
    // Founder decision 2026-09-09
    int24 internal constant POOL_TICK_SPACING = 60;

    /// @notice The hook's lanes, in basis points of a swap's gross STOCK amount: 0.3% to the launch's
    ///         creator, 1% to REGENT stakers (converted to USDC outside swaps) and 3% to the launch's
    ///         memestock stakers. The hook takes their sum, 4.3%, floored once; the creator and REGENT
    ///         lanes are each floored and the staker lane is the rest.
    // Founder decision 2026-09-28
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint16 internal constant CREATOR_LANE_BPS = 30;
    uint16 internal constant REGENT_LANE_BPS = 100;
    uint16 internal constant STAKER_LANE_BPS = 300;

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

    /// @notice Brief §1.2 recommendation: after a failed minimum the reserve and the swept inventory
    ///         are transferred to the dead address ("retired"); supply is not reduced because UERC20
    ///         has no burn. Bidders refund through the CCA.
    // Founder decision 2026-09-09 (failed-minimum retirement)
    bool internal constant RETIRE_FAILED_INVENTORY = true;

    /// @notice Graduation opens the official pool at the auction's final clearing price and locks two
    ///         positions in the fee-only `MemestockLPLocker`: a full-range position funded by the whole
    ///         raise and the reserve it pairs there, and a NEW-only position above the opening price
    ///         funded by the rest of the reserve. Only the rounding remainder below one unit of
    ///         liquidity is left over: its STOCK accrues to the REGENT lane of the pool's hook, its NEW
    ///         is retired.
    // Founder decision 2026-09-09 (the destination of the STOCK rounding remainder)
    bool internal constant LP_STOCK_DUST_TO_REGENT_BUCKET = true;

    /// @notice Every unit of a graduated launch's NEW still held by the launchpad after both positions
    ///         are minted, apart from the creator vesting (the auction's unsold rounding, the positions'
    ///         rounding and anything sent to the launchpad), is retired to the dead address, as a failed
    ///         launch's is.
    // Founder decision 2026-09-27
    bool internal constant RETIRE_LEFTOVER_NEW_ON_GRADUATION = true;

    // -------------------------------------------------------------------------
    // NEW-only position geometry (PositionPlanner offsets from the pool's initial tick)
    // -------------------------------------------------------------------------

    /// @notice The NEW-only position covers the NEW side of the book above the opening NEW price: from
    ///         the tick-spacing boundary adjacent to the initial price out as far as the pinned planner's
    ///         offset reaches, 887,272 ticks or the last usable tick when that is nearer. (Past that the
    ///         price has moved by a factor of more than 10^38, so the range's liquidity is the same as an
    ///         edge-to-edge range's to within one part in 10^19.) It therefore holds only NEW at
    ///         initialization and is the liquidity a STOCK buyer meets as the price rises.
    ///
    ///         NEW is currency1: the NEW side is below the pool price (fewer NEW per STOCK is a higher
    ///         NEW price). The pinned planner rounds an upper offset up to the spacing, so
    ///         `-(spacing - 1)` lands exactly on the initial tick rounded down, which keeps the whole
    ///         range at or below the initial price; the lower offset is the planner's widest, `MIN_TICK`.
    ///
    ///         NEW is currency0: the NEW side is above the pool price. The planner rounds a lower offset
    ///         down, so `+spacing` lands one spacing above the initial tick rounded down, which keeps
    ///         the whole range strictly above the initial tick; the upper offset is the planner's widest,
    ///         `MAX_TICK`.
    // Founder decision 2026-10-01 (a NEW-only position above the opening price; the width is v1's)
    int24 internal constant NEW_ONLY_BELOW_LOWER_OFFSET = TickMath.MIN_TICK;
    int24 internal constant NEW_ONLY_BELOW_UPPER_OFFSET = -(POOL_TICK_SPACING - 1);
    int24 internal constant NEW_ONLY_ABOVE_LOWER_OFFSET = POOL_TICK_SPACING;
    int24 internal constant NEW_ONLY_ABOVE_UPPER_OFFSET = TickMath.MAX_TICK;
}
