// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library HookMiner {
    error HookSaltNotFound(uint160 requiredFlags);

    function find(
        address deployer,
        uint160 requiredFlags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (bytes32 salt, address hookAddress) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        for (uint256 i; i < type(uint24).max; ++i) {
            salt = bytes32(i);
            hookAddress = computeCreate2Address(deployer, salt, initCodeHash);

            if ((uint160(hookAddress) & uint160((1 << 14) - 1)) == requiredFlags) {
                return (salt, hookAddress);
            }
        }

        revert HookSaltNotFound(requiredFlags);
    }

    function computeCreate2Address(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))
            )
        );
    }
}
