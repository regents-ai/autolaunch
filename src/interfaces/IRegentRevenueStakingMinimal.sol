// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IRegentRevenueStakingMinimal
/// @notice The exact live REGENT staking surface the subject splitter calls, transcribed from
///         `regent-contracts` commit `baf7553df90811b60f8c414f724514f8c1e7200f`, files
///         `src/staking/RegentRevenueStaking.sol` and
///         `src/autolaunch/revenue/interfaces/IRegentRevenueStakingMinimal.sol`.
/// @dev `sourceTag` and `sourceRef` are event metadata in the pinned live implementation: they
///      reach `_recordRevenue` and affect no accounting and no authority there. The deployed
///      runtime behind the frozen `Live staking` binding is not proved here; `DEP-045` owns that
///      proof under the separately authorized fork gate.
interface IRegentRevenueStakingMinimal {
    /// @notice Deposit USDC as recognized revenue for the live REGENT stakers.
    /// @param amount The exact USDC amount the caller has approved to this contract.
    /// @param sourceTag Event metadata. The splitter passes its SUBJECT token address.
    /// @param sourceRef Event metadata. The splitter forwards its caller's `revenueRef`.
    /// @return received The amount the implementation observed itself actually receive.
    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256 received);
}
