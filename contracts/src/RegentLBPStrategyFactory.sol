// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AuctionParameters} from "src/cca/interfaces/IContinuousClearingAuction.sol";
import {IDistributionContract} from "src/cca/interfaces/external/IDistributionContract.sol";
import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";
import {RegentLBPStrategy} from "src/RegentLBPStrategy.sol";

contract RegentLBPStrategyFactory is IDistributionStrategy {
    struct RegentLBPStrategyConfig {
        address usdc;
        address auctionInitializerFactory;
        AuctionParameters auctionParameters;
        address officialPoolHook;
        address agentTreasurySafe;
        address vestingWallet;
        address operator;
        address positionRecipient;
        address positionManager;
        address poolManager;
        uint24 officialPoolFee;
        int24 officialPoolTickSpacing;
        uint64 migrationBlock;
        uint64 sweepBlock;
        uint16 lpCurrencyBps;
        uint24 tokenSplitToAuctionMps;
        uint128 auctionTokenAmount;
        uint128 reserveTokenAmount;
        uint128 maxCurrencyAmountForLP;
    }

    event DistributionInitialized(
        address indexed distributionContract, address indexed token, uint256 amount
    );
    event RegentStrategyCreated(
        address indexed strategy, address indexed token, uint256 strategySupply
    );

    function initializeDistribution(
        address token,
        uint256 amount,
        bytes calldata configData,
        bytes32
    ) external returns (IDistributionContract distributionContract) {
        RegentLBPStrategyConfig memory cfg = abi.decode(configData, (RegentLBPStrategyConfig));
        require(amount <= type(uint128).max, "STRATEGY_SUPPLY_TOO_LARGE");

        distributionContract = IDistributionContract(
            address(
                new RegentLBPStrategy(
                    token,
                    cfg.usdc,
                    cfg.auctionInitializerFactory,
                    cfg.auctionParameters,
                    cfg.officialPoolHook,
                    cfg.agentTreasurySafe,
                    cfg.vestingWallet,
                    cfg.operator,
                    cfg.positionRecipient,
                    cfg.positionManager,
                    cfg.poolManager,
                    cfg.officialPoolFee,
                    cfg.officialPoolTickSpacing,
                    cfg.migrationBlock,
                    cfg.sweepBlock,
                    cfg.lpCurrencyBps,
                    cfg.tokenSplitToAuctionMps,
                    uint128(amount),
                    cfg.auctionTokenAmount,
                    cfg.reserveTokenAmount,
                    cfg.maxCurrencyAmountForLP
                )
            )
        );

        emit DistributionInitialized(address(distributionContract), token, amount);
        emit RegentStrategyCreated(address(distributionContract), token, amount);
    }
}
