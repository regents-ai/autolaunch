// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {IERC20SupplyMinimal} from "src/revenue/interfaces/IERC20SupplyMinimal.sol";
import {
    IPermissionlessExistingTokenRevenueFactory
} from "src/revenue/interfaces/IPermissionlessExistingTokenRevenueFactory.sol";
import {IRegentStakingRevenueRouter} from "src/revenue/interfaces/IRegentStakingRevenueRouter.sol";
import {LiveStakeFeePoolSplitter} from "src/revenue/LiveStakeFeePoolSplitter.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {InputBounds} from "src/revenue/libraries/InputBounds.sol";

contract PermissionlessExistingTokenRevenueFactory is
    Owned,
    IPermissionlessExistingTokenRevenueFactory
{
    address public immutable usdc;
    address public immutable ingressFactory;
    SubjectRegistry public immutable subjectRegistry;
    IRegentStakingRevenueRouter public immutable stakingRevenueRouter;

    mapping(bytes32 => address) public splitterOfSubject;
    mapping(address => bytes32[]) private subjectsByCreator;
    mapping(address => bytes32[]) private subjectsByStakeToken;

    event ExistingTokenRevenueSubjectCreated(
        bytes32 indexed subjectId,
        address indexed stakeToken,
        address indexed splitter,
        address ingress,
        address creator,
        address treasury,
        uint16 stakerPoolBps,
        string label
    );

    constructor(
        address owner_,
        address usdc_,
        address ingressFactory_,
        SubjectRegistry subjectRegistry_,
        IRegentStakingRevenueRouter stakingRevenueRouter_
    ) Owned(owner_) {
        require(usdc_ != address(0), "USDC_ZERO");
        require(ingressFactory_ != address(0), "INGRESS_FACTORY_ZERO");
        require(address(subjectRegistry_) != address(0), "SUBJECT_REGISTRY_ZERO");
        require(address(stakingRevenueRouter_) != address(0), "STAKING_ROUTER_ZERO");
        require(stakingRevenueRouter_.usdc() == usdc_, "STAKING_ROUTER_USDC_MISMATCH");

        usdc = usdc_;
        ingressFactory = ingressFactory_;
        subjectRegistry = subjectRegistry_;
        stakingRevenueRouter = stakingRevenueRouter_;
    }

    function createExistingTokenRevenueSubject(ExistingTokenRevenueConfig calldata cfg)
        external
        override
        returns (bytes32 subjectId, address splitter, address ingress)
    {
        require(subjectRegistry.canRegisterSubject(address(this)), "FACTORY_NOT_REGISTRAR");
        require(cfg.stakeToken != address(0), "STAKE_TOKEN_ZERO");
        require(cfg.stakeToken.code.length != 0, "STAKE_TOKEN_NOT_CONTRACT");
        require(cfg.treasury != address(0), "TREASURY_ZERO");
        require(cfg.treasury != address(this), "TREASURY_IS_SELF");
        require(cfg.stakerPoolBps <= 10_000, "STAKER_POOL_TOO_HIGH");
        InputBounds.requireNonEmptyString(
            cfg.label, InputBounds.MAX_LABEL_BYTES, "LABEL_EMPTY", "LABEL_TOO_LONG"
        );

        IERC20SupplyMinimal(cfg.stakeToken).totalSupply();

        subjectId = keccak256(
            abi.encode(
                block.chainid, address(this), cfg.stakeToken, cfg.treasury, msg.sender, cfg.salt
            )
        );
        require(splitterOfSubject[subjectId] == address(0), "SUBJECT_EXISTS");

        LiveStakeFeePoolSplitter deployed = new LiveStakeFeePoolSplitter{salt: cfg.salt}(
            cfg.stakeToken,
            usdc,
            ingressFactory,
            address(subjectRegistry),
            subjectId,
            cfg.treasury,
            address(stakingRevenueRouter),
            cfg.stakerPoolBps,
            cfg.label,
            cfg.treasury
        );

        splitter = address(deployed);
        splitterOfSubject[subjectId] = splitter;
        subjectsByCreator[msg.sender].push(subjectId);
        subjectsByStakeToken[cfg.stakeToken].push(subjectId);

        subjectRegistry.createPermissionlessSubject(
            subjectId, cfg.stakeToken, splitter, cfg.treasury, msg.sender, true, cfg.label
        );

        ingress = RevenueIngressFactory(ingressFactory)
            .createIngressAccount(subjectId, "default-usdc-ingress", true);

        emit ExistingTokenRevenueSubjectCreated(
            subjectId,
            cfg.stakeToken,
            splitter,
            ingress,
            msg.sender,
            cfg.treasury,
            cfg.stakerPoolBps,
            cfg.label
        );
    }

    function subjectCountForCreator(address creator) external view returns (uint256) {
        return subjectsByCreator[creator].length;
    }

    function subjectForCreatorAt(address creator, uint256 index) external view returns (bytes32) {
        return subjectsByCreator[creator][index];
    }

    function subjectsForCreator(address creator) external view returns (bytes32[] memory) {
        return subjectsByCreator[creator];
    }

    function subjectCountForStakeToken(address stakeToken) external view returns (uint256) {
        return subjectsByStakeToken[stakeToken].length;
    }

    function subjectForStakeTokenAt(address stakeToken, uint256 index)
        external
        view
        returns (bytes32)
    {
        return subjectsByStakeToken[stakeToken][index];
    }

    function subjectsForStakeToken(address stakeToken) external view returns (bytes32[] memory) {
        return subjectsByStakeToken[stakeToken];
    }
}
