// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseBindings} from "../src/bindings/BaseBindings.sol";

/// @notice The read-only Base fork harness. Two isolated forks, one committed observation record,
///         and one normalized verdict per claim per header.
/// @dev Evidence here is deliberately two-phase, because a gate that observes a value and then
///      compares it to itself proves nothing.
///
///      1. An authorized discovery pass records the block headers, runtime hashes, proxy families,
///         implementations, and immutable getter results it observes into
///         `reports/frozen/fork-observations.json`. That file is reviewed and committed.
///      2. The final gate is check-only. Every test below reads the committed record and compares
///         it against what the chain answers now. Nothing writes an observation during a check run.
///
///      Each claim runs twice, in two separately created forks: once at the pinned block header
///      recorded for this candidate, and once at the later head captured for the same candidate.
///      The two never share state. Each run emits one normalized verdict per claim, and
///      `bin/fork-gate.sh` reconciles the two sets for `DEP-050`.
///
///      The endpoint is never named here. It is reached only through the `base` alias, whose value
///      stays an unresolved environment reference in every committed file; `bin/fork-gate.sh`
///      scans this run's own artifacts to prove nothing resolved it into evidence.
abstract contract ForkFixture is Test {
    string internal constant OBSERVATIONS_PATH = "reports/frozen/fork-observations.json";

    /// @notice The configured Base endpoint alias. Never an endpoint, always an alias.
    string internal constant RPC_ALIAS = "base";

    /// @notice The two headers every fork claim is proved at.
    enum Header {
        Pinned,
        Later
    }

    string private _observations;

    error ForkObservationsPending();

    /// @dev Loads the committed record and refuses to run while it is still in its pending state,
    ///      so a check run can never invent the values it is supposed to be checking.
    function _loadObservations() internal {
        _observations = vm.readFile(OBSERVATIONS_PATH);
        if (
            keccak256(bytes(vm.parseJsonString(_observations, ".status"))) != keccak256(bytes("observed_and_committed"))
        ) {
            revert ForkObservationsPending();
        }
    }

    /// @notice Create and select one isolated fork at the header this claim is being proved at.
    /// @dev `createSelectFork` makes a fresh fork every call, so no claim inherits another claim's
    ///      warmed access list, cached storage, or staged state.
    function _selectFork(Header header) internal returns (uint256 blockNumber) {
        if (header == Header.Pinned) {
            blockNumber = _observedUint(".headers.pinned.block_number");
            vm.createSelectFork(RPC_ALIAS, blockNumber);
        } else {
            blockNumber = _observedUint(".headers.later.block_number");
            vm.createSelectFork(RPC_ALIAS, blockNumber);
        }
        assertEq(block.number, blockNumber, "the fork did not open at the recorded header");
        assertEq(block.chainid, BaseBindings.BASE_CHAIN_ID, "the fork is not Base mainnet");
    }

    function _headerName(Header header) internal pure returns (string memory) {
        return header == Header.Pinned ? "pinned" : "later";
    }

    // -------------------------------------------------------------------------
    // the committed record
    // -------------------------------------------------------------------------

    function _observedUint(string memory path) internal view returns (uint256) {
        return vm.parseJsonUint(_observations, path);
    }

    function _observedBytes32(string memory path) internal view returns (bytes32) {
        return vm.parseJsonBytes32(_observations, path);
    }

    function _observedAddress(string memory path) internal view returns (address) {
        return vm.parseJsonAddress(_observations, path);
    }

    function _observedString(string memory path) internal view returns (string memory) {
        return vm.parseJsonString(_observations, path);
    }

    /// @dev One binding's recorded facts, addressed by its manifest id.
    function _bindingPath(string memory id, string memory field) internal pure returns (string memory) {
        return string.concat(".bindings.", id, ".", field);
    }

    /// @notice The eight frozen binding ids, in `SPEC.md` table order.
    function _bindingIds() internal pure returns (string[8] memory ids) {
        ids = [
            "regent",
            "usdc",
            "cca_factory",
            "pool_manager",
            "position_manager",
            "live_staking",
            "governance_and_regent_safe",
            "dead_address"
        ];
    }

    function _bindingAddresses() internal pure returns (address[8] memory) {
        return BaseBindings.all();
    }

    // -------------------------------------------------------------------------
    // verdicts
    // -------------------------------------------------------------------------

    /// @dev One claim's normalized verdict at one header. `bin/fork-gate.sh` reads these out of the
    ///      two runs' JSON test reports and requires the pinned and later sets to be identical, which
    ///      is `DEP-050`. Normalized means the string carries the claim's *decision*, never a
    ///      header-dependent value like a block number, a timestamp, or a balance.
    function _emitVerdict(string memory claim, Header header, string memory verdict) internal {
        emit log_named_string(string.concat("verdict ", claim, " ", _headerName(header)), verdict);
    }
}
