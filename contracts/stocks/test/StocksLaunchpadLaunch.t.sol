// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {ConstantsLib} from "continuous-clearing-auction/libraries/ConstantsLib.sol";
import {MaxBidPriceLib} from "continuous-clearing-auction/libraries/MaxBidPriceLib.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {StocksBindings} from "../src/StocksBindings.sol";
import {StocksLaunchpadV1} from "../src/StocksLaunchpadV1.sol";
import {StocksPreset} from "../src/StocksPreset.sol";
import {FixtureStockRoute} from "../src/routes/FixtureStockRoute.sol";
import {IStocksLaunchpadV1} from "../src/interfaces/IStocksLaunchpadV1.sol";
import {MockLiveStaking} from "./mocks/MockLiveStaking.sol";
import {MockSplitter} from "./mocks/MockSplitter.sol";
import {StocksFixture} from "./StocksFixture.sol";

/// @notice Rule 1 (exact minting and custody), rule 2 (canonical auction bindings), rule 8 (the exact,
///         non-refundable launch fee funded into staking), admission, pause scope, launch validation
///         and the subject-lane administration surface.
contract StocksLaunchpadLaunchTest is StocksFixture {
    function setUp() public {
        _deployStocks();
    }

    // -------------------------------------------------------------------------
    // rule 1 and rule 2
    // -------------------------------------------------------------------------

    function test_launch_mints_exactly_S0_once_and_keeps_only_the_reserve() public {
        Launched memory l = _launch(STOCK_LOW);
        UERC20 token = UERC20(l.newToken);

        assertEq(token.totalSupply(), StocksPreset.INITIAL_SUPPLY, "exactly S0 minted");
        assertEq(token.decimals(), StocksPreset.NEW_DECIMALS);
        assertEq(token.creator(), address(launchpad), "launchpad is the creator");
        assertEq(token.graffiti(), bytes32(l.launchId));
        assertEq(token.balanceOf(address(l.auction)), StocksPreset.AUCTION_INVENTORY, "inventory in the auction");
        assertEq(token.balanceOf(address(launchpad)), StocksPreset.MIGRATION_RESERVE, "only the reserve stays");
        assertEq(
            token.balanceOf(address(l.auction)) + token.balanceOf(address(launchpad)),
            StocksPreset.INITIAL_SUPPLY,
            "inventory + reserve == S0"
        );
        assertEq(launchpad.launchIdOfAuction(address(l.auction)), l.launchId);
        assertEq(launchpad.launchIdOfToken(l.newToken), l.launchId);
        assertEq(launchpad.nextLaunchId(), 2);
    }

    function test_auction_is_bound_to_stock_and_to_the_launchpad_as_both_recipients() public {
        Launched memory l = _launch(STOCK_LOW);
        IContinuousClearingAuction cca = l.auction;
        IStocksLaunchpadV1.Launch memory record = _record(l);

        assertEq(cca.token(), l.newToken);
        assertEq(cca.currency(), STOCK_LOW, "currency == stock");
        assertEq(cca.totalSupply(), StocksPreset.AUCTION_INVENTORY);
        assertEq(cca.tokensRecipient(), address(launchpad), "tokensRecipient == launchpad");
        assertEq(cca.fundsRecipient(), address(launchpad), "fundsRecipient == launchpad");
        assertEq(address(cca.validationHook()), address(0));
        assertEq(address(ccaFactory.protocolFeeController()), address(0), "protocolFeeController == 0");
        assertEq(cca.floorPrice(), FLOOR_PRICE_Q96);
        assertEq(cca.tickSpacing(), FLOOR_PRICE_Q96 / StocksPreset.BID_TICK_DIVISOR);
        assertEq(cca.startBlock(), record.startBlock);
        assertEq(cca.endBlock(), record.startBlock + StocksPreset.AUCTION_DURATION_BLOCKS);
        assertEq(cca.claimBlock(), record.endBlock + StocksPreset.CLAIM_DELAY_BLOCKS);
        assertEq(record.migrationBlock, record.endBlock + StocksPreset.MIGRATION_DELAY_BLOCKS);
        assertEq(uint8(record.lifecycle), uint8(IStocksLaunchpadV1.Lifecycle.Active));
        assertEq(record.launcher, launcher);
        assertEq(record.feeAdministrator, feeAdministrator);
        assertEq(record.requiredStockRaised, 100e8);
    }

    function test_launch_emits_creation_and_initial_subject_configuration() public {
        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);
        _approveFee(launcher, params);
        vm.expectEmit(true, false, false, true, address(launchpad));
        emit IStocksLaunchpadV1.SubjectConfigured(1, 1, address(0), 0, feeAdministrator);
        vm.prank(launcher);
        launchpad.launch(params);

        (uint32 version, address splitterOf, uint16 bps, address admin, address proposed) = launchpad.subjectConfig(1);
        assertEq(version, 1);
        assertEq(splitterOf, address(0));
        assertEq(bps, 0);
        assertEq(admin, feeAdministrator);
        assertEq(proposed, address(0));
    }

    function test_launch_with_authentic_splitter_records_the_subject_lane() public {
        Launched memory l = _launchWithSubject(STOCK_HIGH);
        (uint32 version, address splitterOf, uint16 bps,,) = launchpad.subjectConfig(l.launchId);
        assertEq(version, 1);
        assertEq(splitterOf, address(splitter));
        assertEq(bps, StocksPreset.SUBJECT_LANE_BPS);
    }

    function test_both_pool_orderings_are_reachable() public {
        Launched memory low = _launch(STOCK_LOW);
        Launched memory high = _launch(STOCK_HIGH);
        assertTrue(_stockIsCurrency0(low), "STOCK_LOW sorts below NEW");
        assertFalse(_stockIsCurrency0(high), "STOCK_HIGH sorts above NEW");
    }

    // -------------------------------------------------------------------------
    // launch validation
    // -------------------------------------------------------------------------

    function test_launch_refuses_while_paused_and_only_gates_launch() public {
        Launched memory l = _launch(STOCK_LOW);
        vm.prank(governance);
        launchpad.pauseLaunches();

        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);
        vm.expectRevert(StocksLaunchpadV1.LaunchesArePaused.selector);
        vm.prank(launcher);
        launchpad.launch(params);

        // Existing auctions, bids and migration are untouched by the pause.
        _graduate(l, 1_000e8);
        assertEq(uint8(_record(l).lifecycle), uint8(IStocksLaunchpadV1.Lifecycle.Graduated));
    }

    function test_launch_refuses_unadmitted_and_revoked_stock() public {
        address unknown = makeAddr("unknown-stock");
        IStocksLaunchpadV1.LaunchParams memory params = _params(unknown);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.StockNotAdmitted.selector, unknown));
        vm.prank(launcher);
        launchpad.launch(params);

        vm.prank(governance);
        launchpad.revokeStock(STOCK_LOW);
        (bool admitted,, address route) = launchpad.stockAdmission(STOCK_LOW);
        assertFalse(admitted);
        assertEq(route, address(routeLow), "route stays recorded for settlement");
        params = _params(STOCK_LOW);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.StockNotAdmitted.selector, STOCK_LOW));
        vm.prank(launcher);
        launchpad.launch(params);
    }

    function test_revoke_never_changes_an_existing_launch() public {
        Launched memory l = _launch(STOCK_LOW);
        vm.prank(governance);
        launchpad.revokeStock(STOCK_LOW);
        _graduate(l, 1_000e8);
        assertEq(uint8(_record(l).lifecycle), uint8(IStocksLaunchpadV1.Lifecycle.Graduated));
    }

    function test_launch_start_window() public {
        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);
        params.startBlock = uint64(block.number) + StocksPreset.MIN_START_LEAD_BLOCKS - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                StocksLaunchpadV1.StartBlockOutOfWindow.selector,
                params.startBlock,
                block.number + StocksPreset.MIN_START_LEAD_BLOCKS,
                block.number + StocksPreset.MAX_START_LEAD_BLOCKS
            )
        );
        vm.prank(launcher);
        launchpad.launch(params);

        params.startBlock = uint64(block.number) + StocksPreset.MAX_START_LEAD_BLOCKS + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                StocksLaunchpadV1.StartBlockOutOfWindow.selector,
                params.startBlock,
                block.number + StocksPreset.MIN_START_LEAD_BLOCKS,
                block.number + StocksPreset.MAX_START_LEAD_BLOCKS
            )
        );
        vm.prank(launcher);
        launchpad.launch(params);

        params.startBlock = uint64(block.number) + StocksPreset.MAX_START_LEAD_BLOCKS;
        _launchAs(launcher, params);
    }

    function test_floor_price_rules() public {
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.FloorPriceTooLow.selector, ConstantsLib.MIN_FLOOR_PRICE - 1));
        launchpad.bidTickSpacingFor(ConstantsLib.MIN_FLOOR_PRICE - 1);

        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.FloorPriceNotOnGrid.selector, FLOOR_PRICE_Q96 + 1));
        launchpad.bidTickSpacingFor(FLOOR_PRICE_Q96 + 1);

        assertEq(launchpad.bidTickSpacingFor(FLOOR_PRICE_Q96), FLOOR_PRICE_Q96 / 100);
        assertGe(launchpad.bidTickSpacingFor(4_294_967_400), ConstantsLib.MIN_TICK_SPACING);

        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);
        params.floorPriceQ96 = FLOOR_PRICE_Q96 + 1;
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.FloorPriceNotOnGrid.selector, FLOOR_PRICE_Q96 + 1));
        vm.prank(launcher);
        launchpad.launch(params);
    }

    function testFuzz_bidTickSpacingFor_is_one_hundredth_of_an_on_grid_floor(uint256 floorHundredths) public view {
        floorHundredths = bound(floorHundredths, ConstantsLib.MIN_FLOOR_PRICE / 100 + 1, type(uint256).max / 100);
        uint256 floor = floorHundredths * 100;
        assertEq(launchpad.bidTickSpacingFor(floor), floorHundredths);
        assertGe(floorHundredths, ConstantsLib.MIN_TICK_SPACING);
    }

    function test_required_raise_must_be_nonzero_and_reachable() public {
        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);
        // The largest raise the fixed inventory can settle on: the inventory at the highest on-grid
        // price the pinned CCA admits (`StocksLaunchpadV1._maxReachableRaise`).
        uint256 tickSpacing = launchpad.bidTickSpacingFor(FLOOR_PRICE_Q96);
        uint256 maxBidPrice = MaxBidPriceLib.maxBidPrice(StocksPreset.AUCTION_INVENTORY);
        uint256 reachable =
            FullMath.mulDiv(StocksPreset.AUCTION_INVENTORY, maxBidPrice - (maxBidPrice % tickSpacing), FixedPoint96.Q96);
        assertGt(reachable, 0);

        params.requiredStockRaised = 0;
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.UnreachableRequiredRaise.selector, 0, reachable));
        vm.prank(launcher);
        launchpad.launch(params);

        params.requiredStockRaised = type(uint128).max;
        vm.expectRevert(
            abi.encodeWithSelector(StocksLaunchpadV1.UnreachableRequiredRaise.selector, type(uint128).max, reachable)
        );
        vm.prank(launcher);
        launchpad.launch(params);
    }

    function test_fee_administrator_is_required() public {
        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);
        params.feeAdministrator = address(0);
        vm.expectRevert(StocksLaunchpadV1.ZeroAddress.selector);
        vm.prank(launcher);
        launchpad.launch(params);
    }

    function test_inauthentic_splitters_are_refused() public {
        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);

        params.subjectSplitter = makeAddr("codeless");
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.SplitterHasNoCode.selector, params.subjectSplitter));
        vm.prank(launcher);
        launchpad.launch(params);

        // A splitter whose subject the Agent strategy never launched.
        MockSplitter stray = new MockSplitter(makeAddr("stray-subject"), StocksBindings.REGENT);
        params.subjectSplitter = address(stray);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.InauthenticSplitter.selector, address(stray)));
        vm.prank(launcher);
        launchpad.launch(params);

        // A splitter claiming a launched subject but not the one the strategy recorded.
        MockSplitter impostor = new MockSplitter(agentSubject, StocksBindings.REGENT);
        params.subjectSplitter = address(impostor);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.InauthenticSplitter.selector, address(impostor)));
        vm.prank(launcher);
        launchpad.launch(params);
    }

    function test_metadata_caps() public {
        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);
        params.name = "";
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.EmptyMetadataField.selector, 0));
        vm.prank(launcher);
        launchpad.launch(params);

        params = _params(STOCK_LOW);
        params.symbol = "SEVENTEEN-CHARS!!";
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.MetadataFieldTooLong.selector, 1, 16, 17));
        vm.prank(launcher);
        launchpad.launch(params);
    }

    function test_launch_is_atomic_when_the_auction_creation_fails() public {
        // A floor at the very top of the CCA's admissible range passes every launchpad check (a raise
        // of one unit is reachable) but makes `floor + tick > MAX_BID_PRICE` inside the pinned CCA
        // constructor, so the auction factory reverts after NEW was already created. Nothing of the
        // launch survives: no record, no id consumed, no token index, and no NEW token code.
        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);
        uint256 maxBidPrice = MaxBidPriceLib.maxBidPrice(StocksPreset.AUCTION_INVENTORY);
        params.floorPriceQ96 = (maxBidPrice / 100) * 100;
        params.requiredStockRaised = 1;
        uint256 nextBefore = launchpad.nextLaunchId();
        address predictedNew = uerc20Factory.getUERC20Address(
            params.name, params.symbol, StocksPreset.NEW_DECIMALS, address(launchpad), bytes32(nextBefore)
        );
        _approveFee(launcher, params);
        uint256 launcherRegentBefore = regent.balanceOf(launcher);
        uint256 fundedBefore = liveStaking.totalFundedRegent();

        vm.expectRevert(
            abi.encodeWithSelector(
                IContinuousClearingAuction.FloorPriceAndTickSpacingGreaterThanMaxBidPrice.selector,
                params.floorPriceQ96 + params.floorPriceQ96 / 100,
                maxBidPrice
            )
        );
        vm.prank(launcher);
        launchpad.launch(params);

        assertEq(launchpad.nextLaunchId(), nextBefore);
        assertEq(launchpad.launches(nextBefore).auction, address(0));
        assertEq(launchpad.launchIdOfToken(predictedNew), 0);
        assertEq(predictedNew.code.length, 0, "the NEW creation rolled back with the launch");
        assertEq(regent.balanceOf(launcher), launcherRegentBefore, "the fee rolled back with the launch");
        assertEq(liveStaking.totalFundedRegent(), fundedBefore, "nothing reached staking");
        assertEq(regent.allowance(launcher, address(launchpad)), params.expectedLaunchFee, "allowance untouched");
    }

    // -------------------------------------------------------------------------
    // rule 8: the launch fee
    // -------------------------------------------------------------------------

    function test_launch_fee_is_born_at_the_preset() public view {
        assertEq(launchpad.launchFee(), StocksPreset.LAUNCH_FEE_REGENT);
        assertEq(StocksPreset.LAUNCH_FEE_REGENT, 100_000e18, "founder decision: 100,000 REGENT");
    }

    function test_launch_collects_the_exact_fee_and_funds_it_into_staking() public {
        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);
        uint256 fee = params.expectedLaunchFee;
        uint256 launcherBefore = regent.balanceOf(launcher);
        uint256 launchpadBefore = regent.balanceOf(address(launchpad));
        uint256 stakingBefore = regent.balanceOf(address(liveStaking));
        uint256 fundedBefore = liveStaking.totalFundedRegent();

        _approveFee(launcher, params);
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit IStocksLaunchpadV1.StockLaunchFeeCollected(1, launcher, StocksBindings.LIVE_STAKING, fee);
        vm.prank(launcher);
        launchpad.launch(params);

        assertEq(launcherBefore - regent.balanceOf(launcher), fee, "exactly the fee left the launcher");
        assertEq(regent.balanceOf(address(launchpad)), launchpadBefore, "the launchpad keeps none of it");
        assertEq(regent.balanceOf(address(liveStaking)) - stakingBefore, fee, "staking holds the fee");
        assertEq(liveStaking.totalFundedRegent() - fundedBefore, fee, "counted as staker rewards");
        assertEq(liveStaking.fundCalls(), 1);
        assertEq(liveStaking.lastFunder(), address(launchpad));
        assertEq(regent.allowance(launcher, address(launchpad)), 0, "launcher allowance consumed");
        assertEq(regent.allowance(address(launchpad), address(liveStaking)), 0, "staking allowance consumed");
    }

    function test_launch_refuses_a_stale_fee_before_anything_moves() public {
        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);
        _approveFee(launcher, params);
        params.expectedLaunchFee = StocksPreset.LAUNCH_FEE_REGENT - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                StocksLaunchpadV1.StaleLaunchFee.selector, StocksPreset.LAUNCH_FEE_REGENT, StocksPreset.LAUNCH_FEE_REGENT - 1
            )
        );
        vm.prank(launcher);
        launchpad.launch(params);

        // Governance lowered the fee after the launcher reviewed it: refused, not charged the new one.
        params.expectedLaunchFee = StocksPreset.LAUNCH_FEE_REGENT;
        vm.prank(governance);
        launchpad.setLaunchFee(1e18);
        vm.expectRevert(
            abi.encodeWithSelector(StocksLaunchpadV1.StaleLaunchFee.selector, 1e18, StocksPreset.LAUNCH_FEE_REGENT)
        );
        vm.prank(launcher);
        launchpad.launch(params);
        assertEq(regent.allowance(launcher, address(launchpad)), StocksPreset.LAUNCH_FEE_REGENT, "nothing consumed");
        assertEq(liveStaking.totalFundedRegent(), 0);
        assertEq(launchpad.nextLaunchId(), 1);
    }

    function test_launch_refuses_an_allowance_below_or_above_the_fee() public {
        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);
        uint256 fee = params.expectedLaunchFee;

        vm.prank(launcher);
        regent.approve(address(launchpad), fee - 1);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.LaunchFeeAllowanceMismatch.selector, fee, fee - 1));
        vm.prank(launcher);
        launchpad.launch(params);

        vm.prank(launcher);
        regent.approve(address(launchpad), fee + 1);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.LaunchFeeAllowanceMismatch.selector, fee, fee + 1));
        vm.prank(launcher);
        launchpad.launch(params);

        vm.prank(launcher);
        regent.approve(address(launchpad), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(StocksLaunchpadV1.LaunchFeeAllowanceMismatch.selector, fee, type(uint256).max)
        );
        vm.prank(launcher);
        launchpad.launch(params);

        assertEq(launchpad.nextLaunchId(), 1, "no launch consumed an id");
        assertEq(liveStaking.totalFundedRegent(), 0);
    }

    function test_launch_refuses_a_launcher_who_cannot_pay() public {
        address poor = makeAddr("poor-launcher");
        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);
        _approveFee(poor, params);
        vm.expectRevert();
        vm.prank(poor);
        launchpad.launch(params);
        assertEq(launchpad.nextLaunchId(), 1);
    }

    function test_launch_refuses_a_staking_that_does_not_take_the_whole_fee() public {
        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);
        uint256 fee = params.expectedLaunchFee;
        _approveFee(launcher, params);

        liveStaking.setReportsWrongAmount(true);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.InexactTransfer.selector, fee, fee + 1));
        vm.prank(launcher);
        launchpad.launch(params);
        liveStaking.setReportsWrongAmount(false);

        liveStaking.setPaused(true);
        vm.expectRevert(MockLiveStaking.Paused.selector);
        vm.prank(launcher);
        launchpad.launch(params);
        liveStaking.setPaused(false);

        assertEq(regent.allowance(launcher, address(launchpad)), fee, "the whole launch rolled back");
        assertEq(regent.balanceOf(address(launchpad)), 0);
        assertEq(launchpad.nextLaunchId(), 1);
    }

    function test_zero_fee_moves_nothing_and_still_requires_a_zero_allowance() public {
        vm.expectEmit(false, false, false, true, address(launchpad));
        emit IStocksLaunchpadV1.LaunchFeeUpdated(StocksPreset.LAUNCH_FEE_REGENT, 0);
        vm.prank(governance);
        launchpad.setLaunchFee(0);
        assertEq(launchpad.launchFee(), 0);

        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);
        assertEq(params.expectedLaunchFee, 0);

        vm.prank(launcher);
        regent.approve(address(launchpad), 1);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.LaunchFeeAllowanceMismatch.selector, 0, 1));
        vm.prank(launcher);
        launchpad.launch(params);

        vm.prank(launcher);
        regent.approve(address(launchpad), 0);
        uint256 launcherBefore = regent.balanceOf(launcher);
        vm.recordLogs();
        vm.prank(launcher);
        launchpad.launch(params);
        assertEq(regent.balanceOf(launcher), launcherBefore, "nothing moved");
        assertEq(liveStaking.totalFundedRegent(), 0);
        assertEq(liveStaking.fundCalls(), 0, "staking was not called with zero");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].topics[0], IStocksLaunchpadV1.StockLaunchFeeCollected.selector, "no fee event at zero");
        }
    }

    function test_launch_fee_changes_apply_to_later_launches_only() public {
        Launched memory first = _launch(STOCK_LOW);
        assertEq(liveStaking.totalFundedRegent(), StocksPreset.LAUNCH_FEE_REGENT);

        vm.prank(governance);
        launchpad.setLaunchFee(250_000e18);
        assertEq(launchpad.launchFee(), 250_000e18);
        Launched memory second = _launch(STOCK_HIGH);
        assertEq(liveStaking.totalFundedRegent(), StocksPreset.LAUNCH_FEE_REGENT + 250_000e18, "each launch paid its own fee");

        // The existing launch is unaffected by the change.
        _graduate(first, 1_000e8);
        _graduate(second, 1_000e8);
        assertEq(uint8(_record(first).lifecycle), uint8(IStocksLaunchpadV1.Lifecycle.Graduated));
        assertEq(uint8(_record(second).lifecycle), uint8(IStocksLaunchpadV1.Lifecycle.Graduated));
    }

    function test_launch_fee_is_never_refunded() public {
        Launched memory failed = _launch(STOCK_LOW);
        Launched memory graduated = _launch(STOCK_HIGH);
        uint256 funded = 2 * StocksPreset.LAUNCH_FEE_REGENT;
        assertEq(liveStaking.totalFundedRegent(), funded);
        uint256 launcherAfterFees = regent.balanceOf(launcher);

        _rollToStart(failed);
        _bidDirect(failed, bidder, 10e8, _bidPrice(1)); // below the required raise
        _rollToMigration(failed);
        launchpad.migrate(failed.launchId);
        assertEq(uint8(_record(failed).lifecycle), uint8(IStocksLaunchpadV1.Lifecycle.Failed));

        _graduate(graduated, 1_000e8);
        assertEq(uint8(_record(graduated).lifecycle), uint8(IStocksLaunchpadV1.Lifecycle.Graduated));

        assertEq(liveStaking.totalFundedRegent(), funded, "staking keeps both fees through migrate");
        assertEq(regent.balanceOf(address(liveStaking)), funded);
        assertEq(regent.balanceOf(launcher), launcherAfterFees, "the launcher got nothing back");
        assertEq(regent.balanceOf(address(launchpad)), 0, "the launchpad holds no REGENT");
    }

    // -------------------------------------------------------------------------
    // governance
    // -------------------------------------------------------------------------

    function test_governance_only_mutators() public {
        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.NotGovernance.selector, outsider));
        launchpad.admitStock(STOCK_LOW, address(routeLow));
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.NotGovernance.selector, outsider));
        launchpad.revokeStock(STOCK_LOW);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.NotGovernance.selector, outsider));
        launchpad.pauseLaunches();
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.NotGovernance.selector, outsider));
        launchpad.unpauseLaunches();
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.NotGovernance.selector, outsider));
        launchpad.setLaunchFee(0);
        vm.stopPrank();

        vm.startPrank(governance);
        vm.expectRevert(StocksLaunchpadV1.LaunchesNotPaused.selector);
        launchpad.unpauseLaunches();
        launchpad.pauseLaunches();
        vm.expectRevert(StocksLaunchpadV1.LaunchesAlreadyPaused.selector);
        launchpad.pauseLaunches();
        vm.stopPrank();
    }

    function test_a_fresh_launchpad_is_born_paused() public {
        bytes32 salt = _mineHookSalt(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        StocksLaunchpadV1 fresh = new StocksLaunchpadV1(address(uerc20Factory), address(agentStrategy), salt);
        assertTrue(fresh.launchesPaused());
        assertEq(fresh.nextLaunchId(), 1);
        assertNotEq(fresh.hook(), launchpad.hook(), "each launchpad mines its own hook");
    }

    function test_admission_reads_decimals_and_verifies_the_route_bindings() public {
        (bool admitted, uint8 decimals, address route) = launchpad.stockAdmission(STOCK_LOW);
        assertTrue(admitted);
        assertEq(decimals, 8);
        assertEq(route, address(routeLow));

        FixtureStockRoute wrongRoute = new FixtureStockRoute(STOCK_HIGH, USDC_PER_SHARE);
        vm.expectRevert(
            abi.encodeWithSelector(StocksLaunchpadV1.RouteBindingMismatch.selector, STOCK_LOW, STOCK_HIGH)
        );
        vm.prank(governance);
        launchpad.admitStock(STOCK_LOW, address(wrongRoute));

        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.StockRefused.selector, StocksBindings.USDC));
        vm.prank(governance);
        launchpad.admitStock(StocksBindings.USDC, address(routeLow));

        address codeless = makeAddr("codeless-stock");
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.NoCode.selector, codeless));
        vm.prank(governance);
        launchpad.admitStock(codeless, address(routeLow));

        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.StockNotAdmitted.selector, codeless));
        vm.prank(governance);
        launchpad.revokeStock(codeless);
    }

    // -------------------------------------------------------------------------
    // subject administration
    // -------------------------------------------------------------------------

    function test_configureSubject_is_administrator_only_and_versioned() public {
        Launched memory l = _launch(STOCK_LOW);

        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.NotFeeAdministrator.selector, outsider));
        vm.prank(outsider);
        launchpad.configureSubject(l.launchId, address(splitter), 1);

        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.StaleSubjectVersion.selector, 1, 7));
        vm.prank(feeAdministrator);
        launchpad.configureSubject(l.launchId, address(splitter), 7);

        vm.expectEmit(true, true, true, true, address(launchpad));
        emit IStocksLaunchpadV1.SubjectConfigured(l.launchId, 2, address(splitter), 100, feeAdministrator);
        vm.prank(feeAdministrator);
        launchpad.configureSubject(l.launchId, address(splitter), 1);

        (uint32 version, address splitterOf, uint16 bps,,) = launchpad.subjectConfig(l.launchId);
        assertEq(version, 2);
        assertEq(splitterOf, address(splitter));
        assertEq(bps, 100);

        vm.prank(feeAdministrator);
        launchpad.configureSubject(l.launchId, address(0), 2);
        (version, splitterOf, bps,,) = launchpad.subjectConfig(l.launchId);
        assertEq(version, 3);
        assertEq(splitterOf, address(0));
        assertEq(bps, 0);

        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.UnknownLaunch.selector, 99));
        vm.prank(feeAdministrator);
        launchpad.configureSubject(99, address(0), 1);
    }

    function test_fee_administrator_transfer_is_two_step() public {
        Launched memory l = _launch(STOCK_LOW);
        address next = makeAddr("next-admin");

        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.NotFeeAdministrator.selector, outsider));
        vm.prank(outsider);
        launchpad.proposeFeeAdministrator(l.launchId, next);

        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.NotProposedAdministrator.selector, next));
        vm.prank(next);
        launchpad.acceptFeeAdministrator(l.launchId);

        vm.expectEmit(true, true, true, true, address(launchpad));
        emit IStocksLaunchpadV1.FeeAdministratorTransferStarted(l.launchId, feeAdministrator, next);
        vm.prank(feeAdministrator);
        launchpad.proposeFeeAdministrator(l.launchId, next);
        (,,, address admin, address proposed) = launchpad.subjectConfig(l.launchId);
        assertEq(admin, feeAdministrator, "nothing changes until acceptance");
        assertEq(proposed, next);

        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.NotProposedAdministrator.selector, outsider));
        vm.prank(outsider);
        launchpad.acceptFeeAdministrator(l.launchId);

        vm.expectEmit(true, true, true, true, address(launchpad));
        emit IStocksLaunchpadV1.FeeAdministratorTransferred(l.launchId, feeAdministrator, next);
        vm.prank(next);
        launchpad.acceptFeeAdministrator(l.launchId);
        (,,, admin, proposed) = launchpad.subjectConfig(l.launchId);
        assertEq(admin, next);
        assertEq(proposed, address(0));
        assertEq(_record(l).feeAdministrator, next);

        // The previous administrator has no power left; the new one configures.
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.NotFeeAdministrator.selector, feeAdministrator));
        vm.prank(feeAdministrator);
        launchpad.configureSubject(l.launchId, address(splitter), 1);
        vm.prank(next);
        launchpad.configureSubject(l.launchId, address(splitter), 1);
    }

    function test_administrator_cannot_reach_anything_else() public {
        Launched memory l = _launch(STOCK_LOW);
        vm.startPrank(feeAdministrator);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.NotGovernance.selector, feeAdministrator));
        launchpad.pauseLaunches();
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.NotGovernance.selector, feeAdministrator));
        launchpad.revokeStock(l.stock);
        vm.stopPrank();
    }
}
