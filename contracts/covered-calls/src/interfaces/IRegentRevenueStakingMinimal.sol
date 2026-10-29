// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IRegentRevenueStakingMinimal
/// @notice Live REGENT staking's USDC deposit, the path the Memestake hook already settles into
///         (transcribed from `contracts/stocks-v2/src/interfaces/IRegentRevenueStakingMinimal.sol`).
/// @dev `sourceTag` and `sourceRef` are event metadata; covered calls pass
///      `bytes32("autolaunch-covered-calls")` and the listing id.
interface IRegentRevenueStakingMinimal {
    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256 received);
}
