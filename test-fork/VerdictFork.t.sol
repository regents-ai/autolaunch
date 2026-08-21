// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {
    IContinuousClearingAuctionFactory
} from "continuous-clearing-auction/interfaces/IContinuousClearingAuctionFactory.sol";
import {ForkFixture} from "./ForkFixture.sol";

/// @notice `DEP-050`: the two committed headers reach the same normalized verdict for every fork
///         claim.
/// @dev Two layers, on purpose.
///
///      Inside Solidity, each side recomputes the header-independent decisions every other fork
///      claim depends on and emits them as one normalized verdict string. A verdict deliberately
///      carries a *decision*, never a header-dependent value: no block number, no timestamp, no
///      balance, no base fee. Two headers that disagree about a decision therefore produce two
///      different strings.
///
///      Outside Solidity, `bin/fork-gate.sh` extracts every `verdict <claim> <header>` line from
///      both runs' JSON reports and requires the pinned set and the later set to be identical, so
///      the agreement is proved across two separate processes rather than inside one of them.
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
            _emitVerdict(
                string.concat("DEP-050.proxy.", ids[i]), header, _observedString(_bindingPath(ids[i], "proxy_family"))
            );
        }

        // Each side asserts the whole set is well formed on its own; the cross-header comparison is
        // the gate's, because a single process comparing a value to itself proves nothing.
        assertEq(block.chainid, BaseBindings.BASE_CHAIN_ID, "a verdict run opened on the wrong chain");
    }
}
