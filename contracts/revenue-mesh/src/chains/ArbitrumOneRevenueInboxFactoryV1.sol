// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RevenueInboxFactoryV1} from "../RevenueInboxFactoryV1.sol";

/// @notice Offline candidate factory with the Arbitrum One CCTP source configuration fixed in code.
/// @dev Deployment, admission, and activation remain separate founder-authorized steps.
contract ArbitrumOneRevenueInboxFactoryV1 is RevenueInboxFactoryV1 {
    uint256 public constant ARBITRUM_ONE_CHAIN_ID = 42161;
    uint32 public constant ARBITRUM_ONE_CCTP_DOMAIN = 3;
    address public constant ARBITRUM_ONE_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant ARBITRUM_ONE_TOKEN_MESSENGER_V2 = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    // The full literal makes the approved bytes32("eip155") route-identity value auditable.
    // slither-disable-next-line too-many-digits
    bytes32 public constant EIP155_NAMESPACE = 0x6569703135350000000000000000000000000000000000000000000000000000;
    uint256 public constant CCTP_MAX_BURN_PER_MESSAGE = 10_000_000e6;

    constructor(uint256 minimumSweep_, uint256 maxFeeBps_)
        RevenueInboxFactoryV1(
            ARBITRUM_ONE_USDC,
            ARBITRUM_ONE_TOKEN_MESSENGER_V2,
            ARBITRUM_ONE_CCTP_DOMAIN,
            ARBITRUM_ONE_CHAIN_ID,
            EIP155_NAMESPACE,
            minimumSweep_,
            CCTP_MAX_BURN_PER_MESSAGE,
            maxFeeBps_
        )
    {}
}
