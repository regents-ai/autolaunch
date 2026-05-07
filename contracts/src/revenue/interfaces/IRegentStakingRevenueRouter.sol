// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRegentStakingRevenueRouter {
    function usdc() external view returns (address);
    function regentRevenueStaking() external view returns (address);
    function protocolSkimBps() external view returns (uint16);

    function processProtocolFee(
        bytes32 subjectId,
        address subjectTreasury,
        uint256 usdcAmount,
        bytes32 sourceRef
    ) external returns (uint256 depositedUsdc);
}
