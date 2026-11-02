// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Test} from "forge-std/Test.sol";
import {DeployStocksV3} from "../script/DeployStocksV3.s.sol";
import {StocksBindings} from "../src/StocksBindings.sol";
import {StocksFeeHookV1} from "../src/StocksFeeHookV1.sol";

/// @notice The founder-selected ceremony values, derived once and compared ever after.
/// @dev Run only by the ceremony tool (`bin/ceremony.py`), with the selection in the
///      environment: `prepare` supplies the deployer, the nonce it read off Base and the UERC20
///      factory, and this mines the hook salt once; `render` and `rehearse` supply the committed salt
///      too and re-derive the same graph. Mining lives here rather than in the script on purpose: the
///      script imports no miner, so a broadcast can only consume a pinned salt. Nothing here reaches
///      a network.
contract DeploymentSelectionTest is Test {
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    DeployStocksV3 internal deployment;

    function setUp() public {
        deployment = new DeployStocksV3();
    }

    /// @notice Preparation: mine the salt for the selected deployer and nonce, then emit the graph.
    function test_SelectionPrepareCandidate() public {
        DeployStocksV3.Ceremony memory ceremony = _selected(bytes32(0));
        address predictedLaunchpad = vm.computeCreateAddress(ceremony.deployer, ceremony.startingNonce);
        (, ceremony.hookSalt) = HookMiner.find(
            predictedLaunchpad,
            HOOK_FLAGS,
            type(StocksFeeHookV1).creationCode,
            abi.encode(StocksBindings.POOL_MANAGER, predictedLaunchpad)
        );
        _emitSelection(ceremony);
    }

    /// @notice Rendering and rehearsal: the same graph, re-derived from the committed values.
    function test_SelectionMatchesTheCommittedValues() public {
        _emitSelection(_selected(vm.envBytes32("REGENT_DEPLOYMENT_HOOK_SALT")));
    }

    function _selected(bytes32 salt) private view returns (DeployStocksV3.Ceremony memory) {
        return DeployStocksV3.Ceremony({
            deployer: vm.envAddress("REGENT_DEPLOYMENT_DEPLOYER"),
            startingNonce: vm.envUint("REGENT_DEPLOYMENT_STARTING_NONCE"),
            uerc20Factory: vm.envAddress("REGENT_DEPLOYMENT_UERC20_FACTORY"),
            hookSalt: salt
        });
    }

    function _emitSelection(DeployStocksV3.Ceremony memory ceremony) private {
        DeployStocksV3.Graph memory graph = deployment.predict(ceremony);
        emit log_named_address("selection deployer", ceremony.deployer);
        emit log_named_uint("selection starting_nonce", ceremony.startingNonce);
        emit log_named_address("selection uerc20_factory", ceremony.uerc20Factory);
        emit log_named_bytes32("selection hook_salt", ceremony.hookSalt);
        emit log_named_address("selection predicted_launchpad", graph.launchpad);
        emit log_named_address("selection predicted_splitter_implementation", graph.splitterImplementation);
        emit log_named_address("selection predicted_locker", graph.locker);
        emit log_named_address("selection predicted_hook", graph.hook);
        emit log_named_address("selection predicted_bid_adapter", graph.bidAdapter);
    }
}
