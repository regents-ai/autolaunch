// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {AuctionParameters} from "src/cca/interfaces/IContinuousClearingAuction.sol";
import {LaunchPoolFeeHook} from "src/LaunchPoolFeeHook.sol";
import {MockHookDeployer} from "test/mocks/MockHookDeployer.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";
import {
    MockContinuousClearingAuctionFactory
} from "test/mocks/MockContinuousClearingAuctionFactory.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PositionDescriptor} from "@uniswap/v4-periphery/src/PositionDescriptor.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {RegentLBPStrategy} from "src/RegentLBPStrategy.sol";
import {
    IContinuousClearingAuctionFactory
} from "src/cca/interfaces/IContinuousClearingAuctionFactory.sol";
import {IDistributionContract} from "src/cca/interfaces/external/IDistributionContract.sol";

contract TestDistributionContract is IDistributionContract {
    bool public received;

    function onTokensReceived() external {
        received = true;
    }
}

contract MismatchAuctionFactory is IContinuousClearingAuctionFactory {
    function initializeDistribution(address, uint256, bytes calldata, bytes32)
        external
        returns (IDistributionContract distributionContract)
    {
        return new TestDistributionContract();
    }

    function getAuctionAddress(address, uint256, bytes calldata, bytes32, address)
        external
        pure
        returns (address)
    {
        return address(0xCAFE);
    }
}

contract SentinelPositionManager {
    function nextTokenId() external pure returns (uint256) {
        return 1;
    }

    function initializePool(PoolKey calldata, uint160) external pure returns (int24) {
        return type(int24).max;
    }

    function modifyLiquidities(bytes calldata, uint256) external payable {}
}

