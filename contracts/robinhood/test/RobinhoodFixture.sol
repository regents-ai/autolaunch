// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ContinuousClearingAuctionFactory} from "continuous-clearing-auction/ContinuousClearingAuctionFactory.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
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
import {MemestockLPLocker} from "autolaunch-stocks/MemestockLPLocker.sol";
import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {FixtureUsdgStockRoute} from "../src/fixtures/FixtureUsdgStockRoute.sol";
import {IRobinhoodLaunchpadBase} from "../src/interfaces/IRobinhoodLaunchpadBase.sol";
import {IRobinhoodStocksLaunchpadV1} from "../src/interfaces/IRobinhoodStocksLaunchpadV1.sol";
import {RobinhoodFeeHookFactory} from "../src/RobinhoodFeeHookFactory.sol";
import {RobinhoodFeeHookV1} from "../src/RobinhoodFeeHookV1.sol";
import {RobinhoodLaunchpadBase} from "../src/RobinhoodLaunchpadBase.sol";
import {RobinhoodMemestockSplitterV1} from "../src/RobinhoodMemestockSplitterV1.sol";
import {RobinhoodPreset} from "../src/RobinhoodPreset.sol";
import {RobinhoodProtocolRevenueInboxV1} from "../src/RobinhoodProtocolRevenueInboxV1.sol";
import {RobinhoodStockBidAdapterV1} from "../src/RobinhoodStockBidAdapterV1.sol";
import {RobinhoodStocksLaunchpadV1} from "../src/RobinhoodStocksLaunchpadV1.sol";

