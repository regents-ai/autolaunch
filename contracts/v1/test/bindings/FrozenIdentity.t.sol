// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {FrozenIdentity} from "../../src/bindings/FrozenIdentity.sol";

/// @notice Proves the compiled dependency, toolchain, build, and test-portfolio identity
///         equals `requirements/frozen-identity.json`.
/// @dev These tests supplement, and never replace, the gate's own receipt. `bin/gate.sh`
///      first reconciles that fixture against the real authorities — `SPEC.md`, each pinned
///      parent's own gitlink, `git submodule status --recursive`, the installed tools,
///      `forge config --json`, and the produced artifacts — and refuses to run this suite
///      unless every one of those comparisons held. What runs here is the second half of
///      the same claim: the constants the contracts actually compile against are the
///      constants that were independently verified.
contract FrozenIdentityTest is Test {
    string internal fixture;

    function setUp() public {
        fixture = vm.readFile("requirements/frozen-identity.json");
    }

    function _commit(string memory key) internal view returns (string memory) {
        return string.concat("0x", vm.parseJsonString(fixture, key));
    }

    /// @dev `vm.toString` widens a `bytes20` to a right-padded word; a git commit is
    ///      exactly twenty bytes, so render it as those twenty bytes.
    function _hex(bytes20 commit) internal view returns (string memory) {
        return vm.toString(abi.encodePacked(commit));
    }

    /// @dev keccak256 over the newline-joined string array at `key`.
    function _joinedDigest(string memory key) internal view returns (bytes32) {
        string[] memory entries = vm.parseJsonStringArray(fixture, key);
        require(entries.length > 0, "empty path list");

        bytes memory joined = bytes(entries[0]);
        for (uint256 i = 1; i < entries.length; i++) {
            joined = abi.encodePacked(joined, "\n", entries[i]);
        }
        return keccak256(joined);
    }

    // -----------------------------------------------------------------------
    // Founder pins
    // -----------------------------------------------------------------------

    function test_DEP_001_CcaPinEqualsFrozenFounderCommit() public view {
        assertEq(_hex(FrozenIdentity.CCA_COMMIT), _commit(".pins.cca.commit"));
    }

    function test_DEP_002_LiquidityLauncherPinEqualsFrozenFounderCommit() public view {
        assertEq(_hex(FrozenIdentity.LIQUIDITY_LAUNCHER_COMMIT), _commit(".pins.liquidity_launcher.commit"));
    }

    function test_DEP_003_Uerc20FactoryPinEqualsFrozenFounderCommit() public view {
        assertEq(_hex(FrozenIdentity.UERC20_FACTORY_COMMIT), _commit(".pins.uerc20_factory.commit"));
    }

    // -----------------------------------------------------------------------
    // Relations between the pinned upstreams
    // -----------------------------------------------------------------------

    /// @dev The crosscheck itself: the launcher gitlink the pinned CCA tree records must be
    ///      the founder's launcher pin, so two independently frozen upstreams agree.
    function test_DEP_004_CcaRecordedLauncherGitlinkEqualsFounderLauncherPin() public view {
        assertEq(_hex(FrozenIdentity.CCA_RECORDED_LAUNCHER_COMMIT), _commit(".relations.cca_recorded_launcher"));
        assertEq(FrozenIdentity.CCA_RECORDED_LAUNCHER_COMMIT, FrozenIdentity.LIQUIDITY_LAUNCHER_COMMIT);
    }

    /// @dev The mirror: this repository's test framework follows the launcher's forge-std
    ///      identity rather than a separately chosen one.
    function test_DEP_006_ForgeStdMirrorsLauncherRecordedGitlink() public view {
        assertEq(
            _hex(FrozenIdentity.LAUNCHER_RECORDED_FORGE_STD_COMMIT), _commit(".relations.launcher_recorded_forge_std")
        );
        assertEq(_hex(FrozenIdentity.FORGE_STD_COMMIT), _commit(".relations.forge_std"));
        assertEq(FrozenIdentity.FORGE_STD_COMMIT, FrozenIdentity.LAUNCHER_RECORDED_FORGE_STD_COMMIT);
    }

    /// @dev The distinctness: the founder-selected token factory and the launcher's own
    ///      nested UERC20 dependency are two different commits and must never converge.
    function test_DEP_007_FounderUerc20FactoryIsDistinctFromLauncherUerc20() public view {
        assertEq(_hex(FrozenIdentity.LAUNCHER_RECORDED_UERC20_COMMIT), _commit(".relations.launcher_recorded_uerc20"));
        assertTrue(FrozenIdentity.UERC20_FACTORY_COMMIT != FrozenIdentity.LAUNCHER_RECORDED_UERC20_COMMIT);
    }

    // -----------------------------------------------------------------------
    // Closure shape
    // -----------------------------------------------------------------------

    function test_DEP_005_RecursiveClosureShapeIsFrozen() public view {
        assertEq(_joinedDigest(".recursive_closure"), FrozenIdentity.RECURSIVE_CLOSURE_DIGEST);
    }

    function test_DEP_008_RootSubmoduleSetIsFrozen() public view {
        assertEq(_joinedDigest(".root_submodules"), FrozenIdentity.ROOT_SUBMODULE_DIGEST);
    }

    // -----------------------------------------------------------------------
    // Build, toolchain, authority, posture, portfolio
    // -----------------------------------------------------------------------

    function test_DEP_009_CompiledBuildIdentityIsFrozen() public view {
        assertEq(FrozenIdentity.SOLC_IDENTITY, vm.parseJsonString(fixture, ".build.solc_identity"));
        assertEq(FrozenIdentity.OPTIMIZER_RUNS, vm.parseJsonUint(fixture, ".build.optimizer_runs"));
        assertEq(FrozenIdentity.VIA_IR, vm.parseJsonBool(fixture, ".build.via_ir"));
        assertEq(FrozenIdentity.EVM_VERSION, vm.parseJsonString(fixture, ".build.evm_version"));
        assertEq(FrozenIdentity.BYTECODE_HASH, vm.parseJsonString(fixture, ".build.bytecode_hash"));
        assertEq(FrozenIdentity.APPEND_CBOR, vm.parseJsonBool(fixture, ".build.append_cbor"));
    }

    function test_DEP_010_ToolchainIdentityIsFrozen() public view {
        assertEq(FrozenIdentity.FORGE_VERSION, vm.parseJsonString(fixture, ".toolchain.forge_version"));
        assertEq(FrozenIdentity.FORGE_COMMIT_SHA, vm.parseJsonString(fixture, ".toolchain.forge_commit_sha"));
        assertEq(FrozenIdentity.SLITHER_VERSION, vm.parseJsonString(fixture, ".toolchain.slither_version"));
        assertEq(FrozenIdentity.LEDGER_PYTHON_VERSION, vm.parseJsonString(fixture, ".toolchain.python_version"));
    }

    function test_DEP_011_SpecDigestIsFrozen() public view {
        assertEq(
            vm.toString(FrozenIdentity.SPEC_SHA256), string.concat("0x", vm.parseJsonString(fixture, ".spec_sha256"))
        );
    }

    function test_DEP_013_CcaAdmissionProvenanceIsFrozen() public view {
        bytes memory record = abi.encodePacked(
            vm.parseJsonString(fixture, ".admission.provenance_repository"),
            "\n",
            vm.parseJsonString(fixture, ".admission.provenance_commit"),
            "\n",
            vm.parseJsonString(fixture, ".admission.provenance_path"),
            "\n",
            vm.parseJsonString(fixture, ".admission.signature"),
            "\n",
            vm.parseJsonString(fixture, ".admission.state_mutability"),
            "\n",
            vm.parseJsonString(fixture, ".admission.returns")
        );

        assertEq(keccak256(record), FrozenIdentity.CCA_ADMISSION_PROVENANCE_DIGEST);
        assertEq(
            vm.parseJsonString(fixture, ".admission.provenance_commit"), vm.parseJsonString(fixture, ".pins.cca.commit")
        );
    }

    function test_DEP_014_GatePostureIsOfflineWithFfiDisabled() public view {
        assertEq(FrozenIdentity.FOUNDRY_OFFLINE, vm.parseJsonBool(fixture, ".foundry.offline"));
        assertEq(FrozenIdentity.FOUNDRY_FFI, vm.parseJsonBool(fixture, ".foundry.ffi"));
        assertTrue(FrozenIdentity.FOUNDRY_OFFLINE);
        assertFalse(FrozenIdentity.FOUNDRY_FFI);
    }

    function test_DEP_015_DeterministicTestPortfolioIsFrozen() public view {
        assertEq(FrozenIdentity.FUZZ_RUNS, vm.parseJsonUint(fixture, ".fuzz.runs"));
        assertEq(FrozenIdentity.FUZZ_SEED, vm.parseJsonUint(fixture, ".fuzz.seed"));
        assertEq(FrozenIdentity.FUZZ_MAX_TEST_REJECTS, vm.parseJsonUint(fixture, ".fuzz.max_test_rejects"));
        assertEq(FrozenIdentity.FUZZ_FAIL_ON_REVERT, vm.parseJsonBool(fixture, ".fuzz.fail_on_revert"));

        assertEq(FrozenIdentity.INVARIANT_RUNS, vm.parseJsonUint(fixture, ".invariant.runs"));
        assertEq(FrozenIdentity.INVARIANT_DEPTH, vm.parseJsonUint(fixture, ".invariant.depth"));
        assertEq(FrozenIdentity.INVARIANT_FAIL_ON_REVERT, vm.parseJsonBool(fixture, ".invariant.fail_on_revert"));
        assertEq(
            FrozenIdentity.INVARIANT_MAX_ASSUME_REJECTS, vm.parseJsonUint(fixture, ".invariant.max_assume_rejects")
        );
        assertEq(FrozenIdentity.INVARIANT_SHRINK_RUN_LIMIT, vm.parseJsonUint(fixture, ".invariant.shrink_run_limit"));
    }
}
