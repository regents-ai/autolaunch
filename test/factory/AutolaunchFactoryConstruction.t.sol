// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../../src/escrow/ConditionalVestingEscrowV1.sol";
import {RegentsAutolaunchFactoryV1} from "../../src/factory/RegentsAutolaunchFactoryV1.sol";
import {RegentFeeHook} from "../../src/hook/RegentFeeHook.sol";
import {PaymentReceiverV1} from "../../src/revenue/PaymentReceiverV1.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {UERC20Factory} from "uerc20-factory/factories/UERC20Factory.sol";
import {AutolaunchFixture} from "../integration/AutolaunchFixture.sol";

/// @notice `C4-I1`: the only moment an identity is admitted is construction. The four external code
///         identities must be exact, the strategy and the hook are deployed here rather than
///         accepted, and every binding between factory, strategy and hook is reciprocal and
///         permanent.
contract AutolaunchFactoryConstructionTest is AutolaunchFixture {
    /// @dev The Solady `LibClone.clone` runtime, byte for byte: 44 bytes wrapping the implementation.
    bytes internal constant CLONE_PREFIX = hex"3d3d3d3d363d3d37363d73";
    bytes internal constant CLONE_SUFFIX = hex"5af43d3d93803e602a57fd5bf3";

    function setUp() public {
        _deployAutolaunch();
    }

    /// @notice `DEP-060`: the four admitted runtime code hashes are the compiled frozen artifacts'
    ///         own hashes, and every clone this graph creates presents the exact Solady 44-byte
    ///         clone runtime derived from its implementation.
    /// @dev The compiled artifacts are the authority here, not a hand-written manifest row: each
    ///      literal in the production constructor is compared against `type(X).runtimeCode` of the
    ///      same frozen build, and against the code actually running at the deployed address. C5
    ///      owns manifest reconciliation and deployment-specific addresses.
    function test_DEP_060_CloneImplementationAndCloneRuntimeHashesMatchTheFrozenArtifacts() public {
        assertEq(
            factory.ESCROW_IMPLEMENTATION_RUNTIME_CODE_HASH(),
            keccak256(type(ConditionalVestingEscrowV1).runtimeCode),
            "escrow implementation hash is not the frozen artifact's"
        );
        assertEq(
            factory.SPLITTER_IMPLEMENTATION_RUNTIME_CODE_HASH(),
            keccak256(type(SubjectSplitterV1).runtimeCode),
            "splitter implementation hash is not the frozen artifact's"
        );
        assertEq(
            factory.RECEIVER_IMPLEMENTATION_RUNTIME_CODE_HASH(),
            keccak256(type(PaymentReceiverV1).runtimeCode),
            "receiver implementation hash is not the frozen artifact's"
        );

        assertEq(
            address(escrowImplementation).codehash,
            factory.ESCROW_IMPLEMENTATION_RUNTIME_CODE_HASH(),
            "the deployed escrow implementation is not the admitted code"
        );
        assertEq(
            address(splitterImplementation).codehash,
            factory.SPLITTER_IMPLEMENTATION_RUNTIME_CODE_HASH(),
            "the deployed splitter implementation is not the admitted code"
        );
        assertEq(
            address(receiverImplementation).codehash,
            factory.RECEIVER_IMPLEMENTATION_RUNTIME_CODE_HASH(),
            "the deployed receiver implementation is not the admitted code"
        );

        // The strategy carries the same escrow clone fingerprint, derived independently at its own
        // construction, and it is the fingerprint an authentic launch escrow must present.
        Launched memory launched = _defaultLaunch();
        _assertIsCloneOf(address(launched.escrow), address(escrowImplementation), "escrow");
        assertEq(
            strategy.escrowCloneCodehash(),
            address(launched.escrow).codehash,
            "the strategy's admitted escrow clone fingerprint is not this clone's"
        );

        _bidToGraduation(launched, 2_000e18);
        strategy.migrate(address(launched.auction));
        RegentLBPStrategy.Distribution memory d = _distribution(launched);
        _assertIsCloneOf(d.splitter, address(splitterImplementation), "splitter");
        _assertIsCloneOf(d.receiver, address(receiverImplementation), "canonical receiver");

        address custom = factory.createPaymentReceiver(launched.launchId, outsider, 100);
        _assertIsCloneOf(custom, address(receiverImplementation), "custom receiver");
    }

    /// @notice `DEP-060`: the pinned UERC20 factory is admitted by runtime identity alone, so any
    ///         other code at that address is refused before a single launch can exist.
    function test_DEP_060_Uerc20FactoryRuntimeIdentityIsTheAdmittedOne() public view {
        assertEq(
            factory.UERC20_FACTORY_RUNTIME_CODE_HASH(),
            keccak256(type(UERC20Factory).runtimeCode),
            "the admitted UERC20 factory hash is not the frozen artifact's"
        );
        assertEq(
            address(uerc20Factory).codehash,
            factory.UERC20_FACTORY_RUNTIME_CODE_HASH(),
            "the deployed UERC20 factory is not the admitted code"
        );
        assertEq(factory.uerc20Factory(), address(uerc20Factory), "the factory bound a different token factory");
    }

    /// @notice `DEP-060`: construction refuses every substituted or codeless external identity, one
    ///         at a time, and deploys nothing when it does.
    function test_DEP_060_ConstructorRejectsAnyUnexpectedRuntimeCodeHash() public {
        address good0 = address(uerc20Factory);
        address good1 = address(escrowImplementation);
        address good2 = address(splitterImplementation);
        address good3 = address(receiverImplementation);

        // A codeless address for each slot.
        _expectRejected(outsider, good1, good2, good3, factory.UERC20_FACTORY_RUNTIME_CODE_HASH());
        _expectRejected(good0, outsider, good2, good3, factory.ESCROW_IMPLEMENTATION_RUNTIME_CODE_HASH());
        _expectRejected(good0, good1, outsider, good3, factory.SPLITTER_IMPLEMENTATION_RUNTIME_CODE_HASH());
        _expectRejected(good0, good1, good2, outsider, factory.RECEIVER_IMPLEMENTATION_RUNTIME_CODE_HASH());

        // A real, deployed, but wrong C1 implementation for each slot: the substitution a deployer
        // could most plausibly make by accident.
        _expectRejected(good1, good1, good2, good3, factory.UERC20_FACTORY_RUNTIME_CODE_HASH());
        _expectRejected(good0, good2, good2, good3, factory.ESCROW_IMPLEMENTATION_RUNTIME_CODE_HASH());
        _expectRejected(good0, good1, good3, good3, factory.SPLITTER_IMPLEMENTATION_RUNTIME_CODE_HASH());
        _expectRejected(good0, good1, good2, good2, factory.RECEIVER_IMPLEMENTATION_RUNTIME_CODE_HASH());
    }

    /// @notice `HOK-004`: the hook the factory mined and deployed carries in its address exactly the
    ///         permission bits it declares — no more, and none missing.
    /// @dev Uniswap v4 encodes callback permissions in the low bits of a hook address, so this is a
    ///      deployment fact and not a code fact. It is proved here against the address the
    ///      production constructor actually produced from the pre-mined salt.
    function test_HOK_004_MinedHookAddressCarriesExactlyTheDeclaredPermissionBits() public view {
        uint160 bits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(bits, HOOK_FLAGS, "the mined hook address does not carry exactly the declared bits");

        Hooks.Permissions memory declared = hook.getHookPermissions();
        assertEq(_bitSet(Hooks.BEFORE_INITIALIZE_FLAG), declared.beforeInitialize, "beforeInitialize bit");
        assertEq(_bitSet(Hooks.AFTER_INITIALIZE_FLAG), declared.afterInitialize, "afterInitialize bit");
        assertEq(_bitSet(Hooks.BEFORE_ADD_LIQUIDITY_FLAG), declared.beforeAddLiquidity, "beforeAddLiquidity bit");
        assertEq(_bitSet(Hooks.AFTER_ADD_LIQUIDITY_FLAG), declared.afterAddLiquidity, "afterAddLiquidity bit");
        assertEq(
            _bitSet(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG), declared.beforeRemoveLiquidity, "beforeRemoveLiquidity bit"
        );
        assertEq(_bitSet(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG), declared.afterRemoveLiquidity, "afterRemoveLiquidity bit");
        assertEq(_bitSet(Hooks.BEFORE_SWAP_FLAG), declared.beforeSwap, "beforeSwap bit");
        assertEq(_bitSet(Hooks.AFTER_SWAP_FLAG), declared.afterSwap, "afterSwap bit");
        assertEq(_bitSet(Hooks.BEFORE_DONATE_FLAG), declared.beforeDonate, "beforeDonate bit");
        assertEq(_bitSet(Hooks.AFTER_DONATE_FLAG), declared.afterDonate, "afterDonate bit");
        assertEq(_bitSet(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG), declared.beforeSwapReturnDelta, "beforeSwapDelta bit");
        assertEq(_bitSet(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG), declared.afterSwapReturnDelta, "afterSwapDelta bit");
        assertEq(
            _bitSet(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG),
            declared.afterAddLiquidityReturnDelta,
            "afterAddLiquidityDelta bit"
        );
        assertEq(
            _bitSet(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG),
            declared.afterRemoveLiquidityReturnDelta,
            "afterRemoveLiquidityDelta bit"
        );
    }

    /// @notice `HOK-001`: the hook the production constructor deployed points back at that
    ///         constructor's own strategy and at the frozen PoolManager, permanently.
    function test_HOK_001_FactoryConstructionBindsHookToStrategyAndPoolManager() public {
        assertEq(hook.strategy(), address(strategy), "the hook is not bound to this factory's strategy");
        assertEq(address(hook.poolManager()), BaseBindings.POOL_MANAGER, "the hook is not bound to the PoolManager");

        // A second factory produces its own hook at its own mined address, bound to its own
        // strategy. Nothing about the first graph is reachable from the second.
        RegentsAutolaunchFactoryV1 second = _deployUntouchedFactory();
        assertTrue(address(second.hook()) != address(hook), "the second factory reused the first hook");
        assertEq(second.hook().strategy(), address(second.strategy()), "the second hook is misbound");
        assertEq(
            address(second.hook().poolManager()), BaseBindings.POOL_MANAGER, "the second hook is not PoolManager-bound"
        );
        assertEq(hook.strategy(), address(strategy), "the first hook's binding is not immutable");
    }

    /// @notice `STR-001`: the strategy is permanently bound to the factory that deployed it and to
    ///         the one hook that factory mined, and nothing can rebind either.
    function test_STR_001_FactoryConstructionBindsStrategyToFactoryAndHook() public {
        assertEq(strategy.factory(), address(factory), "the strategy is not bound to its factory");
        assertEq(strategy.hook(), address(hook), "the strategy is not bound to the mined hook");
        assertEq(strategy.escrowImplementation(), address(escrowImplementation), "escrow implementation drifted");
        assertEq(strategy.splitterImplementation(), address(splitterImplementation), "splitter implementation drifted");
        assertEq(strategy.receiverImplementation(), address(receiverImplementation), "receiver implementation drifted");

        // The binding is one-shot and factory-only: neither the factory nor anyone else can rebind.
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.HookAlreadyBound.selector, address(hook)));
        vm.prank(address(factory));
        strategy.bindHook(address(hook));

        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.NotFactory.selector, outsider));
        vm.prank(outsider);
        strategy.bindHook(outsider);

        // Only the factory initializes a distribution, so no other caller can enter the strategy.
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.NotFactory.selector, outsider));
        vm.prank(outsider);
        strategy.initializeDistribution(
            RegentLBPStrategy.DistributionParams({
                launchId: 1, escrow: address(escrowImplementation), requiredRegentRaised: 1_000e18
            })
        );

        // The factory keeps no mutable authority of its own over any of it.
        bytes memory runtime = address(factory).code;
        string[8] memory forbidden = [
            "setStrategy(address)",
            "setHook(address)",
            "setUerc20Factory(address)",
            "setEscrowImplementation(address)",
            "setReceiverImplementation(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "execute(address,bytes)"
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            assertFalse(
                _carriesSelector(runtime, bytes4(keccak256(bytes(forbidden[i])))),
                string.concat("the factory exposes a forbidden authority surface: ", forbidden[i])
            );
        }
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _bitSet(uint160 flag) private view returns (bool) {
        return uint160(address(hook)) & flag != 0;
    }

    function _assertIsCloneOf(address instance, address implementation, string memory label) private view {
        bytes memory expected = abi.encodePacked(CLONE_PREFIX, implementation, CLONE_SUFFIX);
        assertEq(expected.length, 44, "the Solady clone runtime is not 44 bytes");
        assertEq(instance.code, expected, string.concat(label, ": not the exact Solady clone runtime"));
        assertEq(instance.codehash, keccak256(expected), string.concat(label, ": clone codehash mismatch"));
    }

    function _expectRejected(address tokenFactory, address escrow, address splitter, address receiver, bytes32 expected)
        private
    {
        address offender = tokenFactory;
        if (expected == factory.ESCROW_IMPLEMENTATION_RUNTIME_CODE_HASH()) offender = escrow;
        if (expected == factory.SPLITTER_IMPLEMENTATION_RUNTIME_CODE_HASH()) offender = splitter;
        if (expected == factory.RECEIVER_IMPLEMENTATION_RUNTIME_CODE_HASH()) offender = receiver;

        vm.expectRevert(
            abi.encodeWithSelector(
                RegentsAutolaunchFactoryV1.UnexpectedRuntimeCodeHash.selector, offender, expected, offender.codehash
            )
        );
        new RegentsAutolaunchFactoryV1(tokenFactory, escrow, splitter, receiver, bytes32(0));
    }
}
