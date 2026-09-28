// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {RegentLBPStrategyV2} from "../../src/strategy/RegentLBPStrategyV2.sol";
import {ConstantsLib} from "continuous-clearing-auction/libraries/ConstantsLib.sol";
import {MaxBidPriceLib} from "continuous-clearing-auction/libraries/MaxBidPriceLib.sol";
import {PositionPlanner} from "liquidity-launcher/src/libraries/PositionPlanner.sol";
import {TokenPricing} from "liquidity-launcher/src/libraries/TokenPricing.sol";
import {CurrencyAmounts, Position, PositionDefinition} from "liquidity-launcher/src/types/PositionPlannerTypes.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StrategyFixture} from "./StrategyFixture.sol";

/// @notice `C3-I5`, price side: every price a graduated launch can open its pool at converts into a
///         valid v4 price in both currency orderings, and no graduated distribution can plan a
///         zero-liquidity position.
/// @dev The pool opens at the raise over the whole sale allocation. A graduated raise is at least the
///      sale allocation at the launch's floor and at most the sale allocation at the highest price the
///      auction admits a bid at, so every opening price lies between the lowest floor a launch may
///      choose and the greatest on-grid multiple of that floor's tick beneath the pinned library's
///      structural ceiling. Both ends are derived here, never transcribed.
contract RegentLBPStrategyPricingTest is StrategyFixture {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q96 = 1 << 96;

    function setUp() public {
        _deployC3();
    }

    /// @notice The admitted price interval's ends, and the prices beside them, convert in both
    ///         orderings, and the largest admitted raise is the sale allocation at the highest
    ///         admitted price.
    function test_STR_014_ReachablePriceBoundariesConvertInBothOrderings() public view {
        uint256 structuralMax = MaxBidPriceLib.maxBidPrice(uint128(AUCTION_ALLOCATION));
        uint256 lowestFloor = _lowestFloor();
        assertEq(strategy.bidTickSpacingFor(lowestFloor), lowestFloor / 100, "the lowest floor is admitted");

        uint256 reachableMax = _reachableMaxPrice(DEFAULT_TICK_Q96);
        assertEq(
            strategy.maxReachableRaiseFor(DEFAULT_TICK_Q96),
            FullMath.mulDiv(AUCTION_ALLOCATION, reachableMax, Q96),
            "the admitted maximum raise is the sale allocation at the highest admitted price"
        );
        assertGt(reachableMax, DEFAULT_FLOOR_Q96, "the interval is non-degenerate");

        uint256[7] memory boundaries = [
            lowestFloor,
            lowestFloor + lowestFloor / 100,
            DEFAULT_FLOOR_Q96,
            Q96,
            reachableMax - DEFAULT_TICK_Q96,
            reachableMax,
            structuralMax
        ];

        for (uint256 i; i < boundaries.length; ++i) {
            _assertConvertsInBothOrderings(boundaries[i]);
        }
    }

    /// @notice Every admitted opening price converts inside the v4 tick range in both orderings, and
    ///         the two orderings describe the same economics.
    function testFuzz_STR_014_EveryReachableFinalPriceConvertsInsideTheTickRange(uint256 priceQ96) public view {
        priceQ96 = bound(priceQ96, _lowestFloor(), MaxBidPriceLib.maxBidPrice(uint128(AUCTION_ALLOCATION)));
        _assertConvertsInBothOrderings(priceQ96);
    }

    /// @notice No graduated distribution plans a zero-liquidity position, in either currency ordering.
    /// @dev The opening price is the raise over the sale allocation, so the raise at an opening price
    ///      is the sale allocation at that price. The fuzz walks every admitted price and drives the
    ///      pinned `PositionPlanner` with that raise and the fixed 15% reserve.
    function testFuzz_STR_014_GraduatedDistributionNeverPlansZeroLiquidity(uint256 priceQ96) public view {
        priceQ96 = bound(priceQ96, _lowestFloor(), MaxBidPriceLib.maxBidPrice(uint128(AUCTION_ALLOCATION)));
        uint256 raised = FullMath.mulDiv(AUCTION_ALLOCATION, priceQ96, Q96);

        _assertNonZeroFullRangePosition(priceQ96, raised, true);
        _assertNonZeroFullRangePosition(priceQ96, raised, false);
    }

    /// @notice Two real launches whose only difference is which side of REGENT their SUBJECT sorts on
    ///         reach the same final price, open reciprocal pools, and both carry real liquidity.
    function test_STR_014_BothCurrencyOrderingsPreservePriceRelationships() public {
        Launch memory low = _newLaunch(SUBJECT_LOW, 1, FLOOR_RAISE);
        Launch memory high = _newLaunch(SUBJECT_HIGH, 2, FLOOR_RAISE);

        _bidToGraduation(low, FLOOR_RAISE);
        _rollToStart(high);
        _bid(high, bidder, FLOOR_RAISE, _bidPrice(10));
        _rollToMigration(high);

        strategy.migrate(address(low.auction));
        strategy.migrate(address(high.auction));

        RegentLBPStrategyV2.Distribution memory dLow = strategy.distribution(address(low.auction));
        RegentLBPStrategyV2.Distribution memory dHigh = strategy.distribution(address(high.auction));

        assertEq(
            low.auction.lbpInitializationParams().currencyRaised,
            high.auction.lbpInitializationParams().currencyRaised,
            "the two identical auctions raised the same amount"
        );

        assertTrue(SUBJECT_LOW < BaseBindings.REGENT, "REGENT is currency1 for the low launch");
        assertTrue(BaseBindings.REGENT < SUBJECT_HIGH, "REGENT is currency0 for the high launch");

        // currency1/currency0 in one ordering is the reciprocal of the other, so the two square-root
        // prices multiply back to Q96 squared.
        assertApproxEqRel(
            uint256(dLow.finalSqrtPriceX96) * uint256(dHigh.finalSqrtPriceX96),
            Q96 * Q96,
            1e9,
            "the two orderings describe the same economics"
        );

        (uint160 lowPrice,,,) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(dLow.poolId);
        (uint160 highPrice,,,) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(dHigh.poolId);
        assertEq(lowPrice, dLow.finalSqrtPriceX96, "the low pool opened at its recorded price");
        assertEq(highPrice, dHigh.finalSqrtPriceX96, "the high pool opened at its recorded price");

        assertGt(positionManager.getPositionLiquidity(dLow.lpTokenId), 0, "the low ordering minted real liquidity");
        assertGt(positionManager.getPositionLiquidity(dHigh.lpTokenId), 0, "the high ordering minted real liquidity");
        assertGt(dLow.lpRegentUsed, 0, "and consumed REGENT");
        assertGt(dHigh.lpRegentUsed, 0, "and consumed REGENT");
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    /// @dev The lowest floor a launch may choose: the pinned CCA's minimum floor, rounded up to a
    ///      whole number of bid ticks.
    function _lowestFloor() internal view returns (uint256) {
        uint256 divisor = strategy.BID_TICK_DIVISOR();
        return (ConstantsLib.MIN_FLOOR_PRICE + divisor - 1) / divisor * divisor;
    }

    /// @dev The highest price an auction with this bid tick can settle on: the greatest multiple of
    ///      the tick at or below the pinned library's structural ceiling.
    function _reachableMaxPrice(uint256 tickSpacing) internal pure returns (uint256) {
        uint256 structuralMax = MaxBidPriceLib.maxBidPrice(uint128(AUCTION_ALLOCATION));
        return structuralMax - (structuralMax % tickSpacing);
    }

    function _sqrtPrice(uint256 priceQ96, bool regentIsCurrency0) internal pure returns (uint160) {
        return TokenPricing.convertToSqrtPriceX96(TokenPricing.convertToPriceX192(priceQ96, regentIsCurrency0));
    }

    function _assertConvertsInBothOrderings(uint256 priceQ96) internal view {
        uint160 asCurrency1 = _sqrtPrice(priceQ96, false);
        uint160 asCurrency0 = _sqrtPrice(priceQ96, true);

        assertGe(asCurrency1, TickMath.MIN_SQRT_PRICE, "REGENT as currency1: at or above the minimum v4 price");
        assertLe(asCurrency1, TickMath.MAX_SQRT_PRICE, "REGENT as currency1: at or below the maximum v4 price");
        assertGe(asCurrency0, TickMath.MIN_SQRT_PRICE, "REGENT as currency0: at or above the minimum v4 price");
        assertLe(asCurrency0, TickMath.MAX_SQRT_PRICE, "REGENT as currency0: at or below the maximum v4 price");

        // Both prices sit strictly inside the usable tick range the full-range position spans.
        int24 lower = TickMath.minUsableTick(60);
        int24 upper = TickMath.maxUsableTick(60);
        assertGt(asCurrency1, TickMath.getSqrtPriceAtTick(lower), "REGENT as currency1: above the full-range floor");
        assertLt(asCurrency1, TickMath.getSqrtPriceAtTick(upper), "REGENT as currency1: below the full-range ceiling");
        assertGt(asCurrency0, TickMath.getSqrtPriceAtTick(lower), "REGENT as currency0: above the full-range floor");
        assertLt(asCurrency0, TickMath.getSqrtPriceAtTick(upper), "REGENT as currency0: below the full-range ceiling");

        assertApproxEqRel(
            uint256(asCurrency1) * uint256(asCurrency0), Q96 * Q96, 1e9, "the two orderings are reciprocal"
        );
    }

    function _assertNonZeroFullRangePosition(uint256 priceQ96, uint256 raised, bool regentIsCurrency0) internal view {
        uint160 sqrtPriceX96 = _sqrtPrice(priceQ96, regentIsCurrency0);
        uint128 regentBudget = uint128(raised);
        uint128 reserve = uint128(RESERVE_ALLOCATION);

        (Position[] memory positions,) = PositionPlanner.resolve(
            new PositionDefinition[](0),
            sqrtPriceX96,
            60,
            CurrencyAmounts({
                amount0: regentIsCurrency0 ? regentBudget : reserve, amount1: regentIsCurrency0 ? reserve : regentBudget
            }),
            BaseBindings.DEAD_ADDRESS
        );

        assertEq(positions.length, 1, "exactly one full-range position is planned");
        assertGt(positions[0].liquidity, 0, "and it is never zero-liquidity");
        assertEq(positions[0].recipient, BaseBindings.DEAD_ADDRESS, "and it is always dead-owned");
        assertEq(positions[0].tickLower, TickMath.minUsableTick(60), "full-range lower tick");
        assertEq(positions[0].tickUpper, TickMath.maxUsableTick(60), "full-range upper tick");
        assertTrue(positions[0].amount0 > 0 || positions[0].amount1 > 0, "and it consumes something");
    }
}
