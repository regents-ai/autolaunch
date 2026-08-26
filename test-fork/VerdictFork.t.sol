// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {
    IContinuousClearingAuctionFactory
} from "continuous-clearing-auction/interfaces/IContinuousClearingAuctionFactory.sol";
import {ForkFixture} from "./ForkFixture.sol";

/// @notice `DEP-050`: the two committed headers reach the same normalized verdict for the exact
///         subset of fork claims that runs at both of them.
/// @dev Two layers, on purpose.
///
///      Inside Solidity, each side recomputes the header-independent decisions the cross-header
///      claims depend on and emits them as one normalized verdict string. A verdict deliberately
///      carries a *decision*, never a header-dependent value: no block number, no timestamp, no
///      balance, no base fee. Two headers that disagree about a decision therefore produce two
///      different strings.
///
///      Outside Solidity, `bin/fork-gate.sh` extracts every `verdict <claim> <header>` line from
///      both runs' JSON reports and holds the later set to an equality rather than to whatever the
///      two happen to have in common: its keys must be exactly `DEP-040`, `DEP-041`, `DEP-042`,
///      `DEP-043`, `DEP-047`, `DEP-051`, `DEP-052`, `GAS-006` and every `DEP-050.*` key this
///      contract emits at the pinned header, each decision must equal its pinned counterpart, and a
///      missing or an extra key fails. The agreement is therefore proved across two separate
///      processes rather than inside one of them, and a silently shrinking later run fails instead
///      of reconciling a smaller intersection.
///
///      This claim is narrowed to the pinned header recorded for this candidate and the later head
///      captured for the same candidate. The ceremony-time fresh-head recheck belongs to
///      `regent-4wx`, not here.
contract VerdictForkTest is ForkFixture {
    function setUp() public {
        _loadObservations();
    }

    function test_DEP_050_ForkPinnedNormalizedVerdictsAreRecorded() public {
        _recordNormalizedVerdicts(Header.Pinned);
    }

    function test_DEP_050_ForkLatestNormalizedVerdictsMatchThePinnedHeader() public {
        _recordNormalizedVerdicts(Header.Later);
    }

    /// @dev The normalized decision set. Every entry is a yes/no or an identity comparison, which is
    ///      exactly what must not move between two headers of the same chain.
    function _recordNormalizedVerdicts(Header header) private {
        _selectFork(header);

        _emitVerdict(
            "DEP-050.chain", header, block.chainid == BaseBindings.BASE_CHAIN_ID ? "chain-id=base" : "chain-id=other"
        );

        _emitVerdict(
            "DEP-050.cca-code",
            header,
            BaseBindings.CCA_FACTORY.codehash == BaseBindings.CCA_FACTORY_RUNTIME_CODE_HASH
                ? "cca-runtime=frozen"
                : "cca-runtime=drifted"
        );

        address controller =
            address(IContinuousClearingAuctionFactory(BaseBindings.CCA_FACTORY).protocolFeeController());
        _emitVerdict("DEP-050.cca-controller", header, controller == address(0) ? "controller=zero" : "controller=set");

        string[8] memory ids = _bindingIds();
        address[8] memory addresses = _bindingAddresses();
        for (uint256 i; i < ids.length; ++i) {
            bool expectedEmpty = addresses[i] == BaseBindings.DEAD_ADDRESS;
            bool empty = addresses[i].code.length == 0;
            _emitVerdict(
                string.concat("DEP-050.binding.", ids[i]),
                header,
                empty == expectedEmpty ? "code-presence=expected" : "code-presence=unexpected"
            );

            if (expectedEmpty) continue;
            _emitVerdict(
                string.concat("DEP-050.codehash.", ids[i]),
                header,
                addresses[i].codehash == _observedBytes32(_bindingPath(ids[i], "runtime_code_hash"))
                    ? "codehash=committed"
                    : "codehash=drifted"
            );

            // Derived from live chain state at this header, never echoed back out of the committed
            // record. A verdict that restated a committed string would be identical at both headers
            // by construction and would prove nothing about either of them.
            (string memory family, address implementation, bytes32 implementationCodeHash,) =
                _classifyProxy(addresses[i]);
            _emitVerdict(string.concat("DEP-050.proxy.", ids[i]), header, string.concat("family=", family));
            _emitVerdict(
                string.concat("DEP-050.implementation.", ids[i]),
                header,
                implementation == _observedAddress(_bindingPath(ids[i], "implementation"))
                    ? "implementation=committed"
                    : "implementation=drifted"
            );
            _emitVerdict(
                string.concat("DEP-050.implementation-code.", ids[i]),
                header,
                implementationCodeHash == _observedBytes32(_bindingPath(ids[i], "implementation_code_hash"))
                    ? "implementation-codehash=committed"
                    : "implementation-codehash=drifted"
            );
        }

        // Each side asserts the whole set is well formed on its own; the cross-header comparison is
        // the gate's, because a single process comparing a value to itself proves nothing.
        assertEq(block.chainid, BaseBindings.BASE_CHAIN_ID, "a verdict run opened on the wrong chain");
    }
}
