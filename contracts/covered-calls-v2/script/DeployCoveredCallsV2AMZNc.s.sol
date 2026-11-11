// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {CoveredCallsV2} from "../src/CoveredCallsV2.sol";

/// @title DeployCoveredCallsV2AMZNc
/// @notice Sends deploy/packet.json's one transaction: CoveredCallsV2 for AMZNc on Base. `new … {salt: …}`
///         in a broadcast goes through the deterministic deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C,
///         so the contract lands at the packet's address whoever sends it. Every constant is the packet's;
///         deploy/rehearse.sh runs this script on a Base copy and checks the transaction it sends has the
///         packet's recipient, value and data, byte for byte. It moves no funds and grants no roles; the contract has no owner.
/// @dev Deploying is a protected action: broadcast only on Sean's go naming it.
contract DeployCoveredCallsV2AMZNc is Script {
    address internal constant AMZNC = 0xb200000000000000000000d9192b6B456483C2E8;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant LIVE_STAKING = 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5;
    /// @notice keccak256("autolaunch.covered-calls.v2.AMZNc")
    bytes32 internal constant SALT = 0x791e83d46ce091730917e3ce8fec811133358eeb150b8ac039f4ab240eb9b4ae;
    bytes32 internal constant INIT_CODE_KECCAK = 0xc8d65e4411ca8dd6a93c7c8121e6da717e7b4b71cd485f25a768e6903a1c0dc8;
    address internal constant PREDICTED = 0xee5B494B7974FeA38Add81a92eA3C794AdB8DDE6;
    bytes32 internal constant RUNTIME_CODE_KECCAK = 0x96528893fe765ba369a54e616f68337d0a4d87689856f19baaca62c9621d51a8;

    error WrongChain(uint256 chainId);
    error AlreadyDeployed(address at);
    error NotThePacketsInitCode(bytes32 initCodeKeccak);
    error NotThePacketsAddress(address deployed);
    error NotThePacketsCode(bytes32 codeKeccak);
    error NotThePacketsReads();

    function run() external returns (CoveredCallsV2 calls) {
        if (block.chainid != 8453) revert WrongChain(block.chainid);
        if (PREDICTED.code.length != 0) revert AlreadyDeployed(PREDICTED);
        bytes32 initCode =
            keccak256(abi.encodePacked(type(CoveredCallsV2).creationCode, abi.encode(AMZNC, USDC, LIVE_STAKING)));
        if (initCode != INIT_CODE_KECCAK) revert NotThePacketsInitCode(initCode);

        vm.broadcast();
        calls = new CoveredCallsV2{salt: SALT}(AMZNC, USDC, LIVE_STAKING);

        if (address(calls) != PREDICTED) revert NotThePacketsAddress(address(calls));
        if (address(calls).codehash != RUNTIME_CODE_KECCAK) revert NotThePacketsCode(address(calls).codehash);
        if (
            calls.stock() != AMZNC || calls.usdc() != USDC || calls.staking() != LIVE_STAKING || calls.unit() != 1e8
                || calls.FEE_BPS() != 100 || calls.EXERCISE_WINDOW() != 1 days || calls.listingCount() != 0
                || calls.bidCount() != 0
        ) revert NotThePacketsReads();
        console.log("CoveredCallsV2 (AMZNc)", address(calls));
    }
}
