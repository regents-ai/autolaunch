// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IChainlinkAggregatorMinimal} from "autolaunch-stocks/interfaces/IChainlinkAggregatorMinimal.sol";
import {IERC20Views} from "autolaunch-stocks/interfaces/IERC20Views.sol";
import {IUniswapV3PoolMinimal} from "../../src/interfaces/IUniswapV3PoolMinimal.sol";
import {UniswapV3StockRouteV1} from "../../src/routes/UniswapV3StockRouteV1.sol";

/// @dev The pool views the ceremony proves and this suite re-proves on the live chain.
interface IUniswapV3PoolProvenance {
    function factory() external view returns (address);
    function fee() external view returns (uint24);
}

interface IUniswapV3FactoryMinimal {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @notice The production route against Robinhood Chain itself: three live pools in both currency
///         orders (AAPL and SNDK sort USDG first, TSLA sorts the stock first), a real purchase and
///         a real sale through each, and the feed bound refusing a purchase the thin SNDK pool
///         cannot fill near the feed price. Runs only on a fork of Robinhood Chain
///         (`FOUNDRY_PROFILE=fork forge test --fork-url robinhood`); any other chain skips it.
/// @dev The stock tokens are the real upgradeable issuer tokens: the stock is read from each pool,
///      never typed in. USDG is dealt to the route (storage write); the stock for every sale is
///      the stock the preceding purchase delivered, so the tokens' transfer rules are exercised
///      for real on every leg.
contract UniswapV3StockRouteForkTest is Test {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;

    address internal constant AAPL_POOL = 0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D;
    address internal constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address internal constant TSLA_POOL = 0xf4ACdAEEB7022862A763C9B1B885e11191c889E3;
    address internal constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address internal constant SNDK_POOL = 0xA1e1C9519cD5ae47e9A935645E1A7b935b944559;
    address internal constant SNDK_FEED = 0xfb133Fa4B7b385802B693a293606682Df47109A3;

    /// @dev A thousand dollars, the settlement size every pool fills near the feed.
    uint256 internal constant PURCHASE_USDG = 1_000e6;
    /// @dev Fifty thousand dollars, far past what the thin SNDK pool can fill within the bound.
    uint256 internal constant LARGE_PURCHASE_USDG = 50_000e6;

    struct Venue {
        string symbol;
        address pool;
        address feed;
        bool stockIsToken0;
    }

    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.skip(block.chainid != ROBINHOOD_CHAIN_ID);
    }

    function test_every_pool_binds_in_its_own_order_and_quotes_from_its_feed() public {
        Venue[3] memory venues = _venues();
        for (uint256 i; i < 3; ++i) {
            (UniswapV3StockRouteV1 route, address stock) = _route(venues[i]);
            assertEq(route.stockIsToken0(), venues[i].stockIsToken0, venues[i].symbol);
            assertEq(route.stockUnit(), 1e18, "every Robinhood stock has eighteen decimals");
            assertEq(route.feedUnit(), 1e8, "every feed reports eight decimals");
            assertEq(IERC20Views(stock).decimals(), 18);

            uint256 shares = route.quoteExactIn(USDG, stock, PURCHASE_USDG);
            assertGt(shares, 0);
            // A thousand dollars of shares back is a thousand dollars, within two floors at six decimals.
            assertApproxEqAbs(route.quoteExactIn(stock, USDG, shares), PURCHASE_USDG, 2);
            console2.log(venues[i].symbol, "feed price (8 decimals):", uint256(_feedPrice(venues[i].feed)));
            console2.log(venues[i].symbol, "shares for 1,000 USDG:", shares);
        }
    }

    function test_live_purchase_and_sale_of_aapl_land_within_the_feed_bound() public {
        _purchaseThenSell(_venues()[0], 0.02e18);
    }

    function test_live_purchase_and_sale_of_tsla_land_within_the_feed_bound() public {
        _purchaseThenSell(_venues()[1], 0.02e18);
    }

    function test_live_purchase_and_sale_of_sndk_land_within_the_feed_bound() public {
        _purchaseThenSell(_venues()[2], 0.05e18);
    }

    function test_large_purchase_on_the_thin_sndk_pool_is_refused_by_the_feed_bound() public {
        (UniswapV3StockRouteV1 route, address stock) = _route(_venues()[2]);
        deal(USDG, address(route), LARGE_PURCHASE_USDG);

        vm.expectPartialRevert(UniswapV3StockRouteV1.PriceDeviation.selector);
        route.swapExactIn(USDG, stock, LARGE_PURCHASE_USDG, 0, alice);
    }