contract RegentLBPStrategyTest is Test {
    address internal constant AGENT_TREASURY = address(0x1234);
    address internal constant VESTING_WALLET = address(0x5678);
    address internal constant OPERATOR = address(0x9ABC);
    address internal constant POSITION_RECIPIENT = address(0xDEF0);
    uint128 internal constant AUCTION_AMOUNT = 100e18;
    uint128 internal constant RESERVE_AMOUNT = 50e18;
    uint24 internal constant OFFICIAL_POOL_FEE = 0;
    int24 internal constant OFFICIAL_POOL_TICK_SPACING = 60;

    MintableERC20Mock internal token;
    MintableERC20Mock internal usdc;
    MockContinuousClearingAuctionFactory internal auctionFactory;
    RegentLBPStrategy internal strategy;
    PoolManager internal poolManager;
    PositionManager internal positionManager;
    WETH internal weth;
    PositionDescriptor internal positionDescriptor;
    MockHookDeployer internal hookDeployer;
    LaunchPoolFeeHook internal hook;
    MismatchAuctionFactory internal mismatchAuctionFactory;
    SentinelPositionManager internal sentinelPositionManager;

    function setUp() external {
        token = new MintableERC20Mock("Launch Token", "LT");
        usdc = new MintableERC20Mock("USD Coin", "USDC");
        auctionFactory = new MockContinuousClearingAuctionFactory();
        poolManager = new PoolManager(address(this));
        weth = new WETH();
        positionDescriptor = new PositionDescriptor(poolManager, address(weth), bytes32("ETH"));
        positionManager = new PositionManager(
            poolManager,
            IAllowanceTransfer(address(0xBEEF)),
            100_000,
            positionDescriptor,
            IWETH9(address(weth))
        );
        hookDeployer = new MockHookDeployer();
        hook = hookDeployer.deploy(
            address(this), address(poolManager), address(0x1111), address(0x2222)
        );
        mismatchAuctionFactory = new MismatchAuctionFactory();
        sentinelPositionManager = new SentinelPositionManager();

        strategy = new RegentLBPStrategy(
            address(token),
            address(usdc),
            address(auctionFactory),
            AuctionParameters({
                currency: address(usdc),
                tokensRecipient: address(0),
                fundsRecipient: address(0),
                startBlock: 1,
                endBlock: 101,
                claimBlock: 101,
                tickSpacing: 1000,
                validationHook: address(0),
                floorPrice: 1000,
                requiredCurrencyRaised: 0,
                auctionStepsData: bytes("")
            }),
            address(hook),
            AGENT_TREASURY,
            VESTING_WALLET,
            OPERATOR,
            POSITION_RECIPIENT,
            address(positionManager),
            address(poolManager),
            OFFICIAL_POOL_FEE,
            OFFICIAL_POOL_TICK_SPACING,
            202,
            303,
            5000,
            6_666_666,
            AUCTION_AMOUNT + RESERVE_AMOUNT,
            AUCTION_AMOUNT,
            RESERVE_AMOUNT,
            type(uint128).max
        );

        token.mint(address(strategy), AUCTION_AMOUNT + RESERVE_AMOUNT);
    }

    function testOnTokensReceivedCreatesStrategyOwnedAuction() external {
        strategy.onTokensReceived();

        assertTrue(strategy.auctionAddress() != address(0));
        assertEq(token.balanceOf(strategy.auctionAddress()), AUCTION_AMOUNT);
        assertEq(token.balanceOf(address(strategy)), RESERVE_AMOUNT);
        assertEq(auctionFactory.lastAmount(), AUCTION_AMOUNT);
        assertEq(strategy.officialPoolFee(), OFFICIAL_POOL_FEE);
        assertEq(strategy.officialPoolTickSpacing(), OFFICIAL_POOL_TICK_SPACING);

        AuctionParameters memory params =
            abi.decode(auctionFactory.lastConfigData(), (AuctionParameters));
        assertEq(params.tokensRecipient, address(strategy));
        assertEq(params.fundsRecipient, address(strategy));
    }

    function testOnTokensReceivedCannotRunTwice() external {
        strategy.onTokensReceived();

        vm.expectRevert("AUCTION_ALREADY_CREATED");
        strategy.onTokensReceived();
    }

    function testOnTokensReceivedRequiresPredictedAuctionMatch() external {
        RegentLBPStrategy mismatchStrategy = new RegentLBPStrategy(
            address(token),
            address(usdc),
            address(mismatchAuctionFactory),
            _auctionParameters(),
            address(hook),
            AGENT_TREASURY,
            VESTING_WALLET,
            OPERATOR,
            POSITION_RECIPIENT,
            address(positionManager),
            address(poolManager),
            OFFICIAL_POOL_FEE,
            OFFICIAL_POOL_TICK_SPACING,
            202,
            303,
            5000,
            6_666_666,
            AUCTION_AMOUNT + RESERVE_AMOUNT,
            AUCTION_AMOUNT,
            RESERVE_AMOUNT,
            type(uint128).max
        );
        token.mint(address(mismatchStrategy), AUCTION_AMOUNT + RESERVE_AMOUNT);

        vm.expectRevert("AUCTION_ADDRESS_MISMATCH");
        mismatchStrategy.onTokensReceived();
    }

    function testMigrateRequiresAuctionCreation() external {
        usdc.mint(address(strategy), 200e18);

        vm.roll(202);
        vm.prank(OPERATOR);
        vm.expectRevert("AUCTION_NOT_CREATED");
        strategy.migrate();
    }

    function testConstructorRejectsCriticalZeroAddresses() external {
        vm.expectRevert("HOOK_ZERO");
        new RegentLBPStrategy(
            address(token),
            address(usdc),
            address(auctionFactory),
            _auctionParameters(),
            address(0),
            AGENT_TREASURY,
            VESTING_WALLET,
            OPERATOR,
            POSITION_RECIPIENT,
            address(positionManager),
            address(poolManager),
            OFFICIAL_POOL_FEE,
            OFFICIAL_POOL_TICK_SPACING,
            202,
            303,
            5000,
            6_666_666,
            AUCTION_AMOUNT + RESERVE_AMOUNT,
            AUCTION_AMOUNT,
            RESERVE_AMOUNT,
            type(uint128).max
        );

        vm.expectRevert("POSITION_MANAGER_ZERO");
        new RegentLBPStrategy(
            address(token),
            address(usdc),
            address(auctionFactory),
            _auctionParameters(),
            address(hook),
            AGENT_TREASURY,
            VESTING_WALLET,
            OPERATOR,
            POSITION_RECIPIENT,
            address(0),
            address(poolManager),
            OFFICIAL_POOL_FEE,
            OFFICIAL_POOL_TICK_SPACING,
            202,
            303,
            5000,
            6_666_666,
            AUCTION_AMOUNT + RESERVE_AMOUNT,
            AUCTION_AMOUNT,
            RESERVE_AMOUNT,
            type(uint128).max
        );

        vm.expectRevert("POOL_MANAGER_ZERO");
        new RegentLBPStrategy(
            address(token),
            address(usdc),
            address(auctionFactory),
            _auctionParameters(),
            address(hook),
            AGENT_TREASURY,
            VESTING_WALLET,
            OPERATOR,
            POSITION_RECIPIENT,
            address(positionManager),
            address(0),
            OFFICIAL_POOL_FEE,
            OFFICIAL_POOL_TICK_SPACING,
            202,
            303,
            5000,
            6_666_666,
            AUCTION_AMOUNT + RESERVE_AMOUNT,
            AUCTION_AMOUNT,
            RESERVE_AMOUNT,
            type(uint128).max
        );
    }

    function testMigrateCreatesRealV4PositionAndSweepsRemainders() external {
        strategy.onTokensReceived();
        usdc.mint(address(strategy), 200e18);

        uint256 expectedPositionId = positionManager.nextTokenId();
        PoolKey memory expectedPoolKey = _expectedPoolKey();
        bytes32 expectedPoolId = PoolId.unwrap(expectedPoolKey.toId());
        int24 lowerTick = TickMath.minUsableTick(OFFICIAL_POOL_TICK_SPACING);
        int24 upperTick = TickMath.maxUsableTick(OFFICIAL_POOL_TICK_SPACING);

        vm.roll(202);
        vm.prank(OPERATOR);
        strategy.migrate();

        assertTrue(strategy.migrated());
        assertEq(strategy.migratedPoolId(), expectedPoolId);
        assertEq(strategy.migratedPositionId(), expectedPositionId);
        assertEq(strategy.migratedCurrencyForLP(), 100e18);
        assertEq(strategy.migratedTokenForLP(), RESERVE_AMOUNT);
        assertTrue(strategy.migratedLiquidity() != 0);

        assertEq(positionManager.ownerOf(expectedPositionId), POSITION_RECIPIENT);
        assertEq(
            positionManager.getPositionLiquidity(expectedPositionId), strategy.migratedLiquidity()
        );

        (PoolKey memory actualPoolKey,) = positionManager.getPoolAndPositionInfo(expectedPositionId);
        assertEq(
            Currency.unwrap(actualPoolKey.currency0), Currency.unwrap(expectedPoolKey.currency0)
        );
        assertEq(
            Currency.unwrap(actualPoolKey.currency1), Currency.unwrap(expectedPoolKey.currency1)
        );
        assertEq(actualPoolKey.fee, expectedPoolKey.fee);
        assertEq(actualPoolKey.tickSpacing, expectedPoolKey.tickSpacing);
        assertEq(address(actualPoolKey.hooks), address(expectedPoolKey.hooks));

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(expectedPoolId));
        assertTrue(sqrtPriceX96 != 0);
        assertTrue(StateLibrary.getLiquidity(poolManager, PoolId.wrap(expectedPoolId)) != 0);

        bytes32 positionKey = Position.calculatePositionKey(
            address(positionManager), lowerTick, upperTick, bytes32(expectedPositionId)
        );
        assertEq(
            StateLibrary.getPositionLiquidity(
                poolManager, PoolId.wrap(expectedPoolId), positionKey
            ),
            strategy.migratedLiquidity()
        );

        uint256 treasuryBefore = usdc.balanceOf(AGENT_TREASURY);
        uint256 vestingBefore = token.balanceOf(VESTING_WALLET);

        token.mint(address(strategy), 12e18);
        usdc.mint(address(strategy), 11e18);

        uint256 currencyToSweep = usdc.balanceOf(address(strategy));
        uint256 tokenToSweep = token.balanceOf(address(strategy));

        vm.roll(303);
        vm.prank(OPERATOR);
        strategy.sweepCurrency();
        vm.prank(OPERATOR);
        strategy.sweepToken();

        assertEq(usdc.balanceOf(address(strategy)), 0);
        assertEq(token.balanceOf(address(strategy)), 0);
        assertEq(usdc.balanceOf(AGENT_TREASURY), treasuryBefore + currencyToSweep);
        assertEq(token.balanceOf(VESTING_WALLET), vestingBefore + tokenToSweep);
    }

    function testMigrateRevertsWhenPoolInitializationFails() external {
        RegentLBPStrategy failingStrategy = new RegentLBPStrategy(
            address(token),
            address(usdc),
            address(auctionFactory),
            _auctionParameters(),
            address(hook),
            AGENT_TREASURY,
            VESTING_WALLET,
            OPERATOR,
            POSITION_RECIPIENT,
            address(sentinelPositionManager),
            address(poolManager),
            OFFICIAL_POOL_FEE,
            OFFICIAL_POOL_TICK_SPACING,
            202,
            303,
            5000,
            6_666_666,
            AUCTION_AMOUNT + RESERVE_AMOUNT,
            AUCTION_AMOUNT,
            RESERVE_AMOUNT,
            type(uint128).max
        );
        token.mint(address(failingStrategy), AUCTION_AMOUNT + RESERVE_AMOUNT);

        failingStrategy.onTokensReceived();
        usdc.mint(address(failingStrategy), 200e18);

        vm.roll(202);
        vm.prank(OPERATOR);
        vm.expectRevert("POOL_INIT_FAILED");
        failingStrategy.migrate();
    }

    function _expectedPoolKey() internal view returns (PoolKey memory poolKey) {
        Currency tokenCurrency = Currency.wrap(address(token));
        Currency usdcCurrency = Currency.wrap(address(usdc));
        (Currency currency0, Currency currency1) = tokenCurrency < usdcCurrency
            ? (tokenCurrency, usdcCurrency)
            : (usdcCurrency, tokenCurrency);
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: OFFICIAL_POOL_FEE,
            tickSpacing: OFFICIAL_POOL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _auctionParameters() internal view returns (AuctionParameters memory) {
        return AuctionParameters({
            currency: address(usdc),
            tokensRecipient: address(0),
            fundsRecipient: address(0),
            startBlock: 1,
            endBlock: 101,
            claimBlock: 101,
            tickSpacing: 1000,
            validationHook: address(0),
            floorPrice: 1000,
            requiredCurrencyRaised: 0,
            auctionStepsData: bytes("")
        });
    }
}
