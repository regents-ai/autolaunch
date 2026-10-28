// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ExposureLegV1} from "../src/ExposureLegV1.sol";
import {ExposureSeriesV1} from "../src/ExposureSeriesV1.sol";
import {IFinalizedPrintOracle} from "../src/interfaces/IFinalizedPrintOracle.sol";
import {MockPrintOracle, MockStock} from "./doubles/Doubles.sol";

/// @notice Shared setup: a five-print series (initial close, open, close, open, close) on an 8-decimal
///         stock, with prints written straight into a mock oracle.
abstract contract SeriesFixture is Test {
    uint256 internal constant TOKEN = 1e8;
    uint256 internal constant USD = 1e18;
    bytes32 internal constant FEED = keccak256("MOCKc official open and close, USD per raw token, v1");
    uint64 internal constant DELAY = 6 hours;

    MockStock internal stock;
    MockPrintOracle internal oracle;
    ExposureSeriesV1 internal series;
    ExposureLegV1 internal overnight;
    ExposureLegV1 internal session;
    uint64[] internal schedule;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        uint64 t = uint64(block.timestamp) + 1 hours;
        // Friday close, Monday open and close, Tuesday open and close (UTC, regular session).
        schedule.push(t);
        schedule.push(t + 2 days + 17.5 hours);
        schedule.push(t + 3 days);
        schedule.push(t + 3 days + 17.5 hours);
        schedule.push(t + 4 days);

        stock = new MockStock();
        oracle = new MockPrintOracle();
        series = new ExposureSeriesV1(_terms(schedule));
        overnight = series.overnight();
        session = series.session();

        address[2] memory holders = [alice, bob];
        for (uint256 i; i < holders.length; ++i) {
            stock.mint(holders[i], 100 * TOKEN);
            vm.prank(holders[i]);
            stock.approve(address(series), type(uint256).max);
        }
    }

    function _terms(uint64[] memory boundaries) internal view returns (ExposureSeriesV1.Terms memory) {
        return ExposureSeriesV1.Terms({
            asset: address(stock),
            oracle: address(oracle),
            feedId: FEED,
            termsHash: keccak256("terms"),
            maxReportDelay: DELAY,
            depositCap: 1_000_000e8,
            boundaries: boundaries,
            overnightName: "MOCKc Overnight 4 Dec 2026",
            overnightSymbol: "MOCKc-N",
            sessionName: "MOCKc Session 4 Dec 2026",
            sessionSymbol: "MOCKc-S"
        });
    }

    /// @dev Publishes the print for boundary `index` one hour after it, moves time there, and applies it.
    function _settle(uint256 index, uint256 priceWad) internal {
        _publish(index, priceWad, schedule[index] + 1 hours);
        if (block.timestamp < schedule[index] + 1 hours) vm.warp(schedule[index] + 1 hours);
        series.settle();
    }

    function _publish(uint256 index, uint256 priceWad, uint64 finalizedAt) internal {
        oracle.set(FEED, schedule[index], index % 2 == 1, uint128(priceWad), finalizedAt);
    }

    function _mint(address who, uint256 assets) internal {
        vm.prank(who);
        series.mint(assets);
    }

    function _redeem(address who, uint256 n, uint256 s) internal returns (uint256) {
        vm.prank(who);
        return series.redeem(n, s);
    }

    function _ledgers() internal view returns (uint256 n, uint256 s) {
        return (series.overnightLedgerWad(), series.sessionLedgerWad());
    }
}

