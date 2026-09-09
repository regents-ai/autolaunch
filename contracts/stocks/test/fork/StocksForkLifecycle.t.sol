// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {TickCalculations} from "liquidity-launcher/src/libraries/TickCalculations.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
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
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {StockBidAdapterV1} from "../../src/StockBidAdapterV1.sol";
import {StocksBindings} from "../../src/StocksBindings.sol";
import {StocksFeeHookV1} from "../../src/StocksFeeHookV1.sol";
import {StocksLaunchpadV1} from "../../src/StocksLaunchpadV1.sol";
import {StocksPreset} from "../../src/StocksPreset.sol";
import {FixtureStockToken} from "../../src/fixtures/FixtureStockToken.sol";
import {IAgentStrategyMinimal} from "../../src/interfaces/IAgentStrategyMinimal.sol";
import {IStocksLaunchpadV1} from "../../src/interfaces/IStocksLaunchpadV1.sol";
import {FixtureStockRoute} from "../../src/routes/FixtureStockRoute.sol";
import {ForkAddresses} from "./ForkAddresses.sol";

/// @dev The frozen Agent factory's launch surface, as deployed on the fork.
interface IAgentFactory {
    struct LaunchParams {
        string name;
        string symbol;
        string description;
        string website;
        string image;
        address treasury;
        uint128 requiredRegentRaised;
        uint256 expectedLaunchFee;
    }

    function launch(LaunchParams calldata params)
        external
        returns (uint256 launchId, address subject, address auction, address escrow);
    function launchFee() external view returns (uint256);
    function launchesPaused() external view returns (bool);
}

interface IAgentStrategy is IAgentStrategyMinimal {
    function migrate(address auction) external;
    function FLOOR_PRICE_Q96() external view returns (uint256);
    function BID_TICK_Q96() external view returns (uint256);
    function MIGRATION_DELAY_BLOCKS() external view returns (uint64);
}

/// @dev The live REGENT staking contract's reward-funding read surface, as deployed on Base.
interface ILiveStaking {
    function stakeToken() external view returns (address);
    function totalFundedRegent() external view returns (uint256);
}

