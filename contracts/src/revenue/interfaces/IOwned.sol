// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IOwned {
    function owner() external view returns (address);
}
