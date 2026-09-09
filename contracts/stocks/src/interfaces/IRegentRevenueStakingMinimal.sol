// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IRegentRevenueStakingMinimal
/// @notice The exact live REGENT staking surface this component settles into: the hook's REGENT
///         bucket through `depositUSDC` (transcribed from the frozen
///         `contracts/v1/src/interfaces/IRegentRevenueStakingMinimal.sol`) and the launch fee through
///         `fundRegentRewards`.
/// @dev `sourceTag` and `sourceRef` are event metadata in the pinned live implementation. The hook
///      passes `bytes32("autolaunch-stocks")` and the pool id. `fundRegentRewards` is permissionless
///      on the live contract, pulls exactly `amount` of its stake token (REGENT) from `msg.sender`
///      and credits it to stakers as rewards; it returns the amount that arrived.
interface IRegentRevenueStakingMinimal {
    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256 received);
    function fundRegentRewards(uint256 amount) external returns (uint256 received);
}
