// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {MockChainlinkFeed} from "autolaunch-stocks-test/mocks/MockChainlinkFeed.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {UniswapV3StockRouteV1} from "../src/routes/UniswapV3StockRouteV1.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";

/// @notice The production route quotes from the feed, executes on the pinned pool in whichever
///         currency order the pool sorts, refuses any execution more than 5% under the feed quote,
///         and keeps nothing between calls. Run once with USDG as `token0` and once with the
///         18-decimal stock as `token0`.
abstract contract UniswapV3StockRouteTestBase is Test {
    /// @dev 230 dollars per share in eight feed decimals; the same price in USDG base units.
    int256 internal constant FEED_ANSWER = 23_000_000_000;
    uint256 internal constant USDG_PER_SHARE = 230_000000;
    uint256 internal constant NOW = 1_789_800_000;

    /// @dev 1,000 USDG through the feed price: 1e9 * 1e18 * 1e8 / (23_000_000_000 * 1e6).
    uint256 internal constant STOCK_FOR_1000_USDG = 4_347_826_086_956_521_739;

    MockERC20 internal usdg;
    MockERC20 internal stock;
    MockUniswapV3Pool internal pool;
    MockChainlinkFeed internal feed;
    UniswapV3StockRouteV1 internal route;

    address internal alice = makeAddr("alice");

    function _stockIsToken0() internal pure virtual returns (bool);

    function setUp() public {
        vm.warp(NOW);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        stock = new MockERC20("Apple", "AAPL", 18);
        pool = _newPool(_stockIsToken0(), address(stock));
        feed = new MockChainlinkFeed(8, FEED_ANSWER, NOW - 1 hours);
        route = new UniswapV3StockRouteV1(address(usdg), address(stock), address(pool), address(feed));

        usdg.mint(address(pool), 10_000_000e6);
        stock.mint(address(pool), 1_000_000e18);
    }

    function _newPool(bool stockFirst, address stock_) internal returns (MockUniswapV3Pool) {
        return stockFirst
            ? new MockUniswapV3Pool(stock_, address(usdg), address(usdg), USDG_PER_SHARE)
            : new MockUniswapV3Pool(address(usdg), stock_, address(usdg), USDG_PER_SHARE);
    }

    // -------------------------------------------------------------------------
    // construction
    // -------------------------------------------------------------------------

    function test_construction_pins_pool_feed_order_and_units() public view {
        assertEq(route.stock(), address(stock));
        assertEq(route.usdg(), address(usdg));
        assertEq(address(route.pool()), address(pool));
        assertEq(address(route.feed()), address(feed));
        assertEq(route.stockIsToken0(), _stockIsToken0());
        assertEq(route.stockUnit(), 1e18);
        assertEq(route.feedUnit(), 1e8);
    }

    function test_construction_rejects_zero_addresses_and_codeless_targets() public {
        vm.expectRevert(UniswapV3StockRouteV1.ZeroAddress.selector);
        new UniswapV3StockRouteV1(address(0), address(stock), address(pool), address(feed));
        vm.expectRevert(UniswapV3StockRouteV1.ZeroAddress.selector);
        new UniswapV3StockRouteV1(address(usdg), address(0), address(pool), address(feed));
        vm.expectRevert(UniswapV3StockRouteV1.ZeroAddress.selector);
        new UniswapV3StockRouteV1(address(usdg), address(stock), address(0), address(feed));
        vm.expectRevert(UniswapV3StockRouteV1.ZeroAddress.selector);
        new UniswapV3StockRouteV1(address(usdg), address(stock), address(pool), address(0));
        vm.expectRevert(abi.encodeWithSelector(UniswapV3StockRouteV1.NoCode.selector, alice));
        new UniswapV3StockRouteV1(address(usdg), address(stock), alice, address(feed));
        vm.expectRevert(abi.encodeWithSelector(UniswapV3StockRouteV1.NoCode.selector, alice));
        new UniswapV3StockRouteV1(address(usdg), address(stock), address(pool), alice);
    }

    function test_construction_rejects_a_dollar_that_is_not_six_decimals() public {
        MockERC20 wrong = new MockERC20("Not USDG", "NUSD", 18);
        MockUniswapV3Pool wrongPool = new MockUniswapV3Pool(address(wrong), address(stock), address(wrong), 1);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3StockRouteV1.UnexpectedDecimals.selector, 6, 18));
        new UniswapV3StockRouteV1(address(wrong), address(stock), address(wrongPool), address(feed));
    }

    function test_construction_accepts_the_pool_in_the_other_currency_order() public {
        MockUniswapV3Pool flipped = _newPool(!_stockIsToken0(), address(stock));
        UniswapV3StockRouteV1 other =
            new UniswapV3StockRouteV1(address(usdg), address(stock), address(flipped), address(feed));
        assertEq(other.stockIsToken0(), !_stockIsToken0());
    }

    function test_construction_rejects_a_pool_of_another_stock() public {
        MockERC20 other = new MockERC20("Nvidia", "NVDA", 18);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3StockRouteV1.PoolBindingMismatch.selector,
                address(usdg),
                address(other),
                pool.token0(),
                pool.token1()
            )
        );
        new UniswapV3StockRouteV1(address(usdg), address(other), address(pool), address(feed));
    }

    function test_construction_rejects_a_pool_of_another_dollar() public {
        MockERC20 other = new MockERC20("Other Dollar", "OUSD", 6);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3StockRouteV1.PoolBindingMismatch.selector,
                address(other),
                address(stock),
                pool.token0(),
                pool.token1()
            )
        );
        new UniswapV3StockRouteV1(address(other), address(stock), address(pool), address(feed));
    }

    // -------------------------------------------------------------------------
    // quotes
    // -------------------------------------------------------------------------

    function test_quote_converts_both_ways_at_the_feed_price() public view {
        assertEq(route.quoteExactIn(address(usdg), address(stock), 1_000e6), STOCK_FOR_1000_USDG);
        assertEq(route.quoteExactIn(address(stock), address(usdg), 1e18), USDG_PER_SHARE);
        // A thousand dollars of shares back is a thousand dollars, within one floor at six decimals.
        assertApproxEqAbs(route.quoteExactIn(address(stock), address(usdg), STOCK_FOR_1000_USDG), 1_000e6, 1);
    }

    function test_quote_rejects_zero_amount_and_unsupported_pairs() public {
        vm.expectRevert(UniswapV3StockRouteV1.ZeroAmount.selector);
        route.quoteExactIn(address(usdg), address(stock), 0);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV3StockRouteV1.UnsupportedPair.selector, address(usdg), address(usdg))
        );
        route.quoteExactIn(address(usdg), address(usdg), 1e6);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3StockRouteV1.UnsupportedPair.selector, address(stock), alice));
        route.quoteExactIn(address(stock), alice, 1e18);
    }

    function test_quote_rejects_a_stopped_or_broken_feed() public {
        feed.set(FEED_ANSWER, NOW - 7 days);
        assertEq(route.quoteExactIn(address(stock), address(usdg), 1e18), USDG_PER_SHARE);

        feed.set(FEED_ANSWER, NOW - 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3StockRouteV1.StaleFeed.selector, NOW - 7 days - 1));
        route.quoteExactIn(address(stock), address(usdg), 1e18);

        feed.set(FEED_ANSWER, 0);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3StockRouteV1.StaleFeed.selector, 0));
        route.quoteExactIn(address(stock), address(usdg), 1e18);

        feed.set(0, NOW);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3StockRouteV1.BadFeedAnswer.selector, int256(0)));
        route.quoteExactIn(address(stock), address(usdg), 1e18);

        feed.set(-1, NOW);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3StockRouteV1.BadFeedAnswer.selector, int256(-1)));
        route.quoteExactIn(address(stock), address(usdg), 1e18);
    }

    // -------------------------------------------------------------------------
    // execution
    // -------------------------------------------------------------------------

    function test_swap_usdg_to_stock_pays_the_recipient_and_keeps_nothing() public {
        usdg.mint(address(route), 1_000e6);

        uint256 amountOut = route.swapExactIn(address(usdg), address(stock), 1_000e6, STOCK_FOR_1000_USDG, alice);

        assertEq(amountOut, STOCK_FOR_1000_USDG);
        assertEq(stock.balanceOf(alice), STOCK_FOR_1000_USDG);
        assertEq(usdg.balanceOf(alice), 0);
        _assertRouteEmpty();
    }

    function test_swap_stock_to_usdg_pays_the_recipient_and_keeps_nothing() public {
        stock.mint(address(route), 3e18);

        uint256 amountOut = route.swapExactIn(address(stock), address(usdg), 3e18, 3 * USDG_PER_SHARE, alice);

        assertEq(amountOut, 3 * USDG_PER_SHARE);
        assertEq(usdg.balanceOf(alice), 3 * USDG_PER_SHARE);
        assertEq(stock.balanceOf(alice), 0);
        _assertRouteEmpty();
    }

    function test_swap_rejects_output_under_the_caller_minimum() public {
        usdg.mint(address(route), 1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3StockRouteV1.InsufficientOutput.selector, STOCK_FOR_1000_USDG + 1, STOCK_FOR_1000_USDG
            )
        );
        route.swapExactIn(address(usdg), address(stock), 1_000e6, STOCK_FOR_1000_USDG + 1, alice);
    }

    function test_swap_rejects_a_zero_recipient() public {
        usdg.mint(address(route), 1_000e6);
        vm.expectRevert(UniswapV3StockRouteV1.ZeroAddress.selector);
        route.swapExactIn(address(usdg), address(stock), 1_000e6, 0, address(0));
    }

    function test_swap_refuses_a_pool_price_more_than_five_percent_under_the_feed() public {
        usdg.mint(address(route), 1_000e6);
        pool.setPrice(USDG_PER_SHARE * 106 / 100);
        uint256 found = 1_000e6 * 1e18 / (USDG_PER_SHARE * 106 / 100);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV3StockRouteV1.PriceDeviation.selector, STOCK_FOR_1000_USDG, found)
        );
        route.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice);

        stock.mint(address(route), 1e18);
        pool.setPrice(USDG_PER_SHARE * 94 / 100);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3StockRouteV1.PriceDeviation.selector, USDG_PER_SHARE, USDG_PER_SHARE * 94 / 100
            )
        );
        route.swapExactIn(address(stock), address(usdg), 1e18, 0, alice);
    }

    function test_swap_accepts_a_pool_price_within_five_percent_of_the_feed() public {
        usdg.mint(address(route), 1_000e6);
        pool.setPrice(USDG_PER_SHARE * 104 / 100);
        uint256 amountOut = route.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice);
        assertEq(amountOut, 1_000e6 * 1e18 / (USDG_PER_SHARE * 104 / 100));
        assertEq(stock.balanceOf(alice), amountOut);
        _assertRouteEmpty();
    }

    function test_swap_returns_unconsumed_input_to_the_recipient() public {
        usdg.mint(address(route), 1_000e6);
        pool.setFillBps(9_700);

        uint256 amountOut = route.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice);

        assertEq(amountOut, 970e6 * 1e18 / USDG_PER_SHARE);
        assertEq(stock.balanceOf(alice), amountOut);
        assertEq(usdg.balanceOf(alice), 30e6);
        _assertRouteEmpty();
    }

    function test_swap_returns_unconsumed_stock_to_the_recipient() public {
        stock.mint(address(route), 10e18);
        pool.setFillBps(9_700);

        uint256 amountOut = route.swapExactIn(address(stock), address(usdg), 10e18, 0, alice);

        assertEq(amountOut, 9.7e18 * USDG_PER_SHARE / 1e18);
        assertEq(usdg.balanceOf(alice), amountOut);
        assertEq(stock.balanceOf(alice), 0.3e18);
        _assertRouteEmpty();
    }

    function test_swap_refuses_a_fill_too_short_to_meet_the_feed_bound() public {
        usdg.mint(address(route), 1_000e6);
        pool.setFillBps(9_000);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3StockRouteV1.PriceDeviation.selector, STOCK_FOR_1000_USDG, 900e6 * 1e18 / USDG_PER_SHARE
            )
        );
        route.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice);
    }

    function test_swap_validates_the_feed_before_touching_the_pool() public {
        usdg.mint(address(route), 1_000e6);
        feed.set(FEED_ANSWER, NOW - 8 days);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3StockRouteV1.StaleFeed.selector, NOW - 8 days));
        route.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice);
    }

    function test_swap_cannot_be_reentered_from_the_pool_callback() public {
        usdg.mint(address(route), 1_000e6);
        pool.setReenter(true);
        vm.expectRevert(ReentrancyGuardTransient.Reentrancy.selector);
        route.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice);
    }

    function test_callback_accepts_only_the_pinned_pool() public {
        usdg.mint(address(route), 1e6);
        stock.mint(address(route), 1e18);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3StockRouteV1.NotPool.selector, address(this)));
        route.uniswapV3SwapCallback(1e6, 0, "");
        vm.expectRevert(abi.encodeWithSelector(UniswapV3StockRouteV1.NotPool.selector, address(this)));
        route.uniswapV3SwapCallback(0, 1e18, "");
        assertEq(usdg.balanceOf(address(route)), 1e6);
        assertEq(stock.balanceOf(address(route)), 1e18);
    }

    function _assertRouteEmpty() internal view {
        assertEq(usdg.balanceOf(address(route)), 0, "usdg left on the route");
        assertEq(stock.balanceOf(address(route)), 0, "stock left on the route");
    }
}

/// @notice USDG is `token0`: AAPL, CRCL, INTC, META, MSFT, MSTR, NVDA, SNDK, QQQ.
contract UniswapV3StockRouteUsdgFirstTest is UniswapV3StockRouteTestBase {
    function _stockIsToken0() internal pure override returns (bool) {
        return false;
    }
}

/// @notice The stock is `token0`: AMZN, GOOGL, SPCX, TSLA, SPY.
contract UniswapV3StockRouteStockFirstTest is UniswapV3StockRouteTestBase {
    function _stockIsToken0() internal pure override returns (bool) {
        return true;
    }
}
