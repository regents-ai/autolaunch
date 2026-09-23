// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IChainlinkAggregatorMinimal} from "autolaunch-stocks/interfaces/IChainlinkAggregatorMinimal.sol";
import {IERC20Views} from "autolaunch-stocks/interfaces/IERC20Views.sol";
import {IRobinhoodStockRoute} from "../interfaces/IRobinhoodStockRoute.sol";
import {IUniswapV3PoolMinimal} from "../interfaces/IUniswapV3PoolMinimal.sol";
import {RobinhoodPreset} from "../RobinhoodPreset.sol";

/// @title UniswapV3StockRouteV1
/// @notice The production USDG <-> STOCK route for one Robinhood Chain stock: one Uniswap v3
///         USDG/STOCK pool for execution, one Chainlink feed for the quote and as a sanity bound on
///         every execution.
/// @dev Pinned at construction: USDG, the stock, the pool (whose two currencies must be exactly USDG
///      and the stock, in either order; the Robinhood pools sort both ways) and the feed. The route
///      calls the pool directly, never a router, and builds every swap itself: the price limit is the
///      extreme of the pool's range, so `minAmountOut` and the feed bound are the only price
///      controls. `quoteExactIn` is the feed price, not the pool price: it is the review quote a
///      caller compares against, and `swapExactIn` refuses any execution that delivers less than
///      `MAX_DEVIATION_BPS` under that quote. The route holds nothing between calls: whatever
///      `amountIn` the pool did not consume goes back to `recipient` in the call.
contract UniswapV3StockRouteV1 is ReentrancyGuardTransient, IRobinhoodStockRoute {
    using SafeTransferLib for address;

    /// @notice Oldest feed answer the route accepts. The feeds hold the last close over weekends
    ///         and market holidays, so the bound only catches a feed that has stopped.
    uint256 public constant MAX_FEED_AGE = 7 days;

    /// @notice Largest shortfall of an execution against the feed quote, in basis points.
    uint256 public constant MAX_DEVIATION_BPS = 500;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant USDG_UNIT = 10 ** uint256(RobinhoodPreset.USDG_DECIMALS);

    address public immutable override stock;
    address public immutable override usdg;
    IUniswapV3PoolMinimal public immutable pool;
    IChainlinkAggregatorMinimal public immutable feed;

    /// @notice Whether the stock is the pool's `token0` (USDG is then `token1`), read from the pool
    ///         at construction.
    bool public immutable stockIsToken0;

    /// @notice One whole share in STOCK base units, read from the token at construction.
    uint256 public immutable stockUnit;

    /// @notice One dollar in feed units, read from the feed at construction.
    uint256 public immutable feedUnit;

    error ZeroAddress();
    error NoCode(address target);
    error UnexpectedDecimals(uint8 expected, uint8 found);
    error PoolBindingMismatch(address usdg, address stock, address token0, address token1);
    error ZeroAmount();
    error UnsupportedPair(address tokenIn, address tokenOut);
    error BadFeedAnswer(int256 answer);
    error StaleFeed(uint256 updatedAt);
    error InsufficientOutput(uint256 minimum, uint256 found);
    error PriceDeviation(uint256 quoted, uint256 found);
    error NotPool(address caller);

    constructor(address usdg_, address stock_, address pool_, address feed_) {
        if (usdg_ == address(0) || stock_ == address(0) || pool_ == address(0) || feed_ == address(0)) {
            revert ZeroAddress();
        }
        if (pool_.code.length == 0) revert NoCode(pool_);
        if (feed_.code.length == 0) revert NoCode(feed_);
        uint8 usdgDecimals = IERC20Views(usdg_).decimals();
        if (usdgDecimals != RobinhoodPreset.USDG_DECIMALS) {
            revert UnexpectedDecimals(RobinhoodPreset.USDG_DECIMALS, usdgDecimals);
        }
        address token0 = IUniswapV3PoolMinimal(pool_).token0();
        address token1 = IUniswapV3PoolMinimal(pool_).token1();
        bool usdgFirst = token0 == usdg_ && token1 == stock_;
        bool stockFirst = token0 == stock_ && token1 == usdg_;
        if (!usdgFirst && !stockFirst) revert PoolBindingMismatch(usdg_, stock_, token0, token1);

        stock = stock_;
        usdg = usdg_;
        pool = IUniswapV3PoolMinimal(pool_);
        feed = IChainlinkAggregatorMinimal(feed_);
        stockIsToken0 = stockFirst;
        stockUnit = 10 ** IERC20Views(stock_).decimals();
        feedUnit = 10 ** IChainlinkAggregatorMinimal(feed_).decimals();
    }

    /// @inheritdoc IRobinhoodStockRoute
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (recipient == address(0)) revert ZeroAddress();
        // Validates the pair, the amount and the feed before anything reaches the pool.
        uint256 quoted = quoteExactIn(tokenIn, tokenOut, amountIn);

        // Selling `token0` for `token1` when the input is whichever side sorts first.
        bool zeroForOne = (tokenIn == stock) == stockIsToken0;
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
        (address token0, address token1) = stockIsToken0 ? (stock, usdg) : (usdg, stock);
        if (amount0Delta > 0) token0.safeTransfer(msg.sender, SafeCastLib.toUint256(amount0Delta));
        else if (amount1Delta > 0) token1.safeTransfer(msg.sender, SafeCastLib.toUint256(amount1Delta));
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
        uint256 price = _feedPrice();
        if (tokenIn == usdg && tokenOut == stock) {
            return FixedPointMathLib.fullMulDiv(amountIn, stockUnit * feedUnit, price * USDG_UNIT);
        }
        if (tokenIn == stock && tokenOut == usdg) {
            return FixedPointMathLib.fullMulDiv(amountIn, price * USDG_UNIT, stockUnit * feedUnit);
        }
        revert UnsupportedPair(tokenIn, tokenOut);
    }

    /// @dev Dollars per whole share in feed units, from the latest round.
    function _feedPrice() internal view returns (uint256) {
        // slither-disable-next-line unused-return
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert BadFeedAnswer(answer);
        if (updatedAt == 0 || updatedAt + MAX_FEED_AGE < block.timestamp) revert StaleFeed(updatedAt);
        return SafeCastLib.toUint256(answer);
    }
}
