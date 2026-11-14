// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";

import {ExposureFactoryV2} from "../src/ExposureFactoryV2.sol";
import {ExposureSeriesV2} from "../src/ExposureSeriesV2.sol";
import {MockFeed} from "./doubles/Doubles.sol";
import {Fixture} from "./Fixture.sol";

contract ExposureFactoryV2Test is Fixture {
    // ---------------------------------------------------------------------------------------------
    // Calendar (expected times from Python's America/New_York zone)
    // ---------------------------------------------------------------------------------------------

    function test_calendarMatchesNewYork() public view {
        // 26-30 Oct 2026, summer time.
        _assertWeek(
            2965,
            _times(
                [
                    uint256(1792785600),
                    1793021400,
                    1793044800,
                    1793107800,
                    1793131200,
                    1793194200,
                    1793217600,
                    1793280600,
                    1793304000,
                    1793367000,
                    1793390400
                ]
            )
        );
        // 2-6 Nov 2026: the clocks went back on Sunday 1 Nov, so the Friday close is 20:00 UTC and the
        // Monday open 14:30 UTC.
        _assertWeek(
            2966,
            _times(
                [
                    uint256(1793390400),
                    1793629800,
                    1793653200,
                    1793716200,
                    1793739600,
                    1793802600,
                    1793826000,
                    1793889000,
                    1793912400,
                    1793975400,
                    1793998800
                ]
            )
        );
        // 23-27 Nov 2026: closed for Thanksgiving, early close on the Friday.
        _assertWeek(
            2969,
            _times(
                [
                    uint256(1795208400),
                    1795444200,
                    1795467600,
                    1795530600,
                    1795554000,
                    1795617000,
                    1795640400,
                    1795789800,
                    1795802400
                ]
            )
        );
        // 21-25 Dec 2026: early close on Christmas Eve, closed on Christmas Day.
        _assertWeek(
            2973,
            _times(
                [
                    uint256(1797627600),
                    1797863400,
                    1797886800,
                    1797949800,
                    1797973200,
                    1798036200,
                    1798059600,
                    1798122600,
                    1798135200
                ]
            )
        );
        // 28 Dec 2026 - 1 Jan 2027: starts from the Christmas Eve early close; closed on New Year's Day.
        _assertWeek(
            2974,
            _times(
                [
                    uint256(1798135200),
                    1798468200,
                    1798491600,
                    1798554600,
                    1798578000,
                    1798641000,
                    1798664400,
                    1798727400,
                    1798750800
                ]
            )
        );
        // 4-8 Jan 2027: starts from the Thursday 31 Dec close.
        assertEq(factory.startOf(2975), 1798750800);
        // 15-19 Mar 2027: the clocks went forward on Sunday 14 Mar, so the Friday close is 21:00 UTC
        // and the Monday open 13:30 UTC.
        _assertWeek(
            2985,
            _times(
                [
                    uint256(1804885200),
                    1805117400,
                    1805140800,
                    1805203800,
                    1805227200,
                    1805290200,
                    1805313600,
                    1805376600,
                    1805400000,
                    1805463000,
                    1805486400
                ]
            )
        );
    }

    function test_consecutiveSeriesShareABoundary() public view {
        for (uint256 w = 2960; w < 3020; ++w) {
            uint64[] memory times = factory.boundariesOf(w);
            assertEq(times[times.length - 1], factory.startOf(w + 1));
        }
    }

    /// The federal rule for every year to 2100: second Sunday of March to first Sunday of November.
    function testFuzz_daylightSavingFollowsTheRule(uint256 year) public view {
        year = bound(year, 2026, 2100);
        uint256 starts = DateTimeLib.dateToEpochDay(year, 3, 8);
        while (DateTimeLib.weekday(starts * 1 days) != DateTimeLib.SUN) {
            ++starts;
        }
        uint256 ends = DateTimeLib.dateToEpochDay(year, 11, 1);
        while (DateTimeLib.weekday(ends * 1 days) != DateTimeLib.SUN) {
            ++ends;
        }
        assertFalse(factory.isDaylightSaving(starts - 1));
        assertTrue(factory.isDaylightSaving(starts));
        assertTrue(factory.isDaylightSaving(ends - 1));
        assertFalse(factory.isDaylightSaving(ends));
        assertFalse(factory.isDaylightSaving(DateTimeLib.dateToEpochDay(year, 1, 15)));
        assertTrue(factory.isDaylightSaving(DateTimeLib.dateToEpochDay(year, 7, 15)));
        // 09:30 New York is 13:30 UTC in summer and 14:30 UTC in winter.
        assertEq(factory.openAt(starts + 1) % 1 days, 13.5 hours);
        assertEq(factory.openAt(starts - 2) % 1 days, 14.5 hours);
    }

    function test_currentWeekTurnsAnHourAfterTheLastClose() public {
        vm.warp(b[0] + 1 hours - 1);
        assertEq(factory.currentWeek(), WEEK - 1);
        vm.warp(b[0] + 1 hours);
        assertEq(factory.currentWeek(), WEEK);
        vm.warp(b[5]);
        assertEq(factory.currentWeek(), WEEK);
        vm.warp(uint256(b[10]) + 1 hours - 1);
        assertEq(factory.currentWeek(), WEEK);
        vm.warp(uint256(b[10]) + 1 hours);
        assertEq(factory.currentWeek(), WEEK + 1);
        // Thanksgiving week ends at the Friday early close, 18:00 UTC.
        vm.warp(1795802400 + 1 hours - 1);
        assertEq(factory.currentWeek(), WEEK + 1);
        vm.warp(1795802400 + 1 hours);
        assertEq(factory.currentWeek(), WEEK + 2);
        // Over a weekend the coming week is current.
        vm.warp(1795802400 + 2 days);
        assertEq(factory.currentWeek(), WEEK + 2);
    }

    // ---------------------------------------------------------------------------------------------
    // Opening
    // ---------------------------------------------------------------------------------------------

    function test_openRules() public {
        address predicted = factory.predictSeries(WEEK);
        assertEq(predicted.code.length, 0);

        vm.warp(b[0] + 1 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(ExposureFactoryV2.NotCurrentWeek.selector, WEEK, WEEK - 1));
        factory.open(WEEK);

        vm.warp(b[0] + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(ExposureFactoryV2.NotCurrentWeek.selector, WEEK + 1, WEEK));
        factory.open(WEEK + 1);

        vm.prank(bob);
        _use(factory.open(WEEK));
        assertEq(address(series), predicted);
        assertEq(address(factory.seriesOf(WEEK)), predicted);
        assertTrue(factory.isSeries(predicted));
        assertEq(series.factory(), address(factory));
        assertEq(series.week(), WEEK);
        assertEq(series.asset(), address(stock));
        assertEq(series.feed(), address(feed));
        assertEq(series.phase(), PHASE);
        assertEq(series.depositCap(), 1_000_000 * TOKEN);
        assertEq(series.termsHash(), keccak256("terms"));
        assertEq(series.boundaryCount(), 11);
        assertEq(series.maturityAt(), b[10]);
        assertEq(overnight.decimals(), 8);
        assertEq(overnight.symbol(), "MOCKc-AH-1120");
        assertEq(session.name(), "MOCKc Market-hours to 20 Nov 2026");

        vm.expectRevert(abi.encodeWithSelector(ExposureFactoryV2.AlreadyOpen.selector, predicted));
        factory.open(WEEK);

        vm.warp(uint256(b[10]) + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(ExposureFactoryV2.NotCurrentWeek.selector, WEEK, WEEK + 1));
        factory.open(WEEK);
    }

    /// Whoever opens the week, and whenever in the week, the series is the same one.
    function test_openerAndMomentDoNotMatter() public {
        _pushWeek(_example());
        uint256 snap = vm.snapshotState();
        vm.warp(b[0] + 1 hours);
        vm.prank(alice);
        ExposureSeriesV2 early = factory.open(WEEK);
        bytes32 earlyTerms = _terms(early);
        vm.revertToState(snap);

        vm.warp(b[7]);
        vm.prank(bob);
        ExposureSeriesV2 late = factory.open(WEEK);
        assertEq(address(late), address(early));
        assertEq(_terms(late), earlyTerms);
        // The late opener's first settle catches up on every boundary since the start.
        late.settle();
        assertEq(late.settled(), 7);
    }

    function test_depositOpensOnceThenJoins() public {
        _pushWeek(_example());
        _deposit(alice, TOKEN);
        address first = address(series);
        _deposit(bob, 2 * TOKEN);
        assertEq(address(series), first);
        assertEq(overnight.balanceOf(bob), 2 * TOKEN);
        assertEq(stock.balanceOf(address(factory)), 0, "the factory keeps nothing");
        assertEq(stock.allowance(address(factory), first), 0);
    }

    function test_depositForAnotherWeekFails() public {
        _pushWeek(_example());
        _deposit(alice, TOKEN);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ExposureFactoryV2.NotCurrentWeek.selector, WEEK + 1, WEEK));
        factory.deposit(WEEK + 1, TOKEN);

        // A deposit sent for this week that lands after it turned over is refused, not moved.
        vm.warp(uint256(b[10]) + 1 hours);
        vm.prank(alice);
        vm.expectRevert(ExposureSeriesV2.NotActive.selector);
        factory.deposit(WEEK, TOKEN);
    }

    // ---------------------------------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------------------------------

    function test_ownerOnly() public {
        uint256[] memory days_ = new uint256[](0);
        vm.startPrank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setPaused(true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setTemplate(_template());
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setDays(days_, ExposureFactoryV2.DayKind.Closed);
        vm.stopPrank();
    }

    function test_pauseStopsOnlyNewSeries() public {
        _pushWeek(_example());
        _deposit(alice, 10 * TOKEN);
        vm.prank(safe);
        factory.setPaused(true);

        _deposit(bob, TOKEN); // an open series keeps taking deposits
        _redeem(alice, TOKEN, TOKEN);
        _warpPast(10);
        vm.prank(alice);
        vm.expectRevert(ExposureFactoryV2.OpeningPaused.selector);
        factory.deposit(WEEK + 1, TOKEN);
        assertEq(_redeem(alice, 9 * TOKEN, 0), 9 * TOKEN * 99 / 212);

        vm.prank(safe);
        factory.setPaused(false);
        factory.open(WEEK + 1);
    }

    function test_daysOnlyChangeForLaterWeeks() public {
        vm.warp(b[0] + 1 hours);
        uint256 monday = factory.mondayOf(WEEK);
        uint256[] memory days_ = new uint256[](1);

        days_[0] = monday + 4; // this week's Friday
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ExposureFactoryV2.DayLocked.selector, monday + 4));
        factory.setDays(days_, ExposureFactoryV2.DayKind.Closed);

        days_[0] = monday + 12; // a Saturday
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ExposureFactoryV2.NotAWeekday.selector, monday + 12));
        factory.setDays(days_, ExposureFactoryV2.DayKind.Closed);

        // Next Wednesday (Thanksgiving week) closes early, and Thanksgiving opens again.
        uint256[] memory two = new uint256[](2);
        (two[0], two[1]) = (monday + 9, THANKSGIVING);
        vm.prank(safe);
        factory.setDays(two, ExposureFactoryV2.DayKind.EarlyClose);
        uint64[] memory times = factory.boundariesOf(WEEK + 1);
        assertEq(times.length, 11);
        assertEq(times[6], factory.openAt(monday + 9) + 3.5 hours);
        _assertWeek(WEEK, b); // this week is untouched
    }

    /// The owner closes a whole future week (as in September 2001): that week has no series and the
    /// next one starts from the last close before it.
    function test_closedWeekIsSkipped() public {
        vm.warp(b[0] + 1 hours);
        uint256[] memory days_ = new uint256[](4);
        uint256 monday = factory.mondayOf(WEEK + 1);
        (days_[0], days_[1], days_[2], days_[3]) = (monday, monday + 1, monday + 2, monday + 4);
        vm.prank(safe);
        factory.setDays(days_, ExposureFactoryV2.DayKind.Closed); // Thursday is Thanksgiving already

        vm.warp(uint256(b[10]) + 1 hours);
        assertEq(factory.currentWeek(), WEEK + 2);
        assertEq(factory.startOf(WEEK + 2), b[10]);
    }

    /// A closure longer than two weeks (the market shut for months in 1914) still leaves the
    /// calendar working, and the owner can open the days again.
    function test_longClosureKeepsTheCalendarWorking() public {
        vm.warp(b[0] + 1 hours);
        uint256 first = factory.mondayOf(WEEK + 1);
        uint256[] memory days_ = new uint256[](15);
        for (uint256 i; i < 15; ++i) {
            days_[i] = first + (i / 5) * 7 + (i % 5);
        }
        vm.prank(safe);
        factory.setDays(days_, ExposureFactoryV2.DayKind.Closed);
        assertEq(factory.startOf(WEEK + 4), b[10], "three closed weeks: the next series starts at this close");

        // The coming week is closed, so the week after it is current; the third can still reopen.
        vm.warp(uint256(b[10]) + 1 hours);
        assertEq(factory.currentWeek(), WEEK + 2);
        uint256[] memory third = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            third[i] = days_[10 + i];
        }
        vm.prank(safe);
        factory.setDays(third, ExposureFactoryV2.DayKind.Regular);
        assertEq(factory.boundariesOf(WEEK + 3).length, 11);
        assertEq(factory.startOf(WEEK + 3), b[10]);
    }

    function test_templateOnlyReachesSeriesNotYetOpen() public {
        _pushWeek(_example());
        _deposit(alice, 10 * TOKEN);
        bytes32 terms = _terms(series);

        ExposureFactoryV2.Template memory t = _template();
        MockFeed other = new MockFeed();
        t.feed = address(other);
        t.depositCap = 1;
        t.termsHash = keccak256("new terms");
        t.ticker = "NEWc";
        vm.startPrank(safe);
        factory.setTemplate(t);
        factory.setPaused(true);
        vm.stopPrank();

        assertEq(_terms(series), terms, "the open series keeps everything");
        _deposit(bob, 5 * TOKEN);
        _warpPast(10);
        series.settle();
        assertEq(series.overnightLedgerWad(), 99e18, "still priced from its own feed");

        vm.prank(safe);
        factory.setPaused(false);
        ExposureSeriesV2 next = factory.open(WEEK + 1);
        assertEq(next.feed(), address(other));
        assertEq(next.depositCap(), 1);
        assertEq(next.termsHash(), keccak256("new terms"));
        assertEq(next.overnight().symbol(), "NEWc-AH-1127");
    }

    function test_templateIsChecked() public {
        ExposureFactoryV2.Template memory t = _template();
        vm.startPrank(safe);

        t.phase = 7;
        vm.expectRevert(abi.encodeWithSelector(ExposureFactoryV2.PhaseNotFound.selector, uint16(7)));
        factory.setTemplate(t);
        t.phase = PHASE;

        t.ticker = "";
        vm.expectRevert(ExposureFactoryV2.BadTicker.selector);
        factory.setTemplate(t);
        t.ticker = "THIRTEENCHARS";
        vm.expectRevert(ExposureFactoryV2.BadTicker.selector);
        factory.setTemplate(t);
        t.ticker = "MOCKc";

        t.depositCap = 0;
        vm.expectRevert(ExposureFactoryV2.ZeroAmount.selector);
        factory.setTemplate(t);
        t.depositCap = 1;

        t.asset = address(0);
        vm.expectRevert(ExposureFactoryV2.ZeroAddress.selector);
        factory.setTemplate(t);
        t.asset = address(stock);

        vm.mockCall(address(feed), abi.encodeWithSignature("decimals()"), abi.encode(uint8(19)));
        vm.expectRevert(abi.encodeWithSelector(ExposureFactoryV2.BadFeedDecimals.selector, uint8(19)));
        factory.setTemplate(t);
        vm.stopPrank();
    }

    /// Chainlink moves the proxy to a new aggregator mid-week. The open series stays on its phase and,
    /// once that phase has been silent too long, ends where it stood; the owner points the next
    /// series at the new phase.
    function test_phaseMigration() public {
        _push(b[0] - 1 hours, 200e8);
        _push(b[1] - 1 hours, 210e8);
        _deposit(alice, 10 * TOKEN);
        feed.addPhase(3);
        feed.setRound(3, 1, 500e8, b[9]); // the new phase's prices never reach this series

        _warpPast(10);
        series.settle();
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV2.EndReason.StaleFeed));
        assertEq(series.lastPriceWad(), 210e18);
        assertEq(_redeem(alice, 10 * TOKEN, 0), 10 * TOKEN * 110 / 210);

        ExposureFactoryV2.Template memory t = _template();
        t.phase = 3;
        vm.prank(safe);
        factory.setTemplate(t);
        ExposureSeriesV2 next = factory.open(WEEK + 1);
        assertEq(next.phase(), 3);
        next.settle();
        assertEq(next.lastPriceWad(), 500e18);
    }

    /// A holiday week settles through its shorter calendar and matures at the early close.
    function test_thanksgivingWeekEndToEnd() public {
        uint64[] memory times = factory.boundariesOf(WEEK + 1);
        assertEq(times.length, 9);
        for (uint256 i; i < times.length; ++i) {
            _push(times[i] - 1 minutes, int256(200e8 + i * 1e8));
        }
        vm.warp(times[0] + 1 hours);
        vm.prank(alice);
        ExposureSeriesV2 s = factory.deposit(WEEK + 1, TOKEN);
        vm.warp(times[8] + 1 hours);
        assertEq(s.settle(), 8);
        assertEq(uint8(s.endReason()), uint8(ExposureSeriesV2.EndReason.Maturity));
        assertEq(s.lastPriceWad(), 208e18);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _assertWeek(uint256 week, uint64[] memory expected) internal view {
        uint64[] memory got = factory.boundariesOf(week);
        assertEq(got.length, expected.length, "boundary count");
        for (uint256 i; i < got.length; ++i) {
            assertEq(got[i], expected[i]);
        }
    }

    function _times(uint256[11] memory t) internal pure returns (uint64[] memory out) {
        out = new uint64[](11);
        for (uint256 i; i < 11; ++i) {
            out[i] = uint64(t[i]);
        }
    }

    function _times(uint256[9] memory t) internal pure returns (uint64[] memory out) {
        out = new uint64[](9);
        for (uint256 i; i < 9; ++i) {
            out[i] = uint64(t[i]);
        }
    }

    function _terms(ExposureSeriesV2 s) internal view returns (bytes32) {
        uint64[] memory times = new uint64[](s.boundaryCount());
        for (uint256 i; i < times.length; ++i) {
            times[i] = s.boundaries(i);
        }
        return keccak256(
            abi.encode(
                s.asset(),
                s.feed(),
                s.phase(),
                s.depositCap(),
                s.termsHash(),
                times,
                s.overnight().name(),
                s.overnight().symbol(),
                s.session().name(),
                s.session().symbol()
            )
        );
    }
}
