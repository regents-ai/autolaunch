// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {RevenueShareSplitter} from "src/revenue/RevenueShareSplitter.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";

contract RevenueShareFactory is Owned {
    address public immutable usdc;
    SubjectRegistry public immutable subjectRegistry;

    mapping(address => address) public splitterOfStakeToken;
    mapping(bytes32 => address) public splitterOfSubject;
    mapping(address => bool) public authorizedCreators;

    event SplitterDeployed(
        bytes32 indexed subjectId,
        address indexed stakeToken,
        address indexed splitter,
        address splitterOwner,
        address treasuryRecipient,
        address protocolRecipient,
        string label
    );
    event AuthorizedCreatorSet(address indexed account, bool enabled);

    constructor(address owner_, address usdc_, SubjectRegistry subjectRegistry_) Owned(owner_) {
        require(usdc_ != address(0), "USDC_ZERO");
        require(address(subjectRegistry_) != address(0), "REGISTRY_ZERO");
        usdc = usdc_;
        subjectRegistry = subjectRegistry_;
    }

    modifier onlyAuthorizedCreator() {
        require(msg.sender == owner || authorizedCreators[msg.sender], "ONLY_AUTHORIZED_CREATOR");
        _;
    }

    function setAuthorizedCreator(address account, bool enabled) external onlyOwner {
        require(account != address(0), "ACCOUNT_ZERO");
        authorizedCreators[account] = enabled;
        emit AuthorizedCreatorSet(account, enabled);
    }

    function createSubjectSplitter(
        bytes32 subjectId,
        address stakeToken,
        address treasuryRecipient,
        address protocolRecipient,
        address splitterOwner,
        address treasurySafe,
        uint256 emissionChainId,
        address emissionRecipient,
        uint16 protocolSkimBps,
        string calldata label,
        uint256 identityChainId,
        address identityRegistry,
        uint256 identityAgentId
    ) external onlyAuthorizedCreator returns (address splitter) {
        require(subjectId != bytes32(0), "SUBJECT_ZERO");
        require(stakeToken != address(0), "STAKE_TOKEN_ZERO");
        require(splitterOfStakeToken[stakeToken] == address(0), "SPLITTER_EXISTS_FOR_TOKEN");
        require(splitterOfSubject[subjectId] == address(0), "SPLITTER_EXISTS_FOR_SUBJECT");
        require(splitterOwner != address(0), "SPLITTER_OWNER_ZERO");
        require(treasurySafe != address(0), "TREASURY_SAFE_ZERO");

        RevenueShareSplitter deployed = new RevenueShareSplitter(
            stakeToken,
            usdc,
            treasuryRecipient,
            protocolRecipient,
            protocolSkimBps,
            label,
            address(this)
        );

        deployed.transferOwnership(splitterOwner);

        splitter = address(deployed);
        splitterOfStakeToken[stakeToken] = splitter;
        splitterOfSubject[subjectId] = splitter;

        subjectRegistry.createSubject(subjectId, stakeToken, splitter, treasurySafe, true, label);
        if (emissionChainId != 0 && emissionRecipient != address(0)) {
            subjectRegistry.setEmissionRecipient(subjectId, emissionChainId, emissionRecipient);
        }
        if (identityChainId != 0 && identityRegistry != address(0) && identityAgentId != 0) {
            subjectRegistry.linkIdentity(
                subjectId, identityChainId, identityRegistry, identityAgentId
            );
        }

        emit SplitterDeployed(
            subjectId,
            stakeToken,
            splitter,
            splitterOwner,
            treasuryRecipient,
            protocolRecipient,
            label
        );
    }
}
