// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
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

/// @notice `C3-I5`, price side: the complete reachable fixed-supply CCA price interval converts into
///         a valid v4 price in both currency orderings, and no graduated distribution can plan a
///         zero-liquidity position.
/// @dev The interval is the auction's own: from the frozen Q96 floor up to
///      `MaxBidPriceLib.maxBidPrice(10_000_000_000e18)`, which is the highest Q96 price the fixed
///      ten-billion-SUBJECT auction will accept a bid at and therefore the highest price its final
///      checkpoint can ever settle on.
contract RegentLBPStrategyPricingTest is StrategyFixture {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q96 = 1 << 96;

    function setUp() public {
        _deployC3();
    }

    /// @notice The reachable interval and the admitted maximum raise are derived from the pinned
    ///         library, never transcribed.
    function test_STR_014_ReachablePriceBoundariesConvertInBothOrderings() public view {
        uint256 maxBidPrice = MaxBidPriceLib.maxBidPrice(uint128(AUCTION_ALLOCATION));
        assertEq(
            strategy.MAX_REACHABLE_RAISE(),
            FullMath.mulDiv(AUCTION_ALLOCATION, maxBidPrice, Q96),
            "the admitted maximum raise is the pinned maximum bid price over the fixed supply"
        );
        assertGt(maxBidPrice, strategy.FLOOR_PRICE_Q96(), "the interval is non-degenerate");
        assertGe(
            maxBidPrice,
            strategy.FLOOR_PRICE_Q96() + strategy.BID_TICK_Q96(),
            "the pinned CCA constructor requires at least one tick above the floor"
        );

        uint256[5] memory boundaries = [
            strategy.FLOOR_PRICE_Q96(),
            strategy.FLOOR_PRICE_Q96() + strategy.BID_TICK_Q96(),
            Q96,
            maxBidPrice - strategy.BID_TICK_Q96(),
            maxBidPrice
        ];

        for (uint256 i; i < boundaries.length; ++i) {
            _assertConvertsInBothOrderings(boundaries[i]);
        }
    }

    /// @notice Every reachable final price converts inside the v4 tick range in both orderings, and
    ///         the two orderings describe the same economics.
    function testFuzz_STR_014_EveryReachableFinalPriceConvertsInsideTheTickRange(uint256 priceQ96) public view {
        priceQ96 = bound(priceQ96, strategy.FLOOR_PRICE_Q96(), MaxBidPriceLib.maxBidPrice(uint128(AUCTION_ALLOCATION)));
        _assertConvertsInBothOrderings(priceQ96);
    }

    /// @notice No graduated distribution can plan a zero-liquidity position.
    /// @dev The final price and the raise are not independent. At the auction's final checkpoint the
    ///      whole remaining schedule is consumed in one step, so the clearing price the checkpoint
    ///      settles on is backed by demand of at least `remainingSupply * price / Q96`, and every
    ///      unit already cleared was cleared at or above the frozen floor. That gives the raise a
    ///      floor of
    ///
    ///          max(cleared * FLOOR / Q96, remaining * price / Q96),   cleared + remaining = 10e9
    ///
    ///      whose minimum over the whole interval is about five million REGENT. This fuzz drives the
    ///      pinned `PositionPlanner` with that minimum raise and the fixed 5% reserve, across the
    ///      whole reachable price interval and both currency orderings.
    function testFuzz_STR_014_GraduatedDistributionNeverPlansZeroLiquidity(uint256 priceQ96, uint256 cleared)
        public
        view
    {
        priceQ96 = bound(priceQ96, strategy.FLOOR_PRICE_Q96(), MaxBidPriceLib.maxBidPrice(uint128(AUCTION_ALLOCATION)));
        cleared = bound(cleared, 0, AUCTION_ALLOCATION);

        uint256 minimumRaise = _minimumRaise(priceQ96, cleared);
        assertGt(minimumRaise, 0, "a graduated auction always raised something");
        assertLe(minimumRaise, strategy.MAX_REACHABLE_RAISE(), "and never more than the reachable maximum");

        _assertNonZeroFullRangePosition(priceQ96, minimumRaise, true);
        _assertNonZeroFullRangePosition(priceQ96, minimumRaise, false);
    }

    /// @notice Two real launches whose only difference is which side of REGENT their SUBJECT sorts on
    ///         reach the same final price, open reciprocal pools, and both carry real liquidity.
    function test_STR_014_BothCurrencyOrderingsPreservePriceRelationships() public {
        Launch memory low = _newLaunch(SUBJECT_LOW, 1, 1_000e18);
        Launch memory high = _newLaunch(SUBJECT_HIGH, 2, 1_000e18);

        _bidToGraduation(low, 2_000e18);
        _rollToStart(high);
        _bid(high, bidder, 2_000e18, _bidPrice(10));
        _rollToMigration(high);

        strategy.migrate(address(low.auction));
        strategy.migrate(address(high.auction));

        RegentLBPStrategy.Distribution memory dLow = strategy.distribution(address(low.auction));
        RegentLBPStrategy.Distribution memory dHigh = strategy.distribution(address(high.auction));

        assertEq(
            low.auction.lbpInitializationParams().initialPriceX96,
            high.auction.lbpInitializationParams().initialPriceX96,
            "the two identical auctions settled on the same final price"
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

    function _minimumRaise(uint256 priceQ96, uint256 cleared) internal view returns (uint256) {
        uint256 fromCleared = FullMath.mulDiv(cleared, strategy.FLOOR_PRICE_Q96(), Q96);
        uint256 fromRemaining = FullMath.mulDiv(AUCTION_ALLOCATION - cleared, priceQ96, Q96);
        return fromCleared > fromRemaining ? fromCleared : fromRemaining;
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
