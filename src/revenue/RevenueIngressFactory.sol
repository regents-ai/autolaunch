// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {RevenueIngressAccount} from "src/revenue/RevenueIngressAccount.sol";

contract RevenueIngressFactory is Owned {
    mapping(address => address[]) public ingressesBySplitter;

    event IngressCreated(
        address indexed splitter,
        address indexed ingress,
        address indexed ingressOwner,
        bytes32 ingressId,
        bytes32 salt
    );

    constructor(address owner_) Owned(owner_) {}

    function createIngressAccount(
        address splitter,
        address usdc,
        address ingressOwner,
        bytes32 ingressId,
        bytes32 salt
    ) external returns (address ingress) {
        require(splitter != address(0), "SPLITTER_ZERO");
        require(usdc != address(0), "USDC_ZERO");
        require(ingressOwner != address(0), "OWNER_ZERO");
        RevenueIngressAccount deployed =
            new RevenueIngressAccount{salt: salt}(splitter, usdc, ingressId, ingressOwner);
        ingress = address(deployed);
        ingressesBySplitter[splitter].push(ingress);

        emit IngressCreated(splitter, ingress, ingressOwner, ingressId, salt);
    }

    function ingressCount(address splitter) external view returns (uint256) {
        return ingressesBySplitter[splitter].length;
    }

    function ingressAt(address splitter, uint256 index) external view returns (address) {
        return ingressesBySplitter[splitter][index];
    }
}
