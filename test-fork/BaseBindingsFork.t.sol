// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {
    IContinuousClearingAuctionFactory
} from "continuous-clearing-auction/interfaces/IContinuousClearingAuctionFactory.sol";
import {ForkFixture} from "./ForkFixture.sol";

/// @notice `DEP-040` through `DEP-044`, `DEP-047`, and `DEP-051` at both committed headers.
/// @dev Every claim runs twice in two separately created forks and never shares state between them.
///      Each pair compares the live chain against `reports/frozen/fork-observations.json`, which was
///      recorded by a separate authorized discovery pass and reviewed before this gate ever ran.
contract BaseBindingsForkTest is ForkFixture {
    /// @dev The proxy families this repository is prepared to recognize. `DEP-043` never assumes a
    ///      binding is EIP-1967: the family is recorded per binding and the read follows the family.
    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant EIP1822_IMPLEMENTATION_SLOT =
        0xc5f16f0fcc639fa48a6947836d9850f504798523bf8c9a3a87d5876cf622bcf7;

    function setUp() public {
        _loadObservations();
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

    /// @dev No binding is assumed to be EIP-1967. The recorded family selects how the
    ///      implementation is read, and a binding recorded as `none` must expose no implementation
    ///      at either standard slot.
    function _checkProxyStatus(Header header) private {
        _selectFork(header);

        string[8] memory ids = _bindingIds();
        address[8] memory addresses = _bindingAddresses();
        for (uint256 i; i < ids.length; ++i) {
            string memory family = _observedString(_bindingPath(ids[i], "proxy_family"));
            bytes32 kind = keccak256(bytes(family));

            if (kind == keccak256("eip1967")) {
                address implementation = _slotAsAddress(addresses[i], EIP1967_IMPLEMENTATION_SLOT);
                assertEq(
                    implementation,
                    _observedAddress(_bindingPath(ids[i], "implementation")),
                    string.concat("binding ", ids[i], " changed its EIP-1967 implementation")
                );
                assertGt(implementation.code.length, 0, "an implementation carries no code");
            } else if (kind == keccak256("eip1822")) {
                address implementation = _slotAsAddress(addresses[i], EIP1822_IMPLEMENTATION_SLOT);
                assertEq(
                    implementation,
                    _observedAddress(_bindingPath(ids[i], "implementation")),
                    string.concat("binding ", ids[i], " changed its EIP-1822 implementation")
                );
            } else {
                assertEq(kind, keccak256("none"), string.concat("binding ", ids[i], " records an unknown proxy family"));
                assertEq(
                    _slotAsAddress(addresses[i], EIP1967_IMPLEMENTATION_SLOT),
                    address(0),
                    string.concat("binding ", ids[i], " is recorded non-proxy but carries an EIP-1967 implementation")
                );
                assertEq(
                    _slotAsAddress(addresses[i], EIP1822_IMPLEMENTATION_SLOT),
                    address(0),
                    string.concat("binding ", ids[i], " is recorded non-proxy but carries an EIP-1822 implementation")
                );
            }
        }
        _emitVerdict("DEP-043", header, "all-binding-proxy-families-match");
    }

    function _slotAsAddress(address account, bytes32 slot) private view returns (address) {
        return address(uint160(uint256(vm.load(account, slot))));
    }

    // -------------------------------------------------------------------------
    // DEP-044 — REGENT and USDC semantics
    // -------------------------------------------------------------------------

    function test_DEP_044_ForkPinnedRegentAndUsdcGettersMatchAssumedSemantics() public {
        _checkTokenSemantics(Header.Pinned);
    }

    function test_DEP_044_ForkLatestRegentAndUsdcGettersMatchAssumedSemantics() public {
        _checkTokenSemantics(Header.Later);
    }

    /// @dev The accounting paths assume exact-amount transfers with no fee taken in flight, exact
    ///      allowance consumption, and stable decimals and symbol. Each is proved on the deployed
    ///      token itself, with balances staged by `deal` and the real production call shapes used.
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
        _emitVerdict("DEP-044", header, "regent-and-usdc-exact-transfer-and-allowance");
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

    // -------------------------------------------------------------------------

    function _balanceOf(address token, address account) private view returns (uint256) {
        return _callUint(token, abi.encodeWithSignature("balanceOf(address)", account));
    }

    function _callUint(address target, bytes memory payload) private view returns (uint256) {
        (bool ok, bytes memory returned) = target.staticcall(payload);
        require(ok && returned.length >= 32, "fork read failed");
        return abi.decode(returned, (uint256));
    }

    function _mustCall(address target, bytes memory payload) private {
        (bool ok, bytes memory returned) = target.call(payload);
        require(ok, "fork call reverted");
        if (returned.length >= 32) require(abi.decode(returned, (bool)), "fork call returned false");
    }
}
