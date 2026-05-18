// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library BaseRegent {
    uint256 internal constant BASE_MAINNET_CHAIN_ID = 8453;
    address internal constant BASE_MAINNET_REGENT = 0x6f89bcA4eA5931EdFCB09786267b251DeE752b07;

    function canonicalRegent(uint256 chainId) internal pure returns (address) {
        if (chainId == BASE_MAINNET_CHAIN_ID) return BASE_MAINNET_REGENT;
        revert("BASE_MAINNET_ONLY");
    }

    function requireCanonical(address token) internal view {
        require(token == canonicalRegent(block.chainid), "REGENT_NOT_CANONICAL");
    }
}
