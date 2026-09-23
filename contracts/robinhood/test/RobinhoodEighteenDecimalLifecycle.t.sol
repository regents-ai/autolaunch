// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";
import {MockChainlinkFeed} from "autolaunch-stocks-test/mocks/MockChainlinkFeed.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {IRobinhoodLaunchpadBase} from "../src/interfaces/IRobinhoodLaunchpadBase.sol";
import {IRobinhoodStocksLaunchpadV1} from "../src/interfaces/IRobinhoodStocksLaunchpadV1.sol";
import {RobinhoodMemestockSplitterV1} from "../src/RobinhoodMemestockSplitterV1.sol";
import {UniswapV3StockRouteV1} from "../src/routes/UniswapV3StockRouteV1.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {RobinhoodFixture} from "./RobinhoodFixture.sol";

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice The whole Robinhood launch life cycle with an 18-decimal STOCK (every real Robinhood
///         stock has 18) and the production route in both caller paths: launch, an auction bid
///         through the bid adapter and the route, graduation (pool creation, the positions library,
///         both positions in the locker), official-pool swaps accruing both fee lanes, the protocol
///         lane settled through the route into the inbox, the staker lane settled into the
///         splitter, the locker's `collect`, and the staker's claims. Once with the STOCK sorting
///         below USDG and NEW (the stock is `token0` of its v3 pool) and once above both.
contract RobinhoodEighteenDecimalLifecycleTest is RobinhoodFixture {
    using StateLibrary for IPoolManager;

    /// @dev 230 dollars per share in eight feed decimals, the fixture's `USDG_PER_SHARE`.
    int256 internal constant FEED_ANSWER = 23_000_000_000;

    /// @dev 115,000 USDG buys exactly 500 shares at the feed price.
    uint256 internal constant BID_USDG = 115_000e6;
    uint128 internal constant BID_STOCK = 500e18;

    /// @dev Ten shares traded on the official pool; each lane takes one percent.
    uint256 internal constant TRADE_STOCK = 10e18;
    uint256 internal constant LANE = TRADE_STOCK / StocksPreset.LANE_DIVISOR;

    function setUp() public {
        _deployRobinhood();
    }

    function test_lifecycle_with_the_stock_sorting_first() public {
        _lifecycle(STOCK_LOW);
    }

    function test_lifecycle_with_usdg_sorting_first() public {
        _lifecycle(STOCK_HIGH);
    }

    function _lifecycle(address stockAddress) private {
        MockERC20 stock = MockERC20(stockAddress);
        assertEq(stock.decimals(), 18, "an 18-decimal stock");
        UniswapV3StockRouteV1 route = _admitProductionRoute(stockAddress);

        // --- launch: the launcher asks for a thousand dollars of STOCK, in 18-decimal base units ---
        Launched memory l = _launchStock(stockAddress);
        assertEq(stocks.launches(l.launchId).requiredRaise, STOCK_REQUIRED_RAISE);
        assertEq(STOCK_REQUIRED_RAISE, 4_347_826_086_956_521_739, "1,000 USDG at 230 per share");

        // --- bid: USDG in through the adapter, STOCK out of the route, the bid owned by the bidder ---
        _rollToStart(l);
        usdg.mint(bidder, BID_USDG);
        vm.startPrank(bidder);
        usdg.approve(address(adapter), BID_USDG);
        (uint256 bidId, uint128 committed) = adapter.bidWithUsdg(
            address(l.auction), BID_USDG, BID_STOCK, _bidPrice(10), FLOOR_PRICE_Q96, block.timestamp
        );
        vm.stopPrank();
        assertEq(committed, BID_STOCK, "500 shares committed");
        assertEq(stock.balanceOf(address(l.auction)), BID_STOCK, "the auction holds the STOCK");
        assertEq(usdg.balanceOf(bidder), 0);
        _assertEmpty(route, stock);
        assertEq(usdg.balanceOf(address(adapter)) + stock.balanceOf(address(adapter)), 0, "adapter empty");

        // --- graduation: pool creation, the positions library, both positions locked ---
        _rollToMigration(l);
        uint256 nextTokenId = positionManager.nextTokenId();
        stocks.migrate(l.launchId);
        IRobinhoodLaunchpadBase.Launch memory record = stocks.launches(l.launchId);
        assertEq(uint8(record.lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Graduated), "graduated");
        IRobinhoodStocksLaunchpadV1.StockRecord memory stockRecord = stocks.stockRecords(l.launchId);
        assertEq(record.lpTokenId, nextTokenId, "full range position");
        assertEq(stockRecord.stockOnlyTokenId, nextTokenId + 1, "one-sided STOCK position");
        assertEq(IERC721Owner(address(positionManager)).ownerOf(nextTokenId), address(locker));
        assertEq(IERC721Owner(address(positionManager)).ownerOf(nextTokenId + 1), address(locker));
        assertGt(positionManager.getPositionLiquidity(nextTokenId), 0, "full range liquidity");
        assertGt(positionManager.getPositionLiquidity(nextTokenId + 1), 0, "one-sided liquidity");
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(PoolId.wrap(record.poolId));
        assertEq(sqrtPriceX96, record.finalSqrtPriceX96, "pool initialized at the graduation price");
        assertEq(record.poolId, _poolId(l, address(stocksHook)));
        (uint256 dust,) = stocksHook.accrued(record.poolId);
        assertEq(record.lpCurrencyUsed + dust, BID_STOCK, "every raised STOCK unit is in the pool or the lane");
        assertEq(stock.balanceOf(address(stocks)), 0, "the launchpad keeps no STOCK");
        assertEq(MockERC20(l.newToken).balanceOf(address(stocks)), 0, "the launchpad keeps no NEW");

        // --- the bidder claims its NEW and stakes the lot ---
        uint256 staked = _claimNewTo(l, bidId, staker);
        assertGt(staked, 0);
        RobinhoodMemestockSplitterV1 splitter = _splitter(l);
        vm.startPrank(staker);
        MockERC20(l.newToken).approve(address(splitter), staked);
        splitter.stake(staked);
        vm.stopPrank();

        // --- official-pool swaps: ten shares in, both lanes accrue one percent each ---
        _fundTrader(l, TRADE_STOCK);
        _swapCurrencyIn(l, address(stocksHook), TRADE_STOCK);
        (uint256 protocolLane, uint256 stakerLane) = stocksHook.accrued(record.poolId);
        assertEq(protocolLane, dust + LANE, "protocol lane");
        assertEq(stakerLane, LANE, "staker lane");
        _swapNewIn(l, address(stocksHook), MockERC20(l.newToken).balanceOf(trader) / 2);
        (uint256 protocolAfterRoundTrip,) = stocksHook.accrued(record.poolId);
        assertGt(protocolAfterRoundTrip, protocolLane, "the NEW leg accrues in STOCK too");

        // --- protocol lane: STOCK through the production route into the inbox in USDG ---
        uint256 expectedUsdg = LANE * USDG_PER_SHARE / 1e18;
        assertEq(expectedUsdg, 23e6, "a tenth of a share is 23 USDG");
        uint256 inboxBefore = inbox.totalCollected();
        vm.prank(executor);
        stocksHook.settleProtocolLane(record.poolId, LANE, expectedUsdg);
        assertEq(inbox.totalCollected(), inboxBefore + expectedUsdg, "the inbox received 23 USDG");
        (uint256 stockConverted, uint256 usdgDeposited,) = stocksHook.settled(record.poolId);
        assertEq(stockConverted, LANE);
        assertEq(usdgDeposited, expectedUsdg);
        _assertEmpty(route, stock);
        assertEq(usdg.balanceOf(address(stocksHook)), 0, "the hook keeps no USDG");

        // --- staker lane: STOCK into the splitter, 2% to the Safe, the rest to the staker ---
        uint256 safeStockBefore = stock.balanceOf(safe);
        vm.prank(outsider);
        uint256 deposited = stocksHook.settleStakerLane(record.poolId);
        assertGt(deposited, LANE, "both swaps fed the staker lane");
        uint256 protocolShare = deposited * 200 / 10_000;
        assertEq(stock.balanceOf(safe), safeStockBefore + protocolShare);
        assertApproxEqAbs(splitter.claimable(stockAddress, staker), deposited - protocolShare, 1);

        // --- locker: LP fees in both currencies through the splitter, positions untouched ---
        uint128 fullLiquidity = positionManager.getPositionLiquidity(record.lpTokenId);
        vm.startPrank(outsider);
        (uint256 full0, uint256 full1) = locker.collect(record.lpTokenId);
        (uint256 side0, uint256 side1) = locker.collect(stockRecord.stockOnlyTokenId);
        vm.stopPrank();
        bool stockIs0 = stockAddress < l.newToken;
        uint256 stockFees = stockIs0 ? full0 + side0 : full1 + side1;
        uint256 newFees = stockIs0 ? full1 + side1 : full0 + side0;
        assertGt(stockFees, 0, "LP fees in STOCK");
        assertGt(newFees, 0, "LP fees in NEW");
        assertEq(positionManager.getPositionLiquidity(record.lpTokenId), fullLiquidity);
        assertEq(stock.balanceOf(address(locker)) + MockERC20(l.newToken).balanceOf(address(locker)), 0);

        // --- claims: the staker takes every whole unit it is owed ---
        vm.roll(block.number + 1);
        uint256 stockOwed = splitter.claimable(stockAddress, staker);
        uint256 newOwed = splitter.claimable(l.newToken, staker);
        assertGt(stockOwed, 0);
        assertGt(newOwed, 0);
        uint256 stakerStockBefore = stock.balanceOf(staker);
        vm.prank(staker);
        splitter.claimAll();
        assertEq(stock.balanceOf(staker), stakerStockBefore + stockOwed, "STOCK claimed");
        assertEq(MockERC20(l.newToken).balanceOf(staker), newOwed, "NEW claimed");
        assertEq(splitter.claimable(stockAddress, staker), 0);
        assertEq(splitter.claimable(l.newToken, staker), 0);
        // The stake itself is untouched: every unit comes back on unstake.
        vm.prank(staker);
        splitter.unstake(staked);
        assertEq(MockERC20(l.newToken).balanceOf(staker), newOwed + staked, "the whole stake came back");
    }

    /// @dev Replace the fixture route with the production route over a v3 pool double in the
    ///      order the addresses sort, funded to pay both directions at the feed price.
    function _admitProductionRoute(address stockAddress) private returns (UniswapV3StockRouteV1 route) {
        bool stockFirst = stockAddress < USDG_ADDRESS;
        MockUniswapV3Pool pool = stockFirst
            ? new MockUniswapV3Pool(stockAddress, USDG_ADDRESS, USDG_ADDRESS, USDG_PER_SHARE)
            : new MockUniswapV3Pool(USDG_ADDRESS, stockAddress, USDG_ADDRESS, USDG_PER_SHARE);
        MockChainlinkFeed feed = new MockChainlinkFeed(8, FEED_ANSWER, block.timestamp - 1 hours);
        route = new UniswapV3StockRouteV1(USDG_ADDRESS, stockAddress, address(pool), address(feed));
        assertEq(route.stockIsToken0(), stockFirst);
        assertEq(route.stockUnit(), 1e18);
        MockERC20(stockAddress).mint(address(pool), 1_000_000e18);
        usdg.mint(address(pool), 1_000_000_000e6);
        vm.prank(safe);
        stocks.admitStock(stockAddress, address(route));
        (,, address admitted) = stocks.stockAdmission(stockAddress);
        assertEq(admitted, address(route), "the production route is the admitted route");
    }

    function _assertEmpty(UniswapV3StockRouteV1 route, MockERC20 stock) private view {
        assertEq(usdg.balanceOf(address(route)), 0, "usdg left on the route");
        assertEq(stock.balanceOf(address(route)), 0, "stock left on the route");
    }
}
