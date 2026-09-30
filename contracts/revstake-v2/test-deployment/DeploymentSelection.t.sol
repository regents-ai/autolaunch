// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {DeployRevstakeV2} from "../script/DeployRevstakeV2.s.sol";
import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {RegentFeeHook} from "../src/hook/RegentFeeHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The founder-selected ceremony values, derived once and compared ever after.
/// @dev Run only by the ceremony tool (`../stocks-v2/bin/ceremony.py`), with the selection in the
///      environment: `prepare` supplies the deployer and the nonce it read off Base, and this mines
///      the hook salt once; `render` and `rehearse` supply the committed salt too and re-derive the
///      same graph. Mining lives here rather than in the script on purpose: the script imports no
///      miner, so a broadcast can only consume a pinned salt. Nothing here reaches a network.
contract DeploymentSelectionTest is Test {
    /// @notice Exactly the three permission bits `RegentFeeHook` declares, stated independently of
    ///         the script so a wrong flag set in either place fails rather than agrees with itself.
    uint160 internal constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    /// @notice The factory nonce its first internal `CREATE` — the strategy — consumes.
    uint256 internal constant STRATEGY_FACTORY_NONCE = 1;

    DeployRevstakeV2 internal deployment;

    function setUp() public {
        deployment = new DeployRevstakeV2();
    }

    /// @notice Preparation: mine the salt for the selected deployer and nonce, then emit the graph.
    function test_SelectionPrepareCandidate() public {
        DeployRevstakeV2.Ceremony memory ceremony = _selected(bytes32(0));
        address predictedFactory = deployment.topLevelAddresses(ceremony)[4];
        (, ceremony.hookSalt) = HookMiner.find(
            predictedFactory,
            HOOK_FLAGS,
            type(RegentFeeHook).creationCode,
            abi.encode(BaseBindings.POOL_MANAGER, vm.computeCreateAddress(predictedFactory, STRATEGY_FACTORY_NONCE))
        );
        _emitSelection(ceremony);
    }

    /// @notice Rendering and rehearsal: the same graph, re-derived from the committed values.
    function test_SelectionMatchesTheCommittedValues() public {
        _emitSelection(_selected(vm.envBytes32("REGENT_DEPLOYMENT_HOOK_SALT")));
    }

    function _selected(bytes32 salt) private view returns (DeployRevstakeV2.Ceremony memory) {
        return DeployRevstakeV2.Ceremony({
            deployer: vm.envAddress("REGENT_DEPLOYMENT_DEPLOYER"),
            startingNonce: vm.envUint("REGENT_DEPLOYMENT_STARTING_NONCE"),
            hookSalt: salt
        });
    }

    /// @dev The whole graph, through the script's own derivation. `predict` rejects a salt whose
    ///      hook address does not carry the three permission bits.
    function _emitSelection(DeployRevstakeV2.Ceremony memory ceremony) private {
        DeployRevstakeV2.Graph memory graph = deployment.predict(ceremony);
        emit log_named_address("selection deployer", ceremony.deployer);
        emit log_named_uint("selection starting_nonce", ceremony.startingNonce);
        emit log_named_bytes32("selection hook_salt", ceremony.hookSalt);
        emit log_named_address("selection predicted_uerc20_factory", graph.uerc20Factory);
        emit log_named_address("selection predicted_escrow_implementation", graph.escrowImplementation);
        emit log_named_address("selection predicted_splitter_implementation", graph.splitterImplementation);
        emit log_named_address("selection predicted_receiver_implementation", graph.receiverImplementation);
        emit log_named_address("selection predicted_factory", graph.factory);
        emit log_named_address("selection predicted_strategy", graph.strategy);
        emit log_named_address("selection predicted_lp_locker", graph.lpLocker);
        emit log_named_address("selection predicted_hook", graph.hook);
    }
}
