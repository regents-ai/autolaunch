// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IERC20Standard
/// @notice The canonical ERC-20 surface the website prepares against for STOCK and USDC. Compiled
///         only for its ABI: the lab config carries this shape, not a fixture's, so the site never
///         learns a fixture-specific mutability or extension.
interface IERC20Standard {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}
