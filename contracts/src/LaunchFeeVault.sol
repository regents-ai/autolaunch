// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {LaunchFeeRegistry} from "src/LaunchFeeRegistry.sol";
import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";

contract LaunchFeeVault is Owned {
    using SafeTransferLib for address;

    LaunchFeeRegistry public immutable registryContract;
    address public hook;

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

    constructor(address owner_, address registry_) Owned(owner_) {
        require(registry_ != address(0), "REGISTRY_ZERO");
        registryContract = LaunchFeeRegistry(registry_);
    }

    function setHook(address hook_) external onlyOwner {
        require(hook_ != address(0), "HOOK_ZERO");
        hook = hook_;
        emit HookSet(hook_);
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
        require(
            currency == config.launchToken || currency == config.quoteToken, "CURRENCY_MISMATCH"
        );

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

    receive() external payable {}
}
