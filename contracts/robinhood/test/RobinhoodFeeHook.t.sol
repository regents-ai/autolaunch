// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";
import {IRobinhoodFeeHookV1} from "../src/interfaces/IRobinhoodFeeHookV1.sol";
import {RobinhoodFeeHookV1} from "../src/RobinhoodFeeHookV1.sol";
import {RobinhoodMemestockSplitterV1} from "../src/RobinhoodMemestockSplitterV1.sol";
import {RobinhoodFixture} from "./RobinhoodFixture.sol";

/// @notice The fee hook on a stock-pair pool: one percent of STOCK per lane, both lanes always on. The
///         protocol lane settles executor-only through the admitted route into the inbox as USDG; the
///         staker lane settles permissionlessly, in STOCK, into the launch's memestock splitter.
contract RobinhoodFeeHookTest is RobinhoodFixture {
    function setUp() public {
        _deployRobinhood();
    }

    function test_hook_bindings() public view {
        assertEq(stocksHook.launchpad(), address(stocks));
        assertEq(stocksHook.usdg(), USDG_ADDRESS);
        assertEq(stocksHook.inbox(), address(inbox));
        assertEq(stocksHook.adminSafe(), safe);
        assertEq(stocksHook.executor(), executor);
    }

    function test_every_swap_accrues_two_equal_stock_lanes_and_the_pool_is_bound_to_its_splitter() public {
        (Launched memory l,) = _graduatedStakedMarket(STOCK_LOW);
        bytes32 poolId = _poolId(l, address(stocksHook));
        (uint256 dust, uint256 stakerBefore) = stocksHook.accrued(poolId);
        assertEq(stakerBefore, 0);

        RobinhoodFeeHookV1.PoolRecord memory bound = stocksHook.pool(poolId);
        assertEq(bound.stock, STOCK_LOW);
        assertEq(bound.newToken, l.newToken);
        assertEq(bound.splitter, address(_splitter(l)));

        _fundTrader(l, 10e8);
        uint256 lane = 10e8 / StocksPreset.LANE_DIVISOR;
        vm.expectEmit(true, false, false, true, address(stocksHook));
        emit IRobinhoodFeeHookV1.HookFeeAccrued(poolId, 10e8, lane, lane);
        _swapCurrencyIn(l, address(stocksHook), 10e8);

        (uint256 protocolLane, uint256 stakerLane) = stocksHook.accrued(poolId);
        assertEq(protocolLane, dust + lane);
        assertEq(stakerLane, lane);
        assertEq(stockLow.balanceOf(address(stocksHook)), dust + 2 * lane);
    }

    function test_protocol_lane_settles_executor_only_through_the_route_into_the_inbox() public {
        (Launched memory l,) = _graduatedStakedMarket(STOCK_LOW);
        bytes32 poolId = _poolId(l, address(stocksHook));
        _fundTrader(l, 10e8);
        _swapCurrencyIn(l, address(stocksHook), 10e8);
        uint256 lane = 10e8 / StocksPreset.LANE_DIVISOR;
        (uint256 protocolBefore,) = stocksHook.accrued(poolId);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodFeeHookV1.NotExecutor.selector, outsider));
        stocksHook.settleProtocolLane(poolId, lane, 0);

        vm.startPrank(executor);
        vm.expectRevert(RobinhoodFeeHookV1.ZeroAmount.selector);
        stocksHook.settleProtocolLane(poolId, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodFeeHookV1.InsufficientAccrual.selector, protocolBefore, protocolBefore + 1)
        );
        stocksHook.settleProtocolLane(poolId, protocolBefore + 1, 0);
        vm.stopPrank();

        uint256 expectedUsdg = lane * USDG_PER_SHARE / 1e8;
        uint256 inboxBefore = inbox.totalCollected();
        vm.expectEmit(true, false, false, true, address(stocksHook));
        emit IRobinhoodFeeHookV1.ProtocolLaneSettled(poolId, lane, expectedUsdg);
        vm.prank(executor);
        stocksHook.settleProtocolLane(poolId, lane, expectedUsdg);

        assertEq(inbox.totalCollected(), inboxBefore + expectedUsdg);
        (uint256 protocolAfter, uint256 stakerAfter) = stocksHook.accrued(poolId);
        assertEq(protocolAfter, protocolBefore - lane);
        assertEq(stakerAfter, lane);
        (uint256 stockConverted, uint256 usdgDeposited, uint256 toStakers) = stocksHook.settled(poolId);
        assertEq(stockConverted, lane);
        assertEq(usdgDeposited, expectedUsdg);
        assertEq(toStakers, 0);
        assertEq(usdg.balanceOf(address(stocksHook)), 0);
        assertEq(usdg.allowance(address(stocksHook), address(inbox)), 0);
        assertEq(stockLow.balanceOf(address(stocksHook)), protocolAfter + stakerAfter);
    }

    function test_protocol_lane_refuses_a_conversion_below_the_executor_minimum() public {
        (Launched memory l,) = _graduatedStakedMarket(STOCK_LOW);
        bytes32 poolId = _poolId(l, address(stocksHook));
        _fundTrader(l, 10e8);
        _swapCurrencyIn(l, address(stocksHook), 10e8);
        uint256 lane = 10e8 / StocksPreset.LANE_DIVISOR;
        uint256 expectedUsdg = lane * USDG_PER_SHARE / 1e8;

        vm.prank(executor);
        vm.expectRevert();
        stocksHook.settleProtocolLane(poolId, lane, expectedUsdg + 1);
    }

    function test_staker_lane_settles_permissionlessly_in_stock_into_the_splitter() public {
        (Launched memory l,) = _graduatedStakedMarket(STOCK_HIGH);
        bytes32 poolId = _poolId(l, address(stocksHook));
        RobinhoodMemestockSplitterV1 splitter = _splitter(l);

        vm.expectRevert(RobinhoodFeeHookV1.ZeroAmount.selector);
        stocksHook.settleStakerLane(poolId);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodFeeHookV1.PoolNotRegistered.selector, bytes32(uint256(1))));
        stocksHook.settleStakerLane(bytes32(uint256(1)));

        _fundTrader(l, 10e8);
        _swapCurrencyIn(l, address(stocksHook), 10e8);
        uint256 lane = 10e8 / StocksPreset.LANE_DIVISOR;
        uint256 safeBefore = stockHigh.balanceOf(safe);
        (uint256 protocolBefore,) = stocksHook.accrued(poolId);

        vm.expectEmit(true, true, false, true, address(stocksHook));
        emit IRobinhoodFeeHookV1.StakerLaneSettled(poolId, address(splitter), lane);
        vm.prank(outsider);
        uint256 deposited = stocksHook.settleStakerLane(poolId);
        assertEq(deposited, lane);

        // The splitter's 2% went to the Safe in STOCK; the rest is the lone staker's.
        uint256 protocolShare = lane * 200 / 10_000;
        assertEq(stockHigh.balanceOf(safe), safeBefore + protocolShare);
        // Up to one unit waits as dust when the stake does not divide the share evenly.
        assertApproxEqAbs(splitter.claimable(STOCK_HIGH, staker), lane - protocolShare, 1);
        assertEq(stockHigh.balanceOf(outsider), 0);

        (uint256 protocolAfter, uint256 stakerAfter) = stocksHook.accrued(poolId);
        assertEq(protocolAfter, protocolBefore);
        assertEq(stakerAfter, 0);
        (,, uint256 toStakers) = stocksHook.settled(poolId);
        assertEq(toStakers, lane);
        assertEq(stockHigh.allowance(address(stocksHook), address(splitter)), 0);
        assertEq(stockHigh.balanceOf(address(stocksHook)), protocolAfter);
    }

    function test_launchpad_only_and_safe_only_surfaces() public {
        Launched memory l = _launchStock(STOCK_LOW);
        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodFeeHookV1.NotLaunchpad.selector, outsider));
        stocksHook.registerPool(_poolKey(l, address(stocksHook)), l.currency, l.newToken, address(0x5717));
        vm.expectRevert(abi.encodeWithSelector(RobinhoodFeeHookV1.NotLaunchpad.selector, outsider));
        stocksHook.creditProtocolLane(bytes32(0), 1);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodFeeHookV1.NotSafe.selector, outsider));
        stocksHook.setExecutor(outsider);
        vm.stopPrank();

        vm.prank(address(stocks));
        vm.expectRevert(RobinhoodFeeHookV1.ZeroAddress.selector);
        stocksHook.registerPool(_poolKey(l, address(stocksHook)), l.currency, l.newToken, address(0));
    }
}
