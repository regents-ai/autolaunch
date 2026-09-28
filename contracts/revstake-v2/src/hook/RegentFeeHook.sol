// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {BaseBindings} from "../bindings/BaseBindings.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {SubjectSplitterV1} from "../revenue/SubjectSplitterV1.sol";

/// @title RegentFeeHook
/// @notice The one shared Uniswap v4 hook every official Autolaunch pool carries. After every swap,
///         it charges 2% of the actual realized unspecified currency in two lanes: 1% to Regent (in
///         REGENT straight into REGENT staking's reward pool, in the launch's token straight to the
///         Regent Safe) and 1% through the launch's splitter to its stakers.
/// @dev Two immutables — the PoolManager and the strategy — are fixed at construction and never
///      change. There is no initializer, upgrade, replacement, setter, flush, threshold, keeper,
///      pause, router allowlist, recovery, or fee mutation of any kind, and registration is
///      append-only. `BaseHook`'s PoolManager-only callback boundary, the registered `PoolId`, the
///      frozen REGENT, staking and Safe bindings, the strategy-validated splitter, and ordinary EVM
///      atomicity are the complete authority and reentrancy design; no separate guard exists or is
///      needed.
///
///      Settlement follows the pinned v4 convention exactly. The specified currency is currency0
///      exactly when `(amountSpecified < 0) == zeroForOne`; the other raw `BalanceDelta` component
///      is the realized unspecified currency. A positive after-swap return delta charges only that
///      component, preserving the core's specified-currency result for full, partial, and zero fills.
///
///      Named invariants: `FA07-I1` realized unspecified base, `FA07-I2` exact lane split,
///      `FA07-I3` unchanged authority, `FA07-I4` atomic cleanliness, `FA07-I5` observability.
contract RegentFeeHook is BaseHook {
    using SafeTransferLib for address;

    /// @notice The hook fee is `feeBase * HOOK_FEE_BPS / BPS_DENOMINATOR`, 2%, floored once. The Regent
    ///         lane is `feeBase * REGENT_LANE_BPS / BPS_DENOMINATOR`, 1%, floored; the staker lane is the
    ///         rest of the fee, never less than its own floored 1%. Founder decisions 2026-09-28.
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant REGENT_LANE_BPS = 100;
    uint256 public constant STAKER_LANE_BPS = 100;
    uint256 public constant HOOK_FEE_BPS = REGENT_LANE_BPS + STAKER_LANE_BPS;

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
        address indexed feeToken,
        uint256 feeBase,
        uint256 regentLane,
        uint256 stakerLane,
        bool exactInput
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
    error AttributableBalanceNotRestored(uint256 expected, uint256 found);
    error AttributableAllowanceNotRestored(uint256 expected, uint256 found);

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
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Bind one exact official `PoolKey` to one launch splitter. Strategy only, once ever.
    /// @dev The whole key is validated before any state is consumed, and the stored `PoolId` is the
    ///      keccak of that exact key, so a pool whose currencies, fee, tick spacing, or hook differ
    ///      in any byte is a different — and unregistered — pool. `FA07-I3`.
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
    ///      deterministic pool into existence at a price the auction never cleared. `FA07-I3`.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        PoolId poolId = key.toId();
        if (splitterOf[poolId] == address(0)) revert PoolNotRegistered(poolId);
        if (sender != strategy) revert NotStrategy(sender);
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev Charges the fee from the absolute actual unspecified component of the raw core delta,
    ///      then returns it as a positive unspecified-currency hook delta. `FA07-I1`–`I4`.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        (PoolId poolId, address splitter) = _resolve(key);
        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        Currency feeCurrency = specifiedIsCurrency0 ? key.currency1 : key.currency0;
        int256 realizedDelta = specifiedIsCurrency0 ? int256(delta.amount1()) : int256(delta.amount0());
        uint256 feeBase = uint256(realizedDelta < 0 ? -realizedDelta : realizedDelta);

        int128 hookDelta =
            _chargeLanes(poolId, splitter, sender, Currency.unwrap(feeCurrency), feeBase, params.amountSpecified < 0);
        return (BaseHook.afterSwap.selector, hookDelta);
    }

    /// @dev Resolves the registered pool and splitter. Reverts for any key the strategy never
    ///      registered, which is the whole key-side authority
    ///      boundary; `BaseHook` supplies the caller-side one. `FA07-I3`.
    function _resolve(PoolKey calldata key) private view returns (PoolId poolId, address splitter) {
        poolId = key.toId();
        splitter = splitterOf[poolId];
        if (splitter == address(0)) revert PoolNotRegistered(poolId);
    }

    /// @dev Floors the 2% fee once and the 1% Regent lane once; the staker lane is the rest. Settles
    ///      both lanes synchronously: the Regent lane taken straight to REGENT staking when the fee is in
    ///      REGENT (a plain transfer into its reward pool, so a paused staking contract never stops a
    ///      swap) and straight to the Regent Safe when it is in the launch's token; the staker lane
    ///      taken here, exact-approved, and pulled by the registered splitter. The hook's fee-token
    ///      balance and splitter allowance must return to their pre-callback levels, so an inexact
    ///      pull or refund fails the whole swap. A zero fee is a valid no-op that makes no PoolManager,
    ///      token, splitter, or approval call at all. `FA07-I2`, `FA07-I4`.
    function _chargeLanes(
        PoolId poolId,
        address splitter,
        address sender,
        address feeToken,
        uint256 feeBase,
        bool exactInput
    ) private returns (int128) {
        uint256 fee = feeBase * HOOK_FEE_BPS / BPS_DENOMINATOR;
        if (fee == 0) return 0;

        // Never truncate: the returned `int128` hook delta must represent both lanes exactly. A nonzero
        // fee always leaves a nonzero staker lane, since the Regent lane is at most half of it.
        int128 hookDelta = SafeCast.toInt128(fee);
        uint256 regentLane = feeBase * REGENT_LANE_BPS / BPS_DENOMINATOR;
        uint256 stakerLane = fee - regentLane;
        address regentRecipient =
            feeToken == BaseBindings.REGENT ? BaseBindings.LIVE_STAKING : BaseBindings.GOVERNANCE_AND_REGENT_SAFE;

        uint256 balanceBefore = feeToken.balanceOf(address(this));
        uint256 allowanceBefore = IERC20Minimal(feeToken).allowance(address(this), splitter);

        if (regentLane != 0) poolManager.take(Currency.wrap(feeToken), regentRecipient, regentLane);
        poolManager.take(Currency.wrap(feeToken), address(this), stakerLane);

        feeToken.safeApprove(splitter, stakerLane);
        SubjectSplitterV1(splitter).depositRecognizedRevenue(feeToken, stakerLane, PoolId.unwrap(poolId));

        uint256 balanceAfter = feeToken.balanceOf(address(this));
        if (balanceAfter != balanceBefore) revert AttributableBalanceNotRestored(balanceBefore, balanceAfter);
        uint256 allowanceAfter = IERC20Minimal(feeToken).allowance(address(this), splitter);
        if (allowanceAfter != allowanceBefore) {
            revert AttributableAllowanceNotRestored(allowanceBefore, allowanceAfter);
        }

        emit SwapFeeSettled(poolId, sender, feeToken, feeBase, regentLane, stakerLane, exactInput);
        return hookDelta;
    }

    function _requireSplitterBinding(address expected, address found) private pure {
        if (expected != found) revert SplitterBindingMismatch(expected, found);
    }
}
