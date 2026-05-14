// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {DeferredAutolaunchVestingWallet} from "src/DeferredAutolaunchVestingWallet.sol";
import {ITokenFactory} from "src/interfaces/ITokenFactory.sol";
import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";
import {IDeferredAutolaunchFactory} from "src/revenue/interfaces/IDeferredAutolaunchFactory.sol";
import {IERC20SupplyMinimal} from "src/revenue/interfaces/IERC20SupplyMinimal.sol";
import {IRegentStakingRevenueRouter} from "src/revenue/interfaces/IRegentStakingRevenueRouter.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {InputBounds} from "src/revenue/libraries/InputBounds.sol";

contract DeferredAutolaunchFactory is Owned, IDeferredAutolaunchFactory {
    using SafeTransferLib for address;

    RevenueShareFactory public immutable revenueShareFactory;
    RevenueIngressFactory public immutable revenueIngressFactory;
    IRegentStakingRevenueRouter public immutable stakingRevenueRouter;
    address public immutable trustedTokenFactory;
    uint256 private _reentrancyGuard = 1;

    event DeferredAutolaunchCreated(
        address indexed creator,
        bytes32 indexed subjectId,
        address indexed token,
        address vestingWallet,
        address revenueShareSplitter,
        address defaultIngress,
        address treasury
    );

    modifier nonReentrant() {
        require(_reentrancyGuard == 1, "REENTRANT");
        _reentrancyGuard = 2;
        _;
        _reentrancyGuard = 1;
    }

    constructor(
        address owner_,
        RevenueShareFactory revenueShareFactory_,
        RevenueIngressFactory revenueIngressFactory_,
        IRegentStakingRevenueRouter stakingRevenueRouter_,
        address trustedTokenFactory_
    ) Owned(owner_) {
        require(address(revenueShareFactory_) != address(0), "REVENUE_SHARE_FACTORY_ZERO");
        require(address(revenueIngressFactory_) != address(0), "REVENUE_INGRESS_FACTORY_ZERO");
        require(address(stakingRevenueRouter_) != address(0), "STAKING_ROUTER_ZERO");
        require(trustedTokenFactory_ != address(0), "TOKEN_FACTORY_ZERO");
        require(trustedTokenFactory_.code.length != 0, "TOKEN_FACTORY_NOT_CONTRACT");
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
        trustedTokenFactory = trustedTokenFactory_;
    }

    function createDeferredAutolaunch(DeferredAutolaunchConfig calldata cfg)
        external
        override
        nonReentrant
        returns (DeferredAutolaunchResult memory result)
    {
        _validateDeferredAutolaunchConfig(cfg);

        address token = ITokenFactory(trustedTokenFactory)
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
        require(token.code.length != 0, "TOKEN_HAS_NO_CODE");
        require(
            IERC20SupplyMinimal(token).balanceOf(address(this)) == cfg.totalSupply,
            "TOKEN_BALANCE_BAD"
        );

        DeferredAutolaunchVestingWallet vestingWallet =
            new DeferredAutolaunchVestingWallet(cfg.treasury, uint64(block.timestamp), token);
        token.safeTransfer(address(vestingWallet), cfg.totalSupply);
        require(
            IERC20SupplyMinimal(token).balanceOf(address(vestingWallet)) == cfg.totalSupply,
            "VESTING_BALANCE_BAD"
        );
        require(IERC20SupplyMinimal(token).balanceOf(address(this)) == 0, "FACTORY_BALANCE_BAD");

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
        InputBounds.requireNonEmptyString(
            cfg.tokenName, InputBounds.MAX_TOKEN_NAME_BYTES, "NAME_EMPTY", "NAME_TOO_LONG"
        );
        InputBounds.requireNonEmptyString(
            cfg.tokenSymbol, InputBounds.MAX_TOKEN_SYMBOL_BYTES, "SYMBOL_EMPTY", "SYMBOL_TOO_LONG"
        );
        require(cfg.totalSupply != 0, "SUPPLY_ZERO");
        require(cfg.treasury != address(0), "TREASURY_ZERO");
        require(cfg.treasury != address(this), "TREASURY_IS_SELF");
        InputBounds.requireNonEmptyString(
            cfg.subjectLabel,
            InputBounds.MAX_LABEL_BYTES,
            "SUBJECT_LABEL_EMPTY",
            "SUBJECT_LABEL_TOO_LONG"
        );
        InputBounds.requireBytesMax(
            cfg.tokenFactoryData,
            InputBounds.MAX_TOKEN_FACTORY_DATA_BYTES,
            "TOKEN_FACTORY_DATA_TOO_LONG"
        );
        bool hasIdentityLink = cfg.identityChainId != 0 || cfg.identityRegistry != address(0)
            || cfg.identityAgentId != 0;
        if (hasIdentityLink) {
            require(cfg.identityChainId != 0, "IDENTITY_CHAIN_ID_ZERO");
            require(cfg.identityRegistry != address(0), "IDENTITY_REGISTRY_ZERO");
            require(cfg.identityAgentId != 0, "IDENTITY_AGENT_ID_ZERO");
        }
    }
}
