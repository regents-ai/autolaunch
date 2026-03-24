// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {LaunchDeploymentController} from "src/LaunchDeploymentController.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";

contract ExampleCCADeploymentScript is Script {
    struct ScriptConfig {
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
        address validationHook;
        uint256 agentId;
        uint256 totalSupply;
        uint24 poolFee;
        int24 poolTickSpacing;
        uint256 auctionTickSpacing;
        uint24 stepMps;
        uint40 stepBlockDelta;
        uint64 startBlock;
        uint64 endBlock;
        uint64 claimBlock;
        uint256 floorPrice;
        uint128 requiredCurrencyRaised;
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
    uint256 internal constant DEFAULT_AUCTION_DURATION_BLOCKS = 21_600;
    uint256 internal constant DEFAULT_STEP_MPS = 100_000;
    uint256 internal constant DEFAULT_STEP_BLOCK_DELTA = 216;
    uint24 internal constant DEFAULT_POOL_FEE = 0;
    int24 internal constant DEFAULT_POOL_TICK_SPACING = 60;
    uint16 internal constant DEFAULT_PROTOCOL_SKIM_BPS = 100;
    uint256 internal constant MPS_TOTAL = 10_000_000;

    function _loadConfig() internal view returns (ScriptConfig memory cfg) {
        address recoverySafe = _envAddressOr(
            "AUTOLAUNCH_RECOVERY_SAFE_ADDRESS", _envAddressOr("RECOVERY_SAFE_ADDRESS", address(0))
        );
        require(recoverySafe != address(0), "RECOVERY_SAFE_ZERO");

        uint256 totalSupply =
            vm.envOr("TOTAL_SUPPLY", vm.envOr("AUTOLAUNCH_TOTAL_SUPPLY", DEFAULT_TOTAL_SUPPLY));
        require(totalSupply > 0, "TOTAL_SUPPLY_ZERO");

        uint256 agentId =
            _parseAgentId(vm.envOr("AUTOLAUNCH_AGENT_ID", vm.envOr("AGENT_ID", string(""))));
        require(agentId > 0, "AGENT_ID_ZERO");

        address auctionProceedsRecipient = _envAddressOr(
            "AUTOLAUNCH_AUCTION_PROCEEDS_RECIPIENT",
            _envAddressOr("AUCTION_PROCEEDS_RECIPIENT", recoverySafe)
        );
        require(auctionProceedsRecipient != address(0), "AUCTION_RECIPIENT_ZERO");

        address agentRevenueTreasury = _envAddressOr(
            "AUTOLAUNCH_ETHEREUM_REVENUE_TREASURY",
            _envAddressOr("ETHEREUM_REVENUE_TREASURY", recoverySafe)
        );
        require(agentRevenueTreasury != address(0), "AGENT_TREASURY_ZERO");

        address emissionRecipient = _envAddressOr(
            "AUTOLAUNCH_EMISSION_RECIPIENT",
            _envAddressOr(
                "AUTOLAUNCH_BASE_EMISSION_RECIPIENT",
                _envAddressOr("EMISSION_RECIPIENT", recoverySafe)
            )
        );
        require(emissionRecipient != address(0), "EMISSION_RECIPIENT_ZERO");

        uint256 poolFeeRaw = vm.envOr("OFFICIAL_POOL_FEE", uint256(DEFAULT_POOL_FEE));
        require(poolFeeRaw <= 1_000_000, "POOL_FEE_INVALID");

        int256 poolTickSpacingRaw =
            vm.envOr("OFFICIAL_POOL_TICK_SPACING", int256(DEFAULT_POOL_TICK_SPACING));
        require(poolTickSpacingRaw > 0, "POOL_TICK_SPACING_INVALID");
        require(poolTickSpacingRaw <= type(int24).max, "POOL_TICK_SPACING_TOO_LARGE");

        uint256 auctionDurationBlocks =
            vm.envOr("AUCTION_DURATION_BLOCKS", DEFAULT_AUCTION_DURATION_BLOCKS);
        require(auctionDurationBlocks > 0, "AUCTION_DURATION_ZERO");
        require(auctionDurationBlocks <= type(uint40).max, "AUCTION_DURATION_TOO_LARGE");

        uint256 stepMpsRaw = vm.envOr("CCA_STEP_MPS", DEFAULT_STEP_MPS);
        require(stepMpsRaw > 0, "STEP_MPS_ZERO");
        require(stepMpsRaw <= type(uint24).max, "STEP_MPS_TOO_LARGE");

        uint256 stepBlockDeltaRaw = vm.envOr("CCA_STEP_BLOCK_DELTA", DEFAULT_STEP_BLOCK_DELTA);
        require(stepBlockDeltaRaw > 0, "STEP_DELTA_ZERO");
        require(stepBlockDeltaRaw <= type(uint40).max, "STEP_DELTA_TOO_LARGE");
        require(MPS_TOTAL % stepMpsRaw == 0, "INVALID_STEP_DATA_MPS");
        require(
            auctionDurationBlocks == (MPS_TOTAL / stepMpsRaw) * stepBlockDeltaRaw,
            "AUCTION_DURATION_MISMATCH"
        );
        require(block.number <= type(uint64).max, "BLOCK_TOO_LARGE");
        require(
            block.number + auctionDurationBlocks <= type(uint64).max, "AUCTION_END_BLOCK_TOO_LARGE"
        );

        address revenueShareFactory = vm.envAddress("REVENUE_SHARE_FACTORY_ADDRESS");
        require(revenueShareFactory != address(0), "REVENUE_SHARE_FACTORY_ZERO");

        address factoryAddress = vm.envOr("FACTORY_ADDRESS", _defaultFactoryForChain(block.chainid));
        require(factoryAddress != address(0), "FACTORY_ZERO");
        require(factoryAddress.code.length > 0, "FACTORY_NOT_DEPLOYED");

        address poolManager = vm.envAddress("UNISWAP_V4_POOL_MANAGER");
        require(poolManager != address(0), "POOL_MANAGER_ZERO");

        address usdcToken =
            _envAddressOr("ETHEREUM_USDC_ADDRESS", _envAddressOr("USDC_ADDRESS", address(0)));
        require(usdcToken != address(0), "USDC_ZERO");

        address identityRegistry = _envAddressOr(
            "AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS", _defaultIdentityRegistryForChain(block.chainid)
        );
        require(identityRegistry != address(0), "IDENTITY_REGISTRY_ZERO");

        address regentRecipient = _envAddressOr("REGENT_MULTISIG_ADDRESS", REGENT_MULTISIG);
        require(regentRecipient != address(0), "REGENT_RECIPIENT_ZERO");

        address mainnetEmissionsController =
            _envAddressOr("MAINNET_REGENT_EMISSIONS_CONTROLLER_ADDRESS", address(0));
        if (block.chainid == 1) {
            require(mainnetEmissionsController != address(0), "MAINNET_EMISSIONS_CONTROLLER_ZERO");
        }

        address validationHook = _envAddressOr("CCA_VALIDATION_HOOK", address(0));
        uint256 auctionTickSpacing = vm.envUint("CCA_TICK_SPACING_Q96");
        uint256 floorPrice = vm.envUint("CCA_FLOOR_PRICE_Q96");
        uint256 requiredCurrencyRaisedRaw = vm.envUint("CCA_REQUIRED_CURRENCY_RAISED");
        require(requiredCurrencyRaisedRaw <= type(uint128).max, "REQUIRED_RAISED_TOO_LARGE");
        uint256 claimBlockOffset = vm.envOr("CCA_CLAIM_BLOCK_OFFSET", uint256(0));
        require(claimBlockOffset <= type(uint64).max, "CLAIM_BLOCK_OFFSET_TOO_LARGE");

        uint256 protocolSkimBpsRaw =
            vm.envOr("PROTOCOL_SKIM_BPS", uint256(DEFAULT_PROTOCOL_SKIM_BPS));
        require(protocolSkimBpsRaw <= type(uint16).max, "PROTOCOL_SKIM_BPS_TOO_LARGE");

        string memory tokenName =
            vm.envOr("AUTOLAUNCH_TOKEN_NAME", vm.envOr("AGENT_NAME", string("Regent Agent Token")));
        string memory tokenSymbol =
            vm.envOr("AUTOLAUNCH_TOKEN_SYMBOL", vm.envOr("AGENT_SYMBOL", string("RAGENT")));
        string memory subjectLabel = vm.envOr("AUTOLAUNCH_SUBJECT_LABEL", tokenName);

        cfg.recoverySafe = recoverySafe;
        cfg.auctionProceedsRecipient = auctionProceedsRecipient;
        cfg.agentRevenueTreasury = agentRevenueTreasury;
        cfg.revenueShareFactory = revenueShareFactory;
        cfg.identityRegistry = identityRegistry;
        cfg.factoryAddress = factoryAddress;
        cfg.poolManager = poolManager;
        cfg.usdcToken = usdcToken;
        cfg.regentRecipient = regentRecipient;
        cfg.mainnetEmissionsController = mainnetEmissionsController;
        cfg.emissionRecipient = emissionRecipient;
        cfg.validationHook = validationHook;
        cfg.agentId = agentId;
        cfg.totalSupply = totalSupply;
        cfg.poolFee = uint24(poolFeeRaw);
        cfg.poolTickSpacing = int24(poolTickSpacingRaw);
        cfg.auctionTickSpacing = auctionTickSpacing;
        cfg.stepMps = uint24(stepMpsRaw);
        cfg.stepBlockDelta = uint40(stepBlockDeltaRaw);
        cfg.startBlock = uint64(block.number);
        cfg.endBlock = uint64(block.number + auctionDurationBlocks);
        cfg.claimBlock = uint64(block.number + auctionDurationBlocks + claimBlockOffset);
        cfg.floorPrice = floorPrice;
        cfg.requiredCurrencyRaised = uint128(requiredCurrencyRaisedRaw);
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
        result = controller.deploy(
            LaunchDeploymentController.DeploymentConfig({
                recoverySafe: cfg.recoverySafe,
                auctionProceedsRecipient: cfg.auctionProceedsRecipient,
                agentRevenueTreasury: cfg.agentRevenueTreasury,
                revenueShareFactory: cfg.revenueShareFactory,
                identityRegistry: cfg.identityRegistry,
                factoryAddress: cfg.factoryAddress,
                poolManager: cfg.poolManager,
                usdcToken: cfg.usdcToken,
                regentRecipient: cfg.regentRecipient,
                mainnetEmissionsController: cfg.mainnetEmissionsController,
                emissionRecipient: cfg.emissionRecipient,
                identityAgentId: cfg.agentId,
                totalSupply: cfg.totalSupply,
                poolFee: cfg.poolFee,
                poolTickSpacing: cfg.poolTickSpacing,
                auctionTickSpacing: cfg.auctionTickSpacing,
                stepMps: cfg.stepMps,
                stepBlockDelta: cfg.stepBlockDelta,
                startBlock: cfg.startBlock,
                endBlock: cfg.endBlock,
                claimBlock: cfg.claimBlock,
                validationHook: cfg.validationHook,
                floorPrice: cfg.floorPrice,
                requiredCurrencyRaised: cfg.requiredCurrencyRaised,
                protocolSkimBps: cfg.protocolSkimBps,
                tokenName: cfg.tokenName,
                tokenSymbol: cfg.tokenSymbol,
                subjectLabel: cfg.subjectLabel
            })
        );
        RevenueShareFactory(cfg.revenueShareFactory)
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
        console2.log("Fee hook deployed to:", result.hookAddress);
        console2.log("Launch fee registry deployed to:", result.launchFeeRegistryAddress);
        console2.log("Launch fee vault deployed to:", result.feeVaultAddress);
        console2.log("Subject registry used:", result.subjectRegistryAddress);
        console2.log("Revenue share splitter deployed to:", result.revenueShareSplitterAddress);
        console2.log(
            string.concat(
                "CCA_RESULT_JSON:{\"factoryAddress\":\"",
                vm.toString(factoryAddress),
                "\",\"auctionAddress\":\"",
                vm.toString(result.auctionAddress),
                "\",\"tokenAddress\":\"",
                vm.toString(result.tokenAddress),
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
                "\",\"poolId\":\"",
                vm.toString(result.poolId),
                "\"}"
            )
        );

        vm.stopBroadcast();
    }

    function _envAddressOr(string memory key, address fallback_) internal view returns (address) {
        try vm.envAddress(key) returns (address value) {
            return value;
        } catch {
            return fallback_;
        }
    }

    function _defaultFactoryForChain(uint256 chainId) internal pure returns (address) {
        return chainId == 1 || chainId == 11_155_111 ? CANONICAL_CCA_FACTORY : address(0);
    }

    function _defaultIdentityRegistryForChain(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return ERC8004_MAINNET;
        if (chainId == 11_155_111) return ERC8004_SEPOLIA;
        return address(0);
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
        return _loadConfig().factoryAddress;
    }
}
