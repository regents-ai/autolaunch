// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {StocksBindings} from "../src/StocksBindings.sol";
import {StocksFeeHookV1} from "../src/StocksFeeHookV1.sol";
import {StocksPreset} from "../src/StocksPreset.sol";
import {FixtureStockToken} from "../src/fixtures/FixtureStockToken.sol";
import {IStocksFeeHookV1} from "../src/interfaces/IStocksFeeHookV1.sol";
import {IStocksLaunchpadV1} from "../src/interfaces/IStocksLaunchpadV1.sol";
import {MockSplitter} from "./mocks/MockSplitter.sol";
import {StocksFixture} from "./StocksFixture.sol";

/// @notice Rules 5 and 6: the hook only accrues, per `(poolId, destination)` bucket, in STOCK, on every
///         swap form and both currency orders; `settle` is the only path out.
contract StocksFeeHookTest is StocksFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant STOCK_AMOUNT = 1e8;
    uint256 internal constant NEW_AMOUNT = 1e24;

    struct Snapshot {
        uint256 traderStock;
        uint256 traderNew;
        uint256 poolStock;
        uint256 hookStock;
        uint256 hookNew;
        uint256 regentBucket;
        uint256 subjectBucket;
    }

    function setUp() public {
        _deployStocks();
    }

    // -------------------------------------------------------------------------
    // permissions and authority
    // -------------------------------------------------------------------------

    function test_hook_address_carries_exactly_the_declared_permission_bits() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
        assertEq(hook.launchpad(), address(launchpad));
        assertEq(address(hook.poolManager()), StocksBindings.POOL_MANAGER);
        assertEq(hook.REGENT_DESTINATION(), StocksBindings.REGENT);
        assertEq(hook.executor(), executor);
    }

    function test_launchpad_only_surface() public {
        Launched memory l = _launch(STOCK_LOW);
        PoolKey memory key = _poolKey(l);
        bytes32 poolId = _poolId(l);
        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.NotLaunchpad.selector, outsider));
        hook.registerPool(key, l.stock, l.newToken, address(0));
        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.NotLaunchpad.selector, outsider));
        hook.setSubject(poolId, address(splitter));
        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.NotLaunchpad.selector, outsider));
        hook.creditRegentLane(poolId, 1);
        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.NotGovernance.selector, outsider));
        hook.setExecutor(outsider);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.NotGovernance.selector, address(launchpad)));
        vm.prank(address(launchpad));
        hook.setExecutor(outsider);
    }

    function test_callbacks_are_pool_manager_only() public {
        Launched memory l = _launch(STOCK_LOW);
        PoolKey memory key = _poolKey(l);
        SwapParams memory params = SwapParams(true, -1, 0);
        vm.startPrank(outsider);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(outsider, key, params, "");
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(outsider, key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(outsider, key, 0);
        vm.stopPrank();
    }

    function test_registration_validates_the_whole_key() public {
        Launched memory l = _launch(STOCK_LOW);
        PoolKey memory key = _poolKey(l);
        vm.startPrank(address(launchpad));

        PoolKey memory wrong = _poolKey(l);
        wrong.fee = 500;
        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.UnexpectedPoolFee.selector, 500));
        hook.registerPool(wrong, l.stock, l.newToken, address(0));

        wrong = _poolKey(l);
        wrong.tickSpacing = 10;
        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.UnexpectedTickSpacing.selector, 10));
        hook.registerPool(wrong, l.stock, l.newToken, address(0));

        wrong = _poolKey(l);
        wrong.hooks = IHooks(address(0));
        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.ForeignHook.selector, address(0)));
        hook.registerPool(wrong, l.stock, l.newToken, address(0));

        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.StockNotInPoolKey.selector, STOCK_HIGH));
        hook.registerPool(key, STOCK_HIGH, l.newToken, address(0));

        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.StockNotInPoolKey.selector, outsider));
        hook.registerPool(key, l.stock, outsider, address(0));

        bytes32 poolId = hook.registerPool(key, l.stock, l.newToken, address(0));
        assertEq(poolId, _poolId(l));
        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.PoolAlreadyRegistered.selector, poolId));
        hook.registerPool(key, l.stock, l.newToken, address(0));
        vm.stopPrank();
    }

    function test_swaps_on_an_unregistered_pool_with_this_hook_cannot_exist() public {
        // A pool carrying this hook that the launchpad never registered cannot even be initialized.
        Launched memory l = _launch(STOCK_LOW);
        PoolKey memory key = _poolKey(l);
        vm.expectRevert();
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    // -------------------------------------------------------------------------
    // fee matrix: two orderings x four swap forms x subject on/off
    // -------------------------------------------------------------------------

    function test_fee_matrix_charges_stock_on_every_swap_form_with_conservation() public {
        for (uint256 bits; bits < 16; ++bits) {
            _runCase(bits & 1 != 0, bits & 2 != 0, bits & 4 != 0, bits & 8 != 0);
        }
    }

    function _runCase(bool stockLow, bool buyNew, bool exactInput, bool subjectOn) private {
        Launched memory l = _graduatedMarket(stockLow ? STOCK_LOW : STOCK_HIGH, subjectOn);
        bytes32 poolId = _poolId(l);
        bool stockIs0 = _stockIsCurrency0(l);
        bool zeroForOne = buyNew == stockIs0;
        bool stockSpecified = buyNew == exactInput;
        int256 amountSpecified;
        if (stockSpecified) amountSpecified = exactInput ? -int256(STOCK_AMOUNT) : int256(STOCK_AMOUNT);
        else amountSpecified = exactInput ? -int256(NEW_AMOUNT) : int256(NEW_AMOUNT);

        Snapshot memory before = _snapshot(l, poolId);
        _swap(l, trader, zeroForOne, amountSpecified);
        Snapshot memory post = _snapshot(l, poolId);

        int256 traderDelta = int256(post.traderStock) - int256(before.traderStock);
        int256 poolDelta = int256(post.poolStock) - int256(before.poolStock);
        int256 hookDelta = int256(post.hookStock) - int256(before.hookStock);
        assertEq(traderDelta + poolDelta + hookDelta, 0, "STOCK conservation across trader, pool and hook");
        assertEq(post.hookNew, 0, "the hook never takes NEW");
        assertGt(hookDelta, 0, "a fee was charged");

        uint256 lanes = subjectOn ? 2 : 1;
        uint256 feeBase;
        if (buyNew) {
            // STOCK input: the fee base is the trader's whole STOCK debit.
            feeBase = uint256(-traderDelta);
            assertEq(poolDelta, traderDelta * -1 - hookDelta, "pool receives the debit minus the fee");
        } else {
            // STOCK output: the fee base is the pool's whole STOCK output before the fee.
            feeBase = uint256(-poolDelta);
            assertEq(uint256(traderDelta) + uint256(hookDelta), feeBase, "trader receives the output minus the fee");
        }
        uint256 lane = feeBase / StocksPreset.LANE_DIVISOR;
        assertEq(uint256(hookDelta), lanes * lane, "each lane is one percent of the gross STOCK amount, floored");
        assertEq(post.regentBucket - before.regentBucket, lane, "REGENT bucket credited one lane");
        assertEq(post.subjectBucket - before.subjectBucket, subjectOn ? lane : 0, "subject bucket only when on");

        // The specified amount is honoured exactly, whichever side it is on.
        if (stockSpecified && exactInput) assertEq(uint256(-traderDelta), STOCK_AMOUNT, "exact STOCK input");
        if (stockSpecified && !exactInput) assertEq(uint256(traderDelta), STOCK_AMOUNT, "exact STOCK output");
        if (!stockSpecified && exactInput) assertEq(before.traderNew - post.traderNew, NEW_AMOUNT, "exact NEW input");
        if (!stockSpecified && !exactInput) assertEq(post.traderNew - before.traderNew, NEW_AMOUNT, "exact NEW output");
    }

    function test_small_stock_inputs_are_charged_exactly_and_floored() public {
        Launched memory l = _graduatedMarket(STOCK_LOW, true);
        bytes32 poolId = _poolId(l);
        for (uint256 amount = 98; amount <= 203; amount += 35) {
            Snapshot memory before = _snapshot(l, poolId);
            _swap(l, trader, true, -int256(amount));
            Snapshot memory post = _snapshot(l, poolId);
            assertEq(before.traderStock - post.traderStock, amount, "debit is exactly the input");
            assertEq(post.hookStock - before.hookStock, 2 * (amount / 100), "two floored lanes");
        }
    }

    function test_stock_specified_partial_fills_revert_and_stock_unspecified_partial_fills_are_charged() public {
        Launched memory l = _graduatedMarket(STOCK_LOW, false);
        bytes32 poolId = _poolId(l);
        (, int24 tick,,) = IPoolManager(address(poolManager)).getSlot0(PoolId.wrap(poolId));
        uint160 limitDown = TickMath.getSqrtPriceAtTick(tick - 30);
        uint160 limitUp = TickMath.getSqrtPriceAtTick(tick + 30);

        // STOCK specified, exact input (STOCK -> NEW) against a limit a few ticks away: refused.
        vm.expectRevert();
        _swapLimited(l, trader, true, -int256(1_000e8), limitDown);
        // STOCK specified, exact output (NEW -> STOCK): refused the same way.
        vm.expectRevert();
        _swapLimited(l, trader, false, int256(1_000e8), limitUp);

        // STOCK unspecified, exact output NEW (STOCK in): fills partially, charged on the gross debit.
        Snapshot memory before = _snapshot(l, poolId);
        _swapLimited(l, trader, true, int256(1e26), limitDown);
        Snapshot memory post = _snapshot(l, poolId);
        assertLt(post.traderNew - before.traderNew, 1e26, "partial fill");
        uint256 debit = before.traderStock - post.traderStock;
        assertEq(post.hookStock - before.hookStock, debit / 100, "one lane of the gross debit");
        assertEq(post.poolStock - before.poolStock, debit - debit / 100);

        // STOCK unspecified, exact input NEW (STOCK out): fills partially, charged on the gross output.
        before = _snapshot(l, poolId);
        _swapLimited(l, trader, false, -int256(1e26), limitUp);
        post = _snapshot(l, poolId);
        assertLt(before.traderNew - post.traderNew, 1e26, "partial fill");
        uint256 output = before.poolStock - post.poolStock;
        assertEq(post.hookStock - before.hookStock, output / 100, "one lane of the gross output");
        assertEq(post.traderStock - before.traderStock, output - output / 100);
    }

    function test_zero_fee_swaps_make_no_take() public {
        Launched memory l = _graduatedMarket(STOCK_LOW, true);
        bytes32 poolId = _poolId(l);
        Snapshot memory before = _snapshot(l, poolId);
        _swap(l, trader, true, -int256(50));
        Snapshot memory post = _snapshot(l, poolId);
        assertEq(post.hookStock, before.hookStock);
        assertEq(post.regentBucket, before.regentBucket);
        assertEq(before.traderStock - post.traderStock, 50);
    }

    function test_accrual_event_names_the_destination_in_effect() public {
        Launched memory l = _graduatedMarket(STOCK_LOW, true);
        bytes32 poolId = _poolId(l);
        vm.expectEmit(true, true, false, true, address(hook));
        emit IStocksFeeHookV1.HookFeeAccrued(poolId, address(splitter), STOCK_AMOUNT, STOCK_AMOUNT / 100, STOCK_AMOUNT / 100);
        _swap(l, trader, _stockIsCurrency0(l), -int256(STOCK_AMOUNT));
    }

    // -------------------------------------------------------------------------
    // buckets never re-attribute
    // -------------------------------------------------------------------------

    function test_buckets_are_attributed_at_swap_time_and_never_redirected() public {
        Launched memory l = _graduatedMarket(STOCK_LOW, false);
        bytes32 poolId = _poolId(l);
        address regentLane = hook.REGENT_DESTINATION();
        MockSplitter second = new MockSplitter(makeAddr("subject-two"), StocksBindings.REGENT);
        agentStrategy.record(makeAddr("subject-two"), makeAddr("auction-two"), address(second));

        uint256 dust = hook.accrued(poolId, regentLane);
        _swap(l, trader, true, -int256(STOCK_AMOUNT));
        assertEq(hook.accrued(poolId, address(splitter)), 0, "off: nothing to the subject");
        uint256 regentAfterOff = hook.accrued(poolId, regentLane);
        assertEq(regentAfterOff - dust, STOCK_AMOUNT / 100);

        vm.prank(feeAdministrator);
        launchpad.configureSubject(l.launchId, address(splitter), 1);
        _swap(l, trader, true, -int256(STOCK_AMOUNT));
        uint256 firstBucket = hook.accrued(poolId, address(splitter));
        assertEq(firstBucket, STOCK_AMOUNT / 100);

        vm.prank(feeAdministrator);
        launchpad.configureSubject(l.launchId, address(second), 2);
        _swap(l, trader, true, -int256(STOCK_AMOUNT));
        assertEq(hook.accrued(poolId, address(splitter)), firstBucket, "old bucket untouched");
        assertEq(hook.accrued(poolId, address(second)), STOCK_AMOUNT / 100, "new bucket credited");

        vm.prank(feeAdministrator);
        launchpad.configureSubject(l.launchId, address(0), 3);
        _swap(l, trader, true, -int256(STOCK_AMOUNT));
        assertEq(hook.accrued(poolId, address(splitter)), firstBucket);
        assertEq(hook.accrued(poolId, address(second)), STOCK_AMOUNT / 100);
        assertEq(hook.accrued(poolId, regentLane), regentAfterOff + 3 * (STOCK_AMOUNT / 100), "REGENT lane always");

        // The hook's STOCK balance is exactly the sum of every bucket, including the graduation dust.
        uint256 total = hook.accrued(poolId, regentLane) + firstBucket + hook.accrued(poolId, address(second));
        assertEq(FixtureStockToken(l.stock).balanceOf(address(hook)), total);
    }

    // -------------------------------------------------------------------------
    // settlement
    // -------------------------------------------------------------------------

    function test_settle_regent_bucket_deposits_usdc_into_live_staking() public {
        Launched memory l = _graduatedMarket(STOCK_LOW, false);
        bytes32 poolId = _poolId(l);
        address regentLane = hook.REGENT_DESTINATION();
        _swap(l, trader, true, -int256(1_000e8));
        uint256 accrued = hook.accrued(poolId, regentLane);
        uint256 amount = accrued / 2;
        uint256 expectedUsdc = amount * USDC_PER_SHARE / 1e8;
        uint256 stakingBefore = usdc.balanceOf(address(liveStaking));
        uint256 hookStockBefore = FixtureStockToken(l.stock).balanceOf(address(hook));

        vm.expectEmit(true, true, false, true, address(hook));
        emit IStocksFeeHookV1.BucketSettled(poolId, regentLane, amount, expectedUsdc, poolId);
        vm.prank(executor);
        hook.settle(poolId, regentLane, amount, expectedUsdc);

        assertEq(hook.accrued(poolId, regentLane), accrued - amount);
        (uint256 converted, uint256 deposited) = hook.settled(poolId, regentLane);
        assertEq(converted, amount);
        assertEq(deposited, expectedUsdc);
        assertEq(usdc.balanceOf(address(liveStaking)) - stakingBefore, expectedUsdc);
        assertEq(liveStaking.lastAmount(), expectedUsdc);
        assertEq(liveStaking.lastSourceTag(), bytes32("autolaunch-stocks"));
        assertEq(liveStaking.lastSourceRef(), poolId);
        assertEq(liveStaking.lastCaller(), address(hook));
        assertEq(hookStockBefore - FixtureStockToken(l.stock).balanceOf(address(hook)), amount);
        assertEq(usdc.balanceOf(address(hook)), 0, "no USDC stays in the hook");
        assertEq(usdc.allowance(address(hook), address(liveStaking)), 0);
    }

    function test_settle_subject_bucket_deposits_usdc_into_that_splitter() public {
        Launched memory l = _graduatedMarket(STOCK_LOW, true);
        bytes32 poolId = _poolId(l);
        _swap(l, trader, true, -int256(1_000e8));
        uint256 amount = hook.accrued(poolId, address(splitter));
        uint256 expectedUsdc = amount * USDC_PER_SHARE / 1e8;

        vm.prank(executor);
        hook.settle(poolId, address(splitter), amount, 1);

        assertEq(hook.accrued(poolId, address(splitter)), 0);
        assertEq(usdc.balanceOf(address(splitter)), expectedUsdc);
        assertEq(splitter.lastToken(), StocksBindings.USDC);
        assertEq(splitter.lastAmount(), expectedUsdc);
        assertEq(splitter.lastRef(), poolId);
        assertEq(usdc.allowance(address(hook), address(splitter)), 0);
        // The REGENT bucket of the same swap is untouched by the subject settlement.
        assertEq(hook.accrued(poolId, hook.REGENT_DESTINATION()), amount + _dust(l));
    }

    function test_settle_re_credits_route_residue() public {
        // A route may return STOCK it did not consume; the bucket gets it back and the totals record
        // only what was converted. The fixture route is fed a one-unit residue by a direct transfer
        // inside the route's own swap through a wrapping route.
        Launched memory l = _graduatedMarket(STOCK_LOW, false);
        bytes32 poolId = _poolId(l);
        _swap(l, trader, true, -int256(1_000e8));
        address regentLane = hook.REGENT_DESTINATION();
        uint256 accrued = hook.accrued(poolId, regentLane);

        ResidueRoute residueRoute = new ResidueRoute(l.stock, 7);
        usdc.mint(address(residueRoute), 1_000_000e6);
        vm.prank(governance);
        launchpad.admitStock(l.stock, address(residueRoute));

        vm.prank(executor);
        hook.settle(poolId, regentLane, 1_000, 1);
        assertEq(hook.accrued(poolId, regentLane), accrued - 1_000 + 7, "residue re-credited");
        (uint256 converted,) = hook.settled(poolId, regentLane);
        assertEq(converted, 993);
    }

    function test_settle_guards() public {
        Launched memory l = _graduatedMarket(STOCK_LOW, true);
        bytes32 poolId = _poolId(l);
        address regentLane = hook.REGENT_DESTINATION();
        _swap(l, trader, true, -int256(1_000e8));
        uint256 accrued = hook.accrued(poolId, regentLane);

        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.NotExecutor.selector, outsider));
        vm.prank(outsider);
        hook.settle(poolId, regentLane, 1, 0);

        vm.startPrank(executor);
        vm.expectRevert(StocksFeeHookV1.ZeroAmount.selector);
        hook.settle(poolId, regentLane, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.InsufficientAccrual.selector, accrued, accrued + 1));
        hook.settle(poolId, regentLane, accrued + 1, 0);
        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.InsufficientAccrual.selector, 0, 1));
        hook.settle(poolId, outsider, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.PoolNotRegistered.selector, bytes32(uint256(1))));
        hook.settle(bytes32(uint256(1)), regentLane, 1, 0);
        // minUsdcOut above what the route pays: the route refuses and the whole settle reverts.
        vm.expectRevert();
        hook.settle(poolId, regentLane, 1e8, type(uint256).max);
        vm.stopPrank();
        assertEq(hook.accrued(poolId, regentLane), accrued, "a failed settle changes nothing");

        // A disabled executor stops settlement entirely.
        vm.prank(governance);
        hook.setExecutor(address(0));
        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.NotExecutor.selector, executor));
        vm.prank(executor);
        hook.settle(poolId, regentLane, 1, 0);
    }

    function test_settle_refuses_a_misbehaving_staking_or_splitter_and_reverts_only_itself() public {
        Launched memory l = _graduatedMarket(STOCK_LOW, true);
        bytes32 poolId = _poolId(l);
        address regentLane = hook.REGENT_DESTINATION();
        _swap(l, trader, true, -int256(1_000e8));
        uint256 regentAccrued = hook.accrued(poolId, regentLane);
        uint256 subjectAccrued = hook.accrued(poolId, address(splitter));

        liveStaking.setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Paused()"))));
        vm.prank(executor);
        hook.settle(poolId, regentLane, 1e8, 1);
        liveStaking.setPaused(false);

        liveStaking.setPullsPartially(true);
        vm.expectRevert();
        vm.prank(executor);
        hook.settle(poolId, regentLane, 1e8, 1);
        liveStaking.setPullsPartially(false);

        liveStaking.setReportsWrongAmount(true);
        uint256 expectedUsdc = 1e8 * USDC_PER_SHARE / 1e8;
        vm.expectRevert(abi.encodeWithSelector(StocksFeeHookV1.DepositMismatch.selector, expectedUsdc, expectedUsdc + 1));
        vm.prank(executor);
        hook.settle(poolId, regentLane, 1e8, 1);
        liveStaking.setReportsWrongAmount(false);

        splitter.setPullsPartially(true);
        vm.expectRevert(
            abi.encodeWithSelector(StocksFeeHookV1.AllowanceNotConsumed.selector, address(splitter), expectedUsdc - expectedUsdc / 2)
        );
        vm.prank(executor);
        hook.settle(poolId, address(splitter), 1e8, 1);
        splitter.setPullsPartially(false);

        assertEq(hook.accrued(poolId, regentLane), regentAccrued, "buckets unchanged by failed settles");
        assertEq(hook.accrued(poolId, address(splitter)), subjectAccrued);

        // Swaps keep working regardless of settlement problems.
        liveStaking.setPaused(true);
        _swap(l, trader, true, -int256(STOCK_AMOUNT));
        assertEq(hook.accrued(poolId, regentLane), regentAccrued + STOCK_AMOUNT / 100);
    }

    // -------------------------------------------------------------------------
    // arithmetic
    // -------------------------------------------------------------------------

    function testFuzz_grossLane_is_the_smallest_fixed_point(uint256 net, bool twoLanes) public view {
        net = bound(net, 0, type(uint128).max);
        uint256 lanes = twoLanes ? 2 : 1;
        uint256 q = hook.grossLane(net, lanes);
        assertEq(q, (net + lanes * q) / 100, "q is one percent, floored, of the gross amount");
        if (q != 0) assertNotEq(q - 1, (net + lanes * (q - 1)) / 100, "q - 1 is not a fixed point");
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _snapshot(Launched memory l, bytes32 poolId) private view returns (Snapshot memory s) {
        s.traderStock = FixtureStockToken(l.stock).balanceOf(trader);
        s.traderNew = UERC20(l.newToken).balanceOf(trader);
        s.poolStock = FixtureStockToken(l.stock).balanceOf(address(poolManager));
        s.hookStock = FixtureStockToken(l.stock).balanceOf(address(hook));
        s.hookNew = UERC20(l.newToken).balanceOf(address(hook));
        s.regentBucket = hook.accrued(poolId, hook.REGENT_DESTINATION());
        s.subjectBucket = hook.accrued(poolId, address(splitter));
    }

    /// @dev The graduation's rounding remainder: the raise less what both locked positions hold.
    function _dust(Launched memory l) private view returns (uint256) {
        IStocksLaunchpadV1.Launch memory record = _record(l);
        return record.lpStockUsed == 0 ? 0 : _raised(l) - record.lpStockUsed - record.lpStockOnlyUsed;
    }

    function _raised(Launched memory l) private view returns (uint256) {
        return l.auction.lbpInitializationParams().currencyRaised;
    }
}

/// @dev A route that consumes all but `residue` of the STOCK it is handed and returns that residue to
///      the recipient, exercising the re-credit path.
contract ResidueRoute {
    address public immutable stock;
    address public immutable usdc = StocksBindings.USDC;
    uint256 public immutable residue;

    constructor(address stock_, uint256 residue_) {
        stock = stock_;
        residue = residue_;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256, address recipient)
        external
        returns (uint256 amountOut)
    {
        require(tokenIn == stock && tokenOut == usdc, "pair");
        amountOut = (amountIn - residue) * 230_000000 / 1e8;
        FixtureStockToken(stock).transfer(recipient, residue);
        FixtureStockToken(usdc).transfer(recipient, amountOut);
    }

    function quoteExactIn(address, address, uint256 amountIn) external view returns (uint256) {
        return (amountIn - residue) * 230_000000 / 1e8;
    }
}