contract ExposureSeriesV1Test is SeriesFixture {
    // ---------------------------------------------------------------------------------------------
    // The paper's worked example
    // ---------------------------------------------------------------------------------------------

    function test_WorkedExample() public {
        _settle(0, 160 * USD);
        _mint(alice, TOKEN);
        assertEq(stock.balanceOf(address(series)), TOKEN);

        uint256[4] memory prices = [uint256(172), 166, 178, 170];
        uint256[4] memory nights = [uint256(92), 92, 104, 104];
        uint256[4] memory days_ = [uint256(80), 74, 74, 66];
        (uint256 n, uint256 s) = _ledgers();
        assertEq(n, 80 * USD);
        assertEq(s, 80 * USD);
        for (uint256 i; i < 4; ++i) {
            _settle(i + 1, prices[i] * USD);
            (n, s) = _ledgers();
            assertEq(n, nights[i] * USD, "overnight ledger");
            assertEq(s, days_[i] * USD, "session ledger");
        }
        assertEq(uint8(series.status()), uint8(ExposureSeriesV1.Status.Ended));
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV1.EndReason.Maturity));

        // One OVERNIGHT is 104/170 of a token, one SESSION 66/170, each rounded down.
        vm.prank(alice);
        session.transfer(bob, TOKEN);
        assertEq(_redeem(alice, TOKEN, 0), TOKEN * 104 / 170);
        assertEq(_redeem(bob, 0, TOKEN), TOKEN * 66 / 170);
        assertEq(stock.balanceOf(address(series)), 1, "one raw unit of rounding dust stays");
        assertEq(overnight.totalSupply() + session.totalSupply(), 0);
    }

    function test_PairRedeemsExactlyAfterEnd() public {
        _settle(0, 160 * USD);
        _mint(alice, 3 * TOKEN + 7);
        for (uint256 i = 1; i < 5; ++i) {
            _settle(i, (150 + 7 * i) * USD);
        }
        assertEq(_redeem(alice, 3 * TOKEN + 7, 3 * TOKEN + 7), 3 * TOKEN + 7);
        assertEq(stock.balanceOf(address(series)), 0);
    }

    function test_MixedRedemptionPairsFirst() public {
        _settle(0, 160 * USD);
        _mint(alice, 10 * TOKEN);
        for (uint256 i = 1; i < 5; ++i) {
            _settle(i, [uint256(0), 172, 166, 178, 170][i] * USD);
        }
        // 10 OVERNIGHT + 4 SESSION = 4 pairs + 6 OVERNIGHT.
        assertEq(series.previewRedeem(10 * TOKEN, 4 * TOKEN), 4 * TOKEN + 6 * TOKEN * 104 / 170);
        assertEq(_redeem(alice, 10 * TOKEN, 4 * TOKEN), 4 * TOKEN + 6 * TOKEN * 104 / 170);
    }

    function test_MintLaterKeepsLedgersAndPairValue() public {
        _settle(0, 160 * USD);
        _mint(alice, TOKEN);
        _settle(1, 172 * USD);
        _settle(2, 166 * USD);
        (uint256 nBefore, uint256 sBefore) = _ledgers();
        _mint(bob, 2 * TOKEN);
        (uint256 n, uint256 s) = _ledgers();
        assertEq(n, nBefore);
        assertEq(s, sBefore);
        assertEq(overnight.totalSupply(), 3 * TOKEN);
        assertEq(session.totalSupply(), 3 * TOKEN);
        assertEq(series.accountedAssets(), 3 * TOKEN);
        assertEq(_redeem(bob, 2 * TOKEN, 2 * TOKEN), 2 * TOKEN);
    }

    // ---------------------------------------------------------------------------------------------
    // Lifecycle rules
    // ---------------------------------------------------------------------------------------------

    function test_NoMintBeforeFirstClose() public {
        vm.expectRevert(ExposureSeriesV1.NotActive.selector);
        _mint(alice, TOKEN);
    }

    function test_NoMintAfterEnd() public {
        _settle(0, 100 * USD);
        _settle(1, 40 * USD);
        vm.expectRevert(ExposureSeriesV1.NotActive.selector);
        _mint(alice, TOKEN);
    }

    function test_OnlyPairsRedeemBeforeEnd() public {
        _settle(0, 160 * USD);
        _mint(alice, 2 * TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV1.PairRequired.selector, TOKEN, 0));
        _redeem(alice, TOKEN, 0);
        assertEq(_redeem(alice, TOKEN, TOKEN), TOKEN);
        assertEq(stock.balanceOf(alice), 99 * TOKEN);
    }

    function test_PrintsApplyOnlyInOrder() public {
        _settle(0, 160 * USD);
        _publish(2, 170 * USD, schedule[2] + 1 hours);
        vm.warp(schedule[2] + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV1.PrintUnavailable.selector, schedule[1]));
        series.settle();
    }

    function test_NothingAfterEnd() public {
        _settle(0, 100 * USD);
        _settle(1, 40 * USD);
        vm.expectRevert(ExposureSeriesV1.AlreadyEnded.selector);
        series.settle();
        vm.expectRevert(ExposureSeriesV1.AlreadyEnded.selector);
        series.endOnMissingPrint();
        assertEq(series.nextBoundaryAt(), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Depletion: the series ends and the other leg owns all the stock
    // ---------------------------------------------------------------------------------------------

    function test_OvernightDepletedOnGapDown() public {
        _settle(0, 100 * USD);
        _mint(alice, TOKEN);
        vm.prank(alice);
        session.transfer(bob, TOKEN);
        // Paper's unconstrained rule would give OVERNIGHT -10 and SESSION 50 on a 40 price.
        _settle(1, 40 * USD);
        (uint256 n, uint256 s) = _ledgers();
        assertEq(n, 0);
        assertEq(s, 40 * USD);
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV1.EndReason.OvernightDepleted));
        assertEq(_redeem(alice, TOKEN, 0), 0);
        assertEq(_redeem(bob, 0, TOKEN), TOKEN);
    }

    function test_SessionDepletedOnFallDuringSession() public {
        _settle(0, 100 * USD);
        _mint(alice, TOKEN);
        _settle(1, 120 * USD); // N 70, S 50
        _settle(2, 65 * USD); // would take S to -5
        (uint256 n, uint256 s) = _ledgers();
        assertEq(n, 65 * USD);
        assertEq(s, 0);
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV1.EndReason.SessionDepleted));
        assertEq(series.previewRedeem(TOKEN, 0), TOKEN);
        assertEq(series.previewRedeem(0, TOKEN), 0);
    }

    function test_LedgerReachingExactlyZeroEnds() public {
        _settle(0, 100 * USD);
        _settle(1, 50 * USD); // N = 50 - 50 = 0
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV1.EndReason.OvernightDepleted));
    }

    // ---------------------------------------------------------------------------------------------
    // Missing, late and broken prints
    // ---------------------------------------------------------------------------------------------

    function test_MissingPrintEndsAtLastLedgers() public {
        _settle(0, 160 * USD);
        _mint(alice, TOKEN);
        uint256 deadline = schedule[1] + DELAY;
        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV1.PrintNotOverdue.selector, deadline));
        series.endOnMissingPrint();

        vm.warp(deadline + 1);
        series.endOnMissingPrint();
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV1.EndReason.MissingPrint));
        assertEq(series.previewRedeem(TOKEN, 0), TOKEN / 2);
        assertEq(series.previewRedeem(0, TOKEN), TOKEN / 2);
    }

    function test_MissingFirstCloseEndsBeforeAnyoneCanMint() public {
        vm.warp(schedule[0] + DELAY + 1);
        series.endOnMissingPrint();
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV1.EndReason.MissingPrint));
        vm.expectRevert(ExposureSeriesV1.NotActive.selector);
        _mint(alice, TOKEN);
    }

    function test_TimelyPrintBlocksTimeoutHoweverLateItIsApplied() public {
        _settle(0, 160 * USD);
        _publish(1, 172 * USD, schedule[1] + DELAY);
        vm.warp(schedule[1] + 30 days);
        vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV1.PrintAvailable.selector, schedule[1]));
        series.endOnMissingPrint();
        series.settle();
        assertEq(series.settled(), 2);
    }

    function test_LatePrintDoesNotCount() public {
        _settle(0, 160 * USD);
        _publish(1, 172 * USD, schedule[1] + DELAY + 1);
        vm.warp(schedule[1] + DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV1.PrintUnavailable.selector, schedule[1]));
        series.settle();
        series.endOnMissingPrint();
        assertEq(uint8(series.endReason()), uint8(ExposureSeriesV1.EndReason.MissingPrint));
    }

    function test_MisdatedPrintsDoNotCount() public {
        _settle(0, 160 * USD);
        uint64 at = schedule[1];
        vm.warp(at + 1 hours);
        IFinalizedPrintOracle.Print[4] memory bad = [
            // labelled for another moment
            IFinalizedPrintOracle.Print({priceWad: uint128(172 * USD), observedAt: at - 60, finalizedAt: at + 60}),
            // final before the event happened
            IFinalizedPrintOracle.Print({priceWad: uint128(172 * USD), observedAt: at, finalizedAt: at - 1}),
            // final in the future
            IFinalizedPrintOracle.Print({priceWad: uint128(172 * USD), observedAt: at, finalizedAt: at + 2 hours}),
            // zero price
            IFinalizedPrintOracle.Print({priceWad: 0, observedAt: at, finalizedAt: at + 60})
        ];
        for (uint256 i; i < bad.length; ++i) {
            oracle.setRaw(FEED, at, true, bad[i]);
            vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV1.PrintUnavailable.selector, at));
            series.settle();
        }
    }

    function test_BrokenOracleCountsAsMissingPrint() public {
        _settle(0, 160 * USD);
        _publish(1, 172 * USD, schedule[1] + 1 hours);
        vm.warp(schedule[1] + DELAY + 1);
        uint256 snapshot = vm.snapshotState();
        for (uint8 m = uint8(MockPrintOracle.Mode.Revert); m <= uint8(MockPrintOracle.Mode.ReturnBomb); ++m) {
            vm.revertToState(snapshot);
            oracle.setMode(MockPrintOracle.Mode(m));
            vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV1.PrintUnavailable.selector, schedule[1]));
            series.settle();
            series.endOnMissingPrint();
            assertEq(uint8(series.endReason()), uint8(ExposureSeriesV1.EndReason.MissingPrint));
        }
    }

    /// @notice However little gas a caller sends, a timely print can never be skipped.
    function testFuzz_LowGasCannotFakeAnOutage(uint256 gas) public {
        gas = bound(gas, 25_000, 400_000);
        _settle(0, 160 * USD);
        _publish(1, 172 * USD, schedule[1] + 1 hours);
        vm.warp(schedule[1] + DELAY + 1);
        (bool ok,) = address(series).call{gas: gas}(abi.encodeCall(ExposureSeriesV1.endOnMissingPrint, ()));
        assertFalse(ok);
        assertEq(uint8(series.status()), uint8(ExposureSeriesV1.Status.Active));
    }

    // ---------------------------------------------------------------------------------------------
    // Backing
    // ---------------------------------------------------------------------------------------------

    function test_DonationsCreateNoClaims() public {
        _settle(0, 160 * USD);
        _mint(alice, TOKEN);
        vm.prank(bob);
        stock.transfer(address(series), 5 * TOKEN);
        assertEq(series.accountedAssets(), TOKEN);
        assertEq(overnight.totalSupply(), TOKEN);
        assertEq(_redeem(alice, TOKEN, TOKEN), TOKEN);
        assertEq(stock.balanceOf(address(series)), 5 * TOKEN);
    }

    function test_SeizureCutsEveryHolderEqually() public {
        _settle(0, 160 * USD);
        _mint(alice, 2 * TOKEN);
        _mint(bob, 2 * TOKEN);
        stock.seize(address(series), TOKEN); // a quarter of the backing

        vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV1.BackingShort.selector, 3 * TOKEN, 4 * TOKEN));
        _mint(bob, TOKEN);

        assertEq(series.previewRedeem(TOKEN, TOKEN), TOKEN * 3 / 4);
        assertEq(_redeem(alice, TOKEN, TOKEN), TOKEN * 3 / 4);
        assertEq(_redeem(bob, 2 * TOKEN, 2 * TOKEN), 2 * TOKEN * 3 / 4);
        assertEq(_redeem(alice, TOKEN, TOKEN), TOKEN * 3 / 4);
        assertEq(stock.balanceOf(address(series)), 0);
        assertEq(series.accountedAssets(), 0);
    }

    function test_RefillAfterSeizureRestoresFullRedemption() public {
        _settle(0, 160 * USD);
        _mint(alice, 2 * TOKEN);
        stock.seize(address(series), TOKEN);
        stock.mint(address(series), TOKEN);
        assertEq(_redeem(alice, 2 * TOKEN, 2 * TOKEN), 2 * TOKEN);
    }

    function test_FeeTakingDepositReverts() public {
        _settle(0, 160 * USD);
        stock.setTakeFee(true);
        vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV1.DepositMismatch.selector, 100 * 1e6, 99 * 1e6));
        _mint(alice, 100 * 1e6);
    }

    function test_FalseReturningTransfersRevertWholeCall() public {
        _settle(0, 160 * USD);
        _mint(alice, TOKEN);
        stock.setReturnFalse(true);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _mint(alice, TOKEN);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        _redeem(alice, TOKEN, TOKEN);
        assertEq(overnight.balanceOf(alice), TOKEN, "burn undone with the failed payout");
        assertEq(series.accountedAssets(), TOKEN);
    }

    // ---------------------------------------------------------------------------------------------
    // Inputs, legs and construction
    // ---------------------------------------------------------------------------------------------

    function test_RejectsZeroInputs() public {
        _settle(0, 160 * USD);
        vm.expectRevert(ExposureSeriesV1.ZeroAmount.selector);
        _mint(alice, 0);
        vm.expectRevert(ExposureSeriesV1.ZeroAmount.selector);
        _redeem(alice, 0, 0);
    }

    function test_DepositCapBoundsStockAtRisk() public {
        ExposureSeriesV1.Terms memory terms = _terms(schedule);
        terms.depositCap = 5 * TOKEN;
        series = new ExposureSeriesV1(terms);
        vm.prank(alice);
        stock.approve(address(series), type(uint256).max);
        _settle(0, 160 * USD);
        _mint(alice, 4 * TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV1.CapReached.selector, TOKEN));
        _mint(alice, TOKEN + 1);
        _mint(alice, TOKEN);
        _redeem(alice, 2 * TOKEN, 2 * TOKEN);
        _mint(alice, 2 * TOKEN); // room frees up as pairs are redeemed
        assertEq(series.accountedAssets(), 5 * TOKEN);

        terms.depositCap = 0;
        vm.expectRevert(ExposureSeriesV1.ZeroAmount.selector);
        new ExposureSeriesV1(terms);
    }

    /// @notice Stock goes only to the account redeeming: legs passed to Bob pay Bob.
    function test_StockGoesToTheRedeemingAccount() public {
        _settle(0, 160 * USD);
        _mint(alice, TOKEN);
        vm.startPrank(alice);
        overnight.transfer(bob, TOKEN);
        session.transfer(bob, TOKEN);
        vm.stopPrank();
        _redeem(bob, TOKEN, TOKEN);
        assertEq(stock.balanceOf(bob), 101 * TOKEN);
        assertEq(stock.balanceOf(alice), 99 * TOKEN);
    }

    function test_TotalSeizureNeverBurnsLegsForNothing() public {
        _settle(0, 160 * USD);
        _mint(alice, TOKEN);
        stock.seize(address(series), TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ExposureSeriesV1.BackingShort.selector, 0, TOKEN));
        _redeem(alice, TOKEN, TOKEN);
        assertEq(overnight.balanceOf(alice), TOKEN);
    }

    /// @notice Found in review: a failing balance read once looked like an empty vault and paid zero.
    function test_FailingBalanceReadRevertsAndKeepsLegs() public {
        _settle(0, 160 * USD);
        _mint(alice, TOKEN);
        stock.setBalanceReadFails(true);
        vm.expectRevert("balance unavailable");
        _redeem(alice, TOKEN, TOKEN);
        vm.expectRevert("balance unavailable");
        series.previewRedeem(TOKEN, TOKEN);
        stock.setBalanceReadFails(false);
        assertEq(_redeem(alice, TOKEN, TOKEN), TOKEN);
    }

    function test_WorthlessLegStillRedeemsForNothing() public {
        _settle(0, 100 * USD);
        _mint(alice, TOKEN);
        _settle(1, 40 * USD); // OVERNIGHT depleted
        assertEq(_redeem(alice, TOKEN, 0), 0);
        assertEq(overnight.balanceOf(alice), 0);
    }

    function test_LegsGiveNoStandingAllowance() public view {
        assertEq(overnight.allowance(alice, 0x000000000022D473030F116dDEE9F6B43aC78BA3), 0);
    }

    function test_LegsAreSeriesControlled() public {
        assertEq(overnight.decimals(), 8);
        assertEq(session.symbol(), "MOCKc-S");
        assertEq(overnight.series(), address(series));
        vm.expectRevert(ExposureLegV1.NotSeries.selector);
        overnight.mint(alice, 1);
        vm.expectRevert(ExposureLegV1.NotSeries.selector);
        session.burn(alice, 0);
    }

    function test_ConstructorRejectsBadTerms() public {
        uint64[] memory even = new uint64[](4);
        uint64[] memory short = new uint64[](1);
        uint64[] memory unordered = new uint64[](3);
        uint64[] memory zeroStart = new uint64[](3);
        for (uint64 i; i < 4; ++i) {
            even[i] = 1 + i;
            if (i < 3) zeroStart[i] = i;
        }
        short[0] = 1;
        (unordered[0], unordered[1], unordered[2]) = (1, 3, 3);
        uint64[] memory tooLong = new uint64[](507);
        for (uint64 i; i < 507; ++i) {
            tooLong[i] = 1 + i;
        }
        uint64[][5] memory badSchedules = [even, short, unordered, zeroStart, tooLong];
        for (uint256 i; i < badSchedules.length; ++i) {
            vm.expectRevert(ExposureSeriesV1.BadSchedule.selector);
            new ExposureSeriesV1(_terms(badSchedules[i]));
        }

        ExposureSeriesV1.Terms memory terms = _terms(schedule);
        terms.maxReportDelay = 0;
        vm.expectRevert(ExposureSeriesV1.BadReportDelay.selector);
        new ExposureSeriesV1(terms);
        terms.maxReportDelay = 7 days + 1;
        vm.expectRevert(ExposureSeriesV1.BadReportDelay.selector);
        new ExposureSeriesV1(terms);
        terms = _terms(schedule);
        terms.oracle = address(0);
        vm.expectRevert(ExposureSeriesV1.ZeroAddress.selector);
        new ExposureSeriesV1(terms);
    }

    // ---------------------------------------------------------------------------------------------
    // Properties
    // ---------------------------------------------------------------------------------------------

    /// @notice Over any price path, the ledgers sum to the last print, neither goes below zero, and
    ///         a ledger at zero has ended the series.
    function testFuzz_LedgersAlwaysSumToPrice(uint128[5] memory prices) public {
        for (uint256 i; i < 5; ++i) {
            uint256 price = bound(prices[i], 1, 1e30);
            _settle(i, price);
            (uint256 n, uint256 s) = _ledgers();
            assertEq(n + s, price);
            if (n == 0 || s == 0) {
                assertEq(uint8(series.status()), uint8(ExposureSeriesV1.Status.Ended));
                break;
            }
        }
        assertEq(uint8(series.status()), uint8(ExposureSeriesV1.Status.Ended));
    }

    /// @notice Whatever the path and however the legs are split, redemptions never pay out more than
    ///         was deposited, and a whole pair always returns exactly its stock.
    function testFuzz_ClaimsNeverExceedBacking(uint128[4] memory prices, uint96 aliceAmount, uint96 bobAmount) public {
        uint256 a = bound(aliceAmount, 1, 100 * TOKEN);
        uint256 b = bound(bobAmount, 1, 100 * TOKEN);
        _settle(0, 1_000 * USD);
        _mint(alice, a);
        _mint(bob, b);
        for (uint256 i; i < 4 && series.status() != ExposureSeriesV1.Status.Ended; ++i) {
            _settle(i + 1, bound(prices[i], 1, 1e24));
        }
        assertEq(uint8(series.status()), uint8(ExposureSeriesV1.Status.Ended));

        // Alice keeps her OVERNIGHT and buys Bob's; Bob keeps his SESSION and buys Alice's.
        vm.prank(alice);
        session.transfer(bob, a);
        vm.prank(bob);
        overnight.transfer(alice, b);
        uint256 paid = _redeem(alice, a + b, 0) + _redeem(bob, 0, a + b);
        assertLe(paid, a + b);
        assertGe(paid + 1, a + b, "at most one raw unit of rounding per leg");
    }

    /// @notice Splitting a single-leg redemption into pieces never pays more than doing it at once.
    function testFuzz_SplittingNeverPaysMore(uint128 price, uint96 x, uint96 y) public {
        _settle(0, 160 * USD);
        _mint(alice, 100 * TOKEN);
        _settle(1, bound(price, 81 * USD, 1_000 * USD));
        vm.warp(schedule[2] + DELAY + 1);
        series.endOnMissingPrint();
        uint256 a = bound(x, 0, 50 * TOKEN);
        uint256 b = bound(y, 1, 50 * TOKEN);
        uint256 whole = series.previewRedeem(a + b, 0);
        uint256 pieces = (a == 0 ? 0 : _redeem(alice, a, 0)) + _redeem(alice, b, 0);
        assertLe(pieces, whole);
    }
}
