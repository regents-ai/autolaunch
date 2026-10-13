// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IChainlinkAggregatorMinimal} from "autolaunch-stocks/interfaces/IChainlinkAggregatorMinimal.sol";
import {IERC20Views} from "autolaunch-stocks/interfaces/IERC20Views.sol";
import {UniswapV4StockRouteV1} from "../../src/routes/UniswapV4StockRouteV1.sol";

/// @notice The v4 route against Robinhood Chain itself: two live hookless pools in both currency
///         orders (COIN sorts USDG first, CRWV sorts the stock first), a real purchase and a real
///         sale through each, and a purchase the thin CRWV pool cannot fill near the feed price,
///         refused by a 95%-of-quote minimum and executed at a zero minimum. Runs only on a fork of
///         Robinhood Chain (`FOUNDRY_PROFILE=fork forge test --fork-url robinhood`); any other chain
///         skips it.
/// @dev The stock tokens are the real upgradeable issuer tokens. Each pool is named by the id its
///      liquidity sits under on the live pool manager, and the route must derive that same id from
///      the stock, fee and tick spacing alone. USDG is dealt to the route (storage write); the stock
///      for every sale is the stock the preceding purchase delivered, so the tokens' transfer rules
///      are exercised for real on every leg.
contract UniswapV4StockRouteForkTest is Test {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    address internal constant COIN = 0x6330D8C3178a418788dF01a47479c0ce7CCF450b;
    address internal constant COIN_FEED = 0xA3a468A452940B7D6b69991207B508c609a98Ef2;
    bytes32 internal constant COIN_POOL_ID = 0x007a13fa152f6dc383cad20a8eaab4e1e2538b606936eae2a424f8aa47d6db31;
    address internal constant CRWV = 0x5f10A1C971B69e47e059e1dC91901B59b3fB49C3;
    address internal constant CRWV_FEED = 0xe1b3aABCAFAd1c94708dc1367dcfF8Aa4407487C;
    bytes32 internal constant CRWV_POOL_ID = 0x237014478f7ef98afbe7412ac35b6a3f96b8fb111de48b7c4dbf49dba4bd9c4b;

    /// @dev A thousand dollars, the settlement size the deep COIN pool fills near the feed; two
    ///      hundred for the thin CRWV pool.
    uint256 internal constant PURCHASE_USDG = 1_000e6;
    uint256 internal constant THIN_PURCHASE_USDG = 200e6;
    /// @dev Fifty thousand dollars, more than the whole CRWV pool holds.
    uint256 internal constant LARGE_PURCHASE_USDG = 50_000e6;

    struct Venue {
        string symbol;
        address stock;
        address feed;
        uint24 fee;
        int24 tickSpacing;
        bytes32 poolId;
        bool stockIsCurrency0;
    }

    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.skip(block.chainid != ROBINHOOD_CHAIN_ID);
    }

    function test_every_pool_binds_in_its_own_order_and_quotes_from_its_feed() public {
        Venue[2] memory venues = _venues();
        for (uint256 i; i < 2; ++i) {
            UniswapV4StockRouteV1 route = _route(venues[i]);
            address stock = venues[i].stock;
            assertEq(route.poolId(), venues[i].poolId, "the route derives the live pool's id");
            assertEq(route.stockIsCurrency0(), venues[i].stockIsCurrency0, venues[i].symbol);
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

    function test_live_purchase_and_sale_of_coin_land_near_the_feed_quote() public {
        _purchaseThenSell(_venues()[0], PURCHASE_USDG, 0.03e18);
    }

    function test_live_purchase_and_sale_of_crwv_land_near_the_feed_quote() public {
        _purchaseThenSell(_venues()[1], THIN_PURCHASE_USDG, 0.05e18);
    }

    function test_large_purchase_on_the_thin_crwv_pool_is_refused_by_a_95_percent_minimum() public {
        Venue memory venue = _venues()[1];
        UniswapV4StockRouteV1 route = _route(venue);
        deal(USDG, address(route), LARGE_PURCHASE_USDG);
        uint256 minimum = route.quoteExactIn(USDG, venue.stock, LARGE_PURCHASE_USDG) * 95 / 100;

        vm.expectPartialRevert(UniswapV4StockRouteV1.InsufficientOutput.selector);
        route.swapExactIn(USDG, venue.stock, LARGE_PURCHASE_USDG, minimum, alice);
    }

    function test_large_purchase_on_the_thin_crwv_pool_executes_at_a_zero_minimum() public {
        Venue memory venue = _venues()[1];
        UniswapV4StockRouteV1 route = _route(venue);
        deal(USDG, address(route), LARGE_PURCHASE_USDG);
        uint256 quoted = route.quoteExactIn(USDG, venue.stock, LARGE_PURCHASE_USDG);

        uint256 shares = route.swapExactIn(USDG, venue.stock, LARGE_PURCHASE_USDG, 0, alice);

        assertEq(IERC20(venue.stock).balanceOf(alice), shares, "the purchase lands with alice");
        assertLt(shares, quoted * 95 / 100, "the thin pool fills a large purchase well under the feed");
        _assertRouteEmpty(route, venue.stock);
        console2.log("CRWV large purchase: shares delivered:", shares);
        console2.log("CRWV large purchase: feed quote:", quoted);
        console2.log("CRWV large purchase shortfall vs feed, bps:", _shortfallBps(shares, quoted));
        console2.log("CRWV large purchase: USDG returned unconsumed:", IERC20(USDG).balanceOf(alice));
    }

    /// @dev Buys the stock for alice, then sells every share back, checking each leg against the
    ///      feed quote and that the route keeps nothing.
    function _purchaseThenSell(Venue memory venue, uint256 purchase, uint256 tolerance) internal {
        UniswapV4StockRouteV1 route = _route(venue);
        address stock = venue.stock;

        deal(USDG, address(route), purchase);
        uint256 quotedShares = route.quoteExactIn(USDG, stock, purchase);
        uint256 shares = route.swapExactIn(USDG, stock, purchase, 0, alice);
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

    function _route(Venue memory venue) internal returns (UniswapV4StockRouteV1) {
        return new UniswapV4StockRouteV1(USDG, venue.stock, POOL_MANAGER, venue.fee, venue.tickSpacing, venue.feed);
    }

    function _assertRouteEmpty(UniswapV4StockRouteV1 route, address stock) internal view {
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

    /// @dev The two live venues, read from the pool manager's `Initialize` events on 13 October
    ///      2026: the deepest v4 stock pool (COIN, 1% fee) and a thin pool with the stock as
    ///      currency0 (CRWV, 0.9% fee).
    function _venues() internal pure returns (Venue[2] memory list) {
        list[0] = Venue("COIN", COIN, COIN_FEED, 10_000, 200, COIN_POOL_ID, false);
        list[1] = Venue("CRWV", CRWV, CRWV_FEED, 9_000, 90, CRWV_POOL_ID, true);
    }
}
