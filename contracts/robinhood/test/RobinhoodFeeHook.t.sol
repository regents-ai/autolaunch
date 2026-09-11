// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {MockERC20} from "autolaunch-stocks-test/mocks/MockERC20.sol";
import {StocksPreset} from "autolaunch-stocks/StocksPreset.sol";
import {RobinhoodFeeHookV1} from "../src/RobinhoodFeeHookV1.sol";
import {RobinhoodPreset} from "../src/RobinhoodPreset.sol";
import {RobinhoodSubjectSplitterV1} from "../src/RobinhoodSubjectSplitterV1.sol";
import {RobinhoodFixture} from "./RobinhoodFixture.sol";

/// @notice The fee hook on both pool kinds: one percent per lane in the pool's fee currency, protocol
///         lane always on, subject lane only with a splitter; USDG buckets settle permissionlessly
///         into the inbox or the splitter, STOCK buckets settle executor-only through the admitted route.
contract RobinhoodFeeHookTest is RobinhoodFixture {
    function setUp() public {
        _deployRobinhood();
    }

    function test_hook_bindings() public view {
        assertEq(revshareHook.launchpad(), address(revshare));
        assertEq(stocksHook.launchpad(), address(stocks));
        assertEq(revshareHook.usdg(), USDG_ADDRESS);
        assertEq(revshareHook.inbox(), address(inbox));
        assertEq(revshareHook.PROTOCOL_DESTINATION(), address(inbox));
        assertEq(stocksHook.executor(), executor);
    }

    function test_usdg_pool_accrues_both_lanes_and_settles_into_inbox_and_splitter() public {
        Launched memory l = _launchRevshare();
        _graduateRevshare(l);
        bytes32 poolId = _poolId(l, address(revshareHook));
        address splitter = revshare.splitterOf(l.newToken);

        _fundTrader(l, 100e6);
        _swapCurrencyIn(l, address(revshareHook), 100e6);

        uint256 lane = 100e6 / StocksPreset.LANE_DIVISOR;
        assertEq(revshareHook.accrued(poolId, address(inbox)), lane);
        assertEq(revshareHook.accrued(poolId, splitter), lane);
        assertEq(usdg.balanceOf(address(revshareHook)), 2 * lane);

        uint256 inboxBefore = inbox.totalCollected();
        vm.prank(outsider);
        revshareHook.settle(poolId, address(inbox), lane, 0);
        assertEq(inbox.totalCollected(), inboxBefore + lane);
        assertEq(revshareHook.accrued(poolId, address(inbox)), 0);

        uint256 treasuryBefore = usdg.balanceOf(treasury);
        vm.prank(outsider);
        revshareHook.settle(poolId, splitter, lane, 0);
        uint256 skim = lane * RobinhoodPreset.PROTOCOL_SKIM_BPS / 10_000;
        assertEq(inbox.totalCollected(), inboxBefore + lane + skim);
        // No stakers: the whole net goes to the treasury.
        assertEq(usdg.balanceOf(treasury), treasuryBefore + lane - skim);
        assertEq(usdg.balanceOf(address(revshareHook)), 0);
        assertEq(usdg.allowance(address(revshareHook), address(inbox)), 0);
        assertEq(usdg.allowance(address(revshareHook), splitter), 0);
    }

    function test_stock_pool_without_subject_accrues_one_lane_and_settles_executor_only() public {
        Launched memory l = _launchStock(STOCK_LOW);
        _graduateStock(l);
        bytes32 poolId = _poolId(l, address(stocksHook));
        uint256 dust = stocksHook.accrued(poolId, address(inbox));

        _fundTrader(l, 10e8);
        _swapCurrencyIn(l, address(stocksHook), 10e8);
        uint256 lane = 10e8 / StocksPreset.LANE_DIVISOR;
        assertEq(stocksHook.accrued(poolId, address(inbox)), dust + lane);
        assertEq(stockLow.balanceOf(address(stocksHook)), dust + lane);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodFeeHookV1.NotExecutor.selector, outsider));
        stocksHook.settle(poolId, address(inbox), lane, 0);

        uint256 expectedUsdg = lane * USDG_PER_SHARE / 1e8;
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodFeeHookV1.InsufficientUsdgOut.selector, expectedUsdg + 1, expectedUsdg)
        );
        stocksHook.settle(poolId, address(inbox), lane, expectedUsdg + 1);

        uint256 inboxBefore = inbox.totalCollected();
        vm.prank(executor);
        stocksHook.settle(poolId, address(inbox), lane, expectedUsdg);
        assertEq(inbox.totalCollected(), inboxBefore + expectedUsdg);
        assertEq(stocksHook.accrued(poolId, address(inbox)), dust);
        assertEq(stockLow.balanceOf(address(stocksHook)), dust);
        assertEq(usdg.balanceOf(address(stocksHook)), 0);
    }

    function test_launchpad_only_and_safe_only_surfaces() public {
        Launched memory l = _launchStock(STOCK_LOW);
        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodFeeHookV1.NotLaunchpad.selector, outsider));
        stocksHook.registerPool(_poolKey(l, address(stocksHook)), l.currency, l.newToken, address(0));
        vm.expectRevert(abi.encodeWithSelector(RobinhoodFeeHookV1.NotLaunchpad.selector, outsider));
        stocksHook.creditProtocolLane(bytes32(0), 1);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodFeeHookV1.NotSafe.selector, outsider));
        stocksHook.setExecutor(outsider);
        vm.stopPrank();
    }
}
