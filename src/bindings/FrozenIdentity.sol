// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title FrozenIdentity
/// @notice The compiled form of the repository's frozen dependency, toolchain, build, and
///         test-portfolio identity.
/// @dev Constants only: no state, no authority, no behavior.
///
///      These constants are the *compiled* copy of `requirements/frozen-identity.json`.
///      They prove nothing on their own. `bin/gate.sh` independently reconciles that file
///      against its real authorities before any test runs — `SPEC.md` for the founder pins
///      and the authority digest, each pinned parent's own gitlink for the recursive
///      closure, `git submodule status --recursive` for materialization, the installed
///      tools for the toolchain identity, `forge config --json` for the effective build
///      and fuzz settings, and the produced artifacts for the compiler that ran. The tests
///      that read the fixture therefore compare compiled constants against independently
///      verified facts, and never against the candidate's own restatement of them.
library FrozenIdentity {
    // -----------------------------------------------------------------------
    // Founder pins (SPEC.md section 3)
    // -----------------------------------------------------------------------

    bytes20 internal constant CCA_COMMIT = bytes20(0x7D7602D257733315434570F2A0c2f94F1C7B207a);
    bytes20 internal constant LIQUIDITY_LAUNCHER_COMMIT = bytes20(0x3A3103543F50A13a0Ae52a253bB98a925d72146F);
    bytes20 internal constant UERC20_FACTORY_COMMIT = bytes20(0x09aE130F7a10f7c1b96e0dC7d9724d567080c4eF);

    // -----------------------------------------------------------------------
    // Gitlinks the pinned parents themselves record
    // -----------------------------------------------------------------------

    /// @notice The launcher gitlink recorded inside the pinned CCA commit's own tree.
    bytes20 internal constant CCA_RECORDED_LAUNCHER_COMMIT = bytes20(0x3A3103543F50A13a0Ae52a253bB98a925d72146F);

    /// @notice The forge-std gitlink recorded inside the pinned launcher commit's own tree.
    bytes20 internal constant LAUNCHER_RECORDED_FORGE_STD_COMMIT = bytes20(0x3B20d60d14B343eE4F908cB8079495c07f5e8981);

    /// @notice The UERC20 gitlink recorded inside the pinned launcher commit's own tree.
    /// @dev Deliberately a different token-factory commit from the founder-selected
    ///      `UERC20_FACTORY_COMMIT`; the two identities must never converge.
    bytes20 internal constant LAUNCHER_RECORDED_UERC20_COMMIT = bytes20(0x46290A5447844016516b4B4530013DA01b6ff801);

    /// @notice This repository's own forge-std identity, which mirrors the launcher's.
    bytes20 internal constant FORGE_STD_COMMIT = bytes20(0x3B20d60d14B343eE4F908cB8079495c07f5e8981);

    // -----------------------------------------------------------------------
    // Dependency-closure shape
    // -----------------------------------------------------------------------

    /// @notice keccak256 of the newline-joined, sorted paths of the four root submodules.
    bytes32 internal constant ROOT_SUBMODULE_DIGEST =
        0x277b6a66442cdcbaf81c57b86fb4bfd01237480cd72d263023959055a7342949;

    /// @notice keccak256 of the newline-joined, sorted paths of the complete recursive
    ///         submodule closure, roots included.
    /// @dev Freezes the *shape* of the closure so a dependency cannot silently disappear.
    ///      The commit each of those paths must carry is never frozen here: it is read
    ///      from the pinned parent that records it.
    bytes32 internal constant RECURSIVE_CLOSURE_DIGEST =
        0x889a12ce9fc76fa20f306d3682e03a3122c96d080221783ba2a9e44714fb0abc;

    // -----------------------------------------------------------------------
    // Controlling authority
    // -----------------------------------------------------------------------

    /// @notice SHA-256 of `SPEC.md` at the C0 freeze.
    bytes32 internal constant SPEC_SHA256 = 0x550ef04853f0918a502b77628992269fed0290db789cd387b54ab19abb6a6894;

    // -----------------------------------------------------------------------
    // Binding set
    // -----------------------------------------------------------------------

    /// @notice keccak256 of the abi-encoded frozen binding set in `SPEC.md` table order.
    bytes32 internal constant BINDING_SET_DIGEST = 0xc06ad38d135fc1f9ac06f17ca4cae0c34e44e0a5dfabfc536247cedaf8b09e32;

    // -----------------------------------------------------------------------
    // CCA admission provenance
    // -----------------------------------------------------------------------

    /// @notice keccak256 of the newline-joined admission provenance record: repository,
    ///         commit, path, signature, state mutability, and declared return type.
    bytes32 internal constant CCA_ADMISSION_PROVENANCE_DIGEST =
        0x0528ced80fcabe5867355db9c65af4c11d5b16681f598391f290ebe53ed7143e;

    /// @notice The admitted CCA admission selector.
    bytes4 internal constant CCA_PROTOCOL_FEE_CONTROLLER_SELECTOR = 0xf02de3b2;

    // -----------------------------------------------------------------------
    // Toolchain identity
    // -----------------------------------------------------------------------

    string internal constant FORGE_VERSION = "1.5.1-stable";
    string internal constant FORGE_COMMIT_SHA = "b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2";
    string internal constant SLITHER_VERSION = "0.11.5";
    string internal constant LEDGER_PYTHON_VERSION = "3.14.7";

    // -----------------------------------------------------------------------
    // Build identity
    // -----------------------------------------------------------------------

    string internal constant SOLC_IDENTITY = "0.8.26+commit.8a97fa7a";
    uint256 internal constant OPTIMIZER_RUNS = 200;
    bool internal constant VIA_IR = true;
    string internal constant EVM_VERSION = "cancun";
    string internal constant BYTECODE_HASH = "none";
    bool internal constant APPEND_CBOR = false;

    // -----------------------------------------------------------------------
    // Gate posture
    // -----------------------------------------------------------------------

    bool internal constant FOUNDRY_OFFLINE = true;
    bool internal constant FOUNDRY_FFI = false;

    // -----------------------------------------------------------------------
    // Deterministic test portfolio
    // -----------------------------------------------------------------------

    uint256 internal constant FUZZ_RUNS = 512;
    uint256 internal constant FUZZ_SEED = 0x5245474e54;
    uint256 internal constant FUZZ_MAX_TEST_REJECTS = 65536;
    bool internal constant FUZZ_FAIL_ON_REVERT = true;

    uint256 internal constant INVARIANT_RUNS = 256;
    uint256 internal constant INVARIANT_DEPTH = 128;
    bool internal constant INVARIANT_FAIL_ON_REVERT = true;
    uint256 internal constant INVARIANT_MAX_ASSUME_REJECTS = 65536;
    uint256 internal constant INVARIANT_SHRINK_RUN_LIMIT = 5000;
}
