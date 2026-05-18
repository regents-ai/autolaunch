// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {AuctionParameters} from "src/cca/interfaces/IContinuousClearingAuction.sol";
import {RegentLBPStrategy} from "src/RegentLBPStrategy.sol";
import {RegentLBPStrategyFactory} from "src/RegentLBPStrategyFactory.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";

contract RegentLBPStrategyFactoryTest is Test {
    address internal constant REGENT = 0x6f89bcA4eA5931EdFCB09786267b251DeE752b07;

    function setUp() external {
        vm.chainId(8453);
        MintableERC20Mock implementation = new MintableERC20Mock("REGENT", "REGENT");
        vm.etch(REGENT, address(implementation).code);
    }

    function testInitializeDistributionCreatesStrategy() external {
        RegentLBPStrategyFactory factory = new RegentLBPStrategyFactory(address(this));

        RegentLBPStrategyFactory.RegentLBPStrategyConfig memory cfg =
            RegentLBPStrategyFactory.RegentLBPStrategyConfig({
                quoteToken: REGENT,
                auctionInitializerFactory: address(0x3333),
                auctionParameters: AuctionParameters({
                    currency: REGENT,
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
                agentSafe: address(0x5555),
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
                reserveTokenAmount: 50
            });

        address strategyAddress = address(
            factory.initializeDistribution(address(0x1111), 150, abi.encode(cfg), bytes32(0))
        );

        RegentLBPStrategy strategy = RegentLBPStrategy(strategyAddress);
        assertEq(strategy.token(), address(0x1111));
        assertEq(strategy.quoteToken(), REGENT);
        assertEq(strategy.auctionInitializerFactory(), address(0x3333));
        assertEq(strategy.agentSafe(), address(0x5555));
        assertEq(strategy.vestingWallet(), address(0x6666));
        assertEq(strategy.auctionCreator(), address(this));
        assertEq(strategy.operator(), address(0x7777));
        assertEq(strategy.officialPoolFee(), 3000);
        assertEq(strategy.officialPoolTickSpacing(), 60);
        assertEq(strategy.totalStrategySupply(), 150);
        assertEq(strategy.auctionTokenAmount(), 100);
        assertEq(strategy.reserveTokenAmount(), 50);
    }

    function testRejectsUnauthorizedCreator() external {
        RegentLBPStrategyFactory factory = new RegentLBPStrategyFactory(address(this));

        RegentLBPStrategyFactory.RegentLBPStrategyConfig memory cfg =
            RegentLBPStrategyFactory.RegentLBPStrategyConfig({
                quoteToken: REGENT,
                auctionInitializerFactory: address(0x3333),
                auctionParameters: AuctionParameters({
                    currency: REGENT,
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
                agentSafe: address(0x5555),
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
                reserveTokenAmount: 50
            });

        vm.prank(address(0xBAD));
        vm.expectRevert("ONLY_AUTHORIZED_CREATOR");
        factory.initializeDistribution(address(0x1111), 150, abi.encode(cfg), bytes32(0));
    }
}
