// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {RegentFeeHook} from "../../src/hook/RegentFeeHook.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockLiveStaking} from "./MockLiveStaking.sol";
import {NestedSwapAttacker} from "./NestedSwapAttacker.sol";
import {SimpleSwapRouter} from "./SimpleSwapRouter.sol";

/// @notice The C2 hook fixture: a real `PoolManager`, two unrelated real swap routers, real
///         `SubjectSplitterV1` clones, and the real `RegentFeeHook` bound to them.
/// @dev Three deliberate choices keep this honest.
///
///      1. Token code is placed at the frozen REGENT binding with `vm.etch`, because the hook
///         validates that exact address in production and a substitute token would prove nothing.
///         SUBJECT is placed both below and above REGENT so every pool ordering is real.
///      2. The hook is constructed *at* its own final address — the creation code is etched there
///         and then called, so the constructor runs with `address(this)` equal to the deployed
///         address and `BaseHook.validateHookAddress` is exercised for real. Nothing in production
///         is weakened or overridden; `test_HOK_004_*` additionally deploys through the pinned
///         `HookMiner` and CREATE2 to prove the same constructor accepts a mined address.
///      3. `PoolManager`, `PoolSwapTest`, and `PoolModifyLiquidityTest` are instantiated directly
///         rather than through the pinned `Deployers` helper, so this suite pulls in exactly one
///         forge-std and exactly one v4-core source-unit universe.
abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;

    /// @dev sqrt(1) in Q96. The pools open at parity so both currencies carry real reserves.
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    int24 internal constant FULL_RANGE_LOWER = -887_220;
    int24 internal constant FULL_RANGE_UPPER = 887_220;

    uint256 internal constant DEFAULT_LIQUIDITY = 1e21;
    uint256 internal constant TOKEN_MINT = 1e30;

    /// @dev The complete SUBJECT supply every authentic launch mints. A splitter binds only a
    ///      SUBJECT reporting exactly this, so every etched SUBJECT here is minted at the launch
    ///      supply rather than at an arbitrary funding figure.
    uint256 internal constant SUBJECT_TOTAL_SUPPLY = 100_000_000_000e18;

    address internal constant REGENT = BaseBindings.REGENT;
    address internal constant REGENT_SAFE = BaseBindings.GOVERNANCE_AND_REGENT_SAFE;

    /// @dev Chosen so `SUBJECT_LOW < REGENT < SUBJECT_HIGH`, giving both PoolKey orderings.
    address internal constant SUBJECT_LOW = 0x1111111111111111111111111111111111111111;
    address internal constant SUBJECT_HIGH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    /// @dev Two more SUBJECTs on the same side as `SUBJECT_LOW`, so several pools can be opened
    ///      identically: same currency ordering, same fee, same tick spacing, same opening price and
    ///      same liquidity, differing only in which token they carry.
    address internal constant SUBJECT_ALT = 0x2222222222222222222222222222222222222222;
    address internal constant SUBJECT_ALT2 = 0x3333333333333333333333333333333333333333;

    /// @notice Exactly the five permission bits the hook declares, and no others.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    address internal constant HOOK_ADDRESS = address(uint160(uint256(0x4444) << 144) | HOOK_FLAGS);

    struct Pool {
        PoolKey key;
        PoolId id;
        MockERC20 subject;
        SubjectSplitterV1 splitter;
        bool regentIsCurrency0;
    }

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    SimpleSwapRouter internal altRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    NestedSwapAttacker internal nestedAttacker;

    RegentFeeHook internal hook;
    SubjectSplitterV1 internal splitterImplementation;
    MockERC20 internal regent;

    address internal strategy = makeAddr("strategy");
    address internal treasury = makeAddr("treasury");
    address internal outsider = makeAddr("outsider");
    address internal staker = makeAddr("staker");

    function _deployHookSystem() internal {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        altRouter = new SimpleSwapRouter(IPoolManager(address(manager)));
        liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        nestedAttacker = new NestedSwapAttacker(IPoolManager(address(manager)));

        splitterImplementation = new SubjectSplitterV1();

        regent = _etchToken(REGENT, TOKEN_MINT);
        (bool ok,) = _constructHookAt(HOOK_ADDRESS, address(manager), strategy);
        require(ok, "HookFixture: hook construction failed");
        hook = RegentFeeHook(HOOK_ADDRESS);
    }

    /// @dev Place `MockERC20` runtime code at an exact address and mint it an exact supply. Storage
    ///      starts empty, which is what a freshly deployed token looks like, and the `decimals`
    ///      immutable travels with the code.
    function _etchToken(address where, uint256 supply) internal returns (MockERC20 token) {
        MockERC20 template = new MockERC20("Etched", "ETCH", 18);
        vm.etch(where, address(template).code);
        token = MockERC20(where);
        token.mint(address(this), supply);
    }

    /// @dev Run the hook's real constructor at `where`. Returns the constructor's own outcome so a
    ///      test can assert on a rejected binding or a rejected address without a cheatcode wrapper.
    function _constructHookAt(address where, address manager_, address strategy_)
        internal
        returns (bool ok, bytes memory returned)
    {
        bytes memory initcode = abi.encodePacked(type(RegentFeeHook).creationCode, abi.encode(manager_, strategy_));
        vm.etch(where, initcode);
        // solhint-disable-next-line avoid-low-level-calls
        (ok, returned) = where.call("");
        vm.etch(where, ok ? returned : bytes(""));
    }

    /// @dev One registered, initialized, funded official pool for `subjectAddress`.
    function _openPool(address subjectAddress, uint256 liquidity) internal returns (Pool memory pool) {
        pool.subject = _etchToken(subjectAddress, SUBJECT_TOTAL_SUPPLY);
        pool.regentIsCurrency0 = REGENT < subjectAddress;
        pool.splitter = _newSplitter(subjectAddress);

        (Currency currency0, Currency currency1) = pool.regentIsCurrency0
            ? (Currency.wrap(REGENT), Currency.wrap(subjectAddress))
            : (Currency.wrap(subjectAddress), Currency.wrap(REGENT));

        pool.key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: hook.POOL_FEE(),
            tickSpacing: hook.POOL_TICK_SPACING(),
            hooks: IHooks(address(hook))
        });
        pool.id = pool.key.toId();

        vm.prank(strategy);
        hook.registerPool(pool.key, address(pool.splitter));

        vm.prank(strategy);
        manager.initialize(pool.key, SQRT_PRICE_1_1);

        _approveAll(pool.subject);
        if (liquidity != 0) _addLiquidity(pool, liquidity);
    }

    function _newSplitter(address subjectAddress) internal returns (SubjectSplitterV1 splitter) {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockLiveStaking liveStaking = new MockLiveStaking(address(usdc));

        splitter = SubjectSplitterV1(LibClone.clone(address(splitterImplementation)));
        splitter.initialize(address(usdc), REGENT, subjectAddress, address(liveStaking), REGENT_SAFE, treasury);
    }

    function _approveAll(MockERC20 subject) internal {
        address[3] memory spenders = [address(swapRouter), address(altRouter), address(liquidityRouter)];
        for (uint256 i; i < spenders.length; ++i) {
            regent.approve(spenders[i], type(uint256).max);
            subject.approve(spenders[i], type(uint256).max);
        }
    }

    function _addLiquidity(Pool memory pool, uint256 liquidity) internal {
        liquidityRouter.modifyLiquidity(
            pool.key,
            ModifyLiquidityParams({
                tickLower: FULL_RANGE_LOWER,
                tickUpper: FULL_RANGE_UPPER,
                liquidityDelta: int256(liquidity),
                salt: bytes32(0)
            }),
            ""
        );
    }

    // -------------------------------------------------------------------------
    // swap helpers
    // -------------------------------------------------------------------------

    function _swapParams(bool zeroForOne, int256 amountSpecified) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? SQRT_PRICE_1_1 / 2 : SQRT_PRICE_1_1 * 2
        });
    }

    function _swap(Pool memory pool, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta delta) {
        delta = swapRouter.swap(
            pool.key,
            _swapParams(zeroForOne, amountSpecified),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _swapWithLimit(Pool memory pool, bool zeroForOne, int256 amountSpecified, uint160 limit)
        internal
        returns (BalanceDelta delta)
    {
        delta = swapRouter.swap(
            pool.key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev `zeroForOne` for the direction in which REGENT is the *input* currency of the pool.
    function _regentIsInput(Pool memory pool) internal pure returns (bool zeroForOne) {
        zeroForOne = pool.regentIsCurrency0;
    }

    function _currentSqrtPrice(Pool memory pool) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(pool.id);
    }

    // -------------------------------------------------------------------------
    // accounting helpers
    // -------------------------------------------------------------------------

    struct Ledger {
        uint256 safeRegent;
        uint256 hookRegent;
        uint256 splitterRegent;
        uint256 treasuryRegent;
        uint256 traderRegent;
        uint256 traderSubject;
        uint256 managerRegent;
        uint256 managerSubject;
        uint256 splitterAllowance;
    }

    function _ledger(Pool memory pool, address trader) internal view returns (Ledger memory snapshot) {
        snapshot.safeRegent = regent.balanceOf(REGENT_SAFE);
        snapshot.hookRegent = regent.balanceOf(address(hook));
        snapshot.splitterRegent = regent.balanceOf(address(pool.splitter));
        snapshot.treasuryRegent = regent.balanceOf(treasury);
        snapshot.traderRegent = regent.balanceOf(trader);
        snapshot.traderSubject = pool.subject.balanceOf(trader);
        snapshot.managerRegent = regent.balanceOf(address(manager));
        snapshot.managerSubject = pool.subject.balanceOf(address(manager));
        snapshot.splitterAllowance = regent.allowance(address(hook), address(pool.splitter));
    }

    function _assertLedgerUnchanged(Ledger memory before, Ledger memory found) internal pure {
        assertEq(found.safeRegent, before.safeRegent, "Regent Safe REGENT moved");
        assertEq(found.hookRegent, before.hookRegent, "hook REGENT moved");
        assertEq(found.splitterRegent, before.splitterRegent, "splitter REGENT moved");
        assertEq(found.treasuryRegent, before.treasuryRegent, "treasury REGENT moved");
        assertEq(found.traderRegent, before.traderRegent, "trader REGENT moved");
        assertEq(found.traderSubject, before.traderSubject, "trader SUBJECT moved");
        assertEq(found.managerRegent, before.managerRegent, "PoolManager REGENT moved");
        assertEq(found.managerSubject, before.managerSubject, "PoolManager SUBJECT moved");
        assertEq(found.splitterAllowance, before.splitterAllowance, "splitter allowance moved");
    }

    /// @dev The exact destinations one settled lane must reach: the direct Regent Safe lane, plus
    ///      the splitter lane's own floored 2% REGENT skim, which also lands at the Regent Safe.
    function _assertLanesLanded(Pool memory pool, Ledger memory before, uint256 lane) internal view {
        uint256 skim = (lane * pool.splitter.SKIM_BPS()) / pool.splitter.BPS_DENOMINATOR();
        assertEq(regent.balanceOf(REGENT_SAFE), before.safeRegent + lane + skim, "Safe lane plus splitter skim");
        assertEq(regent.balanceOf(address(hook)), before.hookRegent, "hook retained attributable REGENT");
        assertEq(regent.allowance(address(hook), address(pool.splitter)), 0, "stale splitter allowance");
    }

    /// @dev Every account that can hold REGENT in this fixture. A swap only moves REGENT between
    ///      them, so the sum is invariant and no lane can be created or destroyed. `C2-I2`.
    function _regentInSystem(Pool memory pool, address trader) internal view returns (uint256) {
        return regent.balanceOf(trader) + regent.balanceOf(REGENT_SAFE) + regent.balanceOf(treasury)
            + regent.balanceOf(address(pool.splitter)) + regent.balanceOf(address(hook))
            + regent.balanceOf(address(manager)) + regent.balanceOf(staker);
    }

    // -------------------------------------------------------------------------
    // settlement-event helpers
    // -------------------------------------------------------------------------

    struct Settlement {
        bool found;
        PoolId poolId;
        address sender;
        uint256 charged;
        uint256 lane;
        bool exactInput;
        bool regentSpecified;
    }

    /// @dev The one `SwapFeeSettled` the hook emitted, if it emitted any. Reading the event rather
    ///      than recomputing the amounts is what makes the pool's own arithmetic — not the test's —
    ///      the source of `charged`.
    function _recordedSettlements() internal returns (Settlement[] memory found) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Settlement[] memory buffer = new Settlement[](logs.length);
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] != RegentFeeHook.SwapFeeSettled.selector) continue;
            Settlement memory entry;
            entry.found = true;
            entry.poolId = PoolId.wrap(logs[i].topics[1]);
            entry.sender = address(uint160(uint256(logs[i].topics[2])));
            (entry.charged, entry.lane, entry.exactInput, entry.regentSpecified) =
                abi.decode(logs[i].data, (uint256, uint256, bool, bool));
            buffer[count++] = entry;
        }
        found = new Settlement[](count);
        for (uint256 i; i < count; ++i) {
            found[i] = buffer[i];
        }
    }

    function _onlySettlement() internal returns (Settlement memory settlement) {
        Settlement[] memory found = _recordedSettlements();
        assertEq(found.length, 1, "expected exactly one settlement event");
        settlement = found[0];
    }

    /// @dev v4 wraps a failing hook call in `WrappedError`, so the hook's own named error survives
    ///      inside the bubbled payload rather than as the outermost selector.
    function _containsSelector(bytes memory data, bytes4 selector) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i; i + 4 <= data.length; ++i) {
            if (
                data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                    && data[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }

    /// @dev Attempt a swap through the pinned router without reverting the test, so the caller can
    ///      inspect both the failure payload and the untouched ledger.
    function _trySwap(Pool memory pool, bool zeroForOne, int256 amountSpecified, uint160 limit)
        internal
        returns (bool ok, bytes memory returned)
    {
        // solhint-disable-next-line avoid-low-level-calls
        (ok, returned) = address(swapRouter)
            .call(
                abi.encodeCall(
                    PoolSwapTest.swap,
                    (
                        pool.key,
                        SwapParams({
                            zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit
                        }),
                        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                        ""
                    )
                )
            );
    }
}