/// @notice The hermetic Robinhood harness: the real PoolManager, PositionManager, CCA factory, UERC20
///         factory and Permit2 constructed from their pinned sources, the whole Robinhood graph
///         (inbox, the launchpad with its hook, locker and splitters, bid adapter, fixture routes) reached only
///         through its production callers. USDG and the two STOCKs are mintable doubles.
abstract contract RobinhoodFixture is Test, DeployPermit2 {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev Two fixture STOCK addresses chosen so that every UERC20 the pinned factory can create sorts
    ///      above the first and below the second, reaching both PoolKey orderings deterministically.
    address internal constant STOCK_LOW = address(uint160(0xB2001));
    address internal constant STOCK_HIGH = address(uint160(type(uint160).max - 0xB200));
    address internal constant USDG_ADDRESS = address(uint160(0xD0011));

    /// @dev Fixture price: 230 USDG per whole share, 8-decimal shares, 6-decimal USDG.
    uint256 internal constant USDG_PER_SHARE = 230_000000;
    uint128 internal constant STOCK_REQUIRED_RAISE =
        uint128(RobinhoodPreset.MINIMUM_RAISE_USDG_STOCKS * 1e8 / USDG_PER_SHARE);

    /// @dev A currency-per-NEW floor of 1e-16 base units per base unit, times 2^96, on the bid grid.
    uint256 internal constant FLOOR_PRICE_Q96 = 7_922_816_251_400;

    struct Launched {
        uint256 launchId;
        address newToken;
        address currency;
        IContinuousClearingAuction auction;
    }

    RobinhoodProtocolRevenueInboxV1 internal inbox;
    RobinhoodFeeHookFactory internal hookFactory;
    RobinhoodStocksLaunchpadV1 internal stocks;
    RobinhoodFeeHookV1 internal stocksHook;
    MemestockLPLocker internal locker;
    RobinhoodStockBidAdapterV1 internal adapter;

    UERC20Factory internal uerc20Factory;
    PoolManager internal poolManager;
    IPositionManager internal positionManager;
    ContinuousClearingAuctionFactory internal ccaFactory;
    PoolSwapTest internal swapRouter;

    MockERC20 internal usdg;
    MockERC20 internal stockLow;
    MockERC20 internal stockHigh;
    FixtureUsdgStockRoute internal routeLow;
    FixtureUsdgStockRoute internal routeHigh;

    address internal safe = makeAddr("robinhood-safe");
    address internal launcher = makeAddr("launcher");
    address internal staker = makeAddr("staker");
    address internal bidder = makeAddr("bidder");
    address internal trader = makeAddr("trader");
    address internal outsider = makeAddr("outsider");
    address internal executor = makeAddr("executor");

    // -------------------------------------------------------------------------
    // deployment
    // -------------------------------------------------------------------------

    function _deployRobinhood() internal {
        vm.roll(1_000_000);
        vm.warp(1_700_000_000);

        _constructAt(
            USDG_ADDRESS, abi.encodePacked(type(MockERC20).creationCode, abi.encode("Global Dollar", "USDG", uint8(6)))
        );
        _constructAt(
            STOCK_LOW, abi.encodePacked(type(MockERC20).creationCode, abi.encode("Stock Low", "LOW", uint8(8)))
        );
        _constructAt(
            STOCK_HIGH, abi.encodePacked(type(MockERC20).creationCode, abi.encode("Stock High", "HIGH", uint8(8)))
        );
        usdg = MockERC20(USDG_ADDRESS);
        stockLow = MockERC20(STOCK_LOW);
        stockHigh = MockERC20(STOCK_HIGH);

        deployPermit2();
        poolManager = new PoolManager(address(this));
        ccaFactory = new ContinuousClearingAuctionFactory(address(0));
        positionManager = new PositionManager(
            IPoolManager(address(poolManager)),
            IAllowanceTransfer(PERMIT2),
            300_000,
            IPositionDescriptor(address(0)),
            IWETH9(payable(address(0)))
        );
        swapRouter = new PoolSwapTest(poolManager);
        uerc20Factory = new UERC20Factory();

        inbox = new RobinhoodProtocolRevenueInboxV1(USDG_ADDRESS, safe);
        hookFactory = new RobinhoodFeeHookFactory(address(poolManager));

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        stocks = new RobinhoodStocksLaunchpadV1(_bindings(), _mineHookSalt(predicted));
        require(address(stocks) == predicted, "RobinhoodFixture: stocks prediction");
        stocksHook = RobinhoodFeeHookV1(stocks.hook());
        locker = MemestockLPLocker(stocks.locker());
        adapter = new RobinhoodStockBidAdapterV1(address(stocks), PERMIT2);

        routeLow = new FixtureUsdgStockRoute(STOCK_LOW, USDG_ADDRESS, USDG_PER_SHARE);
        routeHigh = new FixtureUsdgStockRoute(STOCK_HIGH, USDG_ADDRESS, USDG_PER_SHARE);
        _fundRoute(routeLow, stockLow);
        _fundRoute(routeHigh, stockHigh);

        vm.startPrank(safe);
        stocks.admitStock(STOCK_LOW, address(routeLow));
        stocks.admitStock(STOCK_HIGH, address(routeHigh));
        stocks.unpauseLaunches();
        stocksHook.setExecutor(executor);
        vm.stopPrank();
    }

    function _bindings() internal view returns (RobinhoodLaunchpadBase.Bindings memory) {
        return RobinhoodLaunchpadBase.Bindings({
            uerc20Factory: address(uerc20Factory),
            ccaFactory: address(ccaFactory),
            poolManager: address(poolManager),
            positionManager: address(positionManager),
            hookFactory: address(hookFactory),
            usdg: USDG_ADDRESS,
            inbox: address(inbox),
            adminSafe: safe
        });
    }

    function _mineHookSalt(address predictedLaunchpad) internal view returns (bytes32 salt) {
        (, salt) = HookMiner.find(
            address(hookFactory),
            HOOK_FLAGS,
            type(RobinhoodFeeHookV1).creationCode,
            abi.encode(address(poolManager), predictedLaunchpad, USDG_ADDRESS, address(inbox), safe)
        );
    }

    function _fundRoute(FixtureUsdgStockRoute route, MockERC20 stock) internal {
        stock.mint(address(route), 1_000_000_000e8);
        usdg.mint(address(route), 1_000_000_000_000e6);
    }

    /// @dev Run a real constructor at an exact address so its immutables land where the graph expects.
    function _constructAt(address where, bytes memory initcode) internal {
        vm.etch(where, initcode);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory runtime) = where.call("");
        require(ok && runtime.length != 0, "RobinhoodFixture: construction at address failed");
        vm.etch(where, runtime);
    }

    // -------------------------------------------------------------------------
    // launches
    // -------------------------------------------------------------------------

    function _core(uint256 expectedLaunchFee) internal view returns (IRobinhoodLaunchpadBase.CoreParams memory) {
        return IRobinhoodLaunchpadBase.CoreParams({
            name: "New One",
            symbol: "NEW",
            description: "A Robinhood launch",
            website: "https://autolaunch.sh",
            image: "ipfs://image",
            startBlock: uint64(block.number) + StocksPreset.MIN_START_LEAD_BLOCKS,
            floorPriceQ96: FLOOR_PRICE_Q96,
            expectedLaunchFee: expectedLaunchFee
        });
    }

    /// @dev Reads `launchFee()` (an external call): build params before arming a prank or expectRevert.
    function _stockParams(address stock) internal view returns (IRobinhoodStocksLaunchpadV1.LaunchParams memory) {
        return IRobinhoodStocksLaunchpadV1.LaunchParams({core: _core(stocks.launchFee()), stock: stock});
    }

    /// @dev The exact-allowance discipline a wallet follows: approve precisely the reviewed fee.
    function _approveFee(address who, address launchpad, uint256 fee) internal {
        usdg.mint(who, fee);
        vm.prank(who);
        usdg.approve(launchpad, fee);
    }

    function _launchStockAs(address who, IRobinhoodStocksLaunchpadV1.LaunchParams memory params)
        internal
        returns (Launched memory launched)
    {
        _approveFee(who, address(stocks), params.core.expectedLaunchFee);
        vm.prank(who);
        (uint256 launchId, address newToken, address auction) = stocks.launch(params);
        launched = Launched({
            launchId: launchId, newToken: newToken, currency: params.stock, auction: IContinuousClearingAuction(auction)
        });
    }

    function _launchStock(address stock) internal returns (Launched memory) {
        return _launchStockAs(launcher, _stockParams(stock));
    }

    // -------------------------------------------------------------------------
    // auction driving
    // -------------------------------------------------------------------------

    function _bidPrice(uint256 ticksAboveFloor) internal pure returns (uint256) {
        return FLOOR_PRICE_Q96 + ticksAboveFloor * (FLOOR_PRICE_Q96 / StocksPreset.BID_TICK_DIVISOR);
    }

    /// @dev A direct bid the way a wallet places it: mint the currency, ERC-20 approval to Permit2,
    ///      Permit2 allowance to the auction, then `submitBid` with the bidder as owner.
    function _bidDirect(Launched memory launched, address account, uint128 amount, uint256 priceQ96)
        internal
        returns (uint256 bidId)
    {
        MockERC20(launched.currency).mint(account, amount);
        vm.startPrank(account);
        MockERC20(launched.currency).approve(PERMIT2, amount);
        IAllowanceTransfer(PERMIT2)
            .approve(launched.currency, address(launched.auction), uint160(amount), type(uint48).max);
        bidId = launched.auction.submitBid(priceQ96, amount, account, FLOOR_PRICE_Q96, "");
        vm.stopPrank();
    }

    function _rollToStart(Launched memory launched) internal {
        vm.roll(launched.auction.startBlock());
    }

    function _rollToMigration(Launched memory launched) internal {
        vm.roll(uint256(launched.auction.endBlock()) + StocksPreset.MIGRATION_DELAY_BLOCKS);
    }

    function _bidToMigration(Launched memory launched, uint128 amount) internal returns (uint256 bidId) {
        _rollToStart(launched);
        bidId = _bidDirect(launched, bidder, amount, _bidPrice(10));
        _rollToMigration(launched);
    }

    /// @dev 500 shares of STOCK, well above the quoted minimum and far under the inventory at the floor.
    function _graduateStock(Launched memory launched) internal returns (uint256 bidId) {
        bidId = _bidToMigration(launched, 500e8);
        stocks.migrate(launched.launchId);
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

    // -------------------------------------------------------------------------
    // staking
    // -------------------------------------------------------------------------

    function _splitter(Launched memory launched) internal view returns (RobinhoodMemestockSplitterV1) {
        return RobinhoodMemestockSplitterV1(stocks.launches(launched.launchId).splitter);
    }

    /// @dev A graduated market whose whole auction purchase is staked by `staker`.
    function _graduatedStakedMarket(address stock) internal returns (Launched memory launched, uint256 staked) {
        launched = _launchStock(stock);
        uint256 bidId = _graduateStock(launched);
        staked = _claimNewTo(launched, bidId, staker);
        RobinhoodMemestockSplitterV1 splitter = _splitter(launched);
        vm.startPrank(staker);
        MockERC20(launched.newToken).approve(address(splitter), staked);
        splitter.stake(staked);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // pools and swaps
    // -------------------------------------------------------------------------

    function _poolKey(Launched memory launched, address hook) internal pure returns (PoolKey memory) {
        bool currencyIsCurrency0 = launched.currency < launched.newToken;
        return PoolKey({
            currency0: Currency.wrap(currencyIsCurrency0 ? launched.currency : launched.newToken),
            currency1: Currency.wrap(currencyIsCurrency0 ? launched.newToken : launched.currency),
            fee: StocksPreset.POOL_FEE,
            tickSpacing: StocksPreset.POOL_TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    function _poolId(Launched memory launched, address hook) internal pure returns (bytes32) {
        return PoolId.unwrap(_poolKey(launched, hook).toId());
    }

    function _fundTrader(Launched memory launched, uint256 currencyAmount) internal {
        MockERC20(launched.currency).mint(trader, currencyAmount);
        vm.startPrank(trader);
        MockERC20(launched.currency).approve(address(swapRouter), type(uint256).max);
        MockERC20(launched.newToken).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev An exact-input swap of `amountIn` of the pool currency into NEW by the trader.
    function _swapCurrencyIn(Launched memory launched, address hook, uint256 amountIn)
        internal
        returns (BalanceDelta delta)
    {
        return _swapExactIn(launched, hook, launched.currency < launched.newToken, amountIn);
    }

    /// @dev An exact-input swap of `amountIn` of NEW back into the pool currency by the trader.
    function _swapNewIn(Launched memory launched, address hook, uint256 amountIn)
        internal
        returns (BalanceDelta delta)
    {
        return _swapExactIn(launched, hook, launched.newToken < launched.currency, amountIn);
    }

    function _swapExactIn(Launched memory launched, address hook, bool zeroForOne, uint256 amountIn)
        private
        returns (BalanceDelta delta)
    {
        vm.prank(trader);
        delta = swapRouter.swap(
            _poolKey(launched, hook),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
