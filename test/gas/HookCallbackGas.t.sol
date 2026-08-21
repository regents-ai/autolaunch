// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookFixture} from "../mocks/HookFixture.sol";

/// @notice `GAS-007`: the cold and warm cost of the supported hook callbacks, and the supported
///         router's own sync/settle timing, measured as a genuinely controlled difference and
///         dispositioned against the pinned Uniswap v4 guidance rather than assumed.
/// @dev The measurement is a difference, and the control is exact. The hook charges when the 1%
///      lane floors above zero and returns immediately when it does not, so the lane boundary is a
///      single wei: a specified amount of `LANE_DIVISOR` charges a lane, and `LANE_DIVISOR - 1`
///      charges nothing. The two swaps are therefore run one wei apart on two pools this fixture
///      opens identically — same currency ordering, same fee, same tick spacing, same opening
///      price, same liquidity, same direction, same price limit, same router, same warmth — and
///      the pools' sameness is asserted rather than assumed. Their difference is the callback and
///      nothing else.
///
///      A production-sized lane does slightly more work than a boundary one: at a one-wei lane the
///      splitter's own 2% skim floors to zero and one ERC20 push does not happen. A second pair is
///      therefore measured with a full one-REGENT swap against the same zero-lane control, and it
///      is labelled for what it is rather than merged into the first: it runs *after* the boundary
///      pair, so the Regent Safe and the REGENT token's own slots are already warm and only the
///      production pool's own splitter is cold. That is exactly the posture the second and every
///      later launch on a live system meets, and it is reported under that name.
///
///      Cold is the posture that matters. A user transaction meets a pool the first time anybody
///      swaps it, and pays the first-touch costs at the Regent Safe, the splitter and its onward
///      destination. Warm is only the control that proves the cold figure really was cold, never a
///      figure to quote on its own.
///
///      The applicable pinned-guidance row is "callbacks with external calls" — this hook takes
///      twice from the PoolManager, approves, and calls the launch splitter, which itself moves
///      value — whose target is 100,000 gas and whose hard ceiling is 300,000 gas.
contract HookCallbackGasTest is HookFixture {
    /// @notice The pinned v4 guidance for a callback that makes external calls.
    uint256 internal constant CALLBACK_TARGET_GAS = 100_000;
    uint256 internal constant CALLBACK_CEILING_GAS = 300_000;

    /// @dev A production-sized charging swap: one REGENT, whose lane is large enough that the
    ///      splitter's own 2% skim is nonzero and every branch of the settlement runs.
    int256 internal constant PRODUCTION_SWAP = -1e18;

    uint256 internal constant POOL_LIQUIDITY = 1e24;

    Pool internal charging;
    Pool internal control;
    Pool internal production;

    function setUp() public {
        _deployHookSystem();
        charging = _openPool(SUBJECT_LOW, POOL_LIQUIDITY);
        control = _openPool(SUBJECT_ALT, POOL_LIQUIDITY);
        production = _openPool(SUBJECT_ALT2, POOL_LIQUIDITY);
    }

    /// @notice `GAS-007`: the charging callback's cold and warm cost, measured one wei either side
    ///         of the lane boundary on identically built pools, sits inside the pinned v4 hard
    ///         ceiling for a callback with external calls; the production-sized lane does too;
    ///         warm is measurably cheaper than cold; and the second supported router settles the
    ///         same swap for a recorded cost.
    function test_GAS_007_HookCallbackAndRouterSettlementGasAreMeasured() public {
        _assertPoolsAreIdenticallyBuilt();

        int256 boundaryCharging = -int256(hook.LANE_DIVISOR());
        int256 boundaryZeroLane = boundaryCharging + 1;

        // Cold: no pool here has ever been swapped, so all three pay first-touch storage and
        // account costs. The only difference between the first two is whether a lane is charged.
        uint256 coldCharging = _measurePinned(charging, boundaryCharging);
        uint256 coldControl = _measurePinned(control, boundaryZeroLane);
        uint256 coldProduction = _measurePinned(production, PRODUCTION_SWAP);
        assertGt(coldCharging, coldControl, "the charging swap did not cost more than the zero-lane control");
        uint256 coldCallback = coldCharging - coldControl;
        uint256 coldProductionLane = coldProduction - coldControl;

        // Warm: the same three swaps again, with every touched slot and account now warm.
        uint256 warmCharging = _measurePinned(charging, boundaryCharging);
        uint256 warmControl = _measurePinned(control, boundaryZeroLane);
        uint256 warmProduction = _measurePinned(production, PRODUCTION_SWAP);
        assertGt(warmCharging, warmControl, "the warm charging swap did not cost more than its control");
        uint256 warmCallback = warmCharging - warmControl;
        uint256 warmProductionLane = warmProduction - warmControl;

        emit log_named_uint("GAS-007 controlled charging callback, cold (gas)", coldCallback);
        emit log_named_uint("GAS-007 controlled charging callback, warm (gas)", warmCallback);
        emit log_named_uint("GAS-007 production-lane callback, cold pool warm safe (gas)", coldProductionLane);
        emit log_named_uint("GAS-007 production-lane callback, warm (gas)", warmProductionLane);
        emit log_named_uint("GAS-007 pinned-router production swap, cold total (gas)", coldProduction);
        emit log_named_uint("GAS-007 pinned-router production swap, warm total (gas)", warmProduction);

        // The disposition. Cold is the user-transaction posture; warm is the control beside it.
        assertLe(coldCallback, CALLBACK_CEILING_GAS, "the cold charging callback exceeds the pinned v4 hard ceiling");
        assertLe(warmCallback, CALLBACK_CEILING_GAS, "the warm charging callback exceeds the pinned v4 hard ceiling");
        assertLe(
            coldProductionLane, CALLBACK_CEILING_GAS, "the cold production-lane callback exceeds the pinned v4 ceiling"
        );
        assertLe(
            warmProductionLane, CALLBACK_CEILING_GAS, "the warm production-lane callback exceeds the pinned v4 ceiling"
        );
        assertLt(warmCallback, coldCallback, "the cold/warm control shows no warming at all");
        // A one-wei lane skips the splitter's floored 2% skim, so it really does under-measure a
        // production lane. Recording that the warm production lane is the dearer of the two is what
        // keeps the boundary figure from being read as the whole story.
        assertGt(warmProductionLane, warmCallback, "a production lane is not dearer than a boundary lane");
        assertLt(warmProductionLane, coldProductionLane, "the production-lane pair shows no warming at all");

        // The target is guidance, not a limit. Recording which side of it this hook sits on is the
        // disposition; `docs/audit/gas-and-size.md` carries the reasoning, and `bin/gate.sh`
        // reconciles the figures above against the ones that document publishes.
        emit log_named_uint("GAS-007 pinned v4 target for a callback with external calls (gas)", CALLBACK_TARGET_GAS);
        emit log_named_uint(
            "GAS-007 pinned v4 hard ceiling for a callback with external calls (gas)", CALLBACK_CEILING_GAS
        );

        // The hook has no router allowlist, so an unrelated router's own sync/settle sequence is
        // measured too. Both routers settle the same swap; only their settlement style differs.
        uint256 altWarm = _measureAlt(production, PRODUCTION_SWAP);
        emit log_named_uint("GAS-007 second supported router, warm sync/settle swap total (gas)", altWarm);
        assertLe(
            altWarm,
            coldProduction + CALLBACK_CEILING_GAS,
            "the second router's settlement is not within the recorded band"
        );

        // Whatever it cost, the accounting is unchanged: nothing attributable stays at the hook.
        assertEq(regent.balanceOf(address(hook)), 0, "the hook retained REGENT while being measured");
        assertEq(regent.allowance(address(hook), address(charging.splitter)), 0, "a splitter allowance survived");
        assertEq(regent.allowance(address(hook), address(production.splitter)), 0, "a splitter allowance survived");
    }

    // -------------------------------------------------------------------------

    /// @dev The control is only a control if the pools it compares are the same pool in every way
    ///      the fixture chooses. A difference in ordering, fee, tick spacing, opening price or
    ///      liquidity would land in the measured difference and be reported as callback cost.
    function _assertPoolsAreIdenticallyBuilt() private view {
        Pool[3] memory pools = [charging, control, production];
        for (uint256 i = 1; i < pools.length; ++i) {
            assertEq(pools[i].regentIsCurrency0, pools[0].regentIsCurrency0, "pools sort REGENT differently");
            assertEq(pools[i].key.fee, pools[0].key.fee, "pools carry different fees");
            assertEq(pools[i].key.tickSpacing, pools[0].key.tickSpacing, "pools carry different tick spacings");
            assertEq(address(pools[i].key.hooks), address(pools[0].key.hooks), "pools carry different hooks");
            assertEq(_currentSqrtPrice(pools[i]), _currentSqrtPrice(pools[0]), "pools opened at different prices");
            assertEq(
                pools[i].subject.balanceOf(address(manager)),
                pools[0].subject.balanceOf(address(manager)),
                "pools were funded with different SUBJECT liquidity"
            );
        }
        assertEq(_currentSqrtPrice(pools[0]), SQRT_PRICE_1_1, "the pools did not open at parity");
    }

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
