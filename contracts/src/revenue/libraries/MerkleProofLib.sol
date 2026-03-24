// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library MerkleProofLib {
    function verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf)
        internal
        pure
        returns (bool)
    {
        bytes32 computedHash = leaf;

        for (uint256 i; i < proof.length; ++i) {
            computedHash = _hashPair(computedHash, proof[i]);
        }

        return computedHash == root;
    }

    function _hashPair(bytes32 left, bytes32 right) private pure returns (bytes32) {
        return left < right
            ? keccak256(abi.encodePacked(left, right))
            : keccak256(abi.encodePacked(right, left));
    }
}
