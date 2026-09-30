// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Test} from "forge-std/Test.sol";
import {DeployRobinhood} from "../script/DeployRobinhood.s.sol";
import {DeployRobinhoodBaseReceiver} from "../script/DeployRobinhoodBaseReceiver.s.sol";
import {RobinhoodFeeHookV1} from "../src/RobinhoodFeeHookV1.sol";

/// @notice The founder-selected ceremony values, derived once and compared ever after.
/// @dev Run only by the ceremony tool, with the selection in the environment: `prepare` supplies the
///      deployer, the nonce it read off the chain, the external bindings and the admissions, and this mines the hook
///      salt once; `render` and `rehearse` supply the committed salt too and re-derive the same
///      graph. The script imports no miner, so a broadcast can only consume a pinned salt. Nothing
///      here reaches a network.
contract DeploymentSelectionTest is Test {
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    DeployRobinhood internal deployment;
    DeployRobinhoodBaseReceiver internal receiverDeployment;

    function setUp() public {
        deployment = new DeployRobinhood();
        receiverDeployment = new DeployRobinhoodBaseReceiver();
    }

    /// @notice Preparation: mine the salt for the selected deployer and nonce, then emit the graph.
    function test_SelectionPrepareCandidate() public {
        DeployRobinhood.Ceremony memory ceremony = _selected(bytes32(0));
        address[] memory top = deployment.directAddresses(ceremony);
        (, ceremony.hookSalt) = HookMiner.find(
            top[3],
            HOOK_FLAGS,
            type(RobinhoodFeeHookV1).creationCode,
            abi.encode(
                ceremony.external_.poolManager, top[4], ceremony.external_.usdg, top[1], ceremony.external_.adminSafe
            )
        );
        _emitSelection(ceremony);
    }

    /// @notice Rendering and rehearsal: the same graph, re-derived from the committed values.
    function test_SelectionMatchesTheCommittedValues() public {
        _emitSelection(_selected(vm.envBytes32("REGENT_DEPLOYMENT_HOOK_SALT")));
    }

    /// @notice The Base-side receiver's prediction for the selected deployer and nonce.
    function test_BaseReceiverSelection() public {
        DeployRobinhoodBaseReceiver.Ceremony memory ceremony = DeployRobinhoodBaseReceiver.Ceremony({
            deployer: vm.envAddress("REGENT_DEPLOYMENT_DEPLOYER"),
            startingNonce: vm.envUint("REGENT_DEPLOYMENT_STARTING_NONCE"),
            baseSafe: vm.envAddress("REGENT_DEPLOYMENT_BASE_SAFE")
        });
        emit log_named_address("selection deployer", ceremony.deployer);
        emit log_named_uint("selection starting_nonce", ceremony.startingNonce);
        emit log_named_address("selection base_safe", ceremony.baseSafe);
        emit log_named_address("selection predicted_base_receiver", receiverDeployment.predict(ceremony));
    }

    function _selected(bytes32 salt) private view returns (DeployRobinhood.Ceremony memory) {
        return DeployRobinhood.Ceremony({
            deployer: vm.envAddress("REGENT_DEPLOYMENT_DEPLOYER"),
            startingNonce: vm.envUint("REGENT_DEPLOYMENT_STARTING_NONCE"),
            hookSalt: salt,
            external_: DeployRobinhood.External({
                usdg: vm.envAddress("REGENT_DEPLOYMENT_USDG"),
                ccaFactory: vm.envAddress("REGENT_DEPLOYMENT_CCA_FACTORY"),
                poolManager: vm.envAddress("REGENT_DEPLOYMENT_POOL_MANAGER"),
                positionManager: vm.envAddress("REGENT_DEPLOYMENT_POSITION_MANAGER"),
                permit2: vm.envAddress("REGENT_DEPLOYMENT_PERMIT2"),
                adminSafe: vm.envAddress("REGENT_DEPLOYMENT_ADMIN_SAFE")
            }),
            admissions: deployment.admissionsFromEnvironment()
        });
    }

    function _emitSelection(DeployRobinhood.Ceremony memory ceremony) private {
        DeployRobinhood.Graph memory graph = deployment.predict(ceremony);
        emit log_named_address("selection deployer", ceremony.deployer);
        emit log_named_uint("selection starting_nonce", ceremony.startingNonce);
        emit log_named_bytes32("selection hook_salt", ceremony.hookSalt);
        emit log_named_address("selection usdg", ceremony.external_.usdg);
        emit log_named_address("selection cca_factory", ceremony.external_.ccaFactory);
        emit log_named_address("selection pool_manager", ceremony.external_.poolManager);
        emit log_named_address("selection position_manager", ceremony.external_.positionManager);
        emit log_named_address("selection permit2", ceremony.external_.permit2);
        emit log_named_address("selection admin_safe", ceremony.external_.adminSafe);
        emit log_named_address("selection predicted_uerc20_factory", graph.uerc20Factory);
        emit log_named_address("selection predicted_inbox", graph.inbox);
        emit log_named_address("selection predicted_positions_lib", graph.positionsLib);
        emit log_named_address("selection predicted_hook_factory", graph.hookFactory);
        emit log_named_address("selection predicted_launchpad", graph.launchpad);
        emit log_named_address("selection predicted_bid_adapter", graph.bidAdapter);
        emit log_named_address("selection predicted_hook", graph.hook);
        emit log_named_address("selection predicted_splitter_implementation", graph.splitterImplementation);
        emit log_named_address("selection predicted_locker", graph.locker);
        for (uint256 i; i < graph.routes.length; ++i) {
            emit log_named_address(string.concat("selection predicted_route_", vm.toString(i)), graph.routes[i]);
            emit log_named_address(string.concat("selection stock_", vm.toString(i)), ceremony.admissions[i].stock);
            emit log_named_address(string.concat("selection pool_", vm.toString(i)), ceremony.admissions[i].pool);
            emit log_named_address(string.concat("selection feed_", vm.toString(i)), ceremony.admissions[i].feed);
        }
    }
}
