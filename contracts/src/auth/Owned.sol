// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

abstract contract Owned {
    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    constructor(address owner_) {
        require(owner_ != address(0), "OWNER_ZERO");
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "OWNER_ZERO");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function _onlyOwner() internal view {
        require(msg.sender == owner, "ONLY_OWNER");
    }
}
