// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Checkpoint} from "continuous-clearing-auction/libraries/CheckpointLib.sol";

/// @notice The CCA auction behavior the escrow depends on, and nothing else.
/// @dev Mirrors the pinned `IContinuousClearingAuction` selectors the escrow calls: `token`,
///      `tokensRecipient`, `checkpoint` and `isGraduated`. `setGraduatesOnCheckpoint` reproduces the
///      real contract's stale-until-checkpointed graduation state, and `setReentry` makes the
///      checkpoint call back into the escrow.
contract MockAuction {
    address public token;
    address public tokensRecipient;

    bool private _graduated;
    bool private _graduatesOnCheckpoint;

    uint256 public checkpointCalls;

    /// @notice Optional call this auction makes back into the escrow during the checkpoint.
    address public reentryTarget;
    bytes public reentryCalldata;
    bool public lastReentrySucceeded;

    constructor(address token_, address tokensRecipient_) {
        token = token_;
        tokensRecipient = tokensRecipient_;
    }

    function setGraduated(bool value) external {
        _graduated = value;
    }

    function setGraduatesOnCheckpoint(bool value) external {
        _graduatesOnCheckpoint = value;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryCalldata = data;
    }

    function checkpoint() external returns (Checkpoint memory checkpointValue) {
        checkpointCalls += 1;
        if (_graduatesOnCheckpoint) _graduated = true;

        address target = reentryTarget;
        if (target != address(0)) {
            (bool ok,) = target.call(reentryCalldata);
            lastReentrySucceeded = ok;
        }
        return checkpointValue;
    }

    function isGraduated() external view returns (bool) {
        return _graduated;
    }
}
