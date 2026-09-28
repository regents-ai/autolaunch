// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title ForkAddresses
/// @notice The Agent lab addresses the fork suite runs against, copied from the active run's
///         `contracts/v1/reports/generated/local-base-lab/site-config.json` (Anvil 1.5.1, chain 31337,
///         Base fork block 51503693, RPC http://127.0.0.1:49719). Restarting the Agent lab changes
///         these; the suite checks each one carries code and fails loudly otherwise.
library ForkAddresses {
    address internal constant UERC20_FACTORY = 0xB3B264617C89f1D702c67Dfa99897B899362f165;

    /// @notice A large forked USDC holder the lab impersonates (Morpho Blue on Base).
    address internal constant USDC_HOLDER = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    /// @notice Base-native AAPLc. Carries `0xef` code on the fork; the suite installs the fixture.
    address internal constant AAPLC = 0xb200000000000000000000C2e324d24d7eEcd1fb;

    uint256 internal constant LOCAL_CHAIN_ID = 31_337;
}
