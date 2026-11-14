// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ExposureFactoryV2} from "../src/ExposureFactoryV2.sol";
import {ExposureLegV2} from "../src/ExposureLegV2.sol";
import {ExposureSeriesV2} from "../src/ExposureSeriesV2.sol";
import {MockFeed, MockStock} from "./doubles/Doubles.sol";

/// @notice A factory on a mock stock and a mock Chainlink proxy, with the US market calendar for the
///         end of 2026, and the series for the week of Monday 16 to Friday 20 November 2026:
///         the Friday 13 November close, then five opens and closes (New York standard time).
abstract contract Fixture is Test {
    uint256 internal constant TOKEN = 1e8;
    uint16 internal constant PHASE = 2;
    /// Monday 16 November 2026.
    uint256 internal constant WEEK = 2968;
    /// Days since 1970-01-01: 2026-11-26 Thanksgiving, 2026-12-25 Christmas, 2027-01-01 New Year's Day.
    uint256 internal constant THANKSGIVING = 20_783;
    uint256 internal constant CHRISTMAS = 20_812;
    uint256 internal constant NEW_YEAR = 20_819;
    /// 2026-11-27 and 2026-12-24 close at 13:00 New York.
    uint256 internal constant BLACK_FRIDAY = 20_784;
    uint256 internal constant CHRISTMAS_EVE = 20_811;

    address internal safe = makeAddr("governance safe");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockStock internal stock;
    MockFeed internal feed;
    ExposureFactoryV2 internal factory;
    ExposureSeriesV2 internal series;
    ExposureLegV2 internal overnight;
    ExposureLegV2 internal session;
    uint64[] internal b;
    uint64 internal nextRound;

    function setUp() public virtual {
        stock = new MockStock();
        feed = new MockFeed();
        factory = _newFactory();
        b = factory.boundariesOf(WEEK);
        vm.warp(b[0] - 1 days);

        address[2] memory holders = [alice, bob];
        for (uint256 i; i < holders.length; ++i) {
            stock.mint(holders[i], 1_000 * TOKEN);
            vm.prank(holders[i]);
            stock.approve(address(factory), type(uint256).max);
        }
    }

    function _template() internal view returns (ExposureFactoryV2.Template memory) {
        return ExposureFactoryV2.Template({
            asset: address(stock),
            feed: address(feed),
            phase: PHASE,
            depositCap: 1_000_000 * TOKEN,
            termsHash: keccak256("terms"),
            ticker: "MOCKc"
        });
    }

    function _newFactory() internal returns (ExposureFactoryV2) {
        uint256[] memory closed = new uint256[](3);
        (closed[0], closed[1], closed[2]) = (THANKSGIVING, CHRISTMAS, NEW_YEAR);
        uint256[] memory early = new uint256[](2);
        (early[0], early[1]) = (BLACK_FRIDAY, CHRISTMAS_EVE);
        return new ExposureFactoryV2(safe, _template(), closed, early);
    }

    /// @dev A round of the pinned phase updated at `at` (push rounds in time order).
    function _push(uint256 at, int256 answer) internal {
        feed.setRound(PHASE, ++nextRound, answer, at);
    }

    /// @dev One round five minutes before each of the week's boundaries, in whole dollars.
    function _pushWeek(uint256[11] memory dollars) internal {
        for (uint256 i; i < dollars.length; ++i) {
            _push(b[i] - 5 minutes, int256(dollars[i] * 1e8));
        }
    }

    /// @dev The worked example: 200 at the Friday close, then each day's open and close.
    function _example() internal pure returns (uint256[11] memory) {
        return [uint256(200), 210, 205, 200, 220, 230, 225, 215, 216, 210, 212];
    }

    /// @dev Opens the week's series an hour after its initial close.
    function _open() internal {
        if (vm.getBlockTimestamp() < b[0] + 1 hours) vm.warp(b[0] + 1 hours);
        _use(factory.open(WEEK));
    }

    function _deposit(address who, uint256 assets) internal {
        if (vm.getBlockTimestamp() < b[0] + 1 hours) vm.warp(b[0] + 1 hours);
        vm.prank(who);
        _use(factory.deposit(WEEK, assets));
    }

    function _use(ExposureSeriesV2 s) internal {
        series = s;
        overnight = s.overnight();
        session = s.session();
    }

    /// @dev To an hour after boundary `index`, when it is due.
    function _warpPast(uint256 index) internal {
        uint256 due = uint256(b[index]) + 1 hours;
        if (vm.getBlockTimestamp() < due) vm.warp(due);
    }

    function _redeem(address who, uint256 n, uint256 s) internal returns (uint256) {
        vm.prank(who);
        return series.redeem(n, s);
    }

    function _ended() internal view returns (bool) {
        return series.status() == ExposureSeriesV2.Status.Ended;
    }
}
