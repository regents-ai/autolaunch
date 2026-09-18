// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {PositionPlanner} from "liquidity-launcher/src/libraries/PositionPlanner.sol";
import {
    CurrencyAmounts,
    Plan,
    Position,
    PositionDefinition
} from "liquidity-launcher/src/types/PositionPlannerTypes.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";

/// @title RobinhoodPositionsLib
/// @notice The pinned planner's position resolution and plan encoding for the Robinhood launchpad,
///         as a linked (delegatecall) library so the launchpad does not carry the planner at runtime
///         (EIP-170). Every function is pure: it reads no storage and moves no value.
library RobinhoodPositionsLib {
    error NoFullRangePosition();

    /// @dev The full-range position the pinned planner resolves from a currency budget and the reserve.
    function fullRange(
        uint160 sqrtPriceX96,
        bool currencyIsCurrency0,
        uint128 currencyBudget,
        uint128 reserve,
        address recipient
    ) external pure returns (Position memory) {
        // slither-disable-next-line unused-return
        (Position[] memory positions,) = PositionPlanner.resolve(
            new PositionDefinition[](0),
            sqrtPriceX96,
            StocksPreset.POOL_TICK_SPACING,
            currencyAmounts(currencyIsCurrency0, currencyBudget, reserve),
            recipient
        );
        if (positions.length != 1) revert NoFullRangePosition();
        return positions[0];
    }

    /// @dev One position from an explicit definition and a budget; empty when the budget is below one
    ///      unit of liquidity.
    function defined(
        uint160 sqrtPriceX96,
        PositionDefinition memory definition,
        CurrencyAmounts memory budget,
        address recipient
    ) external pure returns (Position[] memory positions) {
        PositionDefinition[] memory definitions = new PositionDefinition[](1);
        definitions[0] = definition;
        // slither-disable-next-line unused-return
        (positions,) =
            PositionPlanner.resolve(definitions, sqrtPriceX96, StocksPreset.POOL_TICK_SPACING, budget, recipient);
    }

    /// @dev The pinned plan with its two `CONTRACT_BALANCE` settlement sentinels replaced by the exact
    ///      two amounts the caller transfers in, encoded for `modifyLiquidities`.
    function exactlyFundedPlan(Position[] memory positions, PoolKey memory key, uint128 amount0, uint128 amount1)
        external
        pure
        returns (bytes memory unlockData)
    {
        Plan memory plan = PositionPlanner.toPlan(positions, key, ActionConstants.MSG_SENDER);
        uint256 settleOffset = positions.length;
        plan.params[settleOffset] = abi.encode(key.currency0, uint256(amount0), false);
        plan.params[settleOffset + 1] = abi.encode(key.currency1, uint256(amount1), false);
        unlockData = abi.encode(plan.actions, plan.params);
    }

    function currencyAmounts(bool currencyIsCurrency0, uint128 currencyAmount, uint128 newAmount)
        internal
        pure
        returns (CurrencyAmounts memory)
    {
        return CurrencyAmounts({
            amount0: currencyIsCurrency0 ? currencyAmount : newAmount,
            amount1: currencyIsCurrency0 ? newAmount : currencyAmount
        });
    }
}
