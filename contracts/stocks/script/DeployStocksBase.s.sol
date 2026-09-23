// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Script} from "forge-std/Script.sol";
import {AerodromeStockRouteV2} from "../src/routes/AerodromeStockRouteV2.sol";
import {StockBidAdapterV1} from "../src/StockBidAdapterV1.sol";
import {StocksBindings} from "../src/StocksBindings.sol";
import {StocksFeeHookV1} from "../src/StocksFeeHookV1.sol";
import {StocksLaunchpadV1} from "../src/StocksLaunchpadV1.sol";

/// @title DeployStocksBase
/// @notice The whole Base Memestake deployment: the launchpad, the bid adapter and one production
///         stock route per admitted stock, each a direct zero-value creation from one founder-selected
///         deployer, in one fixed order, and nothing else.
/// @dev Modelled on `contracts/v1/script/DeployAutolaunchV1.s.sol`. The launchpad's own constructor
///      creates the splitter implementation (launchpad nonce 1), the LP locker (nonce 2) and the mined
///      fee hook (a `CREATE2` over the pinned salt). No helper, proxy, upgrade path, ownership
///      handoff or governance transaction happens here: the Governance and Regent Safe admits each
///      stock with its route, sets the hook executor and unpauses launches afterwards, by hand.
///
///      Every ceremony value is consumed and never produced here: the deployer, its exact starting
///      nonce, the UERC20 factory the launchpad binds, the pre-mined hook salt and the admitted
///      stocks with their Aerodrome pools and Chainlink feeds. This file imports no miner and
///      contains no search loop; mining belongs to `test-deployment/`, where it happens once against
///      the predicted launchpad and is then frozen into the packet.
///
///      Every check runs while Foundry simulates the script, before a separately authorized
///      broadcast signs anything: the deployer's live nonce must equal the pinned starting nonce,
///      the hook address the salt derives must carry exactly the five permission bits, each
///      creation must land at its prediction, and the launchpad's readbacks must equal the
///      predicted internal creations. A mismatch aborts the simulation and nothing is broadcast.
///
///      The founder sends each creation by hand and confirms every receipt before the next one goes
///      out. If any part of a real sequence lands elsewhere, the packet is terminal and is never
///      resumed. After the last creation the deployer holds no role anywhere in the graph.
contract DeployStocksBase is Script {
    /// @notice Exactly the five permission bits `StocksFeeHookV1` declares.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /// @notice The low bits of an address Uniswap v4 reads a hook's permissions out of.
    uint160 internal constant HOOK_FLAG_MASK = Hooks.ALL_HOOK_MASK;

    /// @notice The direct creations before the per-stock routes: the launchpad, then the adapter.
    uint256 internal constant FIXED_CREATIONS = 2;

    /// @notice The launchpad nonces its constructor's two `CREATE`s consume, in order (EIP-161
    ///         starts a contract's nonce at one).
    uint256 internal constant SPLITTER_LAUNCHPAD_NONCE = 1;
    uint256 internal constant LOCKER_LAUNCHPAD_NONCE = 2;

    /// @notice The ceremony values the approved packet pins and this script only consumes.
    string internal constant DEPLOYER_ENV = "REGENT_DEPLOYMENT_DEPLOYER";
    string internal constant STARTING_NONCE_ENV = "REGENT_DEPLOYMENT_STARTING_NONCE";
    string internal constant UERC20_FACTORY_ENV = "REGENT_DEPLOYMENT_UERC20_FACTORY";
    string internal constant HOOK_SALT_ENV = "REGENT_DEPLOYMENT_HOOK_SALT";
    string internal constant STOCKS_ENV = "REGENT_DEPLOYMENT_STOCKS";
    string internal constant POOLS_ENV = "REGENT_DEPLOYMENT_POOLS";
    string internal constant FEEDS_ENV = "REGENT_DEPLOYMENT_FEEDS";
    string internal constant LIST_DELIMITER = ",";

    /// @notice One admitted stock: the token, its Aerodrome Slipstream USDC/STOCK pool, its feed.
    struct Admission {
        address stock;
        address pool;
        address feed;
    }

    /// @notice A founder-selected ceremony. Every field is pinned by the approved packet.
    struct Ceremony {
        address deployer;
        uint256 startingNonce;
        address uerc20Factory;
        bytes32 hookSalt;
        Admission[] admissions;
    }

    /// @notice Every address one ceremony produces.
    struct Graph {
        address launchpad;
        address splitterImplementation;
        address locker;
        address hook;
        address bidAdapter;
        address[] routes;
    }

    error UnselectedDeployer();
    error UnselectedUerc20Factory();
    error NoAdmissions();
    error AdmissionListsDiffer(uint256 stocks, uint256 pools, uint256 feeds);
    error WrongChain(uint256 expected, uint256 found);
    error HookSaltDoesNotCarryThePermissionBits(address predictedHook, uint160 found, uint160 expected);
    error DeployerNonceMismatch(uint256 expected, uint256 found);
    error CreationAddressMismatch(uint256 index, address expected, address found);
    error InternalCreationMismatch(string what, address expected, address found);
    error DeployerNonceNotAdvancedExactly(uint256 expected, uint256 found);

    /// @notice The complete address graph a ceremony produces, derived and nothing else.
    /// @dev Pure by construction: it reads no chain state, so a prediction can be reviewed and frozen
    ///      into a packet long before anything is broadcast. The direct creations are the deployer's
    ///      own `CREATE` sequence from the pinned starting nonce; the splitter implementation and the
    ///      locker are the launchpad constructor's first two `CREATE`s; the hook is the launchpad's
    ///      `CREATE2` over the pinned salt and the exact initcode this build produces for
    ///      `StocksFeeHookV1(POOL_MANAGER, launchpad)`.
    function predict(Ceremony memory ceremony) public pure returns (Graph memory graph) {
        if (ceremony.uerc20Factory == address(0)) revert UnselectedUerc20Factory();
        address[] memory direct = directAddresses(ceremony);
        graph.launchpad = direct[0];
        graph.bidAdapter = direct[1];
        graph.routes = new address[](ceremony.admissions.length);
        for (uint256 i; i < ceremony.admissions.length; ++i) {
            graph.routes[i] = direct[FIXED_CREATIONS + i];
        }

        graph.splitterImplementation = vm.computeCreateAddress(graph.launchpad, SPLITTER_LAUNCHPAD_NONCE);
        graph.locker = vm.computeCreateAddress(graph.launchpad, LOCKER_LAUNCHPAD_NONCE);
        graph.hook =
            vm.computeCreate2Address(ceremony.hookSalt, keccak256(hookInitcode(graph.launchpad)), graph.launchpad);

        uint160 bits = uint160(graph.hook) & HOOK_FLAG_MASK;
        if (bits != HOOK_FLAGS) revert HookSaltDoesNotCarryThePermissionBits(graph.hook, bits, HOOK_FLAGS);
    }

    /// @notice The deployer's own `CREATE` sequence from the pinned starting nonce: the launchpad, the
    ///         bid adapter, then one route per admission in list order.
    function directAddresses(Ceremony memory ceremony) public pure returns (address[] memory addresses) {
        if (ceremony.deployer == address(0)) revert UnselectedDeployer();
        if (ceremony.admissions.length == 0) revert NoAdmissions();
        addresses = new address[](FIXED_CREATIONS + ceremony.admissions.length);
        for (uint256 i; i < addresses.length; ++i) {
            addresses[i] = vm.computeCreateAddress(ceremony.deployer, ceremony.startingNonce + i);
        }
    }

    /// @notice The exact initcode the launchpad constructor's `CREATE2` uses for the hook.
    function hookInitcode(address launchpad) public pure returns (bytes memory) {
        return abi.encodePacked(type(StocksFeeHookV1).creationCode, abi.encode(StocksBindings.POOL_MANAGER, launchpad));
    }

    /// @notice Build every creation in order and prove each one lands where it was predicted.
    /// @dev Sequential and checked between steps of the simulation, so a skipped, dropped or
    ///      replaced nonce aborts before Foundry has a transaction list to hand a broadcast. These
    ///      checks do not re-run between confirmed Base transactions: the founder confirms each
    ///      receipt in order against the packet, and a drifted sequence terminates the packet.
    function execute(Ceremony memory ceremony) public returns (Graph memory graph) {
        graph = predict(ceremony);

        uint256 nonce = vm.getNonce(ceremony.deployer);
        if (nonce != ceremony.startingNonce) revert DeployerNonceMismatch(ceremony.startingNonce, nonce);

        vm.startBroadcast(ceremony.deployer);

        StocksLaunchpadV1 launchpad = new StocksLaunchpadV1(ceremony.uerc20Factory, ceremony.hookSalt);
        if (address(launchpad) != graph.launchpad) {
            revert CreationAddressMismatch(0, graph.launchpad, address(launchpad));
        }

        address created = address(new StockBidAdapterV1(graph.launchpad));
        if (created != graph.bidAdapter) revert CreationAddressMismatch(1, graph.bidAdapter, created);

        for (uint256 i; i < ceremony.admissions.length; ++i) {
            Admission memory admission = ceremony.admissions[i];
            created = address(new AerodromeStockRouteV2(admission.stock, admission.pool, admission.feed));
            if (created != graph.routes[i]) {
                revert CreationAddressMismatch(FIXED_CREATIONS + i, graph.routes[i], created);
            }
        }

        vm.stopBroadcast();

        address splitter = launchpad.splitterImplementation();
        if (splitter != graph.splitterImplementation) {
            revert InternalCreationMismatch("splitterImplementation", graph.splitterImplementation, splitter);
        }
        address locker = launchpad.locker();
        if (locker != graph.locker) revert InternalCreationMismatch("locker", graph.locker, locker);
        address hook = launchpad.hook();
        if (hook != graph.hook) revert InternalCreationMismatch("hook", graph.hook, hook);

        uint256 expected = ceremony.startingNonce + FIXED_CREATIONS + ceremony.admissions.length;
        nonce = vm.getNonce(ceremony.deployer);
        if (nonce != expected) revert DeployerNonceNotAdvancedExactly(expected, nonce);
    }

    /// @notice The broadcast entrypoint, consuming the pinned ceremony values from the environment.
    /// @dev The ceremony tool runs this only for an unsigned rehearsal: no `--broadcast`, no signer.
    ///      No key, keystore path or endpoint is read here or anywhere else in this file.
    function run() external returns (Graph memory) {
        if (block.chainid != StocksBindings.BASE_CHAIN_ID) {
            revert WrongChain(StocksBindings.BASE_CHAIN_ID, block.chainid);
        }
        return execute(
            Ceremony({
                deployer: vm.envAddress(DEPLOYER_ENV),
                startingNonce: vm.envUint(STARTING_NONCE_ENV),
                uerc20Factory: vm.envAddress(UERC20_FACTORY_ENV),
                hookSalt: vm.envBytes32(HOOK_SALT_ENV),
                admissions: admissionsFromEnvironment()
            })
        );
    }

    /// @notice The admitted stocks as three comma-separated lists of equal length, in one order.
    function admissionsFromEnvironment() public view returns (Admission[] memory admissions) {
        address[] memory stocks = vm.envAddress(STOCKS_ENV, LIST_DELIMITER);
        address[] memory pools = vm.envAddress(POOLS_ENV, LIST_DELIMITER);
        address[] memory feeds = vm.envAddress(FEEDS_ENV, LIST_DELIMITER);
        if (stocks.length != pools.length || stocks.length != feeds.length) {
            revert AdmissionListsDiffer(stocks.length, pools.length, feeds.length);
        }
        admissions = new Admission[](stocks.length);
        for (uint256 i; i < stocks.length; ++i) {
            admissions[i] = Admission({stock: stocks[i], pool: pools[i], feed: feeds[i]});
        }
    }
}
