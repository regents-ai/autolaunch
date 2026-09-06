// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";

library SafeToken {
    error TokenCallFailed(address token, bytes4 selector);
    error InvalidTokenReturn(address token, bytes4 selector);

    function balanceOf(IERC20 token, address account) internal view returns (uint256 value) {
        // Low-level calls accept both standard boolean returns and the permitted empty ERC-20 return.
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory data) = address(token).staticcall(abi.encodeCall(token.balanceOf, (account)));
        if (!success) revert TokenCallFailed(address(token), token.balanceOf.selector);
        if (data.length != 32) revert InvalidTokenReturn(address(token), token.balanceOf.selector);
        value = abi.decode(data, (uint256));
    }

    function allowance(IERC20 token, address owner, address spender) internal view returns (uint256 value) {
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory data) = address(token).staticcall(abi.encodeCall(token.allowance, (owner, spender)));
        if (!success) revert TokenCallFailed(address(token), token.allowance.selector);
        if (data.length != 32) revert InvalidTokenReturn(address(token), token.allowance.selector);
        value = abi.decode(data, (uint256));
    }

    function approve(IERC20 token, address spender, uint256 amount) internal {
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory data) = address(token).call(abi.encodeCall(token.approve, (spender, amount)));
        if (!success) revert TokenCallFailed(address(token), token.approve.selector);
        if (data.length != 0 && (data.length != 32 || !abi.decode(data, (bool)))) {
            revert InvalidTokenReturn(address(token), token.approve.selector);
        }
    }
}
