// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StocksBindings} from "../../src/StocksBindings.sol";
import {FixtureStockToken} from "../../src/fixtures/FixtureStockToken.sol";
import {AerodromeStockRouteV1} from "../../src/routes/AerodromeStockRouteV1.sol";

/// @notice The production route against Base itself: every admitted pool and feed binds, and a
///         real swap through the live AAPLc pool lands within the feed bound. Runs only on a fork
///         of Base mainnet (`--fork-url` to a Base RPC); the lab fork skips it.
/// @dev The `0xb2…` stock tokens are `0xef` precompiles the EVM cannot run, so this suite installs
///      `FixtureStockToken` at the stock address and refills the pool's stock balance. Pool
///      liquidity, prices and USDC are real; the stock token's transfer policy is not exercised.
contract AerodromeStockRouteForkTest is Test {
    uint256 internal constant BASE_CHAIN_ID = 8453;

    address internal constant AAPLC = 0xb200000000000000000000C2e324d24d7eEcd1fb;
    address internal constant AAPLC_POOL = 0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0;
    address internal constant AAPLC_FEED = 0x787f13dEa48Db0897CbCDD985de77809D837F988;

    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.skip(block.chainid != BASE_CHAIN_ID);
    }

    function test_every_admitted_pool_and_feed_binds_and_quotes() public {
        (address[10] memory stocks, address[10] memory pools, address[10] memory feeds) = _admitted();
        for (uint256 i = 0; i < 10; ++i) {
            _installFixtureToken(stocks[i]);
            AerodromeStockRouteV1 route = new AerodromeStockRouteV1(stocks[i], pools[i], feeds[i]);
            assertEq(route.stockUnit(), 1e8);
            assertEq(route.feedUnit(), 1e8);
            uint256 shares = route.quoteExactIn(StocksBindings.USDC, stocks[i], 1_000e6);
            assertGt(shares, 0);
            // A thousand dollars of shares back is a thousand dollars, within two floors at eight decimals.
            assertApproxEqAbs(route.quoteExactIn(stocks[i], StocksBindings.USDC, shares), 1_000e6, 10);
        }
    }

    function test_live_swap_usdc_to_stock_lands_within_the_feed_bound() public {
        AerodromeStockRouteV1 route = _aaplRoute();
        deal(StocksBindings.USDC, address(route), 1_000e6);

        uint256 quoted = route.quoteExactIn(StocksBindings.USDC, AAPLC, 1_000e6);
        uint256 amountOut = route.swapExactIn(StocksBindings.USDC, AAPLC, 1_000e6, 0, alice);

        assertEq(IERC20(AAPLC).balanceOf(alice), amountOut);
        assertApproxEqRel(amountOut, quoted, 0.01e18, "pool price off the feed by over 1%");
        assertEq(IERC20(StocksBindings.USDC).balanceOf(alice), 0, "no USDC residue expected on a full fill");
        _assertRouteEmpty(route);
    }

    function test_live_swap_stock_to_usdc_lands_within_the_feed_bound() public {
        AerodromeStockRouteV1 route = _aaplRoute();
        FixtureStockToken(AAPLC).mint(address(route), 1e8);

        uint256 quoted = route.quoteExactIn(AAPLC, StocksBindings.USDC, 1e8);
        uint256 amountOut = route.swapExactIn(AAPLC, StocksBindings.USDC, 1e8, 0, alice);

        assertEq(IERC20(StocksBindings.USDC).balanceOf(alice), amountOut);
        assertApproxEqRel(amountOut, quoted, 0.01e18, "pool price off the feed by over 1%");
        assertEq(IERC20(AAPLC).balanceOf(alice), 0, "no stock residue expected on a full fill");
        _assertRouteEmpty(route);
    }

    function test_live_swap_beyond_pool_depth_is_refused_by_the_feed_bound() public {
        AerodromeStockRouteV1 route = _aaplRoute();
        deal(StocksBindings.USDC, address(route), 20_000_000e6);

        vm.expectPartialRevert(AerodromeStockRouteV1.PriceDeviation.selector);
        route.swapExactIn(StocksBindings.USDC, AAPLC, 20_000_000e6, 0, alice);
    }

    function _aaplRoute() internal returns (AerodromeStockRouteV1 route) {
        _installFixtureToken(AAPLC);
        route = new AerodromeStockRouteV1(AAPLC, AAPLC_POOL, AAPLC_FEED);
        // The pool's real stock balance vanished with the precompile; give it depth to pay out of.
        FixtureStockToken(AAPLC).mint(AAPLC_POOL, 1_000_000e8);
    }

    function _installFixtureToken(address stock) internal {
        vm.etch(stock, type(FixtureStockToken).runtimeCode);
    }

    function _assertRouteEmpty(AerodromeStockRouteV1 route) internal view {
        assertEq(IERC20(StocksBindings.USDC).balanceOf(address(route)), 0, "usdc left on the route");
        assertEq(IERC20(AAPLC).balanceOf(address(route)), 0, "stock left on the route");
    }

    /// @dev The admitted Base stocks with a Chainlink feed and an Aerodrome Slipstream USDC pool,
    ///      in README order.
    function _admitted()
        internal
        pure
        returns (address[10] memory stocks, address[10] memory pools, address[10] memory feeds)
    {
        stocks = [
            0xb200000000000000000000C2e324d24d7eEcd1fb,
            0xb200000000000000000000d9192b6B456483C2E8,
            0xb2000000000000000000002D0BA3164cc74f58B7,
            0xb2000000000000000000008bC8786B856E61707C,
            0xB200000000000000000000Ab99cFa739E253872B,
            0xb2000000000000000000004884b426556b92883d,
            0xb20000000000000000000078ee7ce2fE4908108C,
            0xb200000000000000000000397293Cb8cda9a10c5,
            0xb2000000000000000000007b9fcbd005511aCBd5,
            0xb2000000000000000000001e800a7f5189430cD0
        ];
        pools = [
            0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0,
            0xd03Bc8C7F2FAedCe2aac81bF0444AEA08Ea06E9b,
            0xB1987CAD1682841b4b641d50E520777eC5Ab5542,
            0xEAF57753BC382E0324a1D43F72E7027705a2273E,
            0x7103eB3c9590d1281f7dc03b2A9EE27C39dF5D54,
            0x8b27f626ab668197000BC722A1012022CAeD10E2,
            0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9,
            0x5A8236f575471e7BfCA2C8462a200c28f737246E,
            0x0bf58fe0FAc935Ac69595c19B12Ba0d75E3F8c0E,
            0x469337fDcc5E8f38e2E4B670B04F57865D13a7BB
        ];
        feeds = [
            0x787f13dEa48Db0897CbCDD985de77809D837F988,
            0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295,
            0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2,
            0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D,
            0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c,
            0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a,
            0x04689a41629776563E6822F76f2e57D148d28513,
            0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA,
            0x6A634B235903C4ad6376892180d6fF8612e3Fa68,
            0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4
        ];
    }
}
