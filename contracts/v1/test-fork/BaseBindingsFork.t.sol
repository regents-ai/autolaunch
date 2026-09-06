// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {
    IContinuousClearingAuctionFactory
} from "continuous-clearing-auction/interfaces/IContinuousClearingAuctionFactory.sol";
import {ForkFixture} from "./ForkFixture.sol";
import {ForkHeaders} from "./ForkHeaders.sol";

/// @notice `DEP-040` through `DEP-044`, `DEP-047`, `DEP-051`, and `DEP-052`.
/// @dev Every claim here runs at the committed pinned header, and all of them but `DEP-044` run
///      again at the later head, each in its own separately created fork that shares state with no
///      other. Every run compares the live chain against `reports/frozen/fork-observations.json`,
///      which was recorded by a separate authorized discovery pass and reviewed before this gate
///      ever ran.
///
///      `DEP-044` is pinned-only on purpose: REGENT and USDC transfer, allowance and getter
///      semantics are the deployed tokens' own code, and the fresh-head subset re-reads the code
///      identity that would have to move first (`DEP-042`, `DEP-051`, `DEP-043`).
contract BaseBindingsForkTest is ForkFixture {
    function setUp() public {
        _loadObservations();
    }

    // -------------------------------------------------------------------------
    // DEP-052 — the header itself, bound before any claim
    // -------------------------------------------------------------------------

    function test_DEP_052_ForkPinnedHeaderIsFullyBoundToTheCommittedRecord() public {
        _checkHeaderBinding(Header.Pinned);
    }

    function test_DEP_052_ForkLatestHeaderIsFullyBoundToTheCommittedRecord() public {
        _checkHeaderBinding(Header.Later);
    }

    /// @dev Two things, and the first one is the reason this claim exists at all.
    ///
    ///      `_selectFork` binds every recorded field of the header it opens — number, parent number
    ///      and parent hash, timestamp, base fee, chain id — and every fork selector in this
    ///      repository reaches its own work only through that function, so no claim can execute
    ///      against a header it has not identified. Checking only the height would not be enough:
    ///      a different chain, or the same chain reorged below the recorded header, can present the
    ///      same height with a different parent. This test re-asserts that binding in the open so
    ///      the claim has evidence of its own rather than only a side effect of every other claim.
    ///
    ///      Second, the two committed headers must stand in the fixed relationship the discovery
    ///      pass constructed: the later header is exactly `PINNED_TO_LATER_DISTANCE` blocks ahead of
    ///      the pinned one, and it is strictly later in time. That is what makes "the same candidate
    ///      at a later head" a defined comparison rather than two arbitrary blocks.
    function _checkHeaderBinding(Header header) private {
        uint256 opened = _selectFork(header);

        string memory prefix = string.concat(".headers.", _headerName(header), ".");
        assertEq(
            opened, _observedUint(string.concat(prefix, "block_number")), "the opened header is not the recorded one"
        );
        assertGt(block.number, 0, "a fork opened at the genesis header");
        assertGt(block.timestamp, 0, "the recorded header carries no timestamp");
        assertTrue(
            blockhash(block.number - 1) != bytes32(0), "the parent hash is unavailable, so the header is unbound"
        );

        uint256 pinned = _observedUint(".headers.pinned.block_number");
        uint256 later = _observedUint(".headers.later.block_number");
        assertEq(
            later - pinned,
            ForkHeaders.PINNED_TO_LATER_DISTANCE,
            "the two committed headers are not the fixed distance apart"
        );
        assertEq(
            _observedUint(".headers.pinned.parent_block_number"),
            pinned - 1,
            "the pinned record's parent number is not its own predecessor"
        );
        assertEq(
            _observedUint(".headers.later.parent_block_number"),
            later - 1,
            "the later record's parent number is not its own predecessor"
        );
        assertGt(
            _observedUint(".headers.later.timestamp"),
            _observedUint(".headers.pinned.timestamp"),
            "the later header is not later in time than the pinned one"
        );

        _emitVerdict("DEP-052", header, "header-fully-bound-and-fixed-distance");
    }

    // -------------------------------------------------------------------------
    // DEP-040 — the CCA runtime code hash
    // -------------------------------------------------------------------------

    function test_DEP_040_ForkPinnedCcaFactoryRuntimeCodeHashMatchesFrozenValue() public {
        _checkCcaRuntimeCodeHash(Header.Pinned);
    }

    function test_DEP_040_ForkLatestCcaFactoryRuntimeCodeHashMatchesFrozenValue() public {
        _checkCcaRuntimeCodeHash(Header.Later);
    }

    function _checkCcaRuntimeCodeHash(Header header) private {
        _selectFork(header);

        bytes32 found = BaseBindings.CCA_FACTORY.codehash;
        assertEq(
            found,
            BaseBindings.CCA_FACTORY_RUNTIME_CODE_HASH,
            "the deployed CCA factory is not the admitted runtime; admission stops"
        );
        _emitVerdict("DEP-040", header, "cca-runtime-code-hash=frozen");
    }

    // -------------------------------------------------------------------------
    // DEP-041 — the zero protocol fee controller
    // -------------------------------------------------------------------------

    function test_DEP_041_ForkPinnedCcaFactoryProtocolFeeControllerIsZero() public {
        _checkProtocolFeeController(Header.Pinned);
    }

    function test_DEP_041_ForkLatestCcaFactoryProtocolFeeControllerIsZero() public {
        _checkProtocolFeeController(Header.Later);
    }

    function _checkProtocolFeeController(Header header) private {
        _selectFork(header);

        address controller =
            address(IContinuousClearingAuctionFactory(BaseBindings.CCA_FACTORY).protocolFeeController());
        assertEq(controller, address(0), "the CCA factory has a protocol fee controller; admission stops");
        _emitVerdict("DEP-041", header, "cca-protocol-fee-controller=zero");
    }

    // -------------------------------------------------------------------------
    // DEP-042 — code presence
    // -------------------------------------------------------------------------

    function test_DEP_042_ForkPinnedEveryBindingHasTheExpectedRuntimeCodePresence() public {
        _checkCodePresence(Header.Pinned);
    }

    function test_DEP_042_ForkLatestEveryBindingHasTheExpectedRuntimeCodePresence() public {
        _checkCodePresence(Header.Later);
    }

    function _checkCodePresence(Header header) private {
        _selectFork(header);

        string[8] memory ids = _bindingIds();
        address[8] memory addresses = _bindingAddresses();
        for (uint256 i; i < ids.length; ++i) {
            uint256 length = addresses[i].code.length;
            if (addresses[i] == BaseBindings.DEAD_ADDRESS) {
                assertEq(length, 0, "the dead address carries code");
            } else {
                assertGt(length, 0, string.concat("binding ", ids[i], " carries no deployed runtime code"));
                assertEq(
                    length,
                    _observedUint(_bindingPath(ids[i], "runtime_bytes")),
                    string.concat("binding ", ids[i], " changed runtime length since the committed observation")
                );
            }
        }
        _emitVerdict("DEP-042", header, "all-bindings-present-dead-empty");
    }

    // -------------------------------------------------------------------------
    // DEP-043 — proxy family and implementation
    // -------------------------------------------------------------------------

    function test_DEP_043_ForkPinnedEveryBindingProxyStatusMatchesTheManifest() public {
        _checkProxyStatus(Header.Pinned);
    }

    function test_DEP_043_ForkLatestEveryBindingProxyStatusMatchesTheManifest() public {
        _checkProxyStatus(Header.Later);
    }

    /// @dev No binding is assumed to be EIP-1967, and none is taken on the record's word. The
    ///      family, the implementation address, and the implementation's own runtime code identity
    ///      are all re-derived from live chain state here and compared against what the reviewed
    ///      discovery pass recorded. A proxy of any recognized family must point at an
    ///      implementation that carries code — an EIP-1822 proxy no less than an EIP-1967 one,
    ///      because a codeless implementation makes every delegated call a silent success.
    ///
    ///      A binding that matches none of the supported patterns is reported as
    ///      `no_supported_proxy_pattern`, and that is the whole claim: this gate reads three
    ///      implementation slots plus, for exactly the frozen Regent Safe, the Safe singleton
    ///      pattern, so a fifth pattern would be invisible to it and no universal non-proxy claim
    ///      is made about any address. Runtime code hashes stay mandatory for every binding
    ///      regardless of family (`DEP-051`), which is what makes a missed pattern a change this
    ///      gate still catches.
    function _checkProxyStatus(Header header) private {
        _selectFork(header);

        string[8] memory ids = _bindingIds();
        address[8] memory addresses = _bindingAddresses();
        for (uint256 i; i < ids.length; ++i) {
            (string memory family, address implementation, bytes32 codeHash, uint256 codeBytes) =
                _classifyProxy(addresses[i]);

            assertEq(
                keccak256(bytes(family)),
                keccak256(bytes(_observedString(_bindingPath(ids[i], "proxy_family")))),
                string.concat("binding ", ids[i], " changed its proxy family")
            );
            assertEq(
                implementation,
                _observedAddress(_bindingPath(ids[i], "implementation")),
                string.concat("binding ", ids[i], " changed its implementation address")
            );
            assertEq(
                codeHash,
                _observedBytes32(_bindingPath(ids[i], "implementation_code_hash")),
                string.concat("binding ", ids[i], " changed its implementation runtime code identity")
            );
            assertEq(
                codeBytes,
                _observedUint(_bindingPath(ids[i], "implementation_runtime_bytes")),
                string.concat("binding ", ids[i], " changed its implementation runtime length")
            );

            if (keccak256(bytes(family)) == keccak256(bytes(NO_SUPPORTED_PROXY_PATTERN))) {
                assertEq(
                    implementation,
                    address(0),
                    string.concat("binding ", ids[i], " matches no supported pattern yet exposes an implementation")
                );
                assertEq(
                    codeBytes,
                    0,
                    string.concat("binding ", ids[i], " matches no supported pattern yet has implementation code")
                );
            } else {
                assertGt(
                    codeBytes, 0, string.concat("binding ", ids[i], " delegates to an implementation with no code")
                );
                assertEq(
                    codeHash,
                    implementation.codehash,
                    string.concat("binding ", ids[i], " implementation identity is not the deployed one")
                );
            }

            // The Safe singleton detector applies to exactly one address, and only that address may
            // ever be classified as one. Its four agreeing measurements are re-asserted here in the
            // open rather than left inside the classifier.
            if (keccak256(bytes(family)) == keccak256("safe_singleton")) {
                assertEq(
                    addresses[i],
                    BaseBindings.GOVERNANCE_AND_REGENT_SAFE,
                    string.concat("binding ", ids[i], " was classified as a Safe singleton proxy")
                );
                assertEq(
                    _slotAsAddress(addresses[i], SAFE_SINGLETON_SLOT),
                    implementation,
                    "the Regent Safe's slot 0 is not the classified singleton"
                );
                assertEq(
                    _callAddress(addresses[i], abi.encodePacked(SAFE_MASTER_COPY_SELECTOR)),
                    implementation,
                    "the Regent Safe's masterCopy() disagrees with its slot 0"
                );
                assertLe(
                    addresses[i].code.length,
                    SAFE_PROXY_MAX_RUNTIME_BYTES,
                    "the Regent Safe's runtime is too large to be a delegating proxy stub"
                );
                assertLt(
                    addresses[i].code.length,
                    implementation.code.length,
                    "the Regent Safe's runtime is not smaller than the singleton it forwards to"
                );
            }
        }
        _emitVerdict("DEP-043", header, "all-binding-proxy-families-and-implementations-match");
    }

    // -------------------------------------------------------------------------
    // DEP-044 — REGENT and USDC semantics
    // -------------------------------------------------------------------------

    function test_DEP_044_ForkPinnedRegentAndUsdcGettersMatchAssumedSemantics() public {
        _checkTokenSemantics(Header.Pinned);
    }

    /// @dev The accounting paths assume exact-amount transfers with no fee taken in flight, exact
    ///      allowance consumption, and stable decimals and symbol. Each is proved on the deployed
    ///      token itself — `symbol()` is actually called and compared, not inferred from the
    ///      claim's wording — with balances staged by `deal` and the real production call shapes
    ///      used throughout.
    function _checkTokenSemantics(Header header) private {
        _selectFork(header);

        address[2] memory tokens = [BaseBindings.REGENT, BaseBindings.USDC];
        string[2] memory ids = ["regent", "usdc"];
        address holder = makeAddr("fork-token-holder");
        address recipient = makeAddr("fork-token-recipient");
        address spender = makeAddr("fork-token-spender");

        for (uint256 i; i < tokens.length; ++i) {
            assertEq(
                _callUint(tokens[i], abi.encodeWithSignature("decimals()")),
                _observedUint(_bindingPath(ids[i], "decimals")),
                string.concat(ids[i], " changed its decimals")
            );
            assertEq(
                _callString(tokens[i], abi.encodeWithSignature("symbol()")),
                _observedString(_bindingPath(ids[i], "symbol")),
                string.concat(ids[i], " changed its symbol")
            );

            uint256 amount = 1_000 * (10 ** _observedUint(_bindingPath(ids[i], "decimals")));
            deal(tokens[i], holder, amount);
            assertEq(_balanceOf(tokens[i], holder), amount, string.concat(ids[i], ": staged balance is not exact"));

            vm.prank(holder);
            _mustCall(tokens[i], abi.encodeWithSignature("transfer(address,uint256)", recipient, amount));
            assertEq(_balanceOf(tokens[i], holder), 0, string.concat(ids[i], ": transfer left a residue"));
            assertEq(
                _balanceOf(tokens[i], recipient),
                amount,
                string.concat(ids[i], ": transfer delivered an inexact amount")
            );

            vm.prank(recipient);
            _mustCall(tokens[i], abi.encodeWithSignature("approve(address,uint256)", spender, amount));
            assertEq(
                _callUint(tokens[i], abi.encodeWithSignature("allowance(address,address)", recipient, spender)),
                amount,
                string.concat(ids[i], ": approve did not record the exact allowance")
            );

            vm.prank(spender);
            _mustCall(
                tokens[i], abi.encodeWithSignature("transferFrom(address,address,uint256)", recipient, holder, amount)
            );
            assertEq(
                _callUint(tokens[i], abi.encodeWithSignature("allowance(address,address)", recipient, spender)),
                0,
                string.concat(ids[i], ": transferFrom did not consume the exact allowance")
            );
            assertEq(_balanceOf(tokens[i], holder), amount, string.concat(ids[i], ": transferFrom was inexact"));
        }
        _emitVerdict("DEP-044", header, "regent-and-usdc-exact-getters-transfer-and-allowance");
    }

    // -------------------------------------------------------------------------
    // DEP-047 — chain id
    // -------------------------------------------------------------------------

    function test_DEP_047_ForkPinnedChainIdIsBaseMainnet() public {
        _checkChainId(Header.Pinned);
    }

    function test_DEP_047_ForkLatestChainIdIsBaseMainnet() public {
        _checkChainId(Header.Later);
    }

    function _checkChainId(Header header) private {
        _selectFork(header);
        assertEq(block.chainid, 8453, "the fork is not Base mainnet");
        assertEq(block.chainid, BaseBindings.BASE_CHAIN_ID, "the compiled chain id is not the fork's");
        _emitVerdict("DEP-047", header, "chain-id=8453");
    }

    // -------------------------------------------------------------------------
    // DEP-051 — every binding's exact runtime code hash
    // -------------------------------------------------------------------------

    function test_DEP_051_ForkPinnedEveryBindingRuntimeCodeHashMatchesTheManifest() public {
        _checkRuntimeCodeHashes(Header.Pinned);
    }

    function test_DEP_051_ForkLatestEveryBindingRuntimeCodeHashMatchesTheManifest() public {
        _checkRuntimeCodeHashes(Header.Later);
    }

    function _checkRuntimeCodeHashes(Header header) private {
        _selectFork(header);

        string[8] memory ids = _bindingIds();
        address[8] memory addresses = _bindingAddresses();
        for (uint256 i; i < ids.length; ++i) {
            if (addresses[i] == BaseBindings.DEAD_ADDRESS) continue;
            assertEq(
                addresses[i].codehash,
                _observedBytes32(_bindingPath(ids[i], "runtime_code_hash")),
                string.concat("binding ", ids[i], " changed its deployed runtime code hash")
            );
        }
        assertEq(
            BaseBindings.CCA_FACTORY.codehash,
            BaseBindings.CCA_FACTORY_RUNTIME_CODE_HASH,
            "the recorded CCA hash disagrees with the frozen admission hash"
        );
        _emitVerdict("DEP-051", header, "all-binding-runtime-code-hashes-match");
    }
}
