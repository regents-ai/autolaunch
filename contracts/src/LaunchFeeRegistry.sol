// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract LaunchFeeRegistry is Owned {
    using PoolIdLibrary for PoolKey;

    struct PoolRegistration {
        address launchToken;
        address quoteToken;
        address treasury;
        address regentRecipient;
        uint24 poolFee;
        int24 tickSpacing;
        address poolManager;
        address hook;
    }

    struct PoolConfig {
        address launchToken;
        address quoteToken;
        address treasury;
        address regentRecipient;
        address currency0;
        address currency1;
        uint24 poolFee;
        int24 tickSpacing;
        address poolManager;
        address hook;
        bool hookEnabled;
    }

    mapping(bytes32 => PoolConfig) private poolConfigs;

    event PoolRegistered(
        bytes32 indexed poolId,
        address indexed launchToken,
        address indexed quoteToken,
        address treasury,
        address poolManager,
        address hook
    );
    event HookEnabledSet(bytes32 indexed poolId, bool hookEnabled);

    constructor(address owner_) Owned(owner_) {}

    function registerPool(PoolRegistration memory registration)
        external
        onlyOwner
        returns (bytes32 poolId)
    {
        require(registration.launchToken != address(0), "TOKEN_ZERO");
        require(registration.quoteToken != address(0), "QUOTE_TOKEN_ZERO");
        require(registration.treasury != address(0), "TREASURY_ZERO");
        require(registration.regentRecipient != address(0), "REGENT_RECIPIENT_ZERO");
        require(registration.poolFee <= 1_000_000, "POOL_FEE_INVALID");
        require(registration.tickSpacing > 0, "TICK_SPACING_INVALID");
        require(registration.poolManager != address(0), "POOL_MANAGER_ZERO");
        require(registration.hook != address(0), "HOOK_ZERO");

        (Currency currency0, Currency currency1) =
            _sortCurrencies(registration.launchToken, registration.quoteToken);

        poolId = PoolId.unwrap(
            PoolKey({
                    currency0: currency0,
                    currency1: currency1,
                    fee: registration.poolFee,
                    tickSpacing: registration.tickSpacing,
                    hooks: IHooks(registration.hook)
                }).toId()
        );

        PoolConfig storage existing = poolConfigs[poolId];
        require(existing.launchToken == address(0), "POOL_ALREADY_REGISTERED");

        poolConfigs[poolId] = PoolConfig({
            launchToken: registration.launchToken,
            quoteToken: registration.quoteToken,
            treasury: registration.treasury,
            regentRecipient: registration.regentRecipient,
            currency0: Currency.unwrap(currency0),
            currency1: Currency.unwrap(currency1),
            poolFee: registration.poolFee,
            tickSpacing: registration.tickSpacing,
            poolManager: registration.poolManager,
            hook: registration.hook,
            hookEnabled: true
        });

        emit PoolRegistered(
            poolId,
            registration.launchToken,
            registration.quoteToken,
            registration.treasury,
            registration.poolManager,
            registration.hook
        );
    }

    function setHookEnabled(bytes32 poolId, bool hookEnabled) external onlyOwner {
        PoolConfig storage config = _poolStorageOrRevert(poolId);
        config.hookEnabled = hookEnabled;
        emit HookEnabledSet(poolId, hookEnabled);
    }

    function getPoolConfig(bytes32 poolId) external view returns (PoolConfig memory) {
        return _poolOrRevert(poolId);
    }

    function isRegisteredPool(bytes32 poolId) external view returns (bool) {
        return poolConfigs[poolId].launchToken != address(0);
    }

    function treasuryRecipient(bytes32 poolId) external view returns (address) {
        return _poolOrRevert(poolId).treasury;
    }

    function regentRecipient(bytes32 poolId) external view returns (address) {
        return _poolOrRevert(poolId).regentRecipient;
    }

    function quoteToken(bytes32 poolId) external view returns (address) {
        return _poolOrRevert(poolId).quoteToken;
    }

    function computePoolId(
        address launchToken,
        address quoteToken_,
        uint24 poolFee,
        int24 tickSpacing,
        address hook
    ) external pure returns (bytes32) {
        (Currency currency0, Currency currency1) = _sortCurrencies(launchToken, quoteToken_);
        return PoolId.unwrap(
            PoolKey({
                    currency0: currency0,
                    currency1: currency1,
                    fee: poolFee,
                    tickSpacing: tickSpacing,
                    hooks: IHooks(hook)
                }).toId()
        );
    }

    function _poolOrRevert(bytes32 poolId) internal view returns (PoolConfig memory config) {
        config = poolConfigs[poolId];
        require(config.launchToken != address(0), "POOL_NOT_REGISTERED");
    }

    function _poolStorageOrRevert(bytes32 poolId)
        internal
        view
        returns (PoolConfig storage config)
    {
        config = poolConfigs[poolId];
        require(config.launchToken != address(0), "POOL_NOT_REGISTERED");
    }

    function _sortCurrencies(address launchToken, address quoteToken_)
        internal
        pure
        returns (Currency currency0, Currency currency1)
    {
        Currency launchCurrency = Currency.wrap(launchToken);
        Currency quoteCurrency = Currency.wrap(quoteToken_);
        require(!(launchCurrency == quoteCurrency), "POOL_CURRENCIES_EQUAL");

        (currency0, currency1) = launchCurrency < quoteCurrency
            ? (launchCurrency, quoteCurrency)
            : (quoteCurrency, launchCurrency);
    }
}
