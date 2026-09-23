// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {MaxBidPriceLib} from "continuous-clearing-auction/libraries/MaxBidPriceLib.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";
import {IRobinhoodLaunchpadBase} from "../src/interfaces/IRobinhoodLaunchpadBase.sol";
import {IRobinhoodStocksLaunchpadV1} from "../src/interfaces/IRobinhoodStocksLaunchpadV1.sol";
import {RobinhoodLaunchpadBase} from "../src/RobinhoodLaunchpadBase.sol";
import {RobinhoodMemestockSplitterV1} from "../src/RobinhoodMemestockSplitterV1.sol";
import {RobinhoodPreset} from "../src/RobinhoodPreset.sol";
import {RobinhoodStocksLaunchpadV1} from "../src/RobinhoodStocksLaunchpadV1.sol";
import {RobinhoodFixture} from "./RobinhoodFixture.sol";

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice The launchpad end to end: Safe-only admission, the fixed ten-minute start, a launch that
///         costs nothing, the launcher-chosen raise, creation, graduation into the official pool with
///         the launch's own splitter and both positions locked in the fee-only locker, and retirement.
contract RobinhoodLaunchpadsTest is RobinhoodFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deployRobinhood();
    }

    // -------------------------------------------------------------------------
    // Safe surface
    // -------------------------------------------------------------------------

    function test_admission_is_safe_only() public {
        assertEq(stocks.adminSafe(), safe);
        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodLaunchpadBase.NotSafe.selector, outsider));
        stocks.admitStock(STOCK_LOW, address(routeLow));
        vm.expectRevert(abi.encodeWithSelector(RobinhoodLaunchpadBase.NotSafe.selector, outsider));
        stocks.revokeStock(STOCK_LOW);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // launch terms
    // -------------------------------------------------------------------------

    function test_auction_opens_exactly_ten_minutes_after_the_creation_block() public {
        vm.roll(12_345_678);
        uint64 expectedStart = 12_345_678 + 6_000;
        assertEq(RobinhoodPreset.START_LEAD_BLOCKS, 6_000, "founder decision: ten minutes at 0.1 s blocks");
        uint64 expectedEnd = expectedStart + RobinhoodPreset.AUCTION_DURATION_BLOCKS;
        IRobinhoodStocksLaunchpadV1.LaunchParams memory params = _stockParams(STOCK_LOW);
        uint256 launchId = stocks.nextLaunchId();
        address predictedNew = uerc20Factory.getUERC20Address(
            params.core.name, params.core.symbol, StocksPreset.NEW_DECIMALS, address(stocks), bytes32(launchId)
        );

        // The start block is the creation block plus the lead, and the launch event carries it so a
        // wallet can show the exact opening block from the receipt.
        vm.expectEmit(true, true, true, false, address(stocks));
        emit IRobinhoodStocksLaunchpadV1.StockLaunchCreated(
            launchId,
            launcher,
            predictedNew,
            STOCK_LOW,
            address(0),
            expectedStart,
            expectedEnd,
            FLOOR_PRICE_Q96,
            STOCK_REQUIRED_RAISE,
            StocksPreset.AUCTION_INVENTORY,
            StocksPreset.MIGRATION_RESERVE
        );
        Launched memory l = _launchStockAs(launcher, params);
        IRobinhoodLaunchpadBase.Launch memory record = stocks.launches(l.launchId);
        assertEq(record.startBlock, expectedStart, "record: creation block + 6,000");
        assertEq(l.auction.startBlock(), expectedStart, "auction: creation block + 6,000");
        assertEq(record.endBlock, expectedEnd, "one day of 0.1 s blocks");
        assertEq(l.auction.endBlock(), expectedEnd);
        assertEq(record.claimBlock, expectedEnd + RobinhoodPreset.CLAIM_DELAY_BLOCKS);
        assertEq(l.auction.claimBlock(), expectedEnd + RobinhoodPreset.CLAIM_DELAY_BLOCKS);
        assertEq(record.migrationBlock, expectedEnd + RobinhoodPreset.MIGRATION_DELAY_BLOCKS);

        // Bidding is refused before the opening block and accepted on it.
        stockLow.mint(bidder, 1e18);
        vm.roll(expectedStart - 1);
        vm.expectRevert();
        vm.prank(bidder);
        l.auction.submitBid(_bidPrice(1), 1e18, bidder, FLOOR_PRICE_Q96, "");
        vm.roll(expectedStart);
        _bidDirect(l, bidder, 1e18, _bidPrice(1));

        // A later creation block opens later by the same lead.
        Launched memory later = _launchStock(STOCK_HIGH);
        assertEq(stocks.launches(later.launchId).startBlock, expectedStart + 6_000);
    }

    function test_launch_costs_no_usdg_and_needs_no_allowance() public {
        address penniless = makeAddr("penniless-launcher");
        assertEq(usdg.balanceOf(penniless), 0);
        assertEq(usdg.allowance(penniless, address(stocks)), 0);

        Launched memory l = _launchStockAs(penniless, _stockParams(STOCK_LOW));
        assertEq(stocks.launches(l.launchId).launcher, penniless);
        assertEq(usdg.balanceOf(penniless), 0, "nothing was pulled");
        assertEq(usdg.balanceOf(address(stocks)), 0, "the launchpad holds no USDG");
        assertEq(inbox.totalCollected(), 0, "the inbox received nothing");
        assertEq(usdg.balanceOf(address(inbox)), 0);

        // Both outcomes leave the launchpad and the inbox without a launch dollar.
        _graduateStock(l);
        Launched memory failed = _launchStockAs(penniless, _stockParams(STOCK_HIGH));
        _bidToMigration(failed, STOCK_REQUIRED_RAISE - 1);
        stocks.migrate(failed.launchId);
        assertEq(usdg.balanceOf(address(stocks)), 0);
        assertEq(inbox.totalCollected(), 0);
    }

    function test_required_raise_is_chosen_by_the_launcher_above_zero_and_within_reach() public {
        // Each launch records exactly the STOCK raise its launcher asked for, in that launch alone.
        Launched memory first = _launchStock(STOCK_LOW);
        assertEq(stocks.launches(first.launchId).requiredRaise, STOCK_REQUIRED_RAISE);
        IRobinhoodStocksLaunchpadV1.LaunchParams memory params = _stockParams(STOCK_HIGH);
        params.requiredStockRaised = 1;
        Launched memory smallest = _launchStockAs(launcher, params);
        assertEq(stocks.launches(smallest.launchId).requiredRaise, 1, "one base unit of STOCK is a valid raise");
        assertEq(stocks.launches(first.launchId).requiredRaise, STOCK_REQUIRED_RAISE, "the earlier launch is untouched");

        // Zero is refused: an auction that graduates on nothing raised is not a launch.
        params = _stockParams(STOCK_LOW);
        params.requiredStockRaised = 0;
        uint256 reachable = _maxReachableRaise();
        vm.expectRevert(abi.encodeWithSelector(RobinhoodLaunchpadBase.UnreachableRequiredRaise.selector, 0, reachable));
        vm.prank(launcher);
        stocks.launch(params);

        // A raise the fixed inventory cannot settle on is refused: the largest admissible raise is
        // the inventory at the highest on-grid price the pinned CCA admits
        // (`RobinhoodLaunchpadBase._maxReachableRaise`), capped at what the auction can carry.
        params.requiredStockRaised = uint128(reachable) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodLaunchpadBase.UnreachableRequiredRaise.selector, reachable + 1, reachable)
        );
        vm.prank(launcher);
        stocks.launch(params);

        params.requiredStockRaised = uint128(reachable);
        Launched memory largest = _launchStockAs(launcher, params);
        assertEq(stocks.launches(largest.launchId).requiredRaise, reachable, "the largest reachable raise is accepted");
    }

    function _maxReachableRaise() private view returns (uint256 reachable) {
        uint256 tickSpacing = stocks.bidTickSpacingFor(FLOOR_PRICE_Q96);
        uint256 maxBidPrice = MaxBidPriceLib.maxBidPrice(StocksPreset.AUCTION_INVENTORY);
        reachable = FullMath.mulDiv(
            StocksPreset.AUCTION_INVENTORY, maxBidPrice - (maxBidPrice % tickSpacing), FixedPoint96.Q96
        );
        if (reachable > type(uint128).max) reachable = type(uint128).max;
    }

    // -------------------------------------------------------------------------
    // stock-pair launches
    // -------------------------------------------------------------------------

    function test_stock_launch_requires_admission_and_records_the_launch() public {
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
