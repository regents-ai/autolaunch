// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {IRegentStakingRevenueRouter} from "src/revenue/interfaces/IRegentStakingRevenueRouter.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";

interface IRevenueShareSplitterV2Deployer {
    function deploy(
        address stakeToken,
        address usdc,
        address ingressFactory,
        address subjectRegistry,
        bytes32 subjectId,
        address treasuryRecipient,
        address stakingRevenueRouter,
        uint256 revenueShareSupplyDenominator,
        string calldata label,
        address owner
    ) external returns (address splitter);
}

interface IOwnedTransfer {
    function transferOwnership(address newOwner) external;
}

contract RevenueShareFactory is Owned {
    error UsdcZero();
    error RegistryZero();
    error StakingRevenueRouterZero();
    error SplitterDeployerZero();
    error StakingRevenueRouterUsdcMismatch();
    error OnlyAuthorizedCreator();
    error AccountZero();
    error SubjectZero();
    error StakeTokenZero();
    error IngressFactoryZero();
    error AgentSafeZero();
    error StakingRevenueRouterMismatch();
    error SplitterExistsForToken();
    error SplitterExistsForSubject();
    error SupplyDenominatorZero();
    error FactoryNotRegistrar();
    error IdentityChainIdZero();
    error IdentityRegistryZero();
    error IdentityAgentIdZero();
    error IdentityLinkFailed();
    error Reentrant();

    address public immutable usdc;
    address public immutable stakingRevenueRouter;
    address public immutable splitterDeployer;
    SubjectRegistry public immutable subjectRegistry;

    mapping(address => address) public splitterOfStakeToken;
    mapping(bytes32 => address) public splitterOfSubject;
    mapping(address => bool) public authorizedCreators;
    uint256 private _createLock = 1;

    event SplitterDeployed(
        bytes32 indexed subjectId,
        address indexed stakeToken,
        address indexed splitter,
        address splitterOwner,
        address treasuryRecipient,
        address stakingRevenueRouter,
        string label
    );
    event AuthorizedCreatorSet(address indexed account, bool enabled);

    constructor(
        address owner_,
        address usdc_,
        SubjectRegistry subjectRegistry_,
        address stakingRevenueRouter_,
        address splitterDeployer_
    ) Owned(owner_) {
        if (usdc_ == address(0)) revert UsdcZero();
        if (address(subjectRegistry_) == address(0)) revert RegistryZero();
        if (stakingRevenueRouter_ == address(0)) revert StakingRevenueRouterZero();
        if (splitterDeployer_ == address(0)) revert SplitterDeployerZero();
        if (IRegentStakingRevenueRouter(stakingRevenueRouter_).usdc() != usdc_) {
            revert StakingRevenueRouterUsdcMismatch();
        }
        usdc = usdc_;
        stakingRevenueRouter = stakingRevenueRouter_;
        splitterDeployer = splitterDeployer_;
        subjectRegistry = subjectRegistry_;
    }

    modifier onlyAuthorizedCreator() {
        if (msg.sender != owner && !authorizedCreators[msg.sender]) {
            revert OnlyAuthorizedCreator();
        }
        _;
    }

    modifier nonReentrantCreate() {
        if (_createLock != 1) revert Reentrant();
        _createLock = 2;
        _;
        _createLock = 1;
    }

    function setAuthorizedCreator(address account, bool enabled) external onlyOwner {
        if (account == address(0)) revert AccountZero();
        authorizedCreators[account] = enabled;
        emit AuthorizedCreatorSet(account, enabled);
    }

    function createSubjectSplitter(
        bytes32 subjectId,
        address stakeToken,
        address ingressFactory,
        address agentSafe,
        address configuredStakingRevenueRouter,
        uint256 revenueShareSupplyDenominator,
        string calldata label,
        uint256 identityChainId,
        address identityRegistry,
        uint256 identityAgentId
    ) external onlyAuthorizedCreator nonReentrantCreate returns (address splitter) {
        if (subjectId == bytes32(0)) revert SubjectZero();
        if (stakeToken == address(0)) revert StakeTokenZero();
        if (ingressFactory == address(0)) revert IngressFactoryZero();
        if (agentSafe == address(0)) revert AgentSafeZero();
        if (configuredStakingRevenueRouter != stakingRevenueRouter) {
            revert StakingRevenueRouterMismatch();
        }
        if (splitterOfStakeToken[stakeToken] != address(0)) revert SplitterExistsForToken();
        if (splitterOfSubject[subjectId] != address(0)) revert SplitterExistsForSubject();
        if (revenueShareSupplyDenominator == 0) revert SupplyDenominatorZero();
        if (!subjectRegistry.canRegisterSubject(address(this))) revert FactoryNotRegistrar();
        bool hasIdentityLink =
            identityChainId != 0 || identityRegistry != address(0) || identityAgentId != 0;
        if (hasIdentityLink) {
            if (identityChainId == 0) revert IdentityChainIdZero();
            if (identityRegistry == address(0)) revert IdentityRegistryZero();
            if (identityAgentId == 0) revert IdentityAgentIdZero();
        }

        splitter = IRevenueShareSplitterV2Deployer(splitterDeployer)
            .deploy(
                stakeToken,
                usdc,
                ingressFactory,
                address(subjectRegistry),
                subjectId,
                agentSafe,
                stakingRevenueRouter,
                revenueShareSupplyDenominator,
                label,
                address(this)
            );

        splitterOfStakeToken[stakeToken] = splitter;
        splitterOfSubject[subjectId] = splitter;

        emit SplitterDeployed(
            subjectId, stakeToken, splitter, agentSafe, agentSafe, stakingRevenueRouter, label
        );

        subjectRegistry.createSubject(subjectId, stakeToken, splitter, agentSafe, true, label);
        if (hasIdentityLink) {
            bytes32 identityHash = subjectRegistry.linkIdentity(
                subjectId, identityChainId, identityRegistry, identityAgentId
            );
            if (identityHash == bytes32(0)) revert IdentityLinkFailed();
        }
        IOwnedTransfer(splitter).transferOwnership(agentSafe);
    }
}
