// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {HookFixture} from "../mocks/HookFixture.sol";
import {HookSwapHandler} from "./handlers/HookSwapHandler.sol";

/// @notice `INV-004`: across every reachable sequence of swaps, through two unrelated routers and
///         every supported shape, the hook retains no attributable REGENT.
/// @dev The accounting model separates *attributable* inventory from an explained external gift.
///      Anyone may transfer REGENT to the hook; that gift is not lane inventory, the hook must
///      never spend it as one, and it must never make a later swap fail. The invariant therefore
///      pins the hook's balance to exactly the gifted total — never above it, which would mean a
///      retained lane, and never below it, which would mean the hook spent someone's gift.
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

    /// @notice `INV-004`: the hook never retains attributable REGENT after a settled swap, and never
    ///         holds a standing allowance to any splitter.
    function invariant_INV_004_HookNeverRetainsAttributableRegent() public view {
        assertEq(
            regent.balanceOf(address(hook)),
            handler.giftedToHook(),
            "the hook's REGENT balance is not exactly the unattributable gift it was handed"
        );
        assertEq(
            regent.allowance(address(hook), address(pool.splitter)),
            0,
            "the hook left a standing splitter allowance behind"
        );

        // Nothing was minted after setup, so every unit of REGENT is still somewhere in the system.
        assertEq(
            regent.balanceOf(address(handler)) + regent.balanceOf(address(this)) + regent.balanceOf(REGENT_SAFE)
                + regent.balanceOf(treasury) + regent.balanceOf(address(pool.splitter))
                + regent.balanceOf(address(hook)) + regent.balanceOf(address(manager)),
            regent.totalSupply(),
            "REGENT left the system"
        );
    }
}
