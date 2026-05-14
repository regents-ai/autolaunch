// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDeferredAutolaunchFactory {
    struct DeferredAutolaunchConfig {
        string tokenName;
        string tokenSymbol;
        uint256 totalSupply;
        address treasury;
        bytes tokenFactoryData;
        bytes32 tokenFactorySalt;
        string subjectLabel;
        uint256 identityChainId;
        address identityRegistry;
        uint256 identityAgentId;
    }

    struct DeferredAutolaunchResult {
        address token;
        address vestingWallet;
        bytes32 subjectId;
        address revenueShareSplitter;
        address defaultIngress;
    }

    function createDeferredAutolaunch(DeferredAutolaunchConfig calldata cfg)
        external
        returns (DeferredAutolaunchResult memory result);
}
