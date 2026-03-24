// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";
import {LaunchFeeVault} from "src/LaunchFeeVault.sol";
import {LaunchPoolFeeHook} from "src/LaunchPoolFeeHook.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";
import {MockHookDeployer} from "test/mocks/MockHookDeployer.sol";
import {MockHookPoolManager} from "test/mocks/MockHookPoolManager.sol";

contract LaunchPoolFeeHookTest is Test {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant POOL_FEE = 0;
    int24 internal constant TICK_SPACING = 60;

    LaunchFeeRegistry internal registry;
    LaunchFeeVault internal vault;
    LaunchPoolFeeHook internal hook;
    MockHookDeployer internal hookDeployer;
    MockHookPoolManager internal poolManager;
    MintableERC20Mock internal quoteToken;

    address internal owner = address(0xA11CE);
    address internal treasury = address(0x7EAD);
    address internal trader = address(0xB0B);
    address internal launchToken = address(0x1001);
    PoolKey internal poolKey;
    bytes32 internal poolId;

    function setUp() external {
        vm.startPrank(owner);

        registry = new LaunchFeeRegistry(owner);
        vault = new LaunchFeeVault(owner, address(registry));
        hookDeployer = new MockHookDeployer();
        poolManager = new MockHookPoolManager();
        hook = hookDeployer.deploy(owner, address(poolManager), address(registry), address(vault));

        vault.setHook(address(hook));

        quoteToken = new MintableERC20Mock("Quote", "Q");
        poolId = registry.registerPool(
            LaunchFeeRegistry.PoolRegistration({
                launchToken: launchToken,
                quoteToken: address(quoteToken),
                treasury: treasury,
                regentRecipient: address(0x9FA1),
                poolFee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                poolManager: address(poolManager),
                hook: address(hook)
            })
        );
        vm.stopPrank();

        poolKey = PoolKey({
            currency0: Currency.wrap(launchToken),
            currency1: Currency.wrap(address(quoteToken)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        quoteToken.mint(address(poolManager), 1000e18);
    }

    function testChargesTwoPercentOnExactInputSwap() external {
        (bytes4 selector, int128 feeDelta) = poolManager.simulateSwap(
            address(hook),
            trader,
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: 0}),
            -100e18,
            100e18
        );

        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(feeDelta, 2e18);
        assertEq(quoteToken.balanceOf(address(vault)), 2e18);
        assertEq(vault.treasuryAccrued(poolId, address(quoteToken)), 1e18);
        assertEq(vault.regentAccrued(poolId, address(quoteToken)), 1e18);
    }

    function testChargesTwoPercentOnExactOutputSwap() external {
        (bytes4 selector, int128 feeDelta) = poolManager.simulateSwap(
            address(hook),
            trader,
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: 250e18, sqrtPriceLimitX96: 0}),
            250e18,
            -250e18
        );

        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(feeDelta, 5e18);
        assertEq(vault.treasuryAccrued(poolId, address(quoteToken)), 25e17);
        assertEq(vault.regentAccrued(poolId, address(quoteToken)), 25e17);
    }

    function testChargesQuoteTokenEvenWhenLaunchTokenIsCurrency1() external {
        MintableERC20Mock launchTokenMock = new MintableERC20Mock("Launch", "LAUNCH");
        vm.startPrank(owner);
        bytes32 altPoolId = registry.registerPool(
            LaunchFeeRegistry.PoolRegistration({
                launchToken: address(launchTokenMock),
                quoteToken: address(quoteToken),
                treasury: treasury,
                regentRecipient: address(0x9FA1),
                poolFee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                poolManager: address(poolManager),
                hook: address(hook)
            })
        );
        vm.stopPrank();

        PoolKey memory altKey = PoolKey({
            currency0: Currency.wrap(address(quoteToken)),
            currency1: Currency.wrap(address(launchTokenMock)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        launchTokenMock.mint(address(poolManager), 500e18);

        (, int128 feeDelta) = poolManager.simulateSwap(
            address(hook),
            trader,
            altKey,
            SwapParams({zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: 0}),
            -100e18,
            100e18
        );

        assertEq(feeDelta, 2e18);
        assertEq(vault.treasuryAccrued(altPoolId, address(quoteToken)), 1e18);
        assertEq(vault.regentAccrued(altPoolId, address(quoteToken)), 1e18);
        assertEq(vault.treasuryAccrued(altPoolId, address(launchTokenMock)), 0);
        assertEq(vault.regentAccrued(altPoolId, address(launchTokenMock)), 0);
    }

    function testRejectsPoolsWithoutUsdcQuoteToken() external {
        vm.startPrank(owner);
        poolId = registry.registerPool(
            LaunchFeeRegistry.PoolRegistration({
                launchToken: launchToken,
                quoteToken: address(0),
                treasury: treasury,
                regentRecipient: address(0x9FA1),
                poolFee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                poolManager: address(poolManager),
                hook: address(hook)
            })
        );
        vm.stopPrank();

        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(launchToken),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert("QUOTE_TOKEN_ZERO");
        poolManager.simulateSwap(
            address(hook),
            trader,
            ethKey,
            SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: 0}),
            100e18,
            -100e18
        );
    }

    function testUnregisteredPoolCannotChargeFee() external {
        PoolKey memory unknownKey = PoolKey({
            currency0: Currency.wrap(address(0x4444)),
            currency1: Currency.wrap(address(quoteToken)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert("POOL_NOT_REGISTERED");
        poolManager.simulateSwap(
            address(hook),
            trader,
            unknownKey,
            SwapParams({zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: 0}),
            -100e18,
            100e18
        );
    }

    function testTreasuryWithdrawIsAccessControlled() external {
        poolManager.simulateSwap(
            address(hook),
            trader,
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: 0}),
            -100e18,
            100e18
        );

        vm.expectRevert("ONLY_TREASURY");
        vault.withdrawTreasury(poolId, address(quoteToken), 1e18, treasury);

        vm.prank(treasury);
        vault.withdrawTreasury(poolId, address(quoteToken), 1e18, treasury);

        assertEq(quoteToken.balanceOf(treasury), 1e18);
        assertEq(vault.treasuryAccrued(poolId, address(quoteToken)), 0);
    }
}
