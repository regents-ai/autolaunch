// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {ForkHeaders} from "./ForkHeaders.sol";

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

    /// @notice Every proxy implementation slot this repository is prepared to recognize.
    /// @dev `DEP-043` never assumes a binding is EIP-1967. Base's own USDC, for one, is a
    ///      FiatTokenProxy that keeps its implementation at the older ZeppelinOS slot, so a gate
    ///      that only read the EIP-1967 slot would classify a real proxy as a plain contract and
    ///      then prove nothing about the code actually executing behind it. The discovery pass
    ///      classifies against all three, records the family it found, and the check pass follows
    ///      the recorded family.
    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant EIP1822_IMPLEMENTATION_SLOT =
        0xc5f16f0fcc639fa48a6947836d9850f504798523bf8c9a3a87d5876cf622bcf7;
    bytes32 internal constant ZEPPELINOS_IMPLEMENTATION_SLOT =
        0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3;

    /// @notice The Safe singleton's own storage slot and its own getter, recognized for exactly one
    ///         address: the frozen Regent Safe.
    /// @dev A Safe proxy keeps its singleton in slot 0 and exposes it as `masterCopy()`. That slot
    ///      is not a namespaced proxy slot — plenty of ordinary contracts keep an unrelated address
    ///      in slot 0 — so this detector is deliberately not applied to anything but the exact
    ///      frozen governance address, and it admits the family only when all four measurements
    ///      agree: the slot-0 address, the `masterCopy()` return, a proxy runtime small enough and
    ///      strictly smaller than the singleton's, and a singleton that carries code.
    bytes32 internal constant SAFE_SINGLETON_SLOT = bytes32(uint256(0));
    bytes4 internal constant SAFE_MASTER_COPY_SELECTOR = 0xa619486e;

    /// @notice The largest runtime a delegating Safe proxy stub can have and still be one.
    /// @dev Metadata-bearing Safe proxy runtimes can exceed 128 bytes; the frozen Regent Safe is
    ///      171 bytes. The bound remains far below a Safe singleton's runtime and is only a shape
    ///      test: identity comes from the agreeing slot-0/getter value and the singleton code hash.
    uint256 internal constant SAFE_PROXY_MAX_RUNTIME_BYTES = 256;

    /// @notice The family string a binding gets when none of the supported patterns is present.
    /// @dev Deliberately not "none". This gate reads three implementation slots and, for one
    ///      address, a Safe singleton; a binding that matches none of them has not been proved to
    ///      be a plain non-proxy contract, only to carry no pattern this repository supports. The
    ///      string says exactly that much and no more.
    string internal constant NO_SUPPORTED_PROXY_PATTERN = "no_supported_proxy_pattern";

    /// @notice The canonical Permit2 deployment every bidder allowance goes through.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

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

    /// @notice Create and select one isolated fork at the header this claim is being proved at, and
    ///         bind every recorded field of that header before the caller's claim executes.
    /// @dev `createSelectFork` makes a fresh fork every call, so no claim inherits another claim's
    ///      warmed access list, cached storage, or staged state.
    ///
    ///      Binding is complete rather than partial. A run that only checked the height would still
    ///      be checking a chain it had not identified: two chains, or one chain reorged below the
    ///      recorded header, can both present that height. Every field the reviewed record carries
    ///      — the number, the parent's number and hash, the timestamp, the base fee — is therefore
    ///      compared against live state here, together with the chain id, and every fork claim in
    ///      this repository reaches its own work only through this function. `DEP-052`.
    function _selectFork(Header header) internal returns (uint256 blockNumber) {
        string memory prefix = string.concat(".headers.", _headerName(header), ".");
        blockNumber = _observedUint(string.concat(prefix, "block_number"));
        vm.createSelectFork(RPC_ALIAS, blockNumber);

        assertEq(block.chainid, BaseBindings.BASE_CHAIN_ID, "the fork is not Base mainnet");
        assertEq(block.number, blockNumber, "the fork did not open at the recorded header");
        assertEq(
            block.number - 1,
            _observedUint(string.concat(prefix, "parent_block_number")),
            "the header's parent number is not the recorded one"
        );
        assertEq(
            blockhash(block.number - 1),
            _observedBytes32(string.concat(prefix, "parent_block_hash")),
            "the header's parent hash is not the recorded one; this is a different chain or a reorg"
        );
        assertEq(
            block.timestamp,
            _observedUint(string.concat(prefix, "timestamp")),
            "the header's timestamp is not the recorded one"
        );
        assertEq(
            block.basefee,
            _observedUint(string.concat(prefix, "base_fee_per_gas")),
            "the header's base fee is not the recorded one"
        );
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

    function _observedBool(string memory path) internal view returns (bool) {
        return vm.parseJsonBool(_observations, path);
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
    // live proxy classification
    // -------------------------------------------------------------------------

    /// @notice Classify one deployed account's proxy family from chain state alone.
    /// @dev Reads the three recognized implementation slots — and, for exactly one address, the
    ///      Safe singleton pattern — and returns the family, the implementation it points at, and
    ///      that implementation's own EVM code identity. It consults no committed value, so the
    ///      check pass derives the family and the implementation identity independently here and
    ///      only then compares them against what was reviewed. The discovery pass deliberately
    ///      keeps its own copy of this classification rather than inheriting this fixture:
    ///      inheriting it would couple discovery to the fixture that reads
    ///      `reports/frozen/fork-observations.json`, and phase one must not consult the record
    ///      phase two checks against.
    ///
    ///      An account that matches nothing is reported as `no_supported_proxy_pattern`, never as
    ///      "not a proxy". This gate knows four patterns; a fifth would be invisible to it, and a
    ///      claim of universal non-proxy detection would be a claim it cannot support.
    function _classifyProxy(address account)
        internal
        view
        returns (
            string memory family,
            address implementation,
            bytes32 implementationCodeHash,
            uint256 implementationBytes
        )
    {
        implementation = _slotAsAddress(account, EIP1967_IMPLEMENTATION_SLOT);
        family = "eip1967";
        if (implementation == address(0)) {
            implementation = _slotAsAddress(account, EIP1822_IMPLEMENTATION_SLOT);
            family = "eip1822";
        }
        if (implementation == address(0)) {
            implementation = _slotAsAddress(account, ZEPPELINOS_IMPLEMENTATION_SLOT);
            family = "zeppelinos";
        }
        if (implementation == address(0) && account == BaseBindings.GOVERNANCE_AND_REGENT_SAFE) {
            implementation = _safeSingleton(account);
            family = "safe_singleton";
        }
        if (implementation == address(0)) {
            return (NO_SUPPORTED_PROXY_PATTERN, address(0), bytes32(0), 0);
        }
        implementationCodeHash = implementation.codehash;
        implementationBytes = implementation.code.length;
    }

    /// @notice The Safe singleton behind the frozen Regent Safe, or zero if this is not one.
    /// @dev Four independent measurements have to agree before this reports a singleton, because
    ///      slot 0 is ordinary storage rather than a namespaced proxy slot:
    ///
    ///        1. slot 0 decodes to a nonzero address;
    ///        2. the account's own `masterCopy()` returns exactly that address;
    ///        3. the account's runtime is a delegating stub — small in absolute terms, and strictly
    ///           smaller than the singleton it forwards to;
    ///        4. that singleton carries code, so the delegated calls actually execute something.
    ///
    ///      Any disagreement returns zero, which classifies the binding as
    ///      `no_supported_proxy_pattern` and — because the reviewed record says otherwise — stops
    ///      the gate rather than quietly reclassifying a governance address.
    function _safeSingleton(address account) internal view returns (address) {
        address slotValue = _slotAsAddress(account, SAFE_SINGLETON_SLOT);
        if (slotValue == address(0) || slotValue.code.length == 0) return address(0);

        (bool ok, bytes memory returned) = account.staticcall(abi.encodePacked(SAFE_MASTER_COPY_SELECTOR));
        if (!ok || returned.length < 32) return address(0);
        if (abi.decode(returned, (address)) != slotValue) return address(0);

        uint256 proxyBytes = account.code.length;
        if (proxyBytes == 0 || proxyBytes > SAFE_PROXY_MAX_RUNTIME_BYTES) return address(0);
        if (proxyBytes >= slotValue.code.length) return address(0);

        return slotValue;
    }

    function _slotAsAddress(address account, bytes32 slot) internal view returns (address) {
        return address(uint160(uint256(vm.load(account, slot))));
    }

    // -------------------------------------------------------------------------
    // deployed-contract reads
    // -------------------------------------------------------------------------

    function _callUint(address target, bytes memory payload) internal view returns (uint256) {
        (bool ok, bytes memory returned) = target.staticcall(payload);
        require(ok && returned.length >= 32, "fork read failed");
        return abi.decode(returned, (uint256));
    }

    function _callBool(address target, bytes memory payload) internal view returns (bool) {
        (bool ok, bytes memory returned) = target.staticcall(payload);
        require(ok && returned.length >= 32, "fork bool read failed");
        return abi.decode(returned, (bool));
    }

    function _callAddress(address target, bytes memory payload) internal view returns (address) {
        (bool ok, bytes memory returned) = target.staticcall(payload);
        require(ok && returned.length >= 32, "fork address read failed");
        return abi.decode(returned, (address));
    }

    function _callString(address target, bytes memory payload) internal view returns (string memory) {
        (bool ok, bytes memory returned) = target.staticcall(payload);
        require(ok && returned.length >= 64, "fork string read failed");
        return abi.decode(returned, (string));
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        return _callUint(token, abi.encodeWithSignature("balanceOf(address)", account));
    }

    function _allowance(address token, address owner, address spender) internal view returns (uint256) {
        return _callUint(token, abi.encodeWithSignature("allowance(address,address)", owner, spender));
    }

    function _mustCall(address target, bytes memory payload) internal {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory returned) = target.call(payload);
        require(ok, "fork call reverted");
        if (returned.length >= 32) require(abi.decode(returned, (bool)), "fork call returned false");
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
