// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

abstract contract TestBase {
    error AssertionFailed(string message);

    function assertTrue(bool value, string memory message) internal pure {
        if (!value) revert AssertionFailed(message);
    }

    function assertFalse(bool value, string memory message) internal pure {
        if (value) revert AssertionFailed(message);
    }

    function assertEq(uint256 left, uint256 right, string memory message) internal pure {
        if (left != right) revert AssertionFailed(message);
    }

    function assertEq(address left, address right, string memory message) internal pure {
        if (left != right) revert AssertionFailed(message);
    }

    function assertEq(bytes32 left, bytes32 right, string memory message) internal pure {
        if (left != right) revert AssertionFailed(message);
    }
}
