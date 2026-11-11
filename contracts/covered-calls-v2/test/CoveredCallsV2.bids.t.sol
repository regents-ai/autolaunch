// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {CoveredCallsV2} from "../src/CoveredCallsV2.sol";
import {B20Double, ShortStaking, StakingDouble, UsdcDouble} from "./doubles/Doubles.sol";
import {WeeklyExpiry} from "./doubles/WeeklyExpiry.sol";

/// @notice Every bid function and every way it refuses: posting, raising, cancelling, selling into
///         and refunding a bid, the calls a sale creates, and the flows around them (partial and dust
///         sales, many sellers, one seller into many bids, a bid that expires unfilled, a corporate
///         action between bid and sale, a cancel or raise landing just before a sale).
contract CoveredCallsV2BidsTest is Test {
    uint256 internal constant TOKEN = 1e8;
    uint256 internal constant USD = 1e6;
    uint256 internal constant BIDDER_USDC = 1_000_000 * USD;
    uint64 internal expiry;

    B20Double internal stock;
    UsdcDouble internal usdc;
    StakingDouble internal staking;
    CoveredCallsV2 internal calls;

    address internal bidder = makeAddr("bidder");
    address internal seller = makeAddr("seller");
    address internal seller2 = makeAddr("seller2");
    address internal other = makeAddr("other");

    function setUp() public {
        vm.warp(1_800_000_000);
        expiry = WeeklyExpiry.next(block.timestamp, 0);
        stock = new B20Double();
        usdc = new UsdcDouble();
        staking = new StakingDouble(usdc);
        calls = new CoveredCallsV2(address(stock), address(usdc), address(staking));

        address[4] memory accounts = [bidder, seller, seller2, other];
        for (uint256 i; i < accounts.length; ++i) {
            stock.mint(accounts[i], 100 * TOKEN);
            usdc.mint(accounts[i], BIDDER_USDC);
            vm.startPrank(accounts[i]);
            stock.approve(address(calls), type(uint256).max);
            usdc.approve(address(calls), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// Ten tokens at a 110 strike and a 3 USDC premium per token: 30 USDC escrowed.
    function _bid() internal returns (uint256 id) {
        vm.prank(bidder);
        id = calls.bid(10 * TOKEN, 110 * USD, 3 * USD, expiry);
    }

    function _sell(address who, uint256 id, uint256 amount) internal returns (uint256 listingId) {
        vm.prank(who);
        listingId = calls.sellToBid(id, amount);
    }

    // ---- bid ----

    function test_bid_escrowsTheWholePremiumAndRecordsTerms() public {
        vm.expectEmit(address(calls));
        emit CoveredCallsV2.BidPosted(1, bidder, 10 * TOKEN, 110 * USD, 3 * USD, expiry, 30 * USD);
        uint256 id = _bid();
        assertEq(id, 1);
        assertEq(calls.bidCount(), 1);
        assertEq(usdc.balanceOf(address(calls)), 30 * USD);
        assertEq(usdc.balanceOf(bidder), BIDDER_USDC - 30 * USD);
        CoveredCallsV2.Bid memory b = calls.bids(id);
        assertEq(b.bidder, bidder);
        assertEq(b.expiry, expiry);
        assertEq(b.amount, 10 * TOKEN);
        assertEq(b.filled, 0);
        assertEq(b.strikePerToken, 110 * USD);
        assertEq(b.premiumPerToken, 3 * USD);
        assertEq(b.refundDue, 0);
        assertEq(calls.refundable(id), 0);
        assertEq(calls.listingCount(), 0);
    }

    /// The escrow rounds up exactly as a fill of the whole amount would charge.
    function test_bid_escrowRoundsUpLikeAFill() public {
        vm.prank(bidder);
        uint256 id = calls.bid(1, 110 * USD, 3 * USD, expiry);
        assertEq(usdc.balanceOf(address(calls)), 1);
        assertEq(calls.costFor(1, 3 * USD), 1);
        assertEq(calls.bids(id).amount, 1);
    }

    function test_bid_refusesZeroTermsAndPastOrOffGridExpiry() public {
        vm.startPrank(bidder);
        vm.expectRevert(CoveredCallsV2.ZeroAmount.selector);
        calls.bid(0, 110 * USD, 3 * USD, expiry);
        vm.expectRevert(CoveredCallsV2.ZeroAmount.selector);
        calls.bid(TOKEN, 0, 3 * USD, expiry);
        vm.expectRevert(CoveredCallsV2.ZeroAmount.selector);
        calls.bid(TOKEN, 110 * USD, 0, expiry);
        uint64 lastWeek = expiry - 1 weeks;
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.ExpiryPassed.selector, lastWeek));
        calls.bid(TOKEN, 110 * USD, 3 * USD, lastWeek);
        uint64 thursday = expiry - 1 days;
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.NotAWeeklyExpiry.selector, thursday));
        calls.bid(TOKEN, 110 * USD, 3 * USD, thursday);
        vm.stopPrank();
    }

    function test_bid_refusesAScheduledCorporateActionBeforeTheWindowCloses() public {
        uint256 at = uint256(expiry) + 1 days - 1;
        stock.schedule(at);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.CorporateActionScheduled.selector, at));
        calls.bid(TOKEN, 110 * USD, 3 * USD, expiry);
        stock.schedule(uint256(expiry) + 1 days);
        _bid();
    }

    function test_bid_failsWhenTheBiddersUsdcCannotMove() public {
        usdc.setPaused(true);
        vm.prank(bidder);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        calls.bid(TOKEN, 110 * USD, 3 * USD, expiry);
    }

    /// A bid needs no stock: posting one works while stock transfers are paused.
    function test_bid_worksWhileStockTransfersArePaused() public {
        stock.setPaused(true);
        _bid();
    }

    // ---- raiseBid ----

    function test_raiseBid_addsAmountAndEscrowAtTheSameTerms() public {
        uint256 id = _bid();
        assertEq(calls.raiseCostFor(id, 5 * TOKEN), 15 * USD);
        vm.expectEmit(address(calls));
        emit CoveredCallsV2.BidRaised(id, 5 * TOKEN, 15 * USD);
        vm.prank(bidder);
        calls.raiseBid(id, 5 * TOKEN);
        assertEq(calls.bids(id).amount, 15 * TOKEN);
        assertEq(usdc.balanceOf(address(calls)), 45 * USD);
        assertEq(usdc.balanceOf(bidder), BIDDER_USDC - 45 * USD);
    }

    /// Raising one raw unit at a time costs, in all, exactly what bidding the total at once would.
    function test_raiseBid_dustRaisesAddUpToOneBid() public {
        vm.prank(bidder);
        uint256 id = calls.bid(1, 110 * USD, 3 * USD, expiry); // 1 micro-USDC
        vm.startPrank(bidder);
        for (uint256 i; i < 99; ++i) {
            calls.raiseBid(id, 1);
        }
        vm.stopPrank();
        assertEq(calls.bids(id).amount, 100);
        assertEq(usdc.balanceOf(address(calls)), calls.costFor(100, 3 * USD));
        assertEq(usdc.balanceOf(address(calls)), 3);
    }

    function test_raiseBid_refusals() public {
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.UnknownBid.selector, 1));
        calls.raiseBid(1, TOKEN);
        uint256 id = _bid();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.NotBidder.selector, other));
        calls.raiseBid(id, TOKEN);
        vm.prank(bidder);
        vm.expectRevert(CoveredCallsV2.ZeroAmount.selector);
        calls.raiseBid(id, 0);
        uint256 at = block.timestamp + 1 hours;
        stock.schedule(at);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.CorporateActionScheduled.selector, at));
        calls.raiseBid(id, TOKEN);
        stock.schedule(0);
        vm.warp(expiry);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.FillsClosed.selector, expiry));
        calls.raiseBid(id, TOKEN);
    }

    /// A bid that sold out, or was cancelled, can ask for more at the same terms until expiry.
    function test_raiseBid_reopensASoldOutOrCancelledBid() public {
        uint256 id = _bid();
        _sell(seller, id, 4 * TOKEN);
        vm.prank(bidder);
        calls.cancelBid(id);
        assertEq(calls.bids(id).amount, 4 * TOKEN);
        vm.prank(bidder);
        calls.raiseBid(id, 2 * TOKEN);
        assertEq(calls.bids(id).amount, 6 * TOKEN);
        _sell(seller2, id, 2 * TOKEN);
        assertEq(calls.bids(id).filled, 6 * TOKEN);
        // 30 posted + 6 raised - 12 - 6 paid to sellers = 18, released by the cancel for the refund.
        assertEq(usdc.balanceOf(address(calls)), 18 * USD);
        assertEq(calls.refundable(id), 18 * USD);
    }

    // ---- cancelBid ----

    function test_cancelBid_stopsSalesAndReleasesOnlyTheUnspentEscrow() public {
        uint256 id = _bid();
        _sell(seller, id, 3 * TOKEN);
        vm.expectEmit(address(calls));
        emit CoveredCallsV2.BidClosed(id, 7 * TOKEN, 21 * USD);
        vm.prank(bidder);
        calls.cancelBid(id);
        CoveredCallsV2.Bid memory b = calls.bids(id);
        assertEq(b.amount, 3 * TOKEN);
        assertEq(b.filled, 3 * TOKEN);
        assertEq(b.refundDue, 21 * USD);
        assertEq(calls.refundable(id), 21 * USD);
        assertEq(usdc.balanceOf(address(calls)), 21 * USD); // nothing moved yet

        vm.prank(seller2);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.ExceedsAvailable.selector, 1, 0));
        calls.sellToBid(id, 1);
        vm.prank(bidder);
        vm.expectRevert(CoveredCallsV2.NothingToCollect.selector);
        calls.cancelBid(id);
        assertEq(calls.held(1, bidder), 3 * TOKEN); // what was sold stays the bidder's
    }

    function test_cancelBid_refusals() public {
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.UnknownBid.selector, 3));
        calls.cancelBid(3);
        uint256 id = _bid();
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.NotBidder.selector, seller));
        calls.cancelBid(id);
        _sell(seller, id, 10 * TOKEN);
        vm.prank(bidder);
        vm.expectRevert(CoveredCallsV2.NothingToCollect.selector);
        calls.cancelBid(id); // sold out: nothing left to stop
    }

    /// Cancelling moves no tokens, so a bidder can always stop sales: during a USDC pause, and while
    /// Circle has the bidder blacklisted (when sales would otherwise keep landing).
    function test_cancelBid_worksWhileUsdcIsPausedOrTheBidderBlacklisted() public {
        uint256 id = _bid();
        usdc.setBlacklisted(bidder, true);
        _sell(seller, id, TOKEN); // a sale never moves the bidder's USDC
        vm.prank(bidder);
        calls.cancelBid(id);
        vm.prank(seller2);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.ExceedsAvailable.selector, TOKEN, 0));
        calls.sellToBid(id, TOKEN);

        uint256 id2 = _bidAs(other);
        usdc.setPaused(true);
        vm.prank(other);
        calls.cancelBid(id2);
        assertEq(calls.refundable(id2), 30 * USD);
    }

    function _bidAs(address who) internal returns (uint256 id) {
        vm.prank(who);
        id = calls.bid(10 * TOKEN, 110 * USD, 3 * USD, expiry);
    }

    // ---- sellToBid ----

    function test_sellToBid_locksStockPaysTheSellerAndGivesTheBidderTheCalls() public {
        uint256 id = _bid();
        uint256 sellerUsdc = usdc.balanceOf(seller);
        (uint256 premium, uint256 fee) = calls.salePremiumFor(id, 4 * TOKEN);
        assertEq(premium, 12 * USD);
        assertEq(fee, 120_000);
        vm.expectEmit(address(calls));
        emit CoveredCallsV2.SoldToBid(id, 1, seller, 4 * TOKEN, 12 * USD, 120_000);
        uint256 listingId = _sell(seller, id, 4 * TOKEN);
        assertEq(listingId, 1);

        assertEq(stock.balanceOf(address(calls)), 4 * TOKEN);
        assertEq(stock.balanceOf(seller), 96 * TOKEN);
        assertEq(usdc.balanceOf(seller) - sellerUsdc, 12 * USD - 120_000);
        assertEq(staking.deposited(), 120_000);
        assertEq(staking.lastTag(), bytes32("autolaunch-covered-calls"));
        assertEq(staking.lastRef(), bytes32(listingId));
        assertEq(usdc.balanceOf(address(calls)), 18 * USD); // the rest of the escrow
        assertEq(usdc.allowance(address(calls), address(staking)), 0);
        assertEq(calls.bids(id).filled, 4 * TOKEN);
        assertEq(calls.held(listingId, bidder), 4 * TOKEN);

        CoveredCallsV2.Listing memory l = calls.listings(listingId);
        assertEq(l.seller, seller);
        assertEq(l.expiry, expiry);
        assertEq(l.amount, 4 * TOKEN);
        assertEq(l.filled, 4 * TOKEN);
        assertEq(l.exercised, 0);
        assertEq(l.strikePerToken, 110 * USD);
        assertEq(l.premiumPerToken, 3 * USD);
        assertFalse(l.stockReturned);
    }

    /// The listing a sale creates is fully filled: nobody can fill it again and its seller has
    /// nothing to cancel.
    function test_sellToBid_createsAListingThatCannotBeFilledOrCancelled() public {
        uint256 id = _bid();
        uint256 listingId = _sell(seller, id, 4 * TOKEN);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.ExceedsAvailable.selector, 1, 0));
        calls.fill(listingId, 1);
        vm.prank(seller);
        vm.expectRevert(CoveredCallsV2.NothingToCollect.selector);
        calls.cancel(listingId);
    }

    function test_sellToBid_refusals() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.UnknownBid.selector, 1));
        calls.sellToBid(1, TOKEN);
        uint256 id = _bid();
        vm.prank(seller);
        vm.expectRevert(CoveredCallsV2.ZeroAmount.selector);
        calls.sellToBid(id, 0);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.ExceedsAvailable.selector, 10 * TOKEN + 1, 10 * TOKEN));
        calls.sellToBid(id, 10 * TOKEN + 1);
        uint256 at = uint256(expiry);
        stock.schedule(at);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.CorporateActionScheduled.selector, at));
        calls.sellToBid(id, TOKEN);
        stock.schedule(0);
        vm.warp(expiry);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.FillsClosed.selector, expiry));
        calls.sellToBid(id, TOKEN);
    }

    /// If any part of a sale fails, nothing moves: the seller's stock cannot move, USDC cannot move or
    /// reach the seller, or staking refuses the fee.
    function test_sellToBid_isAllOrNothing() public {
        uint256 id = _bid();
        uint256 escrow = usdc.balanceOf(address(calls));

        stock.setPaused(true);
        vm.prank(seller);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        calls.sellToBid(id, TOKEN);
        stock.setPaused(false);

        stock.setBlocked(seller, true);
        vm.prank(seller);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        calls.sellToBid(id, TOKEN);
        stock.setBlocked(seller, false);

        usdc.setPaused(true);
        vm.prank(seller);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        calls.sellToBid(id, TOKEN);
        usdc.setPaused(false);

        usdc.setBlacklisted(seller, true);
        vm.prank(seller);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        calls.sellToBid(id, TOKEN);
        usdc.setBlacklisted(seller, false);

        staking.setRefuses(true);
        vm.prank(seller);
        vm.expectRevert(bytes("staking paused"));
        calls.sellToBid(id, TOKEN);
        staking.setRefuses(false);

        assertEq(calls.bids(id).filled, 0);
        assertEq(calls.listingCount(), 0);
        assertEq(usdc.balanceOf(address(calls)), escrow);
        assertEq(stock.balanceOf(address(calls)), 0);
        assertEq(stock.balanceOf(seller), 100 * TOKEN);
        _sell(seller, id, TOKEN);
    }

    /// A sale never touches the bidder's balance, so a bidder Circle has blacklisted can still be
    /// sold into; only its own refund waits until the blacklist lifts.
    function test_sellToBid_worksWhileTheBidderIsBlacklisted() public {
        uint256 id = _bid();
        usdc.setBlacklisted(bidder, true);

        uint256 listingId = _sell(seller, id, 4 * TOKEN);
        assertEq(calls.held(listingId, bidder), 4 * TOKEN);
        assertEq(usdc.balanceOf(seller), BIDDER_USDC + 12 * USD - 120_000);
        vm.prank(bidder);
        calls.cancelBid(id);
        vm.prank(bidder);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        calls.refundBid(id);

        usdc.setBlacklisted(bidder, false);
        vm.prank(bidder);
        calls.refundBid(id);
        assertEq(usdc.balanceOf(bidder), BIDDER_USDC - 12 * USD);
        assertEq(usdc.balanceOf(address(calls)), 0);
    }

    /// Staking must take exactly the fee: a partial pull or a wrong report reverts the sale, so no
    /// allowance on the escrow is ever left behind.
    function test_sellToBid_feeMustReachStakingExactly() public {
        ShortStaking short = new ShortStaking(usdc);
        CoveredCallsV2 c = new CoveredCallsV2(address(stock), address(usdc), address(short));
        vm.startPrank(bidder);
        usdc.approve(address(c), type(uint256).max);
        uint256 id = c.bid(10 * TOKEN, 110 * USD, 3 * USD, expiry);
        vm.stopPrank();
        vm.prank(seller);
        stock.approve(address(c), type(uint256).max);

        short.set(true, false);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.DepositMismatch.selector, 120_000, 60_000));
        c.sellToBid(id, 4 * TOKEN);
        short.set(false, true);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.DepositMismatch.selector, 120_000, 120_001));
        c.sellToBid(id, 4 * TOKEN);
        assertEq(usdc.balanceOf(address(c)), 30 * USD);
    }

    /// A dust sale whose premium rounds to nothing pays nothing and calls staking not at all; the next
    /// sale carries the rounding, so the bid's sellers together are still paid its rounded-up premium.
    function test_sellToBid_dustSalesShareTheRoundingAndNeverOverdrawTheEscrow() public {
        vm.prank(bidder);
        uint256 id = calls.bid(100, 110 * USD, 3 * USD, expiry); // 100 raw at 3 USDC/token = 3 micro-USDC
        assertEq(usdc.balanceOf(address(calls)), 3);

        (uint256 p1, uint256 f1) = calls.salePremiumFor(id, 1);
        assertEq(p1, 1); // ceil(0.03)
        assertEq(f1, 1); // ceil(0.01): the whole premium
        _sell(seller, id, 1);
        (uint256 p2, uint256 f2) = calls.salePremiumFor(id, 1);
        assertEq(p2, 0); // ceil(0.06) - ceil(0.03)
        assertEq(f2, 0);
        uint256 deposits = staking.deposited();
        _sell(seller2, id, 1);
        assertEq(staking.deposited(), deposits); // no fee, no staking call
        _sell(seller2, id, 98);

        assertEq(calls.bids(id).filled, 100);
        assertEq(usdc.balanceOf(address(calls)), 0);
        assertEq(staking.deposited(), 1); // ceil(1% of 3)
        assertEq(usdc.balanceOf(seller) + usdc.balanceOf(seller2), 2 * BIDDER_USDC + 2);
        assertEq(calls.refundable(id), 0);
    }

    // ---- refundBid ----

    function test_refundBid_paysWhatCancelReleasedOnce() public {
        uint256 id = _bid();
        _sell(seller, id, 3 * TOKEN);
        vm.prank(bidder);
        calls.cancelBid(id);
        vm.expectEmit(address(calls));
        emit CoveredCallsV2.BidRefunded(id, 21 * USD);
        vm.prank(bidder);
        calls.refundBid(id);
        assertEq(usdc.balanceOf(bidder), BIDDER_USDC - 9 * USD); // paid for the 3 sold, no more
        assertEq(usdc.balanceOf(address(calls)), 0);
        assertEq(calls.refundable(id), 0);
        vm.prank(bidder);
        vm.expectRevert(CoveredCallsV2.NothingToCollect.selector);
        calls.refundBid(id);
    }

    function test_refundBid_refusals() public {
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.UnknownBid.selector, 1));
        calls.refundBid(1);
        uint256 id = _bid();
        vm.prank(bidder);
        vm.expectRevert(CoveredCallsV2.NothingToCollect.selector);
        calls.refundBid(id); // still open, nothing released
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.NotBidder.selector, seller));
        calls.refundBid(id);
        vm.prank(bidder);
        calls.cancelBid(id);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.NotBidder.selector, other));
        calls.refundBid(id); // released escrow is the bidder's alone
    }

    /// A bid nobody sold into comes back whole after its expiry, in one call, with no deadline.
    function test_refundBid_anUnfilledBidComesBackWholeAfterExpiryWithNoDeadline() public {
        uint256 id = _bid();
        vm.warp(expiry);
        assertEq(calls.refundable(id), 30 * USD);
        vm.warp(uint256(expiry) + 3 * 365 days);
        vm.expectEmit(address(calls));
        emit CoveredCallsV2.BidClosed(id, 10 * TOKEN, 30 * USD);
        vm.expectEmit(address(calls));
        emit CoveredCallsV2.BidRefunded(id, 30 * USD);
        vm.prank(bidder);
        calls.refundBid(id);
        assertEq(usdc.balanceOf(bidder), BIDDER_USDC);
        assertEq(calls.bids(id).amount, 0);
        vm.prank(bidder);
        vm.expectRevert(CoveredCallsV2.NothingToCollect.selector);
        calls.cancelBid(id);
    }

    /// A partly sold bid refunds exactly the escrow behind its unsold part after expiry.
    function test_refundBid_aPartlySoldBidRefundsTheUnsoldEscrowAfterExpiry() public {
        uint256 id = _bid();
        _sell(seller, id, 3 * TOKEN + 7);
        uint256 expected = calls.costFor(10 * TOKEN, 3 * USD) - calls.costFor(3 * TOKEN + 7, 3 * USD);
        vm.warp(expiry);
        assertEq(calls.refundable(id), expected);
        vm.prank(bidder);
        calls.refundBid(id);
        assertEq(usdc.balanceOf(address(calls)), 0);
        assertEq(BIDDER_USDC - usdc.balanceOf(bidder), calls.costFor(3 * TOKEN + 7, 3 * USD));
    }

    /// A refund moves only USDC, so a stock pause never holds it up; a USDC pause or a blacklisting
    /// only delays it, and the escrow stays booked.
    function test_refundBid_onlyWaitsOnUsdc() public {
        uint256 id = _bid();
        vm.prank(bidder);
        calls.cancelBid(id);
        stock.setPaused(true);
        usdc.setBlacklisted(bidder, true);
        vm.prank(bidder);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        calls.refundBid(id);
        assertEq(calls.refundable(id), 30 * USD);
        usdc.setBlacklisted(bidder, false);
        vm.prank(bidder);
        calls.refundBid(id);
        assertEq(usdc.balanceOf(bidder), BIDDER_USDC);
    }

    // ---- views ----

    function test_views_refuseUnknownBids() public {
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.UnknownBid.selector, 1));
        calls.bids(1);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.UnknownBid.selector, 1));
        calls.refundable(1);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.UnknownBid.selector, 1));
        calls.salePremiumFor(1, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.UnknownBid.selector, 1));
        calls.raiseCostFor(1, TOKEN);
        _bid();
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.UnknownBid.selector, 0));
        calls.bids(0);
    }

    function test_views_listingsAndBidsCountSeparately() public {
        vm.prank(seller);
        calls.list(TOKEN, 110 * USD, 3 * USD, expiry);
        uint256 id = _bid();
        assertEq(id, 1);
        assertEq(_sell(seller2, id, TOKEN), 2);
        assertEq(calls.listingCount(), 2);
        assertEq(calls.bidCount(), 1);
    }

    // ---- after the sale: the same life as a listed call ----

    /// Stock rises: the bidder exercises the calls it bought by bid, collects the stock, and the
    /// seller collects the strike and takes back what was not exercised.
    function test_life_bidderExercisesAndSellerCollects() public {
        uint256 id = _bid();
        uint256 listingId = _sell(seller, id, 4 * TOKEN);
        vm.warp(expiry);
        vm.prank(bidder);
        calls.exercise(listingId, 3 * TOKEN);
        assertEq(calls.owed(listingId, bidder), 3 * TOKEN);
        vm.prank(bidder);
        calls.claim(listingId);
        assertEq(stock.balanceOf(bidder), 103 * TOKEN);

        vm.prank(seller);
        calls.collectStrike(listingId);
        assertEq(usdc.balanceOf(seller), BIDDER_USDC + 12 * USD - 120_000 + 330 * USD);

        vm.warp(uint256(expiry) + 1 days);
        assertEq(calls.claimable(listingId, seller), TOKEN);
        vm.prank(seller);
        calls.claim(listingId);
        assertEq(stock.balanceOf(seller), 97 * TOKEN);
        vm.prank(bidder);
        calls.refundBid(id);
        assertEq(stock.balanceOf(address(calls)), 0);
        assertEq(usdc.balanceOf(address(calls)), 0);
    }

    /// Stock falls: nothing is exercised; the seller keeps the premium and takes the stock back.
    function test_life_unexercisedSaleReturnsTheStock() public {
        uint256 id = _bid();
        uint256 listingId = _sell(seller, id, 10 * TOKEN);
        vm.warp(uint256(expiry) + 1 days);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.OutsideExerciseWindow.selector, expiry));
        calls.exercise(listingId, TOKEN);
        vm.prank(seller);
        calls.claim(listingId);
        assertEq(stock.balanceOf(seller), 100 * TOKEN);
        assertEq(usdc.balanceOf(seller), BIDDER_USDC + 30 * USD - 300_000);
        vm.prank(bidder);
        vm.expectRevert(CoveredCallsV2.NothingToCollect.selector);
        calls.refundBid(id); // all of it was spent
    }

    /// Selling into your own bid loses only the fee.
    function test_life_sellingIntoYourOwnBidLosesOnlyTheFee() public {
        uint256 id = _bid();
        uint256 listingId = _sell(bidder, id, 10 * TOKEN);
        vm.warp(expiry);
        vm.startPrank(bidder);
        calls.exercise(listingId, 10 * TOKEN);
        calls.collectStrike(listingId);
        calls.claim(listingId);
        vm.stopPrank();
        assertEq(stock.balanceOf(bidder), 100 * TOKEN);
        assertEq(usdc.balanceOf(bidder), BIDDER_USDC - 300_000);
    }

    // ---- flows ----

    /// Several sellers fill one bid in parts; each gets a listing of its own, the bidder holds all the
    /// calls, and together the sellers are paid exactly what one fill of the whole would pay.
    function test_flow_aBidFilledByManySellers() public {
        uint256 id = _bid();
        address[3] memory sellers = [seller, seller2, other];
        uint256[3] memory parts = [uint256(3 * TOKEN + 1), 5 * TOKEN - 1, 2 * TOKEN];
        uint256 premiums;
        for (uint256 i; i < 3; ++i) {
            uint256 before = usdc.balanceOf(sellers[i]);
            (uint256 premium, uint256 fee) = calls.salePremiumFor(id, parts[i]);
            uint256 listingId = _sell(sellers[i], id, parts[i]);
            assertEq(usdc.balanceOf(sellers[i]) - before, premium - fee);
            assertEq(calls.held(listingId, bidder), parts[i]);
            assertEq(calls.listings(listingId).seller, sellers[i]);
            premiums += premium;
        }
        assertEq(premiums, 30 * USD);
        assertEq(staking.deposited(), 300_000);
        assertEq(usdc.balanceOf(address(calls)), 0);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.ExceedsAvailable.selector, 1, 0));
        calls.sellToBid(id, 1);
    }

    /// One seller sells into three bids at different strikes and expiries; each sale is its own
    /// listing on its own bid's terms, and each bid's escrow pays only its own sale.
    function test_flow_aSellerSellsIntoManyBids() public {
        uint64 later = WeeklyExpiry.next(block.timestamp, 2);
        vm.startPrank(bidder);
        uint256 a = calls.bid(5 * TOKEN, 110 * USD, 3 * USD, expiry);
        uint256 b = calls.bid(5 * TOKEN, 120 * USD, 2 * USD, later);
        vm.stopPrank();
        vm.prank(other);
        uint256 c = calls.bid(5 * TOKEN, 100 * USD, 5 * USD, expiry);

        uint256 before = usdc.balanceOf(seller);
        uint256 la = _sell(seller, a, 2 * TOKEN); // 6 USDC
        uint256 lb = _sell(seller, b, 5 * TOKEN); // 10 USDC
        uint256 lc = _sell(seller, c, TOKEN); // 5 USDC
        assertEq(usdc.balanceOf(seller) - before, 21 * USD - 210_000);
        assertEq(stock.balanceOf(seller), 92 * TOKEN);
        assertEq(calls.listings(lb).strikePerToken, 120 * USD);
        assertEq(calls.listings(lb).expiry, later);
        assertEq(calls.held(la, bidder), 2 * TOKEN);
        assertEq(calls.held(lb, bidder), 5 * TOKEN);
        assertEq(calls.held(lc, other), TOKEN);
        assertEq(calls.held(lc, bidder), 0);
        assertEq(calls.refundable(a) + calls.refundable(b) + calls.refundable(c), 0);
        vm.warp(expiry);
        assertEq(calls.refundable(a), 9 * USD);
        assertEq(calls.refundable(b), 0); // its expiry is two weeks later
        assertEq(calls.refundable(c), 20 * USD);
    }

    /// A corporate action scheduled between bid and sale stops sales until it takes effect; the
    /// bidder can still cancel and be refunded meanwhile, and sales resume on the same raw terms.
    function test_flow_corporateActionBetweenBidAndSale() public {
        uint256 id = _bid();
        uint256 id2 = _bidAs(other);
        uint256 at = block.timestamp + 1 hours;
        stock.schedule(at);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.CorporateActionScheduled.selector, at));
        calls.sellToBid(id, TOKEN);
        vm.startPrank(other);
        calls.cancelBid(id2);
        calls.refundBid(id2);
        vm.stopPrank();
        assertEq(usdc.balanceOf(other), BIDDER_USDC);

        vm.warp(at);
        uint256 listingId = _sell(seller, id, TOKEN);
        assertEq(calls.held(listingId, bidder), TOKEN);
    }

    /// The bidder cancels in the same block just before a seller's sale: the sale reverts and moves
    /// nothing. A raise landing first changes nothing about the sale's terms or price.
    function test_flow_cancelOrRaiseJustBeforeASale() public {
        uint256 id = _bid();
        (uint256 quoted, uint256 quotedFee) = calls.salePremiumFor(id, 4 * TOKEN);
        vm.prank(bidder);
        calls.raiseBid(id, 7 * TOKEN + 3);
        uint256 before = usdc.balanceOf(seller);
        uint256 listingId = _sell(seller, id, 4 * TOKEN);
        assertEq(usdc.balanceOf(seller) - before, quoted - quotedFee);
        assertEq(calls.listings(listingId).premiumPerToken, 3 * USD);
        assertEq(calls.listings(listingId).strikePerToken, 110 * USD);

        vm.prank(bidder);
        calls.cancelBid(id);
        uint256 stockBefore = stock.balanceOf(seller2);
        uint256 usdcBefore = usdc.balanceOf(seller2);
        vm.prank(seller2);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallsV2.ExceedsAvailable.selector, TOKEN, 0));
        calls.sellToBid(id, TOKEN);
        assertEq(stock.balanceOf(seller2), stockBefore);
        assertEq(usdc.balanceOf(seller2), usdcBefore);
    }

    /// Another seller's sale landing first can move a sale's premium by at most one micro-USDC of
    /// rounding, never more.
    function testFuzz_flow_anotherSaleFirstMovesThePriceByAtMostOneMicro(
        uint256 amount,
        uint256 first,
        uint256 premiumPerToken
    ) public {
        premiumPerToken = bound(premiumPerToken, 1, 10_000 * USD);
        usdc.mint(bidder, 1e18);
        vm.prank(bidder);
        uint256 id = calls.bid(50 * TOKEN, 110 * USD, premiumPerToken, expiry);
        amount = bound(amount, 1, 25 * TOKEN);
        first = bound(first, 1, 25 * TOKEN);
        (uint256 quoted,) = calls.salePremiumFor(id, amount);
        _sell(seller2, id, first);
        (uint256 premium,) = calls.salePremiumFor(id, amount);
        assertLe(premium, quoted + 1);
        assertGe(premium + 1, quoted);
        uint256 exact = amount * premiumPerToken / TOKEN; // floor
        assertGe(premium, exact);
        assertLe(premium, exact + 1);
    }
}
