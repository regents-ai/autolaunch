// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ContinuousClearingAuctionFactory} from "continuous-clearing-auction/ContinuousClearingAuctionFactory.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {UERC20Factory} from "uerc20-factory/factories/UERC20Factory.sol";
import {MemestockLPLocker} from "../src/MemestockLPLocker.sol";
import {MemestockSplitterV1} from "../src/MemestockSplitterV1.sol";
import {StockBidAdapterV1} from "../src/StockBidAdapterV1.sol";
import {StocksBindings} from "../src/StocksBindings.sol";
import {StocksFeeHookV1} from "../src/StocksFeeHookV1.sol";
import {StocksLaunchpadV2} from "../src/StocksLaunchpadV2.sol";
import {StocksPreset} from "../src/StocksPreset.sol";
import {FixtureStockToken} from "../src/fixtures/FixtureStockToken.sol";
import {IStocksLaunchpadV2} from "../src/interfaces/IStocksLaunchpadV2.sol";
import {FixtureStockRoute} from "../src/routes/FixtureStockRoute.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLiveStaking} from "./mocks/MockLiveStaking.sol";

/// @notice The hermetic Stocks harness: the real PoolManager, PositionManager, CCA factory and UERC20
///         factory constructed from their pinned sources at the frozen Base addresses, the real
///         Permit2 bytecode at its canonical address, and the whole Stocks graph reached only through
///         its production callers, the real memestock splitter and locker included. USDC, REGENT and
///         live staking are named doubles at their frozen addresses; the fork suite replaces them with
///         chain truth.
abstract contract StocksFixture is Test, DeployPermit2 {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /// @dev Two fixture STOCK addresses chosen so that every UERC20 the pinned factory can create sorts
    ///      above the first and below the second, reaching both PoolKey orderings deterministically.
    address internal constant STOCK_LOW = address(uint160(0xB2001));
    address internal constant STOCK_HIGH = address(uint160(type(uint160).max - 0xB200));

    /// @dev Fixture price: 230 USDC per whole share, 8-decimal shares, 6-decimal USDC.
    uint256 internal constant USDC_PER_SHARE = 230_000000;

    /// @dev Every launch's floor (`StocksPreset.FLOOR_PRICE_Q96`).
    uint256 internal constant FLOOR_PRICE_Q96 = StocksPreset.FLOOR_PRICE_Q96;

    /// @dev The raise every launch must reach: the whole sale allocation at the floor, rounded up
    ///      (`StocksPreset.REQUIRED_STOCK_RAISED`). 26,834,004 base units, about 0.27 of an 8-decimal
    ///      share.
    uint128 internal constant REQUIRED_RAISE = StocksPreset.REQUIRED_STOCK_RAISED;

    /// @dev The price limit of a fixture bid meant to graduate: 100,001 times the floor, so any bid of
    ///      up to about 25,000 shares clears below it, is filled in every block and exits through
    ///      `exitBid`.
    uint256 internal constant GRADUATING_TICKS = 10_000_000;

    struct Launched {
        uint256 launchId;
        address newToken;
        address stock;
        IContinuousClearingAuction auction;
    }

    StocksLaunchpadV2 internal launchpad;
    StocksFeeHookV1 internal hook;
    StockBidAdapterV1 internal adapter;
    MemestockLPLocker internal locker;
    bytes32 internal hookSalt;

    UERC20Factory internal uerc20Factory;
    PoolManager internal poolManager;
    IPositionManager internal positionManager;
    ContinuousClearingAuctionFactory internal ccaFactory;
    PoolSwapTest internal swapRouter;

    MockERC20 internal usdc;
    MockERC20 internal regent;
    MockLiveStaking internal liveStaking;

    FixtureStockToken internal stockLow;
    FixtureStockToken internal stockHigh;
    FixtureStockRoute internal routeLow;
    FixtureStockRoute internal routeHigh;

    address internal governance = StocksBindings.GOVERNANCE_AND_REGENT_SAFE;
    address internal launcher = makeAddr("launcher");
    address internal bidder = makeAddr("bidder");
    address internal trader = makeAddr("trader");
    address internal outsider = makeAddr("outsider");
    address internal executor = makeAddr("executor");

    // -------------------------------------------------------------------------
    // deployment
    // -------------------------------------------------------------------------

    function _deployStocks() internal {
        vm.roll(1_000_000);
        vm.warp(1_700_000_000);

        _constructAt(
            StocksBindings.USDC,
            abi.encodePacked(type(MockERC20).creationCode, abi.encode("USD Coin", "USDC", uint8(6)))
        );
        _constructAt(
            StocksBindings.REGENT,
            abi.encodePacked(type(MockERC20).creationCode, abi.encode("Regent", "REGENT", uint8(18)))
        );
        usdc = MockERC20(StocksBindings.USDC);
        regent = MockERC20(StocksBindings.REGENT);

        deployPermit2();
        _constructAt(
            StocksBindings.LIVE_STAKING,
            abi.encodePacked(type(MockLiveStaking).creationCode, abi.encode(StocksBindings.USDC))
        );
        _constructAt(
            StocksBindings.POOL_MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this)))
        );
        _constructAt(
            StocksBindings.CCA_FACTORY,
            abi.encodePacked(type(ContinuousClearingAuctionFactory).creationCode, abi.encode(address(0)))
        );
        _constructAt(
            StocksBindings.POSITION_MANAGER,
            abi.encodePacked(
                type(PositionManager).creationCode,
                abi.encode(
                    IPoolManager(StocksBindings.POOL_MANAGER),
                    IAllowanceTransfer(StocksBindings.PERMIT2),
                    uint256(300_000),
                    IPositionDescriptor(address(0)),
                    IWETH9(payable(address(0)))
                )
            )
        );
        poolManager = PoolManager(StocksBindings.POOL_MANAGER);
        positionManager = IPositionManager(StocksBindings.POSITION_MANAGER);
        ccaFactory = ContinuousClearingAuctionFactory(StocksBindings.CCA_FACTORY);
        liveStaking = MockLiveStaking(StocksBindings.LIVE_STAKING);
        swapRouter = new PoolSwapTest(poolManager);

        vm.etch(STOCK_LOW, type(FixtureStockToken).runtimeCode);
        vm.etch(STOCK_HIGH, type(FixtureStockToken).runtimeCode);
        stockLow = FixtureStockToken(STOCK_LOW);
        stockHigh = FixtureStockToken(STOCK_HIGH);

        uerc20Factory = new UERC20Factory();
        hookSalt = _mineHookSalt(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        launchpad = new StocksLaunchpadV2(address(uerc20Factory), hookSalt);
        hook = StocksFeeHookV1(launchpad.hook());
        locker = MemestockLPLocker(launchpad.locker());
        adapter = new StockBidAdapterV1(address(launchpad));

        routeLow = new FixtureStockRoute(STOCK_LOW, USDC_PER_SHARE);
        routeHigh = new FixtureStockRoute(STOCK_HIGH, USDC_PER_SHARE);
        _fundRoute(routeLow, stockLow);
        _fundRoute(routeHigh, stockHigh);

        vm.startPrank(governance);
        launchpad.admitStock(STOCK_LOW, address(routeLow));
        launchpad.admitStock(STOCK_HIGH, address(routeHigh));
        launchpad.unpauseLaunches();
        hook.setExecutor(executor);
        vm.stopPrank();
    }

    function _fundRoute(FixtureStockRoute route, FixtureStockToken stock) internal {
        stock.mint(address(route), 1_000_000_000e8);
        usdc.mint(address(route), 1_000_000_000_000e6);
    }

    function _mineHookSalt(address predictedLaunchpad) internal view returns (bytes32 salt) {
        (, salt) = HookMiner.find(
            predictedLaunchpad,
            HOOK_FLAGS,
            type(StocksFeeHookV1).creationCode,
            abi.encode(StocksBindings.POOL_MANAGER, predictedLaunchpad)
        );
    }

    /// @dev Run a real constructor at an exact address so its storage and immutables land where
    ///      production expects them.
    function _constructAt(address where, bytes memory initcode) internal {
        vm.etch(where, initcode);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory runtime) = where.call("");
        require(ok && runtime.length != 0, "StocksFixture: construction at address failed");
        vm.etch(where, runtime);
    }

    // -------------------------------------------------------------------------
    // launches
    // -------------------------------------------------------------------------

    function _params(address stock) internal pure returns (IStocksLaunchpadV2.LaunchParams memory params) {
        params = IStocksLaunchpadV2.LaunchParams({
            name: "New One",
            symbol: "NEW",
            description: "A stocks launch",
            website: "https://autolaunch.sh",
            image: "ipfs://image",
            stock: stock
        });
    }

    function _launchAs(address who, IStocksLaunchpadV2.LaunchParams memory params)
        internal
        returns (Launched memory launched)
    {
        vm.prank(who);
        (uint256 launchId, address newToken, address auction) = launchpad.launch(params);
        launched = Launched({
            launchId: launchId, newToken: newToken, stock: params.stock, auction: IContinuousClearingAuction(auction)
        });
    }

    function _launch(address stock) internal returns (Launched memory) {
        return _launchAs(launcher, _params(stock));
    }

    // -------------------------------------------------------------------------
    // auction driving
    // -------------------------------------------------------------------------

    /// @dev Pure (no external call) so it can be an argument inside an armed prank or expectRevert.
    function _bidPrice(uint256 ticksAboveFloor) internal pure returns (uint256) {
        return FLOOR_PRICE_Q96 + ticksAboveFloor * StocksPreset.BID_TICK_SPACING_Q96;
    }

    /// @dev A direct bid the way a wallet places it: ERC-20 approval to Permit2, Permit2 allowance to the
    ///      auction, then `submitBid` with the bidder as owner.
    function _bidDirect(Launched memory launched, address account, uint128 amount, uint256 priceQ96)
        internal
        returns (uint256 bidId)
    {
        FixtureStockToken(launched.stock).mint(account, amount);
        vm.startPrank(account);
        FixtureStockToken(launched.stock).approve(StocksBindings.PERMIT2, amount);
        IAllowanceTransfer(StocksBindings.PERMIT2)
            .approve(launched.stock, address(launched.auction), uint160(amount), type(uint48).max);
        bidId = launched.auction.submitBid(priceQ96, amount, account, FLOOR_PRICE_Q96, "");
        vm.stopPrank();
    }

    function _rollToStart(Launched memory launched) internal {
        vm.roll(launched.auction.startBlock());
    }

    function _rollToMigration(Launched memory launched) internal {
        vm.roll(uint256(launched.auction.endBlock()) + StocksPreset.MIGRATION_DELAY_BLOCKS);
    }

    function _bidToGraduation(Launched memory launched, uint128 amount) internal returns (uint256 bidId) {
        _rollToStart(launched);
        bidId = _bidDirect(launched, bidder, amount, _bidPrice(GRADUATING_TICKS));
        _rollToMigration(launched);
    }

    function _graduate(Launched memory launched, uint128 amount) internal returns (uint256 bidId) {
        bidId = _bidToGraduation(launched, amount);
        launchpad.migrate(launched.launchId);
    }

    /// @dev The bidder settles its bid through the CCA alone and hands the NEW it bought to `to`.
    function _claimNewTo(Launched memory launched, uint256 bidId, address to) internal returns (uint256 claimed) {
        vm.startPrank(bidder);
        launched.auction.exitBid(bidId);
        launched.auction.claimTokens(bidId);
        claimed = MockERC20(launched.newToken).balanceOf(bidder);
        MockERC20(launched.newToken).transfer(to, claimed);
        vm.stopPrank();
    }

    /// @dev A graduated pool whose trader holds NEW (from the graduated bid) and STOCK (minted).
    function _graduatedMarket(address stock) internal returns (Launched memory launched) {
        launched = _launch(stock);
        // 500 shares clears far below the bid's price limit, so the bid is filled in every block and
        // exits through the plain `exitBid` path.
        uint256 bidId = _graduate(launched, 500e8);
        _claimNewTo(launched, bidId, trader);
        _fundTrader(launched, trader, 1_000_000e8);
    }

    function _record(Launched memory launched) internal view returns (IStocksLaunchpadV2.Launch memory) {
        return launchpad.launches(launched.launchId);
    }

    /// @dev The launch's memestock splitter; exists only once the launch has graduated.
    function _splitter(Launched memory launched) internal view returns (MemestockSplitterV1) {
        return MemestockSplitterV1(_record(launched).splitter);
    }

    /// @dev `account` stakes `amount` of the launch's NEW it already holds.
    function _stake(Launched memory launched, address account, uint256 amount) internal {
        MemestockSplitterV1 splitter = _splitter(launched);
        vm.startPrank(account);
        MockERC20(launched.newToken).approve(address(splitter), amount);
        splitter.stake(amount);
        vm.stopPrank();
    }

    /// @dev Built locally (no external call) so it can sit inside an armed `vm.expectRevert`.
    function _poolKey(Launched memory launched) internal view returns (PoolKey memory) {
        bool stockIsCurrency0 = launched.stock < launched.newToken;
        return PoolKey({
            currency0: Currency.wrap(stockIsCurrency0 ? launched.stock : launched.newToken),
            currency1: Currency.wrap(stockIsCurrency0 ? launched.newToken : launched.stock),
            fee: StocksPreset.POOL_FEE,
            tickSpacing: StocksPreset.POOL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _poolId(Launched memory launched) internal view returns (bytes32) {
        return PoolId.unwrap(_poolKey(launched).toId());
    }

    function _stockIsCurrency0(Launched memory launched) internal pure returns (bool) {
        return launched.stock < launched.newToken;
    }

    // -------------------------------------------------------------------------
    // swaps
    // -------------------------------------------------------------------------

    /// @dev Give `account` a balance of NEW by claiming the graduated bid, and of STOCK by minting.
    function _fundTrader(Launched memory launched, address account, uint256 stockAmount) internal {
        FixtureStockToken(launched.stock).mint(account, stockAmount);
        vm.startPrank(account);
        FixtureStockToken(launched.stock).approve(address(swapRouter), type(uint256).max);
        MockERC20(launched.newToken).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(Launched memory launched, address account, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta delta)
    {
        return _swapLimited(
            launched,
            account,
            zeroForOne,
            amountSpecified,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _swapLimited(
        Launched memory launched,
        address account,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) internal returns (BalanceDelta delta) {
        vm.prank(account);
        delta = swapRouter.swap(
            _poolKey(launched),
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _sqrtPrice(Launched memory launched) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(_poolKey(launched).toId());
    }
}
