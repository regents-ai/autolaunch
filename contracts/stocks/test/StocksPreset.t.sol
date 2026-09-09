// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConstantsLib} from "continuous-clearing-auction/libraries/ConstantsLib.sol";
import {StocksPreset} from "../src/StocksPreset.sol";

/// @notice The preset is a set of arithmetic facts; each one is proved here against the constants.
contract StocksPresetTest is Test {
    function test_allocation_splits_the_initial_supply_exactly() public pure {
        assertEq(StocksPreset.INITIAL_SUPPLY % 5, 0, "S0 divisible by five");
        assertEq(
            uint256(StocksPreset.AUCTION_INVENTORY) + uint256(StocksPreset.MIGRATION_RESERVE),
            StocksPreset.INITIAL_SUPPLY,
            "inventory + reserve == S0"
        );
        assertEq(uint256(StocksPreset.AUCTION_INVENTORY), 4 * (StocksPreset.INITIAL_SUPPLY / 5), "80%");
        assertEq(uint256(StocksPreset.MIGRATION_RESERVE), StocksPreset.INITIAL_SUPPLY / 5, "20%");
        assertLt(StocksPreset.AUCTION_INVENTORY, ConstantsLib.MAX_TOTAL_SUPPLY, "below CCA MAX_TOTAL_SUPPLY");
        assertLt(StocksPreset.INITIAL_SUPPLY, uint256(type(uint128).max), "fits the UERC20 supply width");
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
        assertLt(StocksPreset.MIN_START_LEAD_BLOCKS, StocksPreset.MAX_START_LEAD_BLOCKS);
        assertGt(StocksPreset.MIGRATION_DELAY_BLOCKS, StocksPreset.CLAIM_DELAY_BLOCKS);
    }

    function test_lane_constants() public pure {
        assertEq(StocksPreset.LANE_DIVISOR, 100);
        assertEq(StocksPreset.REGENT_LANE_BPS, 100);
        assertEq(StocksPreset.SUBJECT_LANE_BPS, 100);
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
