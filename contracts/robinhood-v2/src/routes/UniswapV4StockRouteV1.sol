// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IChainlinkAggregatorMinimal} from "autolaunch-stocks/interfaces/IChainlinkAggregatorMinimal.sol";
import {IERC20Views} from "autolaunch-stocks/interfaces/IERC20Views.sol";
import {IRobinhoodStockRoute} from "../interfaces/IRobinhoodStockRoute.sol";
import {RobinhoodPreset} from "../RobinhoodPreset.sol";

/// @title UniswapV4StockRouteV1
/// @notice The production USDG <-> STOCK route for one Robinhood Chain stock whose market is a
///         Uniswap v4 pool: one hookless USDG/STOCK pool for execution, one Chainlink feed for the
///         review quote.
/// @dev Pinned at construction: USDG, the stock, the pool manager, the pool's fee and tick spacing,
///      and the feed. The route builds the pool key itself with no hook, so it can only ever reach
///      the hookless pool of exactly USDG and the stock at that fee and spacing (the Robinhood pools
///      sort both ways; the key sorts them). A pool with a hook, and therefore any pool whose
///      liquidity-provider fee can change, is out of reach by construction; a protocol fee the pool
///      manager's own controller may switch on changes the price only, and the caller's minimum
///      covers it. The route calls the pool manager directly, never a router,
///      and builds every swap itself: the price limit is the extreme of the pool's range, so the
///      caller's `minAmountOut` is the only price control. `quoteExactIn` is the feed price, not the
///      pool price: it is the review quote a caller chooses a minimum from, and `swapExactIn` never
///      reads the feed. The route holds nothing between calls: the pool manager pays the output
///      straight to `recipient`, and whatever `amountIn` the pool did not consume goes back to
///      `recipient` in the call. `swapExactIn` opens the pool manager's lock, so it cannot be called
///      from inside another v4 operation; the bid adapter and the hook's lane settlement call it
///      outside swaps.
contract UniswapV4StockRouteV1 is ReentrancyGuardTransient, IRobinhoodStockRoute, IUnlockCallback {
    using SafeTransferLib for address;
    using StateLibrary for IPoolManager;

    /// @notice Oldest feed answer the quote accepts. The feeds hold the last close over weekends
    ///         and market holidays, so the bound only catches a feed that has stopped.
    uint256 public constant MAX_FEED_AGE = 7 days;

    uint256 internal constant USDG_UNIT = 10 ** uint256(RobinhoodPreset.USDG_DECIMALS);

    address public immutable override stock;
    address public immutable override usdg;
    IPoolManager public immutable poolManager;
    IChainlinkAggregatorMinimal public immutable feed;

    /// @notice The pinned pool's fixed liquidity-provider fee, in hundredths of a basis point, and its
    ///         tick spacing.
    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    /// @notice The pinned pool's id: the hash of the key the route builds.
    bytes32 public immutable poolId;

    /// @notice Whether the stock is the pool's `currency0` (USDG is then `currency1`).
    bool public immutable stockIsCurrency0;

    /// @notice One whole share in STOCK base units, read from the token at construction.
    uint256 public immutable stockUnit;

    /// @notice One dollar in feed units, read from the feed at construction.
    uint256 public immutable feedUnit;

    error ZeroAddress();
    error NoCode(address target);
    error UnexpectedDecimals(uint8 expected, uint8 found);
    error PoolNotInitialized(bytes32 poolId);
    error ZeroAmount();
    error UnsupportedPair(address tokenIn, address tokenOut);
    error BadFeedAnswer(int256 answer);
    error StaleFeed(uint256 updatedAt);
    error InsufficientOutput(uint256 minimum, uint256 found);
    error NotPoolManager(address caller);

    constructor(address usdg_, address stock_, address poolManager_, uint24 fee_, int24 tickSpacing_, address feed_) {
        if (usdg_ == address(0) || stock_ == address(0) || poolManager_ == address(0) || feed_ == address(0)) {
            revert ZeroAddress();
        }
        if (poolManager_.code.length == 0) revert NoCode(poolManager_);
        if (feed_.code.length == 0) revert NoCode(feed_);
        uint8 usdgDecimals = IERC20Views(usdg_).decimals();
        if (usdgDecimals != RobinhoodPreset.USDG_DECIMALS) {
            revert UnexpectedDecimals(RobinhoodPreset.USDG_DECIMALS, usdgDecimals);
        }

        stock = stock_;
        usdg = usdg_;
        poolManager = IPoolManager(poolManager_);
        feed = IChainlinkAggregatorMinimal(feed_);
        fee = fee_;
        tickSpacing = tickSpacing_;
        stockIsCurrency0 = stock_ < usdg_;
        stockUnit = 10 ** IERC20Views(stock_).decimals();
        feedUnit = 10 ** IChainlinkAggregatorMinimal(feed_).decimals();

        // The pool manager only ever initializes a key whose currencies differ and are sorted, whose
        // fee is a valid static fee when there is no hook, and whose tick spacing is in range. A
        // non-zero price therefore proves the pinned pool exists exactly as the route will address it.
        PoolId id = _poolKey(usdg_, stock_, fee_, tickSpacing_).toId();
        // slither-disable-next-line unused-return
        (uint160 sqrtPriceX96,,,) = IPoolManager(poolManager_).getSlot0(id);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized(PoolId.unwrap(id));
        poolId = PoolId.unwrap(id);
    }

    /// @inheritdoc IRobinhoodStockRoute
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();
        _requirePair(tokenIn, tokenOut);

        uint256 consumed;
        (consumed, amountOut) =
            abi.decode(poolManager.unlock(abi.encode(tokenIn, tokenOut, amountIn, recipient)), (uint256, uint256));

        if (amountOut < minAmountOut) revert InsufficientOutput(minAmountOut, amountOut);

        uint256 residue = amountIn - consumed;
        if (residue != 0) tokenIn.safeTransfer(recipient, residue);
    }

    /// @notice The swap itself, run inside the pool manager's lock that `swapExactIn` opened. Only
    ///         the pinned pool manager may call it, and the pool manager only calls it on the account
    ///         that called `unlock`, so the input paid here is always part of an `amountIn` the
    ///         caller just transferred to the route.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager(msg.sender);
        (address tokenIn, address tokenOut, uint256 amountIn, address recipient) =
            abi.decode(data, (address, address, uint256, address));

        // Selling `currency0` for `currency1` when the input is whichever side sorts first.
        bool zeroForOne = (tokenIn == stock) == stockIsCurrency0;
        // Exact input is a negative amount; the price limit is the extreme of the pool's range.
        BalanceDelta delta = poolManager.swap(
            _poolKey(usdg, stock, fee, tickSpacing),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -SafeCastLib.toInt256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 owed, int128 paid) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        // The route owes the pool manager the input it consumed (negative delta, at most `amountIn`)
        // and the pool manager owes the output (positive delta).
        uint256 consumed = SafeCastLib.toUint256(-int256(owed));
        uint256 amountOut = SafeCastLib.toUint256(int256(paid));

        if (consumed != 0) {
            poolManager.sync(Currency.wrap(tokenIn));
            tokenIn.safeTransfer(msg.sender, consumed);
            // slither-disable-next-line unused-return
            poolManager.settle();
        }
        if (amountOut != 0) poolManager.take(Currency.wrap(tokenOut), recipient, amountOut);

        return abi.encode(consumed, amountOut);
    }

    /// @inheritdoc IRobinhoodStockRoute
    /// @dev The Chainlink price, not the pool price. Reverts on a stopped or non-positive feed.
    function quoteExactIn(address tokenIn, address tokenOut, uint256 amountIn)
        public
        view
        override
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        _requirePair(tokenIn, tokenOut);
        uint256 price = _feedPrice();
        if (tokenIn == usdg) {
            return FixedPointMathLib.fullMulDiv(amountIn, stockUnit * feedUnit, price * USDG_UNIT);
        }
        return FixedPointMathLib.fullMulDiv(amountIn, price * USDG_UNIT, stockUnit * feedUnit);
    }

    /// @dev The route converts USDG to the stock and the stock to USDG, nothing else.
    function _requirePair(address tokenIn, address tokenOut) internal view {
        bool purchase = tokenIn == usdg && tokenOut == stock;
        bool sale = tokenIn == stock && tokenOut == usdg;
        if (!purchase && !sale) revert UnsupportedPair(tokenIn, tokenOut);
    }

    /// @dev Dollars per whole share in feed units, from the latest round.
    function _feedPrice() internal view returns (uint256) {
        // slither-disable-next-line unused-return
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert BadFeedAnswer(answer);
        if (updatedAt == 0 || updatedAt + MAX_FEED_AGE < block.timestamp) revert StaleFeed(updatedAt);
        return SafeCastLib.toUint256(answer);
    }

    /// @dev The hookless pool of the two tokens, sorted, at the given fee and tick spacing.
    function _poolKey(address usdg_, address stock_, uint24 fee_, int24 tickSpacing_)
        private
        pure
        returns (PoolKey memory)
    {
        (address currency0, address currency1) = stock_ < usdg_ ? (stock_, usdg_) : (usdg_, stock_);
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee_,
            tickSpacing: tickSpacing_,
            hooks: IHooks(address(0))
        });
    }
}
