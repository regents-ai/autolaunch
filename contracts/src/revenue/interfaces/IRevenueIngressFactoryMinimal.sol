// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRevenueIngressFactoryMinimal {
    function isIngressAccount(address ingress) external view returns (bool);
    function ingressAccountCount(bytes32 subjectId) external view returns (uint256);
    function ingressAccountAt(bytes32 subjectId, uint256 index) external view returns (address);
}
