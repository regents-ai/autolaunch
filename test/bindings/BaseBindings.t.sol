// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";

/// @notice Proves every compiled Base binding constant equals the frozen founder value.
/// @dev Expected values come from `test/fixtures/base-bindings.json`, which `bin/gate.sh`
///      independently reconciles against the `SPEC.md` binding table before this suite runs.
///      The fixture is therefore not derived from the library under test.
contract BaseBindingsTest is Test {
    string internal fixture;

    function setUp() public {
        fixture = vm.readFile("test/fixtures/base-bindings.json");
    }

    function test_DEP_020_RegentBindingEqualsFrozenAddress() public view {
        assertEq(BaseBindings.REGENT, vm.parseJsonAddress(fixture, ".bindings.regent"));
    }

    function test_DEP_021_UsdcBindingEqualsFrozenAddress() public view {
        assertEq(BaseBindings.USDC, vm.parseJsonAddress(fixture, ".bindings.usdc"));
    }

    function test_DEP_022_CcaFactoryBindingEqualsFrozenAddress() public view {
        assertEq(BaseBindings.CCA_FACTORY, vm.parseJsonAddress(fixture, ".bindings.cca_factory"));
    }

    function test_DEP_023_PoolManagerBindingEqualsFrozenAddress() public view {
        assertEq(BaseBindings.POOL_MANAGER, vm.parseJsonAddress(fixture, ".bindings.poolmanager"));
    }

    function test_DEP_024_PositionManagerBindingEqualsFrozenAddress() public view {
        assertEq(BaseBindings.POSITION_MANAGER, vm.parseJsonAddress(fixture, ".bindings.positionmanager"));
    }

    function test_DEP_025_LiveStakingBindingEqualsFrozenAddress() public view {
        assertEq(BaseBindings.LIVE_STAKING, vm.parseJsonAddress(fixture, ".bindings.live_staking"));
    }

    function test_DEP_026_GovernanceSafeBindingEqualsFrozenAddress() public view {
        assertEq(
            BaseBindings.GOVERNANCE_AND_REGENT_SAFE,
            vm.parseJsonAddress(fixture, ".bindings.governance_and_regent_safe")
        );
    }

    function test_DEP_027_DeadAddressBindingEqualsFrozenAddress() public view {
        assertEq(BaseBindings.DEAD_ADDRESS, vm.parseJsonAddress(fixture, ".bindings.dead_address"));
    }

    function test_DEP_028_CcaFactoryRuntimeCodeHashEqualsFrozenValue() public view {
        assertEq(
            BaseBindings.CCA_FACTORY_RUNTIME_CODE_HASH,
            vm.parseJsonBytes32(fixture, ".admission.cca_factory_runtime_code_hash")
        );
    }

    /// @dev The signature's provenance is the pinned CCA v2.1 implementation
    ///      (`src/ContinuousClearingAuctionFactory.sol`), not a local interface file;
    ///      `bin/gate.sh` proves the definition exists in that pinned source.
    function test_ABI_001_ProtocolFeeControllerSelectorDerivesFromPinnedSignature() public view {
        string memory signature =
            vm.parseJsonString(fixture, ".admission.cca_factory_protocol_fee_controller_signature");
        bytes4 admitted = bytes4(vm.parseJsonBytes(fixture, ".admission.cca_factory_protocol_fee_controller_selector"));

        assertEq(bytes4(keccak256(bytes(signature))), admitted);
    }
}
