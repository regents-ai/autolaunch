// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {StockBidAdapterV1} from "../src/StockBidAdapterV1.sol";
import {StocksBindings} from "../src/StocksBindings.sol";
import {StocksFeeHookV1} from "../src/StocksFeeHookV1.sol";
import {StocksLaunchpadV1} from "../src/StocksLaunchpadV1.sol";
import {FixtureStockCatalog} from "../src/fixtures/FixtureStockCatalog.sol";
import {FixtureStockRoute} from "../src/routes/FixtureStockRoute.sol";

/// @title DeployStocksLab
/// @notice Deploys the Stocks graph onto the local Base-fork lab: the launchpad (which mines and
///         deploys its hook), the bid adapter and one fixed-price fixture route per catalog stock.
/// @dev LAB ONLY: refuses any chain but the local Anvil fork (31337). The fixture stock tokens are not
///      deployed here — their runtime code is installed at the catalog addresses by
///      `bin/local-stocks-lab.py` with `anvil_setCode` before this script runs, because those
///      addresses cannot be created by any transaction. The three inputs come from the controller's
///      environment: the unlocked deployer, the Agent lab's pinned UERC20 factory and its deployed
///      Agent strategy. Every deployed address is logged as `REGENT_STOCKS_LAB_<NAME>: 0x…`.
contract DeployStocksLab is Script {
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint256 internal constant LOCAL_CHAIN_ID = 31_337;

    string internal constant DEPLOYER_ENV = "REGENT_STOCKS_LAB_DEPLOYER";
    string internal constant UERC20_FACTORY_ENV = "REGENT_STOCKS_LAB_UERC20_FACTORY";
    string internal constant AGENT_STRATEGY_ENV = "REGENT_STOCKS_LAB_AGENT_STRATEGY";

    error WrongChain(uint256 expected, uint256 found);
    error FixtureNotInstalled(address stock);
    error LaunchpadAddressMismatch(address expected, address found);
    error HookAddressMismatch(address expected, address found);

    function run() external {
        if (block.chainid != LOCAL_CHAIN_ID) revert WrongChain(LOCAL_CHAIN_ID, block.chainid);
        address deployer = vm.envAddress(DEPLOYER_ENV);
        address uerc20Factory = vm.envAddress(UERC20_FACTORY_ENV);
        address agentStrategy = vm.envAddress(AGENT_STRATEGY_ENV);

        FixtureStockCatalog.Entry[13] memory catalog = FixtureStockCatalog.entries();
        for (uint256 i; i < catalog.length; ++i) {
            if (catalog[i].stock.code.length == 0) revert FixtureNotInstalled(catalog[i].stock);
        }

        address predictedLaunchpad = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        (address predictedHook, bytes32 hookSalt) = HookMiner.find(
            predictedLaunchpad,
            HOOK_FLAGS,
            type(StocksFeeHookV1).creationCode,
            abi.encode(StocksBindings.POOL_MANAGER, predictedLaunchpad)
        );

        vm.startBroadcast(deployer);
        StocksLaunchpadV1 launchpad = new StocksLaunchpadV1(uerc20Factory, agentStrategy, hookSalt);
        if (address(launchpad) != predictedLaunchpad) revert LaunchpadAddressMismatch(predictedLaunchpad, address(launchpad));
        if (launchpad.hook() != predictedHook) revert HookAddressMismatch(predictedHook, launchpad.hook());

        StockBidAdapterV1 adapter = new StockBidAdapterV1(address(launchpad));

        address[13] memory routes;
        for (uint256 i; i < catalog.length; ++i) {
            routes[i] = address(new FixtureStockRoute(catalog[i].stock, catalog[i].usdcPerShare));
        }
        vm.stopBroadcast();

        console2.log("REGENT_STOCKS_LAB_HOOK_SALT:", vm.toString(hookSalt));
        console2.log("REGENT_STOCKS_LAB_LAUNCHPAD:", address(launchpad));
        console2.log("REGENT_STOCKS_LAB_HOOK:", launchpad.hook());
        console2.log("REGENT_STOCKS_LAB_BID_ADAPTER:", address(adapter));
        for (uint256 i; i < catalog.length; ++i) {
            console2.log(string.concat("REGENT_STOCKS_LAB_ROUTE_", _upper(catalog[i].symbol), ":"), routes[i]);
        }
    }

    function _upper(string memory value) private pure returns (string memory) {
        bytes memory raw = bytes(value);
        for (uint256 i; i < raw.length; ++i) {
            if (raw[i] >= 0x61 && raw[i] <= 0x7a) raw[i] = bytes1(uint8(raw[i]) - 32);
        }
        return string(raw);
    }
}
