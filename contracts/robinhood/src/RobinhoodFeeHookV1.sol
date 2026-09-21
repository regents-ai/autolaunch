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
import {IERC20Views} from "autolaunch-stocks/interfaces/IERC20Views.sol";
import {IMemestockSplitterMinimal} from "autolaunch-stocks/interfaces/IMemestockSplitterMinimal.sol";
import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";
import {IRobinhoodFeeHookV1} from "./interfaces/IRobinhoodFeeHookV1.sol";
import {IRobinhoodProtocolRevenueInboxV1} from "./interfaces/IRobinhoodProtocolRevenueInboxV1.sol";
import {IRobinhoodStockAdmission} from "./interfaces/IRobinhoodStockAdmission.sol";
import {IRobinhoodStockRoute} from "./interfaces/IRobinhoodStockRoute.sol";

/// @title RobinhoodFeeHookV1
/// @notice The one shared Uniswap v4 hook every official NEW/STOCK pool of the Robinhood launchpad
///         carries. It is the Base `StocksFeeHookV1` with the chain's destinations: it charges two
///         equal STOCK-side lanes on every swap of a registered pool and only accrues them, the
///         protocol lane (converted to USDG and deposited into the protocol revenue inbox) and the
///         staker lane of the pool's memestock splitter. Conversion and deposits happen outside swaps
///         through `settleProtocolLane` and `settleStakerLane`.
/// @dev Fee base is the gross realized STOCK amount of the swap: the trader's total STOCK debit
///      (including the fee) for STOCK-input swaps, the pool's total STOCK output (before the fee) for
///      STOCK-output swaps. Each lane is `feeBase / LANE_DIVISOR`, floored independently.
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
///      Nothing in a swap calls a splitter, a route or the inbox. A pool's splitter is fixed when
///      the pool is registered; nothing redirects either lane afterwards.
contract RobinhoodFeeHookV1 is BaseHook, ReentrancyGuardTransient, IRobinhoodFeeHookV1 {
    using SafeTransferLib for address;
    using PoolIdLibrary for PoolKey;

    /// @notice One registered official pool.
    struct PoolRecord {
        address stock;
        address newToken;
        /// @dev The launch's memestock splitter, the staker lane's only destination.
        address splitter;
    }

    /// @dev STOCK accrued and not yet settled, per lane.
    struct Accrued {
        uint256 protocolLane;
        uint256 stakerLane;
    }

    struct SettledTotals {
        uint256 stockConverted;
        uint256 usdgDeposited;
        uint256 stockDepositedToStakers;
    }

    /// @dev Both lanes are always charged.
    uint256 private constant LANES = 2;

    /// @notice `sourceTag` the protocol lane deposits carry into the inbox.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant PROTOCOL_SOURCE_TAG = bytes32("robinhood-hook");

    /// @dev Transient slots carrying a STOCK-specified swap's pre-committed lane from `beforeSwap` to
    ///      `afterSwap`. PoolManager runs the two callbacks back to back for one swap, and the hook's
    ///      own nested calls never reach these callbacks (`Hooks.noSelfCall`).
    bytes32 private constant PENDING_LANE_SLOT = keccak256("autolaunch-robinhood.hook.pending-lane");
    bytes32 private constant PENDING_POOL_SLOT = keccak256("autolaunch-robinhood.hook.pending-pool");

    /// @notice The only account that may register pools, initialize them or credit launch dust.
    address public immutable override launchpad;
    address public immutable override usdg;
    address public immutable override inbox;
    address public immutable adminSafe;

    /// @notice The only account that may `settleProtocolLane`. Safe-set.
    address public executor;

    mapping(bytes32 poolId => PoolRecord) private _pools;
    mapping(bytes32 poolId => Accrued) private _accrued;
    mapping(bytes32 poolId => SettledTotals) private _settled;

    event PoolRegistered(bytes32 indexed poolId, address indexed stock, address indexed newToken, address splitter);
    event ExecutorSet(address indexed previous, address indexed current);
    /// @notice STOCK the launchpad's graduation could not place in the position, credited to the
    ///         pool's protocol lane.
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
    error StockNotInPoolKey(address stock);
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

    /// @dev `BaseHook` validates that this address carries exactly the permission bits
    ///      `getHookPermissions` declares, so a mis-mined deployment cannot exist.
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

    /// @notice Bind one exact official `PoolKey` to its STOCK and its memestock splitter. Launchpad
    ///         only, once per pool.
    function registerPool(PoolKey calldata key, address stock, address newToken, address splitter)
        external
        onlyLaunchpad
        returns (bytes32 poolId)
    {
        if (splitter == address(0)) revert ZeroAddress();
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
        _pools[poolId] = PoolRecord({stock: stock, newToken: newToken, splitter: splitter});

        emit PoolRegistered(poolId, stock, newToken, splitter);
    }

    /// @notice Credit STOCK the launchpad's graduation did not place in the position to the pool's
    ///         protocol lane. Launchpad only; the exact amount is pulled inside this call.
    function creditProtocolLane(bytes32 poolId, uint256 amount) external onlyLaunchpad {
        PoolRecord storage record = _requireRegistered(poolId);
        if (amount == 0) revert ZeroAmount();

        _accrued[poolId].protocolLane += amount;
        emit LaunchDustAccrued(poolId, amount);

        address stock = record.stock;
        uint256 before = stock.balanceOf(address(this));
        stock.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stock.balanceOf(address(this)) - before;
        if (received != amount) revert InexactTransfer(amount, received);
    }

    // -------------------------------------------------------------------------
    // Safe surface
    // -------------------------------------------------------------------------

    /// @notice Set the account allowed to `settleProtocolLane`. Safe only. Zero disables it.
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
    function settleProtocolLane(bytes32 poolId, uint256 stockAmount, uint256 minUsdgOut) external override nonReentrant {
        if (executor == address(0) || msg.sender != executor) revert NotExecutor(msg.sender);
        if (stockAmount == 0) revert ZeroAmount();
        PoolRecord storage record = _requireRegistered(poolId);

        Accrued storage bucket = _accrued[poolId];
        uint256 available = bucket.protocolLane;
        if (available < stockAmount) revert InsufficientAccrual(available, stockAmount);

        address stock = record.stock;
        // slither-disable-next-line unused-return
        (,, address route) = IRobinhoodStockAdmission(launchpad).stockAdmission(stock);
        if (route == address(0)) revert NoRoute(stock);

        // Effects before interactions: the lane is debited before any token moves.
        bucket.protocolLane = available - stockAmount;

        uint256 stockBefore = stock.balanceOf(address(this));
        uint256 usdgBefore = usdg.balanceOf(address(this));

        stock.safeTransfer(route, stockAmount);
        // slither-disable-next-line unused-return
        IRobinhoodStockRoute(route).swapExactIn(stock, usdg, stockAmount, minUsdgOut, address(this));

        uint256 stockAfter = stock.balanceOf(address(this));
        // The route may hand back STOCK it did not consume; that residue is re-credited, never lost.
        uint256 consumed = stockBefore - stockAfter;
        if (consumed > stockAmount) revert InexactTransfer(stockAmount, consumed);
        uint256 residue = stockAmount - consumed;
        if (residue != 0) bucket.protocolLane += residue;

        uint256 usdgOut = usdg.balanceOf(address(this)) - usdgBefore;
        if (usdgOut < minUsdgOut || usdgOut == 0) revert InsufficientUsdgOut(minUsdgOut, usdgOut);

        usdg.safeApprove(inbox, usdgOut);
        uint256 received = IRobinhoodProtocolRevenueInboxV1(inbox).deposit(usdgOut, PROTOCOL_SOURCE_TAG, poolId);
        if (received != usdgOut) revert DepositMismatch(usdgOut, received);
        _requireAllowanceConsumed(usdg, inbox);

        uint256 usdgAfter = usdg.balanceOf(address(this));
        if (usdgAfter != usdgBefore) revert BalanceNotRestored(usdgBefore, usdgAfter);

        SettledTotals storage totals = _settled[poolId];
        totals.stockConverted += consumed;
        totals.usdgDeposited += usdgOut;

        emit ProtocolLaneSettled(poolId, consumed, usdgOut);
    }

    /// @inheritdoc IRobinhoodFeeHookV1
    /// @dev Permissionless because it decides nothing: the whole staker lane, in STOCK as it accrued,
    ///      always into the pool's fixed splitter.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function settleStakerLane(bytes32 poolId) external override nonReentrant returns (uint256 stockDeposited) {
        PoolRecord storage record = _requireRegistered(poolId);

        Accrued storage bucket = _accrued[poolId];
        stockDeposited = bucket.stakerLane;
        if (stockDeposited == 0) revert ZeroAmount();

        // Effects before interactions: the lane is debited before any token moves.
        bucket.stakerLane = 0;
        _settled[poolId].stockDepositedToStakers += stockDeposited;

        address stock = record.stock;
        address splitter = record.splitter;
        uint256 stockBefore = stock.balanceOf(address(this));

        stock.safeApprove(splitter, stockDeposited);
        IMemestockSplitterMinimal(splitter).depositRecognizedRevenue(stock, stockDeposited, poolId);
        _requireAllowanceConsumed(stock, splitter);

        uint256 sent = stockBefore - stock.balanceOf(address(this));
        if (sent != stockDeposited) revert InexactTransfer(stockDeposited, sent);

        emit StakerLaneSettled(poolId, splitter, stockDeposited);
    }

    // -------------------------------------------------------------------------
    // reads
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodFeeHookV1
    function accrued(bytes32 poolId) external view override returns (uint256 protocolLane, uint256 stakerLane) {
        Accrued storage bucket = _accrued[poolId];
        return (bucket.protocolLane, bucket.stakerLane);
    }

    /// @inheritdoc IRobinhoodFeeHookV1
    function settled(bytes32 poolId)
        external
        view
        override
        returns (uint256 stockConverted, uint256 usdgDeposited, uint256 stockDepositedToStakers)
    {
        SettledTotals storage totals = _settled[poolId];
        return (totals.stockConverted, totals.usdgDeposited, totals.stockDepositedToStakers);
    }

    /// @notice The registered record of a pool: its STOCK, its NEW and its memestock splitter.
    function pool(bytes32 poolId) external view returns (PoolRecord memory) {
        return _pools[poolId];
    }

    /// @notice The smallest per-lane fee `q` with `q == (net + 2 * q) / LANE_DIVISOR`, so that charging
    ///         both lanes on top of a net STOCK amount makes each lane exactly one percent, floored, of
    ///         the gross amount.
    function grossLane(uint256 net) public pure returns (uint256) {
        if (net < StocksPreset.LANE_DIVISOR) return 0;
        return (net - StocksPreset.LANE_DIVISOR) / (StocksPreset.LANE_DIVISOR - LANES) + 1;
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

        uint256 requested = _abs(params.amountSpecified);
        // Exact input: the trader's debit is `requested`, so each lane is one percent of it and the
        // core swaps the rest. Exact output: the trader receives `requested`, so the pool outputs the
        // gross amount and each lane is one percent of that gross amount.
        uint256 lane = exactInput ? requested / StocksPreset.LANE_DIVISOR : grossLane(requested);

        _tstore(PENDING_LANE_SLOT, lane);
        _tstore(PENDING_POOL_SLOT, uint256(poolId));
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(SafeCast.toInt128(LANES * lane), 0), 0);
    }

    /// @dev Takes the fee in STOCK and accrues it to both lanes. STOCK-unspecified swaps return the fee
    ///      as a positive unspecified delta; STOCK-specified swaps already carry it from `beforeSwap`.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());
        PoolRecord storage record = _requireRegistered(poolId);

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
            uint256 fee = LANES * lane;
            uint256 expectedRealized = exactInput ? requested - fee : requested + fee;
            if (realized != expectedRealized) revert PartialFillNotSupported(expectedRealized, realized);
            feeBase = exactInput ? requested : requested + fee;
        } else if (stockIsInput) {
            lane = grossLane(realized);
            feeBase = realized + LANES * lane;
            hookDeltaUnspecified = SafeCast.toInt128(LANES * lane);
        } else {
            // Each lane is floored independently and the same lane is charged twice: two equal lanes,
            // never one floored two percent.
            // slither-disable-next-line divide-before-multiply
            lane = realized / StocksPreset.LANE_DIVISOR;
            feeBase = realized;
            hookDeltaUnspecified = SafeCast.toInt128(LANES * lane);
        }

        if (lane != 0) {
            Accrued storage bucket = _accrued[poolId];
            bucket.protocolLane += lane;
            bucket.stakerLane += lane;
            // slither-disable-next-line divide-before-multiply
            poolManager.take(Currency.wrap(record.stock), address(this), LANES * lane);
        }

        // slither-disable-next-line reentrancy-events
        emit HookFeeAccrued(poolId, feeBase, lane, lane);
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
        if (record.stock == address(0)) revert PoolNotRegistered(poolId);
    }

    function _requireAllowanceConsumed(address token, address spender) private view {
        uint256 remaining = IERC20Views(token).allowance(address(this), spender);
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
