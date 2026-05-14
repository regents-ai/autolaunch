// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {LaunchFeeInfraDeployer} from "src/LaunchFeeInfraDeployer.sol";
import {LaunchDeploymentController} from "src/LaunchDeploymentController.sol";
import {LaunchPoolFeeHook} from "src/LaunchPoolFeeHook.sol";
import {RegentLBPStrategyFactory} from "src/RegentLBPStrategyFactory.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {BaseUsdc} from "src/libraries/BaseUsdc.sol";
import {AuctionStepsBuilder} from "src/cca/libraries/AuctionStepsBuilder.sol";
import {HookMiner} from "src/libraries/HookMiner.sol";
import {UERC20Metadata} from "@uniswap/uerc20-factory/src/libraries/UERC20MetadataLibrary.sol";

interface IUERC20FactoryShape {
    function getUERC20Address(
        string memory name,
        string memory symbol,
        uint8 decimals,
        address creator,
        bytes32 graffiti
    ) external view returns (address);
}

contract ExampleCCADeploymentScript is Script {
    using AuctionStepsBuilder for bytes;

    struct ScriptConfig {
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
        address factoryOwner;
        uint256 agentId;
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
        string tokenDescription;
        string tokenWebsite;
        string tokenImage;
        string subjectLabel;
    }

    address internal constant CANONICAL_CCA_FACTORY = 0xCCccCcCAE7503Cac057829BF2811De42E16e0bD5;
    address internal constant REGENT_MULTISIG = 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e;
    uint256 internal constant BASE_MAINNET_CHAIN_ID = 8453;
    uint256 internal constant DEFAULT_TOTAL_SUPPLY = 100_000_000_000e18;
    uint256 internal constant DEFAULT_AUCTION_START_BLOCK_OFFSET = 300;
    uint256 internal constant DEFAULT_AUCTION_DURATION_BLOCKS = 86_400;
    uint24 internal constant DEFAULT_POOL_FEE = 0;
    int24 internal constant DEFAULT_POOL_TICK_SPACING = 60;
    uint64 internal constant DEFAULT_CLAIM_BLOCK_OFFSET = 64;
    uint64 internal constant DEFAULT_MIGRATION_BLOCK_OFFSET = 128;
    uint64 internal constant DEFAULT_SWEEP_BLOCK_OFFSET = 256;
    uint64 internal constant DEFAULT_VESTING_DURATION_SECONDS = 365 days;
    uint256 internal constant MPS_TOTAL = 10_000_000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant DEFAULT_CCA_PREBID_BLOCKS = 0;
    uint256 internal constant DEFAULT_CCA_FINAL_BLOCK_BPS = 3000;
    uint256 internal constant MIN_CCA_FINAL_BLOCK_BPS = 2000;
    uint256 internal constant MAX_CCA_FINAL_BLOCK_BPS = 4000;
    uint256 internal constant CONVEX_STEP_COUNT = 12;
    uint256 internal constant CONVEX_CURVE_SCALE = 1_000_000_000_000;
    uint160 internal constant REQUIRED_HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    function _loadConfig() internal view returns (ScriptConfig memory cfg) {
        cfg.agentSafe = vm.envAddress("AUTOLAUNCH_AGENT_SAFE_ADDRESS");
        require(cfg.agentSafe != address(0), "AGENT_SAFE_ZERO");

        cfg.totalSupply = vm.envOr("AUTOLAUNCH_TOTAL_SUPPLY", DEFAULT_TOTAL_SUPPLY);
        require(cfg.totalSupply > 0, "TOTAL_SUPPLY_ZERO");

        cfg.agentId = _parseAgentId(vm.envOr("AUTOLAUNCH_AGENT_ID", string("")));

        cfg.strategyOperator = vm.envAddress("STRATEGY_OPERATOR");
        require(cfg.strategyOperator != address(0), "STRATEGY_OPERATOR_ZERO");

        uint256 officialPoolFeeRaw = vm.envOr("OFFICIAL_POOL_FEE", uint256(DEFAULT_POOL_FEE));
        require(officialPoolFeeRaw <= 1_000_000, "POOL_FEE_INVALID");
        cfg.officialPoolFee = _toUint24(officialPoolFeeRaw);

        int256 poolTickSpacing = vm.envOr("OFFICIAL_POOL_TICK_SPACING", int256(DEFAULT_POOL_TICK_SPACING));
        require(poolTickSpacing > 0, "POOL_TICK_SPACING_INVALID");
        require(poolTickSpacing <= type(int24).max, "POOL_TICK_SPACING_TOO_LARGE");
        cfg.officialPoolTickSpacing = _toInt24(poolTickSpacing);

        uint256 auctionDurationBlocks = vm.envOr("AUCTION_DURATION_BLOCKS", DEFAULT_AUCTION_DURATION_BLOCKS);
        require(auctionDurationBlocks > 0, "AUCTION_DURATION_ZERO");
        require(auctionDurationBlocks <= type(uint40).max, "AUCTION_DURATION_TOO_LARGE");
        uint256 prebidBlocks = vm.envOr("CCA_PREBID_BLOCKS", DEFAULT_CCA_PREBID_BLOCKS);
        require(prebidBlocks <= type(uint40).max, "PREBID_BLOCKS_TOO_LARGE");
        uint256 finalBlockBps = vm.envOr("CCA_FINAL_BLOCK_BPS", DEFAULT_CCA_FINAL_BLOCK_BPS);
        require(
            finalBlockBps >= MIN_CCA_FINAL_BLOCK_BPS && finalBlockBps <= MAX_CCA_FINAL_BLOCK_BPS,
            "CCA_FINAL_BLOCK_BPS_INVALID"
        );
        uint256 auctionScheduleBlocks = prebidBlocks + auctionDurationBlocks + 1;
        require(auctionScheduleBlocks <= type(uint64).max, "AUCTION_STEPS_TOO_LARGE");
        uint256 auctionStartBlockOffset = vm.envOr("CCA_START_BLOCK_OFFSET", DEFAULT_AUCTION_START_BLOCK_OFFSET);
        require(auctionStartBlockOffset <= type(uint64).max, "AUCTION_START_OFFSET_TOO_LARGE");
        require(block.number <= type(uint64).max, "BLOCK_TOO_LARGE");
        require(
            block.number + auctionStartBlockOffset + auctionScheduleBlocks <= type(uint64).max,
            "AUCTION_END_BLOCK_TOO_LARGE"
        );

        cfg.revenueShareFactory = vm.envAddress("AUTOLAUNCH_REVENUE_SHARE_FACTORY_ADDRESS");
        require(cfg.revenueShareFactory != address(0), "REVENUE_SHARE_FACTORY_ZERO");

        cfg.revenueIngressFactory = vm.envAddress("AUTOLAUNCH_REVENUE_INGRESS_FACTORY_ADDRESS");
        require(cfg.revenueIngressFactory != address(0), "REVENUE_INGRESS_FACTORY_ZERO");

        cfg.strategyFactory = vm.envAddress("AUTOLAUNCH_LBP_STRATEGY_FACTORY_ADDRESS");
        require(cfg.strategyFactory != address(0), "STRATEGY_FACTORY_ZERO");

        cfg.tokenFactory = vm.envAddress("AUTOLAUNCH_TOKEN_FACTORY_ADDRESS");
        require(cfg.tokenFactory != address(0), "TOKEN_FACTORY_ZERO");

        cfg.auctionInitializerFactory = vm.envAddress("AUTOLAUNCH_CCA_FACTORY_ADDRESS");
        require(cfg.auctionInitializerFactory != address(0), "AUCTION_FACTORY_ZERO");
        require(cfg.auctionInitializerFactory.code.length > 0, "AUCTION_FACTORY_NOT_DEPLOYED");

        cfg.poolManager = vm.envAddress("AUTOLAUNCH_UNISWAP_V4_POOL_MANAGER");
        require(cfg.poolManager != address(0), "POOL_MANAGER_ZERO");

        cfg.positionManager = vm.envAddress("AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER");
        require(cfg.positionManager != address(0), "POSITION_MANAGER_ZERO");

        cfg.usdcToken = vm.envAddress("AUTOLAUNCH_USDC_ADDRESS");
        require(cfg.usdcToken != address(0), "USDC_ZERO");
        _requireBaseMainnetUsdc(cfg.usdcToken);

        cfg.identityRegistry = vm.envOr("AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS", address(0));
        bool hasIdentityLink = cfg.identityRegistry != address(0) || cfg.agentId != 0;
        if (hasIdentityLink) {
            require(cfg.identityRegistry != address(0), "IDENTITY_REGISTRY_ZERO");
            require(cfg.agentId != 0, "AGENT_ID_ZERO");
        }

        cfg.regentRecipient = vm.envAddress("REGENT_MULTISIG_ADDRESS");
        require(cfg.regentRecipient != address(0), "REGENT_RECIPIENT_ZERO");

        cfg.factoryOwner = vm.envAddress("AUTOLAUNCH_FACTORY_OWNER_ADDRESS");
        require(cfg.factoryOwner != address(0), "FACTORY_OWNER_ZERO");

        cfg.validationHook = vm.envOr("CCA_VALIDATION_HOOK", address(0));
        cfg.auctionTickSpacing = vm.envUint("CCA_TICK_SPACING_Q96");
        cfg.floorPrice = vm.envUint("CCA_FLOOR_PRICE_Q96");
        uint256 requiredCurrencyRaisedRaw = vm.envOr("CCA_REQUIRED_CURRENCY_RAISED", uint256(0));
        require(requiredCurrencyRaisedRaw <= type(uint128).max, "REQUIRED_RAISED_TOO_LARGE");

        uint64 claimBlockOffset = _toUint64(vm.envOr("CCA_CLAIM_BLOCK_OFFSET", uint256(DEFAULT_CLAIM_BLOCK_OFFSET)));
        uint64 migrationBlockOffset =
            _toUint64(vm.envOr("LBP_MIGRATION_BLOCK_OFFSET", uint256(DEFAULT_MIGRATION_BLOCK_OFFSET)));
        uint64 sweepBlockOffset = _toUint64(vm.envOr("LBP_SWEEP_BLOCK_OFFSET", uint256(DEFAULT_SWEEP_BLOCK_OFFSET)));

        uint64 vestingStartTimestamp = _toUint64(vm.envOr("VESTING_START_TIMESTAMP", uint256(block.timestamp)));
        uint64 vestingDurationSeconds =
            _toUint64(vm.envOr("VESTING_DURATION_SECONDS", uint256(DEFAULT_VESTING_DURATION_SECONDS)));

        cfg.positionRecipient = cfg.agentSafe;
        uint256 startBlockRaw = block.number + auctionStartBlockOffset;
        uint256 endBlockRaw = startBlockRaw + auctionScheduleBlocks;
        uint256 claimBlockRaw = endBlockRaw + claimBlockOffset;
        cfg.startBlock = _toUint64(startBlockRaw);
        cfg.endBlock = _toUint64(endBlockRaw);
        cfg.claimBlock = _toUint64(claimBlockRaw);
        cfg.migrationBlock = cfg.endBlock + migrationBlockOffset;
        cfg.sweepBlock = cfg.migrationBlock + sweepBlockOffset;
        cfg.vestingStartTimestamp = vestingStartTimestamp;
        cfg.vestingDurationSeconds = vestingDurationSeconds;
        cfg.requiredCurrencyRaised = _toUint128(requiredCurrencyRaisedRaw);
        cfg.auctionStepsData = _convexAuctionSteps(auctionDurationBlocks, prebidBlocks, finalBlockBps);
        cfg.tokenName = vm.envOr("AUTOLAUNCH_TOKEN_NAME", string("Regent Agent Token"));
        cfg.tokenSymbol = vm.envOr("AUTOLAUNCH_TOKEN_SYMBOL", string("RAGENT"));
        cfg.tokenDescription = vm.envOr("AUTOLAUNCH_TOKEN_METADATA_DESCRIPTION", string(""));
        cfg.tokenWebsite = vm.envOr("AUTOLAUNCH_TOKEN_METADATA_WEBSITE", string(""));
        cfg.tokenImage = vm.envOr("AUTOLAUNCH_TOKEN_METADATA_IMAGE", string(""));
        cfg.subjectLabel = vm.envOr("AUTOLAUNCH_SUBJECT_LABEL", cfg.tokenName);
        _validateCcaConfig(cfg, auctionScheduleBlocks);
        _requireUerc20FactoryShape(cfg);
    }

    function _requireBaseMainnetUsdc(address usdc) internal view {
        require(block.chainid == BASE_MAINNET_CHAIN_ID, "BASE_MAINNET_ONLY");
        BaseUsdc.requireCanonical(usdc);
    }

    function deployFromEnv() external returns (LaunchDeploymentController.DeploymentResult memory result) {
        return _deployFromEnv();
    }

    function _deployFromEnv() internal returns (LaunchDeploymentController.DeploymentResult memory result) {
        ScriptConfig memory cfg = _loadConfig();

        return _deploy(cfg);
    }

    function _deploy(ScriptConfig memory cfg)
        internal
        returns (LaunchDeploymentController.DeploymentResult memory result)
    {
        _requireFactoryOwner(cfg);
        if (cfg.feeInfraDeployer == address(0)) {
            cfg.feeInfraDeployer = address(new LaunchFeeInfraDeployer());
        }
        LaunchDeploymentController controller = new LaunchDeploymentController();
        RevenueShareFactory(cfg.revenueShareFactory).setAuthorizedCreator(address(controller), true);
        RevenueIngressFactory(cfg.revenueIngressFactory).setAuthorizedCreator(address(controller), true);
        RegentLBPStrategyFactory(cfg.strategyFactory).setAuthorizedCreator(address(controller), true);
        LaunchDeploymentController.DeploymentConfig memory deployCfg = _controllerConfig(cfg);
        (bytes32 launchId,) = controller.prepareLaunch(deployCfg);
        controller.deployLaunchFeeInfra(launchId, deployCfg);
        result = controller.finalizeLaunch(launchId, deployCfg);
        RevenueShareFactory(cfg.revenueShareFactory).setAuthorizedCreator(address(controller), false);
        RevenueIngressFactory(cfg.revenueIngressFactory).setAuthorizedCreator(address(controller), false);
        RegentLBPStrategyFactory(cfg.strategyFactory).setAuthorizedCreator(address(controller), false);
    }

    function _controllerConfig(ScriptConfig memory cfg)
        internal
        pure
        returns (LaunchDeploymentController.DeploymentConfig memory deployCfg)
    {
        deployCfg.agentSafe = cfg.agentSafe;
        deployCfg.feeInfraDeployer = cfg.feeInfraDeployer;
        deployCfg.revenueShareFactory = cfg.revenueShareFactory;
        deployCfg.revenueIngressFactory = cfg.revenueIngressFactory;
        deployCfg.identityRegistry = cfg.identityRegistry;
        deployCfg.tokenFactory = cfg.tokenFactory;
        deployCfg.strategyFactory = cfg.strategyFactory;
        deployCfg.auctionInitializerFactory = cfg.auctionInitializerFactory;
        deployCfg.poolManager = cfg.poolManager;
        deployCfg.positionManager = cfg.positionManager;
        deployCfg.positionRecipient = cfg.positionRecipient;
        deployCfg.strategyOperator = cfg.strategyOperator;
        deployCfg.usdcToken = cfg.usdcToken;
        deployCfg.regentRecipient = cfg.regentRecipient;
        deployCfg.validationHook = cfg.validationHook;
        deployCfg.identityAgentId = cfg.agentId;
        deployCfg.totalSupply = cfg.totalSupply;
        deployCfg.officialPoolFee = cfg.officialPoolFee;
        deployCfg.officialPoolTickSpacing = cfg.officialPoolTickSpacing;
        deployCfg.auctionTickSpacing = cfg.auctionTickSpacing;
        deployCfg.startBlock = cfg.startBlock;
        deployCfg.endBlock = cfg.endBlock;
        deployCfg.claimBlock = cfg.claimBlock;
        deployCfg.migrationBlock = cfg.migrationBlock;
        deployCfg.sweepBlock = cfg.sweepBlock;
        deployCfg.vestingStartTimestamp = cfg.vestingStartTimestamp;
        deployCfg.vestingDurationSeconds = cfg.vestingDurationSeconds;
        deployCfg.floorPrice = cfg.floorPrice;
        deployCfg.requiredCurrencyRaised = cfg.requiredCurrencyRaised;
        deployCfg.auctionStepsData = cfg.auctionStepsData;
        deployCfg.tokenName = cfg.tokenName;
        deployCfg.tokenSymbol = cfg.tokenSymbol;
        deployCfg.subjectLabel = cfg.subjectLabel;
        deployCfg.tokenFactoryData = _tokenFactoryData(cfg);
        deployCfg.tokenFactoryGraffiti = _tokenFactoryGraffiti(cfg);
        deployCfg.launchFeeHookSalt = _launchFeeHookSalt(cfg.feeInfraDeployer, cfg.poolManager);
    }

    function _tokenFactoryData(ScriptConfig memory cfg) internal pure returns (bytes memory) {
        return abi.encode(
            UERC20Metadata({description: cfg.tokenDescription, website: cfg.tokenWebsite, image: cfg.tokenImage})
        );
    }

    function _tokenFactoryGraffiti(ScriptConfig memory cfg) internal pure returns (bytes32) {
        return keccak256(abi.encode(cfg.agentSafe));
    }

    function _requireUerc20FactoryShape(ScriptConfig memory cfg) internal view {
        require(cfg.tokenFactory.code.length > 0, "TOKEN_FACTORY_NOT_DEPLOYED");

        try IUERC20FactoryShape(cfg.tokenFactory)
            .getUERC20Address(cfg.tokenName, cfg.tokenSymbol, 18, address(this), _tokenFactoryGraffiti(cfg)) returns (
            address predicted
        ) {
            require(predicted != address(0), "TOKEN_FACTORY_UERC20_ZERO");
        } catch {
            revert("TOKEN_FACTORY_NOT_UERC20");
        }
    }

    function _validateCcaConfig(ScriptConfig memory cfg, uint256 auctionDurationBlocks) internal pure {
        require(cfg.startBlock < cfg.endBlock, "START_BLOCK_INVALID");
        require(cfg.endBlock <= cfg.claimBlock, "CLAIM_BEFORE_END");
        require(cfg.migrationBlock > cfg.endBlock, "MIGRATION_BEFORE_END");
        require(cfg.sweepBlock > cfg.migrationBlock, "SWEEP_BEFORE_MIGRATION");
        require(cfg.floorPrice > 0, "FLOOR_PRICE_ZERO");
        require(cfg.auctionTickSpacing > 0, "AUCTION_TICK_SPACING_ZERO");
        require(cfg.floorPrice % cfg.auctionTickSpacing == 0, "FLOOR_PRICE_TICK_MISALIGNED");
        require(cfg.auctionTickSpacing >= cfg.floorPrice / 10_000, "AUCTION_TICK_SPACING_TOO_SMALL");
        _validateAuctionStepsData(cfg.auctionStepsData, auctionDurationBlocks);
    }

    function _launchFeeHookSalt(address feeInfraDeployer, address poolManager)
        internal
        pure
        returns (bytes32 hookSalt)
    {
        address launchFeeRegistry = vm.computeCreateAddress(feeInfraDeployer, 1);
        address feeVault = vm.computeCreateAddress(feeInfraDeployer, 2);

        (hookSalt,) = HookMiner.find(
            feeInfraDeployer,
            REQUIRED_HOOK_FLAGS,
            type(LaunchPoolFeeHook).creationCode,
            abi.encode(feeInfraDeployer, poolManager, launchFeeRegistry, feeVault)
        );
    }

    function _requireFactoryOwner(ScriptConfig memory cfg) internal view {
        require(RevenueShareFactory(cfg.revenueShareFactory).owner() == cfg.factoryOwner, "REVENUE_SHARE_FACTORY_OWNER");
        require(
            RevenueShareFactory(cfg.revenueShareFactory).pendingOwner() == address(0),
            "REVENUE_SHARE_FACTORY_PENDING_OWNER"
        );
        require(
            RevenueIngressFactory(cfg.revenueIngressFactory).owner() == cfg.factoryOwner,
            "REVENUE_INGRESS_FACTORY_OWNER"
        );
        require(
            RevenueIngressFactory(cfg.revenueIngressFactory).pendingOwner() == address(0),
            "REVENUE_INGRESS_FACTORY_PENDING_OWNER"
        );
        require(RegentLBPStrategyFactory(cfg.strategyFactory).owner() == cfg.factoryOwner, "STRATEGY_FACTORY_OWNER");
        require(
            RegentLBPStrategyFactory(cfg.strategyFactory).pendingOwner() == address(0), "STRATEGY_FACTORY_PENDING_OWNER"
        );
    }

    function run() external {
        ScriptConfig memory cfg = _loadConfig();

        vm.startBroadcast(cfg.factoryOwner);

        LaunchDeploymentController.DeploymentResult memory result = _deploy(cfg);
        address factoryAddress = cfg.auctionInitializerFactory;
        address broadcaster = cfg.factoryOwner;

        _logDeploymentResult(factoryAddress, broadcaster, result);

        vm.stopBroadcast();
    }

    function _parseAgentId(string memory raw) internal pure returns (uint256) {
        bytes memory rawBytes = bytes(raw);
        if (rawBytes.length == 0) return 0;

        for (uint256 i; i < rawBytes.length; ++i) {
            if (rawBytes[i] == ":") {
                return _parseUint(_slice(rawBytes, i + 1, rawBytes.length));
            }
        }

        return _parseUint(rawBytes);
    }

    function _parseUint(bytes memory data) internal pure returns (uint256 value) {
        uint256 length = data.length;
        if (length == 0) return 0;

        for (uint256 i; i < length; ++i) {
            uint8 charCode = uint8(data[i]);
            if (charCode < 48 || charCode > 57) {
                return 0;
            }
            value = value * 10 + (charCode - 48);
        }
    }

    function _slice(bytes memory data, uint256 start, uint256 end) internal pure returns (bytes memory out) {
        out = new bytes(end - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[start + i];
        }
    }

    function _toUint24(uint256 value) internal pure returns (uint24) {
        require(value <= type(uint24).max, "UINT24_OVERFLOW");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(value);
    }

    function _toInt24(int256 value) internal pure returns (int24) {
        require(value >= type(int24).min, "INT24_UNDERFLOW");
        require(value <= type(int24).max, "INT24_OVERFLOW");
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(value);
    }

    function _toUint64(uint256 value) internal pure returns (uint64) {
        require(value <= type(uint64).max, "UINT64_OVERFLOW");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(value);
    }

    function _toUint128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, "UINT128_OVERFLOW");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }

    function _toUint40(uint256 value) internal pure returns (uint40) {
        require(value <= type(uint40).max, "UINT40_OVERFLOW");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint40(value);
    }

    function _convexAuctionSteps(uint256 durationBlocks, uint256 prebidBlocks, uint256 finalBlockBps)
        internal
        pure
        returns (bytes memory steps)
    {
        require(durationBlocks > 0, "AUCTION_DURATION_ZERO");
        require(durationBlocks <= type(uint40).max, "AUCTION_DURATION_TOO_LARGE");
        require(prebidBlocks <= type(uint40).max, "PREBID_BLOCKS_TOO_LARGE");
        require(
            finalBlockBps >= MIN_CCA_FINAL_BLOCK_BPS && finalBlockBps <= MAX_CCA_FINAL_BLOCK_BPS,
            "CCA_FINAL_BLOCK_BPS_INVALID"
        );

        uint256 targetFinalMps = (MPS_TOTAL * finalBlockBps) / BPS_DENOMINATOR;
        uint256 gradualMps = MPS_TOTAL - targetFinalMps;
        uint256 scheduledMps;
        uint256 previousBoundaryBlocks;

        steps = AuctionStepsBuilder.init();

        if (prebidBlocks != 0) {
            steps = steps.addStep(0, _toUint40(prebidBlocks));
        }

        for (uint256 step = 1; step <= CONVEX_STEP_COUNT; ++step) {
            uint256 boundaryBlocks = _roundDiv(durationBlocks * _convexBoundaryAt(step), CONVEX_CURVE_SCALE);
            require(boundaryBlocks > previousBoundaryBlocks, "AUCTION_STEP_BLOCKS_ZERO");

            uint256 blockDelta = boundaryBlocks - previousBoundaryBlocks;
            uint256 stepMps = _roundDiv(gradualMps, CONVEX_STEP_COUNT * blockDelta);
            require(stepMps != 0, "AUCTION_DURATION_TOO_LONG");

            scheduledMps += stepMps * blockDelta;
            require(scheduledMps < MPS_TOTAL, "AUCTION_STEPS_MPS_OVERFLOW");

            steps = steps.addStep(_toUint24(stepMps), _toUint40(blockDelta));
            previousBoundaryBlocks = boundaryBlocks;
        }

        require(previousBoundaryBlocks == durationBlocks, "AUCTION_STEPS_BLOCKS");

        uint256 finalMps = MPS_TOTAL - scheduledMps;
        require(finalMps != 0, "FINAL_BLOCK_MPS_ZERO");
        steps = steps.addStep(_toUint24(finalMps), 1);
    }

    function _convexBoundaryAt(uint256 step) internal pure returns (uint256) {
        if (step == 1) return 126_090_479_119;
        if (step == 2) return 224_667_692_433;
        if (step == 3) return 314_980_262_474;
        if (step == 4) return 400_312_318_392;
        if (step == 5) return 482_122_387_529;
        if (step == 6) return 561_231_024_155;
        if (step == 7) return 638_161_590_787;
        if (step == 8) return 713_275_462_622;
        if (step == 9) return 786_836_297_566;
        if (step == 10) return 859_044_434_072;
        if (step == 11) return 930_056_928_912;
        if (step == 12) return CONVEX_CURVE_SCALE;
        revert("CONVEX_STEP_INVALID");
    }

    function _roundDiv(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        require(denominator != 0, "DIV_ZERO");
        return (numerator + denominator / 2) / denominator;
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

    function _logDeploymentResult(
        address factoryAddress,
        address broadcaster,
        LaunchDeploymentController.DeploymentResult memory result
    ) internal pure {
        console2.log("Factory used:", factoryAddress);
        console2.log("Broadcaster used:", broadcaster);
        console2.log("Token deployed to:", result.tokenAddress);
        console2.log("Auction deployed to:", result.auctionAddress);
        console2.log("Strategy deployed to:", result.strategyAddress);
        console2.log("Vesting wallet deployed to:", result.vestingWalletAddress);
        console2.log("Fee hook deployed to:", result.hookAddress);
        console2.log("Launch fee registry deployed to:", result.launchFeeRegistryAddress);
        console2.log("Launch fee vault deployed to:", result.feeVaultAddress);
        console2.log("Subject registry used:", result.subjectRegistryAddress);
        console2.log("Revenue share splitter deployed to:", result.revenueShareSplitterAddress);
        console2.log("Default ingress deployed to:", result.defaultIngressAddress);
        console2.log(_resultJson(factoryAddress, result));
    }

    function _resultJson(address factoryAddress, LaunchDeploymentController.DeploymentResult memory result)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "CCA_RESULT_JSON:{\"factoryAddress\":\"",
            vm.toString(factoryAddress),
            "\",\"auctionAddress\":\"",
            vm.toString(result.auctionAddress),
            "\",\"tokenAddress\":\"",
            vm.toString(result.tokenAddress),
            "\",\"strategyAddress\":\"",
            vm.toString(result.strategyAddress),
            "\",\"vestingWalletAddress\":\"",
            vm.toString(result.vestingWalletAddress),
            "\",\"hookAddress\":\"",
            vm.toString(result.hookAddress),
            "\",\"launchFeeRegistryAddress\":\"",
            vm.toString(result.launchFeeRegistryAddress),
            "\",\"feeVaultAddress\":\"",
            vm.toString(result.feeVaultAddress),
            "\",\"subjectRegistryAddress\":\"",
            vm.toString(result.subjectRegistryAddress),
            "\",\"subjectId\":\"",
            vm.toString(result.subjectId),
            "\",\"revenueShareSplitterAddress\":\"",
            vm.toString(result.revenueShareSplitterAddress),
            "\",\"defaultIngressAddress\":\"",
            vm.toString(result.defaultIngressAddress),
            "\",\"poolId\":\"",
            vm.toString(result.poolId),
            "\"}"
        );
    }
}
