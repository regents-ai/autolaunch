// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {RevenueIngressAccount} from "src/revenue/RevenueIngressAccount.sol";
import {ISubjectRegistry} from "src/revenue/interfaces/ISubjectRegistry.sol";

contract RevenueIngressFactory is Owned {
    address public immutable usdc;
    address public immutable subjectRegistry;

    mapping(bytes32 => address[]) private ingressAccountsBySubject;
    mapping(address => bool) public isIngressAccount;
    mapping(bytes32 => address) public defaultIngressOfSubject;
    mapping(address => bool) public authorizedCreators;

    event IngressAccountCreated(
        bytes32 indexed subjectId,
        address indexed ingress,
        address indexed splitter,
        address owner,
        string label,
        bool makeDefault
    );
    event DefaultIngressSet(bytes32 indexed subjectId, address indexed ingress);
    event AuthorizedCreatorSet(address indexed account, bool enabled);

    constructor(address usdc_, address subjectRegistry_, address owner_) Owned(owner_) {
        require(usdc_ != address(0), "USDC_ZERO");
        require(subjectRegistry_ != address(0), "SUBJECT_REGISTRY_ZERO");

        usdc = usdc_;
        subjectRegistry = subjectRegistry_;
    }

    modifier onlySubjectManager(bytes32 subjectId) {
        require(
            ISubjectRegistry(subjectRegistry).canManageSubject(subjectId, msg.sender)
                || msg.sender == owner,
            "ONLY_SUBJECT_MANAGER"
        );
        _;
    }

    modifier onlyCreateIngressManager(bytes32 subjectId) {
        require(
            msg.sender == owner || authorizedCreators[msg.sender]
                || ISubjectRegistry(subjectRegistry).canManageSubject(subjectId, msg.sender),
            "ONLY_SUBJECT_MANAGER"
        );
        _;
    }

    function setAuthorizedCreator(address account, bool enabled) external onlyOwner {
        require(account != address(0), "ACCOUNT_ZERO");
        authorizedCreators[account] = enabled;
        emit AuthorizedCreatorSet(account, enabled);
    }

    function createIngressAccount(bytes32 subjectId, string calldata label, bool makeDefault)
        external
        onlyCreateIngressManager(subjectId)
        returns (address ingress)
    {
        ingress = _createIngressAccount(subjectId, label, makeDefault);
    }

    function _createIngressAccount(bytes32 subjectId, string calldata label, bool makeDefault)
        internal
        returns (address ingress)
    {
        ISubjectRegistry.SubjectConfig memory cfg = _subjectConfig(subjectId);
        require(cfg.stakeToken != address(0), "SUBJECT_UNKNOWN");
        require(cfg.splitter != address(0), "SPLITTER_ZERO");
        require(cfg.active, "SUBJECT_INACTIVE");

        RevenueIngressAccount account =
            new RevenueIngressAccount(usdc, cfg.splitter, subjectId, label, cfg.treasurySafe);
        ingress = address(account);

        ingressAccountsBySubject[subjectId].push(ingress);
        isIngressAccount[ingress] = true;

        if (makeDefault || defaultIngressOfSubject[subjectId] == address(0)) {
            defaultIngressOfSubject[subjectId] = ingress;
            emit DefaultIngressSet(subjectId, ingress);
        }

        emit IngressAccountCreated(
            subjectId,
            ingress,
            cfg.splitter,
            cfg.treasurySafe,
            label,
            makeDefault || defaultIngressOfSubject[subjectId] == ingress
        );
    }

    function setDefaultIngress(bytes32 subjectId, address ingress)
        external
        onlySubjectManager(subjectId)
    {
        require(_subjectConfig(subjectId).active, "SUBJECT_INACTIVE");
        require(isIngressAccount[ingress], "INGRESS_UNKNOWN");
        require(
            RevenueIngressAccount(payable(ingress)).subjectId() == subjectId,
            "INGRESS_SUBJECT_MISMATCH"
        );

        defaultIngressOfSubject[subjectId] = ingress;
        emit DefaultIngressSet(subjectId, ingress);
    }

    function ingressAccountCount(bytes32 subjectId) external view returns (uint256) {
        return ingressAccountsBySubject[subjectId].length;
    }

    function ingressAccountAt(bytes32 subjectId, uint256 index) external view returns (address) {
        return ingressAccountsBySubject[subjectId][index];
    }

    function ingressAccountsOfSubject(bytes32 subjectId) external view returns (address[] memory) {
        return ingressAccountsBySubject[subjectId];
    }

    function _subjectConfig(bytes32 subjectId)
        internal
        view
        returns (ISubjectRegistry.SubjectConfig memory)
    {
        return ISubjectRegistry(subjectRegistry).getSubject(subjectId);
    }
}
