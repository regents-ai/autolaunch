// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {DeferredAutolaunchVestingWallet} from "src/DeferredAutolaunchVestingWallet.sol";
import {IERC20Minimal} from "src/interfaces/IERC20Minimal.sol";
import {ITokenFactory} from "src/interfaces/ITokenFactory.sol";
import {IDeferredAutolaunchFactory} from "src/revenue/interfaces/IDeferredAutolaunchFactory.sol";
import {IRegentStakingRevenueRouter} from "src/revenue/interfaces/IRegentStakingRevenueRouter.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";

contract DeferredAutolaunchFactory is Owned, IDeferredAutolaunchFactory {
    RevenueShareFactory public immutable revenueShareFactory;
    RevenueIngressFactory public immutable revenueIngressFactory;
    IRegentStakingRevenueRouter public immutable stakingRevenueRouter;

    event DeferredAutolaunchCreated(
        address indexed creator,
        bytes32 indexed subjectId,
        address indexed token,
        address vestingWallet,
        address revenueShareSplitter,
        address defaultIngress,
        address treasury
    );

    constructor(
        address owner_,
        RevenueShareFactory revenueShareFactory_,
        RevenueIngressFactory revenueIngressFactory_,
        IRegentStakingRevenueRouter stakingRevenueRouter_
    ) Owned(owner_) {
        require(address(revenueShareFactory_) != address(0), "REVENUE_SHARE_FACTORY_ZERO");
        require(address(revenueIngressFactory_) != address(0), "REVENUE_INGRESS_FACTORY_ZERO");
        require(address(stakingRevenueRouter_) != address(0), "STAKING_ROUTER_ZERO");
        require(revenueShareFactory_.usdc() == revenueIngressFactory_.usdc(), "USDC_MISMATCH");
        require(
            revenueShareFactory_.stakingRevenueRouter() == address(stakingRevenueRouter_),
            "STAKING_ROUTER_MISMATCH"
        );
        require(
            stakingRevenueRouter_.usdc() == revenueShareFactory_.usdc(),
            "STAKING_ROUTER_USDC_MISMATCH"
        );

        revenueShareFactory = revenueShareFactory_;
        revenueIngressFactory = revenueIngressFactory_;
        stakingRevenueRouter = stakingRevenueRouter_;
    }

    function createDeferredAutolaunch(DeferredAutolaunchConfig calldata cfg)
        external
        override
        returns (DeferredAutolaunchResult memory result)
    {
        _validateDeferredAutolaunchConfig(cfg);

        address token = ITokenFactory(cfg.tokenFactory)
            .createToken(
                cfg.tokenName,
                cfg.tokenSymbol,
                18,
                cfg.totalSupply,
                address(this),
                cfg.tokenFactoryData,
                cfg.tokenFactorySalt
            );
        require(token != address(0), "TOKEN_NOT_CREATED");

        DeferredAutolaunchVestingWallet vestingWallet =
            new DeferredAutolaunchVestingWallet(cfg.treasury, uint64(block.timestamp), token);
        require(
            IERC20Minimal(token).transfer(address(vestingWallet), cfg.totalSupply),
            "VESTING_TRANSFER_FAILED"
        );

        bytes32 subjectId = keccak256(abi.encode(block.chainid, token));

        address splitter = revenueShareFactory.createSubjectSplitter(
            subjectId,
            token,
            address(revenueIngressFactory),
            cfg.treasury,
            address(stakingRevenueRouter),
            cfg.totalSupply,
            cfg.subjectLabel,
            cfg.identityChainId,
            cfg.identityRegistry,
            cfg.identityAgentId
        );

        address ingress =
            revenueIngressFactory.createIngressAccount(subjectId, "default-usdc-ingress", true);
        require(ingress != address(0), "DEFAULT_INGRESS_NOT_CREATED");

        result = DeferredAutolaunchResult({
            token: token,
            vestingWallet: address(vestingWallet),
            subjectId: subjectId,
            revenueShareSplitter: splitter,
            defaultIngress: ingress
        });

        emit DeferredAutolaunchCreated(
            msg.sender, subjectId, token, address(vestingWallet), splitter, ingress, cfg.treasury
        );
    }

    function _validateDeferredAutolaunchConfig(DeferredAutolaunchConfig calldata cfg)
        internal
        view
    {
        require(bytes(cfg.tokenName).length != 0, "NAME_EMPTY");
        require(bytes(cfg.tokenSymbol).length != 0, "SYMBOL_EMPTY");
        require(cfg.totalSupply != 0, "SUPPLY_ZERO");
        require(cfg.treasury != address(0), "TREASURY_ZERO");
        require(cfg.treasury != address(this), "TREASURY_IS_SELF");
        require(cfg.tokenFactory != address(0), "TOKEN_FACTORY_ZERO");
        require(cfg.tokenFactory.code.length != 0, "TOKEN_FACTORY_NOT_CONTRACT");
        require(bytes(cfg.subjectLabel).length != 0, "SUBJECT_LABEL_EMPTY");
        bool hasIdentityLink = cfg.identityChainId != 0 || cfg.identityRegistry != address(0)
            || cfg.identityAgentId != 0;
        if (hasIdentityLink) {
            require(cfg.identityChainId != 0, "IDENTITY_CHAIN_ID_ZERO");
            require(cfg.identityRegistry != address(0), "IDENTITY_REGISTRY_ZERO");
            require(cfg.identityAgentId != 0, "IDENTITY_AGENT_ID_ZERO");
        }
    }
}
