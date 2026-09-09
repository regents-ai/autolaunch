// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title ISubjectSplitterMinimal
/// @notice The two reads and the one deposit this component makes on an Agent `SubjectSplitterV1`.
interface ISubjectSplitterMinimal {
    function subject() external view returns (address);
    function regent() external view returns (address);
    /// @notice Recognize exactly `amount` of `token`, pulled from the caller inside this call.
    function depositRecognizedRevenue(address token, uint256 amount, bytes32 revenueRef) external;
}
