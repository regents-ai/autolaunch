// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ExposureSeriesV2} from "../src/ExposureSeriesV2.sol";
import {SeriesConfig} from "../src/interfaces/IExposureV2.sol";
import {FormulaFeed, MockStock} from "./doubles/Doubles.sol";

/// @notice The series' own search for the round in force, opened up for testing.
contract SearchHarness is ExposureSeriesV2 {
    constructor(uint256 week_) ExposureSeriesV2(week_) {}

    function roundInForce(uint64 at, uint64 cursor, uint64 cursorUpdatedAt, uint256 cursorAnswer)
        external
        view
        returns (Read read, uint64 round, int256 answer, uint64 updatedAt)
    {
        return _roundInForce(at, cursor, cursorUpdatedAt, cursorAnswer);
    }
}

/// @notice The on-chain search finds exactly the round a linear scan finds: the highest-numbered
///         round updated at or before the boundary, with rounds sharing an update time and a
///         boundary equal to an update time, from a standing start or from any earlier round.
contract RoundSearchTest is Test {
    MockStock internal stock = new MockStock();
    FormulaFeed internal feed;

    /// The harness reads its configuration back from its creator, like a series from the factory.
    function seriesConfig(uint256) external view returns (SeriesConfig memory c) {
        c.asset = address(stock);
        c.feed = address(feed);
        c.phase = 2;
        c.feedDecimals = 8;
        c.depositCap = 1;
        c.boundaries = new uint64[](3);
        (c.boundaries[0], c.boundaries[1], c.boundaries[2]) = (1, 2, 3);
    }

    function _harness(uint256 start, uint256 step, uint256 group, uint256 count, uint256 seed)
        internal
        returns (SearchHarness)
    {
        feed = new FormulaFeed(start, step, group, count, seed);
        return new SearchHarness(1);
    }

    /// @dev The highest round updated at or before `at`, by reading every round in turn.
    function _linearScan(uint256 at) internal view returns (uint256 found) {
        for (uint256 r = 1; r <= feed.count(); ++r) {
            uint256 u = feed.updatedAtOf(r);
            if (u != 0 && u <= at) found = r;
        }
    }

    /// @dev The same answer from the formula, for histories too long to scan.
    function _closedForm(uint256 at) internal view returns (uint256) {
        if (at < feed.start()) return 0;
        uint256 g = (at - feed.start()) / feed.step();
        if (feed.groupTime(g) > at) {
            if (g == 0) return 0;
            --g;
        }
        uint256 last = (g + 1) * feed.group();
        return last < feed.count() ? last : feed.count();
    }

    function _check(SearchHarness h, uint64 at, uint256 expected, uint64 cursor) internal view {
        uint64 cursorUpdatedAt = cursor == 0 ? 0 : uint64(feed.updatedAtOf(cursor));
        uint256 cursorAnswer = cursor == 0 ? 0 : 100e8 + cursor;
        (ExposureSeriesV2.Read read, uint64 round, int256 answer, uint64 updatedAt) =
            h.roundInForce(at, cursor, cursorUpdatedAt, cursorAnswer);
        if (expected == 0) {
            assertEq(uint8(read), uint8(ExposureSeriesV2.Read.NoRound), "no round in force");
            return;
        }
        assertEq(uint8(read), uint8(ExposureSeriesV2.Read.Found), "found");
        assertEq(round, expected, "round in force");
        assertEq(answer, int256(100e8 + expected), "answer of that round");
        assertEq(updatedAt, feed.updatedAtOf(expected), "update time of that round");
        assertLe(updatedAt, at, "updated at or before the boundary");
    }

    function testFuzz_searchEqualsLinearScan(
        uint256 count,
        uint256 group,
        uint256 step,
        uint256 seed,
        uint256 atSeed,
        uint256 cursorSeed
    ) public {
        count = bound(count, 1, 300);
        group = bound(group, 1, 4);
        step = bound(step, 1, 6 hours);
        uint256 start = 1_790_000_000;
        SearchHarness h = _harness(start, step, group, count, seed);
        uint256 groups = (count + group - 1) / group;
        uint64 at = uint64(bound(atSeed, start - step, start + (groups + 1) * step));
        uint256 expected = _linearScan(at);

        _check(h, at, expected, 0);
        if (expected != 0) _check(h, at, expected, uint64(bound(cursorSeed, 1, expected)));
    }

    /// Boundaries exactly on an update time, and on update times shared by several rounds.
    function testFuzz_boundaryOnAnUpdateTime(uint256 count, uint256 group, uint256 seed, uint256 pick) public {
        count = bound(count, 1, 200);
        group = bound(group, 1, 5);
        SearchHarness h = _harness(1_790_000_000, 1 hours, group, count, seed);
        uint256 r = bound(pick, 1, count);
        uint64 at = uint64(feed.updatedAtOf(r));
        uint256 expected = _linearScan(at);
        // Every round sharing the boundary's update time is in force; the last of them is the price.
        assertGe(expected, r);
        assertEq(feed.updatedAtOf(expected), at);
        _check(h, at, expected, 0);
        _check(h, at, expected, uint64(r));
        _check(h, at - 1, _linearScan(at - 1), 0);
    }

    function testFuzz_searchOverLongHistories(
        uint256 count,
        uint256 group,
        uint256 step,
        uint256 seed,
        uint256 atSeed,
        uint256 cursorSeed
    ) public {
        count = bound(count, 1, type(uint64).max);
        group = bound(group, 1, 1 << 20);
        step = bound(step, 1, 1 days);
        uint256 start = 1_790_000_000;
        SearchHarness h = _harness(start, step, group, count, seed);
        uint256 groups = (count - 1) / group + 1;
        uint256 end = start + (groups + 1) * step;
        if (end > type(uint64).max) end = type(uint64).max;
        uint64 at = uint64(bound(atSeed, start - 1, end));
        uint256 expected = _closedForm(at);

        _check(h, at, expected, 0);
        if (expected != 0) _check(h, at, expected, uint64(bound(cursorSeed, 1, expected)));
    }

    /// The whole id space of a phase: the gallop stops at 2^64 and the search still ends on the last round.
    function test_searchToTheEndOfThePhase() public {
        SearchHarness h = _harness(1_790_000_000, 1, 1 << 40, type(uint64).max, 7);
        uint64 at = type(uint64).max;
        _check(h, at, type(uint64).max, 0);
        _check(h, at, type(uint64).max, 1 << 63);
    }
}
