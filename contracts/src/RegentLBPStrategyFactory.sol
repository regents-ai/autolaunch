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
        address agentSafe;
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
                    RegentLBPStrategy.StrategyConfig({
                        token: token,
                        usdc: cfg.usdc,
                        auctionInitializerFactory: cfg.auctionInitializerFactory,
                        auctionParameters: cfg.auctionParameters,
                        officialPoolHook: cfg.officialPoolHook,
                        agentSafe: cfg.agentSafe,
                        vestingWallet: cfg.vestingWallet,
                        operator: cfg.operator,
                        positionRecipient: cfg.positionRecipient,
                        positionManager: cfg.positionManager,
                        poolManager: cfg.poolManager,
                        officialPoolFee: cfg.officialPoolFee,
                        officialPoolTickSpacing: cfg.officialPoolTickSpacing,
                        migrationBlock: cfg.migrationBlock,
                        sweepBlock: cfg.sweepBlock,
                        lpCurrencyBps: cfg.lpCurrencyBps,
                        tokenSplitToAuctionMps: cfg.tokenSplitToAuctionMps,
                        totalStrategySupply: uint128(amount),
                        auctionTokenAmount: cfg.auctionTokenAmount,
                        reserveTokenAmount: cfg.reserveTokenAmount,
                        maxCurrencyAmountForLP: cfg.maxCurrencyAmountForLP
                    })
                )
            )
        );

        emit DistributionInitialized(address(distributionContract), token, amount);
        emit RegentStrategyCreated(address(distributionContract), token, amount);
    }
}
