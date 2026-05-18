// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";
import {LaunchFeeVault} from "src/LaunchFeeVault.sol";
import {LaunchPoolFeeHook} from "src/LaunchPoolFeeHook.sol";
import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";
import {MockHookDeployer} from "test/mocks/MockHookDeployer.sol";
import {MockHookPoolManager} from "test/mocks/MockHookPoolManager.sol";

contract RealPoolManagerHarness is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeTransferLib for address;
    using TransientStateLibrary for IPoolManager;

    enum Action {
        MODIFY_LIQUIDITY,
        SWAP
    }

    IPoolManager public immutable poolManager;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params) external {
        poolManager.unlock(abi.encode(Action.MODIFY_LIQUIDITY, abi.encode(key, params)));
    }

    function swap(PoolKey memory key, SwapParams memory params)
        external
        returns (int128 amount0, int128 amount1)
    {
        bytes memory result = poolManager.unlock(abi.encode(Action.SWAP, abi.encode(key, params)));
        return abi.decode(result, (int128, int128));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "ONLY_POOL_MANAGER");

        (Action action, bytes memory inner) = abi.decode(data, (Action, bytes));
        if (action == Action.MODIFY_LIQUIDITY) {
            (PoolKey memory liquidityKey, ModifyLiquidityParams memory liquidityParams) =
                abi.decode(inner, (PoolKey, ModifyLiquidityParams));
            (BalanceDelta liquidityDelta,) =
                poolManager.modifyLiquidity(liquidityKey, liquidityParams, bytes(""));
            _resolveCurrency(liquidityKey.currency0);
            _resolveCurrency(liquidityKey.currency1);
            return abi.encode(liquidityDelta.amount0(), liquidityDelta.amount1());
        }

        (PoolKey memory swapKey, SwapParams memory swapParams) =
            abi.decode(inner, (PoolKey, SwapParams));
        BalanceDelta swapDelta = poolManager.swap(swapKey, swapParams, bytes(""));
        _resolveCurrency(swapKey.currency0);
        _resolveCurrency(swapKey.currency1);
        return abi.encode(swapDelta.amount0(), swapDelta.amount1());
    }

    function _resolveCurrency(Currency currency) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) {
            uint256 amount = uint256(-delta);
            poolManager.sync(currency);
            Currency.unwrap(currency).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        } else if (delta > 0) {
            poolManager.take(currency, address(this), uint256(delta));
        }
    }
}

