// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {DeployRobinhood} from "../script/DeployRobinhood.s.sol";
import {DeployRobinhoodBaseReceiver} from "../script/DeployRobinhoodBaseReceiver.s.sol";
import {RobinhoodPositionsLib} from "../src/libraries/RobinhoodPositionsLib.sol";
import {RobinhoodBaseRevenueReceiverV1} from "../src/RobinhoodBaseRevenueReceiverV1.sol";
import {RobinhoodFeeHookFactory} from "../src/RobinhoodFeeHookFactory.sol";
import {RobinhoodFeeHookV1} from "../src/RobinhoodFeeHookV1.sol";
import {RobinhoodProtocolRevenueInboxV1} from "../src/RobinhoodProtocolRevenueInboxV1.sol";
import {RobinhoodStockBidAdapterV1} from "../src/RobinhoodStockBidAdapterV1.sol";
import {RobinhoodStocksLaunchpadV1} from "../src/RobinhoodStocksLaunchpadV1.sol";
import {UniswapV3StockRouteV1} from "../src/routes/UniswapV3StockRouteV1.sol";
import {MockUniswapV3Pool} from "../test/mocks/MockUniswapV3Pool.sol";
import {RobinhoodFixture} from "../test/RobinhoodFixture.sol";
import {StocksBindings} from "autolaunch-stocks/StocksBindings.sol";
import {MockLiveStaking} from "autolaunch-stocks-test/mocks/MockLiveStaking.sol";
import {MockChainlinkFeed} from "autolaunch-stocks-test/mocks/MockChainlinkFeed.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";

