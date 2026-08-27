// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {DeployAutolaunchV1} from "../script/DeployAutolaunchV1.s.sol";
import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {RegentFeeHook} from "../src/hook/RegentFeeHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The founder-selected ceremony values, derived once and compared ever after.
/// @dev This contract closes no requirement and carries no requirement id. Like the preflight it is
///      excluded by name from the deployment gate's compiled listing and from the ledger
///      reconciliation, and like the preflight it runs only in the gate's two provider modes.
///
///      A ceremony has exactly two free parameters — a founder-selected account and the nonce it is
///      at — and everything else follows from them. `--prepare` reads that account's live nonce off
///      Base, mines the hook salt once against the predicted factory and the predicted strategy, and
///      emits the resulting graph for the gate to write as a reviewable candidate. `--rehearse`
///      re-derives the same graph from the values a human then installed and committed, and the gate
///      holds it to the committed record; a rehearsal derives nothing it is allowed to keep.
///
///      Mining lives here rather than in `script/DeployAutolaunchV1.s.sol` on purpose: the script
///      imports no miner and contains no search loop, so a broadcast can only ever consume the salt
///      an approved packet pinned.
///
///      Nothing here signs, broadcasts, funds, or moves value, and no key, mnemonic or endpoint is
///      read. The three values below are public ceremony parameters and the fork is read-only.
contract DeploymentSelectionTest is Test {
    /// @notice The configured Base endpoint alias. Never an endpoint, always an alias.
    string internal constant RPC_ALIAS = "base";

    /// @notice Exactly the five permission bits `RegentFeeHook` declares, stated independently of
    ///         the script so a wrong flag set in either place fails rather than agrees with itself.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /// @notice The factory nonce its first internal `CREATE` — the strategy — consumes.
    uint256 internal constant STRATEGY_FACTORY_NONCE = 1;

    /// @notice The three public ceremony values, under the names the script itself consumes.
    string internal constant DEPLOYER_ENV = "REGENT_DEPLOYMENT_DEPLOYER";
    string internal constant STARTING_NONCE_ENV = "REGENT_DEPLOYMENT_STARTING_NONCE";
    string internal constant HOOK_SALT_ENV = "REGENT_DEPLOYMENT_HOOK_SALT";

    DeployAutolaunchV1 internal deployment;

    function setUp() public {
        vm.createSelectFork(RPC_ALIAS);
        deployment = new DeployAutolaunchV1();
    }

    /// @notice Preparation: the founder's deployer, its live Base nonce, and the salt mined once.
    /// @dev The gate writes what this emits as a gitignored candidate and stops. Installing it is a
    ///      deliberate human step, so nothing this function derives can become authority by itself.
    function test_SelectionPrepareCandidate() public {
        address deployer = vm.envAddress(DEPLOYER_ENV);
        uint256 startingNonce = vm.getNonce(deployer);

        address[5] memory top = deployment.topLevelAddresses(
            DeployAutolaunchV1.Ceremony({deployer: deployer, startingNonce: startingNonce, hookSalt: bytes32(0)})
        );
        address predictedFactory = top[4];

        (, bytes32 hookSalt) = HookMiner.find(
            predictedFactory,
            HOOK_FLAGS,
            type(RegentFeeHook).creationCode,
            abi.encode(BaseBindings.POOL_MANAGER, vm.computeCreateAddress(predictedFactory, STRATEGY_FACTORY_NONCE))
        );

        _emitSelection(
            DeployAutolaunchV1.Ceremony({deployer: deployer, startingNonce: startingNonce, hookSalt: hookSalt})
        );
    }

    /// @notice Rehearsal: the same graph, re-derived from the committed selection and nothing else.
    function test_SelectionMatchesTheCommittedValues() public {
        _emitSelection(
            DeployAutolaunchV1.Ceremony({
                deployer: vm.envAddress(DEPLOYER_ENV),
                startingNonce: vm.envUint(STARTING_NONCE_ENV),
                hookSalt: vm.envBytes32(HOOK_SALT_ENV)
            })
        );
    }

    /// @dev The whole graph, through the script's own derivation. `predict` rejects a salt whose
    ///      hook address does not carry the five permission bits, so a wrong salt fails here.
    function _emitSelection(DeployAutolaunchV1.Ceremony memory ceremony) private {
        DeployAutolaunchV1.Graph memory graph = deployment.predict(ceremony);

        emit log_named_address("selection deployer", ceremony.deployer);
        emit log_named_uint("selection starting_nonce", ceremony.startingNonce);
        emit log_named_bytes32("selection hook_salt", ceremony.hookSalt);
        emit log_named_address("selection predicted_uerc20_factory", graph.uerc20Factory);
        emit log_named_address("selection predicted_escrow_implementation", graph.escrowImplementation);
        emit log_named_address("selection predicted_splitter_implementation", graph.splitterImplementation);
        emit log_named_address("selection predicted_receiver_implementation", graph.receiverImplementation);
        emit log_named_address("selection predicted_factory", graph.factory);
        emit log_named_address("selection predicted_strategy", graph.strategy);
        emit log_named_address("selection predicted_hook", graph.hook);
    }
}
