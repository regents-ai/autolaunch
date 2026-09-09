// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title ForkAddresses
/// @notice The Agent lab graph the fork suite runs against, copied from the active run's
///         `contracts/v1/reports/generated/local-base-lab/site-config.json` (Anvil 1.5.1, chain 31337,
///         Base fork block 50984591, RPC http://127.0.0.1:58737). Restarting the Agent lab changes
///         these; the suite checks each one carries code and fails loudly otherwise.
library ForkAddresses {
    address internal constant AGENT_FACTORY = 0x48341359fD31763A61188DB01Cbacb5EE3aF2B38;
    address internal constant AGENT_STRATEGY = 0x91421C8EcA9f1179cc8e00d117582094Df2540CD;
    address internal constant AGENT_HOOK = 0x3CD11C027003fD73514e8E725E653bdfCf5Be044;
    address internal constant UERC20_FACTORY = 0x5Cf2bd1d329075aD57a29bFFcaC63E473b65E853;

    /// @notice A large forked USDC holder the lab impersonates (Morpho Blue on Base).
    address internal constant USDC_HOLDER = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    /// @notice Base-native AAPLc. Carries `0xef` code on the fork; the suite installs the fixture.
    address internal constant AAPLC = 0xb200000000000000000000C2e324d24d7eEcd1fb;

    uint256 internal constant LOCAL_CHAIN_ID = 31_337;
}
