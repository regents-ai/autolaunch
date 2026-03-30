// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";
import {IERC20SupplyMinimal} from "src/revenue/interfaces/IERC20SupplyMinimal.sol";

contract AgentTokenVestingWallet {
    using SafeTransferLib for address;

    address public immutable beneficiary;
    uint64 public immutable startTimestamp;
    uint64 public immutable durationSeconds;
    address public immutable launchToken;

    uint256 public releasedLaunchToken;
    uint256 private _reentrancyGuard = 1;

    event LaunchTokenReleased(address indexed beneficiary, uint256 amount);

    modifier nonReentrant() {
        require(_reentrancyGuard == 1, "REENTRANT");
        _reentrancyGuard = 2;
        _;
        _reentrancyGuard = 1;
    }

    constructor(
        address beneficiary_,
        uint64 startTimestamp_,
        uint64 durationSeconds_,
        address launchToken_
    ) {
        require(beneficiary_ != address(0), "BENEFICIARY_ZERO");
        require(durationSeconds_ != 0, "DURATION_ZERO");
        require(launchToken_ != address(0), "LAUNCH_TOKEN_ZERO");

        beneficiary = beneficiary_;
        startTimestamp = startTimestamp_;
        durationSeconds = durationSeconds_;
        launchToken = launchToken_;
    }

    function releasableLaunchToken() external view returns (uint256) {
        return _vestedAmount(_currentTime()) - releasedLaunchToken;
    }

    function releaseLaunchToken() external nonReentrant returns (uint256 amount) {
        uint256 vestedAmount = _vestedAmount(_currentTime());
        amount = vestedAmount - releasedLaunchToken;
        require(amount != 0, "NOTHING_TO_RELEASE");

        releasedLaunchToken = vestedAmount;
        launchToken.safeTransfer(beneficiary, amount);

        emit LaunchTokenReleased(beneficiary, amount);
    }

    function _currentTime() internal view returns (uint256 timestamp) {
        // slither-disable-next-line timestamp
        timestamp = block.timestamp;
    }

    function _vestedAmount(uint256 timestamp) internal view returns (uint256) {
        uint256 totalAllocation =
            IERC20SupplyMinimal(launchToken).balanceOf(address(this)) + releasedLaunchToken;

        if (timestamp <= startTimestamp) {
            return 0;
        }

        uint256 elapsed = timestamp - startTimestamp;
        if (elapsed >= durationSeconds) {
            return totalAllocation;
        }

        return (totalAllocation * elapsed) / durationSeconds;
    }
}
