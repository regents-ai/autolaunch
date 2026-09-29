// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {GrossStockFeePrototype} from "../src/GrossStockFeePrototype.sol";
import {FixtureToken} from "./FixtureToken.sol";

contract GrossStockFeePrototypeTest is Test {
    uint160 private nextHook = 0x100000;
    address private constant SUBJECT_A = address(0xaaaa);
    address private constant SUBJECT_B = address(0xbbbb);
    struct Market {
        PoolManager manager;
        PoolSwapTest router;
        FixtureToken stock;
        FixtureToken newToken;
        GrossStockFeePrototype hook;
        PoolKey key;
    }
    event FeeCase(bool stockIs0, bool buyNew, bool exactInput, bool subjectOn, bool partialFill, uint256 grossStock, uint256 stockFee);

    function market(bool stockIs0, bool subjectOn, bool liquidity) external returns (Market memory m) {
        m.manager = new PoolManager(address(this));
        FixtureToken a = new FixtureToken("A", 18);
        FixtureToken b = new FixtureToken("B", 18);
        (FixtureToken low, FixtureToken high) = address(a) < address(b) ? (a, b) : (b, a);
        m.stock = stockIs0 ? low : high;
        m.newToken = stockIs0 ? high : low;
        m.router = new PoolSwapTest(m.manager);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(m.manager);
        uint160 permissions = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        address hookAddress = address((nextHook++ << 14) | permissions);
        GrossStockFeePrototype implementation = new GrossStockFeePrototype(m.manager, address(m.stock), address(this));
        vm.etch(hookAddress, address(implementation).code);
        m.hook = GrossStockFeePrototype(hookAddress);
        if (subjectOn) m.hook.setSubject(SUBJECT_A);
        m.key = PoolKey(Currency.wrap(address(low)), Currency.wrap(address(high)), 3000, 60, IHooks(hookAddress));
        m.manager.initialize(m.key, uint160(1 << 96));
        a.mint(address(this), 1e36);
        b.mint(address(this), 1e36);
        a.approve(address(lp), type(uint256).max);
        b.approve(address(lp), type(uint256).max);
        a.approve(address(m.router), type(uint256).max);
        b.approve(address(m.router), type(uint256).max);
        if (liquidity) lp.modifyLiquidity(m.key, ModifyLiquidityParams(-600, 600, 1e24, bytes32(0)), "");
    }

    // Proposed policy proof: exact actual gross STOCK accounting across both
    // directions, modes and orderings, optional lane, and partial execution.
    function test_proposed_gross_fee_matrix() public {
        for (uint256 bits; bits < 32; ++bits) {
            runCase(bits & 1 != 0, bits & 2 != 0, bits & 4 != 0, bits & 8 != 0, bits & 16 != 0);
        }
    }

    function runCase(bool stockIs0, bool buyNew, bool exactInput, bool subjectOn, bool partialFill) internal {
        Market memory m = this.market(stockIs0, subjectOn, true);
        bool zeroForOne = buyNew == stockIs0;
        uint256 requested = partialFill ? 1e26 : 1e18;
        uint160 limit = partialFill ? TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-1) : int24(1)) :
            (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        SwapParams memory params = SwapParams(zeroForOne, exactInput ? -int256(requested) : int256(requested), limit);
        uint256 oldStock = m.stock.balanceOf(address(this));
        uint256 oldNew = m.newToken.balanceOf(address(this));
        m.router.swap(m.key, params, PoolSwapTest.TestSettings(false, false), "");
        uint256 gross = m.hook.lastBase();
        uint256 fee = m.hook.lastFee();
        assertGt(gross, 0);
        assertEq(fee, (subjectOn ? 2 : 1) * (gross / 100));
        assertEq(m.hook.regentAccrued(), gross / 100);
        assertEq(m.hook.subjectAccrued(SUBJECT_A), subjectOn ? gross / 100 : 0);
        assertEq(m.stock.balanceOf(address(m.hook)), fee);
        assertEq(m.newToken.balanceOf(address(m.hook)), 0);
        uint256 stockMovement = buyNew ? oldStock - m.stock.balanceOf(address(this)) : m.stock.balanceOf(address(this)) - oldStock;
        uint256 newMovement = buyNew ? m.newToken.balanceOf(address(this)) - oldNew : oldNew - m.newToken.balanceOf(address(this));
        assertEq(stockMovement, buyNew ? gross : gross - fee);
        uint256 specifiedMovement = exactInput == buyNew ? stockMovement : newMovement;
        if (partialFill) assertLt(specifiedMovement, requested);
        else assertEq(specifiedMovement, requested);
        emit FeeCase(stockIs0, buyNew, exactInput, subjectOn, partialFill, gross, fee);
    }

    function test_zero_execution_collects_no_stock_in_all_modes() public {
        for (uint256 bits; bits < 8; ++bits) {
            bool stockIs0 = bits & 1 != 0;
            bool buyNew = bits & 2 != 0;
            bool exactInput = bits & 4 != 0;
            Market memory m = this.market(stockIs0, true, false);
            bool zeroForOne = buyNew == stockIs0;
            uint256 beforeStock = m.stock.balanceOf(address(this));
            m.router.swap(m.key, SwapParams(zeroForOne, exactInput ? -int256(1e18) : int256(1e18),
                TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-1) : int24(1))), PoolSwapTest.TestSettings(false, false), "");
            assertEq(m.hook.lastBase(), 0);
            assertEq(m.hook.lastFee(), 0);
            assertEq(m.hook.regentAccrued(), 0);
            assertEq(m.hook.subjectAccrued(SUBJECT_A), 0);
            assertEq(m.stock.balanceOf(address(this)), beforeStock);
        }
    }

    function test_off_on_retarget_preserves_history_and_another_router_cannot_skip_fees() public {
        Market memory m = this.market(true, false, true);
        SwapParams memory p = SwapParams(true, -int256(1e18), TickMath.MIN_SQRT_PRICE + 1);
        m.router.swap(m.key, p, PoolSwapTest.TestSettings(false, false), "");
        assertEq(m.hook.subjectAccrued(SUBJECT_A), 0);
        m.hook.setSubject(SUBJECT_A);
        m.router.swap(m.key, p, PoolSwapTest.TestSettings(false, false), "");
        uint256 historicalA = m.hook.subjectAccrued(SUBJECT_A);
        assertGt(historicalA, 0);
        m.hook.setSubject(SUBJECT_B);
        PoolSwapTest alternative = new PoolSwapTest(m.manager);
        m.stock.approve(address(alternative), type(uint256).max);
        m.newToken.approve(address(alternative), type(uint256).max);
        alternative.swap(m.key, p, PoolSwapTest.TestSettings(false, false), "");
        assertEq(m.hook.subjectAccrued(SUBJECT_A), historicalA);
        uint256 historicalB = m.hook.subjectAccrued(SUBJECT_B);
        assertEq(historicalB, m.hook.lastBase() / 100);
        m.hook.setSubject(address(0));
        alternative.swap(m.key, p, PoolSwapTest.TestSettings(false, false), "");
        assertEq(m.hook.subjectAccrued(SUBJECT_A), historicalA);
        assertEq(m.hook.subjectAccrued(SUBJECT_B), historicalB);
        assertEq(m.stock.balanceOf(address(m.hook)), m.hook.regentAccrued() + historicalA + historicalB);
    }

    function test_small_gross_inputs_do_not_need_a_hidden_rounding_payment() public {
        for (uint256 amount = 98; amount <= 103; ++amount) {
            Market memory m = this.market(true, true, true);
            uint256 beforeStock = m.stock.balanceOf(address(this));
            m.router.swap(m.key, SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false), "");
            assertEq(beforeStock - m.stock.balanceOf(address(this)), amount);
            assertEq(m.hook.lastBase(), amount);
            assertEq(m.hook.lastFee(), 2 * (amount / 100));
        }
    }

    // Counterexample to a DIFFERENT policy, not proof that v4 is impossible:
    // exact full-budget input + floor(1% core input) has integer gaps. A
    // beforeSwap-only fee adaptation cannot silently ignore that fee-base issue.
    function test_counterexample_core_input_floor_fee_has_budget_gaps() public pure {
        uint256 solutions;
        for (uint256 core; core <= 100; ++core) {
            if (core + core / 100 == 100) ++solutions;
        }
        assertEq(solutions, 0);
        uint256 wholeToken = 1e18;
        assertEq(wholeToken % 101, 100);
        uint256 candidate = wholeToken / 101;
        assertTrue(candidate != (wholeToken - candidate) / 100);
        assertTrue(candidate + 1 != (wholeToken - candidate - 1) / 100);
    }
}
