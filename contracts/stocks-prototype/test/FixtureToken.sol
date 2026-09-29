// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @dev Generic test asset only. This is NOT admitted-stock/B20 compatibility evidence.
contract FixtureToken is ERC20 {
    constructor(string memory label, uint8 precision) ERC20(label, label, precision) {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}
