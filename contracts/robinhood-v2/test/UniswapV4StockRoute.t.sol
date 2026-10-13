// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockChainlinkFeed} from "autolaunch-stocks-test/mocks/MockChainlinkFeed.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {UniswapV4StockRouteV1} from "../src/routes/UniswapV4StockRouteV1.sol";
import {ReenteringStock} from "./mocks/ReenteringStock.sol";

/// @notice The v4 route quotes from the feed, executes on the pinned hookless pool of the real pool
///         manager in whichever currency order the pool sorts, refuses only what the caller's
///         minimum refuses, and keeps nothing between calls. Run once with USDG as `currency0` and
///         once with the 18-decimal stock as `currency0`.
abstract contract UniswapV4StockRouteTestBase is Test {
    using StateLibrary for IPoolManager;

    /// @dev 230 dollars per share in eight feed decimals; the same price in USDG base units.
    int256 internal constant FEED_ANSWER = 23_000_000_000;
    uint256 internal constant USDG_PER_SHARE = 230_000000;
    uint256 internal constant NOW = 1_789_800_000;

    /// @dev 1,000 USDG through the feed price: 1e9 * 1e18 * 1e8 / (23_000_000_000 * 1e6).
    uint256 internal constant STOCK_FOR_1000_USDG = 4_347_826_086_956_521_739;

    /// @dev The deep pool: a 1% fee like the live COIN and ORCL pools, about ten million dollars a
    ///      side across the whole range.
    uint24 internal constant FEE = 10_000;
    int24 internal constant TICK_SPACING = 200;
    int256 internal constant DEEP_LIQUIDITY = 6.6e17;

    /// @dev The thin pool: liquidity only within ten spacings of the price, so a large swap runs out.
    uint24 internal constant THIN_FEE = 3_000;
    int24 internal constant THIN_TICK_SPACING = 60;
    int256 internal constant THIN_LIQUIDITY = 1e15;

    MockERC20 internal usdg;
    ReenteringStock internal stock;
    PoolManager internal poolManager;
    PoolModifyLiquidityTest internal liquidityRouter;
    MockChainlinkFeed internal feed;
    UniswapV4StockRouteV1 internal route;

    address internal alice = makeAddr("alice");

    function _stockIsCurrency0() internal pure virtual returns (bool);

    function setUp() public {
        vm.warp(NOW);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        stock = _newStock("Coinbase", "COIN");
        poolManager = new PoolManager(address(this));
        liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        feed = new MockChainlinkFeed(8, FEED_ANSWER, NOW - 1 hours);

        usdg.mint(address(this), 100_000_000e6);
        stock.mint(address(this), 1_000_000e18);
        usdg.approve(address(liquidityRouter), type(uint256).max);
        stock.approve(address(liquidityRouter), type(uint256).max);

        PoolKey memory key = _key(address(usdg), address(stock), FEE, TICK_SPACING);
        poolManager.initialize(key, _sqrtPriceAtFeed());
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), DEEP_LIQUIDITY, 0
            ),
            ""
        );

        route = _newRoute(address(usdg), address(stock), FEE, TICK_SPACING);
    }

    // -------------------------------------------------------------------------
    // construction
    // -------------------------------------------------------------------------

    function test_construction_pins_pool_feed_order_and_units() public view {
        assertEq(route.stock(), address(stock));
        assertEq(route.usdg(), address(usdg));
        assertEq(address(route.poolManager()), address(poolManager));
        assertEq(address(route.feed()), address(feed));
        assertEq(route.fee(), FEE);
        assertEq(route.tickSpacing(), TICK_SPACING);
        assertEq(route.poolId(), PoolId.unwrap(_key(address(usdg), address(stock), FEE, TICK_SPACING).toId()));
        assertEq(route.stockIsCurrency0(), _stockIsCurrency0());
        assertEq(route.stockUnit(), 1e18);
        assertEq(route.feedUnit(), 1e8);
    }

    function test_construction_rejects_zero_addresses_and_codeless_targets() public {
        address manager = address(poolManager);
        vm.expectRevert(UniswapV4StockRouteV1.ZeroAddress.selector);
        new UniswapV4StockRouteV1(address(0), address(stock), manager, FEE, TICK_SPACING, address(feed));
        vm.expectRevert(UniswapV4StockRouteV1.ZeroAddress.selector);
        new UniswapV4StockRouteV1(address(usdg), address(0), manager, FEE, TICK_SPACING, address(feed));
        vm.expectRevert(UniswapV4StockRouteV1.ZeroAddress.selector);
        new UniswapV4StockRouteV1(address(usdg), address(stock), address(0), FEE, TICK_SPACING, address(feed));
        vm.expectRevert(UniswapV4StockRouteV1.ZeroAddress.selector);
        new UniswapV4StockRouteV1(address(usdg), address(stock), manager, FEE, TICK_SPACING, address(0));
        vm.expectRevert(abi.encodeWithSelector(UniswapV4StockRouteV1.NoCode.selector, alice));
        new UniswapV4StockRouteV1(address(usdg), address(stock), alice, FEE, TICK_SPACING, address(feed));
        vm.expectRevert(abi.encodeWithSelector(UniswapV4StockRouteV1.NoCode.selector, alice));
        new UniswapV4StockRouteV1(address(usdg), address(stock), manager, FEE, TICK_SPACING, alice);
    }

    function test_construction_rejects_a_dollar_that_is_not_six_decimals() public {
        MockERC20 wrong = new MockERC20("Not USDG", "NUSD", 18);
        vm.expectRevert(abi.encodeWithSelector(UniswapV4StockRouteV1.UnexpectedDecimals.selector, 6, 18));
        _newRoute(address(wrong), address(stock), FEE, TICK_SPACING);
    }

    function test_construction_rejects_a_pool_that_does_not_exist() public {
        MockERC20 otherDollar = new MockERC20("Other Dollar", "OUSD", 6);
        MockERC20 otherStock = new MockERC20("Nvidia", "NVDA", 18);

        _expectNotInitialized(address(usdg), address(stock), FEE + 1, TICK_SPACING);
        _newRoute(address(usdg), address(stock), FEE + 1, TICK_SPACING);
        _expectNotInitialized(address(usdg), address(stock), FEE, TICK_SPACING + 1);
        _newRoute(address(usdg), address(stock), FEE, TICK_SPACING + 1);
        _expectNotInitialized(address(usdg), address(otherStock), FEE, TICK_SPACING);
        _newRoute(address(usdg), address(otherStock), FEE, TICK_SPACING);
        _expectNotInitialized(address(otherDollar), address(stock), FEE, TICK_SPACING);
        _newRoute(address(otherDollar), address(stock), FEE, TICK_SPACING);
    }

    function test_construction_rejects_a_pair_whose_only_pool_has_a_hook() public {
        // The same pair, fee and spacing behind a hook is a different pool; the route never reaches it.
        PoolKey memory hooked = _key(address(usdg), address(stock), THIN_FEE, THIN_TICK_SPACING);
        hooked.hooks = IHooks(address((uint160(1) << 159) | Hooks.BEFORE_DONATE_FLAG));
        poolManager.initialize(hooked, _sqrtPriceAtFeed());

        _expectNotInitialized(address(usdg), address(stock), THIN_FEE, THIN_TICK_SPACING);
        _newRoute(address(usdg), address(stock), THIN_FEE, THIN_TICK_SPACING);
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
        vm.expectRevert(UniswapV4StockRouteV1.ZeroAmount.selector);
        route.quoteExactIn(address(usdg), address(stock), 0);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV4StockRouteV1.UnsupportedPair.selector, address(usdg), address(usdg))
        );
        route.quoteExactIn(address(usdg), address(usdg), 1e6);
        vm.expectRevert(abi.encodeWithSelector(UniswapV4StockRouteV1.UnsupportedPair.selector, address(stock), alice));
        route.quoteExactIn(address(stock), alice, 1e18);
    }

    function test_quote_rejects_a_stopped_or_broken_feed() public {
        feed.set(FEED_ANSWER, NOW - 7 days);
        assertEq(route.quoteExactIn(address(stock), address(usdg), 1e18), USDG_PER_SHARE);

        feed.set(FEED_ANSWER, NOW - 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(UniswapV4StockRouteV1.StaleFeed.selector, NOW - 7 days - 1));
        route.quoteExactIn(address(stock), address(usdg), 1e18);

        feed.set(FEED_ANSWER, 0);
        vm.expectRevert(abi.encodeWithSelector(UniswapV4StockRouteV1.StaleFeed.selector, 0));
        route.quoteExactIn(address(stock), address(usdg), 1e18);

        feed.set(0, NOW);
        vm.expectRevert(abi.encodeWithSelector(UniswapV4StockRouteV1.BadFeedAnswer.selector, int256(0)));
        route.quoteExactIn(address(stock), address(usdg), 1e18);

        feed.set(-1, NOW);
        vm.expectRevert(abi.encodeWithSelector(UniswapV4StockRouteV1.BadFeedAnswer.selector, int256(-1)));
        route.quoteExactIn(address(stock), address(usdg), 1e18);
    }

    // -------------------------------------------------------------------------
    // execution
    // -------------------------------------------------------------------------

    function test_swap_usdg_to_stock_pays_the_recipient_and_keeps_nothing() public {
        usdg.mint(address(route), 1_000e6);
        uint256 managerUsdg = usdg.balanceOf(address(poolManager));
        uint256 managerStock = stock.balanceOf(address(poolManager));

        uint256 amountOut = route.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice);

        // The pool opened at the feed price and keeps a 1% fee.
        assertApproxEqRel(amountOut, STOCK_FOR_1000_USDG * 99 / 100, 0.001e18);
        assertEq(stock.balanceOf(alice), amountOut);
        assertEq(usdg.balanceOf(alice), 0);
        assertEq(usdg.balanceOf(address(poolManager)), managerUsdg + 1_000e6);
        assertEq(stock.balanceOf(address(poolManager)), managerStock - amountOut);
        _assertRouteEmpty(route);
    }

    function test_swap_stock_to_usdg_pays_the_recipient_and_keeps_nothing() public {
        stock.mint(address(route), 3e18);
        uint256 managerUsdg = usdg.balanceOf(address(poolManager));
        uint256 managerStock = stock.balanceOf(address(poolManager));

        uint256 amountOut = route.swapExactIn(address(stock), address(usdg), 3e18, 0, alice);

        assertApproxEqRel(amountOut, 3 * USDG_PER_SHARE * 99 / 100, 0.001e18);
        assertEq(usdg.balanceOf(alice), amountOut);
        assertEq(stock.balanceOf(alice), 0);
        assertEq(stock.balanceOf(address(poolManager)), managerStock + 3e18);
        assertEq(usdg.balanceOf(address(poolManager)), managerUsdg - amountOut);
        _assertRouteEmpty(route);
    }

    function test_swap_is_refused_one_unit_over_what_the_pool_pays_and_executes_at_it() public {
        usdg.mint(address(route), 1_000e6);
        uint256 snapshot = vm.snapshotState();
        uint256 found = route.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice);
        vm.revertToState(snapshot);

        vm.expectRevert(abi.encodeWithSelector(UniswapV4StockRouteV1.InsufficientOutput.selector, found + 1, found));
        route.swapExactIn(address(usdg), address(stock), 1_000e6, found + 1, alice);
        assertEq(usdg.balanceOf(address(route)), 1_000e6, "a refused swap moves nothing");

        assertEq(route.swapExactIn(address(usdg), address(stock), 1_000e6, found, alice), found);
        _assertRouteEmpty(route);
    }

    function test_swap_rejects_a_zero_recipient() public {
        usdg.mint(address(route), 1_000e6);
        vm.expectRevert(UniswapV4StockRouteV1.ZeroAddress.selector);
        route.swapExactIn(address(usdg), address(stock), 1_000e6, 0, address(0));
    }

    function test_swap_rejects_zero_amount_and_unsupported_pairs() public {
        usdg.mint(address(route), 1e6);
        vm.expectRevert(UniswapV4StockRouteV1.ZeroAmount.selector);
        route.swapExactIn(address(usdg), address(stock), 0, 0, alice);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV4StockRouteV1.UnsupportedPair.selector, address(usdg), address(usdg))
        );
        route.swapExactIn(address(usdg), address(usdg), 1e6, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(UniswapV4StockRouteV1.UnsupportedPair.selector, address(stock), alice));
        route.swapExactIn(address(stock), alice, 1e6, 0, alice);
        assertEq(usdg.balanceOf(address(route)), 1e6);
    }

    function test_swap_far_under_the_feed_is_refused_only_by_the_caller_minimum() public {
        // The feed says a share costs half what the pool charges: the quote doubles, the pool does not.
        feed.set(FEED_ANSWER / 2, NOW);
        usdg.mint(address(route), 1_000e6);
        uint256 minimum = route.quoteExactIn(address(usdg), address(stock), 1_000e6) * 95 / 100;

        vm.expectPartialRevert(UniswapV4StockRouteV1.InsufficientOutput.selector);
        route.swapExactIn(address(usdg), address(stock), 1_000e6, minimum, alice);

        uint256 amountOut = route.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice);
        assertLt(amountOut, minimum);
        assertEq(stock.balanceOf(alice), amountOut);
        _assertRouteEmpty(route);
    }

    function test_swap_returns_unconsumed_usdg_to_the_recipient() public {
        UniswapV4StockRouteV1 thin = _thinRoute();
        usdg.mint(address(thin), 1_000_000e6);

        uint256 amountOut = thin.swapExactIn(address(usdg), address(stock), 1_000_000e6, 0, alice);

        uint256 returned = usdg.balanceOf(alice);
        assertGt(amountOut, 0);
        assertEq(stock.balanceOf(alice), amountOut);
        assertGt(returned, 0, "the thin pool cannot take a million dollars");
        assertLt(returned, 1_000_000e6);
        _assertRouteEmpty(thin);
    }

    function test_swap_returns_unconsumed_stock_to_the_recipient() public {
        UniswapV4StockRouteV1 thin = _thinRoute();
        stock.mint(address(thin), 10_000e18);

        uint256 amountOut = thin.swapExactIn(address(stock), address(usdg), 10_000e18, 0, alice);

        uint256 returned = stock.balanceOf(alice);
        assertGt(amountOut, 0);
        assertEq(usdg.balanceOf(alice), amountOut);
        assertGt(returned, 0, "the thin pool cannot take ten thousand shares");
        assertLt(returned, 10_000e18);
        _assertRouteEmpty(thin);
    }

    function test_swap_succeeds_while_the_feed_is_stale_and_the_quote_reverts() public {
        usdg.mint(address(route), 1_000e6);
        feed.set(FEED_ANSWER, NOW - 8 days);
        vm.expectRevert(abi.encodeWithSelector(UniswapV4StockRouteV1.StaleFeed.selector, NOW - 8 days));
        route.quoteExactIn(address(usdg), address(stock), 1_000e6);

        uint256 amountOut = route.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice);

        assertGt(amountOut, 0);
        assertEq(stock.balanceOf(alice), amountOut);
        _assertRouteEmpty(route);

        feed.set(0, NOW);
        stock.mint(address(route), 1e18);
        assertGt(route.swapExactIn(address(stock), address(usdg), 1e18, 0, alice), 0);
        _assertRouteEmpty(route);
    }

    function test_swap_spends_only_the_stated_amount_and_leaves_other_tokens_alone() public {
        usdg.mint(address(route), 1_500e6);
        stock.mint(address(route), 5e18);
        uint256 managerUsdg = usdg.balanceOf(address(poolManager));
        uint256 managerStock = stock.balanceOf(address(poolManager));

        uint256 bought = route.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice);

        assertEq(usdg.balanceOf(address(poolManager)), managerUsdg + 1_000e6, "exactly the stated USDG");
        assertEq(usdg.balanceOf(address(route)), 500e6, "the other USDG stays");
        assertEq(stock.balanceOf(address(route)), 5e18, "the stock stays");
        assertEq(stock.balanceOf(alice), bought);
        assertEq(usdg.balanceOf(alice), 0, "nothing is refunded on a full fill");

        uint256 sold = route.swapExactIn(address(stock), address(usdg), 3e18, 0, alice);

        assertEq(stock.balanceOf(address(poolManager)), managerStock - bought + 3e18, "exactly the stated stock");
        assertEq(stock.balanceOf(address(route)), 2e18, "the other stock stays");
        assertEq(usdg.balanceOf(address(route)), 500e6);
        assertEq(usdg.balanceOf(alice), sold);
        assertEq(stock.balanceOf(alice), bought, "nothing is refunded on a full fill");
    }

    function test_swap_reverts_when_the_route_holds_less_than_the_stated_amount() public {
        usdg.mint(address(route), 999e6);
        vm.expectRevert();
        route.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice);
        assertEq(usdg.balanceOf(address(route)), 999e6);
        assertEq(stock.balanceOf(alice), 0);
    }

    function test_swap_of_dust_that_buys_nothing_pays_nothing_and_keeps_nothing() public {
        // One base unit of an 18-decimal share is far less than one base unit of USDG.
        stock.mint(address(route), 1);

        assertEq(route.swapExactIn(address(stock), address(usdg), 1, 0, alice), 0);

        assertEq(usdg.balanceOf(alice), 0);
        assertEq(stock.balanceOf(alice), 0, "the pool took the unit");
        _assertRouteEmpty(route);
    }

    function test_swap_on_a_pool_with_no_liquidity_returns_the_whole_input() public {
        poolManager.initialize(_key(address(usdg), address(stock), THIN_FEE, THIN_TICK_SPACING), _sqrtPriceAtFeed());
        UniswapV4StockRouteV1 empty = _newRoute(address(usdg), address(stock), THIN_FEE, THIN_TICK_SPACING);
        usdg.mint(address(empty), 1_000e6);

        assertEq(empty.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice), 0);

        assertEq(usdg.balanceOf(alice), 1_000e6, "every unit comes back");
        assertEq(stock.balanceOf(alice), 0);
        _assertRouteEmpty(empty);
    }

    function test_swap_after_the_pool_ran_out_is_refused_and_moves_nothing() public {
        UniswapV4StockRouteV1 thin = _thinRoute();
        usdg.mint(address(thin), 1_000_000e6);
        thin.swapExactIn(address(usdg), address(stock), 1_000_000e6, 0, alice);

        // The partial fill left the pool's price at the end of its range; nothing more can be bought
        // until someone sells back into it.
        usdg.mint(address(thin), 1_000e6);
        vm.expectPartialRevert(Pool.PriceLimitAlreadyExceeded.selector);
        thin.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice);
        assertEq(usdg.balanceOf(address(thin)), 1_000e6);

        stock.mint(address(thin), 1e18);
        assertGt(thin.swapExactIn(address(stock), address(usdg), 1e18, 0, alice), 0, "the other side still trades");
        assertGt(thin.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice), 0, "and buying resumes");
        _assertRouteEmpty(thin);
    }

    function test_swap_cannot_be_called_from_inside_another_pool_manager_lock() public {
        usdg.mint(address(route), 1_000e6);

        poolManager.unlock("");

        assertEq(usdg.balanceOf(address(route)), 1_000e6, "a refused swap moves nothing");
        assertEq(stock.balanceOf(alice), 0);
    }

    /// @dev This contract's own lock on the pool manager: the route must refuse to swap inside it.
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        route.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice);
        return "";
    }

    function test_swap_cannot_be_reentered_from_a_stock_transfer() public {
        usdg.mint(address(route), 1_000e6);
        stock.arm(route, address(usdg), alice);

        uint256 amountOut = route.swapExactIn(address(usdg), address(stock), 1_000e6, 0, alice);

        assertEq(bytes4(stock.reentryRevert()), ReentrancyGuardTransient.Reentrancy.selector);
        assertEq(stock.balanceOf(alice), amountOut);
        _assertRouteEmpty(route);
    }

    function test_swap_cannot_be_reentered_from_the_refund_of_unconsumed_stock() public {
        UniswapV4StockRouteV1 thin = _thinRoute();
        stock.mint(address(thin), 10_000e18);
        // The refund to alice happens after the pool manager's lock has closed, so only the route's
        // own guard stands in the way.
        stock.arm(thin, address(usdg), alice);

        uint256 amountOut = thin.swapExactIn(address(stock), address(usdg), 10_000e18, 0, alice);

        assertEq(bytes4(stock.reentryRevert()), ReentrancyGuardTransient.Reentrancy.selector);
        assertEq(usdg.balanceOf(alice), amountOut);
        assertGt(stock.balanceOf(alice), 0, "the unconsumed stock came back");
        _assertRouteEmpty(thin);
    }

    function test_unlock_callback_accepts_only_the_pinned_pool_manager() public {
        usdg.mint(address(route), 1e6);
        vm.expectRevert(abi.encodeWithSelector(UniswapV4StockRouteV1.NotPoolManager.selector, address(this)));
        route.unlockCallback(abi.encode(address(usdg), address(stock), uint256(1e6), alice));
        assertEq(usdg.balanceOf(address(route)), 1e6);
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    /// @dev A stock whose address sorts on the side of USDG this run asks for.
    function _newStock(string memory name_, string memory symbol_) internal returns (ReenteringStock candidate) {
        do {
            candidate = new ReenteringStock(name_, symbol_);
        } while ((address(candidate) < address(usdg)) != _stockIsCurrency0());
    }

    function _newRoute(address usdg_, address stock_, uint24 fee_, int24 tickSpacing_)
        internal
        returns (UniswapV4StockRouteV1)
    {
        return new UniswapV4StockRouteV1(usdg_, stock_, address(poolManager), fee_, tickSpacing_, address(feed));
    }

    /// @dev A second pool of the same pair, with liquidity only within ten spacings of the price.
    function _thinRoute() internal returns (UniswapV4StockRouteV1) {
        PoolKey memory key = _key(address(usdg), address(stock), THIN_FEE, THIN_TICK_SPACING);
        poolManager.initialize(key, _sqrtPriceAtFeed());
        (, int24 tick,,) = IPoolManager(address(poolManager)).getSlot0(key.toId());
        int24 centre = tick / THIN_TICK_SPACING * THIN_TICK_SPACING;
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(centre - 10 * THIN_TICK_SPACING, centre + 10 * THIN_TICK_SPACING, THIN_LIQUIDITY, 0),
            ""
        );
        return _newRoute(address(usdg), address(stock), THIN_FEE, THIN_TICK_SPACING);
    }

    function _key(address usdg_, address stock_, uint24 fee_, int24 tickSpacing_)
        internal
        pure
        returns (PoolKey memory)
    {
        (address currency0, address currency1) = stock_ < usdg_ ? (stock_, usdg_) : (usdg_, stock_);
        return PoolKey(Currency.wrap(currency0), Currency.wrap(currency1), fee_, tickSpacing_, IHooks(address(0)));
    }

    /// @dev The pool price of 230 dollars a share: `currency1` base units per `currency0` base unit,
    ///      as a Q64.96 square root.
    function _sqrtPriceAtFeed() internal pure returns (uint160) {
        (uint256 amount1, uint256 amount0) =
            _stockIsCurrency0() ? (USDG_PER_SHARE, uint256(1e18)) : (uint256(1e18), USDG_PER_SHARE);
        return uint160(FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(amount1, 1 << 192, amount0)));
    }

    function _expectNotInitialized(address usdg_, address stock_, uint24 fee_, int24 tickSpacing_) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4StockRouteV1.PoolNotInitialized.selector,
                PoolId.unwrap(_key(usdg_, stock_, fee_, tickSpacing_).toId())
            )
        );
    }

    function _assertRouteEmpty(UniswapV4StockRouteV1 target) internal view {
        assertEq(usdg.balanceOf(address(target)), 0, "usdg left on the route");
        assertEq(stock.balanceOf(address(target)), 0, "stock left on the route");
    }
}

/// @notice USDG is `currency0`: COIN, NBIS, ORCL, EWY.
contract UniswapV4StockRouteUsdgFirstTest is UniswapV4StockRouteTestBase {
    function _stockIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

/// @notice The stock is `currency0`: CRWV, RKLB.
contract UniswapV4StockRouteStockFirstTest is UniswapV4StockRouteTestBase {
    function _stockIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}
