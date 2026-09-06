// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @notice Re-enters the hook with two arbitrary calls at the one moment the hook is mid-settlement
///         and records what each call returned.
/// @dev Unlike a probe that simply reverts, this one swallows both outcomes and lets the outer swap
///      finish, so a test can read the recorded results afterwards instead of inferring them from a
///      rolled-back transaction. That is what makes "the authority boundary held while re-entered" a
///      positive observation rather than an absence of evidence.
contract HookReentrancyProbe {
    address public target;
    bytes public firstCall;
    bytes public secondCall;

    uint256 public probes;
    bool public firstSucceeded;
    bool public secondSucceeded;
    bytes public firstReturn;
    bytes public secondReturn;

    function arm(address target_, bytes calldata first, bytes calldata second) external {
        target = target_;
        firstCall = first;
        secondCall = second;
    }

    function probe() external {
        probes += 1;
        // solhint-disable-next-line avoid-low-level-calls
        (firstSucceeded, firstReturn) = target.call(firstCall);
        // solhint-disable-next-line avoid-low-level-calls
        (secondSucceeded, secondReturn) = target.call(secondCall);
    }
}
