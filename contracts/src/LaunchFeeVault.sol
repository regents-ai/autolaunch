// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";
import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";

contract LaunchFeeVault is Owned {
    using SafeTransferLib for address;

    LaunchFeeRegistry public immutable registryContract;
    address public hook;
    address public canonicalLaunchToken;
    address public canonicalQuoteToken;

    mapping(bytes32 => mapping(address => uint256)) public treasuryAccrued;
    mapping(bytes32 => mapping(address => uint256)) public regentAccrued;

    event HookSet(address indexed hook);
    event FeeAccrued(
        bytes32 indexed poolId,
        address indexed currency,
        uint256 treasuryAmount,
        uint256 regentAmount
    );
    event TreasuryWithdrawn(
        bytes32 indexed poolId, address indexed currency, address indexed recipient, uint256 amount
    );
    event RegentShareWithdrawn(
        bytes32 indexed poolId, address indexed currency, address indexed recipient, uint256 amount
    );
    event CanonicalTokensSet(address indexed launchToken, address indexed quoteToken);

    constructor(address owner_, address registry_) Owned(owner_) {
        require(registry_ != address(0), "REGISTRY_ZERO");
        registryContract = LaunchFeeRegistry(registry_);
    }

    function setHook(address hook_) external onlyOwner {
        require(hook_ != address(0), "HOOK_ZERO");
        require(hook == address(0), "HOOK_ALREADY_SET");
        hook = hook_;
        emit HookSet(hook_);
    }

    function setCanonicalTokens(address launchToken_, address quoteToken_) external onlyOwner {
        require(launchToken_ != address(0), "TOKEN_ZERO");
        require(quoteToken_ != address(0), "QUOTE_TOKEN_ZERO");
        require(launchToken_ != quoteToken_, "POOL_CURRENCIES_EQUAL");
        require(canonicalLaunchToken == address(0), "CANONICAL_TOKENS_ALREADY_SET");

        canonicalLaunchToken = launchToken_;
        canonicalQuoteToken = quoteToken_;
        emit CanonicalTokensSet(launchToken_, quoteToken_);
    }

    function recordAccrual(
        bytes32 poolId,
        address currency,
        uint256 treasuryAmount,
        uint256 regentAmount
    ) external {
        require(msg.sender == hook, "ONLY_HOOK");

        LaunchFeeRegistry.PoolConfig memory config = registryContract.getPoolConfig(poolId);
        require(config.hookEnabled, "HOOK_DISABLED");
        require(currency == config.quoteToken, "CURRENCY_MISMATCH");

        treasuryAccrued[poolId][currency] += treasuryAmount;
        regentAccrued[poolId][currency] += regentAmount;

        emit FeeAccrued(poolId, currency, treasuryAmount, regentAmount);
    }

    function withdrawTreasury(bytes32 poolId, address currency, uint256 amount, address recipient)
        external
    {
        require(recipient != address(0), "RECIPIENT_ZERO");
        require(msg.sender == registryContract.treasuryRecipient(poolId), "ONLY_TREASURY");

        uint256 available = treasuryAccrued[poolId][currency];
        require(available >= amount, "TREASURY_BALANCE_LOW");

        unchecked {
            treasuryAccrued[poolId][currency] = available - amount;
        }

        emit TreasuryWithdrawn(poolId, currency, recipient, amount);
        currency.safeTransfer(recipient, amount);
    }

    function withdrawRegentShare(
        bytes32 poolId,
        address currency,
        uint256 amount,
        address recipient
    ) external {
        require(recipient != address(0), "RECIPIENT_ZERO");
        require(msg.sender == registryContract.regentRecipient(poolId), "ONLY_REGENT_RECIPIENT");

        uint256 available = regentAccrued[poolId][currency];
        require(available >= amount, "REGENT_BALANCE_LOW");

        unchecked {
            regentAccrued[poolId][currency] = available - amount;
        }

        emit RegentShareWithdrawn(poolId, currency, recipient, amount);
        currency.safeTransfer(recipient, amount);
    }

    receive() external payable {
        revert("ETH_NOT_ACCEPTED");
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == canonicalLaunchToken || token == canonicalQuoteToken;
    }
}
