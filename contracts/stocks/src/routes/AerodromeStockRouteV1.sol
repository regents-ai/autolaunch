// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IChainlinkAggregatorMinimal} from "../interfaces/IChainlinkAggregatorMinimal.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {ISlipstreamPoolMinimal} from "../interfaces/ISlipstreamPoolMinimal.sol";
import {IStockRoute} from "../interfaces/IStockRoute.sol";
import {StocksBindings} from "../StocksBindings.sol";

/// @title AerodromeStockRouteV1
/// @notice The production USDC <-> STOCK route for one Base-native stock: one Aerodrome Slipstream
///         USDC/STOCK pool for execution, one Chainlink total-return feed for the quote and as a
///         sanity bound on every execution.
/// @dev Pinned at construction: the pool (which must be `USDC/STOCK` in that currency order, as
///      every `0xb2…` stock pool is, USDC sorting first) and the feed. The route calls the pool
///      directly, never a router, and builds every swap itself: the price limit is the extreme of
///      the pool's range, so `minAmountOut` and the feed bound are the only price controls.
///      `quoteExactIn` is the feed price, not the pool price: `StocksLaunchpadV1.launch` uses it
///      to convert the USDC minimum raise into STOCK, and `swapExactIn` refuses any execution that
///      delivers less than `MAX_DEVIATION_BPS` under that quote. The route holds nothing between
///      calls: whatever `amountIn` the pool did not consume goes back to `recipient` in the call.
contract AerodromeStockRouteV1 is ReentrancyGuardTransient, IStockRoute {
    using SafeTransferLib for address;

    /// @notice Oldest feed answer the route accepts. The feeds hold the last close over weekends
    ///         and market holidays, so the bound only catches a feed that has stopped.
    uint256 public constant MAX_FEED_AGE = 7 days;

    /// @notice Largest shortfall of an execution against the feed quote, in basis points.
    uint256 public constant MAX_DEVIATION_BPS = 500;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant USDC_UNIT = 1e6;

    address public immutable override stock;
    address public immutable override usdc;
    ISlipstreamPoolMinimal public immutable pool;
    IChainlinkAggregatorMinimal public immutable feed;

    /// @notice One whole share in STOCK base units, read from the token at construction.
    uint256 public immutable stockUnit;

    /// @notice One dollar in feed units, read from the feed at construction.
    uint256 public immutable feedUnit;

    error ZeroAddress();
    error NoCode(address target);
    error PoolBindingMismatch(address expected, address found);
    error ZeroAmount();
    error UnsupportedPair(address tokenIn, address tokenOut);
    error BadFeedAnswer(int256 answer);
    error StaleFeed(uint256 updatedAt);
    error InsufficientOutput(uint256 minimum, uint256 found);
    error PriceDeviation(uint256 quoted, uint256 found);
    error NotPool(address caller);

    constructor(address stock_, address pool_, address feed_) {
        if (stock_ == address(0) || pool_ == address(0) || feed_ == address(0)) revert ZeroAddress();
        if (pool_.code.length == 0) revert NoCode(pool_);
        if (feed_.code.length == 0) revert NoCode(feed_);
        address token0 = ISlipstreamPoolMinimal(pool_).token0();
        if (token0 != StocksBindings.USDC) revert PoolBindingMismatch(StocksBindings.USDC, token0);
        address token1 = ISlipstreamPoolMinimal(pool_).token1();
        if (token1 != stock_) revert PoolBindingMismatch(stock_, token1);

        stock = stock_;
        usdc = StocksBindings.USDC;
        pool = ISlipstreamPoolMinimal(pool_);
        feed = IChainlinkAggregatorMinimal(feed_);
        stockUnit = 10 ** IERC20Minimal(stock_).decimals();
        feedUnit = 10 ** IChainlinkAggregatorMinimal(feed_).decimals();
    }

    /// @inheritdoc IStockRoute
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (recipient == address(0)) revert ZeroAddress();
        // Validates the pair, the amount and the feed before anything reaches the pool.
        uint256 quoted = quoteExactIn(tokenIn, tokenOut, amountIn);

        bool zeroForOne = tokenIn == usdc;
        (int256 amount0, int256 amount1) = pool.swap(
            recipient,
            zeroForOne,
            SafeCastLib.toInt256(amountIn),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            ""
        );
        (int256 owed, int256 paid) = zeroForOne ? (amount0, amount1) : (amount1, amount0);
        // Exact input: the pool owes us the output (negative delta) and we owed it at most `amountIn`.
        uint256 consumed = SafeCastLib.toUint256(owed);
        amountOut = SafeCastLib.toUint256(-paid);

        if (amountOut < minAmountOut) revert InsufficientOutput(minAmountOut, amountOut);
        if (amountOut * BPS < quoted * (BPS - MAX_DEVIATION_BPS)) revert PriceDeviation(quoted, amountOut);

        uint256 residue = amountIn - consumed;
        if (residue != 0) tokenIn.safeTransfer(recipient, residue);
    }

    /// @notice The pool's pull of the input currency during `swapExactIn`. Only the pinned pool may
    ///         call it, and the pool only calls it on the account that called `swap`, so the owed
    ///         amount is always part of an `amountIn` the caller just transferred here.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != address(pool)) revert NotPool(msg.sender);
        if (amount0Delta > 0) usdc.safeTransfer(msg.sender, SafeCastLib.toUint256(amount0Delta));
        else if (amount1Delta > 0) stock.safeTransfer(msg.sender, SafeCastLib.toUint256(amount1Delta));
    }

    /// @inheritdoc IStockRoute
    /// @dev The Chainlink price, not the pool price. Reverts on a stopped or non-positive feed.
    function quoteExactIn(address tokenIn, address tokenOut, uint256 amountIn)
        public
        view
        override
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        uint256 price = _feedPrice();
        if (tokenIn == usdc && tokenOut == stock) {
            return FixedPointMathLib.fullMulDiv(amountIn, stockUnit * feedUnit, price * USDC_UNIT);
        }
        if (tokenIn == stock && tokenOut == usdc) {
            return FixedPointMathLib.fullMulDiv(amountIn, price * USDC_UNIT, stockUnit * feedUnit);
        }
        revert UnsupportedPair(tokenIn, tokenOut);
    }

    /// @dev Dollars per whole share in feed units, from the latest round.
    function _feedPrice() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert BadFeedAnswer(answer);
        if (updatedAt == 0 || updatedAt + MAX_FEED_AGE < block.timestamp) revert StaleFeed(updatedAt);
        return SafeCastLib.toUint256(answer);
    }
}
