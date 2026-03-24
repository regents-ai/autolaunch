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

contract LaunchPoolFeeHookTest is Test {
    uint24 internal constant POOL_FEE = 0;
    int24 internal constant TICK_SPACING = 60;
    address internal constant OWNER = address(0xA11CE);
    address internal constant TREASURY = address(0x7EAD);
    address internal constant REGENT_RECIPIENT = address(0x9FA1);
    address internal constant TRADER = address(0xB0B);
    address internal constant LAUNCH_TOKEN = address(0x1001);
    uint256 internal constant SWAP_AMOUNT = 100e18;
    uint256 internal constant FEE_BPS = 200;
    uint256 internal constant HALF_FEE = 1e18;

    LaunchFeeRegistry internal registry;
    LaunchFeeVault internal vault;
    LaunchPoolFeeHook internal hook;
    MockHookDeployer internal hookDeployer;
    MockHookPoolManager internal poolManager;
    MintableERC20Mock internal quoteToken;

    PoolKey internal poolKey;
    bytes32 internal poolId;

    function setUp() external {
        vm.startPrank(OWNER);

        registry = new LaunchFeeRegistry(OWNER);
        vault = new LaunchFeeVault(OWNER, address(registry));
        hookDeployer = new MockHookDeployer();
        poolManager = new MockHookPoolManager();
        hook = hookDeployer.deploy(OWNER, address(poolManager), address(registry), address(vault));

        vault.setHook(address(hook));

        quoteToken = new MintableERC20Mock("Quote", "Q");
        poolId = _registerPool(LAUNCH_TOKEN, address(quoteToken));
        vm.stopPrank();

        poolKey = _poolKey(LAUNCH_TOKEN, address(quoteToken));

        quoteToken.mint(address(poolManager), 1000e18);
    }

    function testChargesTwoPercentOnExactInputSwap() external {
        (bytes4 selector, int128 feeDelta) = _simulateSwap(
            poolKey,
            true,
            -int256(SWAP_AMOUNT),
            -int128(int256(SWAP_AMOUNT)),
            int128(int256(SWAP_AMOUNT))
        );

        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(feeDelta, 2e18);
        assertEq(quoteToken.balanceOf(address(vault)), 2e18);
        _assertSplitFee(poolId, address(quoteToken), HALF_FEE);
    }

    function testChargesTwoPercentOnExactOutputSwap() external {
        (bytes4 selector, int128 feeDelta) = _simulateSwap(poolKey, false, 250e18, 250e18, -250e18);

        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(feeDelta, 5e18);
        assertEq(vault.treasuryAccrued(poolId, address(quoteToken)), 25e17);
        assertEq(vault.regentAccrued(poolId, address(quoteToken)), 25e17);
    }

    function testChargesQuoteTokenEvenWhenLaunchTokenIsCurrency1() external {
        MintableERC20Mock launchTokenMock = new MintableERC20Mock("Launch", "LAUNCH");
        vm.startPrank(OWNER);
        bytes32 altPoolId = _registerPool(address(launchTokenMock), address(quoteToken));
        vm.stopPrank();

        PoolKey memory altKey = _poolKey(address(quoteToken), address(launchTokenMock));

        launchTokenMock.mint(address(poolManager), 500e18);

        (, int128 feeDelta) = _simulateSwap(
            altKey,
            true,
            -int256(SWAP_AMOUNT),
            -int128(int256(SWAP_AMOUNT)),
            int128(int256(SWAP_AMOUNT))
        );

        assertEq(feeDelta, 2e18);
        _assertSplitFee(altPoolId, address(quoteToken), HALF_FEE);
        assertEq(vault.treasuryAccrued(altPoolId, address(launchTokenMock)), 0);
        assertEq(vault.regentAccrued(altPoolId, address(launchTokenMock)), 0);
    }

    function testRejectsPoolsWithoutUsdcQuoteToken() external {
        vm.startPrank(OWNER);
        vm.expectRevert("QUOTE_TOKEN_ZERO");
        _registerPool(LAUNCH_TOKEN, address(0));
        vm.stopPrank();
    }

    function testUnregisteredPoolCannotChargeFee() external {
        PoolKey memory unknownKey = _poolKey(address(0x4444), address(quoteToken));

        vm.expectRevert("POOL_NOT_REGISTERED");
        _simulateSwap(
            unknownKey,
            true,
            -int256(SWAP_AMOUNT),
            -int128(int256(SWAP_AMOUNT)),
            int128(int256(SWAP_AMOUNT))
        );
    }

    function testTreasuryWithdrawIsAccessControlled() external {
        _simulateSwap(
            poolKey,
            true,
            -int256(SWAP_AMOUNT),
            -int128(int256(SWAP_AMOUNT)),
            int128(int256(SWAP_AMOUNT))
        );

        vm.expectRevert("ONLY_TREASURY");
        vault.withdrawTreasury(poolId, address(quoteToken), HALF_FEE, TREASURY);

        vm.prank(TREASURY);
        vault.withdrawTreasury(poolId, address(quoteToken), HALF_FEE, TREASURY);

        assertEq(quoteToken.balanceOf(TREASURY), HALF_FEE);
        assertEq(vault.treasuryAccrued(poolId, address(quoteToken)), 0);
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
                regentRecipient: REGENT_RECIPIENT,
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
    ) internal returns (bytes4 selector, int128 feeDelta) {
        return poolManager.simulateSwap(
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

    function _assertSplitFee(bytes32 id, address token, uint256 share) internal view {
        assertEq(vault.treasuryAccrued(id, token), share);
        assertEq(vault.regentAccrued(id, token), share);
    }
}
