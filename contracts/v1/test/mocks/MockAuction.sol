// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";
import {Checkpoint} from "continuous-clearing-auction/libraries/CheckpointLib.sol";

/// @notice The CCA auction behavior the escrow depends on, and nothing else.
/// @dev Mirrors the pinned `IContinuousClearingAuction` selectors the escrow calls:
///      `token`, `tokensRecipient`, `checkpoint`, `isGraduated`, `remainingSupply`, and the
///      recipient-only, one-shot `sweepUnsoldTokens`. `setGraduatesOnCheckpoint` reproduces the
///      real contract's stale-until-checkpointed graduation state, and `setSweepAmountOverride`
///      makes it deliver less than it reported.
contract MockAuction {
    address public token;
    address public tokensRecipient;

    bool private _graduated;
    bool private _graduatesOnCheckpoint;
    uint256 private _remainingSupply;

    uint256 public checkpointCalls;
    bool public swept;

    /// @dev When set, `sweepUnsoldTokens` transfers the override instead of `remainingSupply()`.
    bool private _overrideSweepAmount;
    uint256 private _sweepAmountOverride;

    /// @notice Optional call this auction makes back into the escrow during the sweep.
    address public reentryTarget;
    bytes public reentryCalldata;
    bool public lastReentrySucceeded;

    error NotAuthorized(address authorized, address caller);
    error CannotSweepTokens();

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

    function setRemainingSupply(uint256 value) external {
        _remainingSupply = value;
    }

    function setSweepAmountOverride(uint256 value) external {
        _overrideSweepAmount = true;
        _sweepAmountOverride = value;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryCalldata = data;
    }

    function checkpoint() external returns (Checkpoint memory) {
        checkpointCalls += 1;
        if (_graduatesOnCheckpoint) _graduated = true;
        return _emptyCheckpoint();
    }

    function isGraduated() external view returns (bool) {
        return _graduated;
    }

    function remainingSupply() external view returns (uint256) {
        return _remainingSupply;
    }

    function sweepUnsoldTokens() external {
        if (msg.sender != tokensRecipient) revert NotAuthorized(tokensRecipient, msg.sender);
        if (swept) revert CannotSweepTokens();
        swept = true;

        uint256 amount = _overrideSweepAmount
            ? _sweepAmountOverride
            : (_graduated ? _remainingSupply : MockERC20(token).balanceOf(address(this)));
        if (amount != 0) MockERC20(token).transfer(tokensRecipient, amount);

        address target = reentryTarget;
        if (target != address(0)) {
            (bool ok,) = target.call(reentryCalldata);
            lastReentrySucceeded = ok;
        }
    }

    function _emptyCheckpoint() private pure returns (Checkpoint memory checkpointValue) {
        return checkpointValue;
    }
}
