// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {MemestockLPLocker} from "autolaunch-stocks/MemestockLPLocker.sol";
import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {IRobinhoodLaunchpadBase} from "../src/interfaces/IRobinhoodLaunchpadBase.sol";
import {IRobinhoodStocksLaunchpadV1} from "../src/interfaces/IRobinhoodStocksLaunchpadV1.sol";
import {RobinhoodMemestockSplitterV1} from "../src/RobinhoodMemestockSplitterV1.sol";
import {RobinhoodFixture} from "./RobinhoodFixture.sol";

/// @notice The launch positions live in the fee-only locker forever: anyone may collect their LP fees,
///         which always land, in both pool currencies, in the launch's memestock splitter; the
///         liquidity itself can never leave. The locker is the Base Stocks contract, proved in full
///         there; this suite proves the Robinhood launchpad wires it correctly.
contract RobinhoodLockedLiquidityTest is RobinhoodFixture {
    function setUp() public {
        _deployRobinhood();
    }

    function test_collect_deposits_both_currencies_into_the_splitter_and_keeps_nothing() public {
        _collectCase(STOCK_LOW);
    }

    function test_collect_works_in_the_other_currency_order() public {
        _collectCase(STOCK_HIGH);
    }

    function _collectCase(address stockAddress) private {
        (Launched memory l,) = _graduatedStakedMarket(stockAddress);
        IRobinhoodLaunchpadBase.Launch memory record = stocks.launches(l.launchId);
        IRobinhoodStocksLaunchpadV1.StockRecord memory stockRecord = stocks.stockRecords(l.launchId);
        RobinhoodMemestockSplitterV1 splitter = _splitter(l);
        MockERC20 stock = MockERC20(stockAddress);
        MockERC20 memestock = MockERC20(l.newToken);

        // Trade both ways so LP fees accrue in both currencies.
        _fundTrader(l, 20e8);
        _swapCurrencyIn(l, address(stocksHook), 20e8);
        _swapNewIn(l, address(stocksHook), memestock.balanceOf(trader) / 2);

        uint128 fullLiquidity = positionManager.getPositionLiquidity(record.lpTokenId);
        uint128 sideLiquidity = positionManager.getPositionLiquidity(stockRecord.stockOnlyTokenId);
        uint256 safeStock = stock.balanceOf(safe);
        uint256 safeMemestock = memestock.balanceOf(safe);
        uint256 splitterStock = stock.balanceOf(address(splitter));
        uint256 splitterMemestock = memestock.balanceOf(address(splitter));

        vm.startPrank(outsider);
        (uint256 full0, uint256 full1) = locker.collect(record.lpTokenId);
        (uint256 side0, uint256 side1) = locker.collect(stockRecord.stockOnlyTokenId);
        vm.stopPrank();

        bool stockIs0 = stockAddress < l.newToken;
        uint256 stockFees = stockIs0 ? full0 + side0 : full1 + side1;
        uint256 memestockFees = stockIs0 ? full1 + side1 : full0 + side0;
        assertGt(stockFees, 0, "LP fees in STOCK");
        assertGt(memestockFees, 0, "LP fees in MEMESTOCK");

        // Every collected unit went through the splitter: 2% to the Safe, the rest to the staker.
        uint256 stockToSafe = stock.balanceOf(safe) - safeStock;
        uint256 memestockToSafe = memestock.balanceOf(safe) - safeMemestock;
        assertEq(stockToSafe + (stock.balanceOf(address(splitter)) - splitterStock), stockFees);
        assertEq(memestockToSafe + (memestock.balanceOf(address(splitter)) - splitterMemestock), memestockFees);
        assertApproxEqAbs(stockToSafe, stockFees * 200 / 10_000, 1);
        assertApproxEqAbs(memestockToSafe, memestockFees * 200 / 10_000, 1);
        assertApproxEqAbs(splitter.claimable(stockAddress, staker), stockFees - stockToSafe, 2);
        assertApproxEqAbs(splitter.claimable(l.newToken, staker), memestockFees - memestockToSafe, 2);
        assertEq(stock.balanceOf(outsider) + memestock.balanceOf(outsider), 0, "the caller earns nothing");

        // The locker keeps nothing and the positions are exactly as they were.
        assertEq(stock.balanceOf(address(locker)), 0);
        assertEq(memestock.balanceOf(address(locker)), 0);
        assertEq(positionManager.getPositionLiquidity(record.lpTokenId), fullLiquidity);
        assertEq(positionManager.getPositionLiquidity(stockRecord.stockOnlyTokenId), sideLiquidity);
    }

    function test_only_the_launchpad_registers_and_a_registration_is_forever() public {
        (Launched memory l,) = _graduatedStakedMarket(STOCK_LOW);
        IRobinhoodLaunchpadBase.Launch memory record = stocks.launches(l.launchId);
        address splitter = record.splitter;

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(MemestockLPLocker.NotLaunchpad.selector, outsider));
        locker.register(record.lpTokenId, _poolKey(l, address(stocksHook)), splitter);

        vm.prank(address(stocks));
        vm.expectRevert(abi.encodeWithSelector(MemestockLPLocker.AlreadyRegistered.selector, record.lpTokenId));
        locker.register(record.lpTokenId, _poolKey(l, address(stocksHook)), splitter);

        vm.expectRevert(abi.encodeWithSelector(MemestockLPLocker.UnregisteredPosition.selector, 999));
        locker.collect(999);
    }
}
