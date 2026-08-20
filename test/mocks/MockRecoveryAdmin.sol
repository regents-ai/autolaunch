// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @notice A deployed contract standing in for the immutable recovery admin.
/// @dev The splitter requires an admin address that carries code, so an EOA or an address that
///      never existed cannot be admitted. Nothing else about the admin is C1's concern: the
///      recovery entry points check `msg.sender` against the bound address and nothing more, so
///      the tests call them as this contract.
contract MockRecoveryAdmin {
    /// @notice The address this admin would recover to, for readers of a trace.
    /// @dev Present only so the mock carries runtime code, which is the property under test.
    function role() external pure returns (bytes32) {
        return "recovery-admin";
    }
}
