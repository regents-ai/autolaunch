// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {RegentsAutolaunchFactoryV2} from "../../src/factory/RegentsAutolaunchFactoryV2.sol";
import {RegentLBPStrategyV2} from "../../src/strategy/RegentLBPStrategyV2.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {Bid} from "continuous-clearing-auction/libraries/BidLib.sol";
import {Checkpoint} from "continuous-clearing-auction/libraries/CheckpointLib.sol";
import {LBPInitializationParams} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";
import {TokenPricing} from "liquidity-launcher/src/libraries/TokenPricing.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {AutolaunchFixture} from "./AutolaunchFixture.sol";

/// @notice A graduated auction sells its whole sale allocation to its bidders through the auction
///         itself: after graduation and every bid's exit and claim, the bidders hold the 20% up to
///         rounding crumbs. The pool opens at the final clearing price and pairs half the raise with
///         at most the whole reserve. Whatever SUBJECT the strategy has left after the position — the
///         auction's unsold crumbs, the reserve the pool did not pair and anything sent to the
///         strategy — goes to the launch's escrow. The required raise is the sale allocation at the
///         floor, and an auction that falls short of it fails.
contract AutolaunchFullSaleTest is AutolaunchFixture {
    using StateLibrary for IPoolManager;

    /// @dev The most SUBJECT, in base units, a graduation may leave with anyone but the bidders and
    ///      the pool. The pinned auction rounds each clearing price up by less than one Q96 unit, so
    ///      what it leaves unsold is under the allocation divided by the floor price in Q96 units:
    ///      252,435 base units at the default floor, about 2.5e-13 SUBJECT. The full-range position
    ///      leaves under 1,000 base units of the reserve per unit of liquidity it rounds away at a
    ///      pool price at or above the floor; two such units are allowed. The largest leftover
    ///      measured over 100,000 fuzzed single bids was 122,703 base units.
    uint256 private constant SALE_CRUMBS = AUCTION_ALLOCATION / DEFAULT_FLOOR_Q96 + 2_000;

    /// @dev A price far above the floor, so a bid there is filled in every block it is live.
    uint256 private constant GRADUATING_TICKS = 10_000;

    function setUp() public {
        _deployAutolaunch();
    }

    // -------------------------------------------------------------------------
    // graduation: one bidder
    // -------------------------------------------------------------------------

    function test_SALE_001_SoleBidderAtTheStartBuysTheWholeSaleAllocationBothOrderings() public {
        _soleBidderCase(_launchSorted(true, _params()), 2 * FLOOR_RAISE, _bidPrice(GRADUATING_TICKS), 0);
        _soleBidderCase(_launchSorted(false, _params()), 2 * FLOOR_RAISE, _bidPrice(GRADUATING_TICKS), 0);
    }

    /// @dev Nobody bids until the last block that still takes bids; every unit released earlier rolls
    ///      into it, so the one late bid still buys the whole sale allocation.
    function test_SALE_002_SoleBidderInTheLastEligibleBlockBuysTheWholeSaleAllocation() public {
        Launched memory low = _launchSorted(true, _params());
        _soleBidderCase(low, 4 * FLOOR_RAISE, _bidPrice(GRADUATING_TICKS), low.auction.endBlock() - 1);
        Launched memory high = _launchSorted(false, _params());
        _soleBidderCase(high, 4 * FLOOR_RAISE, _bidPrice(GRADUATING_TICKS), high.auction.endBlock() - 1);
    }

    /// @dev A bid larger than the sale allocation at its own price limit: the clearing price rises to
    ///      the limit and the bid is partly filled there, refunded the rest, and still buys the whole
    ///      sale allocation.
    function test_SALE_003_SoleBidderPartlyFilledAtItsLimitBuysTheWholeSaleAllocation() public {
        _soleBidderCase(_launchSorted(true, _params()), 20 * FLOOR_RAISE, _bidPrice(10), 0);
        _soleBidderCase(_launchSorted(false, _params()), 20 * FLOOR_RAISE, _bidPrice(10), 0);
    }

    function testFuzz_SALE_004_SoleBidderBuysTheWholeSaleAllocation(uint128 amount, uint32 ticks, uint32 lateBy)
        public
    {
        amount = uint128(bound(amount, 2 * FLOOR_RAISE, 1_000_000e18));
        uint256 priceQ96 = _bidPrice(bound(ticks, 1, 100_000));
        Launched memory l = _launchSorted(ticks % 2 == 0, _params());
        uint256 duration = uint256(l.auction.endBlock()) - uint256(l.auction.startBlock());
        uint256 bidBlock = uint256(l.auction.startBlock()) + bound(lateBy, 0, duration - 1);
        _soleBidderCase(l, amount, priceQ96, bidBlock);
    }

    /// @param bidBlock The block the bid is placed in; zero for the auction's first block.
    function _soleBidderCase(Launched memory l, uint128 amount, uint256 priceQ96, uint256 bidBlock) private {
        vm.roll(bidBlock == 0 ? l.auction.startBlock() : bidBlock);
        uint256 bidId = _bid(l, bidder, amount, priceQ96);
        _rollToMigration(l);
        uint256 toEscrow = _migrateAndAssertGraduation(l);

        uint256 received = _settle(l, bidId);
        _assertSoldOut(l, received, toEscrow);
    }

    // -------------------------------------------------------------------------
    // graduation: several bidders
    // -------------------------------------------------------------------------

    /// @dev Three bids exercise every way a bid ends: `early` at 1.2 times the floor is outbid when
    ///      `anchor` arrives, `anchor` sets the final clearing price and is partly filled at it, and
    ///      `late` is priced above it and filled in every block. Each exits and claims at the auction,
    ///      and together they hold the whole sale allocation up to crumbs.
    function test_SALE_005_SeveralBiddersEachWayABidEndsBuyTheWholeSaleAllocationBothOrderings() public {
        _severalBiddersCase(true);
        _severalBiddersCase(false);
    }

    function _severalBiddersCase(bool subjectBelowRegent) private {
        Launched memory l = _launchSorted(subjectBelowRegent, _params());
        uint256 anchorPrice = _bidPrice(1_000);

        _rollToStart(l);
        uint256 earlyBid = _bid(l, makeAddr("early"), FLOOR_RAISE * 6 / 10, _bidPrice(20));
        vm.roll(l.auction.startBlock() + 1_000);
        uint256 anchorBid = _bid(l, makeAddr("anchor"), 20 * FLOOR_RAISE, anchorPrice);
        vm.roll(l.auction.startBlock() + 2_000);
        uint256 lateBid = _bid(l, makeAddr("late"), 2 * FLOOR_RAISE, _bidPrice(GRADUATING_TICKS));
        _rollToMigration(l);
        uint256 toEscrow = _migrateAndAssertGraduation(l);

        Checkpoint memory finalCheckpoint = l.auction.checkpoints(l.auction.endBlock());
        assertEq(finalCheckpoint.clearingPrice, anchorPrice, "the anchor bid sets the final price");
        (, uint64 earlyOutbid) = _hints(l.auction, earlyBid);
        assertNotEq(earlyOutbid, 0, "the early bid was outbid");
        (, uint64 anchorOutbid) = _hints(l.auction, anchorBid);
        assertEq(anchorOutbid, 0, "the anchor bid was never outbid");

        uint256 earlyReceived = _settle(l, earlyBid);
        uint256 anchorReceived = _settle(l, anchorBid);
        uint256 lateReceived = _settle(l, lateBid);
        assertGt(earlyReceived, 0, "the early bid bought before it was outbid");
        assertGt(anchorReceived, lateReceived, "the anchor bid bought the most");

        _assertSoldOut(l, earlyReceived + anchorReceived + lateReceived, toEscrow);
    }

    /// @dev The auction pays bids from the claim block, before migration can run, so SUBJECT can
    ///      already be sent to the strategy when the launch graduates. Graduation sends it, with the
    ///      crumbs, to the launch's escrow.
    function test_SALE_007_SubjectSentToTheStrategyBeforeMigrationGoesToTheEscrow() public {
        Launched memory l = _defaultLaunch();
        _rollToStart(l);
        uint256 bidId = _bid(l, bidder, 2 * FLOOR_RAISE, _bidPrice(GRADUATING_TICKS));
        vm.roll(l.auction.claimBlock());
        vm.startPrank(bidder);
        l.auction.exitBid(bidId);
        l.auction.claimTokens(bidId);
        uint256 claimed = l.subject.balanceOf(bidder);
        uint256 gift = claimed / 2;
        l.subject.transfer(address(strategy), gift);
        vm.stopPrank();
        assertApproxEqAbs(claimed, AUCTION_ALLOCATION, SALE_CRUMBS, "the bidder bought the whole sale allocation");

        _rollToMigration(l);
        uint256 toEscrow = _migrateAndAssertGraduation(l);
        assertGe(toEscrow, gift, "the gift went to the escrow");
        assertLe(toEscrow - gift, SALE_CRUMBS, "beyond the gift, only crumbs went to the escrow");
        assertEq(l.subject.balanceOf(address(l.escrow)), PENDING_ALLOCATION + toEscrow, "the escrow holds the gift");
    }

    // -------------------------------------------------------------------------
    // the minimum raise
    // -------------------------------------------------------------------------

    /// @dev Placed in the auction's first block, a bid of exactly the minimum is counted in full.
    function test_MIN_001_FloorMinimumMetExactlyGraduatesAndOneUnitBelowFails() public {
        Launched memory met = _launchSorted(true, _params());
        Launched memory below = _launchSorted(false, _params());
        _rollToStart(met);
        _bid(met, bidder, FLOOR_RAISE, _bidPrice(GRADUATING_TICKS));
        _bid(below, bidder, FLOOR_RAISE - 1, _bidPrice(GRADUATING_TICKS));

        _rollToMigration(below);
        strategy.migrate(address(met.auction));
        strategy.migrate(address(below.auction));
        assertEq(uint8(_distribution(met).lifecycle), uint8(RegentLBPStrategyV2.Lifecycle.Graduated), "exactly met");
        assertEq(uint8(_distribution(below).lifecycle), uint8(RegentLBPStrategyV2.Lifecycle.Failed), "one unit short");
    }

    /// @dev The pinned auction rounds what it counts of a bid placed after its first block down by up
    ///      to one base unit, so there the minimum plus one base unit is what graduates, in any block.
    function testFuzz_MIN_002_MinimumPlusOneUnitGraduatesInAnyBlock(uint32 lateBy) public {
        Launched memory l = _defaultLaunch();
        uint256 duration = uint256(l.auction.endBlock()) - uint256(l.auction.startBlock());
        vm.roll(uint256(l.auction.startBlock()) + bound(lateBy, 0, duration - 1));
        _bid(l, bidder, FLOOR_RAISE + 1, _bidPrice(GRADUATING_TICKS));
        _rollToMigration(l);
        strategy.migrate(address(l.auction));
        assertEq(uint8(_distribution(l).lifecycle), uint8(RegentLBPStrategyV2.Lifecycle.Graduated), "not graduated");
    }

    function test_MIN_003_MinimumBidAfterTheFirstBlockIsCountedOneUnitShortAndFails() public {
        Launched memory l = _defaultLaunch();
        vm.roll(uint256(l.auction.startBlock()) + 1);
        _bid(l, bidder, FLOOR_RAISE, _bidPrice(GRADUATING_TICKS));
        _rollToMigration(l);
        l.auction.checkpoint();
        assertEq(l.auction.currencyRaised(), FLOOR_RAISE - 1, "the auction's own rounding");
        strategy.migrate(address(l.auction));
        assertEq(uint8(_distribution(l).lifecycle), uint8(RegentLBPStrategyV2.Lifecycle.Failed), "not failed");
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    /// @dev Migrates and checks the graduation's economics: the pool opens at the final clearing
    ///      price, pairs half the raise with at most the whole reserve, the rest of the raise reaches
    ///      the treasury, and every unit of this launch's SUBJECT the strategy
    ///      held or swept, less what the position used, goes to the escrow on top of its 70%.
    /// @return toEscrow The SUBJECT graduation sent to the escrow.
    function _migrateAndAssertGraduation(Launched memory l) private returns (uint256 toEscrow) {
        uint256 treasuryBefore = regent.balanceOf(treasury);
        uint256 strategyBefore = l.subject.balanceOf(address(strategy));
        uint256 auctionBefore = l.subject.balanceOf(address(l.auction));
        uint256 escrowBefore = l.subject.balanceOf(address(l.escrow));
        strategy.migrate(address(l.auction));

        RegentLBPStrategyV2.Distribution memory d = _distribution(l);
        assertEq(uint8(d.lifecycle), uint8(RegentLBPStrategyV2.Lifecycle.Graduated), "the launch did not graduate");
        LBPInitializationParams memory lbp = l.auction.lbpInitializationParams();
        assertGe(lbp.currencyRaised, strategy.REQUIRED_REGENT_RAISED(), "the minimum was met");

        PoolKey memory key = strategy.poolKeyOf(address(l.subject));
        bool regentIsCurrency0 = Currency.unwrap(key.currency0) == BaseBindings.REGENT;
        assertLe(
            FullMath.mulDiv(lbp.currencyRaised, FixedPoint96.Q96, AUCTION_ALLOCATION),
            lbp.initialPriceX96,
            "the raise never exceeds the sale allocation at the final clearing price"
        );
        uint160 expected = TokenPricing.convertToSqrtPriceX96(
            TokenPricing.convertToPriceX192(lbp.initialPriceX96, regentIsCurrency0)
        );
        (uint160 slotPrice,,,) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(_poolId(l));
        assertEq(slotPrice, expected, "the pool did not open at the final clearing price");

        assertLe(uint256(d.lpSubjectUsed), RESERVE_ALLOCATION, "the position used more than the reserve");
        assertApproxEqRel(uint256(d.lpRegentUsed), lbp.currencyRaised / 2, 1e12, "half the raise");
        assertLe(uint256(d.lpRegentUsed), lbp.currencyRaised / 2, "more than half the raise");
        assertEq(
            regent.balanceOf(treasury) - treasuryBefore,
            lbp.currencyRaised - d.lpRegentUsed,
            "the rest of the raise reached the treasury"
        );

        uint256 swept = auctionBefore - l.subject.balanceOf(address(l.auction));
        toEscrow = l.subject.balanceOf(address(l.escrow)) - escrowBefore;
        assertEq(escrowBefore, PENDING_ALLOCATION, "escrow held exactly its 70% before graduation");
        assertEq(toEscrow, strategyBefore + swept - d.lpSubjectUsed, "the leftover SUBJECT went to the escrow");
        assertEq(l.subject.balanceOf(address(strategy)), 0, "the strategy kept SUBJECT");
    }

    /// @dev Exits one bid at the auction and claims its tokens, returning the SUBJECT its owner received.
    function _settle(Launched memory l, uint256 bidId) private returns (uint256 received) {
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

    /// @dev Every bid has exited and claimed: the bidders hold the whole sale allocation up to crumbs,
    ///      graduation sent no more than the unpaired reserve and crumbs to the escrow, and the sale allocation and the reserve
    ///      are exactly the bidders' SUBJECT, the pool's, the escrow's leftover and what the auction's
    ///      own rounding keeps.
    function _assertSoldOut(Launched memory l, uint256 received, uint256 toEscrow) private view {
        RegentLBPStrategyV2.Distribution memory d = _distribution(l);
        uint256 auctionKept = l.subject.balanceOf(address(l.auction));
        assertLe(received, AUCTION_ALLOCATION, "the bidders received more than the sale allocation");
        assertLe(AUCTION_ALLOCATION - received, SALE_CRUMBS, "the bidders did not buy the whole sale allocation");
        assertLe(
            toEscrow, RESERVE_ALLOCATION - d.lpSubjectUsed + SALE_CRUMBS,
            "graduation sent more than the unpaired reserve and crumbs to the escrow"
        );
        assertEq(
            received + auctionKept + toEscrow + d.lpSubjectUsed,
            AUCTION_ALLOCATION + RESERVE_ALLOCATION,
            "the sale allocation and the reserve are not all assigned"
        );
    }

    /// @dev The last checkpoint priced below the bid and the first priced above it, or zero when the
    ///      auction never rose above the bid.
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
