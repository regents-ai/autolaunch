// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {DeployAutolaunchV1} from "../script/DeployAutolaunchV1.s.sol";
import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../src/escrow/ConditionalVestingEscrowV1.sol";
import {RegentsAutolaunchFactoryV1} from "../src/factory/RegentsAutolaunchFactoryV1.sol";
import {RegentFeeHook} from "../src/hook/RegentFeeHook.sol";
import {PaymentReceiverV1} from "../src/revenue/PaymentReceiverV1.sol";
import {SubjectSplitterV1} from "../src/revenue/SubjectSplitterV1.sol";
import {RegentLBPStrategy} from "../src/strategy/RegentLBPStrategy.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {UERC20Factory} from "uerc20-factory/factories/UERC20Factory.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The deployment-ceremony gate's own evidence: `DEP-070` through `DEP-075`.
/// @dev Every claim here runs the real `script/DeployAutolaunchV1.s.sol` against a disposable
///      deployer whose starting nonce is set explicitly, which is exactly the shape the Base
///      ceremony has. Nothing about the ceremony needs a provider: the five creations reach no
///      external contract at all, and the one frozen address the graph binds — the Base PoolManager
///      — is compared rather than called. The chief's separately authorized rehearsal runs this
///      same suite against a read-only Base fork, plus the preflight that reads external state.
///
///      Preparation, and only preparation, mines the hook salt. It happens once here, against the
///      predicted factory and the predicted strategy, with the pinned Uniswap `HookMiner` the
///      periphery remapping resolves to `lib/liquidity-launcher/lib/v4-periphery/src/utils/`. The
///      script imports no miner, so a broadcast can only consume the salt a packet pinned.
///
///      Nothing in this file signs, broadcasts, funds, or moves value. `vm.startBroadcast` inside
///      the script attributes each `CREATE` to the deployer's own nonce sequence, which is what
///      makes the predicted addresses the real ones; under `forge test` it sends nothing.
contract DeploymentCeremonyTest is Test {
    /// @notice Exactly the five permission bits `RegentFeeHook` declares, stated independently of
    ///         the script so a wrong flag set in either place fails rather than agrees with itself.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /// @notice EIP-170's deployed-runtime ceiling and EIP-3860's initcode ceiling.
    uint256 internal constant EIP170_RUNTIME_LIMIT = 24_576;
    uint256 internal constant EIP3860_INITCODE_LIMIT = 49_152;

    /// @notice A guardrail on in-EVM creation gas, and not a transaction-gas result.
    /// @dev What is measured below is the in-EVM cost of each creation — the `CREATE` execution and
    ///      the code deposit — which is a *floor* on what a real creation transaction costs. It
    ///      excludes the intrinsic cost, the initcode calldata cost, and EIP-3860's per-word
    ///      initcode charge, all of which are priced by the Base transaction gas schedule that
    ///      lives in the fork gate's reviewed observation record and that this profile deliberately
    ///      has no filesystem permission to read. So `DEP-074` proves the EIP-170 and EIP-3860 size
    ///      margins, and holds the floor under the same 14,000,000 the fork gate holds a launch and
    ///      a migration to purely as a sanity bound. No complete deployment-transaction gas figure
    ///      is claimed anywhere: the full per-transaction estimates stay pending the exact selected
    ///      deployer and salt and an authorized rehearsal, and a founder funds the ceremony from a
    ///      live estimate against that deployer rather than from anything measured here.
    uint256 internal constant CREATION_GAS_FLOOR_GUARDRAIL = 14_000_000;

    /// @notice The disposable deployer this suite stands in for a founder-selected one.
    /// @dev A deployment ceremony has exactly two free parameters — an account and the nonce it is
    ///      at — and nothing about either is special. Fixing both here is what makes the whole
    ///      address graph, and therefore this suite, deterministic; `test_DEP_070_*` additionally
    ///      fuzzes the derivation across arbitrary deployers and nonces so the proof is about the
    ///      rule rather than about this one account.
    uint64 internal constant STARTING_NONCE = 3;

    DeployAutolaunchV1 internal deployment;
    address internal deployer;

    function setUp() public {
        deployment = new DeployAutolaunchV1();
        deployer = makeAddr("regent-839.7-ceremony-deployer");
    }

    // -------------------------------------------------------------------------
    // DEP-070 — the five direct, zero-value creations
    // -------------------------------------------------------------------------

    /// @notice `DEP-070`: the five top-level creations land on the deployer's own nonce sequence.
    function test_DEP_070_FiveTopLevelCreationsLandOnThePinnedNonceSequence() public {
        (DeployAutolaunchV1.Ceremony memory ceremony, DeployAutolaunchV1.Graph memory predicted) = _prepare();

        uint256 balanceBefore = deployer.balance;
        DeployAutolaunchV1.Graph memory graph = deployment.execute(ceremony);

        assertEq(graph.uerc20Factory, vm.computeCreateAddress(deployer, STARTING_NONCE), "creation 1 moved");
        assertEq(graph.escrowImplementation, vm.computeCreateAddress(deployer, STARTING_NONCE + 1), "creation 2 moved");
        assertEq(
            graph.splitterImplementation, vm.computeCreateAddress(deployer, STARTING_NONCE + 2), "creation 3 moved"
        );
        assertEq(
            graph.receiverImplementation, vm.computeCreateAddress(deployer, STARTING_NONCE + 3), "creation 4 moved"
        );
        assertEq(graph.factory, vm.computeCreateAddress(deployer, STARTING_NONCE + 4), "creation 5 moved");
        assertEq(abi.encode(graph), abi.encode(predicted), "the executed graph is not the predicted graph");

        // Exactly five creations, in exactly this order, and nothing else from this account.
        assertEq(vm.getNonce(deployer), STARTING_NONCE + 5, "the deployer sent something other than five creations");

        // Zero value. Nothing was funded, nothing was forwarded, and no created contract holds ETH.
        assertEq(deployer.balance, balanceBefore, "the ceremony moved value out of the deployer");
        address[7] memory created = _addresses(graph);
        for (uint256 i; i < created.length; ++i) {
            assertEq(created[i].balance, 0, "a created contract holds ETH");
            assertGt(created[i].code.length, 0, "a predicted address carries no code");
        }

        _emitCreationOrder(graph);
    }

    /// @notice `DEP-070`: the top-level derivation is the deployer's `CREATE` sequence, for any
    ///         deployer and any starting nonce, and never a fixed or substituted address.
    function testFuzz_DEP_070_TopLevelDerivationIsTheDeployerCreateSequence(address account, uint32 nonce) public view {
        vm.assume(account != address(0));

        address[5] memory top = deployment.topLevelAddresses(
            DeployAutolaunchV1.Ceremony({deployer: account, startingNonce: nonce, hookSalt: bytes32(0)})
        );

        for (uint256 i; i < top.length; ++i) {
            assertEq(top[i], vm.computeCreateAddress(account, uint256(nonce) + i), "a top-level offset moved");
        }
    }

    // -------------------------------------------------------------------------
    // DEP-071 — the two internal creations the factory alone makes
    // -------------------------------------------------------------------------

    /// @notice `DEP-071`: the factory constructor alone creates the strategy at its first internal
    ///         `CREATE` and the hook by `CREATE2` over the pre-mined salt, and the hook address
    ///         carries exactly the five declared permission bits.
    function test_DEP_071_FactoryAloneCreatesTheStrategyAndTheMinedHook() public {
        (DeployAutolaunchV1.Ceremony memory ceremony,) = _prepare();
        DeployAutolaunchV1.Graph memory graph = deployment.execute(ceremony);

        RegentsAutolaunchFactoryV1 factory = RegentsAutolaunchFactoryV1(graph.factory);
        assertEq(address(factory.strategy()), graph.strategy, "the strategy is not the factory's first CREATE");
        assertEq(address(factory.hook()), graph.hook, "the hook is not the factory's predicted CREATE2");

        assertEq(graph.strategy, vm.computeCreateAddress(graph.factory, 1), "the strategy is not at factory nonce 1");
        assertEq(
            graph.hook,
            vm.computeCreate2Address(
                ceremony.hookSalt, keccak256(deployment.hookInitcode(graph.strategy)), graph.factory
            ),
            "the hook is not the factory's CREATE2 over the pinned salt"
        );

        uint160 bits = uint160(graph.hook) & Hooks.ALL_HOOK_MASK;
        assertEq(uint256(bits), uint256(HOOK_FLAGS), "the hook address does not carry exactly the five bits");

        // The factory made both, and only those two. A contract's nonce starts at one under
        // EIP-161, the strategy's `CREATE` consumes nonce 1, and the hook's `CREATE2` consumes one
        // more, so a factory that made any third internal creation would be past three.
        assertEq(vm.getNonce(graph.factory), 3, "the factory made an internal creation the ceremony does not admit");

        // The permission-bit word is a packet fact: it is a property of the hook's own declaration
        // and is the same whoever deploys it. This run's salt and strategy are not — they belong to
        // this run's stand-in deployer — so they are reported and never rendered.
        emit log_named_uint("packet hook_flags", uint256(HOOK_FLAGS));
        emit log_named_bytes32("ceremony hook_salt", ceremony.hookSalt);
        emit log_named_bytes32("ceremony hook_initcode_keccak256", keccak256(deployment.hookInitcode(graph.strategy)));
    }

    // -------------------------------------------------------------------------
    // DEP-072 — exact constructor bindings and runtime readbacks
    // -------------------------------------------------------------------------

    /// @notice `DEP-072`: every constructor binding and every runtime readback across the seven
    ///         deployed contracts is exactly what the ceremony intended, with no post-deployment
    ///         binding call anywhere.
    function test_DEP_072_EveryConstructorBindingAndReadbackIsExact() public {
        (DeployAutolaunchV1.Ceremony memory ceremony,) = _prepare();
        DeployAutolaunchV1.Graph memory graph = deployment.execute(ceremony);

        RegentsAutolaunchFactoryV1 factory = RegentsAutolaunchFactoryV1(graph.factory);
        RegentLBPStrategy strategy = RegentLBPStrategy(graph.strategy);
        RegentFeeHook hook = RegentFeeHook(graph.hook);

        assertEq(factory.uerc20Factory(), graph.uerc20Factory, "the factory bound another token factory");
        assertEq(address(factory.strategy()), graph.strategy, "the factory bound another strategy");
        assertEq(address(factory.hook()), graph.hook, "the factory bound another hook");
        assertEq(factory.launchFee(), factory.INITIAL_LAUNCH_FEE(), "the factory was not born at its initial fee");
        assertEq(factory.nextLaunchId(), 1, "the factory was not born at launch id one");
        assertFalse(factory.launchesPaused(), "the factory was born paused");

        assertEq(strategy.factory(), graph.factory, "the strategy bound another factory");
        assertEq(strategy.escrowImplementation(), graph.escrowImplementation, "the strategy bound another escrow");
        assertEq(strategy.splitterImplementation(), graph.splitterImplementation, "the strategy bound another splitter");
        assertEq(strategy.receiverImplementation(), graph.receiverImplementation, "the strategy bound another receiver");
        assertEq(strategy.hook(), graph.hook, "the strategy did not bind the hook the factory created");

        assertEq(address(hook.poolManager()), BaseBindings.POOL_MANAGER, "the hook bound another PoolManager");
        assertEq(hook.strategy(), graph.strategy, "the hook bound another strategy");

        // The four admitted runtime code hashes are the constructor's own admission rule, and the
        // deployed accounts are what it admitted. A codeless or substituted implementation would
        // have failed construction several steps before this readback.
        assertEq(
            graph.uerc20Factory.codehash,
            factory.UERC20_FACTORY_RUNTIME_CODE_HASH(),
            "the admitted UERC20 factory is not the deployed one"
        );
        assertEq(
            graph.escrowImplementation.codehash,
            factory.ESCROW_IMPLEMENTATION_RUNTIME_CODE_HASH(),
            "the admitted escrow implementation is not the deployed one"
        );
        assertEq(
            graph.splitterImplementation.codehash,
            factory.SPLITTER_IMPLEMENTATION_RUNTIME_CODE_HASH(),
            "the admitted splitter implementation is not the deployed one"
        );
        assertEq(
            graph.receiverImplementation.codehash,
            factory.RECEIVER_IMPLEMENTATION_RUNTIME_CODE_HASH(),
            "the admitted receiver implementation is not the deployed one"
        );
    }

    // -------------------------------------------------------------------------
    // DEP-073 — the deployer keeps nothing
    // -------------------------------------------------------------------------

    /// @notice `DEP-073`: the disposable deployer retains no protocol authority anywhere in the
    ///         graph, and the frozen Governance/Regent Safe is the sole mutable authority.
    function test_DEP_073_TheDeployerRetainsNoProtocolAuthority() public {
        (DeployAutolaunchV1.Ceremony memory ceremony,) = _prepare();
        DeployAutolaunchV1.Graph memory graph = deployment.execute(ceremony);

        RegentsAutolaunchFactoryV1 factory = RegentsAutolaunchFactoryV1(graph.factory);
        RegentLBPStrategy strategy = RegentLBPStrategy(graph.strategy);

        // The factory's whole mutable surface is governance-only, and the deployer is not it.
        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSelector(RegentsAutolaunchFactoryV1.NotGovernance.selector, deployer));
        factory.setLaunchFee(0);
        vm.expectRevert(abi.encodeWithSelector(RegentsAutolaunchFactoryV1.NotGovernance.selector, deployer));
        factory.pauseLaunches();
        vm.expectRevert(abi.encodeWithSelector(RegentsAutolaunchFactoryV1.NotGovernance.selector, deployer));
        factory.unpauseLaunches();

        // The strategy answers only to the factory, and the hook binding is already spent.
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategy.NotFactory.selector, deployer));
        strategy.bindHook(deployer);
        vm.stopPrank();

        // The Safe is the authority, and it is the one compiled into the frozen bindings.
        vm.prank(BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        factory.setLaunchFee(7);
        assertEq(factory.launchFee(), 7, "the frozen Safe is not the launch-fee authority");

        // Nothing about the deployer survives in the graph: no balance, no code, no allowance from
        // any created contract, and no residual role. Its remaining ETH is ordinary wallet property.
        assertEq(deployer.code.length, 0, "the disposable deployer is not an ordinary account");
        address[7] memory created = _addresses(graph);
        for (uint256 i; i < created.length; ++i) {
            assertEq(created[i].balance, 0, "a created contract holds ETH the deployer could reach");
        }
    }

    // -------------------------------------------------------------------------
    // DEP-074 — deployability margins for every contract the ceremony creates
    // -------------------------------------------------------------------------

    /// @notice `DEP-074`: every contract the ceremony creates fits EIP-170 and EIP-3860 with the
    ///         margins this run measures, and each creation's in-EVM gas floor stays under the
    ///         guardrail. No complete deployment-transaction gas figure is measured or claimed.
    function test_DEP_074_EveryCreationFitsTheDeployabilityLimits() public {
        (DeployAutolaunchV1.Ceremony memory ceremony,) = _prepare();

        uint256[5] memory gasUsed = _measureTopLevelCreations(ceremony);
        DeployAutolaunchV1.Graph memory graph = deployment.predict(ceremony);

        string[5] memory names = [
            "UERC20Factory",
            "ConditionalVestingEscrowV1",
            "SubjectSplitterV1",
            "PaymentReceiverV1",
            "RegentsAutolaunchFactoryV1"
        ];
        bytes[5] memory creationCode = [
            type(UERC20Factory).creationCode,
            type(ConditionalVestingEscrowV1).creationCode,
            type(SubjectSplitterV1).creationCode,
            type(PaymentReceiverV1).creationCode,
            type(RegentsAutolaunchFactoryV1).creationCode
        ];
        bytes[5] memory constructorArgs = [
            bytes(""),
            bytes(""),
            bytes(""),
            bytes(""),
            abi.encode(
                graph.uerc20Factory,
                graph.escrowImplementation,
                graph.splitterImplementation,
                graph.receiverImplementation,
                ceremony.hookSalt
            )
        ];
        address[5] memory addresses = [
            graph.uerc20Factory,
            graph.escrowImplementation,
            graph.splitterImplementation,
            graph.receiverImplementation,
            graph.factory
        ];

        for (uint256 i; i < names.length; ++i) {
            _reportDeployability(names[i], creationCode[i], constructorArgs[i], addresses[i].code.length, gasUsed[i]);
        }

        // The two the factory creates from inside its own constructor are subject to the same two
        // limits, measured against the exact arguments the constructor itself supplies.
        _reportDeployability(
            "RegentLBPStrategy",
            type(RegentLBPStrategy).creationCode,
            abi.encode(
                graph.factory, graph.escrowImplementation, graph.splitterImplementation, graph.receiverImplementation
            ),
            graph.strategy.code.length,
            0
        );
        _reportDeployability(
            "RegentFeeHook",
            type(RegentFeeHook).creationCode,
            abi.encode(BaseBindings.POOL_MANAGER, graph.strategy),
            graph.hook.code.length,
            0
        );

        // The hook's two halves must be exactly the initcode the factory's CREATE2 consumes, or the
        // margin above would be measured against something the ceremony never sends.
        assertEq(
            keccak256(
                abi.encodePacked(
                    type(RegentFeeHook).creationCode, abi.encode(BaseBindings.POOL_MANAGER, graph.strategy)
                )
            ),
            keccak256(deployment.hookInitcode(graph.strategy)),
            "the measured hook initcode is not the one the ceremony derives the address from"
        );
    }

    // -------------------------------------------------------------------------
    // DEP-075 — the ceremony aborts in simulation, before anything is created
    // -------------------------------------------------------------------------

    /// @notice `DEP-075`: a wrong starting nonce, a salt that does not carry the permission bits, an
    ///         unselected deployer, and a wrong chain each abort the ceremony before it creates
    ///         anything, so no transaction sequence is ever assembled for a broadcast to send.
    function test_DEP_075_AnyPinnedValueMismatchAbortsBeforeTheFirstCreation() public {
        (DeployAutolaunchV1.Ceremony memory ceremony,) = _prepare();

        // An unselected deployer is refused by derivation, before any nonce is even read.
        vm.expectRevert(DeployAutolaunchV1.UnselectedDeployer.selector);
        deployment.predict(
            DeployAutolaunchV1.Ceremony({deployer: address(0), startingNonce: 0, hookSalt: ceremony.hookSalt})
        );

        // A salt that is not the mined one derives a hook address without the five permission bits.
        // It is refused during derivation, before the script creates anything, so a broadcast of
        // this sequence is never assembled at all. The factory constructor's own
        // `Hooks.validateHookAddress` would catch it too, but only in the fifth creation — after
        // four transactions that, on a real ceremony, would already be irreversible.
        DeployAutolaunchV1.Ceremony memory wrongSalt = DeployAutolaunchV1.Ceremony({
            deployer: ceremony.deployer,
            startingNonce: ceremony.startingNonce,
            hookSalt: bytes32(uint256(ceremony.hookSalt) ^ 1)
        });
        address strayHook = vm.computeCreate2Address(
            wrongSalt.hookSalt,
            keccak256(deployment.hookInitcode(vm.computeCreateAddress(_predictedFactory(), 1))),
            _predictedFactory()
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAutolaunchV1.HookSaltDoesNotCarryThePermissionBits.selector,
                strayHook,
                uint160(strayHook) & Hooks.ALL_HOOK_MASK,
                HOOK_FLAGS
            )
        );
        deployment.execute(wrongSalt);

        // The broadcast entrypoint refuses any chain that is not Base mainnet, whatever the
        // environment says the ceremony is.
        vm.setEnv("REGENT_DEPLOYMENT_DEPLOYER", vm.toString(deployer));
        vm.setEnv("REGENT_DEPLOYMENT_STARTING_NONCE", vm.toString(uint256(STARTING_NONCE)));
        vm.setEnv("REGENT_DEPLOYMENT_HOOK_SALT", vm.toString(ceremony.hookSalt));
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployAutolaunchV1.WrongChain.selector, 8453, 1));
        deployment.run();

        // Nothing was created by any of the three refusals.
        DeployAutolaunchV1.Graph memory graph = deployment.predict(ceremony);
        address[7] memory created = _addresses(graph);
        for (uint256 i; i < created.length; ++i) {
            assertEq(created[i].code.length, 0, "an aborted ceremony created something");
        }

        // On Base, that same environment is the ceremony the packet pinned, consumed exactly.
        vm.chainId(BaseBindings.BASE_CHAIN_ID);
        DeployAutolaunchV1.Graph memory fromEnvironment = deployment.run();
        assertEq(abi.encode(fromEnvironment), abi.encode(graph), "the broadcast entrypoint deployed another graph");

        // And a partial or repeated ceremony is terminal rather than resumable: the deployer has
        // moved past the nonce the packet pinned, so the same packet is refused before it can
        // create anything a second time.
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAutolaunchV1.DeployerNonceMismatch.selector, STARTING_NONCE, STARTING_NONCE + 5
            )
        );
        deployment.execute(ceremony);
    }

    // -------------------------------------------------------------------------
    // preparation
    // -------------------------------------------------------------------------

    /// @dev The one admitted preparation: put the deployer at its pinned starting nonce, then mine
    ///      the hook salt once against the predicted factory and the predicted strategy.
    function _prepare()
        private
        returns (DeployAutolaunchV1.Ceremony memory ceremony, DeployAutolaunchV1.Graph memory predicted)
    {
        vm.setNonce(deployer, STARTING_NONCE);

        address predictedFactory = _predictedFactory();
        (, bytes32 hookSalt) = HookMiner.find(
            predictedFactory,
            HOOK_FLAGS,
            type(RegentFeeHook).creationCode,
            abi.encode(BaseBindings.POOL_MANAGER, vm.computeCreateAddress(predictedFactory, 1))
        );

        ceremony = DeployAutolaunchV1.Ceremony({deployer: deployer, startingNonce: STARTING_NONCE, hookSalt: hookSalt});
        predicted = deployment.predict(ceremony);
    }

    function _predictedFactory() private view returns (address) {
        return vm.computeCreateAddress(deployer, uint256(STARTING_NONCE) + 4);
    }

    /// @dev Each creation measured on its own, in the ceremony's order, from the deployer's account.
    function _measureTopLevelCreations(DeployAutolaunchV1.Ceremony memory ceremony)
        private
        returns (uint256[5] memory gasUsed)
    {
        DeployAutolaunchV1.Graph memory graph = deployment.predict(ceremony);
        uint256 before;

        vm.startBroadcast(deployer);
        before = gasleft();
        new UERC20Factory();
        gasUsed[0] = before - gasleft();

        before = gasleft();
        new ConditionalVestingEscrowV1();
        gasUsed[1] = before - gasleft();

        before = gasleft();
        new SubjectSplitterV1();
        gasUsed[2] = before - gasleft();

        before = gasleft();
        new PaymentReceiverV1();
        gasUsed[3] = before - gasleft();

        before = gasleft();
        new RegentsAutolaunchFactoryV1(
            graph.uerc20Factory,
            graph.escrowImplementation,
            graph.splitterImplementation,
            graph.receiverImplementation,
            ceremony.hookSalt
        );
        gasUsed[4] = before - gasleft();
        vm.stopBroadcast();
    }

    /// @dev One contract's two deployability margins, asserted and then emitted for the packet. The
    ///      creation code and its ABI-encoded arguments are reported apart because only the first
    ///      half is deployer-independent: a ceremony's real initcode carries addresses this run
    ///      cannot know, so the hash the packet records is the creation code's — the frozen build's
    ///      own identity — while the length it records is the whole initcode's, because that is
    ///      what EIP-3860 measures.
    function _reportDeployability(
        string memory name,
        bytes memory creationCode,
        bytes memory constructorArgs,
        uint256 runtimeBytes,
        uint256 gasUsed
    ) private {
        uint256 initcodeBytes = creationCode.length + constructorArgs.length;

        assertGt(runtimeBytes, 0, "a ceremony contract deployed no runtime");
        assertLe(runtimeBytes, EIP170_RUNTIME_LIMIT, "a ceremony contract exceeds the EIP-170 runtime limit");
        assertLe(initcodeBytes, EIP3860_INITCODE_LIMIT, "a ceremony creation exceeds the EIP-3860 initcode limit");

        emit log_named_string("packet contract", name);
        emit log_named_uint("  runtime_bytes", runtimeBytes);
        emit log_named_uint("  runtime_margin_bytes", EIP170_RUNTIME_LIMIT - runtimeBytes);
        emit log_named_uint("  creation_code_bytes", creationCode.length);
        emit log_named_bytes32("  creation_code_keccak256", keccak256(creationCode));
        emit log_named_uint("  constructor_args_bytes", constructorArgs.length);
        emit log_named_uint("  initcode_bytes", initcodeBytes);
        emit log_named_uint("  initcode_margin_bytes", EIP3860_INITCODE_LIMIT - initcodeBytes);

        if (gasUsed != 0) {
            assertLe(gasUsed, CREATION_GAS_FLOOR_GUARDRAIL, "in-EVM creation gas exceeds the 14,000,000 guardrail");
            emit log_named_uint("  in_evm_creation_gas_floor", gasUsed);
        }
    }

    function _emitCreationOrder(DeployAutolaunchV1.Graph memory graph) private {
        emit log_named_uint("ceremony top_level_creations", 5);
        emit log_named_address("ceremony creation_1_uerc20_factory", graph.uerc20Factory);
        emit log_named_address("ceremony creation_2_escrow_implementation", graph.escrowImplementation);
        emit log_named_address("ceremony creation_3_splitter_implementation", graph.splitterImplementation);
        emit log_named_address("ceremony creation_4_receiver_implementation", graph.receiverImplementation);
        emit log_named_address("ceremony creation_5_factory", graph.factory);
        emit log_named_address("ceremony internal_strategy", graph.strategy);
        emit log_named_address("ceremony internal_hook", graph.hook);
    }

    function _addresses(DeployAutolaunchV1.Graph memory graph) private pure returns (address[7] memory set) {
        set[0] = graph.uerc20Factory;
        set[1] = graph.escrowImplementation;
        set[2] = graph.splitterImplementation;
        set[3] = graph.receiverImplementation;
        set[4] = graph.factory;
        set[5] = graph.strategy;
        set[6] = graph.hook;
    }
}
