// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRegentRevenueStakingMinimal {
    function usdc() external view returns (address);

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef)
        external
        returns (uint256 received);
}
