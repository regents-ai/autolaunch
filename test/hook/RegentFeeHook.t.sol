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
import {BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {RegentFeeHook} from "../../src/hook/RegentFeeHook.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {HookFixture} from "../mocks/HookFixture.sol";
import {HookReentrancyProbe} from "../mocks/HookReentrancyProbe.sol";
import {HostileHookSplitter} from "../mocks/HostileHookSplitter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {NestedSwapAttacker} from "../mocks/NestedSwapAttacker.sol";

/// @notice C2 claim coverage for `RegentFeeHook`, `HOK-001` through `HOK-019`.
/// @dev Every fee-path claim runs against the real pinned `PoolManager` and a real pinned swap
///      router, with the real `SubjectSplitterV1` on the receiving end. `INV-004` and `INV-010`
///      stay pending for C5's stateful invariant gate; nothing here closes them.
contract RegentFeeHookTest is HookFixture {
    /// @dev Solidity's `Panic(uint256)` selector, the shape an exhausted ERC20 allowance takes.
    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;

    uint160 internal constant MIN_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    function setUp() public {
        _deployHookSystem();
    }

    // =========================================================================
    // HOK-001 — immutable bindings
    // =========================================================================

    function test_HOK_001_BindingToStrategyAndPoolManagerIsImmutable() public {
        assertEq(address(hook.poolManager()), address(manager), "PoolManager binding");
        assertEq(hook.strategy(), strategy, "strategy binding");

        // The bindings survive every reachable production operation.
        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        _swap(pool, _regentIsInput(pool), -1e18);
        assertEq(address(hook.poolManager()), address(manager), "PoolManager binding after use");
        assertEq(hook.strategy(), strategy, "strategy binding after use");

        // A zero or self strategy can never be bound in the first place.
        (bool ok, bytes memory returned) = _constructHookAt(_freeHookAddress(1), address(manager), address(0));
        assertFalse(ok, "zero strategy accepted");
        assertEq(bytes4(returned), RegentFeeHook.ZeroStrategy.selector, "zero strategy error");

        address selfBound = _freeHookAddress(2);
        (ok, returned) = _constructHookAt(selfBound, address(manager), selfBound);
        assertFalse(ok, "self strategy accepted");
        assertEq(bytes4(returned), RegentFeeHook.SelfStrategy.selector, "self strategy error");
    }

    // =========================================================================
    // HOK-002 — strategy-only, exact-key registration
    // =========================================================================

    function test_HOK_002_OnlyTheStrategyRegistersAnExactPoolKey() public {
        MockERC20 subject = _etchToken(SUBJECT_LOW);
        SubjectSplitterV1 splitter = _newSplitter(SUBJECT_LOW);
        PoolKey memory key = _officialKey(SUBJECT_LOW);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RegentFeeHook.NotStrategy.selector, outsider));
        hook.registerPool(key, address(splitter));

        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(RegentFeeHook.NotStrategy.selector, address(manager)));
        hook.registerPool(key, address(splitter));

        // Every field of the key is exact. Each variant is an independent copy, because assigning
        // one memory struct to another aliases it rather than duplicating it.
        PoolKey memory wrong = _copyKey(key);
        wrong.hooks = IHooks(address(0));
        _expectRegisterRevert(
            wrong, address(splitter), abi.encodeWithSelector(RegentFeeHook.ForeignHook.selector, address(0))
        );

        wrong = _copyKey(key);
        wrong.fee = 500;
        _expectRegisterRevert(
            wrong, address(splitter), abi.encodeWithSelector(RegentFeeHook.UnexpectedPoolFee.selector, uint24(500))
        );

        wrong = _copyKey(key);
        wrong.tickSpacing = 10;
        _expectRegisterRevert(
            wrong, address(splitter), abi.encodeWithSelector(RegentFeeHook.UnexpectedTickSpacing.selector, int24(10))
        );

        // Reversed ordering is rejected before any write-once state is consumed.
        wrong = _copyKey(key);
        (wrong.currency0, wrong.currency1) = (key.currency1, key.currency0);
        _expectRegisterRevert(
            wrong,
            address(splitter),
            abi.encodeWithSelector(
                RegentFeeHook.CurrencyOrderInvalid.selector,
                Currency.unwrap(key.currency1),
                Currency.unwrap(key.currency0)
            )
        );
        assertEq(hook.splitterOf(wrong.toId()), address(0), "rejected ordering consumed state");

        wrong = _copyKey(key);
        wrong.currency0 = Currency.wrap(address(0));
        _expectRegisterRevert(wrong, address(splitter), abi.encodeWithSelector(RegentFeeHook.NativeCurrency.selector));

        // A pool with no REGENT side at all.
        wrong = _copyKey(key);
        wrong.currency0 = Currency.wrap(SUBJECT_LOW);
        wrong.currency1 = Currency.wrap(SUBJECT_HIGH);
        _expectRegisterRevert(
            wrong, address(splitter), abi.encodeWithSelector(RegentFeeHook.RegentNotInPoolKey.selector)
        );

        // The splitter must be deployed and must be bound to this exact launch.
        _expectRegisterRevert(key, outsider, abi.encodeWithSelector(RegentFeeHook.SplitterHasNoCode.selector, outsider));

        HostileHookSplitter foreignSubject = new HostileHookSplitter(REGENT, SUBJECT_HIGH, REGENT_SAFE);
        _expectRegisterRevert(
            key,
            address(foreignSubject),
            abi.encodeWithSelector(RegentFeeHook.SplitterBindingMismatch.selector, SUBJECT_LOW, SUBJECT_HIGH)
        );

        HostileHookSplitter foreignRegent = new HostileHookSplitter(SUBJECT_HIGH, SUBJECT_LOW, REGENT_SAFE);
        _expectRegisterRevert(
            key,
            address(foreignRegent),
            abi.encodeWithSelector(RegentFeeHook.SplitterBindingMismatch.selector, REGENT, SUBJECT_HIGH)
        );

        HostileHookSplitter foreignSafe = new HostileHookSplitter(REGENT, SUBJECT_LOW, outsider);
        _expectRegisterRevert(
            key,
            address(foreignSafe),
            abi.encodeWithSelector(RegentFeeHook.SplitterBindingMismatch.selector, REGENT_SAFE, outsider)
        );

        // The exact key from the exact caller registers, once, with its event.
        vm.expectEmit(true, true, true, true, address(hook));
        emit RegentFeeHook.PoolRegistered(key.toId(), address(splitter), SUBJECT_LOW);
        vm.prank(strategy);
        hook.registerPool(key, address(splitter));

        assertEq(hook.splitterOf(key.toId()), address(splitter), "registered splitter");
        assertEq(subject.balanceOf(address(hook)), 0, "registration moved value");
    }

    // =========================================================================
    // HOK-003 — write-once registration
    // =========================================================================

    function test_HOK_003_PoolKeyRegistrationIsOnceAndFinal() public {
        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        assertEq(hook.splitterOf(pool.id), address(pool.splitter), "first registration");

        SubjectSplitterV1 replacement = _newSplitter(SUBJECT_LOW);

        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(RegentFeeHook.PoolAlreadyRegistered.selector, pool.id));
        hook.registerPool(pool.key, address(replacement));

        vm.prank(strategy);
        vm.expectRevert(abi.encodeWithSelector(RegentFeeHook.PoolAlreadyRegistered.selector, pool.id));
        hook.registerPool(pool.key, address(pool.splitter));

        assertEq(hook.splitterOf(pool.id), address(pool.splitter), "registration replaced");

        // A different launch registers independently and does not disturb the first.
        Pool memory other = _openPool(SUBJECT_HIGH, DEFAULT_LIQUIDITY);
        assertEq(hook.splitterOf(other.id), address(other.splitter), "second registration");
        assertEq(hook.splitterOf(pool.id), address(pool.splitter), "first registration disturbed");
    }

    // =========================================================================
    // HOK-004 — exactly the five required permission bits
    // =========================================================================

    function test_HOK_004_HookPermissionsAreExactlyThoseRequired() public {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeInitialize, "beforeInitialize");
        assertTrue(permissions.beforeSwap, "beforeSwap");
        assertTrue(permissions.afterSwap, "afterSwap");
        assertTrue(permissions.beforeSwapReturnDelta, "beforeSwapReturnDelta");
        assertTrue(permissions.afterSwapReturnDelta, "afterSwapReturnDelta");

        assertFalse(permissions.afterInitialize, "afterInitialize");
        assertFalse(permissions.beforeAddLiquidity, "beforeAddLiquidity");
        assertFalse(permissions.afterAddLiquidity, "afterAddLiquidity");
        assertFalse(permissions.beforeRemoveLiquidity, "beforeRemoveLiquidity");
        assertFalse(permissions.afterRemoveLiquidity, "afterRemoveLiquidity");
        assertFalse(permissions.beforeDonate, "beforeDonate");
        assertFalse(permissions.afterDonate, "afterDonate");
        assertFalse(permissions.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta");
        assertFalse(permissions.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta");

        // The deployed address carries those five bits and no others.
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS, "address permission bits");

        // The pinned miner and a real CREATE2 deployment agree with the same constructor.
        (address mined, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(RegentFeeHook).creationCode,
            abi.encode(IPoolManager(address(manager)), strategy)
        );
        RegentFeeHook created = new RegentFeeHook{salt: salt}(IPoolManager(address(manager)), strategy);
        assertEq(address(created), mined, "mined address");
        assertEq(uint160(address(created)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS, "mined permission bits");

        // Production validation is real: an address without the bits cannot carry this code.
        address wrongBits = address(uint160(uint256(0x5555) << 144));
        (bool ok, bytes memory returned) = _constructHookAt(wrongBits, address(manager), strategy);
        assertFalse(ok, "wrong-flag address accepted");
        assertEq(bytes4(returned), Hooks.HookAddressNotValid.selector, "wrong-flag address rejected by another error");
    }

    // =========================================================================
    // HOK-005 / HOK-006 — REGENT as the specified currency
    // =========================================================================

    function test_HOK_005_ExactInputChargesRegentWhenSpecified() public {
        _assertSpecifiedShape(SUBJECT_LOW, true);
        _assertSpecifiedShape(SUBJECT_HIGH, true);
    }

    function test_HOK_006_ExactOutputChargesRegentWhenSpecified() public {
        _assertSpecifiedShape(SUBJECT_LOW, false);
        _assertSpecifiedShape(SUBJECT_HIGH, false);

        // Frozen V1 behavior: the specified lane charges against the *requested* specified amount,
        // so a price-limited fill can charge against more REGENT than the pool actually exchanges.
        Pool memory pool = _openPool(SUBJECT_ALT, DEFAULT_LIQUIDITY);
        bool zeroForOne = !_regentIsInput(pool);
        uint160 current = _currentSqrtPrice(pool);

        // Partial fill: the limit stops the swap well short of the requested output.
        uint160 partialLimit = zeroForOne ? current - (current / 1000) : current + (current / 1000);
        Ledger memory before = _ledger(pool, address(this));
        uint256 systemBefore = _regentInSystem(pool, address(this));

        vm.recordLogs();
        BalanceDelta delta = _swapWithLimit(pool, zeroForOne, int256(1e21), partialLimit);
        Settlement memory settled = _onlySettlement();

        assertEq(settled.charged, 1e21, "partial fill charged the requested specified amount");
        assertEq(settled.lane, 1e19, "partial fill lane");

        // The REGENT the pool actually exchanged is the trader's net delta plus both lanes, and it
        // is far below the requested amount the lanes were charged against.
        int128 regentDelta = pool.regentIsCurrency0 ? delta.amount0() : delta.amount1();
        int256 exchanged = int256(regentDelta) + int256(2 * settled.lane);
        assertGt(exchanged, int256(0), "partial fill exchanged nothing at all");
        assertLt(exchanged, int256(settled.charged), "the price limit did not restrict the fill");
        _assertLanesLanded(pool, before, settled.lane);
        assertEq(_regentInSystem(pool, address(this)), systemBefore, "REGENT conservation on partial fill");

        // Zero fill: the limit is one unit away, so the pool exchanges essentially nothing while the
        // hook still charges both lanes against the requested amount and every delta still closes.
        current = _currentSqrtPrice(pool);
        uint160 zeroLimit = zeroForOne ? current - 1 : current + 1;
        before = _ledger(pool, address(this));
        systemBefore = _regentInSystem(pool, address(this));

        vm.recordLogs();
        delta = _swapWithLimit(pool, zeroForOne, int256(1e21), zeroLimit);
        settled = _onlySettlement();

        assertEq(settled.charged, 1e21, "zero fill charged the requested specified amount");
        assertEq(settled.lane, 1e19, "zero fill lane");
        regentDelta = pool.regentIsCurrency0 ? delta.amount0() : delta.amount1();
        exchanged = int256(regentDelta) + int256(2 * settled.lane);
        assertEq(exchanged, int256(0), "the zero fill exchanged REGENT after all");
        assertEq(
            regentDelta,
            -int128(int256(2 * settled.lane)),
            "a zero fill must still leave the trader paying exactly both lanes"
        );
        _assertLanesLanded(pool, before, settled.lane);
        assertEq(_regentInSystem(pool, address(this)), systemBefore, "REGENT conservation on zero fill");
    }

    // =========================================================================
    // HOK-007 / HOK-008 — REGENT as the unspecified currency
    // =========================================================================

    function test_HOK_007_ExactOutputChargesRegentWhenUnspecified() public {
        _assertUnspecifiedShape(SUBJECT_LOW, false);
        _assertUnspecifiedShape(SUBJECT_HIGH, false);
    }

    function test_HOK_008_ExactInputChargesRegentWhenUnspecified() public {
        _assertUnspecifiedShape(SUBJECT_LOW, true);
        _assertUnspecifiedShape(SUBJECT_HIGH, true);
    }

    // =========================================================================
    // HOK-009 — two independently floored lanes
    // =========================================================================

    function test_HOK_009_TwoOnePercentLanesAreFlooredIndependently() public {
        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        bool zeroForOne = _regentIsInput(pool);

        uint256[2] memory inputs = [uint256(150), uint256(1050)];
        for (uint256 i; i < inputs.length; ++i) {
            uint256 charged = inputs[i];
            uint256 lane = charged / 100;

            // The distinguishing case: two floored 1% lanes are strictly less than one floored 2%.
            assertLt(2 * lane, (2 * charged) / 100, "input does not distinguish the two roundings");

            Ledger memory before = _ledger(pool, address(this));
            vm.recordLogs();
            BalanceDelta delta = _swap(pool, zeroForOne, -int256(charged));
            Settlement memory settled = _onlySettlement();

            assertEq(settled.charged, charged, "charged amount");
            assertEq(settled.lane, lane, "floored lane");

            int128 regentDelta = pool.regentIsCurrency0 ? delta.amount0() : delta.amount1();
            assertEq(regentDelta, -int128(int256(charged)), "trader pays exactly the specified amount");
            _assertLanesLanded(pool, before, lane);

            // Both lanes are the same floored amount, and their sum — not one floored 2% — is what
            // the pool gave up. The singleton keeps the charge less exactly `2 * lane`.
            uint256 skim = _skim(pool, lane);
            assertEq(
                regent.balanceOf(treasury),
                before.treasuryRegent + lane - skim,
                "the splitter lane differed from the direct lane"
            );
            assertEq(
                regent.balanceOf(address(manager)),
                before.managerRegent + charged - 2 * lane,
                "the pool gave up other than two independently floored lanes"
            );
        }
    }

    // =========================================================================
    // HOK-010 / HOK-011 — the two lane destinations
    // =========================================================================

    function test_HOK_010_OneLaneGoesDirectlyToTheRegentSafe() public {
        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        bool zeroForOne = _regentIsInput(pool);

        // A lane of 49 skims nothing at the splitter, so the Safe delta is the direct lane alone.
        Ledger memory before = _ledger(pool, address(this));
        vm.recordLogs();
        _swap(pool, zeroForOne, -int256(4999));
        Settlement memory settled = _onlySettlement();

        assertEq(settled.lane, 49, "lane");
        assertEq((settled.lane * pool.splitter.SKIM_BPS()) / pool.splitter.BPS_DENOMINATOR(), 0, "skim is not zero");
        assertEq(regent.balanceOf(REGENT_SAFE), before.safeRegent + 49, "direct lane to the Regent Safe");
        assertEq(regent.balanceOf(treasury), before.treasuryRegent + 49, "splitter lane net to the treasury");

        // With a larger lane the Safe receives the direct lane plus the splitter's REGENT skim.
        before = _ledger(pool, address(this));
        vm.recordLogs();
        _swap(pool, zeroForOne, -int256(1e18));
        settled = _onlySettlement();

        uint256 skim = (settled.lane * pool.splitter.SKIM_BPS()) / pool.splitter.BPS_DENOMINATOR();
        assertGt(skim, 0, "expected a nonzero skim");
        assertEq(regent.balanceOf(REGENT_SAFE), before.safeRegent + settled.lane + skim, "Safe total");
    }

    function test_HOK_011_OtherLaneGoesToTheSplitterAndIsSkimmed() public {
        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        bool zeroForOne = _regentIsInput(pool);

        // Zero stake: the splitter's net goes straight to the immutable launch treasury.
        Ledger memory before = _ledger(pool, address(this));
        vm.recordLogs();
        _swap(pool, zeroForOne, -int256(1e18));
        Settlement memory settled = _onlySettlement();

        uint256 skim = (settled.lane * pool.splitter.SKIM_BPS()) / pool.splitter.BPS_DENOMINATOR();
        uint256 net = settled.lane - skim;
        assertEq(regent.balanceOf(treasury), before.treasuryRegent + net, "zero-stake net to the treasury");
        assertEq(regent.balanceOf(address(pool.splitter)), before.splitterRegent, "splitter retained the lane");
        assertEq(regent.balanceOf(REGENT_SAFE), before.safeRegent + settled.lane + skim, "Safe lane and skim");

        // A staked claimant: the same lane accrues to the staker instead of the treasury.
        pool.subject.transfer(staker, 1_000e18);
        vm.startPrank(staker);
        pool.subject.approve(address(pool.splitter), 1_000e18);
        pool.splitter.stake(1_000e18);
        vm.stopPrank();

        before = _ledger(pool, address(this));
        vm.recordLogs();
        _swap(pool, zeroForOne, -int256(1e18));
        settled = _onlySettlement();

        skim = (settled.lane * pool.splitter.SKIM_BPS()) / pool.splitter.BPS_DENOMINATOR();
        net = settled.lane - skim;
        assertEq(regent.balanceOf(treasury), before.treasuryRegent, "staked lane leaked to the treasury");
        assertEq(regent.balanceOf(address(pool.splitter)), before.splitterRegent + net, "staker net held");
        assertEq(pool.splitter.claimable(REGENT, staker), net, "staker claimable");

        vm.prank(staker);
        pool.splitter.claim(REGENT);
        assertEq(regent.balanceOf(staker), net, "staker claimed the net lane");
    }

    // =========================================================================
    // HOK-012 — sub-lane swaps charge nothing
    // =========================================================================

    function test_HOK_012_TinySwapsChargeNothingWithoutLoss() public {
        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        bool zeroForOne = _regentIsInput(pool);

        Ledger memory before = _ledger(pool, address(this));
        uint256 systemBefore = _regentInSystem(pool, address(this));

        vm.recordLogs();
        BalanceDelta delta = _swap(pool, zeroForOne, -int256(99));
        assertEq(_recordedSettlements().length, 0, "a sub-lane swap settled something");

        int128 regentDelta = pool.regentIsCurrency0 ? delta.amount0() : delta.amount1();
        assertEq(regentDelta, -int128(99), "trader paid more than the specified amount");
        assertEq(regent.balanceOf(REGENT_SAFE), before.safeRegent, "Safe charged on a sub-lane swap");
        assertEq(regent.balanceOf(treasury), before.treasuryRegent, "treasury charged on a sub-lane swap");
        assertEq(regent.balanceOf(address(hook)), before.hookRegent, "hook retained on a sub-lane swap");
        assertEq(regent.allowance(address(hook), address(pool.splitter)), 0, "allowance on a sub-lane swap");
        assertEq(_regentInSystem(pool, address(this)), systemBefore, "REGENT conservation on a sub-lane swap");

        // The splitter is genuinely never called: a splitter that reverts on every deposit cannot
        // stop a sub-lane swap.
        Pool memory hostilePool = _openHostilePool(SUBJECT_HIGH, DEFAULT_LIQUIDITY);
        HostileHookSplitter(hook.splitterOf(hostilePool.id)).setReverts(true);

        vm.recordLogs();
        _swap(hostilePool, _regentIsInput(hostilePool), -int256(99));
        assertEq(_recordedSettlements().length, 0, "a sub-lane swap reached the splitter");
    }

    // =========================================================================
    // HOK-013 — synchronous settlement
    // =========================================================================

    function test_HOK_013_SettlementCompletesInsideTheSwapTransaction() public {
        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        bool zeroForOne = _regentIsInput(pool);

        Ledger memory before = _ledger(pool, address(this));
        vm.recordLogs();
        _swap(pool, zeroForOne, -int256(1e18));
        Settlement memory settled = _onlySettlement();

        // Everything below is measured immediately after the single swap call returned.
        assertEq(settled.sender, address(swapRouter), "settlement recorded the calling router");
        assertEq(PoolId.unwrap(settled.poolId), PoolId.unwrap(pool.id), "settlement recorded the pool");
        assertTrue(settled.exactInput, "settlement shape: exact input");
        assertTrue(settled.regentSpecified, "settlement shape: REGENT specified");

        uint256 skim = (settled.lane * pool.splitter.SKIM_BPS()) / pool.splitter.BPS_DENOMINATOR();
        assertEq(regent.balanceOf(REGENT_SAFE), before.safeRegent + settled.lane + skim, "Safe settled");
        assertEq(regent.balanceOf(treasury), before.treasuryRegent + settled.lane - skim, "treasury settled");
        assertEq(regent.balanceOf(address(hook)), before.hookRegent, "hook settled");
        assertEq(regent.allowance(address(hook), address(pool.splitter)), 0, "allowance settled");

        // A repeat swap settles the same way, so nothing was deferred into later state.
        before = _ledger(pool, address(this));
        vm.recordLogs();
        _swap(pool, zeroForOne, -int256(1e18));
        Settlement memory repeat = _onlySettlement();
        assertEq(repeat.charged, settled.charged, "repeat charged");
        assertEq(repeat.lane, settled.lane, "repeat lane");
        _assertLanesLanded(pool, before, repeat.lane);
    }

    // =========================================================================
    // HOK-014 — no attributable inventory, gift or not
    // =========================================================================

    function test_HOK_014_NoAttributableInventoryRemainsAfterASwap() public {
        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        bool zeroForOne = _regentIsInput(pool);

        assertEq(regent.balanceOf(address(hook)), 0, "hook started with REGENT");
        _swap(pool, zeroForOne, -int256(1e18));
        assertEq(regent.balanceOf(address(hook)), 0, "hook retained attributable REGENT");

        // An unrelated permanent gift is not fee inventory. The hook must finish each swap at
        // exactly its pre-swap balance, not at zero. This is the C2 reading of INV-010, which stays
        // pending for C5's stateful invariant gate.
        uint256 gift = 777;
        regent.transfer(address(hook), gift);
        assertEq(regent.balanceOf(address(hook)), gift, "gift not seeded");

        _swap(pool, zeroForOne, -int256(1e18));
        assertEq(regent.balanceOf(address(hook)), gift, "gift disturbed or fee retained");

        _swap(pool, !zeroForOne, -int256(1e18));
        assertEq(regent.balanceOf(address(hook)), gift, "gift disturbed on the unspecified shape");

        assertEq(pool.subject.balanceOf(address(hook)), 0, "hook retained SUBJECT");
        assertEq(regent.allowance(address(hook), address(pool.splitter)), 0, "stale allowance");
    }

    // =========================================================================
    // HOK-015 — no control plane on the deployed surface
    // =========================================================================

    function test_HOK_015_NoFlushThresholdKeeperPauseOrFeeSetterExists() public {
        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);

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
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, bytes memory returned) =
                address(hook).call(abi.encodeWithSelector(bytes4(keccak256(bytes(forbidden[i])))));
            assertFalse(ok, forbidden[i]);
            assertEq(returned.length, 0, forbidden[i]);
        }

        // No receive or fallback either, so the hook cannot even be funded with ETH.
        vm.deal(address(this), 1 ether);
        // solhint-disable-next-line avoid-low-level-calls
        (bool paid,) = address(hook).call{value: 1}("");
        assertFalse(paid, "hook accepted ETH");

        // The surface that does exist is exactly registration plus the four callbacks, and the fee
        // arithmetic is constant.
        assertEq(hook.LANE_DIVISOR(), 100, "lane divisor is not constant");
        assertEq(hook.POOL_FEE(), 3000, "pool fee is not constant");
        assertEq(hook.POOL_TICK_SPACING(), 60, "tick spacing is not constant");
        assertEq(hook.splitterOf(pool.id), address(pool.splitter), "registration is not readable");
    }

    // =========================================================================
    // HOK-016 — settlement failure reverts the swap
    // =========================================================================

    function test_HOK_016_SettlementFailureRevertsTheSwap() public {
        // A thin pool: the early `take` in the specified path runs before the trader's input is
        // ever settled, so a lane larger than the singleton's REGENT balance reverts the whole swap.
        Pool memory thin = _openPool(SUBJECT_LOW, 1e18);
        Ledger memory before = _ledger(thin, address(this));
        uint256 systemBefore = _regentInSystem(thin, address(this));

        (bool ok, bytes memory returned) = _trySwap(thin, _regentIsInput(thin), -int256(1e23), MIN_LIMIT);
        assertFalse(ok, "insufficient PoolManager REGENT was settled in beforeSwap");
        assertTrue(
            _containsSelector(returned, CurrencyLibrary.ERC20TransferFailed.selector),
            "beforeSwap failed for a reason other than the singleton being unable to pay the lane"
        );
        _assertLedgerUnchanged(before, _ledger(thin, address(this)));
        assertEq(_regentInSystem(thin, address(this)), systemBefore, "partial settlement in beforeSwap");

        // The same boundary on the exact-output, REGENT-unspecified path, where the take runs in
        // afterSwap and the trader's REGENT input is likewise still unsettled. The Safe lane is paid
        // first there and the second lane is the one that cannot be covered, so this also proves the
        // half-paid state does not survive.
        (ok, returned) = _trySwap(thin, _regentIsInput(thin), int256(99e16), MAX_LIMIT);
        assertFalse(ok, "insufficient PoolManager REGENT was settled in afterSwap");
        assertTrue(
            _containsSelector(returned, CurrencyLibrary.ERC20TransferFailed.selector),
            "afterSwap failed for a reason other than the singleton being unable to pay the lane"
        );
        _assertLedgerUnchanged(before, _ledger(thin, address(this)));
        assertEq(_regentInSystem(thin, address(this)), systemBefore, "partial settlement in afterSwap");

        // Positive control: the same thin pool settles a swap whose lanes it can cover, so the two
        // failures above are the liveness boundary and not a broken fixture.
        vm.recordLogs();
        _swap(thin, _regentIsInput(thin), -int256(1e16));
        assertEq(_onlySettlement().lane, 1e14, "the thin pool could not settle an affordable swap");

        // A splitter that reverts, under-pulls, or refunds fails the swap outright.
        Pool memory pool = _openHostilePool(SUBJECT_HIGH, DEFAULT_LIQUIDITY);
        HostileHookSplitter hostile = HostileHookSplitter(hook.splitterOf(pool.id));
        bool zeroForOne = _regentIsInput(pool);

        before = _ledger(pool, address(this));
        systemBefore = _regentInSystem(pool, address(this));

        hostile.setReverts(true);
        (ok, returned) = _trySwap(pool, zeroForOne, -int256(1e18), MIN_LIMIT);
        assertFalse(ok, "reverting splitter did not fail the swap");
        assertTrue(_containsSelector(returned, HostileHookSplitter.HostileRevert.selector), "splitter revert");
        _assertLedgerUnchanged(before, _ledger(pool, address(this)));
        hostile.setReverts(false);

        hostile.setPullsPartially(true);
        (ok, returned) = _trySwap(pool, zeroForOne, -int256(1e18), MIN_LIMIT);
        assertFalse(ok, "under-pulling splitter did not fail the swap");
        assertTrue(_containsSelector(returned, RegentFeeHook.AttributableBalanceNotRestored.selector), "under-pull");
        _assertLedgerUnchanged(before, _ledger(pool, address(this)));
        hostile.setPullsPartially(false);

        hostile.setRefunds(true);
        (ok, returned) = _trySwap(pool, zeroForOne, -int256(1e18), MIN_LIMIT);
        assertFalse(ok, "refunding splitter did not fail the swap");
        assertTrue(_containsSelector(returned, RegentFeeHook.AttributableBalanceNotRestored.selector), "refund");
        _assertLedgerUnchanged(before, _ledger(pool, address(this)));
        assertEq(_regentInSystem(pool, address(this)), systemBefore, "partial settlement on splitter failure");
    }

    // =========================================================================
    // HOK-017 — PoolManager plus registered key is the whole authority boundary
    // =========================================================================

    function test_HOK_017_PoolManagerAndRegisteredKeyAreTheOnlyAuthority() public {
        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        SwapParams memory params = _swapParams(_regentIsInput(pool), -int256(1e18));

        // Nobody but the PoolManager may call a callback, however well-formed the key is.
        vm.prank(outsider);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(outsider, pool.key, params, "");

        vm.prank(outsider);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(outsider, pool.key, params, BalanceDelta.wrap(0), "");

        vm.prank(strategy);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(strategy, pool.key, SQRT_PRICE_1_1);

        // Even from the PoolManager, an unregistered key is rejected. Altering any single field
        // produces a different PoolId, and therefore a pool this hook never bound.
        PoolKey memory altered = _copyKey(pool.key);
        altered.fee = 500;
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(RegentFeeHook.PoolNotRegistered.selector, altered.toId()));
        hook.beforeSwap(address(swapRouter), altered, params, "");

        altered = _copyKey(pool.key);
        altered.tickSpacing = 30;
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(RegentFeeHook.PoolNotRegistered.selector, altered.toId()));
        hook.afterSwap(address(swapRouter), altered, params, BalanceDelta.wrap(0), "");

        // Initialization of an unregistered official pool is impossible, so the deterministic pool
        // cannot be brought into existence at a price the auction never cleared.
        _etchToken(SUBJECT_HIGH);
        PoolKey memory unregistered = _officialKey(SUBJECT_HIGH);
        vm.prank(strategy);
        (bool ok, bytes memory returned) = _tryInitialize(unregistered);
        assertFalse(ok, "unregistered pool initialized");
        assertTrue(_containsSelector(returned, RegentFeeHook.PoolNotRegistered.selector), "unregistered key");

        // And a registered pool can only be initialized by the strategy.
        SubjectSplitterV1 splitter = _newSplitter(SUBJECT_HIGH);
        vm.prank(strategy);
        hook.registerPool(unregistered, address(splitter));

        vm.prank(outsider);
        (ok, returned) = _tryInitialize(unregistered);
        assertFalse(ok, "a non-strategy sender initialized the official pool");
        assertTrue(_containsSelector(returned, RegentFeeHook.NotStrategy.selector), "foreign initializer");

        vm.prank(strategy);
        (ok,) = _tryInitialize(unregistered);
        assertTrue(ok, "the strategy could not initialize its own registered pool");
    }

    // =========================================================================
    // HOK-018 — arbitrary routers and reentrancy
    // =========================================================================

    function test_HOK_018_ArbitraryRoutersAndReentrancyCannotChangeLaneAccounting() public {
        // Two unrelated routers, two identically configured pools, one identical swap.
        Pool memory poolA = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        Pool memory poolB = _openPool(SUBJECT_ALT, DEFAULT_LIQUIDITY);

        Ledger memory beforeA = _ledger(poolA, address(this));
        vm.recordLogs();
        BalanceDelta deltaA = _swap(poolA, _regentIsInput(poolA), -int256(1e18));
        Settlement memory settledA = _onlySettlement();

        Ledger memory beforeB = _ledger(poolB, address(this));
        vm.recordLogs();
        BalanceDelta deltaB = altRouter.swap(poolB.key, _swapParams(_regentIsInput(poolB), -int256(1e18)));
        Settlement memory settledB = _onlySettlement();

        assertEq(settledA.charged, settledB.charged, "routers disagreed on the charged amount");
        assertEq(settledA.lane, settledB.lane, "routers disagreed on the lane");
        assertEq(settledA.sender, address(swapRouter), "router A identity");
        assertEq(settledB.sender, address(altRouter), "router B identity");
        assertEq(BalanceDelta.unwrap(deltaA), BalanceDelta.unwrap(deltaB), "routers produced different deltas");

        assertEq(
            regent.balanceOf(REGENT_SAFE) - beforeB.safeRegent,
            beforeB.safeRegent - beforeA.safeRegent,
            "routers delivered different Safe lanes"
        );
        _assertLanesLanded(poolB, beforeB, settledB.lane);

        // A splitter that re-enters the hook at the one moment the hook is mid-settlement cannot
        // reach anything: it is neither the strategy nor the PoolManager, and the swap it is
        // interrupting still settles exactly as it would have.
        Pool memory pool = _openHostilePool(SUBJECT_HIGH, DEFAULT_LIQUIDITY);
        HostileHookSplitter hostile = HostileHookSplitter(hook.splitterOf(pool.id));
        bool zeroForOne = _regentIsInput(pool);
        SwapParams memory params = _swapParams(zeroForOne, -int256(1e18));

        HookReentrancyProbe probe = new HookReentrancyProbe();
        probe.arm(
            address(hook),
            abi.encodeCall(RegentFeeHook.registerPool, (pool.key, address(hostile))),
            abi.encodeCall(IHooks.beforeSwap, (address(probe), pool.key, params, ""))
        );
        hostile.setReentry(address(probe), abi.encodeCall(HookReentrancyProbe.probe, ()));

        Ledger memory before = _ledger(pool, address(this));
        vm.recordLogs();
        _swap(pool, zeroForOne, -int256(1e18));
        Settlement memory settled = _onlySettlement();

        assertEq(probe.probes(), 1, "the reentrancy probe never ran");
        assertFalse(probe.firstSucceeded(), "a re-entrant caller registered a pool");
        assertFalse(probe.secondSucceeded(), "a re-entrant caller invoked a callback");
        assertTrue(_containsSelector(probe.firstReturn(), RegentFeeHook.NotStrategy.selector), "registration");
        assertTrue(_containsSelector(probe.secondReturn(), ImmutableState.NotPoolManager.selector), "callback");

        // The interrupted swap still delivered both lanes exactly. This pool's splitter is the
        // hostile stand-in rather than a real `SubjectSplitterV1`, so it keeps its lane whole
        // instead of skimming it, and the Safe delta is the direct lane alone.
        assertEq(settled.lane, 1e16, "reentrancy changed the lane");
        assertEq(regent.balanceOf(REGENT_SAFE), before.safeRegent + settled.lane, "direct lane under reentrancy");
        assertEq(regent.balanceOf(address(hostile)), settled.lane, "splitter lane under reentrancy");
        assertEq(regent.balanceOf(address(hook)), before.hookRegent, "hook retained under reentrancy");
        assertEq(regent.allowance(address(hook), address(hostile)), 0, "stale allowance under reentrancy");

        // The strongest nested attack available: the same splitter, still holding the hook's live
        // approval, issues a second swap on the same pool straight at the already-unlocked
        // PoolManager and settles that swap out of its own inventory. The nested swap does reach the
        // hook and does overwrite the outer approval with its own exact lane, which is precisely why
        // the outer pull can no longer complete and the whole transaction fails closed.
        regent.transfer(address(nestedAttacker), 1e20);
        pool.subject.transfer(address(nestedAttacker), 1e20);
        hostile.setReentry(
            address(nestedAttacker),
            abi.encodeCall(NestedSwapAttacker.attack, (pool.key, _swapParams(zeroForOne, -int256(1e17))))
        );

        before = _ledger(pool, address(this));
        uint256 systemBefore = _regentInSystem(pool, address(this));

        (bool ok, bytes memory returned) = _trySwap(pool, zeroForOne, -int256(1e18), MIN_LIMIT);
        assertFalse(ok, "a nested swap changed lane accounting");
        assertTrue(_containsSelector(returned, PANIC_SELECTOR), "the outer pull was not the failing step");
        _assertLedgerUnchanged(before, _ledger(pool, address(this)));
        assertEq(_regentInSystem(pool, address(this)), systemBefore, "nested swap moved REGENT");

        // With the attack disarmed the same pool settles normally, so the failure above was the
        // attack and not the fixture.
        hostile.setReentry(address(0), "");
        vm.recordLogs();
        _swap(pool, zeroForOne, -int256(1e18));
        assertEq(_onlySettlement().lane, 1e16, "disarmed lane");
    }

    // =========================================================================
    // HOK-019 — lane rounding at the frozen boundary inputs
    // =========================================================================

    function test_HOK_019_LaneRoundingIsExactAtTheFeeBoundaryInputs() public {
        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        bool regentIn = _regentIsInput(pool);

        // A charged amount of exactly zero is only reachable through the unspecified shape: an
        // input too small to produce any REGENT output at all.
        Ledger memory before = _ledger(pool, address(this));
        vm.recordLogs();
        BalanceDelta delta = _swap(pool, !regentIn, -int256(1));
        Settlement[] memory zeroCase = _recordedSettlements();

        int128 regentOut = pool.regentIsCurrency0 ? delta.amount0() : delta.amount1();
        assertEq(regentOut, int128(0), "expected a zero REGENT component");
        assertEq(zeroCase.length, 0, "a zero charge settled a lane");
        _assertLedgerUnchangedAtDestinations(pool, before);

        uint256[7] memory inputs =
            [uint256(1), uint256(49), uint256(50), uint256(99), uint256(100), uint256(9_999), uint256(10_000)];
        for (uint256 i; i < inputs.length; ++i) {
            uint256 charged = inputs[i];
            uint256 lane = charged / 100;

            before = _ledger(pool, address(this));
            vm.recordLogs();
            delta = _swap(pool, regentIn, -int256(charged));
            Settlement[] memory settlements = _recordedSettlements();

            int128 regentDelta = pool.regentIsCurrency0 ? delta.amount0() : delta.amount1();
            assertEq(regentDelta, -int128(int256(charged)), "trader paid other than the specified amount");

            if (lane == 0) {
                assertEq(settlements.length, 0, "a sub-lane input settled a lane");
                _assertLedgerUnchangedAtDestinations(pool, before);
            } else {
                assertEq(settlements.length, 1, "expected one settlement");
                assertEq(settlements[0].charged, charged, "charged");
                assertEq(settlements[0].lane, lane, "floored lane");
                _assertLanesLanded(pool, before, lane);
            }
        }
    }

    // =========================================================================
    // shared shape assertions
    // =========================================================================

    /// @dev REGENT is the specified currency, so the charge is taken in `beforeSwap` against
    ///      `abs(amountSpecified)` and the trader's REGENT side lands on exactly that amount.
    function _assertSpecifiedShape(address subjectAddress, bool exactInput) private {
        Pool memory pool = _openPool(subjectAddress, DEFAULT_LIQUIDITY);
        bool zeroForOne = exactInput ? _regentIsInput(pool) : !_regentIsInput(pool);
        int256 amountSpecified = exactInput ? -int256(1e18) : int256(1e18);

        Ledger memory before = _ledger(pool, address(this));
        uint256 systemBefore = _regentInSystem(pool, address(this));

        vm.recordLogs();
        BalanceDelta delta = _swap(pool, zeroForOne, amountSpecified);
        Settlement memory settled = _onlySettlement();

        assertEq(settled.charged, 1e18, "charged against the specified amount");
        assertEq(settled.lane, 1e16, "lane");
        assertEq(settled.exactInput, exactInput, "recorded exact-input shape");
        assertTrue(settled.regentSpecified, "recorded REGENT as specified");

        int128 regentDelta = pool.regentIsCurrency0 ? delta.amount0() : delta.amount1();
        int128 subjectDelta = pool.regentIsCurrency0 ? delta.amount1() : delta.amount0();
        if (exactInput) {
            assertEq(regentDelta, -int128(int256(1e18)), "trader paid other than the specified REGENT");
            assertGt(subjectDelta, int128(0), "trader received no SUBJECT");
        } else {
            assertEq(regentDelta, int128(int256(1e18)), "trader received other than the specified REGENT");
            assertLt(subjectDelta, int128(0), "trader paid no SUBJECT");
        }

        _assertLanesLanded(pool, before, settled.lane);
        assertEq(regent.balanceOf(treasury), before.treasuryRegent + settled.lane - _skim(pool, settled.lane), "net");
        assertEq(_regentInSystem(pool, address(this)), systemBefore, "REGENT conservation");
    }

    /// @dev REGENT is the unspecified currency, so the charge is taken in `afterSwap` against the
    ///      absolute REGENT component of the realized swap delta, and the trader's *specified* side
    ///      lands on exactly the requested amount.
    function _assertUnspecifiedShape(address subjectAddress, bool exactInput) private {
        Pool memory pool = _openPool(subjectAddress, DEFAULT_LIQUIDITY);
        bool zeroForOne = exactInput ? !_regentIsInput(pool) : _regentIsInput(pool);
        int256 amountSpecified = exactInput ? -int256(1e18) : int256(1e18);

        Ledger memory before = _ledger(pool, address(this));
        uint256 systemBefore = _regentInSystem(pool, address(this));

        vm.recordLogs();
        BalanceDelta delta = _swap(pool, zeroForOne, amountSpecified);
        Settlement memory settled = _onlySettlement();

        assertFalse(settled.regentSpecified, "recorded REGENT as specified");
        assertEq(settled.exactInput, exactInput, "recorded exact-input shape");
        assertEq(settled.lane, settled.charged / hook.LANE_DIVISOR(), "lane is the floored charge");
        assertGt(settled.lane, 0, "expected a chargeable REGENT delta");

        int128 regentDelta = pool.regentIsCurrency0 ? delta.amount0() : delta.amount1();
        int128 subjectDelta = pool.regentIsCurrency0 ? delta.amount1() : delta.amount0();
        if (exactInput) {
            // SUBJECT in is exactly the specified amount; REGENT out is the realized amount less
            // both lanes.
            assertEq(subjectDelta, -int128(int256(1e18)), "trader paid other than the specified SUBJECT");
            assertEq(
                regentDelta,
                int128(int256(settled.charged)) - int128(int256(2 * settled.lane)),
                "trader received other than the realized REGENT less both lanes"
            );
        } else {
            // SUBJECT out is exactly the specified amount; REGENT in is the realized amount plus
            // both lanes.
            assertEq(subjectDelta, int128(int256(1e18)), "trader received other than the specified SUBJECT");
            assertEq(
                regentDelta,
                -int128(int256(settled.charged)) - int128(int256(2 * settled.lane)),
                "trader paid other than the realized REGENT plus both lanes"
            );
        }

        _assertLanesLanded(pool, before, settled.lane);
        assertEq(regent.balanceOf(treasury), before.treasuryRegent + settled.lane - _skim(pool, settled.lane), "net");
        assertEq(_regentInSystem(pool, address(this)), systemBefore, "REGENT conservation");
    }

    function _assertLedgerUnchangedAtDestinations(Pool memory pool, Ledger memory before) private view {
        assertEq(regent.balanceOf(REGENT_SAFE), before.safeRegent, "Safe charged");
        assertEq(regent.balanceOf(treasury), before.treasuryRegent, "treasury charged");
        assertEq(regent.balanceOf(address(pool.splitter)), before.splitterRegent, "splitter charged");
        assertEq(regent.balanceOf(address(hook)), before.hookRegent, "hook retained");
        assertEq(regent.allowance(address(hook), address(pool.splitter)), 0, "stale allowance");
    }

    function _skim(Pool memory pool, uint256 lane) private view returns (uint256) {
        return (lane * pool.splitter.SKIM_BPS()) / pool.splitter.BPS_DENOMINATOR();
    }

    // =========================================================================
    // local helpers
    // =========================================================================

    /// @dev An independent copy. `PoolKey memory b = a` would alias `a`, so a mutated variant would
    ///      silently corrupt the key every later assertion is measured against.
    function _copyKey(PoolKey memory key) private pure returns (PoolKey memory copied) {
        copied = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: key.hooks
        });
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

    /// @dev A registered, initialized, funded pool whose splitter is the hostile stand-in.
    function _openHostilePool(address subjectAddress, uint256 liquidity) private returns (Pool memory pool) {
        pool.subject = _etchToken(subjectAddress);
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

    function _expectRegisterRevert(PoolKey memory key, address splitter, bytes memory expected) private {
        vm.prank(strategy);
        vm.expectRevert(expected);
        hook.registerPool(key, splitter);
    }

    function _tryInitialize(PoolKey memory key) private returns (bool ok, bytes memory returned) {
        // solhint-disable-next-line avoid-low-level-calls
        (ok, returned) = address(manager).call(abi.encodeCall(IPoolManager.initialize, (key, SQRT_PRICE_1_1)));
    }

    /// @dev A permission-bearing address with no code, for a construction that must fail.
    function _freeHookAddress(uint256 nonce) private pure returns (address) {
        return address(uint160((uint256(0x7000) + nonce) << 144) | HOOK_FLAGS);
    }
}
