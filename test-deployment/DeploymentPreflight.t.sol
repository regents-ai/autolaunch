// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The final external-state preflight, run in the deployment gate's two provider modes.
/// @dev This contract closes no requirement and carries no requirement id, so the deployment gate
///      excludes it by name from the compiled listing and the ledger reconciliation. Every read
///      below is a hard `staticcall` that reverts if the provider, the account, or the getter
///      fails, so a run that cannot reach Base fails loudly instead of reporting an empty
///      observation, and the gate can never claim a fork it did not open.
///
///      This profile has no filesystem permission, so nothing here reads a frozen record or writes
///      an observation. Every value is emitted as a decoded log and compared by
///      `bin/deployment-gate.sh`: runtime and supported proxy identity for the eight bindings plus
///      canonical Permit2 against `reports/frozen/fork-observations.json`, and the mutable control
///      surface against `deployments/base-mainnet/mainnet-no-go-packet.json`. Those mutable facts
///      are re-read on every rehearsal because each can move between the reviewed packet and the
///      broadcast, and each changes whether the deployed system works or who controls it.
///
///      Nothing here writes, signs, broadcasts, funds, or moves value. The fork is read-only and
///      the endpoint is reached only through the `base` alias, whose value is never printed.
contract DeploymentPreflightTest is Test {
    /// @notice The configured Base endpoint alias. Never an endpoint, always an alias.
    string internal constant RPC_ALIAS = "base";

    /// @notice Canonical Permit2 used by every CCA bid.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice The Safe storage slots that hold the two powers a signature check does not cover.
    /// @dev Derived rather than transcribed, so a mistyped literal cannot silently read slot zero.
    bytes32 internal constant SAFE_GUARD_SLOT = keccak256("guard_manager.guard.address");
    bytes32 internal constant SAFE_FALLBACK_HANDLER_SLOT = keccak256("fallback_manager.handler.address");

    /// @notice The sentinel a Safe's module linked list starts from.
    address internal constant SAFE_MODULE_SENTINEL = address(0x1);

    /// @notice The three namespaced implementation slots and the Safe singleton slot, in the order
    ///         the frozen observation record was classified by.
    /// @dev The rule is `test-fork/ForkDiscovery.t.sol`'s, restated because this test root compiles
    ///      on its own and the deployment profile can read no file. A binding matching none of the
    ///      four is `no_supported_proxy_pattern`. Slot zero is ordinary storage for anything that is
    ///      not a Safe proxy, so that detector applies to exactly the frozen Regent Safe.
    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant EIP1822_IMPLEMENTATION_SLOT =
        0xc5f16f0fcc639fa48a6947836d9850f504798523bf8c9a3a87d5876cf622bcf7;
    bytes32 internal constant ZEPPELINOS_IMPLEMENTATION_SLOT =
        0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3;
    bytes32 internal constant SAFE_SINGLETON_SLOT = bytes32(uint256(0));
    bytes4 internal constant SAFE_MASTER_COPY_SELECTOR = 0xa619486e;
    uint256 internal constant SAFE_PROXY_MAX_RUNTIME_BYTES = 256;
    string internal constant NO_SUPPORTED_PROXY_PATTERN = "no_supported_proxy_pattern";

    function setUp() public {
        vm.createSelectFork(RPC_ALIAS);
    }

    /// @notice Chain identity, and the complete runtime and supported proxy identity of every
    ///         frozen binding, emitted for comparison against the frozen observation record.
    /// @dev Nothing is asserted about a binding here, because the gate compares every value below
    ///      to `reports/frozen/fork-observations.json` exactly: a moved runtime, a moved
    ///      implementation, or an empty read fails the run rather than passing a presence check.
    function test_PreflightChainAndFrozenBindingIdentity() public {
        assertEq(block.chainid, BaseBindings.BASE_CHAIN_ID, "the preflight fork is not Base mainnet");
        emit log_named_uint("preflight block_number", block.number);
        emit log_named_uint("preflight block_timestamp", block.timestamp);

        string[8] memory ids = _bindingIds();
        address[8] memory bindings = BaseBindings.all();
        for (uint256 i; i < bindings.length; ++i) {
            _emitBinding(ids[i], bindings[i]);
        }
        _emitBinding("permit2", PERMIT2);
    }

    /// @notice The CCA factory is the admitted code and still charges no protocol fee.
    function test_PreflightCcaFactoryIdentityAndZeroFeeController() public {
        assertEq(
            BaseBindings.CCA_FACTORY.codehash,
            BaseBindings.CCA_FACTORY_RUNTIME_CODE_HASH,
            "the deployed CCA factory is not the admitted runtime code"
        );
        address controller = _callAddress(BaseBindings.CCA_FACTORY, abi.encodeWithSignature("protocolFeeController()"));
        assertEq(controller, address(0), "the CCA factory now has a protocol fee controller");
    }

    /// @notice Live staking is unpaused, bound to the frozen USDC, and owned by a real account.
    /// @dev A paused live-staking contract means the splitter's USDC skim cannot settle, so a
    ///      deployment into that state is a stop rather than a note. All three are also emitted,
    ///      because ownership can move: the gate holds each to the committed packet.
    function test_PreflightLiveStakingOwnerPauseAndUsdcBinding() public {
        address staking = BaseBindings.LIVE_STAKING;

        address owner = _callAddress(staking, abi.encodeWithSignature("owner()"));
        assertTrue(owner != address(0), "live staking reports no owner");

        bool paused = _callBool(staking, abi.encodeWithSignature("paused()"));
        assertFalse(paused, "live staking is paused");

        address usdc = _callAddress(staking, abi.encodeWithSignature("usdc()"));
        assertEq(usdc, BaseBindings.USDC, "live staking is bound to a different USDC");

        emit log_named_address("preflight live_staking_owner", owner);
        emit log_named_string("preflight live_staking_paused", paused ? "true" : "false");
        emit log_named_address("preflight live_staking_usdc", usdc);
    }

    /// @notice The mutable USDC policy the revenue path depends on.
    /// @dev USDC is upgradeable and centrally controlled: it can be paused, and it can blacklist an
    ///      account. Both are read immediately before a ceremony because either one would break the
    ///      splitter's settlement to the frozen Safe after deployment, not before it.
    function test_PreflightUsdcPauseAndBlacklistPolicy() public {
        address usdc = BaseBindings.USDC;

        assertFalse(_callBool(usdc, abi.encodeWithSignature("paused()")), "USDC is paused");
        assertFalse(
            _callBool(usdc, abi.encodeWithSignature("isBlacklisted(address)", BaseBindings.GOVERNANCE_AND_REGENT_SAFE)),
            "the frozen Regent Safe is blacklisted by USDC"
        );
        assertFalse(
            _callBool(usdc, abi.encodeWithSignature("isBlacklisted(address)", BaseBindings.LIVE_STAKING)),
            "the live staking binding is blacklisted by USDC"
        );

        emit log_named_address("preflight usdc_pauser", _callAddress(usdc, abi.encodeWithSignature("pauser()")));
        emit log_named_address(
            "preflight usdc_blacklister", _callAddress(usdc, abi.encodeWithSignature("blacklister()"))
        );
    }

    /// @notice The exact Governance/Regent Safe control surface, emitted for exact comparison.
    /// @dev The factory's only mutable authority is this Safe, so who can act as it — and through
    ///      what guard, module or fallback handler — is part of the deployment decision. Every
    ///      value is emitted and the gate holds each to the committed packet, so an added owner, a
    ///      lowered threshold, an installed guard, a new module, a swapped fallback handler or a
    ///      changed singleton or version is each a stop. The relations asserted here are the ones
    ///      that must hold whatever the membership is, which is what preparation has instead.
    function test_PreflightGovernanceSafeControlSurface() public {
        address safe = BaseBindings.GOVERNANCE_AND_REGENT_SAFE;

        (bool ok, bytes memory returned) = safe.staticcall(abi.encodeWithSignature("getOwners()"));
        require(ok, "the Regent Safe did not answer getOwners()");
        address[] memory owners = abi.decode(returned, (address[]));
        assertGt(owners.length, 0, "the Regent Safe reports no owner");

        uint256 threshold = _callUint(safe, abi.encodeWithSignature("getThreshold()"));
        assertGt(threshold, 0, "the Regent Safe has a zero signature threshold");
        assertLe(threshold, owners.length, "the Regent Safe threshold exceeds its own owner count");

        (ok, returned) =
            safe.staticcall(abi.encodeWithSignature("getModulesPaginated(address,uint256)", SAFE_MODULE_SENTINEL, 32));
        require(ok, "the Regent Safe did not answer getModulesPaginated");
        (address[] memory modules, address nextModulePage) = abi.decode(returned, (address[], address));
        assertEq(
            nextModulePage, SAFE_MODULE_SENTINEL, "the Regent Safe has more modules than this exact snapshot reads"
        );

        emit log_named_uint("preflight safe_threshold", threshold);
        emit log_named_array("preflight safe_owners", owners);
        emit log_named_array("preflight safe_modules", modules);
        emit log_named_address("preflight safe_module_next_page", nextModulePage);
        emit log_named_address("preflight safe_guard", _slotAsAddress(safe, SAFE_GUARD_SLOT));
        emit log_named_address("preflight safe_fallback_handler", _slotAsAddress(safe, SAFE_FALLBACK_HANDLER_SLOT));
        emit log_named_address("preflight safe_singleton", _slotAsAddress(safe, bytes32(0)));
        emit log_named_string("preflight safe_version", _callString(safe, abi.encodeWithSignature("VERSION()")));
    }

    // -------------------------------------------------------------------------
    // binding identity
    // -------------------------------------------------------------------------

    /// @dev The frozen observation record's own key for each binding, in `BaseBindings.all()` order.
    function _bindingIds() private pure returns (string[8] memory ids) {
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

    function _emitBinding(string memory id, address binding) private {
        (string memory family, address implementation) = _classify(binding);

        emit log_named_string("preflight binding_id", id);
        emit log_named_address("  binding_address", binding);
        emit log_named_uint("  binding_runtime_bytes", binding.code.length);
        emit log_named_bytes32("  binding_runtime_code_hash", binding.codehash);
        emit log_named_string("  binding_proxy_family", family);
        emit log_named_address("  binding_implementation", implementation);
        emit log_named_bytes32(
            "  binding_implementation_code_hash", implementation == address(0) ? bytes32(0) : implementation.codehash
        );
        emit log_named_uint("  binding_implementation_runtime_bytes", implementation.code.length);
    }

    /// @dev The four supported proxy patterns, in the order the frozen record was classified by.
    function _classify(address account) private view returns (string memory family, address implementation) {
        implementation = _slotAsAddress(account, EIP1967_IMPLEMENTATION_SLOT);
        if (implementation != address(0)) return ("eip1967", implementation);
        implementation = _slotAsAddress(account, EIP1822_IMPLEMENTATION_SLOT);
        if (implementation != address(0)) return ("eip1822", implementation);
        implementation = _slotAsAddress(account, ZEPPELINOS_IMPLEMENTATION_SLOT);
        if (implementation != address(0)) return ("zeppelinos", implementation);
        if (account == BaseBindings.GOVERNANCE_AND_REGENT_SAFE) {
            implementation = _safeSingleton(account);
            if (implementation != address(0)) return ("safe_singleton", implementation);
        }
        return (NO_SUPPORTED_PROXY_PATTERN, address(0));
    }

    /// @dev Four agreeing measurements: slot zero, `masterCopy()`, a delegating-stub runtime shape,
    ///      and a singleton carrying more code than the stub in front of it.
    function _safeSingleton(address account) private view returns (address) {
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

    // -------------------------------------------------------------------------
    // hard reads
    // -------------------------------------------------------------------------

    function _callUint(address target, bytes memory payload) private view returns (uint256) {
        (bool ok, bytes memory returned) = target.staticcall(payload);
        require(ok && returned.length >= 32, "preflight uint read failed");
        return abi.decode(returned, (uint256));
    }

    function _callBool(address target, bytes memory payload) private view returns (bool) {
        (bool ok, bytes memory returned) = target.staticcall(payload);
        require(ok && returned.length >= 32, "preflight bool read failed");
        return abi.decode(returned, (bool));
    }

    function _callAddress(address target, bytes memory payload) private view returns (address) {
        (bool ok, bytes memory returned) = target.staticcall(payload);
        require(ok && returned.length >= 32, "preflight address read failed");
        return abi.decode(returned, (address));
    }

    function _callString(address target, bytes memory payload) private view returns (string memory) {
        (bool ok, bytes memory returned) = target.staticcall(payload);
        require(ok && returned.length >= 64, "preflight string read failed");
        return abi.decode(returned, (string));
    }

    function _slotAsAddress(address account, bytes32 slot) private view returns (address) {
        return address(uint160(uint256(vm.load(account, slot))));
    }
}