contract LaunchPoolFeeHookTest is Test {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant POOL_FEE = 0;
    int24 internal constant TICK_SPACING = 60;
    address internal constant OWNER = address(0xA11CE);
    address internal constant TREASURY = address(0x7EAD);
    address internal constant REGENT_RECIPIENT = address(0x9FA1);
    address internal constant TRADER = address(0xB0B);
    uint256 internal constant FEE_BPS = 200;

    LaunchFeeRegistry internal registry;
    LaunchFeeVault internal vault;
    LaunchPoolFeeHook internal hook;
    MockHookDeployer internal hookDeployer;
    MockHookPoolManager internal poolManager;
    MintableERC20Mock internal launchToken;
    MintableERC20Mock internal quoteToken;
    LaunchFeeRegistry internal realRegistry;
    LaunchFeeVault internal realVault;
    LaunchPoolFeeHook internal realHook;
    PoolManager internal realPoolManager;
    MintableERC20Mock internal realLaunchToken;
    MintableERC20Mock internal realQuoteToken;
    RealPoolManagerHarness internal realHarness;

    PoolKey internal poolKey;
    bytes32 internal poolId;
    PoolKey internal realPoolKey;
    bytes32 internal realPoolId;

    function setUp() external {
        vm.startPrank(OWNER);

        launchToken = new MintableERC20Mock("Launch", "LAUNCH");
        quoteToken = new MintableERC20Mock("Quote", "Q");
        registry = new LaunchFeeRegistry(OWNER, address(quoteToken));
        vault = new LaunchFeeVault(OWNER, address(registry));
        hookDeployer = new MockHookDeployer();
        poolManager = new MockHookPoolManager();
        hook = hookDeployer.deploy(OWNER, address(poolManager), address(registry), address(vault));

        vault.setHook(address(hook));
        poolId = _registerPool(address(launchToken), address(quoteToken));
        realPoolManager = new PoolManager(OWNER);
        realLaunchToken = new MintableERC20Mock("Real Launch", "RLAUNCH");
        realQuoteToken = new MintableERC20Mock("Real Quote", "RQUOTE");
        realRegistry = new LaunchFeeRegistry(OWNER, address(realQuoteToken));
        realVault = new LaunchFeeVault(OWNER, address(realRegistry));
        realHook = hookDeployer.deploy(
            OWNER, address(realPoolManager), address(realRegistry), address(realVault)
        );
        realVault.setHook(address(realHook));
        realPoolId = realRegistry.registerPool(
            LaunchFeeRegistry.PoolRegistration({
                launchToken: address(realLaunchToken),
                quoteToken: address(realQuoteToken),
                treasury: TREASURY,
                regentRecipient: REGENT_RECIPIENT,
                poolFee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                poolManager: address(realPoolManager),
                hook: address(realHook)
            })
        );
        vm.stopPrank();

        poolKey = _sortedPoolKey(address(launchToken), address(quoteToken), address(hook));
        realPoolKey =
            _sortedPoolKey(address(realLaunchToken), address(realQuoteToken), address(realHook));
        launchToken.mint(address(poolManager), 1000e18);
        quoteToken.mint(address(poolManager), 1000e18);
        realHarness = new RealPoolManagerHarness(realPoolManager);
        realLaunchToken.mint(address(realHarness), 10_000e18);
        realQuoteToken.mint(address(realHarness), 10_000e18);
        realPoolManager.initialize(realPoolKey, TickMath.getSqrtPriceAtTick(0));
        realHarness.modifyLiquidity(
            realPoolKey,
            ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: 1000e18, salt: bytes32(0)
            })
        );
    }

    function testZeroForOneExactInputChargesQuoteToken() external {
        _assertSwapFee(poolKey, true, -100e18, -100e18, 80e18);
    }

    function testZeroForOneExactOutputChargesQuoteToken() external {
        _assertSwapFee(poolKey, true, 90e18, -120e18, 90e18);
    }

    function testOneForZeroExactInputChargesQuoteToken() external {
        _assertSwapFee(poolKey, false, -100e18, 70e18, -100e18);
    }

    function testOneForZeroExactOutputChargesQuoteToken() external {
        _assertSwapFee(poolKey, false, 80e18, 80e18, -110e18);
    }

    function testRejectsPoolsWithoutQuoteToken() external {
        vm.startPrank(OWNER);
        vm.expectRevert("QUOTE_TOKEN_ZERO");
        _registerPool(address(launchToken), address(0));
        vm.stopPrank();
    }

    function testUnregisteredPoolCannotChargeFee() external {
        PoolKey memory unknownKey = _poolKey(address(0x4444), address(quoteToken));

        vm.expectRevert("POOL_NOT_REGISTERED");
        _simulateSwap(unknownKey, true, -100e18, -100e18, 80e18);
    }

    function testOwnerCanDisableAndReEnableFeeCapture() external {
        vm.prank(OWNER);
        registry.setHookEnabled(poolId, false);

        vm.expectRevert("HOOK_DISABLED");
        _simulateSwap(poolKey, true, -100e18, -100e18, 80e18);

        vm.prank(OWNER);
        registry.setHookEnabled(poolId, true);

        _assertSwapFee(poolKey, true, -100e18, -100e18, 80e18);
    }

    function testRejectsDirectBeforeSwapCallsFromNonPoolManager() external {
        vm.expectRevert("ONLY_POOL_MANAGER");
        hook.beforeSwap(
            TRADER,
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: 0}),
            bytes("")
        );
    }

    function testRejectsDirectAfterSwapCallsFromNonPoolManager() external {
        vm.expectRevert("ONLY_POOL_MANAGER");
        hook.afterSwap(
            TRADER,
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: 0}),
            BalanceDelta.wrap(0),
            bytes("")
        );
    }

    function testRejectsPoolRegisteredForDifferentPoolManager() external {
        MintableERC20Mock otherLaunchToken = new MintableERC20Mock("Other Launch", "OLAUNCH");
        vm.prank(OWNER);
        registry.registerPool(
            LaunchFeeRegistry.PoolRegistration({
                launchToken: address(otherLaunchToken),
                quoteToken: address(quoteToken),
                treasury: TREASURY,
                regentRecipient: REGENT_RECIPIENT,
                poolFee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                poolManager: address(0xDEAD),
                hook: address(hook)
            })
        );
        PoolKey memory mismatchedPoolManagerKey =
            _sortedPoolKey(address(otherLaunchToken), address(quoteToken), address(hook));

        vm.expectRevert("POOL_MANAGER_MISMATCH");
        _simulateSwap(mismatchedPoolManagerKey, true, -100e18, -100e18, 80e18);
    }

    function testRejectsPoolRegisteredForDifferentHook() external {
        MintableERC20Mock otherLaunchToken = new MintableERC20Mock("Other Launch", "OLAUNCH");
        address wrongHook = address(0x1234);
        vm.prank(OWNER);
        registry.registerPool(
            LaunchFeeRegistry.PoolRegistration({
                launchToken: address(otherLaunchToken),
                quoteToken: address(quoteToken),
                treasury: TREASURY,
                regentRecipient: REGENT_RECIPIENT,
                poolFee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                poolManager: address(poolManager),
                hook: wrongHook
            })
        );
        PoolKey memory mismatchedHookKey =
            _sortedPoolKey(address(otherLaunchToken), address(quoteToken), wrongHook);

        vm.expectRevert("HOOK_MISMATCH");
        _simulateSwap(mismatchedHookKey, true, -100e18, -100e18, 80e18);
    }

    function testOddSmallFeeIsFullyAssignedToWithdrawableShares() external {
        _simulateSwap(poolKey, true, -50, -50, 49);

        assertEq(poolManager.lastTakeAmount(), 1);
        assertEq(quoteToken.balanceOf(address(vault)), 1);
        assertEq(vault.treasuryAccrued(poolId, address(quoteToken)), 0);
        assertEq(vault.regentAccrued(poolId, address(quoteToken)), 1);
    }

    function testFuzzQuoteFeesAreFullyWithdrawable(uint128 amountSeed) external {
        uint256 amount = bound(uint256(amountSeed), 50, 1_000_000e18);
        uint256 expectedFee = amount * FEE_BPS / 10_000;
        quoteToken.mint(address(poolManager), expectedFee);

        uint256 treasuryBefore = vault.treasuryAccrued(poolId, address(quoteToken));
        uint256 regentBefore = vault.regentAccrued(poolId, address(quoteToken));
        uint256 vaultBalanceBefore = quoteToken.balanceOf(address(vault));

        _simulateSwap(
            poolKey, true, -int256(amount), -int128(int256(amount)), int128(int256(amount))
        );

        uint256 treasuryDelta = vault.treasuryAccrued(poolId, address(quoteToken)) - treasuryBefore;
        uint256 regentDelta = vault.regentAccrued(poolId, address(quoteToken)) - regentBefore;
        uint256 vaultBalanceDelta = quoteToken.balanceOf(address(vault)) - vaultBalanceBefore;

        assertEq(vaultBalanceDelta, expectedFee);
        assertEq(treasuryDelta + regentDelta, expectedFee);
    }

    function testTreasuryWithdrawIsAccessControlled() external {
        _simulateSwap(poolKey, true, -100e18, -100e18, 80e18);

        uint256 halfFee = poolManager.lastTakeAmount() / 2;

        vm.expectRevert("ONLY_TREASURY");
        vault.withdrawTreasury(poolId, address(quoteToken), halfFee, TREASURY);

        vm.prank(TREASURY);
        vault.withdrawTreasury(poolId, address(quoteToken), halfFee, TREASURY);

        assertEq(quoteToken.balanceOf(TREASURY), halfFee);
        assertEq(vault.treasuryAccrued(poolId, address(quoteToken)), 0);
    }

    function testRealPoolManagerExactInputSwapAccruesExpectedFee() external {
        vm.recordLogs();
        realHarness.swap(
            realPoolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -10e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        _assertRealSwapFee(realPoolId, true, vm.getRecordedLogs());
    }

    function testRealPoolManagerExactOutputSwapAccruesExpectedFee() external {
        vm.recordLogs();
        realHarness.swap(
            realPoolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: 5e18,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );

        _assertRealSwapFee(realPoolId, false, vm.getRecordedLogs());
    }

    function _registerPool(address launchTokenAddress, address quoteTokenAddress)
        internal
        returns (bytes32)
    {
        return registry.registerPool(
            LaunchFeeRegistry.PoolRegistration({
                launchToken: launchTokenAddress,
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

    function _sortedPoolKey(address tokenA, address tokenB, address hookAddress)
        internal
        pure
        returns (PoolKey memory)
    {
        (address currency0, address currency1) =
            tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });
    }

    function _simulateSwap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        int128 amount0,
        int128 amount1
    )
        internal
        returns (
            bytes4 beforeSelector,
            BeforeSwapDelta beforeDelta,
            bytes4 afterSelector,
            int128 afterDelta
        )
    {
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

    function _assertSwapFee(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        int128 amount0,
        int128 amount1
    ) internal {
        (uint256 baseAmount, bool quoteIsSpecified) =
            _expectedQuoteFeeBaseAmount(key, zeroForOne, amountSpecified, amount0, amount1);
        uint256 expectedFee = baseAmount * FEE_BPS / 10_000;

        bytes32 id = PoolId.unwrap(key.toId());
        (
            bytes4 beforeSelector,
            BeforeSwapDelta beforeDelta,
            bytes4 afterSelector,
            int128 afterDelta
        ) = _simulateSwap(key, zeroForOne, amountSpecified, amount0, amount1);

        assertEq(beforeSelector, IHooks.beforeSwap.selector);
        assertEq(afterSelector, IHooks.afterSwap.selector);
        if (quoteIsSpecified) {
            assertEq(uint128(BeforeSwapDeltaLibrary.getSpecifiedDelta(beforeDelta)), expectedFee);
            assertEq(uint128(afterDelta), 0);
        } else {
            assertEq(uint128(BeforeSwapDeltaLibrary.getSpecifiedDelta(beforeDelta)), 0);
            assertEq(uint128(afterDelta), expectedFee);
        }
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(beforeDelta), 0);
        assertEq(poolManager.lastTakeCurrency(), address(quoteToken));
        assertEq(poolManager.lastTakeRecipient(), address(vault));
        assertEq(poolManager.lastTakeAmount(), expectedFee);
        assertEq(quoteToken.balanceOf(address(vault)), expectedFee);

        _assertSplitFee(id, address(quoteToken), expectedFee / 2);
        _assertSplitFee(id, address(launchToken), 0);
    }

    function _expectedQuoteFeeBaseAmount(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        int128 amount0,
        int128 amount1
    ) internal view returns (uint256 amount, bool quoteIsSpecified) {
        bool exactInput = amountSpecified < 0;
        bool specifiedCurrency0 = exactInput == zeroForOne;
        address specifiedCurrency =
            specifiedCurrency0 ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        quoteIsSpecified = specifiedCurrency == address(quoteToken);

        if (quoteIsSpecified) {
            return
                (amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified), true);
        }

        bool unspecifiedCurrency0 = !specifiedCurrency0;
        int128 chargedAmount = unspecifiedCurrency0 ? amount0 : amount1;
        if (chargedAmount < 0) {
            chargedAmount = -chargedAmount;
        }
        amount = uint128(chargedAmount);
    }

    function _assertSplitFee(bytes32 id, address token, uint256 share) internal view {
        assertEq(vault.treasuryAccrued(id, token), share);
        assertEq(vault.regentAccrued(id, token), share);
    }

    function _assertRealSwapFee(bytes32 id, bool exactInput, Vm.Log[] memory entries)
        internal
        view
    {
        bytes32 eventTopic = keccak256(
            "SwapFeeAccrued(bytes32,address,address,uint256,uint256,uint256,uint256,bool)"
        );
        bool found;
        uint256 totalFee;
        uint256 treasuryFee;
        uint256 regentFee;
        bool eventExactInput;

        for (uint256 i = 0; i < entries.length; ++i) {
            if (
                entries[i].emitter == address(realHook) && entries[i].topics.length == 4
                    && entries[i].topics[0] == eventTopic
            ) {
                found = true;
                assertEq(entries[i].topics[1], id);
                assertEq(address(uint160(uint256(entries[i].topics[3]))), address(realQuoteToken));
                (, totalFee, treasuryFee, regentFee, eventExactInput) =
                    abi.decode(entries[i].data, (uint256, uint256, uint256, uint256, bool));
                assertEq(eventExactInput, exactInput);
                break;
            }
        }

        assertTrue(found);
        assertEq(realVault.treasuryAccrued(id, address(realQuoteToken)), treasuryFee);
        assertEq(realVault.regentAccrued(id, address(realQuoteToken)), regentFee);
        assertEq(realQuoteToken.balanceOf(address(realVault)), totalFee);
        assertEq(realVault.treasuryAccrued(id, address(realLaunchToken)), 0);
        assertEq(realVault.regentAccrued(id, address(realLaunchToken)), 0);
    }
}
