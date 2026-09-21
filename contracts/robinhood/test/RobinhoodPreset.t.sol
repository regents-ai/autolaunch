// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConstantsLib} from "continuous-clearing-auction/libraries/ConstantsLib.sol";
import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";
import {RobinhoodPreset} from "../src/RobinhoodPreset.sol";

/// @notice The Robinhood auction schedule: every Base block term scaled twentyfold for 0.1-second
///         blocks, and the step vector proved to sum exactly to the duration and to MPS.
contract RobinhoodPresetTest is Test {
    function test_every_block_term_is_the_base_term_times_twenty() public pure {
        assertEq(RobinhoodPreset.START_LEAD_BLOCKS, 6_000, "ten minutes at 0.1 s blocks");
        assertEq(RobinhoodPreset.START_LEAD_BLOCKS, StocksPreset.START_LEAD_BLOCKS * 20);
        assertEq(RobinhoodPreset.AUCTION_DURATION_BLOCKS, 864_000, "one day at 0.1 s blocks");
        assertEq(RobinhoodPreset.AUCTION_DURATION_BLOCKS, StocksPreset.AUCTION_DURATION_BLOCKS * 20);
        assertEq(RobinhoodPreset.CLAIM_DELAY_BLOCKS, 1_280);
        assertEq(RobinhoodPreset.CLAIM_DELAY_BLOCKS, StocksPreset.CLAIM_DELAY_BLOCKS * 20);
        assertEq(RobinhoodPreset.MIGRATION_DELAY_BLOCKS, 2_560);
        assertEq(RobinhoodPreset.MIGRATION_DELAY_BLOCKS, StocksPreset.MIGRATION_DELAY_BLOCKS * 20);
        assertGt(RobinhoodPreset.MIGRATION_DELAY_BLOCKS, RobinhoodPreset.CLAIM_DELAY_BLOCKS);
    }

    function test_schedule_has_thirteen_steps_summing_to_the_duration_and_to_mps() public pure {
        bytes memory steps = RobinhoodPreset.AUCTION_STEPS;
        assertEq(steps.length, 8 * RobinhoodPreset.AUCTION_STEP_COUNT, "13 packed bytes8 steps");
        assertEq(RobinhoodPreset.AUCTION_STEP_COUNT, StocksPreset.AUCTION_STEP_COUNT, "same shape as Base");

        uint256 sumMps;
        uint256 sumBlocks;
        uint24 previousMps;
        for (uint256 i; i < steps.length; i += 8) {
            (uint24 mps, uint40 blockDelta) = _step(steps, i);
            assertGt(blockDelta, 0, "no zero block delta");
            assertGe(mps, previousMps, "per-block rate never falls");
            previousMps = mps;
            sumMps += uint256(mps) * uint256(blockDelta);
            sumBlocks += blockDelta;
        }
        assertEq(sumBlocks, RobinhoodPreset.AUCTION_DURATION_BLOCKS, "block deltas sum to the duration");
        assertEq(sumMps, ConstantsLib.MPS, "mps * blockDelta sums to exactly MPS");

        (uint24 terminalMps, uint40 terminalDelta) = _step(steps, steps.length - 8);
        assertEq(terminalDelta, 1, "terminal step is a single block");
        assertEq(terminalMps, 2_930_550, "terminal step carries the remainder");
        assertEq(uint256(terminalMps) * 10_000 / ConstantsLib.MPS, 2_930, "terminal block releases 29.30%");
    }

    function test_each_scheduled_step_is_the_base_step_stretched_twentyfold() public pure {
        bytes memory steps = RobinhoodPreset.AUCTION_STEPS;
        bytes memory baseSteps = StocksPreset.AUCTION_STEPS;
        for (uint256 i; i < steps.length - 8; i += 8) {
            (uint24 mps, uint40 blockDelta) = _step(steps, i);
            (uint24 baseMps, uint40 baseDelta) = _step(baseSteps, i);
            // The twelfth step also carries the nineteen blocks the single terminal block does not.
            uint256 expectedDelta = uint256(baseDelta) * 20 + (i == steps.length - 16 ? 19 : 0);
            assertEq(blockDelta, expectedDelta, "twenty Robinhood blocks per Base block");
            assertEq(mps, (uint256(baseMps) + 10) / 20, "the Base rate divided by twenty, rounded");
            uint256 released = uint256(mps) * uint256(blockDelta);
            assertGe(released, 544_000, "at least 5.44%");
            assertLe(released, 625_000, "at most 6.25%");
        }
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
