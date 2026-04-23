// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TestnetMintableERC20 is ERC20, Ownable {
    uint8 private immutable _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address owner_,
        address initialHolder_,
        uint256 initialSupply_
    ) ERC20(name_, symbol_) Ownable(owner_) {
        require(owner_ != address(0), "OWNER_ZERO");

        _decimals = decimals_;

        if (initialSupply_ > 0) {
            require(initialHolder_ != address(0), "INITIAL_HOLDER_ZERO");
            _mint(initialHolder_, initialSupply_);
        }
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "TO_ZERO");
        _mint(to, amount);
    }
}
