// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";
import {IRobinhoodLaunchpadBase} from "../src/interfaces/IRobinhoodLaunchpadBase.sol";
import {IRobinhoodStocksLaunchpadV1} from "../src/interfaces/IRobinhoodStocksLaunchpadV1.sol";
import {RobinhoodLaunchpadBase} from "../src/RobinhoodLaunchpadBase.sol";
import {RobinhoodMemestockSplitterV1} from "../src/RobinhoodMemestockSplitterV1.sol";
import {RobinhoodStocksLaunchpadV1} from "../src/RobinhoodStocksLaunchpadV1.sol";
import {RobinhoodFixture} from "./RobinhoodFixture.sol";

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice The launchpad end to end: the Safe-only minimum and fee, the USDG launch fee into the inbox,
///         creation, graduation into the official pool with the launch's own splitter and both
///         positions locked in the fee-only locker, and retirement.
contract RobinhoodLaunchpadsTest is RobinhoodFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deployRobinhood();
    }

    // -------------------------------------------------------------------------
    // Safe surface
    // -------------------------------------------------------------------------

    function test_minimum_raise_is_born_at_the_founder_value_and_safe_settable() public {
        assertEq(stocks.minimumRaiseUsdg(), 1_000e6);
        assertEq(stocks.adminSafe(), safe);

        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodLaunchpadBase.NotSafe.selector, outsider));
        stocks.setMinimumRaiseUsdg(2_000e6);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodLaunchpadBase.NotSafe.selector, outsider));
        stocks.setLaunchFee(1);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodLaunchpadBase.NotSafe.selector, outsider));
        stocks.admitStock(STOCK_LOW, address(routeLow));
        vm.stopPrank();

        vm.startPrank(safe);
        vm.expectRevert(RobinhoodStocksLaunchpadV1.ZeroMinimumRaise.selector);
        stocks.setMinimumRaiseUsdg(0);
        stocks.setMinimumRaiseUsdg(2_000e6);
        vm.stopPrank();
        assertEq(stocks.minimumRaiseUsdg(), 2_000e6);
    }

    function test_launch_fee_is_usdg_deposited_into_the_inbox_with_exact_allowance() public {
        assertEq(stocks.launchFee(), 0);
        vm.prank(safe);
        stocks.setLaunchFee(50e6);

        IRobinhoodStocksLaunchpadV1.LaunchParams memory stale = _stockParams(STOCK_LOW);
        stale.core.expectedLaunchFee = 0;
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodLaunchpadBase.StaleLaunchFee.selector, 50e6, 0));
        stocks.launch(stale);

        IRobinhoodStocksLaunchpadV1.LaunchParams memory params = _stockParams(STOCK_LOW);
        usdg.mint(launcher, 50e6);
        vm.startPrank(launcher);
        usdg.approve(address(stocks), 60e6);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodLaunchpadBase.LaunchFeeAllowanceMismatch.selector, 50e6, 60e6));
        stocks.launch(params);
        usdg.approve(address(stocks), 50e6);
        (uint256 launchId,,) = stocks.launch(params);
        vm.stopPrank();

        assertEq(inbox.totalCollected(), 50e6);
        assertEq(usdg.balanceOf(address(inbox)), 50e6);
        assertEq(usdg.balanceOf(address(stocks)), 0);
        assertEq(usdg.balanceOf(launcher), 0);
        assertEq(launchId, 1);
    }

    // -------------------------------------------------------------------------
    // stock-pair launches
    // -------------------------------------------------------------------------

    function test_stock_launch_requires_admission_and_derives_the_raise_from_the_quote() public {
        MockERC20 unknown = new MockERC20("Unknown", "UNK", 8);
        IRobinhoodStocksLaunchpadV1.LaunchParams memory params = _stockParams(address(unknown));
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStocksLaunchpadV1.StockNotAdmitted.selector, address(unknown)));
        stocks.launch(params);

        Launched memory l = _launchStock(STOCK_LOW);
        IRobinhoodLaunchpadBase.Launch memory record = stocks.launches(l.launchId);
        assertEq(record.requiredRaise, STOCK_REQUIRED_RAISE);
        assertEq(record.currency, STOCK_LOW);
        assertEq(record.splitter, address(0));
        assertEq(l.auction.currency(), STOCK_LOW);
        assertEq(MockERC20(l.newToken).balanceOf(address(stocks)), StocksPreset.MIGRATION_RESERVE);
        assertEq(MockERC20(l.newToken).balanceOf(address(l.auction)), StocksPreset.AUCTION_INVENTORY);

        vm.prank(safe);
        stocks.setMinimumRaiseUsdg(2_000e6);
        Launched memory later = _launchStock(STOCK_HIGH);
        assertEq(stocks.launches(later.launchId).requiredRaise, 2_000e6 * 1e8 / USDG_PER_SHARE);
    }

    function test_usdg_can_never_be_admitted_as_a_stock() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStocksLaunchpadV1.StockRefused.selector, USDG_ADDRESS));
        stocks.admitStock(USDG_ADDRESS, address(routeLow));
    }

    function test_the_launchpad_deploys_its_own_locker_and_splitter_implementation() public view {
        assertEq(locker.launchpad(), address(stocks));
        assertEq(locker.positionManager(), address(positionManager));

        RobinhoodMemestockSplitterV1 implementation = RobinhoodMemestockSplitterV1(stocks.splitterImplementation());
        assertEq(implementation.usdg(), USDG_ADDRESS);
        assertEq(implementation.inbox(), address(inbox));
        assertEq(implementation.adminSafe(), safe);
        assertEq(implementation.memestock(), address(0));
    }

    function test_stock_graduation_creates_the_splitter_and_locks_both_positions_in_the_locker() public {
        Launched memory l = _launchStock(STOCK_HIGH);
        uint256 nextTokenId = positionManager.nextTokenId();
        _graduateStock(l);

        IRobinhoodLaunchpadBase.Launch memory record = stocks.launches(l.launchId);
        assertEq(uint8(record.lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Graduated));
        assertEq(record.poolId, _poolId(l, address(stocksHook)));
        assertEq(record.lpTokenId, nextTokenId);

        RobinhoodMemestockSplitterV1 splitter = RobinhoodMemestockSplitterV1(record.splitter);
        assertTrue(address(splitter) != address(0) && address(splitter) != stocks.splitterImplementation());
        assertEq(splitter.dollar(), USDG_ADDRESS);
        assertEq(splitter.memestock(), l.newToken);
        assertEq(splitter.stock(), STOCK_HIGH);
        assertEq(splitter.protocolTreasury(), safe);
        assertEq(stocksHook.pool(record.poolId).splitter, address(splitter));
        vm.expectRevert();
        splitter.initialize(l.newToken, STOCK_HIGH);

        assertEq(IERC721Owner(address(positionManager)).ownerOf(nextTokenId), address(locker));
        assertEq(locker.splitterOf(nextTokenId), address(splitter));
        IRobinhoodStocksLaunchpadV1.StockRecord memory stockRecord = stocks.stockRecords(l.launchId);
        assertEq(stockRecord.stockOnlyTokenId, nextTokenId + 1);
        assertEq(IERC721Owner(address(positionManager)).ownerOf(nextTokenId + 1), address(locker));
        assertEq(locker.splitterOf(nextTokenId + 1), address(splitter));
        assertGt(stockRecord.stockOnlyStock, 0);

        (uint160 sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(PoolId.wrap(record.poolId));
        assertEq(sqrtPriceX96, record.finalSqrtPriceX96);
        assertEq(MockERC20(l.newToken).balanceOf(address(stocks)), 0);
        assertEq(MockERC20(l.newToken).balanceOf(DEAD), record.retiredNew);
        assertEq(stockHigh.balanceOf(address(stocks)), 0);
        (uint256 protocolLane, uint256 stakerLane) = stocksHook.accrued(record.poolId);
        assertEq(stakerLane, 0);
        assertEq(protocolLane, stockHigh.balanceOf(address(stocksHook)));
    }

    function test_each_graduation_gets_its_own_splitter() public {
        Launched memory first = _launchStock(STOCK_LOW);
        _graduateStock(first);
        Launched memory second = _launchStock(STOCK_HIGH);
        _graduateStock(second);

        address firstSplitter = stocks.launches(first.launchId).splitter;
        address secondSplitter = stocks.launches(second.launchId).splitter;
        assertTrue(firstSplitter != secondSplitter);
        assertEq(RobinhoodMemestockSplitterV1(firstSplitter).stock(), STOCK_LOW);
        assertEq(RobinhoodMemestockSplitterV1(secondSplitter).stock(), STOCK_HIGH);
    }

    function test_stock_launch_that_misses_the_raise_retires_every_new() public {
        Launched memory l = _launchStock(STOCK_LOW);
        _bidToMigration(l, STOCK_REQUIRED_RAISE - 1);
        stocks.migrate(l.launchId);
        IRobinhoodLaunchpadBase.Launch memory record = stocks.launches(l.launchId);
        assertEq(uint8(record.lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Failed));
        assertEq(record.retiredNew, StocksPreset.INITIAL_SUPPLY);
        assertEq(MockERC20(l.newToken).balanceOf(DEAD), StocksPreset.INITIAL_SUPPLY);
        assertEq(record.poolId, bytes32(0));
        assertEq(record.splitter, address(0));
    }

    function test_migration_waits_for_the_migration_block() public {
        Launched memory l = _launchStock(STOCK_LOW);
        _rollToStart(l);
        vm.expectRevert(
            abi.encodeWithSelector(
                RobinhoodLaunchpadBase.MigrationNotYetAllowed.selector,
                stocks.launches(l.launchId).migrationBlock,
                block.number
            )
        );
        stocks.migrate(l.launchId);
    }
}
