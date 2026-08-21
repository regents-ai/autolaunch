// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {BaseBindings} from "../bindings/BaseBindings.sol";
import {SubjectSplitterV1} from "../revenue/SubjectSplitterV1.sol";

/// @title RegentFeeHook
/// @notice The one shared Uniswap v4 hook every official Autolaunch pool carries. It charges two
///         independently floored 1% REGENT lanes on every swap and settles both of them inside the
///         swap transaction: one lane straight to the Regent Safe, one lane through the launch's
///         `SubjectSplitterV1`.
/// @dev Two immutables — the PoolManager and the strategy — are fixed at construction and never
///      change. There is no initializer, upgrade, replacement, setter, flush, threshold, keeper,
///      pause, router allowlist, recovery, or fee mutation of any kind, and registration is
///      append-only. `BaseHook`'s PoolManager-only callback boundary, the registered `PoolId`, the
///      frozen REGENT binding, the strategy-validated splitter, and ordinary EVM atomicity are the
///      complete authority and reentrancy design; no separate guard exists or is needed.
///
///      Settlement follows the pinned v4 convention exactly. When REGENT is the swap's *specified*
///      currency the charge is taken in `beforeSwap` from `abs(amountSpecified)` and returned as a
///      positive specified delta; when REGENT is the *unspecified* currency the charge is taken in
///      `afterSwap` from the absolute REGENT component of the realized `BalanceDelta` and returned
///      as a positive unspecified delta. Exactly one of the two callbacks ever charges a given swap.
///
///      Named invariants: `C2-I1` exact authority, `C2-I2` fee conservation, `C2-I3` synchronous
///      cleanliness, `C2-I4` shape symmetry, `C2-I5` atomic failure, `C2-I6` no control plane.
contract RegentFeeHook is BaseHook {
    using SafeTransferLib for address;

    /// @notice Each lane is `chargedRegent / LANE_DIVISOR`, floored independently. Two equal lanes.
    uint256 public constant LANE_DIVISOR = 100;

    /// @notice The only static LP fee an official pool may carry, 0.30%.
    uint24 public constant POOL_FEE = 3000;

    /// @notice The only tick spacing an official pool may carry.
    int24 public constant POOL_TICK_SPACING = 60;

    /// @notice The only account that may register a pool or initialize one.
    address public immutable strategy;

    /// @notice The registered launch splitter for a pool. Write-once; zero means unregistered.
    mapping(PoolId poolId => address splitter) public splitterOf;

    event PoolRegistered(PoolId indexed poolId, address indexed splitter, address indexed subject);

    /// @notice One settled swap. Observability only; this event is never authority.
    event SwapFeeSettled(
        PoolId indexed poolId,
        address indexed sender,
        uint256 chargedRegent,
        uint256 lane,
        bool exactInput,
        bool regentSpecified
    );

    error ZeroStrategy();
    error SelfStrategy();
    error NotStrategy(address caller);
    error PoolAlreadyRegistered(PoolId poolId);
    error PoolNotRegistered(PoolId poolId);
    error ForeignHook(address hooks);
    error UnexpectedPoolFee(uint24 fee);
    error UnexpectedTickSpacing(int24 tickSpacing);
    error CurrencyOrderInvalid(address currency0, address currency1);
    error NativeCurrency();
    error RegentNotInPoolKey();
    error SplitterHasNoCode(address splitter);
    error SplitterBindingMismatch(address expected, address found);
    error SpecifiedAmountOutOfRange();
    error AttributableBalanceNotRestored(uint256 expected, uint256 found);

    /// @dev `BaseHook` validates that this address carries exactly the permission bits
    ///      `getHookPermissions` declares, so a mis-mined deployment cannot exist.
    constructor(IPoolManager manager_, address strategy_) BaseHook(manager_) {
        if (strategy_ == address(0)) revert ZeroStrategy();
        if (strategy_ == address(this)) revert SelfStrategy();
        strategy = strategy_;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Bind one exact official `PoolKey` to one launch splitter. Strategy only, once ever.
    /// @dev The whole key is validated before any state is consumed, and the stored `PoolId` is the
    ///      keccak of that exact key, so a pool whose currencies, fee, tick spacing, or hook differ
    ///      in any byte is a different — and unregistered — pool. `C2-I1`, `C2-I6`.
    function registerPool(PoolKey calldata key, address splitter) external {
        if (msg.sender != strategy) revert NotStrategy(msg.sender);
        if (address(key.hooks) != address(this)) revert ForeignHook(address(key.hooks));
        if (key.fee != POOL_FEE) revert UnexpectedPoolFee(key.fee);
        if (key.tickSpacing != POOL_TICK_SPACING) revert UnexpectedTickSpacing(key.tickSpacing);

        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (currency0 >= currency1) revert CurrencyOrderInvalid(currency0, currency1);
        if (currency0 == address(0)) revert NativeCurrency();

        // The currencies are strictly ordered, so at most one of them can be REGENT; requiring that
        // one of them is makes it exactly one, and the other is this launch's SUBJECT.
        bool regentIsCurrency0 = currency0 == BaseBindings.REGENT;
        if (!regentIsCurrency0 && currency1 != BaseBindings.REGENT) revert RegentNotInPoolKey();
        address subject = regentIsCurrency0 ? currency1 : currency0;

        if (splitter.code.length == 0) revert SplitterHasNoCode(splitter);
        _requireSplitterBinding(BaseBindings.REGENT, SubjectSplitterV1(splitter).regent());
        _requireSplitterBinding(subject, SubjectSplitterV1(splitter).subject());
        _requireSplitterBinding(BaseBindings.GOVERNANCE_AND_REGENT_SAFE, SubjectSplitterV1(splitter).regentSafe());

        PoolId poolId = key.toId();
        if (splitterOf[poolId] != address(0)) revert PoolAlreadyRegistered(poolId);
        splitterOf[poolId] = splitter;

        emit PoolRegistered(poolId, splitter, subject);
    }

    /// @dev Only the strategy may initialize a registered official pool, so nobody can front-run the
    ///      deterministic pool into existence at a price the auction never cleared. `C2-I1`.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        PoolId poolId = key.toId();
        if (splitterOf[poolId] == address(0)) revert PoolNotRegistered(poolId);
        if (sender != strategy) revert NotStrategy(sender);
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev Charges the two lanes when REGENT is the specified currency, from `abs(amountSpecified)`,
    ///      and returns them as a positive specified delta. `C2-I2`, `C2-I4`.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (PoolId poolId, address splitter, bool regentSpecified) = _resolve(key, params);
        if (!regentSpecified) return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        int256 amountSpecified = params.amountSpecified;
        if (amountSpecified == type(int256).min) revert SpecifiedAmountOutOfRange();
        uint256 charged = uint256(amountSpecified < 0 ? -amountSpecified : amountSpecified);

        int128 hookDelta = _chargeLanes(poolId, splitter, sender, charged, amountSpecified < 0, true);
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(hookDelta, 0), 0);
    }

    /// @dev Charges the two lanes when REGENT is the unspecified currency, from the absolute REGENT
    ///      component of the realized swap delta, and returns them as a positive unspecified delta.
    ///      A swap already charged in `beforeSwap` is never charged again here. `C2-I2`, `C2-I4`.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        (PoolId poolId, address splitter, bool regentSpecified) = _resolve(key, params);
        if (regentSpecified) return (BaseHook.afterSwap.selector, 0);

        int128 regentDelta = Currency.unwrap(key.currency0) == BaseBindings.REGENT ? delta.amount0() : delta.amount1();
        // Checked negation: an `int128.min` component reverts here rather than truncating.
        if (regentDelta < 0) regentDelta = -regentDelta;

        int128 hookDelta =
            _chargeLanes(poolId, splitter, sender, uint256(uint128(regentDelta)), params.amountSpecified < 0, false);
        return (BaseHook.afterSwap.selector, hookDelta);
    }

    /// @dev The registered pool, its splitter, and which side of this swap REGENT sits on. Reverts
    ///      for any key the strategy never registered, which is the whole key-side authority
    ///      boundary; `BaseHook` supplies the caller-side one. `C2-I1`.
    function _resolve(PoolKey calldata key, SwapParams calldata params)
        private
        view
        returns (PoolId poolId, address splitter, bool regentSpecified)
    {
        poolId = key.toId();
        splitter = splitterOf[poolId];
        if (splitter == address(0)) revert PoolNotRegistered(poolId);

        // The pinned v4 convention: the specified currency is currency0 exactly when the swap is
        // exact-input zero-for-one or exact-output one-for-zero.
        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        regentSpecified = specifiedIsCurrency0 == (Currency.unwrap(key.currency0) == BaseBindings.REGENT);
    }

    /// @dev Floors one 1% lane, uses that same amount twice, and settles both lanes synchronously:
    ///      one taken straight to the Regent Safe, one taken here, exact-approved, and pulled by the
    ///      registered splitter. The hook's REGENT balance must return to its pre-callback level, so
    ///      a splitter that under-pulls, over-pulls, or refunds fails the whole swap. Exact
    ///      consumption of an exact approval leaves no allowance behind. A lane of zero is a valid
    ///      no-op that makes no PoolManager, token, splitter, or approval call at all.
    ///      `C2-I2`, `C2-I3`, `C2-I5`.
    function _chargeLanes(
        PoolId poolId,
        address splitter,
        address sender,
        uint256 charged,
        bool exactInput,
        bool regentSpecified
    ) private returns (int128) {
        uint256 lane = charged / LANE_DIVISOR;
        if (lane == 0) return 0;

        // Two equal lanes summed, never one floored 2%. Never truncate either: the returned `int128`
        // hook delta must represent both lanes exactly.
        int128 hookDelta = SafeCast.toInt128(lane + lane);

        address regent = BaseBindings.REGENT;
        uint256 balanceBefore = regent.balanceOf(address(this));

        poolManager.take(Currency.wrap(regent), BaseBindings.GOVERNANCE_AND_REGENT_SAFE, lane);
        poolManager.take(Currency.wrap(regent), address(this), lane);

        regent.safeApprove(splitter, lane);
        SubjectSplitterV1(splitter).depositRecognizedRevenue(regent, lane, PoolId.unwrap(poolId));

        uint256 balanceAfter = regent.balanceOf(address(this));
        if (balanceAfter != balanceBefore) revert AttributableBalanceNotRestored(balanceBefore, balanceAfter);

        emit SwapFeeSettled(poolId, sender, charged, lane, exactInput, regentSpecified);
        return hookDelta;
    }

    function _requireSplitterBinding(address expected, address found) private pure {
        if (expected != found) revert SplitterBindingMismatch(expected, found);
    }
}
