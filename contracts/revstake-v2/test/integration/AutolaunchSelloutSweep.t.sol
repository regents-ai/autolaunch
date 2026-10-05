// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {RegentLBPStrategyV2} from "../../src/strategy/RegentLBPStrategyV2.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {Bid} from "continuous-clearing-auction/libraries/BidLib.sol";
import {Checkpoint} from "continuous-clearing-auction/libraries/CheckpointLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Permit2Double} from "../strategy/doubles/Permit2Double.sol";
import {AutolaunchFixture} from "./AutolaunchFixture.sol";

/// @notice AL-03 sweep: several bidders with fuzzed amounts (down to one base unit), prices (down to
///         one tick above the floor) and blocks (up to the last block that takes bids). Whatever the
///         mix, a launch graduates exactly when the auction's own raise meets the minimum, a graduated
///         launch opens its pool and its bidders hold the whole sale allocation up to crumbs, and a
///         failed launch opens no pool and refunds every bid in full. The sum of bid amounts reaching
///         the minimum is not graduation: outbid refunds and the auction's rounding come off first.
contract AutolaunchSelloutSweepTest is AutolaunchFixture {
    using StateLibrary for IPoolManager;

    uint256 private constant SALE_CRUMBS = AUCTION_ALLOCATION / DEFAULT_FLOOR_Q96 + 2_000;
    uint256 private constant MAX_BIDDERS = 6;

    struct Sweep {
        uint256[] bidIds;
        uint256 placed;
        uint256 bidTotal;
    }

    function setUp() public {
        _deployAutolaunch();
    }

    /// @param seeds One word per bidder: amount, price and block gap are drawn from separate bits.
    /// @param scale Chooses the amount range, so runs land on both sides of the minimum.
    function testFuzz_AL03_GraduationIsExactlyTheMinimumAndAGraduatedSaleSellsOut(
        uint256[MAX_BIDDERS] memory seeds,
        uint8 count,
        uint8 scale,
        bool subjectBelowRegent
    ) public {
        Launched memory l = _launchSorted(subjectBelowRegent, _params());
        Sweep memory s = _placeBids(l, seeds, bound(count, 2, MAX_BIDDERS), scale);
        _assertOutcome(l, s);
    }

    /// @dev Bids that add up to the minimum, or a few base units over it, split across bidders and
    ///      blocks: the auction may count each bid after its first block one unit short, so these sit
    ///      on both sides of graduation, and graduation follows the counted raise, not the bid total.
    function testFuzz_AL03_BidsAddingUpToTheMinimumGraduateOnlyOnTheCountedRaise(
        uint256[MAX_BIDDERS] memory seeds,
        uint8 count,
        uint8 extra,
        bool subjectBelowRegent
    ) public {
        Launched memory l = _launchSorted(subjectBelowRegent, _params());
        uint256 n = bound(count, 2, 4);
        uint256 remaining = uint256(FLOOR_RAISE) + extra % (n + 1);
        Sweep memory s;
        s.bidIds = new uint256[](n);
        uint256 blockNumber = l.auction.startBlock();
        for (uint256 i; i < n; ++i) {
            uint256 seed = seeds[i];
            blockNumber += seed % 2 == 0 ? 0 : bound(seed >> 64, 1, 20_000);
            if (blockNumber > uint256(l.auction.endBlock()) - 1) blockNumber = uint256(l.auction.endBlock()) - 1;
            vm.roll(blockNumber);
            uint128 amount = uint128(i == n - 1 ? remaining : bound(seed >> 8, 1, remaining - (n - 1 - i)));
            remaining -= amount;
            uint256 bidId = _bid(l, address(uint160(0xA103 + i)), amount, _bidPrice(bound(seed >> 32, 1, 10_000)));
            s.bidIds[s.placed++] = bidId;
            s.bidTotal += amount;
        }
        _assertOutcome(l, s);
    }

    function _assertOutcome(Launched memory l, Sweep memory s) private {
        _rollToMigration(l);
        l.auction.checkpoint();
        uint256 raised = l.auction.currencyRaised();
        bool minimumMet = raised >= strategy.REQUIRED_REGENT_RAISED();
        assertEq(l.auction.isGraduated(), minimumMet, "the auction's own graduation is the minimum");

        strategy.migrate(address(l.auction));
        RegentLBPStrategyV2.Distribution memory d = _distribution(l);
        (uint160 sqrtPrice,,,) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(_poolId(l));

        if (minimumMet) {
            assertEq(uint8(d.lifecycle), uint8(RegentLBPStrategyV2.Lifecycle.Graduated), "met but not graduated");
            assertNotEq(sqrtPrice, 0, "graduated but no pool");
            uint256 received;
            for (uint256 i; i < s.placed; ++i) {
                received += _settleGraduated(l, s.bidIds[i]);
            }
            assertLe(received, AUCTION_ALLOCATION, "bidders received more than the sale allocation");
            assertLe(AUCTION_ALLOCATION - received, SALE_CRUMBS, "graduated without selling out");
        } else {
            assertEq(uint8(d.lifecycle), uint8(RegentLBPStrategyV2.Lifecycle.Failed), "short but not failed");
            assertEq(sqrtPrice, 0, "failed but a pool opened");
            uint256 refunded;
            for (uint256 i; i < s.placed; ++i) {
                Bid memory placed = l.auction.bids(s.bidIds[i]);
                uint256 before = regent.balanceOf(placed.owner);
                l.auction.exitBid(s.bidIds[i]);
                refunded += regent.balanceOf(placed.owner) - before;
            }
            assertEq(refunded, s.bidTotal, "a failed launch did not refund every bid in full");
        }
    }

    function _placeBids(Launched memory l, uint256[MAX_BIDDERS] memory seeds, uint256 count, uint8 scale)
        private
        returns (Sweep memory s)
    {
        s.bidIds = new uint256[](count);
        uint256 lastBidBlock = uint256(l.auction.endBlock()) - 1;
        uint256 blockNumber = l.auction.startBlock();
        uint256 maxAmount = scale % 3 == 0 ? FLOOR_RAISE : scale % 3 == 1 ? 4 * FLOOR_RAISE : 1_000_000e18;
        for (uint256 i; i < count; ++i) {
            uint256 seed = seeds[i];
            blockNumber += (seed >> 128) % 3 == 0 ? 0 : bound(seed >> 64, 0, 20_000);
            if (blockNumber > lastBidBlock) blockNumber = lastBidBlock;
            vm.roll(blockNumber);

            uint128 amount = uint128(bound(seed, 1, maxAmount));
            uint256 clearing = l.auction.checkpoint().clearingPrice;
            uint256 ticks = bound(seed >> 32, 1, 2_000);
            uint256 minTicks = (clearing - DEFAULT_FLOOR_Q96) / DEFAULT_TICK_Q96 + 1;
            if (ticks < minTicks) ticks = minTicks + ticks % 50;

            address account = address(uint160(uint256(keccak256(abi.encode("sweep", i)))));
            regent.mint(account, amount);
            vm.startPrank(account);
            regent.approve(PERMIT2, type(uint256).max);
            Permit2Double(PERMIT2).approve(address(regent), address(l.auction), uint160(amount), type(uint48).max);
            try l.auction.submitBid(_bidPrice(ticks), amount, account, l.auction.floorPrice(), "") returns (
                uint256 bidId
            ) {
                s.bidIds[s.placed++] = bidId;
                s.bidTotal += amount;
            } catch {}
            vm.stopPrank();
        }
    }

    function _settleGraduated(Launched memory l, uint256 bidId) private returns (uint256 received) {
        Bid memory placed = l.auction.bids(bidId);
        uint256 startBalance = l.subject.balanceOf(placed.owner);
        if (placed.maxPrice > l.auction.checkpoints(l.auction.endBlock()).clearingPrice) {
            l.auction.exitBid(bidId);
        } else {
            (uint64 lastFullyFilled, uint64 outbid) = _hints(l.auction, bidId);
            l.auction.exitPartiallyFilledBid(bidId, lastFullyFilled, outbid);
        }
        l.auction.claimTokens(bidId);
        received = l.subject.balanceOf(placed.owner) - startBalance;
    }

    function _hints(IContinuousClearingAuction auction, uint256 bidId)
        private
        view
        returns (uint64 lastFullyFilled, uint64 outbid)
    {
        Bid memory placed = auction.bids(bidId);
        uint64 blockNumber = placed.startBlock;
        while (blockNumber != type(uint64).max) {
            Checkpoint memory checkpoint = auction.checkpoints(blockNumber);
            if (checkpoint.clearingPrice < placed.maxPrice) lastFullyFilled = blockNumber;
            if (checkpoint.clearingPrice > placed.maxPrice && outbid == 0) outbid = blockNumber;
            blockNumber = checkpoint.next;
        }
    }
}
