// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The final external-state preflight, run only in the deployment gate's separately
///         authorized Base rehearsal mode.
/// @dev This contract closes no requirement and carries no requirement id. It is excluded by name
///      from the deployment gate's compiled listing and from the ledger reconciliation, exactly as
///      the fork gate excludes its discovery pass, because it asserts live chain truth that no
///      committed record can freeze and that no offline run can reach.
///
///      What it does is stop a ceremony rather than describe one. Every read below is a hard
///      `staticcall` that reverts if the provider, the account, or the getter fails, so a run that
///      cannot reach Base fails loudly instead of reporting an empty observation, and the gate can
///      never claim a fork it did not open. The mutable facts — the live staking pause, the USDC
///      pause and blacklist policy, and the Safe's exact owner set, threshold, guard, modules and
///      fallback handler — are read again here because each of them can move between the reviewed
///      packet and the broadcast, and each of them changes whether the deployed system works or who
///      controls it.
///
///      Nothing here writes, signs, broadcasts, funds, or moves value. The fork is read-only and
///      the endpoint is reached only through the `base` alias, whose value is never printed.
contract DeploymentPreflightTest is Test {
    /// @notice The configured Base endpoint alias. Never an endpoint, always an alias.
    string internal constant RPC_ALIAS = "base";

    /// @notice The Safe storage slots that hold the two powers a signature check does not cover.
    /// @dev Derived rather than transcribed, so a mistyped literal cannot silently read slot zero.
    bytes32 internal constant SAFE_GUARD_SLOT = keccak256("guard_manager.guard.address");
    bytes32 internal constant SAFE_FALLBACK_HANDLER_SLOT = keccak256("fallback_manager.handler.address");

    /// @notice The sentinel a Safe's module linked list starts from.
    address internal constant SAFE_MODULE_SENTINEL = address(0x1);

    function setUp() public {
        vm.createSelectFork(RPC_ALIAS);
    }

    /// @notice Chain identity, and the presence or absence of code at every frozen binding.
    function test_PreflightChainAndFrozenBindingPresence() public {
        assertEq(block.chainid, BaseBindings.BASE_CHAIN_ID, "the preflight fork is not Base mainnet");
        emit log_named_uint("preflight block_number", block.number);
        emit log_named_uint("preflight block_timestamp", block.timestamp);

        address[8] memory bindings = BaseBindings.all();
        for (uint256 i; i < bindings.length; ++i) {
            if (bindings[i] == BaseBindings.DEAD_ADDRESS) {
                assertEq(bindings[i].code.length, 0, "the dead address carries code");
                continue;
            }
            assertGt(bindings[i].code.length, 0, "a frozen binding carries no deployed code");
            emit log_named_address("preflight binding", bindings[i]);
            emit log_named_bytes32("  runtime_codehash", bindings[i].codehash);
        }
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
    ///      deployment into that state is a stop rather than a note.
    function test_PreflightLiveStakingOwnerPauseAndUsdcBinding() public {
        address staking = BaseBindings.LIVE_STAKING;

        address owner = _callAddress(staking, abi.encodeWithSignature("owner()"));
        assertTrue(owner != address(0), "live staking reports no owner");

        assertFalse(_callBool(staking, abi.encodeWithSignature("paused()")), "live staking is paused");
        assertEq(
            _callAddress(staking, abi.encodeWithSignature("usdc()")),
            BaseBindings.USDC,
            "live staking is bound to a different USDC"
        );

        emit log_named_address("preflight live_staking_owner", owner);
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

    /// @notice The exact Governance/Regent Safe control surface, frozen into this run's record.
    /// @dev The factory's only mutable authority is this Safe, so who can act as it — and through
    ///      what guard, module or fallback handler — is part of the deployment decision. Every
    ///      value is emitted for the packet; the structural relations that must hold whatever the
    ///      membership is are asserted here.
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