/// @notice The Robinhood ceremony's own evidence: the real `script/DeployRobinhood.s.sol` and
///         `script/DeployRobinhoodBaseReceiver.s.sol` run against a disposable deployer whose
///         starting nonce is set explicitly, over the pinned external contracts the Robinhood fixture
///         constructs in memory.
/// @dev The deployment profile links `RobinhoodPositionsLib` to the address this deployer's third
///      creation lands at from nonce zero, which is what lets the linked launchpad be created here
///      without a Foundry pre-deployment. A ceremony on the real chain pins the link on the command
///      line to its own prediction instead; the script proves the link before it creates anything.
contract DeploymentCeremonyTest is RobinhoodFixture {
    /// @dev A fixed hermetic deployer; the same account the Base Memestake ceremony test uses.
    address internal constant TEST_DEPLOYER = 0xb82F93C62A4e9eCa6DAD667151Ba1a7232Bd6dbA;
    uint256 internal constant STARTING_NONCE = 0;
    /// @dev `foundry.toml` `[profile.deployment].libraries` pins the library here: the deployer's
    ///      creation at nonce 2. Stated as a literal so a drift in either place fails.
    address internal constant PINNED_POSITIONS_LIB = 0x968fa82eb9898E7ED76bC36FA44dB539483cd7c6;

    DeployRobinhood internal deployment;
    DeployRobinhoodBaseReceiver internal receiverDeployment;
    MockUniswapV3Pool internal pool;
    MockChainlinkFeed internal feed;

    function setUp() public {
        _deployRobinhood();
        deployment = new DeployRobinhood();
        receiverDeployment = new DeployRobinhoodBaseReceiver();
        pool = new MockUniswapV3Pool(address(STOCK_LOW), USDG_ADDRESS, USDG_ADDRESS, USDG_PER_SHARE);
        feed = new MockChainlinkFeed(8, 230e8, block.timestamp - 1 hours);
    }

    function test_the_profile_pins_the_library_where_the_ceremony_creates_it() public pure {
        assertEq(address(RobinhoodPositionsLib), PINNED_POSITIONS_LIB, "profile link target");
        assertEq(vm.computeCreateAddress(TEST_DEPLOYER, STARTING_NONCE + 2), PINNED_POSITIONS_LIB, "third creation");
    }

    function test_predict_is_the_deployer_sequence_and_the_launchpad_creations() public view {
        DeployRobinhood.Ceremony memory ceremony = _ceremony(_mine());
        DeployRobinhood.Graph memory graph = deployment.predict(ceremony);

        assertEq(graph.uerc20Factory, vm.computeCreateAddress(TEST_DEPLOYER, STARTING_NONCE), "uerc20 factory");
        assertEq(graph.inbox, vm.computeCreateAddress(TEST_DEPLOYER, STARTING_NONCE + 1), "inbox");
        assertEq(graph.positionsLib, vm.computeCreateAddress(TEST_DEPLOYER, STARTING_NONCE + 2), "library");
        assertEq(graph.hookFactory, vm.computeCreateAddress(TEST_DEPLOYER, STARTING_NONCE + 3), "hook factory");
        assertEq(graph.launchpad, vm.computeCreateAddress(TEST_DEPLOYER, STARTING_NONCE + 4), "launchpad");
        assertEq(graph.bidAdapter, vm.computeCreateAddress(TEST_DEPLOYER, STARTING_NONCE + 5), "adapter");
        assertEq(graph.routes.length, 1, "one route per admission");
        assertEq(graph.routes[0], vm.computeCreateAddress(TEST_DEPLOYER, STARTING_NONCE + 6), "route");
        assertEq(graph.splitterImplementation, vm.computeCreateAddress(graph.launchpad, 1), "splitter");
        assertEq(graph.locker, vm.computeCreateAddress(graph.launchpad, 2), "locker");
        assertEq(uint160(graph.hook) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS, "hook permission bits");
    }

    function test_execute_lands_every_creation_at_its_prediction() public {
        DeployRobinhood.Ceremony memory ceremony = _ceremony(_mine());
        DeployRobinhood.Graph memory predicted = deployment.predict(ceremony);

        DeployRobinhood.Graph memory graph = deployment.execute(ceremony);

        assertEq(graph.uerc20Factory, predicted.uerc20Factory, "uerc20 factory");
        assertEq(graph.inbox, predicted.inbox, "inbox");
        assertEq(graph.positionsLib, predicted.positionsLib, "library");
        assertEq(graph.hookFactory, predicted.hookFactory, "hook factory");
        assertEq(graph.launchpad, predicted.launchpad, "launchpad");
        assertEq(graph.bidAdapter, predicted.bidAdapter, "adapter");
        assertEq(graph.hook, predicted.hook, "hook");
        assertEq(graph.splitterImplementation, predicted.splitterImplementation, "splitter");
        assertEq(graph.locker, predicted.locker, "locker");
        assertEq(graph.routes.length, 1, "one route per admission");
        assertEq(graph.routes[0], predicted.routes[0], "route");
        assertEq(vm.getNonce(TEST_DEPLOYER), STARTING_NONCE + 7, "exactly seven creations");

        assertEq(
            keccak256(graph.positionsLib.code), keccak256(type(RobinhoodPositionsLib).runtimeCode), "library bytes"
        );
        assertGt(graph.uerc20Factory.code.length, 0, "uerc20 factory bytes");

        RobinhoodStocksLaunchpadV1 created = RobinhoodStocksLaunchpadV1(graph.launchpad);
        assertTrue(created.launchesPaused(), "born paused");
        assertEq(created.adminSafe(), safe, "admin safe");
        assertEq(created.hook(), graph.hook, "hook readback");
        assertEq(created.locker(), graph.locker, "locker readback");
        assertEq(created.splitterImplementation(), graph.splitterImplementation, "splitter readback");
        assertEq(RobinhoodFeeHookV1(graph.hook).launchpad(), graph.launchpad, "hook bound to the launchpad");
        assertEq(RobinhoodFeeHookV1(graph.hook).inbox(), graph.inbox, "hook bound to the inbox");
        assertEq(RobinhoodFeeHookFactory(graph.hookFactory).poolManager(), address(poolManager), "factory pool manager");
        assertEq(RobinhoodProtocolRevenueInboxV1(graph.inbox).usdg(), USDG_ADDRESS, "inbox usdg");
        assertEq(RobinhoodProtocolRevenueInboxV1(graph.inbox).adminSafe(), safe, "inbox safe");
        assertEq(address(RobinhoodStockBidAdapterV1(graph.bidAdapter).launchpad()), graph.launchpad, "adapter bound");
        UniswapV3StockRouteV1 route = UniswapV3StockRouteV1(graph.routes[0]);
        assertEq(route.stock(), address(STOCK_LOW), "route stock");
        assertEq(route.usdg(), USDG_ADDRESS, "route usdg");
        assertEq(address(route.pool()), address(pool), "route pool");
        assertEq(address(route.feed()), address(feed), "route feed");
        assertTrue(route.stockIsToken0(), "the stock sorts first in this pool");
    }

    function test_predict_refuses_a_ceremony_without_admissions() public {
        DeployRobinhood.Ceremony memory ceremony = _ceremony(_mine());
        ceremony.admissions = new DeployRobinhood.Admission[](0);
        vm.expectRevert(DeployRobinhood.NoAdmissions.selector);
        deployment.predict(ceremony);
    }

    function test_admissions_come_from_three_equal_lists() public {
        vm.setEnv(
            "REGENT_DEPLOYMENT_STOCKS",
            string.concat(vm.toString(address(STOCK_LOW)), ",", vm.toString(address(STOCK_HIGH)))
        );
        vm.setEnv("REGENT_DEPLOYMENT_POOLS", string.concat(vm.toString(address(pool)), ",", vm.toString(address(pool))));
        vm.setEnv("REGENT_DEPLOYMENT_FEEDS", string.concat(vm.toString(address(feed)), ",", vm.toString(address(feed))));
        DeployRobinhood.Admission[] memory admissions = deployment.admissionsFromEnvironment();
        assertEq(admissions.length, 2, "two admissions");
        assertEq(admissions[1].stock, address(STOCK_HIGH), "second stock");
        assertEq(admissions[1].pool, address(pool), "second pool");
        assertEq(admissions[1].feed, address(feed), "second feed");

        vm.setEnv("REGENT_DEPLOYMENT_FEEDS", vm.toString(address(feed)));
        vm.expectRevert(abi.encodeWithSelector(DeployRobinhood.AdmissionListsDiffer.selector, 2, 2, 1));
        deployment.admissionsFromEnvironment();
    }

    function test_execute_refuses_a_deployer_whose_nonce_moved() public {
        vm.setNonce(TEST_DEPLOYER, uint64(STARTING_NONCE + 1));
        DeployRobinhood.Ceremony memory ceremony = _ceremony(_mine());
        vm.expectRevert(
            abi.encodeWithSelector(DeployRobinhood.DeployerNonceMismatch.selector, STARTING_NONCE, STARTING_NONCE + 1)
        );
        deployment.execute(ceremony);
    }

    function test_execute_refuses_a_link_that_is_not_the_predicted_library() public {
        DeployRobinhood.Ceremony memory ceremony = _ceremony(_mine());
        ceremony.startingNonce = STARTING_NONCE + 1;
        ceremony.hookSalt = _mineFor(ceremony);
        address expected = vm.computeCreateAddress(TEST_DEPLOYER, STARTING_NONCE + 3);
        vm.expectRevert(
            abi.encodeWithSelector(DeployRobinhood.LibraryLinkMismatch.selector, expected, PINNED_POSITIONS_LIB)
        );
        deployment.execute(ceremony);
    }

    function test_predict_refuses_a_salt_whose_hook_lacks_the_permission_bits() public {
        DeployRobinhood.Ceremony memory ceremony = _ceremony(bytes32(0));
        vm.expectPartialRevert(DeployRobinhood.HookSaltDoesNotCarryThePermissionBits.selector);
        deployment.predict(ceremony);
    }

    function test_base_receiver_lands_at_its_prediction_over_the_frozen_base_bindings() public {
        _constructAt(
            StocksBindings.USDC,
            abi.encodePacked(type(MockERC20).creationCode, abi.encode("USD Coin", "USDC", uint8(6)))
        );
        _constructAt(
            StocksBindings.LIVE_STAKING,
            abi.encodePacked(type(MockLiveStaking).creationCode, abi.encode(StocksBindings.USDC))
        );
        address baseSafe = makeAddr("base-safe");
        vm.setNonce(TEST_DEPLOYER, 9);
        DeployRobinhoodBaseReceiver.Ceremony memory ceremony =
            DeployRobinhoodBaseReceiver.Ceremony({deployer: TEST_DEPLOYER, startingNonce: 9, baseSafe: baseSafe});
        address predicted = receiverDeployment.predict(ceremony);
        assertEq(predicted, vm.computeCreateAddress(TEST_DEPLOYER, 9), "prediction");

        address receiver = receiverDeployment.execute(ceremony);

        assertEq(receiver, predicted, "receiver");
        assertEq(RobinhoodBaseRevenueReceiverV1(receiver).usdc(), StocksBindings.USDC, "usdc");
        assertEq(RobinhoodBaseRevenueReceiverV1(receiver).liveStaking(), StocksBindings.LIVE_STAKING, "staking");
        assertEq(RobinhoodBaseRevenueReceiverV1(receiver).baseSafe(), baseSafe, "base safe");
        assertEq(vm.getNonce(TEST_DEPLOYER), 10, "exactly one creation");
    }

    function _ceremony(bytes32 salt) internal view returns (DeployRobinhood.Ceremony memory) {
        DeployRobinhood.Admission[] memory admissions = new DeployRobinhood.Admission[](1);
        admissions[0] = DeployRobinhood.Admission({stock: address(STOCK_LOW), pool: address(pool), feed: address(feed)});
        return DeployRobinhood.Ceremony({
            deployer: TEST_DEPLOYER,
            startingNonce: STARTING_NONCE,
            hookSalt: salt,
            external_: DeployRobinhood.External({
                usdg: USDG_ADDRESS,
                ccaFactory: address(ccaFactory),
                poolManager: address(poolManager),
                positionManager: address(positionManager),
                permit2: PERMIT2,
                adminSafe: safe
            }),
            admissions: admissions
        });
    }

    function _mine() internal view returns (bytes32) {
        return _mineFor(_ceremony(bytes32(0)));
    }

    function _mineFor(DeployRobinhood.Ceremony memory ceremony) internal view returns (bytes32 salt) {
        address[] memory top = deployment.directAddresses(ceremony);
        (, salt) = HookMiner.find(
            top[3],
            HOOK_FLAGS,
            type(RobinhoodFeeHookV1).creationCode,
            abi.encode(address(poolManager), top[4], USDG_ADDRESS, top[1], safe)
        );
    }
}
