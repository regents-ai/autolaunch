// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @notice Force-sends ETH to a contract that has no receive or fallback function.
/// @dev Real EVM behavior rather than an injected balance: `SELFDESTRUCT` in the same transaction
///      as creation still credits the target under Cancun. This is the only way ETH can ever reach
///      a splitter or a receiver, which is exactly what the forced-ETH recovery paths exist for.
contract ForceEthSender {
    constructor(address target) payable {
        selfdestruct(payable(target));
    }
}
