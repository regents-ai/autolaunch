// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IERC20Minimal
/// @notice The ERC-20 reads this component makes that Solady's `SafeTransferLib` does not provide.
interface IERC20Minimal {
    function totalSupply() external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function decimals() external view returns (uint8);
}