/// @notice One complete Stocks lifecycle against the live local Base fork: the real pinned CCA
///         factory, PoolManager, PositionManager, Permit2, USDC and REGENT staking, the Agent graph
///         the lab deployed, and a fixture STOCK installed at the real AAPLc address. Nothing here is
///         B20-verified: the fixture replaces the `0xef` code Anvil cannot execute.
contract StocksForkLifecycleTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using TickCalculations for int24;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint256 internal constant USDC_PER_SHARE = 230_000000;
    uint256 internal constant FLOOR_PRICE_Q96 = 7_922_816_251_400;

    StocksLaunchpadV1 internal launchpad;
    StocksFeeHookV1 internal hook;
    StockBidAdapterV1 internal adapter;
    FixtureStockRoute internal route;
    FixtureStockToken internal stock = FixtureStockToken(ForkAddresses.AAPLC);
    IERC20 internal usdc = IERC20(StocksBindings.USDC);
    IERC20 internal regent = IERC20(StocksBindings.REGENT);
    ILiveStaking internal liveStaking = ILiveStaking(StocksBindings.LIVE_STAKING);
    PoolSwapTest internal swapRouter;

    address internal governance = StocksBindings.GOVERNANCE_AND_REGENT_SAFE;
    address internal launcher = makeAddr("stocks-launcher");
    address internal feeAdministrator = makeAddr("stocks-fee-admin");
    address internal bidderDirect = makeAddr("bidder-direct");
    address internal bidderUsdc = makeAddr("bidder-usdc");

    function setUp() public {
        vm.skip(block.chainid != ForkAddresses.LOCAL_CHAIN_ID);
        _requireCode(StocksBindings.CCA_FACTORY, "CCA factory");
        _requireCode(StocksBindings.POOL_MANAGER, "PoolManager");
        _requireCode(StocksBindings.POSITION_MANAGER, "PositionManager");
        _requireCode(StocksBindings.PERMIT2, "Permit2");
        _requireCode(StocksBindings.USDC, "USDC");
        _requireCode(StocksBindings.LIVE_STAKING, "live staking");
        _requireCode(ForkAddresses.AGENT_STRATEGY, "Agent strategy (restart the Agent lab and update ForkAddresses)");
        _requireCode(ForkAddresses.UERC20_FACTORY, "UERC20 factory");

        // The real AAPLc carries one byte of `0xef` code on a fresh fork; once the lab controller has
        // run, the fixture is already there. Either way this suite installs its own copy.
        bool placeholder = ForkAddresses.AAPLC.code.length == 1;
        if (!placeholder) assertEq(ForkAddresses.AAPLC.codehash, keccak256(type(FixtureStockToken).runtimeCode), "unknown code at AAPLc");
        vm.etch(ForkAddresses.AAPLC, type(FixtureStockToken).runtimeCode);
        assertEq(stock.symbol(), "AAPLc");
        assertEq(stock.decimals(), 8);

        bytes32 salt;
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        (, salt) = HookMiner.find(
            predicted, HOOK_FLAGS, type(StocksFeeHookV1).creationCode, abi.encode(StocksBindings.POOL_MANAGER, predicted)
        );
        launchpad = new StocksLaunchpadV1(ForkAddresses.UERC20_FACTORY, ForkAddresses.AGENT_STRATEGY, salt);
        hook = StocksFeeHookV1(launchpad.hook());
        adapter = new StockBidAdapterV1(address(launchpad));
        route = new FixtureStockRoute(ForkAddresses.AAPLC, USDC_PER_SHARE);
        swapRouter = new PoolSwapTest(IPoolManager(StocksBindings.POOL_MANAGER));

        stock.mint(address(route), 10_000_000e8);
        vm.prank(ForkAddresses.USDC_HOLDER);
        usdc.transfer(address(route), 5_000_000e6);

        // The live staking contract's stake token is REGENT: the launch fee lands where it must.
        assertEq(liveStaking.stakeToken(), StocksBindings.REGENT, "live staking stakes REGENT");

        vm.startPrank(governance);
        launchpad.admitStock(ForkAddresses.AAPLC, address(route));
        hook.setExecutor(address(this));
        launchpad.unpauseLaunches();
        // The Governance and REGENT Safe holds the forked REGENT supply; it funds the launcher's fees.
        regent.transfer(launcher, 10 * StocksPreset.LAUNCH_FEE_REGENT);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // launch fee against the real live staking contract
    // -------------------------------------------------------------------------

    function test_fork_launch_fee_is_funded_into_the_real_live_staking_as_rewards() public {
        uint256 fee = launchpad.launchFee();
        assertEq(fee, StocksPreset.LAUNCH_FEE_REGENT);
        uint256 launcherBefore = regent.balanceOf(launcher);
        uint256 launchpadBefore = regent.balanceOf(address(launchpad));
        uint256 stakingBefore = regent.balanceOf(StocksBindings.LIVE_STAKING);
        uint256 fundedBefore = liveStaking.totalFundedRegent();

        IStocksLaunchpadV1.LaunchParams memory params = _launchParams(address(0));
        uint256 launchId = launchpad.nextLaunchId();
        vm.prank(launcher);
        regent.approve(address(launchpad), fee);
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit IStocksLaunchpadV1.StockLaunchFeeCollected(launchId, launcher, StocksBindings.LIVE_STAKING, fee);
        vm.prank(launcher);
        (uint256 created,, address auctionAddress) = launchpad.launch(params);
        assertEq(created, launchId);
        IContinuousClearingAuction auction = IContinuousClearingAuction(auctionAddress);

        assertEq(launcherBefore - regent.balanceOf(launcher), fee, "exactly the fee left the launcher");
        assertEq(regent.balanceOf(address(launchpad)), launchpadBefore, "the launchpad keeps none of it");
        assertEq(regent.balanceOf(StocksBindings.LIVE_STAKING) - stakingBefore, fee, "real staking holds the fee");
        assertEq(liveStaking.totalFundedRegent() - fundedBefore, fee, "real staking counts it as staker rewards");
        assertEq(regent.allowance(launcher, address(launchpad)), 0);
        assertEq(regent.allowance(address(launchpad), StocksBindings.LIVE_STAKING), 0);

        // A stale or inexact fee is refused before anything moves.
        params = _launchParams(address(0));
        params.expectedLaunchFee = fee - 1;
        vm.prank(launcher);
        regent.approve(address(launchpad), fee);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.StaleLaunchFee.selector, fee, fee - 1));
        vm.prank(launcher);
        launchpad.launch(params);
        params.expectedLaunchFee = fee;
        vm.prank(launcher);
        regent.approve(address(launchpad), fee + 1);
        vm.expectRevert(abi.encodeWithSelector(StocksLaunchpadV1.LaunchFeeAllowanceMismatch.selector, fee, fee + 1));
        vm.prank(launcher);
        launchpad.launch(params);
        vm.prank(launcher);
        regent.approve(address(launchpad), 0);

        // The fee stays with stakers whatever happens to the launch: a failed minimum refunds bidders
        // through the CCA and returns nothing to the launcher.
        vm.roll(auction.startBlock());
        _bidDirect(auction, bidderDirect, 10e8, _bidPrice(1));
        vm.roll(uint256(auction.endBlock()) + StocksPreset.MIGRATION_DELAY_BLOCKS);
        launchpad.migrate(launchId);
        assertEq(uint8(launchpad.launches(launchId).lifecycle), uint8(IStocksLaunchpadV1.Lifecycle.Failed));
        assertEq(liveStaking.totalFundedRegent() - fundedBefore, fee, "still funded after a failed minimum");
        assertEq(regent.balanceOf(launcher), launcherBefore - fee, "nothing came back");
        assertEq(regent.balanceOf(address(launchpad)), launchpadBefore);
    }

    // -------------------------------------------------------------------------
    // graduated lifecycle
    // -------------------------------------------------------------------------

    function test_fork_full_lifecycle_graduates_and_settles_the_regent_bucket_into_live_staking() public {
        (uint256 launchId, address newToken, IContinuousClearingAuction auction) = _launch(address(0));
        vm.roll(auction.startBlock());

        // Bid one: direct STOCK through the real Permit2, owner = bidder.
        uint256 directBid = _bidDirect(auction, bidderDirect, 300e8, _bidPrice(10));
        // Bid two: USDC -> STOCK -> bid through the adapter, owner = bidder.
        vm.prank(ForkAddresses.USDC_HOLDER);
        usdc.transfer(bidderUsdc, 23_000e6);
        vm.startPrank(bidderUsdc);
        usdc.approve(address(adapter), 23_000e6);
        (uint256 adapterBid, uint128 committed) =
            adapter.bidWithUsdc(address(auction), 23_000e6, 100e8, _bidPrice(5), FLOOR_PRICE_Q96, block.timestamp);
        vm.stopPrank();
        assertEq(committed, 100e8);
        assertEq(auction.bids(adapterBid).owner, bidderUsdc);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(stock.balanceOf(address(adapter)), 0);
        (uint160 permit2Allowance,,) =
            IAllowanceTransfer(StocksBindings.PERMIT2).allowance(address(adapter), ForkAddresses.AAPLC, address(auction));
        assertEq(permit2Allowance, 0);

        vm.roll(uint256(auction.endBlock()) + StocksPreset.MIGRATION_DELAY_BLOCKS);
        launchpad.migrate(launchId);

        IStocksLaunchpadV1.Launch memory record = launchpad.launches(launchId);
        assertEq(uint8(record.lifecycle), uint8(IStocksLaunchpadV1.Lifecycle.Graduated));
        PoolKey memory key = _poolKey(newToken);
        assertEq(PoolId.unwrap(key.toId()), record.poolId, "the derived key is the registered pool");
        (uint160 sqrtPriceX96,,,) = IPoolManager(StocksBindings.POOL_MANAGER).getSlot0(PoolId.wrap(record.poolId));
        assertEq(sqrtPriceX96, record.finalSqrtPriceX96, "real PoolManager initialized at the clearing price");
        assertGt(IPoolManager(StocksBindings.POOL_MANAGER).getLiquidity(PoolId.wrap(record.poolId)), 0);
        assertEq(IERC20(newToken).balanceOf(address(launchpad)), 0);
        assertEq(stock.balanceOf(address(launchpad)), 0);
        _assertAllNetStockLocked(record, auction.lbpInitializationParams().currencyRaised, newToken);

        // Both bidders settle through the CCA alone.
        vm.prank(bidderDirect);
        auction.exitBid(directBid);
        vm.prank(bidderDirect);
        auction.claimTokens(directBid);
        vm.prank(bidderUsdc);
        auction.exitBid(adapterBid);
        vm.prank(bidderUsdc);
        auction.claimTokens(adapterBid);
        assertGt(IERC20(newToken).balanceOf(bidderDirect), 0);
        assertGt(IERC20(newToken).balanceOf(bidderUsdc), 0);

        // Swaps on the real PoolManager are charged in STOCK, both directions.
        _approveRouter(bidderDirect, newToken);
        stock.mint(bidderDirect, 1_000e8);
        bool stockIs0 = ForkAddresses.AAPLC < newToken;
        uint256 regentBefore = hook.accrued(record.poolId, hook.REGENT_DESTINATION());
        uint256 stockBefore = stock.balanceOf(bidderDirect);
        vm.prank(bidderDirect);
        swapRouter.swap(
            key,
            SwapParams(stockIs0, -int256(50e8), stockIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(stockBefore - stock.balanceOf(bidderDirect), 50e8, "exact STOCK input");
        assertEq(hook.accrued(record.poolId, hook.REGENT_DESTINATION()) - regentBefore, 50e8 / 100, "one lane");

        regentBefore = hook.accrued(record.poolId, hook.REGENT_DESTINATION());
        vm.prank(bidderDirect);
        swapRouter.swap(
            key,
            SwapParams(!stockIs0, -int256(1e22), !stockIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertGt(hook.accrued(record.poolId, hook.REGENT_DESTINATION()), regentBefore, "STOCK output charged");

        // Settle the REGENT bucket through the fixture route into the real live staking contract. The
        // bucket holds only swap fees: the graduation locked the whole raise and left no dust.
        uint256 accruedBefore = hook.accrued(record.poolId, hook.REGENT_DESTINATION());
        uint256 amount = accruedBefore / 2;
        uint256 expectedUsdc = amount * USDC_PER_SHARE / 1e8;
        uint256 stakingBefore = usdc.balanceOf(StocksBindings.LIVE_STAKING);
        hook.settle(record.poolId, hook.REGENT_DESTINATION(), amount, expectedUsdc);
        assertEq(usdc.balanceOf(StocksBindings.LIVE_STAKING) - stakingBefore, expectedUsdc, "live staking received USDC");
        assertEq(hook.accrued(record.poolId, hook.REGENT_DESTINATION()), accruedBefore - amount);
        (uint256 converted, uint256 deposited) = hook.settled(record.poolId, hook.REGENT_DESTINATION());
        assertEq(converted, amount);
        assertEq(deposited, expectedUsdc);
        assertEq(usdc.balanceOf(address(hook)), 0);
        assertEq(usdc.allowance(address(hook), StocksBindings.LIVE_STAKING), 0);
    }

    // -------------------------------------------------------------------------
    // failed minimum
    // -------------------------------------------------------------------------

    function test_fork_failed_minimum_retires_and_refunds_through_the_cca() public {
        (uint256 launchId, address newToken, IContinuousClearingAuction auction) = _launch(address(0));
        vm.roll(auction.startBlock());
        uint256 bidId = _bidDirect(auction, bidderDirect, 10e8, _bidPrice(1));
        vm.roll(uint256(auction.endBlock()) + StocksPreset.MIGRATION_DELAY_BLOCKS);

        uint256 deadBefore = IERC20(newToken).balanceOf(StocksBindings.DEAD_ADDRESS);
        launchpad.migrate(launchId);
        IStocksLaunchpadV1.Launch memory record = launchpad.launches(launchId);
        assertEq(uint8(record.lifecycle), uint8(IStocksLaunchpadV1.Lifecycle.Failed));
        assertEq(IERC20(newToken).balanceOf(StocksBindings.DEAD_ADDRESS) - deadBefore, StocksPreset.INITIAL_SUPPLY);
        assertEq(IERC20(newToken).balanceOf(address(launchpad)), 0);

        vm.prank(bidderDirect);
        auction.exitBid(bidId);
        assertEq(stock.balanceOf(bidderDirect), 10e8, "full refund through the CCA");
    }

    // -------------------------------------------------------------------------
    // subject lane against a real Agent splitter
    // -------------------------------------------------------------------------

    function test_fork_subject_lane_settles_into_a_real_agent_splitter() public {
        (address splitter, address agentAuction) = _graduateAnAgentLaunch();
        (uint256 launchId, address newToken, IContinuousClearingAuction auction) = _launch(splitter);
        (, address recorded, uint16 bps,,) = launchpad.subjectConfig(launchId);
        assertEq(recorded, splitter);
        assertEq(bps, 100);

        vm.roll(auction.startBlock());
        uint256 bidId = _bidDirect(auction, bidderDirect, 300e8, _bidPrice(10));
        vm.roll(uint256(auction.endBlock()) + StocksPreset.MIGRATION_DELAY_BLOCKS);
        launchpad.migrate(launchId);
        IStocksLaunchpadV1.Launch memory record = launchpad.launches(launchId);
        assertEq(hook.pool(record.poolId).subject, splitter);
        _assertAllNetStockLocked(record, auction.lbpInitializationParams().currencyRaised, newToken);

        vm.prank(bidderDirect);
        auction.exitBid(bidId);
        vm.prank(bidderDirect);
        auction.claimTokens(bidId);
        _approveRouter(bidderDirect, newToken);
        stock.mint(bidderDirect, 1_000e8);
        bool stockIs0 = ForkAddresses.AAPLC < newToken;
        PoolKey memory key = _poolKey(newToken);
        assertEq(PoolId.unwrap(key.toId()), record.poolId, "the derived key is the registered pool");
        vm.prank(bidderDirect);
        swapRouter.swap(
            key,
            SwapParams(stockIs0, -int256(100e8), stockIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(hook.accrued(record.poolId, splitter), 1e8, "subject lane accrued");

        uint256 expectedUsdc = 1e8 * USDC_PER_SHARE / 1e8;
        address treasury = IAgentStrategy(ForkAddresses.AGENT_STRATEGY).distribution(agentAuction).treasury;
        uint256 splitterBefore = usdc.balanceOf(splitter);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 stakingBefore = usdc.balanceOf(StocksBindings.LIVE_STAKING);
        hook.settle(record.poolId, splitter, 1e8, expectedUsdc);
        // The real splitter skims exactly 2% of a recognized USDC inflow into live staking; with no
        // stakers the remaining 98% goes to the launch treasury as the pinned splitter defines.
        uint256 skim = expectedUsdc * 200 / 10_000;
        assertEq(usdc.balanceOf(StocksBindings.LIVE_STAKING) - stakingBefore, skim, "splitter skim reached live staking");
        assertEq(
            (usdc.balanceOf(splitter) - splitterBefore) + (usdc.balanceOf(treasury) - treasuryBefore),
            expectedUsdc - skim,
            "the rest is the splitter's recognized revenue"
        );
        assertEq(hook.accrued(record.poolId, splitter), 0);
        assertEq(usdc.allowance(address(hook), splitter), 0);
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    /// @dev Brief P13 on the real PositionManager: both positions locked at the dead address, minted
    ///      back to back; the one-sided position sits on the STOCK side adjacent to the initial tick;
    ///      placed STOCK + dust == raise with dust inside the rounding bound; when more than a quarter
    ///      sold (every graduated lifecycle here) the whole reserve is placed up to rounding.
    function _assertAllNetStockLocked(IStocksLaunchpadV1.Launch memory record, uint256 raised, address newToken)
        private
        view
    {
        IERC721 nft = IERC721(StocksBindings.POSITION_MANAGER);
        IPositionManager positions = IPositionManager(StocksBindings.POSITION_MANAGER);
        int24 spacing = StocksPreset.POOL_TICK_SPACING;
        bool stockIs0 = ForkAddresses.AAPLC < newToken;

        assertEq(nft.ownerOf(record.lpTokenId), StocksBindings.DEAD_ADDRESS, "full range to dead");
        (, PositionInfo fullInfo) = positions.getPoolAndPositionInfo(record.lpTokenId);
        assertEq(fullInfo.tickLower(), TickMath.minUsableTick(spacing));
        assertEq(fullInfo.tickUpper(), TickMath.maxUsableTick(spacing));

        assertEq(record.lpStockOnlyTokenId, record.lpTokenId + 1, "one-sided position minted second");
        assertEq(nft.ownerOf(record.lpStockOnlyTokenId), StocksBindings.DEAD_ADDRESS, "one-sided to dead");
        assertGt(positions.getPositionLiquidity(record.lpStockOnlyTokenId), 0);
        (PoolKey memory sideKey, PositionInfo sideInfo) = positions.getPoolAndPositionInfo(record.lpStockOnlyTokenId);
        assertEq(PoolId.unwrap(sideKey.toId()), record.poolId);
        int24 tick = TickMath.getTickAtSqrtPrice(record.finalSqrtPriceX96);
        int24 floored = tick.tickFloor(spacing);
        if (stockIs0) {
            assertEq(sideInfo.tickLower(), floored + spacing);
            assertEq(sideInfo.tickUpper(), TickMath.maxUsableTick(spacing));
        } else {
            assertEq(sideInfo.tickLower(), TickMath.minUsableTick(spacing));
            assertEq(sideInfo.tickUpper(), floored);
        }

        uint256 dust = hook.accrued(record.poolId, hook.REGENT_DESTINATION());
        assertEq(uint256(record.lpStockUsed) + record.lpStockOnlyUsed + dust, raised, "raised == placed + dust");
        assertLe(dust, _roundingBound(stockIs0, record.finalSqrtPriceX96, raised - record.lpStockUsed), "dust bounded");
        assertGt(record.lpStockOnlyUsed, 0, "the remainder is locked, not routed");
        assertLe(
            StocksPreset.MIGRATION_RESERVE - record.lpNewUsed,
            _roundingBound(!stockIs0, record.finalSqrtPriceX96, StocksPreset.MIGRATION_RESERVE),
            "reserve fully placed up to rounding"
        );
        assertEq(stock.balanceOf(address(hook)), dust, "hook holds exactly the dust");
    }

    /// @dev The pinned planner's floor-liquidity / round-up-amounts remainder bound, as derived in
    ///      `StocksLaunchpadMigrateTest._roundingBound`.
    function _roundingBound(bool budgetIsCurrency0, uint160 sqrtPriceX96, uint256 budget) private pure returns (uint256) {
        if (budgetIsCurrency0) {
            uint256 product = FullMath.mulDiv(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(StocksPreset.POOL_TICK_SPACING)),
                FixedPoint96.Q96
            );
            return budget / product + FixedPoint96.Q96 / sqrtPriceX96 + 1;
        }
        return sqrtPriceX96 / FixedPoint96.Q96 + 1;
    }

    function _launchParams(address splitter) private view returns (IStocksLaunchpadV1.LaunchParams memory) {
        return IStocksLaunchpadV1.LaunchParams({
            name: string.concat("Fork New ", vm.toString(launchpad.nextLaunchId())),
            symbol: "FNEW",
            description: "Fork lifecycle",
            website: "https://autolaunch.sh",
            image: "ipfs://image",
            stock: ForkAddresses.AAPLC,
            startBlock: uint64(block.number) + StocksPreset.MIN_START_LEAD_BLOCKS,
            floorPriceQ96: FLOOR_PRICE_Q96,
            requiredStockRaised: 100e8,
            feeAdministrator: feeAdministrator,
            subjectSplitter: splitter,
            expectedLaunchFee: launchpad.launchFee()
        });
    }

    /// @dev A launch the way a wallet makes it: approve exactly the reviewed fee, then `launch`.
    function _launch(address splitter)
        private
        returns (uint256 launchId, address newToken, IContinuousClearingAuction auction)
    {
        IStocksLaunchpadV1.LaunchParams memory params = _launchParams(splitter);
        address auctionAddress;
        vm.startPrank(launcher);
        regent.approve(address(launchpad), params.expectedLaunchFee);
        (launchId, newToken, auctionAddress) = launchpad.launch(params);
        vm.stopPrank();
        auction = IContinuousClearingAuction(auctionAddress);
    }

    /// @dev The official pool key, as `StocksLaunchpadV1._poolKeyOf` derives it; checked against the
    ///      registered `record.poolId` where it is used.
    function _poolKey(address newToken) private view returns (PoolKey memory) {
        bool stockIs0 = ForkAddresses.AAPLC < newToken;
        return PoolKey({
            currency0: Currency.wrap(stockIs0 ? ForkAddresses.AAPLC : newToken),
            currency1: Currency.wrap(stockIs0 ? newToken : ForkAddresses.AAPLC),
            fee: StocksPreset.POOL_FEE,
            tickSpacing: StocksPreset.POOL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _bidPrice(uint256 ticks) private pure returns (uint256) {
        return FLOOR_PRICE_Q96 + ticks * (FLOOR_PRICE_Q96 / StocksPreset.BID_TICK_DIVISOR);
    }

    function _bidDirect(IContinuousClearingAuction auction, address account, uint128 amount, uint256 price)
        private
        returns (uint256 bidId)
    {
        stock.mint(account, amount);
        vm.startPrank(account);
        stock.approve(StocksBindings.PERMIT2, amount);
        IAllowanceTransfer(StocksBindings.PERMIT2).approve(ForkAddresses.AAPLC, address(auction), uint160(amount), type(uint48).max);
        bidId = auction.submitBid(price, amount, account, FLOOR_PRICE_Q96, "");
        vm.stopPrank();
    }

    function _approveRouter(address account, address newToken) private {
        vm.startPrank(account);
        stock.approve(address(swapRouter), type(uint256).max);
        IERC20(newToken).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Drives one real Agent launch on the fork to graduation and returns its authentic splitter.
    function _graduateAnAgentLaunch() private returns (address splitter, address auction) {
        IAgentFactory factory = IAgentFactory(ForkAddresses.AGENT_FACTORY);
        IAgentStrategy strategy = IAgentStrategy(ForkAddresses.AGENT_STRATEGY);
        assertFalse(factory.launchesPaused(), "Agent factory open on the lab");

        address agentLauncher = makeAddr("agent-launcher");
        address agentBidder = makeAddr("agent-bidder");
        uint256 fee = factory.launchFee();
        vm.startPrank(governance);
        regent.transfer(agentLauncher, fee);
        regent.transfer(agentBidder, 100_000e18);
        vm.stopPrank();

        vm.startPrank(agentLauncher);
        regent.approve(ForkAddresses.AGENT_FACTORY, fee);
        address subject;
        (, subject, auction,) = factory.launch(
            IAgentFactory.LaunchParams({
                name: "Fork Agent Subject",
                symbol: "FAS",
                description: "Agent launch for the Stocks subject lane proof",
                website: "https://autolaunch.sh",
                image: "ipfs://image",
                treasury: makeAddr("agent-treasury"),
                requiredRegentRaised: 1_000e18,
                expectedLaunchFee: fee
            })
        );
        vm.stopPrank();

        IContinuousClearingAuction agentAuction = IContinuousClearingAuction(auction);
        vm.roll(agentAuction.startBlock());
        uint256 price = strategy.FLOOR_PRICE_Q96() + 10 * strategy.BID_TICK_Q96();
        vm.startPrank(agentBidder);
        regent.approve(StocksBindings.PERMIT2, 100_000e18);
        IAllowanceTransfer(StocksBindings.PERMIT2)
            .approve(StocksBindings.REGENT, auction, uint160(100_000e18), type(uint48).max);
        agentAuction.submitBid(price, 100_000e18, agentBidder, strategy.FLOOR_PRICE_Q96(), "");
        vm.stopPrank();

        vm.roll(uint256(agentAuction.endBlock()) + strategy.MIGRATION_DELAY_BLOCKS());
        strategy.migrate(auction);
        splitter = strategy.distribution(auction).splitter;
        assertNotEq(splitter, address(0), "Agent launch graduated with a splitter");
        assertEq(strategy.auctionOfSubject(subject), auction);
    }

    function _requireCode(address account, string memory label) private view {
        assertGt(account.code.length, 0, string.concat("fork binding has no code: ", label));
    }
}
