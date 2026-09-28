// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ConstantsLib} from "continuous-clearing-auction/libraries/ConstantsLib.sol";
import {MaxBidPriceLib} from "continuous-clearing-auction/libraries/MaxBidPriceLib.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";
import {IRobinhoodLaunchpadBase} from "../src/interfaces/IRobinhoodLaunchpadBase.sol";
import {IRobinhoodStocksLaunchpadV2} from "../src/interfaces/IRobinhoodStocksLaunchpadV2.sol";
import {RobinhoodLaunchpadBase} from "../src/RobinhoodLaunchpadBase.sol";
import {RobinhoodMemestockSplitterV1} from "../src/RobinhoodMemestockSplitterV1.sol";
import {RobinhoodPreset} from "../src/RobinhoodPreset.sol";
import {RobinhoodStocksLaunchpadV2} from "../src/RobinhoodStocksLaunchpadV2.sol";
import {RobinhoodFixture} from "./RobinhoodFixture.sol";

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice The launchpad end to end: Safe-only admission, the fixed ten-minute start, a launch that
///         costs nothing, the raise the floor sets, creation, graduation into the official pool with
///         the launch's own splitter and one full-range position locked in the fee-only locker, and
///         retirement. The graduation arithmetic and the leftover NEW are proved in
///         `RobinhoodLaunchpadMigrateTest`.
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
        IRobinhoodStocksLaunchpadV2.LaunchParams memory params = _stockParams(STOCK_LOW);
        uint256 launchId = stocks.nextLaunchId();
        address predictedNew = uerc20Factory.getUERC20Address(
            params.core.name, params.core.symbol, StocksPreset.NEW_DECIMALS, address(stocks), bytes32(launchId)
        );

        // The start block is the creation block plus the lead, and the launch event carries it so a
        // wallet can show the exact opening block from the receipt.
        vm.expectEmit(true, true, true, false, address(stocks));
        emit IRobinhoodStocksLaunchpadV2.StockLaunchCreated(
            launchId,
            launcher,
            predictedNew,
            STOCK_LOW,
            address(0),
            expectedStart,
            expectedEnd,
            FLOOR_PRICE_Q96,
            REQUIRED_RAISE,
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
        _bidToMigration(failed, REQUIRED_RAISE - 1);
        stocks.migrate(failed.launchId);
        assertEq(usdg.balanceOf(address(stocks)), 0);
        assertEq(inbox.totalCollected(), 0);
    }

    function test_required_raise_is_the_sale_allocation_at_the_floor_rounded_up() public {
        // The fixture floor: 500,000,000 NEW at about 1e-8 STOCK base units each. The floor was rounded
        // down to the grid, so the exact product falls just short of five shares and rounds up to
        // exactly five. The migration tests prove the auction applies it.
        assertEq(stocks.requiredStockRaisedFor(FLOOR_PRICE_Q96), REQUIRED_RAISE);
        assertLt(
            FullMath.mulDiv(StocksPreset.AUCTION_INVENTORY, FLOOR_PRICE_Q96, FixedPoint96.Q96),
            REQUIRED_RAISE,
            "the exact product is fractional and rounds up"
        );

        // Each launch records the raise its own floor sets; the launcher does not choose it.
        Launched memory first = _launchStock(STOCK_LOW);
        assertEq(_record(first).requiredRaise, REQUIRED_RAISE);
        IRobinhoodStocksLaunchpadV2.LaunchParams memory params = _stockParams(STOCK_HIGH);
        params.core.floorPriceQ96 = FLOOR_PRICE_Q96 * 10;
        Launched memory higher = _launchStockAs(launcher, params);
        assertEq(_record(higher).requiredRaise, stocks.requiredStockRaisedFor(FLOOR_PRICE_Q96 * 10));
        assertEq(_record(first).requiredRaise, REQUIRED_RAISE, "the earlier launch is untouched");
    }

    function testFuzz_required_raise_is_never_zero_and_never_below_the_floor_value(uint256 floorHundredths)
        public
        view
    {
        uint256 maxBidPrice = MaxBidPriceLib.maxBidPrice(StocksPreset.AUCTION_INVENTORY);
        floorHundredths = bound(floorHundredths, ConstantsLib.MIN_FLOOR_PRICE / 100 + 1, maxBidPrice / 100);
        uint256 floor = floorHundredths * 100;
        uint256 required = stocks.requiredStockRaisedFor(floor);
        uint256 exact = FullMath.mulDiv(StocksPreset.AUCTION_INVENTORY, floor, FixedPoint96.Q96);
        assertGe(required, 1, "an auction nobody bid in never graduates");
        assertGe(required, exact, "never below the sale allocation at the floor");
        assertLe(required, exact + 1, "rounded up by at most one base unit");
    }

    // -------------------------------------------------------------------------
    // stock-pair launches
    // -------------------------------------------------------------------------

    function test_stock_launch_requires_admission_and_records_the_launch() public {
        MockERC20 unknown = new MockERC20("Unknown", "UNK", 8);
        IRobinhoodStocksLaunchpadV2.LaunchParams memory params = _stockParams(address(unknown));
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStocksLaunchpadV2.StockNotAdmitted.selector, address(unknown)));
        stocks.launch(params);

        Launched memory l = _launchStock(STOCK_LOW);
        IRobinhoodLaunchpadBase.Launch memory record = stocks.launches(l.launchId);
        assertEq(record.requiredRaise, REQUIRED_RAISE);
        assertEq(record.currency, STOCK_LOW);
        assertEq(record.splitter, address(0));
        assertEq(l.auction.currency(), STOCK_LOW);
        assertEq(MockERC20(l.newToken).balanceOf(address(stocks)), StocksPreset.MIGRATION_RESERVE);
        assertEq(MockERC20(l.newToken).balanceOf(address(l.auction)), StocksPreset.AUCTION_INVENTORY);
    }

    function test_usdg_can_never_be_admitted_as_a_stock() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStocksLaunchpadV2.StockRefused.selector, USDG_ADDRESS));
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

    function test_stock_graduation_creates_the_splitter_and_locks_one_position_in_the_locker() public {
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
        assertEq(positionManager.nextTokenId(), nextTokenId + 1, "exactly one position");

        (uint160 sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(PoolId.wrap(record.poolId));
        assertEq(sqrtPriceX96, record.finalSqrtPriceX96);
        assertEq(MockERC20(l.newToken).balanceOf(address(stocks)), 0, "the launchpad keeps no NEW");
        assertEq(MockERC20(l.newToken).balanceOf(DEAD), record.retiredNew, "the leftover NEW is retired");
        assertEq(stockHigh.balanceOf(address(stocks)), 0);
        (uint256 creatorLane, uint256 protocolLane, uint256 stakerLane) = stocksHook.accrued(record.poolId);
        assertEq(creatorLane, 0);
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
        _bidToMigration(l, REQUIRED_RAISE - 1);
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
