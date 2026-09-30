// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Test} from "forge-std/Test.sol";
import {DeployStocksBase} from "../script/DeployStocksBase.s.sol";
import {StocksBindings} from "../src/StocksBindings.sol";
import {StocksFeeHookV1} from "../src/StocksFeeHookV1.sol";

/// @notice The founder-selected ceremony values, derived once and compared ever after.
/// @dev Run only by the ceremony tool, with the selection in the environment: `prepare` supplies the
///      deployer, the nonce it read off Base, the UERC20 factory and the admissions, and this mines
///      the hook salt once; `render` and `rehearse` supply the committed salt too and re-derive the
///      same graph. Mining lives here rather than in the script on purpose: the script imports no
///      miner, so a broadcast can only consume a pinned salt. Nothing here reaches a network.
contract DeploymentSelectionTest is Test {
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    DeployStocksBase internal deployment;

    function setUp() public {
        deployment = new DeployStocksBase();
    }

    /// @notice Preparation: mine the salt for the selected deployer and nonce, then emit the graph.
    function test_SelectionPrepareCandidate() public {
        DeployStocksBase.Ceremony memory ceremony = _selected(bytes32(0));
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

    function _selected(bytes32 salt) private view returns (DeployStocksBase.Ceremony memory) {
        return DeployStocksBase.Ceremony({
            deployer: vm.envAddress("REGENT_DEPLOYMENT_DEPLOYER"),
            startingNonce: vm.envUint("REGENT_DEPLOYMENT_STARTING_NONCE"),
            uerc20Factory: vm.envAddress("REGENT_DEPLOYMENT_UERC20_FACTORY"),
            hookSalt: salt,
            admissions: deployment.admissionsFromEnvironment()
        });
    }

    function _emitSelection(DeployStocksBase.Ceremony memory ceremony) private {
        DeployStocksBase.Graph memory graph = deployment.predict(ceremony);
        emit log_named_address("selection deployer", ceremony.deployer);
        emit log_named_uint("selection starting_nonce", ceremony.startingNonce);
        emit log_named_address("selection uerc20_factory", ceremony.uerc20Factory);
        emit log_named_bytes32("selection hook_salt", ceremony.hookSalt);
        emit log_named_address("selection predicted_launchpad", graph.launchpad);
        emit log_named_address("selection predicted_splitter_implementation", graph.splitterImplementation);
        emit log_named_address("selection predicted_locker", graph.locker);
        emit log_named_address("selection predicted_hook", graph.hook);
        emit log_named_address("selection predicted_bid_adapter", graph.bidAdapter);
        for (uint256 i; i < graph.routes.length; ++i) {
            emit log_named_address(string.concat("selection predicted_route_", vm.toString(i)), graph.routes[i]);
            emit log_named_address(string.concat("selection stock_", vm.toString(i)), ceremony.admissions[i].stock);
            emit log_named_address(string.concat("selection pool_", vm.toString(i)), ceremony.admissions[i].pool);
            emit log_named_address(string.concat("selection feed_", vm.toString(i)), ceremony.admissions[i].feed);
        }
    }
}
