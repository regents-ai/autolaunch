// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library InputBounds {
    uint256 internal constant MAX_TOKEN_NAME_BYTES = 64;
    uint256 internal constant MAX_TOKEN_SYMBOL_BYTES = 16;
    uint256 internal constant MAX_LABEL_BYTES = 96;
    uint256 internal constant MAX_TOKEN_FACTORY_DATA_BYTES = 1024;

    function requireNonEmptyString(
        string memory value,
        uint256 maxBytes,
        string memory emptyErr,
        string memory tooLongErr
    ) internal pure {
        uint256 length = bytes(value).length;
        require(length != 0, emptyErr);
        require(length <= maxBytes, tooLongErr);
    }

    function requireStringMax(string memory value, uint256 maxBytes, string memory tooLongErr)
        internal
        pure
    {
        require(bytes(value).length <= maxBytes, tooLongErr);
    }

    function requireBytesMax(bytes memory value, uint256 maxBytes, string memory tooLongErr)
        internal
        pure
    {
        require(value.length <= maxBytes, tooLongErr);
    }
}
