// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {MemestockSplitterV1} from "../src/MemestockSplitterV1.sol";
import {StocksBindings} from "../src/StocksBindings.sol";
import {StocksFeeHookV1} from "../src/StocksFeeHookV1.sol";
import {StocksLaunchpadV2} from "../src/StocksLaunchpadV2.sol";
import {StocksPreset} from "../src/StocksPreset.sol";
import {BidFillLib} from "../src/libraries/BidFillLib.sol";
import {FixtureStockToken} from "../src/fixtures/FixtureStockToken.sol";
import {IStocksLaunchpadV2} from "../src/interfaces/IStocksLaunchpadV2.sol";
import {FixtureStockRoute} from "../src/routes/FixtureStockRoute.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {StocksFixture} from "./StocksFixture.sol";

/// @notice Graduation and failure. A graduated launch gives its bidders the entire sale allocation
///         (what the auction sold, plus a pro-rata share of anything it did not), opens the official
///         pool at the raise divided by the sale allocation and locks the whole reserve with the whole
///         raise in one full-range position held by the fee-only locker. An auction that raised less
///         than the sale allocation at the floor, including one nobody bid in, fails: the inventory is
///         retired and bidders are refunded through the CCA alone.
contract StocksLaunchpadMigrateTest is StocksFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 private constant Q96 = FixedPoint96.Q96;

    /// @dev The crumbs a graduation may leave unassigned, in NEW base units: the full-range position's
    ///      unpaired reserve and the auction's own rounding. One NEW in a billion of the supply.
    uint256 private constant NEW_CRUMBS = StocksPreset.INITIAL_SUPPLY / 1e9;

    enum ShareOrder {
        BeforeExit,
        AfterExit,
        AfterClaim
    }

    function setUp() public {
        _deployStocks();
    }

    // -------------------------------------------------------------------------
    // graduation: one bidder
    // -------------------------------------------------------------------------

    function test_sole_bidder_at_the_start_receives_the_whole_sale_allocation_both_orderings() public {
        _soleBidderCase(_launch(STOCK_LOW), 1_000e8, _bidPrice(GRADUATING_TICKS), 0);
        _soleBidderCase(_launch(STOCK_HIGH), 1_000e8, _bidPrice(GRADUATING_TICKS), 0);
    }

    /// @dev Nobody bids until the last block that still takes bids; every unit released earlier rolls
    ///      into it, so the one late bid still buys the whole sale allocation.
    function test_sole_bidder_in_the_last_eligible_block_receives_the_whole_sale_allocation() public {
        Launched memory low = _launch(STOCK_LOW);
        _soleBidderCase(low, 20e8, _bidPrice(GRADUATING_TICKS), low.auction.endBlock() - 1);
        Launched memory high = _launch(STOCK_HIGH);
        _soleBidderCase(high, 20e8, _bidPrice(GRADUATING_TICKS), high.auction.endBlock() - 1);
    }

    /// @dev A bid larger than the sale allocation at its own price limit: the clearing price rises to
    ///      the limit and the bid is partly filled there, refunded the rest, and still receives the whole
    ///      sale allocation.
    function test_sole_bidder_partly_filled_at_its_limit_receives_the_whole_sale_allocation() public {
        _soleBidderCase(_launch(STOCK_LOW), 100e8, _bidPrice(10), 0);
        _soleBidderCase(_launch(STOCK_HIGH), 100e8, _bidPrice(10), 0);
    }

    function testFuzz_sole_bidder_receives_the_whole_sale_allocation(uint128 amount, uint32 ticks, uint32 lateBy)
        public
    {
        amount = uint128(bound(amount, 2 * REQUIRED_RAISE, 1_000_000e8));
        uint256 priceQ96 = _bidPrice(bound(ticks, 1, 1_000_000));
        Launched memory l = _launch(ticks % 2 == 0 ? STOCK_LOW : STOCK_HIGH);
        uint256 bidBlock = l.auction.startBlock() + bound(lateBy, 0, StocksPreset.AUCTION_DURATION_BLOCKS - 1);
        _soleBidderCase(l, amount, priceQ96, bidBlock);
    }

    /// @param bidBlock The block the bid is placed in; zero for the auction's first block.
    function _soleBidderCase(Launched memory l, uint128 amount, uint256 priceQ96, uint256 bidBlock) private {
        vm.roll(bidBlock == 0 ? l.auction.startBlock() : bidBlock);
        uint256 bidId = _bidDirect(l, bidder, amount, priceQ96);
        _rollToMigration(l);
        _migrateAndAssertGraduation(l, amount);

        (uint256 filled, uint256 share) = _settle(l, bidId, ShareOrder.AfterClaim);
        IStocksLaunchpadV2.Launch memory record = _record(l);
        assertEq(filled + share, UERC20(l.newToken).balanceOf(bidder), "the bidder holds what it was paid");
        assertApproxEqAbs(
            filled + share + record.lpNewUsed,
            StocksPreset.INITIAL_SUPPLY,
            NEW_CRUMBS,
            "the bidder and the pool hold the whole supply, up to crumbs"
        );
        assertApproxEqAbs(filled + share, StocksPreset.AUCTION_INVENTORY, NEW_CRUMBS, "the whole sale allocation");
    }

    // -------------------------------------------------------------------------
    // graduation: several bidders
    // -------------------------------------------------------------------------

    /// @dev Three bids exercise every way a bid ends: `early` at 1.2 times the floor is outbid when
    ///      `anchor` arrives, `anchor` sets the final clearing price and is partly filled at it, and
    ///      `late` is priced above it and filled in every block. Each is settled at the auction and
    ///      paid its share, in each order relative to its own settlement, and nothing is left over but
    ///      crumbs.
    function test_several_bidders_each_way_a_bid_ends_share_out_both_orderings() public {
        _severalBiddersCase(STOCK_LOW);
        _severalBiddersCase(STOCK_HIGH);
    }

    function _severalBiddersCase(address stock) private {
        Launched memory l = _launch(stock);
        address early = makeAddr("early");
        address anchor = makeAddr("anchor");
        address late = makeAddr("late");
        uint256 anchorPrice = _bidPrice(1_000);

        _rollToStart(l);
        uint256 earlyBid = _bidDirect(l, early, 3e8, _bidPrice(20));
        vm.roll(l.auction.startBlock() + 1_000);
        uint256 anchorBid = _bidDirect(l, anchor, 100e8, anchorPrice);
        vm.roll(l.auction.startBlock() + 2_000);
        uint256 lateBid = _bidDirect(l, late, 10e8, _bidPrice(GRADUATING_TICKS));
        _rollToMigration(l);
        _migrateAndAssertGraduation(l, 113e8);

        Checkpoint memory finalCheckpoint = l.auction.checkpoints(l.auction.endBlock());
        assertEq(finalCheckpoint.clearingPrice, anchorPrice, "the anchor bid sets the final price");
        (uint64 earlyLast, uint64 earlyOutbid) = _hints(l.auction, earlyBid);
        assertNotEq(earlyOutbid, 0, "the early bid was outbid");
        (, uint64 anchorOutbid) = _hints(l.auction, anchorBid);
        assertEq(anchorOutbid, 0, "the anchor bid was never outbid");

        // A wrong hint pair is refused, exactly as the auction refuses it.
        vm.expectRevert(BidFillLib.InvalidOutbidBlockCheckpointHint.selector);
        launchpad.claimUnsoldShare(l.launchId, earlyBid, earlyLast, earlyOutbid + 1);
        vm.expectRevert(BidFillLib.InvalidLastFullyFilledCheckpointHint.selector);
        launchpad.claimUnsoldShare(l.launchId, earlyBid, earlyOutbid, earlyOutbid);
        vm.expectRevert(BidFillLib.BidNotAtFinalClearingPrice.selector);
        launchpad.claimUnsoldShare(l.launchId, earlyBid, earlyLast, 0);

        (uint256 earlyFilled, uint256 earlyShare) = _settle(l, earlyBid, ShareOrder.BeforeExit);
        (uint256 anchorFilled, uint256 anchorShare) = _settle(l, anchorBid, ShareOrder.AfterExit);
        (uint256 lateFilled, uint256 lateShare) = _settle(l, lateBid, ShareOrder.AfterClaim);
        assertGt(earlyFilled, 0, "the early bid bought before it was outbid");
        assertGt(anchorFilled, lateFilled, "the anchor bid bought the most");

        IStocksLaunchpadV2.Launch memory record = _record(l);
        uint256 filled = earlyFilled + anchorFilled + lateFilled;
        uint256 shared = earlyShare + anchorShare + lateShare;
        assertLe(filled, record.newSold, "the bids never won more than the auction kept");
        assertLe(shared, record.newShared, "the shares never add up to more than was held");
        assertEq(UERC20(l.newToken).balanceOf(address(launchpad)), record.newShared - shared, "only crumbs remain");
        assertApproxEqAbs(
            filled + shared + record.lpNewUsed, StocksPreset.INITIAL_SUPPLY, NEW_CRUMBS, "the whole supply is assigned"
        );
    }

    // -------------------------------------------------------------------------
    // the share-out
    // -------------------------------------------------------------------------

    function test_share_is_paid_once_to_the_owner_whoever_calls() public {
        Launched memory l = _launch(STOCK_LOW);
        uint256 bidId = _graduate(l, 50e8);
        (address owner, uint256 quoted, bool claimed) = launchpad.unsoldShareOf(l.launchId, bidId, 0, 0);
        assertEq(owner, bidder);
        assertFalse(claimed);

        uint256 before = UERC20(l.newToken).balanceOf(bidder);
        vm.prank(outsider);
        launchpad.claimUnsoldShare(l.launchId, bidId, 0, 0);
        assertEq(UERC20(l.newToken).balanceOf(bidder) - before, quoted, "the owner is paid");
        assertEq(UERC20(l.newToken).balanceOf(outsider), 0, "the caller is paid nothing");
        (,, claimed) = launchpad.unsoldShareOf(l.launchId, bidId, 0, 0);
        assertTrue(claimed);

        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV2.UnsoldShareAlreadyClaimed.selector, l.launchId, bidId));
        launchpad.claimUnsoldShare(l.launchId, bidId, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV2.UnsoldShareAlreadyClaimed.selector, l.launchId, bidId));
        vm.prank(bidder);
        launchpad.claimUnsoldShare(l.launchId, bidId, 0, 0);
    }

    /// @dev The auction pays bids from the claim block, before migration can run, so NEW can already
    ///      be sent to the launchpad when it graduates. What the auction sold is measured from its own
    ///      sweep, so NEW sent beforehand joins the share-out and never inflates a share.
    function test_new_sent_to_the_launchpad_before_migration_joins_the_share_out() public {
        Launched memory l = _launch(STOCK_LOW);
        _rollToStart(l);
        uint256 bidId = _bidDirect(l, bidder, 50e8, _bidPrice(GRADUATING_TICKS));
        vm.roll(l.auction.claimBlock());
        uint256 claimed = _claimNewTo(l, bidId, address(launchpad));
        _rollToMigration(l);
        launchpad.migrate(l.launchId);

        IStocksLaunchpadV2.Launch memory record = _record(l);
        assertEq(record.newSold, claimed + UERC20(l.newToken).balanceOf(address(l.auction)), "what the auction kept");
        assertEq(record.newShared, UERC20(l.newToken).balanceOf(address(launchpad)), "held for the share-out");
        assertGe(record.newShared, claimed, "the NEW sent here is shared");

        launchpad.claimUnsoldShare(l.launchId, bidId, 0, 0);
        assertEq(
            UERC20(l.newToken).balanceOf(bidder),
            FullMath.mulDiv(record.newShared, claimed, record.newSold),
            "the sole bidder takes its pro rata share"
        );
        assertLe(UERC20(l.newToken).balanceOf(bidder), record.newShared, "never more than was held");
    }

    function test_share_is_refused_until_graduation_and_for_a_failed_launch() public {
        Launched memory l = _launch(STOCK_LOW);
        _rollToStart(l);
        uint256 bidId = _bidDirect(l, bidder, REQUIRED_RAISE - 1, _bidPrice(1));
        vm.expectRevert(
            abi.encodeWithSelector(StocksLaunchpadV2.LaunchNotGraduated.selector, IStocksLaunchpadV2.Lifecycle.Active)
        );
        launchpad.claimUnsoldShare(l.launchId, bidId, 0, 0);

        _rollToMigration(l);
        launchpad.migrate(l.launchId);
        vm.expectRevert(
            abi.encodeWithSelector(StocksLaunchpadV2.LaunchNotGraduated.selector, IStocksLaunchpadV2.Lifecycle.Failed)
        );
        launchpad.claimUnsoldShare(l.launchId, bidId, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(StocksLaunchpadV2.LaunchNotGraduated.selector, IStocksLaunchpadV2.Lifecycle.None)
        );
        launchpad.claimUnsoldShare(42, bidId, 0, 0);
    }

    function test_share_is_refused_for_a_bid_the_auction_never_took() public {
        Launched memory l = _launch(STOCK_LOW);
        uint256 bidId = _graduate(l, 50e8);
        vm.expectRevert(abi.encodeWithSelector(IBidStorage.BidIdDoesNotExist.selector, bidId + 1));
        launchpad.claimUnsoldShare(l.launchId, bidId + 1, 0, 0);
    }

    // -------------------------------------------------------------------------
    // the minimum raise
    // -------------------------------------------------------------------------

    /// @dev Placed in the auction's first block, a bid of exactly the minimum is counted in full.
    function test_minimum_met_exactly_graduates_and_one_unit_below_fails() public {
        Launched memory met = _launch(STOCK_LOW);
        _rollToStart(met);
        _bidDirect(met, bidder, REQUIRED_RAISE, _bidPrice(GRADUATING_TICKS));
        Launched memory below = _launch(STOCK_HIGH);
        _rollToStart(below);
        _bidDirect(below, bidder, REQUIRED_RAISE - 1, _bidPrice(GRADUATING_TICKS));

        _rollToMigration(below);
        launchpad.migrate(met.launchId);
        launchpad.migrate(below.launchId);
        assertEq(uint8(_record(met).lifecycle), uint8(IStocksLaunchpadV2.Lifecycle.Graduated), "exactly met");
        assertEq(uint8(_record(below).lifecycle), uint8(IStocksLaunchpadV2.Lifecycle.Failed), "one unit short");
    }

    /// @dev The pinned auction rounds what it counts of a bid placed after its first block down by up
    ///      to one base unit, so there the minimum plus one base unit is what graduates, in any block.
    function testFuzz_minimum_plus_one_unit_graduates_in_any_block(uint32 lateBy) public {
        Launched memory l = _launch(STOCK_LOW);
        vm.roll(l.auction.startBlock() + bound(lateBy, 0, StocksPreset.AUCTION_DURATION_BLOCKS - 1));
        _bidDirect(l, bidder, REQUIRED_RAISE + 1, _bidPrice(GRADUATING_TICKS));
        _rollToMigration(l);
        launchpad.migrate(l.launchId);
        assertEq(uint8(_record(l).lifecycle), uint8(IStocksLaunchpadV2.Lifecycle.Graduated));
    }

    function test_minimum_bid_after_the_first_block_is_counted_one_unit_short_and_fails() public {
        Launched memory l = _launch(STOCK_LOW);
        vm.roll(l.auction.startBlock() + 1);
        _bidDirect(l, bidder, REQUIRED_RAISE, _bidPrice(GRADUATING_TICKS));
        _rollToMigration(l);
        l.auction.checkpoint();
        assertEq(l.auction.currencyRaised(), REQUIRED_RAISE - 1, "the auction's own rounding");
        launchpad.migrate(l.launchId);
        assertEq(uint8(_record(l).lifecycle), uint8(IStocksLaunchpadV2.Lifecycle.Failed));
    }

    // -------------------------------------------------------------------------
    // other currency decimals
    // -------------------------------------------------------------------------

    /// @dev An eighteen-decimal STOCK: the same rules hold at a floor of 1e-8 of it per NEW, a minimum
    ///      of five whole units.
    function test_eighteen_decimal_stock_graduates_and_shares_out() public {
        address stock18 = address(new MockERC20("Eighteen", "EIGHTEEN", 18));
        FixtureStockRoute route = new FixtureStockRoute(stock18, USDC_PER_SHARE);
        vm.prank(governance);
        launchpad.admitStock(stock18, address(route));
        (, uint8 decimals,) = launchpad.stockAdmission(stock18);
        assertEq(decimals, 18);

        IStocksLaunchpadV2.LaunchParams memory params = _params(stock18);
        params.floorPriceQ96 = 792_281_625_142_643_375_900;
        uint256 required = launchpad.requiredStockRaisedFor(params.floorPriceQ96);
        assertEq(required, 5e18, "five whole units");

        Launched memory short = _launchAs(launcher, params);
        Launched memory l = _launchAs(launcher, params);
        uint256 limit = params.floorPriceQ96 * 1_001;
        _rollToStart(l);
        _bidAt(short, uint128(required - 1), limit, params.floorPriceQ96);
        uint256 bidId = _bidAt(l, uint128(required * 3), limit, params.floorPriceQ96);
        _rollToMigration(l);
        launchpad.migrate(short.launchId);
        assertEq(uint8(_record(short).lifecycle), uint8(IStocksLaunchpadV2.Lifecycle.Failed), "one unit short");
        _migrateAndAssertGraduation(l, required * 3);

        (uint256 filled, uint256 share) = _settle(l, bidId, ShareOrder.AfterExit);
        assertApproxEqAbs(filled + share, StocksPreset.AUCTION_INVENTORY, NEW_CRUMBS, "the whole sale allocation");
    }

    /// @dev `_bidDirect` for a launch at its own floor, which is the bid's tick hint.
    function _bidAt(Launched memory l, uint128 amount, uint256 priceQ96, uint256 floorPriceQ96)
        private
        returns (uint256 bidId)
    {
        MockERC20(l.stock).mint(bidder, amount);
        vm.startPrank(bidder);
        MockERC20(l.stock).approve(StocksBindings.PERMIT2, amount);
        IAllowanceTransfer(StocksBindings.PERMIT2)
            .approve(l.stock, address(l.auction), uint160(amount), type(uint48).max);
        bidId = l.auction.submitBid(priceQ96, amount, bidder, floorPriceQ96, "");
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // the graduation checks every case above shares
    // -------------------------------------------------------------------------

    function _migrateAndAssertGraduation(Launched memory l, uint256 totalBid) private {
        IContinuousClearingAuction cca = l.auction;
        cca.checkpoint();
        LBPInitializationParams memory lbp = cca.lbpInitializationParams();
        uint256 pmStockBefore = MockERC20(l.stock).balanceOf(address(positionManager));
        uint256 pmNewBefore = UERC20(l.newToken).balanceOf(address(positionManager));
        uint256 ccaNewBefore = UERC20(l.newToken).balanceOf(address(cca));
        uint256 nextTokenId = positionManager.nextTokenId();
        bytes32 poolId = _poolId(l);

        launchpad.migrate(l.launchId);

        IStocksLaunchpadV2.Launch memory record = _record(l);
        assertEq(uint8(record.lifecycle), uint8(IStocksLaunchpadV2.Lifecycle.Graduated));
        assertEq(record.poolId, poolId);
        assertGe(lbp.currencyRaised, record.requiredStockRaised, "the minimum was met");

        // The pool opens at the raise divided by the whole sale allocation, never above the auction's
        // final clearing price.
        bool stockIsCurrency0 = _stockIsCurrency0(l);
        uint256 priceX96 = FullMath.mulDiv(lbp.currencyRaised, Q96, StocksPreset.AUCTION_INVENTORY);
        assertLe(priceX96, lbp.initialPriceX96, "at or below the final clearing price");
        uint160 expectedSqrtPrice =
            TokenPricing.convertToSqrtPriceX96(TokenPricing.convertToPriceX192(priceX96, stockIsCurrency0));
        assertEq(record.finalSqrtPriceX96, expectedSqrtPrice);
        assertEq(_sqrtPrice(l), expectedSqrtPrice, "pool at raise / sale allocation");
        assertGt(IPoolManager(address(poolManager)).getLiquidity(PoolId.wrap(poolId)), 0, "live liquidity");

        _assertLockedPosition(record, nextTokenId);
        assertEq(positionManager.nextTokenId(), nextTokenId + 1, "exactly one position minted");
        assertEq(
            MockERC20(l.stock).balanceOf(address(positionManager)), pmStockBefore, "PositionManager STOCK unchanged"
        );
        assertEq(UERC20(l.newToken).balanceOf(address(positionManager)), pmNewBefore, "PositionManager NEW unchanged");

        // STOCK: the whole raise is paired but for rounding, which goes to the hook's REGENT lane.
        (uint256 dust,) = hook.accrued(poolId);
        assertEq(uint256(record.lpStockUsed) + dust, lbp.currencyRaised, "raised == paired + dust");
        assertLe(dust, lbp.currencyRaised / 1e9 + 2, "the unpaired STOCK is rounding");
        assertEq(MockERC20(l.stock).balanceOf(address(hook)), dust, "hook holds exactly the dust");
        assertEq(MockERC20(l.stock).balanceOf(address(launchpad)), 0, "launchpad keeps no STOCK");
        assertEq(
            MockERC20(l.stock).balanceOf(address(cca)),
            totalBid - lbp.currencyRaised,
            "auction keeps only the bidders' refundable remainder"
        );

        // NEW: the auction keeps what it sold for its bids, the pool takes the reserve, and the
        // launchpad holds the rest for the share-out. Nothing is retired and the three reconcile.
        uint256 swept = ccaNewBefore - UERC20(l.newToken).balanceOf(address(cca));
        assertEq(record.newSold, StocksPreset.AUCTION_INVENTORY - swept, "newSold is what the auction kept");
        assertGe(record.newSold, lbp.tokensSold, "the auction keeps the claimable NEW");
        assertEq(record.newShared, UERC20(l.newToken).balanceOf(address(launchpad)), "held for the share-out");
        assertEq(
            record.newSold + record.newShared + record.lpNewUsed, StocksPreset.INITIAL_SUPPLY, "the supply reconciles"
        );
        assertLe(record.newShared, NEW_CRUMBS, "the auction sold the allocation but for crumbs");
        assertEq(record.retiredNew, 0, "nothing is retired");
        assertEq(UERC20(l.newToken).balanceOf(StocksBindings.DEAD_ADDRESS), 0, "nothing is sent to the dead address");

        // The hook knows the pool, and the launch has its own fresh splitter.
        StocksFeeHookV1.PoolRecord memory pool = hook.pool(poolId);
        assertEq(pool.stock, l.stock);
        assertEq(pool.newToken, l.newToken);
        assertEq(pool.splitter, record.splitter);
        MemestockSplitterV1 created = MemestockSplitterV1(record.splitter);
        assertGt(record.splitter.code.length, 0, "splitter deployed");
        assertEq(created.memestock(), l.newToken);
        assertEq(created.stock(), l.stock);
        assertEq(created.dollar(), StocksBindings.USDC);
        assertEq(created.totalStaked(), 0);
        vm.expectRevert();
        created.initialize(l.newToken, l.stock);
    }

    /// @dev The one locked position: full range, in the official pool, owned by and registered in the
    ///      locker.
    function _assertLockedPosition(IStocksLaunchpadV2.Launch memory record, uint256 nextTokenId) private view {
        assertEq(record.lpTokenId, nextTokenId, "the position is this graduation's mint");
        assertEq(IERC721(address(positionManager)).ownerOf(record.lpTokenId), address(locker), "owned by the locker");
        assertEq(locker.splitterOf(record.lpTokenId), record.splitter, "registered with the launch's splitter");
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(record.lpTokenId);
        assertEq(PoolId.unwrap(key.toId()), record.poolId);
        assertEq(info.tickLower(), TickMath.minUsableTick(StocksPreset.POOL_TICK_SPACING));
        assertEq(info.tickUpper(), TickMath.maxUsableTick(StocksPreset.POOL_TICK_SPACING));
        assertGt(positionManager.getPositionLiquidity(record.lpTokenId), 0);
        assertApproxEqAbs(record.lpNewUsed, StocksPreset.MIGRATION_RESERVE, NEW_CRUMBS, "the whole reserve is paired");
    }

    /// @dev Settle one bid at the auction and take its share, the share at the chosen point. Returns the
    ///      NEW the auction paid it and its share.
    function _settle(Launched memory l, uint256 bidId, ShareOrder order)
        private
        returns (uint256 filled, uint256 share)
    {
        Bid memory bid = l.auction.bids(bidId);
        (uint64 lastFullyFilled, uint64 outbid) = _hints(l.auction, bidId);
        uint256 startBalance = UERC20(l.newToken).balanceOf(bid.owner);
        uint256 finalPrice = l.auction.checkpoints(l.auction.endBlock()).clearingPrice;

        (, uint256 quoted,) = launchpad.unsoldShareOf(l.launchId, bidId, lastFullyFilled, outbid);
        if (order == ShareOrder.BeforeExit) _claimShare(l, bidId, lastFullyFilled, outbid, 0, quoted, true);

        if (bid.maxPrice > finalPrice) {
            l.auction.exitBid(bidId);
        } else {
            l.auction.exitPartiallyFilledBid(bidId, lastFullyFilled, outbid);
        }
        filled = l.auction.bids(bidId).tokensFilled;
        (, uint256 afterExit,) = launchpad.unsoldShareOf(l.launchId, bidId, lastFullyFilled, outbid);
        assertEq(afterExit, quoted, "the share does not change when the bid exits");
        if (order == ShareOrder.BeforeExit) {
            assertEq(quoted, FullMath.mulDiv(_record(l).newShared, filled, _record(l).newSold), "pro rata");
        }
        if (order == ShareOrder.AfterExit) _claimShare(l, bidId, lastFullyFilled, outbid, filled, quoted, false);

        l.auction.claimTokens(bidId);
        assertEq(l.auction.bids(bidId).tokensFilled, 0, "the auction zeroed its record of the fill");
        if (order == ShareOrder.AfterClaim) _claimShare(l, bidId, lastFullyFilled, outbid, filled, quoted, false);

        share = quoted;
        assertEq(UERC20(l.newToken).balanceOf(bid.owner) - startBalance, filled + share, "paid fill and share");
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
        vm.expectEmit(true, true, true, !fillUnknown, address(launchpad));
        emit IStocksLaunchpadV2.UnsoldShareClaimed(l.launchId, bidId, owner, filled, quoted);
        vm.prank(outsider);
        launchpad.claimUnsoldShare(l.launchId, bidId, lastFullyFilled, outbid);
        if (!fillUnknown) {
            assertEq(quoted, FullMath.mulDiv(_record(l).newShared, filled, _record(l).newSold), "pro rata");
        }
    }

    /// @dev The hints `exitPartiallyFilledBid` takes, found by walking the auction's checkpoints: the
    ///      last one priced below the bid's limit and the first one priced above it (zero if none).
    function _hints(IContinuousClearingAuction auction, uint256 bidId)
        private
        view
        returns (uint64 lastFullyFilled, uint64 outbid)
    {
        Bid memory bid = auction.bids(bidId);
        uint64 blockNumber = bid.startBlock;
        while (blockNumber != type(uint64).max) {
            Checkpoint memory checkpoint = auction.checkpoints(blockNumber);
            if (checkpoint.clearingPrice < bid.maxPrice) lastFullyFilled = blockNumber;
            if (checkpoint.clearingPrice > bid.maxPrice && outbid == 0) outbid = blockNumber;
            blockNumber = checkpoint.next;
        }
    }

    // -------------------------------------------------------------------------
    // records
    // -------------------------------------------------------------------------

    function test_each_graduation_gets_its_own_splitter() public {
        Launched memory first = _launch(STOCK_LOW);
        _graduate(first, 1_000e8);
        Launched memory second = _launch(STOCK_HIGH);
        _graduate(second, 1_000e8);
        assertNotEq(_record(first).splitter, _record(second).splitter);
        assertNotEq(_record(first).splitter, launchpad.splitterImplementation());
        assertEq(_splitter(second).memestock(), second.newToken);
    }

    function test_graduation_emits_the_record() public {
        Launched memory l = _launch(STOCK_LOW);
        _bidToGraduation(l, 1_000e8);
        vm.recordLogs();
        launchpad.migrate(l.launchId);
        IStocksLaunchpadV2.Launch memory record = _record(l);
        bytes32 topic = keccak256(
            "StockLaunchGraduated(uint256,address,bytes32,uint160,uint256,uint128,uint128,uint256,uint256,uint256,uint256)"
        );
        bool found;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(launchpad) && logs[i].topics[0] == topic) {
                found = true;
                assertEq(uint256(logs[i].topics[1]), l.launchId);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(l.auction));
                (
                    bytes32 poolId,
                    uint160 sqrtPriceX96,
                    uint256 lpTokenId,
                    uint128 lpStockUsed,
                    uint128 lpNewUsed,
                    uint256 stockRaised,
                    uint256 stockDust,
                    uint256 newSold,
                    uint256 newShared
                ) = abi.decode(
                    logs[i].data, (bytes32, uint160, uint256, uint128, uint128, uint256, uint256, uint256, uint256)
                );
                assertEq(poolId, record.poolId);
                assertEq(sqrtPriceX96, record.finalSqrtPriceX96);
                assertEq(lpTokenId, record.lpTokenId);
                assertEq(lpStockUsed, record.lpStockUsed);
                assertEq(lpNewUsed, record.lpNewUsed);
                assertEq(stockRaised, l.auction.lbpInitializationParams().currencyRaised);
                assertEq(uint256(lpStockUsed) + stockDust, stockRaised);
                assertEq(newSold, record.newSold);
                assertEq(newShared, record.newShared);
            }
        }
        assertTrue(found, "StockLaunchGraduated emitted");
    }

    // -------------------------------------------------------------------------
    // failure
    // -------------------------------------------------------------------------

    function test_failed_minimum_retires_inventory_and_reserve_and_refunds_through_the_cca() public {
        Launched memory l = _launch(STOCK_LOW);
        _rollToStart(l);
        uint128 bidAmount = REQUIRED_RAISE - 1; // one base unit below the required raise
        uint256 bidId = _bidDirect(l, bidder, bidAmount, _bidPrice(1));
        assertEq(FixtureStockToken(l.stock).balanceOf(bidder), 0);
        assertEq(FixtureStockToken(l.stock).balanceOf(address(l.auction)), bidAmount);
        _rollToMigration(l);

        uint256 deadBefore = UERC20(l.newToken).balanceOf(StocksBindings.DEAD_ADDRESS);
        vm.expectEmit(true, true, false, true, address(launchpad));
        emit IStocksLaunchpadV2.StockLaunchRetired(l.launchId, address(l.auction), StocksPreset.INITIAL_SUPPLY);
        launchpad.migrate(l.launchId);

        IStocksLaunchpadV2.Launch memory record = _record(l);
        assertEq(uint8(record.lifecycle), uint8(IStocksLaunchpadV2.Lifecycle.Failed));
        assertEq(record.retiredNew, StocksPreset.INITIAL_SUPPLY, "inventory + reserve retired");
        assertEq(UERC20(l.newToken).balanceOf(StocksBindings.DEAD_ADDRESS) - deadBefore, StocksPreset.INITIAL_SUPPLY);
        assertEq(UERC20(l.newToken).balanceOf(address(launchpad)), 0);
        assertEq(UERC20(l.newToken).balanceOf(address(l.auction)), 0);
        assertEq(record.poolId, bytes32(0), "no pool");
        assertEq(record.lpTokenId, 0, "no position");
        assertEq(record.newSold, 0);
        assertEq(record.newShared, 0);

        // Bidder STOCK never moved through this component; the CCA refunds it in full.
        assertEq(FixtureStockToken(l.stock).balanceOf(address(launchpad)), 0);
        assertEq(FixtureStockToken(l.stock).balanceOf(address(l.auction)), bidAmount, "still in the auction");
        vm.prank(bidder);
        l.auction.exitBid(bidId);
        assertEq(FixtureStockToken(l.stock).balanceOf(bidder), bidAmount, "full refund");
        assertEq(FixtureStockToken(l.stock).balanceOf(address(l.auction)), 0);
    }

    function test_launch_nobody_bid_in_never_graduates() public {
        Launched memory l = _launch(STOCK_HIGH);
        _rollToMigration(l);
        launchpad.migrate(l.launchId);
        assertEq(uint8(_record(l).lifecycle), uint8(IStocksLaunchpadV2.Lifecycle.Failed));
        assertEq(UERC20(l.newToken).balanceOf(StocksBindings.DEAD_ADDRESS), StocksPreset.INITIAL_SUPPLY);
    }

    // -------------------------------------------------------------------------
    // guards
    // -------------------------------------------------------------------------

    function test_migrate_guards() public {
        Launched memory l = _launch(STOCK_LOW);

        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV2.UnknownLaunch.selector, 42));
        launchpad.migrate(42);

        _rollToStart(l);
        _bidDirect(l, bidder, 1_000e8, _bidPrice(GRADUATING_TICKS));
        vm.roll(l.auction.endBlock() + StocksPreset.MIGRATION_DELAY_BLOCKS - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                StocksLaunchpadV2.MigrationNotYetAllowed.selector,
                l.auction.endBlock() + StocksPreset.MIGRATION_DELAY_BLOCKS,
                block.number
            )
        );
        launchpad.migrate(l.launchId);

        vm.roll(block.number + 1);
        vm.prank(outsider); // anyone may drive migration
        launchpad.migrate(l.launchId);

        vm.expectRevert(
            abi.encodeWithSelector(StocksLaunchpadV2.LaunchNotActive.selector, IStocksLaunchpadV2.Lifecycle.Graduated)
        );
        launchpad.migrate(l.launchId);
    }

    function test_nobody_can_initialize_the_official_pool_before_migration() public {
        Launched memory l = _launch(STOCK_LOW);
        PoolKey memory key = _poolKey(l);
        vm.expectRevert();
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        vm.expectRevert();
        vm.prank(address(launchpad));
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    function test_no_principal_path_exists_for_the_locked_position() public {
        Launched memory l = _launch(STOCK_LOW);
        _graduate(l, 1_000e8);
        uint256 tokenId = _record(l).lpTokenId;

        address[3] memory callers = [address(launchpad), governance, outsider];
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(1), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(_poolKey(l).currency0, _poolKey(l).currency1, address(this));
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert();
            vm.prank(callers[i]);
            positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        }
    }

    function test_launchpad_never_exposes_a_token_or_stock_withdrawal() public {
        // The launchpad's whole external surface is the interface; there is no transfer, sweep, rescue
        // or approve of NEW or STOCK. The NEW it holds after graduation leaves only through the
        // share-out, to the bids' owners.
        Launched memory l = _launch(STOCK_LOW);
        assertEq(UERC20(l.newToken).balanceOf(address(launchpad)), StocksPreset.MIGRATION_RESERVE);
        uint256 bidId = _graduate(l, 1_000e8);
        assertEq(UERC20(l.newToken).balanceOf(address(launchpad)), _record(l).newShared);
        assertEq(FixtureStockToken(l.stock).balanceOf(address(launchpad)), 0);
        (, uint256 share,) = launchpad.unsoldShareOf(l.launchId, bidId, 0, 0);
        launchpad.claimUnsoldShare(l.launchId, bidId, 0, 0);
        assertEq(UERC20(l.newToken).balanceOf(address(launchpad)), _record(l).newShared - share);
    }
}
