// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {CoveredCallsV1} from "../src/CoveredCallsV1.sol";

/// @title DeployCoveredCallsAMZNc
/// @notice Sends deploy/packet.json's one transaction: CoveredCallsV1 for AMZNc on Base. `new … {salt: …}`
///         in a broadcast goes through the deterministic deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C,
///         so the contract lands at the packet's address whoever sends it. Every constant is the packet's;
///         deploy/rehearse.sh runs this script on a Base copy and checks the transaction it sends has the
///         packet's recipient, value and data, byte for byte. It moves no funds and grants no roles; the contract has no owner.
/// @dev Deploying is a protected action: broadcast only on Sean's go naming it.
contract DeployCoveredCallsAMZNc is Script {
    address internal constant AMZNC = 0xb200000000000000000000d9192b6B456483C2E8;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant LIVE_STAKING = 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5;
    /// @notice keccak256("autolaunch.covered-calls.v1.AMZNc")
    bytes32 internal constant SALT = 0x52a9b8f155c1895a8412c0e70f3d431bfc366613b5e2c5d634d227071af13345;
    bytes32 internal constant INIT_CODE_KECCAK = 0x758462a26cd2e9dc152f89f2c13a335f9255ec811669b94b137ee0c145b24fc2;
    address internal constant PREDICTED = 0x0B2FE2810F9219bDd5e5e304DC8A1A4c84eA553E;
    bytes32 internal constant RUNTIME_CODE_KECCAK = 0x44cf180fcad6f5e1bc1c2e68df260394526edbafc67687ffab49d820fbb5448e;

    error WrongChain(uint256 chainId);
    error AlreadyDeployed(address at);
    error NotThePacketsInitCode(bytes32 initCodeKeccak);
    error NotThePacketsAddress(address deployed);
    error NotThePacketsCode(bytes32 codeKeccak);
    error NotThePacketsReads();

    function run() external returns (CoveredCallsV1 calls) {
        if (block.chainid != 8453) revert WrongChain(block.chainid);
        if (PREDICTED.code.length != 0) revert AlreadyDeployed(PREDICTED);
        bytes32 initCode =
            keccak256(abi.encodePacked(type(CoveredCallsV1).creationCode, abi.encode(AMZNC, USDC, LIVE_STAKING)));
        if (initCode != INIT_CODE_KECCAK) revert NotThePacketsInitCode(initCode);

        vm.broadcast();
        calls = new CoveredCallsV1{salt: SALT}(AMZNC, USDC, LIVE_STAKING);

        if (address(calls) != PREDICTED) revert NotThePacketsAddress(address(calls));
        if (address(calls).codehash != RUNTIME_CODE_KECCAK) revert NotThePacketsCode(address(calls).codehash);
        if (
            calls.stock() != AMZNC || calls.usdc() != USDC || calls.staking() != LIVE_STAKING || calls.unit() != 1e8
                || calls.FEE_BPS() != 100 || calls.EXERCISE_WINDOW() != 1 days
        ) revert NotThePacketsReads();
        console.log("CoveredCallsV1 (AMZNc)", address(calls));
    }
}
