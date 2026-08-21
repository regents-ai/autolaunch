// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookFixture} from "../mocks/HookFixture.sol";

/// @notice `GAS-007`: the cold and warm cost of the supported hook callbacks, and the supported
///         router's own sync/settle timing, measured and dispositioned against the pinned Uniswap v4
///         guidance rather than assumed.
/// @dev The measurement is a difference, not a swap total. Two identical pools open cold side by
///      side; one takes a charging swap and the other takes a swap too small for either 1% lane to
///      floor above zero. Both swaps do the same PoolManager work, so the difference between them is
///      exactly what the charging callback costs, with the pool's own cold-storage cost cancelled
///      out. Repeating the same pair warm gives the cold/warm control.
///
///      The applicable pinned-guidance row is "callbacks with external calls" — this hook takes
///      twice from the PoolManager, approves, and calls the launch splitter, which itself moves
///      value — whose target is 100,000 gas and whose hard ceiling is 300,000 gas.
contract HookCallbackGasTest is HookFixture {
    /// @notice The pinned v4 guidance for a callback that makes external calls.
    uint256 internal constant CALLBACK_TARGET_GAS = 100_000;
    uint256 internal constant CALLBACK_CEILING_GAS = 300_000;

    /// @dev A charging swap: one REGENT, comfortably above the hundred-unit lane floor.
    int256 internal constant CHARGING_SWAP = -1e18;
    /// @dev A zero-lane swap of the same shape: below the floor, so no lane is charged at all.
    int256 internal constant ZERO_LANE_SWAP = -99;

    uint256 internal constant POOL_LIQUIDITY = 1e24;

    Pool internal charging;
    Pool internal control;

    function setUp() public {
        _deployHookSystem();
        charging = _openPool(SUBJECT_LOW, POOL_LIQUIDITY);
        control = _openPool(SUBJECT_ALT, POOL_LIQUIDITY);
    }

    /// @notice `GAS-007`: the charging callback's cold and warm cost sits inside the pinned v4 hard
    ///         ceiling for a callback with external calls, warm is measurably cheaper than cold, and
    ///         the second supported router settles the same swap for a recorded cost.
    function test_GAS_007_HookCallbackAndRouterSettlementGasAreMeasured() public {
        // Cold: neither pool has ever been swapped, so both pay first-touch storage and account
        // costs. The only difference between them is whether a lane is charged.
        uint256 coldCharging = _measurePinned(charging, CHARGING_SWAP);
        uint256 coldControl = _measurePinned(control, ZERO_LANE_SWAP);
        assertGt(coldCharging, coldControl, "the charging swap did not cost more than the zero-lane control");
        uint256 coldCallback = coldCharging - coldControl;

        // Warm: the same pair again, with every touched slot and account now warm.
        uint256 warmCharging = _measurePinned(charging, CHARGING_SWAP);
        uint256 warmControl = _measurePinned(control, ZERO_LANE_SWAP);
        assertGt(warmCharging, warmControl, "the warm charging swap did not cost more than its control");
        uint256 warmCallback = warmCharging - warmControl;

        emit log_named_uint("hook charging callback, cold (gas)", coldCallback);
        emit log_named_uint("hook charging callback, warm (gas)", warmCallback);
        emit log_named_uint("pinned-router swap, cold total (gas)", coldCharging);
        emit log_named_uint("pinned-router swap, warm total (gas)", warmCharging);

        assertLe(coldCallback, CALLBACK_CEILING_GAS, "the cold charging callback exceeds the pinned v4 hard ceiling");
        assertLe(warmCallback, CALLBACK_CEILING_GAS, "the warm charging callback exceeds the pinned v4 hard ceiling");
        assertLt(warmCallback, coldCallback, "the cold/warm control shows no warming at all");

        // The target is guidance, not a limit. Recording which side of it this hook sits on is the
        // disposition; `docs/audit/` carries the reasoning.
        emit log_named_uint("pinned v4 target for a callback with external calls (gas)", CALLBACK_TARGET_GAS);
        emit log_named_uint("pinned v4 hard ceiling for a callback with external calls (gas)", CALLBACK_CEILING_GAS);

        // The hook has no router allowlist, so an unrelated router's own sync/settle sequence is
        // measured too. Both routers settle the same swap; only their settlement style differs.
        uint256 altWarm = _measureAlt(charging, CHARGING_SWAP);
        emit log_named_uint("second supported router, warm sync/settle swap total (gas)", altWarm);
        assertLe(
            altWarm,
            coldCharging + CALLBACK_CEILING_GAS,
            "the second router's settlement is not within the recorded band"
        );

        // Whatever it cost, the accounting is unchanged: nothing attributable stays at the hook.
        assertEq(regent.balanceOf(address(hook)), 0, "the hook retained REGENT while being measured");
        assertEq(regent.allowance(address(hook), address(charging.splitter)), 0, "a splitter allowance survived");
    }

    // -------------------------------------------------------------------------

    function _measurePinned(Pool memory pool, int256 amountSpecified) private returns (uint256 used) {
        SwapParams memory params = _swapParams(_regentIsInput(pool), amountSpecified);
        uint256 before = gasleft();
        swapRouter.swap(pool.key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        used = before - gasleft();
    }

    function _measureAlt(Pool memory pool, int256 amountSpecified) private returns (uint256 used) {
        SwapParams memory params = _swapParams(_regentIsInput(pool), amountSpecified);
        uint256 before = gasleft();
        BalanceDelta delta = altRouter.swap(pool.key, params);
        delta;
        used = before - gasleft();
    }
}
