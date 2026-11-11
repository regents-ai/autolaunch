// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {CoveredCallsV2} from "../src/CoveredCallsV2.sol";
import {B20Double, StakingDouble, UsdcDouble} from "./doubles/Doubles.sol";
import {WeeklyExpiry} from "./doubles/WeeklyExpiry.sol";

/// @notice Drives random sequences of every call, listings and bids alike, by several accounts across
///         time, with the stock's transfer pause and blocklist, USDC's pause and blacklist, scheduled
///         corporate actions and a refusing staking contract switched on and off, and keeps its own
///         books from token balances: what each bidder paid in and got back, what each bid's sellers
///         were paid, and every fee.
contract CoveredCallsV2Handler is Test {
    uint256 internal constant UNIT = 1e8;

    CoveredCallsV2 public immutable calls;
    B20Double public immutable stock;
    UsdcDouble public immutable usdc;
    StakingDouble public immutable staking;

    address[] public actors;
    /// Raw stock each listing locked when it was made (by `list`, or by a sale into a bid).
    mapping(uint256 listingId => uint256) public listedOf;
    mapping(uint256 listingId => uint256) public claimedOf;
    /// The bid a sale's listing came from; zero for a listing made by `list`.
    mapping(uint256 listingId => uint256) public bidOf;
    /// USDC a bidder paid into its bid (posting and raises), and got back by refund, measured on its
    /// balance.
    mapping(uint256 bidId => uint256) public paidIn;
    mapping(uint256 bidId => uint256) public refunded;
    /// USDC the sales into a bid paid out, premium including fee, measured on the sellers' and
    /// staking's balances; and the fee part alone.
    mapping(uint256 bidId => uint256) public salesPaid;
    mapping(uint256 bidId => uint256) public salesFees;
    /// Fees on fills, worked out here from the listing's terms.
    uint256 public fillFeesExpected;
    /// Claims and refunds that paid something other than `claimable` / `refundable` just before.
    uint256 public mismatches;
    mapping(bytes4 selector => uint256) public succeeded;

    constructor(CoveredCallsV2 calls_, B20Double stock_, UsdcDouble usdc_, StakingDouble staking_) {
        calls = calls_;
        stock = stock_;
        usdc = usdc_;
        staking = staking_;
        for (uint256 i; i < 4; ++i) {
            address actor = address(uint160(0xA000 + i));
            actors.push(actor);
            stock.mint(actor, 1_000e8);
            usdc.mint(actor, 1e15);
            vm.startPrank(actor);
            stock.approve(address(calls), type(uint256).max);
            usdc.approve(address(calls), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// Premium or strike for `amount` raw at `perToken`, rounded up, worked out here.
    function cost(uint256 amount, uint256 perToken) public pure returns (uint256) {
        return (amount * perToken + UNIT - 1) / UNIT;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _someListing(uint256 seed) internal view returns (uint256) {
        uint256 count = calls.listingCount();
        return count == 0 ? 0 : 1 + seed % count;
    }

    function _someBid(uint256 seed) internal view returns (uint256) {
        uint256 count = calls.bidCount();
        return count == 0 ? 0 : 1 + seed % count;
    }

    /// A listing still open to fills, searched from the seeded one, or zero when none is.
    function _openListing(uint256 seed) internal view returns (uint256) {
        uint256 count = calls.listingCount();
        for (uint256 i; i < count; ++i) {
            uint256 id = 1 + (seed % count + i) % count;
            CoveredCallsV2.Listing memory l = calls.listings(id);
            if (l.amount != l.filled && block.timestamp < l.expiry) return id;
        }
        return 0;
    }

    /// A listing and an account holding calls on it whose exercise window has not closed, searched
    /// from the seeded ones, or zero when there is none.
    function _holding(uint256 listingSeed, uint256 who) internal view returns (uint256, address) {
        uint256 count = calls.listingCount();
        for (uint256 i; i < count; ++i) {
            uint256 id = 1 + (listingSeed % count + i) % count;
            if (block.timestamp >= uint256(calls.listings(id).expiry) + calls.EXERCISE_WINDOW()) continue;
            for (uint256 a; a < actors.length; ++a) {
                address holder = _actor(who % actors.length + a);
                if (calls.held(id, holder) != 0) return (id, holder);
            }
        }
        return (0, address(0));
    }

    /// A bid still open to sales, searched from the seeded one, or zero when none is.
    function _openBid(uint256 seed) internal view returns (uint256) {
        uint256 count = calls.bidCount();
        for (uint256 i; i < count; ++i) {
            uint256 id = 1 + (seed % count + i) % count;
            CoveredCallsV2.Bid memory b = calls.bids(id);
            if (b.amount != b.filled && block.timestamp < b.expiry) return id;
        }
        return 0;
    }

    // ---- listings ----

    function list(uint256 who, uint256 amount, uint256 strike, uint256 premium, uint256 weeksAhead) external {
        amount = bound(amount, 1, 50e8);
        strike = bound(strike, 1, 1_000e6);
        premium = bound(premium, 1, 100e6);
        uint64 expiry = WeeklyExpiry.next(block.timestamp, bound(weeksAhead, 0, 2));
        vm.prank(_actor(who));
        try calls.list(amount, strike, premium, expiry) returns (uint256 id) {
            listedOf[id] = amount;
            ++succeeded[this.list.selector];
        } catch {}
    }

    function fill(uint256 who, uint256 listingSeed, uint256 amount) external {
        uint256 id = _openListing(listingSeed);
        if (id == 0) return;
        CoveredCallsV2.Listing memory l = calls.listings(id);
        amount = bound(amount, 1, l.amount - l.filled);
        uint256 premium = cost(amount, l.premiumPerToken);
        vm.prank(_actor(who));
        try calls.fill(id, amount) {
            fillFeesExpected += (premium + 99) / 100;
            ++succeeded[this.fill.selector];
        } catch {}
    }

    function cancel(uint256 listingSeed) external {
        uint256 id = _openListing(listingSeed);
        if (id == 0) return;
        vm.prank(calls.listings(id).seller);
        try calls.cancel(id) {
            ++succeeded[this.cancel.selector];
        } catch {}
    }

    /// An account holding calls on a listing whose exercise window has not closed exercises some of
    /// them, searched from the seeded listing and account.
    function exercise(uint256 who, uint256 listingSeed, uint256 amount, uint256 into) external {
        (uint256 id, address holder) = _holding(listingSeed, who);
        if (id == 0) return;
        uint256 holding = calls.held(id, holder);
        // Time only moves forward: step into the listing's exercise window when it is still ahead.
        uint256 expiry = calls.listings(id).expiry;
        if (block.timestamp < expiry) vm.warp(expiry + bound(into, 0, 1 days - 1));
        vm.prank(holder);
        try calls.exercise(id, bound(amount, 1, holding)) {
            ++succeeded[this.exercise.selector];
        } catch {}
    }

    /// Half the time the seller claims, stepping past the window first when asked; otherwise an
    /// account owed stock on the listing claims.
    function claim(uint256 who, uint256 listingSeed, bool sellerAfterWindow) external {
        uint256 id = _someListing(listingSeed);
        if (id == 0) return;
        address account;
        if (who % 2 == 0) {
            account = calls.listings(id).seller;
            uint256 windowEnd = uint256(calls.listings(id).expiry) + calls.EXERCISE_WINDOW();
            if (sellerAfterWindow && block.timestamp < windowEnd) vm.warp(windowEnd);
        } else {
            account = _actor(who);
            for (uint256 i; i < actors.length && calls.owed(id, account) == 0; ++i) {
                account = _actor(who % actors.length + i);
            }
        }
        uint256 before = stock.balanceOf(account);
        uint256 shown = calls.claimable(id, account);
        vm.prank(account);
        try calls.claim(id) {
            uint256 paid = stock.balanceOf(account) - before;
            claimedOf[id] += paid;
            if (paid != shown) ++mismatches;
            ++succeeded[this.claim.selector];
        } catch {}
    }

    /// A seller collects strike paid on one of its listings, searched from the seeded one.
    function collectStrike(uint256 listingSeed) external {
        uint256 id;
        uint256 count = calls.listingCount();
        for (uint256 i; i < count && id == 0; ++i) {
            uint256 candidate = 1 + (listingSeed % count + i) % count;
            CoveredCallsV2.Listing memory l = calls.listings(candidate);
            if (l.strikePaid != l.strikeCollected) id = candidate;
        }
        if (id == 0) return;
        vm.prank(calls.listings(id).seller);
        try calls.collectStrike(id) {
            ++succeeded[this.collectStrike.selector];
        } catch {}
    }

    // ---- bids ----

    function bid(uint256 who, uint256 amount, uint256 strike, uint256 premium, uint256 weeksAhead) external {
        address bidder = _actor(who);
        amount = bound(amount, 1, 50e8);
        strike = bound(strike, 1, 1_000e6);
        premium = bound(premium, 1, 100e6);
        uint64 expiry = WeeklyExpiry.next(block.timestamp, bound(weeksAhead, 0, 2));
        uint256 before = usdc.balanceOf(bidder);
        vm.prank(bidder);
        try calls.bid(amount, strike, premium, expiry) returns (uint256 id) {
            paidIn[id] += before - usdc.balanceOf(bidder);
            ++succeeded[this.bid.selector];
        } catch {}
    }

    function raiseBid(uint256 bidSeed, uint256 amount) external {
        uint256 id = _openBid(bidSeed);
        if (id == 0) return;
        address bidder = calls.bids(id).bidder;
        uint256 before = usdc.balanceOf(bidder);
        vm.prank(bidder);
        try calls.raiseBid(id, bound(amount, 1, 20e8)) {
            paidIn[id] += before - usdc.balanceOf(bidder);
            ++succeeded[this.raiseBid.selector];
        } catch {}
    }

    function cancelBid(uint256 bidSeed) external {
        uint256 id = _openBid(bidSeed);
        if (id == 0) return;
        vm.prank(calls.bids(id).bidder);
        try calls.cancelBid(id) {
            ++succeeded[this.cancelBid.selector];
        } catch {}
    }

    /// Sells part of a bid, half the time in dust so the bid's rounding is exercised.
    function sellToBid(uint256 who, uint256 bidSeed, uint256 amount) external {
        uint256 id = _openBid(bidSeed);
        if (id == 0) return;
        CoveredCallsV2.Bid memory b = calls.bids(id);
        uint256 left = b.amount - b.filled;
        amount = amount % 2 == 0 ? bound(amount, 1, left < 1_000 ? left : 1_000) : bound(amount, 1, left);
        address seller = _actor(who);
        uint256 sellerBefore = usdc.balanceOf(seller);
        uint256 feesBefore = staking.deposited();
        vm.prank(seller);
        try calls.sellToBid(id, amount) returns (uint256 listingId) {
            uint256 fee = staking.deposited() - feesBefore;
            salesPaid[id] += usdc.balanceOf(seller) - sellerBefore + fee;
            salesFees[id] += fee;
            listedOf[listingId] = amount;
            bidOf[listingId] = id;
            ++succeeded[this.sellToBid.selector];
        } catch {}
    }

    /// The bidder takes its refund, stepping past the bid's expiry first when asked.
    function refundBid(uint256 bidSeed, bool afterExpiry) external {
        uint256 id = _someBid(bidSeed);
        if (id == 0) return;
        CoveredCallsV2.Bid memory b = calls.bids(id);
        if (afterExpiry && block.timestamp < b.expiry) vm.warp(b.expiry);
        uint256 shown = calls.refundable(id);
        uint256 before = usdc.balanceOf(b.bidder);
        vm.prank(b.bidder);
        try calls.refundBid(id) {
            uint256 paid = usdc.balanceOf(b.bidder) - before;
            refunded[id] += paid;
            if (paid != shown) ++mismatches;
            ++succeeded[this.refundBid.selector];
        } catch {}
    }

    // ---- the world ----

    function passTime(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 6 hours));
    }

    /// Switches one restriction on (one time in eight) or off: the stock's transfer pause or blocklist
    /// on an actor, USDC's pause or blacklist on an actor, or staking refusing deposits. Zero, the
    /// fuzzer's favourite value, switches the stock's pause off, so restrictions stay the exception
    /// and most calls get through.
    function restrict(uint256 seed, uint256 who) external {
        bool on = seed % 8 == 1;
        uint256 kind = (seed / 8) % 5;
        if (kind == 0) stock.setPaused(on);
        else if (kind == 1) stock.setBlocked(_actor(who), on);
        else if (kind == 2) usdc.setPaused(on);
        else if (kind == 3) usdc.setBlacklisted(_actor(who), on);
        else staking.setRefuses(on);
    }

    /// Schedules a corporate action up to 20 days out one time in eight, and otherwise clears it; zero
    /// clears it.
    function scheduleCorporateAction(uint256 inSeconds) external {
        stock.schedule(inSeconds % 8 == 1 ? block.timestamp + bound(inSeconds, 0, 20 days) : 0);
    }

    /// Lifts every restriction, moves past every exercise window, and has every account take all it
    /// is owed and every bidder its refund. Called once a run ends.
    function recoverEverything() external {
        stock.setPaused(false);
        usdc.setPaused(false);
        for (uint256 a; a < actors.length; ++a) {
            stock.setBlocked(actors[a], false);
            usdc.setBlacklisted(actors[a], false);
        }
        vm.warp(block.timestamp + 22 days + calls.EXERCISE_WINDOW());
        for (uint256 id = 1; id <= calls.listingCount(); ++id) {
            CoveredCallsV2.Listing memory l = calls.listings(id);
            if (l.strikePaid != l.strikeCollected) {
                vm.prank(l.seller);
                calls.collectStrike(id);
            }
            for (uint256 a; a < actors.length; ++a) {
                address account = actors[a];
                if (calls.claimable(id, account) != 0) {
                    uint256 before = stock.balanceOf(account);
                    vm.prank(account);
                    calls.claim(id);
                    claimedOf[id] += stock.balanceOf(account) - before;
                }
            }
        }
        for (uint256 id = 1; id <= calls.bidCount(); ++id) {
            if (calls.refundable(id) == 0) continue;
            address bidder = calls.bids(id).bidder;
            uint256 before = usdc.balanceOf(bidder);
            vm.prank(bidder);
            calls.refundBid(id);
            refunded[id] += usdc.balanceOf(bidder) - before;
        }
    }
}

contract CoveredCallsV2InvariantTest is Test {
    CoveredCallsV2 internal calls;
    B20Double internal stock;
    UsdcDouble internal usdc;
    StakingDouble internal staking;
    CoveredCallsV2Handler internal handler;
    uint256 internal stockSupply;
    uint256 internal usdcSupply;

    function setUp() public {
        vm.warp(1_800_000_000);
        stock = new B20Double();
        usdc = new UsdcDouble();
        staking = new StakingDouble(usdc);
        calls = new CoveredCallsV2(address(stock), address(usdc), address(staking));
        handler = new CoveredCallsV2Handler(calls, stock, usdc, staking);
        stockSupply = stock.totalSupply();
        usdcSupply = usdc.totalSupply();
        bytes4[] memory endOnly = new bytes4[](1);
        endOnly[0] = handler.recoverEverything.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: endOnly}));
        targetContract(address(handler));
    }

    /// The escrow a bid still holds, worked out from its terms: the premium for everything it asks
    /// for less the premium for everything sold, plus what closing it released.
    function _escrow(CoveredCallsV2.Bid memory b) internal view returns (uint256) {
        return handler.cost(b.amount, b.premiumPerToken) - handler.cost(b.filled, b.premiumPerToken) + b.refundDue;
    }

    /// The contract holds exactly the stock it still owes: every listing's unexercised stock until it
    /// is returned to the seller, plus everything any account may still claim. Sales into bids are
    /// listings, so their stock is counted the same way.
    function invariant_stockHeldEqualsStockOwed() public view {
        uint256 owedTotal;
        for (uint256 id = 1; id <= calls.listingCount(); ++id) {
            CoveredCallsV2.Listing memory l = calls.listings(id);
            if (!l.stockReturned) owedTotal += l.amount - l.exercised;
            for (uint256 a; a < handler.actorCount(); ++a) {
                owedTotal += calls.owed(id, handler.actors(a));
            }
        }
        assertEq(stock.balanceOf(address(calls)), owedTotal);
    }

    /// The contract holds exactly the strike paid and not collected plus every bid's unspent escrow;
    /// fill premiums and all fees pass straight through.
    function invariant_usdcHeldEqualsStrikeUncollectedPlusEscrow() public view {
        uint256 owedTotal;
        for (uint256 id = 1; id <= calls.listingCount(); ++id) {
            CoveredCallsV2.Listing memory l = calls.listings(id);
            owedTotal += l.strikePaid - l.strikeCollected;
        }
        for (uint256 id = 1; id <= calls.bidCount(); ++id) {
            owedTotal += _escrow(calls.bids(id));
        }
        assertEq(usdc.balanceOf(address(calls)), owedTotal);
    }

    /// Each bid's books close on its bidder's balance: what it paid in, less what came back, less what
    /// its sales paid out, is exactly the escrow it still holds. Its sales paid out exactly the
    /// premium for everything sold, rounded up once, and exactly 1% of that, rounded up once, as fee.
    function invariant_eachBidsEscrowIsItsOwn() public view {
        for (uint256 id = 1; id <= calls.bidCount(); ++id) {
            CoveredCallsV2.Bid memory b = calls.bids(id);
            uint256 sold = handler.cost(b.filled, b.premiumPerToken);
            assertEq(handler.salesPaid(id), sold, "sales paid other than the bid's premium");
            assertEq(handler.salesFees(id), (sold + 99) / 100, "sales fee other than 1% rounded up once");
            assertEq(
                handler.paidIn(id) - handler.refunded(id) - handler.salesPaid(id), _escrow(b), "bid books do not close"
            );
            assertLe(b.filled, b.amount);
        }
    }

    /// Nothing is oversold, and every unit a listing ever locked is still locked, owed or claimed.
    /// The listings sold into a bid add up to exactly what the bid says was sold.
    function invariant_noOversellingAndEveryUnitAccounted() public view {
        uint256[] memory soldInto = new uint256[](calls.bidCount() + 1);
        for (uint256 id = 1; id <= calls.listingCount(); ++id) {
            CoveredCallsV2.Listing memory l = calls.listings(id);
            assertLe(l.filled, l.amount);
            assertLe(l.exercised, l.filled);
            uint256 heldTotal;
            uint256 owedTotal;
            for (uint256 a; a < handler.actorCount(); ++a) {
                heldTotal += calls.held(id, handler.actors(a));
                owedTotal += calls.owed(id, handler.actors(a));
            }
            assertEq(heldTotal + l.exercised, l.filled);
            uint256 locked = l.stockReturned ? 0 : l.amount - l.exercised;
            assertEq(locked + owedTotal + handler.claimedOf(id), handler.listedOf(id));
            uint256 bidId = handler.bidOf(id);
            if (bidId != 0) {
                assertEq(l.amount, l.filled, "a sale's listing is fully filled");
                soldInto[bidId] += l.amount;
            }
        }
        for (uint256 id = 1; id <= calls.bidCount(); ++id) {
            assertEq(soldInto[id], calls.bids(id).filled, "sale listings differ from the bid");
        }
    }

    /// A claim pays exactly what `claimable` showed, and a refund exactly what `refundable` showed.
    function invariant_pullsPayWhatTheViewsShow() public view {
        assertEq(handler.mismatches(), 0);
    }

    /// Stock is never created or lost.
    function invariant_stockIsConserved() public view {
        uint256 total = stock.balanceOf(address(calls));
        for (uint256 a; a < handler.actorCount(); ++a) {
            total += stock.balanceOf(handler.actors(a));
        }
        assertEq(total, stockSupply);
    }

    /// Every fee reached staking exactly once: 1% of each fill's premium rounded up, and 1% of each
    /// bid's sold premium rounded up.
    function invariant_feesReachStakingOnce() public view {
        uint256 expected = handler.fillFeesExpected();
        for (uint256 id = 1; id <= calls.bidCount(); ++id) {
            CoveredCallsV2.Bid memory b = calls.bids(id);
            expected += (handler.cost(b.filled, b.premiumPerToken) + 99) / 100;
        }
        assertEq(staking.deposited(), expected);
        assertEq(usdc.balanceOf(address(staking)), expected);
        assertEq(usdc.allowance(address(calls), address(staking)), 0);
    }

    /// USDC is never created or lost.
    function invariant_usdcIsConserved() public view {
        uint256 total = usdc.balanceOf(address(calls)) + usdc.balanceOf(address(staking));
        for (uint256 a; a < handler.actorCount(); ++a) {
            total += usdc.balanceOf(handler.actors(a));
        }
        assertEq(total, usdcSupply);
    }

    /// Once every restriction lifts, every party recovers everything that is theirs, the contract is
    /// left holding nothing, and each bidder has paid exactly the premium for what was sold to it.
    function afterInvariant() public {
        console.log("list", handler.succeeded(handler.list.selector), "fill", handler.succeeded(handler.fill.selector));
        console.log(
            "cancel",
            handler.succeeded(handler.cancel.selector),
            "exercise",
            handler.succeeded(handler.exercise.selector)
        );
        console.log(
            "claim",
            handler.succeeded(handler.claim.selector),
            "collectStrike",
            handler.succeeded(handler.collectStrike.selector)
        );
        console.log(
            "bid", handler.succeeded(handler.bid.selector), "raiseBid", handler.succeeded(handler.raiseBid.selector)
        );
        console.log(
            "cancelBid",
            handler.succeeded(handler.cancelBid.selector),
            "sellToBid",
            handler.succeeded(handler.sellToBid.selector)
        );
        console.log("refundBid", handler.succeeded(handler.refundBid.selector));
        handler.recoverEverything();
        assertEq(stock.balanceOf(address(calls)), 0);
        assertEq(usdc.balanceOf(address(calls)), 0);
        invariant_noOversellingAndEveryUnitAccounted();
        invariant_eachBidsEscrowIsItsOwn();
        for (uint256 id = 1; id <= calls.bidCount(); ++id) {
            CoveredCallsV2.Bid memory b = calls.bids(id);
            assertEq(handler.paidIn(id) - handler.refunded(id), handler.cost(b.filled, b.premiumPerToken));
        }
    }
}
