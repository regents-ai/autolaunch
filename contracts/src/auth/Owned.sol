// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";

abstract contract Owned {
    using SafeTransferLib for address;

    address public owner;
    address public pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event NativeRescued(address indexed recipient, uint256 amount);
    event UnsupportedTokenRescued(address indexed token, uint256 amount, address indexed recipient);

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
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() public {
        require(msg.sender == pendingOwner, "ONLY_PENDING_OWNER");

        address previousOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);

        emit OwnershipTransferred(previousOwner, owner);
    }

    function rescueNative(address recipient) external onlyOwner {
        require(recipient != address(0), "RECIPIENT_ZERO");

        uint256 amount = address(this).balance;
        require(amount != 0, "NOTHING_TO_RESCUE");

        address(0).safeTransfer(recipient, amount);
        emit NativeRescued(recipient, amount);
    }

    function rescueUnsupportedToken(address token, uint256 amount, address recipient)
        external
        onlyOwner
    {
        require(token != address(0), "TOKEN_ZERO");
        require(!_isProtectedToken(token), "PROTECTED_TOKEN");
        require(amount != 0, "AMOUNT_ZERO");
        require(recipient != address(0), "RECIPIENT_ZERO");

        token.safeTransfer(recipient, amount);
        emit UnsupportedTokenRescued(token, amount, recipient);
    }

    function _onlyOwner() internal view {
        require(msg.sender == owner, "ONLY_OWNER");
    }

    function _isProtectedToken(address) internal view virtual returns (bool) {
        return false;
    }
}
