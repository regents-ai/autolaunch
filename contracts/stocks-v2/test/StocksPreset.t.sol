// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConstantsLib} from "continuous-clearing-auction/libraries/ConstantsLib.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StocksPreset} from "../src/StocksPreset.sol";

/// @notice The preset is a set of arithmetic facts; each one is proved here against the constants.
contract StocksPresetTest is Test {
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
        assertEq(steps.length, 8 * StocksPreset.AUCTION_STEP_COUNT, "13 packed bytes8 steps");

        uint256 sumMps;
        uint256 sumBlocks;
        uint24 previousMps;
        for (uint256 i; i < steps.length; i += 8) {
            (uint24 mps, uint40 blockDelta) = _step(steps, i);
            assertGt(blockDelta, 0, "no zero block delta");
            assertGt(mps, previousMps, "per-block rate rises step by step");
            previousMps = mps;
            sumMps += uint256(mps) * uint256(blockDelta);
            sumBlocks += blockDelta;
        }
        assertEq(sumBlocks, StocksPreset.AUCTION_DURATION_BLOCKS, "block deltas sum to the duration");
        assertEq(sumMps, ConstantsLib.MPS, "mps * blockDelta sums to exactly MPS");

        (uint24 terminalMps, uint40 terminalDelta) = _step(steps, steps.length - 8);
        assertEq(terminalDelta, 1, "terminal step is a single block");
        assertEq(terminalMps, 2_988_024, "terminal step carries the remainder");
        // ~29.88% of the inventory is released in the final block, the same shape as Agent's pinned
        // schedule (2,988,006 mps in its terminal block).
        assertEq(uint256(terminalMps) * 10_000 / ConstantsLib.MPS, 2_988, "terminal block releases 29.88%");
    }

    function test_twelve_scheduled_steps_each_release_about_five_point_eight_percent() public pure {
        bytes memory steps = StocksPreset.AUCTION_STEPS;
        for (uint256 i; i < steps.length - 8; i += 8) {
            (uint24 mps, uint40 blockDelta) = _step(steps, i);
            uint256 released = uint256(mps) * uint256(blockDelta);
            assertGe(released, 579_000, "at least 5.79%");
            assertLe(released, 589_000, "at most 5.89%");
        }
    }

    function test_timing_constants() public pure {
        assertEq(StocksPreset.AUCTION_DURATION_BLOCKS, 43_200, "~24 h at 2 s blocks");
        assertEq(StocksPreset.CLAIM_DELAY_BLOCKS, 64);
        assertEq(StocksPreset.MIGRATION_DELAY_BLOCKS, 128);
        assertEq(StocksPreset.START_LEAD_BLOCKS, 300, "ten minutes at 2 s blocks");
        assertEq(StocksPreset.CREATOR_VESTING_BLOCKS, 1_296_000, "thirty days at 2 s blocks");
        assertGt(StocksPreset.MIGRATION_DELAY_BLOCKS, StocksPreset.CLAIM_DELAY_BLOCKS);
    }

    function test_lane_constants() public pure {
        assertEq(StocksPreset.BPS_DENOMINATOR, 10_000);
        assertEq(StocksPreset.CREATOR_LANE_BPS, 30);
        assertEq(StocksPreset.REGENT_LANE_BPS, 100);
        assertEq(StocksPreset.STAKER_LANE_BPS, 300);
        assertEq(StocksPreset.POOL_FEE, 3000);
        assertEq(StocksPreset.POOL_TICK_SPACING, 60);
    }

    function _step(bytes memory steps, uint256 offset) private pure returns (uint24 mps, uint40 blockDelta) {
        bytes8 word;
        assembly ("memory-safe") {
            word := mload(add(add(steps, 0x20), offset))
        }
        mps = uint24(bytes3(word));
        blockDelta = uint40(uint64(word));
    }
}
