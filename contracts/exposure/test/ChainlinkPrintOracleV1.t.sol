// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ChainlinkPrintOracleV1} from "../src/ChainlinkPrintOracleV1.sol";
import {ExposureFactoryV1} from "../src/ExposureFactoryV1.sol";
import {ExposureSeriesV1} from "../src/ExposureSeriesV1.sol";
import {IFinalizedPrintOracle} from "../src/interfaces/IFinalizedPrintOracle.sol";
import {MockAggregator, MockStock} from "./doubles/Doubles.sol";

contract ChainlinkPrintOracleV1Test is Test {
    uint80 internal constant PHASE2 = uint80(2) << 64;

    MockAggregator internal feed;
    ChainlinkPrintOracleV1 internal oracle;
    uint64 internal at;

    function setUp() public {
        vm.warp(1_800_000_000);
        at = uint64(block.timestamp);
        feed = new MockAggregator();
        oracle = new ChainlinkPrintOracleV1(address(feed));
        // Rounds before, exactly at, and after the scheduled moment.
        feed.push(PHASE2 | 1, 250e8, at - 3 hours);
        feed.push(PHASE2 | 2, 252e8, at - 20 minutes);
        feed.push(PHASE2 | 3, 255e8, at + 10 minutes);
        vm.warp(at + 1 hours);
    }

    function _print(bool isOpen) internal view returns (IFinalizedPrintOracle.Print memory) {
        return oracle.getPrint(oracle.feedId(), at, isOpen);
    }

    function test_RecordsTheRoundInForce() public {
        oracle.record(at, true, PHASE2 | 2);
        IFinalizedPrintOracle.Print memory p = _print(true);
        assertEq(p.priceWad, 252e18, "8-decimal answer scaled to 18");
        assertEq(p.observedAt, at);
        assertEq(p.finalizedAt, block.timestamp);
        assertEq(_print(false).finalizedAt, 0, "the close at the same time is separate");
    }

    function test_RefusesARoundThatWasNotInForce() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPrintOracleV1.RoundNotInForce.selector, PHASE2 | 1));
        oracle.record(at, true, PHASE2 | 1); // superseded before the moment
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPrintOracleV1.RoundNotInForce.selector, PHASE2 | 3));
        oracle.record(at, true, PHASE2 | 3); // came after the moment
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPrintOracleV1.RoundNotInForce.selector, PHASE2 | 9));
        oracle.record(at, true, PHASE2 | 9); // does not exist
    }

    function test_RoundUpdatedExactlyAtTheMomentCounts() public {
        feed.push(PHASE2 | 4, 260e8, at + 2 hours);
        uint64 later = at + 10 minutes;
        vm.warp(later + 1 hours);
        oracle.record(later, false, PHASE2 | 3);
        assertEq(oracle.getPrint(oracle.feedId(), later, false).priceWad, 255e18);
    }

    function test_LatestRoundIsInForceWhenNothingFollows() public {
        uint64 quiet = at + 1 days; // a weekend: the feed holds its last value
        vm.warp(quiet + 1 hours);
        oracle.record(quiet, false, PHASE2 | 3);
        assertEq(oracle.getPrint(oracle.feedId(), quiet, false).priceWad, 255e18);
    }

    function test_FollowsIntoTheNextPhase() public {
        uint80 phase3 = uint80(3) << 64;
        feed.push(phase3 | 1, 256e8, at + 30 minutes);
        uint64 moment = at + 20 minutes;
        vm.warp(moment + 1 hours);
        oracle.record(moment, true, PHASE2 | 3);
        vm.warp(at + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPrintOracleV1.RoundNotInForce.selector, PHASE2 | 3));
        oracle.record(at + 40 minutes, true, PHASE2 | 3);
    }

    /// @notice Found in review on real Base data: while an old and a new feed run side by side, the
    ///         old phase's round no longer counts once the new phase has reported, so a moment has
    ///         one print and nobody can pick between two.
    function test_OverlappingFeedsGiveOnePrint() public {
        uint80 phase3 = uint80(3) << 64;
        feed.push(phase3 | 1, 251e8, at - 1 hours); // new feed reported before the moment
        feed.push(PHASE2 | 4, 260e8, at + 2 hours); // old feed still publishing
        feed.push(phase3 | 2, 253e8, at + 3 hours);
        vm.warp(at + 4 hours);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPrintOracleV1.RoundNotInForce.selector, PHASE2 | 2));
        oracle.record(at, true, PHASE2 | 2);
        oracle.record(at, true, phase3 | 1);
        assertEq(_print(true).priceWad, 251e18);
    }

    function test_ProxyOnANewFeedWithNoRoundsYet() public {
        feed.switchPhase(3);
        uint64 later = at + 30 minutes; // round 3 still in force
        vm.warp(later + 1 hours);
        oracle.record(later, true, PHASE2 | 3);
        assertEq(oracle.getPrint(oracle.feedId(), later, true).priceWad, 255e18);
    }

    function test_MissingRoundsReadAsZeros() public {
        feed.setMissingRoundsRevert(false);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPrintOracleV1.RoundNotInForce.selector, PHASE2 | 9));
        oracle.record(at, true, PHASE2 | 9);
        uint64 quiet = at + 1 days;
        vm.warp(quiet + 1 hours);
        oracle.record(quiet, false, PHASE2 | 3); // the latest: the zero-read round after it is no round
        assertEq(oracle.getPrint(oracle.feedId(), quiet, false).priceWad, 255e18);
    }

    function test_TooEarlyAndOnlyOnce() public {
        uint64 recent = uint64(block.timestamp - 30 minutes);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPrintOracleV1.TooEarly.selector, uint256(recent) + 1 hours));
        oracle.record(recent, true, PHASE2 | 3);
        oracle.record(at, true, PHASE2 | 2);
        vm.expectRevert(ChainlinkPrintOracleV1.AlreadyRecorded.selector);
        oracle.record(at, true, PHASE2 | 2);
    }

    function test_RefusesNonPositiveAnswers() public {
        feed.push(PHASE2 | 4, 0, at + 2 hours);
        uint64 moment = at + 3 hours;
        vm.warp(moment + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPrintOracleV1.BadAnswer.selector, int256(0)));
        oracle.record(moment, true, PHASE2 | 4);
    }

    function test_AnswersOnlyForItsOwnFeed() public {
        oracle.record(at, true, PHASE2 | 2);
        assertEq(oracle.getPrint(keccak256("other feed"), at, true).priceWad, 0);
        assertEq(oracle.feedId(), keccak256(abi.encode(block.chainid, address(feed))));
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
        oracle.record(schedule[0], false, PHASE2 | 2); // close 252
        oracle.record(schedule[1], true, PHASE2 | 3); // open 255
        oracle.record(schedule[2], false, PHASE2 | 3); // close 255, no move
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
