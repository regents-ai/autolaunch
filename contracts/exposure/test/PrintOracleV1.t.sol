// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ExposureFactoryV1} from "../src/ExposureFactoryV1.sol";
import {ExposureSeriesV1} from "../src/ExposureSeriesV1.sol";
import {PrintOracleV1} from "../src/PrintOracleV1.sol";
import {IFinalizedPrintOracle} from "../src/interfaces/IFinalizedPrintOracle.sol";
import {MockStock} from "./doubles/Doubles.sol";

contract PrintOracleV1Test is Test {
    bytes32 internal constant FEED = keccak256("feed");
    uint128 internal constant PRICE = 160e18;

    PrintOracleV1 internal oracle;
    address internal r1 = makeAddr("reporter1");
    address internal r2 = makeAddr("reporter2");
    address internal r3 = makeAddr("reporter3");
    uint64 internal at;

    function setUp() public {
        vm.warp(1_800_000_000);
        at = uint64(block.timestamp - 1 hours);
        address[] memory reporters = new address[](3);
        (reporters[0], reporters[1], reporters[2]) = (r1, r2, r3);
        oracle = new PrintOracleV1(reporters, 2);
    }

    function _report(address reporter, uint128 price) internal {
        vm.prank(reporter);
        oracle.report(FEED, at, false, price, keccak256(abi.encode(reporter, price)));
    }

    function _print() internal view returns (IFinalizedPrintOracle.Print memory) {
        return oracle.getPrint(FEED, at, false);
    }

    function test_FinalWhenThresholdAgrees() public {
        _report(r1, PRICE);
        assertEq(_print().finalizedAt, 0, "one vote is not enough");
        vm.warp(block.timestamp + 5 minutes);
        _report(r2, PRICE);
        IFinalizedPrintOracle.Print memory p = _print();
        assertEq(p.priceWad, PRICE);
        assertEq(p.observedAt, at);
        assertEq(p.finalizedAt, block.timestamp, "stamped when the deciding vote landed");
        assertEq(oracle.getPrint(FEED, at, true).finalizedAt, 0, "the open at the same time is separate");
    }

    function test_DisagreementDoesNotFinalize() public {
        _report(r1, PRICE);
        _report(r2, PRICE + 1);
        assertEq(_print().finalizedAt, 0);
        _report(r3, PRICE + 1);
        assertEq(_print().priceWad, PRICE + 1);
    }

    /// @notice A reporter can fix its vote before the print is final; the old vote stops counting.
    function test_ReporterRevisesVoteBeforeFinal() public {
        _report(r1, PRICE + 1); // typo
        _report(r2, PRICE);
        assertEq(_print().finalizedAt, 0);
        _report(r1, PRICE);
        assertEq(_print().priceWad, PRICE);
        assertEq(oracle.votesFor(oracle.printKey(FEED, at, false), PRICE + 1), 0);
    }

    function test_RevisedAwayVoteNoLongerCounts() public {
        _report(r1, PRICE);
        _report(r1, PRICE + 1);
        _report(r2, PRICE);
        assertEq(_print().finalizedAt, 0, "r1 no longer backs PRICE");
    }

    function test_FinalPrintNeverChanges() public {
        _report(r1, PRICE);
        _report(r2, PRICE);
        uint64 finalizedAt = _print().finalizedAt;
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(PrintOracleV1.AlreadyFinal.selector);
        _report(r3, PRICE + 5);
        assertEq(_print().priceWad, PRICE);
        assertEq(_print().finalizedAt, finalizedAt);
    }

    function test_RejectsBadReports() public {
        vm.expectRevert(PrintOracleV1.NotReporter.selector);
        _report(makeAddr("stranger"), PRICE);
        vm.expectRevert(PrintOracleV1.ZeroPrice.selector);
        _report(r1, 0);
        _report(r1, PRICE);
        vm.expectRevert(PrintOracleV1.AlreadyVoted.selector);
        _report(r1, PRICE);
        uint64 future = uint64(block.timestamp + 1);
        vm.prank(r2);
        vm.expectRevert(abi.encodeWithSelector(PrintOracleV1.NotYetHappened.selector, future));
        oracle.report(FEED, future, true, PRICE, bytes32(0));
    }

    function test_ConstructorNeedsAMajorityOfDistinctReporters() public {
        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (r1, r2, r3);
        vm.expectRevert(PrintOracleV1.BadThreshold.selector);
        new PrintOracleV1(three, 1);
        vm.expectRevert(PrintOracleV1.BadThreshold.selector);
        new PrintOracleV1(three, 4);
        address[] memory duplicate = new address[](2);
        (duplicate[0], duplicate[1]) = (r1, r1);
        vm.expectRevert(PrintOracleV1.BadReporters.selector);
        new PrintOracleV1(duplicate, 2);
        vm.expectRevert(PrintOracleV1.BadReporters.selector);
        new PrintOracleV1(new address[](0), 1);
        address[] memory withZero = new address[](1);
        vm.expectRevert(PrintOracleV1.BadReporters.selector);
        new PrintOracleV1(withZero, 1);
    }

    /// @notice The series reads this oracle within its gas budget and accepts its prints.
    function test_SeriesSettlesFromQuorumPrints() public {
        MockStock stock = new MockStock();
        uint64[] memory schedule = new uint64[](3);
        (schedule[0], schedule[1], schedule[2]) = (at, at + 1 hours, at + 2 hours);
        ExposureSeriesV1 series = new ExposureSeriesV1(
            ExposureSeriesV1.Terms({
                asset: address(stock),
                oracle: address(oracle),
                feedId: FEED,
                termsHash: bytes32(0),
                maxReportDelay: 6 hours,
                depositCap: 1_000_000e8,
                boundaries: schedule,
                overnightName: "N",
                overnightSymbol: "N",
                sessionName: "S",
                sessionSymbol: "S"
            })
        );
        _report(r1, PRICE);
        _report(r3, PRICE);
        series.settle();
        assertEq(series.overnightLedgerWad(), PRICE / 2);
        vm.warp(at + 1 hours + 10 minutes);
        vm.prank(r1);
        oracle.report(FEED, at + 1 hours, true, 170e18, bytes32(0));
        vm.prank(r2);
        oracle.report(FEED, at + 1 hours, true, 170e18, bytes32(0));
        series.settle();
        assertEq(series.overnightLedgerWad(), 90e18);
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