    /// @dev Buys a thousand dollars of the stock for alice, then sells every share back, checking
    ///      each leg against the feed quote and that the route keeps nothing.
    function _purchaseThenSell(Venue memory venue, uint256 tolerance) internal {
        (UniswapV3StockRouteV1 route, address stock) = _route(venue);

        deal(USDG, address(route), PURCHASE_USDG);
        uint256 quotedShares = route.quoteExactIn(USDG, stock, PURCHASE_USDG);
        uint256 shares = route.swapExactIn(USDG, stock, PURCHASE_USDG, 0, alice);
        assertEq(IERC20(stock).balanceOf(alice), shares, "the purchase lands with alice");
        assertApproxEqRel(shares, quotedShares, tolerance, "purchase off the feed");
        assertEq(IERC20(USDG).balanceOf(alice), 0, "no USDG residue on a full fill");
        _assertRouteEmpty(route, stock);
        console2.log(venue.symbol, "purchase: shares delivered:", shares);
        console2.log(venue.symbol, "purchase: feed quote:", quotedShares);
        console2.log(venue.symbol, "purchase shortfall vs feed, bps:", _shortfallBps(shares, quotedShares));

        vm.prank(alice);
        IERC20(stock).transfer(address(route), shares);
        uint256 quotedUsdg = route.quoteExactIn(stock, USDG, shares);
        uint256 usdg = route.swapExactIn(stock, USDG, shares, 0, alice);
        assertEq(IERC20(USDG).balanceOf(alice), usdg, "the sale lands with alice");
        assertApproxEqRel(usdg, quotedUsdg, tolerance, "sale off the feed");
        assertEq(IERC20(stock).balanceOf(alice), 0, "no stock residue on a full fill");
        _assertRouteEmpty(route, stock);
        console2.log(venue.symbol, "sale: USDG delivered:", usdg);
        console2.log(venue.symbol, "sale: feed quote:", quotedUsdg);
        console2.log(venue.symbol, "sale shortfall vs feed, bps:", _shortfallBps(usdg, quotedUsdg));
    }

    /// @dev Proves the pool the way the ceremony does, reads the stock from it, and deploys the route.
    function _route(Venue memory venue) internal returns (UniswapV3StockRouteV1 route, address stock) {
        address token0 = IUniswapV3PoolMinimal(venue.pool).token0();
        address token1 = IUniswapV3PoolMinimal(venue.pool).token1();
        assertTrue(token0 == USDG || token1 == USDG, "the pool holds USDG");
        stock = token0 == USDG ? token1 : token0;
        assertEq(IUniswapV3PoolProvenance(venue.pool).factory(), V3_FACTORY, "not a Uniswap v3 pool");
        uint24 fee = IUniswapV3PoolProvenance(venue.pool).fee();
        assertEq(
            IUniswapV3FactoryMinimal(V3_FACTORY).getPool(token0, token1, fee), venue.pool, "not the factory's pool"
        );
        route = new UniswapV3StockRouteV1(USDG, stock, venue.pool, venue.feed);
    }

    function _assertRouteEmpty(UniswapV3StockRouteV1 route, address stock) internal view {
        assertEq(IERC20(USDG).balanceOf(address(route)), 0, "USDG left on the route");
        assertEq(IERC20(stock).balanceOf(address(route)), 0, "stock left on the route");
    }

    function _feedPrice(address feed) internal view returns (int256 answer) {
        (, answer,,,) = IChainlinkAggregatorMinimal(feed).latestRoundData();
    }

    /// @dev Basis points delivered below the feed quote; zero when the execution beat the feed.
    function _shortfallBps(uint256 delivered, uint256 quoted) internal pure returns (uint256) {
        return delivered >= quoted ? 0 : (quoted - delivered) * 10_000 / quoted;
    }

    /// @dev The three live venues, from `venue-discovery-2026-09-23.md`: the deepest pool (AAPL),
    ///      the deep pool with the stock as token0 (TSLA) and a thin pool (SNDK).
    function _venues() internal pure returns (Venue[3] memory list) {
        list[0] = Venue("AAPL", AAPL_POOL, AAPL_FEED, false);
        list[1] = Venue("TSLA", TSLA_POOL, TSLA_FEED, true);
        list[2] = Venue("SNDK", SNDK_POOL, SNDK_FEED, false);
    }
}
