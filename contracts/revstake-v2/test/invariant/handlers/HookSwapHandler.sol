// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {SimpleSwapRouter} from "../../mocks/SimpleSwapRouter.sol";

/// @notice Drives a registered official pool through every swap shape the hook supports, through two
///         unrelated routers, and gifts the hook both fee assets it must never consume.
/// @dev Amounts are bounded well inside the pool's liquidity and the price limits are the pinned
///      fixture's, so a swap that reverts here is a real failure rather than an exhausted pool.
///      `fail_on_revert = true` therefore keeps its full strength.
contract HookSwapHandler is CommonBase, StdUtils {
    /// @dev sqrt(1) in Q96, the price both pools opened at.
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    /// @dev Comfortably inside the seeded liquidity, so the price limits are never the binding
    ///      constraint and every swap settles.
    uint256 internal constant MAX_SWAP = 1e20;

    /// @dev A lane is `feeBase / 100` floored, so anything below one hundred units charges nothing.
    uint256 internal constant ZERO_LANE_CEILING = 99;

    PoolSwapTest public immutable pinnedRouter;
    SimpleSwapRouter public immutable altRouter;
    MockERC20 public immutable regent;
    MockERC20 public immutable subject;
    address public immutable hook;

    PoolKey private _key;

    /// @notice Fee assets handed to the hook as unattributable external gifts.
    uint256 public giftedRegentToHook;
    uint256 public giftedSubjectToHook;
    /// @notice Swaps that actually settled, by shape.
    uint256 public exactInputSwaps;
    uint256 public exactOutputSwaps;
    uint256 public zeroLaneSwaps;

    constructor(
        PoolSwapTest pinnedRouter_,
        SimpleSwapRouter altRouter_,
        MockERC20 regent_,
        MockERC20 subject_,
        address hook_,
        PoolKey memory key_
    ) {
        pinnedRouter = pinnedRouter_;
        altRouter = altRouter_;
        regent = regent_;
        subject = subject_;
        hook = hook_;
        _key = key_;

        // This handler is the trader, so it grants its own router allowances here rather than
        // having a test reach in and set them.
        regent_.approve(address(pinnedRouter_), type(uint256).max);
        regent_.approve(address(altRouter_), type(uint256).max);
        subject_.approve(address(pinnedRouter_), type(uint256).max);
        subject_.approve(address(altRouter_), type(uint256).max);
    }

    function key() external view returns (PoolKey memory) {
        return _key;
    }

    // -------------------------------------------------------------------------
    // actions
    // -------------------------------------------------------------------------

    function swapExactInput(uint256 amount, bool zeroForOne, bool useAltRouter) external {
        _swap(-int256(bound(amount, 1, MAX_SWAP)), zeroForOne, useAltRouter);
        exactInputSwaps += 1;
    }

    function swapExactOutput(uint256 amount, bool zeroForOne, bool useAltRouter) external {
        _swap(int256(bound(amount, 1, MAX_SWAP)), zeroForOne, useAltRouter);
        exactOutputSwaps += 1;
    }

    /// @dev The zero-lane shape: too small for either 1% lane to floor above zero, which the hook
    ///      must treat as a valid no-op rather than a charge of zero.
    function swapZeroLane(uint256 amount, bool zeroForOne, bool exactOutput) external {
        int256 specified = int256(bound(amount, 1, ZERO_LANE_CEILING));
        _swap(exactOutput ? specified : -specified, zeroForOne, false);
        zeroLaneSwaps += 1;
    }

    /// @dev An explained external gift. It is not lane inventory and the hook must never spend it.
    function giftRegentToHook(uint256 amount) external {
        uint256 available = regent.balanceOf(address(this));
        if (available == 0) return;
        amount = bound(amount, 1, available > MAX_SWAP ? MAX_SWAP : available);

        regent.transfer(hook, amount);
        giftedRegentToHook += amount;
    }

    /// @dev An explained external SUBJECT gift. It is not lane inventory and must remain untouched.
    function giftSubjectToHook(uint256 amount) external {
        uint256 available = subject.balanceOf(address(this));
        if (available == 0) return;
        amount = bound(amount, 1, available > MAX_SWAP ? MAX_SWAP : available);

        subject.transfer(hook, amount);
        giftedSubjectToHook += amount;
    }

    // -------------------------------------------------------------------------

    function _swap(int256 amountSpecified, bool zeroForOne, bool useAltRouter) private {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? SQRT_PRICE_1_1 / 2 : SQRT_PRICE_1_1 * 2
        });

        if (useAltRouter) {
            altRouter.swap(_key, params);
        } else {
            pinnedRouter.swap(_key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        }
    }
}
