// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {RegentFeeHook} from "../../src/hook/RegentFeeHook.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {HookFixture} from "../mocks/HookFixture.sol";
import {HookReentrancyProbe} from "../mocks/HookReentrancyProbe.sol";
import {HostileHookSplitter} from "../mocks/HostileHookSplitter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {SimpleSwapRouter} from "../mocks/SimpleSwapRouter.sol";

/// @notice Claim-level FA-07 coverage against the pinned PoolManager and real splitter.
contract RegentFeeHookTest is HookFixture {
    uint160 internal constant MIN_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    struct TokenLedger {
        uint256 safe;
        uint256 treasury;
        uint256 hookBalance;
        uint256 splitter;
        uint256 managerBalance;
        uint256 trader;
        uint256 allowance;
    }

    function setUp() public {
        _deployHookSystem();
    }

    function test_HOK_003_FA07_I3_ImmutableBindingsAndExactRegistrationAuthority() public {
        assertEq(address(hook.poolManager()), address(manager), "FA07-I3 PoolManager binding");
        assertEq(hook.strategy(), strategy, "FA07-I3 strategy binding");

        MockERC20 subject = _etchToken(SUBJECT_LOW, SUBJECT_TOTAL_SUPPLY);
        SubjectSplitterV1 splitter = _newSplitter(SUBJECT_LOW);
        PoolKey memory key = _officialKey(SUBJECT_LOW);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RegentFeeHook.NotStrategy.selector, outsider));
        hook.registerPool(key, address(splitter));

        PoolKey memory wrong = _copyKey(key);
        wrong.fee = 500;
        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(RegentFeeHook.UnexpectedPoolFee.selector, uint24(500)));
        hook.registerPool(wrong, address(splitter));

        wrong = _copyKey(key);
        wrong.hooks = IHooks(address(0));
        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(RegentFeeHook.ForeignHook.selector, address(0)));
        hook.registerPool(wrong, address(splitter));

        HostileHookSplitter foreignSubject = new HostileHookSplitter(REGENT, SUBJECT_HIGH, REGENT_SAFE);
        vm.prank(strategy);
        vm.expectRevert(
            abi.encodeWithSelector(RegentFeeHook.SplitterBindingMismatch.selector, SUBJECT_LOW, SUBJECT_HIGH)
        );
        hook.registerPool(key, address(foreignSubject));

        vm.expectEmit(true, true, true, true, address(hook));
        emit RegentFeeHook.PoolRegistered(key.toId(), address(splitter), SUBJECT_LOW);
        vm.prank(strategy);
        hook.registerPool(key, address(splitter));

        assertEq(hook.splitterOf(key.toId()), address(splitter), "FA07-I3 exact key binding");
        assertEq(subject.balanceOf(address(hook)), 0, "FA07-I3 registration moved value");
        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(RegentFeeHook.PoolAlreadyRegistered.selector, key.toId()));
        hook.registerPool(key, address(splitter));
    }

    function test_HOK_003_FA07_I3_PermissionsAndInheritedBeforeSwapBoundaryAreExact() public {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeInitialize, "FA07-I3 beforeInitialize");
        assertTrue(permissions.afterSwap, "FA07-I3 afterSwap");
        assertTrue(permissions.afterSwapReturnDelta, "FA07-I3 afterSwapReturnDelta");
        assertFalse(permissions.beforeSwap, "FA07-I3 beforeSwap disabled");
        assertFalse(permissions.beforeSwapReturnDelta, "FA07-I3 beforeSwapReturnDelta disabled");
        assertFalse(permissions.afterInitialize, "FA07-I3 afterInitialize");
        assertFalse(permissions.beforeAddLiquidity, "FA07-I3 beforeAddLiquidity");
        assertFalse(permissions.afterAddLiquidity, "FA07-I3 afterAddLiquidity");
        assertFalse(permissions.beforeRemoveLiquidity, "FA07-I3 beforeRemoveLiquidity");
        assertFalse(permissions.afterRemoveLiquidity, "FA07-I3 afterRemoveLiquidity");
        assertFalse(permissions.beforeDonate, "FA07-I3 beforeDonate");
        assertFalse(permissions.afterDonate, "FA07-I3 afterDonate");
        assertFalse(permissions.afterAddLiquidityReturnDelta, "FA07-I3 afterAddLiquidityReturnDelta");
        assertFalse(permissions.afterRemoveLiquidityReturnDelta, "FA07-I3 afterRemoveLiquidityReturnDelta");
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS, "FA07-I3 address bits");

        (address mined, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(RegentFeeHook).creationCode,
            abi.encode(IPoolManager(address(manager)), strategy)
        );
        RegentFeeHook created = new RegentFeeHook{salt: salt}(IPoolManager(address(manager)), strategy);
        assertEq(address(created), mined, "FA07-I3 mined address");

        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        SwapParams memory params = _swapParams(_regentIsInput(pool), -int256(1e18));
        vm.prank(outsider);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(outsider, pool.key, params, "");

        vm.recordLogs();
        _swap(pool, _regentIsInput(pool), -int256(1e18));
        assertEq(_onlySettlement().feeToken, SUBJECT_LOW, "FA07-I3 PoolManager dispatched afterSwap only");
    }

    function test_HOK_006_FA07_I6_ObsoletePreSwapControlPlaneIsAbsent() public {
        string[12] memory forbidden = [
            "flush()",
            "flush(address)",
            "setThreshold(uint256)",
            "setKeeper(address)",
            "pause()",
            "unpause()",
            "setFee(uint24)",
            "setSplitter(bytes32,address)",
            "setStrategy(address)",
            "allowRouter(address)",
            "sweep(address)",
            "recover(address,uint256)"
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            (bool ok, bytes memory returned) =
                address(hook).call(abi.encodeWithSelector(bytes4(keccak256(bytes(forbidden[i])))));
            assertFalse(ok, forbidden[i]);
            assertEq(returned.length, 0, forbidden[i]);
        }

        assertEq(
            RegentFeeHook.SwapFeeSettled.selector,
            keccak256("SwapFeeSettled(bytes32,address,address,uint256,uint256,bool)"),
            "FA07-I6 settlement event identity"
        );
    }

    function test_HOK_001_FA07_I1_AllTradeFormsAndOrderingsUseRealizedUnspecifiedCurrency() public {
        Pool memory low = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        _assertAllFourForms(low);
        Pool memory high = _openPool(SUBJECT_HIGH, DEFAULT_LIQUIDITY);
        _assertAllFourForms(high);
    }

    function test_HOK_001_FA07_I1_PriceLimitedPartialAndZeroFillsRemainValid() public {
        Pool memory p0 = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        _assertPartialAndZero(p0, _regentIsInput(p0), true, SUBJECT_LOW);
        Pool memory p1 = _openPool(SUBJECT_HIGH, DEFAULT_LIQUIDITY);
        _assertPartialAndZero(p1, !_regentIsInput(p1), true, REGENT);
        Pool memory p2 = _openPool(SUBJECT_ALT, DEFAULT_LIQUIDITY);
        _assertPartialAndZero(p2, _regentIsInput(p2), false, REGENT);
        Pool memory p3 = _openPool(SUBJECT_ALT2, DEFAULT_LIQUIDITY);
        _assertPartialAndZero(p3, !_regentIsInput(p3), false, SUBJECT_ALT2);
    }

    function test_HOK_002_FA07_I2_RoundingBoundariesAreMeasuredFromExecution() public {
        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        bool zeroForOne = _regentIsInput(pool);
        bool sawSubThreshold;
        bool sawOneUnitLane;
        bool sawTwoUnitLane;

        for (uint256 amountSpecified = 1; amountSpecified <= 260; ++amountSpecified) {
            vm.recordLogs();
            BalanceDelta delta = _swap(pool, zeroForOne, -int256(amountSpecified));
            Settlement[] memory settlements = _recordedSettlements();
            int128 netOutput = zeroForOne ? delta.amount1() : delta.amount0();
            if (settlements.length == 0) {
                assertLt(uint256(uint128(netOutput)), 100, "FA07-I2 sub-threshold execution charged");
                sawSubThreshold = true;
                continue;
            }
            assertEq(settlements.length, 1, "FA07-I2 more than one settlement");
            Settlement memory settled = settlements[0];
            assertEq(settled.feeToken, SUBJECT_LOW, "FA07-I2 boundary asset");
            assertEq(settled.charged, uint256(uint128(netOutput)) + 2 * settled.lane, "FA07-I2 realized base");
            assertEq(settled.lane, settled.charged / 100, "FA07-I2 independently floored lane");
            if (settled.lane == 1) sawOneUnitLane = true;
            if (settled.lane == 2) sawTwoUnitLane = true;
        }
        assertTrue(sawSubThreshold, "FA07-I2 no measured sub-threshold execution");
        assertTrue(sawOneUnitLane, "FA07-I2 no measured one-unit lane boundary");
        assertTrue(sawTwoUnitLane, "FA07-I2 no measured two-unit lane boundary");
    }

    function test_HOK_002_FA07_I2_BothAssetsRouteInKindWithExactCleanLanes() public {
        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        regent.transfer(address(hook), 777);
        pool.subject.transfer(address(hook), 888);

        vm.recordLogs();
        _swap(pool, _regentIsInput(pool), -int256(1e18));
        assertEq(_onlySettlement().feeToken, SUBJECT_LOW, "FA07-I2 SUBJECT lane");
        vm.recordLogs();
        _swap(pool, !_regentIsInput(pool), -int256(1e18));
        assertEq(_onlySettlement().feeToken, REGENT, "FA07-I2 REGENT lane");

        assertEq(regent.balanceOf(address(hook)), 777, "FA07-I4 REGENT gift changed");
        assertEq(pool.subject.balanceOf(address(hook)), 888, "FA07-I4 SUBJECT gift changed");
        assertEq(regent.allowance(address(hook), address(pool.splitter)), 0, "FA07-I4 REGENT allowance");
        assertEq(pool.subject.allowance(address(hook), address(pool.splitter)), 0, "FA07-I4 SUBJECT allowance");
    }

    function test_HOK_005_FA07_I5_PostHookWalletLimitsAreExact() public {
        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        _assertRouterLimits(pool, _regentIsInput(pool), -int256(1e18));
        _assertRouterLimits(pool, !_regentIsInput(pool), -int256(1e18));
        _assertRouterLimits(pool, _regentIsInput(pool), int256(1e18));
        _assertRouterLimits(pool, !_regentIsInput(pool), int256(1e18));
    }

    function test_HOK_004_FA07_I4_SplitterFailuresRollbackBothFeeAssets() public {
        Pool memory pool = _openHostilePool(SUBJECT_HIGH, DEFAULT_LIQUIDITY);
        _assertHostileFailures(pool, _regentIsInput(pool), pool.subject);
        _assertHostileFailures(pool, !_regentIsInput(pool), regent);
    }

    function test_HOK_004_FA07_I4_ExactOutputReserveExhaustionRollsBack() public {
        Pool memory pool = _openPool(SUBJECT_LOW, 1e18);
        _assertReserveExhaustion(pool, _regentIsInput(pool), regent);
        _assertReserveExhaustion(pool, !_regentIsInput(pool), pool.subject);
    }

    function test_HOK_004_FA07_I4_ForeignAndReentrantCallbacksGainNoAuthority() public {
        Pool memory pool = _openHostilePool(SUBJECT_HIGH, DEFAULT_LIQUIDITY);
        HostileHookSplitter hostile = HostileHookSplitter(hook.splitterOf(pool.id));
        bool zeroForOne = _regentIsInput(pool);
        SwapParams memory params = _swapParams(zeroForOne, -int256(1e18));
        HookReentrancyProbe probe = new HookReentrancyProbe();
        probe.arm(
            address(hook),
            abi.encodeCall(RegentFeeHook.registerPool, (pool.key, address(hostile))),
            abi.encodeCall(IHooks.afterSwap, (address(probe), pool.key, params, BalanceDelta.wrap(0), ""))
        );
        hostile.setReentry(address(probe), abi.encodeCall(HookReentrancyProbe.probe, ()));

        vm.recordLogs();
        _swap(pool, zeroForOne, -int256(1e18));
        Settlement memory settled = _onlySettlement();
        assertEq(probe.probes(), 1, "FA07-I4 reentrancy probe did not run");
        assertFalse(probe.firstSucceeded(), "FA07-I3 reentrant registration succeeded");
        assertFalse(probe.secondSucceeded(), "FA07-I3 reentrant callback succeeded");
        assertTrue(_containsSelector(probe.firstReturn(), RegentFeeHook.NotStrategy.selector), "FA07-I3 registration");
        assertTrue(
            _containsSelector(probe.secondReturn(), ImmutableState.NotPoolManager.selector), "FA07-I3 callback boundary"
        );
        assertEq(settled.feeToken, SUBJECT_HIGH, "FA07-I4 reentrancy changed fee token");
        assertEq(pool.subject.balanceOf(address(hook)), 0, "FA07-I4 reentrancy retained fee token");
        assertEq(pool.subject.allowance(address(hook), address(hostile)), 0, "FA07-I4 reentrancy allowance");
    }

    function test_HOK_005_FA07_I5_EventUsesRouterContextWithoutAuthority() public {
        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        vm.recordLogs();
        BalanceDelta delta = altRouter.swap(pool.key, _swapParams(_regentIsInput(pool), -int256(1e18)));
        Settlement memory settled = _onlySettlement();
        assertEq(PoolId.unwrap(settled.poolId), PoolId.unwrap(pool.id), "FA07-I5 pool");
        assertEq(settled.sender, address(altRouter), "FA07-I5 sender is router context");
        assertEq(settled.feeToken, SUBJECT_LOW, "FA07-I5 fee token");
        assertTrue(settled.exactInput, "FA07-I5 exact-input mode");
        int128 netOutput = pool.regentIsCurrency0 ? delta.amount1() : delta.amount0();
        assertEq(settled.charged, uint256(uint128(netOutput)) + 2 * settled.lane, "FA07-I5 realized base");
    }

    function _assertAllFourForms(Pool memory pool) private {
        bool regentIn = _regentIsInput(pool);
        _assertShape(pool, regentIn, -int256(1e18), address(pool.subject));
        _assertShape(pool, regentIn, int256(1e18), REGENT);
        _assertShape(pool, !regentIn, -int256(1e18), REGENT);
        _assertShape(pool, !regentIn, int256(1e18), address(pool.subject));
    }

    function _assertShape(Pool memory pool, bool zeroForOne, int256 amountSpecified, address expectedFeeToken) private {
        MockERC20 feeToken = MockERC20(expectedFeeToken);
        TokenLedger memory before = _tokenLedger(pool, feeToken);
        vm.recordLogs();
        BalanceDelta delta = _swap(pool, zeroForOne, amountSpecified);
        Settlement memory settled = _onlySettlement();

        bool exactInput = amountSpecified < 0;
        bool specifiedIsCurrency0 = exactInput == zeroForOne;
        int128 specifiedDelta = specifiedIsCurrency0 ? delta.amount0() : delta.amount1();
        int128 unspecifiedDelta = specifiedIsCurrency0 ? delta.amount1() : delta.amount0();
        uint256 postHookUnspecified = _abs(unspecifiedDelta);
        uint256 feeBase = exactInput ? postHookUnspecified + 2 * settled.lane : postHookUnspecified - 2 * settled.lane;

        assertEq(settled.feeToken, expectedFeeToken, "FA07-I1 unspecified fee token");
        assertEq(settled.charged, feeBase, "FA07-I1 actual realized fee base");
        assertEq(settled.lane, feeBase / 100, "FA07-I2 lane");
        assertEq(settled.exactInput, exactInput, "FA07-I5 event mode");
        assertEq(
            specifiedDelta,
            exactInput ? -int128(int256(_abs256(amountSpecified))) : int128(int256(uint256(amountSpecified))),
            "FA07-I1 specified core result changed"
        );
        _assertLanesInKind(pool, feeToken, before, settled.lane);
    }

    function _assertPartialAndZero(Pool memory pool, bool zeroForOne, bool exactInput, address expectedFeeToken)
        private
    {
        int256 requested = exactInput ? -int256(1e21) : int256(1e21);
        uint160 current = _currentSqrtPrice(pool);
        uint160 partialLimit = zeroForOne ? current - (current / 1000) : current + (current / 1000);
        vm.recordLogs();
        BalanceDelta partialDelta = _swapWithLimit(pool, zeroForOne, requested, partialLimit);
        Settlement memory settled = _onlySettlement();
        bool specifiedIsCurrency0 = exactInput == zeroForOne;
        int128 specifiedDelta = specifiedIsCurrency0 ? partialDelta.amount0() : partialDelta.amount1();
        int128 unspecifiedDelta = specifiedIsCurrency0 ? partialDelta.amount1() : partialDelta.amount0();
        uint256 postHookUnspecified = _abs(unspecifiedDelta);
        uint256 feeBase = exactInput ? postHookUnspecified + 2 * settled.lane : postHookUnspecified - 2 * settled.lane;
        assertEq(settled.feeToken, expectedFeeToken, "FA07-I1 partial fee token");
        assertEq(settled.charged, feeBase, "FA07-I1 partial realized base");
        assertGt(_abs(specifiedDelta), 0, "FA07-I1 partial fill executed nothing");
        assertLt(_abs(specifiedDelta), _abs256(requested), "FA07-I1 price limit did not create partial fill");

        current = _currentSqrtPrice(pool);
        uint160 zeroLimit = zeroForOne ? current - 1 : current + 1;
        vm.recordLogs();
        BalanceDelta zero = _swapWithLimit(pool, zeroForOne, requested, zeroLimit);
        int128 zeroSpecified = specifiedIsCurrency0 ? zero.amount0() : zero.amount1();
        int128 zeroUnspecified = specifiedIsCurrency0 ? zero.amount1() : zero.amount0();
        int128 zeroOutput = exactInput ? zeroUnspecified : zeroSpecified;
        int128 dustInput = exactInput ? zeroSpecified : zeroUnspecified;
        assertEq(zeroOutput, 0, "FA07-I1 zero fill realized output currency");
        assertLt(_abs(dustInput), 100, "FA07-I2 zero fill crossed lane floor");
        assertEq(_recordedSettlements().length, 0, "FA07-I2 zero fill settled a lane");
    }

    function _assertRouterLimits(Pool memory pool, bool zeroForOne, int256 amountSpecified) private {
        SwapParams memory params = _swapParams(zeroForOne, amountSpecified);
        uint256 snapshot = vm.snapshotState();
        BalanceDelta measured = altRouter.swap(pool.key, params);
        bool specifiedIsCurrency0 = (amountSpecified < 0) == zeroForOne;
        uint256 postHookAmount = _abs(specifiedIsCurrency0 ? measured.amount1() : measured.amount0());
        vm.revertToState(snapshot);

        if (amountSpecified < 0) {
            altRouter.swapWithLimits(pool.key, params, postHookAmount, type(uint256).max);
            vm.revertToState(snapshot);
            vm.expectRevert(
                abi.encodeWithSelector(SimpleSwapRouter.InsufficientOutput.selector, postHookAmount + 1, postHookAmount)
            );
            altRouter.swapWithLimits(pool.key, params, postHookAmount + 1, type(uint256).max);
        } else {
            altRouter.swapWithLimits(pool.key, params, 0, postHookAmount);
            vm.revertToState(snapshot);
            vm.expectRevert(
                abi.encodeWithSelector(SimpleSwapRouter.ExcessiveInput.selector, postHookAmount - 1, postHookAmount)
            );
            altRouter.swapWithLimits(pool.key, params, 0, postHookAmount - 1);
        }
        vm.revertToState(snapshot);
    }

    function _assertHostileFailures(Pool memory pool, bool zeroForOne, MockERC20 feeToken) private {
        HostileHookSplitter hostile = HostileHookSplitter(hook.splitterOf(pool.id));
        TokenLedger memory before = _tokenLedger(pool, feeToken);
        uint160 sqrtBefore = _currentSqrtPrice(pool);

        hostile.setReverts(true);
        (bool ok, bytes memory returned) = _trySwap(pool, zeroForOne, -int256(1e18), zeroForOne ? MIN_LIMIT : MAX_LIMIT);
        assertFalse(ok, "FA07-I4 reverting splitter succeeded");
        assertTrue(_containsSelector(returned, HostileHookSplitter.HostileRevert.selector), "FA07-I4 splitter revert");
        _assertRollback(pool, feeToken, before, sqrtBefore);
        hostile.setReverts(false);

        hostile.setPullsPartially(true);
        (ok, returned) = _trySwap(pool, zeroForOne, -int256(1e18), zeroForOne ? MIN_LIMIT : MAX_LIMIT);
        assertFalse(ok, "FA07-I4 under-pulling splitter succeeded");
        assertTrue(
            _containsSelector(returned, RegentFeeHook.AttributableBalanceNotRestored.selector), "FA07-I4 under-pull"
        );
        _assertRollback(pool, feeToken, before, sqrtBefore);
        hostile.setPullsPartially(false);

        hostile.setRefunds(true);
        (ok, returned) = _trySwap(pool, zeroForOne, -int256(1e18), zeroForOne ? MIN_LIMIT : MAX_LIMIT);
        assertFalse(ok, "FA07-I4 refunding splitter succeeded");
        assertTrue(_containsSelector(returned, RegentFeeHook.AttributableBalanceNotRestored.selector), "FA07-I4 refund");
        _assertRollback(pool, feeToken, before, sqrtBefore);
        hostile.setRefunds(false);
    }

    function _assertReserveExhaustion(Pool memory pool, bool zeroForOne, MockERC20 feeToken) private {
        TokenLedger memory before = _tokenLedger(pool, feeToken);
        uint160 sqrtBefore = _currentSqrtPrice(pool);
        (bool ok, bytes memory returned) = _trySwap(pool, zeroForOne, int256(99e16), zeroForOne ? MIN_LIMIT : MAX_LIMIT);
        assertFalse(ok, "FA07-I4 exact-output reserve exhaustion succeeded");
        assertTrue(
            _containsSelector(returned, CurrencyLibrary.ERC20TransferFailed.selector),
            "FA07-I4 reserve boundary failed elsewhere"
        );
        _assertRollback(pool, feeToken, before, sqrtBefore);
    }

    function _assertRollback(Pool memory pool, MockERC20 feeToken, TokenLedger memory before, uint160 sqrtBefore)
        private
        view
    {
        TokenLedger memory after_ = _tokenLedger(pool, feeToken);
        assertEq(after_.safe, before.safe, "FA07-I4 Safe rolled forward");
        assertEq(after_.treasury, before.treasury, "FA07-I4 treasury rolled forward");
        assertEq(after_.hookBalance, before.hookBalance, "FA07-I4 hook rolled forward");
        assertEq(after_.splitter, before.splitter, "FA07-I4 splitter rolled forward");
        assertEq(after_.managerBalance, before.managerBalance, "FA07-I4 manager rolled forward");
        assertEq(after_.trader, before.trader, "FA07-I4 trader rolled forward");
        assertEq(after_.allowance, before.allowance, "FA07-I4 allowance rolled forward");
        assertEq(_currentSqrtPrice(pool), sqrtBefore, "FA07-I4 pool state rolled forward");
    }

    function _assertLanesInKind(Pool memory pool, MockERC20 feeToken, TokenLedger memory before, uint256 lane)
        private
        view
    {
        uint256 skim = (lane * pool.splitter.SKIM_BPS()) / pool.splitter.BPS_DENOMINATOR();
        assertEq(feeToken.balanceOf(REGENT_SAFE), before.safe + lane + skim, "FA07-I2 Safe lane");
        assertEq(feeToken.balanceOf(treasury), before.treasury + lane - skim, "FA07-I2 splitter lane");
        assertEq(feeToken.balanceOf(address(hook)), before.hookBalance, "FA07-I4 hook balance");
        assertEq(feeToken.allowance(address(hook), address(pool.splitter)), before.allowance, "FA07-I4 hook allowance");
    }

    function _tokenLedger(Pool memory pool, MockERC20 token) private view returns (TokenLedger memory found) {
        address splitter = hook.splitterOf(pool.id);
        found.safe = token.balanceOf(REGENT_SAFE);
        found.treasury = token.balanceOf(treasury);
        found.hookBalance = token.balanceOf(address(hook));
        found.splitter = token.balanceOf(splitter);
        found.managerBalance = token.balanceOf(address(manager));
        found.trader = token.balanceOf(address(this));
        found.allowance = token.allowance(address(hook), splitter);
    }

    function _officialKey(address subjectAddress) private view returns (PoolKey memory key) {
        (Currency currency0, Currency currency1) = REGENT < subjectAddress
            ? (Currency.wrap(REGENT), Currency.wrap(subjectAddress))
            : (Currency.wrap(subjectAddress), Currency.wrap(REGENT));
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.POOL_TICK_SPACING(),
            hooks: IHooks(address(hook))
        });
    }

    function _copyKey(PoolKey memory key) private pure returns (PoolKey memory copied) {
        copied = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: key.hooks
        });
    }

    function _openHostilePool(address subjectAddress, uint256 liquidity) private returns (Pool memory pool) {
        pool.subject = _etchToken(subjectAddress, SUBJECT_TOTAL_SUPPLY);
        pool.regentIsCurrency0 = REGENT < subjectAddress;
        pool.key = _officialKey(subjectAddress);
        pool.id = pool.key.toId();
        HostileHookSplitter hostile = new HostileHookSplitter(REGENT, subjectAddress, REGENT_SAFE);
        vm.prank(strategy);
        hook.registerPool(pool.key, address(hostile));
        vm.prank(strategy);
        manager.initialize(pool.key, SQRT_PRICE_1_1);
        _approveAll(pool.subject);
        _addLiquidity(pool, liquidity);
    }

    function _abs(int128 value) private pure returns (uint256) {
        int256 widened = int256(value);
        return uint256(widened < 0 ? -widened : widened);
    }

    function _abs256(int256 value) private pure returns (uint256) {
        return uint256(value < 0 ? -value : value);
    }
}
