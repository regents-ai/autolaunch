// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {MemestockLPLocker} from "../src/MemestockLPLocker.sol";
import {MemestockSplitterV1} from "../src/MemestockSplitterV1.sol";
import {StocksBindings} from "../src/StocksBindings.sol";
import {StocksPreset} from "../src/StocksPreset.sol";
import {FixtureStockToken} from "../src/fixtures/FixtureStockToken.sol";
import {IStocksLaunchpadV1} from "../src/interfaces/IStocksLaunchpadV1.sol";
import {StocksFixture} from "./StocksFixture.sol";

/// @notice The launch positions live in the fee-only locker forever: anyone may collect their LP fees,
///         which always land, in both pool currencies, in the launch's memestock splitter; the
///         liquidity itself can never leave.
contract MemestockLPLockerTest is StocksFixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _deployStocks();
    }

    // -------------------------------------------------------------------------
    // collection
    // -------------------------------------------------------------------------

    function test_collect_deposits_both_currencies_into_the_splitter_and_keeps_nothing() public {
        _collectCase(STOCK_LOW);
    }

    function test_collect_works_in_the_other_currency_order() public {
        _collectCase(STOCK_HIGH);
    }

    function _collectCase(address stockAddress) private {
        Launched memory l = _graduatedMarket(stockAddress);
        IStocksLaunchpadV1.Launch memory record = _record(l);
        MemestockSplitterV1 splitter = _splitter(l);
        FixtureStockToken stock = FixtureStockToken(l.stock);
        UERC20 memestock = UERC20(l.newToken);
        _stake(l, trader, 1_000e18);
        _tradeBothWays(l);

        uint128 fullLiquidity = positionManager.getPositionLiquidity(record.lpTokenId);
        uint128 sideLiquidity = positionManager.getPositionLiquidity(record.lpStockOnlyTokenId);
        uint256 safeStock = stock.balanceOf(governance);
        uint256 safeMemestock = memestock.balanceOf(governance);
        uint256 splitterStock = stock.balanceOf(address(splitter));
        uint256 splitterMemestock = memestock.balanceOf(address(splitter));

        vm.startPrank(outsider);
        (uint256 full0, uint256 full1) = locker.collect(record.lpTokenId);
        (uint256 side0, uint256 side1) = locker.collect(record.lpStockOnlyTokenId);
        vm.stopPrank();

        bool stockIs0 = _stockIsCurrency0(l);
        uint256 stockFees = stockIs0 ? full0 + side0 : full1 + side1;
        uint256 memestockFees = stockIs0 ? full1 + side1 : full0 + side0;
        assertGt(stockFees, 0, "LP fees in STOCK");
        assertGt(memestockFees, 0, "LP fees in MEMESTOCK");

        // Every collected unit went through the splitter: 2% to the Safe, the rest to the staker.
        uint256 stockToSafe = stock.balanceOf(governance) - safeStock;
        uint256 memestockToSafe = memestock.balanceOf(governance) - safeMemestock;
        assertEq(stockToSafe + (stock.balanceOf(address(splitter)) - splitterStock), stockFees);
        assertEq(memestockToSafe + (memestock.balanceOf(address(splitter)) - splitterMemestock), memestockFees);
        assertApproxEqAbs(stockToSafe, stockFees * 200 / 10_000, 1, "2% of the STOCK fees, floored per deposit");
        assertApproxEqAbs(memestockToSafe, memestockFees * 200 / 10_000, 1);
        assertApproxEqAbs(splitter.claimable(l.stock, trader), stockFees - stockToSafe, 2);
        assertApproxEqAbs(splitter.claimable(l.newToken, trader), memestockFees - memestockToSafe, 2);
        assertEq(
            outsider.balance + stock.balanceOf(outsider) + memestock.balanceOf(outsider), 0, "the caller earns nothing"
        );

        // The locker keeps nothing and the positions are exactly as they were.
        assertEq(stock.balanceOf(address(locker)), 0);
        assertEq(memestock.balanceOf(address(locker)), 0);
        assertEq(stock.allowance(address(locker), address(splitter)), 0);
        assertEq(memestock.allowance(address(locker), address(splitter)), 0);
        assertEq(positionManager.getPositionLiquidity(record.lpTokenId), fullLiquidity, "liquidity untouched");
        assertEq(positionManager.getPositionLiquidity(record.lpStockOnlyTokenId), sideLiquidity);
        assertEq(IERC721(address(positionManager)).ownerOf(record.lpTokenId), address(locker));
        assertEq(IERC721(address(positionManager)).ownerOf(record.lpStockOnlyTokenId), address(locker));

        // Nothing new to collect: a no-op that deposits nothing.
        (uint256 again0, uint256 again1) = locker.collect(record.lpTokenId);
        assertEq(again0 + again1, 0);
    }

    function test_collect_emits_the_deposit_and_tags_it_with_the_position() public {
        Launched memory l = _graduatedMarket(STOCK_LOW);
        IStocksLaunchpadV1.Launch memory record = _record(l);
        _stake(l, trader, 1_000e18);
        _tradeBothWays(l);

        vm.recordLogs();
        (uint256 amount0, uint256 amount1) = locker.collect(record.lpTokenId);
        bytes32 deposited = keccak256("FeesDeposited(uint256,address,address,address,uint256,uint256)");
        bytes32 recognized = keccak256("RevenueRecognized(address,address,bytes32,uint256,uint256,uint256)");
        bool sawDeposit;
        uint256 recognitions;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(locker) && logs[i].topics[0] == deposited) {
                sawDeposit = true;
                assertEq(uint256(logs[i].topics[1]), record.lpTokenId);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), record.splitter);
                (address currency0, address currency1, uint256 logged0, uint256 logged1) =
                    abi.decode(logs[i].data, (address, address, uint256, uint256));
                assertEq(currency0, l.stock);
                assertEq(currency1, l.newToken);
                assertEq(logged0, amount0);
                assertEq(logged1, amount1);
            }
            if (logs[i].emitter == record.splitter && logs[i].topics[0] == recognized) {
                ++recognitions;
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(locker), "the locker is the source");
                assertEq(uint256(logs[i].topics[3]), record.lpTokenId, "the reference is the position");
            }
        }
        assertTrue(sawDeposit, "FeesDeposited emitted");
        assertEq(recognitions, 2, "one recognition per currency");
    }

    function test_collect_never_touches_balances_the_locker_already_held() public {
        Launched memory l = _graduatedMarket(STOCK_LOW);
        IStocksLaunchpadV1.Launch memory record = _record(l);
        _stake(l, trader, 1_000e18);
        _tradeBothWays(l);

        // Donations to the locker are stranded by design; a collection deposits only what it received.
        FixtureStockToken(l.stock).mint(address(locker), 77e8);
        (uint256 amount0,) = locker.collect(record.lpTokenId);
        assertGt(amount0, 0);
        assertEq(FixtureStockToken(l.stock).balanceOf(address(locker)), 77e8);
    }

    function test_with_nothing_staked_collected_fees_are_the_protocols() public {
        Launched memory l = _graduatedMarket(STOCK_LOW);
        IStocksLaunchpadV1.Launch memory record = _record(l);
        _tradeBothWays(l);

        uint256 safeStock = FixtureStockToken(l.stock).balanceOf(governance);
        (uint256 amount0,) = locker.collect(record.lpTokenId);
        assertGt(amount0, 0);
        assertEq(FixtureStockToken(l.stock).balanceOf(governance) - safeStock, amount0);
        assertEq(FixtureStockToken(l.stock).balanceOf(record.splitter), 0);
    }

    function test_collect_refuses_positions_the_launchpad_never_registered() public {
        vm.expectRevert(abi.encodeWithSelector(MemestockLPLocker.UnregisteredPosition.selector, 1));
        locker.collect(1);
    }

    // -------------------------------------------------------------------------
    // registration
    // -------------------------------------------------------------------------

    function test_bindings_and_the_launchpad_only_write_once_registration() public {
        assertEq(locker.launchpad(), address(launchpad));
        assertEq(locker.positionManager(), StocksBindings.POSITION_MANAGER);

        Launched memory l = _graduatedMarket(STOCK_LOW);
        IStocksLaunchpadV1.Launch memory record = _record(l);
        PoolKey memory key = _poolKey(l);

        vm.expectRevert(abi.encodeWithSelector(MemestockLPLocker.NotLaunchpad.selector, outsider));
        vm.prank(outsider);
        locker.register(record.lpTokenId, key, record.splitter);

        vm.expectRevert(abi.encodeWithSelector(MemestockLPLocker.AlreadyRegistered.selector, record.lpTokenId));
        vm.prank(address(launchpad));
        locker.register(record.lpTokenId, key, record.splitter);

        vm.expectRevert(MemestockLPLocker.ZeroAddress.selector);
        new MemestockLPLocker(address(0), StocksBindings.POSITION_MANAGER);
        vm.expectRevert(MemestockLPLocker.ZeroAddress.selector);
        new MemestockLPLocker(address(launchpad), address(0));
    }

    function test_registration_checks_ownership_pool_and_splitter() public {
        Launched memory l = _graduatedMarket(STOCK_LOW);
        Launched memory other = _graduatedMarket(STOCK_HIGH);
        IStocksLaunchpadV1.Launch memory record = _record(l);
        address otherSplitter = _record(other).splitter;
        PoolKey memory key = _poolKey(l);

        // A locker whose registrar is this test, holding one fresh position in the launch's pool.
        MemestockLPLocker own = new MemestockLPLocker(address(this), StocksBindings.POSITION_MANAGER);
        uint256 tokenId = _mintFullRange(l, address(own));

        vm.expectRevert(abi.encodeWithSelector(MemestockLPLocker.PositionNotOwned.selector, record.lpTokenId));
        own.register(record.lpTokenId, key, record.splitter);

        vm.expectRevert(MemestockLPLocker.PoolMismatch.selector);
        own.register(tokenId, _poolKey(other), record.splitter);

        vm.expectRevert(MemestockLPLocker.SplitterMismatch.selector);
        own.register(tokenId, key, makeAddr("codeless-splitter"));
        vm.expectRevert(MemestockLPLocker.SplitterMismatch.selector);
        own.register(tokenId, key, otherSplitter);

        vm.expectEmit(true, true, true, true, address(own));
        emit MemestockLPLocker.PositionLocked(tokenId, PoolId.wrap(record.poolId), record.splitter);
        own.register(tokenId, key, record.splitter);
        assertEq(own.splitterOf(tokenId), record.splitter);

        vm.expectRevert(abi.encodeWithSelector(MemestockLPLocker.AlreadyRegistered.selector, tokenId));
        own.register(tokenId, key, otherSplitter);
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    /// @dev One swap each way, so both pool currencies earn LP fees.
    function _tradeBothWays(Launched memory l) private {
        bool stockIs0 = _stockIsCurrency0(l);
        _swap(l, trader, stockIs0, -int256(1_000e8));
        _swap(l, trader, !stockIs0, -int256(1e24));
    }

    /// @dev The trader mints a small full-range position in the launch's pool to `owner`.
    function _mintFullRange(Launched memory l, address owner) private returns (uint256 tokenId) {
        PoolKey memory key = _poolKey(l);
        tokenId = positionManager.nextTokenId();
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            TickMath.minUsableTick(StocksPreset.POOL_TICK_SPACING),
            TickMath.maxUsableTick(StocksPreset.POOL_TICK_SPACING),
            uint256(1e9),
            type(uint128).max,
            type(uint128).max,
            owner,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        vm.startPrank(trader);
        FixtureStockToken(l.stock).approve(StocksBindings.PERMIT2, type(uint256).max);
        UERC20(l.newToken).approve(StocksBindings.PERMIT2, type(uint256).max);
        IAllowanceTransfer(StocksBindings.PERMIT2)
            .approve(l.stock, address(positionManager), type(uint160).max, type(uint48).max);
        IAllowanceTransfer(StocksBindings.PERMIT2)
            .approve(l.newToken, address(positionManager), type(uint160).max, type(uint48).max);
        positionManager.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params),
            block.timestamp
        );
        vm.stopPrank();
    }
}
