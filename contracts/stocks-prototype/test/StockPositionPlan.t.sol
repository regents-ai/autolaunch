// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StockPositionPlan} from "../src/StockPositionPlan.sol";
import {FixtureToken} from "./FixtureToken.sol";

contract StockPositionPlanTest is Test {
    using StateLibrary for IPoolManager;
    uint160 private nextTokenAddress = 0x100000;
    event Geometry(int24 tick, bool newIs0, uint8 stockDecimals, uint256 newDust, uint256 stockDust, uint128 activeLiquidity);

    function plan(uint160 price, uint256 amount0, uint256 amount1) external pure returns (StockPositionPlan.Plan memory) {
        return StockPositionPlan.build(price, amount0, amount1);
    }

    // Invariant: the reserve and all provided net STOCK enter actual native
    // positions except measured rounding dust, without resetting opening price.
    function test_positions_account_for_reserve_stock_and_opening_price() public {
        int24[3] memory ticks = [int24(-60000), int24(0), int24(60000)];
        for (uint256 t; t < ticks.length; ++t) {
            for (uint256 order; order < 2; ++order) {
                for (uint256 precision; precision < 2; ++precision) {
                    geometry(ticks[t], order == 0, precision == 0 ? 6 : 18);
                }
            }
        }
    }

    // Boundary proof: this particular three-position plan cannot silently
    // accept a price without room for its out-of-range inventory positions.
    function test_outer_tick_boundaries_fail_closed() public {
        vm.expectRevert(StockPositionPlan.UnsupportedOpeningPrice.selector);
        this.plan(TickMath.getSqrtPriceAtTick(887200), 1e24, 1e24);
        vm.expectRevert(StockPositionPlan.UnsupportedOpeningPrice.selector);
        this.plan(TickMath.getSqrtPriceAtTick(-887200), 1e24, 1e24);
    }

    function geometry(int24 tick, bool newIs0, uint8 stockDecimals) internal {
        IPoolManager manager = new PoolManager(address(this));
        PoolModifyLiquidityTest depositor = new PoolModifyLiquidityTest(manager);
        FixtureToken lowImplementation = new FixtureToken("LOW", newIs0 ? 18 : stockDecimals);
        FixtureToken highImplementation = new FixtureToken("HIGH", newIs0 ? stockDecimals : 18);
        FixtureToken low = FixtureToken(address(nextTokenAddress++));
        FixtureToken high = FixtureToken(address(nextTokenAddress++));
        vm.etch(address(low), address(lowImplementation).code);
        vm.etch(address(high), address(highImplementation).code);
        FixtureToken newToken = newIs0 ? low : high;
        FixtureToken stock = newIs0 ? high : low;
        assertEq(newToken.decimals(), 18);
        assertEq(stock.decimals(), stockDecimals);
        uint256 newReserve = 20_000_000_000e18;
        uint256 netStock = 1_000_000 * 10 ** uint256(stockDecimals);
        uint256 amount0 = newIs0 ? newReserve : netStock;
        uint256 amount1 = newIs0 ? netStock : newReserve;
        uint160 price = TickMath.getSqrtPriceAtTick(tick);
        PoolKey memory key = PoolKey(Currency.wrap(address(low)), Currency.wrap(address(high)), 3000, 60, IHooks(address(0)));
        manager.initialize(key, price);
        newToken.mint(address(this), newReserve);
        stock.mint(address(this), netStock);
        low.approve(address(depositor), amount0);
        high.approve(address(depositor), amount1);
        StockPositionPlan.Plan memory p = StockPositionPlan.build(price, amount0, amount1);
        assertGt(p.positions[0].liquidity, 0, "usable opening liquidity missing");
        uint256 used0;
        uint256 used1;
        for (uint256 i; i < p.positions.length; ++i) {
            StockPositionPlan.Position memory position = p.positions[i];
            if (position.liquidity == 0) continue;
            BalanceDelta delta = depositor.modifyLiquidity(key,
                ModifyLiquidityParams(position.lower, position.upper, int256(uint256(position.liquidity)), bytes32(i)), "");
            used0 += uint256(-int256(delta.amount0()));
            used1 += uint256(-int256(delta.amount1()));
            (uint128 actual,,) = manager.getPositionInfo(key.toId(), address(depositor), position.lower, position.upper, bytes32(i));
            assertEq(actual, position.liquidity);
        }
        assertEq(used0 + p.remainder0, amount0);
        assertEq(used1 + p.remainder1, amount1);
        assertEq(low.balanceOf(address(this)), p.remainder0);
        assertEq(high.balanceOf(address(this)), p.remainder1);
        (uint160 current,,,) = manager.getSlot0(key.toId());
        assertEq(current, price);
        uint256 newDust = newIs0 ? p.remainder0 : p.remainder1;
        uint256 stockDust = newIs0 ? p.remainder1 : p.remainder0;
        // A diagnostic ceiling only, not an approved production dust policy.
        assertLt(newDust, newReserve / 1_000_000);
        assertLt(stockDust, netStock / 1_000_000);
        emit Geometry(tick, newIs0, stockDecimals, newDust, stockDust, p.positions[0].liquidity);
    }
}
