// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRevenueShareSplitter {
    function stakeToken() external view returns (address);
    function usdc() external view returns (address);
    function treasuryRecipient() external view returns (address);
    function protocolRecipient() external view returns (address);
    function totalStaked() external view returns (uint256);
    function previewClaimableUSDC(address account) external view returns (uint256);

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef)
        external
        returns (uint256 received);
}
