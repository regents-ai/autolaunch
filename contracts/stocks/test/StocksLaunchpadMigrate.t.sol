// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {LBPInitializationParams} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";
import {TickCalculations} from "liquidity-launcher/src/libraries/TickCalculations.sol";
import {TokenPricing} from "liquidity-launcher/src/libraries/TokenPricing.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {StocksBindings} from "../src/StocksBindings.sol";
import {StocksFeeHookV1} from "../src/StocksFeeHookV1.sol";
import {StocksLaunchpadV1} from "../src/StocksLaunchpadV1.sol";
import {StocksPreset} from "../src/StocksPreset.sol";
import {FixtureStockToken} from "../src/fixtures/FixtureStockToken.sol";
import {IStocksLaunchpadV1} from "../src/interfaces/IStocksLaunchpadV1.sol";
import {StocksFixture} from "./StocksFixture.sol";

/// @notice Rules 3 and 4: graduation locks the whole reserve and all net STOCK in two positions at the
///         dead address (full range, then one-sided STOCK for what the full range could not pair),
///         routes only the rounding remainder as the preset says and retires unsold NEW; failure
///         retires the inventory and never touches bidder STOCK, whose refunds go through the CCA alone.
contract StocksLaunchpadMigrateTest is StocksFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using TickCalculations for int24;

    uint256 private constant Q96 = FixedPoint96.Q96;

    function setUp() public {
        _deployStocks();
    }

    // -------------------------------------------------------------------------
    // graduation
    // -------------------------------------------------------------------------

    /// @dev 1,000 shares at ten ticks above the floor buys more than the whole inventory, so the
    ///      auction sells out (four times the reserve): the case where a single full-range position
    ///      could place only a quarter of the raise and the one-sided STOCK position must lock the rest.
    function test_graduation_both_orderings() public {
        _assertGraduation(_launch(STOCK_LOW), 1_000e8, _bidPrice(10));
        _assertGraduation(_launch(STOCK_HIGH), 1_000e8, _bidPrice(10));
    }

    /// @dev 100 shares one tick above the floor clears at the floor and buys half the reserve: the full
    ///      range is STOCK-bound, so it takes every unit of STOCK itself and the reserve it cannot pair
    ///      is retired with the unsold NEW.
    function test_graduation_with_less_than_a_quarter_sold_both_orderings() public {
        _assertGraduation(_launch(STOCK_LOW), 100e8, _bidPrice(1));
        _assertGraduation(_launch(STOCK_HIGH), 100e8, _bidPrice(1));
    }

    /// @dev Every clearing price the bid grid reaches with a sell-out changes the initial tick's
    ///      alignment to the pool's spacing; the one-sided geometry and the dust bound hold at all of them.
    function testFuzz_graduation_locks_all_net_stock_at_any_clearing_price(uint16 ticksAboveFloor) public {
        uint256 priceQ96 = _bidPrice(bound(ticksAboveFloor, 1, type(uint16).max));
        _assertGraduation(_launch(STOCK_LOW), 1_000_000e8, priceQ96);
        _assertGraduation(_launch(STOCK_HIGH), 1_000_000e8, priceQ96);
    }

    function _assertGraduation(Launched memory l, uint128 bidAmount, uint256 priceQ96) private {
        _rollToStart(l);
        _bidDirect(l, bidder, bidAmount, priceQ96);
        _rollToMigration(l);

        IContinuousClearingAuction cca = l.auction;
        cca.checkpoint();
        LBPInitializationParams memory lbp = cca.lbpInitializationParams();
        uint256 pmStockBefore = FixtureStockToken(l.stock).balanceOf(address(positionManager));
        uint256 pmNewBefore = UERC20(l.newToken).balanceOf(address(positionManager));
        uint256 deadNewBefore = UERC20(l.newToken).balanceOf(StocksBindings.DEAD_ADDRESS);
        uint256 ccaNewBefore = UERC20(l.newToken).balanceOf(address(cca));
        uint256 nextTokenId = positionManager.nextTokenId();
        bytes32 poolId = _poolId(l);

        launchpad.migrate(l.launchId);

        IStocksLaunchpadV1.Launch memory record = _record(l);
        assertEq(uint8(record.lifecycle), uint8(IStocksLaunchpadV1.Lifecycle.Graduated));
        assertEq(record.poolId, poolId);

        // Pool initialized at the auction's final price, converted through the pinned TokenPricing.
        bool stockIsCurrency0 = _stockIsCurrency0(l);
        uint160 expectedSqrtPrice =
            TokenPricing.convertToSqrtPriceX96(TokenPricing.convertToPriceX192(lbp.initialPriceX96, stockIsCurrency0));
        assertEq(record.finalSqrtPriceX96, expectedSqrtPrice);
        assertEq(_sqrtPrice(l), expectedSqrtPrice, "pool at the clearing price");
        assertGt(IPoolManager(address(poolManager)).getLiquidity(PoolId.wrap(poolId)), 0, "live liquidity");

        uint256 minted = _assertLockedPositions(l, record, nextTokenId);
        assertEq(positionManager.nextTokenId(), nextTokenId + minted, "only this graduation's positions minted");

        // Exactly what the two positions consumed funded them; the PositionManager keeps nothing extra
        // and nothing that was already there is touched.
        assertEq(
            FixtureStockToken(l.stock).balanceOf(address(positionManager)), pmStockBefore, "PositionManager STOCK unchanged"
        );
        assertEq(UERC20(l.newToken).balanceOf(address(positionManager)), pmNewBefore, "PositionManager NEW unchanged");
        uint256 placed = uint256(record.lpStockUsed) + record.lpStockOnlyUsed;
        assertGe(FixtureStockToken(l.stock).balanceOf(address(poolManager)), placed, "pool holds the placed STOCK");

        // STOCK conservation: raised == placed + dust; dust is bounded rounding, in the REGENT bucket
        // and held by the hook.
        uint256 dust = hook.accrued(poolId, hook.REGENT_DESTINATION());
        assertEq(placed + dust, lbp.currencyRaised, "raised == placed + dust");
        assertLe(
            dust,
            _roundingBound(stockIsCurrency0, expectedSqrtPrice, lbp.currencyRaised - record.lpStockUsed),
            "dust within the one-sided rounding bound"
        );
        assertEq(FixtureStockToken(l.stock).balanceOf(address(hook)), dust, "hook holds exactly the dust");
        assertEq(FixtureStockToken(l.stock).balanceOf(address(launchpad)), 0, "launchpad keeps no STOCK");
        assertEq(
            FixtureStockToken(l.stock).balanceOf(address(cca)),
            bidAmount - lbp.currencyRaised,
            "auction keeps only the bidder's refundable remainder"
        );

        // NEW conservation: reserve + swept unsold == placed + retired; the launchpad keeps none; only
        // the full range holds NEW. The CCA keeps at least what its bidders can claim.
        uint256 swept = ccaNewBefore - UERC20(l.newToken).balanceOf(address(cca));
        assertGe(StocksPreset.AUCTION_INVENTORY - swept, lbp.tokensSold, "the auction keeps the claimable NEW");
        uint256 retired = UERC20(l.newToken).balanceOf(StocksBindings.DEAD_ADDRESS) - deadNewBefore;
        assertEq(record.retiredNew, retired);
        assertEq(uint256(record.lpNewUsed) + retired, uint256(StocksPreset.MIGRATION_RESERVE) + swept, "NEW conserved");
        assertEq(UERC20(l.newToken).balanceOf(address(launchpad)), 0, "launchpad keeps no NEW");
        assertLe(record.lpNewUsed, StocksPreset.MIGRATION_RESERVE, "the reserve was the only NEW budget");

        if (lbp.tokensSold > StocksPreset.MIGRATION_RESERVE) {
            // More than a quarter sold: the full range is NEW-bound, so the whole reserve is placed up
            // to rounding and the one-sided position exists and holds the rest of the raise.
            assertLe(
                StocksPreset.MIGRATION_RESERVE - record.lpNewUsed,
                _roundingBound(!stockIsCurrency0, expectedSqrtPrice, StocksPreset.MIGRATION_RESERVE),
                "reserve fully placed up to rounding"
            );
            assertEq(minted, 2, "both positions minted");
            assertGt(record.lpStockOnlyUsed, record.lpStockUsed, "the one-sided position holds most of the raise");
        } else {
            // Less than a quarter sold: the full range is STOCK-bound and takes the raise itself.
            assertLe(
                lbp.currencyRaised - record.lpStockUsed,
                _roundingBound(stockIsCurrency0, expectedSqrtPrice, lbp.currencyRaised),
                "full range takes the whole raise up to rounding"
            );
        }

        // The hook knows the pool.
        StocksFeeHookV1.PoolRecord memory pool = hook.pool(poolId);
        assertEq(pool.stock, l.stock);
        assertEq(pool.newToken, l.newToken);
        assertEq(pool.subject, address(0));
    }

    /// @dev Both locked positions: owner, pool, geometry, liquidity. Returns how many were minted.
    function _assertLockedPositions(Launched memory l, IStocksLaunchpadV1.Launch memory record, uint256 nextTokenId)
        private
        view
        returns (uint256 minted)
    {
        int24 spacing = StocksPreset.POOL_TICK_SPACING;
        int24 minUsable = TickMath.minUsableTick(spacing);
        int24 maxUsable = TickMath.maxUsableTick(spacing);

        assertEq(record.lpTokenId, nextTokenId, "the full range is minted first");
        assertEq(IERC721(address(positionManager)).ownerOf(record.lpTokenId), StocksBindings.DEAD_ADDRESS, "full range to dead");
        (PoolKey memory fullKey, PositionInfo fullInfo) = positionManager.getPoolAndPositionInfo(record.lpTokenId);
        assertEq(PoolId.unwrap(fullKey.toId()), record.poolId);
        assertEq(fullInfo.tickLower(), minUsable);
        assertEq(fullInfo.tickUpper(), maxUsable);
        assertGt(positionManager.getPositionLiquidity(record.lpTokenId), 0);
        minted = 1;

        if (record.lpStockOnlyTokenId == 0) {
            assertEq(record.lpStockOnlyUsed, 0, "no one-sided position, nothing placed in it");
            return minted;
        }

        assertEq(record.lpStockOnlyTokenId, record.lpTokenId + 1, "the one-sided position is minted second");
        assertEq(
            IERC721(address(positionManager)).ownerOf(record.lpStockOnlyTokenId), StocksBindings.DEAD_ADDRESS, "one-sided to dead"
        );
        (PoolKey memory sideKey, PositionInfo sideInfo) = positionManager.getPoolAndPositionInfo(record.lpStockOnlyTokenId);
        assertEq(PoolId.unwrap(sideKey.toId()), record.poolId);
        assertGt(positionManager.getPositionLiquidity(record.lpStockOnlyTokenId), 0);
        assertGt(record.lpStockOnlyUsed, 0);

        // The range sits entirely on the STOCK side of the initial tick, adjacent to it, out to the
        // last usable tick: below the price when STOCK is currency1, above it when STOCK is currency0.
        int24 tick = TickMath.getTickAtSqrtPrice(record.finalSqrtPriceX96);
        int24 floored = tick.tickFloor(spacing);
        if (_stockIsCurrency0(l)) {
            assertEq(sideInfo.tickLower(), floored + spacing, "starts one spacing above the floored tick");
            assertEq(sideInfo.tickUpper(), maxUsable);
            assertGt(sideInfo.tickLower(), tick, "strictly above the initial tick: STOCK only");
        } else {
            assertEq(sideInfo.tickLower(), minUsable);
            assertEq(sideInfo.tickUpper(), floored, "ends at the floored tick");
            assertLe(sideInfo.tickUpper(), tick, "at or below the initial tick: STOCK only");
        }
        minted = 2;
    }

    /// @dev Upper bound on what the pinned planner's arithmetic (floor the liquidity a budget affords,
    ///      then round the amounts of that liquidity up) can leave of a budget placed on one side of
    ///      the price. For a currency0 budget in a range `[A, B]` at or above the price the remainder is
    ///      below `budget * Q96 / (A * B) + Q96 / A`; for a currency1 budget in a range `[A, B]` at or
    ///      below the price it is below `(B - A) / Q96`. Evaluated at the price itself, which is
    ///      conservative for both (A >= price above, B <= price below), plus one for the integer floors.
    ///      Equals one or zero at every price the fixtures reach.
    function _roundingBound(bool budgetIsCurrency0, uint160 sqrtPriceX96, uint256 budget) private pure returns (uint256) {
        if (budgetIsCurrency0) {
            uint256 product = FullMath.mulDiv(
                sqrtPriceX96, TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(StocksPreset.POOL_TICK_SPACING)), Q96
            );
            return budget / product + Q96 / sqrtPriceX96 + 1;
        }
        return sqrtPriceX96 / Q96 + 1;
    }

    function test_graduation_registers_the_subject_lane_recorded_at_launch() public {
        Launched memory l = _launchWithSubject(STOCK_LOW);
        _graduate(l, 1_000e8);
        assertEq(hook.pool(_poolId(l)).subject, address(splitter));
    }

    function test_configureSubject_after_graduation_reaches_the_hook() public {
        Launched memory l = _launch(STOCK_LOW);
        _graduate(l, 1_000e8);
        bytes32 poolId = _poolId(l);
        assertEq(hook.pool(poolId).subject, address(0));

        vm.prank(feeAdministrator);
        launchpad.configureSubject(l.launchId, address(splitter), 1);
        assertEq(hook.pool(poolId).subject, address(splitter));

        vm.prank(feeAdministrator);
        launchpad.configureSubject(l.launchId, address(0), 2);
        assertEq(hook.pool(poolId).subject, address(0));
    }

    function test_graduation_emits_the_record() public {
        Launched memory l = _launch(STOCK_LOW);
        _bidToGraduation(l, 1_000e8);
        vm.recordLogs();
        launchpad.migrate(l.launchId);
        IStocksLaunchpadV1.Launch memory record = _record(l);
        bytes32 topic = keccak256(
            "StockLaunchGraduated(uint256,address,bytes32,uint160,uint256,uint128,uint128,uint256,uint128,uint256,uint256,uint256)"
        );
        bool found;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(launchpad) && logs[i].topics[0] == topic) {
                found = true;
                assertEq(uint256(logs[i].topics[1]), l.launchId);
                (
                    bytes32 poolId,
                    ,
                    uint256 lpTokenId,
                    uint128 lpStockUsed,
                    uint128 lpNewUsed,
                    uint256 lpStockOnlyTokenId,
                    uint128 lpStockOnlyUsed,
                    uint256 stockRaised,
                    uint256 stockDust,
                    uint256 retired
                ) = abi.decode(
                    logs[i].data, (bytes32, uint160, uint256, uint128, uint128, uint256, uint128, uint256, uint256, uint256)
                );
                assertEq(poolId, record.poolId);
                assertEq(lpTokenId, record.lpTokenId);
                assertEq(lpStockUsed, record.lpStockUsed);
                assertEq(lpNewUsed, record.lpNewUsed);
                assertEq(lpStockOnlyTokenId, record.lpStockOnlyTokenId);
                assertEq(lpStockOnlyUsed, record.lpStockOnlyUsed);
                assertEq(stockRaised, l.auction.lbpInitializationParams().currencyRaised);
                assertEq(uint256(lpStockUsed) + lpStockOnlyUsed + stockDust, stockRaised);
                assertEq(retired, record.retiredNew);
            }
        }
        assertTrue(found, "StockLaunchGraduated emitted");
    }

    // -------------------------------------------------------------------------
    // failure
    // -------------------------------------------------------------------------

    function test_failed_minimum_retires_inventory_and_reserve_and_refunds_through_the_cca() public {
        Launched memory l = _launch(STOCK_LOW);
        _rollToStart(l);
        uint128 bidAmount = 10e8; // below the 100e8 required raise
        uint256 bidId = _bidDirect(l, bidder, bidAmount, _bidPrice(1));
        assertEq(FixtureStockToken(l.stock).balanceOf(bidder), 0);
        assertEq(FixtureStockToken(l.stock).balanceOf(address(l.auction)), bidAmount);
        _rollToMigration(l);

        uint256 deadBefore = UERC20(l.newToken).balanceOf(StocksBindings.DEAD_ADDRESS);
        vm.expectEmit(true, true, false, true, address(launchpad));
        emit IStocksLaunchpadV1.StockLaunchRetired(l.launchId, address(l.auction), StocksPreset.INITIAL_SUPPLY);
        launchpad.migrate(l.launchId);

        IStocksLaunchpadV1.Launch memory record = _record(l);
        assertEq(uint8(record.lifecycle), uint8(IStocksLaunchpadV1.Lifecycle.Failed));
        assertEq(record.retiredNew, StocksPreset.INITIAL_SUPPLY, "inventory + reserve retired");
        assertEq(UERC20(l.newToken).balanceOf(StocksBindings.DEAD_ADDRESS) - deadBefore, StocksPreset.INITIAL_SUPPLY);
        assertEq(UERC20(l.newToken).balanceOf(address(launchpad)), 0);
        assertEq(UERC20(l.newToken).balanceOf(address(l.auction)), 0);
        assertEq(record.poolId, bytes32(0), "no pool");
        assertEq(record.lpTokenId, 0, "no position");

        // Bidder STOCK never moved through this component; the CCA refunds it in full.
        assertEq(FixtureStockToken(l.stock).balanceOf(address(launchpad)), 0);
        assertEq(FixtureStockToken(l.stock).balanceOf(address(l.auction)), bidAmount, "still in the auction");
        vm.prank(bidder);
        l.auction.exitBid(bidId);
        assertEq(FixtureStockToken(l.stock).balanceOf(bidder), bidAmount, "full refund");
        assertEq(FixtureStockToken(l.stock).balanceOf(address(l.auction)), 0);
    }

    function test_failed_launch_with_no_bids() public {
        Launched memory l = _launch(STOCK_HIGH);
        _rollToMigration(l);
        launchpad.migrate(l.launchId);
        assertEq(uint8(_record(l).lifecycle), uint8(IStocksLaunchpadV1.Lifecycle.Failed));
        assertEq(UERC20(l.newToken).balanceOf(StocksBindings.DEAD_ADDRESS), StocksPreset.INITIAL_SUPPLY);
    }

    // -------------------------------------------------------------------------
    // guards
    // -------------------------------------------------------------------------

    function test_migrate_guards() public {
        Launched memory l = _launch(STOCK_LOW);

        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.UnknownLaunch.selector, 42));
        launchpad.migrate(42);

        _rollToStart(l);
        _bidDirect(l, bidder, 1_000e8, _bidPrice(10));
        vm.roll(l.auction.endBlock() + StocksPreset.MIGRATION_DELAY_BLOCKS - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                StocksLaunchpadV1.MigrationNotYetAllowed.selector,
                l.auction.endBlock() + StocksPreset.MIGRATION_DELAY_BLOCKS,
                block.number
            )
        );
        launchpad.migrate(l.launchId);

        vm.roll(block.number + 1);
        vm.prank(outsider); // anyone may drive migration
        launchpad.migrate(l.launchId);

        vm.expectRevert(
            abi.encodeWithSelector(StocksLaunchpadV1.LaunchNotActive.selector, IStocksLaunchpadV1.Lifecycle.Graduated)
        );
        launchpad.migrate(l.launchId);
    }

    function test_nobody_can_initialize_the_official_pool_before_migration() public {
        Launched memory l = _launch(STOCK_LOW);
        PoolKey memory key = _poolKey(l);
        vm.expectRevert();
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        vm.expectRevert();
        vm.prank(address(launchpad));
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    function test_no_principal_path_exists_for_either_locked_position() public {
        Launched memory l = _launch(STOCK_LOW);
        _graduate(l, 1_000e8);
        IStocksLaunchpadV1.Launch memory record = _record(l);
        assertNotEq(record.lpStockOnlyTokenId, 0, "a sell-out mints both positions");

        uint256[2] memory tokenIds = [record.lpTokenId, record.lpStockOnlyTokenId];
        address[3] memory callers = [address(launchpad), governance, outsider];
        for (uint256 t; t < tokenIds.length; ++t) {
            bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(tokenIds[t], uint256(1), uint128(0), uint128(0), bytes(""));
            params[1] = abi.encode(_poolKey(l).currency0, _poolKey(l).currency1, address(this));
            for (uint256 i; i < callers.length; ++i) {
                vm.expectRevert();
                vm.prank(callers[i]);
                positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
            }
        }
    }

    function test_launchpad_never_exposes_a_token_or_stock_withdrawal() public {
        // The launchpad's whole external surface is the interface; there is no transfer, sweep, rescue
        // or approve of NEW or STOCK. This proves the balance facts the surface implies.
        Launched memory l = _launch(STOCK_LOW);
        assertEq(UERC20(l.newToken).balanceOf(address(launchpad)), StocksPreset.MIGRATION_RESERVE);
        _graduate(l, 1_000e8);
        assertEq(UERC20(l.newToken).balanceOf(address(launchpad)), 0);
        assertEq(FixtureStockToken(l.stock).balanceOf(address(launchpad)), 0);
    }
}
