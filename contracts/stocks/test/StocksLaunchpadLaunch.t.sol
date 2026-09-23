// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

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
import {StocksFixture} from "./StocksFixture.sol";

/// @notice Rule 1 (exact minting and custody), rule 2 (canonical auction bindings), rule 8 (a launch
///         costs nothing and opens ten minutes after creation), admission, pause scope and launch
///         validation.
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
        assertEq(record.splitter, address(0), "the splitter is created at graduation");
        assertEq(record.requiredStockRaised, REQUIRED_RAISE);
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

    function test_auction_opens_exactly_ten_minutes_after_the_creation_block() public {
        vm.roll(2_345_678);
        uint64 expectedStart = 2_345_678 + 300;
        assertEq(StocksPreset.START_LEAD_BLOCKS, 300, "founder decision: ten minutes at 2 s blocks");
        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);
        uint256 launchId = launchpad.nextLaunchId();
        address predictedNew = uerc20Factory.getUERC20Address(
            params.name, params.symbol, StocksPreset.NEW_DECIMALS, address(launchpad), bytes32(launchId)
        );

        // The start block is the creation block plus the lead, and the launch event carries it so a
        // wallet can show the exact opening block from the receipt.
        vm.expectEmit(true, true, true, false, address(launchpad));
        emit IStocksLaunchpadV1.StockLaunchCreated(
            launchId,
            launcher,
            predictedNew,
            STOCK_LOW,
            address(0),
            expectedStart,
            expectedStart + StocksPreset.AUCTION_DURATION_BLOCKS,
            FLOOR_PRICE_Q96,
            REQUIRED_RAISE,
            StocksPreset.AUCTION_INVENTORY,
            StocksPreset.MIGRATION_RESERVE
        );
        Launched memory l = _launchAs(launcher, params);
        IStocksLaunchpadV1.Launch memory record = _record(l);
        assertEq(record.startBlock, expectedStart, "record: creation block + 300");
        assertEq(l.auction.startBlock(), expectedStart, "auction: creation block + 300");
        assertEq(record.endBlock, expectedStart + StocksPreset.AUCTION_DURATION_BLOCKS);

        // Bidding is refused before the opening block and accepted on it.
        stockLow.mint(bidder, 1e8);
        vm.roll(expectedStart - 1);
        vm.expectRevert();
        vm.prank(bidder);
        l.auction.submitBid(_bidPrice(1), 1e8, bidder, FLOOR_PRICE_Q96, "");
        vm.roll(expectedStart);
        _bidDirect(l, bidder, 1e8, _bidPrice(1));

        // Two launches in the same block open in the same block; a later block opens later.
        Launched memory sameBlock = _launch(STOCK_HIGH);
        assertEq(_record(sameBlock).startBlock, expectedStart + 300, "the next creation block sets the next start");
    }

    function test_floor_price_rules() public {
        vm.expectRevert(
            abi.encodeWithSelector(StocksLaunchpadV1.FloorPriceTooLow.selector, ConstantsLib.MIN_FLOOR_PRICE - 1)
        );
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

    function test_required_raise_is_chosen_by_the_launcher_above_zero_and_within_reach() public {
        // Each launch records exactly the STOCK raise its launcher asked for, in that launch alone.
        Launched memory first = _launch(STOCK_LOW);
        assertEq(_record(first).requiredStockRaised, REQUIRED_RAISE);
        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_HIGH);
        params.requiredStockRaised = 1;
        Launched memory smallest = _launchAs(launcher, params);
        assertEq(_record(smallest).requiredStockRaised, 1, "one base unit of STOCK is a valid raise");
        assertEq(_record(first).requiredStockRaised, REQUIRED_RAISE, "the earlier launch is untouched");

        // Zero is refused: an auction that graduates on nothing raised is not a launch.
        params = _params(STOCK_LOW);
        params.requiredStockRaised = 0;
        uint256 reachable = _maxReachableRaise();
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.UnreachableRequiredRaise.selector, 0, reachable));
        vm.prank(launcher);
        launchpad.launch(params);

        // A raise the fixed inventory cannot settle on is refused: the largest admissible raise is
        // the inventory at the highest on-grid price the pinned CCA admits
        // (`StocksLaunchpadV1._maxReachableRaise`), capped at what the auction can carry.
        params.requiredStockRaised = uint128(reachable) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(StocksLaunchpadV1.UnreachableRequiredRaise.selector, reachable + 1, reachable)
        );
        vm.prank(launcher);
        launchpad.launch(params);

        params.requiredStockRaised = uint128(reachable);
        Launched memory largest = _launchAs(launcher, params);
        assertEq(_record(largest).requiredStockRaised, reachable, "the largest reachable raise is accepted");
    }

    function _maxReachableRaise() private view returns (uint256 reachable) {
        uint256 tickSpacing = launchpad.bidTickSpacingFor(FLOOR_PRICE_Q96);
        uint256 maxBidPrice = MaxBidPriceLib.maxBidPrice(StocksPreset.AUCTION_INVENTORY);
        reachable = FullMath.mulDiv(
            StocksPreset.AUCTION_INVENTORY, maxBidPrice - (maxBidPrice % tickSpacing), FixedPoint96.Q96
        );
        if (reachable > type(uint128).max) reachable = type(uint128).max;
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
        // A floor at the very top of the CCA's admissible range passes every launchpad check (the
        // quoted raise is far below what the inventory settles on at that floor) but makes
        // `floor + tick > MAX_BID_PRICE` inside the pinned CCA constructor, so the auction factory
        // reverts after NEW was already created. Nothing of the launch survives: no record, no id
        // consumed, no token index, and no NEW token code.
        IStocksLaunchpadV1.LaunchParams memory params = _params(STOCK_LOW);
        uint256 maxBidPrice = MaxBidPriceLib.maxBidPrice(StocksPreset.AUCTION_INVENTORY);
        params.floorPriceQ96 = (maxBidPrice / 100) * 100;
        uint256 nextBefore = launchpad.nextLaunchId();
        address predictedNew = uerc20Factory.getUERC20Address(
            params.name, params.symbol, StocksPreset.NEW_DECIMALS, address(launchpad), bytes32(nextBefore)
        );

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
    }

    // -------------------------------------------------------------------------
    // rule 8: a launch costs nothing
    // -------------------------------------------------------------------------

    function test_launch_costs_no_regent_and_needs_no_allowance() public {
        address penniless = makeAddr("penniless-launcher");
        assertEq(regent.balanceOf(penniless), 0);
        assertEq(regent.allowance(penniless, address(launchpad)), 0);
        uint256 launchpadBefore = regent.balanceOf(address(launchpad));
        uint256 stakingBefore = regent.balanceOf(address(liveStaking));

        Launched memory l = _launchAs(penniless, _params(STOCK_LOW));
        assertEq(_record(l).launcher, penniless);
        assertEq(regent.balanceOf(penniless), 0, "nothing was pulled");
        assertEq(regent.balanceOf(address(launchpad)), launchpadBefore, "the launchpad holds no REGENT");
        assertEq(regent.balanceOf(address(liveStaking)), stakingBefore, "staking received nothing");
        assertEq(liveStaking.depositCalls(), 0, "staking was not called");

        // A paused staking contract cannot stop a launch: the launchpad never calls it at creation.
        liveStaking.setPaused(true);
        _launchAs(penniless, _params(STOCK_HIGH));
        liveStaking.setPaused(false);

        // A launch survives both outcomes with no REGENT anywhere in this component.
        _graduate(l, 1_000e8);
        assertEq(regent.balanceOf(address(launchpad)), launchpadBefore);
        assertEq(regent.balanceOf(address(liveStaking)), stakingBefore);
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
        StocksLaunchpadV1 fresh = new StocksLaunchpadV1(address(uerc20Factory), salt);
        assertTrue(fresh.launchesPaused());
        assertEq(fresh.nextLaunchId(), 1);
        assertNotEq(fresh.hook(), launchpad.hook(), "each launchpad mines its own hook");
        assertNotEq(fresh.locker(), launchpad.locker(), "each launchpad deploys its own locker");
        assertNotEq(fresh.splitterImplementation(), launchpad.splitterImplementation());
    }

    function test_admission_reads_decimals_and_verifies_the_route_bindings() public {
        (bool admitted, uint8 decimals, address route) = launchpad.stockAdmission(STOCK_LOW);
        assertTrue(admitted);
        assertEq(decimals, 8);
        assertEq(route, address(routeLow));

        FixtureStockRoute wrongRoute = new FixtureStockRoute(STOCK_HIGH, USDC_PER_SHARE);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.RouteBindingMismatch.selector, STOCK_LOW, STOCK_HIGH));
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
}
