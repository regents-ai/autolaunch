// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";
import {IRobinhoodLaunchpadBase} from "../src/interfaces/IRobinhoodLaunchpadBase.sol";
import {IRobinhoodRevshareLaunchpadV1} from "../src/interfaces/IRobinhoodRevshareLaunchpadV1.sol";
import {IRobinhoodStocksLaunchpadV1} from "../src/interfaces/IRobinhoodStocksLaunchpadV1.sol";
import {RobinhoodLaunchpadBase} from "../src/RobinhoodLaunchpadBase.sol";
import {RobinhoodPreset} from "../src/RobinhoodPreset.sol";
import {RobinhoodRevshareLaunchpadV1} from "../src/RobinhoodRevshareLaunchpadV1.sol";
import {RobinhoodStocksLaunchpadV1} from "../src/RobinhoodStocksLaunchpadV1.sol";
import {RobinhoodSubjectSplitterV1} from "../src/RobinhoodSubjectSplitterV1.sol";
import {RobinhoodFixture} from "./RobinhoodFixture.sol";

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

contract SplitterStub {
    address public immutable subject;

    constructor(address subject_) {
        subject = subject_;
    }
}

/// @notice Both launchpads end to end: Safe-only minimums and fees, the USDG launch fee into the inbox,
///         creation, graduation into the official pool, retirement, the revenue-share splitter and
///         vesting, and splitter provenance for stock-pair launches.
contract RobinhoodLaunchpadsTest is RobinhoodFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deployRobinhood();
    }

    // -------------------------------------------------------------------------
    // Safe surface
    // -------------------------------------------------------------------------

    function test_minimum_raises_are_born_at_the_founder_values_and_safe_settable() public {
        assertEq(stocks.minimumRaiseUsdg(), 1_000e6);
        assertEq(revshare.minimumRaiseUsdg(), 5_000e6);
        assertEq(stocks.adminSafe(), safe);
        assertEq(revshare.adminSafe(), safe);

        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodLaunchpadBase.NotSafe.selector, outsider));
        stocks.setMinimumRaiseUsdg(2_000e6);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodLaunchpadBase.NotSafe.selector, outsider));
        revshare.setMinimumRaiseUsdg(2_000e6);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodLaunchpadBase.NotSafe.selector, outsider));
        stocks.setLaunchFee(1);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodLaunchpadBase.NotSafe.selector, outsider));
        stocks.admitStock(STOCK_LOW, address(routeLow));
        vm.stopPrank();

        vm.startPrank(safe);
        vm.expectRevert(RobinhoodStocksLaunchpadV1.ZeroMinimumRaise.selector);
        stocks.setMinimumRaiseUsdg(0);
        vm.expectRevert(RobinhoodRevshareLaunchpadV1.ZeroMinimumRaise.selector);
        revshare.setMinimumRaiseUsdg(0);
        stocks.setMinimumRaiseUsdg(2_000e6);
        revshare.setMinimumRaiseUsdg(7_000e6);
        vm.stopPrank();
        assertEq(stocks.minimumRaiseUsdg(), 2_000e6);
        assertEq(revshare.minimumRaiseUsdg(), 7_000e6);
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

    function test_stock_graduation_locks_both_positions_and_credits_dust_to_the_protocol_bucket() public {
        Launched memory l = _launchStock(STOCK_HIGH);
        uint256 nextTokenId = positionManager.nextTokenId();
        _graduateStock(l);

        IRobinhoodLaunchpadBase.Launch memory record = stocks.launches(l.launchId);
        assertEq(uint8(record.lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Graduated));
        assertEq(record.poolId, _poolId(l, address(stocksHook)));
        assertEq(record.lpTokenId, nextTokenId);
        assertEq(IERC721Owner(address(positionManager)).ownerOf(nextTokenId), DEAD);
        IRobinhoodStocksLaunchpadV1.StockRecord memory stockRecord = stocks.stockRecords(l.launchId);
        assertEq(stockRecord.stockOnlyTokenId, nextTokenId + 1);
        assertEq(IERC721Owner(address(positionManager)).ownerOf(nextTokenId + 1), DEAD);
        assertGt(stockRecord.stockOnlyStock, 0);

        (uint160 sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(PoolId.wrap(record.poolId));
        assertEq(sqrtPriceX96, record.finalSqrtPriceX96);
        assertEq(MockERC20(l.newToken).balanceOf(address(stocks)), 0);
        assertEq(MockERC20(l.newToken).balanceOf(DEAD), record.retiredNew);
        assertEq(stockHigh.balanceOf(address(stocks)), 0);
        assertEq(stocksHook.accrued(record.poolId, address(inbox)), stockHigh.balanceOf(address(stocksHook)));
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

    function test_only_a_splitter_this_system_created_is_accepted_as_a_subject() public {
        Launched memory rev = _launchRevshare();
        _graduateRevshare(rev);
        address authentic = revshare.splitterOf(rev.newToken);
        assertTrue(authentic != address(0));

        SplitterStub stub = new SplitterStub(rev.newToken);
        IRobinhoodStocksLaunchpadV1.LaunchParams memory params = _stockParams(STOCK_LOW);
        params.subjectSplitter = address(stub);
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStocksLaunchpadV1.InauthenticSplitter.selector, address(stub)));
        stocks.launch(params);

        params.subjectSplitter = authentic;
        Launched memory l = _launchStockAs(launcher, params);
        (uint32 version, address splitter, uint16 subjectBps, address administrator,) = stocks.subjectConfig(l.launchId);
        assertEq(version, 1);
        assertEq(splitter, authentic);
        assertEq(subjectBps, RobinhoodPreset.SUBJECT_LANE_BPS);
        assertEq(administrator, feeAdministrator);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStocksLaunchpadV1.NotFeeAdministrator.selector, outsider));
        stocks.configureSubject(l.launchId, address(0), 1);
        vm.prank(feeAdministrator);
        stocks.configureSubject(l.launchId, address(0), 1);
        (version, splitter, subjectBps,,) = stocks.subjectConfig(l.launchId);
        assertEq(version, 2);
        assertEq(splitter, address(0));
        assertEq(subjectBps, 0);
    }

    // -------------------------------------------------------------------------
    // revenue-share launches
    // -------------------------------------------------------------------------

    function test_revshare_launch_enforces_the_minimum_raise_and_treasury_admission() public {
        IRobinhoodRevshareLaunchpadV1.LaunchParams memory params = _revshareParams();
        params.requiredUsdgRaised = REVSHARE_REQUIRED_RAISE - 1;
        vm.prank(launcher);
        vm.expectRevert(
            abi.encodeWithSelector(
                RobinhoodRevshareLaunchpadV1.RequiredRaiseBelowMinimum.selector,
                REVSHARE_REQUIRED_RAISE - 1,
                REVSHARE_REQUIRED_RAISE
            )
        );
        revshare.launch(params);

        params = _revshareParams();
        params.treasury = address(inbox);
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodRevshareLaunchpadV1.RefusedTreasury.selector, address(inbox)));
        revshare.launch(params);

        Launched memory l = _launchRevshare();
        assertEq(l.auction.currency(), USDG_ADDRESS);
        assertEq(MockERC20(l.newToken).totalSupply(), RobinhoodPreset.REVSHARE_TOTAL_SUPPLY);
        assertEq(MockERC20(l.newToken).balanceOf(address(l.auction)), RobinhoodPreset.REVSHARE_AUCTION_INVENTORY);
        assertEq(
            MockERC20(l.newToken).balanceOf(address(revshare)),
            RobinhoodPreset.REVSHARE_TREASURY_ALLOCATION + RobinhoodPreset.REVSHARE_MIGRATION_RESERVE
        );
    }

    function test_revshare_graduation_creates_the_splitter_locks_the_full_range_and_starts_vesting() public {
        Launched memory l = _launchRevshare();
        uint256 nextTokenId = positionManager.nextTokenId();
        _graduateRevshare(l);

        IRobinhoodLaunchpadBase.Launch memory record = revshare.launches(l.launchId);
        assertEq(uint8(record.lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Graduated));
        assertEq(record.lpTokenId, nextTokenId);
        assertEq(positionManager.nextTokenId(), nextTokenId + 1);
        assertEq(IERC721Owner(address(positionManager)).ownerOf(nextTokenId), DEAD);

        IRobinhoodRevshareLaunchpadV1.RevshareRecord memory rev = revshare.revshareRecords(l.launchId);
        RobinhoodSubjectSplitterV1 splitter = RobinhoodSubjectSplitterV1(rev.splitter);
        assertEq(revshare.splitterOf(l.newToken), rev.splitter);
        assertEq(splitter.subject(), l.newToken);
        assertEq(splitter.usdg(), USDG_ADDRESS);
        assertEq(splitter.inbox(), address(inbox));
        assertEq(splitter.treasury(), treasury);
        assertEq(revshareHook.pool(record.poolId).subject, rev.splitter);

        // Everything not sold and not paired vests; the launchpad holds exactly that much NEW.
        assertEq(rev.vestingStart, block.timestamp);
        assertEq(rev.vestingTotal, MockERC20(l.newToken).balanceOf(address(revshare)));
        assertGt(rev.vestingTotal, RobinhoodPreset.REVSHARE_TREASURY_ALLOCATION);
        // The USDG the full range could not pair went to the treasury; nothing stayed behind.
        assertEq(usdg.balanceOf(address(revshare)), 0);
        assertEq(usdg.balanceOf(treasury) + record.lpCurrencyUsed, 10_000e6);
    }

    function test_vesting_is_linear_and_released_to_the_treasury_only() public {
        Launched memory l = _launchRevshare();
        _graduateRevshare(l);
        uint256 total = revshare.revshareRecords(l.launchId).vestingTotal;

        vm.expectRevert(abi.encodeWithSelector(RobinhoodRevshareLaunchpadV1.NothingToRelease.selector, l.launchId));
        revshare.release(l.launchId);

        vm.warp(block.timestamp + RobinhoodPreset.REVSHARE_VESTING_DURATION / 4);
        assertEq(revshare.releasable(l.launchId), total / 4);
        vm.prank(outsider);
        uint256 released = revshare.release(l.launchId);
        assertEq(released, total / 4);
        assertEq(MockERC20(l.newToken).balanceOf(treasury), total / 4);

        vm.warp(block.timestamp + RobinhoodPreset.REVSHARE_VESTING_DURATION);
        revshare.release(l.launchId);
        assertEq(MockERC20(l.newToken).balanceOf(treasury), total);
        assertEq(MockERC20(l.newToken).balanceOf(address(revshare)), 0);
        assertEq(revshare.releasable(l.launchId), 0);
    }

    function test_revshare_failure_retires_everything_and_creates_no_splitter() public {
        Launched memory l = _launchRevshare();
        _bidToMigration(l, REVSHARE_REQUIRED_RAISE - 1);
        revshare.migrate(l.launchId);
        assertEq(uint8(revshare.launches(l.launchId).lifecycle), uint8(IRobinhoodLaunchpadBase.Lifecycle.Failed));
        assertEq(MockERC20(l.newToken).balanceOf(DEAD), RobinhoodPreset.REVSHARE_TOTAL_SUPPLY);
        assertEq(revshare.splitterOf(l.newToken), address(0));
        assertEq(revshare.revshareRecords(l.launchId).vestingTotal, 0);
        assertEq(usdg.balanceOf(address(revshare)), 0);
    }
}
