// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IB20AssetMinimal
/// @notice The part of Base's B20 Asset precompile (base-std v1.0.0 `IB20` and ERC-8056
///         `IScaledUIAmountNewUIMultiplier`) this component reads.
/// @dev `effectiveAt` is when a scheduled multiplier change takes effect; it is in the past or zero
///      when none is pending.
interface IB20AssetMinimal {
    function decimals() external view returns (uint8);
    function effectiveAt() external view returns (uint256);
}
