// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

/// @notice A splitter-shaped contract that re-enters the receiver while holding its approval.
/// @dev It answers the four getters a receiver reads at initialization, so a receiver can be bound
///      to it, and then attacks from inside `depositRecognizedRevenue` — the one moment a receiver
///      has granted an allowance and is mid-route.
contract HostileSplitter {
    address public treasury;
    address public usdc;
    address public regent;
    address public subject;

    address public reentryTarget;
    bytes public reentryCalldata;
    bool public lastReentrySucceeded;

    /// @notice When set, the deposit consumes less than the approved amount.
    bool public consumesPartially;

    constructor(address treasury_, address usdc_, address regent_, address subject_) {
        treasury = treasury_;
        usdc = usdc_;
        regent = regent_;
        subject = subject_;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryCalldata = data;
    }

    function setConsumesPartially(bool value) external {
        consumesPartially = value;
    }

    function depositRecognizedRevenue(address token, uint256 amount, bytes32) external {
        address target = reentryTarget;
        if (target != address(0)) {
            (bool ok,) = target.call(reentryCalldata);
            lastReentrySucceeded = ok;
        }

        uint256 pull = consumesPartially ? amount / 2 : amount;
        MockERC20(token).transferFrom(msg.sender, address(this), pull);
    }
}
