// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";

contract LaunchFeeRegistryTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant NOT_OWNER = address(0xB0B);
    address internal constant LAUNCH_TOKEN = address(0x1001);
    address internal constant QUOTE_TOKEN = address(0x2002);
    address internal constant TREASURY = address(0x3003);
    address internal constant REGENT_RECIPIENT = address(0x4004);
    address internal constant POOL_MANAGER = address(0x5005);
    address internal constant HOOK = address(0x6006);
    uint24 internal constant POOL_FEE = 0;
    int24 internal constant TICK_SPACING = 60;

    LaunchFeeRegistry internal registry;

    function setUp() external {
        registry = new LaunchFeeRegistry(OWNER);
    }

    function testRegisterPoolStoresConfigAndGetters() external {
        vm.prank(OWNER);
        bytes32 poolId = registry.registerPool(_registration(LAUNCH_TOKEN, QUOTE_TOKEN));

        LaunchFeeRegistry.PoolConfig memory config = registry.getPoolConfig(poolId);

        assertTrue(registry.isRegisteredPool(poolId));
        assertEq(config.launchToken, LAUNCH_TOKEN);
        assertEq(config.quoteToken, QUOTE_TOKEN);
        assertEq(config.treasury, TREASURY);
        assertEq(config.regentRecipient, REGENT_RECIPIENT);
        assertEq(config.poolManager, POOL_MANAGER);
        assertEq(config.hook, HOOK);
        assertTrue(config.hookEnabled);
        assertEq(registry.treasuryRecipient(poolId), TREASURY);
        assertEq(registry.regentRecipient(poolId), REGENT_RECIPIENT);
        assertEq(registry.quoteToken(poolId), QUOTE_TOKEN);

        bytes32 computed =
            registry.computePoolId(LAUNCH_TOKEN, QUOTE_TOKEN, POOL_FEE, TICK_SPACING, HOOK);

        assertEq(poolId, computed);
    }

    function testRegisterPoolRequiresOwnerAndRejectsDuplicates() external {
        vm.prank(NOT_OWNER);
        vm.expectRevert("ONLY_OWNER");
        registry.registerPool(_registration(LAUNCH_TOKEN, QUOTE_TOKEN));

        vm.startPrank(OWNER);
        registry.registerPool(_registration(LAUNCH_TOKEN, QUOTE_TOKEN));
        vm.expectRevert("POOL_ALREADY_REGISTERED");
        registry.registerPool(_registration(LAUNCH_TOKEN, QUOTE_TOKEN));
        vm.stopPrank();
    }

    function testRejectsEqualPoolCurrencies() external {
        vm.prank(OWNER);
        vm.expectRevert("POOL_CURRENCIES_EQUAL");
        registry.registerPool(_registration(LAUNCH_TOKEN, LAUNCH_TOKEN));
    }

    function testHookEnabledCanBeToggled() external {
        vm.prank(OWNER);
        bytes32 poolId = registry.registerPool(_registration(LAUNCH_TOKEN, QUOTE_TOKEN));

        vm.prank(OWNER);
        registry.setHookEnabled(poolId, false);
        assertFalse(registry.getPoolConfig(poolId).hookEnabled);

        vm.prank(OWNER);
        registry.setHookEnabled(poolId, true);
        assertTrue(registry.getPoolConfig(poolId).hookEnabled);
    }

    function _registration(address launchToken, address quoteToken)
        internal
        pure
        returns (LaunchFeeRegistry.PoolRegistration memory)
    {
        return LaunchFeeRegistry.PoolRegistration({
            launchToken: launchToken,
            quoteToken: quoteToken,
            treasury: TREASURY,
            regentRecipient: REGENT_RECIPIENT,
            poolFee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            poolManager: POOL_MANAGER,
            hook: HOOK
        });
    }
}
