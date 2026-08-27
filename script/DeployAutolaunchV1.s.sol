// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../src/escrow/ConditionalVestingEscrowV1.sol";
import {RegentsAutolaunchFactoryV1} from "../src/factory/RegentsAutolaunchFactoryV1.sol";
import {RegentFeeHook} from "../src/hook/RegentFeeHook.sol";
import {PaymentReceiverV1} from "../src/revenue/PaymentReceiverV1.sol";
import {SubjectSplitterV1} from "../src/revenue/SubjectSplitterV1.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {UERC20Factory} from "uerc20-factory/factories/UERC20Factory.sol";
import {Script} from "forge-std/Script.sol";

/// @title DeployAutolaunchV1
/// @notice The whole Autolaunch Base deployment: five direct, zero-value creation transactions from
///         one founder-selected disposable deployer, in one fixed order, and nothing else.
/// @dev The topology is the ticket's, not this script's, and it is minimal on purpose. The deployer
///      creates the pinned `UERC20Factory`, then `ConditionalVestingEscrowV1`, then
///      `SubjectSplitterV1`, then `PaymentReceiverV1`, then `RegentsAutolaunchFactoryV1`. The
///      factory's own constructor is the only thing that creates `RegentLBPStrategy` — its first
///      internal `CREATE`, at factory nonce 1 — and the mined `RegentFeeHook`, its one internal
///      `CREATE2`. There is no deployment helper, proxy, upgrade path, ownership handoff, role
///      grant, governance transaction, locker, recovery framework, or post-deployment binding call.
///
///      Three values are consumed and never produced here: the deployer, its exact starting nonce,
///      and the pre-mined `hookSalt`. This file imports no miner and contains no search loop, so the
///      salt a broadcast uses is always the salt the approved packet pinned. Mining belongs to
///      preparation under `test-deployment/`, where it happens once against the predicted factory
///      and the predicted strategy and is then frozen into the packet.
///
///      Every check here runs while Foundry simulates the whole script, which it does before a
///      separately authorized broadcast signs anything. The deployer's live nonce must equal the
///      pinned starting nonce; the hook address the pinned salt derives must already carry exactly
///      the three permission bits Uniswap v4 encodes in a hook address; each simulated creation's
///      address must equal the prediction; and the factory's own `strategy()` and `hook()`
///      readbacks must equal the predicted internal addresses. A mismatch aborts the simulation, so
///      no transaction sequence is assembled and nothing is broadcast at all.
///
///      These are not checks between confirmed Base transactions. Once a broadcast begins this
///      contract runs no further, so the authorized ceremony sends the five creations sequentially,
///      confirms each receipt before the next transaction goes out, and verifies the resulting
///      addresses and readbacks against the approved packet afterwards. If any part of a real
///      sequence lands, the packet is terminal: it is never resumed.
///
///      Nothing here holds authority. The deployer's account is disposable: after the fifth creation
///      it owns no role, setter, allowance, balance, upgrade path or recovery power anywhere in the
///      graph, and the frozen Governance/Regent Safe remains the sole launch-fee and new-launch
///      pause authority exactly as it was compiled into the factory.
contract DeployAutolaunchV1 is Script {
    /// @notice Exactly the three permission bits `RegentFeeHook` declares.
    uint160 internal constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    /// @notice The low bits of an address Uniswap v4 reads a hook's permissions out of.
    uint160 internal constant HOOK_FLAG_MASK = Hooks.ALL_HOOK_MASK;

    /// @notice The number of direct creation transactions the deployer sends.
    uint256 internal constant TOP_LEVEL_CREATIONS = 5;

    /// @notice The factory nonce its first internal `CREATE` — the strategy — consumes.
    /// @dev EIP-161 starts a contract's nonce at one, so the factory's first `CREATE` is nonce 1.
    uint256 internal constant STRATEGY_FACTORY_NONCE = 1;

    /// @notice The three ceremony values the approved packet pins and this script only consumes.
    string internal constant DEPLOYER_ENV = "REGENT_DEPLOYMENT_DEPLOYER";
    string internal constant STARTING_NONCE_ENV = "REGENT_DEPLOYMENT_STARTING_NONCE";
    string internal constant HOOK_SALT_ENV = "REGENT_DEPLOYMENT_HOOK_SALT";

    /// @notice A founder-selected ceremony. Every field is pinned by the approved packet.
    struct Ceremony {
        address deployer;
        uint256 startingNonce;
        bytes32 hookSalt;
    }

    /// @notice The seven addresses one ceremony produces, in creation order.
    struct Graph {
        address uerc20Factory;
        address escrowImplementation;
        address splitterImplementation;
        address receiverImplementation;
        address factory;
        address strategy;
        address hook;
    }

    error UnselectedDeployer();
    error WrongChain(uint256 expected, uint256 found);
    error HookSaltDoesNotCarryThePermissionBits(address predictedHook, uint160 found, uint160 expected);
    error DeployerNonceMismatch(uint256 expected, uint256 found);
    error CreationAddressMismatch(uint256 index, address expected, address found);
    error InternalCreationMismatch(string what, address expected, address found);
    error DeployerNonceNotAdvancedExactly(uint256 expected, uint256 found);

    /// @notice The complete address graph a ceremony produces, derived and nothing else.
    /// @dev Pure by construction: it reads no chain state, so a prediction can be checked, reviewed
    ///      and frozen into a packet long before anything is broadcast. The five top-level addresses
    ///      are the deployer's own `CREATE` sequence from the pinned starting nonce; the strategy is
    ///      the factory's first internal `CREATE`; and the hook is the factory's `CREATE2` over the
    ///      pinned salt and the exact initcode this repository's frozen build produces for
    ///      `RegentFeeHook(POOL_MANAGER, predictedStrategy)`.
    ///
    ///      The permission-bit check is what makes a wrong or absent salt fail here rather than
    ///      inside the factory constructor: `Hooks.validateHookAddress` would reject it anyway, but
    ///      it would do so after four creations had already been sent.
    function predict(Ceremony memory ceremony) public pure returns (Graph memory graph) {
        address[TOP_LEVEL_CREATIONS] memory top = topLevelAddresses(ceremony);
        graph.uerc20Factory = top[0];
        graph.escrowImplementation = top[1];
        graph.splitterImplementation = top[2];
        graph.receiverImplementation = top[3];
        graph.factory = top[4];

        graph.strategy = vm.computeCreateAddress(graph.factory, STRATEGY_FACTORY_NONCE);
        graph.hook = vm.computeCreate2Address(ceremony.hookSalt, keccak256(hookInitcode(graph.strategy)), graph.factory);

        uint160 bits = uint160(graph.hook) & HOOK_FLAG_MASK;
        if (bits != HOOK_FLAGS) revert HookSaltDoesNotCarryThePermissionBits(graph.hook, bits, HOOK_FLAGS);
    }

    /// @notice The deployer's own five-transaction `CREATE` sequence from the pinned starting nonce.
    /// @dev Separated from the full graph because it is the half a salt has no bearing on: these
    ///      five addresses are fixed the moment the founder selects an account and its nonce, and
    ///      nothing about the hook can move them.
    function topLevelAddresses(Ceremony memory ceremony)
        public
        pure
        returns (address[TOP_LEVEL_CREATIONS] memory addresses)
    {
        if (ceremony.deployer == address(0)) revert UnselectedDeployer();
        for (uint256 i; i < TOP_LEVEL_CREATIONS; ++i) {
            addresses[i] = vm.computeCreateAddress(ceremony.deployer, ceremony.startingNonce + i);
        }
    }

    /// @notice The exact initcode the factory constructor's `CREATE2` uses for the hook.
    function hookInitcode(address strategy) public pure returns (bytes memory) {
        return abi.encodePacked(type(RegentFeeHook).creationCode, abi.encode(BaseBindings.POOL_MANAGER, strategy));
    }

    /// @notice Build the five creations in order and prove each one lands where it was predicted.
    /// @dev Sequential, and checked between steps of the simulation. A prediction this sequence
    ///      cannot reproduce aborts here, before Foundry has a transaction list to hand a broadcast,
    ///      so no skipped, dropped or replaced nonce can move the factory away from the prediction
    ///      the packet approved. The checks do not re-run between confirmed Base transactions; an
    ///      authorized executor confirms each receipt in order and verifies the addresses and
    ///      readbacks against the packet. If part of a real sequence lands and the rest does not,
    ///      the packet is terminally invalid and is never resumed: the nonce is read again, the
    ///      gates and the review are repeated, and a new founder-approved digest is required.
    function execute(Ceremony memory ceremony) public returns (Graph memory graph) {
        graph = predict(ceremony);

        uint256 nonce = vm.getNonce(ceremony.deployer);
        if (nonce != ceremony.startingNonce) revert DeployerNonceMismatch(ceremony.startingNonce, nonce);

        vm.startBroadcast(ceremony.deployer);

        address created = address(new UERC20Factory());
        if (created != graph.uerc20Factory) revert CreationAddressMismatch(0, graph.uerc20Factory, created);

        created = address(new ConditionalVestingEscrowV1());
        if (created != graph.escrowImplementation) {
            revert CreationAddressMismatch(1, graph.escrowImplementation, created);
        }

        created = address(new SubjectSplitterV1());
        if (created != graph.splitterImplementation) {
            revert CreationAddressMismatch(2, graph.splitterImplementation, created);
        }

        created = address(new PaymentReceiverV1());
        if (created != graph.receiverImplementation) {
            revert CreationAddressMismatch(3, graph.receiverImplementation, created);
        }

        RegentsAutolaunchFactoryV1 factory = new RegentsAutolaunchFactoryV1(
            graph.uerc20Factory,
            graph.escrowImplementation,
            graph.splitterImplementation,
            graph.receiverImplementation,
            ceremony.hookSalt
        );
        if (address(factory) != graph.factory) revert CreationAddressMismatch(4, graph.factory, address(factory));

        vm.stopBroadcast();

        address strategy = address(factory.strategy());
        if (strategy != graph.strategy) revert InternalCreationMismatch("strategy", graph.strategy, strategy);

        address hook = address(factory.hook());
        if (hook != graph.hook) revert InternalCreationMismatch("hook", graph.hook, hook);

        uint256 expected = ceremony.startingNonce + TOP_LEVEL_CREATIONS;
        nonce = vm.getNonce(ceremony.deployer);
        if (nonce != expected) revert DeployerNonceNotAdvancedExactly(expected, nonce);
    }

    /// @notice The broadcast entrypoint, consuming the three pinned ceremony values.
    /// @dev The three values arrive through the process environment, set from the approved packet by
    ///      whoever executes an authorized ceremony. The deployment gate invokes this entrypoint
    ///      only for an unsigned rehearsal: it omits `--broadcast` and every signer option. No key,
    ///      mnemonic, keystore path or endpoint is read here or anywhere else in this file, and the
    ///      gate refuses to run beside signing authority at all.
    function run() external returns (Graph memory) {
        if (block.chainid != BaseBindings.BASE_CHAIN_ID) {
            revert WrongChain(BaseBindings.BASE_CHAIN_ID, block.chainid);
        }
        return execute(
            Ceremony({
                deployer: vm.envAddress(DEPLOYER_ENV),
                startingNonce: vm.envUint(STARTING_NONCE_ENV),
                hookSalt: vm.envBytes32(HOOK_SALT_ENV)
            })
        );
    }
}
