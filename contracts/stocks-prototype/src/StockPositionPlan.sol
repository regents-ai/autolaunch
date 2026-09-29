// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @dev Geometry prototype only; not auction admission or position custody.
library StockPositionPlan {
    struct Position { int24 lower; int24 upper; uint128 liquidity; }
    struct Plan { Position[3] positions; uint256 remainder0; uint256 remainder1; }
    error UnsupportedOpeningPrice();
    error NoActiveLiquidity();

    function build(uint160 price, uint256 amount0, uint256 amount1) internal pure returns (Plan memory p) {
        int24 spacing = 60;
        int24 minimum = TickMath.minUsableTick(spacing);
        int24 maximum = TickMath.maxUsableTick(spacing);
        int24 tick = TickMath.getTickAtSqrtPrice(price);
        int24 floor = (tick / spacing) * spacing;
        if (tick < 0 && tick % spacing != 0) floor -= spacing;
        // Candidate envelope, not an approved auction-price policy. Reject
        // rather than silently leave unplaceable inventory or change price.
        if (floor <= minimum + spacing || floor >= maximum - spacing) revert UnsupportedOpeningPrice();
        p.remainder0 = amount0;
        p.remainder1 = amount1;
        allocate(p, 0, price, minimum, maximum);
        if (p.positions[0].liquidity == 0) revert NoActiveLiquidity();
        // These inventory positions are strictly outside the opening tick.
        // They must not be reported as active opening liquidity.
        allocate(p, 1, price, floor + spacing, floor + 2 * spacing);
        allocate(p, 2, price, floor - spacing, floor);
    }

    function allocate(Plan memory p, uint256 index, uint160 price, int24 lower, int24 upper) private pure {
        uint160 low = TickMath.getSqrtPriceAtTick(lower);
        uint160 high = TickMath.getSqrtPriceAtTick(upper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(price, low, high, p.remainder0, p.remainder1);
        p.positions[index] = Position(lower, upper, liquidity);
        if (liquidity == 0) return;
        // Match PoolManager's actual deposit rounding (UP), not withdrawal
        // rounding or an approximate decimal/token-price calculation.
        uint256 used0 = price >= high ? 0 : SqrtPriceMath.getAmount0Delta(price > low ? price : low, high, liquidity, true);
        uint256 used1 = price <= low ? 0 : SqrtPriceMath.getAmount1Delta(low, price < high ? price : high, liquidity, true);
        p.remainder0 -= used0;
        p.remainder1 -= used1;
    }
}
