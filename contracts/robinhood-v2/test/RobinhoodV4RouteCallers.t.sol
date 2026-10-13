// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockChainlinkFeed} from "autolaunch-stocks-test/mocks/MockChainlinkFeed.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {IRobinhoodLaunchpadBase} from "../src/interfaces/IRobinhoodLaunchpadBase.sol";
import {UniswapV4StockRouteV1} from "../src/routes/UniswapV4StockRouteV1.sol";
import {RobinhoodFixture} from "./RobinhoodFixture.sol";

/// @notice The v4 route through its two real callers, on the same pool manager the fee hook's own
///         pools live on: an auction bid through the bid adapter, and the protocol lane settled by
///         the hook into the inbox. The route opens the pool manager's lock itself, so both callers
///         must reach it outside any v4 operation; a change that called either from inside one would
///         fail here. Once with the stock sorting below USDG and once above.
contract RobinhoodV4RouteCallersTest is RobinhoodFixture {
    /// @dev 230 dollars per share in eight feed decimals, the fixture's `USDG_PER_SHARE`.
    int256 internal constant FEED_ANSWER = 23_000_000_000;

    /// @dev A 1% pool with about ten million dollars a side across the whole range.
    uint24 internal constant FEE = 10_000;
    int24 internal constant TICK_SPACING = 200;
    int256 internal constant LIQUIDITY = 6.6e17;

    uint256 internal constant BID_USDG = 115_000e6;

    /// @dev Ten shares traded on the official pool; the protocol lane takes one percent.
    uint256 internal constant TRADE_STOCK = 10e18;
    uint256 internal constant LANE = TRADE_STOCK / 100;

    function setUp() public {
        _deployRobinhood();
    }

    function test_bid_and_protocol_lane_with_the_stock_sorting_first() public {
        _bidThenSettle(STOCK_LOW);
    }

    function test_bid_and_protocol_lane_with_usdg_sorting_first() public {
        _bidThenSettle(STOCK_HIGH);
    }

    function _bidThenSettle(address stockAddress) private {
        MockERC20 stock = MockERC20(stockAddress);
        UniswapV4StockRouteV1 route = _admitV4Route(stockAddress);
        Launched memory l = _launchStock(stockAddress);

        // --- bid: USDG in through the adapter, STOCK out of the pool, within 3% of the feed quote ---
        _rollToStart(l);
        usdg.mint(bidder, BID_USDG);
        uint256 quoted = route.quoteExactIn(USDG_ADDRESS, stockAddress, BID_USDG);
        uint128 minimum = uint128(quoted * 97 / 100);
        vm.startPrank(bidder);
        usdg.approve(address(adapter), BID_USDG);
        (, uint128 committed) = adapter.bidWithUsdg(
            address(l.auction), BID_USDG, minimum, _bidPrice(GRADUATING_TICKS), FLOOR_PRICE_Q96, block.timestamp
        );
        vm.stopPrank();
        assertGe(committed, minimum, "the bid cleared the caller's minimum");
        assertLt(committed, quoted, "the pool keeps its fee");
        assertEq(stock.balanceOf(address(l.auction)), committed, "the auction holds the STOCK");
        assertEq(usdg.balanceOf(bidder), 0, "the deep pool took every dollar");
        _assertEmpty(route, stock);
        assertEq(usdg.balanceOf(address(adapter)) + stock.balanceOf(address(adapter)), 0, "adapter empty");

        // --- graduation, then a trade on the official pool to fill the protocol lane ---
        _rollToMigration(l);
        stocks.migrate(l.launchId);
        IRobinhoodLaunchpadBase.Launch memory record = stocks.launches(l.launchId);
        assertEq(uint8(record.lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Graduated), "graduated");
        _fundTrader(l, TRADE_STOCK);
        _swapCurrencyIn(l, address(stocksHook), TRADE_STOCK);

        // --- protocol lane: STOCK through the v4 route into the inbox in USDG ---
        uint256 minUsdg = route.quoteExactIn(stockAddress, USDG_ADDRESS, LANE) * 97 / 100;
        uint256 inboxBefore = inbox.totalCollected();
        vm.prank(executor);
        stocksHook.settleProtocolLane(record.poolId, LANE, minUsdg);
        (, uint256 stockConverted, uint256 usdgDeposited,) = stocksHook.settled(record.poolId);
        assertEq(stockConverted, LANE, "the whole lane amount was sold");
        assertGe(usdgDeposited, minUsdg, "the sale cleared the executor's minimum");
        assertEq(inbox.totalCollected(), inboxBefore + usdgDeposited, "the inbox received the USDG");
        _assertEmpty(route, stock);
        assertEq(usdg.balanceOf(address(stocksHook)), 0, "the hook keeps no USDG");
    }

    /// @dev Replace the fixture route with the v4 route over a real hookless USDG/STOCK pool on the
    ///      fixture's pool manager, opened at the feed price.
    function _admitV4Route(address stockAddress) private returns (UniswapV4StockRouteV1 route) {
        bool stockFirst = stockAddress < USDG_ADDRESS;
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        MockERC20(stockAddress).mint(address(this), 1_000_000e18);
        usdg.mint(address(this), 100_000_000e6);
        MockERC20(stockAddress).approve(address(liquidityRouter), type(uint256).max);
        usdg.approve(address(liquidityRouter), type(uint256).max);

        (address currency0, address currency1) =
            stockFirst ? (stockAddress, USDG_ADDRESS) : (USDG_ADDRESS, stockAddress);
        PoolKey memory key =
            PoolKey(Currency.wrap(currency0), Currency.wrap(currency1), FEE, TICK_SPACING, IHooks(address(0)));
        // `currency1` base units per `currency0` base unit, as a Q64.96 square root.
        (uint256 amount1, uint256 amount0) =
            stockFirst ? (USDG_PER_SHARE, uint256(1e18)) : (uint256(1e18), USDG_PER_SHARE);
        poolManager.initialize(
            key, uint160(FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(amount1, 1 << 192, amount0)))
        );
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), LIQUIDITY, 0
            ),
            ""
        );

        MockChainlinkFeed feed = new MockChainlinkFeed(8, FEED_ANSWER, block.timestamp - 1 hours);
        route = new UniswapV4StockRouteV1(
            USDG_ADDRESS, stockAddress, address(poolManager), FEE, TICK_SPACING, address(feed)
        );
        assertEq(route.stockIsCurrency0(), stockFirst);
        vm.prank(safe);
        stocks.admitStock(stockAddress, address(route));
        (,, address admitted) = stocks.stockAdmission(stockAddress);
        assertEq(admitted, address(route), "the v4 route is the admitted route");
    }

    function _assertEmpty(UniswapV4StockRouteV1 route, MockERC20 stock) private view {
        assertEq(usdg.balanceOf(address(route)), 0, "usdg left on the route");
        assertEq(stock.balanceOf(address(route)), 0, "stock left on the route");
    }
}
