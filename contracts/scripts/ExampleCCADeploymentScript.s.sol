// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {LaunchDeploymentController} from "src/LaunchDeploymentController.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";

contract ExampleCCADeploymentScript is Script {
    struct ScriptConfig {
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
        uint128 maxCurrencyAmountForLP;
        uint16 protocolSkimBps;
        string tokenName;
        string tokenSymbol;
        string subjectLabel;
    }

    address internal constant CANONICAL_CCA_FACTORY = 0xCCccCcCAE7503Cac057829BF2811De42E16e0bD5;
    address internal constant REGENT_MULTISIG = 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e;
    address internal constant ERC8004_MAINNET = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address internal constant ERC8004_SEPOLIA = 0x8004A818BFB912233c491871b3d84c89A494BD9e;

    uint256 internal constant DEFAULT_TOTAL_SUPPLY = 100_000_000_000e18;
    uint256 internal constant DEFAULT_AUCTION_DURATION_BLOCKS = 9258;
    uint24 internal constant DEFAULT_POOL_FEE = 0;
    int24 internal constant DEFAULT_POOL_TICK_SPACING = 60;
    uint16 internal constant DEFAULT_PROTOCOL_SKIM_BPS = 100;
    uint64 internal constant DEFAULT_CLAIM_BLOCK_OFFSET = 64;
    uint64 internal constant DEFAULT_MIGRATION_BLOCK_OFFSET = 128;
    uint64 internal constant DEFAULT_SWEEP_BLOCK_OFFSET = 256;
    uint64 internal constant DEFAULT_VESTING_DURATION_SECONDS = 365 days;
    uint256 internal constant ETHEREUM_SEPOLIA_CHAIN_ID = 11_155_111;

    function _loadConfig() internal view returns (ScriptConfig memory cfg) {
        require(block.chainid == ETHEREUM_SEPOLIA_CHAIN_ID, "SEPOLIA_ONLY");

        address recoverySafe = vm.envAddress("AUTOLAUNCH_RECOVERY_SAFE_ADDRESS");
        require(recoverySafe != address(0), "RECOVERY_SAFE_ZERO");

        uint256 totalSupply = vm.envOr("AUTOLAUNCH_TOTAL_SUPPLY", DEFAULT_TOTAL_SUPPLY);
        require(totalSupply > 0, "TOTAL_SUPPLY_ZERO");

        uint256 agentId = _parseAgentId(vm.envOr("AUTOLAUNCH_AGENT_ID", string("")));
        require(agentId > 0, "AGENT_ID_ZERO");

        address agentTreasurySafe = vm.envAddress("AUTOLAUNCH_ETHEREUM_REVENUE_TREASURY");
        require(agentTreasurySafe != address(0), "AGENT_TREASURY_ZERO");

        address positionRecipient = vm.envAddress("AUTOLAUNCH_AUCTION_PROCEEDS_RECIPIENT");
        require(positionRecipient != address(0), "POSITION_RECIPIENT_ZERO");

        address strategyOperator = vm.envAddress("STRATEGY_OPERATOR");
        require(strategyOperator != address(0), "STRATEGY_OPERATOR_ZERO");

        uint256 poolFeeRaw = vm.envOr("OFFICIAL_POOL_FEE", uint256(DEFAULT_POOL_FEE));
        require(poolFeeRaw <= 1_000_000, "POOL_FEE_INVALID");

        int256 poolTickSpacingRaw =
            vm.envOr("OFFICIAL_POOL_TICK_SPACING", int256(DEFAULT_POOL_TICK_SPACING));
        require(poolTickSpacingRaw > 0, "POOL_TICK_SPACING_INVALID");
        require(poolTickSpacingRaw <= type(int24).max, "POOL_TICK_SPACING_TOO_LARGE");

        uint256 auctionDurationBlocks =
            vm.envOr("AUCTION_DURATION_BLOCKS", DEFAULT_AUCTION_DURATION_BLOCKS);
        require(auctionDurationBlocks > 0, "AUCTION_DURATION_ZERO");
        require(auctionDurationBlocks <= type(uint64).max, "AUCTION_DURATION_TOO_LARGE");
        require(block.number <= type(uint64).max, "BLOCK_TOO_LARGE");
        require(
            block.number + auctionDurationBlocks <= type(uint64).max, "AUCTION_END_BLOCK_TOO_LARGE"
        );

        address revenueShareFactory = vm.envAddress("REVENUE_SHARE_FACTORY_ADDRESS");
        require(revenueShareFactory != address(0), "REVENUE_SHARE_FACTORY_ZERO");

        address revenueIngressFactory = vm.envAddress("REVENUE_INGRESS_FACTORY_ADDRESS");
        require(revenueIngressFactory != address(0), "REVENUE_INGRESS_FACTORY_ZERO");

        address strategyFactory = vm.envAddress("LBP_STRATEGY_FACTORY_ADDRESS");
        require(strategyFactory != address(0), "STRATEGY_FACTORY_ZERO");

        address tokenFactory = vm.envAddress("TOKEN_FACTORY_ADDRESS");
        require(tokenFactory != address(0), "TOKEN_FACTORY_ZERO");

        address auctionInitializerFactory = vm.envAddress("FACTORY_ADDRESS");
        require(auctionInitializerFactory != address(0), "AUCTION_FACTORY_ZERO");
        require(auctionInitializerFactory.code.length > 0, "AUCTION_FACTORY_NOT_DEPLOYED");

        address poolManager = vm.envAddress("UNISWAP_V4_POOL_MANAGER");
        require(poolManager != address(0), "POOL_MANAGER_ZERO");

        address positionManager = vm.envAddress("UNISWAP_V4_POSITION_MANAGER");
        require(positionManager != address(0), "POSITION_MANAGER_ZERO");

        address usdcToken = vm.envAddress("ETHEREUM_USDC_ADDRESS");
        require(usdcToken != address(0), "USDC_ZERO");

        address identityRegistry = vm.envAddress("AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS");
        require(identityRegistry != address(0), "IDENTITY_REGISTRY_ZERO");

        address regentRecipient = vm.envAddress("REGENT_MULTISIG_ADDRESS");
        require(regentRecipient != address(0), "REGENT_RECIPIENT_ZERO");

        address validationHook = vm.envOr("CCA_VALIDATION_HOOK", address(0));
        uint256 auctionTickSpacing = vm.envUint("CCA_TICK_SPACING_Q96");
        uint256 floorPrice = vm.envUint("CCA_FLOOR_PRICE_Q96");
        uint256 requiredCurrencyRaisedRaw = vm.envUint("CCA_REQUIRED_CURRENCY_RAISED");
        require(requiredCurrencyRaisedRaw <= type(uint128).max, "REQUIRED_RAISED_TOO_LARGE");

        uint64 claimBlockOffset =
            uint64(vm.envOr("CCA_CLAIM_BLOCK_OFFSET", uint256(DEFAULT_CLAIM_BLOCK_OFFSET)));
        uint64 migrationBlockOffset =
            uint64(vm.envOr("LBP_MIGRATION_BLOCK_OFFSET", uint256(DEFAULT_MIGRATION_BLOCK_OFFSET)));
        uint64 sweepBlockOffset =
            uint64(vm.envOr("LBP_SWEEP_BLOCK_OFFSET", uint256(DEFAULT_SWEEP_BLOCK_OFFSET)));

        uint64 vestingStartTimestamp =
            uint64(vm.envOr("VESTING_START_TIMESTAMP", uint256(block.timestamp)));
        uint64 vestingDurationSeconds =
            uint64(vm.envOr("VESTING_DURATION_SECONDS", uint256(DEFAULT_VESTING_DURATION_SECONDS)));

        uint256 maxCurrencyAmountForLPRaw =
            vm.envOr("MAX_CURRENCY_AMOUNT_FOR_LP", type(uint128).max);
        require(maxCurrencyAmountForLPRaw <= type(uint128).max, "MAX_CCY_FOR_LP_TOO_LARGE");

        uint256 protocolSkimBpsRaw =
            vm.envOr("PROTOCOL_SKIM_BPS", uint256(DEFAULT_PROTOCOL_SKIM_BPS));
        require(protocolSkimBpsRaw <= type(uint16).max, "PROTOCOL_SKIM_BPS_TOO_LARGE");

        string memory tokenName = vm.envOr("AUTOLAUNCH_TOKEN_NAME", string("Regent Agent Token"));
        string memory tokenSymbol = vm.envOr("AUTOLAUNCH_TOKEN_SYMBOL", string("RAGENT"));
        string memory subjectLabel = vm.envOr("AUTOLAUNCH_SUBJECT_LABEL", tokenName);

        cfg.recoverySafe = recoverySafe;
        cfg.agentTreasurySafe = agentTreasurySafe;
        cfg.revenueShareFactory = revenueShareFactory;
        cfg.revenueIngressFactory = revenueIngressFactory;
        cfg.identityRegistry = identityRegistry;
        cfg.tokenFactory = tokenFactory;
        cfg.strategyFactory = strategyFactory;
        cfg.auctionInitializerFactory = auctionInitializerFactory;
        cfg.poolManager = poolManager;
        cfg.positionManager = positionManager;
        cfg.positionRecipient = positionRecipient;
        cfg.strategyOperator = strategyOperator;
        cfg.usdcToken = usdcToken;
        cfg.regentRecipient = regentRecipient;
        cfg.validationHook = validationHook;
        cfg.agentId = agentId;
        cfg.totalSupply = totalSupply;
        cfg.officialPoolFee = uint24(poolFeeRaw);
        cfg.officialPoolTickSpacing = int24(poolTickSpacingRaw);
        cfg.auctionTickSpacing = auctionTickSpacing;
        cfg.startBlock = uint64(block.number);
        cfg.endBlock = uint64(block.number + auctionDurationBlocks);
        cfg.claimBlock = uint64(block.number + auctionDurationBlocks + claimBlockOffset);
        cfg.migrationBlock = cfg.endBlock + migrationBlockOffset;
        cfg.sweepBlock = cfg.migrationBlock + sweepBlockOffset;
        cfg.vestingStartTimestamp = vestingStartTimestamp;
        cfg.vestingDurationSeconds = vestingDurationSeconds;
        cfg.floorPrice = floorPrice;
        cfg.requiredCurrencyRaised = uint128(requiredCurrencyRaisedRaw);
        cfg.maxCurrencyAmountForLP = uint128(maxCurrencyAmountForLPRaw);
        cfg.protocolSkimBps = uint16(protocolSkimBpsRaw);
        cfg.tokenName = tokenName;
        cfg.tokenSymbol = tokenSymbol;
        cfg.subjectLabel = subjectLabel;
    }

    function deployFromEnv()
        external
        returns (LaunchDeploymentController.DeploymentResult memory result)
    {
        return _deployFromEnv();
    }

    function _deployFromEnv()
        internal
        returns (LaunchDeploymentController.DeploymentResult memory result)
    {
        ScriptConfig memory cfg = _loadConfig();

        LaunchDeploymentController controller = new LaunchDeploymentController();
        RevenueShareFactory(cfg.revenueShareFactory).setAuthorizedCreator(address(controller), true);
        RevenueIngressFactory(cfg.revenueIngressFactory)
            .setAuthorizedCreator(address(controller), true);
        result = controller.deploy(
            LaunchDeploymentController.DeploymentConfig({
                recoverySafe: cfg.recoverySafe,
                agentTreasurySafe: cfg.agentTreasurySafe,
                revenueShareFactory: cfg.revenueShareFactory,
                revenueIngressFactory: cfg.revenueIngressFactory,
                identityRegistry: cfg.identityRegistry,
                tokenFactory: cfg.tokenFactory,
                strategyFactory: cfg.strategyFactory,
                auctionInitializerFactory: cfg.auctionInitializerFactory,
                poolManager: cfg.poolManager,
                positionManager: cfg.positionManager,
                positionRecipient: cfg.positionRecipient,
                strategyOperator: cfg.strategyOperator,
                usdcToken: cfg.usdcToken,
                regentRecipient: cfg.regentRecipient,
                validationHook: cfg.validationHook,
                identityAgentId: cfg.agentId,
                totalSupply: cfg.totalSupply,
                officialPoolFee: cfg.officialPoolFee,
                officialPoolTickSpacing: cfg.officialPoolTickSpacing,
                auctionTickSpacing: cfg.auctionTickSpacing,
                startBlock: cfg.startBlock,
                endBlock: cfg.endBlock,
                claimBlock: cfg.claimBlock,
                migrationBlock: cfg.migrationBlock,
                sweepBlock: cfg.sweepBlock,
                vestingStartTimestamp: cfg.vestingStartTimestamp,
                vestingDurationSeconds: cfg.vestingDurationSeconds,
                floorPrice: cfg.floorPrice,
                requiredCurrencyRaised: cfg.requiredCurrencyRaised,
                maxCurrencyAmountForLP: cfg.maxCurrencyAmountForLP,
                protocolSkimBps: cfg.protocolSkimBps,
                tokenName: cfg.tokenName,
                tokenSymbol: cfg.tokenSymbol,
                subjectLabel: cfg.subjectLabel,
                tokenFactoryData: bytes(""),
                tokenFactorySalt: bytes32(0)
            })
        );
        RevenueShareFactory(cfg.revenueShareFactory)
            .setAuthorizedCreator(address(controller), false);
        RevenueIngressFactory(cfg.revenueIngressFactory)
            .setAuthorizedCreator(address(controller), false);
    }

    function run() external {
        vm.startBroadcast();

        LaunchDeploymentController.DeploymentResult memory result = _deployFromEnv();
        address factoryAddress = cfgFactoryAddress();
        address broadcaster = tx.origin;
        require(broadcaster != address(0), "BROADCASTER_ZERO");

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
        console2.log(
            string.concat(
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
            )
        );

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

    function _slice(bytes memory data, uint256 start, uint256 end)
        internal
        pure
        returns (bytes memory out)
    {
        out = new bytes(end - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[start + i];
        }
    }

    function cfgFactoryAddress() internal view returns (address) {
        return _loadConfig().auctionInitializerFactory;
    }
}
