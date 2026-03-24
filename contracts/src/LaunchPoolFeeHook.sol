// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";
import {LaunchFeeVault} from "src/LaunchFeeVault.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

contract LaunchPoolFeeHook is Owned, IHooks {
    using Hooks for IHooks;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for uint256;

    uint256 public constant TOTAL_FEE_BPS = 200;
    uint256 public constant TREASURY_FEE_BPS = 100;
    uint256 public constant REGENT_MULTISIG_FEE_BPS = 100;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint160 public constant REQUIRED_HOOK_FLAGS =
        Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    struct SwapFeeComputation {
        address feeCurrency;
        uint256 quoteAmount;
        uint256 totalFee;
        uint256 treasuryFee;
        uint256 regentFee;
        bool exactInput;
    }

    LaunchFeeRegistry public immutable registryContract;
    LaunchFeeVault public immutable vaultContract;
    IPoolManager public immutable poolManagerContract;

    error HookNotImplemented();

    event SwapFeeAccrued(
        bytes32 indexed poolId,
        address indexed payer,
        address indexed currency,
        uint256 quoteAmount,
        uint256 totalFee,
        uint256 treasuryFee,
        uint256 regentFee,
        bool exactInput
    );

    constructor(address owner_, address poolManager_, address registry_, address vault_)
        Owned(owner_)
    {
        require(poolManager_ != address(0), "POOL_MANAGER_ZERO");
        require(registry_ != address(0), "REGISTRY_ZERO");
        require(vault_ != address(0), "VAULT_ZERO");

        poolManagerContract = IPoolManager(poolManager_);
        registryContract = LaunchFeeRegistry(registry_);
        vaultContract = LaunchFeeVault(payable(vault_));

        IHooks(address(this)).validateHookPermissions(_permissions());
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external returns (bytes4, int128) {
        require(msg.sender == address(poolManagerContract), "ONLY_POOL_MANAGER");

        bytes32 poolId = PoolId.unwrap(key.toId());
        LaunchFeeRegistry.PoolConfig memory config = _validatePool(poolId);
        SwapFeeComputation memory feeData = _computeSwapFee(key, params, delta, config.quoteToken);
        if (feeData.totalFee == 0) {
            return (IHooks.afterSwap.selector, 0);
        }

        _emitSwapFeeAccrued(
            poolId,
            sender,
            feeData.feeCurrency,
            feeData.quoteAmount,
            feeData.totalFee,
            feeData.treasuryFee,
            feeData.regentFee,
            feeData.exactInput
        );

        poolManagerContract.take(
            Currency.wrap(feeData.feeCurrency), address(vaultContract), feeData.totalFee
        );
        vaultContract.recordAccrual(
            poolId, feeData.feeCurrency, feeData.treasuryFee, feeData.regentFee
        );

        return (IHooks.afterSwap.selector, feeData.totalFee.toInt128());
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function _permissions() internal pure returns (Hooks.Permissions memory permissions) {
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    function _computeSwapFee(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        address quoteToken
    ) internal pure returns (SwapFeeComputation memory feeData) {
        int128 quoteAmount = Currency.unwrap(key.currency0) == quoteToken
            ? delta.amount0()
            : delta.amount1();

        if (quoteAmount < 0) quoteAmount = -quoteAmount;

        feeData.feeCurrency = quoteToken;
        feeData.quoteAmount = uint128(quoteAmount);
        feeData.totalFee = feeData.quoteAmount * TOTAL_FEE_BPS / BPS_DENOMINATOR;
        feeData.treasuryFee = feeData.quoteAmount * TREASURY_FEE_BPS / BPS_DENOMINATOR;
        feeData.regentFee = feeData.quoteAmount * REGENT_MULTISIG_FEE_BPS / BPS_DENOMINATOR;
        if (feeData.treasuryFee + feeData.regentFee > feeData.totalFee) {
            feeData.regentFee = feeData.totalFee - feeData.treasuryFee;
        }
        feeData.exactInput = params.amountSpecified < 0;
    }

    function _validatePool(bytes32 poolId)
        internal
        view
        returns (LaunchFeeRegistry.PoolConfig memory config)
    {
        config = registryContract.getPoolConfig(poolId);
        require(config.hookEnabled, "HOOK_DISABLED");
        require(config.poolManager == msg.sender, "POOL_MANAGER_MISMATCH");
        require(config.hook == address(this), "HOOK_MISMATCH");
        require(config.quoteToken != address(0), "QUOTE_TOKEN_ZERO");
    }

    function _emitSwapFeeAccrued(
        bytes32 poolId,
        address sender,
        address feeCurrency,
        uint256 quoteAmount,
        uint256 totalFee,
        uint256 treasuryFee,
        uint256 regentFee,
        bool exactInput
    ) internal {
        emit SwapFeeAccrued(
            poolId, sender, feeCurrency, quoteAmount, totalFee, treasuryFee, regentFee, exactInput
        );
    }
}
