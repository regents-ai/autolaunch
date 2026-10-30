// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IMemestockSplitterMinimal
/// @notice The two reads and the one deposit the hook, the launchpad and the locker make on a launch's
///         memestock splitter.
interface IMemestockSplitterMinimal {
    function memestock() external view returns (address);
    function stock() external view returns (address);
    /// @notice Recognize exactly `amount` of `token`, pulled from the caller inside this call.
    function depositRecognizedRevenue(address token, uint256 amount, bytes32 revenueRef) external;
}
