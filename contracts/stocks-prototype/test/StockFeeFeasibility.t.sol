// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {AfterSwapStockCandidate} from "../src/AfterSwapStockCandidate.sol";
import {FixtureToken} from "./FixtureToken.sol";

contract StockFeeFeasibilityTest is Test {
    struct Market {
        PoolManager manager;
        PoolSwapTest router;
        FixtureToken stock;
        FixtureToken newToken;
        AfterSwapStockCandidate hook;
        PoolKey key;
    }

    function market(bool stockIs0) internal returns (Market memory m) {
        m.manager = new PoolManager(address(this));
        FixtureToken a = new FixtureToken("A", 18);
        FixtureToken b = new FixtureToken("B", 18);
        (FixtureToken low, FixtureToken high) = address(a) < address(b) ? (a, b) : (b, a);
        m.stock = stockIs0 ? low : high;
        m.newToken = stockIs0 ? high : low;
        m.router = new PoolSwapTest(m.manager);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(m.manager);
        address hookAddress = address(uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));
        AfterSwapStockCandidate implementation = new AfterSwapStockCandidate(m.manager, address(m.stock));
        vm.etch(hookAddress, address(implementation).code);
        m.hook = AfterSwapStockCandidate(hookAddress);
        m.key = PoolKey(Currency.wrap(address(low)), Currency.wrap(address(high)), 3000, 60, IHooks(hookAddress));
        m.manager.initialize(m.key, uint160(1 << 96));
        a.mint(address(this), 1e36);
        b.mint(address(this), 1e36);
        a.approve(address(lp), type(uint256).max);
        b.approve(address(lp), type(uint256).max);
        a.approve(address(m.router), type(uint256).max);
        b.approve(address(m.router), type(uint256).max);
        lp.modifyLiquidity(m.key, ModifyLiquidityParams(-600, 600, 1e24, bytes32(0)), "");
    }

    // Invariant: when STOCK is unspecified, a realized 1% STOCK charge can
    // settle through native v4 return-delta accounting with no NEW fee taken.
    function test_unspecified_stock_charge_survives_both_orders_and_routers() public {
        for (uint256 order; order < 2; ++order) {
            for (uint256 direction; direction < 2; ++direction) {
                bool stockIs0 = order == 0;
                bool buyNew = direction == 0;
                Market memory m = market(stockIs0);
                bool zeroForOne = buyNew == stockIs0;
                bool exactInput = !buyNew;
                SwapParams memory p = SwapParams(zeroForOne, exactInput ? -int256(1e18) : int256(1e18),
                    zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
                m.router.swap(m.key, p, PoolSwapTest.TestSettings(false, false), "");
                assertGt(m.hook.realizedStock(), 0);
                uint256 charged = m.stock.balanceOf(address(m.hook));
                assertEq(charged, m.hook.realizedStock() / 100);
                assertEq(m.newToken.balanceOf(address(m.hook)), 0);
                PoolSwapTest alternative = new PoolSwapTest(m.manager);
                m.stock.approve(address(alternative), type(uint256).max);
                m.newToken.approve(address(alternative), type(uint256).max);
                alternative.swap(m.key, p, PoolSwapTest.TestSettings(false, false), "");
                assertEq(m.stock.balanceOf(address(m.hook)) - charged, m.hook.realizedStock() / 100);
            }
        }
    }

    // Counterexample, NOT a passed product requirement: afterSwap's scalar
    // return is the unspecified currency. Taking specified STOCK instead
    // leaves flash-accounting debt and the official swap must revert.
    function test_counterexample_specified_stock_cannot_use_after_swap_only() public {
        for (uint256 order; order < 2; ++order) {
            for (uint256 direction; direction < 2; ++direction) {
                bool stockIs0 = order == 0;
                bool buyNew = direction == 0;
                Market memory m = market(stockIs0);
                bool zeroForOne = buyNew == stockIs0;
                SwapParams memory p = SwapParams(zeroForOne, buyNew ? -int256(1e18) : int256(1e18),
                    zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
                vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
                m.router.swap(m.key, p, PoolSwapTest.TestSettings(false, false), "");
                assertEq(m.stock.balanceOf(address(m.hook)), 0);
            }
        }
    }
}
