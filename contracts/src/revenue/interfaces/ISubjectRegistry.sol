// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ISubjectRegistry {
    struct SubjectConfig {
        address stakeToken;
        address splitter;
        address treasurySafe;
        bool active;
        string label;
    }

    function getSubject(bytes32 subjectId) external view returns (SubjectConfig memory);
    function splitterOfSubject(bytes32 subjectId) external view returns (address);
    function subjectOfStakeToken(address stakeToken) external view returns (bytes32);
    function emissionRecipient(bytes32 subjectId, uint256 chainId) external view returns (address);
    function canManageSubject(bytes32 subjectId, address account) external view returns (bool);
}
