// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ILaunchFeeVaultMinimal {
    function withdrawTreasury(bytes32 poolId, address currency, uint256 amount, address recipient)
        external;

    function withdrawRegentShare(
        bytes32 poolId,
        address currency,
        uint256 amount,
        address recipient
    ) external;
}
