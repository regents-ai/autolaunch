// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IERC20Minimal
/// @notice The only two ERC20 reads this repository makes that Solady's `SafeTransferLib` does
///         not already provide.
/// @dev Transfers, approvals, and `balanceOf` go through `SafeTransferLib` instead, so nothing
///      here needs to model a token's return-value behavior.
interface IERC20Minimal {
    /// @notice Total supply, used to prove a launch's SUBJECT denomination before custody.
    function totalSupply() external view returns (uint256);

    /// @notice Remaining spend the splitter has granted a spender, used to prove skim cleanup.
    function allowance(address owner, address spender) external view returns (uint256);
}
