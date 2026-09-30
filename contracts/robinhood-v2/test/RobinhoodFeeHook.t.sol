// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IRobinhoodFeeHookV1} from "../src/interfaces/IRobinhoodFeeHookV1.sol";
import {RobinhoodFeeHookV1} from "../src/RobinhoodFeeHookV1.sol";
import {RobinhoodMemestockSplitterV1} from "../src/RobinhoodMemestockSplitterV1.sol";
import {RobinhoodFixture} from "./RobinhoodFixture.sol";

/// @notice The fee hook on a stock-pair pool: 0.3% of STOCK to the creator, 1% to the protocol lane and
///         3% to the staker lane, all always on. The creator lane settles permissionlessly, in STOCK, to
///         the launcher; the protocol lane settles executor-only through the admitted route into the inbox
///         as USDG; the staker lane settles permissionlessly, in STOCK, into the launch's memestock splitter.
contract RobinhoodFeeHookTest is RobinhoodFixture {
    uint256 internal constant TRADE = 10e18;
    uint256 internal constant CREATOR_LANE = TRADE * 30 / 10_000;
    uint256 internal constant PROTOCOL_LANE = TRADE / 100;
    uint256 internal constant STAKER_LANE = TRADE * 300 / 10_000;

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

    function test_every_swap_accrues_three_stock_lanes_and_the_pool_is_bound_to_its_splitter_and_creator() public {
        (Launched memory l,) = _graduatedStakedMarket(STOCK_LOW);
        bytes32 poolId = _poolId(l, address(stocksHook));
        (uint256 creatorBefore, uint256 dust, uint256 stakerBefore) = stocksHook.accrued(poolId);
        assertEq(creatorBefore, 0);
        assertEq(stakerBefore, 0);

        RobinhoodFeeHookV1.PoolRecord memory bound = stocksHook.pool(poolId);
        assertEq(bound.stock, STOCK_LOW);
        assertEq(bound.newToken, l.newToken);
        assertEq(bound.splitter, address(_splitter(l)));
        assertEq(bound.creator, launcher);

        _fundTrader(l, TRADE);
        vm.expectEmit(true, false, false, true, address(stocksHook));
        emit IRobinhoodFeeHookV1.HookFeeAccrued(poolId, TRADE, CREATOR_LANE, PROTOCOL_LANE, STAKER_LANE);
        _swapCurrencyIn(l, address(stocksHook), TRADE);

        (uint256 creatorLane, uint256 protocolLane, uint256 stakerLane) = stocksHook.accrued(poolId);
        assertEq(creatorLane, CREATOR_LANE);
        assertEq(protocolLane, dust + PROTOCOL_LANE);
        assertEq(stakerLane, STAKER_LANE);
        assertEq(stockLow.balanceOf(address(stocksHook)), dust + TRADE * 430 / 10_000);
    }

    function test_creator_lane_settles_permissionlessly_in_stock_to_the_launcher() public {
        (Launched memory l,) = _graduatedStakedMarket(STOCK_LOW);
        bytes32 poolId = _poolId(l, address(stocksHook));

        vm.expectRevert(RobinhoodFeeHookV1.ZeroAmount.selector);
        stocksHook.settleCreatorLane(poolId);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodFeeHookV1.PoolNotRegistered.selector, bytes32(uint256(1))));
        stocksHook.settleCreatorLane(bytes32(uint256(1)));

        _fundTrader(l, TRADE);
        _swapCurrencyIn(l, address(stocksHook), TRADE);
        (, uint256 protocolBefore, uint256 stakerBefore) = stocksHook.accrued(poolId);
        uint256 launcherBefore = stockLow.balanceOf(launcher);

        vm.expectEmit(true, true, false, true, address(stocksHook));
        emit IRobinhoodFeeHookV1.CreatorLaneSettled(poolId, launcher, CREATOR_LANE);
        vm.prank(outsider);
        assertEq(stocksHook.settleCreatorLane(poolId), CREATOR_LANE);

        assertEq(stockLow.balanceOf(launcher), launcherBefore + CREATOR_LANE);
        (uint256 creatorAfter, uint256 protocolAfter, uint256 stakerAfter) = stocksHook.accrued(poolId);
        assertEq(creatorAfter, 0);
        assertEq(protocolAfter, protocolBefore);
        assertEq(stakerAfter, stakerBefore);
        (uint256 toCreator,,,) = stocksHook.settled(poolId);
        assertEq(toCreator, CREATOR_LANE);
        assertEq(stockLow.balanceOf(address(stocksHook)), protocolAfter + stakerAfter);
    }

    function test_protocol_lane_settles_executor_only_through_the_route_into_the_inbox() public {
        (Launched memory l,) = _graduatedStakedMarket(STOCK_LOW);
        bytes32 poolId = _poolId(l, address(stocksHook));
        _fundTrader(l, TRADE);
        _swapCurrencyIn(l, address(stocksHook), TRADE);
        uint256 lane = PROTOCOL_LANE;
        (, uint256 protocolBefore,) = stocksHook.accrued(poolId);

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

        uint256 expectedUsdg = lane * USDG_PER_SHARE / 1e18;
        uint256 inboxBefore = inbox.totalCollected();
        vm.expectEmit(true, false, false, true, address(stocksHook));
        emit IRobinhoodFeeHookV1.ProtocolLaneSettled(poolId, lane, expectedUsdg);
        vm.prank(executor);
        stocksHook.settleProtocolLane(poolId, lane, expectedUsdg);

        assertEq(inbox.totalCollected(), inboxBefore + expectedUsdg);
        (uint256 creatorAfter, uint256 protocolAfter, uint256 stakerAfter) = stocksHook.accrued(poolId);
        assertEq(protocolAfter, protocolBefore - lane);
        assertEq(creatorAfter, CREATOR_LANE);
        assertEq(stakerAfter, STAKER_LANE);
        (, uint256 stockConverted, uint256 usdgDeposited, uint256 toStakers) = stocksHook.settled(poolId);
        assertEq(stockConverted, lane);
        assertEq(usdgDeposited, expectedUsdg);
        assertEq(toStakers, 0);
        assertEq(usdg.balanceOf(address(stocksHook)), 0);
        assertEq(usdg.allowance(address(stocksHook), address(inbox)), 0);
        assertEq(stockLow.balanceOf(address(stocksHook)), creatorAfter + protocolAfter + stakerAfter);
    }

    function test_protocol_lane_refuses_a_conversion_below_the_executor_minimum() public {
        (Launched memory l,) = _graduatedStakedMarket(STOCK_LOW);
        bytes32 poolId = _poolId(l, address(stocksHook));
        _fundTrader(l, TRADE);
        _swapCurrencyIn(l, address(stocksHook), TRADE);
        uint256 lane = PROTOCOL_LANE;
        uint256 expectedUsdg = lane * USDG_PER_SHARE / 1e18;

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

        _fundTrader(l, TRADE);
        _swapCurrencyIn(l, address(stocksHook), TRADE);
        uint256 lane = STAKER_LANE;
        uint256 safeBefore = stockHigh.balanceOf(safe);
        (uint256 creatorBefore, uint256 protocolBefore,) = stocksHook.accrued(poolId);

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

        (uint256 creatorAfter, uint256 protocolAfter, uint256 stakerAfter) = stocksHook.accrued(poolId);
        assertEq(creatorAfter, creatorBefore);
        assertEq(protocolAfter, protocolBefore);
        assertEq(stakerAfter, 0);
        (,,, uint256 toStakers) = stocksHook.settled(poolId);
        assertEq(toStakers, lane);
        assertEq(stockHigh.allowance(address(stocksHook), address(splitter)), 0);
        assertEq(stockHigh.balanceOf(address(stocksHook)), creatorAfter + protocolAfter);
    }

    function test_launchpad_only_and_safe_only_surfaces() public {
        Launched memory l = _launchStock(STOCK_LOW);
        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodFeeHookV1.NotLaunchpad.selector, outsider));
        stocksHook.registerPool(
            _poolKey(l, address(stocksHook)), l.currency, l.newToken, address(0x5717), address(0xC4EA)
        );
        vm.expectRevert(abi.encodeWithSelector(RobinhoodFeeHookV1.NotLaunchpad.selector, outsider));
        stocksHook.creditProtocolLane(bytes32(0), 1);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodFeeHookV1.NotSafe.selector, outsider));
        stocksHook.setExecutor(outsider);
        vm.stopPrank();

        vm.prank(address(stocks));
        vm.expectRevert(RobinhoodFeeHookV1.ZeroAddress.selector);
        stocksHook.registerPool(_poolKey(l, address(stocksHook)), l.currency, l.newToken, address(0), launcher);
        vm.prank(address(stocks));
        vm.expectRevert(RobinhoodFeeHookV1.ZeroAddress.selector);
        stocksHook.registerPool(_poolKey(l, address(stocksHook)), l.currency, l.newToken, address(0x5717), address(0));
    }
}
