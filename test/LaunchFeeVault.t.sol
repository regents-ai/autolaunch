// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";
import {LaunchFeeVault} from "src/LaunchFeeVault.sol";
import {LaunchPoolFeeHook} from "src/LaunchPoolFeeHook.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";
import {MockHookDeployer} from "test/mocks/MockHookDeployer.sol";
import {MockHookPoolManager} from "test/mocks/MockHookPoolManager.sol";

contract LaunchFeeVaultTest is Test {
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
    address internal regentMultisig = address(0x9FA1);
    address internal trader = address(0xB0B);
    bytes32 internal poolId;
    PoolKey internal poolKey;

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
                launchToken: address(0x1001),
                quoteToken: address(quoteToken),
                treasury: treasury,
                regentRecipient: regentMultisig,
                poolFee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                poolManager: address(poolManager),
                hook: address(hook)
            })
        );
        vm.stopPrank();

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1001)),
            currency1: Currency.wrap(address(quoteToken)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        quoteToken.mint(address(poolManager), 1000e18);
        poolManager.simulateSwap(
            address(hook),
            trader,
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: 0}),
            -100e18,
            100e18
        );
    }

    function testTreasuryAndRegentSharesAreTrackedSeparately() external view {
        assertEq(vault.treasuryAccrued(poolId, address(quoteToken)), 1e18);
        assertEq(vault.regentAccrued(poolId, address(quoteToken)), 1e18);
    }

    function testRegentShareWithdrawalIsAccessControlled() external {
        vm.expectRevert("ONLY_REGENT_RECIPIENT");
        vault.withdrawRegentShare(poolId, address(quoteToken), 1e18, regentMultisig);

        vm.prank(regentMultisig);
        vault.withdrawRegentShare(poolId, address(quoteToken), 1e18, regentMultisig);

        assertEq(quoteToken.balanceOf(regentMultisig), 1e18);
        assertEq(vault.regentAccrued(poolId, address(quoteToken)), 0);
    }

    function testRejectsNativeQuotedPools() external {
        vm.startPrank(owner);
        bytes32 nativePoolId = registry.registerPool(
            LaunchFeeRegistry.PoolRegistration({
                launchToken: address(0x2002),
                quoteToken: address(0),
                treasury: treasury,
                regentRecipient: regentMultisig,
                poolFee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                poolManager: address(poolManager),
                hook: address(hook)
            })
        );
        vm.stopPrank();

        PoolKey memory nativePoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0x2002)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert("QUOTE_TOKEN_ZERO");
        poolManager.simulateSwap(
            address(hook),
            trader,
            nativePoolKey,
            SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: 0}),
            100e18,
            -100e18
        );
        assertEq(vault.treasuryAccrued(nativePoolId, address(0)), 0);
        assertEq(vault.regentAccrued(nativePoolId, address(0)), 0);
    }
}
