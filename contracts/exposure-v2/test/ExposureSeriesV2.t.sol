// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ExposureFactoryV2} from "../src/ExposureFactoryV2.sol";
import {ExposureSeriesV2} from "../src/ExposureSeriesV2.sol";
import {MockFeed} from "./doubles/Doubles.sol";
import {Fixture} from "./Fixture.sol";

/// @notice Calls `target` with `data` from inside a stock transfer and keeps what came back. Transfers
///         made by that call do not call it again.
contract Reenterer {
    address public target;
    bytes public data;
    bool public busy;
    bool public lastOk;
    bytes public lastReturn;

    function arm(address target_, bytes calldata data_) external {
        (target, data) = (target_, data_);
    }

    function approve(address token, address spender) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok);
    }

    function onTransfer() external {
        if (target == address(0) || busy) return;
        busy = true;
        (lastOk, lastReturn) = target.call(data);
        busy = false;
    }
}

contract ExposureSeriesV2Test is Fixture {
    using SeriesStateLib for ExposureSeriesV2;

    // ---------------------------------------------------------------------------------------------
    // Prices and ledgers
    // ---------------------------------------------------------------------------------------------

    function test_workedExample() public {
        _pushWeek(_example());
        _deposit(alice, 10 * TOKEN);
        assertEq(series.settled(), 1, "the deposit applied the initial close");
        assertEq(series.lastPriceWad(), 200e18);
        assertEq(series.overnightLedgerWad(), 100e18);

        _warpPast(4);
        assertEq(series.settle(), 4);
        // Mon open 210: OVERNIGHT 110. Mon close 205: SESSION 95. Tue open 200: OVERNIGHT 105.
        // Tue close 220: SESSION 115.
        assertEq(series.lastPriceWad(), 220e18);
        assertEq(series.overnightLedgerWad(), 105e18);
        assertEq(series.sessionLedgerWad(), 115e18);

        _warpPast(10);
        assertEq(series.settle(), 6);
        assertTrue(_ended());
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV2.EndReason.Maturity));
        assertEq(series.lastPriceWad(), 212e18);
        assertEq(series.overnightLedgerWad(), 99e18);
        assertEq(series.sessionLedgerWad(), 113e18);
        assertEq(series.nextBoundaryAt(), 0);

        uint256 paidOvernight = _redeem(alice, 10 * TOKEN, 0);
        uint256 paidSession = _redeem(alice, 0, 10 * TOKEN);
        assertEq(paidOvernight, 10 * TOKEN * 99 / 212);
        assertEq(paidSession, 10 * TOKEN * 113 / 212);
        assertLe(10 * TOKEN - paidOvernight - paidSession, 1, "at most one raw unit of rounding stays");
    }

    function test_ledgersFollowTheModelForAnyPath(uint256[11] memory dollars) public {
        for (uint256 i; i < 11; ++i) {
            dollars[i] = bound(dollars[i], 1, 2_000);
        }
        _pushWeek(dollars);
        _open();
        _warpPast(10);
        series.settle();

        (uint256 price, uint256 night, uint256 applied, ExposureSeriesV2.EndReason reason) = _model(dollars);
        assertTrue(_ended());
        assertEq(series.settled(), applied);
        assertEq(uint8(series.endReason()), uint8(reason));
        assertEq(series.lastPriceWad(), price);
        assertEq(series.overnightLedgerWad(), night);
    }

    function test_overnightDepletesAtAnOpen() public {
        _pushWeek([uint256(200), 100, 1, 1, 1, 1, 1, 1, 1, 1, 1]);
        _deposit(alice, 10 * TOKEN);
        _warpPast(10);
        assertEq(series.settle(), 1, "the series ends at the first open");
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV2.EndReason.OvernightDepleted));
        assertEq(series.overnightLedgerWad(), 0);
        assertEq(series.lastPriceWad(), 100e18);
        assertEq(_redeem(alice, 0, 10 * TOKEN), 10 * TOKEN, "SESSION takes everything");
        assertEq(_redeem(alice, 10 * TOKEN, 0), 0, "worthless OVERNIGHT redeems for nothing");
    }

    function test_sessionDepletesAtAClose() public {
        _pushWeek([uint256(200), 210, 110, 1, 1, 1, 1, 1, 1, 1, 1]);
        _deposit(alice, 10 * TOKEN);
        _warpPast(10);
        assertEq(series.settle(), 2);
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV2.EndReason.SessionDepleted));
        assertEq(series.overnightLedgerWad(), 110e18);
        assertEq(series.sessionLedgerWad(), 0);
        assertEq(_redeem(alice, 10 * TOKEN, 3 * TOKEN), 10 * TOKEN);
    }

    function test_smallestPriceStillStarts() public {
        _push(b[0] - 1, 1); // one hundred-millionth of a dollar: OVERNIGHT starts at half of it
        _open();
        series.settle();
        assertEq(series.overnightLedgerWad(), 5e9);
        assertEq(uint8(series.status()), uint8(ExposureSeriesV2.Status.Active));
    }

    // ---------------------------------------------------------------------------------------------
    // The round in force
    // ---------------------------------------------------------------------------------------------

    function test_roundUpdatedExactlyAtTheBoundaryCounts() public {
        _push(b[0] - 1 hours, 150e8);
        _push(b[0], 200e8); // same second as the boundary
        _push(b[0], 202e8); // and another in the same second: the later round is the price
        _push(b[0] + 1, 300e8); // one second after: not in force
        _open();
        series.settle();
        assertEq(series.lastPriceWad(), 202e18);
        assertEq(series.lastRound(), 3);
        assertEq(series.lastRoundUpdatedAt(), b[0]);
    }

    function test_quietFeedCarriesTheLastRound() public {
        _push(b[0] - 3 hours, 200e8);
        _push(b[2] - 1 hours, 190e8); // nothing after Monday's close
        _open();
        _warpPast(8);
        series.settle();
        // Thursday's close is 72 hours after the last round: still in force.
        assertEq(series.settled(), 9);
        assertEq(uint8(series.status()), uint8(ExposureSeriesV2.Status.Active));
        assertEq(series.lastRound(), 2);
        assertEq(series.lastPriceWad(), 190e18);
    }

    function test_staleFeedEndsAtTheLastLedgers() public {
        _push(b[0] - 3 hours, 200e8);
        _push(b[1] - 1 hours, 210e8);
        _push(b[2] - 1 hours, 190e8);
        _deposit(alice, 10 * TOKEN);
        _warpPast(10);
        series.settle();
        // Friday's open is 90.5 hours after Monday's last round: older than 84 hours.
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV2.EndReason.StaleFeed));
        assertEq(series.settled(), 9, "the boundaries up to Thursday's close stand");
        assertEq(series.lastPriceWad(), 190e18);
        assertEq(series.overnightLedgerWad(), 110e18);
        assertEq(_redeem(alice, 10 * TOKEN, 0), 10 * TOKEN * 110 / 190);
    }

    function test_noRoundBeforeTheStartEndsBeforeAnyDeposit() public {
        _push(b[0] + 1, 200e8);
        vm.warp(b[0] + 1 hours);
        vm.prank(alice);
        vm.expectRevert(ExposureSeriesV2.NotActive.selector);
        factory.deposit(WEEK, TOKEN);

        _open();
        assertEq(series.settle(), 1);
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV2.EndReason.StaleFeed));
        assertEq(series.settled(), 0);
        assertEq(series.lastPriceWad(), 0);
    }

    function test_badAnswersEndTheSeries() public {
        int256[3] memory bad = [int256(0), -1, int256(uint256(type(uint128).max / 1e10) + 1)];
        for (uint256 i; i < bad.length; ++i) {
            uint256 snap = vm.snapshotState();
            _push(b[0] - 1, 200e8);
            _push(b[1] - 1, 220e8);
            _push(b[2] - 1, bad[i]);
            _deposit(alice, 10 * TOKEN);
            _warpPast(10);
            series.settle();
            assertEq(uint8(series.endReason()), uint8(ExposureSeriesV2.EndReason.BadPrice));
            assertEq(series.settled(), 2);
            assertEq(series.lastPriceWad(), 220e18);
            assertEq(series.overnightLedgerWad(), 120e18);
            vm.revertToState(snap);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // A feed that cannot be read
    // ---------------------------------------------------------------------------------------------

    function test_unreadableFeedWaitsThenEnds() public {
        MockFeed.Mode[5] memory modes = [
            MockFeed.Mode.Revert,
            MockFeed.Mode.ShortReply,
            MockFeed.Mode.LongReply,
            MockFeed.Mode.BurnGas,
            MockFeed.Mode.ReturnBomb
        ];
        _pushWeek(_example());
        _deposit(alice, 10 * TOKEN);
        _warpPast(2);
        series.settle();
        for (uint256 i; i < modes.length; ++i) {
            uint256 snap = vm.snapshotState();
            feed.setMode(modes[i]);

            _warpPast(10);
            uint256 seen = uint256(b[10]) + 1 hours;
            assertEq(series.settle(), 0, "nothing is decided while the feed fails");
            assertEq(series.unreadableSince(), seen, "the first failing read starts the clock");
            assertEq(uint8(series.status()), uint8(ExposureSeriesV2.Status.Active));
            _redeem(alice, TOKEN, TOKEN); // pairs never need the feed

            vm.warp(seen + 7 days - 1);
            assertEq(series.settle(), 0);
            assertEq(series.unreadableSince(), seen, "later failures do not restart it");
            vm.warp(seen + 7 days);
            assertEq(series.settle(), 1);
            assertEq(uint8(series.endReason()), uint8(ExposureSeriesV2.EndReason.FeedUnreadable));
            assertEq(series.settled(), 3, "ends at the ledgers it had");
            assertEq(series.overnightLedgerWad(), 110e18);
            assertEq(series.lastPriceWad(), 205e18);
            vm.revertToState(snap);
        }
    }

    function test_feedThatRecoversInTimeLosesNothing() public {
        _pushWeek(_example());
        _deposit(alice, 10 * TOKEN);
        feed.setMode(MockFeed.Mode.Revert);
        _warpPast(10);
        uint256 seen = uint256(b[10]) + 1 hours;
        assertEq(series.settle(), 0);
        vm.warp(seen + 7 days - 1);
        feed.setMode(MockFeed.Mode.Normal);
        assertEq(series.settle(), 10);
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV2.EndReason.Maturity));
        assertEq(series.overnightLedgerWad(), 99e18);
        assertEq(series.unreadableSince(), 0);
    }

    /// Nobody settles for weeks, then the first settle meets a brief outage. It only starts the
    /// clock; the next settle after the outage applies every price.
    function test_briefOutageCannotEndALazySeries() public {
        _pushWeek(_example());
        _deposit(alice, 10 * TOKEN);
        vm.warp(uint256(b[10]) + 30 days);
        feed.setMode(MockFeed.Mode.Revert);
        assertEq(series.settle(), 0);
        assertEq(uint8(series.status()), uint8(ExposureSeriesV2.Status.Active));
        vm.warp(uint256(b[10]) + 30 days + 10 minutes);
        feed.setMode(MockFeed.Mode.Normal);
        assertEq(_redeem(alice, 10 * TOKEN, 0), 10 * TOKEN * 99 / 212);
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV2.EndReason.Maturity));
    }

    /// A good read in between stops the clock: two outages a week apart do not add up.
    function test_goodReadResetsTheClock() public {
        _pushWeek(_example());
        _deposit(alice, 10 * TOKEN);
        _warpPast(4);
        feed.setMode(MockFeed.Mode.Revert);
        series.settle();
        uint256 first = uint256(b[4]) + 1 hours;
        assertEq(series.unreadableSince(), first);

        // A day later Tuesday's and Wednesday's boundaries read fine.
        vm.warp(first + 1 days);
        feed.setMode(MockFeed.Mode.Normal);
        assertEq(series.settle(), 6);
        assertEq(series.unreadableSince(), 0);

        _warpPast(10);
        feed.setMode(MockFeed.Mode.Revert);
        series.settle();
        assertEq(series.unreadableSince(), uint256(b[10]) + 1 hours);
        vm.warp(first + 7 days);
        assertEq(series.settle(), 0, "the clock started again at the second outage");
        assertEq(uint8(series.status()), uint8(ExposureSeriesV2.Status.Active));
    }

    /// However little gas a caller sends, a settle either reverts or gives the same result as one
    /// with plenty: too little gas can never be passed off as a failing feed, not even to start
    /// the unreadable clock.
    function testFuzz_lowGasCannotFakeAFailingFeed(uint256 gas, bool clockRunning) public {
        _pushWeek(_example());
        _deposit(alice, 10 * TOKEN);
        if (clockRunning) {
            // A real outage a week ago: one faked failure now would end the series.
            vm.warp(uint256(b[1]) + 1 hours);
            feed.setMode(MockFeed.Mode.Revert);
            series.settle();
            feed.setMode(MockFeed.Mode.Normal);
        }
        vm.warp(uint256(b[10]) + 7 days);
        uint256 snap = vm.snapshotState();
        series.settle();
        bytes32 expected = series.fingerprint();
        vm.revertToState(snap);

        gas = bound(gas, 30_000, 1_500_000);
        (bool ok,) = address(series).call{gas: gas}(abi.encodeCall(ExposureSeriesV2.settle, ()));
        if (ok) assertEq(series.fingerprint(), expected);
        else assertEq(series.settled(), 1, "a failed settle changes nothing");
    }

    // ---------------------------------------------------------------------------------------------
    // Settling is the same whenever and however often it happens
    // ---------------------------------------------------------------------------------------------

    function test_settleIsIdempotent() public {
        _pushWeek(_example());
        _open();
        _warpPast(6);
        assertEq(series.settle(), 7);
        bytes32 before = series.fingerprint();
        assertEq(series.settle(), 0);
        assertEq(series.settle(), 0);
        assertEq(series.fingerprint(), before);
    }

    function testFuzz_settleTimingDoesNotMatter(uint256[11] memory dollars, uint256 seed) public {
        for (uint256 i; i < 11; ++i) {
            dollars[i] = bound(dollars[i], 50, 400);
        }
        // Several rounds around each boundary, some on it, some just after it.
        for (uint256 i; i < 11; ++i) {
            _push(b[i] - 30 minutes, int256(dollars[i] * 1e8 - 7e8));
            _push(b[i], int256(dollars[i] * 1e8));
            _push(b[i] + 1, int256(dollars[i] * 1e8 + 9e8));
        }
        _open();
        ExposureSeriesV2 eager = series;
        ExposureSeriesV2 lazy = _newFactory().open(WEEK);

        // The eager series is settled at random moments; the lazy one only at the end.
        uint256 t = uint256(b[0]) + 1 hours;
        for (uint256 i; i < 12; ++i) {
            t += uint256(keccak256(abi.encode(seed, i))) % 20 hours;
            vm.warp(t);
            eager.settle();
            assertEq(eager.previewFingerprint(), lazy.previewFingerprint(), "the same state seen from now");
        }
        vm.warp(uint256(b[10]) + 1 hours);
        eager.settle();
        lazy.settle();
        assertEq(eager.fingerprint(), lazy.fingerprint());
        assertTrue(eager.status() == ExposureSeriesV2.Status.Ended);
    }

    function test_previewMatchesSettle() public {
        _pushWeek(_example());
        _deposit(alice, 10 * TOKEN);
        _warpPast(10);
        bytes32 preview = series.previewFingerprint();
        assertEq(series.previewRedeem(10 * TOKEN, 0), 10 * TOKEN * 99 / 212);
        assertEq(series.settled(), 1, "previews change nothing");
        series.settle();
        assertEq(series.previewFingerprint(), preview);
        assertEq(series.overnightLedgerWad(), 99e18);
    }

    // ---------------------------------------------------------------------------------------------
    // Deposits and redemptions
    // ---------------------------------------------------------------------------------------------

    function test_pairRedemptionNeverReadsTheFeed() public {
        _pushWeek(_example());
        _deposit(alice, 10 * TOKEN);
        feed.setMode(MockFeed.Mode.Revert);
        _warpPast(10);
        assertEq(series.previewRedeem(4 * TOKEN, 4 * TOKEN), 4 * TOKEN);
        assertEq(_redeem(alice, 4 * TOKEN, 4 * TOKEN), 4 * TOKEN);
        assertEq(series.settled(), 1, "and applies no price");
    }

    function test_singleLegsNeedTheEnd() public {
        _pushWeek(_example());
        _deposit(alice, 10 * TOKEN);
        _warpPast(9);
        vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV2.PairRequired.selector, TOKEN, 0));
        _redeem(alice, TOKEN, 0);
        // The redeem that ends the series pays at the final ledgers in the same call.
        _warpPast(10);
        assertEq(_redeem(alice, TOKEN, 0), TOKEN * 99 / 212);
    }

    function test_mintWindow() public {
        _pushWeek(_example());
        vm.warp(b[0] + 1 hours - 1);
        vm.prank(alice);
        vm.expectRevert(); // still the previous week: NotCurrentWeek
        factory.deposit(WEEK, TOKEN);

        _deposit(alice, TOKEN);
        vm.warp(b[10]);
        vm.prank(alice);
        vm.expectRevert(ExposureSeriesV2.Matured.selector);
        series.mint(TOKEN, alice);

        vm.warp(uint256(b[10]) + 1 hours);
        vm.prank(alice);
        vm.expectRevert(ExposureSeriesV2.NotActive.selector);
        series.mint(TOKEN, alice);
    }

    function test_mintRejectsZeroes() public {
        _pushWeek(_example());
        _deposit(alice, TOKEN);
        vm.startPrank(alice);
        stock.approve(address(series), type(uint256).max);
        vm.expectRevert(ExposureSeriesV2.ZeroAmount.selector);
        series.mint(0, alice);
        vm.expectRevert(ExposureSeriesV2.ZeroAddress.selector);
        series.mint(TOKEN, address(0));
        vm.expectRevert(ExposureSeriesV2.ZeroAmount.selector);
        series.redeem(0, 0);
        vm.stopPrank();
    }

    function test_depositCap() public {
        vm.prank(safe);
        factory.setTemplate(_cappedTemplate(150 * TOKEN));
        _pushWeek(_example());
        _deposit(alice, 100 * TOKEN);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV2.CapReached.selector, 50 * TOKEN));
        factory.deposit(WEEK, 60 * TOKEN);
        _deposit(bob, 50 * TOKEN);
        _redeem(alice, 30 * TOKEN, 30 * TOKEN);
        _deposit(bob, 30 * TOKEN); // redeemed room opens again
        assertEq(series.accountedAssets(), 150 * TOKEN);
    }

    function test_donationsChangeNothing() public {
        _pushWeek(_example());
        _deposit(alice, 10 * TOKEN);
        vm.prank(bob);
        stock.transfer(address(series), 5 * TOKEN);
        assertEq(series.accountedAssets(), 10 * TOKEN);
        assertEq(series.previewRedeem(TOKEN, TOKEN), TOKEN);
        _deposit(bob, TOKEN);
        _warpPast(10);
        assertEq(_redeem(alice, 10 * TOKEN, 0), 10 * TOKEN * 99 / 212);
    }

    function test_tokenThatShortChangesIsRefused() public {
        _pushWeek(_example());
        _deposit(alice, TOKEN);
        stock.setTakeFee(true);
        vm.prank(alice);
        vm.expectRevert(); // the factory receives less than it must forward
        factory.deposit(WEEK, 10 * TOKEN);

        vm.startPrank(alice);
        stock.approve(address(series), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV2.DepositMismatch.selector, 10 * TOKEN, 9.9e8));
        series.mint(10 * TOKEN, alice);
        vm.stopPrank();
    }

    function test_tokenThatReturnsFalseIsRefused() public {
        _pushWeek(_example());
        _deposit(alice, TOKEN);
        stock.setReturnFalse(true);
        vm.prank(alice);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        factory.deposit(WEEK, TOKEN);
        vm.prank(alice);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        series.redeem(TOKEN, TOKEN);
    }

    // ---------------------------------------------------------------------------------------------
    // The issuer
    // ---------------------------------------------------------------------------------------------

    function test_seizureCutsEveryoneByTheSameFraction() public {
        _pushWeek(_example());
        _deposit(alice, 100 * TOKEN);
        _deposit(bob, 100 * TOKEN);
        stock.seize(address(series), 50 * TOKEN);

        assertEq(series.previewRedeem(100 * TOKEN, 100 * TOKEN), 75 * TOKEN);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV2.BackingShort.selector, 150 * TOKEN, 200 * TOKEN));
        factory.deposit(WEEK, TOKEN);

        assertEq(_redeem(alice, 100 * TOKEN, 100 * TOKEN), 75 * TOKEN);
        _warpPast(10);
        uint256 night = _redeem(bob, 100 * TOKEN, 0);
        uint256 day = _redeem(bob, 0, 100 * TOKEN);
        assertEq(night, 100 * TOKEN * 99 / 212 * 3 / 4);
        assertApproxEqAbs(night + day, 75 * TOKEN, 2, "bob is cut by the same quarter");
    }

    function test_totalSeizureNeverBurnsLegsForNothing() public {
        _pushWeek(_example());
        _deposit(alice, 10 * TOKEN);
        stock.seize(address(series), 10 * TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV2.BackingShort.selector, 0, 10 * TOKEN));
        _redeem(alice, TOKEN, TOKEN);
        assertEq(overnight.balanceOf(alice), 10 * TOKEN);
    }

    function test_blocklistAndPauseOnlyStopTheBlockedAccount() public {
        _pushWeek(_example());
        _deposit(alice, 10 * TOKEN);
        _deposit(bob, 10 * TOKEN);

        stock.setBlocked(alice, true);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        _redeem(alice, TOKEN, TOKEN);
        // Alice cannot pass her stock to anyone else either: redemptions only pay the redeemer.
        assertEq(_redeem(bob, TOKEN, TOKEN), TOKEN);
        // She can still sell her legs, which the issuer does not control.
        vm.prank(alice);
        overnight.transfer(bob, TOKEN);

        stock.setPaused(true);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        _redeem(bob, TOKEN, TOKEN);
        _warpPast(10);
        series.settle(); // prices still apply while transfers are paused
        assertTrue(_ended());
        stock.setPaused(false);
        stock.setBlocked(alice, false);
        assertEq(_redeem(alice, 9 * TOKEN, 9 * TOKEN), 9 * TOKEN);
    }

    function test_unreadableBalanceStopsMintAndRedeem() public {
        _pushWeek(_example());
        _deposit(alice, 10 * TOKEN);
        stock.setBalanceReadFails(true);
        vm.expectRevert(bytes("balance unavailable"));
        _redeem(alice, TOKEN, TOKEN);
        vm.prank(alice);
        vm.expectRevert(bytes("balance unavailable"));
        factory.deposit(WEEK, TOKEN);
    }

    // ---------------------------------------------------------------------------------------------
    // Reentrancy
    // ---------------------------------------------------------------------------------------------

    function test_stockHooksCannotReenter() public {
        _pushWeek(_example());
        _deposit(alice, 10 * TOKEN);
        Reenterer r = new Reenterer();
        stock.mint(address(r), 10 * TOKEN);
        r.approve(address(stock), address(factory));
        r.approve(address(stock), address(series));
        stock.setHook(address(r));
        bytes4 reentrancy = ReentrancyGuard.Reentrancy.selector;

        bytes[4] memory calls = [
            abi.encodeCall(ExposureSeriesV2.settle, ()),
            abi.encodeCall(ExposureSeriesV2.redeem, (TOKEN, TOKEN)),
            abi.encodeCall(ExposureSeriesV2.mint, (TOKEN, alice)),
            abi.encodeCall(factory.deposit, (WEEK, TOKEN))
        ];
        for (uint256 i; i < calls.length; ++i) {
            address target = i == 3 ? address(factory) : address(series);
            r.arm(target, calls[i]);
            // The series' payout to alice calls the hook while the series is locked.
            _redeem(alice, TOKEN, TOKEN);
            assertFalse(r.lastOk());
            assertEq(bytes4(r.lastReturn()), reentrancy);
            // And so does its pull from the factory during a deposit.
            _deposit(alice, TOKEN);
            assertFalse(r.lastOk());
            assertEq(bytes4(r.lastReturn()), reentrancy);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Reference model
    // ---------------------------------------------------------------------------------------------

    /// @dev Version 1's rules applied to a whole week of prices, in dollars.
    function _model(uint256[11] memory dollars)
        internal
        pure
        returns (uint256 price, uint256 night, uint256 applied, ExposureSeriesV2.EndReason reason)
    {
        for (uint256 i; i < 11; ++i) {
            uint256 p = dollars[i] * 1e18;
            applied = i + 1;
            if (i == 0) {
                night = p / 2;
            } else if (i % 2 == 1) {
                uint256 day = price - night;
                if (p <= day) {
                    (price, night) = (p, 0);
                    return (price, night, applied, ExposureSeriesV2.EndReason.OvernightDepleted);
                }
                night = p - day;
            } else if (p <= night) {
                return (p, p, applied, ExposureSeriesV2.EndReason.SessionDepleted);
            }
            price = p;
        }
        reason = ExposureSeriesV2.EndReason.Maturity;
    }

    function _cappedTemplate(uint256 cap) internal view returns (ExposureFactoryV2.Template memory t) {
        t = _template();
        t.depositCap = cap;
    }
}

/// @notice A hash of everything settling decides, stored or previewed.
library SeriesStateLib {
    function fingerprint(ExposureSeriesV2 s) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                s.status(),
                s.endReason(),
                s.settled(),
                s.lastPriceWad(),
                s.overnightLedgerWad(),
                s.lastRound(),
                s.lastRoundUpdatedAt(),
                s.unreadableSince()
            )
        );
    }

    function previewFingerprint(ExposureSeriesV2 s) internal view returns (bytes32) {
        (
            ExposureSeriesV2.Status status,
            ExposureSeriesV2.EndReason reason,
            uint256 printsApplied,
            uint256 price,
            uint256 night
        ) = s.previewState();
        return keccak256(abi.encode(status, reason, printsApplied, price, night));
    }
}
