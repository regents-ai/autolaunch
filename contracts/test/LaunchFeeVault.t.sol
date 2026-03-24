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
    address internal constant OWNER = address(0xA11CE);
    address internal constant TREASURY = address(0x7EAD);
    address internal constant REGENT_MULTISIG = address(0x9FA1);
    address internal constant TRADER = address(0xB0B);
    address internal constant PRIMARY_LAUNCH_TOKEN = address(0x1001);
    address internal constant NATIVE_QUOTE_TOKEN = address(0);
    address internal constant SECONDARY_LAUNCH_TOKEN = address(0x2002);
    uint256 internal constant SWAP_AMOUNT = 100e18;
    uint256 internal constant ACCRUED_SHARE = 1e18;

    LaunchFeeRegistry internal registry;
    LaunchFeeVault internal vault;
    LaunchPoolFeeHook internal hook;
    MockHookDeployer internal hookDeployer;
    MockHookPoolManager internal poolManager;
    MintableERC20Mock internal quoteToken;

    bytes32 internal poolId;
    PoolKey internal poolKey;

    function setUp() external {
        vm.startPrank(OWNER);
        registry = new LaunchFeeRegistry(OWNER);
        vault = new LaunchFeeVault(OWNER, address(registry));
        hookDeployer = new MockHookDeployer();
        poolManager = new MockHookPoolManager();
        hook = hookDeployer.deploy(OWNER, address(poolManager), address(registry), address(vault));
        vault.setHook(address(hook));
        quoteToken = new MintableERC20Mock("Quote", "Q");
        poolId = _registerPool(PRIMARY_LAUNCH_TOKEN, address(quoteToken));
        vm.stopPrank();

        poolKey = _poolKey(PRIMARY_LAUNCH_TOKEN, address(quoteToken));

        quoteToken.mint(address(poolManager), 1000e18);
        _simulateSwap(
            poolKey,
            true,
            -int256(SWAP_AMOUNT),
            -int128(int256(SWAP_AMOUNT)),
            int128(int256(SWAP_AMOUNT))
        );
    }

    function testTreasuryAndRegentSharesAreTrackedSeparately() external view {
        assertEq(vault.treasuryAccrued(poolId, address(quoteToken)), ACCRUED_SHARE);
        assertEq(vault.regentAccrued(poolId, address(quoteToken)), ACCRUED_SHARE);
    }

    function testRegentShareWithdrawalIsAccessControlled() external {
        vm.expectRevert("ONLY_REGENT_RECIPIENT");
        vault.withdrawRegentShare(poolId, address(quoteToken), ACCRUED_SHARE, REGENT_MULTISIG);

        vm.prank(REGENT_MULTISIG);
        vault.withdrawRegentShare(poolId, address(quoteToken), ACCRUED_SHARE, REGENT_MULTISIG);

        assertEq(quoteToken.balanceOf(REGENT_MULTISIG), ACCRUED_SHARE);
        assertEq(vault.regentAccrued(poolId, address(quoteToken)), 0);
    }

    function testRejectsNativeQuotedPools() external {
        vm.startPrank(OWNER);
        vm.expectRevert("QUOTE_TOKEN_ZERO");
        _registerPool(SECONDARY_LAUNCH_TOKEN, NATIVE_QUOTE_TOKEN);
        vm.stopPrank();
    }

    function _registerPool(address launchToken, address quoteTokenAddress)
        internal
        returns (bytes32)
    {
        return registry.registerPool(
            LaunchFeeRegistry.PoolRegistration({
                launchToken: launchToken,
                quoteToken: quoteTokenAddress,
                treasury: TREASURY,
                regentRecipient: REGENT_MULTISIG,
                poolFee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                poolManager: address(poolManager),
                hook: address(hook)
            })
        );
    }

    function _poolKey(address currency0, address currency1) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _simulateSwap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        int128 amount0,
        int128 amount1
    ) internal {
        poolManager.simulateSwap(
            address(hook),
            TRADER,
            key,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0
            }),
            amount0,
            amount1
        );
    }
}
