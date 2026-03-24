// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {ISubjectRegistry} from "src/revenue/interfaces/ISubjectRegistry.sol";

contract SubjectRegistry is Owned, ISubjectRegistry {
    struct IdentityLink {
        uint256 chainId;
        address registry;
        uint256 agentId;
    }

    mapping(bytes32 => SubjectConfig) private subjects;
    mapping(address => bytes32) public override subjectOfStakeToken;
    mapping(bytes32 => mapping(address => bool)) public subjectManagers;
    mapping(bytes32 => mapping(uint256 => address)) private emissionRecipients;
    mapping(bytes32 => IdentityLink[]) private identityLinks;
    mapping(bytes32 => bytes32) public subjectOfIdentityHash;

    event SubjectCreated(
        bytes32 indexed subjectId,
        address indexed stakeToken,
        address indexed splitter,
        address treasurySafe,
        string label
    );
    event SubjectUpdated(
        bytes32 indexed subjectId,
        address indexed splitter,
        address treasurySafe,
        bool active,
        string label
    );
    event SubjectManagerSet(bytes32 indexed subjectId, address indexed account, bool enabled);
    event EmissionRecipientSet(
        bytes32 indexed subjectId, uint256 indexed chainId, address recipient
    );
    event IdentityLinked(
        bytes32 indexed subjectId,
        bytes32 indexed identityHash,
        uint256 chainId,
        address indexed registry,
        uint256 agentId
    );
    event IdentityUnlinked(
        bytes32 indexed subjectId,
        bytes32 indexed identityHash,
        uint256 chainId,
        address indexed registry,
        uint256 agentId
    );

    constructor(address owner_) Owned(owner_) {}

    modifier onlySubjectManager(bytes32 subjectId) {
        require(canManageSubject(subjectId, msg.sender), "ONLY_SUBJECT_MANAGER");
        _;
    }

    function createSubject(
        bytes32 subjectId,
        address stakeToken,
        address splitter,
        address treasurySafe,
        bool active,
        string calldata label
    ) external onlyOwner {
        require(subjectId != bytes32(0), "SUBJECT_ZERO");
        require(stakeToken != address(0), "STAKE_TOKEN_ZERO");
        require(splitter != address(0), "SPLITTER_ZERO");
        require(treasurySafe != address(0), "TREASURY_SAFE_ZERO");
        require(subjects[subjectId].stakeToken == address(0), "SUBJECT_EXISTS");
        require(subjectOfStakeToken[stakeToken] == bytes32(0), "STAKE_TOKEN_ALREADY_LINKED");

        subjects[subjectId] = SubjectConfig({
            stakeToken: stakeToken,
            splitter: splitter,
            treasurySafe: treasurySafe,
            active: active,
            label: label
        });
        subjectOfStakeToken[stakeToken] = subjectId;
        subjectManagers[subjectId][treasurySafe] = true;

        emit SubjectCreated(subjectId, stakeToken, splitter, treasurySafe, label);
        emit SubjectManagerSet(subjectId, treasurySafe, true);
    }

    function updateSubject(
        bytes32 subjectId,
        address splitter,
        address treasurySafe,
        bool active,
        string calldata label
    ) external onlySubjectManager(subjectId) {
        SubjectConfig storage cfg = _subjectStorage(subjectId);
        require(splitter != address(0), "SPLITTER_ZERO");
        require(treasurySafe != address(0), "TREASURY_SAFE_ZERO");

        if (cfg.treasurySafe != treasurySafe) {
            subjectManagers[subjectId][cfg.treasurySafe] = false;
            emit SubjectManagerSet(subjectId, cfg.treasurySafe, false);
            subjectManagers[subjectId][treasurySafe] = true;
            emit SubjectManagerSet(subjectId, treasurySafe, true);
        }

        cfg.splitter = splitter;
        cfg.treasurySafe = treasurySafe;
        cfg.active = active;
        cfg.label = label;

        emit SubjectUpdated(subjectId, splitter, treasurySafe, active, label);
    }

    function setSubjectManager(bytes32 subjectId, address account, bool enabled)
        external
        onlySubjectManager(subjectId)
    {
        require(account != address(0), "ACCOUNT_ZERO");
        subjectManagers[subjectId][account] = enabled;
        emit SubjectManagerSet(subjectId, account, enabled);
    }

    function setEmissionRecipient(bytes32 subjectId, uint256 chainId, address recipient)
        external
        onlySubjectManager(subjectId)
    {
        require(chainId != 0, "CHAIN_ID_ZERO");
        require(recipient != address(0), "RECIPIENT_ZERO");
        _subjectStorage(subjectId);
        emissionRecipients[subjectId][chainId] = recipient;
        emit EmissionRecipientSet(subjectId, chainId, recipient);
    }

    function linkIdentity(bytes32 subjectId, uint256 chainId, address registry, uint256 agentId)
        external
        onlySubjectManager(subjectId)
        returns (bytes32 identityHash)
    {
        require(chainId != 0, "CHAIN_ID_ZERO");
        require(registry != address(0), "REGISTRY_ZERO");
        require(agentId != 0, "AGENT_ID_ZERO");
        _subjectStorage(subjectId);

        identityHash = _identityHash(chainId, registry, agentId);
        bytes32 previous = subjectOfIdentityHash[identityHash];
        require(previous == bytes32(0) || previous == subjectId, "IDENTITY_LINKED_TO_OTHER_SUBJECT");

        if (previous == bytes32(0)) {
            subjectOfIdentityHash[identityHash] = subjectId;
            identityLinks[subjectId].push(
                IdentityLink({chainId: chainId, registry: registry, agentId: agentId})
            );
            emit IdentityLinked(subjectId, identityHash, chainId, registry, agentId);
        }
    }

    function unlinkIdentity(bytes32 subjectId, uint256 chainId, address registry, uint256 agentId)
        external
        onlySubjectManager(subjectId)
    {
        _subjectStorage(subjectId);
        bytes32 identityHash = _identityHash(chainId, registry, agentId);
        require(subjectOfIdentityHash[identityHash] == subjectId, "IDENTITY_NOT_LINKED");

        delete subjectOfIdentityHash[identityHash];

        IdentityLink[] storage links = identityLinks[subjectId];
        uint256 length = links.length;
        for (uint256 i; i < length; ++i) {
            IdentityLink memory link = links[i];
            if (link.chainId == chainId && link.registry == registry && link.agentId == agentId) {
                uint256 last = length - 1;
                if (i != last) {
                    links[i] = links[last];
                }
                links.pop();
                emit IdentityUnlinked(subjectId, identityHash, chainId, registry, agentId);
                return;
            }
        }

        revert("IDENTITY_NOT_FOUND");
    }

    function getSubject(bytes32 subjectId) external view override returns (SubjectConfig memory) {
        return _subject(subjectId);
    }

    function splitterOfSubject(bytes32 subjectId) external view override returns (address) {
        return _subject(subjectId).splitter;
    }

    function emissionRecipient(bytes32 subjectId, uint256 chainId)
        external
        view
        override
        returns (address)
    {
        _subjectStorage(subjectId);
        return emissionRecipients[subjectId][chainId];
    }

    function canManageSubject(bytes32 subjectId, address account)
        public
        view
        override
        returns (bool)
    {
        SubjectConfig storage cfg = subjects[subjectId];
        if (cfg.stakeToken == address(0)) {
            return false;
        }

        return
            account == owner || subjectManagers[subjectId][account] || account == cfg.treasurySafe;
    }

    function identityLinkCount(bytes32 subjectId) external view returns (uint256) {
        _subjectStorage(subjectId);
        return identityLinks[subjectId].length;
    }

    function identityLinkAt(bytes32 subjectId, uint256 index)
        external
        view
        returns (IdentityLink memory)
    {
        _subjectStorage(subjectId);
        return identityLinks[subjectId][index];
    }

    function subjectForIdentity(uint256 chainId, address registry, uint256 agentId)
        external
        view
        returns (bytes32)
    {
        return subjectOfIdentityHash[_identityHash(chainId, registry, agentId)];
    }

    function _subject(bytes32 subjectId) internal view returns (SubjectConfig memory) {
        SubjectConfig memory cfg = subjects[subjectId];
        require(cfg.stakeToken != address(0), "SUBJECT_NOT_FOUND");
        return cfg;
    }

    function _subjectStorage(bytes32 subjectId) internal view returns (SubjectConfig storage cfg) {
        cfg = subjects[subjectId];
        require(cfg.stakeToken != address(0), "SUBJECT_NOT_FOUND");
    }

    function _identityHash(uint256 chainId, address registry, uint256 agentId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(chainId, registry, agentId));
    }
}
