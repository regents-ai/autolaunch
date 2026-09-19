// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {StocksBindings} from "../src/StocksBindings.sol";
import {AerodromeStockRouteV1} from "../src/routes/AerodromeStockRouteV1.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSlipstreamPool} from "./mocks/MockSlipstreamPool.sol";

/// @notice The production route quotes from the feed, executes on the pinned pool, refuses any
///         execution more than 5% under the feed quote, and keeps nothing between calls.
contract AerodromeStockRouteTest is Test {
    /// @dev 335.47 dollars per share in eight feed decimals; the same price in USDC base units.
    int256 internal constant FEED_ANSWER = 33_547_000_000;
    uint256 internal constant USDC_PER_SHARE = 335_470_000;
    uint256 internal constant NOW = 1_789_800_000;

    /// @dev 1,000 USDC through the feed price: 1e9 * 1e8 * 1e8 / (33_547_000_000 * 1e6).
    uint256 internal constant STOCK_FOR_1000_USDC = 298_089_247;

    MockERC20 internal usdc;
    MockERC20 internal stock;
    MockSlipstreamPool internal pool;
    MockChainlinkFeed internal feed;
    AerodromeStockRouteV1 internal route;

    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.warp(NOW);
        vm.etch(StocksBindings.USDC, address(new MockERC20("USD Coin", "USDC", 6)).code);
        usdc = MockERC20(StocksBindings.USDC);
        stock = new MockERC20("Apple", "AAPLc", 8);
        pool = new MockSlipstreamPool(address(usdc), address(stock), USDC_PER_SHARE);
        feed = new MockChainlinkFeed(8, FEED_ANSWER, NOW - 1 hours);
        route = new AerodromeStockRouteV1(address(stock), address(pool), address(feed));

        usdc.mint(address(pool), 10_000_000e6);
        stock.mint(address(pool), 1_000_000e8);
    }

    // -------------------------------------------------------------------------
    // construction
    // -------------------------------------------------------------------------

    function test_construction_pins_pool_feed_and_units() public view {
        assertEq(route.stock(), address(stock));
        assertEq(route.usdc(), StocksBindings.USDC);
        assertEq(address(route.pool()), address(pool));
        assertEq(address(route.feed()), address(feed));
        assertEq(route.stockUnit(), 1e8);
        assertEq(route.feedUnit(), 1e8);
    }

    function test_construction_rejects_zero_addresses_and_codeless_targets() public {
        vm.expectRevert(AerodromeStockRouteV1.ZeroAddress.selector);
        new AerodromeStockRouteV1(address(0), address(pool), address(feed));
        vm.expectRevert(AerodromeStockRouteV1.ZeroAddress.selector);
        new AerodromeStockRouteV1(address(stock), address(0), address(feed));
        vm.expectRevert(AerodromeStockRouteV1.ZeroAddress.selector);
        new AerodromeStockRouteV1(address(stock), address(pool), address(0));
        vm.expectRevert(abi.encodeWithSelector(AerodromeStockRouteV1.NoCode.selector, alice));
        new AerodromeStockRouteV1(address(stock), alice, address(feed));
        vm.expectRevert(abi.encodeWithSelector(AerodromeStockRouteV1.NoCode.selector, alice));
        new AerodromeStockRouteV1(address(stock), address(pool), alice);
    }

    function test_construction_rejects_a_pool_in_the_other_currency_order() public {
        MockSlipstreamPool flipped = new MockSlipstreamPool(address(stock), address(usdc), USDC_PER_SHARE);
        vm.expectRevert(
            abi.encodeWithSelector(
                AerodromeStockRouteV1.PoolBindingMismatch.selector, StocksBindings.USDC, address(stock)
            )
        );
        new AerodromeStockRouteV1(address(stock), address(flipped), address(feed));
    }

    function test_construction_rejects_a_pool_of_another_stock() public {
        MockERC20 other = new MockERC20("Nvidia", "NVDAc", 8);
        vm.expectRevert(
            abi.encodeWithSelector(AerodromeStockRouteV1.PoolBindingMismatch.selector, address(other), address(stock))
        );
        new AerodromeStockRouteV1(address(other), address(pool), address(feed));
    }

    // -------------------------------------------------------------------------
    // quotes
    // -------------------------------------------------------------------------

    function test_quote_converts_both_ways_at_the_feed_price() public view {
        assertEq(route.quoteExactIn(address(usdc), address(stock), 1_000e6), STOCK_FOR_1000_USDC);
        assertEq(route.quoteExactIn(address(stock), address(usdc), 1e8), USDC_PER_SHARE);
    }

    function test_quote_rejects_zero_amount_and_unsupported_pairs() public {
        vm.expectRevert(AerodromeStockRouteV1.ZeroAmount.selector);
        route.quoteExactIn(address(usdc), address(stock), 0);
        vm.expectRevert(
            abi.encodeWithSelector(AerodromeStockRouteV1.UnsupportedPair.selector, address(usdc), address(usdc))
        );
        route.quoteExactIn(address(usdc), address(usdc), 1e6);
        vm.expectRevert(abi.encodeWithSelector(AerodromeStockRouteV1.UnsupportedPair.selector, address(stock), alice));
        route.quoteExactIn(address(stock), alice, 1e8);
    }

    function test_quote_rejects_a_stopped_or_broken_feed() public {
        feed.set(FEED_ANSWER, NOW - 7 days);
        assertEq(route.quoteExactIn(address(stock), address(usdc), 1e8), USDC_PER_SHARE);

        feed.set(FEED_ANSWER, NOW - 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(AerodromeStockRouteV1.StaleFeed.selector, NOW - 7 days - 1));
        route.quoteExactIn(address(stock), address(usdc), 1e8);

        feed.set(FEED_ANSWER, 0);
        vm.expectRevert(abi.encodeWithSelector(AerodromeStockRouteV1.StaleFeed.selector, 0));
        route.quoteExactIn(address(stock), address(usdc), 1e8);

        feed.set(0, NOW);
        vm.expectRevert(abi.encodeWithSelector(AerodromeStockRouteV1.BadFeedAnswer.selector, int256(0)));
        route.quoteExactIn(address(stock), address(usdc), 1e8);

        feed.set(-1, NOW);
        vm.expectRevert(abi.encodeWithSelector(AerodromeStockRouteV1.BadFeedAnswer.selector, int256(-1)));
        route.quoteExactIn(address(stock), address(usdc), 1e8);
    }

    // -------------------------------------------------------------------------
    // execution
    // -------------------------------------------------------------------------

    function test_swap_usdc_to_stock_pays_the_recipient_and_keeps_nothing() public {
        usdc.mint(address(route), 1_000e6);

        uint256 amountOut = route.swapExactIn(address(usdc), address(stock), 1_000e6, STOCK_FOR_1000_USDC, alice);

        assertEq(amountOut, STOCK_FOR_1000_USDC);
        assertEq(stock.balanceOf(alice), STOCK_FOR_1000_USDC);
        assertEq(usdc.balanceOf(alice), 0);
        _assertRouteEmpty();
    }

    function test_swap_stock_to_usdc_pays_the_recipient_and_keeps_nothing() public {
        stock.mint(address(route), 3e8);

        uint256 amountOut = route.swapExactIn(address(stock), address(usdc), 3e8, 3 * USDC_PER_SHARE, alice);

        assertEq(amountOut, 3 * USDC_PER_SHARE);
        assertEq(usdc.balanceOf(alice), 3 * USDC_PER_SHARE);
        assertEq(stock.balanceOf(alice), 0);
        _assertRouteEmpty();
    }

    function test_swap_rejects_output_under_the_caller_minimum() public {
        usdc.mint(address(route), 1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                AerodromeStockRouteV1.InsufficientOutput.selector, STOCK_FOR_1000_USDC + 1, STOCK_FOR_1000_USDC
            )
        );
        route.swapExactIn(address(usdc), address(stock), 1_000e6, STOCK_FOR_1000_USDC + 1, alice);
    }

    function test_swap_rejects_a_zero_recipient() public {
        usdc.mint(address(route), 1_000e6);
        vm.expectRevert(AerodromeStockRouteV1.ZeroAddress.selector);
        route.swapExactIn(address(usdc), address(stock), 1_000e6, 0, address(0));
    }

    function test_swap_refuses_a_pool_price_more_than_five_percent_under_the_feed() public {
        usdc.mint(address(route), 1_000e6);
        pool.setPrice(USDC_PER_SHARE * 106 / 100);
        uint256 found = 1_000e6 * 1e8 / (USDC_PER_SHARE * 106 / 100);
        vm.expectRevert(
            abi.encodeWithSelector(AerodromeStockRouteV1.PriceDeviation.selector, STOCK_FOR_1000_USDC, found)
        );
        route.swapExactIn(address(usdc), address(stock), 1_000e6, 0, alice);

        stock.mint(address(route), 1e8);
        pool.setPrice(USDC_PER_SHARE * 94 / 100);
        vm.expectRevert(
            abi.encodeWithSelector(
                AerodromeStockRouteV1.PriceDeviation.selector, USDC_PER_SHARE, USDC_PER_SHARE * 94 / 100
            )
        );
        route.swapExactIn(address(stock), address(usdc), 1e8, 0, alice);
    }

    function test_swap_accepts_a_pool_price_within_five_percent_of_the_feed() public {
        usdc.mint(address(route), 1_000e6);
        pool.setPrice(USDC_PER_SHARE * 104 / 100);
        uint256 amountOut = route.swapExactIn(address(usdc), address(stock), 1_000e6, 0, alice);
        assertEq(amountOut, 1_000e6 * 1e8 / (USDC_PER_SHARE * 104 / 100));
        assertEq(stock.balanceOf(alice), amountOut);
        _assertRouteEmpty();
    }

    function test_swap_returns_unconsumed_input_to_the_recipient() public {
        usdc.mint(address(route), 1_000e6);
        pool.setFillBps(9_700);

        uint256 amountOut = route.swapExactIn(address(usdc), address(stock), 1_000e6, 0, alice);

        assertEq(amountOut, 970e6 * 1e8 / USDC_PER_SHARE);
        assertEq(stock.balanceOf(alice), amountOut);
        assertEq(usdc.balanceOf(alice), 30e6);
        _assertRouteEmpty();
    }

    function test_swap_refuses_a_fill_too_short_to_meet_the_feed_bound() public {
        usdc.mint(address(route), 1_000e6);
        pool.setFillBps(9_000);
        vm.expectRevert(
            abi.encodeWithSelector(
                AerodromeStockRouteV1.PriceDeviation.selector, STOCK_FOR_1000_USDC, 900e6 * 1e8 / USDC_PER_SHARE
            )
        );
        route.swapExactIn(address(usdc), address(stock), 1_000e6, 0, alice);
    }

    function test_swap_validates_the_feed_before_touching_the_pool() public {
        usdc.mint(address(route), 1_000e6);
        feed.set(FEED_ANSWER, NOW - 8 days);
        vm.expectRevert(abi.encodeWithSelector(AerodromeStockRouteV1.StaleFeed.selector, NOW - 8 days));
        route.swapExactIn(address(usdc), address(stock), 1_000e6, 0, alice);
    }

    function test_swap_cannot_be_reentered_from_the_pool_callback() public {
        usdc.mint(address(route), 1_000e6);
        pool.setReenter(true);
        vm.expectRevert(ReentrancyGuardTransient.Reentrancy.selector);
        route.swapExactIn(address(usdc), address(stock), 1_000e6, 0, alice);
    }

    function test_callback_accepts_only_the_pinned_pool() public {
        usdc.mint(address(route), 1e6);
        vm.expectRevert(abi.encodeWithSelector(AerodromeStockRouteV1.NotPool.selector, address(this)));
        route.uniswapV3SwapCallback(1e6, 0, "");
        assertEq(usdc.balanceOf(address(route)), 1e6);
    }

    function _assertRouteEmpty() internal view {
        assertEq(usdc.balanceOf(address(route)), 0, "usdc left on the route");
        assertEq(stock.balanceOf(address(route)), 0, "stock left on the route");
    }
}
