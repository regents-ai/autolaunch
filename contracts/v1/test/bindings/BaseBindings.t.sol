// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {FrozenIdentity} from "../../src/bindings/FrozenIdentity.sol";

/// @notice Proves every compiled Base binding equals the frozen founder value, and that the
///         compiled binding set as a whole is exactly the frozen set.
/// @dev Expected values come from `requirements/frozen-identity.json`, which `bin/gate.sh`
///      reconciles against the `SPEC.md` binding table — by name, not only by literal —
///      before this suite runs. The fixture is therefore not derived from the library under
///      test.
contract BaseBindingsTest is Test {
    string internal fixture;

    function setUp() public {
        fixture = vm.readFile("requirements/frozen-identity.json");
    }

    function _frozenAddress(uint256 index) internal view returns (address) {
        return vm.parseJsonAddress(fixture, string.concat(".bindings[", vm.toString(index), "].address"));
    }

    function test_DEP_020_RegentBindingEqualsFrozenAddress() public view {
        assertEq(BaseBindings.REGENT, _frozenAddress(0));
    }

    function test_DEP_021_UsdcBindingEqualsFrozenAddress() public view {
        assertEq(BaseBindings.USDC, _frozenAddress(1));
    }

    function test_DEP_022_CcaFactoryBindingEqualsFrozenAddress() public view {
        assertEq(BaseBindings.CCA_FACTORY, _frozenAddress(2));
    }

    function test_DEP_023_PoolManagerBindingEqualsFrozenAddress() public view {
        assertEq(BaseBindings.POOL_MANAGER, _frozenAddress(3));
    }

    function test_DEP_024_PositionManagerBindingEqualsFrozenAddress() public view {
        assertEq(BaseBindings.POSITION_MANAGER, _frozenAddress(4));
    }

    function test_DEP_025_LiveStakingBindingEqualsFrozenAddress() public view {
        assertEq(BaseBindings.LIVE_STAKING, _frozenAddress(5));
    }

    function test_DEP_026_GovernanceAndRegentSafeBindingEqualsFrozenAddress() public view {
        assertEq(BaseBindings.GOVERNANCE_AND_REGENT_SAFE, _frozenAddress(6));
    }

    function test_DEP_027_DeadAddressBindingEqualsFrozenAddress() public view {
        assertEq(BaseBindings.DEAD_ADDRESS, _frozenAddress(7));
    }

    function test_DEP_028_CcaFactoryRuntimeCodeHashEqualsFrozenValue() public view {
        assertEq(
            BaseBindings.CCA_FACTORY_RUNTIME_CODE_HASH, vm.parseJsonBytes32(fixture, ".admission.runtime_code_hash")
        );
    }

    /// @dev The designation only. Whether each address is actually deployed on Base is
    ///      deployed-runtime truth that no hermetic test can reach; it stays bound to the
    ///      authorized fork gate (`DEP-042`, `DEP-047`, `DEP-051`).
    function test_DEP_029_CompiledBindingSetIsDesignatedForBaseMainnet() public view {
        assertEq(BaseBindings.BASE_CHAIN_ID, vm.parseJsonUint(fixture, ".chain.id"));
        assertEq(vm.parseJsonString(fixture, ".chain.name"), "base-mainnet");
    }

    /// @dev The whole-set proof the per-binding tests above cannot give: nothing added,
    ///      nothing removed, nothing reordered, and no two bindings collapsed onto one
    ///      address.
    function test_DEP_012_BindingSetIsExactlyTheFrozenSet() public view {
        address[8] memory compiled = BaseBindings.all();

        bytes memory packed;
        for (uint256 i = 0; i < compiled.length; i++) {
            assertEq(compiled[i], _frozenAddress(i));
            assertTrue(compiled[i] != address(0));
            for (uint256 j = i + 1; j < compiled.length; j++) {
                assertTrue(compiled[i] != compiled[j]);
            }
            packed = abi.encodePacked(packed, compiled[i]);
        }

        assertEq(keccak256(packed), FrozenIdentity.BINDING_SET_DIGEST);
    }

    /// @dev The signature's provenance is the pinned CCA v2.1 implementation, not a local
    ///      interface file; `bin/gate.sh` proves the body-bearing definition exists there
    ///      with exactly this signature, mutability, and return type. Here the EVM derives
    ///      the selector independently of any hand-written value.
    function test_ABI_001_ProtocolFeeControllerSelectorDerivesFromPinnedSignature() public view {
        string memory signature = vm.parseJsonString(fixture, ".admission.signature");
        bytes4 admitted = bytes4(vm.parseJsonBytes(fixture, ".admission.selector"));

        assertEq(bytes4(keccak256(bytes(signature))), admitted);
        assertEq(FrozenIdentity.CCA_PROTOCOL_FEE_CONTROLLER_SELECTOR, admitted);
    }
}
