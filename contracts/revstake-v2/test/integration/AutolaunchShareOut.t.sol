// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {BidFillLib} from "../../src/libraries/BidFillLib.sol";
import {RegentsAutolaunchFactoryV2} from "../../src/factory/RegentsAutolaunchFactoryV2.sol";
import {RegentLBPStrategyV2} from "../../src/strategy/RegentLBPStrategyV2.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {IBidStorage} from "continuous-clearing-auction/interfaces/IBidStorage.sol";
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

/// @notice A graduated launch gives its bidders the entire sale allocation: what the auction sold,
///         plus a pro-rata share of what it did not and of the reserve the pool did not pair. The
///         pool opens at the raise divided by the sale allocation and pairs the whole reserve with
///         three quarters of the raise. The required raise is the sale allocation at the floor, or
///         the launcher's higher minimum, and an auction that falls short of it fails.
contract AutolaunchShareOutTest is AutolaunchFixture {
    using StateLibrary for IPoolManager;

    /// @dev The crumbs a graduation may leave unassigned, in SUBJECT base units: the full-range
    ///      position's rounding and the auction's own. One SUBJECT in a billion of the supply.
    uint256 private constant SUBJECT_CRUMBS = TOTAL_SUPPLY / 1e9;

    /// @dev A price far above the floor, so a bid there is filled in every block it is live.
    uint256 private constant GRADUATING_TICKS = 10_000;

    enum ShareOrder {
        BeforeExit,
        AfterExit,
        AfterClaim
    }

    function setUp() public {
        _deployAutolaunch();
    }

    // -------------------------------------------------------------------------
    // graduation: one bidder
    // -------------------------------------------------------------------------

    function test_SHR_001_SoleBidderAtTheStartReceivesTheWholeSaleAllocationBothOrderings() public {
        _soleBidderCase(_launchSorted(true, _params()), 2 * FLOOR_RAISE, _bidPrice(GRADUATING_TICKS), 0);
        _soleBidderCase(_launchSorted(false, _params()), 2 * FLOOR_RAISE, _bidPrice(GRADUATING_TICKS), 0);
    }

    /// @dev Nobody bids until the last block that still takes bids; every unit released earlier rolls
    ///      into it, so the one late bid still buys the whole sale allocation.
    function test_SHR_002_SoleBidderInTheLastEligibleBlockReceivesTheWholeSaleAllocation() public {
        Launched memory low = _launchSorted(true, _params());
        _soleBidderCase(low, 4 * FLOOR_RAISE, _bidPrice(GRADUATING_TICKS), low.auction.endBlock() - 1);
        Launched memory high = _launchSorted(false, _params());
        _soleBidderCase(high, 4 * FLOOR_RAISE, _bidPrice(GRADUATING_TICKS), high.auction.endBlock() - 1);
    }

    /// @dev A bid larger than the sale allocation at its own price limit: the clearing price rises to
    ///      the limit and the bid is partly filled there, refunded the rest, and still receives the
    ///      whole sale allocation.
    function test_SHR_003_SoleBidderPartlyFilledAtItsLimitReceivesTheWholeSaleAllocation() public {
        _soleBidderCase(_launchSorted(true, _params()), 20 * FLOOR_RAISE, _bidPrice(10), 0);
        _soleBidderCase(_launchSorted(false, _params()), 20 * FLOOR_RAISE, _bidPrice(10), 0);
    }

    function testFuzz_SHR_004_SoleBidderReceivesTheWholeSaleAllocation(uint128 amount, uint32 ticks, uint32 lateBy)
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
        _migrateAndAssertGraduation(l);

        uint256 before = l.subject.balanceOf(bidder);
        (uint256 filled, uint256 share) = _settle(l, bidId, ShareOrder.AfterClaim);
        RegentLBPStrategyV2.Distribution memory d = _distribution(l);
        assertEq(filled + share, l.subject.balanceOf(bidder) - before, "the bidder holds what it was paid");
        assertApproxEqAbs(
            filled + share + d.lpSubjectUsed,
            AUCTION_ALLOCATION + RESERVE_ALLOCATION,
            SUBJECT_CRUMBS,
            "the bidder and the pool hold the sale allocation and the reserve, up to crumbs"
        );
        assertApproxEqAbs(filled + share, AUCTION_ALLOCATION, SUBJECT_CRUMBS, "the whole sale allocation");
    }

    // -------------------------------------------------------------------------
    // graduation: several bidders
    // -------------------------------------------------------------------------

    /// @dev Three bids exercise every way a bid ends: `early` at 1.2 times the floor is outbid when
    ///      `anchor` arrives, `anchor` sets the final clearing price and is partly filled at it, and
    ///      `late` is priced above it and filled in every block. Each is settled at the auction and
    ///      paid its share, in each order relative to its own settlement, and nothing is left over but
    ///      crumbs.
    function test_SHR_005_SeveralBiddersEachWayABidEndsShareOutBothOrderings() public {
        _severalBiddersCase(true);
        _severalBiddersCase(false);
    }

    function _severalBiddersCase(bool subjectBelowRegent) private {
        Launched memory l = _launchSorted(subjectBelowRegent, _params());
        address early = makeAddr("early");
        address anchor = makeAddr("anchor");
        address late = makeAddr("late");
        uint256 anchorPrice = _bidPrice(1_000);

        _rollToStart(l);
        uint256 earlyBid = _bid(l, early, 12_000e18, _bidPrice(20));
        vm.roll(l.auction.startBlock() + 1_000);
        uint256 anchorBid = _bid(l, anchor, 400_000e18, anchorPrice);
        vm.roll(l.auction.startBlock() + 2_000);
        uint256 lateBid = _bid(l, late, 40_000e18, _bidPrice(GRADUATING_TICKS));
        _rollToMigration(l);
        _migrateAndAssertGraduation(l);

        Checkpoint memory finalCheckpoint = l.auction.checkpoints(l.auction.endBlock());
        assertEq(finalCheckpoint.clearingPrice, anchorPrice, "the anchor bid sets the final price");
        (uint64 earlyLast, uint64 earlyOutbid) = _hints(l.auction, earlyBid);
        assertNotEq(earlyOutbid, 0, "the early bid was outbid");
        (, uint64 anchorOutbid) = _hints(l.auction, anchorBid);
        assertEq(anchorOutbid, 0, "the anchor bid was never outbid");

        // A wrong hint pair is refused, exactly as the auction refuses it.
        address auction = address(l.auction);
        vm.expectRevert(BidFillLib.InvalidOutbidBlockCheckpointHint.selector);
        strategy.claimUnsoldShare(auction, earlyBid, earlyLast, earlyOutbid + 1);
        vm.expectRevert(BidFillLib.InvalidLastFullyFilledCheckpointHint.selector);
        strategy.claimUnsoldShare(auction, earlyBid, earlyOutbid, earlyOutbid);
        vm.expectRevert(BidFillLib.BidNotAtFinalClearingPrice.selector);
        strategy.claimUnsoldShare(auction, earlyBid, earlyLast, 0);

        (uint256 earlyFilled, uint256 earlyShare) = _settle(l, earlyBid, ShareOrder.BeforeExit);
        (uint256 anchorFilled, uint256 anchorShare) = _settle(l, anchorBid, ShareOrder.AfterExit);
        (uint256 lateFilled, uint256 lateShare) = _settle(l, lateBid, ShareOrder.AfterClaim);
        assertGt(earlyFilled, 0, "the early bid bought before it was outbid");
        assertGt(anchorFilled, lateFilled, "the anchor bid bought the most");

        RegentLBPStrategyV2.Distribution memory d = _distribution(l);
        uint256 filled = earlyFilled + anchorFilled + lateFilled;
        uint256 shared = earlyShare + anchorShare + lateShare;
        assertLe(filled, d.subjectSold, "the bids never won more than the auction kept");
        assertLe(shared, d.subjectShared, "the shares never add up to more than was held");
        assertEq(l.subject.balanceOf(address(strategy)), d.subjectShared - shared, "only crumbs remain");
        assertApproxEqAbs(
            filled + shared + d.lpSubjectUsed,
            AUCTION_ALLOCATION + RESERVE_ALLOCATION,
            SUBJECT_CRUMBS,
            "the sale allocation and the reserve are assigned"
        );
    }

    // -------------------------------------------------------------------------
    // the share-out
    // -------------------------------------------------------------------------

    function test_SHR_006_ShareIsPaidOnceToTheOwnerWhoeverCalls() public {
        Launched memory l = _defaultLaunch();
        uint256 bidId = _graduate(l, 2 * FLOOR_RAISE);
        address auction = address(l.auction);
        (address owner, uint256 quoted, bool claimed) = strategy.unsoldShareOf(auction, bidId, 0, 0);
        assertEq(owner, bidder, "the share belongs to the bid's owner");
        assertFalse(claimed, "a share was paid before anyone claimed it");

        uint256 before = l.subject.balanceOf(bidder);
        vm.prank(outsider);
        strategy.claimUnsoldShare(auction, bidId, 0, 0);
        assertEq(l.subject.balanceOf(bidder) - before, quoted, "the owner is paid");
        assertEq(l.subject.balanceOf(outsider), 0, "the caller is paid nothing");
        (,, claimed) = strategy.unsoldShareOf(auction, bidId, 0, 0);
        assertTrue(claimed, "the paid share is not recorded as paid");

        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategyV2.UnsoldShareAlreadyClaimed.selector, auction, bidId));
        strategy.claimUnsoldShare(auction, bidId, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategyV2.UnsoldShareAlreadyClaimed.selector, auction, bidId));
        vm.prank(bidder);
        strategy.claimUnsoldShare(auction, bidId, 0, 0);
    }

    /// @dev The auction pays bids from the claim block, before migration can run, so SUBJECT can
    ///      already be sent to the strategy when the launch graduates. What the auction sold is
    ///      measured from its own sweep, so SUBJECT sent beforehand joins the share-out and never
    ///      inflates a share.
    function test_SHR_007_SubjectSentToTheStrategyBeforeMigrationJoinsTheShareOut() public {
        Launched memory l = _defaultLaunch();
        _rollToStart(l);
        uint256 bidId = _bid(l, bidder, 2 * FLOOR_RAISE, _bidPrice(GRADUATING_TICKS));
        vm.roll(l.auction.claimBlock());
        vm.startPrank(bidder);
        l.auction.exitBid(bidId);
        l.auction.claimTokens(bidId);
        uint256 claimed = l.subject.balanceOf(bidder);
        l.subject.transfer(address(strategy), claimed);
        vm.stopPrank();
        _rollToMigration(l);
        strategy.migrate(address(l.auction));

        RegentLBPStrategyV2.Distribution memory d = _distribution(l);
        assertEq(d.subjectSold, claimed + l.subject.balanceOf(address(l.auction)), "what the auction kept");
        assertEq(d.subjectShared, l.subject.balanceOf(address(strategy)), "held for the share-out");
        assertGe(d.subjectShared, claimed, "the SUBJECT sent here is shared");

        strategy.claimUnsoldShare(address(l.auction), bidId, 0, 0);
        assertEq(
            l.subject.balanceOf(bidder),
            FullMath.mulDiv(d.subjectShared, claimed, d.subjectSold),
            "the sole bidder takes its pro rata share"
        );
        assertLe(l.subject.balanceOf(bidder), d.subjectShared, "never more than was held");
    }

    function test_SHR_008_ShareIsRefusedUntilGraduationAndForAFailedLaunch() public {
        Launched memory l = _defaultLaunch();
        address auction = address(l.auction);
        _rollToStart(l);
        uint256 bidId = _bid(l, bidder, FLOOR_RAISE - 1, _bidPrice(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                RegentLBPStrategyV2.LaunchNotGraduated.selector, RegentLBPStrategyV2.Lifecycle.Active
            )
        );
        strategy.claimUnsoldShare(auction, bidId, 0, 0);

        _rollToMigration(l);
        strategy.migrate(auction);
        vm.expectRevert(
            abi.encodeWithSelector(
                RegentLBPStrategyV2.LaunchNotGraduated.selector, RegentLBPStrategyV2.Lifecycle.Failed
            )
        );
        strategy.claimUnsoldShare(auction, bidId, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(RegentLBPStrategyV2.LaunchNotGraduated.selector, RegentLBPStrategyV2.Lifecycle.None)
        );
        strategy.claimUnsoldShare(outsider, bidId, 0, 0);
    }

    function test_SHR_009_ShareIsRefusedForABidTheAuctionNeverTook() public {
        Launched memory l = _defaultLaunch();
        uint256 bidId = _graduate(l, 2 * FLOOR_RAISE);
        vm.expectRevert(abi.encodeWithSelector(IBidStorage.BidIdDoesNotExist.selector, bidId + 1));
        strategy.claimUnsoldShare(address(l.auction), bidId + 1, 0, 0);
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

    /// @dev A launcher's minimum above the floor minimum is what the auction must raise: met exactly
    ///      it graduates and opens the pool at that raise over the sale allocation, and one unit
    ///      short it fails even though it clears the floor minimum many times over.
    function test_MIN_004_LauncherMinimumAboveTheFloorMinimumIsTheRequiredRaise() public {
        RegentsAutolaunchFactoryV2.LaunchParams memory params = _params();
        params.minimumRegentRaised = 3 * FLOOR_RAISE;
        Launched memory met = _launchSorted(true, params);
        Launched memory below = _launchSorted(false, params);
        assertEq(_distribution(met).requiredRegentRaised, 3 * FLOOR_RAISE, "the launcher's minimum is recorded");

        _rollToStart(met);
        _bid(met, bidder, 3 * FLOOR_RAISE, _bidPrice(GRADUATING_TICKS));
        _bid(below, bidder, 3 * FLOOR_RAISE - 1, _bidPrice(GRADUATING_TICKS));
        _rollToMigration(below);

        _migrateAndAssertGraduation(met);
        assertEq(met.auction.lbpInitializationParams().currencyRaised, 3 * FLOOR_RAISE, "the whole minimum was raised");
        strategy.migrate(address(below.auction));
        assertEq(uint8(_distribution(below).lifecycle), uint8(RegentLBPStrategyV2.Lifecycle.Failed), "one unit short");
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    /// @dev One bid far above the floor in the auction's first block, then migration.
    function _graduate(Launched memory l, uint128 amount) private returns (uint256 bidId) {
        _rollToStart(l);
        bidId = _bid(l, bidder, amount, _bidPrice(GRADUATING_TICKS));
        _rollToMigration(l);
        _migrateAndAssertGraduation(l);
    }

    /// @dev Migrates and checks the graduation's economics: the pool opens at the raise over the sale
    ///      allocation, pairs the whole reserve (to crumbs) with three quarters of the raise, the rest
    ///      of the raise reaches the treasury, and escrow keeps exactly its 65%.
    function _migrateAndAssertGraduation(Launched memory l) private {
        uint256 treasuryBefore = regent.balanceOf(treasury);
        strategy.migrate(address(l.auction));

        RegentLBPStrategyV2.Distribution memory d = _distribution(l);
        assertEq(uint8(d.lifecycle), uint8(RegentLBPStrategyV2.Lifecycle.Graduated), "the launch did not graduate");
        LBPInitializationParams memory lbp = l.auction.lbpInitializationParams();
        assertGe(lbp.currencyRaised, d.requiredRegentRaised, "the minimum was met");

        PoolKey memory key = strategy.poolKeyOf(address(l.subject));
        bool regentIsCurrency0 = Currency.unwrap(key.currency0) == BaseBindings.REGENT;
        uint256 priceX96 = FullMath.mulDiv(lbp.currencyRaised, FixedPoint96.Q96, AUCTION_ALLOCATION);
        assertLe(priceX96, lbp.initialPriceX96, "at or below the final clearing price");
        uint160 expected =
            TokenPricing.convertToSqrtPriceX96(TokenPricing.convertToPriceX192(priceX96, regentIsCurrency0));
        (uint160 slotPrice,,,) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(_poolId(l));
        assertEq(slotPrice, expected, "the pool did not open at the raise over the sale allocation");

        assertApproxEqAbs(uint256(d.lpSubjectUsed), RESERVE_ALLOCATION, SUBJECT_CRUMBS, "the whole reserve is paired");
        assertApproxEqRel(uint256(d.lpRegentUsed), (lbp.currencyRaised * 3) / 4, 1e12, "three quarters of the raise");
        assertEq(
            regent.balanceOf(treasury) - treasuryBefore,
            lbp.currencyRaised - d.lpRegentUsed,
            "the rest of the raise reached the treasury"
        );
        assertEq(l.subject.balanceOf(address(l.escrow)), PENDING_ALLOCATION, "escrow keeps exactly its 65%");
        assertEq(l.subject.balanceOf(address(strategy)), d.subjectShared, "the strategy holds exactly the share-out");
    }

    /// @dev Settles one bid at the auction and pays its share, in the given order relative to the
    ///      auction's own exit and claim. The share never changes across the bid's settlement.
    function _settle(Launched memory l, uint256 bidId, ShareOrder order)
        private
        returns (uint256 filled, uint256 share)
    {
        address auction = address(l.auction);
        Bid memory placed = l.auction.bids(bidId);
        (uint64 lastFullyFilled, uint64 outbid) = _hints(l.auction, bidId);
        uint256 startBalance = l.subject.balanceOf(placed.owner);
        uint256 finalPrice = l.auction.checkpoints(l.auction.endBlock()).clearingPrice;

        (, uint256 quoted,) = strategy.unsoldShareOf(auction, bidId, lastFullyFilled, outbid);
        if (order == ShareOrder.BeforeExit) _claimShare(l, bidId, lastFullyFilled, outbid, 0, quoted, true);

        if (placed.maxPrice > finalPrice) {
            l.auction.exitBid(bidId);
        } else {
            l.auction.exitPartiallyFilledBid(bidId, lastFullyFilled, outbid);
        }
        filled = l.auction.bids(bidId).tokensFilled;
        (, uint256 afterExit,) = strategy.unsoldShareOf(auction, bidId, lastFullyFilled, outbid);
        assertEq(afterExit, quoted, "the share does not change when the bid exits");
        if (order == ShareOrder.BeforeExit) {
            RegentLBPStrategyV2.Distribution memory d = _distribution(l);
            assertEq(quoted, FullMath.mulDiv(d.subjectShared, filled, d.subjectSold), "pro rata");
        }
        if (order == ShareOrder.AfterExit) _claimShare(l, bidId, lastFullyFilled, outbid, filled, quoted, false);

        l.auction.claimTokens(bidId);
        assertEq(l.auction.bids(bidId).tokensFilled, 0, "the auction zeroed its record of the fill");
        if (order == ShareOrder.AfterClaim) _claimShare(l, bidId, lastFullyFilled, outbid, filled, quoted, false);

        share = quoted;
        assertEq(l.subject.balanceOf(placed.owner) - startBalance, filled + share, "paid fill and share");
    }

    function _claimShare(
        Launched memory l,
        uint256 bidId,
        uint64 lastFullyFilled,
        uint64 outbid,
        uint256 filled,
        uint256 quoted,
        bool fillUnknown
    ) private {
        address owner = l.auction.bids(bidId).owner;
        vm.expectEmit(true, true, true, !fillUnknown, address(strategy));
        emit RegentLBPStrategyV2.UnsoldShareClaimed(address(l.auction), bidId, owner, filled, quoted);
        vm.prank(outsider);
        strategy.claimUnsoldShare(address(l.auction), bidId, lastFullyFilled, outbid);
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
