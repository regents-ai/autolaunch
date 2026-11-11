// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {CoveredCallsV2} from "../src/CoveredCallsV2.sol";
import {B20Double, CallbackToken, ReenteringStaking, StakingDouble, UsdcDouble} from "./doubles/Doubles.sol";
import {WeeklyExpiry} from "./doubles/WeeklyExpiry.sol";

/// @notice Attacks on the bid paths from the adversarial review: re-entering through staking, the
///         USDC or the stock; a stranger, a seller or a bidder reaching for what is another's; and
///         amounts large enough to overflow.
contract CoveredCallsV2AttacksTest is Test {
    uint256 internal constant TOKEN = 1e8;
    uint256 internal constant USD = 1e6;
    uint64 internal expiry;

    address internal bidder = makeAddr("bidder");
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_800_000_000);
        expiry = WeeklyExpiry.next(block.timestamp, 1);
    }

    function _fund(CoveredCallsV2 calls, address stock, address usdc, address who) internal {
        B20Double(stock).mint(who, 100 * TOKEN);
        UsdcDouble(usdc).mint(who, 1_000_000 * USD);
        vm.startPrank(who);
        B20Double(stock).approve(address(calls), type(uint256).max);
        UsdcDouble(usdc).approve(address(calls), type(uint256).max);
        vm.stopPrank();
    }

    function _reentrancy() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector);
    }

    /// Every state-changing call an attacker might make from inside a callback.
    function _callbacks(uint256 bidId, uint256 listingId) internal view returns (bytes[] memory c) {
        c = new bytes[](11);
        c[0] = abi.encodeCall(CoveredCallsV2.sellToBid, (bidId, 1));
        c[1] = abi.encodeCall(CoveredCallsV2.cancelBid, (bidId));
        c[2] = abi.encodeCall(CoveredCallsV2.refundBid, (bidId));
        c[3] = abi.encodeCall(CoveredCallsV2.raiseBid, (bidId, 1));
        c[4] = abi.encodeCall(CoveredCallsV2.bid, (TOKEN, 110 * USD, 3 * USD, expiry, 1));
        c[5] = abi.encodeCall(CoveredCallsV2.fill, (listingId, 1));
        c[6] = abi.encodeCall(CoveredCallsV2.list, (TOKEN, 110 * USD, 3 * USD, expiry));
        c[7] = abi.encodeCall(CoveredCallsV2.cancel, (listingId));
        c[8] = abi.encodeCall(CoveredCallsV2.exercise, (listingId, 1));
        c[9] = abi.encodeCall(CoveredCallsV2.claim, (listingId));
        c[10] = abi.encodeCall(CoveredCallsV2.collectStrike, (listingId));
    }

    // ---- re-entry ----

    /// Staking runs code during every fill and sale. Whatever it calls back into is refused by the
    /// guard, and the sale's books come out exact.
    function test_reentry_throughStakingDuringASaleIsRefused() public {
        B20Double stock = new B20Double();
        UsdcDouble usdc = new UsdcDouble();
        ReenteringStaking staking = new ReenteringStaking(usdc);
        CoveredCallsV2 calls = new CoveredCallsV2(address(stock), address(usdc), address(staking));
        _fund(calls, address(stock), address(usdc), bidder);
        _fund(calls, address(stock), address(usdc), seller);
        vm.prank(bidder);
        uint256 id = calls.bid(50 * TOKEN, 110 * USD, 3 * USD, expiry, 1);
        vm.prank(seller);
        uint256 listingId = calls.list(20 * TOKEN, 110 * USD, 3 * USD, expiry);

        bytes[] memory c = _callbacks(id, listingId);
        for (uint256 i; i < c.length; ++i) {
            staking.arm(address(calls), c[i]);
            vm.prank(seller);
            calls.sellToBid(id, TOKEN);
            assertTrue(staking.calledBack());
            assertEq(staking.callbackRevert(), _reentrancy());

            staking.arm(address(calls), c[i]);
            vm.prank(bidder);
            calls.fill(listingId, TOKEN);
            assertEq(staking.callbackRevert(), _reentrancy());
        }
        assertEq(calls.bids(id).filled, 11 * TOKEN);
        assertEq(calls.listings(listingId).filled, 11 * TOKEN);
        assertEq(
            usdc.balanceOf(address(calls)), calls.costFor(50 * TOKEN, 3 * USD) - calls.costFor(11 * TOKEN, 3 * USD)
        );
        assertEq(stock.balanceOf(address(calls)), 31 * TOKEN);
    }

    /// A USDC that called back on every transfer still could not re-enter: bid, raise, the sale's
    /// payout, refund, fill, exercise and the strike collection each refuse the callback.
    function test_reentry_throughUsdcIsRefused() public {
        B20Double stock = new B20Double();
        CallbackToken usdc = new CallbackToken(6);
        StakingDouble staking = new StakingDouble(UsdcDouble(address(usdc)));
        CoveredCallsV2 calls = new CoveredCallsV2(address(stock), address(usdc), address(staking));
        address[3] memory who = [bidder, seller, buyer];
        for (uint256 i; i < 3; ++i) {
            stock.mint(who[i], 100 * TOKEN);
            usdc.mint(who[i], 1_000_000 * USD);
            vm.startPrank(who[i]);
            stock.approve(address(calls), type(uint256).max);
            usdc.approve(address(calls), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(seller);
        uint256 listingId = calls.list(20 * TOKEN, 110 * USD, 3 * USD, expiry);
        bytes[] memory c = _callbacks(1, listingId);

        for (uint256 i; i < c.length; ++i) {
            usdc.arm(address(calls), c[i]);
            vm.prank(bidder);
            calls.bid(10 * TOKEN, 110 * USD, 3 * USD, expiry, 1);
            assertEq(usdc.callbackRevert(), _reentrancy(), "bid");

            usdc.arm(address(calls), c[i]);
            vm.prank(bidder);
            calls.raiseBid(1, TOKEN);
            assertEq(usdc.callbackRevert(), _reentrancy(), "raiseBid");

            usdc.arm(address(calls), c[i]);
            vm.prank(seller);
            calls.sellToBid(1, TOKEN);
            assertEq(usdc.callbackRevert(), _reentrancy(), "sellToBid");

            usdc.arm(address(calls), c[i]);
            vm.prank(buyer);
            calls.fill(listingId, TOKEN);
            assertEq(usdc.callbackRevert(), _reentrancy(), "fill");
        }
        uint256 bidCount = calls.bidCount();
        vm.prank(bidder);
        calls.cancelBid(1);
        usdc.arm(address(calls), c[2]);
        vm.prank(bidder);
        calls.refundBid(1);
        assertEq(usdc.callbackRevert(), _reentrancy(), "refundBid");

        vm.warp(expiry);
        usdc.arm(address(calls), c[8]);
        vm.prank(buyer);
        calls.exercise(listingId, TOKEN);
        assertEq(usdc.callbackRevert(), _reentrancy(), "exercise");
        usdc.arm(address(calls), c[10]);
        vm.prank(seller);
        calls.collectStrike(listingId);
        assertEq(usdc.callbackRevert(), _reentrancy(), "collectStrike");

        // The contract's USDC is exactly the open bids' escrow.
        uint256 escrow;
        for (uint256 id = 1; id <= bidCount; ++id) {
            escrow += calls.refundable(id);
        }
        assertEq(usdc.balanceOf(address(calls)), escrow);
    }

    /// A stock that called back on every transfer still could not re-enter: listing, the sale's lock
    /// and the claim each refuse the callback.
    function test_reentry_throughStockIsRefused() public {
        CallbackToken stock = new CallbackToken(8);
        UsdcDouble usdc = new UsdcDouble();
        StakingDouble staking = new StakingDouble(usdc);
        CoveredCallsV2 calls = new CoveredCallsV2(address(stock), address(usdc), address(staking));
        address[2] memory who = [bidder, seller];
        for (uint256 i; i < 2; ++i) {
            stock.mint(who[i], 100 * TOKEN);
            usdc.mint(who[i], 1_000_000 * USD);
            vm.startPrank(who[i]);
            stock.approve(address(calls), type(uint256).max);
            usdc.approve(address(calls), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(bidder);
        uint256 id = calls.bid(50 * TOKEN, 110 * USD, 3 * USD, expiry, 1);
        bytes[] memory c = _callbacks(id, 1);
        for (uint256 i; i < c.length; ++i) {
            stock.arm(address(calls), c[i]);
            vm.prank(seller);
            calls.list(TOKEN, 110 * USD, 3 * USD, expiry);
            assertEq(stock.callbackRevert(), _reentrancy(), "list");

            stock.arm(address(calls), c[i]);
            vm.prank(seller);
            calls.sellToBid(id, TOKEN);
            assertEq(stock.callbackRevert(), _reentrancy(), "sellToBid");
        }
        vm.warp(uint256(expiry) + 1 days);
        stock.arm(address(calls), c[9]);
        vm.prank(seller);
        calls.claim(2);
        assertEq(stock.callbackRevert(), _reentrancy(), "claim");
        assertEq(stock.balanceOf(address(calls)), 21 * TOKEN);
    }

    // ---- someone else's escrow, stock or strike ----

    /// Mid-life, with a listing partly filled and a bid partly sold into, nobody but the right party
    /// can move anything, and every attempt leaves the contract's balances as they were.
    function test_nobodyReachesAnotherAccountsEscrowStockOrStrike() public {
        B20Double stock = new B20Double();
        UsdcDouble usdc = new UsdcDouble();
        StakingDouble staking = new StakingDouble(usdc);
        CoveredCallsV2 calls = new CoveredCallsV2(address(stock), address(usdc), address(staking));
        address[4] memory who = [bidder, seller, buyer, stranger];
        for (uint256 i; i < 4; ++i) {
            _fund(calls, address(stock), address(usdc), who[i]);
        }
        vm.prank(seller);
        uint256 listed = calls.list(10 * TOKEN, 110 * USD, 3 * USD, expiry);
        vm.prank(buyer);
        calls.fill(listed, 4 * TOKEN);
        vm.prank(bidder);
        uint256 id = calls.bid(10 * TOKEN, 120 * USD, 2 * USD, expiry, 1);
        vm.prank(seller);
        uint256 sold = calls.sellToBid(id, 6 * TOKEN);

        uint256 stockHeld = stock.balanceOf(address(calls));
        uint256 usdcHeld = usdc.balanceOf(address(calls));
        _attempts(calls, id, listed, sold);
        assertEq(stock.balanceOf(address(calls)), stockHeld);
        assertEq(usdc.balanceOf(address(calls)), usdcHeld);

        vm.warp(expiry);
        vm.prank(bidder);
        calls.exercise(sold, 2 * TOKEN);
        vm.prank(buyer);
        calls.exercise(listed, TOKEN);
        stockHeld = stock.balanceOf(address(calls));
        usdcHeld = usdc.balanceOf(address(calls));
        _attempts(calls, id, listed, sold);
        assertEq(stock.balanceOf(address(calls)), stockHeld);
        assertEq(usdc.balanceOf(address(calls)), usdcHeld);

        vm.warp(uint256(expiry) + 1 days);
        stockHeld = stock.balanceOf(address(calls));
        usdcHeld = usdc.balanceOf(address(calls));
        _attempts(calls, id, listed, sold);
        assertEq(stock.balanceOf(address(calls)), stockHeld);
        assertEq(usdc.balanceOf(address(calls)), usdcHeld);

        // Each party then takes exactly its own, and the contract ends empty.
        vm.startPrank(seller);
        calls.claim(listed);
        calls.claim(sold);
        calls.collectStrike(listed);
        calls.collectStrike(sold);
        vm.stopPrank();
        vm.startPrank(bidder);
        calls.claim(sold);
        calls.refundBid(id);
        vm.stopPrank();
        vm.prank(buyer);
        calls.claim(listed);
        assertEq(stock.balanceOf(address(calls)), 0);
        assertEq(usdc.balanceOf(address(calls)), 0);
        assertEq(stock.balanceOf(bidder), 102 * TOKEN);
        assertEq(stock.balanceOf(buyer), 101 * TOKEN);
        assertEq(stock.balanceOf(seller), 97 * TOKEN);
        assertEq(stock.balanceOf(stranger), 100 * TOKEN);
        assertEq(usdc.balanceOf(stranger), 1_000_000 * USD);
    }

    /// Everything the wrong party might try on a bid, its sale and a listing; each must revert.
    function _attempts(CoveredCallsV2 calls, uint256 id, uint256 listed, uint256 sold) internal {
        address[3] memory notBidder = [seller, buyer, stranger];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(notBidder[i]);
            vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.NotBidder.selector, notBidder[i]));
            calls.cancelBid(id);
            vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.NotBidder.selector, notBidder[i]));
            calls.refundBid(id);
            vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.NotBidder.selector, notBidder[i]));
            calls.raiseBid(id, TOKEN);
            vm.stopPrank();
        }
        address[3] memory notSeller = [bidder, buyer, stranger];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(notSeller[i]);
            vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.NotSeller.selector, notSeller[i]));
            calls.cancel(sold);
            vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.NotSeller.selector, notSeller[i]));
            calls.collectStrike(sold);
            vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.NotSeller.selector, notSeller[i]));
            calls.collectStrike(listed);
            vm.stopPrank();
        }
        // The stranger holds nothing and is owed nothing on either listing.
        vm.startPrank(stranger);
        vm.expectRevert(CoveredCallsV2.NothingToCollect.selector);
        calls.claim(sold);
        vm.expectRevert(CoveredCallsV2.NothingToCollect.selector);
        calls.claim(listed);
        if (block.timestamp >= expiry && block.timestamp < uint256(expiry) + 1 days) {
            vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.ExceedsAvailable.selector, 1, 0));
            calls.exercise(sold, 1);
            vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.ExceedsAvailable.selector, 1, 0));
            calls.exercise(listed, 1);
        }
        vm.stopPrank();
        // The buyer of the listing holds nothing on the bid's sale, and the bidder nothing on the listing.
        if (block.timestamp >= expiry && block.timestamp < uint256(expiry) + 1 days) {
            vm.prank(buyer);
            vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.ExceedsAvailable.selector, 1, 0));
            calls.exercise(sold, 1);
            vm.prank(bidder);
            vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.ExceedsAvailable.selector, 1, 0));
            calls.exercise(listed, 1);
        }
        // Inside the term the seller has nothing to claim on the sold listing; the bidder never has
        // the seller's unexercised stock.
        if (block.timestamp < uint256(expiry) + 1 days) {
            vm.prank(seller);
            vm.expectRevert(CoveredCallsV2.NothingToCollect.selector);
            calls.claim(sold);
        }
        if (calls.owed(sold, bidder) == 0) {
            vm.prank(bidder);
            vm.expectRevert(CoveredCallsV2.NothingToCollect.selector);
            calls.claim(sold);
        }
    }

    // ---- overflow ----

    /// A bid or raise so large its escrow overflows reverts and leaves the bid as it was; a sale can
    /// never overflow, because it never prices more than a bid already paid for.
    function test_overflowingAmountsRevertAndChangeNothing() public {
        B20Double stock = new B20Double();
        UsdcDouble usdc = new UsdcDouble();
        StakingDouble staking = new StakingDouble(usdc);
        CoveredCallsV2 calls = new CoveredCallsV2(address(stock), address(usdc), address(staking));
        _fund(calls, address(stock), address(usdc), bidder);
        vm.startPrank(bidder);
        vm.expectRevert(FixedPointMathLib.MulDivFailed.selector);
        calls.bid(type(uint256).max / 2, 110 * USD, 3 * USD, expiry, 1);
        uint256 id = calls.bid(TOKEN, 110 * USD, 3 * USD, expiry, 1);
        vm.expectRevert(FixedPointMathLib.MulDivFailed.selector);
        calls.raiseBid(id, type(uint256).max / 4);
        vm.expectRevert(); // arithmetic overflow adding to the amount
        calls.raiseBid(id, type(uint256).max);
        vm.stopPrank();
        assertEq(calls.bids(id).amount, TOKEN);
        assertEq(usdc.balanceOf(address(calls)), 3 * USD);
    }
}
