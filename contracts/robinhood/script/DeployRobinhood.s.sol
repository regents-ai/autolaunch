// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Script} from "forge-std/Script.sol";
import {UERC20Factory} from "uerc20-factory/factories/UERC20Factory.sol";
import {RobinhoodPositionsLib} from "../src/libraries/RobinhoodPositionsLib.sol";
import {RobinhoodFeeHookFactory} from "../src/RobinhoodFeeHookFactory.sol";
import {RobinhoodFeeHookV1} from "../src/RobinhoodFeeHookV1.sol";
import {RobinhoodLaunchpadBase} from "../src/RobinhoodLaunchpadBase.sol";
import {RobinhoodProtocolRevenueInboxV1} from "../src/RobinhoodProtocolRevenueInboxV1.sol";
import {RobinhoodStockBidAdapterV1} from "../src/RobinhoodStockBidAdapterV1.sol";
import {RobinhoodStocksLaunchpadV1} from "../src/RobinhoodStocksLaunchpadV1.sol";

/// @title DeployRobinhood
/// @notice The whole Robinhood Chain Memestake deployment: six direct zero-value creations from
///         one founder-selected deployer, in one fixed order, and nothing else.
/// @dev Modelled on `contracts/v1/script/DeployAutolaunchV1.s.sol`. The deployer creates the pinned
///      `UERC20Factory` (Robinhood Chain carries Uniswap's own token factory, but not the runtime
///      the launchpad's constructor demands), then the protocol revenue inbox, then the externally
///      linked `RobinhoodPositionsLib`, then the fee hook factory, then the launchpad, then the USDG
///      bid adapter. The launchpad's own constructor
///      has the factory create the mined fee hook (a `CREATE2` from the factory over the pinned
///      salt) and creates the splitter implementation (launchpad nonce 1) and the LP locker (nonce
///      2). The Robinhood Safe admits stocks, sets the hook executor, sets the inbox's Base
///      destination and bridge adapter, and unpauses launches afterwards, by hand.
///
///      Every ceremony value is consumed and never produced here: the deployer, its exact starting
///      nonce, the pre-mined hook salt and the six external bindings the constructors verify.
///      This file imports no miner; mining belongs to `test-deployment/`.
///
///      The launchpad's runtime is linked against the library at deployment. The link target must
///      be the address this ceremony creates the library at, so the run is invoked with
///      `--libraries src/libraries/RobinhoodPositionsLib.sol:RobinhoodPositionsLib:<predicted>` and
///      the script proves, before it broadcasts anything, that the linked address equals the
///      prediction. The library is created here from its own creation code so the sequence stays one
///      deployer's `CREATE`s and Foundry pre-deploys nothing.
///
///      Every check runs while Foundry simulates the script: the deployer's live nonce must equal the
///      pinned starting nonce, the hook address must carry exactly the five permission bits, each
///      creation must land at its prediction, and the launchpad's readbacks must equal the predicted
///      internal creations. A mismatch aborts the simulation and nothing is broadcast. The founder
///      sends each creation by hand and confirms every receipt before the next one; a drifted
///      sequence terminates the packet and is never resumed.
contract DeployRobinhood is Script {
    /// @notice Exactly the five permission bits `RobinhoodFeeHookV1` declares.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /// @notice The low bits of an address Uniswap v4 reads a hook's permissions out of.
    uint160 internal constant HOOK_FLAG_MASK = Hooks.ALL_HOOK_MASK;

    /// @notice Robinhood Chain mainnet.
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    /// @notice The number of direct creation transactions the deployer sends.
    uint256 internal constant TOP_LEVEL_CREATIONS = 6;

    /// @notice The launchpad nonces its constructor's two `CREATE`s consume, in order.
    uint256 internal constant SPLITTER_LAUNCHPAD_NONCE = 1;
    uint256 internal constant LOCKER_LAUNCHPAD_NONCE = 2;

    /// @notice The ceremony values the approved packet pins and this script only consumes.
    string internal constant DEPLOYER_ENV = "REGENT_DEPLOYMENT_DEPLOYER";
    string internal constant STARTING_NONCE_ENV = "REGENT_DEPLOYMENT_STARTING_NONCE";
    string internal constant HOOK_SALT_ENV = "REGENT_DEPLOYMENT_HOOK_SALT";
    string internal constant USDG_ENV = "REGENT_DEPLOYMENT_USDG";
    string internal constant CCA_FACTORY_ENV = "REGENT_DEPLOYMENT_CCA_FACTORY";
    string internal constant POOL_MANAGER_ENV = "REGENT_DEPLOYMENT_POOL_MANAGER";
    string internal constant POSITION_MANAGER_ENV = "REGENT_DEPLOYMENT_POSITION_MANAGER";
    string internal constant PERMIT2_ENV = "REGENT_DEPLOYMENT_PERMIT2";
    string internal constant ADMIN_SAFE_ENV = "REGENT_DEPLOYMENT_ADMIN_SAFE";

    /// @notice The six external bindings the founder supplies; each constructor verifies its own.
    struct External {
        address usdg;
        address ccaFactory;
        address poolManager;
        address positionManager;
        address permit2;
        address adminSafe;
    }

    /// @notice A founder-selected ceremony. Every field is pinned by the approved packet.
    struct Ceremony {
        address deployer;
        uint256 startingNonce;
        bytes32 hookSalt;
        External external_;
    }

    /// @notice The nine addresses one ceremony produces.
    struct Graph {
        address uerc20Factory;
        address inbox;
        address positionsLib;
        address hookFactory;
        address launchpad;
        address bidAdapter;
        address hook;
        address splitterImplementation;
        address locker;
    }

    error UnselectedDeployer();
    error WrongChain(uint256 expected, uint256 found);
    error HookSaltDoesNotCarryThePermissionBits(address predictedHook, uint160 found, uint160 expected);
    error LibraryLinkMismatch(address expected, address linked);
    error DeployerNonceMismatch(uint256 expected, uint256 found);
    error CreationAddressMismatch(uint256 index, address expected, address found);
    error LibraryCreationFailed();
    error InternalCreationMismatch(string what, address expected, address found);
    error DeployerNonceNotAdvancedExactly(uint256 expected, uint256 found);

    /// @notice The complete address graph a ceremony produces, derived and nothing else.
    /// @dev Pure by construction. The six top-level addresses are the deployer's own `CREATE`
    ///      sequence from the pinned starting nonce; the hook is the factory's `CREATE2` over the
    ///      pinned salt and the exact initcode this build produces for
    ///      `RobinhoodFeeHookV1(poolManager, launchpad, usdg, inbox, adminSafe)`; the splitter
    ///      implementation and the locker are the launchpad constructor's two `CREATE`s.
    function predict(Ceremony memory ceremony) public pure returns (Graph memory graph) {
        address[TOP_LEVEL_CREATIONS] memory top = topLevelAddresses(ceremony);
        graph.uerc20Factory = top[0];
        graph.inbox = top[1];
        graph.positionsLib = top[2];
        graph.hookFactory = top[3];
        graph.launchpad = top[4];
        graph.bidAdapter = top[5];

        graph.hook = vm.computeCreate2Address(
            ceremony.hookSalt,
            keccak256(hookInitcode(ceremony.external_, graph.launchpad, graph.inbox)),
            graph.hookFactory
        );
        graph.splitterImplementation = vm.computeCreateAddress(graph.launchpad, SPLITTER_LAUNCHPAD_NONCE);
        graph.locker = vm.computeCreateAddress(graph.launchpad, LOCKER_LAUNCHPAD_NONCE);

        uint160 bits = uint160(graph.hook) & HOOK_FLAG_MASK;
        if (bits != HOOK_FLAGS) revert HookSaltDoesNotCarryThePermissionBits(graph.hook, bits, HOOK_FLAGS);
    }

    /// @notice The deployer's own six-transaction `CREATE` sequence from the pinned starting nonce.
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

    /// @notice The exact initcode the hook factory's `CREATE2` uses for the launchpad's hook.
    function hookInitcode(External memory external_, address launchpad, address inbox)
        public
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            type(RobinhoodFeeHookV1).creationCode,
            abi.encode(external_.poolManager, launchpad, external_.usdg, inbox, external_.adminSafe)
        );
    }

    /// @notice The launchpad's constructor argument, assembled from the ceremony and its predictions.
    function bindings(Ceremony memory ceremony, Graph memory graph)
        public
        pure
        returns (RobinhoodLaunchpadBase.Bindings memory)
    {
        return RobinhoodLaunchpadBase.Bindings({
            uerc20Factory: graph.uerc20Factory,
            ccaFactory: ceremony.external_.ccaFactory,
            poolManager: ceremony.external_.poolManager,
            positionManager: ceremony.external_.positionManager,
            hookFactory: graph.hookFactory,
            usdg: ceremony.external_.usdg,
            inbox: graph.inbox,
            adminSafe: ceremony.external_.adminSafe
        });
    }

    /// @notice Build the six creations in order and prove each one lands where it was predicted.
    /// @dev The link check comes first: a launchpad linked against any address but the one this
    ///      sequence creates the library at would delegate to nothing at graduation, so a run without
    ///      the exact `--libraries` pin aborts before the deployer's nonce is even read.
    function execute(Ceremony memory ceremony) public returns (Graph memory graph) {
        graph = predict(ceremony);

        address linked = address(RobinhoodPositionsLib);
        if (linked != graph.positionsLib) revert LibraryLinkMismatch(graph.positionsLib, linked);

        uint256 nonce = vm.getNonce(ceremony.deployer);
        if (nonce != ceremony.startingNonce) revert DeployerNonceMismatch(ceremony.startingNonce, nonce);

        vm.startBroadcast(ceremony.deployer);

        address created = address(new UERC20Factory());
        if (created != graph.uerc20Factory) revert CreationAddressMismatch(0, graph.uerc20Factory, created);

        created = address(new RobinhoodProtocolRevenueInboxV1(ceremony.external_.usdg, ceremony.external_.adminSafe));
        if (created != graph.inbox) revert CreationAddressMismatch(1, graph.inbox, created);

        created = _createLibrary();
        if (created != graph.positionsLib) revert CreationAddressMismatch(2, graph.positionsLib, created);

        created = address(new RobinhoodFeeHookFactory(ceremony.external_.poolManager));
        if (created != graph.hookFactory) revert CreationAddressMismatch(3, graph.hookFactory, created);

        RobinhoodStocksLaunchpadV1 launchpad =
            new RobinhoodStocksLaunchpadV1(bindings(ceremony, graph), ceremony.hookSalt);
        if (address(launchpad) != graph.launchpad) {
            revert CreationAddressMismatch(4, graph.launchpad, address(launchpad));
        }

        created = address(new RobinhoodStockBidAdapterV1(graph.launchpad, ceremony.external_.permit2));
        if (created != graph.bidAdapter) revert CreationAddressMismatch(5, graph.bidAdapter, created);

        vm.stopBroadcast();

        address hook = launchpad.hook();
        if (hook != graph.hook) revert InternalCreationMismatch("hook", graph.hook, hook);
        address splitter = launchpad.splitterImplementation();
        if (splitter != graph.splitterImplementation) {
            revert InternalCreationMismatch("splitterImplementation", graph.splitterImplementation, splitter);
        }
        address locker = launchpad.locker();
        if (locker != graph.locker) revert InternalCreationMismatch("locker", graph.locker, locker);

        uint256 expected = ceremony.startingNonce + TOP_LEVEL_CREATIONS;
        nonce = vm.getNonce(ceremony.deployer);
        if (nonce != expected) revert DeployerNonceNotAdvancedExactly(expected, nonce);
    }

    /// @notice The broadcast entrypoint, consuming the pinned ceremony values from the environment.
    /// @dev The ceremony tool runs this only for an unsigned rehearsal: no `--broadcast`, no signer.
    ///      No key, keystore path or endpoint is read here or anywhere else in this file.
    function run() external returns (Graph memory) {
        if (block.chainid != ROBINHOOD_CHAIN_ID) revert WrongChain(ROBINHOOD_CHAIN_ID, block.chainid);
        return execute(
            Ceremony({
                deployer: vm.envAddress(DEPLOYER_ENV),
                startingNonce: vm.envUint(STARTING_NONCE_ENV),
                hookSalt: vm.envBytes32(HOOK_SALT_ENV),
                external_: External({
                    usdg: vm.envAddress(USDG_ENV),
                    ccaFactory: vm.envAddress(CCA_FACTORY_ENV),
                    poolManager: vm.envAddress(POOL_MANAGER_ENV),
                    positionManager: vm.envAddress(POSITION_MANAGER_ENV),
                    permit2: vm.envAddress(PERMIT2_ENV),
                    adminSafe: vm.envAddress(ADMIN_SAFE_ENV)
                })
            })
        );
    }

    /// @dev A plain `CREATE` of the library's own creation code from the broadcasting deployer, so the
    ///      library is the deployer's third creation and not a Foundry pre-deployment.
    function _createLibrary() private returns (address created) {
        bytes memory initcode = type(RobinhoodPositionsLib).creationCode;
        assembly ("memory-safe") {
            created := create(0, add(initcode, 0x20), mload(initcode))
        }
        if (created == address(0)) revert LibraryCreationFailed();
    }
}
