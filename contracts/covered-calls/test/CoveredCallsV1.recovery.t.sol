// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {CoveredCallsV1} from "../src/CoveredCallsV1.sol";
import {B20Double, StakingDouble, UsdcDouble} from "./doubles/Doubles.sol";
import {WeeklyExpiry} from "./doubles/WeeklyExpiry.sol";

/// @notice What the tokens, the issuer, Circle and staking can refuse, and how each party still
///         recovers what is theirs. From the adversarial review of 28 Oct 2026: the five `F1`/`F2`
///         tests failed on the first version, where `cancel` returned stock and `settle` paid USDC
///         and stock in one call, so a block on one token held up the other; the rest pin behaviour
///         the review checked.
contract CoveredCallsV1RecoveryTest is Test {
    uint256 internal constant TOKEN = 1e8;
    uint256 internal constant USD = 1e6;
    uint256 internal constant ACTORS = 5;
    uint64 internal expiry;

    B20Double internal stock;
    UsdcDouble internal usdc;
    StakingDouble internal staking;
    CoveredCallsV1 internal calls;

    address internal seller = makeAddr("seller");
    address internal buyer;
    address[] internal actors;

    function setUp() public {
        vm.warp(1_800_000_000);
        expiry = WeeklyExpiry.next(block.timestamp, 0);
        stock = new B20Double();
        usdc = new UsdcDouble();
        staking = new StakingDouble(usdc);
        calls = new CoveredCallsV1(address(stock), address(usdc), address(staking));

        stock.mint(seller, 1_000 * TOKEN);
        usdc.mint(seller, 1_000_000 * USD);
        vm.startPrank(seller);
        stock.approve(address(calls), type(uint256).max);
        usdc.approve(address(calls), type(uint256).max);
        vm.stopPrank();
        for (uint256 i; i < ACTORS; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            usdc.mint(a, 100_000_000 * USD);
            vm.prank(a);
            usdc.approve(address(calls), type(uint256).max);
        }
        buyer = actors[0];
    }

    /// 110 USDC strike and 3 USDC premium per token.
    function _list(uint256 amount) internal returns (uint256 id) {
        vm.prank(seller);
        id = calls.list(amount, 110 * USD, 3 * USD, expiry);
    }

    // ---- F1: the seller can always stop sales ----

    function test_F1_sellerCancelsWhileStockIsPausedAndBuyersCannotFillAfter() public {
        uint256 id = _list(10 * TOKEN);
        stock.setPaused(true);
        vm.prank(seller);
        calls.cancel(id);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.ExceedsAvailable.selector, 1, 0));
        calls.fill(id, 1);

        stock.setPaused(false);
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 1_000 * TOKEN);
    }

    function test_F1_blocklistedSellerCanStillStopSales() public {
        uint256 id = _list(10 * TOKEN);
        stock.setBlocked(seller, true);
        vm.prank(seller);
        calls.cancel(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.ExceedsAvailable.selector, 1, 0));
        calls.fill(id, 1);
        assertEq(calls.owed(id, seller), 10 * TOKEN);
    }

    // ---- F2: a block on one token never holds up the other ----

    function test_F2_usdcBlacklistedSellerStillRecoversUnexercisedStock() public {
        uint256 id = _list(10 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, 10 * TOKEN);
        vm.warp(expiry);
        vm.prank(buyer);
        calls.exercise(id, TOKEN); // 110 USDC strike waits in the contract

        usdc.setBlacklisted(seller, true);
        vm.warp(uint256(expiry) + calls.EXERCISE_WINDOW());
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 999 * TOKEN);
        assertEq(usdc.balanceOf(address(calls)), 110 * USD);
    }

    function test_F2_stockBlocklistedSellerStillCollectsTheStrike() public {
        uint256 id = _list(10 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, 10 * TOKEN);
        vm.warp(uint256(expiry) + calls.EXERCISE_WINDOW() - 1); // exercised in the last second
        vm.prank(buyer);
        calls.exercise(id, TOKEN);

        stock.setBlocked(seller, true);
        vm.warp(uint256(expiry) + calls.EXERCISE_WINDOW());
        uint256 before = usdc.balanceOf(seller);
        vm.prank(seller);
        calls.collectStrike(id);
        assertEq(usdc.balanceOf(seller) - before, 110 * USD);
    }

    function test_F2_stockPauseAfterTheWindowNeverHoldsTheSellersUsdc() public {
        uint256 id = _list(10 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, 10 * TOKEN);
        vm.warp(expiry);
        vm.prank(buyer);
        calls.exercise(id, TOKEN);

        vm.warp(uint256(expiry) + calls.EXERCISE_WINDOW());
        stock.setPaused(true);
        uint256 before = usdc.balanceOf(seller);
        vm.prank(seller);
        calls.collectStrike(id);
        assertEq(usdc.balanceOf(seller) - before, 110 * USD);
    }

    // ---- time boundaries ----

    function test_boundariesAreDisjointAndExact() public {
        uint256 id = _list(10 * TOKEN);
        uint256 windowEnd = uint256(expiry) + calls.EXERCISE_WINDOW();

        vm.warp(uint256(expiry) - 1);
        vm.prank(buyer);
        calls.fill(id, 2 * TOKEN); // last fill second

        vm.warp(expiry);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.FillsClosed.selector, expiry));
        calls.fill(id, 1);
        vm.prank(buyer);
        calls.exercise(id, 1); // first exercise second

        vm.startPrank(seller);
        calls.collectStrike(id);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id); // the stock does not return inside the window
        vm.stopPrank();

        vm.warp(windowEnd - 1);
        vm.prank(buyer);
        calls.exercise(id, 1); // last exercise second

        vm.warp(windowEnd);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.OutsideExerciseWindow.selector, expiry));
        calls.exercise(id, 1);

        vm.prank(seller);
        calls.claim(id); // first second the stock returns
        assertEq(stock.balanceOf(seller), 1_000 * TOKEN - 2);
        assertEq(stock.balanceOf(address(calls)), 2); // exercised, owed to the buyer
        vm.prank(seller);
        vm.expectRevert(CoveredCallsV1.NothingToCollect.selector);
        calls.claim(id); // never twice
    }

    /// A change taking effect the second exercising closes is allowed; one second earlier is refused;
    /// `effectiveAt == now` counts as already in effect, as B20 refuses scheduling at `now`
    /// (`EffectiveAtInPast` when `effectiveAt <= block.timestamp`).
    function test_corporateActionBoundaries() public {
        uint256 windowEnd = uint256(expiry) + calls.EXERCISE_WINDOW();
        stock.schedule(windowEnd);
        _list(TOKEN);
        stock.schedule(windowEnd - 1);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.CorporateActionScheduled.selector, windowEnd - 1));
        calls.list(TOKEN, 110 * USD, 3 * USD, expiry);
        stock.schedule(block.timestamp);
        _list(TOKEN);
    }

    /// A change scheduled after listing stops fills until it takes effect; prices are per raw unit, so
    /// the listing's terms keep their value across it and fills resume.
    function test_fillsResumeOnAListingOnceItsCorporateActionHasTakenEffect() public {
        uint256 id = _list(10 * TOKEN);
        uint256 at = block.timestamp + 1 hours;
        stock.schedule(at);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.CorporateActionScheduled.selector, at));
        calls.fill(id, TOKEN);
        vm.warp(at);
        vm.prank(buyer);
        calls.fill(id, TOKEN);
        assertEq(calls.held(id, buyer), TOKEN);
    }

    // ---- the fee ----

    function test_feeIsPaidOnceAndNoAllowanceIsLeftBehind() public {
        uint256 id = _list(10 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, 10 * TOKEN); // premium 30 USDC
        assertEq(staking.deposited(), 300_000);
        assertEq(usdc.balanceOf(seller), 1_000_000 * USD + 30 * USD - 300_000);
        assertEq(usdc.allowance(address(calls), address(staking)), 0);
        assertEq(usdc.balanceOf(address(calls)), 0);
    }

    /// The fee rounds up, so splitting a fill into dust never avoids it.
    function test_tinyFillStillPaysTheFee() public {
        uint256 id = _list(10 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, 3300); // premium ceil(3300 * 3e6 / 1e8) = 99 micro-USDC
        assertEq(calls.premiumFor(id, 3300), 99);
        assertEq(staking.deposited(), 1);
    }

    /// Staking refusing deposits stops fills that carry a fee; nothing else touches staking.
    function test_stakingRefusalStopsFillsButNeverRecovery() public {
        uint256 id = _list(10 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, 2 * TOKEN);
        staking.setRefuses(true);
        vm.prank(buyer);
        vm.expectRevert(bytes("staking paused"));
        calls.fill(id, TOKEN);
        vm.warp(expiry);
        vm.startPrank(buyer);
        calls.exercise(id, TOKEN);
        calls.claim(id);
        vm.stopPrank();
        vm.startPrank(seller);
        calls.cancel(id);
        calls.collectStrike(id);
        vm.warp(uint256(expiry) + 1 days);
        calls.claim(id);
        vm.stopPrank();
        assertEq(stock.balanceOf(address(calls)), 0);
        assertEq(usdc.balanceOf(address(calls)), 0);
    }

    /// The 24-hour window is a deadline: if USDC is paused for all of it, no exercise is possible, the
    /// premium stays with the seller and the seller takes the stock back.
    function test_usdcPauseThroughTheWindowForfeitsExercise() public {
        uint256 id = _list(10 * TOKEN);
        vm.prank(buyer);
        calls.fill(id, 10 * TOKEN);
        vm.warp(expiry);
        usdc.setPaused(true);
        vm.prank(buyer);
        vm.expectRevert();
        calls.exercise(id, 10 * TOKEN);
        vm.warp(uint256(expiry) + 1 days);
        usdc.setPaused(false);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV1.OutsideExerciseWindow.selector, expiry));
        calls.exercise(id, 10 * TOKEN);
        vm.prank(seller);
        calls.claim(id);
        assertEq(stock.balanceOf(seller), 1_000 * TOKEN);
    }

    // ---- everyone recovers once restrictions lift ----

    /// Random fractional fills by many accounts, exercises, a cancel, strike collected inside and
    /// after the window, while a holder is blocklisted, transfers are paused and the seller is
    /// blacklisted on USDC; once every restriction lifts, every party recovers exactly what is theirs
    /// and the contract ends empty.
    function testFuzz_everyoneRecoversOnceRestrictionsLift(uint256 seed) public {
        uint256 id = _list(37 * TOKEN + 12_345);
        uint256 premiumPaid;
        uint256 exercisedTotal;
        uint256 strikeTotal;
        uint256[ACTORS] memory exercisedBy;

        for (uint256 i; i < 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address a = actors[seed % ACTORS];
            CoveredCallsV1.Listing memory l = calls.listings(id);
            if (l.amount == l.filled) break;
            uint256 amount = bound(seed >> 8, 1, l.amount - l.filled);
            premiumPaid += calls.premiumFor(id, amount);
            vm.prank(a);
            calls.fill(id, amount);
        }
        stock.setPaused(seed % 2 == 0);
        stock.setBlocked(actors[seed % ACTORS], true);
        if (seed % 3 == 0) {
            vm.prank(seller);
            try calls.cancel(id) {} catch {}
        }

        vm.warp(uint256(expiry) + (seed >> 32) % 1 days);
        for (uint256 k; k < ACTORS; ++k) {
            uint256 h = calls.held(id, actors[k]);
            if (h == 0) continue;
            uint256 x = bound(uint256(keccak256(abi.encode(seed, k))), 0, h);
            if (x == 0) continue;
            strikeTotal += calls.strikeFor(id, x);
            exercisedBy[k] = x;
            exercisedTotal += x;
            vm.prank(actors[k]);
            calls.exercise(id, x);
        }
        if (seed % 5 == 0 && strikeTotal != 0) {
            vm.prank(seller);
            calls.collectStrike(id); // inside the window, while the stock may be paused
        }
        usdc.setBlacklisted(seller, seed % 7 == 0);

        vm.warp(uint256(expiry) + 1 days);
        stock.setPaused(false);
        stock.setBlocked(actors[seed % ACTORS], false);
        vm.startPrank(seller);
        try calls.cancel(id) {} catch {}
        CoveredCallsV1.Listing memory end = calls.listings(id);
        if (end.amount != end.exercised || calls.owed(id, seller) != 0) calls.claim(id); // stock never waits on USDC
        usdc.setBlacklisted(seller, false);
        if (calls.listings(id).strikePaid != calls.listings(id).strikeCollected) calls.collectStrike(id);
        vm.stopPrank();
        for (uint256 k; k < ACTORS; ++k) {
            if (calls.owed(id, actors[k]) == 0) continue;
            vm.prank(actors[k]);
            calls.claim(id);
            assertEq(stock.balanceOf(actors[k]), exercisedBy[k]);
        }

        assertEq(stock.balanceOf(address(calls)), 0);
        assertEq(usdc.balanceOf(address(calls)), 0);
        assertEq(stock.balanceOf(seller), 1_000 * TOKEN - exercisedTotal);
        assertEq(usdc.balanceOf(seller), 1_000_000 * USD + premiumPaid - staking.deposited() + strikeTotal);
    }
}
