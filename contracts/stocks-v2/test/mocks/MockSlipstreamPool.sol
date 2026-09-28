// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ISlipstreamPoolMinimal} from "../../src/interfaces/ISlipstreamPoolMinimal.sol";
import {IStockRoute} from "../../src/interfaces/IStockRoute.sol";

interface ISwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice A fixed-price stand-in for an Aerodrome Slipstream USDC/STOCK pool with Uniswap v3 swap
///         and callback semantics: pays the output first, pulls the input through the caller's
///         `uniswapV3SwapCallback`, and checks the pull landed. `fillBps` consumes only part of the
///         input (a pool that ran out of range); `reenter` re-calls the route from inside the
///         callback. Not evidence about the live pool.
contract MockSlipstreamPool is ISlipstreamPoolMinimal {
    using SafeTransferLib for address;

    uint256 internal constant SHARE = 1e8;

    address public immutable override token0;
    address public immutable override token1;

    /// @notice USDC base units per whole share.
    uint256 public usdcPerShare;
    uint256 public fillBps = 10_000;
    bool public reenter;

    error Underpaid(uint256 owed, uint256 received);

    constructor(address usdc, address stock, uint256 usdcPerShare_) {
        token0 = usdc;
        token1 = stock;
        usdcPerShare = usdcPerShare_;
    }

    function setPrice(uint256 usdcPerShare_) external {
        usdcPerShare = usdcPerShare_;
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
        uint256 out = zeroForOne ? consumed * SHARE / usdcPerShare : consumed * usdcPerShare / SHARE;
        (amount0, amount1) = zeroForOne ? (int256(consumed), -int256(out)) : (-int256(out), int256(consumed));

        tokenOut.safeTransfer(recipient, out);
        uint256 before = tokenIn.balanceOf(address(this));
        if (reenter) {
            IStockRoute(msg.sender).swapExactIn(tokenIn, tokenOut, 1, 0, address(this));
        }
        ISwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        uint256 received = tokenIn.balanceOf(address(this)) - before;
        if (received < consumed) revert Underpaid(consumed, received);
    }
}
