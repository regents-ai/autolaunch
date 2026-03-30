// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {AuctionParameters} from "src/cca/interfaces/IContinuousClearingAuction.sol";
import {RegentLBPStrategy} from "src/RegentLBPStrategy.sol";
import {RegentLBPStrategyFactory} from "src/RegentLBPStrategyFactory.sol";

contract RegentLBPStrategyFactoryTest is Test {
    function testInitializeDistributionCreatesStrategy() external {
        RegentLBPStrategyFactory factory = new RegentLBPStrategyFactory();

        RegentLBPStrategyFactory.RegentLBPStrategyConfig memory cfg =
            RegentLBPStrategyFactory.RegentLBPStrategyConfig({
                usdc: address(0x2222),
                auctionInitializerFactory: address(0x3333),
                auctionParameters: AuctionParameters({
                    currency: address(0x2222),
                    tokensRecipient: address(0),
                    fundsRecipient: address(0),
                    startBlock: 1,
                    endBlock: 10,
                    claimBlock: 10,
                    tickSpacing: 100,
                    validationHook: address(0),
                    floorPrice: 100,
                    requiredCurrencyRaised: 0,
                    auctionStepsData: bytes("")
                }),
                officialPoolHook: address(0x4444),
                agentTreasurySafe: address(0x5555),
                vestingWallet: address(0x6666),
                operator: address(0x7777),
                positionRecipient: address(0x8888),
                positionManager: address(0x9999),
                poolManager: address(0xAAAA),
                officialPoolFee: 3000,
                officialPoolTickSpacing: 60,
                migrationBlock: 20,
                sweepBlock: 30,
                lpCurrencyBps: 5000,
                tokenSplitToAuctionMps: 6_666_666,
                auctionTokenAmount: 100,
                reserveTokenAmount: 50,
                maxCurrencyAmountForLP: 1000
            });

        address strategyAddress = address(
            factory.initializeDistribution(address(0x1111), 150, abi.encode(cfg), bytes32(0))
        );

        RegentLBPStrategy strategy = RegentLBPStrategy(strategyAddress);
        assertEq(strategy.token(), address(0x1111));
        assertEq(strategy.usdc(), address(0x2222));
        assertEq(strategy.auctionInitializerFactory(), address(0x3333));
        assertEq(strategy.agentTreasurySafe(), address(0x5555));
        assertEq(strategy.vestingWallet(), address(0x6666));
        assertEq(strategy.operator(), address(0x7777));
        assertEq(strategy.officialPoolFee(), 3000);
        assertEq(strategy.officialPoolTickSpacing(), 60);
        assertEq(strategy.totalStrategySupply(), 150);
        assertEq(strategy.auctionTokenAmount(), 100);
        assertEq(strategy.reserveTokenAmount(), 50);
    }
}
