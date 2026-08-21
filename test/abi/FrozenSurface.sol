// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Reads the committed frozen ABI surface and reconciles it against compiler truth.
/// @dev `bin/freeze-artifacts.py` generates `reports/frozen/abi-surface.json` from the compiler
///      artifacts and `bin/gate.sh` re-runs it in check mode, so a hand edit here cannot pass the
///      gate. These tests therefore treat the file as the frozen *record* and always compare it
///      against something Solidity can derive on its own — a `.selector`, an event selector, or a
///      keccak of the canonical signature — never against a second copy of itself.
///
///      Every recorded line is `"<selector-or-topic> <canonical signature>"`, with events carrying
///      a trailing `" indexed=<n>"`. Because the signature carries every integer and value width,
///      a changed width changes the signature, which changes the hash, which fails both directions
///      of the comparison below.
abstract contract FrozenSurface is Test {
    string internal constant SURFACE_PATH = "reports/frozen/abi-surface.json";
    string internal constant SIZES_PATH = "reports/frozen/deployable-sizes.json";
    string internal constant MANIFEST_PATH = "contracts/autolaunch-release-manifest.json";

    string private _surface;

    struct FrozenEvent {
        bytes32 topic0;
        string signature;
        uint256 indexedFields;
    }

    function _loadFrozenSurface() internal {
        _surface = vm.readFile(SURFACE_PATH);
    }

    function _frozenStrings(string memory contractName, string memory field) internal view returns (string[] memory) {
        return vm.parseJsonStringArray(_surface, string.concat(".contracts.", contractName, ".", field));
    }

    function _consumedStrings(string memory upstream, string memory field) internal view returns (string[] memory) {
        return vm.parseJsonStringArray(_surface, string.concat(".consumed.", upstream, ".", field));
    }

    // -------------------------------------------------------------------------
    // line shapes
    // -------------------------------------------------------------------------

    function _functionLine(bytes4 selector, string memory signature) internal view returns (string memory) {
        return string.concat(vm.toString(abi.encodePacked(selector)), " ", signature);
    }

    function _eventLine(FrozenEvent memory entry) internal view returns (string memory) {
        return
            string.concat(
                vm.toString(entry.topic0), " ", entry.signature, " indexed=", vm.toString(entry.indexedFields)
            );
    }

    // -------------------------------------------------------------------------
    // reconciliation
    // -------------------------------------------------------------------------

    /// @dev The frozen list and the expected list must be the same set, in both directions: an
    ///      entry the compiler produced but nobody expected fails just as loudly as one that is
    ///      expected and absent.
    function _assertSameSet(string[] memory frozenLines, string[] memory expected, string memory what) internal pure {
        assertEq(frozenLines.length, expected.length, string.concat(what, ": the frozen surface has a different size"));
        for (uint256 i; i < expected.length; ++i) {
            assertTrue(
                _contains(frozenLines, expected[i]),
                string.concat(what, ": the frozen surface does not carry [", expected[i], "]")
            );
        }
        for (uint256 i; i < frozenLines.length; ++i) {
            assertTrue(
                _contains(expected, frozenLines[i]),
                string.concat(what, ": nothing expects the frozen entry [", frozenLines[i], "]")
            );
        }
    }

    /// @dev One function: the frozen line must equal the compiler's own selector for the exact
    ///      canonical signature, and that signature must hash to that selector.
    function _assertFrozenFunction(
        string[] memory frozenLines,
        bytes4 selector,
        string memory signature,
        string memory what
    ) internal view returns (string memory line) {
        assertEq(
            bytes4(keccak256(bytes(signature))), selector, string.concat(what, ": ", signature, " is not that selector")
        );
        line = _functionLine(selector, signature);
        assertTrue(_contains(frozenLines, line), string.concat(what, ": the frozen surface lacks [", line, "]"));
    }

    /// @dev One event: the frozen topic must equal the compiler's event selector *and* the keccak of
    ///      the canonical signature, which together pin the name, the argument types, and every
    ///      integer width. The indexed count is compared separately because it is topic layout
    ///      rather than signature.
    function _assertFrozenEvent(string[] memory frozenLines, FrozenEvent memory entry, string memory what)
        internal
        view
        returns (string memory line)
    {
        assertEq(
            keccak256(bytes(entry.signature)),
            entry.topic0,
            string.concat(what, ": ", entry.signature, " does not hash to the compiler's topic")
        );
        line = _eventLine(entry);
        assertTrue(_contains(frozenLines, line), string.concat(what, ": the frozen surface lacks [", line, "]"));
    }

    function _contains(string[] memory haystack, string memory needle) internal pure returns (bool) {
        bytes32 wanted = keccak256(bytes(needle));
        for (uint256 i; i < haystack.length; ++i) {
            if (keccak256(bytes(haystack[i])) == wanted) return true;
        }
        return false;
    }

    /// @dev Whether any frozen line's signature part starts with `name(`, used to prove a whole
    ///      family of superseded entry points is absent rather than one exact overload.
    function _declaresFunctionNamed(string[] memory frozenLines, string memory name) internal pure returns (bool) {
        bytes memory wanted = bytes(string.concat(name, "("));
        for (uint256 i; i < frozenLines.length; ++i) {
            bytes memory line = bytes(frozenLines[i]);
            // Every line is "0x........ <signature>"; the signature starts after the space.
            uint256 start = 11;
            if (line.length < start + wanted.length) continue;
            bool same = true;
            for (uint256 j; j < wanted.length; ++j) {
                if (line[start + j] != wanted[j]) {
                    same = false;
                    break;
                }
            }
            if (same) return true;
        }
        return false;
    }
}
