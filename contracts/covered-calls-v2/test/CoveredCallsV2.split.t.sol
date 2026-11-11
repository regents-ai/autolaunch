// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {CoveredCallsV2} from "../src/CoveredCallsV2.sol";
import {B20Double, StakingDouble, UsdcDouble} from "./doubles/Doubles.sol";
import {WeeklyExpiry} from "./doubles/WeeklyExpiry.sol";

/// @notice Splitting a sale into a bid never changes what anyone gets. The same bid is sold into once
///         on one contract and in many random pieces (by one seller, or by many), each at least the
///         bid's random minimum sale, on an identical second contract; the sellers, the bidder and
///         staking must end exactly level. And whatever mix of sales, raises and cancels a bid sees,
///         its bidder pays exactly what one fill of everything sold into it would cost.
contract CoveredCallsV2SplitTest is Test {
    uint256 internal constant TOKEN = 1e8;
    uint256 internal constant USD = 1e6;
    uint256 internal constant START_USDC = 1e15;
    uint256 internal constant START_STOCK = 1_000 * TOKEN;

    struct Market {
        B20Double stock;
        UsdcDouble usdc;
        StakingDouble staking;
        CoveredCallsV2 calls;
    }

    struct Terms {
        uint256 amount;
        uint256 soldBefore;
        uint256 premiumPerToken;
        uint256 minSale;
        uint256 x;
    }

    address internal bidder = makeAddr("bidder");
    address internal first = makeAddr("first");
    address[] internal sellers;
    uint64 internal expiry;

    function setUp() public {
        vm.warp(1_800_000_000);
        expiry = WeeklyExpiry.next(block.timestamp, 1);
        for (uint256 i; i < 6; ++i) {
            sellers.push(makeAddr(string.concat("seller", vm.toString(i))));
        }
    }

    function _market() internal returns (Market memory m) {
        m.stock = new B20Double();
        m.usdc = new UsdcDouble();
        m.staking = new StakingDouble(m.usdc);
        m.calls = new CoveredCallsV2(address(m.stock), address(m.usdc), address(m.staking));
        _fund(m, bidder);
        _fund(m, first);
        for (uint256 i; i < sellers.length; ++i) {
            _fund(m, sellers[i]);
        }
    }

    function _fund(Market memory m, address who) internal {
        m.stock.mint(who, START_STOCK);
        m.usdc.mint(who, START_USDC);
        vm.startPrank(who);
        m.stock.approve(address(m.calls), type(uint256).max);
        m.usdc.approve(address(m.calls), type(uint256).max);
        vm.stopPrank();
    }

    /// Posts the same bid on a market and, when `soldBefore` is not zero, has `first` sell that much
    /// into it, so the split starts part way through the bid's rounding.
    function _open(Market memory m, Terms memory t) internal returns (uint256 id) {
        vm.prank(bidder);
        id = m.calls.bid(t.amount, 137 * USD, t.premiumPerToken, expiry, t.minSale);
        if (t.soldBefore != 0) {
            vm.prank(first);
            m.calls.sellToBid(id, t.soldBefore);
        }
    }

    /// Random piece sizes that add up to `total`, at most `count` of them, each at least `minSale`.
    function _pieces(uint256 total, uint256 count, uint256 minSale, uint256 seed)
        internal
        pure
        returns (uint256[] memory parts)
    {
        parts = new uint256[](count);
        uint256 left = total;
        uint256 n;
        for (; n < count - 1 && left >= 2 * minSale; ++n) {
            seed = uint256(keccak256(abi.encode(seed, n)));
            // Mostly the minimum or a little over, sometimes a large piece; always leaving at least
            // the minimum for the pieces after it.
            uint256 room = left - 2 * minSale;
            uint256 cap = seed % 3 == 0 ? room : (room < 1_000 ? room : 1_000);
            parts[n] = minSale + (seed >> 8) % (cap + 1);
            left -= parts[n];
        }
        parts[n] = left;
        assembly {
            mstore(parts, add(n, 1))
        }
    }

    /// What the bidder holds across every listing the sales into its bid created.
    function _held(Market memory m) internal view returns (uint256 total) {
        for (uint256 id = 1; id <= m.calls.listingCount(); ++id) {
            total += m.calls.held(id, bidder);
        }
    }

    /// A bid of `amount` with a minimum sale of at most half of it (one raw unit half the time, so
    /// dust is tried), `soldBefore` already sold (zero, or a valid sale leaving at least the
    /// minimum), and a sale `x` of at least the minimum.
    function _terms(uint256 amount, uint256 soldBefore, uint256 premiumPerToken, uint256 minSale, uint256 x)
        internal
        pure
        returns (Terms memory t)
    {
        t.amount = bound(amount, 2, 400 * TOKEN);
        t.minSale = minSale % 2 == 0 ? 1 : bound(minSale, 1, t.amount / 2);
        t.soldBefore = bound(soldBefore, 0, t.amount - t.minSale);
        if (t.soldBefore < t.minSale) t.soldBefore = 0;
        t.premiumPerToken = bound(premiumPerToken, 1, 50_000 * USD);
        t.x = bound(x, t.minSale, t.amount - t.soldBefore);
    }

    /// One seller selling `x` into a bid in up to 40 random pieces is paid exactly what one sale of `x`
    /// pays, after the fee too; the bidder holds the same calls and has the same escrow left; staking
    /// receives the same fee.
    function testFuzz_oneSellerSplittingASaleChangesNothing(
        uint256 amount,
        uint256 soldBefore,
        uint256 premiumPerToken,
        uint256 minSale,
        uint256 x,
        uint256 seed
    ) public {
        Terms memory t = _terms(amount, soldBefore, premiumPerToken, minSale, x);
        Market memory one = _market();
        Market memory split = _market();
        uint256 a = _open(one, t);
        uint256 b = _open(split, t);
        address seller = sellers[0];

        vm.prank(seller);
        one.calls.sellToBid(a, t.x);
        uint256[] memory parts = _pieces(t.x, 40, t.minSale, seed);
        for (uint256 i; i < parts.length; ++i) {
            vm.prank(seller);
            split.calls.sellToBid(b, parts[i]);
        }

        assertEq(split.usdc.balanceOf(seller), one.usdc.balanceOf(seller), "seller paid differently");
        assertEq(split.stock.balanceOf(seller), one.stock.balanceOf(seller), "seller locked differently");
        assertEq(split.staking.deposited(), one.staking.deposited(), "staking fee differs");
        assertEq(_held(split), _held(one), "bidder holds different calls");
        assertEq(split.calls.bids(b).filled, one.calls.bids(a).filled);
        assertEq(split.usdc.balanceOf(address(split.calls)), one.usdc.balanceOf(address(one.calls)), "escrow left");
        vm.warp(expiry);
        assertEq(split.calls.refundable(b), one.calls.refundable(a), "bidder refunded differently");
    }

    /// Many sellers sharing `x` of a bid between them are paid, together, exactly what one seller
    /// selling `x` is paid, and the bidder and staking end level too.
    function testFuzz_manySellersTogetherAreLevelWithOne(
        uint256 amount,
        uint256 soldBefore,
        uint256 premiumPerToken,
        uint256 minSale,
        uint256 x,
        uint256 seed
    ) public {
        Terms memory t = _terms(amount, soldBefore, premiumPerToken, minSale, x);
        Market memory one = _market();
        Market memory many = _market();
        uint256 a = _open(one, t);
        uint256 b = _open(many, t);

        vm.prank(sellers[0]);
        one.calls.sellToBid(a, t.x);
        uint256[] memory parts = _pieces(t.x, 30, t.minSale, seed);
        for (uint256 i; i < parts.length; ++i) {
            vm.prank(sellers[uint256(keccak256(abi.encode(seed, "who", i))) % sellers.length]);
            many.calls.sellToBid(b, parts[i]);
        }

        uint256 paidOne;
        uint256 paidMany;
        for (uint256 i; i < sellers.length; ++i) {
            paidOne += one.usdc.balanceOf(sellers[i]) - START_USDC;
            paidMany += many.usdc.balanceOf(sellers[i]) - START_USDC;
        }
        assertEq(paidMany, paidOne, "sellers together paid differently");
        assertEq(many.staking.deposited(), one.staking.deposited(), "staking fee differs");
        assertEq(_held(many), _held(one), "bidder holds different calls");
        vm.warp(expiry);
        assertEq(many.calls.refundable(b), one.calls.refundable(a), "bidder refunded differently");
    }

    /// Whatever sequence of sales, raises and cancels a bid sees before expiry, once refunded its
    /// bidder has paid exactly `costFor(filled)` — what one fill of everything sold would cost — the
    /// sellers were paid exactly that, staking received exactly its rounded-up 1%, and the contract
    /// keeps nothing.
    function testFuzz_bidderPaysExactlyOneFillOfWhatWasSold(uint256 seed, uint256 premiumPerToken) public {
        premiumPerToken = bound(premiumPerToken, 1, 50_000 * USD);
        Market memory m = _market();
        uint256 amount = 1 + seed % (20 * TOKEN);
        uint256 minSale = (seed >> 128) % 2 == 0 ? 1 : 1 + (seed >> 64) % amount;
        vm.prank(bidder);
        uint256 id = m.calls.bid(amount, 137 * USD, premiumPerToken, expiry, minSale);

        for (uint256 i; i < 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            CoveredCallsV2.Bid memory b = m.calls.bids(id);
            uint256 kind = seed % 5;
            if (kind <= 2 && b.amount > b.filled) {
                // At least the minimum, mostly close to it, or the whole remainder when less is left.
                uint256 left = b.amount - b.filled;
                uint256 room = left > minSale ? left - minSale : 0;
                uint256 part =
                    left <= minSale ? left : minSale + (seed >> 8) % ((seed % 2 == 0 && room > 500 ? 500 : room) + 1);
                vm.prank(sellers[(seed >> 16) % sellers.length]);
                m.calls.sellToBid(id, part);
            } else if (kind == 3) {
                vm.prank(bidder);
                m.calls.raiseBid(id, 1 + (seed >> 8) % (5 * TOKEN));
            } else if (b.amount > b.filled) {
                vm.prank(bidder);
                m.calls.cancelBid(id);
            }
        }
        vm.warp(expiry);
        if (m.calls.refundable(id) != 0) {
            vm.prank(bidder);
            m.calls.refundBid(id);
        }

        uint256 filled = m.calls.bids(id).filled;
        uint256 cost = m.calls.costFor(filled, premiumPerToken);
        uint256 fee = (cost + 99) / 100;
        uint256 sellersGot;
        for (uint256 i; i < sellers.length; ++i) {
            sellersGot += m.usdc.balanceOf(sellers[i]) - START_USDC;
        }
        assertEq(START_USDC - m.usdc.balanceOf(bidder), cost, "bidder paid other than one fill");
        assertEq(m.staking.deposited(), fee, "fee other than 1% of the bid's premium, rounded up");
        assertEq(sellersGot + fee, cost, "sellers paid other than the bid's premium");
        assertEq(m.usdc.balanceOf(address(m.calls)), 0, "contract kept USDC");
        assertEq(_held(m), filled, "bidder holds other than what was sold");
    }
}
