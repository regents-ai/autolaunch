// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
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
import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {FixtureUsdgStockRoute} from "../src/fixtures/FixtureUsdgStockRoute.sol";
import {IRobinhoodLaunchpadBase} from "../src/interfaces/IRobinhoodLaunchpadBase.sol";
import {IRobinhoodStocksLaunchpadV2} from "../src/interfaces/IRobinhoodStocksLaunchpadV2.sol";
import {RobinhoodFeeHookV1} from "../src/RobinhoodFeeHookV1.sol";
import {RobinhoodLaunchpadBase} from "../src/RobinhoodLaunchpadBase.sol";
import {RobinhoodMemestockSplitterV1} from "../src/RobinhoodMemestockSplitterV1.sol";
import {RobinhoodPreset} from "../src/RobinhoodPreset.sol";
import {RobinhoodFixture} from "./RobinhoodFixture.sol";

/// @notice Graduation and failure, as the Base Stocks launchpad proves them, on the Robinhood graph. A
///         graduated launch has sold its whole sale allocation to its bidders through the auction but
///         for rounding, opens the official pool at the raise divided by the sale allocation, locks the
///         whole reserve with the whole raise in one full-range position held by the fee-only locker,
///         credits the rounding remainder of the raise to the pool's protocol lane and retires the NEW
///         left over. An auction that raised less than the sale allocation at the floor, including one
///         nobody bid in, fails: the inventory is retired and bidders are refunded through the CCA alone.
contract RobinhoodLaunchpadMigrateTest is RobinhoodFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 private constant Q96 = FixedPoint96.Q96;

    function setUp() public {
        _deployRobinhood();
    }

    // -------------------------------------------------------------------------
    // graduation: one bidder
    // -------------------------------------------------------------------------

    function test_sole_bidder_at_the_start_receives_the_whole_sale_allocation_both_orderings() public {
        _soleBidderCase(_launchStock(STOCK_LOW), 1_000e18, _bidPrice(GRADUATING_TICKS), 0);
        _soleBidderCase(_launchStock(STOCK_HIGH), 1_000e18, _bidPrice(GRADUATING_TICKS), 0);
    }

    /// @dev Nobody bids until the last block that still takes bids; every unit released earlier rolls
    ///      into it, so the one late bid still buys the whole sale allocation.
    function test_sole_bidder_in_the_last_eligible_block_receives_the_whole_sale_allocation() public {
        Launched memory low = _launchStock(STOCK_LOW);
        _soleBidderCase(low, 20e18, _bidPrice(GRADUATING_TICKS), low.auction.endBlock() - 1);
        Launched memory high = _launchStock(STOCK_HIGH);
        _soleBidderCase(high, 20e18, _bidPrice(GRADUATING_TICKS), high.auction.endBlock() - 1);
    }

    /// @dev A bid larger than the sale allocation at its own price limit: the clearing price rises to
    ///      the limit and the bid is partly filled there, refunded the rest, and still receives the whole
    ///      sale allocation.
    function test_sole_bidder_partly_filled_at_its_limit_receives_the_whole_sale_allocation() public {
        _soleBidderCase(_launchStock(STOCK_LOW), 100e18, _bidPrice(10), 0);
        _soleBidderCase(_launchStock(STOCK_HIGH), 100e18, _bidPrice(10), 0);
    }

    function testFuzz_sole_bidder_receives_the_whole_sale_allocation(uint128 amount, uint32 ticks, uint32 lateBy)
        public
    {
        amount = uint128(bound(amount, 2 * REQUIRED_RAISE, 1_000_000e18));
        uint256 priceQ96 = _bidPrice(bound(ticks, 1, 1_000_000));
        Launched memory l = _launchStock(ticks % 2 == 0 ? STOCK_LOW : STOCK_HIGH);
        uint256 bidBlock = l.auction.startBlock() + bound(lateBy, 0, RobinhoodPreset.AUCTION_DURATION_BLOCKS - 1);
        _soleBidderCase(l, amount, priceQ96, bidBlock);
    }

    /// @param bidBlock The block the bid is placed in; zero for the auction's first block.
    function _soleBidderCase(Launched memory l, uint128 amount, uint256 priceQ96, uint256 bidBlock) private {
        vm.roll(bidBlock == 0 ? l.auction.startBlock() : bidBlock);
        uint256 bidId = _bidDirect(l, bidder, amount, priceQ96);
        _rollToMigration(l);
        _migrateAndAssertGraduation(l, amount);

        uint256 filled = _settle(l, bidId);
        assertEq(filled, UERC20(l.newToken).balanceOf(bidder), "the bidder holds what it was paid");
        _assertWholeAllocationSold(l, filled);
    }

    // -------------------------------------------------------------------------
    // graduation: several bidders
    // -------------------------------------------------------------------------

    /// @dev Three bids exercise every way a bid ends: `early` at 1.2 times the floor is outbid when
    ///      `anchor` arrives, `anchor` sets the final clearing price and is partly filled at it, and
    ///      `late` is priced above it and filled in every block. Each exits and claims at the auction,
    ///      and between them they receive the whole sale allocation but for crumbs.
    function test_several_bidders_each_way_a_bid_ends_receive_the_whole_sale_allocation_both_orderings() public {
        _severalBiddersCase(STOCK_LOW);
        _severalBiddersCase(STOCK_HIGH);
    }

    function _severalBiddersCase(address stock) private {
        Launched memory l = _launchStock(stock);
        address early = makeAddr("early");
        address anchor = makeAddr("anchor");
        address late = makeAddr("late");
        uint256 anchorPrice = _bidPrice(1_000);

        _rollToStart(l);
        uint256 earlyBid = _bidDirect(l, early, 3e18, _bidPrice(20));
        vm.roll(l.auction.startBlock() + 1_000);
        uint256 anchorBid = _bidDirect(l, anchor, 100e18, anchorPrice);
        vm.roll(l.auction.startBlock() + 2_000);
        uint256 lateBid = _bidDirect(l, late, 10e18, _bidPrice(GRADUATING_TICKS));
        _rollToMigration(l);
        _migrateAndAssertGraduation(l, 113e18);

        Checkpoint memory finalCheckpoint = l.auction.checkpoints(l.auction.endBlock());
        assertEq(finalCheckpoint.clearingPrice, anchorPrice, "the anchor bid sets the final price");
        (, uint64 earlyOutbid) = _hints(l.auction, earlyBid);
        assertNotEq(earlyOutbid, 0, "the early bid was outbid");
        (, uint64 anchorOutbid) = _hints(l.auction, anchorBid);
        assertEq(anchorOutbid, 0, "the anchor bid was never outbid");

        uint256 earlyFilled = _settle(l, earlyBid);
        uint256 anchorFilled = _settle(l, anchorBid);
        uint256 lateFilled = _settle(l, lateBid);
        assertGt(earlyFilled, 0, "the early bid bought before it was outbid");
        assertGt(anchorFilled, lateFilled, "the anchor bid bought the most");
        _assertWholeAllocationSold(l, earlyFilled + anchorFilled + lateFilled);
    }

    // -------------------------------------------------------------------------
    // leftover NEW
    // -------------------------------------------------------------------------

    /// @dev The auction pays bids from the claim block, before migration can run, so NEW can already
    ///      be sent to the launchpad when it graduates. Graduation retires every unit of the launch's
    ///      NEW it still holds, so NEW sent beforehand is retired with the crumbs.
    function test_new_sent_to_the_launchpad_before_migration_is_retired() public {
        Launched memory l = _launchStock(STOCK_LOW);
        _rollToStart(l);
        uint256 bidId = _bidDirect(l, bidder, 50e18, _bidPrice(GRADUATING_TICKS));
        vm.roll(l.auction.claimBlock());
        uint256 claimed = _claimNewTo(l, bidId, address(stocks));
        assertGe(claimed, StocksPreset.AUCTION_INVENTORY - _newCrumbs(l), "the bid bought the sale allocation");
        _rollToMigration(l);
        stocks.migrate(l.launchId);

        IRobinhoodLaunchpadBase.Launch memory record = _record(l);
        assertEq(uint8(record.lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Graduated));
        assertGe(record.retiredNew, claimed, "the NEW sent here is retired");
        assertLe(record.retiredNew - claimed, _newCrumbs(l), "on top of crumbs");
        assertEq(UERC20(l.newToken).balanceOf(DEAD), record.retiredNew, "at the dead address");
        assertEq(UERC20(l.newToken).balanceOf(address(stocks)), 0, "the launchpad keeps no NEW");
        assertEq(
            UERC20(l.newToken).balanceOf(address(l.auction)) + record.lpNewUsed + record.retiredNew,
            StocksPreset.INITIAL_SUPPLY,
            "the supply reconciles"
        );
    }

    // -------------------------------------------------------------------------
    // the minimum raise
    // -------------------------------------------------------------------------

    /// @dev Placed in the auction's first block, a bid of exactly the minimum is counted in full.
    function test_minimum_met_exactly_graduates_and_one_unit_below_fails() public {
        Launched memory met = _launchStock(STOCK_LOW);
        _rollToStart(met);
        _bidDirect(met, bidder, REQUIRED_RAISE, _bidPrice(GRADUATING_TICKS));
        Launched memory below = _launchStock(STOCK_HIGH);
        _rollToStart(below);
        _bidDirect(below, bidder, REQUIRED_RAISE - 1, _bidPrice(GRADUATING_TICKS));

        _rollToMigration(below);
        stocks.migrate(met.launchId);
        stocks.migrate(below.launchId);
        assertEq(uint8(_record(met).lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Graduated), "exactly met");
        assertEq(uint8(_record(below).lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Failed), "one unit short");
    }

    /// @dev The pinned auction rounds what it counts of a bid placed after its first block down by up
    ///      to one base unit, so there the minimum plus one base unit is what graduates, in any block.
    function testFuzz_minimum_plus_one_unit_graduates_in_any_block(uint32 lateBy) public {
        Launched memory l = _launchStock(STOCK_LOW);
        vm.roll(l.auction.startBlock() + bound(lateBy, 0, RobinhoodPreset.AUCTION_DURATION_BLOCKS - 1));
        uint256 bidId = _bidDirect(l, bidder, REQUIRED_RAISE + 1, _bidPrice(GRADUATING_TICKS));
        _rollToMigration(l);
        stocks.migrate(l.launchId);
        assertEq(uint8(_record(l).lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Graduated));
        _assertWholeAllocationSold(l, _settle(l, bidId));
    }

    function test_minimum_bid_after_the_first_block_is_counted_one_unit_short_and_fails() public {
        Launched memory l = _launchStock(STOCK_LOW);
        vm.roll(l.auction.startBlock() + 1);
        _bidDirect(l, bidder, REQUIRED_RAISE, _bidPrice(GRADUATING_TICKS));
        _rollToMigration(l);
        l.auction.checkpoint();
        assertEq(l.auction.currencyRaised(), REQUIRED_RAISE - 1, "the auction's own rounding");
        stocks.migrate(l.launchId);
        assertEq(uint8(_record(l).lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Failed));
    }

    // -------------------------------------------------------------------------
    // other currency decimals
    // -------------------------------------------------------------------------

    /// @dev Every Robinhood stock has 18 decimals and the fixture uses them throughout; admission reads
    ///      the decimals rather than assuming them, so an eight-decimal STOCK must obey the same rules:
    ///      at a floor of 1e-8 of it per NEW, a minimum of five whole units.
    function test_eight_decimal_stock_graduates_and_sells_the_whole_sale_allocation() public {
        MockERC20 stock8 = new MockERC20("Eight", "EIGHT", 8);
        FixtureUsdgStockRoute route = new FixtureUsdgStockRoute(address(stock8), USDG_ADDRESS, USDG_PER_SHARE);
        vm.prank(safe);
        stocks.admitStock(address(stock8), address(route));
        (, uint8 decimals,) = stocks.stockAdmission(address(stock8));
        assertEq(decimals, 8);

        IRobinhoodStocksLaunchpadV2.LaunchParams memory params = _stockParams(address(stock8));
        params.core.floorPriceQ96 = 79_228_162_500;
        uint256 required = stocks.requiredStockRaisedFor(params.core.floorPriceQ96);
        assertEq(required, 5e8, "five whole units");

        Launched memory short = _launchStockAs(launcher, params);
        Launched memory l = _launchStockAs(launcher, params);
        uint256 limit = params.core.floorPriceQ96 * 1_001;
        _rollToStart(l);
        _bidAt(short, uint128(required - 1), limit, params.core.floorPriceQ96);
        uint256 bidId = _bidAt(l, uint128(required * 3), limit, params.core.floorPriceQ96);
        _rollToMigration(l);
        stocks.migrate(short.launchId);
        assertEq(uint8(_record(short).lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Failed), "one unit short");
        _migrateAndAssertGraduation(l, required * 3);

        _assertWholeAllocationSold(l, _settle(l, bidId));
    }

    /// @dev `_bidDirect` for a launch at its own floor, which is the bid's tick hint.
    function _bidAt(Launched memory l, uint128 amount, uint256 priceQ96, uint256 floorPriceQ96)
        private
        returns (uint256 bidId)
    {
        MockERC20(l.currency).mint(bidder, amount);
        vm.startPrank(bidder);
        MockERC20(l.currency).approve(PERMIT2, amount);
        IAllowanceTransfer(PERMIT2).approve(l.currency, address(l.auction), uint160(amount), type(uint48).max);
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
        uint256 pmStockBefore = MockERC20(l.currency).balanceOf(address(positionManager));
        uint256 pmNewBefore = UERC20(l.newToken).balanceOf(address(positionManager));
        uint256 ccaNewBefore = UERC20(l.newToken).balanceOf(address(cca));
        assertEq(UERC20(l.newToken).balanceOf(address(stocks)), StocksPreset.MIGRATION_RESERVE, "only the reserve");
        uint256 nextTokenId = positionManager.nextTokenId();
        bytes32 poolId = _poolId(l, address(stocksHook));

        stocks.migrate(l.launchId);

        IRobinhoodLaunchpadBase.Launch memory record = _record(l);
        assertEq(uint8(record.lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Graduated));
        assertEq(record.poolId, poolId);
        assertGe(lbp.currencyRaised, record.requiredRaise, "the minimum was met");

        // The pool opens at the raise divided by the whole sale allocation, never above the auction's
        // final clearing price.
        bool stockIsCurrency0 = l.currency < l.newToken;
        uint256 priceX96 = FullMath.mulDiv(lbp.currencyRaised, Q96, StocksPreset.AUCTION_INVENTORY);
        assertLe(priceX96, lbp.initialPriceX96, "at or below the final clearing price");
        uint160 expectedSqrtPrice =
            TokenPricing.convertToSqrtPriceX96(TokenPricing.convertToPriceX192(priceX96, stockIsCurrency0));
        assertEq(record.finalSqrtPriceX96, expectedSqrtPrice);
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(PoolId.wrap(poolId));
        assertEq(sqrtPriceX96, expectedSqrtPrice, "pool at raise / sale allocation");
        assertGt(IPoolManager(address(poolManager)).getLiquidity(PoolId.wrap(poolId)), 0, "live liquidity");

        _assertLockedPosition(record, nextTokenId, _newCrumbs(l));
        assertEq(positionManager.nextTokenId(), nextTokenId + 1, "exactly one position minted");
        assertEq(
            MockERC20(l.currency).balanceOf(address(positionManager)), pmStockBefore, "PositionManager STOCK unchanged"
        );
        assertEq(UERC20(l.newToken).balanceOf(address(positionManager)), pmNewBefore, "PositionManager NEW unchanged");

        // STOCK: the whole raise is paired but for rounding, which goes to the hook's protocol lane.
        (uint256 dust, uint256 stakerLane) = stocksHook.accrued(poolId);
        assertEq(stakerLane, 0, "the staker lane starts empty");
        assertEq(uint256(record.lpCurrencyUsed) + dust, lbp.currencyRaised, "raised == paired + dust");
        assertLe(dust, lbp.currencyRaised / 1e9 + 2, "the unpaired STOCK is rounding");
        assertEq(MockERC20(l.currency).balanceOf(address(stocksHook)), dust, "hook holds exactly the dust");
        assertEq(MockERC20(l.currency).balanceOf(address(stocks)), 0, "launchpad keeps no STOCK");
        assertEq(
            MockERC20(l.currency).balanceOf(address(cca)),
            totalBid - lbp.currencyRaised,
            "auction keeps only the bidders' refundable remainder"
        );

        // NEW: the auction keeps what it sold for its bids, the pool takes the reserve, and the
        // launchpad retires the rest: the auction's unsold rounding and the reserve the position did
        // not pair. The three reconcile exactly and the launchpad keeps nothing.
        uint256 ccaNewAfter = UERC20(l.newToken).balanceOf(address(cca));
        uint256 swept = ccaNewBefore - ccaNewAfter;
        assertGe(ccaNewAfter, lbp.tokensSold, "the auction keeps the claimable NEW");
        assertEq(record.retiredNew, swept + StocksPreset.MIGRATION_RESERVE - record.lpNewUsed, "what was left over");
        assertEq(
            ccaNewAfter + record.lpNewUsed + record.retiredNew, StocksPreset.INITIAL_SUPPLY, "the supply reconciles"
        );
        assertLe(record.retiredNew, _newCrumbs(l), "only crumbs are retired");
        assertEq(UERC20(l.newToken).balanceOf(DEAD), record.retiredNew, "at the dead address");
        assertEq(UERC20(l.newToken).balanceOf(address(stocks)), 0, "the launchpad keeps no NEW");

        // The hook knows the pool, and the launch has its own fresh splitter.
        RobinhoodFeeHookV1.PoolRecord memory pool = stocksHook.pool(poolId);
        assertEq(pool.stock, l.currency);
        assertEq(pool.newToken, l.newToken);
        assertEq(pool.splitter, record.splitter);
        RobinhoodMemestockSplitterV1 created = RobinhoodMemestockSplitterV1(record.splitter);
        assertGt(record.splitter.code.length, 0, "splitter deployed");
        assertEq(created.memestock(), l.newToken);
        assertEq(created.stock(), l.currency);
        assertEq(created.dollar(), USDG_ADDRESS);
        assertEq(created.totalStaked(), 0);
        vm.expectRevert();
        created.initialize(l.newToken, l.currency);
    }

    /// @dev The one locked position: full range, in the official pool, owned by and registered in the
    ///      locker.
    function _assertLockedPosition(IRobinhoodLaunchpadBase.Launch memory record, uint256 nextTokenId, uint256 crumbs)
        private
        view
    {
        assertEq(record.lpTokenId, nextTokenId, "the position is this graduation's mint");
        assertEq(IERC721(address(positionManager)).ownerOf(record.lpTokenId), address(locker), "owned by the locker");
        assertEq(locker.splitterOf(record.lpTokenId), record.splitter, "registered with the launch's splitter");
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(record.lpTokenId);
        assertEq(PoolId.unwrap(key.toId()), record.poolId);
        assertEq(info.tickLower(), TickMath.minUsableTick(StocksPreset.POOL_TICK_SPACING));
        assertEq(info.tickUpper(), TickMath.maxUsableTick(StocksPreset.POOL_TICK_SPACING));
        assertGt(positionManager.getPositionLiquidity(record.lpTokenId), 0);
        assertApproxEqAbs(record.lpNewUsed, StocksPreset.MIGRATION_RESERVE, crumbs, "the whole reserve is paired");
    }

    /// @dev Exit one bid at the auction and claim its NEW. Returns the NEW the auction paid it.
    function _settle(Launched memory l, uint256 bidId) private returns (uint256 filled) {
        Bid memory bid = l.auction.bids(bidId);
        uint256 startBalance = UERC20(l.newToken).balanceOf(bid.owner);
        if (bid.maxPrice > l.auction.checkpoints(l.auction.endBlock()).clearingPrice) {
            l.auction.exitBid(bidId);
        } else {
            (uint64 lastFullyFilled, uint64 outbid) = _hints(l.auction, bidId);
            l.auction.exitPartiallyFilledBid(bidId, lastFullyFilled, outbid);
        }
        filled = l.auction.bids(bidId).tokensFilled;
        l.auction.claimTokens(bidId);
        assertEq(UERC20(l.newToken).balanceOf(bid.owner) - startBalance, filled, "paid what the bid won");
    }

    /// @dev Once every bid has exited and claimed: the bids received the whole sale allocation but for
    ///      crumbs, and the auction, the pool, the dead address and the bids hold the whole supply.
    function _assertWholeAllocationSold(Launched memory l, uint256 received) private view {
        IRobinhoodLaunchpadBase.Launch memory record = _record(l);
        assertLe(received, StocksPreset.AUCTION_INVENTORY, "never more than the sale allocation");
        assertGe(received, StocksPreset.AUCTION_INVENTORY - _newCrumbs(l), "the whole sale allocation, but for crumbs");
        assertLe(record.retiredNew, _newCrumbs(l), "only crumbs are retired");
        assertEq(
            received + UERC20(l.newToken).balanceOf(address(l.auction)) + record.lpNewUsed + record.retiredNew,
            StocksPreset.INITIAL_SUPPLY,
            "the supply reconciles"
        );
    }

    /// @dev The crumbs a graduation may leave, in NEW base units: both how far short of the sale
    ///      allocation the bids' claims may fall and how much NEW graduation may retire. Both come from
    ///      prices kept to one Q96 unit and never below the floor: the auction's clearing price sets how
    ///      much NEW the bids' STOCK buys, leaving the unsold rounding, and the pool price sets how much
    ///      of the reserve the position pairs. So the supply divided by the floor price in Q96 bounds
    ///      them together: about 1.26e6 base units at the fixture's floor, where the largest observed is about
    ///      2.7e5.
    function _newCrumbs(Launched memory l) private view returns (uint256) {
        return StocksPreset.INITIAL_SUPPLY / l.auction.floorPrice();
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

    function test_graduation_emits_the_record() public {
        Launched memory l = _launchStock(STOCK_LOW);
        _bidToMigration(l, 1_000e18);
        vm.recordLogs();
        stocks.migrate(l.launchId);
        IRobinhoodLaunchpadBase.Launch memory record = _record(l);
        bytes32 topic = keccak256(
            "StockLaunchGraduated(uint256,address,bytes32,uint160,uint256,uint128,uint128,uint256,uint256,uint256)"
        );
        bool found;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(stocks) && logs[i].topics[0] == topic) {
                found = true;
                assertEq(uint256(logs[i].topics[1]), l.launchId);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(l.auction));
                assertEq(logs[i].topics[3], record.poolId, "the pool id is indexed");
                (
                    uint160 sqrtPriceX96,
                    uint256 lpTokenId,
                    uint128 lpStockUsed,
                    uint128 lpNewUsed,
                    uint256 stockRaised,
                    uint256 stockDust,
                    uint256 newRetired
                ) = abi.decode(logs[i].data, (uint160, uint256, uint128, uint128, uint256, uint256, uint256));
                assertEq(sqrtPriceX96, record.finalSqrtPriceX96);
                assertEq(lpTokenId, record.lpTokenId);
                assertEq(lpStockUsed, record.lpCurrencyUsed);
                assertEq(lpNewUsed, record.lpNewUsed);
                assertEq(stockRaised, l.auction.lbpInitializationParams().currencyRaised);
                assertEq(uint256(lpStockUsed) + stockDust, stockRaised);
                assertEq(newRetired, record.retiredNew);
            }
        }
        assertTrue(found, "StockLaunchGraduated emitted");
    }

    // -------------------------------------------------------------------------
    // failure
    // -------------------------------------------------------------------------

    function test_failed_minimum_retires_inventory_and_reserve_and_refunds_through_the_cca() public {
        Launched memory l = _launchStock(STOCK_LOW);
        _rollToStart(l);
        uint128 bidAmount = REQUIRED_RAISE - 1; // one base unit below the required raise
        uint256 bidId = _bidDirect(l, bidder, bidAmount, _bidPrice(1));
        assertEq(stockLow.balanceOf(bidder), 0);
        assertEq(stockLow.balanceOf(address(l.auction)), bidAmount);
        _rollToMigration(l);

        uint256 deadBefore = UERC20(l.newToken).balanceOf(DEAD);
        vm.expectEmit(true, true, false, true, address(stocks));
        emit IRobinhoodLaunchpadBase.LaunchRetired(l.launchId, address(l.auction), StocksPreset.INITIAL_SUPPLY);
        stocks.migrate(l.launchId);

        IRobinhoodLaunchpadBase.Launch memory record = _record(l);
        assertEq(uint8(record.lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Failed));
        assertEq(record.retiredNew, StocksPreset.INITIAL_SUPPLY, "inventory + reserve retired");
        assertEq(UERC20(l.newToken).balanceOf(DEAD) - deadBefore, StocksPreset.INITIAL_SUPPLY);
        assertEq(UERC20(l.newToken).balanceOf(address(stocks)), 0);
        assertEq(UERC20(l.newToken).balanceOf(address(l.auction)), 0);
        assertEq(record.poolId, bytes32(0), "no pool");
        assertEq(record.lpTokenId, 0, "no position");

        // Bidder STOCK never moved through this component; the CCA refunds it in full.
        assertEq(stockLow.balanceOf(address(stocks)), 0);
        assertEq(stockLow.balanceOf(address(l.auction)), bidAmount, "still in the auction");
        vm.prank(bidder);
        l.auction.exitBid(bidId);
        assertEq(stockLow.balanceOf(bidder), bidAmount, "full refund");
        assertEq(stockLow.balanceOf(address(l.auction)), 0);
    }

    function test_launch_nobody_bid_in_never_graduates() public {
        Launched memory l = _launchStock(STOCK_HIGH);
        _rollToMigration(l);
        stocks.migrate(l.launchId);
        assertEq(uint8(_record(l).lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Failed));
        assertEq(UERC20(l.newToken).balanceOf(DEAD), StocksPreset.INITIAL_SUPPLY);
    }

    // -------------------------------------------------------------------------
    // guards
    // -------------------------------------------------------------------------

    function test_no_principal_path_exists_for_the_locked_position() public {
        Launched memory l = _launchStock(STOCK_LOW);
        _graduateStock(l);
        uint256 tokenId = _record(l).lpTokenId;
        PoolKey memory key = _poolKey(l, address(stocksHook));

        address[3] memory callers = [address(stocks), safe, outsider];
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(1), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert();
            vm.prank(callers[i]);
            positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        }
    }

    function test_launchpad_never_exposes_a_token_or_stock_withdrawal() public {
        // The launchpad's whole external surface is the interface; there is no transfer, sweep, rescue
        // or approve of NEW or STOCK. Graduation leaves it holding neither.
        Launched memory l = _launchStock(STOCK_LOW);
        assertEq(UERC20(l.newToken).balanceOf(address(stocks)), StocksPreset.MIGRATION_RESERVE);
        _bidToMigration(l, 1_000e18);
        stocks.migrate(l.launchId);
        assertEq(UERC20(l.newToken).balanceOf(address(stocks)), 0);
        assertEq(stockLow.balanceOf(address(stocks)), 0);
    }
}
