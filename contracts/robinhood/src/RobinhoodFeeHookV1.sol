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
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20Minimal} from "autolaunch-stocks/interfaces/IERC20Minimal.sol";
import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";
import {IRobinhoodFeeHookV1} from "./interfaces/IRobinhoodFeeHookV1.sol";
import {IRobinhoodProtocolRevenueInboxV1} from "./interfaces/IRobinhoodProtocolRevenueInboxV1.sol";
import {IRobinhoodStockAdmission} from "./interfaces/IRobinhoodStockAdmission.sol";
import {IRobinhoodStockRoute} from "./interfaces/IRobinhoodStockRoute.sol";
import {IRobinhoodSubjectSplitterV1} from "./interfaces/IRobinhoodSubjectSplitterV1.sol";

/// @title RobinhoodFeeHookV1
/// @notice The one shared Uniswap v4 hook every official pool of one Robinhood launchpad carries. It
///         is the Base `StocksFeeHookV1` with the fee currency generalized: a pool's fee currency is
///         whatever the launch raised in (USDG or STOCK), the protocol bucket deposits into the
///         protocol revenue inbox instead of REGENT staking, and USDG buckets need no conversion.
/// @dev v4 lets an after-swap return delta charge only the *unspecified* currency, so the two swap
///      forms in which the fee currency is unspecified are charged in `afterSwap`, and the two in
///      which it is specified are charged in `beforeSwap` through a specified-currency return delta.
///      A fee-currency-specified swap cut short by the trader's own price limit would make that
///      pre-committed fee inexact, so it reverts (`PartialFillNotSupported`).
///
///      Nothing in a swap calls a splitter, a route or the inbox.
contract RobinhoodFeeHookV1 is BaseHook, ReentrancyGuardTransient, IRobinhoodFeeHookV1 {
    using SafeTransferLib for address;
    using PoolIdLibrary for PoolKey;

    struct PoolRecord {
        address feeToken;
        address newToken;
        /// @dev The splitter the subject lane currently accrues to; zero means the lane is off.
        address subject;
    }

    struct SettledTotals {
        uint256 feeTokenConsumed;
        uint256 usdgDeposited;
    }

    /// @notice `sourceTag` the protocol bucket deposits carry into the inbox.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant PROTOCOL_SOURCE_TAG = bytes32("robinhood-hook");

    bytes32 private constant PENDING_LANE_SLOT = keccak256("autolaunch-robinhood.hook.pending-lane");
    bytes32 private constant PENDING_POOL_SLOT = keccak256("autolaunch-robinhood.hook.pending-pool");

    address public immutable override launchpad;
    address public immutable override usdg;
    address public immutable override inbox;
    address public immutable adminSafe;

    /// @notice The only account that may settle a STOCK bucket. Safe-set.
    address public executor;

    mapping(bytes32 poolId => PoolRecord) private _pools;
    mapping(bytes32 poolId => mapping(address destination => uint256 amount)) private _accrued;
    mapping(bytes32 poolId => mapping(address destination => SettledTotals)) private _settled;

    event PoolRegistered(bytes32 indexed poolId, address indexed feeToken, address indexed newToken, address subject);
    event SubjectLaneSet(bytes32 indexed poolId, address indexed previous, address indexed current);
    event ExecutorSet(address indexed previous, address indexed current);
    event LaunchDustAccrued(bytes32 indexed poolId, uint256 amount);

    error ZeroAddress();
    error SelfAddress();
    error NotLaunchpad(address caller);
    error NotSafe(address caller);
    error NotExecutor(address caller);
    error PoolAlreadyRegistered(bytes32 poolId);
    error PoolNotRegistered(bytes32 poolId);
    error ForeignHook(address hooks);
    error UnexpectedPoolFee(uint24 fee);
    error UnexpectedTickSpacing(int24 tickSpacing);
    error CurrencyOrderInvalid(address currency0, address currency1);
    error NativeCurrency();
    error FeeTokenNotInPoolKey(address token);
    error PendingPoolMismatch(bytes32 expected, bytes32 found);
    error PartialFillNotSupported(uint256 expectedRealized, uint256 realized);
    error ZeroAmount();
    error InsufficientAccrual(uint256 accrued, uint256 requested);
    error NoRoute(address stock);
    error InexactTransfer(uint256 expected, uint256 found);
    error InsufficientUsdgOut(uint256 minimum, uint256 found);
    error DepositMismatch(uint256 expected, uint256 reported);
    error AllowanceNotConsumed(address spender, uint256 remaining);
    error BalanceNotRestored(uint256 expected, uint256 found);

    constructor(IPoolManager manager_, address launchpad_, address usdg_, address inbox_, address adminSafe_)
        BaseHook(manager_)
    {
        _requireBindable(launchpad_);
        _requireBindable(usdg_);
        _requireBindable(inbox_);
        _requireBindable(adminSafe_);
        launchpad = launchpad_;
        usdg = usdg_;
        inbox = inbox_;
        adminSafe = adminSafe_;
    }

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert NotLaunchpad(msg.sender);
        _;
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

    // -------------------------------------------------------------------------
    // launchpad surface
    // -------------------------------------------------------------------------

    /// @notice Bind one exact official `PoolKey` to its fee currency and initial subject destination.
    function registerPool(PoolKey calldata key, address feeToken, address newToken, address subject)
        external
        onlyLaunchpad
        returns (bytes32 poolId)
    {
        if (address(key.hooks) != address(this)) revert ForeignHook(address(key.hooks));
        if (key.fee != StocksPreset.POOL_FEE) revert UnexpectedPoolFee(key.fee);
        if (key.tickSpacing != StocksPreset.POOL_TICK_SPACING) revert UnexpectedTickSpacing(key.tickSpacing);

        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (currency0 >= currency1) revert CurrencyOrderInvalid(currency0, currency1);
        if (currency0 == address(0)) revert NativeCurrency();
        bool feeIsCurrency0 = currency0 == feeToken;
        if (!feeIsCurrency0 && currency1 != feeToken) revert FeeTokenNotInPoolKey(feeToken);
        if ((feeIsCurrency0 ? currency1 : currency0) != newToken) revert FeeTokenNotInPoolKey(newToken);

        poolId = PoolId.unwrap(key.toId());
        if (_pools[poolId].feeToken != address(0)) revert PoolAlreadyRegistered(poolId);
        _pools[poolId] = PoolRecord({feeToken: feeToken, newToken: newToken, subject: subject});

        emit PoolRegistered(poolId, feeToken, newToken, subject);
    }

    /// @notice Set the destination future subject-lane accruals of a pool belong to. Zero turns the
    ///         lane off. Existing buckets are untouched.
    function setSubject(bytes32 poolId, address subject) external onlyLaunchpad {
        PoolRecord storage record = _requireRegistered(poolId);
        address previous = record.subject;
        record.subject = subject;
        emit SubjectLaneSet(poolId, previous, subject);
    }

    /// @notice Credit fee currency the launchpad's graduation did not place in a position to the
    ///         pool's protocol bucket. The exact amount is pulled inside this call.
    function creditProtocolLane(bytes32 poolId, uint256 amount) external onlyLaunchpad {
        PoolRecord storage record = _requireRegistered(poolId);
        if (amount == 0) revert ZeroAmount();

        _accrued[poolId][inbox] += amount;
        emit LaunchDustAccrued(poolId, amount);

        address feeToken = record.feeToken;
        uint256 before = feeToken.balanceOf(address(this));
        feeToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = feeToken.balanceOf(address(this)) - before;
        if (received != amount) revert InexactTransfer(amount, received);
    }

    // -------------------------------------------------------------------------
    // Safe surface
    // -------------------------------------------------------------------------

    /// @notice Set the account allowed to settle STOCK buckets. Zero disables STOCK settlement.
    function setExecutor(address executor_) external {
        if (msg.sender != adminSafe) revert NotSafe(msg.sender);
        address previous = executor;
        // slither-disable-next-line missing-zero-check
        executor = executor_;
        emit ExecutorSet(previous, executor_);
    }

    // -------------------------------------------------------------------------
    // settlement
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodFeeHookV1
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function settle(bytes32 poolId, address destination, uint256 amount, uint256 minUsdgOut)
        external
        override
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        PoolRecord storage record = _requireRegistered(poolId);
        address feeToken = record.feeToken;
        bool needsConversion = feeToken != usdg;
        if (needsConversion && (executor == address(0) || msg.sender != executor)) revert NotExecutor(msg.sender);

        uint256 available = _accrued[poolId][destination];
        if (available < amount) revert InsufficientAccrual(available, amount);

        // Effects before interactions: the bucket is debited before any token moves.
        _accrued[poolId][destination] = available - amount;

        uint256 usdgBefore = usdg.balanceOf(address(this));
        uint256 consumed = amount;
        uint256 usdgOut = amount;
        if (needsConversion) {
            (consumed, usdgOut) = _convert(poolId, destination, feeToken, amount);
        }
        if (usdgOut < minUsdgOut) revert InsufficientUsdgOut(minUsdgOut, usdgOut);

        if (destination == inbox) {
            usdg.safeApprove(inbox, usdgOut);
            uint256 received = IRobinhoodProtocolRevenueInboxV1(inbox).deposit(usdgOut, PROTOCOL_SOURCE_TAG, poolId);
            if (received != usdgOut) revert DepositMismatch(usdgOut, received);
            _requireAllowanceConsumed(usdg, inbox);
        } else {
            usdg.safeApprove(destination, usdgOut);
            IRobinhoodSubjectSplitterV1(destination).depositRecognizedRevenue(usdg, usdgOut, poolId);
            _requireAllowanceConsumed(usdg, destination);
        }

        // A USDG bucket leaves exactly its amount; a STOCK bucket's USDG comes and goes inside the call.
        uint256 usdgExpected = needsConversion ? usdgBefore : usdgBefore - amount;
        uint256 usdgAfter = usdg.balanceOf(address(this));
        if (usdgAfter != usdgExpected) revert BalanceNotRestored(usdgExpected, usdgAfter);

        SettledTotals storage totals = _settled[poolId][destination];
        totals.feeTokenConsumed += consumed;
        totals.usdgDeposited += usdgOut;

        emit BucketSettled(poolId, destination, consumed, usdgOut, poolId);
    }

    /// @dev STOCK -> USDG through the launchpad's admitted route. STOCK the route hands back is
    ///      re-credited to the bucket, never lost.
    function _convert(bytes32 poolId, address destination, address stock, uint256 amount)
        private
        returns (uint256 consumed, uint256 usdgOut)
    {
        // slither-disable-next-line unused-return
        (,, address route) = IRobinhoodStockAdmission(launchpad).stockAdmission(stock);
        if (route == address(0)) revert NoRoute(stock);

        uint256 stockBefore = stock.balanceOf(address(this));
        uint256 usdgBefore = usdg.balanceOf(address(this));

        stock.safeTransfer(route, amount);
        // slither-disable-next-line unused-return
        IRobinhoodStockRoute(route).swapExactIn(stock, usdg, amount, 0, address(this));

        consumed = stockBefore - stock.balanceOf(address(this));
        if (consumed > amount) revert InexactTransfer(amount, consumed);
        uint256 residue = amount - consumed;
        if (residue != 0) _accrued[poolId][destination] += residue;

        usdgOut = usdg.balanceOf(address(this)) - usdgBefore;
        if (usdgOut == 0) revert InsufficientUsdgOut(1, 0);
    }

    // -------------------------------------------------------------------------
    // reads
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodFeeHookV1
    function PROTOCOL_DESTINATION() external view override returns (address) {
        return inbox;
    }

    /// @inheritdoc IRobinhoodFeeHookV1
    function accrued(bytes32 poolId, address destination) external view override returns (uint256) {
        return _accrued[poolId][destination];
    }

    /// @inheritdoc IRobinhoodFeeHookV1
    function settled(bytes32 poolId, address destination)
        external
        view
        override
        returns (uint256 feeTokenConsumed, uint256 usdgDeposited)
    {
        SettledTotals storage totals = _settled[poolId][destination];
        return (totals.feeTokenConsumed, totals.usdgDeposited);
    }

    function pool(bytes32 poolId) external view returns (PoolRecord memory) {
        return _pools[poolId];
    }

    /// @notice The smallest per-lane fee `q` with `q == (net + lanes * q) / LANE_DIVISOR`.
    function grossLane(uint256 net, uint256 lanes) public pure returns (uint256) {
        if (net < StocksPreset.LANE_DIVISOR) return 0;
        return (net - StocksPreset.LANE_DIVISOR) / (StocksPreset.LANE_DIVISOR - lanes) + 1;
    }

    // -------------------------------------------------------------------------
    // hook callbacks (PoolManager only, via BaseHook)
    // -------------------------------------------------------------------------

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        bytes32 poolId = PoolId.unwrap(key.toId());
        if (_pools[poolId].feeToken == address(0)) revert PoolNotRegistered(poolId);
        if (sender != launchpad) revert NotLaunchpad(sender);
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());
        PoolRecord storage record = _requireRegistered(poolId);

        bool exactInput = params.amountSpecified < 0;
        bool feeIsCurrency0 = Currency.unwrap(key.currency0) == record.feeToken;
        bool feeSpecified = (exactInput == params.zeroForOne) == feeIsCurrency0;
        if (!feeSpecified) return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 lanes = record.subject == address(0) ? 1 : 2;
        uint256 requested = _abs(params.amountSpecified);
        uint256 lane = exactInput ? requested / StocksPreset.LANE_DIVISOR : grossLane(requested, lanes);

        _tstore(PENDING_LANE_SLOT, lane);
        _tstore(PENDING_POOL_SLOT, uint256(poolId));
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(SafeCast.toInt128(lanes * lane), 0), 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());
        PoolRecord storage record = _requireRegistered(poolId);
        address subject = record.subject;
        uint256 lanes = subject == address(0) ? 1 : 2;

        bool exactInput = params.amountSpecified < 0;
        bool feeIsCurrency0 = Currency.unwrap(key.currency0) == record.feeToken;
        bool feeSpecified = (exactInput == params.zeroForOne) == feeIsCurrency0;
        bool feeIsInput = feeIsCurrency0 == params.zeroForOne;
        uint256 realized = _abs(feeIsCurrency0 ? int256(delta.amount0()) : int256(delta.amount1()));

        uint256 lane;
        uint256 feeBase;
        int128 hookDeltaUnspecified = 0;
        if (feeSpecified) {
            bytes32 pendingPool = bytes32(_tload(PENDING_POOL_SLOT));
            if (pendingPool != poolId) revert PendingPoolMismatch(poolId, pendingPool);
            lane = _tload(PENDING_LANE_SLOT);
            _tstore(PENDING_LANE_SLOT, 0);
            _tstore(PENDING_POOL_SLOT, 0);

            uint256 requested = _abs(params.amountSpecified);
            uint256 fee = lanes * lane;
            uint256 expectedRealized = exactInput ? requested - fee : requested + fee;
            if (realized != expectedRealized) revert PartialFillNotSupported(expectedRealized, realized);
            feeBase = exactInput ? requested : requested + fee;
        } else if (feeIsInput) {
            lane = grossLane(realized, lanes);
            feeBase = realized + lanes * lane;
            hookDeltaUnspecified = SafeCast.toInt128(lanes * lane);
        } else {
            // slither-disable-next-line divide-before-multiply
            lane = realized / StocksPreset.LANE_DIVISOR;
            feeBase = realized;
            hookDeltaUnspecified = SafeCast.toInt128(lanes * lane);
        }

        if (lane != 0) {
            _accrued[poolId][inbox] += lane;
            if (subject != address(0)) _accrued[poolId][subject] += lane;
            // slither-disable-next-line divide-before-multiply
            poolManager.take(Currency.wrap(record.feeToken), address(this), lanes * lane);
        }

        // slither-disable-next-line reentrancy-events
        emit HookFeeAccrued(poolId, subject, feeBase, lane, subject == address(0) ? 0 : lane);
        return (BaseHook.afterSwap.selector, hookDeltaUnspecified);
    }

    // -------------------------------------------------------------------------
    // internals
    // -------------------------------------------------------------------------

    function _requireBindable(address value) private view {
        if (value == address(0)) revert ZeroAddress();
        if (value == address(this)) revert SelfAddress();
    }

    function _requireRegistered(bytes32 poolId) private view returns (PoolRecord storage record) {
        record = _pools[poolId];
        if (record.feeToken == address(0)) revert PoolNotRegistered(poolId);
    }

    function _requireAllowanceConsumed(address token, address spender) private view {
        uint256 remaining = IERC20Minimal(token).allowance(address(this), spender);
        if (remaining != 0) revert AllowanceNotConsumed(spender, remaining);
    }

    function _abs(int256 value) private pure returns (uint256) {
        return uint256(value < 0 ? -value : value);
    }

    function _tstore(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _tload(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}
