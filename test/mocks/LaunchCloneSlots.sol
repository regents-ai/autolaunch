// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @notice The two addresses one launch's splitter and canonical receiver are deployed to, derived
///         from first principles rather than from the strategy.
/// @dev `RegentLBPStrategy` keeps its own derivation private and publishes no getter for it, which
///      is deliberate: the prediction is an internal deployment identity, not a record, and adding
///      an ABI entry for it would invite consumers to treat it as one. So this library restates the
///      derivation independently — the two role tags spelled out as the strings the strategy hashes,
///      the salt built the way the strategy builds it, and the CREATE2 address computed from the
///      53-byte Solady minimal-proxy creation code written out byte for byte.
///
///      Because it shares no code with production, a test that asserts a real deployment landed here
///      is proving the derivation, not restating it. `C6-I3`, `C6-I5`.
library LaunchCloneSlots {
    /// @dev The strategy's `SPLITTER_CLONE_ROLE`.
    bytes32 internal constant SPLITTER_ROLE = keccak256("RegentLBPStrategy.launchSplitter");

    /// @dev The strategy's `CANONICAL_RECEIVER_CLONE_ROLE`.
    bytes32 internal constant CANONICAL_RECEIVER_ROLE = keccak256("RegentLBPStrategy.launchCanonicalReceiver");

    /// @notice The address this launch's splitter clone will occupy.
    function splitter(address strategy, address splitterImplementation, uint256 launchId, address subject)
        internal
        pure
        returns (address)
    {
        return _create2(strategy, splitterImplementation, _salt(SPLITTER_ROLE, launchId, subject));
    }

    /// @notice The address this launch's canonical receiver clone will occupy.
    function canonicalReceiver(address strategy, address receiverImplementation, uint256 launchId, address subject)
        internal
        pure
        returns (address)
    {
        return _create2(strategy, receiverImplementation, _salt(CANONICAL_RECEIVER_ROLE, launchId, subject));
    }

    function _salt(bytes32 role, uint256 launchId, address subject) private pure returns (bytes32) {
        return keccak256(abi.encode(role, launchId, subject));
    }

    /// @dev The Solady minimal-proxy creation code, written out rather than imported, followed by the
    ///      EVM's own CREATE2 address rule.
    function _create2(address deployer, address implementation, bytes32 salt) private pure returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                hex"602c3d8160093d39f33d3d3d3d363d3d37363d73", implementation, hex"5af43d3d93803e602a57fd5bf3"
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
