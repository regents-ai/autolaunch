// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AgentLaunchToken} from "src/AgentLaunchToken.sol";
import {AuctionParameters} from "src/cca/interfaces/IContinuousClearingAuction.sol";
import {
    IContinuousClearingAuctionFactory
} from "src/cca/interfaces/IContinuousClearingAuctionFactory.sol";
import {IDistributionContract} from "src/cca/interfaces/external/IDistributionContract.sol";
import {AuctionStepsBuilder} from "src/cca/libraries/AuctionStepsBuilder.sol";
import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";
import {LaunchFeeVault} from "src/LaunchFeeVault.sol";
import {LaunchPoolFeeHook} from "src/LaunchPoolFeeHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "src/libraries/HookMiner.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";

contract LaunchDeploymentController {
    using AuctionStepsBuilder for bytes;

    uint256 internal constant MPS_TOTAL = 10_000_000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant PUBLIC_SALE_BPS = 1000;

    struct DeploymentConfig {
        address recoverySafe;
        address auctionProceedsRecipient;
        address agentRevenueTreasury;
        address revenueShareFactory;
        address identityRegistry;
        address factoryAddress;
        address poolManager;
        address usdcToken;
        address regentRecipient;
        address mainnetEmissionsController;
        address emissionRecipient;
        uint256 identityAgentId;
        uint256 totalSupply;
        uint24 poolFee;
        int24 poolTickSpacing;
        uint256 auctionTickSpacing;
        uint24 stepMps;
        uint40 stepBlockDelta;
        uint64 startBlock;
        uint64 endBlock;
        uint64 claimBlock;
        address validationHook;
        uint256 floorPrice;
        uint128 requiredCurrencyRaised;
        uint16 protocolSkimBps;
        string tokenName;
        string tokenSymbol;
        string subjectLabel;
    }

    struct DeploymentResult {
        address tokenAddress;
        address auctionAddress;
        address hookAddress;
        address feeVaultAddress;
        address launchFeeRegistryAddress;
        address subjectRegistryAddress;
        address revenueShareSplitterAddress;
        bytes32 subjectId;
        bytes32 poolId;
    }

    function deploy(DeploymentConfig memory cfg) external returns (DeploymentResult memory result) {
        require(cfg.recoverySafe != address(0), "RECOVERY_SAFE_ZERO");
        require(cfg.auctionProceedsRecipient != address(0), "AUCTION_RECIPIENT_ZERO");
        require(cfg.agentRevenueTreasury != address(0), "AGENT_TREASURY_ZERO");
        require(cfg.revenueShareFactory != address(0), "REVENUE_SHARE_FACTORY_ZERO");
        require(cfg.identityRegistry != address(0), "IDENTITY_REGISTRY_ZERO");
        require(cfg.factoryAddress != address(0), "FACTORY_ZERO");
        require(cfg.poolManager != address(0), "POOL_MANAGER_ZERO");
        require(cfg.usdcToken != address(0), "USDC_ZERO");
        require(cfg.emissionRecipient != address(0), "EMISSION_RECIPIENT_ZERO");
        require(cfg.identityAgentId != 0, "AGENT_ID_ZERO");
        require(cfg.totalSupply > 0, "SUPPLY_ZERO");
        require(cfg.poolTickSpacing > 0, "POOL_TICK_SPACING_INVALID");
        require(cfg.auctionTickSpacing > 0, "AUCTION_TICK_SPACING_INVALID");
        require(cfg.poolFee <= 1_000_000, "POOL_FEE_INVALID");
        require(cfg.stepMps > 0, "STEP_MPS_ZERO");
        require(cfg.stepBlockDelta > 0, "STEP_BLOCK_DELTA_ZERO");
        require(cfg.startBlock < cfg.endBlock, "START_BLOCK_INVALID");
        require(cfg.claimBlock >= cfg.endBlock, "CLAIM_BEFORE_END");
        require(cfg.floorPrice > 0, "FLOOR_PRICE_ZERO");
        require(cfg.protocolSkimBps <= 10_000, "SKIM_BPS_INVALID");
        require(bytes(cfg.tokenName).length > 0, "NAME_EMPTY");
        require(bytes(cfg.tokenSymbol).length > 0, "SYMBOL_EMPTY");
        require(MPS_TOTAL % uint256(cfg.stepMps) == 0, "STEP_MPS_MUST_DIVIDE_TOTAL");

        uint256 stepCount = MPS_TOTAL / uint256(cfg.stepMps);
        require(
            uint256(cfg.endBlock - cfg.startBlock) == stepCount * uint256(cfg.stepBlockDelta),
            "STEP_BLOCK_DELTA_MISMATCH"
        );

        address effectiveRegentRecipient = cfg.mainnetEmissionsController != address(0)
            ? cfg.mainnetEmissionsController
            : cfg.regentRecipient;
        require(effectiveRegentRecipient != address(0), "REGENT_RECIPIENT_ZERO");

        uint256 publicSaleAmount = cfg.totalSupply * PUBLIC_SALE_BPS / BPS_DENOMINATOR;
        require(publicSaleAmount != 0, "PUBLIC_SALE_ZERO");
        uint256 retainedAmount = cfg.totalSupply - publicSaleAmount;

        AgentLaunchToken token =
            new AgentLaunchToken(cfg.tokenName, cfg.tokenSymbol, cfg.totalSupply, address(this));

        bytes memory auctionStepsData = AuctionStepsBuilder.init();
        for (uint256 i; i < stepCount; ++i) {
            auctionStepsData = auctionStepsData.addStep(cfg.stepMps, cfg.stepBlockDelta);
        }

        AuctionParameters memory parameters = AuctionParameters({
            currency: cfg.usdcToken,
            tokensRecipient: cfg.recoverySafe,
            fundsRecipient: cfg.auctionProceedsRecipient,
            startBlock: cfg.startBlock,
            endBlock: cfg.endBlock,
            claimBlock: cfg.claimBlock,
            tickSpacing: cfg.auctionTickSpacing,
            validationHook: cfg.validationHook,
            floorPrice: cfg.floorPrice,
            requiredCurrencyRaised: cfg.requiredCurrencyRaised,
            auctionStepsData: auctionStepsData
        });

        IDistributionContract auction = IContinuousClearingAuctionFactory(cfg.factoryAddress)
            .initializeDistribution(
                address(token), publicSaleAmount, abi.encode(parameters), bytes32(0)
            );

        bool transferred = token.transfer(address(auction), publicSaleAmount);
        require(transferred, "AUCTION_TRANSFER_FAILED");
        if (retainedAmount != 0) {
            bool retainedTransferred = token.transfer(cfg.recoverySafe, retainedAmount);
            require(retainedTransferred, "RETAINED_TRANSFER_FAILED");
        }
        auction.onTokensReceived();

        bytes32 subjectId = keccak256(abi.encode(block.chainid, address(token)));
        address revenueShareSplitter = RevenueShareFactory(cfg.revenueShareFactory)
            .createSubjectSplitter(
                subjectId,
                address(token),
                cfg.agentRevenueTreasury,
                effectiveRegentRecipient,
                cfg.recoverySafe,
                cfg.recoverySafe,
                block.chainid,
                cfg.emissionRecipient,
                cfg.protocolSkimBps,
                cfg.subjectLabel,
                block.chainid,
                cfg.identityRegistry,
                cfg.identityAgentId
            );

        LaunchFeeRegistry launchFeeRegistry = new LaunchFeeRegistry(address(this));
        LaunchFeeVault vault = new LaunchFeeVault(address(this), address(launchFeeRegistry));
        (bytes32 hookSalt,) = HookMiner.find(
            address(this),
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            type(LaunchPoolFeeHook).creationCode,
            abi.encode(address(this), cfg.poolManager, address(launchFeeRegistry), address(vault))
        );
        LaunchPoolFeeHook hook = new LaunchPoolFeeHook{salt: hookSalt}(
            address(this), cfg.poolManager, address(launchFeeRegistry), address(vault)
        );

        vault.setHook(address(hook));

        bytes32 poolId = launchFeeRegistry.registerPool(
            LaunchFeeRegistry.PoolRegistration({
                launchToken: address(token),
                quoteToken: cfg.usdcToken,
                treasury: revenueShareSplitter,
                regentRecipient: effectiveRegentRecipient,
                poolFee: cfg.poolFee,
                tickSpacing: cfg.poolTickSpacing,
                poolManager: cfg.poolManager,
                hook: address(hook)
            })
        );

        launchFeeRegistry.transferOwnership(cfg.recoverySafe);
        vault.transferOwnership(cfg.recoverySafe);
        hook.transferOwnership(cfg.recoverySafe);

        result = DeploymentResult({
            tokenAddress: address(token),
            auctionAddress: address(auction),
            hookAddress: address(hook),
            feeVaultAddress: address(vault),
            launchFeeRegistryAddress: address(launchFeeRegistry),
            subjectRegistryAddress: address(
                SubjectRegistry(RevenueShareFactory(cfg.revenueShareFactory).subjectRegistry())
            ),
            revenueShareSplitterAddress: revenueShareSplitter,
            subjectId: subjectId,
            poolId: poolId
        });
    }
}
