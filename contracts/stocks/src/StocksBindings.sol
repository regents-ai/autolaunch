// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title StocksBindings
/// @notice Immutable Base mainnet bindings the Stocks component compiles against.
/// @dev Constants only: no state, no authority, no behavior. The values are the frozen
///      `contracts/v1` bindings (`BaseBindings.sol`, SPEC.md section 3) copied here so this component
///      never imports from the frozen project, plus the canonical Permit2 the pinned CCA pulls a
///      non-native bid currency through. Deployed code and proxy shape stay bound to fork evidence.
library StocksBindings {
    address internal constant REGENT = 0x6f89bcA4eA5931EdFCB09786267b251DeE752b07;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CCA_FACTORY = 0x000000001F26a0044BaA66024e7b6599c61963F8;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant LIVE_STAKING = 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5;
    address internal constant GOVERNANCE_AND_REGENT_SAFE = 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e;
    address internal constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Canonical Permit2. `ContinuousClearingAuction.submitBid` pulls a non-native currency
    ///         from `msg.sender` through `permit2.transferFrom(from, to, uint160 amount, token)`.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice The chain every binding above belongs to. Base mainnet.
    uint256 internal constant BASE_CHAIN_ID = 8453;
}
