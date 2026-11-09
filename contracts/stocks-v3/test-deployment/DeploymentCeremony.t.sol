// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {DeployStocksV3} from "../script/DeployStocksV3.s.sol";
import {AerodromeStockRouteV2} from "../src/routes/AerodromeStockRouteV2.sol";
import {StockBidAdapterV1} from "../src/StockBidAdapterV1.sol";
import {StocksBindings} from "../src/StocksBindings.sol";
import {StocksFeeHookV1} from "../src/StocksFeeHookV1.sol";
import {StocksLaunchpadV3} from "../src/StocksLaunchpadV3.sol";
import {MockChainlinkFeed} from "../test/mocks/MockChainlinkFeed.sol";
import {MockSlipstreamPool} from "../test/mocks/MockSlipstreamPool.sol";
import {StocksFixture} from "../test/StocksFixture.sol";

/// @notice The Base Memestake version 3 ceremony's own evidence: the real
///         `script/DeployStocksV3.s.sol` run against a disposable deployer whose starting nonce is
///         set explicitly, over the hermetic Base bindings the Stocks fixture stands up at their
///         frozen addresses, and then the Safe's admission of a route version 2 already deployed.
/// @dev Nothing here needs a provider. The ceremony tool runs this suite offline before it renders a
///      packet. Mining happens in `DeploymentSelection.t.sol`; here a salt is mined only to drive the
///      script.
contract DeploymentCeremonyTest is StocksFixture {
    /// @dev A fixed hermetic deployer; the same account the version 2 ceremony test uses.
    address internal constant TEST_DEPLOYER = 0xb82F93C62A4e9eCa6DAD667151Ba1a7232Bd6dbA;
    uint256 internal constant STARTING_NONCE = 7;

    DeployStocksV3 internal deployment;
    AerodromeStockRouteV2 internal versionTwoRoute;

    function setUp() public {
        _deployStocks();
        deployment = new DeployStocksV3();
        // A route as version 2's ceremony created it, from another account, before this ceremony.
        MockSlipstreamPool pool = new MockSlipstreamPool(StocksBindings.USDC, STOCK_LOW, USDC_PER_SHARE);
        MockChainlinkFeed feed = new MockChainlinkFeed(8, 230e8, block.timestamp - 1 hours);
        vm.prank(makeAddr("stocks-v2-ceremony-deployer"));
        versionTwoRoute = new AerodromeStockRouteV2(STOCK_LOW, address(pool), address(feed));
    }

    function test_predict_is_the_deployer_sequence_and_the_launchpad_creations() public view {
        DeployStocksV3.Graph memory graph = deployment.predict(_ceremony(_mine()));

        assertEq(graph.launchpad, vm.computeCreateAddress(TEST_DEPLOYER, STARTING_NONCE), "launchpad");
        assertEq(graph.bidAdapter, vm.computeCreateAddress(TEST_DEPLOYER, STARTING_NONCE + 1), "adapter");
        assertEq(graph.splitterImplementation, vm.computeCreateAddress(graph.launchpad, 1), "splitter");
        assertEq(graph.locker, vm.computeCreateAddress(graph.launchpad, 2), "locker");
        assertEq(uint160(graph.hook) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS, "hook permission bits");
    }

    function test_execute_lands_every_creation_at_its_prediction() public {
        vm.setNonce(TEST_DEPLOYER, uint64(STARTING_NONCE));
        DeployStocksV3.Ceremony memory ceremony = _ceremony(_mine());
        DeployStocksV3.Graph memory predicted = deployment.predict(ceremony);

        DeployStocksV3.Graph memory graph = deployment.execute(ceremony);

        assertEq(abi.encode(graph), abi.encode(predicted), "the executed graph is not the predicted graph");
        assertEq(vm.getNonce(TEST_DEPLOYER), STARTING_NONCE + 2, "exactly two creations");
        assertEq(vm.getNonce(graph.launchpad), 4, "the launchpad made a creation the ceremony does not admit");

        StocksLaunchpadV3 created = StocksLaunchpadV3(graph.launchpad);
        assertTrue(created.launchesPaused(), "born paused");
        assertEq(created.hook(), graph.hook, "hook readback");
        assertEq(created.locker(), graph.locker, "locker readback");
        assertEq(created.splitterImplementation(), graph.splitterImplementation, "splitter readback");
        assertEq(address(StocksFeeHookV1(graph.hook).launchpad()), graph.launchpad, "hook bound to the launchpad");
        assertEq(address(StockBidAdapterV1(graph.bidAdapter).launchpad()), graph.launchpad, "adapter bound");
        (bool admitted,,) = created.stockAdmission(STOCK_LOW);
        assertFalse(admitted, "the ceremony admitted a stock");
    }

    /// @notice The Safe batch's one call shape: the frozen Safe admits a route version 2 deployed,
    ///         and the deployer cannot.
    function test_the_safe_admits_a_version_two_route_after_the_ceremony() public {
        vm.setNonce(TEST_DEPLOYER, uint64(STARTING_NONCE));
        StocksLaunchpadV3 created = StocksLaunchpadV3(deployment.execute(_ceremony(_mine())).launchpad);

        vm.prank(TEST_DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV3.NotGovernance.selector, TEST_DEPLOYER));
        created.admitStock(STOCK_LOW, address(versionTwoRoute));

        vm.prank(StocksBindings.GOVERNANCE_AND_REGENT_SAFE);
        created.admitStock(STOCK_LOW, address(versionTwoRoute));
        (bool admitted, uint8 decimals, address route) = created.stockAdmission(STOCK_LOW);
        assertTrue(admitted, "the Safe did not admit the stock");
        assertEq(decimals, stockLow.decimals(), "admitted decimals");
        assertEq(route, address(versionTwoRoute), "admitted route");

        vm.prank(StocksBindings.GOVERNANCE_AND_REGENT_SAFE);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV3.RouteBindingMismatch.selector, STOCK_HIGH, STOCK_LOW));
        created.admitStock(STOCK_HIGH, address(versionTwoRoute));
    }

    function test_execute_refuses_a_deployer_whose_nonce_moved() public {
        vm.setNonce(TEST_DEPLOYER, uint64(STARTING_NONCE + 1));
        DeployStocksV3.Ceremony memory ceremony = _ceremony(_mine());
        vm.expectRevert(
            abi.encodeWithSelector(DeployStocksV3.DeployerNonceMismatch.selector, STARTING_NONCE, STARTING_NONCE + 1)
        );
        deployment.execute(ceremony);
    }

    function test_predict_refuses_a_salt_whose_hook_lacks_the_permission_bits() public {
        DeployStocksV3.Ceremony memory ceremony = _ceremony(bytes32(0));
        vm.expectPartialRevert(DeployStocksV3.HookSaltDoesNotCarryThePermissionBits.selector);
        deployment.predict(ceremony);
    }

    function test_predict_refuses_an_unselected_deployer_or_factory() public {
        DeployStocksV3.Ceremony memory ceremony = _ceremony(_mine());
        ceremony.uerc20Factory = address(0);
        vm.expectRevert(DeployStocksV3.UnselectedUerc20Factory.selector);
        deployment.predict(ceremony);

        ceremony.deployer = address(0);
        vm.expectRevert(DeployStocksV3.UnselectedDeployer.selector);
        deployment.predict(ceremony);
    }

    function test_run_refuses_any_chain_but_base() public {
        vm.setEnv("REGENT_DEPLOYMENT_DEPLOYER", vm.toString(TEST_DEPLOYER));
        vm.setEnv("REGENT_DEPLOYMENT_STARTING_NONCE", vm.toString(STARTING_NONCE));
        vm.setEnv("REGENT_DEPLOYMENT_UERC20_FACTORY", vm.toString(address(uerc20Factory)));
        vm.setEnv("REGENT_DEPLOYMENT_HOOK_SALT", vm.toString(_mine()));
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployStocksV3.WrongChain.selector, 8453, 1));
        deployment.run();
    }

    function _ceremony(bytes32 salt) internal view returns (DeployStocksV3.Ceremony memory) {
        return DeployStocksV3.Ceremony({
            deployer: TEST_DEPLOYER,
            startingNonce: STARTING_NONCE,
            uerc20Factory: address(uerc20Factory),
            hookSalt: salt
        });
    }

    function _mine() internal view returns (bytes32 salt) {
        address predictedLaunchpad = vm.computeCreateAddress(TEST_DEPLOYER, STARTING_NONCE);
        (, salt) = HookMiner.find(
            predictedLaunchpad,
            HOOK_FLAGS,
            type(StocksFeeHookV1).creationCode,
            abi.encode(StocksBindings.POOL_MANAGER, predictedLaunchpad)
        );
    }
}
