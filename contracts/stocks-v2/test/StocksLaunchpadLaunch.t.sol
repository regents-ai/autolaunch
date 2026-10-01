// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {IDistributorFactory} from "liquidity-launcher/src/interfaces/IDistributorFactory.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {StocksBindings} from "../src/StocksBindings.sol";
import {StocksLaunchpadV2} from "../src/StocksLaunchpadV2.sol";
import {StocksPreset} from "../src/StocksPreset.sol";
import {FixtureStockRoute} from "../src/routes/FixtureStockRoute.sol";
import {IStocksLaunchpadV2} from "../src/interfaces/IStocksLaunchpadV2.sol";
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

    function test_launch_mints_exactly_S0_once_and_keeps_only_the_reserve_and_the_vesting() public {
        Launched memory l = _launch(STOCK_LOW);
        UERC20 token = UERC20(l.newToken);

        assertEq(token.totalSupply(), StocksPreset.INITIAL_SUPPLY, "exactly S0 minted");
        assertEq(token.decimals(), StocksPreset.NEW_DECIMALS);
        assertEq(token.creator(), address(launchpad), "launchpad is the creator");
        assertEq(token.graffiti(), bytes32(l.launchId));
        assertEq(token.balanceOf(address(l.auction)), StocksPreset.AUCTION_INVENTORY, "inventory in the auction");
        assertEq(
            token.balanceOf(address(launchpad)),
            uint256(StocksPreset.MIGRATION_RESERVE) + StocksPreset.CREATOR_VESTING,
            "only the reserve and the vesting stay"
        );
        assertEq(
            token.balanceOf(address(l.auction)) + token.balanceOf(address(launchpad)),
            StocksPreset.INITIAL_SUPPLY,
            "inventory + reserve + vesting == S0"
        );
        assertEq(launchpad.launchIdOfAuction(address(l.auction)), l.launchId);
        assertEq(launchpad.launchIdOfToken(l.newToken), l.launchId);
        assertEq(launchpad.nextLaunchId(), 2);
    }

    function test_auction_is_bound_to_stock_and_to_the_launchpad_as_both_recipients() public {
        Launched memory l = _launch(STOCK_LOW);
        IContinuousClearingAuction cca = l.auction;
        IStocksLaunchpadV2.Launch memory record = _record(l);

        assertEq(cca.token(), l.newToken);
        assertEq(cca.currency(), STOCK_LOW, "currency == stock");
        assertEq(cca.totalSupply(), StocksPreset.AUCTION_INVENTORY);
        assertEq(cca.tokensRecipient(), address(launchpad), "tokensRecipient == launchpad");
        assertEq(cca.fundsRecipient(), address(launchpad), "fundsRecipient == launchpad");
        assertEq(address(cca.validationHook()), address(0));
        assertEq(address(ccaFactory.protocolFeeController()), address(0), "protocolFeeController == 0");
        assertEq(cca.floorPrice(), StocksPreset.FLOOR_PRICE_Q96, "every launch has the one floor");
        assertEq(cca.tickSpacing(), StocksPreset.BID_TICK_SPACING_Q96);
        assertEq(cca.startBlock(), record.startBlock);
        assertEq(cca.endBlock(), record.startBlock + StocksPreset.AUCTION_DURATION_BLOCKS);
        assertEq(cca.claimBlock(), record.endBlock + StocksPreset.CLAIM_DELAY_BLOCKS);
        assertEq(record.migrationBlock, record.endBlock + StocksPreset.MIGRATION_DELAY_BLOCKS);
        assertEq(uint8(record.lifecycle), uint8(IStocksLaunchpadV2.Lifecycle.Active));
        assertEq(record.launcher, launcher);
        assertEq(record.splitter, address(0), "the splitter is created at graduation");
        assertEq(record.vestingStartBlock, 0, "the vesting starts at graduation");
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

        IStocksLaunchpadV2.LaunchParams memory params = _params(STOCK_LOW);
        vm.expectRevert(StocksLaunchpadV2.LaunchesArePaused.selector);
        vm.prank(launcher);
        launchpad.launch(params);

        // Existing auctions, bids and migration are untouched by the pause.
        _graduate(l, 1_000e8);
        assertEq(uint8(_record(l).lifecycle), uint8(IStocksLaunchpadV2.Lifecycle.Graduated));
    }

    function test_launch_refuses_unadmitted_and_revoked_stock() public {
        address unknown = makeAddr("unknown-stock");
        IStocksLaunchpadV2.LaunchParams memory params = _params(unknown);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV2.StockNotAdmitted.selector, unknown));
        vm.prank(launcher);
        launchpad.launch(params);

        vm.prank(governance);
        launchpad.revokeStock(STOCK_LOW);
        (bool admitted,, address route) = launchpad.stockAdmission(STOCK_LOW);
        assertFalse(admitted);
        assertEq(route, address(routeLow), "route stays recorded for settlement");
        params = _params(STOCK_LOW);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV2.StockNotAdmitted.selector, STOCK_LOW));
        vm.prank(launcher);
        launchpad.launch(params);
    }

    function test_revoke_never_changes_an_existing_launch() public {
        Launched memory l = _launch(STOCK_LOW);
        vm.prank(governance);
        launchpad.revokeStock(STOCK_LOW);
        _graduate(l, 1_000e8);
        assertEq(uint8(_record(l).lifecycle), uint8(IStocksLaunchpadV2.Lifecycle.Graduated));
    }

    function test_auction_opens_exactly_ten_minutes_after_the_creation_block() public {
        vm.roll(2_345_678);
        uint64 expectedStart = 2_345_678 + 300;
        assertEq(StocksPreset.START_LEAD_BLOCKS, 300, "founder decision: ten minutes at 2 s blocks");
        IStocksLaunchpadV2.LaunchParams memory params = _params(STOCK_LOW);
        uint256 launchId = launchpad.nextLaunchId();
        address predictedNew = uerc20Factory.getUERC20Address(
            params.name, params.symbol, StocksPreset.NEW_DECIMALS, address(launchpad), bytes32(launchId)
        );

        // The start block is the creation block plus the lead, and the launch event carries it so a
        // wallet can show the exact opening block from the receipt.
        vm.expectEmit(true, true, true, false, address(launchpad));
        emit IStocksLaunchpadV2.StockLaunchCreated(
            launchId,
            launcher,
            predictedNew,
            STOCK_LOW,
            address(0),
            expectedStart,
            expectedStart + StocksPreset.AUCTION_DURATION_BLOCKS,
            StocksPreset.AUCTION_INVENTORY,
            StocksPreset.MIGRATION_RESERVE,
            StocksPreset.CREATOR_VESTING
        );
        Launched memory l = _launchAs(launcher, params);
        IStocksLaunchpadV2.Launch memory record = _record(l);
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

    function test_metadata_caps() public {
        IStocksLaunchpadV2.LaunchParams memory params = _params(STOCK_LOW);
        params.name = "";
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV2.EmptyMetadataField.selector, 0));
        vm.prank(launcher);
        launchpad.launch(params);

        params = _params(STOCK_LOW);
        params.symbol = "SEVENTEEN-CHARS!!";
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV2.MetadataFieldTooLong.selector, 1, 16, 17));
        vm.prank(launcher);
        launchpad.launch(params);
    }

    function test_launch_is_atomic_when_the_auction_creation_fails() public {
        // The auction factory reverts after NEW was already created. Nothing of the launch survives:
        // no record, no id consumed, no token index, and no NEW token code.
        IStocksLaunchpadV2.LaunchParams memory params = _params(STOCK_LOW);
        uint256 nextBefore = launchpad.nextLaunchId();
        address predictedNew = uerc20Factory.getUERC20Address(
            params.name, params.symbol, StocksPreset.NEW_DECIMALS, address(launchpad), bytes32(nextBefore)
        );

        vm.mockCallRevert(
            StocksBindings.CCA_FACTORY,
            abi.encodeWithSelector(IDistributorFactory.create.selector),
            bytes("auction creation failed")
        );
        vm.expectRevert(bytes("auction creation failed"));
        vm.prank(launcher);
        launchpad.launch(params);
        vm.clearMockedCalls();

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
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV2.NotGovernance.selector, outsider));
        launchpad.admitStock(STOCK_LOW, address(routeLow));
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV2.NotGovernance.selector, outsider));
        launchpad.revokeStock(STOCK_LOW);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV2.NotGovernance.selector, outsider));
        launchpad.pauseLaunches();
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV2.NotGovernance.selector, outsider));
        launchpad.unpauseLaunches();
        vm.stopPrank();

        vm.startPrank(governance);
        vm.expectRevert(StocksLaunchpadV2.LaunchesNotPaused.selector);
        launchpad.unpauseLaunches();
        launchpad.pauseLaunches();
        vm.expectRevert(StocksLaunchpadV2.LaunchesAlreadyPaused.selector);
        launchpad.pauseLaunches();
        vm.stopPrank();
    }

    function test_a_fresh_launchpad_is_born_paused() public {
        bytes32 salt = _mineHookSalt(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        StocksLaunchpadV2 fresh = new StocksLaunchpadV2(address(uerc20Factory), salt);
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
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV2.RouteBindingMismatch.selector, STOCK_LOW, STOCK_HIGH));
        vm.prank(governance);
        launchpad.admitStock(STOCK_LOW, address(wrongRoute));

        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV2.StockRefused.selector, StocksBindings.USDC));
        vm.prank(governance);
        launchpad.admitStock(StocksBindings.USDC, address(routeLow));

        address codeless = makeAddr("codeless-stock");
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV2.NoCode.selector, codeless));
        vm.prank(governance);
        launchpad.admitStock(codeless, address(routeLow));

        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV2.StockNotAdmitted.selector, codeless));
        vm.prank(governance);
        launchpad.revokeStock(codeless);
    }
}
