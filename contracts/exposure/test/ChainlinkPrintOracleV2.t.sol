// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {AfterHoursDemo} from "../script/AfterHoursDemo.s.sol";
import {ChainlinkPrintOracleV2} from "../src/ChainlinkPrintOracleV2.sol";
import {ExposureFactoryV1} from "../src/ExposureFactoryV1.sol";
import {ExposureSeriesV1} from "../src/ExposureSeriesV1.sol";
import {IFinalizedPrintOracle} from "../src/interfaces/IFinalizedPrintOracle.sol";
import {MockAggregator, MockStock} from "./doubles/Doubles.sol";

contract ChainlinkPrintOracleV2Test is Test {
    uint80 internal constant PHASE2 = uint80(2) << 64;
    uint80 internal constant PHASE3 = uint80(3) << 64;

    MockAggregator internal feed;
    ChainlinkPrintOracleV2 internal oracle;
    uint64 internal at;

    function setUp() public {
        vm.warp(1_800_000_000);
        at = uint64(block.timestamp);
        feed = new MockAggregator();
        oracle = new ChainlinkPrintOracleV2(address(feed)); // pins phase 2
        // Rounds before, and after, the scheduled moment.
        feed.push(PHASE2 | 1, 250e8, at - 3 hours);
        feed.push(PHASE2 | 2, 252e8, at - 20 minutes);
        feed.push(PHASE2 | 3, 255e8, at + 10 minutes);
        vm.warp(at + 1 hours);
    }

    function _print(uint64 moment, bool isOpen) internal view returns (IFinalizedPrintOracle.Print memory) {
        return oracle.getPrint(oracle.feedId(), moment, isOpen);
    }

    function test_PinsThePhaseItWasDeployedOn() public view {
        assertEq(oracle.phase(), 2);
        assertEq(oracle.roundIdOf(7), PHASE2 | 7);
        assertEq(oracle.feedId(), keccak256(abi.encode(block.chainid, address(feed), uint16(2))));
    }

    function test_RecordsTheRoundInForceAndItsSource() public {
        oracle.record(at, true, 2);
        IFinalizedPrintOracle.Print memory p = _print(at, true);
        assertEq(p.priceWad, 252e18, "8-decimal answer scaled to 18");
        assertEq(p.observedAt, at);
        assertEq(p.finalizedAt, block.timestamp);
        ChainlinkPrintOracleV2.Source memory source = oracle.sourceOf(at, true);
        assertEq(source.roundId, PHASE2 | 2);
        assertEq(source.updatedAt, at - 20 minutes);
        assertEq(_print(at, false).finalizedAt, 0, "the close at the same time is separate");
    }

    function test_RefusesARoundThatWasNotInForce() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPrintOracleV2.RoundNotInForce.selector, uint64(1)));
        oracle.record(at, true, 1); // superseded before the moment
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPrintOracleV2.RoundNotInForce.selector, uint64(3)));
        oracle.record(at, true, 3); // came after the moment
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPrintOracleV2.RoundNotInForce.selector, uint64(9)));
        oracle.record(at, true, 9); // does not exist
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPrintOracleV2.RoundNotInForce.selector, uint64(0)));
        oracle.record(at, true, 0);
    }

    function test_RoundUpdatedExactlyAtTheMomentCounts() public {
        feed.push(PHASE2 | 4, 260e8, at + 2 hours);
        uint64 later = at + 10 minutes;
        vm.warp(later + 1 hours);
        oracle.record(later, false, 3);
        assertEq(_print(later, false).priceWad, 255e18);
    }

    function test_LastRoundIsInForceOverAQuietWeekend() public {
        uint64 monday = at + 2 days;
        vm.warp(monday + 1 hours);
        oracle.record(monday, true, 3);
        assertEq(_print(monday, true).priceWad, 255e18);
    }

    /// @notice Found in the second review: with the proxy followed, a moment's print depended on
    ///         whether it was recorded before or after the proxy switched aggregators. Pinned to one
    ///         phase, the print is the same whenever it is recorded, and the new phase cannot be named.
    function test_ProxySwitchDoesNotChangeAPrint() public {
        feed.push(PHASE3 | 1, 249e8, at - 10 minutes); // new aggregator, already reporting
        uint256 snapshot = vm.snapshotState();
        oracle.record(at, true, 2); // recorded before the switch
        uint256 before = _print(at, true).priceWad;

        vm.revertToState(snapshot);
        feed.setPhaseId(3); // the proxy switches
        vm.warp(block.timestamp + 30 minutes);
        oracle.record(at, true, 2); // recorded after it
        assertEq(_print(at, true).priceWad, before);
        assertEq(before, 252e18);
    }

    /// @notice A retired or stopped feed goes stale and its prints are refused, so the series ends at
    ///         its last applied values rather than recording a frozen price for ever.
    function test_RefusesARoundOlderThanTheStalenessLimit() public {
        uint64 lastUpdate = at + 10 minutes; // round 3, the phase's last
        uint64 limit = lastUpdate + 84 hours;
        vm.warp(limit + 1 + 1 hours);
        oracle.record(limit, true, 3); // exactly 84 hours old: still counts
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPrintOracleV2.RoundTooOld.selector, uint256(lastUpdate)));
        oracle.record(limit + 1, false, 3);
    }

    /// @notice Found in review: the longest normal gap in the feed's history (Labor Day weekend,
    ///         75.9 hours) still prices, so the limit only refuses a stopped or retired feed.
    function test_HolidayWeekendGapStillPrices() public {
        uint64 tuesdayOpen = at + 10 minutes + 75.9 hours;
        vm.warp(tuesdayOpen + 1 hours);
        oracle.record(tuesdayOpen, true, 3);
        assertEq(_print(tuesdayOpen, true).priceWad, 255e18);
    }

    /// @notice Found in review: the keeper stops on a dead feed instead of failing, and once the
    ///         print's recording deadline has passed it ends the series at its last values.
    function test_KeeperEndsTheSeriesOnADeadFeed() public {
        MockStock stock = new MockStock();
        uint64[] memory schedule = new uint64[](3);
        (schedule[0], schedule[1], schedule[2]) = (at, at + 4 days, at + 4 days + 6.5 hours);
        ExposureSeriesV1 series = new ExposureSeriesV1(_terms(address(stock), schedule, 2 days));
        AfterHoursDemo keeper = new AfterHoursDemo();
        keeper.recordAndSettle(series); // first close, from round 2
        assertEq(series.settled(), 1);

        vm.warp(schedule[1] + 1 hours); // the feed has not updated since round 3: too old
        keeper.recordAndSettle(series);
        assertEq(uint8(series.status()), uint8(ExposureSeriesV1.Status.Active), "waits before the deadline");

        vm.warp(schedule[1] + 2 days + 1);
        keeper.recordAndSettle(series);
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV1.EndReason.MissingPrint));
        assertEq(series.lastPriceWad(), 252e18);
    }

    function _terms(address stock, uint64[] memory schedule, uint64 delay)
        internal
        view
        returns (ExposureSeriesV1.Terms memory)
    {
        return ExposureSeriesV1.Terms({
            asset: stock,
            oracle: address(oracle),
            feedId: oracle.feedId(),
            termsHash: bytes32(0),
            maxReportDelay: delay,
            depositCap: 1_000_000e8,
            boundaries: schedule,
            overnightName: "N",
            overnightSymbol: "N",
            sessionName: "S",
            sessionSymbol: "S"
        });
    }

    function test_TooEarlyAndOnlyOnce() public {
        uint64 recent = uint64(block.timestamp - 30 minutes);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPrintOracleV2.TooEarly.selector, uint256(recent) + 1 hours));
        oracle.record(recent, true, 3);
        oracle.record(at, true, 2);
        vm.expectRevert(ChainlinkPrintOracleV2.AlreadyRecorded.selector);
        oracle.record(at, true, 2);
    }

    function test_RefusesNonPositiveAnswers() public {
        feed.push(PHASE2 | 4, 0, at + 2 hours);
        uint64 moment = at + 3 hours;
        vm.warp(moment + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPrintOracleV2.BadAnswer.selector, int256(0)));
        oracle.record(moment, true, 4);
    }

    function test_AnswersOnlyForItsOwnFeed() public {
        oracle.record(at, true, 2);
        assertEq(oracle.getPrint(keccak256("other feed"), at, true).priceWad, 0);
    }

    /// @notice The keeper's search finds exactly the round in force, across many rounds and moments.
    function testFuzz_KeeperFindsTheRoundInForce(uint8 count, uint32 offset) public {
        MockAggregator many = new MockAggregator();
        ChainlinkPrintOracleV2 o = new ChainlinkPrintOracleV2(address(many));
        uint256 n = bound(count, 1, 200);
        uint256 start = 1_700_000_000;
        for (uint64 i = 1; i <= n; ++i) {
            many.push(PHASE2 | i, int256(uint256(100e8 + i)), start + i * 7 minutes);
        }
        uint64 moment = uint64(start + 7 minutes + bound(offset, 0, n * 7 minutes + 1 days));
        uint64 expected = uint64((moment - start) / 7 minutes);
        if (expected > n) expected = uint64(n);
        assertEq(new AfterHoursDemo().roundInForce(o, moment), expected);
    }

    /// @notice A series settles end to end from recorded feed prints.
    function test_SeriesSettlesFromFeedPrints() public {
        MockStock stock = new MockStock();
        uint64[] memory schedule = new uint64[](3);
        (schedule[0], schedule[1], schedule[2]) = (at, at + 30 minutes, at + 2 hours);
        ExposureSeriesV1 series = new ExposureSeriesV1(
            ExposureSeriesV1.Terms({
                asset: address(stock),
                oracle: address(oracle),
                feedId: oracle.feedId(),
                termsHash: bytes32(0),
                maxReportDelay: 2 days,
                depositCap: 1_000_000e8,
                boundaries: schedule,
                overnightName: "N",
                overnightSymbol: "N",
                sessionName: "S",
                sessionSymbol: "S"
            })
        );
        vm.warp(at + 3 hours + 1);
        oracle.record(schedule[0], false, 2); // close 252
        oracle.record(schedule[1], true, 3); // open 255
        oracle.record(schedule[2], false, 3); // close 255, no move
        series.settle();
        series.settle();
        series.settle();
        assertEq(series.overnightLedgerWad(), 129e18, "126 + 3 overnight");
        assertEq(series.sessionLedgerWad(), 126e18);
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV1.EndReason.Maturity));
    }
}

