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
import {FixtureUsdgStockRoute} from "../src/fixtures/FixtureUsdgStockRoute.sol";
import {RobinhoodFeeHookFactory} from "../src/RobinhoodFeeHookFactory.sol";
import {RobinhoodFeeHookV1} from "../src/RobinhoodFeeHookV1.sol";
import {RobinhoodLaunchpadBase} from "../src/RobinhoodLaunchpadBase.sol";
import {RobinhoodProtocolRevenueInboxV1} from "../src/RobinhoodProtocolRevenueInboxV1.sol";
import {RobinhoodStockBidAdapterV1} from "../src/RobinhoodStockBidAdapterV1.sol";
import {RobinhoodStocksLaunchpadV1} from "../src/RobinhoodStocksLaunchpadV1.sol";

/// @title DeployRobinhoodLab
/// @notice Deploys the Robinhood launch graph onto a blank local Anvil chain: a mintable USDG
///         double, the real PoolManager, CCA factory, PositionManager and UERC20 factory from their
///         pinned sources, the protocol revenue inbox, the hook factory, the Stocks launchpad (which
///         mines and deploys its own hook, LP locker and splitter implementation), the USDG bid
///         adapter, and one mintable fixture stock with a fixed-price USDG route per catalog entry,
///         admitted on the launchpad. The unlocked deployer stands in for the admin safe and the hook executor.
/// @dev LAB ONLY: refuses any chain but the local Robinhood lab (31338). Permit2 cannot be compiled
///      under this build (it pins solc 0.8.17), so `bin/local-robinhood-lab.py` installs its runtime
///      code at the canonical address with `anvil_setCode` before this script runs. Every deployed
///      address is logged as `REGENT_ROBINHOOD_LAB_<NAME>: 0x…`; the fixture stocks and their routes
///      as `REGENT_ROBINHOOD_LAB_STOCK_<SYMBOL>` and `REGENT_ROBINHOOD_LAB_ROUTE_<SYMBOL>`.
contract DeployRobinhoodLab is Script {
    /// @dev A lab stock: display name and symbol for the mintable double, and the fixed USDG price
    ///      (six decimals) per whole share the route quotes. Fixture data only.
    struct CatalogEntry {
        string name;
        string symbol;
        uint256 usdgPerShare;
    }

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint256 internal constant LOCAL_CHAIN_ID = 31_338;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    string internal constant DEPLOYER_ENV = "REGENT_ROBINHOOD_LAB_DEPLOYER";
    uint8 internal constant STOCK_DECIMALS = 8;
    uint256 internal constant CATALOG_SIZE = 13;
    /// @dev Route inventory: one million shares and one billion USDG per route.
    uint256 internal constant ROUTE_STOCK_INVENTORY = 1_000_000e8;
    uint256 internal constant ROUTE_USDG_INVENTORY = 1_000_000_000e6;

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
        (address predictedStocksHook, bytes32 stocksHookSalt) = _mineHookSalt(bindings, predictedLaunchpad);
        RobinhoodStocksLaunchpadV1 stocks = new RobinhoodStocksLaunchpadV1(bindings, stocksHookSalt);
        if (address(stocks) != predictedLaunchpad) {
            revert LaunchpadAddressMismatch(predictedLaunchpad, address(stocks));
        }
        if (stocks.hook() != predictedStocksHook) revert HookAddressMismatch(predictedStocksHook, stocks.hook());
        RobinhoodStockBidAdapterV1 adapter = new RobinhoodStockBidAdapterV1(address(stocks), PERMIT2);

        CatalogEntry[CATALOG_SIZE] memory catalog = _catalog();
        address[CATALOG_SIZE] memory stockTokens;
        address[CATALOG_SIZE] memory routes;
        for (uint256 i; i < CATALOG_SIZE; ++i) {
            MockERC20 stock = new MockERC20(catalog[i].name, catalog[i].symbol, STOCK_DECIMALS);
            FixtureUsdgStockRoute route =
                new FixtureUsdgStockRoute(address(stock), address(usdg), catalog[i].usdgPerShare);
            stock.mint(address(route), ROUTE_STOCK_INVENTORY);
            usdg.mint(address(route), ROUTE_USDG_INVENTORY);
            stocks.admitStock(address(stock), address(route));
            stockTokens[i] = address(stock);
            routes[i] = address(route);
        }
        RobinhoodFeeHookV1(stocks.hook()).setExecutor(deployer);
        stocks.unpauseLaunches();
        vm.stopBroadcast();

        console2.log("REGENT_ROBINHOOD_LAB_STOCKS_HOOK_SALT:", vm.toString(stocksHookSalt));
        console2.log("REGENT_ROBINHOOD_LAB_STOCKS_LAUNCHPAD:", address(stocks));
        console2.log("REGENT_ROBINHOOD_LAB_STOCKS_HOOK:", stocks.hook());
        console2.log("REGENT_ROBINHOOD_LAB_STOCKS_LOCKER:", stocks.locker());
        console2.log("REGENT_ROBINHOOD_LAB_STOCKS_SPLITTER_IMPLEMENTATION:", stocks.splitterImplementation());
        console2.log("REGENT_ROBINHOOD_LAB_BID_ADAPTER:", address(adapter));
        console2.log("REGENT_ROBINHOOD_LAB_USDG:", address(usdg));
        console2.log("REGENT_ROBINHOOD_LAB_INBOX:", address(inbox));
        console2.log("REGENT_ROBINHOOD_LAB_HOOK_FACTORY:", address(hookFactory));
        console2.log("REGENT_ROBINHOOD_LAB_POOL_MANAGER:", address(poolManager));
        console2.log("REGENT_ROBINHOOD_LAB_POSITION_MANAGER:", address(positionManager));
        console2.log("REGENT_ROBINHOOD_LAB_CCA_FACTORY:", address(ccaFactory));
        console2.log("REGENT_ROBINHOOD_LAB_UERC20_FACTORY:", address(uerc20Factory));
        console2.log("REGENT_ROBINHOOD_LAB_PERMIT2:", PERMIT2);
        console2.log("REGENT_ROBINHOOD_LAB_ADMIN_SAFE:", deployer);
        for (uint256 i; i < CATALOG_SIZE; ++i) {
            string memory symbol = _upper(catalog[i].symbol);
            console2.log(string.concat("REGENT_ROBINHOOD_LAB_STOCK_", symbol, ":"), stockTokens[i]);
            console2.log(string.concat("REGENT_ROBINHOOD_LAB_ROUTE_", symbol, ":"), routes[i]);
        }
    }

    function _mineHookSalt(RobinhoodLaunchpadBase.Bindings memory bindings, address predictedLaunchpad)
        private
        view
        returns (address predictedHook, bytes32 salt)
    {
        return HookMiner.find(
            bindings.hookFactory,
            HOOK_FLAGS,
            type(RobinhoodFeeHookV1).creationCode,
            abi.encode(bindings.poolManager, predictedLaunchpad, bindings.usdg, bindings.inbox, bindings.adminSafe)
        );
    }

    /// @dev The same thirteen symbols and fixture prices as the Base Stocks lab catalog
    ///      (`contracts/stocks/src/fixtures/FixtureStockCatalog.sol`), as mintable doubles on the
    ///      Robinhood chain where no admitted stock token exists yet.
    function _catalog() private pure returns (CatalogEntry[CATALOG_SIZE] memory list) {
        list[0] = CatalogEntry("Apple", "AAPLc", 230_000000);
        list[1] = CatalogEntry("Amazon", "AMZNc", 220_000000);
        list[2] = CatalogEntry("Coinbase", "COINc", 300_000000);
        list[3] = CatalogEntry("Circle", "CRCLc", 150_000000);
        list[4] = CatalogEntry("Alphabet", "GOOGLc", 180_000000);
        list[5] = CatalogEntry("Intel", "INTCc", 30_000000);
        list[6] = CatalogEntry("Meta", "METAc", 700_000000);
        list[7] = CatalogEntry("Microsoft", "MSFTc", 500_000000);
        list[8] = CatalogEntry("Strategy", "MSTRc", 350_000000);
        list[9] = CatalogEntry("NVIDIA", "NVDAc", 170_000000);
        list[10] = CatalogEntry("Sandisk", "SNDKc", 60_000000);
        list[11] = CatalogEntry("SpaceX", "SPCXc", 100_000000);
        list[12] = CatalogEntry("Tesla", "TSLAc", 400_000000);
    }

    function _upper(string memory value) private pure returns (string memory) {
        bytes memory raw = bytes(value);
        for (uint256 i; i < raw.length; ++i) {
            if (raw[i] >= 0x61 && raw[i] <= 0x7a) raw[i] = bytes1(uint8(raw[i]) - 32);
        }
        return string(raw);
    }
}
