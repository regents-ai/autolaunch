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
    function canRegisterSubject(address account) external view returns (bool);
    function subjectCountForStakeToken(address stakeToken) external view returns (uint256);
    function subjectForStakeTokenAt(address stakeToken, uint256 index)
        external
        view
        returns (bytes32);
    function subjectsForStakeToken(address stakeToken) external view returns (bytes32[] memory);
    function canManageSubject(bytes32 subjectId, address account) external view returns (bool);

    function setCanonicalSubjectForStakeToken(address stakeToken, bytes32 subjectId) external;

    function createSubject(
        bytes32 subjectId,
        address stakeToken,
        address splitter,
        address treasurySafe,
        bool active,
        string calldata label
    ) external;

    function createPermissionlessSubject(
        bytes32 subjectId,
        address stakeToken,
        address splitter,
        address treasurySafe,
        address creator,
        bool active,
        string calldata label
    ) external;
}
