// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @notice A deployed contract that can hold value and can never move it again.
/// @dev It stands in for the worst treasury a launcher can choose while still being admitted: it
///      carries code, it is none of the refused protocol accounts, and it is not a clone of any
///      admitted Autolaunch implementation, so launch-time treasury admission accepts it. Anything
///      it receives is stranded there permanently, which is exactly the launcher-selected
///      consequence `FAC-015` names.
contract InertTreasury {
    /// @notice Present only so this contract carries runtime code, which is the property under test.
    function role() external pure returns (bytes32) {
        return "inert-treasury";
    }
}
