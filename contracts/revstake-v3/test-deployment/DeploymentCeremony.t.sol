// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {DeployRevstakeV3} from "../script/DeployRevstakeV3.s.sol";
import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV2} from "../src/escrow/ConditionalVestingEscrowV2.sol";
import {RegentsAutolaunchFactoryV3} from "../src/factory/RegentsAutolaunchFactoryV3.sol";
import {RegentFeeHook} from "../src/hook/RegentFeeHook.sol";
import {PaymentReceiverV1} from "../src/revenue/PaymentReceiverV1.sol";
import {RevstakeLPLocker} from "../src/revenue/RevstakeLPLocker.sol";
import {SubjectSplitterV1} from "../src/revenue/SubjectSplitterV1.sol";
import {RegentLBPStrategyV3} from "../src/strategy/RegentLBPStrategyV3.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {UERC20Factory} from "uerc20-factory/factories/UERC20Factory.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The Revstake version 3 ceremony's own evidence: `DEP-070` through `DEP-076`.
/// @dev Every claim here runs the real `script/DeployRevstakeV3.s.sol` against a disposable
///      deployer whose starting nonce is set explicitly, which is exactly the shape the Base
///      ceremony has. The four contracts version 3 reuses from version 2 are stood up here from
///      this package's own unchanged sources by a separate account, as version 2's ceremony
///      created them; the factory admits them by runtime code hash, so a build whose bytes drifted
///      from the deployed version 2 ones fails construction rather than agreeing with itself.
///      Nothing here needs a provider, and nothing here signs, broadcasts, funds or moves value:
///      `vm.startBroadcast` inside the script only attributes the `CREATE` to the deployer's nonce.
contract DeploymentCeremonyTest is Test {
    /// @notice Exactly the three permission bits `RegentFeeHook` declares, stated independently of
    ///         the script so a wrong flag set in either place fails rather than agrees with itself.
    uint160 internal constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    /// @notice EIP-170's deployed-runtime ceiling and EIP-3860's initcode ceiling.
    uint256 internal constant EIP170_RUNTIME_LIMIT = 24_576;
    uint256 internal constant EIP3860_INITCODE_LIMIT = 49_152;

    /// @notice A guardrail on in-EVM creation gas, and not a transaction-gas result.
    /// @dev The in-EVM cost of the creation is a floor on what the real transaction costs; the
    ///      rehearsal measures the real figure on a Base node against the live block gas limit.
    uint256 internal constant CREATION_GAS_FLOOR_GUARDRAIL = 14_000_000;

    /// @notice The disposable deployer's pinned starting nonce in this suite.
    uint64 internal constant STARTING_NONCE = 3;

    DeployRevstakeV3 internal deployment;
    address internal deployer;
    address internal uerc20Factory;
    address internal escrowImplementation;
    address internal splitterImplementation;
    address internal receiverImplementation;

    function setUp() public {
        deployment = new DeployRevstakeV3();
        deployer = makeAddr("revstake-v3-ceremony-deployer");

        // Version 2's shared contracts, created by version 2's own deployer before this ceremony.
        vm.startPrank(makeAddr("revstake-v2-ceremony-deployer"));
        uerc20Factory = address(new UERC20Factory());
        escrowImplementation = address(new ConditionalVestingEscrowV2());
        splitterImplementation = address(new SubjectSplitterV1());
        receiverImplementation = address(new PaymentReceiverV1());
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // DEP-070 — the one direct, zero-value creation
    // -------------------------------------------------------------------------

    /// @notice `DEP-070`: the factory lands at the deployer's pinned nonce, and the deployer sends
    ///         that one creation and nothing else.
    function test_DEP_070_OneCreationLandsAtThePinnedNonce() public {
        (DeployRevstakeV3.Ceremony memory ceremony, DeployRevstakeV3.Graph memory predicted) = _prepare();

        uint256 balanceBefore = deployer.balance;
        DeployRevstakeV3.Graph memory graph = deployment.execute(ceremony);

        assertEq(graph.factory, vm.computeCreateAddress(deployer, STARTING_NONCE), "the creation moved");
        assertEq(abi.encode(graph), abi.encode(predicted), "the executed graph is not the predicted graph");
        assertEq(vm.getNonce(deployer), STARTING_NONCE + 1, "the deployer sent something other than one creation");

        assertEq(deployer.balance, balanceBefore, "the ceremony moved value out of the deployer");
        address[4] memory created = _addresses(graph);
        for (uint256 i; i < created.length; ++i) {
            assertEq(created[i].balance, 0, "a created contract holds ETH");
            assertGt(created[i].code.length, 0, "a predicted address carries no code");
        }
    }

    // -------------------------------------------------------------------------
    // DEP-071 — the three internal creations: two by the factory, one by the strategy
    // -------------------------------------------------------------------------

    /// @notice `DEP-071`: the factory constructor alone creates the strategy at its first internal
    ///         `CREATE` and the hook by `CREATE2` over the pre-mined salt, the hook carries exactly
    ///         the three permission bits, and the strategy constructor alone creates the LP locker.
    function test_DEP_071_FactoryAloneCreatesTheStrategyAndTheMinedHook() public {
        (DeployRevstakeV3.Ceremony memory ceremony,) = _prepare();
        DeployRevstakeV3.Graph memory graph = deployment.execute(ceremony);

        assertEq(graph.strategy, vm.computeCreateAddress(graph.factory, 1), "the strategy is not at factory nonce 1");
        assertEq(graph.lpLocker, vm.computeCreateAddress(graph.strategy, 1), "the locker is not at strategy nonce 1");
        assertEq(
            graph.hook,
            vm.computeCreate2Address(
                ceremony.hookSalt, keccak256(deployment.hookInitcode(graph.strategy)), graph.factory
            ),
            "the hook is not the factory's CREATE2 over the pinned salt"
        );
        assertEq(
            uint256(uint160(graph.hook) & Hooks.ALL_HOOK_MASK),
            uint256(HOOK_FLAGS),
            "the hook address does not carry exactly the three bits"
        );

        // EIP-161 starts a contract's nonce at one: the factory's two creations leave it at three,
        // the strategy's one leaves it at two, and nothing else created anything.
        assertEq(vm.getNonce(graph.factory), 3, "the factory made an internal creation the ceremony does not admit");
        assertEq(vm.getNonce(graph.strategy), 2, "the strategy made an internal creation the ceremony does not admit");
        assertEq(vm.getNonce(graph.lpLocker), 1, "the locker created something");
        assertEq(vm.getNonce(graph.hook), 1, "the hook created something");
    }

    // -------------------------------------------------------------------------
    // DEP-072 — exact constructor bindings and runtime readbacks
    // -------------------------------------------------------------------------

    /// @notice `DEP-072`: every binding and readback across the four created contracts is exactly
    ///         what the ceremony intended, and the reused version 2 contracts are the admitted ones.
    function test_DEP_072_EveryConstructorBindingAndReadbackIsExact() public {
        (DeployRevstakeV3.Ceremony memory ceremony,) = _prepare();
        DeployRevstakeV3.Graph memory graph = deployment.execute(ceremony);

        RegentsAutolaunchFactoryV3 factory = RegentsAutolaunchFactoryV3(graph.factory);
        RegentLBPStrategyV3 strategy = RegentLBPStrategyV3(graph.strategy);
        RegentFeeHook hook = RegentFeeHook(graph.hook);

        assertEq(factory.uerc20Factory(), uerc20Factory, "the factory bound another token factory");
        assertEq(address(factory.strategy()), graph.strategy, "the factory bound another strategy");
        assertEq(address(factory.hook()), graph.hook, "the factory bound another hook");
        assertEq(factory.nextLaunchId(), 1, "the factory was not born at launch id one");
        assertTrue(factory.launchesPaused(), "the creation did not leave the factory paused");

        assertEq(strategy.factory(), graph.factory, "the strategy bound another factory");
        assertEq(strategy.escrowImplementation(), escrowImplementation, "the strategy bound another escrow");
        assertEq(strategy.splitterImplementation(), splitterImplementation, "the strategy bound another splitter");
        assertEq(strategy.receiverImplementation(), receiverImplementation, "the strategy bound another receiver");
        assertEq(strategy.hook(), graph.hook, "the strategy did not bind the hook the factory created");
        assertEq(address(strategy.lpLocker()), graph.lpLocker, "the strategy bound another locker");

        assertEq(RevstakeLPLocker(graph.lpLocker).strategy(), graph.strategy, "the locker bound another strategy");
        assertEq(address(hook.poolManager()), BaseBindings.POOL_MANAGER, "the hook bound another PoolManager");
        assertEq(hook.strategy(), graph.strategy, "the hook bound another strategy");

        assertEq(
            uerc20Factory.codehash,
            factory.UERC20_FACTORY_RUNTIME_CODE_HASH(),
            "the token factory is not the admitted one"
        );
        assertEq(
            escrowImplementation.codehash,
            factory.ESCROW_IMPLEMENTATION_RUNTIME_CODE_HASH(),
            "the escrow implementation is not the admitted one"
        );
        assertEq(
            splitterImplementation.codehash,
            factory.SPLITTER_IMPLEMENTATION_RUNTIME_CODE_HASH(),
            "the splitter implementation is not the admitted one"
        );
        assertEq(
            receiverImplementation.codehash,
            factory.RECEIVER_IMPLEMENTATION_RUNTIME_CODE_HASH(),
            "the receiver implementation is not the admitted one"
        );
    }

    // -------------------------------------------------------------------------
    // DEP-073 — the deployer keeps nothing
    // -------------------------------------------------------------------------

    /// @notice `DEP-073`: the disposable deployer retains no protocol authority, and the frozen
    ///         Governance/Regent Safe is the sole new-launch pause authority.
    function test_DEP_073_TheDeployerRetainsNoProtocolAuthority() public {
        (DeployRevstakeV3.Ceremony memory ceremony,) = _prepare();
        DeployRevstakeV3.Graph memory graph = deployment.execute(ceremony);

        RegentsAutolaunchFactoryV3 factory = RegentsAutolaunchFactoryV3(graph.factory);

        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSelector(RegentsAutolaunchFactoryV3.NotGovernance.selector, deployer));
        factory.pauseLaunches();
        vm.expectRevert(abi.encodeWithSelector(RegentsAutolaunchFactoryV3.NotGovernance.selector, deployer));
        factory.unpauseLaunches();
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategyV3.NotFactory.selector, deployer));
        RegentLBPStrategyV3(graph.strategy).bindHook(deployer);
        vm.stopPrank();

        assertTrue(factory.launchesPaused(), "the ceremony graph did not stay paused");
        vm.prank(BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        factory.unpauseLaunches();
        assertFalse(factory.launchesPaused(), "the frozen Safe is not the activation authority");
    }

    // -------------------------------------------------------------------------
    // DEP-074 — deployability margins for every contract the ceremony creates
    // -------------------------------------------------------------------------

    /// @notice `DEP-074`: every contract the ceremony creates fits EIP-170 and EIP-3860, and the
    ///         creation's in-EVM gas floor stays under the guardrail.
    function test_DEP_074_EveryCreationFitsTheDeployabilityLimits() public {
        (DeployRevstakeV3.Ceremony memory ceremony, DeployRevstakeV3.Graph memory graph) = _prepare();

        bytes memory factoryArgs = abi.encode(
            uerc20Factory, escrowImplementation, splitterImplementation, receiverImplementation, ceremony.hookSalt
        );
        vm.startBroadcast(deployer);
        uint256 before = gasleft();
        new RegentsAutolaunchFactoryV3(
            uerc20Factory, escrowImplementation, splitterImplementation, receiverImplementation, ceremony.hookSalt
        );
        uint256 gasUsed = before - gasleft();
        vm.stopBroadcast();

        _reportDeployability(
            "RegentsAutolaunchFactoryV3",
            type(RegentsAutolaunchFactoryV3).creationCode,
            factoryArgs,
            graph.factory.code.length,
            gasUsed
        );
        _reportDeployability(
            "RegentLBPStrategyV3",
            type(RegentLBPStrategyV3).creationCode,
            abi.encode(graph.factory, escrowImplementation, splitterImplementation, receiverImplementation),
            graph.strategy.code.length,
            0
        );
        _reportDeployability(
            "RevstakeLPLocker",
            type(RevstakeLPLocker).creationCode,
            abi.encode(graph.strategy),
            graph.lpLocker.code.length,
            0
        );
        _reportDeployability(
            "RegentFeeHook",
            type(RegentFeeHook).creationCode,
            abi.encode(BaseBindings.POOL_MANAGER, graph.strategy),
            graph.hook.code.length,
            0
        );
    }

    // -------------------------------------------------------------------------
    // DEP-075 — the ceremony aborts in simulation, before anything is created
    // -------------------------------------------------------------------------

    /// @notice `DEP-075`: an unselected deployer or implementation, a salt without the permission
    ///         bits, a wrong chain and a moved nonce each abort before the creation.
    function test_DEP_075_AnyPinnedValueMismatchAbortsBeforeTheCreation() public {
        (DeployRevstakeV3.Ceremony memory ceremony,) = _prepare();

        DeployRevstakeV3.Ceremony memory unselected = _ceremony(address(0), 0, ceremony.hookSalt);
        vm.expectRevert(DeployRevstakeV3.UnselectedDeployer.selector);
        deployment.predict(unselected);

        unselected = _ceremony(deployer, STARTING_NONCE, ceremony.hookSalt);
        unselected.splitterImplementation = address(0);
        vm.expectRevert(DeployRevstakeV3.UnselectedImplementation.selector);
        deployment.predict(unselected);

        DeployRevstakeV3.Ceremony memory wrongSalt =
            _ceremony(deployer, STARTING_NONCE, bytes32(uint256(ceremony.hookSalt) ^ 1));
        vm.expectPartialRevert(DeployRevstakeV3.HookSaltDoesNotCarryThePermissionBits.selector);
        deployment.execute(wrongSalt);

        vm.setEnv("REGENT_DEPLOYMENT_DEPLOYER", vm.toString(deployer));
        vm.setEnv("REGENT_DEPLOYMENT_STARTING_NONCE", vm.toString(uint256(STARTING_NONCE)));
        vm.setEnv("REGENT_DEPLOYMENT_HOOK_SALT", vm.toString(ceremony.hookSalt));
        vm.setEnv("REGENT_DEPLOYMENT_UERC20_FACTORY", vm.toString(uerc20Factory));
        vm.setEnv("REGENT_DEPLOYMENT_ESCROW_IMPLEMENTATION", vm.toString(escrowImplementation));
        vm.setEnv("REGENT_DEPLOYMENT_SPLITTER_IMPLEMENTATION", vm.toString(splitterImplementation));
        vm.setEnv("REGENT_DEPLOYMENT_RECEIVER_IMPLEMENTATION", vm.toString(receiverImplementation));
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployRevstakeV3.WrongChain.selector, 8453, 1));
        deployment.run();

        DeployRevstakeV3.Graph memory graph = deployment.predict(ceremony);
        address[4] memory created = _addresses(graph);
        for (uint256 i; i < created.length; ++i) {
            assertEq(created[i].code.length, 0, "an aborted ceremony created something");
        }

        // On Base, that same environment is the ceremony the packet pinned, consumed exactly.
        vm.chainId(BaseBindings.BASE_CHAIN_ID);
        DeployRevstakeV3.Graph memory fromEnvironment = deployment.run();
        assertEq(abi.encode(fromEnvironment), abi.encode(graph), "the broadcast entrypoint deployed another graph");

        // A repeated ceremony is terminal rather than resumable.
        vm.expectRevert(
            abi.encodeWithSelector(DeployRevstakeV3.DeployerNonceMismatch.selector, STARTING_NONCE, STARTING_NONCE + 1)
        );
        deployment.execute(ceremony);
    }

    // -------------------------------------------------------------------------
    // DEP-076 — only the exact version 2 contracts are reused
    // -------------------------------------------------------------------------

    /// @notice `DEP-076`: an address whose runtime is not the admitted version 2 build fails the
    ///         factory's construction, so the ceremony cannot bind anything else.
    function test_DEP_076_ASubstitutedImplementationFailsConstruction() public {
        (DeployRevstakeV3.Ceremony memory ceremony, DeployRevstakeV3.Graph memory graph) = _prepare();
        ceremony.receiverImplementation = splitterImplementation;

        // The admitted receiver hash is the deployed receiver's own, as `DEP-072` proves.
        vm.expectRevert(
            abi.encodeWithSelector(
                RegentsAutolaunchFactoryV3.UnexpectedRuntimeCodeHash.selector,
                splitterImplementation,
                receiverImplementation.codehash,
                splitterImplementation.codehash
            )
        );
        deployment.execute(ceremony);
        assertEq(graph.factory.code.length, 0, "a refused ceremony created the factory");
    }

    // -------------------------------------------------------------------------
    // preparation
    // -------------------------------------------------------------------------

    /// @dev Put the deployer at its pinned starting nonce, then mine the hook salt once against the
    ///      predicted factory and the predicted strategy.
    function _prepare()
        private
        returns (DeployRevstakeV3.Ceremony memory ceremony, DeployRevstakeV3.Graph memory predicted)
    {
        vm.setNonce(deployer, STARTING_NONCE);
        ceremony = _ceremony(deployer, STARTING_NONCE, _mine(deployer, STARTING_NONCE));
        predicted = deployment.predict(ceremony);
    }

    function _ceremony(address account, uint256 nonce, bytes32 salt)
        private
        view
        returns (DeployRevstakeV3.Ceremony memory)
    {
        return DeployRevstakeV3.Ceremony({
            deployer: account,
            startingNonce: nonce,
            uerc20Factory: uerc20Factory,
            escrowImplementation: escrowImplementation,
            splitterImplementation: splitterImplementation,
            receiverImplementation: receiverImplementation,
            hookSalt: salt
        });
    }

    function _mine(address account, uint256 nonce) private view returns (bytes32 salt) {
        address predictedFactory = vm.computeCreateAddress(account, nonce);
        (, salt) = HookMiner.find(
            predictedFactory,
            HOOK_FLAGS,
            type(RegentFeeHook).creationCode,
            abi.encode(BaseBindings.POOL_MANAGER, vm.computeCreateAddress(predictedFactory, 1))
        );
    }

    /// @dev One contract's two deployability margins, asserted and then emitted.
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
        emit log_named_uint("  initcode_bytes", initcodeBytes);
        emit log_named_uint("  initcode_margin_bytes", EIP3860_INITCODE_LIMIT - initcodeBytes);

        if (gasUsed != 0) {
            assertLe(gasUsed, CREATION_GAS_FLOOR_GUARDRAIL, "in-EVM creation gas exceeds the 14,000,000 guardrail");
            emit log_named_uint("  in_evm_creation_gas_floor", gasUsed);
        }
    }

    function _addresses(DeployRevstakeV3.Graph memory graph) private pure returns (address[4] memory set) {
        set[0] = graph.factory;
        set[1] = graph.strategy;
        set[2] = graph.lpLocker;
        set[3] = graph.hook;
    }
}
