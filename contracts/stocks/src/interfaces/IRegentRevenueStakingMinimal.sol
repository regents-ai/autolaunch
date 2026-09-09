// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IRegentRevenueStakingMinimal
/// @notice The exact live REGENT staking surface the hook's REGENT bucket settles into, transcribed
///         from the frozen `contracts/v1/src/interfaces/IRegentRevenueStakingMinimal.sol`.
/// @dev `sourceTag` and `sourceRef` are event metadata in the pinned live implementation. The hook
///      passes `bytes32("autolaunch-stocks")` and the pool id.
interface IRegentRevenueStakingMinimal {
    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256 received);
}
