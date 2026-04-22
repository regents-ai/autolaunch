// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AuctionParameters} from "src/cca/interfaces/IContinuousClearingAuction.sol";
import {IDistributionContract} from "src/cca/interfaces/external/IDistributionContract.sol";
import {Owned} from "src/auth/Owned.sol";
import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";
import {LaunchFeeVault} from "src/LaunchFeeVault.sol";
import {LaunchPoolFeeHook} from "src/LaunchPoolFeeHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "src/libraries/HookMiner.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {AgentTokenVestingWallet} from "src/AgentTokenVestingWallet.sol";
import {RegentLBPStrategy} from "src/RegentLBPStrategy.sol";
import {RegentLBPStrategyFactory} from "src/RegentLBPStrategyFactory.sol";
import {ITokenFactory} from "src/interfaces/ITokenFactory.sol";
import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";

contract LaunchDeploymentController is Owned {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant MPS_TOTAL = 10_000_000;
    uint16 internal constant PUBLIC_SALE_BPS = 1000;
    uint16 internal constant LP_RESERVE_BPS = 500;
    uint16 internal constant VESTING_BPS = 8500;
    uint16 internal constant LP_CURRENCY_BPS = 5000;
    uint24 internal constant MAX_POOL_FEE = 1_000_000;
    uint160 internal constant REQUIRED_HOOK_FLAGS =
        Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    struct DeploymentConfig {
        address agentSafe;
        address revenueShareFactory;
        address revenueIngressFactory;
        address identityRegistry;
        address tokenFactory;
        address strategyFactory;
        address auctionInitializerFactory;
        address poolManager;
        address positionManager;
        address positionRecipient;
        address strategyOperator;
        address usdcToken;
        address regentRecipient;
        address validationHook;
        uint256 identityAgentId;
        uint256 totalSupply;
        uint24 officialPoolFee;
        int24 officialPoolTickSpacing;
        uint256 auctionTickSpacing;
        uint64 startBlock;
        uint64 endBlock;
        uint64 claimBlock;
        uint64 migrationBlock;
        uint64 sweepBlock;
        uint64 vestingStartTimestamp;
        uint64 vestingDurationSeconds;
        uint256 floorPrice;
        uint128 requiredCurrencyRaised;
        uint128 maxCurrencyAmountForLP;
        string tokenName;
        string tokenSymbol;
        string subjectLabel;
        bytes tokenFactoryData;
        bytes32 tokenFactorySalt;
    }

    struct DeploymentResult {
        address tokenAddress;
        address auctionAddress;
        address strategyAddress;
        address vestingWalletAddress;
        address hookAddress;
        address feeVaultAddress;
        address launchFeeRegistryAddress;
        address subjectRegistryAddress;
        address revenueShareSplitterAddress;
        address defaultIngressAddress;
        bytes32 subjectId;
        bytes32 poolId;
    }

    struct AllocationData {
        uint256 publicSaleAmount;
        uint256 lpReserveAmount;
        uint256 vestingAmount;
        uint256 strategySupply;
        uint24 tokenSplitToAuctionMps;
    }

    struct FeeInfra {
        LaunchFeeRegistry launchFeeRegistry;
        LaunchFeeVault feeVault;
        LaunchPoolFeeHook hook;
    }

    struct RevenueSubject {
        bytes32 subjectId;
        address revenueShareSplitter;
        address defaultIngress;
    }

    event LaunchStackDeployed(
        address indexed deployer,
        bytes32 indexed subjectId,
        address indexed tokenAddress,
        address auctionAddress,
        address strategyAddress,
        address vestingWalletAddress,
        address hookAddress,
        address feeVaultAddress,
        address launchFeeRegistryAddress,
        address subjectRegistryAddress,
        address revenueShareSplitterAddress,
        address defaultIngressAddress,
        bytes32 poolId,
        address agentSafe
    );

    constructor() Owned(msg.sender) {}

    function deploy(DeploymentConfig memory cfg)
        external
        onlyOwner
        returns (DeploymentResult memory result)
    {
        _validateConfig(cfg);

        AllocationData memory allocation = _allocationData(cfg.totalSupply);
        SubjectRegistry subjectRegistry = _subjectRegistryOrRevert(cfg.revenueShareFactory);

        address token = _createToken(cfg);
        AgentTokenVestingWallet vestingWallet = _createVestingWallet(cfg, token);
        RevenueSubject memory revenueSubject = _createRevenueSubject(cfg, token);

        FeeInfra memory feeInfra = _deployFeeInfra(cfg);
        IDistributionContract strategy =
            _initializeStrategy(cfg, token, vestingWallet, feeInfra.hook, allocation);

        require(
            IERC20Like(token).transfer(address(strategy), allocation.strategySupply),
            "STRATEGY_TRANSFER_FAILED"
        );
        require(
            IERC20Like(token).transfer(address(vestingWallet), allocation.vestingAmount),
            "VESTING_TRANSFER_FAILED"
        );
        strategy.onTokensReceived();
        require(
            RegentLBPStrategy(address(strategy)).auctionAddress() != address(0),
            "AUCTION_NOT_CREATED"
        );

        bytes32 poolId = feeInfra.launchFeeRegistry.registerPool(
            LaunchFeeRegistry.PoolRegistration({
                launchToken: token,
                quoteToken: cfg.usdcToken,
                treasury: revenueSubject.revenueShareSplitter,
                regentRecipient: cfg.regentRecipient,
                poolFee: cfg.officialPoolFee,
                tickSpacing: cfg.officialPoolTickSpacing,
                poolManager: cfg.poolManager,
                hook: address(feeInfra.hook)
            })
        );
        feeInfra.feeVault.setCanonicalTokens(token, cfg.usdcToken);

        feeInfra.launchFeeRegistry.transferOwnership(cfg.agentSafe);
        feeInfra.feeVault.transferOwnership(cfg.agentSafe);
        feeInfra.hook.transferOwnership(cfg.agentSafe);

        result = DeploymentResult({
            tokenAddress: token,
            auctionAddress: RegentLBPStrategy(address(strategy)).auctionAddress(),
            strategyAddress: address(strategy),
            vestingWalletAddress: address(vestingWallet),
            hookAddress: address(feeInfra.hook),
            feeVaultAddress: address(feeInfra.feeVault),
            launchFeeRegistryAddress: address(feeInfra.launchFeeRegistry),
            subjectRegistryAddress: address(subjectRegistry),
            revenueShareSplitterAddress: revenueSubject.revenueShareSplitter,
            defaultIngressAddress: revenueSubject.defaultIngress,
            subjectId: revenueSubject.subjectId,
            poolId: poolId
        });

        _emitLaunchStackDeployed(result, cfg.agentSafe);
    }

    function _validateConfig(DeploymentConfig memory cfg) internal pure {
        require(cfg.agentSafe != address(0), "AGENT_SAFE_ZERO");
        require(cfg.revenueShareFactory != address(0), "REVENUE_SHARE_FACTORY_ZERO");
        require(cfg.revenueIngressFactory != address(0), "REVENUE_INGRESS_FACTORY_ZERO");
        require(cfg.identityRegistry != address(0), "IDENTITY_REGISTRY_ZERO");
        require(cfg.tokenFactory != address(0), "TOKEN_FACTORY_ZERO");
        require(cfg.strategyFactory != address(0), "STRATEGY_FACTORY_ZERO");
        require(cfg.auctionInitializerFactory != address(0), "AUCTION_FACTORY_ZERO");
        require(cfg.poolManager != address(0), "POOL_MANAGER_ZERO");
        require(cfg.positionManager != address(0), "POSITION_MANAGER_ZERO");
        require(cfg.positionRecipient != address(0), "POSITION_RECIPIENT_ZERO");
        require(cfg.positionRecipient == cfg.agentSafe, "POSITION_RECIPIENT_MUST_MATCH_AGENT_SAFE");
        require(cfg.strategyOperator != address(0), "STRATEGY_OPERATOR_ZERO");
        require(cfg.usdcToken != address(0), "USDC_ZERO");
        require(cfg.regentRecipient != address(0), "REGENT_RECIPIENT_ZERO");
        require(cfg.identityAgentId != 0, "AGENT_ID_ZERO");
        require(cfg.totalSupply != 0, "SUPPLY_ZERO");
        require(cfg.officialPoolTickSpacing > 0, "POOL_TICK_SPACING_INVALID");
        require(cfg.officialPoolFee <= MAX_POOL_FEE, "POOL_FEE_INVALID");
        require(cfg.startBlock < cfg.endBlock, "START_BLOCK_INVALID");
        require(cfg.claimBlock >= cfg.endBlock, "CLAIM_BEFORE_END");
        require(cfg.migrationBlock > cfg.endBlock, "MIGRATION_BEFORE_END");
        require(cfg.sweepBlock > cfg.migrationBlock, "SWEEP_BEFORE_MIGRATION");
        require(cfg.maxCurrencyAmountForLP != 0, "MAX_CCY_FOR_LP_ZERO");
        require(cfg.vestingDurationSeconds != 0, "VESTING_DURATION_ZERO");
        require(cfg.floorPrice > 0, "FLOOR_PRICE_ZERO");
        require(bytes(cfg.tokenName).length != 0, "NAME_EMPTY");
        require(bytes(cfg.tokenSymbol).length != 0, "SYMBOL_EMPTY");
        require(
            PUBLIC_SALE_BPS + LP_RESERVE_BPS + VESTING_BPS == BPS_DENOMINATOR,
            "ALLOCATION_BPS_INVALID"
        );
    }

    function _allocationData(uint256 totalSupply) internal pure returns (AllocationData memory data) {
        data.publicSaleAmount = (totalSupply * PUBLIC_SALE_BPS) / BPS_DENOMINATOR;
        data.lpReserveAmount = (totalSupply * LP_RESERVE_BPS) / BPS_DENOMINATOR;
        data.vestingAmount = totalSupply - data.publicSaleAmount - data.lpReserveAmount;
        data.strategySupply = data.publicSaleAmount + data.lpReserveAmount;

        require(data.publicSaleAmount != 0, "PUBLIC_SALE_ZERO");
        require(data.lpReserveAmount != 0, "LP_RESERVE_ZERO");
        require(data.vestingAmount != 0, "VESTING_ZERO");
        require(data.strategySupply <= type(uint128).max, "STRATEGY_SUPPLY_OVERFLOW");
        require(data.publicSaleAmount <= type(uint128).max, "PUBLIC_SALE_OVERFLOW");
        require(data.lpReserveAmount <= type(uint128).max, "LP_RESERVE_OVERFLOW");

        uint256 tokenSplitToAuctionMpsRaw =
            (totalSupply * PUBLIC_SALE_BPS * MPS_TOTAL) / (BPS_DENOMINATOR * data.strategySupply);
        require(tokenSplitToAuctionMpsRaw <= type(uint24).max, "TOKEN_SPLIT_OVERFLOW");
        data.tokenSplitToAuctionMps = uint24(tokenSplitToAuctionMpsRaw);
        require(data.tokenSplitToAuctionMps != 0, "TOKEN_SPLIT_ZERO");
        require(data.tokenSplitToAuctionMps <= MPS_TOTAL, "TOKEN_SPLIT_INVALID");
    }

    function _subjectRegistryOrRevert(address revenueShareFactory)
        internal
        view
        returns (SubjectRegistry subjectRegistry)
    {
        subjectRegistry = RevenueShareFactory(revenueShareFactory).subjectRegistry();
        require(
            subjectRegistry.owner() == revenueShareFactory,
            "SUBJECT_REGISTRY_NOT_OWNED_BY_FACTORY"
        );
    }

    function _createToken(DeploymentConfig memory cfg) internal returns (address token) {
        token = ITokenFactory(cfg.tokenFactory).createToken(
            cfg.tokenName,
            cfg.tokenSymbol,
            18,
            cfg.totalSupply,
            address(this),
            cfg.tokenFactoryData,
            cfg.tokenFactorySalt
        );
        require(token != address(0), "TOKEN_NOT_CREATED");
    }

    function _createVestingWallet(DeploymentConfig memory cfg, address token)
        internal
        returns (AgentTokenVestingWallet vestingWallet)
    {
        vestingWallet = new AgentTokenVestingWallet(
            cfg.agentSafe, cfg.vestingStartTimestamp, cfg.vestingDurationSeconds, token
        );
    }

    function _deployFeeInfra(DeploymentConfig memory cfg) internal returns (FeeInfra memory feeInfra) {
        feeInfra.launchFeeRegistry = new LaunchFeeRegistry(address(this));
        feeInfra.feeVault =
            new LaunchFeeVault(address(this), address(feeInfra.launchFeeRegistry));

        // slither-disable-next-line too-many-digits
        (bytes32 hookSalt, address expectedHookAddress) = HookMiner.find(
            address(this),
            REQUIRED_HOOK_FLAGS,
            type(LaunchPoolFeeHook).creationCode,
            abi.encode(
                address(this),
                cfg.poolManager,
                address(feeInfra.launchFeeRegistry),
                address(feeInfra.feeVault)
            )
        );

        feeInfra.hook = new LaunchPoolFeeHook{salt: hookSalt}(
            address(this),
            cfg.poolManager,
            address(feeInfra.launchFeeRegistry),
            address(feeInfra.feeVault)
        );
        require(address(feeInfra.hook) == expectedHookAddress, "HOOK_ADDRESS_MISMATCH");

        feeInfra.feeVault.setHook(address(feeInfra.hook));
    }

    function _createRevenueSubject(DeploymentConfig memory cfg, address token)
        internal
        returns (RevenueSubject memory revenueSubject)
    {
        revenueSubject.subjectId = keccak256(abi.encode(block.chainid, token));
        revenueSubject.revenueShareSplitter =
            RevenueShareFactory(cfg.revenueShareFactory).createSubjectSplitter(
                revenueSubject.subjectId,
                token,
                cfg.agentSafe,
                cfg.regentRecipient,
                cfg.totalSupply,
                cfg.subjectLabel,
                block.chainid,
                cfg.identityRegistry,
                cfg.identityAgentId
            );

        revenueSubject.defaultIngress = RevenueIngressFactory(cfg.revenueIngressFactory)
            .createIngressAccount(revenueSubject.subjectId, "default-usdc-ingress", true);
        require(revenueSubject.defaultIngress != address(0), "DEFAULT_INGRESS_NOT_CREATED");
    }

    function _initializeStrategy(
        DeploymentConfig memory cfg,
        address token,
        AgentTokenVestingWallet vestingWallet,
        LaunchPoolFeeHook hook,
        AllocationData memory allocation
    ) internal returns (IDistributionContract strategy) {
        strategy = IDistributionStrategy(cfg.strategyFactory).initializeDistribution(
            token,
            allocation.strategySupply,
            abi.encode(
                RegentLBPStrategyFactory.RegentLBPStrategyConfig({
                    usdc: cfg.usdcToken,
                    auctionInitializerFactory: cfg.auctionInitializerFactory,
                    auctionParameters: _auctionParameters(cfg),
                    officialPoolHook: address(hook),
                    agentSafe: cfg.agentSafe,
                    vestingWallet: address(vestingWallet),
                    operator: cfg.strategyOperator,
                    positionRecipient: cfg.positionRecipient,
                    positionManager: cfg.positionManager,
                    poolManager: cfg.poolManager,
                    officialPoolFee: cfg.officialPoolFee,
                    officialPoolTickSpacing: cfg.officialPoolTickSpacing,
                    migrationBlock: cfg.migrationBlock,
                    sweepBlock: cfg.sweepBlock,
                    lpCurrencyBps: LP_CURRENCY_BPS,
                    tokenSplitToAuctionMps: allocation.tokenSplitToAuctionMps,
                    auctionTokenAmount: uint128(allocation.publicSaleAmount),
                    reserveTokenAmount: uint128(allocation.lpReserveAmount),
                    maxCurrencyAmountForLP: cfg.maxCurrencyAmountForLP
                })
            ),
            bytes32(0)
        );
    }

    function _auctionParameters(DeploymentConfig memory cfg)
        internal
        pure
        returns (AuctionParameters memory)
    {
        return AuctionParameters({
            currency: cfg.usdcToken,
            tokensRecipient: address(0),
            fundsRecipient: address(0),
            startBlock: cfg.startBlock,
            endBlock: cfg.endBlock,
            claimBlock: cfg.claimBlock,
            tickSpacing: cfg.auctionTickSpacing,
            validationHook: cfg.validationHook,
            floorPrice: cfg.floorPrice,
            requiredCurrencyRaised: cfg.requiredCurrencyRaised,
            auctionStepsData: bytes("")
        });
    }

    function _emitLaunchStackDeployed(DeploymentResult memory result, address agentSafe) internal {
        emit LaunchStackDeployed(
            msg.sender,
            result.subjectId,
            result.tokenAddress,
            result.auctionAddress,
            result.strategyAddress,
            result.vestingWalletAddress,
            result.hookAddress,
            result.feeVaultAddress,
            result.launchFeeRegistryAddress,
            result.subjectRegistryAddress,
            result.revenueShareSplitterAddress,
            result.defaultIngressAddress,
            result.poolId,
            agentSafe
        );
    }
}

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
}