contract ExposureFactoryV1Test is Test {
    address internal safe = makeAddr("governance safe");
    ExposureFactoryV1 internal factory;

    function setUp() public {
        factory = new ExposureFactoryV1(safe);
    }

    function _terms() internal returns (ExposureSeriesV1.Terms memory terms) {
        uint64[] memory schedule = new uint64[](3);
        (schedule[0], schedule[1], schedule[2]) = (100, 200, 300);
        terms = ExposureSeriesV1.Terms({
            asset: address(new MockStock()),
            oracle: makeAddr("oracle"),
            feedId: keccak256("feed"),
            termsHash: keccak256("terms"),
            maxReportDelay: 1 hours,
            depositCap: 1_000_000e8,
            boundaries: schedule,
            overnightName: "N",
            overnightSymbol: "N",
            sessionName: "S",
            sessionSymbol: "S"
        });
    }

    function test_OnlyOwnerCreatesAndSeriesAreListed() public {
        ExposureSeriesV1.Terms memory terms = _terms();
        vm.expectRevert();
        factory.createSeries(terms);

        vm.prank(safe);
        ExposureSeriesV1 series = factory.createSeries(terms);
        assertTrue(factory.isSeries(address(series)));
        assertEq(series.asset(), terms.asset);
        assertEq(series.termsHash(), terms.termsHash);
        assertEq(series.overnight().series(), address(series));
        assertFalse(factory.isSeries(makeAddr("other")));
    }
}
