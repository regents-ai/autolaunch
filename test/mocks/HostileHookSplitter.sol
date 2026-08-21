// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

/// @notice A splitter-shaped contract that answers the three bindings `RegentFeeHook.registerPool`
///         validates and then misbehaves from inside `depositRecognizedRevenue`.
/// @dev One configurable surface rather than one mock per attack: it can revert outright, pull less
///      than the approval, pull the lane and refund it, or re-enter an arbitrary target while it
///      still holds the hook's approval — the single moment the hook is mid-settlement. Each test
///      still asserts its own distinct property.
contract HostileHookSplitter {
    address public regent;
    address public subject;
    address public regentSafe;

    /// @notice When set, the deposit reverts.
    bool public reverts;
    /// @notice When set, the deposit pulls only half the approved lane.
    bool public pullsPartially;
    /// @notice When set, the deposit pulls the whole lane and sends it straight back.
    bool public refunds;

    /// @notice An optional call made before the pull, while the hook's approval is live.
    address public reentryTarget;
    bytes public reentryCalldata;
    bool public lastReentrySucceeded;
    uint256 public reentryAttempts;

    bool private _reentering;

    error HostileRevert();

    constructor(address regent_, address subject_, address regentSafe_) {
        regent = regent_;
        subject = subject_;
        regentSafe = regentSafe_;
    }

    function setReverts(bool value) external {
        reverts = value;
    }

    function setPullsPartially(bool value) external {
        pullsPartially = value;
    }

    function setRefunds(bool value) external {
        refunds = value;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryCalldata = data;
    }

    function approveToken(address token, address spender, uint256 amount) external {
        MockERC20(token).approve(spender, amount);
    }

    function depositRecognizedRevenue(address token, uint256 amount, bytes32) external {
        if (reverts) revert HostileRevert();

        address target = reentryTarget;
        if (target != address(0) && !_reentering) {
            _reentering = true;
            reentryAttempts += 1;
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok,) = target.call(reentryCalldata);
            lastReentrySucceeded = ok;
            _reentering = false;
        }

        uint256 pull = pullsPartially ? amount / 2 : amount;
        MockERC20(token).transferFrom(msg.sender, address(this), pull);
        if (refunds) MockERC20(token).transfer(msg.sender, pull);
    }
}
