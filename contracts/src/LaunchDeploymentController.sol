// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AuctionParameters} from "src/cca/interfaces/IContinuousClearingAuction.sol";
import {IDistributionContract} from "src/cca/interfaces/external/IDistributionContract.sol";
import {Owned} from "src/auth/Owned.sol";
import {LaunchFeeInfraDeployer} from "src/LaunchFeeInfraDeployer.sol";
import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";
import {LaunchFeeVault} from "src/LaunchFeeVault.sol";
import {LaunchPoolFeeHook} from "src/LaunchPoolFeeHook.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {AgentTokenVestingWallet} from "src/AgentTokenVestingWallet.sol";
import {RegentLBPStrategy} from "src/RegentLBPStrategy.sol";
import {RegentLBPStrategyFactory} from "src/RegentLBPStrategyFactory.sol";
import {ITokenFactory} from "src/interfaces/ITokenFactory.sol";
import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";
import {BaseUsdc} from "src/libraries/BaseUsdc.sol";

contract LaunchDeploymentController is Owned {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant MPS_TOTAL = 10_000_000;
    uint16 internal constant PUBLIC_SALE_BPS = 1000;
    uint16 internal constant LP_RESERVE_BPS = 500;
    uint16 internal constant VESTING_BPS = 8500;
    uint16 internal constant LP_CURRENCY_BPS = 5000;
    uint24 internal constant MAX_POOL_FEE = 1_000_000;

    struct DeploymentConfig {
        address agentSafe;
        address feeInfraDeployer;
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
        bytes auctionStepsData;
        string tokenName;
        string tokenSymbol;
        string subjectLabel;
        bytes tokenFactoryData;
        bytes32 tokenFactoryGraffiti;
        bytes32 launchFeeHookSalt;
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

    struct StagedLaunch {
        bytes32 configHash;
        address tokenAddress;
        address strategyAddress;
        address auctionAddress;
        address vestingWalletAddress;
        address hookAddress;
        address feeVaultAddress;
        address launchFeeRegistryAddress;
        address subjectRegistryAddress;
        address revenueShareSplitterAddress;
        address defaultIngressAddress;
        bytes32 poolId;
        bool feeInfraDeployed;
        bool finalized;
    }

    mapping(bytes32 => StagedLaunch) public stagedLaunches;

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
    event StagedLaunchPrepared(
        bytes32 indexed launchId,
        address indexed tokenAddress,
        address indexed vestingWalletAddress,
        address revenueShareSplitterAddress,
        address defaultIngressAddress
    );
    event StagedLaunchFeeInfraDeployed(
        bytes32 indexed launchId,
        address indexed hookAddress,
        address indexed feeVaultAddress,
        address launchFeeRegistryAddress
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

        bytes32 poolId = feeInfra.launchFeeRegistry
            .registerPool(
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

    function prepareLaunch(DeploymentConfig memory cfg)
        external
        onlyOwner
        returns (bytes32 launchId, DeploymentResult memory result)
    {
        _validateConfig(cfg);
        _allocationData(cfg.totalSupply);
        SubjectRegistry subjectRegistry = _subjectRegistryOrRevert(cfg.revenueShareFactory);

        address token = _createToken(cfg);
        AgentTokenVestingWallet vestingWallet = _createVestingWallet(cfg, token);
        RevenueSubject memory revenueSubject = _createRevenueSubject(cfg, token);

        launchId = revenueSubject.subjectId;
        StagedLaunch storage launch = stagedLaunches[launchId];
        require(launch.configHash == bytes32(0), "LAUNCH_EXISTS");

        launch.configHash = _configHash(cfg);
        launch.tokenAddress = token;
        launch.vestingWalletAddress = address(vestingWallet);
        launch.subjectRegistryAddress = address(subjectRegistry);
        launch.revenueShareSplitterAddress = revenueSubject.revenueShareSplitter;
        launch.defaultIngressAddress = revenueSubject.defaultIngress;

        result = _resultFromStagedLaunch(launchId);

        emit StagedLaunchPrepared(
            launchId,
            token,
            address(vestingWallet),
            revenueSubject.revenueShareSplitter,
            revenueSubject.defaultIngress
        );
    }

    function deployLaunchFeeInfra(bytes32 launchId, DeploymentConfig memory cfg)
        external
        onlyOwner
        returns (DeploymentResult memory result)
    {
        StagedLaunch storage launch = _stagedLaunchOrRevert(launchId, cfg);
        require(!launch.feeInfraDeployed, "FEE_INFRA_ALREADY_DEPLOYED");

        FeeInfra memory feeInfra = _deployFeeInfra(cfg);

        launch.launchFeeRegistryAddress = address(feeInfra.launchFeeRegistry);
        launch.feeVaultAddress = address(feeInfra.feeVault);
        launch.hookAddress = address(feeInfra.hook);
        launch.feeInfraDeployed = true;

        result = _resultFromStagedLaunch(launchId);

        emit StagedLaunchFeeInfraDeployed(
            launchId,
            address(feeInfra.hook),
            address(feeInfra.feeVault),
            address(feeInfra.launchFeeRegistry)
        );
    }

    function finalizeLaunch(bytes32 launchId, DeploymentConfig memory cfg)
        external
        onlyOwner
        returns (DeploymentResult memory result)
    {
        StagedLaunch storage launch = _stagedLaunchOrRevert(launchId, cfg);
        require(launch.feeInfraDeployed, "FEE_INFRA_NOT_DEPLOYED");
        require(!launch.finalized, "LAUNCH_FINALIZED");

        AllocationData memory allocation = _allocationData(cfg.totalSupply);
        IDistributionContract strategy = _initializeStrategy(
            cfg,
            launch.tokenAddress,
            AgentTokenVestingWallet(launch.vestingWalletAddress),
            LaunchPoolFeeHook(launch.hookAddress),
            allocation
        );

        require(
            IERC20Like(launch.tokenAddress).transfer(address(strategy), allocation.strategySupply),
            "STRATEGY_TRANSFER_FAILED"
        );
        require(
            IERC20Like(launch.tokenAddress)
                .transfer(launch.vestingWalletAddress, allocation.vestingAmount),
            "VESTING_TRANSFER_FAILED"
        );
        strategy.onTokensReceived();
        require(
            RegentLBPStrategy(address(strategy)).auctionAddress() != address(0),
            "AUCTION_NOT_CREATED"
        );

        LaunchFeeRegistry launchFeeRegistry = LaunchFeeRegistry(launch.launchFeeRegistryAddress);
        LaunchFeeVault feeVault = LaunchFeeVault(payable(launch.feeVaultAddress));
        LaunchPoolFeeHook hook = LaunchPoolFeeHook(launch.hookAddress);

        bytes32 poolId = launchFeeRegistry.registerPool(
            LaunchFeeRegistry.PoolRegistration({
                launchToken: launch.tokenAddress,
                quoteToken: cfg.usdcToken,
                treasury: launch.revenueShareSplitterAddress,
                regentRecipient: cfg.regentRecipient,
                poolFee: cfg.officialPoolFee,
                tickSpacing: cfg.officialPoolTickSpacing,
                poolManager: cfg.poolManager,
                hook: address(hook)
            })
        );
        feeVault.setCanonicalTokens(launch.tokenAddress, cfg.usdcToken);

        launchFeeRegistry.transferOwnership(cfg.agentSafe);
        feeVault.transferOwnership(cfg.agentSafe);
        hook.transferOwnership(cfg.agentSafe);

        launch.strategyAddress = address(strategy);
        launch.auctionAddress = RegentLBPStrategy(address(strategy)).auctionAddress();
        launch.poolId = poolId;
        launch.finalized = true;

        result = _resultFromStagedLaunch(launchId);

        _emitLaunchStackDeployed(result, cfg.agentSafe);
    }

    function stagedLaunchResult(bytes32 launchId)
        external
        view
        returns (DeploymentResult memory result)
    {
        require(stagedLaunches[launchId].configHash != bytes32(0), "LAUNCH_NOT_PREPARED");
        return _resultFromStagedLaunch(launchId);
    }

    function _validateConfig(DeploymentConfig memory cfg) internal view {
        require(cfg.agentSafe != address(0), "AGENT_SAFE_ZERO");
        require(cfg.feeInfraDeployer != address(0), "FEE_INFRA_DEPLOYER_ZERO");
        require(cfg.revenueShareFactory != address(0), "REVENUE_SHARE_FACTORY_ZERO");
        require(cfg.revenueIngressFactory != address(0), "REVENUE_INGRESS_FACTORY_ZERO");
        require(cfg.tokenFactory != address(0), "TOKEN_FACTORY_ZERO");
        require(cfg.strategyFactory != address(0), "STRATEGY_FACTORY_ZERO");
        require(cfg.auctionInitializerFactory != address(0), "AUCTION_FACTORY_ZERO");
        require(cfg.poolManager != address(0), "POOL_MANAGER_ZERO");
        require(cfg.positionManager != address(0), "POSITION_MANAGER_ZERO");
        require(cfg.positionRecipient != address(0), "POSITION_RECIPIENT_ZERO");
        require(cfg.positionRecipient == cfg.agentSafe, "POSITION_RECIPIENT_MUST_MATCH_AGENT_SAFE");
        require(cfg.strategyOperator != address(0), "STRATEGY_OPERATOR_ZERO");
        require(cfg.usdcToken != address(0), "USDC_ZERO");
        BaseUsdc.requireCanonical(cfg.usdcToken);
        require(cfg.regentRecipient != address(0), "REGENT_RECIPIENT_ZERO");
        bool hasIdentityLink = cfg.identityRegistry != address(0) || cfg.identityAgentId != 0;
        if (hasIdentityLink) {
            require(cfg.identityRegistry != address(0), "IDENTITY_REGISTRY_ZERO");
            require(cfg.identityAgentId != 0, "AGENT_ID_ZERO");
        }
        require(cfg.totalSupply != 0, "SUPPLY_ZERO");
        require(cfg.officialPoolTickSpacing > 0, "POOL_TICK_SPACING_INVALID");
        require(cfg.officialPoolFee <= MAX_POOL_FEE, "POOL_FEE_INVALID");
        require(cfg.startBlock < cfg.endBlock, "START_BLOCK_INVALID");
        require(cfg.claimBlock >= cfg.endBlock, "CLAIM_BEFORE_END");
        require(cfg.migrationBlock > cfg.endBlock, "MIGRATION_BEFORE_END");
        require(cfg.sweepBlock > cfg.migrationBlock, "SWEEP_BEFORE_MIGRATION");
        require(cfg.vestingDurationSeconds != 0, "VESTING_DURATION_ZERO");
        require(cfg.floorPrice > 0, "FLOOR_PRICE_ZERO");
        require(cfg.auctionTickSpacing > 0, "AUCTION_TICK_SPACING_ZERO");
        require(cfg.floorPrice % cfg.auctionTickSpacing == 0, "FLOOR_PRICE_TICK_MISALIGNED");
        require(cfg.auctionTickSpacing >= cfg.floorPrice / 10_000, "AUCTION_TICK_SPACING_TOO_SMALL");
        _validateAuctionStepsData(cfg.auctionStepsData, cfg.endBlock - cfg.startBlock);
        require(bytes(cfg.tokenName).length != 0, "NAME_EMPTY");
        require(bytes(cfg.tokenSymbol).length != 0, "SYMBOL_EMPTY");
        require(
            RevenueShareFactory(cfg.revenueShareFactory).usdc() == cfg.usdcToken,
            "REVENUE_SHARE_USDC_MISMATCH"
        );
        require(
            RevenueIngressFactory(cfg.revenueIngressFactory).usdc() == cfg.usdcToken,
            "REVENUE_INGRESS_USDC_MISMATCH"
        );
        require(
            PUBLIC_SALE_BPS + LP_RESERVE_BPS + VESTING_BPS == BPS_DENOMINATOR,
            "ALLOCATION_BPS_INVALID"
        );
    }

    function _allocationData(uint256 totalSupply)
        internal
        pure
        returns (AllocationData memory data)
    {
        data.publicSaleAmount =
            (totalSupply * PUBLIC_SALE_BPS) / BPS_DENOMINATOR;
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
        data.tokenSplitToAuctionMps = _toUint24(tokenSplitToAuctionMpsRaw);
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
            subjectRegistry.canRegisterSubject(revenueShareFactory),
            "REVENUE_SHARE_FACTORY_NOT_REGISTRAR"
        );
    }

    function _createToken(DeploymentConfig memory cfg) internal returns (address token) {
        token = ITokenFactory(cfg.tokenFactory)
            .createToken(
                cfg.tokenName,
                cfg.tokenSymbol,
                18,
                cfg.totalSupply,
                address(this),
                cfg.tokenFactoryData,
                cfg.tokenFactoryGraffiti
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

    function _deployFeeInfra(DeploymentConfig memory cfg)
        internal
        returns (FeeInfra memory feeInfra)
    {
        (feeInfra.launchFeeRegistry, feeInfra.feeVault, feeInfra.hook) = LaunchFeeInfraDeployer(
                cfg.feeInfraDeployer
            ).deploy(address(this), cfg.poolManager, cfg.usdcToken, cfg.launchFeeHookSalt);

        feeInfra.launchFeeRegistry.acceptOwnership();
        feeInfra.feeVault.acceptOwnership();
        feeInfra.hook.acceptOwnership();
    }

    function _createRevenueSubject(DeploymentConfig memory cfg, address token)
        internal
        returns (RevenueSubject memory revenueSubject)
    {
        revenueSubject.subjectId = keccak256(abi.encode(block.chainid, token));
        uint256 identityChainId =
            cfg.identityRegistry == address(0) && cfg.identityAgentId == 0 ? 0 : block.chainid;
        revenueSubject.revenueShareSplitter = RevenueShareFactory(cfg.revenueShareFactory)
            .createSubjectSplitter(
                revenueSubject.subjectId,
                token,
                cfg.revenueIngressFactory,
                cfg.agentSafe,
                RevenueShareFactory(cfg.revenueShareFactory).stakingRevenueRouter(),
                cfg.totalSupply,
                cfg.subjectLabel,
                identityChainId,
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
        RegentLBPStrategyFactory.RegentLBPStrategyConfig memory
            strategyCfg = _strategyConfig(cfg, vestingWallet, hook, allocation);

        strategy = IDistributionStrategy(cfg.strategyFactory)
            .initializeDistribution(
                token, allocation.strategySupply, abi.encode(strategyCfg), bytes32(0)
            );
    }

    function _strategyConfig(
        DeploymentConfig memory cfg,
        AgentTokenVestingWallet vestingWallet,
        LaunchPoolFeeHook hook,
        AllocationData memory allocation
    ) internal pure returns (RegentLBPStrategyFactory.RegentLBPStrategyConfig memory strategyCfg) {
        strategyCfg.usdc = cfg.usdcToken;
        strategyCfg.auctionInitializerFactory = cfg.auctionInitializerFactory;
        strategyCfg.auctionParameters = _auctionParameters(cfg);
        strategyCfg.officialPoolHook = address(hook);
        strategyCfg.agentSafe = cfg.agentSafe;
        strategyCfg.vestingWallet = address(vestingWallet);
        strategyCfg.operator = cfg.strategyOperator;
        strategyCfg.positionRecipient = cfg.positionRecipient;
        strategyCfg.positionManager = cfg.positionManager;
        strategyCfg.poolManager = cfg.poolManager;
        strategyCfg.officialPoolFee = cfg.officialPoolFee;
        strategyCfg.officialPoolTickSpacing = cfg.officialPoolTickSpacing;
        strategyCfg.migrationBlock = cfg.migrationBlock;
        strategyCfg.sweepBlock = cfg.sweepBlock;
        strategyCfg.lpCurrencyBps = LP_CURRENCY_BPS;
        strategyCfg.tokenSplitToAuctionMps = allocation.tokenSplitToAuctionMps;
        strategyCfg.auctionTokenAmount = uint128(allocation.publicSaleAmount);
        strategyCfg.reserveTokenAmount = uint128(allocation.lpReserveAmount);
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
            auctionStepsData: cfg.auctionStepsData
        });
    }

    function _validateAuctionStepsData(bytes memory steps, uint256 durationBlocks) internal pure {
        require(steps.length != 0, "AUCTION_STEPS_EMPTY");
        require(steps.length % 8 == 0, "AUCTION_STEPS_LENGTH");

        uint256 totalMps;
        uint256 totalBlocks;

        for (uint256 offset; offset < steps.length; offset += 8) {
            uint256 packed;
            assembly {
                packed := shr(192, mload(add(add(steps, 0x20), offset)))
            }

            uint256 stepMps = packed >> 40;
            uint256 blockDelta = packed & type(uint40).max;
            require(blockDelta != 0, "AUCTION_STEP_BLOCKS_ZERO");

            totalMps += stepMps * blockDelta;
            totalBlocks += blockDelta;
        }

        require(totalMps == MPS_TOTAL, "AUCTION_STEPS_MPS");
        require(totalBlocks == durationBlocks, "AUCTION_STEPS_BLOCKS");
    }

    function _stagedLaunchOrRevert(bytes32 launchId, DeploymentConfig memory cfg)
        internal
        view
        returns (StagedLaunch storage launch)
    {
        launch = stagedLaunches[launchId];
        require(launch.configHash != bytes32(0), "LAUNCH_NOT_PREPARED");
        require(launch.configHash == _configHash(cfg), "LAUNCH_CONFIG_CHANGED");
    }

    function _resultFromStagedLaunch(bytes32 launchId)
        internal
        view
        returns (DeploymentResult memory result)
    {
        StagedLaunch storage launch = stagedLaunches[launchId];

        result = DeploymentResult({
            tokenAddress: launch.tokenAddress,
            auctionAddress: launch.auctionAddress,
            strategyAddress: launch.strategyAddress,
            vestingWalletAddress: launch.vestingWalletAddress,
            hookAddress: launch.hookAddress,
            feeVaultAddress: launch.feeVaultAddress,
            launchFeeRegistryAddress: launch.launchFeeRegistryAddress,
            subjectRegistryAddress: launch.subjectRegistryAddress,
            revenueShareSplitterAddress: launch.revenueShareSplitterAddress,
            defaultIngressAddress: launch.defaultIngressAddress,
            subjectId: launchId,
            poolId: launch.poolId
        });
    }

    function _configHash(DeploymentConfig memory cfg) internal pure returns (bytes32) {
        return keccak256(abi.encode(cfg));
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

    function _toUint24(uint256 value) internal pure returns (uint24) {
        require(value <= type(uint24).max, "UINT24_OVERFLOW");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(value);
    }
}

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
}
