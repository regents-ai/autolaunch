// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ContinuousClearingAuctionFactory} from "continuous-clearing-auction/ContinuousClearingAuctionFactory.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {UERC20Factory} from "uerc20-factory/factories/UERC20Factory.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {RobinhoodFeeHookFactory} from "../src/RobinhoodFeeHookFactory.sol";
import {RobinhoodFeeHookV1} from "../src/RobinhoodFeeHookV1.sol";
import {RobinhoodLaunchpadBase} from "../src/RobinhoodLaunchpadBase.sol";
import {RobinhoodProtocolRevenueInboxV1} from "../src/RobinhoodProtocolRevenueInboxV1.sol";
import {RobinhoodRevshareLaunchpadV1} from "../src/RobinhoodRevshareLaunchpadV1.sol";

/// @title DeployRobinhoodLab
/// @notice Deploys the whole Revshare graph onto a blank local Anvil chain: a mintable USDG double,
///         the real PoolManager, CCA factory, PositionManager and UERC20 factory from their pinned
///         sources, the protocol revenue inbox, the hook factory and the Revshare launchpad (which
///         mines and deploys its hook). The unlocked deployer stands in for the admin safe.
/// @dev LAB ONLY: refuses any chain but the local Robinhood lab (31338). Permit2 cannot be compiled
///      under this build (it pins solc 0.8.17), so `bin/local-robinhood-lab.py` installs its runtime
///      code at the canonical address with `anvil_setCode` before this script runs. Every deployed
///      address is logged as `REGENT_ROBINHOOD_LAB_<NAME>: 0x…`.
contract DeployRobinhoodLab is Script {
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint256 internal constant LOCAL_CHAIN_ID = 31_338;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    string internal constant DEPLOYER_ENV = "REGENT_ROBINHOOD_LAB_DEPLOYER";

    error WrongChain(uint256 expected, uint256 found);
    error Permit2NotInstalled();
    error LaunchpadAddressMismatch(address expected, address found);
    error HookAddressMismatch(address expected, address found);

    function run() external {
        if (block.chainid != LOCAL_CHAIN_ID) revert WrongChain(LOCAL_CHAIN_ID, block.chainid);
        if (PERMIT2.code.length == 0) revert Permit2NotInstalled();
        address deployer = vm.envAddress(DEPLOYER_ENV);

        vm.startBroadcast(deployer);
        MockERC20 usdg = new MockERC20("Global Dollar", "USDG", 6);
        PoolManager poolManager = new PoolManager(deployer);
        ContinuousClearingAuctionFactory ccaFactory = new ContinuousClearingAuctionFactory(address(0));
        PositionManager positionManager = new PositionManager(
            IPoolManager(address(poolManager)),
            IAllowanceTransfer(PERMIT2),
            300_000,
            IPositionDescriptor(address(0)),
            IWETH9(payable(address(0)))
        );
        UERC20Factory uerc20Factory = new UERC20Factory();
        RobinhoodProtocolRevenueInboxV1 inbox = new RobinhoodProtocolRevenueInboxV1(address(usdg), deployer);
        RobinhoodFeeHookFactory hookFactory = new RobinhoodFeeHookFactory(address(poolManager));

        RobinhoodLaunchpadBase.Bindings memory bindings = RobinhoodLaunchpadBase.Bindings({
            uerc20Factory: address(uerc20Factory),
            ccaFactory: address(ccaFactory),
            poolManager: address(poolManager),
            positionManager: address(positionManager),
            hookFactory: address(hookFactory),
            usdg: address(usdg),
            inbox: address(inbox),
            adminSafe: deployer
        });

        address predictedLaunchpad = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        (address predictedHook, bytes32 hookSalt) = HookMiner.find(
            address(hookFactory),
            HOOK_FLAGS,
            type(RobinhoodFeeHookV1).creationCode,
            abi.encode(address(poolManager), predictedLaunchpad, address(usdg), address(inbox), deployer)
        );
        RobinhoodRevshareLaunchpadV1 launchpad = new RobinhoodRevshareLaunchpadV1(bindings, hookSalt);
        if (address(launchpad) != predictedLaunchpad) {
            revert LaunchpadAddressMismatch(predictedLaunchpad, address(launchpad));
        }
        if (launchpad.hook() != predictedHook) revert HookAddressMismatch(predictedHook, launchpad.hook());
        launchpad.unpauseLaunches();
        vm.stopBroadcast();

        console2.log("REGENT_ROBINHOOD_LAB_HOOK_SALT:", vm.toString(hookSalt));
        console2.log("REGENT_ROBINHOOD_LAB_LAUNCHPAD:", address(launchpad));
        console2.log("REGENT_ROBINHOOD_LAB_HOOK:", launchpad.hook());
        console2.log("REGENT_ROBINHOOD_LAB_USDG:", address(usdg));
        console2.log("REGENT_ROBINHOOD_LAB_INBOX:", address(inbox));
        console2.log("REGENT_ROBINHOOD_LAB_HOOK_FACTORY:", address(hookFactory));
        console2.log("REGENT_ROBINHOOD_LAB_POOL_MANAGER:", address(poolManager));
        console2.log("REGENT_ROBINHOOD_LAB_POSITION_MANAGER:", address(positionManager));
        console2.log("REGENT_ROBINHOOD_LAB_CCA_FACTORY:", address(ccaFactory));
        console2.log("REGENT_ROBINHOOD_LAB_UERC20_FACTORY:", address(uerc20Factory));
        console2.log("REGENT_ROBINHOOD_LAB_PERMIT2:", PERMIT2);
        console2.log("REGENT_ROBINHOOD_LAB_ADMIN_SAFE:", deployer);
    }
}
