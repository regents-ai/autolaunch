// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IRegentRevenueStakingMinimal} from "./interfaces/IRegentRevenueStakingMinimal.sol";
import {IStockRoute} from "./interfaces/IStockRoute.sol";
import {IStocksFeeHookV1} from "./interfaces/IStocksFeeHookV1.sol";
import {IStocksLaunchpadV1} from "./interfaces/IStocksLaunchpadV1.sol";
import {ISubjectSplitterMinimal} from "./interfaces/ISubjectSplitterMinimal.sol";
import {StocksBindings} from "./StocksBindings.sol";
import {StocksPreset} from "./StocksPreset.sol";

/// @title StocksFeeHookV1
/// @notice The one shared Uniswap v4 hook every official NEW/STOCK pool carries. It charges STOCK-side
///         fees on every swap of a registered pool and only accrues them per `(poolId, destination)`
///         bucket. Conversion and deposits happen outside swaps through `settle`.
/// @dev Fee base is the gross realized STOCK amount of the swap: the trader's total STOCK debit
///      (including the fee) for STOCK-input swaps, the pool's total STOCK output (before the fee) for
///      STOCK-output swaps. Each enabled lane is `feeBase / LANE_DIVISOR`, floored independently.
///
///      v4 lets an after-swap return delta charge only the *unspecified* currency, so the two swap
///      forms in which STOCK is unspecified (exact-input NEW->STOCK, exact-output STOCK->NEW) are
///      charged in `afterSwap`, and the two in which STOCK is specified (exact-input STOCK->NEW,
///      exact-output NEW->STOCK) are charged in `beforeSwap` through a specified-currency return
///      delta, which shrinks (exact input) or grows (exact output) the amount the core swaps by the
///      exact fee. A STOCK-specified swap whose core fill is cut short by the trader's own price limit
///      would make that pre-committed fee inexact, so it reverts (`PartialFillNotSupported`) instead
///      of over- or under-charging; STOCK-unspecified swaps fill partially as usual.
///
///      Nothing in a swap calls a splitter, a route or REGENT staking. Every accrual is attributed to
///      the destination in effect when it accrued; later administration never redirects a bucket.
contract StocksFeeHookV1 is BaseHook, ReentrancyGuardTransient, IStocksFeeHookV1 {
    using SafeTransferLib for address;
    using PoolIdLibrary for PoolKey;

    /// @notice One registered official pool.
    struct PoolRecord {
        address stock;
        address newToken;
        /// @dev The splitter the subject lane currently accrues to; zero means the lane is off.
        address subject;
    }

    struct SettledTotals {
        uint256 stockConverted;
        uint256 usdcDeposited;
    }

    /// @notice `sourceTag` the REGENT bucket deposits carry into live staking.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant REGENT_SOURCE_TAG = bytes32("autolaunch-stocks");

    /// @dev Transient slots carrying a STOCK-specified swap's pre-committed lane from `beforeSwap` to
    ///      `afterSwap`. PoolManager runs the two callbacks back to back for one swap, and the hook's
    ///      own nested calls never reach these callbacks (`Hooks.noSelfCall`).
    bytes32 private constant PENDING_LANE_SLOT = keccak256("autolaunch-stocks.hook.pending-lane");
    bytes32 private constant PENDING_POOL_SLOT = keccak256("autolaunch-stocks.hook.pending-pool");

    /// @notice The only account that may register pools, initialize them, set subject lanes or
    ///         credit launch dust.
    address public immutable override launchpad;

    /// @notice The only account that may `settle`. Governance-set.
    address public executor;

    mapping(bytes32 poolId => PoolRecord) private _pools;
    mapping(bytes32 poolId => mapping(address destination => uint256 stock)) private _accrued;
    mapping(bytes32 poolId => mapping(address destination => SettledTotals)) private _settled;

    event PoolRegistered(bytes32 indexed poolId, address indexed stock, address indexed newToken, address subject);
    event SubjectLaneSet(bytes32 indexed poolId, address indexed previous, address indexed current);
    event ExecutorSet(address indexed previous, address indexed current);
    /// @notice STOCK the launchpad's graduation could not place in the position, credited to the
    ///         pool's REGENT bucket.
    event LaunchDustAccrued(bytes32 indexed poolId, uint256 amount);

    error ZeroAddress();
    error SelfAddress();
    error NotLaunchpad(address caller);
    error NotGovernance(address caller);
    error NotExecutor(address caller);
    error PoolAlreadyRegistered(bytes32 poolId);
    error PoolNotRegistered(bytes32 poolId);
    error ForeignHook(address hooks);
    error UnexpectedPoolFee(uint24 fee);
    error UnexpectedTickSpacing(int24 tickSpacing);
    error CurrencyOrderInvalid(address currency0, address currency1);
    error NativeCurrency();
    error StockNotInPoolKey(address stock);
    error PendingPoolMismatch(bytes32 expected, bytes32 found);
    error PartialFillNotSupported(uint256 expectedRealized, uint256 realized);
    error ZeroAmount();
    error InsufficientAccrual(uint256 accrued, uint256 requested);
    error NoRoute(address stock);
    error InexactTransfer(uint256 expected, uint256 found);
    error InsufficientUsdcOut(uint256 minimum, uint256 found);
    error DepositMismatch(uint256 expected, uint256 reported);
    error AllowanceNotConsumed(address spender, uint256 remaining);
    error BalanceNotRestored(uint256 expected, uint256 found);

    /// @dev `BaseHook` validates that this address carries exactly the permission bits
    ///      `getHookPermissions` declares, so a mis-mined deployment cannot exist.
    constructor(IPoolManager manager_, address launchpad_) BaseHook(manager_) {
        if (launchpad_ == address(0)) revert ZeroAddress();
        if (launchpad_ == address(this)) revert SelfAddress();
        launchpad = launchpad_;
    }

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert NotLaunchpad(msg.sender);
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != StocksBindings.GOVERNANCE_AND_REGENT_SAFE) revert NotGovernance(msg.sender);
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

    /// @notice Bind one exact official `PoolKey` to its STOCK and initial subject destination.
    ///         Launchpad only, once per pool.
    function registerPool(PoolKey calldata key, address stock, address newToken, address subject)
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
        bool stockIsCurrency0 = currency0 == stock;
        if (!stockIsCurrency0 && currency1 != stock) revert StockNotInPoolKey(stock);
        if ((stockIsCurrency0 ? currency1 : currency0) != newToken) revert StockNotInPoolKey(newToken);

        poolId = PoolId.unwrap(key.toId());
        if (_pools[poolId].stock != address(0)) revert PoolAlreadyRegistered(poolId);
        _pools[poolId] = PoolRecord({stock: stock, newToken: newToken, subject: subject});

        emit PoolRegistered(poolId, stock, newToken, subject);
    }

    /// @notice Set the destination future subject-lane accruals of a pool belong to. Zero turns the
    ///         lane off. Launchpad only; existing buckets are untouched.
    function setSubject(bytes32 poolId, address subject) external onlyLaunchpad {
        PoolRecord storage record = _requireRegistered(poolId);
        address previous = record.subject;
        record.subject = subject;
        emit SubjectLaneSet(poolId, previous, subject);
    }

    /// @notice Credit STOCK the launchpad's graduation did not place in the position to the pool's
    ///         REGENT bucket. Launchpad only; the exact amount is pulled inside this call.
    function creditRegentLane(bytes32 poolId, uint256 amount) external onlyLaunchpad {
        PoolRecord storage record = _requireRegistered(poolId);
        if (amount == 0) revert ZeroAmount();

        _accrued[poolId][REGENT_DESTINATION()] += amount;
        emit LaunchDustAccrued(poolId, amount);

        address stock = record.stock;
        uint256 before = stock.balanceOf(address(this));
        stock.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stock.balanceOf(address(this)) - before;
        if (received != amount) revert InexactTransfer(amount, received);
    }

    // -------------------------------------------------------------------------
    // governance surface
    // -------------------------------------------------------------------------

    /// @notice Set the account allowed to `settle`. Governance only. Zero disables settlement.
    function setExecutor(address executor_) external onlyGovernance {
        address previous = executor;
        // slither-disable-next-line missing-zero-check
        executor = executor_;
        emit ExecutorSet(previous, executor_);
    }

    // -------------------------------------------------------------------------
    // settlement
    // -------------------------------------------------------------------------

    /// @inheritdoc IStocksFeeHookV1
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function settle(bytes32 poolId, address destination, uint256 stockAmount, uint256 minUsdcOut)
        external
        override
        nonReentrant
    {
        if (executor == address(0) || msg.sender != executor) revert NotExecutor(msg.sender);
        if (stockAmount == 0) revert ZeroAmount();
        PoolRecord storage record = _requireRegistered(poolId);

        uint256 available = _accrued[poolId][destination];
        if (available < stockAmount) revert InsufficientAccrual(available, stockAmount);

        address stock = record.stock;
        // slither-disable-next-line unused-return
        (,, address route) = IStocksLaunchpadV1(launchpad).stockAdmission(stock);
        if (route == address(0)) revert NoRoute(stock);

        // Effects before interactions: the bucket is debited before any token moves.
        _accrued[poolId][destination] = available - stockAmount;

        address usdc = StocksBindings.USDC;
        uint256 stockBefore = stock.balanceOf(address(this));
        uint256 usdcBefore = usdc.balanceOf(address(this));

        stock.safeTransfer(route, stockAmount);
        // slither-disable-next-line unused-return
        IStockRoute(route).swapExactIn(stock, usdc, stockAmount, minUsdcOut, address(this));

        uint256 stockAfter = stock.balanceOf(address(this));
        // The route may hand back STOCK it did not consume; that residue is re-credited, never lost.
        uint256 consumed = stockBefore - stockAfter;
        if (consumed > stockAmount) revert InexactTransfer(stockAmount, consumed);
        uint256 residue = stockAmount - consumed;
        if (residue != 0) _accrued[poolId][destination] += residue;

        uint256 usdcOut = usdc.balanceOf(address(this)) - usdcBefore;
        if (usdcOut < minUsdcOut || usdcOut == 0) revert InsufficientUsdcOut(minUsdcOut, usdcOut);

        if (destination == REGENT_DESTINATION()) {
            usdc.safeApprove(StocksBindings.LIVE_STAKING, usdcOut);
            uint256 received =
                IRegentRevenueStakingMinimal(StocksBindings.LIVE_STAKING).depositUSDC(usdcOut, REGENT_SOURCE_TAG, poolId);
            if (received != usdcOut) revert DepositMismatch(usdcOut, received);
            _requireAllowanceConsumed(usdc, StocksBindings.LIVE_STAKING);
        } else {
            usdc.safeApprove(destination, usdcOut);
            ISubjectSplitterMinimal(destination).depositRecognizedRevenue(usdc, usdcOut, poolId);
            _requireAllowanceConsumed(usdc, destination);
        }

        uint256 usdcAfter = usdc.balanceOf(address(this));
        if (usdcAfter != usdcBefore) revert BalanceNotRestored(usdcBefore, usdcAfter);

        SettledTotals storage totals = _settled[poolId][destination];
        totals.stockConverted += consumed;
        totals.usdcDeposited += usdcOut;

        emit BucketSettled(poolId, destination, consumed, usdcOut, poolId);
    }

    // -------------------------------------------------------------------------
    // reads
    // -------------------------------------------------------------------------

    /// @inheritdoc IStocksFeeHookV1
    function REGENT_DESTINATION() public pure override returns (address) {
        return StocksBindings.REGENT;
    }

    /// @inheritdoc IStocksFeeHookV1
    function accrued(bytes32 poolId, address destination) external view override returns (uint256) {
        return _accrued[poolId][destination];
    }

    /// @inheritdoc IStocksFeeHookV1
    function settled(bytes32 poolId, address destination)
        external
        view
        override
        returns (uint256 stockConverted, uint256 usdcDeposited)
    {
        SettledTotals storage totals = _settled[poolId][destination];
        return (totals.stockConverted, totals.usdcDeposited);
    }

    /// @notice The registered record of a pool: its STOCK, its NEW and the current subject destination.
    function pool(bytes32 poolId) external view returns (PoolRecord memory) {
        return _pools[poolId];
    }

    /// @notice The smallest per-lane fee `q` with `q == (net + lanes * q) / LANE_DIVISOR`, so that
    ///         charging `lanes * q` on top of a net STOCK amount makes each lane exactly one percent,
    ///         floored, of the gross amount.
    function grossLane(uint256 net, uint256 lanes) public pure returns (uint256) {
        if (net < StocksPreset.LANE_DIVISOR) return 0;
        return (net - StocksPreset.LANE_DIVISOR) / (StocksPreset.LANE_DIVISOR - lanes) + 1;
    }

    // -------------------------------------------------------------------------
    // hook callbacks (PoolManager only, via BaseHook)
    // -------------------------------------------------------------------------

    /// @dev Only the launchpad may initialize a registered official pool, so nobody can front-run the
    ///      deterministic pool into existence at a price the auction never cleared.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        bytes32 poolId = PoolId.unwrap(key.toId());
        if (_pools[poolId].stock == address(0)) revert PoolNotRegistered(poolId);
        if (sender != launchpad) revert NotLaunchpad(sender);
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev STOCK-specified swaps pre-commit their exact fee as a specified-currency delta.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());
        PoolRecord storage record = _requireRegistered(poolId);

        bool exactInput = params.amountSpecified < 0;
        bool stockIsCurrency0 = Currency.unwrap(key.currency0) == record.stock;
        bool stockSpecified = (exactInput == params.zeroForOne) == stockIsCurrency0;
        if (!stockSpecified) return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 lanes = record.subject == address(0) ? 1 : 2;
        uint256 requested = _abs(params.amountSpecified);
        // Exact input: the trader's debit is `requested`, so each lane is one percent of it and the
        // core swaps the rest. Exact output: the trader receives `requested`, so the pool outputs the
        // gross amount and each lane is one percent of that gross amount.
        uint256 lane = exactInput ? requested / StocksPreset.LANE_DIVISOR : grossLane(requested, lanes);

        _tstore(PENDING_LANE_SLOT, lane);
        _tstore(PENDING_POOL_SLOT, uint256(poolId));
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(SafeCast.toInt128(lanes * lane), 0), 0);
    }

    /// @dev Takes the fee in STOCK and accrues it per bucket. STOCK-unspecified swaps return the fee
    ///      as a positive unspecified delta; STOCK-specified swaps already carry it from `beforeSwap`.
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
        bool stockIsCurrency0 = Currency.unwrap(key.currency0) == record.stock;
        bool stockSpecified = (exactInput == params.zeroForOne) == stockIsCurrency0;
        bool stockIsInput = stockIsCurrency0 == params.zeroForOne;
        uint256 realized = _abs(stockIsCurrency0 ? int256(delta.amount0()) : int256(delta.amount1()));

        uint256 lane;
        uint256 feeBase;
        int128 hookDeltaUnspecified = 0;
        if (stockSpecified) {
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
        } else if (stockIsInput) {
            lane = grossLane(realized, lanes);
            feeBase = realized + lanes * lane;
            hookDeltaUnspecified = SafeCast.toInt128(lanes * lane);
        } else {
            // Each lane is floored independently and the same lane is charged `lanes` times: two equal
            // lanes, never one floored two percent.
            // slither-disable-next-line divide-before-multiply
            lane = realized / StocksPreset.LANE_DIVISOR;
            feeBase = realized;
            hookDeltaUnspecified = SafeCast.toInt128(lanes * lane);
        }

        if (lane != 0) {
            _accrued[poolId][REGENT_DESTINATION()] += lane;
            if (subject != address(0)) _accrued[poolId][subject] += lane;
            // slither-disable-next-line divide-before-multiply
            poolManager.take(Currency.wrap(record.stock), address(this), lanes * lane);
        }

        // slither-disable-next-line reentrancy-events
        emit HookFeeAccrued(poolId, subject, feeBase, lane, subject == address(0) ? 0 : lane);
        return (BaseHook.afterSwap.selector, hookDeltaUnspecified);
    }

    // -------------------------------------------------------------------------
    // internals
    // -------------------------------------------------------------------------

    function _requireRegistered(bytes32 poolId) private view returns (PoolRecord storage record) {
        record = _pools[poolId];
        if (record.stock == address(0)) revert PoolNotRegistered(poolId);
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
