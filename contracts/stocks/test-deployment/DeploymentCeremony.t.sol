// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {DeployStocksBase} from "../script/DeployStocksBase.s.sol";
import {AerodromeStockRouteV1} from "../src/routes/AerodromeStockRouteV1.sol";
import {StockBidAdapterV1} from "../src/StockBidAdapterV1.sol";
import {StocksBindings} from "../src/StocksBindings.sol";
import {StocksFeeHookV1} from "../src/StocksFeeHookV1.sol";
import {StocksLaunchpadV1} from "../src/StocksLaunchpadV1.sol";
import {MockChainlinkFeed} from "../test/mocks/MockChainlinkFeed.sol";
import {MockSlipstreamPool} from "../test/mocks/MockSlipstreamPool.sol";
import {StocksFixture} from "../test/StocksFixture.sol";

/// @notice The Base Memestake ceremony's own evidence: the real `script/DeployStocksBase.s.sol`
///         run against a disposable deployer whose starting nonce is set explicitly, over the
///         hermetic Base bindings the Stocks fixture stands up at their frozen addresses.
/// @dev Nothing here needs a provider. The ceremony tool runs this suite offline before it renders a
///      packet and again, on a read-only fork, as the rehearsal's hermetic half. Mining happens in
///      `DeploymentSelection.t.sol`; here a salt is mined only to drive the script.
contract DeploymentCeremonyTest is StocksFixture {
    /// @dev A fixed hermetic deployer; the same account the Robinhood ceremony test uses.
    address internal constant TEST_DEPLOYER = 0xb82F93C62A4e9eCa6DAD667151Ba1a7232Bd6dbA;
    uint256 internal constant STARTING_NONCE = 7;

    DeployStocksBase internal deployment;
    MockSlipstreamPool internal pool;
    MockChainlinkFeed internal feed;

    function setUp() public {
        _deployStocks();
        deployment = new DeployStocksBase();
        pool = new MockSlipstreamPool(StocksBindings.USDC, STOCK_LOW, USDC_PER_SHARE);
        feed = new MockChainlinkFeed(8, 230e8, block.timestamp - 1 hours);
    }

    function test_predict_is_the_deployer_sequence_and_the_launchpad_creations() public view {
        DeployStocksBase.Ceremony memory ceremony = _ceremony(_mine());
        DeployStocksBase.Graph memory graph = deployment.predict(ceremony);

        assertEq(graph.launchpad, vm.computeCreateAddress(TEST_DEPLOYER, STARTING_NONCE), "launchpad");
        assertEq(graph.bidAdapter, vm.computeCreateAddress(TEST_DEPLOYER, STARTING_NONCE + 1), "adapter");
        assertEq(graph.routes.length, 1, "one route per admission");
        assertEq(graph.routes[0], vm.computeCreateAddress(TEST_DEPLOYER, STARTING_NONCE + 2), "route");
        assertEq(graph.splitterImplementation, vm.computeCreateAddress(graph.launchpad, 1), "splitter");
        assertEq(graph.locker, vm.computeCreateAddress(graph.launchpad, 2), "locker");
        assertEq(uint160(graph.hook) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS, "hook permission bits");
    }

    function test_execute_lands_every_creation_at_its_prediction() public {
        vm.setNonce(TEST_DEPLOYER, uint64(STARTING_NONCE));
        DeployStocksBase.Ceremony memory ceremony = _ceremony(_mine());
        DeployStocksBase.Graph memory predicted = deployment.predict(ceremony);

        DeployStocksBase.Graph memory graph = deployment.execute(ceremony);

        assertEq(graph.launchpad, predicted.launchpad, "launchpad");
        assertEq(graph.bidAdapter, predicted.bidAdapter, "adapter");
        assertEq(graph.routes[0], predicted.routes[0], "route");
        assertEq(graph.hook, predicted.hook, "hook");
        assertEq(graph.locker, predicted.locker, "locker");
        assertEq(graph.splitterImplementation, predicted.splitterImplementation, "splitter");
        assertEq(vm.getNonce(TEST_DEPLOYER), STARTING_NONCE + 3, "exactly three creations");

        StocksLaunchpadV1 created = StocksLaunchpadV1(graph.launchpad);
        assertTrue(created.launchesPaused(), "born paused");
        assertEq(created.hook(), graph.hook, "hook readback");
        assertEq(created.locker(), graph.locker, "locker readback");
        assertEq(created.splitterImplementation(), graph.splitterImplementation, "splitter readback");
        assertEq(address(StocksFeeHookV1(graph.hook).launchpad()), graph.launchpad, "hook bound to the launchpad");
        assertEq(address(StockBidAdapterV1(graph.bidAdapter).launchpad()), graph.launchpad, "adapter bound");
        assertEq(AerodromeStockRouteV1(graph.routes[0]).stock(), STOCK_LOW, "route stock");
        assertEq(address(AerodromeStockRouteV1(graph.routes[0]).pool()), address(pool), "route pool");
        assertEq(address(AerodromeStockRouteV1(graph.routes[0]).feed()), address(feed), "route feed");
    }

    function test_execute_refuses_a_deployer_whose_nonce_moved() public {
        vm.setNonce(TEST_DEPLOYER, uint64(STARTING_NONCE + 1));
        DeployStocksBase.Ceremony memory ceremony = _ceremony(_mine());
        vm.expectRevert(
            abi.encodeWithSelector(DeployStocksBase.DeployerNonceMismatch.selector, STARTING_NONCE, STARTING_NONCE + 1)
        );
        deployment.execute(ceremony);
    }

    function test_predict_refuses_a_salt_whose_hook_lacks_the_permission_bits() public {
        DeployStocksBase.Ceremony memory ceremony = _ceremony(bytes32(0));
        vm.expectPartialRevert(DeployStocksBase.HookSaltDoesNotCarryThePermissionBits.selector);
        deployment.predict(ceremony);
    }

    function test_predict_refuses_a_ceremony_without_admissions() public {
        DeployStocksBase.Ceremony memory ceremony = _ceremony(_mine());
        ceremony.admissions = new DeployStocksBase.Admission[](0);
        vm.expectRevert(DeployStocksBase.NoAdmissions.selector);
        deployment.predict(ceremony);
    }

    function test_admissions_come_from_three_equal_lists() public {
        vm.setEnv("REGENT_DEPLOYMENT_STOCKS", string.concat(vm.toString(STOCK_LOW), ",", vm.toString(STOCK_HIGH)));
        vm.setEnv("REGENT_DEPLOYMENT_POOLS", string.concat(vm.toString(address(pool)), ",", vm.toString(address(pool))));
        vm.setEnv("REGENT_DEPLOYMENT_FEEDS", string.concat(vm.toString(address(feed)), ",", vm.toString(address(feed))));
        DeployStocksBase.Admission[] memory admissions = deployment.admissionsFromEnvironment();
        assertEq(admissions.length, 2, "two admissions");
        assertEq(admissions[1].stock, STOCK_HIGH, "second stock");
        assertEq(admissions[1].pool, address(pool), "second pool");
        assertEq(admissions[1].feed, address(feed), "second feed");

        vm.setEnv("REGENT_DEPLOYMENT_FEEDS", vm.toString(address(feed)));
        vm.expectRevert(abi.encodeWithSelector(DeployStocksBase.AdmissionListsDiffer.selector, 2, 2, 1));
        deployment.admissionsFromEnvironment();
    }

    function _ceremony(bytes32 salt) internal view returns (DeployStocksBase.Ceremony memory ceremony) {
        DeployStocksBase.Admission[] memory admissions = new DeployStocksBase.Admission[](1);
        admissions[0] = DeployStocksBase.Admission({stock: STOCK_LOW, pool: address(pool), feed: address(feed)});
        ceremony = DeployStocksBase.Ceremony({
            deployer: TEST_DEPLOYER,
            startingNonce: STARTING_NONCE,
            uerc20Factory: address(uerc20Factory),
            hookSalt: salt,
            admissions: admissions
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
