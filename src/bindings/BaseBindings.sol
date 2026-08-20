// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title BaseBindings
/// @notice Immutable Base mainnet bindings frozen by `SPEC.md` section 3.
/// @dev Constants only: this library holds no state, no authority, and no behavior.
///      It asserts nothing about external runtime truth. Deployed code, code hash,
///      proxy shape, getter results, the zero CCA protocol fee controller, and the
///      live chain id stay bound to the separately authorized fork gate
///      (`DEP-040` through `DEP-050`).
///
///      Each constant name is the mechanical CONSTANT_CASE form of its `SPEC.md`
///      binding-table label, so `bin/gate.sh` can match bindings by name and not
///      merely by literal value.
library BaseBindings {
    address internal constant REGENT = 0x6f89bcA4eA5931EdFCB09786267b251DeE752b07;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CCA_FACTORY = 0x000000001F26a0044BaA66024e7b6599c61963F8;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant LIVE_STAKING = 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5;
    address internal constant GOVERNANCE_AND_REGENT_SAFE = 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e;
    address internal constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice The chain every binding above belongs to. Base mainnet.
    uint256 internal constant BASE_CHAIN_ID = 8453;

    /// @notice Runtime code hash the CCA factory binding must present before admission.
    bytes32 internal constant CCA_FACTORY_RUNTIME_CODE_HASH =
        0xa1d2a90564f4f63580b25de42efaff92505c254b00fc666f65ab38126cce5cfa;

    /// @notice The frozen binding set in `SPEC.md` table order.
    /// @dev Returned as a value so a test can prove the whole set at once: nothing added,
    ///      nothing removed, nothing reordered, and no two bindings collapsed onto one
    ///      address.
    function all() internal pure returns (address[8] memory set) {
        set[0] = REGENT;
        set[1] = USDC;
        set[2] = CCA_FACTORY;
        set[3] = POOL_MANAGER;
        set[4] = POSITION_MANAGER;
        set[5] = LIVE_STAKING;
        set[6] = GOVERNANCE_AND_REGENT_SAFE;
        set[7] = DEAD_ADDRESS;
    }
}
