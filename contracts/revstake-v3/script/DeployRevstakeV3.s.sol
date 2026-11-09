// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {RegentsAutolaunchFactoryV3} from "../src/factory/RegentsAutolaunchFactoryV3.sol";
import {RegentFeeHook} from "../src/hook/RegentFeeHook.sol";
import {RegentLBPStrategyV3} from "../src/strategy/RegentLBPStrategyV3.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Script} from "forge-std/Script.sol";

/// @title DeployRevstakeV3
/// @notice The whole Revstake version 3 deployment on Base: one direct, zero-value creation
///         transaction from one founder-selected disposable deployer, and nothing else.
/// @dev Version 3 reuses version 2's four shared contracts as they stand on Base: the pinned
///      `UERC20Factory`, `ConditionalVestingEscrowV2`, `SubjectSplitterV1` and `PaymentReceiverV1`
///      that `contracts/revstake-v2/deployments/base-mainnet/deployed-manifest.json` records. Their
///      bytes are unchanged in this package, and `RegentsAutolaunchFactoryV3`'s constructor admits
///      each by its runtime code hash, so a substituted or codeless address fails construction.
///
///      The deployer creates `RegentsAutolaunchFactoryV3` and nothing else. The factory's own
///      constructor is the only thing that creates `RegentLBPStrategyV3` — its first internal
///      `CREATE`, at factory nonce 1 — and the mined `RegentFeeHook`, its one internal `CREATE2`;
///      the strategy's own constructor is the only thing that creates `RevstakeLPLocker`, its first
///      internal `CREATE`, at strategy nonce 1. There is no deployment helper, proxy, upgrade path,
///      ownership handoff, role grant, governance transaction or post-deployment binding call.
///
///      Every ceremony value is consumed and never produced here: the deployer, its exact starting
///      nonce, the four reused version 2 addresses and the pre-mined `hookSalt`. This file imports
///      no miner and contains no search loop; mining belongs to `test-deployment/`, where it
///      happens once against the predicted factory and strategy and is then frozen into the packet.
///
///      Every check runs while Foundry simulates the script, before a separately authorized
///      broadcast signs anything: the deployer's live nonce must equal the pinned starting nonce,
///      the hook address the salt derives must carry exactly the three permission bits, the
///      creation must land at its prediction, and the factory's `strategy()` and `hook()` and the
///      strategy's `lpLocker()` must equal the predicted internal creations. A mismatch aborts the
///      simulation and nothing is broadcast.
///
///      The factory is born paused. After the creation the deployer holds no role anywhere in the
///      graph, and the frozen Governance/Regent Safe remains the sole new-launch pause authority.
contract DeployRevstakeV3 is Script {
    /// @notice Exactly the three permission bits `RegentFeeHook` declares.
    uint160 internal constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    /// @notice The low bits of an address Uniswap v4 reads a hook's permissions out of.
    uint160 internal constant HOOK_FLAG_MASK = Hooks.ALL_HOOK_MASK;

    /// @notice The number of direct creation transactions the deployer sends.
    uint256 internal constant TOP_LEVEL_CREATIONS = 1;

    /// @notice The factory nonce its first internal `CREATE` — the strategy — consumes.
    /// @dev EIP-161 starts a contract's nonce at one, so the factory's first `CREATE` is nonce 1.
    uint256 internal constant STRATEGY_FACTORY_NONCE = 1;

    /// @notice The strategy nonce its only internal `CREATE` — the LP locker — consumes.
    uint256 internal constant LOCKER_STRATEGY_NONCE = 1;

    /// @notice The ceremony values the approved packet pins and this script only consumes.
    string internal constant DEPLOYER_ENV = "REGENT_DEPLOYMENT_DEPLOYER";
    string internal constant STARTING_NONCE_ENV = "REGENT_DEPLOYMENT_STARTING_NONCE";
    string internal constant HOOK_SALT_ENV = "REGENT_DEPLOYMENT_HOOK_SALT";
    string internal constant UERC20_FACTORY_ENV = "REGENT_DEPLOYMENT_UERC20_FACTORY";
    string internal constant ESCROW_IMPLEMENTATION_ENV = "REGENT_DEPLOYMENT_ESCROW_IMPLEMENTATION";
    string internal constant SPLITTER_IMPLEMENTATION_ENV = "REGENT_DEPLOYMENT_SPLITTER_IMPLEMENTATION";
    string internal constant RECEIVER_IMPLEMENTATION_ENV = "REGENT_DEPLOYMENT_RECEIVER_IMPLEMENTATION";

    /// @notice A founder-selected ceremony. Every field is pinned by the approved packet.
    struct Ceremony {
        address deployer;
        uint256 startingNonce;
        address uerc20Factory;
        address escrowImplementation;
        address splitterImplementation;
        address receiverImplementation;
        bytes32 hookSalt;
    }

    /// @notice The four addresses one ceremony creates, in creation order.
    struct Graph {
        address factory;
        address strategy;
        address lpLocker;
        address hook;
    }

    error UnselectedDeployer();
    error UnselectedImplementation();
    error WrongChain(uint256 expected, uint256 found);
    error HookSaltDoesNotCarryThePermissionBits(address predictedHook, uint160 found, uint160 expected);
    error DeployerNonceMismatch(uint256 expected, uint256 found);
    error CreationAddressMismatch(uint256 index, address expected, address found);
    error InternalCreationMismatch(string what, address expected, address found);
    error DeployerNonceNotAdvancedExactly(uint256 expected, uint256 found);

    /// @notice The complete address graph a ceremony produces, derived and nothing else.
    /// @dev Pure by construction: it reads no chain state, so a prediction can be reviewed and frozen
    ///      into a packet long before anything is broadcast. The factory is the deployer's `CREATE`
    ///      at the pinned starting nonce; the strategy is the factory's first internal `CREATE`; the
    ///      LP locker is the strategy's first internal `CREATE`; and the hook is the factory's
    ///      `CREATE2` over the pinned salt and the exact initcode this build produces for
    ///      `RegentFeeHook(POOL_MANAGER, predictedStrategy)`.
    function predict(Ceremony memory ceremony) public pure returns (Graph memory graph) {
        if (ceremony.deployer == address(0)) revert UnselectedDeployer();
        if (
            ceremony.uerc20Factory == address(0) || ceremony.escrowImplementation == address(0)
                || ceremony.splitterImplementation == address(0) || ceremony.receiverImplementation == address(0)
        ) revert UnselectedImplementation();

        graph.factory = vm.computeCreateAddress(ceremony.deployer, ceremony.startingNonce);
        graph.strategy = vm.computeCreateAddress(graph.factory, STRATEGY_FACTORY_NONCE);
        graph.lpLocker = vm.computeCreateAddress(graph.strategy, LOCKER_STRATEGY_NONCE);
        graph.hook = vm.computeCreate2Address(ceremony.hookSalt, keccak256(hookInitcode(graph.strategy)), graph.factory);

        uint160 bits = uint160(graph.hook) & HOOK_FLAG_MASK;
        if (bits != HOOK_FLAGS) revert HookSaltDoesNotCarryThePermissionBits(graph.hook, bits, HOOK_FLAGS);
    }

    /// @notice The exact initcode the factory constructor's `CREATE2` uses for the hook.
    function hookInitcode(address strategy) public pure returns (bytes memory) {
        return abi.encodePacked(type(RegentFeeHook).creationCode, abi.encode(BaseBindings.POOL_MANAGER, strategy));
    }

    /// @notice Build the one creation and prove it and its internal creations land where predicted.
    /// @dev Checked inside the simulation. If the real creation lands elsewhere, the packet is
    ///      terminal: it is never resumed, and a new founder-approved digest is required.
    function execute(Ceremony memory ceremony) public returns (Graph memory graph) {
        graph = predict(ceremony);

        uint256 nonce = vm.getNonce(ceremony.deployer);
        if (nonce != ceremony.startingNonce) revert DeployerNonceMismatch(ceremony.startingNonce, nonce);

        vm.startBroadcast(ceremony.deployer);
        RegentsAutolaunchFactoryV3 factory = new RegentsAutolaunchFactoryV3(
            ceremony.uerc20Factory,
            ceremony.escrowImplementation,
            ceremony.splitterImplementation,
            ceremony.receiverImplementation,
            ceremony.hookSalt
        );
        vm.stopBroadcast();

        if (address(factory) != graph.factory) revert CreationAddressMismatch(0, graph.factory, address(factory));

        address strategy = address(factory.strategy());
        if (strategy != graph.strategy) revert InternalCreationMismatch("strategy", graph.strategy, strategy);

        address lpLocker = address(RegentLBPStrategyV3(strategy).lpLocker());
        if (lpLocker != graph.lpLocker) revert InternalCreationMismatch("lpLocker", graph.lpLocker, lpLocker);

        address hook = address(factory.hook());
        if (hook != graph.hook) revert InternalCreationMismatch("hook", graph.hook, hook);

        uint256 expected = ceremony.startingNonce + TOP_LEVEL_CREATIONS;
        nonce = vm.getNonce(ceremony.deployer);
        if (nonce != expected) revert DeployerNonceNotAdvancedExactly(expected, nonce);
    }

    /// @notice The broadcast entrypoint, consuming the pinned ceremony values from the environment.
    /// @dev No key, mnemonic, keystore path or endpoint is read here or anywhere else in this file.
    function run() external returns (Graph memory) {
        if (block.chainid != BaseBindings.BASE_CHAIN_ID) {
            revert WrongChain(BaseBindings.BASE_CHAIN_ID, block.chainid);
        }
        return execute(
            Ceremony({
                deployer: vm.envAddress(DEPLOYER_ENV),
                startingNonce: vm.envUint(STARTING_NONCE_ENV),
                uerc20Factory: vm.envAddress(UERC20_FACTORY_ENV),
                escrowImplementation: vm.envAddress(ESCROW_IMPLEMENTATION_ENV),
                splitterImplementation: vm.envAddress(SPLITTER_IMPLEMENTATION_ENV),
                receiverImplementation: vm.envAddress(RECEIVER_IMPLEMENTATION_ENV),
                hookSalt: vm.envBytes32(HOOK_SALT_ENV)
            })
        );
    }
}
