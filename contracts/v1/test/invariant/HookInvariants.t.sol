// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {HookFixture} from "../mocks/HookFixture.sol";
import {HookSwapHandler} from "./handlers/HookSwapHandler.sol";

/// @notice `FA07-I4`: across every reachable sequence of swaps, through two unrelated routers and
///         every supported shape, the hook retains neither attributable fee asset.
/// @dev The accounting model separates *attributable* inventory from an explained external gift.
///      Anyone may transfer either asset to the hook; those gifts are not lane inventory. The
///      invariant pins both balances to their explained gifts and both splitter allowances to zero.
contract HookInvariantsTest is HookFixture {
    uint256 internal constant HANDLER_FUNDING = 1e26;
    uint256 internal constant POOL_LIQUIDITY = 1e24;

    Pool internal pool;
    HookSwapHandler internal handler;

    function setUp() public {
        _deployHookSystem();
        pool = _openPool(SUBJECT_LOW, POOL_LIQUIDITY);

        handler = new HookSwapHandler(swapRouter, altRouter, regent, pool.subject, address(hook), pool.key);
        regent.mint(address(handler), HANDLER_FUNDING);
        pool.subject.mint(address(handler), HANDLER_FUNDING);

        targetContract(address(handler));
    }

    /// @notice `FA07-I4`: the hook never retains either attributable fee asset or an allowance.
    function invariant_INV_004_FA07_I4_HookNeverRetainsAttributableFeeAssets() public view {
        assertEq(
            regent.balanceOf(address(hook)),
            handler.giftedRegentToHook(),
            "the hook's REGENT balance is not exactly the unattributable gift it was handed"
        );
        assertEq(
            pool.subject.balanceOf(address(hook)),
            handler.giftedSubjectToHook(),
            "the hook's SUBJECT balance is not exactly the unattributable gift it was handed"
        );
        assertEq(
            regent.allowance(address(hook), address(pool.splitter)),
            0,
            "the hook left a standing splitter allowance behind"
        );
        assertEq(
            pool.subject.allowance(address(hook), address(pool.splitter)),
            0,
            "the hook left a standing SUBJECT splitter allowance behind"
        );

        // Nothing was minted after setup, so every unit of REGENT is still somewhere in the system.
        assertEq(
            regent.balanceOf(address(handler)) + regent.balanceOf(address(this)) + regent.balanceOf(REGENT_SAFE)
                + regent.balanceOf(treasury) + regent.balanceOf(address(pool.splitter))
                + regent.balanceOf(address(hook)) + regent.balanceOf(address(manager)),
            regent.totalSupply(),
            "REGENT left the system"
        );

        assertEq(
            pool.subject.balanceOf(address(handler)) + pool.subject.balanceOf(address(this))
                + pool.subject.balanceOf(REGENT_SAFE) + pool.subject.balanceOf(treasury)
                + pool.subject.balanceOf(address(pool.splitter)) + pool.subject.balanceOf(address(hook))
                + pool.subject.balanceOf(address(manager)),
            pool.subject.totalSupply(),
            "SUBJECT left the system"
        );
    }
}
