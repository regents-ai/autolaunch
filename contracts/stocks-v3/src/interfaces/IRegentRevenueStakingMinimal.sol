// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IRegentRevenueStakingMinimal
/// @notice The exact live REGENT staking surface this component settles into: the hook's REGENT
///         bucket and every memestock splitter's USDC protocol share, through `depositUSDC`
///         (transcribed from the frozen `contracts/v1/src/interfaces/IRegentRevenueStakingMinimal.sol`).
/// @dev `sourceTag` and `sourceRef` are event metadata in the pinned live implementation. The hook
///      passes `bytes32("autolaunch-stocks")` and the pool id; a splitter passes its MEMESTOCK and
///      the recognition reference.
interface IRegentRevenueStakingMinimal {
    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256 received);
}
