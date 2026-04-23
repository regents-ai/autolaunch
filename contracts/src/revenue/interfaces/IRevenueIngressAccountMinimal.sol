// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRevenueIngressAccountMinimal {
    function usdc() external view returns (address);
    function splitter() external view returns (address);
    function subjectId() external view returns (bytes32);
}
