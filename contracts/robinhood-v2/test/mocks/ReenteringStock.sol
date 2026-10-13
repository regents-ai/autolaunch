// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {IRobinhoodStockRoute} from "../../src/interfaces/IRobinhoodStockRoute.sol";

/// @notice An eighteen-decimal stock stand-in that, once armed, re-calls the route from inside its
///         own transfer to one chosen account and records how the route answered. The issuer's stock tokens are
///         upgradeable, so a transfer that calls out is a case the route must hold against. Unarmed
///         it is a plain token. Not evidence about a live stock.
contract ReenteringStock is MockERC20 {
    IRobinhoodStockRoute public route;
    address public usdg;
    address public onTransferTo;
    bytes public reentryRevert;

    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_, 18) {}

    function arm(IRobinhoodStockRoute route_, address usdg_, address onTransferTo_) external {
        route = route_;
        usdg = usdg_;
        onTransferTo = onTransferTo_;
    }

    function _afterTokenTransfer(address, address to, uint256) internal override {
        IRobinhoodStockRoute target = route;
        if (address(target) == address(0) || to != onTransferTo) return;
        // One attempt per arming, so the recorded answer is the reentrant call's own.
        delete route;
        try target.swapExactIn(usdg, address(this), 1e6, 0, address(this)) {}
        catch (bytes memory reason) {
            reentryRevert = reason;
        }
    }
}
