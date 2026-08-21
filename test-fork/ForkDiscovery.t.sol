// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {ForkHeaders} from "./ForkHeaders.sol";

/// @notice The authorized read-only discovery pass: phase one of the two-phase fork evidence.
/// @dev This contract observes and records. It never checks. Nothing in it reads
///      `reports/frozen/fork-observations.json`, so it cannot compare a fact to itself, and it
///      cannot write there either — the `fork-discovery` profile grants write access to exactly
///      one gitignored scratch directory and to nothing else. What it produces is a *candidate*:
///
///        reports/generated/fork/fork-observations-candidate.json
///
///      A human reads that candidate, fills in the two transaction-gas-schedule values the chain
///      does not expose, flips its status, installs it at `reports/frozen/fork-observations.json`,
///      activates `fork` in `requirements/ledger.toml`, and commits both. Only then can
///      `bin/fork-gate.sh check` run, and check is compare-only against what was reviewed.
///
///      Header choice is deterministic rather than arbitrary. The run opens one fork at the chain
///      head, takes that height as the *later* header, and takes `later - CONFIRMATION_DEPTH` as
///      the *pinned* header, so the pinned header is far enough back to be settled and the later
///      header is a genuinely later head of the same chain. Both are recorded as exact numbers,
///      and every binding fact below is observed at the pinned header.
///
///      The endpoint is never named here. It is reached only through the `base` alias, and
///      `bin/fork-gate.sh` scans everything this run produces to prove nothing resolved it.
contract ForkDiscoveryTest is Test {
    string internal constant RPC_ALIAS = "base";
    string internal constant CANDIDATE_PATH = "reports/generated/fork/fork-observations-candidate.json";

    /// @notice How far behind the head the pinned header sits, from the one shared literal.
    /// @dev `DEP-052` asserts the two committed records really are exactly this far apart, so the
    ///      check pass proves the choice discovery made rather than inheriting it on trust.
    uint256 internal constant CONFIRMATION_DEPTH = ForkHeaders.PINNED_TO_LATER_DISTANCE;

    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant EIP1822_IMPLEMENTATION_SLOT =
        0xc5f16f0fcc639fa48a6947836d9850f504798523bf8c9a3a87d5876cf622bcf7;
    bytes32 internal constant ZEPPELINOS_IMPLEMENTATION_SLOT =
        0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3;

    /// @notice The Safe singleton pattern, recognized for exactly the frozen Regent Safe.
    bytes32 internal constant SAFE_SINGLETON_SLOT = bytes32(uint256(0));
    bytes4 internal constant SAFE_MASTER_COPY_SELECTOR = 0xa619486e;
    uint256 internal constant SAFE_PROXY_MAX_RUNTIME_BYTES = 128;

    /// @notice What a binding matching none of the four supported patterns is recorded as.
    string internal constant NO_SUPPORTED_PROXY_PATTERN = "no_supported_proxy_pattern";

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Observe both headers and every binding fact, and write the reviewable candidate.
    function testDiscoverBaseObservations() public {
        uint256 later = _openHead();
        require(later > CONFIRMATION_DEPTH, "the head is too shallow to pin a settled header");
        uint256 pinned = later - CONFIRMATION_DEPTH;

        string memory laterHeader = _header("later", later);
        vm.createSelectFork(RPC_ALIAS, pinned);
        require(block.chainid == BaseBindings.BASE_CHAIN_ID, "the pinned fork is not Base mainnet");
        string memory pinnedHeader = _header("pinned", pinned);

        string memory headers = vm.serializeString("discovery.headers", "pinned", pinnedHeader);
        headers = vm.serializeString("discovery.headers", "later", laterHeader);

        string memory bindings = _bindings();

        string memory root = vm.serializeString("discovery", "purpose", _purpose());
        root = vm.serializeString("discovery", "status", "discovery_candidate_pending_review");
        root = vm.serializeString("discovery", "operator_transition", _transition());
        root = vm.serializeString(
            "discovery",
            "endpoint",
            "reached only through the configured `base` alias; no endpoint is ever recorded here"
        );
        root = vm.serializeString("discovery", "headers", headers);
        root = vm.serializeString("discovery", "transaction_gas_schedule", _gasSchedule());
        root = vm.serializeString("discovery", "bindings", bindings);
        root = vm.serializeString("discovery", "permit2", _account("discovery.permit2", PERMIT2));

        vm.writeJson(root, CANDIDATE_PATH);
        emit log_named_string("wrote the reviewable fork observation candidate to", CANDIDATE_PATH);
        emit log_named_uint("pinned header", pinned);
        emit log_named_uint("later header", later);
    }

    // -------------------------------------------------------------------------

    /// @dev Open the chain head without naming a block, and return the height it opened at.
    function _openHead() private returns (uint256) {
        vm.createSelectFork(RPC_ALIAS);
        require(block.chainid == BaseBindings.BASE_CHAIN_ID, "the fork is not Base mainnet");
        return block.number;
    }

    function _header(string memory name, uint256 number) private returns (string memory record) {
        uint256 restore = vm.activeFork();
        vm.createSelectFork(RPC_ALIAS, number);

        // A fork cannot see its own block hash — `blockhash(block.number)` is zero inside the
        // block being executed — so the parent's hash is what is recordable here, and it is
        // recorded under a name that says so rather than under `block_hash`.
        string memory key = string.concat("discovery.header.", name);
        record = vm.serializeUint(key, "block_number", block.number);
        record = vm.serializeUint(key, "parent_block_number", block.number - 1);
        record = vm.serializeBytes32(key, "parent_block_hash", blockhash(block.number - 1));
        record = vm.serializeUint(key, "timestamp", block.timestamp);
        record = vm.serializeUint(key, "base_fee_per_gas", block.basefee);

        vm.selectFork(restore);
    }

    /// @dev Every frozen binding, observed at the currently selected fork.
    function _bindings() private returns (string memory record) {
        string[8] memory ids = [
            "regent",
            "usdc",
            "cca_factory",
            "pool_manager",
            "position_manager",
            "live_staking",
            "governance_and_regent_safe",
            "dead_address"
        ];
        address[8] memory addresses = BaseBindings.all();

        for (uint256 i; i < ids.length; ++i) {
            string memory key = string.concat("discovery.binding.", ids[i]);
            string memory entry = _account(key, addresses[i]);

            if (addresses[i] == BaseBindings.REGENT || addresses[i] == BaseBindings.USDC) {
                entry =
                    vm.serializeUint(key, "decimals", _callUint(addresses[i], abi.encodeWithSignature("decimals()")));
                entry =
                    vm.serializeString(key, "symbol", _callString(addresses[i], abi.encodeWithSignature("symbol()")));
            }
            if (addresses[i] == BaseBindings.CCA_FACTORY) {
                entry = vm.serializeAddress(
                    key,
                    "protocol_fee_controller",
                    _callAddress(addresses[i], abi.encodeWithSignature("protocolFeeController()"))
                );
            }
            if (addresses[i] == BaseBindings.POSITION_MANAGER) {
                entry = vm.serializeUint(
                    key, "next_token_id", _callUint(addresses[i], abi.encodeWithSignature("nextTokenId()"))
                );
            }
            if (addresses[i] == BaseBindings.LIVE_STAKING) {
                entry =
                    vm.serializeAddress(key, "owner", _callAddress(addresses[i], abi.encodeWithSignature("owner()")));
                entry = vm.serializeBool(key, "paused", _callBool(addresses[i], abi.encodeWithSignature("paused()")));
            }

            record = vm.serializeString("discovery.bindings", ids[i], entry);
        }
    }

    /// @dev One account's complete code and proxy identity, observed from chain state alone.
    function _account(string memory key, address account) private returns (string memory record) {
        (string memory family, address implementation) = _classify(account);

        record = vm.serializeAddress(key, "address", account);
        record = vm.serializeUint(key, "runtime_bytes", account.code.length);
        record = vm.serializeBytes32(key, "runtime_code_hash", account.codehash);
        record = vm.serializeString(key, "proxy_family", family);
        record = vm.serializeAddress(key, "implementation", implementation);
        record = vm.serializeBytes32(key, "implementation_code_hash", implementation.codehash);
        record = vm.serializeUint(key, "implementation_runtime_bytes", implementation.code.length);
    }

    /// @dev The four supported patterns, in the order the check pass reads them. The Safe singleton
    ///      detector applies to exactly one address — the frozen Regent Safe — because slot 0 is
    ///      ordinary storage rather than a namespaced proxy slot. An account matching none of them
    ///      is recorded as `no_supported_proxy_pattern`, which says what was actually measured; it
    ///      is deliberately not a claim that the account is not a proxy at all.
    function _classify(address account) private view returns (string memory family, address implementation) {
        implementation = _slot(account, EIP1967_IMPLEMENTATION_SLOT);
        if (implementation != address(0)) return ("eip1967", implementation);
        implementation = _slot(account, EIP1822_IMPLEMENTATION_SLOT);
        if (implementation != address(0)) return ("eip1822", implementation);
        implementation = _slot(account, ZEPPELINOS_IMPLEMENTATION_SLOT);
        if (implementation != address(0)) return ("zeppelinos", implementation);
        if (account == BaseBindings.GOVERNANCE_AND_REGENT_SAFE) {
            implementation = _safeSingleton(account);
            if (implementation != address(0)) return ("safe_singleton", implementation);
        }
        return (NO_SUPPORTED_PROXY_PATTERN, address(0));
    }

    /// @dev The same four agreeing measurements the check pass makes: slot 0, `masterCopy()`, a
    ///      delegating-stub runtime shape, and a singleton that carries code.
    function _safeSingleton(address account) private view returns (address) {
        address slotValue = _slot(account, SAFE_SINGLETON_SLOT);
        if (slotValue == address(0) || slotValue.code.length == 0) return address(0);

        (bool ok, bytes memory returned) = account.staticcall(abi.encodePacked(SAFE_MASTER_COPY_SELECTOR));
        if (!ok || returned.length < 32) return address(0);
        if (abi.decode(returned, (address)) != slotValue) return address(0);

        uint256 proxyBytes = account.code.length;
        if (proxyBytes == 0 || proxyBytes > SAFE_PROXY_MAX_RUNTIME_BYTES) return address(0);
        if (proxyBytes >= slotValue.code.length) return address(0);

        return slotValue;
    }

    /// @dev The two protocol-rule values no contract exposes, left for the reviewer to supply.
    function _gasSchedule() private returns (string memory record) {
        record = vm.serializeString(
            "discovery.schedule",
            "note",
            "the Base transaction gas rules active at each header. No contract exposes these, so "
            "discovery cannot observe them: the reviewer fills them in from the protocol rules "
            "active at the recorded headers before installing this record. GAS-006 takes the "
            "applicable maximum of execution-plus-intrinsic and the calldata floor, never a sum."
        );
        record = vm.serializeUint("discovery.schedule", "intrinsic_gas", 0);
        record = vm.serializeUint("discovery.schedule", "calldata_zero_byte_gas", 0);
        record = vm.serializeUint("discovery.schedule", "calldata_nonzero_byte_gas", 0);
        record = vm.serializeUint("discovery.schedule", "floor_per_calldata_token", 0);
        record = vm.serializeString(
            "discovery.schedule", "reviewer_action", "replace every zero above with the rule active at these headers"
        );
    }

    function _purpose() private pure returns (string memory) {
        return "A reviewable candidate produced by an authorized read-only Base discovery pass. It is not "
            "evidence and nothing checks against it. A human reviews it, supplies the transaction gas "
            "schedule, and deliberately installs it as reports/frozen/fork-observations.json with status "
            "observed_and_committed before any fork claim can close.";
    }

    function _transition() private pure returns (string memory) {
        return "1. review every value below against an independent source; 2. fill in "
            "transaction_gas_schedule; 3. set status to observed_and_committed; 4. copy this file to "
            "reports/frozen/fork-observations.json; 5. add \"fork\" to activated_gates in "
            "requirements/ledger.toml and flip the eighteen fork claims to active; 6. commit both; "
            "7. run bin/fork-gate.sh check.";
    }

    // -------------------------------------------------------------------------

    function _slot(address account, bytes32 slot) private view returns (address) {
        return address(uint160(uint256(vm.load(account, slot))));
    }

    function _callUint(address target, bytes memory payload) private view returns (uint256) {
        (bool ok, bytes memory returned) = target.staticcall(payload);
        require(ok && returned.length >= 32, "discovery uint read failed");
        return abi.decode(returned, (uint256));
    }

    function _callBool(address target, bytes memory payload) private view returns (bool) {
        (bool ok, bytes memory returned) = target.staticcall(payload);
        require(ok && returned.length >= 32, "discovery bool read failed");
        return abi.decode(returned, (bool));
    }

    function _callAddress(address target, bytes memory payload) private view returns (address) {
        (bool ok, bytes memory returned) = target.staticcall(payload);
        require(ok && returned.length >= 32, "discovery address read failed");
        return abi.decode(returned, (address));
    }

    function _callString(address target, bytes memory payload) private view returns (string memory) {
        (bool ok, bytes memory returned) = target.staticcall(payload);
        require(ok && returned.length >= 64, "discovery string read failed");
        return abi.decode(returned, (string));
    }
}
