// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {ConstantsLib} from "continuous-clearing-auction/libraries/ConstantsLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MemestockLPLocker} from "../../src/MemestockLPLocker.sol";
import {MemestockSplitterV1} from "../../src/MemestockSplitterV1.sol";
import {StockBidAdapterV1} from "../../src/StockBidAdapterV1.sol";
import {StocksBindings} from "../../src/StocksBindings.sol";
import {StocksFeeHookV1} from "../../src/StocksFeeHookV1.sol";
import {StocksLaunchpadV3} from "../../src/StocksLaunchpadV3.sol";
import {StocksPreset} from "../../src/StocksPreset.sol";
import {IStocksLaunchpadV3} from "../../src/interfaces/IStocksLaunchpadV3.sol";
import {AerodromeStockRouteV2} from "../../src/routes/AerodromeStockRouteV2.sol";
import {V2Schedule} from "../V2Schedule.sol";

/// @notice Version 3 on a local copy of Base mainnet, which has made a block every 0.2 seconds since
///         Denim (block 53,556,127, 5 November 2026 18:00:01 UTC). Everything is the real thing: the
///         pinned CCA factory, Permit2, PoolManager, PositionManager, USDC, REGENT staking, the UERC20
///         factory and the AAPLc route version 2 deployed, and AAPLc itself, a Base stock token whose
///         one-byte `0xef` code only `--network base` runs. The launchpad, adapter and hook are built
///         here exactly as the deployment builds them, and the Governance and Regent Safe's own calls
///         open them. Nothing is sent to Base: the copy is local to Forge.
///
///         Version 2's lab lifecycle suite (`contracts/stocks-v2/test/fork`) is ported here, with the
///         real stock and route in place of its fixtures, plus the wall-clock and gas checks the
///         faster blocks call for.
contract StocksBaseCopyTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint256 internal constant DENIM_BLOCK = 53_556_127;
    uint256 internal constant BLOCKS_PER_SECOND = 5;
    /// @dev Version 2's UERC20 factory, which version 3 binds unchanged.
    address internal constant UERC20_FACTORY = 0x4c003500c6a28826d15A6E4cF023C1f1ecd41E08;
    address internal constant AAPLC = 0xb200000000000000000000C2e324d24d7eEcd1fb;
    /// @dev The AerodromeStockRouteV2 version 2 deployed for AAPLc, and the Slipstream pool it trades.
    address internal constant AAPLC_ROUTE = 0xc0e910234d2a057Eb5E78B69C5149567617c0563;
    address internal constant AAPLC_POOL = 0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0;
    /// @dev A large USDC holder on Base (Morpho Blue).
    address internal constant USDC_HOLDER = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    /// @dev The widest gap, in mps, between version 3 and version 2 at the same wall-clock time.
    uint256 internal constant WIDEST_GAP_MPS = 10_218;
    uint256 internal constant FLOOR_PRICE_Q96 = StocksPreset.FLOOR_PRICE_Q96;
    /// @dev A price limit far above where these bids clear, so each exits through `exitBid`.
    uint256 internal constant GRADUATING_TICKS = 10_000_000;

    StocksLaunchpadV3 internal launchpad;
    StocksFeeHookV1 internal hook;
    StockBidAdapterV1 internal adapter;
    PoolSwapTest internal swapRouter;
    IERC20 internal stock = IERC20(AAPLC);
    IERC20 internal usdc = IERC20(StocksBindings.USDC);
    IERC20 internal regent = IERC20(StocksBindings.REGENT);
    AerodromeStockRouteV2 internal route = AerodromeStockRouteV2(AAPLC_ROUTE);

    address internal governance = StocksBindings.GOVERNANCE_AND_REGENT_SAFE;
    address internal launcher = makeAddr("stocks-launcher");
    address internal bidderDirect = makeAddr("bidder-direct");
    address internal bidderUsdc = makeAddr("bidder-usdc");

    uint256 internal forkBlock;

    function setUp() public {
        assertEq(block.chainid, BASE_CHAIN_ID, "a copy of Base mainnet");
        assertGt(block.number, DENIM_BLOCK, "after Denim");
        forkBlock = block.number;
        assertEq(route.stock(), AAPLC, "version 2's AAPLc route");
        assertEq(IERC20Metadata(AAPLC).symbol(), "AAPLc");

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        (, bytes32 salt) = HookMiner.find(
            predicted,
            HOOK_FLAGS,
            type(StocksFeeHookV1).creationCode,
            abi.encode(StocksBindings.POOL_MANAGER, predicted)
        );
        launchpad = new StocksLaunchpadV3(UERC20_FACTORY, salt);
        hook = StocksFeeHookV1(launchpad.hook());
        adapter = new StockBidAdapterV1(address(launchpad));
        swapRouter = new PoolSwapTest(IPoolManager(StocksBindings.POOL_MANAGER));
        assertTrue(launchpad.launchesPaused(), "born paused");

        // The Safe's switch-on calls, from the Safe's own address.
        vm.startPrank(governance);
        launchpad.admitStock(AAPLC, AAPLC_ROUTE);
        hook.setExecutor(address(this));
        launchpad.unpauseLaunches();
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Base's clock
    // -------------------------------------------------------------------------

    /// @dev The copy's own history: 1,000 blocks span 200 seconds.
    function test_base_makes_five_blocks_a_second() public {
        vm.rollFork(forkBlock - 1000);
        uint256 earlier = vm.getBlockTimestamp();
        vm.rollFork(forkBlock);
        assertApproxEqAbs(vm.getBlockTimestamp() - earlier, 200, 1, "1,000 blocks in 200 seconds");
    }

    /// @dev A launch at five blocks a second: ten minutes to the opening, a day of auction, claims 128
    ///      seconds and the pool 256 seconds after the end, and thirty days of creator vesting.
    function test_base_launch_runs_its_day_on_the_base_clock() public {
        (uint256 launchId, address newToken, IContinuousClearingAuction auction) = _launch();
        uint64 startBlock = auction.startBlock();
        uint64 endBlock = auction.endBlock();
        assertEq(startBlock, forkBlock + StocksPreset.START_LEAD_BLOCKS, "opens 3,000 blocks after creation");
        assertEq(endBlock - startBlock, StocksPreset.AUCTION_DURATION_BLOCKS);

        _elapse(600);
        assertEq(vm.getBlockNumber(), startBlock, "ten minutes to the opening block");
        uint256 openedAt = vm.getBlockTimestamp();
        uint256 bidId = _bidDirect(auction, bidderDirect, 1e8, _bidPrice(GRADUATING_TICKS));

        _elapse(12 hours);
        uint256 released = auction.checkpoint().cumulativeMps;
        assertEq(released, V2Schedule.released(StocksPreset.AUCTION_STEPS, 12 hours * 5), "the schedule at 12 h");
        assertApproxEqAbs(
            released, V2Schedule.released(V2Schedule.AUCTION_STEPS, 12 hours / 2), WIDEST_GAP_MPS, "version 2 at 12 h"
        );

        _elapse(12 hours - 2);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(vm.getBlockNumber(), endBlock, "the end block");
        assertApproxEqAbs(vm.getBlockTimestamp() - openedAt, 1 days, 2, "a day of wall-clock time");
        assertEq(auction.checkpoint().cumulativeMps, ConstantsLib.MPS, "everything released by the end");

        _elapse(128);
        assertEq(vm.getBlockNumber(), auction.claimBlock(), "claims open 128 seconds after the end");
        _elapse(127);
        vm.roll(vm.getBlockNumber() + 4);
        vm.expectRevert();
        launchpad.migrate(launchId);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(vm.getBlockNumber(), launchpad.launches(launchId).migrationBlock, "the pool 256 seconds after the end");
        launchpad.migrate(launchId);
        IStocksLaunchpadV3.Launch memory record = launchpad.launches(launchId);
        assertEq(uint8(record.lifecycle), uint8(IStocksLaunchpadV3.Lifecycle.Graduated));
        assertEq(record.vestingStart, vm.getBlockTimestamp(), "vesting starts at the graduation timestamp");

        vm.startPrank(bidderDirect);
        auction.exitBid(bidId);
        auction.claimTokens(bidId);
        vm.stopPrank();
        assertGt(IERC20(newToken).balanceOf(bidderDirect), 0, "the bidder holds NEW");

        _elapse(15 days);
        assertEq(
            launchpad.releaseCreatorVesting(launchId), uint256(StocksPreset.CREATOR_VESTING) / 2, "half at 15 days"
        );
        _elapse(15 days);
        launchpad.releaseCreatorVesting(launchId);
        assertEq(IERC20(newToken).balanceOf(launcher), StocksPreset.CREATOR_VESTING, "all of it at 30 days");
    }

    /// @dev The step loop's worst case: an auction nobody touched, checkpointed once after its end,
    ///      walks all thirteen steps in one call.
    function test_base_a_checkpoint_across_every_step_is_cheap() public {
        (,, IContinuousClearingAuction auction) = _launch();
        vm.roll(auction.endBlock());
        uint256 before = gasleft();
        auction.checkpoint();
        uint256 used = before - gasleft();
        emit log_named_uint("gas for one checkpoint across all thirteen steps", used);
        assertEq(auction.checkpoint().cumulativeMps, ConstantsLib.MPS);
        assertLt(used, 500_000, "far inside one Base block");
    }

    // -------------------------------------------------------------------------
    // creation terms against the real pinned CCA factory
    // -------------------------------------------------------------------------

    function test_base_launch_costs_nothing_and_opens_ten_minutes_after_creation() public {
        assertEq(regent.balanceOf(launcher), 0, "the launcher holds no REGENT");
        uint256 launchpadBefore = regent.balanceOf(address(launchpad));
        uint256 stakingBefore = regent.balanceOf(StocksBindings.LIVE_STAKING);
        uint64 creationBlock = uint64(block.number);

        (uint256 launchId,, IContinuousClearingAuction auction) = _launch();
        IStocksLaunchpadV3.Launch memory record = launchpad.launches(launchId);
        assertEq(record.startBlock, creationBlock + StocksPreset.START_LEAD_BLOCKS, "creation block + 3,000");
        assertEq(auction.startBlock(), record.startBlock, "the real auction opens on the recorded block");
        assertEq(auction.endBlock(), record.startBlock + StocksPreset.AUCTION_DURATION_BLOCKS);
        assertEq(auction.claimBlock(), auction.endBlock() + StocksPreset.CLAIM_DELAY_BLOCKS);
        assertEq(auction.floorPrice(), FLOOR_PRICE_Q96, "every launch has the one floor");
        assertEq(regent.balanceOf(launcher), 0, "nothing was pulled");
        assertEq(regent.balanceOf(address(launchpad)), launchpadBefore, "the launchpad holds no REGENT");
        assertEq(regent.balanceOf(StocksBindings.LIVE_STAKING), stakingBefore, "real staking received nothing");

        // A raise bidders did not meet fails through the CCA, and still no REGENT has moved anywhere.
        vm.roll(auction.startBlock());
        _bidDirect(auction, bidderDirect, StocksPreset.REQUIRED_STOCK_RAISED - 1, _bidPrice(1));
        vm.roll(uint256(auction.endBlock()) + StocksPreset.MIGRATION_DELAY_BLOCKS);
        launchpad.migrate(launchId);
        assertEq(uint8(launchpad.launches(launchId).lifecycle), uint8(IStocksLaunchpadV3.Lifecycle.Failed));
        assertEq(regent.balanceOf(launcher), 0);
        assertEq(regent.balanceOf(address(launchpad)), launchpadBefore);
        assertEq(regent.balanceOf(StocksBindings.LIVE_STAKING), stakingBefore);
    }

    // -------------------------------------------------------------------------
    // graduated lifecycle
    // -------------------------------------------------------------------------

    function test_base_full_lifecycle_graduates_and_settles_the_regent_lane_into_live_staking() public {
        (uint256 launchId, address newToken, IContinuousClearingAuction auction) = _launch();
        vm.roll(auction.startBlock());

        // Bid one: AAPLc straight through the real Permit2.
        uint256 directBid = _bidDirect(auction, bidderDirect, 1e8, _bidPrice(GRADUATING_TICKS));
        // Bid two: USDC -> AAPLc through the real route and Aerodrome pool, then the bid, by the adapter.
        uint256 usdcIn = 300e6;
        uint128 minStock = uint128(route.quoteExactIn(StocksBindings.USDC, AAPLC, usdcIn) * 90 / 100);
        vm.prank(USDC_HOLDER);
        usdc.transfer(bidderUsdc, usdcIn);
        vm.startPrank(bidderUsdc);
        usdc.approve(address(adapter), usdcIn);
        (uint256 adapterBid, uint128 committed) = adapter.bidWithUsdc(
            address(auction), usdcIn, minStock, _bidPrice(GRADUATING_TICKS / 2), FLOOR_PRICE_Q96, block.timestamp
        );
        vm.stopPrank();
        assertGe(committed, minStock, "the route bought at least the minimum");
        assertEq(auction.bids(adapterBid).owner, bidderUsdc);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(stock.balanceOf(address(adapter)), 0);
        (uint160 permit2Allowance,,) =
            IAllowanceTransfer(StocksBindings.PERMIT2).allowance(address(adapter), AAPLC, address(auction));
        assertEq(permit2Allowance, 0);

        vm.roll(uint256(auction.endBlock()) + StocksPreset.MIGRATION_DELAY_BLOCKS);
        launchpad.migrate(launchId);

        IStocksLaunchpadV3.Launch memory record = launchpad.launches(launchId);
        assertEq(uint8(record.lifecycle), uint8(IStocksLaunchpadV3.Lifecycle.Graduated));
        PoolKey memory key = _poolKey(newToken);
        assertEq(PoolId.unwrap(key.toId()), record.poolId, "the derived key is the registered pool");
        (uint160 sqrtPriceX96,,,) = IPoolManager(StocksBindings.POOL_MANAGER).getSlot0(PoolId.wrap(record.poolId));
        assertEq(sqrtPriceX96, record.finalSqrtPriceX96, "real PoolManager initialized at the final clearing price");
        assertGt(IPoolManager(StocksBindings.POOL_MANAGER).getLiquidity(PoolId.wrap(record.poolId)), 0);
        assertEq(IERC20(newToken).balanceOf(address(launchpad)), StocksPreset.CREATOR_VESTING, "only the vesting stays");
        assertEq(IERC20(newToken).balanceOf(StocksBindings.DEAD_ADDRESS), record.retiredNew, "at the dead address");
        assertEq(stock.balanceOf(address(launchpad)), 0);
        _assertLocked(record, auction.lbpInitializationParams().currencyRaised);

        // Both bidders settle through the CCA; between them they hold the whole sale allocation but
        // for crumbs.
        vm.startPrank(bidderDirect);
        auction.exitBid(directBid);
        auction.claimTokens(directBid);
        vm.stopPrank();
        vm.startPrank(bidderUsdc);
        auction.exitBid(adapterBid);
        auction.claimTokens(adapterBid);
        vm.stopPrank();
        assertApproxEqAbs(
            IERC20(newToken).balanceOf(bidderDirect) + IERC20(newToken).balanceOf(bidderUsdc),
            StocksPreset.AUCTION_INVENTORY,
            StocksPreset.INITIAL_SUPPLY / FLOOR_PRICE_Q96,
            "the bidders hold the whole sale allocation"
        );

        // Swaps on the real PoolManager are charged in AAPLc, both directions.
        _approveRouter(bidderDirect, newToken);
        _takeStock(bidderDirect, 1e8);
        bool stockIs0 = AAPLC < newToken;
        (uint256 creatorBefore, uint256 regentBefore, uint256 stakerBefore) = hook.accrued(record.poolId);
        uint256 stockBefore = stock.balanceOf(bidderDirect);
        vm.prank(bidderDirect);
        swapRouter.swap(
            key,
            SwapParams(stockIs0, -int256(1e8), stockIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(stockBefore - stock.balanceOf(bidderDirect), 1e8, "exact AAPLc input");
        (uint256 creatorLane, uint256 regentLane, uint256 stakerLane) = hook.accrued(record.poolId);
        assertEq(creatorLane - creatorBefore, 1e8 * 30 / 10_000, "creator lane 0.3%");
        assertEq(regentLane - regentBefore, 1e8 / 100, "REGENT lane 1%");
        assertEq(stakerLane - stakerBefore, 1e8 * 300 / 10_000, "staker lane 3%");

        regentBefore = regentLane;
        vm.prank(bidderDirect);
        swapRouter.swap(
            key,
            SwapParams(!stockIs0, -int256(1e22), !stockIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        (, regentLane,) = hook.accrued(record.poolId);
        assertGt(regentLane, regentBefore, "AAPLc output charged");

        // Settle half the REGENT lane through the real route into the real live staking contract.
        uint256 amount = regentLane / 2;
        uint256 minUsdc = route.quoteExactIn(AAPLC, StocksBindings.USDC, amount) * 90 / 100;
        uint256 stakingBefore = usdc.balanceOf(StocksBindings.LIVE_STAKING);
        hook.settleRegentLane(record.poolId, amount, minUsdc);
        (, uint256 converted, uint256 deposited,) = hook.settled(record.poolId);
        assertEq(converted, amount);
        assertGe(deposited, minUsdc, "the route paid at least the minimum");
        assertEq(usdc.balanceOf(StocksBindings.LIVE_STAKING) - stakingBefore, deposited, "live staking received USDC");
        (, uint256 regentAfter,) = hook.accrued(record.poolId);
        assertEq(regentAfter, regentLane - amount);
        assertEq(usdc.balanceOf(address(hook)), 0);
        assertEq(usdc.allowance(address(hook), StocksBindings.LIVE_STAKING), 0);
    }

    // -------------------------------------------------------------------------
    // failed minimum
    // -------------------------------------------------------------------------

    function test_base_failed_minimum_retires_and_refunds_through_the_cca() public {
        (uint256 launchId, address newToken, IContinuousClearingAuction auction) = _launch();
        vm.roll(auction.startBlock());
        uint128 short = StocksPreset.REQUIRED_STOCK_RAISED / 2;
        uint256 bidId = _bidDirect(auction, bidderDirect, short, _bidPrice(1));
        vm.roll(uint256(auction.endBlock()) + StocksPreset.MIGRATION_DELAY_BLOCKS);

        uint256 deadBefore = IERC20(newToken).balanceOf(StocksBindings.DEAD_ADDRESS);
        launchpad.migrate(launchId);
        IStocksLaunchpadV3.Launch memory record = launchpad.launches(launchId);
        assertEq(uint8(record.lifecycle), uint8(IStocksLaunchpadV3.Lifecycle.Failed));
        assertEq(IERC20(newToken).balanceOf(StocksBindings.DEAD_ADDRESS) - deadBefore, StocksPreset.INITIAL_SUPPLY);
        assertEq(IERC20(newToken).balanceOf(address(launchpad)), 0);

        vm.prank(bidderDirect);
        auction.exitBid(bidId);
        assertEq(stock.balanceOf(bidderDirect), short, "full refund through the CCA");
    }

    // -------------------------------------------------------------------------
    // memestock staking against the real PositionManager and live staking
    // -------------------------------------------------------------------------

    function test_base_stakers_receive_the_staker_lane_and_the_locked_positions_fees() public {
        (uint256 launchId, address newToken, IContinuousClearingAuction auction) = _launch();
        vm.roll(auction.startBlock());
        uint256 bidId = _bidDirect(auction, bidderDirect, 1e8, _bidPrice(GRADUATING_TICKS));
        vm.roll(uint256(auction.endBlock()) + StocksPreset.MIGRATION_DELAY_BLOCKS);
        launchpad.migrate(launchId);
        IStocksLaunchpadV3.Launch memory record = launchpad.launches(launchId);
        MemestockSplitterV1 splitter = MemestockSplitterV1(record.splitter);
        MemestockLPLocker locker = MemestockLPLocker(launchpad.locker());
        assertEq(hook.pool(record.poolId).splitter, record.splitter);
        assertEq(splitter.memestock(), newToken);
        assertEq(splitter.stock(), AAPLC);
        _assertLocked(record, auction.lbpInitializationParams().currencyRaised);

        // The bidder claims its NEW and stakes half of it.
        vm.startPrank(bidderDirect);
        auction.exitBid(bidId);
        auction.claimTokens(bidId);
        uint256 staked = IERC20(newToken).balanceOf(bidderDirect) / 2;
        IERC20(newToken).approve(record.splitter, staked);
        splitter.stake(staked);
        vm.stopPrank();
        // Exit and claim are refused in the staking block.
        vm.roll(block.number + 1);

        // One swap each way so both pool currencies earn LP fees.
        _approveRouter(bidderDirect, newToken);
        _takeStock(bidderDirect, 1e8);
        bool stockIs0 = AAPLC < newToken;
        PoolKey memory key = _poolKey(newToken);
        vm.startPrank(bidderDirect);
        swapRouter.swap(
            key,
            SwapParams(stockIs0, -int256(1e8), stockIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        swapRouter.swap(
            key,
            SwapParams(!stockIs0, -int256(1e22), !stockIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();

        // Anyone settles the staker lane: AAPLc in kind, 2% to the Safe, the rest to the staker.
        (,, uint256 stakerLane) = hook.accrued(record.poolId);
        assertGt(stakerLane, 0, "staker lane accrued on both swaps");
        uint256 safeStockBefore = stock.balanceOf(governance);
        assertEq(hook.settleStakerLane(record.poolId), stakerLane);
        uint256 laneSkim = stakerLane * 200 / 10_000;
        assertEq(stock.balanceOf(governance) - safeStockBefore, laneSkim, "2% of the lane to the Safe");
        assertEq(stock.allowance(address(hook), record.splitter), 0);

        // Anyone collects the locked position's LP fees into the same splitter, both currencies.
        uint256 splitterStockBefore = stock.balanceOf(record.splitter);
        uint256 splitterNewBefore = IERC20(newToken).balanceOf(record.splitter);
        (uint256 fees0, uint256 fees1) = locker.collect(record.lpTokenId);
        uint256 stockFees = stockIs0 ? fees0 : fees1;
        uint256 newFees = stockIs0 ? fees1 : fees0;
        assertGt(stockFees, 0, "LP fees in AAPLc");
        assertGt(newFees, 0, "LP fees in NEW");
        assertEq(stock.balanceOf(address(locker)), 0, "the locker keeps nothing");
        assertEq(IERC20(newToken).balanceOf(address(locker)), 0);
        assertApproxEqAbs(
            stock.balanceOf(record.splitter) - splitterStockBefore, stockFees - stockFees * 200 / 10_000, 2
        );
        assertApproxEqAbs(
            IERC20(newToken).balanceOf(record.splitter) - splitterNewBefore, newFees - newFees * 200 / 10_000, 2
        );
        assertEq(IERC721(StocksBindings.POSITION_MANAGER).ownerOf(record.lpTokenId), address(locker));

        // The sole staker claims everything recognized, in kind.
        uint256 stockBalance = stock.balanceOf(bidderDirect);
        uint256 newBalance = IERC20(newToken).balanceOf(bidderDirect);
        vm.prank(bidderDirect);
        splitter.claimAll();
        assertApproxEqAbs(
            stock.balanceOf(bidderDirect) - stockBalance,
            (stakerLane - laneSkim) + (stockFees - stockFees * 200 / 10_000),
            4
        );
        assertApproxEqAbs(IERC20(newToken).balanceOf(bidderDirect) - newBalance, newFees - newFees * 200 / 10_000, 2);

        // USDC revenue: 2% goes straight into the real live staking contract.
        vm.startPrank(USDC_HOLDER);
        usdc.approve(record.splitter, 1_000e6);
        uint256 stakingBefore = usdc.balanceOf(StocksBindings.LIVE_STAKING);
        splitter.depositRecognizedRevenue(StocksBindings.USDC, 1_000e6, bytes32("base copy"));
        vm.stopPrank();
        assertEq(usdc.balanceOf(StocksBindings.LIVE_STAKING) - stakingBefore, 20e6, "USDC share reached live staking");
        assertEq(usdc.allowance(record.splitter, StocksBindings.LIVE_STAKING), 0);
        assertApproxEqAbs(splitter.claimable(StocksBindings.USDC, bidderDirect), 980e6, 1);
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    /// @dev On the real PositionManager: the full-range position pairing the whole raise and the
    ///      NEW-only position holding the rest of the reserve, both held by the fee-only locker.
    function _assertLocked(IStocksLaunchpadV3.Launch memory record, uint256 raised) private view {
        IERC721 nft = IERC721(StocksBindings.POSITION_MANAGER);
        IPositionManager positions = IPositionManager(StocksBindings.POSITION_MANAGER);
        int24 spacing = StocksPreset.POOL_TICK_SPACING;

        assertEq(nft.ownerOf(record.lpTokenId), launchpad.locker(), "full range to the locker");
        (PoolKey memory key, PositionInfo info) = positions.getPoolAndPositionInfo(record.lpTokenId);
        assertEq(PoolId.unwrap(key.toId()), record.poolId);
        assertEq(info.tickLower(), TickMath.minUsableTick(spacing));
        assertEq(info.tickUpper(), TickMath.maxUsableTick(spacing));
        // The full range pairs the whole raise; a NEW-only position exists only when the reserve it
        // left holds at least one unit of liquidity, which small raises like these may not.
        if (record.newOnlyTokenId == 0) {
            assertEq(record.newOnlyUsed, 0, "no NEW-only position, nothing placed in one");
            assertEq(positions.nextTokenId(), record.lpTokenId + 1, "one position minted");
        } else {
            assertEq(record.newOnlyTokenId, record.lpTokenId + 1, "the NEW-only position is the second mint");
            assertEq(nft.ownerOf(record.newOnlyTokenId), launchpad.locker(), "NEW-only position to the locker");
            assertEq(positions.nextTokenId(), record.lpTokenId + 2, "two positions minted");
        }

        (, uint256 dust,) = hook.accrued(record.poolId);
        assertEq(uint256(record.lpStockUsed) + dust, raised, "raised == paired + dust");
        assertLe(dust, raised / 1e9 + 2, "dust is rounding");
        assertApproxEqAbs(
            uint256(record.lpNewUsed) + record.newOnlyUsed,
            StocksPreset.MIGRATION_RESERVE,
            StocksPreset.INITIAL_SUPPLY / FLOOR_PRICE_Q96,
            "the reserve is placed"
        );
        assertEq(stock.balanceOf(address(hook)), dust, "the hook holds exactly the dust");
    }

    function _launch() private returns (uint256 launchId, address newToken, IContinuousClearingAuction auction) {
        IStocksLaunchpadV3.LaunchParams memory params = IStocksLaunchpadV3.LaunchParams({
            name: string.concat("Base Copy ", vm.toString(launchpad.nextLaunchId())),
            symbol: "BCOPY",
            description: "Base copy lifecycle",
            website: "https://autolaunch.sh",
            image: "ipfs://image",
            stock: AAPLC
        });
        address auctionAddress;
        vm.prank(launcher);
        (launchId, newToken, auctionAddress) = launchpad.launch(params);
        auction = IContinuousClearingAuction(auctionAddress);
    }

    /// @dev The official pool key, as the launchpad derives it; checked against `record.poolId`.
    function _poolKey(address newToken) private view returns (PoolKey memory) {
        bool stockIs0 = AAPLC < newToken;
        return PoolKey({
            currency0: Currency.wrap(stockIs0 ? AAPLC : newToken),
            currency1: Currency.wrap(stockIs0 ? newToken : AAPLC),
            fee: StocksPreset.POOL_FEE,
            tickSpacing: StocksPreset.POOL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _bidPrice(uint256 ticks) private pure returns (uint256) {
        return FLOOR_PRICE_Q96 + ticks * StocksPreset.BID_TICK_SPACING_Q96;
    }

    /// @dev Real AAPLc cannot be minted; it comes out of the Slipstream pool the route trades.
    function _takeStock(address to, uint256 amount) private {
        vm.prank(AAPLC_POOL);
        stock.transfer(to, amount);
    }

    function _bidDirect(IContinuousClearingAuction auction, address account, uint128 amount, uint256 price)
        private
        returns (uint256 bidId)
    {
        _takeStock(account, amount);
        vm.startPrank(account);
        stock.approve(StocksBindings.PERMIT2, amount);
        IAllowanceTransfer(StocksBindings.PERMIT2).approve(AAPLC, address(auction), uint160(amount), type(uint48).max);
        bidId = auction.submitBid(price, amount, account, FLOOR_PRICE_Q96, "");
        vm.stopPrank();
    }

    function _approveRouter(address account, address newToken) private {
        vm.startPrank(account);
        stock.approve(address(swapRouter), type(uint256).max);
        IERC20(newToken).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Five blocks to each second, as Base makes them.
    function _elapse(uint256 seconds_) private {
        vm.roll(vm.getBlockNumber() + BLOCKS_PER_SECOND * seconds_);
        vm.warp(vm.getBlockTimestamp() + seconds_);
    }
}

