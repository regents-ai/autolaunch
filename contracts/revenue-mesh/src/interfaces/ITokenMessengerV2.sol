// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The Circle CCTP V2 source-chain burn entry point.
/// @dev Matches Circle's `TokenMessengerV2.sol` at commit
///      a92a2b4e7e6ef99bf0b05dca71780f5ec190e729.
interface ITokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}
