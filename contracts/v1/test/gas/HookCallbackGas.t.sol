// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookFixture} from "../mocks/HookFixture.sol";

/// @notice `GAS-007`: the cold and warm cost of the supported hook callbacks, and a second
///         supported router's own sync/settle timing, measured as a genuinely controlled difference
///         and recorded.
/// @dev The measurement is a difference, and the control is exact. Against the pinned core at the
///      fixture's opening state, specified inputs 102 and 101 realize unspecified outputs 100 and
///      99 respectively. The test reads the settlement event to prove which side of the lane floor
///      each execution reached. The two swaps therefore run one wei apart on two pools this fixture
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
///      This claim records measurements and asserts only relations the measurement itself
///      establishes. It asserts **no** absolute callback gas limit, because no pinned dependency
///      and no founder requirement states one: the 100,000/300,000 pair an earlier draft compared
///      against came from a general-purpose community guidance table, not from Uniswap v4, from
///      the pinned closure, or from `SPEC.md`. Inventing a protocol limit and then passing it is
///      not evidence, so the figures below are published and reconciled by the gate and left as
///      recorded measurements. The only absolute gas ceiling this repository holds anyone to is
///      the founder's 14,000,000 complete-transaction limit, which `GAS-003` through `GAS-006`
///      prove on the authorized fork gate.
contract HookCallbackGasTest is HookFixture {
    int256 internal constant BOUNDARY_CHARGING = -102;
    int256 internal constant BOUNDARY_ZERO_LANE = -101;

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
    ///         of the lane boundary on identically built pools; the production-sized lane measured
    ///         the same way; warm measurably cheaper than cold; a production lane dearer than a
    ///         boundary one; and a second supported router's own sync/settle total recorded beside
    ///         them.
    function test_GAS_007_HookCallbackAndRouterSettlementGasAreMeasured() public {
        _assertPoolsAreIdenticallyBuilt();

        // Cold: no pool here has ever been swapped, so all three pay first-touch storage and
        // account costs. The only difference between the first two is whether a lane is charged.
        uint256 coldCharging = _measurePinned(charging, BOUNDARY_CHARGING, true);
        uint256 coldControl = _measurePinned(control, BOUNDARY_ZERO_LANE, false);
        uint256 coldProduction = _measurePinned(production, PRODUCTION_SWAP, true);
        assertGt(coldCharging, coldControl, "the charging swap did not cost more than the zero-lane control");
        uint256 coldCallback = coldCharging - coldControl;
        uint256 coldProductionLane = coldProduction - coldControl;

        // Warm: the same three swaps again, with every touched slot and account now warm.
        uint256 warmCharging = _measurePinned(charging, BOUNDARY_CHARGING, true);
        uint256 warmControl = _measurePinned(control, BOUNDARY_ZERO_LANE, false);
        uint256 warmProduction = _measurePinned(production, PRODUCTION_SWAP, true);
        assertGt(warmCharging, warmControl, "the warm charging swap did not cost more than its control");
        uint256 warmCallback = warmCharging - warmControl;
        uint256 warmProductionLane = warmProduction - warmControl;

        emit log_named_uint("GAS-007 controlled charging callback, cold (gas)", coldCallback);
        emit log_named_uint("GAS-007 controlled charging callback, warm (gas)", warmCallback);
        emit log_named_uint("GAS-007 production-lane callback, cold pool warm safe (gas)", coldProductionLane);
        emit log_named_uint("GAS-007 production-lane callback, warm (gas)", warmProductionLane);
        emit log_named_uint("GAS-007 pinned-router production swap, cold total (gas)", coldProduction);
        emit log_named_uint("GAS-007 pinned-router production swap, warm total (gas)", warmProduction);

        // The only assertions are the ones the controlled measurement itself establishes. Cold is
        // the user-transaction posture; warm is the control beside it.
        assertLt(warmCallback, coldCallback, "the cold/warm control shows no warming at all");
        // A one-wei lane skips the splitter's floored 2% skim, so it really does under-measure a
        // production lane. Recording that the warm production lane is the dearer of the two is what
        // keeps the boundary figure from being read as the whole story.
        assertGt(warmProductionLane, warmCallback, "a production lane is not dearer than a boundary lane");
        assertLt(warmProductionLane, coldProductionLane, "the production-lane pair shows no warming at all");

        // The hook has no router allowlist, so an unrelated router's own sync/settle sequence is
        // measured too. Both routers settle the same swap; only their settlement style differs.
        // This figure is recorded only: there is no admitted cost relation between two routers'
        // settlement styles to assert, and asserting an invented band would prove nothing.
        uint256 altWarm = _measureAlt(production, PRODUCTION_SWAP);
        emit log_named_uint("GAS-007 second supported router, warm sync/settle swap total (gas)", altWarm);

        // Whatever it cost, the accounting is unchanged: nothing attributable stays at the hook.
        assertEq(regent.balanceOf(address(hook)), 0, "the hook retained REGENT while being measured");
        assertEq(charging.subject.balanceOf(address(hook)), 0, "the hook retained charging SUBJECT");
        assertEq(control.subject.balanceOf(address(hook)), 0, "the hook retained control SUBJECT");
        assertEq(production.subject.balanceOf(address(hook)), 0, "the hook retained production SUBJECT");
        assertEq(
            charging.subject.allowance(address(hook), address(charging.splitter)), 0, "a splitter allowance survived"
        );
        assertEq(
            production.subject.allowance(address(hook), address(production.splitter)),
            0,
            "a splitter allowance survived"
        );
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

    function _measurePinned(Pool memory pool, int256 amountSpecified, bool shouldCharge)
        private
        returns (uint256 used)
    {
        SwapParams memory params = _swapParams(_regentIsInput(pool), amountSpecified);
        vm.recordLogs();
        uint256 before = gasleft();
        swapRouter.swap(pool.key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        used = before - gasleft();
        Settlement[] memory settlements = _recordedSettlements();
        if (shouldCharge) {
            assertEq(settlements.length, 1, "FA07-I2 charging measurement did not settle");
            assertGt(settlements[0].lane, 0, "FA07-I2 charging measurement had a zero lane");
        } else {
            assertEq(settlements.length, 0, "FA07-I2 control crossed the lane floor");
        }
    }

    function _measureAlt(Pool memory pool, int256 amountSpecified) private returns (uint256 used) {
        SwapParams memory params = _swapParams(_regentIsInput(pool), amountSpecified);
        uint256 before = gasleft();
        BalanceDelta delta = altRouter.swap(pool.key, params);
        delta;
        used = before - gasleft();
    }
}
