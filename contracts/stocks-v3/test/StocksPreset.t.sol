// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConstantsLib} from "continuous-clearing-auction/libraries/ConstantsLib.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StocksPreset} from "../src/StocksPreset.sol";
import {V2Schedule} from "./V2Schedule.sol";

/// @notice The preset is a set of arithmetic facts; each one is proved here against the constants.
contract StocksPresetTest is Test {
    /// @dev The widest gap, in mps, between version 3 at block `10 t` and version 2 at block `t`.
    uint256 internal constant WIDEST_GAP_MPS = 10_218;

    function test_allocation_and_floor_are_exact() public pure {
        assertEq(
            uint256(StocksPreset.AUCTION_INVENTORY) + uint256(StocksPreset.MIGRATION_RESERVE)
                + uint256(StocksPreset.CREATOR_VESTING),
            StocksPreset.INITIAL_SUPPLY,
            "inventory + reserve + vesting == S0"
        );
        assertEq(uint256(StocksPreset.AUCTION_INVENTORY), 497_500_000e18, "49.75% is sold");
        assertEq(uint256(StocksPreset.MIGRATION_RESERVE), 497_500_000e18, "49.75% is the pool reserve");
        assertEq(uint256(StocksPreset.CREATOR_VESTING), 5_000_000e18, "0.5% vests to the launcher");
        assertLt(StocksPreset.AUCTION_INVENTORY, ConstantsLib.MAX_TOTAL_SUPPLY, "below CCA MAX_TOTAL_SUPPLY");
        assertLt(StocksPreset.INITIAL_SUPPLY, uint256(type(uint128).max), "fits the UERC20 supply width");

        uint256 lowestOnGrid = (ConstantsLib.MIN_FLOOR_PRICE + 99) / 100 * 100;
        assertEq(StocksPreset.FLOOR_PRICE_Q96, lowestOnGrid, "the floor is the lowest the CCA admits on the grid");
        assertEq(StocksPreset.FLOOR_PRICE_Q96 % StocksPreset.BID_TICK_SPACING_Q96, 0, "the floor is on the grid");
        assertGe(StocksPreset.BID_TICK_SPACING_Q96, ConstantsLib.MIN_TICK_SPACING, "the tick is admitted");
        assertEq(
            StocksPreset.REQUIRED_STOCK_RAISED,
            FullMath.mulDivRoundingUp(StocksPreset.AUCTION_INVENTORY, StocksPreset.FLOOR_PRICE_Q96, FixedPoint96.Q96),
            "the required raise is the sale allocation at the floor, rounded up"
        );
        assertEq(StocksPreset.REQUIRED_STOCK_RAISED, 26_969_530, "the required raise");
    }

    function test_schedule_has_thirteen_steps_summing_to_the_duration_and_to_mps() public pure {
        bytes memory steps = StocksPreset.AUCTION_STEPS;
        assertEq(StocksPreset.AUCTION_STEP_COUNT, 13);
        assertEq(steps.length, 8 * StocksPreset.AUCTION_STEP_COUNT, "13 packed bytes8 steps");

        uint256 sumMps;
        uint256 sumBlocks;
        uint24 previousMps;
        for (uint256 i; i < steps.length; i += 8) {
            (uint24 mps, uint40 blockDelta) = V2Schedule.step(steps, i);
            assertGt(blockDelta, 0, "no zero block delta");
            assertNotEq(mps, previousMps, "neighbouring pieces at one rate are joined");
            assertLt(uint256(mps) * blockDelta, 1 << 24, "each step's product fits the CCA's uint24");
            previousMps = mps;
            sumMps += uint256(mps) * blockDelta;
            sumBlocks += blockDelta;
        }
        assertEq(sumBlocks, StocksPreset.AUCTION_DURATION_BLOCKS, "block deltas sum to the duration");
        assertEq(sumMps, ConstantsLib.MPS, "mps * blockDelta sums to exactly MPS");

        (uint24 terminalMps, uint40 terminalDelta) = V2Schedule.step(steps, steps.length - 8);
        assertEq(terminalDelta, 1, "terminal step is a single block");
        assertEq(terminalMps, 2_988_024, "terminal step carries the remainder");
        // ~29.88% of the inventory is released in the final block, the same shape as Agent's pinned
        // schedule (2,988,006 mps in its terminal block).
        assertEq(uint256(terminalMps) * 10_000 / ConstantsLib.MPS, 2_988, "terminal block releases 29.88%");
    }

    /// @dev Each version 2 step boundary at block `t` is block `10 t` here, and the amount released by
    ///      then is identical, so each of the twelve windows releases what it did in version 2 at the
    ///      same wall-clock time.
    function test_schedule_matches_version_two_at_every_version_two_step_boundary() public pure {
        bytes memory v2 = V2Schedule.AUCTION_STEPS;
        uint256 boundary;
        for (uint256 i; i < v2.length - 8; i += 8) {
            (, uint40 blockDelta) = V2Schedule.step(v2, i);
            boundary += blockDelta;
            assertEq(
                V2Schedule.released(StocksPreset.AUCTION_STEPS, 10 * boundary),
                V2Schedule.released(v2, boundary),
                "equal at a version 2 step boundary"
            );
        }
        assertEq(boundary, V2Schedule.AUCTION_DURATION_BLOCKS - 1, "twelve scheduled windows");
        assertEq(10 * boundary + 1, StocksPreset.AUCTION_DURATION_BLOCKS, "ten times the windows, one terminal block");
    }

    /// @dev At every 2-second mark of the auction (each version 2 block `t`, version 3 block `10 t`) the
    ///      two schedules differ by at most 10,218 mps, 0.11% of the inventory. Every mark is checked.
    function test_schedule_tracks_version_two_at_every_two_second_mark() public pure {
        uint256 widest = V2Schedule.widestGap(StocksPreset.AUCTION_STEPS);
        assertEq(widest, WIDEST_GAP_MPS, "the widest gap between boundaries");
        assertLe(widest * 10_000, 11 * uint256(ConstantsLib.MPS), "never more than 0.11% of the inventory");
    }

    /// @dev For any block of the version 3 auction, what it has released lies within the widest gap of
    ///      what version 2 released at the 2-second marks either side of it, and it is whole at the end.
    function testFuzz_schedule_tracks_version_two_at_any_block(uint256 blockNumber) public pure {
        blockNumber = bound(blockNumber, 0, StocksPreset.AUCTION_DURATION_BLOCKS + 10);
        uint256 current = V2Schedule.released(StocksPreset.AUCTION_STEPS, blockNumber);
        uint256 before = V2Schedule.released(V2Schedule.AUCTION_STEPS, blockNumber / 10);
        uint256 later = V2Schedule.released(V2Schedule.AUCTION_STEPS, (blockNumber + 9) / 10);
        assertLe(current, later + WIDEST_GAP_MPS, "never far ahead of version 2");
        assertGe(current + WIDEST_GAP_MPS, before, "never far behind version 2");
        if (blockNumber >= StocksPreset.AUCTION_DURATION_BLOCKS) assertEq(current, ConstantsLib.MPS, "whole");
    }

    function test_timing_constants() public pure {
        assertEq(StocksPreset.AUCTION_DURATION_BLOCKS, 431_991, "~24 h at 0.2 s blocks");
        assertEq(StocksPreset.CLAIM_DELAY_BLOCKS, 640);
        assertEq(StocksPreset.MIGRATION_DELAY_BLOCKS, 1280);
        assertEq(StocksPreset.START_LEAD_BLOCKS, 3000, "ten minutes at 0.2 s blocks");
        assertEq(StocksPreset.CREATOR_VESTING_SECONDS, 2_592_000, "thirty days in seconds");
        assertGt(StocksPreset.MIGRATION_DELAY_BLOCKS, StocksPreset.CLAIM_DELAY_BLOCKS);

        // The same wall-clock times as version 2's 300, 64 and 128 blocks at 2 s, in milliseconds.
        assertEq(uint256(StocksPreset.START_LEAD_BLOCKS) * 200, 300 * 2000, "ten minutes");
        assertEq(uint256(StocksPreset.CLAIM_DELAY_BLOCKS) * 200, 64 * 2000, "128 seconds");
        assertEq(uint256(StocksPreset.MIGRATION_DELAY_BLOCKS) * 200, 128 * 2000, "256 seconds");
        assertEq(uint256(StocksPreset.AUCTION_DURATION_BLOCKS) * 200, 86_398_200, "1.8 s short of 24 h");
    }

    function test_lane_constants() public pure {
        assertEq(StocksPreset.BPS_DENOMINATOR, 10_000);
        assertEq(StocksPreset.CREATOR_LANE_BPS, 30);
        assertEq(StocksPreset.REGENT_LANE_BPS, 100);
        assertEq(StocksPreset.STAKER_LANE_BPS, 300);
        assertEq(StocksPreset.POOL_FEE, 3000);
        assertEq(StocksPreset.POOL_TICK_SPACING, 60);
    }
}
