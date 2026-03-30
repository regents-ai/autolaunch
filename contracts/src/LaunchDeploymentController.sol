// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AuctionParameters} from "src/cca/interfaces/IContinuousClearingAuction.sol";
import {IDistributionContract} from "src/cca/interfaces/external/IDistributionContract.sol";
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

contract LaunchDeploymentController {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant MPS_TOTAL = 10_000_000;
    uint16 internal constant PUBLIC_SALE_BPS = 1000;
    uint16 internal constant LP_RESERVE_BPS = 500;
    uint16 internal constant VESTING_BPS = 8500;
    uint16 internal constant LP_CURRENCY_BPS = 5000;
    uint24 internal constant MAX_POOL_FEE = 1_000_000;

    struct DeploymentConfig {
        address recoverySafe;
        address agentTreasurySafe;
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
        uint16 protocolSkimBps;
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

    function deploy(DeploymentConfig memory cfg) external returns (DeploymentResult memory result) {
        require(cfg.recoverySafe != address(0), "RECOVERY_SAFE_ZERO");
        require(cfg.agentTreasurySafe != address(0), "AGENT_TREASURY_ZERO");
        require(cfg.revenueShareFactory != address(0), "REVENUE_SHARE_FACTORY_ZERO");
        require(cfg.revenueIngressFactory != address(0), "REVENUE_INGRESS_FACTORY_ZERO");
        require(cfg.identityRegistry != address(0), "IDENTITY_REGISTRY_ZERO");
        require(cfg.tokenFactory != address(0), "TOKEN_FACTORY_ZERO");
        require(cfg.strategyFactory != address(0), "STRATEGY_FACTORY_ZERO");
        require(cfg.auctionInitializerFactory != address(0), "AUCTION_FACTORY_ZERO");
        require(cfg.poolManager != address(0), "POOL_MANAGER_ZERO");
        require(cfg.positionManager != address(0), "POSITION_MANAGER_ZERO");
        require(cfg.positionRecipient != address(0), "POSITION_RECIPIENT_ZERO");
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
        require(cfg.protocolSkimBps <= BPS_DENOMINATOR, "SKIM_BPS_INVALID");
        require(bytes(cfg.tokenName).length != 0, "NAME_EMPTY");
        require(bytes(cfg.tokenSymbol).length != 0, "SYMBOL_EMPTY");
        require(
            PUBLIC_SALE_BPS + LP_RESERVE_BPS + VESTING_BPS == BPS_DENOMINATOR,
            "ALLOCATION_BPS_INVALID"
        );

        uint256 publicSaleAmount = (cfg.totalSupply * PUBLIC_SALE_BPS) / BPS_DENOMINATOR;
        uint256 lpReserveAmount = (cfg.totalSupply * LP_RESERVE_BPS) / BPS_DENOMINATOR;
        uint256 vestingAmount = cfg.totalSupply - publicSaleAmount - lpReserveAmount;
        uint256 strategySupply = publicSaleAmount + lpReserveAmount;
        require(publicSaleAmount != 0, "PUBLIC_SALE_ZERO");
        require(lpReserveAmount != 0, "LP_RESERVE_ZERO");
        require(vestingAmount != 0, "VESTING_ZERO");
        require(strategySupply <= type(uint128).max, "STRATEGY_SUPPLY_OVERFLOW");
        require(publicSaleAmount <= type(uint128).max, "PUBLIC_SALE_OVERFLOW");
        require(lpReserveAmount <= type(uint128).max, "LP_RESERVE_OVERFLOW");

        uint256 tokenSplitToAuctionMpsRaw =
            (cfg.totalSupply * PUBLIC_SALE_BPS * MPS_TOTAL) / (BPS_DENOMINATOR * strategySupply);
        require(tokenSplitToAuctionMpsRaw <= type(uint24).max, "TOKEN_SPLIT_OVERFLOW");
        uint24 tokenSplitToAuctionMps = uint24(tokenSplitToAuctionMpsRaw);
        require(tokenSplitToAuctionMps != 0, "TOKEN_SPLIT_ZERO");
        require(tokenSplitToAuctionMps <= MPS_TOTAL, "TOKEN_SPLIT_INVALID");

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

        AgentTokenVestingWallet vestingWallet = new AgentTokenVestingWallet(
            cfg.agentTreasurySafe, cfg.vestingStartTimestamp, cfg.vestingDurationSeconds, token
        );

        bytes32 subjectId = keccak256(abi.encode(block.chainid, token));
        address revenueShareSplitter = RevenueShareFactory(cfg.revenueShareFactory)
            .createSubjectSplitter(
                subjectId,
                token,
                cfg.agentTreasurySafe,
                cfg.regentRecipient,
                cfg.recoverySafe,
                cfg.recoverySafe,
                cfg.protocolSkimBps,
                cfg.subjectLabel,
                block.chainid,
                cfg.identityRegistry,
                cfg.identityAgentId
            );

        address defaultIngress = RevenueIngressFactory(cfg.revenueIngressFactory)
            .createIngressAccount(subjectId, "default-usdc-ingress", true);
        require(defaultIngress != address(0), "DEFAULT_INGRESS_NOT_CREATED");

        LaunchFeeRegistry launchFeeRegistry = new LaunchFeeRegistry(address(this));
        LaunchFeeVault feeVault = new LaunchFeeVault(address(this), address(launchFeeRegistry));
        (bytes32 hookSalt, address expectedHookAddress) = HookMiner.find(
            address(this),
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            type(LaunchPoolFeeHook).creationCode,
            abi.encode(
                address(this), cfg.poolManager, address(launchFeeRegistry), address(feeVault)
            )
        );
        LaunchPoolFeeHook hook = new LaunchPoolFeeHook{salt: hookSalt}(
            address(this), cfg.poolManager, address(launchFeeRegistry), address(feeVault)
        );
        require(address(hook) == expectedHookAddress, "HOOK_ADDRESS_MISMATCH");
        feeVault.setHook(address(hook));

        AuctionParameters memory auctionParameters = AuctionParameters({
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

        IDistributionContract strategy = IDistributionStrategy(cfg.strategyFactory)
            .initializeDistribution(
                token,
                strategySupply,
                abi.encode(
                    RegentLBPStrategyFactory.RegentLBPStrategyConfig({
                        usdc: cfg.usdcToken,
                        auctionInitializerFactory: cfg.auctionInitializerFactory,
                        auctionParameters: auctionParameters,
                        officialPoolHook: address(hook),
                        agentTreasurySafe: cfg.agentTreasurySafe,
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
                        tokenSplitToAuctionMps: tokenSplitToAuctionMps,
                        auctionTokenAmount: uint128(publicSaleAmount),
                        reserveTokenAmount: uint128(lpReserveAmount),
                        maxCurrencyAmountForLP: cfg.maxCurrencyAmountForLP
                    })
                ),
                bytes32(0)
            );

        require(
            IERC20Like(token).transfer(address(strategy), strategySupply),
            "STRATEGY_TRANSFER_FAILED"
        );
        require(
            IERC20Like(token).transfer(address(vestingWallet), vestingAmount),
            "VESTING_TRANSFER_FAILED"
        );
        strategy.onTokensReceived();
        require(
            RegentLBPStrategy(address(strategy)).auctionAddress() != address(0),
            "AUCTION_NOT_CREATED"
        );

        bytes32 poolId = launchFeeRegistry.registerPool(
            LaunchFeeRegistry.PoolRegistration({
                launchToken: token,
                quoteToken: cfg.usdcToken,
                treasury: revenueShareSplitter,
                regentRecipient: cfg.regentRecipient,
                poolFee: cfg.officialPoolFee,
                tickSpacing: cfg.officialPoolTickSpacing,
                poolManager: cfg.poolManager,
                hook: address(hook)
            })
        );

        launchFeeRegistry.transferOwnership(cfg.recoverySafe);
        feeVault.transferOwnership(cfg.recoverySafe);
        hook.transferOwnership(cfg.recoverySafe);

        result = DeploymentResult({
            tokenAddress: token,
            auctionAddress: RegentLBPStrategy(address(strategy)).auctionAddress(),
            strategyAddress: address(strategy),
            vestingWalletAddress: address(vestingWallet),
            hookAddress: address(hook),
            feeVaultAddress: address(feeVault),
            launchFeeRegistryAddress: address(launchFeeRegistry),
            subjectRegistryAddress: address(
                SubjectRegistry(RevenueShareFactory(cfg.revenueShareFactory).subjectRegistry())
            ),
            revenueShareSplitterAddress: revenueShareSplitter,
            defaultIngressAddress: defaultIngress,
            subjectId: subjectId,
            poolId: poolId
        });
    }
}

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
}
