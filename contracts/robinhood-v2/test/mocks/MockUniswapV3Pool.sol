// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20Views} from "autolaunch-stocks/interfaces/IERC20Views.sol";
import {IRobinhoodStockRoute} from "../../src/interfaces/IRobinhoodStockRoute.sol";
import {IUniswapV3PoolMinimal} from "../../src/interfaces/IUniswapV3PoolMinimal.sol";

interface ISwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice A fixed-price stand-in for a Uniswap v3 USDG/STOCK pool in either currency order, with
///         v3 swap and callback semantics: pays the output first, pulls the input through the
///         caller's `uniswapV3SwapCallback`, and checks the pull landed. `fillBps` consumes only part
///         of the input (a pool that ran out of range); `reenter` re-calls the route from inside the
///         callback. Not evidence about a live pool.
contract MockUniswapV3Pool is IUniswapV3PoolMinimal {
    using SafeTransferLib for address;

    address public immutable override token0;
    address public immutable override token1;
    address public immutable usdg;
    address public immutable stock;

    /// @notice One whole share in STOCK base units, read from the token.
    uint256 public immutable stockUnit;

    /// @notice USDG base units per whole share.
    uint256 public usdgPerShare;
    uint256 public fillBps = 10_000;
    bool public reenter;

    error Underpaid(uint256 owed, uint256 received);

    constructor(address token0_, address token1_, address usdg_, uint256 usdgPerShare_) {
        token0 = token0_;
        token1 = token1_;
        usdg = usdg_;
        stock = token0_ == usdg_ ? token1_ : token0_;
        stockUnit = 10 ** IERC20Views(stock).decimals();
        usdgPerShare = usdgPerShare_;
    }

    function setPrice(uint256 usdgPerShare_) external {
        usdgPerShare = usdgPerShare_;
    }

    function setFillBps(uint256 fillBps_) external {
        fillBps = fillBps_;
    }

    function setReenter(bool reenter_) external {
        reenter = reenter_;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        override
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "exact input only");
        uint256 consumed = uint256(amountSpecified) * fillBps / 10_000;
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);
        uint256 out = tokenIn == usdg ? consumed * stockUnit / usdgPerShare : consumed * usdgPerShare / stockUnit;
        (amount0, amount1) = zeroForOne ? (int256(consumed), -int256(out)) : (-int256(out), int256(consumed));

        tokenOut.safeTransfer(recipient, out);
        uint256 before = tokenIn.balanceOf(address(this));
        if (reenter) {
            IRobinhoodStockRoute(msg.sender).swapExactIn(tokenIn, tokenOut, 1, 0, address(this));
        }
        ISwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        uint256 received = tokenIn.balanceOf(address(this)) - before;
        if (received < consumed) revert Underpaid(consumed, received);
    }
}
