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

        registry = new LaunchFeeRegistry(OWNER);
        vault = new LaunchFeeVault(OWNER, address(registry));
        hookDeployer = new MockHookDeployer();
        poolManager = new MockHookPoolManager();
        hook = hookDeployer.deploy(OWNER, address(poolManager), address(registry), address(vault));

        vault.setHook(address(hook));
        launchToken = new MintableERC20Mock("Launch", "LAUNCH");
        quoteToken = new MintableERC20Mock("Quote", "Q");
        poolId = _registerPool(address(launchToken), address(quoteToken));
        realPoolManager = new PoolManager(OWNER);
        realRegistry = new LaunchFeeRegistry(OWNER);
        realVault = new LaunchFeeVault(OWNER, address(realRegistry));
        realHook =
            hookDeployer.deploy(OWNER, address(realPoolManager), address(realRegistry), address(realVault));
        realVault.setHook(address(realHook));
        realLaunchToken = new MintableERC20Mock("Real Launch", "RLAUNCH");
        realQuoteToken = new MintableERC20Mock("Real Quote", "RQUOTE");
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

        poolKey = _poolKey(address(launchToken), address(quoteToken));
        realPoolKey = _sortedPoolKey(address(realLaunchToken), address(realQuoteToken), address(realHook));
        launchToken.mint(address(poolManager), 1000e18);
        quoteToken.mint(address(poolManager), 1000e18);
        realHarness = new RealPoolManagerHarness(realPoolManager);
        realLaunchToken.mint(address(realHarness), 10_000e18);
        realQuoteToken.mint(address(realHarness), 10_000e18);
        realPoolManager.initialize(realPoolKey, TickMath.getSqrtPriceAtTick(0));
        realHarness.modifyLiquidity(
            realPoolKey,
            ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: 1_000e18, salt: bytes32(0)
            })
        );
    }

    function testZeroForOneExactInputChargesCurrency1() external {
        _assertSwapFee(poolKey, true, -100e18, -100e18, 80e18);
    }

    function testZeroForOneExactOutputChargesCurrency0() external {
        _assertSwapFee(poolKey, true, 90e18, -120e18, 90e18);
    }

    function testOneForZeroExactInputChargesCurrency0() external {
        _assertSwapFee(poolKey, false, -100e18, 70e18, -100e18);
    }

    function testOneForZeroExactOutputChargesCurrency1() external {
        _assertSwapFee(poolKey, false, 80e18, 80e18, -110e18);
    }

    function testRejectsPoolsWithoutUsdcQuoteToken() external {
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

    function testTreasuryWithdrawIsAccessControlled() external {
        _simulateSwap(
            poolKey,
            true,
            -100e18,
            -100e18,
            80e18
        );

        uint256 halfFee = (80e18 * FEE_BPS / 10_000) / 2;

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

        _assertRealSwapFee(realPoolKey, realPoolId, true, true, vm.getRecordedLogs());
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

        _assertRealSwapFee(realPoolKey, realPoolId, false, false, vm.getRecordedLogs());
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

    function _assertSwapFee(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        int128 amount0,
        int128 amount1
    ) internal {
        (address expectedCurrency, uint256 baseAmount) =
            _expectedChargedCurrencyAndAmount(key, zeroForOne, amountSpecified < 0, amount0, amount1);
        uint256 expectedFee = baseAmount * FEE_BPS / 10_000;

        bytes32 id = PoolId.unwrap(key.toId());
        (bytes4 selector, int128 feeDelta) =
            _simulateSwap(key, zeroForOne, amountSpecified, amount0, amount1);

        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(uint128(feeDelta), expectedFee);
        assertEq(poolManager.lastTakeCurrency(), expectedCurrency);
        assertEq(poolManager.lastTakeRecipient(), address(vault));
        assertEq(poolManager.lastTakeAmount(), expectedFee);
        assertEq(
            MintableERC20Mock(expectedCurrency).balanceOf(address(vault)),
            expectedFee
        );

        _assertSplitFee(id, expectedCurrency, expectedFee / 2);
    }

    function _expectedChargedCurrencyAndAmount(
        PoolKey memory key,
        bool zeroForOne,
        bool exactInput,
        int128 amount0,
        int128 amount1
    ) internal pure returns (address currency, uint256 amount) {
        bool chargeCurrency0 = exactInput ? !zeroForOne : zeroForOne;
        currency = chargeCurrency0 ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        int128 chargedAmount = chargeCurrency0 ? amount0 : amount1;
        if (chargedAmount < 0) {
            chargedAmount = -chargedAmount;
        }
        amount = uint128(chargedAmount);
    }

    function _assertSplitFee(bytes32 id, address token, uint256 share) internal view {
        assertEq(vault.treasuryAccrued(id, token), share);
        assertEq(vault.regentAccrued(id, token), share);
    }

    function _assertRealSwapFee(
        PoolKey memory key,
        bytes32 id,
        bool zeroForOne,
        bool exactInput,
        Vm.Log[] memory entries
    ) internal view {
        address expectedCurrency =
            Currency.unwrap((exactInput ? !zeroForOne : zeroForOne) ? key.currency0 : key.currency1);
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
                assertEq(address(uint160(uint256(entries[i].topics[3]))), expectedCurrency);
                (, totalFee, treasuryFee, regentFee, eventExactInput) = abi.decode(
                    entries[i].data, (uint256, uint256, uint256, uint256, bool)
                );
                assertEq(eventExactInput, exactInput);
                break;
            }
        }

        assertTrue(found);
        assertEq(realVault.treasuryAccrued(id, expectedCurrency), treasuryFee);
        assertEq(realVault.regentAccrued(id, expectedCurrency), regentFee);
        assertEq(MintableERC20Mock(expectedCurrency).balanceOf(address(realVault)), totalFee);

        address otherCurrency = expectedCurrency == address(realLaunchToken)
            ? address(realQuoteToken)
            : address(realLaunchToken);
        assertEq(realVault.treasuryAccrued(id, otherCurrency), 0);
        assertEq(realVault.regentAccrued(id, otherCurrency), 0);
    }
}
